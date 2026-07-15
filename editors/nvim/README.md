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
cp /path/to/wax/tree-sitter-wax/queries/{highlights,locals,injections,indents,textobjects}.scm \
   ~/.config/nvim/queries/wax/
```

`indents.scm` drives the nvim-treesitter indent module and `textobjects.scm`
the [nvim-treesitter-textobjects](https://github.com/nvim-treesitter/nvim-treesitter-textobjects)
plugin (function/parameter/call/conditional/loop/comment objects); both are
optional and used only if you enable those modules.

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

## Formatting

`wax format` reformats a buffer through standard input (`wax format -f wax`,
reading stdin and writing stdout), so it plugs into Neovim's `formatexpr`. Wire
`gq` to it and, optionally, format on save:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "wax",
  callback = function(args)
    vim.bo[args.buf].formatexpr = "v:lua.require'wax_format'()"
  end,
})
```

with a small module `lua/wax_format.lua` on your `runtimepath`:

```lua
-- Format the current buffer (or the `gq` range) with `wax format`.
return function()
  -- Let Neovim handle the interactive `gq`/`gw` case (e.g. comments).
  if vim.v.char ~= "" then return 1 end
  local buf = vim.api.nvim_get_current_buf()
  local input = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local result = vim.system(
    { "wax", "format", "-f", "wax" }, { stdin = input, text = true }):wait()
  if result.code ~= 0 then
    vim.notify(vim.trim(result.stderr), vim.log.levels.ERROR, { title = "wax format" })
    return 0
  end
  local formatted = vim.split(vim.trim(result.stdout), "\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, formatted)
  return 0
end
```

Then `gggqG` (or `gq` over a selection) formats. On a parse error `wax format`
exits non-zero and the buffer is left untouched, with the diagnostic shown via
`vim.notify`. To format on save, call the same module from `BufWritePre`:

```lua
vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = "*.wax",
  callback = function() require("wax_format")() end,
})
```

> Prefer a formatter plugin? Point [conform.nvim](https://github.com/stevearc/conform.nvim)
> or null-ls at the same command (`wax format -f wax`, stdin) and it works the
> same way.

## Diagnostics (errors & warnings)

`wax check --error-format=short` prints one `file:line:col: severity: message`
line per diagnostic, which maps straight onto `vim.diagnostic`. A small module
`lua/wax_diagnostics.lua`:

```lua
local ns = vim.api.nvim_create_namespace("wax")
local severity = {
  error = vim.diagnostic.severity.ERROR,
  warning = vim.diagnostic.severity.WARN,
}
return function(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then return end
  vim.system({ "wax", "check", "--error-format=short", file }, { text = true },
    function(res)
      local diags = {}
      for line in (res.stderr or ""):gmatch("[^\n]+") do
        local l, c, s, msg = line:match("^.-:(%d+):(%d+): (%a+): (.+)$")
        if l then
          table.insert(diags, {
            lnum = tonumber(l) - 1, col = tonumber(c) - 1,
            severity = severity[s] or vim.diagnostic.severity.ERROR,
            message = msg, source = "wax",
          })
        end
      end
      vim.schedule(function() vim.diagnostic.set(ns, buf, diags) end)
    end)
end
```

Run it when a `.wax` buffer is read and after each save:

```lua
vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
  pattern = "*.wax",
  callback = function(args) require("wax_diagnostics")(args.buf) end,
})
```

Errors and warnings then show as signs/virtual text, and the warning's `-W`
name rides along in the message (`… [unused-local]`).

> Prefer a linter plugin? [nvim-lint](https://github.com/mfussenegger/nvim-lint)
> can run the same command; parse its output with `require('lint.parser').from_pattern`
> (or an `errorformat`) using `%f:%l:%c: %t%*[^:]: %m`.

## Verify

Open a `.wax` file, then `:InspectTree` for the parse tree. With
nvim-treesitter, `:checkhealth nvim-treesitter` confirms the parser is
installed.
