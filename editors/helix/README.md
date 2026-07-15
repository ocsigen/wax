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
grammar = "wax"

[[grammar]]
name = "wax"
# Remote checkout with the grammar in a subdirectory:
source = { git = "https://github.com/ocsigen/wax", rev = "main", subpath = "tree-sitter-wax" }
```

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
