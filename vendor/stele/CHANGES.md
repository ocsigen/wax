# Changes

## 0.1.0

First release as a standalone project. stele was previously developed inside
the [Wax](https://github.com/ocsigen/wax) toolchain, which uses it for the error
messages of both its grammars.

- `stele generate` writes a message for every error state of a Menhir grammar,
  from `menhir --list-errors` and the grammar's `.cmly`: the list of what could
  come next, a hint pointing at the unclosed delimiter, and an "Assuming that
  ... is complete" message where the grammar uses `%on_error_reduce`. Each
  list is checked against the parser's tables.
- A per-grammar config file improves the wording (readable names and token
  classes), and an overrides file holds hand-written messages. Stale entries in
  either fail the build.
- `stats`, `census`, `names`, `fallbacks`, `suggest-classes` and `transitions`
  help review and improve the messages; `stats` and `census` are meant to be
  pinned as golden files.
- `stele tune` suggests changes to the grammar's `%on_error_reduce`
  annotations, trying each one on a scratch copy of the grammar.
- The `stele.runtime` library turns the location markers in a message into
  source spans at parse time. It depends only on `menhirLib`, so it also works
  under `js_of_ocaml` and `wasm_of_ocaml`.
- A tutorial and a runnable example (`example/`).
