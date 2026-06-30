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

The **execution oracles** below need an external runner: `node` (`exec.sh`),
wabt's `wast2json` + `spectest-interp` (`exec-interp.sh`), or the WebAssembly
reference interpreter (`exec-ref.sh`, default `~/sources/Wasm/interpreter/wasm`,
override with `REF`).

## Usage

```sh
fuzz/build-corpus.sh        # populate fuzz/corpus/{valid,invalid}/ (~7000 modules)
fuzz/run.sh                 # run every oracle over the corpus, print a report
fuzz/oracle.sh FILE [valid|invalid|unknown]   # check one file (the fuzzing unit)
fuzz/smith.sh [count] [bytes]                 # generate valid modules + check them
fuzz/triage.sh REPORT       # collapse a findings report into ranked bug signatures

# Wax *source* side (compile direction: parser, type checker, to_wasm):
fuzz/wax-corpus.sh          # decompile the valid wasm corpus to fuzz/corpus-wax/ (.wax seeds)
fuzz/mutate-wax.sh [count]  # AST-mutate the wax seeds + check them

# Execution (behavioural-equivalence) oracles — run on spec .wast files:
fuzz/exec-ref.sh [wast…]    # via the reference interpreter (strongest; GC/SIMD/EH/multi-mem)
fuzz/exec-interp.sh [wast…] # via wabt spectest-interp
fuzz/exec.sh [wast…]        # via Node
```

`run.sh`, `smith.sh` and `mutate-wax.sh` exit non-zero if any **HIGH**-severity
finding appears, so any can gate CI; the execution oracles exit non-zero on any
behavioural regression. `fuzz/corpus/`, `fuzz/corpus-wax/`,
`fuzz/smith-findings/` and `fuzz/mutate-findings/` are gitignored.

## The corpus

* `test/wasmoo/wasm-source/*.wat` — curated single modules (files using `(@if)`
  conditional annotations are skipped: they need `-D` defines and are not
  standalone wasm).
* `test/wasm-test-suite/**/*.wast` — the official spec suite, exploded into one
  `.wasm` per module by `wasm-tools json-from-wast`. The JSON's command type tags
  each module `valid` (`module`) or `invalid` (`assert_invalid` /
  `assert_malformed`) — giving differential-validation ground truth on both sides.

## The Wax source side

Everything above starts from *wasm* and runs `wasm → wax → wasm`. That barely
exercises the *compile* direction — the Wax parser, type checker and `to_wasm` —
on anything the decompiler would not itself emit. Two scripts close that gap:

* `wax-corpus.sh` decompiles the valid wasm corpus into `fuzz/corpus-wax/valid/`,
  a corpus of valid, type-correct Wax (wax's own output). `run.sh
  fuzz/corpus-wax` sweeps it, exercising the `wax → wat/wax/wasm` directions and
  the wax round-trip (oracle 6).
* `mutate-wax.sh` is the AST mutation fuzzer. The `fuzz_mutate` tool
  (`src/bin/fuzz_mutate.ml`) parses a `.wax` seed, mutates one AST node — swap a
  binary/unary operator, tweak a literal, reorder a block's first two statements
  — and reprints it. Because the output is printed from a real AST it *always
  re-parses*, so ~95% of mutants reach the type checker and `to_wasm` (a
  token-level mutator mostly produces parse errors that never get that far).
  Mutants have unknown validity, so the live oracles are crashes, emitter
  soundness, and the wax round-trip.

There is no external reference for Wax (no `wasm-tools validate` equivalent), so
a wax-side bug is: a crash; wax accepting a program whose emitted wasm the
reference rejects (`FALSE_ACCEPT`); or a broken `wax → wasm → wax → wasm`
round-trip. A natural next step (not yet built) is a from-scratch grammar-based
Wax generator for syntactic constructs the decompiler never emits.

## The oracles (`oracle.sh`)

| Category        | Severity | What it asserts |
|-----------------|----------|-----------------|
| `CRASH`         | HIGH   | No pipeline (`wat/wasm/wax → wat/wax/wasm`, ± `-v`) exits other than ok/rejected. |
| `FALSE_REJECT`  | HIGH   | `wax check` accepts every module known valid. |
| `FALSE_ACCEPT`  | HIGH   | `wax check` rejects every module known invalid; and a binary wax emits from an accepted module passes `wasm-tools validate` (emitter soundness). |
| `VALIDATOR_DIFF`| REVIEW | For untagged input, `wax check`'s verdict matches `wasm-tools validate`. |
| `ROUNDTRIP`     | HIGH   | `x → wax → wasm` recompiles and validates; and for a wax input, `wax → wasm → wax → wasm` re-validates (the two directions compose). |
| `IDEMPOTENCE`   | REVIEW | `format(format(x)) == format(x)` textually. |

Each finding line is tab-separated: `FINDING  category  severity  input  detail
repro`, where `repro` is a runnable command. HIGH = wax did something
provably wrong; REVIEW = worth a human look (may include benign noise).

### Deliberately *not* an oracle

Textual equivalence of `x → wasm` vs `x → wax → wasm`. wax legitimately reorders
locals, dedups/renumbers types and rewrites the name section, so two
semantically-equal binaries differ textually. The round-trip oracle therefore
checks *validity* of the recompiled binary, not byte/text identity. True
behavioural equivalence belongs in the execution oracles below.

## The execution oracles

The strongest check: recompile each spec module through wax, then run the spec's
own `assert_return` / `assert_trap` assertions and confirm the results are
unchanged. A difference is a *miscompilation* — the bug class the validity/crash
oracles cannot see. All three are differential (compare a baseline run of the
original against a run after wax recompiled the modules) so any runner limitation
cancels out, and all take `MODE=codec` (wasm→wasm, default) or `MODE=wax`
(wasm→wax→wasm). A module the runner cannot instantiate (unsupported proposal) or
wax cannot recompile is skipped and counted, not failed.

| Script            | Runner | Reach |
|-------------------|--------|-------|
| `exec-ref.sh`     | WebAssembly reference interpreter | Widest — GC, SIMD, exceptions, multi-memory (not stack switching). Runs `.wast` directly via `wast-rewrite.js`. |
| `exec-interp.sh`  | wabt `spectest-interp` | SIMD/v128, GC, memory64; but `wast2json` crashes on ~100 core files. |
| `exec.sh`         | Node (`exec-run.js`) | MVP + common proposals; no v128. |

`exec-ref.sh` is the one to reach for; the others predate it and remain for
cross-checking against a second engine.

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

The **corpus + oracle** and **execution oracle** layers are both built (above).
Natural remaining extensions, each reusing `oracle.sh` unchanged:

1. **Mutation** — parse a corpus `.wasm`, perturb the AST (swap operands, nudge
   indices, drop/duplicate instructions), re-emit, feed to `oracle.sh`. Keeps
   inputs near-valid, where the interesting validation/typing edges live.
2. **Coverage-guided** — build wax with AFL instrumentation (or wrap the OCaml
   entry points with [Crowbar](https://github.com/stedolan/crowbar)) so the
   generator is steered by coverage rather than blind random bytes.
