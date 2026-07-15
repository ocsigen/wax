# Wax in Neovim (nvim-treesitter)

Uses the [`tree-sitter-wax`](../../tree-sitter-wax/) grammar. Neovim compiles the
C parser itself (`src/parser.c` + `src/scanner.c`), so you only need a C
compiler — no prebuilt artifact.

The highlight/locals/injection queries ship *with the grammar* (they use
nvim-treesitter's capture conventions), so this integration is just parser
registration plus copying those queries onto your runtimepath.

## Register the parser

```lua
require("nvim-treesitter.parsers").get_parser_configs().wax = {
  install_info = {
    -- A local checkout works; use `url = "https://github.com/ocsigen/wax"` for a remote.
    url = "/path/to/wax",
    location = "tree-sitter-wax", -- the grammar lives in this subdirectory
    files = { "src/parser.c", "src/scanner.c" },
    branch = "main",
  },
  filetype = "wax",
}

vim.filetype.add({ extension = { wax = "wax" } })
```

Then run `:TSInstall wax`.

## Install the queries

nvim-treesitter looks up queries under `queries/wax/` on the runtimepath. Copy
the grammar's queries there:

```sh
mkdir -p ~/.config/nvim/queries/wax
cp /path/to/wax/tree-sitter-wax/queries/{highlights,locals,injections}.scm \
   ~/.config/nvim/queries/wax/
```

## Verify

Open a `.wax` file, then `:InspectTree` to see the parse tree and
`:checkhealth nvim-treesitter` to confirm the parser is installed.
