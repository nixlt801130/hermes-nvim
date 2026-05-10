-- Hermes Agent Neovim Plugin
-- Simple integration with Hermes Agent CLI

local M = {}

-- Configuration
M.config = {
  chat_window = "right",
  chat_width = 60,
  chat_height = 20,
  hermes_cmd = "hermes",
}

-- Chat buffer state
local chat_buf = nil
local chat_win = nil
local current_job = nil

-- Spinner animation
local spinner_frames = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
local spinner_index = 1
local spinner_timer = nil

-- Start loading spinner
local function start_spinner(buf)
  spinner_index = 1
  if spinner_timer then
    spinner_timer:stop()
  end

  spinner_timer = vim.loop.new_timer()
  spinner_timer:start(100, 100, vim.schedule_wrap(function()
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      if spinner_timer then
        spinner_timer:stop()
        spinner_timer:close()
        spinner_timer = nil
      end
      return
    end

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local last_line = #lines
    if last_line > 0 then
      vim.api.nvim_buf_set_lines(buf, last_line - 1, last_line, false, {
        spinner_frames[spinner_index] .. " Thinking..."
      })
    end
    spinner_index = (spinner_index % #spinner_frames) + 1
  end))
end

-- Stop loading spinner
local function stop_spinner(buf)
  if spinner_timer then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end

  if buf and vim.api.nvim_buf_is_valid(buf) then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local last_line = #lines
    if last_line > 0 and lines[last_line]:match("^.*Thinking%.%.%.$") then
      vim.api.nvim_buf_set_lines(buf, last_line - 1, last_line, false, {
        "✓ Done"
      })
    end
  end
end

-- Open chat window
function M.open_chat()
  -- Close existing window if open
  if chat_win and vim.api.nvim_win_is_valid(chat_win) then
    vim.api.nvim_win_close(chat_win, true)
    chat_win = nil
    chat_buf = nil
  end

  -- Create new buffer (no name to avoid E95)
  chat_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(chat_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(chat_buf, "swapfile", false)
  vim.api.nvim_buf_set_option(chat_buf, "modifiable", true)

  -- Create window
  local width = M.config.chat_width
  local height = M.config.chat_height
  local col = vim.api.nvim_get_option("columns")
  local row = vim.api.nvim_get_option("lines")

  if M.config.chat_window == "right" then
    chat_win = vim.api.nvim_open_win(chat_buf, true, {
      relative = "editor",
      width = width,
      height = height,
      col = col - width,
      row = 0,
      style = "minimal",
      border = "rounded",
    })
  else
    chat_win = vim.api.nvim_open_win(chat_buf, true, {
      relative = "editor",
      width = width,
      height = height,
      col = 0,
      row = row - height,
      style = "minimal",
      border = "rounded",
    })
  end

  -- Set keymaps
  local opts = { noremap = true, silent = true }
  vim.api.nvim_buf_set_keymap(chat_buf, "n", "q", ":lua require('hermes').close_chat()<CR>", opts)
  vim.api.nvim_buf_set_keymap(chat_buf, "n", "<CR>", ":lua require('hermes').send_message()<CR>", opts)

  -- Add header
  local model_info = ""
  local ok, model_output = pcall(vim.fn.system, "hermes config show | grep 'Model:' | head -1 | sed 's/.*default.*: //' | tr -d \"'\"")
  if ok and #model_output > 0 then
    model_info = "Model: " .. vim.fn.trim(model_output)
  end

  vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, {
    "Hermes Agent Chat",
    "==================",
    model_info,
    "",
    "Type your message and press Enter to send",
    "Press 'q' to close",
    "",
  })
end

-- Close chat window
function M.close_chat()
  if current_job then
    vim.fn.jobstop(current_job)
    current_job = nil
  end

  if spinner_timer then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end

  if chat_win and vim.api.nvim_win_is_valid(chat_win) then
    vim.api.nvim_win_close(chat_win, true)
    chat_win = nil
    chat_buf = nil
  end
end

-- Send message to Hermes (async)
function M.send_message()
  if not chat_buf or not vim.api.nvim_buf_is_valid(chat_buf) then
    vim.notify("Chat window not open", vim.log.levels.ERROR)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
  local message = table.concat(lines, "\n")

  if #message == 0 then
    vim.notify("No message to send", vim.log.levels.WARN)
    return
  end

  -- Clear input and add user message
  vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, {
    "Hermes Agent Chat",
    "==================",
    "You: " .. message,
    "Hermes: ",
  })

  -- Start spinner
  start_spinner(chat_buf)

  -- Call Hermes CLI asynchronously
  local cmd = M.config.hermes_cmd .. " chat -q " .. vim.fn.shellescape(message) .. " --quiet"
  local output_lines = {}

  current_job = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          table.insert(output_lines, line)
        end
      end
    end,
    on_exit = function(_, exit_code)
      current_job = nil
      stop_spinner(chat_buf)

      if exit_code ~= 0 then
        vim.notify("Hermes CLI failed (exit " .. exit_code .. ")", vim.log.levels.ERROR)
        return
      end

      local output = table.concat(output_lines, "\n")

  -- Add Hermes response
      local response_lines = vim.split(output, "\n")
      local new_content = {
        "Hermes Agent Chat",
        "==================",
        "You: " .. message,
        "Hermes:",
      }
      for _, line in ipairs(response_lines) do
        table.insert(new_content, line)
      end
      table.insert(new_content, "")
      table.insert(new_content, "────────────────────────────────────────────────────────────")
      table.insert(new_content, "Type your message and press Enter to send")
      table.insert(new_content, "Press 'q' to close")
      table.insert(new_content, "")

      vim.api.nvim_buf_set_lines(chat_buf,0, -1, false, new_content)
    end,
  })

  if current_job <= 0 then
    vim.notify("Failed to start Hermes CLI", vim.log.levels.ERROR)
    stop_spinner(chat_buf)
  end
