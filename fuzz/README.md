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
fuzz/diff-validate.sh [count] [bytes]         # differential validation vs the spec reference (both directions)
fuzz/triage.sh REPORT       # collapse a findings report into ranked bug signatures

# Wax *source* side (compile direction: parser, type checker, to_wasm):
fuzz/wax-corpus.sh [smith-count] [bytes]   # build .wax seeds: spec corpus + smith modules
fuzz/mutate-wax.sh [count]       # AST-mutate the wax seeds + check them (needs wasm-tools)
fuzz/mutate-validate.sh [count]  # AST-mutate + emitter-soundness vs the spec reference (no wasm-tools)
fuzz/cast-lattice.sh             # deterministic sweep of the numeric/ref cast lattice

# WAT *input* side (the text lexer/parser):
fuzz/wat-corpus.sh [smith-count] [bytes]   # build .wat seeds: spec corpus + smith modules
fuzz/mutate-wat.sh [count]  # text-mutate the wat seeds (edge literals) + check them
fuzz/wat-cast-chain.sh      # deterministic byte-identical round-trip of WAT two-cast chains

# wasm *binary* input side (the binary reader):
fuzz/mutate-wasm.sh [count] # byte-mutate the valid wasm corpus + check them

# Execution (behavioural-equivalence) oracles — run on spec .wast files:
fuzz/exec-ref.sh [wast…]    # via the reference interpreter (strongest; GC/SIMD/EH/multi-mem)
fuzz/exec-interp.sh [wast…] # via wabt spectest-interp
fuzz/exec.sh [wast…]        # via Node
```

`run.sh`, `smith.sh`, `mutate-wax.sh`, `diff-validate.sh`, `mutate-validate.sh`,
`cast-lattice.sh` and `wat-cast-chain.sh` exit non-zero if any **HIGH**-severity
finding appears, so any can gate CI; the execution oracles exit non-zero on any
behavioural regression. `fuzz/corpus/`, `fuzz/corpus-wax/`, `fuzz/smith-findings/` and
`fuzz/mutate-findings/` are gitignored.

The parallel campaigns (`smith.sh`, `mutate-wax.sh`, `diff-validate.sh`,
`mutate-validate.sh`, `cast-lattice.sh`) snapshot the wax binary at start-up
(`freeze_wax` in `lib.sh`) and run every worker against the frozen copy. A long
run fans thousands of short wax invocations across workers; without the snapshot,
rebuilding `_build/.../main.exe` mid-run would let a worker exec a half-written
binary and report the resulting non-zero exit as a spurious crash (a whole burst
of them). The copy lives in the run's scratch dir and is removed on exit.

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

* `wax-corpus.sh` builds the `.wax` seed set in `fuzz/corpus-wax/valid/` by
  decompiling, with wax itself, both the valid wasm corpus (small, curated
  spec-suite modules) and a batch of `wasm-tools smith` modules (default 1000 at
  8192 seed bytes — tens to hundreds of lines, far more intertwined, so the
  mutator explores deep code rather than only tiny snippets). Every seed is
  valid, type-correct Wax (wax's own output). `run.sh fuzz/corpus-wax` sweeps it,
  exercising the `wax → wat/wax/wasm` directions and the wax round-trip (oracle 6).
* `mutate-wax.sh` is the AST mutation fuzzer. The `fuzz_mutate` tool
  (`src/bin/fuzz_mutate.ml`) parses a `.wax` seed and mutates one AST node —
  graft another subexpression from the same program in its place, swap a
  binary/unary operator or a binop's operands, retype a cast, substitute an
  edge-value literal, or swap/delete/duplicate a statement — then reprints it.
  Because the output is printed from a real AST it *always re-parses*, so ~57% of
  mutants reach the type checker and `to_wasm` (the rest exercise its rejection
  paths; a token-level mutator mostly produces parse errors that never get that
  far). Mutants have unknown validity, so the live oracles are crashes, emitter
  soundness, and the wax round-trip; each finding is re-verified to drop transient
  load noise.

There is no external reference for Wax *source* (no `wasm-tools validate`
equivalent), so a wax-side bug is: a crash; wax accepting a program whose emitted
wasm the reference rejects (`FALSE_ACCEPT`); or a broken `wax → wasm → wax → wasm`
round-trip. A natural next step (not yet built) is a from-scratch grammar-based
Wax generator for syntactic constructs the decompiler never emits.

* `mutate-validate.sh` is the `FALSE_ACCEPT` (emitter-soundness) check on its own,
  judged by the spec **reference interpreter** instead of `wasm-tools` — so it runs
  where `mutate-wax.sh`'s full oracle cannot (no `wasm-tools` installed). It mutates
  a seed, type-checks it (`wax --validate`), and if wax accepts, the emitted binary
  must decode+validate under the reference; a wax accept + reference reject is
  `UNSOUND`, a wax crash is `CRASH`, a wax rejection is fine. Two precautions avoid
  false positives: seeds are pre-filtered to those the reference can decode
  unmutated (dropping proposals the REF build lacks, e.g. stack switching), and a
  reference *decoding* error on a mutant (an unsupported proposal a graft pulled in)
  is ignored — only a *validation* rejection counts. This targets the hand-written
  soundness class the decompiler-based oracles structurally miss: decompiled wax
  always carries explicit casts, so implicit coercions and flexible-literal
  defaults (e.g. a large-int literal used as an integer then coerced to a float)
  only arise in source a human — or the mutator — writes. Caveat: `fuzz_mutate`
  only edits literals and cast targets plus grafts, so it under-explores those
  patterns; reviewing the flexible-literal arms of `lib-wax/typing.ml` directly is
  the higher-signal method, and a clean run is corroboration, not proof.

* `cast-lattice.sh` makes that "higher-signal method" a deterministic guard for
  one especially bug-prone corner: numeric/reference **casts**. Several crashes
  had the same shape — the type checker accepts a cast whose emitted form
  `to_wasm` has no instruction to lower, so lowering hits `assert false`. These
  live in the flexible-numeric (`Number`/`Int`/`Float`/`LargeInt`/`Unknown`) arms
  of `cast`/`signed_cast`, which the decompiler-seeded oracles never reach
  (decompiled Wax always carries concrete, explicit casts), and which random
  mutation only samples one cell at a time. The cast space is small and
  enumerable, so `cast-lattice.sh` enumerates it: every (source flavour × cast
  target × signedness), as a single cast, a two-level chain, and a cast feeding a
  unary intrinsic, asserting wax never *crashes* (it must compile or cleanly
  reject). Compiling cases are round-tripped so the *fused* cast path — `to_wasm`
  re-expanding a single cast the decompiler fused from two — is covered too. The
  property: the set of casts the typer accepts must equal the set `to_wasm` can
  lower (`cast`/`signed_cast` and `default_cast` are two hand-maintained tables
  that must agree cell for cell). Deterministic, so it belongs in CI.

## The WAT input side

The lexer and WAT parser are a blind spot for everything above: `mutate-wax.sh`
only feeds *Wax*, and the corpus/smith oracles only feed *valid* wasm/wat, so an
out-of-range or malformed *WAT* literal never reaches them (several such crashes
were found only by hand-auditing the literal-parsing paths). `mutate-wat.sh`
closes it. `wat-corpus.sh` builds `.wat` seeds (spec corpus + smith modules,
converted with `wax -i wasm -f wat`); `mutate-wat.sh` applies text mutations from
`mutate-wat.awk` — chiefly injecting out-of-range / edge-value numeric literals
(e.g. `2^64`, huge hex) and over-long `\u{…}` escapes into the const, memarg,
index, lane and string positions the lexer/parser convert — and runs the oracle.
Text (not AST) mutation is the right tool here: the bugs are in the parser/lexer,
so feeding it almost-valid-but-malformed text is the point. A mutant is almost
always invalid, so a clean rejection (123/128) is expected, not a finding; the
hunt is purely for crashes. Findings are re-verified to drop transient load noise.

`wat-cast-chain.sh` is the WAT-side counterpart of `cast-lattice.sh`: where the
latter drives cast *lowering* from Wax source, this drives cast *decompilation
and re-fusion* from WAT. The decompiler fuses adjacent casts (the wasm pair
`ref.cast (ref i31)` then `i31.get_s` becomes a single Wax `x as i32_s`, which
`to_wasm` must re-expand), and that seam is only exercised when the input already
lines two casts up just so — which decompiled corpus/smith modules rarely do, and
which the Wax-seeded `cast-lattice.sh` cannot reach (its casts are always single
and explicit). So this script builds every WAT function whose body is a chain of
two type-composing cast-like instructions (numeric conversions plus the GC
reference casts), batches them into modules (translating several at once — every
chain is valid *by construction*, so unlike `cast-lattice.sh` there is no need to
isolate one per invocation), and asserts each round-trips **byte-identically**:
`wasm → wax → wasm` must equal the straight `wat → wasm` compile after
`wasm-tools strip --all` removes the name section. Anchoring to the *original*
binary (not to a fixed point of the round-trip) is what lets it catch a *wrong
first decompilation* — a self-consistent misread such as `i31.get_s` as unsigned
— that a fixed-point check would wave through. The one subtlety byte-identity
forces: pairs wax legitimately *canonicalises* are pruned, since re-emitting them
verbatim is not required — a `ref.cast` to a supertype-or-equal of the operand's
static type is a proven no-op wax drops, and `i32.wrap_i64; i64.extend_i32_s` is
folded to the equivalent `i64.extend32_s`. Deterministic; needs `wasm-tools` (for
`strip --all`), the round-trip legs themselves being wax-only.

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

## Differential validation (`diff-validate.sh`)

The `FALSE_REJECT` / emitter-`FALSE_ACCEPT` checks above use `wasm-tools validate`
as the reference and run over the fixed corpus. `diff-validate.sh` is the same
idea aimed at the **spec reference interpreter** (`REF`, default
`~/sources/Wasm/interpreter/wasm`) over freshly `smith`-generated modules, testing
both directions in one pass. For each module the reference accepts, it decompiles
to Wax and compares verdicts:

* **`OVER_REJECT`** — the reference accepts the module but wax rejects its faithful
  decompilation (a completeness gap: wax's typing is too strict).
* **`UNSOUND`** — wax accepts the decompiled Wax, but the binary it re-emits is
  rejected by the reference (wax's typing is too lenient).
* **`CRASH`** — wax crashed on either step.

Modules the reference rejects are skipped. Failing modules are saved under
`fuzz/diff-findings/` (gitignored). Because a decompiled module exercises the full
`wasm → wax → wasm` path against ground truth on *both* sides, this is the sharpest
net for the typing/`to_wasm` edges the corpus oracles miss (the reference is the
`REF` interpreter, not `wasm-tools`, so it also covers proposals `wasm-tools` lags
on).

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
