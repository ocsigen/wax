# Project Context: Wax
**Description:** A compiler toolchain for Wax, a Rust-like syntax for
  WebAssembly.
**Capabilities:** Formatting, Type Checking, Syntax Conversion (Wax ↔
  Wasm Text ↔ Wasm Binary).

## Tech Stack
* **Language:** OCaml (Latest Stable)
* **Build System:** Dune
* **Parser Generator:** Menhir (`.mly`)
* **Lexer:** Sedlex
* **Formatter:** OCamlformat (enforced via `dune build \@fmt`)
* **Testing:** Dune Diff/Golden Tests (Input vs `.expected` files)
* **Target:** WebAssembly (Wasm)

## Development Cheatsheet
The following commands define the standard developer workflow.

| Action | Command | Context |
| :--- | :--- | :--- |
| **Build** | `dune build` | Compiles the project. |
| **Format** | `dune build \@fmt` | Auto-formats code using `ocamlformat`. **Run before committing.** |
| **Test** | `dune runtest` | Runs the golden tests (diffs). |
| **Accept Diff**| `dune promote` | Updates `.expected` files if `runtest` shows a diff. |
| **Run CLI** | `dune exec wax -- <args>` | Execute the compiler manually. |

## CLI Interface (`bin/main.ml`)
**Usage:** `dune exec wax -- [options] [INPUT]`

### Positional Arguments
| Argument | Description | Notes |
| :--- | :--- | :--- |
| `[INPUT]` | Source file to convert/format. | Optional. If omitted, the tool readd from `stdin` |

### Options
| Flag | Long Flag | Description | Values |
| :--- | :--- | :--- | :--- |
| `-f` | `--format` | Output format (Default: Auto/`wax`) | `wat`, `wasm`, `wax` |
| `-i` | `--input-format` | Input format (Default: Auto/`wax`) | `wat`, `wasm`, `wax` |
| `-o` | `--output` | Output file (Default: `stdout`) | File path |

### Current Supported Pipelines
The CLI supports the following flows:
1.  `wat` -> `wat` (Formatting / Round-trip)
2.  `wat` -> `wax` (Decompilation / Desugaring)
3.  `wat` -> `wasm` (Compilation to binary)
4.  `wax` -> `wat` (Compilation / Sugar removal)
5.  `wax` -> `wax` (Formatting / Checking)
6.  `wax` -> `wasm` (Compilation to binary)

## Project Structure
* `src/bin/` - CLI entry point and test drivers.
    * `main.ml` - Main CLI driver (argument parsing).
    * `convert.ml` - Conversion logic entry point.
    * `pretty_print.ml` - Pretty printing utilities.
    * `run_wasm_testsuite.ml` - Test runner for the Wasm test suite.
    * `test_wasm.ml` - Wasm specific tests.
* `src/lib-utils/` - Shared helpers.
    * `ast.ml` / `.mli` - Common node definitions (location, annotations).
    * `printer.ml` / `.mli` - Generic `Format` wrappers/helpers.
    * `uint32.ml` / `.mli`, `uint64.ml` / `.mli` - Unsigned integer handling.
    * `colors.ml` / `.mli` - Terminal color support.
    * `source_map.ml` / '.mli' - Source map output support
    * `unicode.ml` / `.mli` - Unicode utilities (width).
    * `unicode_widths.ml` / `.mli` - Generated unicode width table.
* `src/lib-conversion/` - AST-to-AST transformation.
    * `from_wasm.ml` / `.mli` - Logic to convert WAT -> Wax.
    * `to_wasm.ml` / `.mli` - Logic to convert Wax -> WAT.
    * `namespace.ml` / `.mli` - Namespace management for conversion.
* `src/lib-wasm/` - **Target Language** (WAT) handling.
    * `ast.ml` / `.mli` - Wasm AST (Functor-based).
    * `ast_utils.ml` / `.mli` - AST traversal and utility functions.
    * `parser.mly` / `lexer.ml` - WAT parsing.
    * `parsing.ml` / `.mli` - Parsing logic and drivers.
    * `validation.ml` / `.mli` - Well-formedness checks.
    * `types.ml` / `.mli` - Subtyping and matching machinery.
    * `folding.ml` / `.mli` - Folded vs. Unfolded instruction conversion.
    * `output.ml` / `.mli` - WAT Pretty-printing.
    * `misc.ml` / `.mli` - Miscellaneous helpers.
    * `binary_to_text.ml` / '.mli' - Conversion from binary to text format
    * `text_to_binary.ml` / '.mli' - Conversion from text to binary format
    * `wasm_output.ml` / '.mli' - Wasm binary format output
    * `wasm_parser.ml` / 'mli` -  Wasm binary format parsing
