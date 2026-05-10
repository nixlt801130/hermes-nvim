-- hermes.lua — Hermes Agent Neovim Plugin
-- Async chat + streaming + code editing via Hermes CLI

local M = {}

M.config = {
  chat_window  = "right",   -- "right" or "bottom"
  chat_width   = 60,
  chat_height  = 20,
  hermes_cmd   = "hermes",
  send_context = true,      -- auto-prefix current file/cursor info to chat
  confirm_edits = true,    -- show diff preview before applying edits
}

-- ── internal state ──────────────────────────────────────────

local state = { buf = nil, win = nil, job = nil, timer = nil, header_lines = 0, context_file = nil, context_line = nil, edit_orig = nil, edit_path = nil, status_model = nil, start_time = nil }

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- ── spinner ─────────────────────────────────────────────────

-- search backwards from end of buffer for the spinner line
local function find_spinner_line(lines)
  for i = #lines, 1, -1 do
    if lines[i]:match("^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] Thinking") then
      return i
    end
  end
  return nil
end

local function spinner_start(buf)
  local idx = 1
  if state.timer then pcall(vim.fn.timer_stop, state.timer); state.timer = nil end
  state.start_time = os.time()
  state.timer = vim.fn.timer_start(100, vim.schedule_wrap(function()
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.fn.timer_stop, state.timer)
      state.timer = nil
      return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local sl = find_spinner_line(lines)
    if sl then
      vim.api.nvim_buf_set_lines(buf, sl - 1, sl, false, { SPINNER[idx] .. " Thinking..." })
    end
    -- Update header status line (3rd line, 0-indexed: 2)
    if state.status_model and state.start_time then
      local elapsed = math.floor(os.difftime(os.time(), state.start_time))
      local elapsed_str
      if elapsed < 60 then
        elapsed_str = elapsed .. "s"
      elseif elapsed < 3600 then
        elapsed_str = math.floor(elapsed / 60) .. "m " .. (elapsed % 60) .. "s"
      else
        elapsed_str = math.floor(elapsed / 3600) .. "h " .. math.floor((elapsed % 3600) / 60) .. "m"
      end
      local inner = "  " .. state.status_model .. " │ ⏲ " .. elapsed_str
      local pad = 44 - #inner
      if pad < 0 then pad = 0 end
      pcall(vim.api.nvim_buf_set_lines, buf, 2, 3, false, { "║" .. inner .. string.rep(" ", pad) .. "║" })
    end
    idx = (idx % #SPINNER) + 1
  end), { ["repeat"] = -1 })
end

local function spinner_stop(buf)
  if state.timer then
    pcall(vim.fn.timer_stop, state.timer)
    state.timer = nil
  end
  state.start_time = nil
  if buf and vim.api.nvim_buf_is_valid(buf) then
    -- Restore model line in header
    if state.status_model then
      local restored = "║  Model: " .. state.status_model .. string.rep(" ", 35 - #state.status_model) .. "║"
      pcall(vim.api.nvim_buf_set_lines, buf, 2, 3, false, { restored })
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local sl = find_spinner_line(lines)
    if sl then
      vim.api.nvim_buf_set_lines(buf, sl - 1, sl, false, { "✓ Done" })
    end
  end
end

-- ── diff preview ───────────────────────────────────────────

local function compute_diff_text(orig, new)
  if #orig == #new then
    local same = true
    for i = 1, #orig do
      if orig[i] ~= new[i] then same = false; break end
    end
    if same then return nil end
  end
  local ok, ret = pcall(vim.diff, table.concat(orig, "\n"), table.concat(new, "\n"), { result_type = "unified" })
  if ok then return ret end
  return nil
end

-- show diff in floating window with inline prompt, return boolean
local function confirm_diff(diff_text, fpath)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].modifiable = true

  local max_w = vim.o.columns - 4
  local max_h = vim.o.lines - 8
  local width = math.min(max_w, 100)
  local height = math.min(max_h, 20)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = 2,
    style = "minimal",
    border = "single",
    title = " Hermes diff — " .. vim.fn.fnamemodify(fpath, ":t") .. " ",
  })

  -- Build lines: diff content + inline prompt footer
  local lines = {}
  for _, l in ipairs(vim.split(diff_text, "\n")) do
    table.insert(lines, l)
  end
  table.insert(lines, "")
  table.insert(lines, string.rep("─", width - 4))
  table.insert(lines, "  y  = accept this edit")
  table.insert(lines, "  n / q  = reject this edit")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "diff"

  vim.api.nvim_set_current_win(win)
  vim.cmd("redraw")

  -- Block and wait for a keypress inside the floating window
  local choice = nil
  while choice == nil do
    local raw = vim.fn.getchar()
    local char
    if type(raw) == "number" then
      char = vim.fn.nr2char(raw)
    else
      char = raw
    end
    if char == "y" or char == "Y" then
      choice = true
    elseif char == "n" or char == "N" or char == "q" or char == "\27" or char == "\r" then
      choice = false
    end
  end

  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  return choice
