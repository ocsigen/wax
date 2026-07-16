# Wax in Neovim

Two pieces: the [`tree-sitter-wax`](../../tree-sitter-wax/) grammar for syntax
highlighting, and the built-in `wax lsp` language server for everything else
(diagnostics, hover, navigation, rename, completion, signature help,
formatting). Neovim compiles the C parser itself (`src/parser.c` +
`src/scanner.c`), so you only need a C compiler for the grammar; the language
server is the `wax` binary on your `PATH`.

The highlight/locals/injection queries ship *with the grammar* (they use
nvim-treesitter's capture conventions), so either highlighting path below is
just installing the parser plus copying those queries onto your runtimepath.

## Highlighting

Two options: **nvim-treesitter** (the plugin, most common) or Neovim's
**built-in** tree-sitter (no plugin, Neovim ≥ 0.9).

### Option A — nvim-treesitter

Register the parser:

```lua
require("nvim-treesitter.parsers").get_parser_configs().wax = {
  install_info = {
    -- A local checkout is recommended so you can easily copy the queries below:
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
cp /path/to/wax/tree-sitter-wax/queries/*.scm ~/.config/nvim/queries/wax/
```

`indents.scm` drives the nvim-treesitter indent module and `textobjects.scm`
the [nvim-treesitter-textobjects](https://github.com/nvim-treesitter/nvim-treesitter-textobjects)
plugin (function/parameter/call/conditional/loop/comment objects); both are
optional and used only if you enable those modules.

### Option B — built-in tree-sitter (no plugin)

Build the parser into a shared library and drop it, with the queries, onto the
runtimepath. From the grammar directory:

```sh
cd /path/to/wax/tree-sitter-wax
npx tree-sitter build -o wax.so          # or: cc -shared -fPIC -Os -Isrc -o wax.so src/parser.c src/scanner.c

mkdir -p ~/.local/share/nvim/site/parser ~/.config/nvim/queries/wax
cp wax.so ~/.local/share/nvim/site/parser/wax.so
cp queries/*.scm ~/.config/nvim/queries/wax/
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

## Language server

`wax lsp` provides diagnostics (as you type), hover, go to definition, go to
type definition, find references, document highlight, rename, completion,
signature help, and formatting. Neovim starts it per `.wax` buffer, so `wax`
only needs to be on your `PATH`.

Neovim ≥ 0.11:

```lua
vim.filetype.add({ extension = { wax = "wax" } }) -- if not already set above
vim.lsp.config("wax", { cmd = { "wax", "lsp" }, filetypes = { "wax" } })
vim.lsp.enable("wax")
```

On Neovim 0.10 or older, start it from a `FileType` autocmd instead:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "wax",
  callback = function(args)
    vim.lsp.start({
      name = "wax",
      cmd = { "wax", "lsp" },
      root_dir = vim.fs.root(args.buf, { ".git", "dune-project" }),
    })
  end,
})
```

(Or register a custom server with [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig).)
Diagnostics then show as signs / virtual text with the warning's `-W` name in
the message, and the standard `vim.lsp.buf.*` mappings (`K`, `grr`, `grn`, …)
drive hover, references, and rename.

## Formatting

The language server formats: `vim.lsp.buf.format()`, or on save via an
`LspAttach` autocmd. `wax`'s formatter reindents to four spaces and preserves
comments; a buffer with a syntax error is left untouched.

Prefer a standalone formatter, without the language server? `wax format -f wax`
reads the buffer on stdin and writes the result to stdout, so point
[conform.nvim](https://github.com/stevearc/conform.nvim) (or `formatexpr`) at
it.

## Verify

Open a `.wax` file, then `:InspectTree` for the parse tree and `:checkhealth
vim.lsp` (or `:LspInfo`) to confirm the `wax` server attached. With
nvim-treesitter, `:checkhealth nvim-treesitter` confirms the parser is
installed.
