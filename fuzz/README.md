# Fuzzing the wax toolchain

A lightweight, process-isolated harness that runs wax's conversions, typing and
validation over a large corpus and flags any output that violates a correctness
invariant. It needs no golden files, so the same oracles work on a fixed corpus,
on mutated inputs, and on machine-generated modules.

## Why this works here

The toolchain hands us oracles for free:

* **Crashes are unambiguous.** wax answers any well-formed request with exit `0`
  (done), `128` (validation diagnostic) or `123` (parse/malformed). *Anything
  else* — an uncaught exception (cmdliner reports it as `125`), a signal, or a
  timeout — is a bug, with no reference implementation required.
* **A reference validator exists.** `wasm-tools validate` (and the spec
  interpreter) tell us the ground truth for "is this module valid", so we can
  catch wax accepting the invalid or rejecting the valid.
* **The pipelines compose into round-trips.** A module decompiled to Wax and
  recompiled must still be a valid binary.

## Requirements

* A built wax: `dune build` (the harness uses `_build/default/src/bin/main.exe`).
* [`wasm-tools`](https://github.com/bytecodealliance/wasm-tools)
  (`cargo install wasm-tools`) on `PATH` or at `~/.cargo/bin`.
* `jq` (optional) — lets the corpus builder also harvest the *invalid*-module
  corpus from the spec suite.

Overridable via environment: `WAX`, `WASM_TOOLS`, `TIMEOUT` (seconds per
invocation, default 30), `WT_FEATURES` (default `all` — wax targets bleeding-edge
proposals, so the reference must enable them too or it false-rejects valid output).

## Usage

```sh
fuzz/build-corpus.sh        # populate fuzz/corpus/{valid,invalid}/ (~7000 modules)
fuzz/run.sh                 # run every oracle over the corpus, print a report
fuzz/oracle.sh FILE [valid|invalid|unknown]   # check one file (the fuzzing unit)
fuzz/smith.sh [count] [bytes]                 # generate valid modules + check them
```

`run.sh` and `smith.sh` exit non-zero if any **HIGH**-severity finding appears,
so either can gate CI. `fuzz/corpus/` and `fuzz/smith-findings/` are gitignored.

## The corpus

* `test/wasmoo/wasm-source/*.wat` — curated single modules (files using `(@if)`
  conditional annotations are skipped: they need `-D` defines and are not
  standalone wasm).
* `test/wasm-test-suite/**/*.wast` — the official spec suite, exploded into one
  `.wasm` per module by `wasm-tools json-from-wast`. The JSON's command type tags
  each module `valid` (`module`) or `invalid` (`assert_invalid` /
  `assert_malformed`) — giving differential-validation ground truth on both sides.

## The oracles (`oracle.sh`)

| Category        | Severity | What it asserts |
|-----------------|----------|-----------------|
| `CRASH`         | HIGH   | No pipeline (`wat/wasm/wax → wat/wax/wasm`, ± `-v`) exits other than ok/rejected. |
| `FALSE_REJECT`  | HIGH   | `wax check` accepts every module known valid. |
| `FALSE_ACCEPT`  | HIGH   | `wax check` rejects every module known invalid; and a binary wax emits from an accepted module passes `wasm-tools validate` (emitter soundness). |
| `VALIDATOR_DIFF`| REVIEW | For untagged input, `wax check`'s verdict matches `wasm-tools validate`. |
| `ROUNDTRIP`     | HIGH   | `x → wax → wasm` recompiles and the result validates. |
| `IDEMPOTENCE`   | REVIEW | `format(format(x)) == format(x)` textually. |

Each finding line is tab-separated: `FINDING  category  severity  input  detail
repro`, where `repro` is a runnable command. HIGH = wax did something
provably wrong; REVIEW = worth a human look (may include benign noise).

### Deliberately *not* an oracle

Textual equivalence of `x → wasm` vs `x → wax → wasm`. wax legitimately reorders
locals, dedups/renumbers types and rewrites the name section, so two
semantically-equal binaries differ textually. The round-trip oracle therefore
checks *validity* of the recompiled binary, not byte/text identity. True
behavioural equivalence belongs in the execution oracle below.

## Triaging findings

* **HIGH `CRASH` / `ROUNDTRIP` / emitter `FALSE_ACCEPT`** — almost always real.
* **`FALSE_REJECT` from `smith.sh`** — triage: a genuine validator gap *or* a
  proposal wax does not implement yet (e.g. `exnref`, custom descriptors). Tune
  `smith.sh`'s `--*-enabled` flags down to wax's supported feature set to remove
  the unimplemented-proposal noise.
* **`VALIDATOR_DIFF` / `IDEMPOTENCE` (REVIEW)** — confirm by hand before filing.

Replay any finding with the `repro` command, or for a saved smith module:
`fuzz/oracle.sh fuzz/smith-findings/smith-<n>.wasm valid`.

## Roadmap

This is the **corpus + oracle** layer. Natural extensions, each reusing
`oracle.sh` unchanged:

1. **Mutation** — parse a corpus `.wasm`, perturb the AST (swap operands, nudge
   indices, drop/duplicate instructions), re-emit, feed to `oracle.sh`. Keeps
   inputs near-valid, where the interesting validation/typing edges live.
2. **Coverage-guided** — build wax with AFL instrumentation (or wrap the OCaml
   entry points with [Crowbar](https://github.com/stedolan/crowbar)) so the
   generator is steered by coverage rather than blind random bytes.
3. **Execution oracle (behavioural equivalence)** — the strongest check. The
   spec `.wast` files carry `assert_return` / `assert_trap` expectations.
   Recompile each module through wax, point the original assertions at wax's
   binary, and run them under `spectest-interp` (or Node). A result that differs
   from the expectation is a miscompilation — the bug class the validity oracles
   cannot see.