end

-- shared edit flow: save orig → run → diff confirm → apply/revert
local function do_hermes_edit(path, callback)
  state.edit_orig = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  state.edit_path = path
  callback()
end

local function finish_edit()
  local orig = state.edit_orig
  local path = state.edit_path
  state.edit_orig = nil
  state.edit_path = nil
  if not orig or not path or not M.config.confirm_edits then
    vim.cmd("edit!")
    return true
  end

  -- Read new file content from disk
  local f = io.open(path, "r")
  if not f then vim.cmd("edit!"); return true end
  local new_str = f:read("*all")
  f:close()
  -- vim.split adds trailing empty string for trailing newlines
  local new_lines = vim.split(new_str, "\n")
  if #new_lines > 0 and new_lines[#new_lines] == "" then
    table.remove(new_lines)
  end

  local diff_text = compute_diff_text(orig, new_lines)
  if not diff_text then
    -- No actual changes
    vim.cmd("edit!")
    vim.notify("Hermes: no changes made", vim.log.levels.INFO)
    return false
  end

  local accepted = confirm_diff(diff_text, path)
  if accepted then
    vim.cmd("edit!")
    vim.notify("✓ Hermes: changes applied", vim.log.levels.INFO)
    return true
  else
    -- Revert: write original back to disk and reload
    f = io.open(path, "w")
    f:write(table.concat(orig, "\n"))
    f:close()
    vim.cmd("edit!")
    vim.notify("✗ Hermes: changes reverted", vim.log.levels.INFO)
    return false
  end
end

-- ── helpers ─────────────────────────────────────────────────

local function append(buf, lines)
  local safe = {}
  for _, l in ipairs(lines) do
    for part in l:gmatch("([^\n]*)\n?") do
      table.insert(safe, part)
    end
  end
  local n = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, n, n, false, safe)
end

local function scroll_bottom(win)
  local n = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  pcall(vim.api.nvim_win_set_cursor, win, { n, 0 })
end

local function get_model()
  local ok, out = pcall(vim.fn.system, "hermes config show 2>/dev/null")
  if not ok or out == "" then return "?" end
  for line in out:gmatch("[^\n]+") do
    local m = line:match("default.*: '([^']+)'")
    if m then return m end
    m = line:match("default.*: ([%w/._-]+)")
    if m then return m end
  end
  return "?"
end

-- remove the first line matching the spinner pattern from a buffer lines table
local function strip_spinner(lines)
  for i = #lines, 1, -1 do
    if lines[i]:match("^[✓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]") then
      table.remove(lines, i)
      return
    end
  end
end

-- ── chat window ─────────────────────────────────────────────

