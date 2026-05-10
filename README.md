# Hermes-nvim

Neovim plugin for Hermes Agent CLI — coding assistant su chat'u ir inline editing.

## Features

- **Chat panel** (`<leader>hc`) — floating window, streaming response
- **Inline edit** (`<leader>he`, visual selection) — pažymi kodą, nurodai pakeitimą
- **Fix without selection** (`<leader>hf`) — aprašai ką keisti, nereikia žymėti kodo
- **Diff preview** — prieš pritaikant pakeitimus rodomas diff langas su Y/N patvirtinimu
- **File context awareness** — automatiškai pasiunčia failo pavadinimą ir kursorių su žinute
- **checktime auto-reload** — po kiekvieno atsakymo atnaujina buffer'ius iš disko
- **Spinner animacija** — sukasi kol modelis "galvoja"
- **Klaidų apsauga** — `pcall` apglota, CLI crash'ai nelaužo plugin'o
- **Atskiras profilis** — gali naudoti kitą modelį / provider'į nei terminale

## Installation

### lazy.nvim

```lua
{
  dir = "~/Projects/DemoAi/test",
  opts = {
    chat_window   = 'right',    -- 'right' arba 'bottom'
    chat_width    = 60,
    chat_height   = 20,
    hermes_cmd    = 'hermes',   -- arba 'neovim' jei turi atskirą profilį
    send_context  = true,       -- siųsti failo pavadinimą / kursorių
    confirm_edits = true,       -- rodyti diff langą prieš pritaikant pakeitimus
  },
}
```

Arba jei nori naudoti GitHub versiją:

```lua
{
  "nixlt801130/hermes-nvim",
  opts = {
    hermes_cmd = "neovim",
  },
}
```

### Atskiras profilis

Jei nori naudoti skirtingą modelį / provider'į (pvz. NVIDIA):

```bash
hermes profile create neovim --clone default
hermes profile set model.default stepfun-ai/step-3.5-flash --profile neovim
hermes profile set model.provider nvidia --profile neovim
```

Tada wrapper'is `~/.local/bin/neovim`:

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
| `<leader>he` | Redaguoti pažymėtą tekstą (visual mode) |
| `<leader>hf` | Keisti failą be selection (normal mode) |
| `q` (chat)   | Uždaryti chat panelį  |

Chat'e: rašai žinutę, spaudi Enter. Atsakymas streamina į tą patį buffer'į.

## Diff Preview

Kai naudoji `<leader>hf` arba `<leader>he`, prieš pritaikant pakeitimus atsidaro floating langas su diff. Lange matosi:

- Kas keičiama (žalia = pridėta, raudona = ištrinta)
- Apatinėje dalyje: `y` = accept, `n` / `q` = reject

Jei atmeti, originalus failo turinys atstatomas automatiškai.

Išjungti: `confirm_edits = false`.

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