* `src/lib-wax/` - **Source Language** (Wax) handling.
    * `ast.ml` / `.mli` - Wax AST (Recursive).
    * `ast_utils.ml` / `.mli` - AST traversal and utility functions.
    * `parser.mly` / `lexer.ml` - Wax parsing.
    * `typing.ml` / `.mli` - Semantic analysis and type checking.
    * `output.ml` / `.mli` - Wax Pretty-printing (AST traversal).
* `test/` - **Immutable** regression test suite (Source + `.expected` files).

## Documentation
* **Project Documentation:** Located in `docs/`. This is an `mdbook` project containing the official documentation.
* **API Documentation:** OCaml interface files (`.mli`) contain developer documentation for modules.

## AST Reference (Condensed)

### 1. Wax AST (`wax/ast.ml`)
Wax is expression-oriented. Note the recursive structure and
high-level constructs.

```ocaml
type binop = Add | Sub | Mul | Div of signage option | Rem of signage | ...
type unop = Neg | Pos | Not

type 'info instr_desc =
  | Block of label option * functype * 'info instr list
  | Loop of label option * functype * 'info instr list
  | If of label option * functype * 'info instr * 'info instr list * 'info instr list option
  | Let of (idx option * valtype option) list * 'info instr option
  | BinOp of binop * 'info instr * 'info instr  (* Recursive operands *)
  | UnOp of unop * 'info instr
  | Call of 'info instr * 'info instr list
  | Cast of 'info instr * casttype
  (* ... see lib/wax_ast.ml *)

and 'info instr = ('info instr_desc, 'info) annotated
```

### 2. Wasm AST (`wasm/ast.ml`)
**Crucial:** Defined inside the `Instructions(X)` functor. Operations
  are grouped by type.

```ocaml
(* Inside module Instructions(X) *)
type ('i32, 'i64, 'f32, 'f64) op = I32 of 'i32 | I64 of 'i64 | ...

type 'info instr_desc =
  | Block of { label : X.label; typ : blocktype option; block : 'info instr list }
  | Loop of { label : X.label; typ : blocktype option; block : 'info instr list }
  | If of { label : X.label; typ : blocktype option; if_block : 'info instr list; else_block : 'info instr list }
  | LocalGet of X.idx
  | LocalSet of X.idx
  (* Note: BinOp groups all binary ops under one variant *)
  | BinOp of (int_bin_op, int_bin_op, float_bin_op, float_bin_op) op
  | Const of (X.int32_t, X.int64_t, X.float_t, X.float_t) op
```

## Coding Standards (OCaml)

* **Paradigm:** Strictly functional. Prefer recursion and high-order
    functions (`List.map`, `List.fold_left`) over imperative loops.
* **Pattern Matching:** Use pattern matching exclusively for control
    flow on ADTs. Ensure exhaustiveness.
* **Style:**
    * `snake_case` for values/functions.
    * `OCaml_module_style` for module names and constructors.
    * Annotate top-level functions in `.mli` interface files.

## Rules & Constraints (Non-negotiables)
1.  **TEST SUITE INTEGRITY:**
    * **NEVER** modify `.expected` files in `test/` to make a test pass.
    * If a test fails (diff mismatch), assume the **code** is broken, not the
      test.
    * **NEVER** modify `dune` rules in `test/` without explicit permission.
2.  **Menhir Workflow:**
    * Edit `lib/parser.mly` for grammar changes.
    * **NEVER** edit the generated `.ml` parser files manually.
3.  **Formatting:**
    * Assume `ocamlformat` handles style. Do not manually align code.
    * Run `dune build \@fmt` to verify formatting.
4. **Avoid changing unrelated code:** Keep diffs small by only
   changing the code you intended to change. Nearby code should not be
   cleaned up while making a change -- if you think there is a good
   cleanup, suggest it to me for a separate patch.
5. **Keep related functions together:** When adding a new function,
   try to insert it near related functions, to keep similar behaviour
   close.
6. Do not add comments that simply repeat what the code says.