function M.open_chat()
  -- remember which file and line we were editing, so Hermes knows the context
  state.context_file = vim.api.nvim_buf_get_name(0)
  state.context_line = vim.fn.line(".")

  M.close_chat()

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype  = "nofile"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].modifiable = true

  local is_right = M.config.chat_window == "right"
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width    = M.config.chat_width,
    height   = M.config.chat_height,
    col      = is_right and vim.o.columns - M.config.chat_width or 0,
    row      = is_right and 0 or vim.o.lines - M.config.chat_height,
    style    = "minimal",
    border   = "rounded",
  })

  -- buffer-local mappings
  local km = function(m, l, r)
    vim.api.nvim_buf_set_keymap(state.buf, m, l, r, { noremap = true, silent = true })
  end
  km("n", "q",       "<cmd>lua require('hermes').close_chat()<CR>")
  km("n", "<CR>",    "<cmd>lua require('hermes').send_message()<CR>")
  km("i", "<CR>",    "<cmd>lua require('hermes').send_message()<CR>")

  local model = get_model()
  state.status_model = model
  local model_line = "║  Model: " .. model .. string.rep(" ", 35 - #model) .. "║"

  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {
    "╔═══════════════════════════════════════════╗",
    "║        Hermes Agent Chat                 ║",
    model_line,
    "╚═══════════════════════════════════════════╝",
    "",
    "  Type below and press Enter  |  q = close",
    "",
  })
  state.header_lines = 7

  vim.api.nvim_win_set_cursor(state.win, { state.header_lines, 0 })
  vim.cmd("startinsert!")
end

function M.close_chat()
  if state.job then vim.fn.jobstop(state.job); state.job = nil end
  if state.timer then pcall(vim.fn.timer_stop, state.timer); state.timer = nil end
  state.start_time = nil
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.buf = nil; state.win = nil
end

-- ── send message ────────────────────────────────────────────

