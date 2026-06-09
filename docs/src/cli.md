# CLI Reference

The `wax` binary is the primary interface for the Wax toolchain. It supports conversion between Wax, WebAssembly Text (WAT), and WebAssembly Binary (Wasm) formats.

## Usage

```sh
wax [OPTIONS] [INPUT]        # convert (the default command)
wax format [OPTIONS] FILE…   # reformat files
```

By default `wax` converts between formats. The `format` subcommand reformats
files (see [Formatting](#formatting) below).

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
    - Perform validation during conversion.
    - For Wax: Runs type checking.
    - For Wasm Text: Runs well-formedness checks.
    - For input containing conditional annotations (`#[if]` / `(@if ...)`), every reachable combination of conditions is checked independently, and each error is reported with the assumption (`reachable when ...`) under which it occurs.
    - Disabled by default.

- **`-s`**, **`--strict-validate`**
    - Perform strict reference validation (for Wasm Text). Overrides default relaxed validation.

- **`--color`** *WHEN*
    - Colorize output.
    - Values: `always`, `never`, `auto`.
    - Default: `auto` (colors enabled only if output is a TTY).


- **`--fold`**
    - Fold instructions into nested S-expressions.
    - Applies typically to Wasm Text output.

- **`--unfold`**
    - Unfold instructions into flat instruction lists.
    - Applies typically to Wasm Text output.

- **`--source-map-file`** *FILE*
    - Generate a source map file.

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

## Formatting

The `format` subcommand reformats files in their own format (`.wat` → `.wat`,
`.wax` → `.wax`, `.wasm` → `.wasm`), detected from each file's extension.

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
- **`-v`**, **`--validate`**
    - Also type-check (Wax) / well-formedness-check (Wasm) while formatting.
- **`--color`** *WHEN* — as above (ignored when writing back in place).
- **`--fold`** / **`--unfold`** — as above.

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
