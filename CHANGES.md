# Changelog

This is the changelog for the `wax` / `wax-lib` opam packages. `dune-release`
reads the top entry's version and notes when cutting an opam release (see
[`RELEASING.md`](RELEASING.md)). The VS Code extension keeps its own changelog,
[`editors/vscode/CHANGELOG.md`](editors/vscode/CHANGELOG.md); the tree-sitter
grammar keeps none, and both are versioned independently of the toolchain.

## Unreleased

### Language

- The final `;` of a block is now optional. Writing it still does not discard
  the statement's value, and the formatter keeps emitting the canonical
  trailing `;`.
- New parenthesized type ascription `(e : t)`. It asserts a type instead of
  converting to it: the operand's type must already be a subtype of `t`, the
  expression compiles to nothing, and an ascription that does not hold is a
  compile-time error. Use it to pin a literal's width, or to widen a reference
  without a runtime cast.
- The [compilation-hints
  proposal](https://github.com/WebAssembly/compilation-hints) is supported and
  preserved through every conversion, with no feature flag: `#[freq = n]`,
  `#[never_opt]`, `#[always_opt]` and `#[targets(f: 0.73, …)]` prefixing an
  expression, and `#[priority = n]`, `#[optimization = n]` and `#[run_once]` on
  a function.
- A hole `_` is now rejected, with an explanation, as a `match` scrutinee, a
  `dispatch` index or a `while` condition. Those positions desugar to a nested
  block, where a hole draws from the block's own stack and could never pick up
  the intended value.
- `custom-descriptors` follows two upstream rule changes: a type and its
  descriptor must agree on finality, and the "L" subtyping rule is gone. Exact
  allocation types are now gated on the feature as well.
- `compact-import-section` treats the text form as authoritative for import
  layout. A Wax `import "m" { … }` block (or a WAT `(import "m" (item …) …)`
  group) lowers to a compact entry, a one-item block flattens to a plain
  import, and imports written separately are never merged. A binary input,
  which has no authorial layout, still gets its runs of same-module imports
  coalesced. The shared-type text form cannot bind identifiers, so a group
  whose items carry names takes the one-type-per-item form and the binary
  encoder restores the shared-type encoding.
- A module name annotation is rejected inside a `#[if]` / `(@if)` conditional,
  since the name applies in every configuration.
- A branch-hint annotation is accepted on a folded operand in WAT.

### Command line

- New `--faithful`: decompile without the stream-reshaping recoveries, so a WAT
  or Wasm module converted to Wax recompiles with the same reachable
  instruction structure. Wax output only. The new
  [Round-Tripping](https://ocsigen.org/wax/correspondence/round_trip.html)
  page states the contract and the few inert divergences that remain.
- `--desugar` now synthesizes the declarative element segment that Wax's
  lenient reader lets a module omit, so the output passes strict spec
  validation, including after resolving conditionals with `-D`. The
  `metadata.code.*` hint annotations are real WebAssembly text and are kept.
- `--error-format human` appends the warning's `-W` name to the header
  (`Warning [unused-local]:`). With `json`, a diagnostic carrying a
  machine-applicable fix gained an `edit` object, and syntax errors now emit
  `hint`, `related` and `edit` like every other diagnostic.
- `--source-map` is rejected as a usage error when the input is a Wasm binary,
  which carries no source to map.
- New developer `--debug` categories `width-check` and `width-record`, self
  checks on the decompiler's numeric-width recording.

### Warnings

- `unused-field` and `unused-import` now ask reachability from the module's
  roots rather than the mere presence of a reference, so a dead cycle of
  mutually recursive functions or types is reported. They span every named
  index space: functions, globals, memories, tables, tags, types, and passive
  data and element segments.
- New `unnecessary-mut` (shown by default): a module-defined, non-exported
  global declared mutable that no assignment ever targets, so it could be a
  `const`.
- New `confusable-unicode` (shown by default): a "Trojan Source" bidirectional
  control character in a string the module carries (an export or import name, a
  string literal, a data segment), which can make the source read differently
  than it runs.
- New `suggestion` group, hidden by default and reported at a distinct
  Suggestion severity, each entry carrying a machine-applicable rewrite:
  `compound-assignment` (`x = x + e` to `x += e`), `field-punning` (`{x: x}` to
  `{x}`) and `redundant-annotation` (a type the inference already pins).
- `dead-code` also reports a `#[if]` / `(@if)` branch that no configuration can
  select.
- Quick-fix edits are attached to `unused-local`, `unused-label`, `precedence`
  and redundant casts, so editors can offer them.
- `cast-always-fails` reports only the innermost cast of a chain, where the fix
  belongs.
- Fewer false positives: float arithmetic identities, `x - x` on floats,
  `any`/`extern` conversions, a leading sign on a constant operand, and SIMD
  vector methods now classified as effect-free. Constant expressions are linted
  too, not just function bodies.

### Diagnostics

- Parser error messages are regenerated by `stele`, a message generator
  vendored with the repository, and are golden-tested. They name the construct
  under repair, underline the right token, and fall back to hand-written
  wording for the states heuristics cannot serve.
- Syntax errors carry a structured payload, and a parse that recovery repairs
  by inserting a token (a missing `;` or operand) offers that insertion as a
  fix.
- Better locations throughout: `br_table` targets, block parameters and
  results, a missing block argument, the arms of an `if` and of a structured
  `try`, the intrinsic name in an arity error, a non-function callee at the
  call site, a missing `;` at the end of the previous lexeme.
- A duplicate binding, export or dispatch arm now reports where the previous
  one was.
- Error cascades are cut: a failed cast, a failed arithmetic operand, a local
  whose declared type is unresolved, and a chained or nested type error each
  report once instead of at every level.

### Editors

- Machine-applicable suggestions are served as `textDocument/codeAction` quick
  fixes over LSP, mirroring the VS Code code-action provider.
- Contextual type completion: value and heap types in Wax, and types in WAT
  buffers.

### Fixes

- Silent miscompilations in both directions of the Wax/Wasm conversion, most of
  them numeric-width drift: a decompiled expression could recompile at a
  different width than the original opcode stated. The decompiler now records
  the type each source opcode states and the type checker pins any value that
  would otherwise come back at the wrong width.
- A shadowing `let`'s initializer is kept in the outer scope.
- A call through a struct's function-pointer field is no longer rejected when
  the field's name is also a built-in method's (`copy`, `length`, `switch`, a
  SIMD lane operation). The type checker chose the intrinsic by name and
  argument count, while the lowering had always chosen by the receiver's type.
  Field names come from the name section, so a decompiled module could carry
  one and produce Wax that did not compile back.
- Conditional modules: entities referenced only inside an `(@if)` body are
  converted, imports are hoisted, and every configuration is checked as a whole
  rather than through a separate specializer.
- A memory's minimum is derived from its custom page size.
- A bare `(type N)` blocktype naming an implicit type resolves.
- Generated labels no longer clash with `dispatch` and `match` arm labels.
- Crash on `become` of a binary intrinsic method, plus several crashes and a
  hang in typer error recovery.
- Writing a large Wasm binary no longer overflows the stack, and lowering
  nested calls no longer blows up exponentially.
- Inputs that were wrongly accepted are now rejected: a `br_on_cast` flags byte
  outside `0..3`, overlong tag bytes, degenerate import groups, a non-finite or
  over-long hint payload, a `br` value that violates the block's result type,
  and a table with a non-nullable element type written with an inline element
  list, whose active segment fills the table at instantiation but leaves the
  table itself without a default. An out-of-f32-range float literal takes type
  `f64`.
- A decompiled block (`do`, `if`, `loop`, `try`) whose value is left on the
  stack for a later statement keeps its result type. Two annotations that were
  each redundant on their own — the block's result, and the cast pinning the
  same type — were both dropped, and the Wax that came out no longer compiled.
- Decompiled dead code no longer gains a `ref.cast`, or a stray
  `extern.convert_any`, on the way back. The decompiler pins the type of an
  operand it cannot see, and those pins were landing on a neighbouring value
  instead of on the hole they were meant for, where they turned into real
  instructions. Affected a `ref.cast` into the extern hierarchy, both
  `extern`/`any` conversions, a `call_ref` callee, a field or element access
  receiver, `array.len` and `i31.get_s`.
- Output fixes: an empty blocktype uses the `0x40` shorthand, funcidx element
  segments encode `(ref func)` rather than `funcref`, an empty name-section
  entry names nothing, and data strings are split at word boundaries.
- Formatting fixes: an empty block body beside a following clause, `rec` groups
  and catch arms always broken across lines, `(do &t { x; }[0] = 1)`, and more
  faithful preservation of comments and of annotations the tokenizer does not
  interpret.

### Performance

- The pretty-printer streams straight to the output channel instead of building
  a document tree, and an in-house `Printer` replaces `Format` throughout.
- An O(n²) in the binary-to-text path is gone, trivia tables are keyed on byte
  offsets, and several hot traversals are allocation-free.

### Library

- `wax-lib` depends on `cmdliner`.
- `Driver.to_binary` reports a failed lowering (a conditional that survived
  specialization, an unresolved reference) as a located diagnostic instead of
  letting an exception escape to the embedder.
- The embedding API can turn the unused-declaration warnings off.
- `Parsing` and `Parser_error_runtime` moved to `lib-utils`, `Naming` to
  `lib-conversion`.

### Documentation

- A browser [playground](https://ocsigen.org/wax/playground.html): write
  Wax, see the WAT and the diagnostics live, with no install.
- A `wax` agent skill under `skills/wax/`, for coding assistants that read the
  `SKILL.md` format (`npx skills add ocsigen/wax`).
- `opam install wax` is documented now that both packages are in
  opam-repository.

## 0.1.0

- Initial release of the Wax toolchain: bidirectional conversion between Wax,
  WebAssembly text (WAT), and WebAssembly binary, with formatting, type
  checking, a language server, and the supporting libraries (`wax-lib`).
