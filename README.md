# Hermes-nvim

Neovim plugin for Hermes Agent CLI — coding assistant su chat'u ir inline editing.

## Features

- **Chat panel** (`<leader>hc`) — floating window, streaming response
- **Inline edit** (`<leader>he` vizualiai) — pažymėk kodą, nurodai pakeitimą
- **File context awareness** — automatiškai pasiunčia failo pavadinimą ir kursorių su žinute
- **checktime auto-reload** — po kiekvieno atsakymo atnaujina buffer'ius iš disko
- **Spinner animacija** — sukasi kol modelis "galvoja"
- **Klaidų apsauga** — `pcall` apglota, CLI crash'ai nelaužo plugin'o
- **Atskiras profilis** — gali naudoti kitą modelį / provider'į nei terminale

## Installation

### lazy.nvim

```lua
{
  "nixlt801130/hermes-nvim",
  config = function()
    require('hermes').setup({
      chat_window  = "right",  -- 'right' arba 'bottom'
      chat_width   = 60,
      chat_height  = 20,
      hermes_cmd   = "hermes", -- arba "neovim" jei turi atskirą profilį
      send_context = true,     -- siųsti failo pavadinimą / kursorių
    })
  end,
}
```

Jei nori naudoti **atskirą profilį** (pvz. `neovim` su OpenRouter):

```bash
hermes profile create neovim --clone default
hermes profile set model "openrouter/auto" neovim
hermes profile set provider openrouter neovim
hermes profile set compression.enabled false neovim
```

Tada pasidaryk wrapper'į `~/.local/bin/neovim`:

```bash
#!/bin/bash
exec hermes --profile neovim "$@"
```

Ir nustatyk `hermes_cmd = "neovim"` setup'e.

## Commands / Keymaps

| Key          | Veiksmas              |
|-------------|-----------------------|
| `<leader>hc` | Atidaryti chat panelį |
| `<leader>hq` | Uždaryti chat panelį  |
| `<leader>he` | Redaguoti pažymėtą tekstą |
| `q` (chat)   | Uždaryti chat panelį  |

Chat'e: rašai žinutę, spaudi Enter. Atsakymas streamina į tą patį buffer'į.

## How it works

Kiekviena žinutė siunčiama per `hermes chat -q "..." --quiet`. Plugin'as naudoja `jobstart()` su `stdout_buffered = false` kad gautų atsakymą po dalis, o ne viską iš karto.

Jei `send_context = true`, prieš žinutę pridedamas kontekstas:

```
[file: ~/Projektai/main.rs | cursor: line 42]
<tavo žinutė>
```

Po atsakymo paleidžiamas `checktime`, kad jei Hermes pakeitė failą — pakeitimas matytųsi iškart.

## Requirements

- Neovim 0.8+
- Hermes Agent CLI (`~/.local/bin/hermes`)
- `hermes` pasiekiamas PATH

## License

MIT
