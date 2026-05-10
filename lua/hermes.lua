-- hermes.lua — Hermes Agent Neovim Plugin
-- Async chat + code editing via Hermes CLI

local M = {}

M.config = {
  chat_window = "right",   -- "right" or "bottom"
  chat_width  = 60,
  chat_height = 20,
  hermes_cmd  = "hermes",
}

-- ── internal state ──────────────────────────────────────────

local state = { buf = nil, win = nil, job = nil, timer = nil, header_lines = 0 }

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- ── spinner ─────────────────────────────────────────────────

local function spinner_start(buf)
  local idx = 1
  if state.timer then pcall(vim.uv.close, state.timer) end
  state.timer = vim.uv.new_timer()
  state.timer:start(100, 100, vim.schedule_wrap(function()
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.uv.close, state.timer)
      state.timer = nil
      return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local n = #lines
    if n > 0 and lines[n]:match("^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] Thinking") then
      vim.api.nvim_buf_set_lines(buf, n - 1, n, false, { SPINNER[idx] .. " Thinking..." })
    end
    idx = (idx % #SPINNER) + 1
  end))
end

local function spinner_stop(buf)
  if state.timer then
    pcall(vim.uv.close, state.timer)
    state.timer = nil
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local n = #lines
    if n > 0 and lines[n]:match("^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] Thinking%.%.%.$") then
      vim.api.nvim_buf_set_lines(buf, n - 1, n, false, { "✓ Done" })
    end
  end
end

-- ── helpers ─────────────────────────────────────────────────

local function append(buf, lines)
  local n = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, n, n, false, lines)
end

local function get_model()
  local ok, out = pcall(vim.fn.system, "hermes config show 2>/dev/null")
  if not ok or out == "" then return "?" end
  -- extract model from "Model: ..." line in the output
  for line in out:gmatch("[^\n]+") do
    local m = line:match("default.*: '([^']+)'")
    if m then return m end
    m = line:match("default.*: ([%w/._-]+)")
    if m then return m end
  end
  return "?"
end

local function scroll_bottom(win)
  local n = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  pcall(vim.api.nvim_win_set_cursor, win, { n, 0 })
end

-- ── chat window ─────────────────────────────────────────────

function M.open_chat()
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
  -- track header size so send_message knows where input starts
  state.header_lines = 7

  -- start in insert mode on the last (empty input) line
  vim.api.nvim_win_set_cursor(state.win, { state.header_lines, 0 })
  vim.cmd("startinsert!")
end

function M.close_chat()
  if state.job then vim.fn.jobstop(state.job); state.job = nil end
  if state.timer then pcall(vim.uv.close, state.timer); state.timer = nil end
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

  local cmd = M.config.hermes_cmd .. " chat -q " .. vim.fn.shellescape(msg) .. " --quiet"
  local stdout, stderr = {}, {}

  state.job = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, d) if d then for _, l in ipairs(d) do table.insert(stdout, l) end end end,
    on_stderr = function(_, d) if d then for _, l in ipairs(d) do table.insert(stderr, l) end end end,
    on_exit = function(_, code)
      state.job = nil
      spinner_stop(buf)
      if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

      if code ~= 0 then
        vim.notify("Hermes CLI exit " .. code, vim.log.levels.ERROR)
        append(buf, { "⚠ Hermes CLI failed (exit " .. code .. ")", "" })
        scroll_bottom(state.win)
        return
      end

      -- remove the "⠋ Thinking..." / "✓ Done" line
      local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      for i = #cur, 1, -1 do
        if cur[i]:match("^[✓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]") then
          table.remove(cur, i)
          break
        end
      end

      table.insert(cur, "Hermes:")
      for _, l in ipairs(stdout) do
        if l ~= "" then table.insert(cur, "  " .. l) end
      end
      table.insert(cur, "")

      vim.api.nvim_buf_set_lines(buf, 0, -1, false, cur)
      scroll_bottom(state.win)

      -- add a fresh blank input line and go back to insert
      local n = vim.api.nvim_buf_line_count(buf)
      vim.api.nvim_buf_set_lines(buf, n, n, false, { "" })
      vim.api.nvim_win_set_cursor(state.win, { n + 1, 0 })
      vim.cmd("startinsert!")

      -- if Hermes modified any files on disk, pick up the changes
      pcall(vim.cmd, "checktime")
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

  vim.fn.jobstart(M.config.hermes_cmd .. " chat -q " .. vim.fn.shellescape(prompt)
    .. " --quiet --yolo", {
    stdout_buffered = true,
    on_exit = function(_, code)
      if code == 0 then
        -- remember approximate cursor line so we don't jump to top
        local saved_line = vim.fn.line(".")
        vim.cmd("edit!")
        pcall(vim.api.nvim_win_set_cursor, 0, { saved_line, 0 })
        vim.cmd("normal! zz")
        vim.notify("✓ Hermes: done", vim.log.levels.INFO)
      else
        vim.notify("⚠ Hermes edit failed (" .. code .. ")", vim.log.levels.ERROR)
      end
    end,
  })
end

-- ── setup ───────────────────────────────────────────────────

function M.setup(opts)
  M.config = vim.tbl_extend("force", M.config, opts or {})

  vim.api.nvim_create_user_command("HermesChat",  M.open_chat,      {})
  vim.api.nvim_create_user_command("HermesClose",  M.close_chat,     {})
  vim.api.nvim_create_user_command("HermesEdit",   M.edit_selection, { range = true })

  vim.keymap.set("n", "<leader>hc", "<cmd>HermesChat<CR>",  { noremap = true, silent = true })
  vim.keymap.set("n", "<leader>hq", "<cmd>HermesClose<CR>", { noremap = true, silent = true })
  vim.keymap.set("v", "<leader>he", "<cmd>HermesEdit<CR>",  { noremap = true, silent = true })

  vim.notify("Hermes Agent loaded", vim.log.levels.INFO)
end

return M
