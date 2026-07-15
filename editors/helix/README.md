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
formatter = { command = "wax", args = ["format", "-f", "wax"] }
auto-format = true
grammar = "wax"

[[grammar]]
name = "wax"
# Remote checkout with the grammar in a subdirectory:
source = { git = "https://github.com/ocsigen/wax", rev = "main", subpath = "tree-sitter-wax" }
```

## Formatting

The `formatter` line above runs `wax format -f wax`, which reads the buffer on
standard input and writes the formatted result to standard output — Helix's
formatter protocol. Format the current buffer with `:format`, or on every save
via `auto-format = true` (drop that line to format only on demand). `wax` must
be on your `PATH`.

## Build and install the queries

```sh
hx --grammar fetch
hx --grammar build
mkdir -p ~/.config/helix/runtime/queries/wax
cp /path/to/wax/editors/helix/queries/wax/*.scm \
   ~/.config/helix/runtime/queries/wax/
```

## Verify

`hx --health wax` should show the grammar and highlight queries as present.

---

> Config keys (`comment-tokens`, `subpath`, …) track recent Helix releases;
> adjust for older versions.