end

-- Edit selected text with Hermes
function M.edit_selection()
  -- Get selected text
  local start_pos = vim.api.nvim_buf_get_mark(0, "<")
  local end_pos = vim.api.nvim_buf_get_mark(0, ">")

  if start_pos[1] == 0 or end_pos[1] == 0 then
    vim.notify("No text selected", vim.log.levels.WARN)
    return
  end

  local start_line = start_pos[1]
  local end_line = end_pos[1]
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  local selected_text = table.concat(lines, "\n")

  -- Ask for instruction
  local instruction = vim.fn.input("Edit instruction: ")
  if #instruction == 0 then
    vim.notify("No instruction provided", vim.log.levels.WARN)
    return
  end

  -- Get file path
  local file_path = vim.api.nvim_buf_get_name(0)
  if #file_path == 0 then
    vim.notify("Please save the file first", vim.log.levels.WARN)
    return
  end

  -- Show loading notification
  vim.notify("🔄 Editing with Hermes...", vim.log.levels.INFO)

  -- Call Hermes CLI - it will directly modify the file via patch tool
  local cmd = string.format(
    '%s chat -q "Edit this code in file %s: %s\\n\\nSelected code (lines %d-%d):\\n%s" --quiet --yolo',
    M.config.hermes_cmd,
    vim.fn.shellescape(file_path),
    vim.fn.shellescape(instruction),
    start_line,
    end_line,
    vim.fn.shellescape(selected_text)
  )

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_exit = function(_, exit_code)
      if exit_code == 0 then
        -- Reload the file to see changes
        vim.cmd("e!")
        vim.notify("✓ Text edited successfully", vim.log.levels.INFO)
      else
        vim.notify("✗ Editing failed (exit " .. exit_code .. ")", vim.log.levels.ERROR)
      end
    end,
  })
end

-- Setup function
function M.setup(opts)
  M.config = vim.tbl_extend("force", M.config, opts or {})

  -- Create commands
  vim.api.nvim_create_user_command("HermesChat", function()
    M.open_chat()
  end, {})

  vim.api.nvim_create_user_command("HermesClose", function()
    M.close_chat()
  end, {})

  vim.api.nvim_create_user_command("HermesEdit", function()
    M.edit_selection()
  end, { range = true })

  -- Create keymaps
  local opts = { noremap = true, silent = true }
  vim.api.nvim_set_keymap("n", "<leader>hc", ":HermesChat<CR>", opts)
  vim.api.nvim_set_keymap("n", "<leader>hq", ":HermesClose<CR>", opts)
  vim.api.nvim_set_keymap("v", "<leader>he", ":HermesEdit<CR>", opts)

  vim.notify("Hermes Agent plugin loaded", vim.log.levels.INFO)
end

return M
