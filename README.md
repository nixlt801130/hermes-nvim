# Hermes Agent Neovim Plugin

Simple Neovim integration for Hermes Agent CLI.

## Features

- **Chat Panel**: Interactive chat with Hermes Agent
- **Code Editing**: Edit selected text with AI instructions
- **Simple Commands**: Easy-to-use commands and keymaps

## Installation

### Using lazy.nvim

```lua
{
  "nixlt801130/hermes-nvim",
  config = function()
    require('hermes').setup({
      chat_window = 'right',  -- 'right' or 'bottom'
      chat_width = 60,
      chat_height = 20,
      hermes_cmd = 'hermes',   -- Hermes CLI command
    })
  end,
}
```

### Using packer.nvim

```lua
use {
  'nixlt801130/hermes-nvim',
  config = function()
    require('hermes').setup({
      chat_window = 'right',
      chat_width = 60,
      chat_height = 20,
      hermes_cmd = 'hermes',
    })
  end
}
```

## Usage

### Chat Panel

Open chat panel:
```vim
:HermesChat
```
Or press: `<leader>hc`

Close chat panel:
```vim
:HermesClose
```
Or press: `<leader>hq`

In the chat window:
- Type your message and press `Enter` to send
- Press `q` to close

### Code Editing

1. Select text in visual mode
2. Run:
```vim
:HermesEdit
```
Or press: `<leader>he`
3. Enter your edit instruction
4. The selected text will be replaced with the edited version

### Example Usage

**Chat:**
```
You: How do I create a function in Rust?
Hermes: [AI response]
```

**Code Editing:**
1. Select this code:
```rust
fn main() {
    println!("Hello");
}
```

2. Run `:HermesEdit`
3. Enter instruction: "Add error handling"
4. Result:
```rust
fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("Hello");
    Ok(())
}
```

## Configuration

```lua
require('hermes').setup({
  chat_window = 'right',  -- 'right' or 'bottom'
  chat_width = 60,        -- Width of chat window
  chat_height = 20,       -- Height of chat window
  hermes_cmd = 'hermes',  -- Hermes CLI command
})
```

## Keymaps

- `<leader>hc` - Open chat panel
- `<leader>hq` - Close chat panel
- `<leader>he` - Edit selected text

## Requirements

- Hermes Agent CLI installed and available in PATH
- Neovim 0.5+

## Next Steps

Future improvements:
- [ ] Inline suggestions (code completion)
- [ ] Better chat history
- [ ] File context awareness
- [ ] Multi-file editing
- [ ] Code actions (refactor, explain, fix)
- [ ] Floating window for quick questions

## License

MIT