function M.send_message()
  local buf = state.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    vim.notify("Hermes: chat not open", vim.log.levels.ERROR)
    return
  end

  -- get cursor position (1-indexed row) and read that line as the message
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local row = cursor[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local msg = vim.trim(lines[row] or "")

  if msg == "" then
    vim.notify("Hermes: nothing to send", vim.log.levels.WARN)
    return
  end

  -- clear the input line
  lines[row] = ""
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- append user message + thinking indicator
  append(buf, { "You: " .. msg, "⠋ Thinking..." })
  scroll_bottom(state.win)
  spinner_start(buf)

  -- attach file/cursor context so Hermes knows which file we're talking about
  if M.config.send_context and state.context_file and state.context_file ~= "" then
    local short = vim.fn.fnamemodify(state.context_file, ":~:.")
    msg = "[file: " .. short .. " | cursor: line " .. (state.context_line or 1) .. "]\n" .. msg
  end

  -- PYTHONUNBUFFERED forces real-time line-by-line output from Hermes CLI
  local cmd = "PYTHONUNBUFFERED=1 " .. M.config.hermes_cmd
    .. " chat -q " .. vim.fn.shellescape(msg) .. " --quiet"
  local stderr = {}

  -- streaming state
  local stream_started = false
  local partial = ""

  state.job = vim.fn.jobstart(cmd, {
    stdout_buffered = false,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
      if not data or #data == 0 then return end
      -- data is an array of lines from the latest chunk.
      -- The last element may be a partial line (if output doesn't end with \n).
      -- Neovim handles line splitting but may deliver partial lines at chunk boundaries.
      local complete = {}
      for _, l in ipairs(data) do
        if partial ~= "" then
          l = partial .. l
          partial = ""
        end
        table.insert(complete, l)
      end
      -- If the last element is non-empty, it might be partial — save for next chunk
      local last = complete[#complete]
      if last ~= "" then
        partial = table.remove(complete)
      end
      if #complete == 0 then return end

      if not stream_started then
        stream_started = true
        spinner_stop(buf)
        -- Replace the spinner line with "Hermes:" + first content chunk
        local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        strip_spinner(cur)
        table.insert(cur, "Hermes:")
        for _, l in ipairs(complete) do
          table.insert(cur, "  " .. l)
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, cur)
      else
        -- Append subsequent chunks
        local add = {}
        for _, l in ipairs(complete) do
          table.insert(add, "  " .. l)
        end
        append(buf, add)
      end
      scroll_bottom(state.win)
    end,
    on_stderr = function(_, d)
      if d then for _, l in ipairs(d) do table.insert(stderr, l) end end
    end,
    on_exit = function(_, code)
      state.job = nil
      if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

      local ok, err = pcall(function()
        -- Flush any remaining partial line
        if partial ~= "" then
          if not stream_started then
            stream_started = true
            spinner_stop(buf)
            local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            strip_spinner(cur)
            table.insert(cur, "Hermes:")
            table.insert(cur, "  " .. partial)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, cur)
          else
            append(buf, { "  " .. partial })
          end
          partial = ""
          scroll_bottom(state.win)
        end

        if not stream_started then
          -- No output at all — remove spinner, show result
          spinner_stop(buf)
          local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          strip_spinner(cur)
          if code ~= 0 then
            local detail = ""
            if #stderr > 0 then
              detail = ": " .. table.concat(stderr, " | "):gsub("^%s*(.-)%s*$", "%1"):sub(1, 200)
            end
            vim.notify("Hermes CLI exit " .. code .. detail, vim.log.levels.ERROR)
            table.insert(cur, "⚠ Hermes CLI failed (exit " .. code .. ")")
            if stderr[1] then table.insert(cur, "  " .. stderr[1]) end
          else
            table.insert(cur, "Hermes:")
            table.insert(cur, "  _(no output)_")
          end
          table.insert(cur, "")
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, cur)
        elseif code ~= 0 then
          -- Streaming started but process exited with error
          local detail = ""
          if #stderr > 0 then
            detail = ": " .. table.concat(stderr, " | "):gsub("^%s*(.-)%s*$", "%1"):sub(1, 200)
          end
          vim.notify("Hermes CLI exit " .. code .. detail, vim.log.levels.ERROR)
          append(buf, { "", "⚠ CLI error (exit " .. code .. ")", "" })
        else
          -- Success — stop spinner if still running (shouldn't be, but safety)
          spinner_stop(buf)
        end

        -- add a fresh blank input line and go back to insert
        local n = vim.api.nvim_buf_line_count(buf)
        vim.api.nvim_buf_set_lines(buf, n, n, false, { "" })
        vim.api.nvim_win_set_cursor(state.win, { n + 1, 0 })
        vim.cmd("startinsert!")

        -- if Hermes modified any files on disk, pick up the changes
        pcall(vim.cmd, "checktime")
      end)
      if not ok then
        vim.notify("Hermes: internal error: " .. tostring(err), vim.log.levels.ERROR)
        pcall(append, buf, { "⚠ Plugin error: " .. tostring(err), "" })
        pcall(scroll_bottom, state.win)
      end
    end,
  })

  if state.job <= 0 then
    vim.notify("Hermes: failed to start CLI", vim.log.levels.ERROR)
    spinner_stop(buf)
  end
end

-- ── edit selection ──────────────────────────────────────────

function M.edit_selection()
  local start = vim.api.nvim_buf_get_mark(0, "<")
  local stop  = vim.api.nvim_buf_get_mark(0, ">")
  if start[1] == 0 or stop[1] == 0 then
    vim.notify("Hermes: no selection", vim.log.levels.WARN)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(0, start[1] - 1, stop[1], false)
  local text  = table.concat(lines, "\n")
  local path  = vim.api.nvim_buf_get_name(0)
  if path == "" then
    vim.notify("Hermes: save the file first", vim.log.levels.WARN)
    return
  end

  local instr = vim.fn.input("Hermes edit: ")
  if instr == "" then return end

  vim.notify("🔄 Hermes editing...", vim.log.levels.INFO)

  local prompt = ("Edit this code in %s (lines %d-%d): %s\n\n```\n%s\n```")
    :format(path, start[1], stop[1], instr, text)

  do_hermes_edit(path, function()
    vim.fn.jobstart(M.config.hermes_cmd .. " chat -q " .. vim.fn.shellescape(prompt)
      .. " --quiet --yolo", {
      stdout_buffered = true,
      on_exit = function(_, code)
        if code == 0 then
          local saved_line = vim.fn.line(".")
          local applied = finish_edit()
          if applied then
            pcall(vim.api.nvim_win_set_cursor, 0, { saved_line, 0 })
            vim.cmd("normal! zz")
          end
        else
          vim.notify("⚠ Hermes edit failed (" .. code .. ")", vim.log.levels.ERROR)
        end
      end,
    })
  end)
end

-- ── edit file (no selection needed) ────────────────────────

function M.edit_file()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    vim.notify("Hermes: save the file first", vim.log.levels.WARN)
    return
  end

  local instr = vim.fn.input("Hermes fix: ")
  if instr == "" then return end

  vim.notify("🔄 Hermes fixing...", vim.log.levels.INFO)

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local text  = table.concat(lines, "\n")

  local prompt = ("In the file %s, please make this change:\n%s\n\nThe full file content is:\n\n```\n%s\n```")
    :format(path, instr, text)

  do_hermes_edit(path, function()
    local stderr = {}
    vim.fn.jobstart(
      { M.config.hermes_cmd, "chat", "-q", prompt, "--quiet", "--yolo" },
      {
      env = { PYTHONUNBUFFERED = "1" },
      stdout_buffered = true,
      stderr_buffered = true,
      on_stderr = function(_, d)
        if d then for _, l in ipairs(d) do table.insert(stderr, l) end end
      end,
      on_exit = function(_, code)
        local ok, err = pcall(function()
          if code == 0 then
            local saved_line = vim.fn.line(".")
            local applied = finish_edit()
            if applied then
              pcall(vim.api.nvim_win_set_cursor, 0, { saved_line, 0 })
              vim.cmd("normal! zz")
            end
          else
            local detail = ""
            if #stderr > 0 then
              detail = ": " .. table.concat(stderr, " | "):gsub("^%s*(.-)%s*$", "%1"):sub(1, 200)
            end
            vim.notify("⚠ Hermes fix failed (" .. code .. ")" .. detail, vim.log.levels.ERROR)
          end
        end)
        if not ok then
          vim.notify("Hermes: internal error: " .. tostring(err), vim.log.levels.ERROR)
        end
      end,
    })
  end)
end

-- ── setup ───────────────────────────────────────────────────

function M.setup(opts)
  M.config = vim.tbl_extend("force", M.config, opts or {})

  vim.api.nvim_create_user_command("HermesChat",  M.open_chat,      {})
  vim.api.nvim_create_user_command("HermesClose",  M.close_chat,     {})
  vim.api.nvim_create_user_command("HermesEdit",   M.edit_selection, { range = true })
  vim.api.nvim_create_user_command("HermesFix",    M.edit_file,      {})

  vim.keymap.set("n", "<leader>hc", "<cmd>HermesChat<CR>",  { noremap = true, silent = true })
  vim.keymap.set("n", "<leader>hq", "<cmd>HermesClose<CR>", { noremap = true, silent = true })
  vim.keymap.set("v", "<leader>he", "<cmd>HermesEdit<CR>",  { noremap = true, silent = true })
  vim.keymap.set("n", "<leader>hf", "<cmd>HermesFix<CR>",   { noremap = true, silent = true })

  vim.notify("Hermes Agent loaded", vim.log.levels.INFO)
end

return M
