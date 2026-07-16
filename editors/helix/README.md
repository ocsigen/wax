# Wax in Helix

Uses the [`tree-sitter-wax`](../../tree-sitter-wax/) grammar. Helix builds the C
parser itself, so you only need a C compiler.

The highlight query here is written for Helix's capture-name vocabulary (e.g.
`@constant.numeric`, `@constant.character`, `@variable.other.member`). The
`locals` and `injections` queries are the same as the grammar's.

## Configure the language and grammar

Add to `~/.config/helix/languages.toml` (see [`languages.toml`](languages.toml)
for a ready-to-paste copy):

```toml
[[language]]
name = "wax"
scope = "source.wax"
file-types = ["wax"]
comment-tokens = ["//"]
block-comment-tokens = { start = "/*", end = "*/" }
indent = { tab-width = 4, unit = "    " }
language-servers = ["wax"]
auto-format = true
grammar = "wax"

[language-server.wax]
command = "wax"
args = ["lsp"]

[[grammar]]
name = "wax"
# We recommend a local checkout so you can easily copy the queries below:
# (A remote works too: source = { git = "https://github.com/ocsigen/wax", rev = "main", subpath = "tree-sitter-wax" })
source = { path = "/path/to/wax/tree-sitter-wax" }
```

## Language server

`wax lsp` is the built-in language server; Helix starts it (the same way it runs
a formatter) whenever a `.wax` buffer opens, so `wax` only needs to be on your
`PATH`. It provides diagnostics, hover, go to definition, go to type definition,
find references, rename, completion, signature help, and formatting. The
tree-sitter grammar above still drives syntax highlighting; the server layers
the language intelligence on top.

## Formatting

With `auto-format = true` Helix formats through the language server on save;
`:format` formats on demand. `wax`'s formatter reindents to four spaces and
preserves comments; a buffer with a syntax error is left untouched.

Prefer a standalone formatter (no language server)? Drop `language-servers` and
set `formatter = { command = "wax", args = ["format", "-f", "wax"] }` instead —
`wax format` reads the buffer on stdin and writes the result to stdout, Helix's
formatter protocol.

## Diagnostics

Errors, warnings, and lints show inline, served by the language server above.
(On the command line, `wax check --error-format=short file.wax` prints the same
diagnostics as `file:line:col: severity: message`.)

## Build and install the queries

```sh
hx --grammar fetch
hx --grammar build
mkdir -p ~/.config/helix/runtime/queries/wax
cp /path/to/wax/editors/helix/queries/wax/*.scm \
   ~/.config/helix/runtime/queries/wax/
```

This copies `highlights`, `locals`, and `injections`, plus `indents` (auto-indent)
and `textobjects` (function/parameter/comment selections, e.g. `mif` / `maf`).

## Verify

`hx --health wax` should show the grammar and highlight queries as present, and
the `wax` language server configured.

---

> Config keys (`comment-tokens`, `subpath`, …) track recent Helix releases;
> adjust for older versions.
