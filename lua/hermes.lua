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

-- Loading state
local loading_timer = nil
local loading_spinner = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
local loading_index = 1
local loading_line = 0

-- Start loading animation
function M.start_loading()
  if loading_timer then
    return
  end

  loading_index = 1
  loading_line = #vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)

  loading_timer = vim.loop.new_timer()
  loading_timer:start(100, 100, vim.schedule_wrap(function()
    if not chat_buf or not vim.api.nvim_buf_is_valid(chat_buf) then
      M.stop_loading()
      return
    end

    local spinner = loading_spinner[loading_index]
    loading_index = loading_index % #loading_spinner + 1

    vim.api.nvim_buf_set_lines(chat_buf, loading_line, loading_line + 1, false, {
      spinner .. " Thinking...",
    })
  end))
end

-- Stop loading animation
function M.stop_loading()
  if loading_timer then
    loading_timer:stop()
    loading_timer:close()
    loading_timer = nil
  end

  if chat_buf and vim.api.nvim_buf_is_valid(chat_buf) then
    local lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
    if loading_line < #lines then
      vim.api.nvim_buf_set_lines(chat_buf, loading_line, loading_line + 1, false, {
        "✓ Done",
      })
    end
  end
end

-- Open chat window
function M.open_chat()
  -- Close existing chat window if open
  if chat_win and vim.api.nvim_win_is_valid(chat_win) then
    vim.api.nvim_win_close(chat_win, true)
  end

  -- Create new buffer
  chat_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(chat_buf, "Hermes Chat")
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
  vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, {
    "Hermes Agent Chat",
    "==================",
    "Type your message and press Enter to send",
    "Press 'q' to close",
    "",
  })
end

-- Close chat window
function M.close_chat()
  M.stop_loading()

  if chat_win and vim.api.nvim_win_is_valid(chat_win) then
    vim.api.nvim_win_close(chat_win, true)
    chat_win = nil
    chat_buf = nil
  end
end

-- Send message to Hermes
function M.send_message()
  if not chat_buf then
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

  -- Start loading animation
  M.start_loading()

  -- Call Hermes CLI
  local cmd = M.config.hermes_cmd .. " -z " .. vim.fn.shellescape(message)
  local output = vim.fn.system(cmd)

  -- Stop loading animation
  M.stop_loading()

  -- Add Hermes response
  local new_lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
  local last_line = #new_lines
  vim.api.nvim_buf_set_lines(chat_buf, last_line, last_line, false, {
    "",
    "Hermes: " .. output,
    "",
    "────────────────────────────────────────────────────────────",
    "Type your message and press Enter to send",
    "Press 'q' to close",
    "",
  })
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

  -- Show loading notification
  vim.notify("🔄 Editing with Hermes...", vim.log.levels.INFO)

  -- Call Hermes CLI with context
  local cmd = string.format(
    '%s -z "Edit this code: %s\\n\\nCode:\\n%s"',
    M.config.hermes_cmd,
    vim.fn.shellescape(instruction),
    vim.fn.shellescape(selected_text)
  )

  local output = vim.fn.system(cmd)

  -- Replace selected text with result
  vim.api.nvim_buf_set_lines(0, start_line - 1, end_line, false, vim.split(output, "\n"))

  vim.notify("✓ Text edited successfully", vim.log.levels.INFO)
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
