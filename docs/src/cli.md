# CLI Reference

The `wax` binary is the primary interface for the Wax toolchain. It supports conversion between Wax, WebAssembly Text (WAT), and WebAssembly Binary (Wasm) formats.

## Usage

```sh
wax [OPTIONS] [INPUT]         # convert (the default command)
wax convert [OPTIONS] [INPUT] # the same, named explicitly
wax format [OPTIONS] FILE…    # reformat files
wax check [OPTIONS] FILE…     # validate files
```

By default `wax` converts between formats; this command is also available under
its explicit name, `wax convert` (useful when an input filename could be
mistaken for a subcommand). The `format` subcommand reformats files (see
[Formatting](#formatting)) and `check` validates them (see
[Checking](#checking)).

## Positional Arguments

- `[INPUT]`: Source file to convert/format. Supported extensions: `.wax`, `.wat`, `.wasm`.
    - If omitted, `wax` reads from `stdin`.

## Options

- **`-o`**, **`--output`** *FILE*
    - Output file. Writes to `stdout` if not specified.

- **`-f`**, **`--format`**, **`--output-format`** *FORMAT*
    - Specify the output format.
    - Values: `wax`, `wat`, `wasm`.
    - Default: `wasm` (if not auto-detected from output filename).

- **`-i`**, **`--input-format`** *FORMAT*
    - Specify the input format.
    - Values: `wax`, `wat`, `wasm`.
    - Default: Auto-detected from input filename, or `wax` if reading from stdin.

- **`-v`**, **`--validate`**
    - Force validation, and additionally report unused locals.
    - For Wax: Runs type checking.
    - For Wasm Text: Runs well-formedness checks.
    - A text input (Wax/Wat) is **validated by default before it is converted to a different format** — the conversion and lowering passes trust that their input is well-formed, so a malformed module is rejected up front rather than reaching them. A same-format conversion (`wat` → `wat`, `wax` → `wax`) only re-prints and is *not* validated by default; a Wasm *binary* input is trusted and *not* validated. `--validate` forces validation in every case.
    - Reports a warning for any local that is declared but never read — a Wax `let` binding, or a Wasm Text `(local …)`. This reporting is only enabled by `--validate` (the default validation above does not turn it on). Prefix the name with `_` (e.g. `let _x = …`, `(local $_x i32)`) to mark it intentionally unused and silence the warning; function parameters are never reported. This `unused-local` warning can be silenced, kept, or promoted to an error with [`-W`](#options) (e.g. `-W unused-local=error`).
    - For input containing conditional annotations (`#[if]` / `(@if ...)`), every reachable combination of conditions is checked independently, and each error is reported with the assumption (`reachable when ...`) under which it occurs.

- **`-s`**, **`--strict-validate`**
    - Perform strict reference validation for Wasm Text input (overrides the default relaxed validation). Wasm *binary* input is always validated strictly, regardless of this flag. When compiling Wax or Wasm Text to a binary, functions referenced by `ref.func` only inside a function body are automatically declared (via a declarative element segment), so the output passes strict validation.

- **`-D`** *NAME[=VALUE]*, **`--define`** *NAME[=VALUE]*
    - Set a conditional-compilation variable, specializing `#[if(...)]` (Wax) and
      `(@if ...)` (WAT) annotations. A fully determined conditional is removed —
      its surviving branch is spliced in — and a partially determined one is kept
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
        - `custom-descriptors` — exact reference types (`&!t`), `descriptor`/`describes`
          struct clauses, and the descriptor instructions. Without it these
          constructs are rejected during validation.
        - `compact-import-section` — group a module's consecutive same-module
          imports under one module name in the binary import section. Gated on
          *output* only: it is emitted just when enabled, but the compact form is
          always accepted on input.

- **`-W`** *NAME=LEVEL*, **`--warn`** *NAME=LEVEL*
    - Set the reporting level of a warning produced during validation.
    - *NAME* is a single warning, a group, or `all`:
        - `unused-local` (group `unused`) — a local that is declared but never
          read. Produced while validating; shown by default.
        - `unused-field` (groups `unused`, `correctness`) — a module field (a
          function or global) that is defined but never referenced, exported, or
          used as the start function. The module-level analog of `unused-local`;
          prefix its name with `_` to silence one. Shown by default.
        - `unused-label` (groups `unused`, `correctness`) — a block label that
          is declared but never branched to. Prefix its name with `_` to silence
          one. Shown by default.
        - `shift-count-overflow` (group `correctness`) — a shift by a constant
          count at least the operand's bit width. Wasm masks the count modulo
          the width, so the shift is almost certainly not what was meant. Shown
          by default.
        - `constant-trap` (group `correctness`) — an operation that always traps
          on a constant operand: an integer division or remainder by zero, or a
          trapping float-to-integer conversion of an out-of-range constant.
          Shown by default.
        - `tautological-comparison` (group `correctness`) — a comparison whose
          result is constant regardless of its variable operand: an unsigned
          comparison against zero (`x >=u 0`, `x <u 0`), or two identical
          operands (`x == x`). Shown by default.
        - `constant-condition` (group `correctness`) — a branch, loop, or
          `select` condition that is a constant literal (the idiomatic infinite
          loop `while <nonzero>` is not flagged). Shown by default.
        - `unused-result` (group `correctness`) — the result of a
          side-effect-free expression is computed and then discarded, as in
          `_ = x + 1`. Shown by default.
        - `dead-code` (group `correctness`) — a statement that can never be
          reached, following an unconditional branch, `return`, or
          `unreachable`. Shown by default.
        - `truncated-coverage` — path-sensitive validation gave up after too
          many conditional configurations. Shown by default.
        - `naming-conflict` (group `naming`) — converting from Wasm, a source
          name collided with another and was renamed (e.g. `foo` → `foo_2`).
          Hidden by default.
        - `reserved-word-rename` (group `naming`) — converting from Wasm, a
          source name is a Wax reserved word and was renamed (e.g. `if` →
          `if_2`). Hidden by default.
        - `generated-name` (group `naming`) — converting from Wasm, an unnamed
          but referenced parameter was given a generated name (e.g. `x`), since
          it cannot be rendered anonymously. Hidden by default.
    - *LEVEL* is one of:
        - `hidden` — suppress the warning entirely.
        - `warning` — report it as a warning.
        - `error` — promote it to an error, so the run fails.
    - Repeatable; later settings override earlier ones. For example,
      `-W all=error -W unused-local=warning` makes every warning fatal except
      unused locals.
    - The validation warnings — `truncated-coverage`, and the `unused` and
      `correctness` lints — are produced only while validating.
      `truncated-coverage` can arise from the validation `convert` runs on a
      text input; the `unused`/`correctness` lints are turned on only by
      `--validate`, and always for `check`. The `naming` warnings are produced
      when converting a Wasm module to Wax.
    - The `correctness` lints apply to WebAssembly text/binary input as well as
      Wax: `shift-count-overflow`, `constant-trap`, `tautological-comparison`,
      `constant-condition`, `unused-result` and `dead-code` are checked by the
      Wasm validator too (so `wax check foo.wat` reports them). On Wasm input
      `unused-result` covers discarding a constant or a pure `local.get`/
      `global.get` read. `unused-field` and `unused-label` are also checked on
      WebAssembly input — a numeric `br N` counts as a use of the label `N`
      levels out — but, like `unused-local`, only when unused reporting is on
      (under `check`, or under a conversion with `--validate`).
    - The `WAX_WARN` environment variable sets default levels applied *before*
      the `-W` options. Its value is a list of `NAME=LEVEL` specs separated by
      commas or whitespace, e.g. `WAX_WARN="correctness=hidden
      unused-local=error"`. Unlike a plain environment fallback, these defaults
      still apply when `-W` is given — the command line only refines them (so
      `WAX_WARN=correctness=hidden` with `-W dead-code=warning` hides the tier
      except dead code). A malformed or unknown entry is reported on stderr and
      skipped.

- **`--color`** *WHEN*
    - Colorize output.
    - Values: `always`, `never`, `auto`.
    - Default: `auto` (colors enabled only if output is a TTY).


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
    - Only valid with wat output (`-f wat`); requesting it for wasm or wax
      output is a usage error.
    - Fails (exit `128`) if a conditional-compilation directive `(@if …)`
      remains unresolved; resolve them first with `-D`/`--define`.

- **`--source-map-file`** *FILE*
    - Generate a source map file. Only valid with wasm output (`-f wasm`);
      requesting one for wat or wax output is an error.

- **`--debug`** *CATEGORY*
    - Enable developer debug output for a category. Repeatable, and a single
      value may list several categories separated by commas
      (`--debug timing,…`).
    - Categories:
        - `timing` — log the wall-clock running time of each compiler pass
          (parse, specialize, validate, type-check, convert, output) to stderr,
          one line per pass as it finishes. The normal output on stdout is
          unchanged.

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
wax input.wax -f wax
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
Formatting never validates — it only re-prints; use [`check`](#checking) to
validate.

```sh
wax format [OPTIONS] FILE…
```

### Options

- **`-i`**, **`--inplace`**
    - Write the formatted output back to each input file.
    - Without this flag (and without `--check`), exactly one file must be given
      and its formatted output is written to `stdout`.
- **`-c`**, **`--check`**
    - Write nothing; list the files that are not already formatted and exit with
      a non-zero status if any are found. Useful in CI. Cannot be combined with
      `--inplace`.
- **`-f`**, **`--format`**, **`--input-format`** *FORMAT*
    - Treat all input files as this format (`wat`, `wasm` or `wax`), overriding
      the detection from each file's extension.
- **`-W`** *NAME=LEVEL*, **`--warn`** *NAME=LEVEL* — set a warning's level, as
  above.
- **`--color`** *WHEN* — as above (ignored when writing back in place).
- **`--fold`** / **`--unfold`** — as above.
- **`--debug`** *CATEGORY* — as above.

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
themselves cause a non-zero exit — unless promoted to an error with
[`-W`](#options) (e.g. `wax check -W unused-local=error src/*.wax`).

```sh
wax check [OPTIONS] FILE…
```

### Options

- **`-f`**, **`--format`**, **`--input-format`** *FORMAT* — force the format of
  all files, overriding extension detection.
- **`-s`**, **`--strict-validate`** — strict reference validation for Wasm Text,
  as above (Wasm binary is always strict).
- **`-D`** *NAME[=VALUE]*, **`--define`** *NAME[=VALUE]* — set a
  conditional-compilation variable, as for [`convert`](#options): the
  conditionals are specialized before validation. A full set validates one
  configuration; a partial set leaves the remaining conditionals for the
  path-sensitive check to explore. Repeatable.
- **`-X`** *NAME[=on|off]*, **`--feature`** *NAME[=on|off]* — enable or disable
  an optional proposal, as for [`convert`](#options). Repeatable.
- **`-W`** *NAME=LEVEL*, **`--warn`** *NAME=LEVEL* — set a warning's level, as
  above.
- **`--color`** *WHEN* — as above.
- **`--debug`** *CATEGORY* — as above.

### Example

**Type-check several Wax files (e.g. in CI):**
```sh
wax check src/*.wax
```

## Exit status

All three commands share the same exit codes:

| Code | Meaning |
|------|---------|
| `0`  | Success. For `check` / `format --check`, also means every file passed. |
| `123` | A **usage** error — an invalid combination of flags (e.g. `--source-map-file` with text output, or binary output to a terminal) — or a `format --check` run that found files needing formatting. |
| `124` | A command-line parse error: an unknown flag or a bad option value (reported by the argument parser). |
| `125` | An internal error (an uncaught exception). |
| `128` | The input was **rejected by a diagnostic**: a parse, validation, or type error, or a malformed wasm binary. This is also the status of a `check` run that found any problem. |

The distinction is *how you used the tool* (`123`/`124`) versus *the input is
bad* (`128`). A rejected input reports `128` wherever the error is found —
syntax, validation, or type-checking — so `check` exits `0` when every input is
valid and `128` otherwise, which is what a CI gate wants. For scripting, treat
any non-zero status as failure.
