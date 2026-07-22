# CLI Reference

The `wax` binary is the primary interface for the Wax toolchain. It supports conversion between Wax, WebAssembly Text (WAT), and WebAssembly Binary (Wasm) formats.

## Usage

```sh
wax [OPTIONS] [INPUT]         # convert (the default command)
wax convert [OPTIONS] [INPUT] # the same, named explicitly
wax format [OPTIONS] FILE…    # reformat files
wax check [OPTIONS] FILE…     # validate files
wax lsp                       # run the language server (over stdin/stdout)
```

By default `wax` converts between formats; this command is also available under
its explicit name, `wax convert` (useful when an input filename could be
mistaken for a subcommand). The `format` subcommand reformats files (see
[Formatting](#formatting)), `check` validates them (see [Checking](#checking)),
and `lsp` starts a Language Server Protocol server for editors (see [Language
server](#language-server)).

## Positional Arguments

- `[INPUT]`: Source file to convert/format. Supported extensions: `.wax`, `.wat`, `.wasm`.
    - If omitted, `wax` reads from `stdin`.

## Options

- **`-o`**, **`--output`** *FILE*
    - Output file. Writes to `stdout` if not specified.

- **`-f`**, **`--format`**, **`--output-format`** *FORMAT*
    - Specify the output format.
    - Values: `wax`, `wat`, `wasm`.
    - Default: `wax` (if not auto-detected from output filename).

- **`-i`**, **`--input-format`** *FORMAT*
    - Specify the input format.
    - Values: `wax`, `wat`, `wasm`.
    - Default: Auto-detected from input filename, or `wax` if reading from stdin.

- **`-v`**, **`--validate`**
    - Force validation, and additionally report unused locals.
    - For Wax: Runs type checking.
    - For Wasm Text: Runs well-formedness checks.
    - A text input (Wax/WAT) is **validated by default before it is converted to a different format**: the conversion and lowering passes trust that their input is well-formed, so a malformed module is rejected up front rather than reaching them. A same-format conversion (`wat` → `wat`, `wax` → `wax`) only re-prints and is *not* validated by default; a Wasm *binary* input is trusted and *not* validated. `--validate` forces validation in every case.
    - Reports a warning for any local that is declared but never read: a Wax `let` binding, or a Wasm Text `(local …)`. This reporting is only enabled by `--validate` (the default validation above does not turn it on). Prefix the name with `_` (e.g. `let _x = …`, `(local $_x i32)`) to mark it intentionally unused and silence the warning; function parameters are never reported. This `unused-local` warning can be silenced, kept, or promoted to an error with [`-W`](#options) (e.g. `-W unused-local=error`).
    - For input containing conditional annotations (`#[if]` / `(@if ...)`), every reachable combination of conditions is checked independently, and each error is reported with the assumption (`reachable when ...`) under which it occurs.

- **`-s`**, **`--strict-validate`**
    - Perform strict reference validation for Wasm Text input (overrides the default relaxed validation). Wasm *binary* input is always validated strictly, regardless of this flag. When compiling Wax or Wasm Text to a binary, functions referenced by `ref.func` only inside a function body are automatically declared (via a declarative element segment), so the output passes strict validation.

- **`-D`** *NAME[=VALUE]*, **`--define`** *NAME[=VALUE]*
    - Set a conditional-compilation variable, specializing `#[if(...)]` (Wax) and
      `(@if ...)` (WAT) annotations. A fully determined conditional is removed
      (its surviving branch is spliced in) and a partially determined one is kept
      with its condition simplified (the set variables substituted, the rest
      left). Comments inside a removed branch are dropped.
    - The value kind is inferred: a bare *NAME* (or `NAME=true` / `NAME=false`)
      sets a boolean; `NAME=N.N.N` (three integers) sets a version; any other
      `NAME=VALUE` sets a string.
    - Repeatable, to set several variables. Has no effect on Wasm binary input
      (which carries no conditionals).

- **`-X`** *NAME[=on|off]*, **`--feature`** *NAME[=on|off]*
    - Enable (or disable) an optional WebAssembly proposal, off by default.
      Bare *NAME* or `NAME=on`/`true`/`yes` enables it; `NAME=off`/`false`/`no`
      disables it. Repeatable. Known features:
        - `custom-descriptors`: exact reference types (`&!t`), `descriptor`/`describes`
          struct clauses, and the descriptor instructions. Without it these
          constructs are rejected during validation.
        - `compact-import-section`: write same-module imports under one module
          name in the binary import section. What the flag enables depends on the
          input, because the text form is authoritative for import layout. From a
          text input (Wax or WAT), a `import "m" { … }` block / `(import "m"
          (item …) …)` group is lowered to a compact entry — a name-only group
          sharing one type when the items' types all match, else one type per
          item; a Wax block of one item flattens to a plain import, and imports
          the source left *separate* are never merged. From a WASM binary — which
          has no authorial text layout — the flag instead coalesces runs of
          consecutive same-module plain imports (the "compress this binary"
          mode). Groups written explicitly, or already present in a binary, are
          preserved through WAT↔WAT and WASM↔WASM round-trips on their own, no
          flag needed.
    - A module can also declare the features it uses itself, with a
      `#![feature = "NAME"]` inner attribute (WAT: a module-level
      `(@feature "NAME")` annotation); see
      [Features](./language.md#features). The declared and enabled sets are
      unioned. The one exception is a conflict: an explicit `-X NAME=off`
      against a module that declares *NAME* is an error, reported at the
      attribute, since the file states a fact and the flag states a policy and
      neither silently wins.
    - A binary persists the declarations as `+NAME` entries of the
      conventional `target_features` custom section, one entry per declared
      feature; other producers' entries there are preserved verbatim and not
      interpreted. Decompiling a binary restores the attributes from the
      union of those entries and the gated encodings the module actually
      uses.

- <a id="warnings"></a>**`-W`** *NAME=LEVEL*, **`--warn`** *NAME=LEVEL*
    - Set the reporting level of a warning produced during validation.
    - *NAME* is a single warning, a group, or `all`:
        - `unused-local` (group `unused`): a local that is declared but never
          read. Produced while validating; shown by default. Carries a
          quick-fix `edit` that inserts a `_` at the name's start.
        - `unused-field` (groups `unused`, `correctness`): a module field (a
          function or global) that is defined but never referenced, exported, or
          used as the start function. The module-level analog of `unused-local`;
          prefix its name with `_` to silence one. Shown by default.
        - `unused-import` (groups `unused`, `correctness`): an imported function
          or global that is never referenced, exported, or used as the start
          function. Like `unused-field`, but for imports; `_` silences one. Shown
          by default.
        - `unused-label` (groups `unused`, `correctness`): a block label that
          is declared but never branched to. Prefix its name with `_` to silence
          one. Shown by default. On the Wax side it carries a quick-fix `edit`
          that deletes the whole `'name:` prefix.
        - `shift-count-overflow` (group `correctness`): a shift by a constant
          count at least the operand's bit width. Wasm masks the count modulo
          the width, so the shift is almost certainly not what was meant. Shown
          by default.
        - `constant-trap` (group `correctness`): an operation that always traps
          on a constant operand: an integer division or remainder by zero, or a
          trapping float-to-integer conversion of an out-of-range constant.
          Shown by default.
        - `tautological-comparison` (group `correctness`): a comparison whose
          result is constant regardless of its variable operand: an unsigned
          comparison against zero (`x >=u 0`, `x <u 0`), or two identical
          operands (`x == x`). Shown by default.
        - `constant-condition` (group `correctness`): a branch, loop, or
          `select` condition that is a constant literal (the idiomatic infinite
          loop `while <nonzero>` is not flagged). Shown by default.
        - `unused-result` (group `correctness`): the result of a
          side-effect-free expression is computed and then discarded, as in
          `_ = x + 1`. Covers reads, constants, pure arithmetic, and heap
          allocations (a discarded struct/array literal) whose operands are
          themselves effect-free. Shown by default.
        - `dead-code` (group `correctness`): a statement that can never be
          reached, following an unconditional branch, `return`, or
          `unreachable`. Shown by default.
        - `cast-always-fails` (group `correctness`): a reference cast or test
          whose operand can never have the target type (the two are unrelated in
          the type hierarchy), so the cast always traps and the test is always
          false. Shown by default.
        - `eager-select` (group `correctness`): a trapping or effectful
          operation in a branch of a `?:` (which compiles to a `select`,
          evaluating both branches unconditionally), so it runs even when the
          condition selects the other branch. Shown by default. On Wasm input
          the check covers a folded `select` (its value operands are distinct
          subtrees); an unfolded `select` is not flagged.
        - `precedence` (group `correctness`): two operators whose relative
          precedence is easy to misremember are mixed without parentheses: a
          shift (`<<`/`>>`) with arithmetic (`+`, `-`, …), or a comparison with
          a bitwise operator (`&`, `|`, `^`). The code is correct, but a reader
          may misread the grouping (`1 << nbits - 1` is `1 << (nbits - 1)`).
          Shown by default. Wax-only: WAT/Wasm have no infix precedence. Carries
          a quick-fix `edit` that wraps the tighter-binding sub-expression in
          parentheses.
        - `redundant-operation` (group `redundant`): an operation with no effect
          on its result: an arithmetic identity (`x + 0`, `x * 1`, `x << 0`, …),
          an absorbing operand (`x * 0`, `x & 0`), two identical operands
          (`x - x`, `x ^ x`), a self-assignment (`x = x`), or a cast to a type
          the operand already has. **Hidden by default** (these are common in
          generated code); enable with `-W redundant=warning`.
        - `truncated-coverage`: path-sensitive validation gave up after too
          many conditional configurations. Shown by default.
        - `confusable-unicode` (group `correctness`): a string the module
          carries — an export/import name, a string literal, a data segment, or
          a conditional string — contains a "Trojan Source" bidirectional
          control character (U+202A/B/D/E, U+2066–2069, U+206C) that can make the
          displayed source read differently than it runs. Shown by default,
          reported on Wax, WAT and Wasm input alike.
        - `naming-conflict` (group `naming`): converting from Wasm, a source
          name collided with another and was renamed (e.g. `foo` → `foo_2`).
          Hidden by default.
        - `reserved-word-rename` (group `naming`): converting from Wasm, a
          source name is a Wax reserved word and was renamed (e.g. `if` →
          `if_2`). Hidden by default.
        - `generated-name` (group `naming`): converting from Wasm, an unnamed
          but referenced parameter was given a generated name (e.g. `x`), since
          it cannot be rendered anonymously. Hidden by default.
        - `compound-assignment` (group `suggestion`): a plain assignment
          `x = x op e` can be written with the compound operator `x op= e`
          (arithmetic and bitwise operators only; `x` must be the operator's
          *first* operand, so `x = e - x` is left alone). Hidden by default.
        - `field-punning` (group `suggestion`): a struct field initialised from
          the like-named local or global, `{x: x}`, can use the punning
          shorthand `{x}`. Hidden by default.
        - `redundant-annotation` (group `suggestion`): a type the inferred type
          already makes redundant and so can be dropped: a `let` annotation
          (`let x: t = e` → `let x = e`, including the anonymous `_: t = e` and
          each binding of a tuple `let (a: t, b) = e`), a module-level global
          annotation (`let counter: i32 = 0` → `let counter = 0`, likewise for a
          `const`), a construction type name (`{T| …}` → `{…}`), a block result
          type (`do t { … }` → `do { … }`), or an `if` result type
          (`if c => t { … }` → `if c { … }`). Hidden by default.
    - The `suggestion` group is reported at a distinct **Suggestion** severity
      (not a warning), and each entry carries a machine-applicable rewrite. These
      are optional simplifications, so they are hidden by default and surface as
      on-demand quick fixes in the VS Code extension; `wax check` prints them
      when enabled with `-W suggestion=warning` (or an individual name). A
      redundant *cast* removal is offered too, but as a fix attached to the
      existing `redundant-operation` warning rather than a separate suggestion.
    - *LEVEL* is one of:
        - `hidden`: suppress the warning entirely.
        - `warning`: report it as a warning.
        - `error`: promote it to an error, so the run fails.
    - Repeatable; later settings override earlier ones. For example,
      `-W all=error -W unused-local=warning` makes every warning fatal except
      unused locals.
    - The validation warnings (`truncated-coverage`, and the `unused` and
      `correctness` lints) are produced only while validating.
      `truncated-coverage` can arise from the validation `convert` runs on a
      text input; the `unused`/`correctness` lints are turned on only by
      `--validate`, and always for `check`. The `naming` warnings are produced
      when converting a Wasm module to Wax.
    - Almost all of these lints apply to WebAssembly text/binary input as well
      as Wax: the Wasm validator runs the same checks, so `wax check foo.wat`
      reports them. (The exceptions are `precedence`, which is Wax-only since
      WAT/Wasm have no infix precedence, and `eager-select`, whose Wasm side
      covers only a folded `select`.) On Wasm input `unused-result` covers discarding a constant or
      a pure `local.get`/`global.get` read; for `unused-label` a numeric `br N`
      counts as a use of the label `N` levels out; `cast-always-fails` and
      `redundant-operation` reason about `ref.cast`/`ref.test` and constant
      operands directly from the bytecode. As with `unused-local`, they fire only
      when unused reporting is on (under `check`, or under a conversion with
      `--validate`).
    - The `WAX_WARN` environment variable sets default levels applied *before*
      the `-W` options. Its value is a list of `NAME=LEVEL` specs separated by
      commas or whitespace, e.g. `WAX_WARN="correctness=hidden
      unused-local=error"`. Unlike a plain environment fallback, these defaults
      still apply when `-W` is given: the command line only refines them (so
      `WAX_WARN=correctness=hidden` with `-W dead-code=warning` hides the tier
      except dead code). A malformed or unknown entry is reported on stderr and
      skipped.

- **`--color`** *WHEN*
    - Colorize output.
    - Values: `always`, `never`, `auto`.
    - Default: `auto` (colors enabled only if output is a TTY).

- **`--error-format`** *FORMAT*
    - How diagnostics are rendered.
    - Values: `human` (source snippets, the default), `json`, or `short`.
    - With `human`, a named warning's `-W` name is appended to the header as
      `[name]` (e.g. `Warning [unused-local]:`), so at a glance you can tell
      which warning fired and which `-W` name silences or promotes it.
    - With `json`, every diagnostic — errors, warnings, and syntax errors — is
      written to stderr as one JSON object per line (JSON Lines), for an editor,
      CI job, or AI assistant to parse. Each object has `severity`, `file`,
      `startLine`/`startColumn`/`endLine`/`endColumn` (1-based line, 0-based
      column), `startOffset`/`endOffset` (byte offsets), `message`, `warning`
      (the [`-W`](#options) name, or null), `hint`, and `related`. A diagnostic
      carrying a machine-applicable fix (a `suggestion`, a fixable warning like a
      redundant cast, an unused local, an unused label, or a confusing precedence
      mix, or a syntax error whose recovery insertion derives one — e.g. a
      missing `;`, under [`--all-errors`](#check)) also has an `edit` object: the
      same span fields for the slice to replace (an empty span, for an
      insertion), plus its `newText`. Syntax errors report their `hint` and
      `related` here too.
    - With `short`, each diagnostic is one
      `file:line:col: severity: message` line (gcc/rustc style, 1-based column),
      for an editor with a line-based error parser (Vim's `errorformat`, Emacs
      Flymake, …). A named warning's `-W` name is appended as `[name]`.
    - Exit codes are unchanged. Also accepted by `check` and `format`.


- **`--fold`**
    - Fold instructions into nested S-expressions.
    - Affects WAT output (the default form is chosen automatically).

- **`--unfold`**
    - Unfold instructions into flat instruction lists.
    - Affects WAT output (the default form is chosen automatically).

- **`--desugar`**
    - Expand the Wax-specific `(@string …)` and `(@char …)` annotations into
      core WebAssembly (`array.new_fixed` / `i32.const`), so the output is plain
      WebAssembly text that other tools accept. An `i8` string keeps its raw
      UTF-8 bytes; an `i16` string is UTF-16-encoded; an untyped string reuses an
      existing `(array (mut i8))` type when the module has one and otherwise pins
      a synthesised one. A module-level `(@string …)` global becomes an ordinary
      global.
    - Synthesises the declarative element segment (`(elem declare func …)`) that
      Wax's lenient reader lets a module omit for a function used by `ref.func`
      only inside a body, so the output passes strict/spec reference validation.
      This heals a conditional module: WAT emitted from a `#[if]` module keeps
      its `(@if …)` and omits the segment, but once the conditionals are resolved
      with `-D` and desugared the segment is added. It is a no-op when the
      segment is already present (as on the wax-to-wat and binary-to-wat paths).
    - Only valid with wat output (`-f wat`); requesting it for wasm or wax
      output is a usage error.
    - Fails (exit `128`) if a conditional-compilation directive `(@if …)`
      remains unresolved; resolve them first with `-D`/`--define`.
    - A `(@feature "…")` declaration is stripped: no annotation remains in the
      output. Feature resolution has already run by then, so the declaration
      still gates during processing; re-ingesting the desugared text needs
      `-X` again, exactly as desugared strings do not come back as literals.
      A module *using* gated constructs is not an error — those are real
      (proposal) WebAssembly, and removing annotations is orthogonal to
      whether the consumer supports the proposal.

- **`--source-map`**
    - Generate a source map file alongside the output file and insert a `sourceMappingURL` custom section. Only valid with wasm output (`-f wasm`) to a file, when the source is a text file (not a Wasm binary).
      Requesting one for wat or wax output, when the source is a Wasm binary, or when outputting to `stdout`, is an error.

- **`--debug`** *CATEGORY*
    - Enable developer debug output for a category. Repeatable, and a single
      value may list several categories separated by commas
      (`--debug timing,…`).
    - Categories:
        - `timing`: log the wall-clock running time of each compiler pass
          (parse, specialize, validate, type-check, convert, output) to stderr,
          one line per pass as it finishes. The normal output on stdout is
          unchanged.

- **`--version`**
    - Print the toolchain version and exit. In a released build this is the git
      tag it was built from; a plain development build reports `dev`.

- **`--help`**
    - Show the manual page and exit. Also available per subcommand
      (`wax format --help`, etc.).

## Examples

**Convert a Wax file to Wasm binary:**
```sh
wax input.wax -o output.wasm
```

**Convert a Wasm Text file to Wax (decompilation):**
```sh
wax input.wat -o output.wax
```

**Format a Wax file (round-trip):**
```sh
wax input.wax
```

**Read from stdin and write to stdout:**
```sh
cat input.wax | wax -f wasm > output.wasm
```

**Specialize conditional compilation while converting:**
```sh
wax input.wax -D debug=false -D ocaml_version=5.1.0 -D target=wasi -o output.wasm
```

## Formatting

The `format` subcommand reformats files in their own format (`.wat` → `.wat`,
`.wax` → `.wax`, `.wasm` → `.wasm`), detected from each file's extension.
Formatting never validates: it only re-prints; use [`check`](#checking) to
validate.

With no `FILE`, `format` reads standard input and writes the formatted result to
standard output. The format cannot be detected without a filename, so `--format`
is required in this mode (and `--inplace` / `--check`, which act on named files,
are not allowed). This is the interface an editor formatter or a shell pipe
uses:

```sh
echo 'fn f(x:i32)->i32{x*x;}' | wax format -f wax
```

```sh
wax format [OPTIONS] FILE…
```

### Options

- **`-i`**, **`--inplace`**
    - Write the formatted output back to each input file.
    - Without this flag (and without `--check`), exactly one file must be given
      and its formatted output is written to `stdout` — or no file, to format
      `stdin` to `stdout` (see above).
- **`-c`**, **`--check`**
    - Write nothing; list the files that are not already formatted and exit with
      a non-zero status if any are found. Useful in CI. Cannot be combined with
      `--inplace`.
- **`-f`**, **`--format`**, **`--input-format`** *FORMAT*
    - Treat all input files as this format (`wat`, `wasm` or `wax`), overriding
      the detection from each file's extension.
- **`-W`** *NAME=LEVEL*, **`--warn`** *NAME=LEVEL*: set a warning's level, as
  above.
- **`--color`** *WHEN*: as above (ignored when writing back in place).
- **`--error-format`** *FORMAT*: `human`, `json`, or `short`, as above (a
  malformed file still reports its syntax error).
- **`--fold`** / **`--unfold`**: as above.
- **`--debug`** *CATEGORY*: as above.

### Examples

**Format a single file to stdout:**
```sh
wax format input.wat
```

**Reformat several files in place:**
```sh
wax format -i a.wax b.wax c.wax
```

**Check formatting in CI (non-zero exit if any file differs):**
```sh
wax format --check src/*.wax
```

## Checking

The `check` subcommand validates files (type-checking for Wax, well-formedness
for Wasm) without producing any output, reporting diagnostics and exiting with a
non-zero status if any file fails. It takes one or more files. Unused-local
warnings (see [`--validate`](#options)) are reported too, but do not by
themselves cause a non-zero exit, unless promoted to an error with
[`-W`](#options) (e.g. `wax check -W unused-local=error src/*.wax`).

```sh
wax check [OPTIONS] FILE…
```

### Options

- **`-f`**, **`--format`**, **`--input-format`** *FORMAT*: force the format of
  all files, overriding extension detection.
- **`-s`**, **`--strict-validate`**: strict reference validation for Wasm Text,
  as above (Wasm binary is always strict).
- **`-D`** *NAME[=VALUE]*, **`--define`** *NAME[=VALUE]*: set a
  conditional-compilation variable, as for [`convert`](#options): the
  conditionals are specialized before validation. A full set validates one
  configuration; a partial set leaves the remaining conditionals for the
  path-sensitive check to explore. Repeatable.
- **`-X`** *NAME[=on|off]*, **`--feature`** *NAME[=on|off]*: enable or disable
  an optional proposal, as for [`convert`](#options). Repeatable.
- **`-W`** *NAME=LEVEL*, **`--warn`** *NAME=LEVEL*: set a warning's level, as
  above.
- **`--all-errors`**: report *every* syntax error instead of stopping at the
  first. Normally the parser gives up at the first unexpected token; with this
  flag it uses panic-mode error recovery and continues, so a single run lists
  all the syntax errors. Wax resynchronizes at statement and block boundaries
  (`;`, `}`, `)`, `]`, and the keywords that begin a new item or statement); WAT,
  being fully parenthesized, resynchronizes on the parentheses (dropping an
  incomplete group, auto-closing an unclosed one). The recovered module is then
  checked too — type-checked for Wax, validated for WAT — so genuine type or
  validation errors in the intact regions surface alongside the syntax errors,
  while the cascades a dropped construct would otherwise trigger (an unbound name
  in Wax; a warning or wrong stack height in WAT) are suppressed. Text input
  only, Wax and Wat (ignored for a Wasm binary).
- **`--color`** *WHEN*: as above.
- **`--error-format`** *FORMAT*: `human`, `json`, or `short`, as above.
- **`--debug`** *CATEGORY*: as above.

### Example

**Type-check several Wax files (e.g. in CI):**
```sh
wax check src/*.wax
```

**Report all syntax errors in a Wax file at once:**
```sh
wax check --all-errors src/foo.wax
```

## Language server

The `lsp` subcommand starts a [Language Server
Protocol](https://microsoft.github.io/language-server-protocol/) server for Wax
and WebAssembly text, speaking JSON-RPC over stdin/stdout. It runs the same
analysis the VS Code extension runs in-process, exposed to any LSP-capable
editor (Neovim, Emacs with Eglot or lsp-mode, Helix, Kakoune, Zed, and others).

```sh
wax lsp
```

It reads no files of its own; the editor tells it which documents are open.
Supported requests: diagnostics (pushed on open/change), hover,
go-to-definition, go-to-type-definition, find-references, document highlight,
rename (with prepare), document symbols (outline), completion, signature help,
inlay hints, folding ranges, selection ranges, semantic tokens, and document
formatting. The hover, navigation and completion features that need the typed
tree are Wax-only, while formatting, diagnostics and the outline work for `.wat`
too (dispatched by the document's URI extension).

A lint diagnostic carries the extra metadata editors use: the `-W` name as its
code (linked to this reference), and `DiagnosticTag.Unnecessary` on the
removable/unreachable lints (unused bindings, dead code) so the editor fades
them.

The one setting is `wax.define`, a list of conditional-compilation defines
(mirroring the [`-D`](#options) flag, e.g. `["debug=true", "arch=wasm64"]`).
Diagnostics and completion specialize to it, so a definition or an error in a
branch the defines rule out is dropped. The server reads it from the client's
`initializationOptions` at startup and from `workspace/didChangeConfiguration`
live (under a `wax` section), re-checking the open documents when it changes.

Documents are synchronized in full (each change carries the whole buffer). The
position encoding is negotiated: the server uses UTF-8 when the client offers it
and otherwise UTF-16, the LSP default that every client supports. The `--stdio`
flag is accepted (and ignored) for the editors that pass it by convention.

### Editor setup

Most editors just need the launch command `wax lsp` bound to the `wax` (and, if
desired, `wat`) file type through their LSP client. Ready-to-use configurations
for Neovim, Helix, and Emacs — paired with the `tree-sitter-wax` grammar for
highlighting — live under [`editors/`](https://github.com/ocsigen/wax/tree/main/editors)
in the repository (one directory per editor, each with a README).

## Exit status

All three commands share the same exit codes:

| Code | Meaning |
|------|---------|
| `0`  | Success. For `check` / `format --check`, also means every file passed. |
| `123` | A **usage** error: an invalid combination of flags (e.g. `--source-map` with text output or binary input, or binary output to a terminal), or a `format --check` run that found files needing formatting. |
| `124` | A command-line parse error: an unknown flag or a bad option value (reported by the argument parser). |
| `125` | An internal error (an uncaught exception). |
| `128` | The input was **rejected by a diagnostic**: a parse, validation, or type error, or a malformed wasm binary. This is also the status of a `check` run that found any problem. |

The distinction is *how you used the tool* (`123`/`124`) versus *the input is
bad* (`128`). A rejected input reports `128` wherever the error is found
(syntax, validation, or type-checking) so `check` exits `0` when every input is
valid and `128` otherwise, which is what a CI gate wants. For scripting, treat
any non-zero status as failure.

## Shell completion

`wax` supports `zsh`, `bash`, and PowerShell completion: subcommands, flag
names, flag values (`--format` → `wat`/`wasm`/`wax`, `-W`/`-X` names and values,
`--color`, `--debug`), and input/output file paths.

Completion has two halves. The generic per-shell scripts ship with the
[`cmdliner`](https://opam.ocaml.org/packages/cmdliner/) package; the `wax`
package installs its own completion definitions (and man pages) alongside the
binary. Installing `wax` through opam puts both in place. (These extra files are
installed on Unix only; they are skipped on native Windows.)

Then hook the generic scripts into your shell once. For `zsh`, ensure the
site-functions directory is on `$fpath` **before** `compinit`:

```sh
FPATH="$(opam var share)/zsh/site-functions:$FPATH"
autoload -Uz compinit && compinit
```

For `bash`, with [`bash-completion`](https://github.com/scop/bash-completion)
installed, point it at the cmdliner share directory. See the
[cmdliner completion guide](https://erratique.ch/software/cmdliner/doc/cli.html#cli_completion)
for the per-shell details and the PowerShell setup.
