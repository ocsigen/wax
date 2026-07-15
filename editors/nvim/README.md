# Wax in Neovim

Uses the [`tree-sitter-wax`](../../tree-sitter-wax/) grammar. Neovim compiles the
C parser itself (`src/parser.c` + `src/scanner.c`), so you only need a C
compiler — no prebuilt artifact.

The highlight/locals/injection queries ship *with the grammar* (they use
nvim-treesitter's capture conventions), so either path below is just installing
the parser plus copying those queries onto your runtimepath.

Two options: **nvim-treesitter** (the plugin, most common) or Neovim's
**built-in** tree-sitter (no plugin, Neovim ≥ 0.9).

## Option A — nvim-treesitter

Register the parser:

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

Then run `:TSInstall wax`. Install the queries onto the runtimepath:

```sh
mkdir -p ~/.config/nvim/queries/wax
cp /path/to/wax/tree-sitter-wax/queries/{highlights,locals,injections}.scm \
   ~/.config/nvim/queries/wax/
```

## Option B — built-in tree-sitter (no plugin)

Build the parser into a shared library and drop it, with the queries, onto the
runtimepath. From the grammar directory:

```sh
cd /path/to/wax/tree-sitter-wax
npx tree-sitter build -o wax.so          # or: cc -shared -fPIC -Os -Isrc -o wax.so src/parser.c src/scanner.c

mkdir -p ~/.local/share/nvim/site/parser ~/.config/nvim/queries/wax
cp wax.so ~/.local/share/nvim/site/parser/wax.so
cp queries/{highlights,locals,injections}.scm ~/.config/nvim/queries/wax/
```

Then associate the filetype and start highlighting on `.wax` buffers:

```lua
vim.filetype.add({ extension = { wax = "wax" } })
vim.api.nvim_create_autocmd("FileType", {
  pattern = "wax",
  callback = function() vim.treesitter.start() end,
})
```

(The filetype `wax` maps to the parser named `wax` by default; no
`vim.treesitter.language.register` call is needed.)

## Verify

Open a `.wax` file, then `:InspectTree` for the parse tree. With
nvim-treesitter, `:checkhealth nvim-treesitter` confirms the parser is
installed.
