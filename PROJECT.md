## Project's description

The wasm_of_ocaml runtime consists of ~20k lines of handwritten WAT (WebAssembly Text) files. WAT's S-expression syntax is verbose and error-prone at this scale.

Wax addresses this by providing a Rust-like syntax for WebAssembly. It is a compiler toolchain, written in OCaml, that supports bidirectional conversion between three formats: Wax (source), WAT (text), and WASM (binary). It includes a type checker, a formatter, and all 9 conversion pipelines between the three formats. A working prototype was developed in the context of Improving wasm_of_ocaml (#1010).

This project takes the Wax toolchain from prototype to production, making it ready to serve as the primary authoring format for the wasm_of_ocaml runtime.

### Goal

Bring the Wax toolchain to production readiness: achieve full Wasm 3.0 support (SIMD, memory, tables, element and data segments), produce clear error messages from validation and type-checking, preserve comments through formatting, add conditional compilation, and complete the documentation.

### Design

The toolchain is a single `wax` binary that converts between any combination of Wax, WAT, and WASM formats. Input and output formats are auto-detected from file extensions or specified explicitly.

Key workflows:

- **Compile:** `wax runtime.wax -o runtime.wasm` — compile Wax source to WASM binary, the primary build step for the wasm_of_ocaml runtime
- **Type-check:** `wax runtime.wax -v` — catch type errors before compilation
- **Format:** `wax runtime.wax -f wax` — auto-format Wax source
- **Decompile:** `wax runtime.wat -f wax` — convert existing WAT files to Wax, enabling incremental migration of the wasm_of_ocaml runtime
- **Disassemble:** `wax runtime.wasm -f wat` — inspect compiled output as readable WAT
- **Round-trip:** any format can be converted to any other, enabling toolchain interoperability

### Challenges (and how they were addressed)

- **Comment preservation** — comments were discarded during parsing. **Resolved:** comments and blank lines are attached to AST nodes (`lib-utils/trivia.ml`) and threaded through both pretty-printers, surviving wax↔wax, wat↔wat, and wax↔wat round-trips (delimiters are translated across formats); they are lost only into/out of the WASM binary.
- **Crash-prone validation** — many `assert false` / `failwith` sites produced cryptic OCaml backtraces instead of diagnostics. **Largely resolved:** the sites were audited and classified (`INVARIANTS.md`), user-reachable ones now report diagnostics, `failwith` is nearly gone, and the remainder are genuine invariants or unimplemented features. Full crash-freedom on every invalid input is the main open item.
- **Silent data loss in decompilation** — SIMD, memory/table imports, and data/elem segments were dropped or replaced with `unreachable` when converting WAT/WASM to Wax. **Resolved:** all now decompile to dedicated Wax syntax, and higher-level idioms (`dispatch`, `match`, `while`) are recovered; no instruction is silently dropped.
- **Wasm 3.0 breadth** — SIMD (~250 instructions) and threads/atomics (~70) across parsing, AST, validation, conversion, and output are a large surface. **Resolved:** all are handled in every pipeline, along with several beyond-3.0 proposals (stack switching, wide arithmetic, branch hints, custom page sizes).

### Key results (success criteria)

1. **Done.** Full Wasm 3.0 support: SIMD, threads/atomics, memory, tables, element and data segments handled in all conversion pipelines without silent data loss (and several beyond-3.0 proposals too)
2. **Done.** All WebAssembly spec test suite tests pass (now passing; formerly 4 known failures)
3. **In progress.** No `assert false` / `failwith` reachable from user input — worst cases converted to diagnostics and the sites classified (`INVARIANTS.md`); remaining reachable crashes are unimplemented Wax features
4. **Done.** Comments are preserved through Wax-to-Wax and WAT-to-WAT formatting round-trips (and wax↔wat conversion)
5. **Done.** Conditional compilation (`#[if(FLAG)]` / `#[else]`) works with the `-D` CLI flag
6. **Mostly done.** Documentation covers the supported features (language guide, correspondence, feature matrix); a changelog, contributor guide, and blog post remain

### Deliverables

- ✅ Full Wasm 3.0 support: SIMD, threads/atomics, memory, tables, element and data segments across all 9 conversion pipelines
- 🔶 Hardened validation and type-checking with clear error messages — worst crashes converted to diagnostics; full crash-freedom on invalid input still in progress
- ✅ Comment-preserving pretty-printers for both Wax and WAT
- ✅ Conditional compilation support (`#[if]` / `#[else]` attributes, `-D` flag)
- 🔶 Documentation: language guide, correspondence tables, and a feature-support page are done; a dedicated known-limitations page is only partial
- ⬜ Blog post introducing Wax and its toolchain

### Timeline

Each key result was estimated at 2 FTE weeks of Specialist Software Engineer work, for a total of 10 FTE weeks. Most of the technical work is now complete; the estimates are kept for the record.

1. Full Wasm 3.0 support — 2 weeks — ✅ done
2. Clear error diagnostics and spec test suite passing — 2 weeks — 🔶 spec suite passes; diagnostic hardening ongoing
3. Comment-preserving pretty-printers — 2 weeks — ✅ done
4. Conditional compilation — 2 weeks — ✅ done
5. Complete documentation — 2 weeks — 🔶 mostly done (changelog/contributor guide/blog remain)

### Follow-up meetings

Monthly, as part of the wasm_of_ocaml coordination meeting

### Autonomy and scope

- *To be determined.*

### Resources available

- Repository: https://github.com/vouillon/wax
- Documentation: https://vouillon.github.io/wax/
- WebAssembly spec test suite included in `test/wasm-test-suite/core/`
- Detailed roadmap in `ROADMAP.md`

## Sub-tasks

> **Status (audited 2026-07-03).** Wasm 3.0 support and comment preservation are
> done, and the toolchain now goes beyond 3.0 — threads/atomics, stack
> switching, wide arithmetic, branch hints, and custom page sizes all round-trip
> — plus module naming (`#![module = "name"]`). The spec test suite passes with
> no known failures. Conditional compilation is complete (parse, per-branch
> validation, `-D`/`--define` selection, cross-format lowering). Documentation is
> now broadly complete: an expanded language guide, correspondence pages, and a
> feature-support page, with the guide's code blocks compile-checked in CI. CI
> (build + test matrix, docs deploy) and an npm build/publish workflow have been
> added. Validation/typing hardening is the main remaining work (crash-site
> cleanup and `wasm → wasm` validation). The prose figures in the sections above
> (e.g. "~250 SIMD instructions dropped", "comments are currently discarded",
> "~100+ assert false") are historical and now outdated.

### Full Wasm 3.0 support — done
- [x] SIMD: Wax syntax for v128 operations, conversion in both directions (`simd.ml`, `from_wasm.ml`, `to_wasm.ml`; commit `016cc3c`)
- [x] Memory operations: handled in Wax conversion (`from_wasm.ml` load/store/size/grow)
- [x] Table operations: handled in Wax conversion (get/set/size/grow/fill/copy/init)
- [x] Element and data segments: handled in Wax conversion (passive/active/declare, drop, init)
- [x] Memory/table imports: handled in Wax conversion (emit `Some` with import attributes)
- [x] `i32.extend8_s`, `i32.extend16_s`, `i64.extend8_s`, `i64.extend16_s` (and `i64.extend32_s`) in Wax decompilation
- [x] Pass all WebAssembly spec test suite tests (`test/wasm_test_suite.expected` empty; `dune runtest` green)

### Decompilation output quality (WAT/WASM → Wax)

Make decompiled Wax idiomatic and readable, so existing WAT runtime files can
be migrated to Wax with minimal hand-editing. These cleanups apply only when
converting *from* Wasm; hand-written Wax is left untouched.

- [x] Sink local declarations to their first use and fuse `let x: t; … x = e;` into `let x: t = e;` (`lib-conversion/sink_let.ml`, applied after `from_wasm.ml`)
- [x] Drop casts made redundant by precise types, and tighten `&?extern`/`&?any` casts of non-nullable values to `&extern`/`&any` (gated behind a `simplify` flag in `typing.ml`, enabled on both Wasm-to-Wax paths)
- [x] Drop redundant type annotations on initialized `let` bindings (`let x: t = e` → `let x = e` when the initializer already infers `t`)
- [ ] Inline / copy-propagate single-use locals where it improves readability
- [~] Recover higher-level control-flow idioms where unambiguous — `dispatch` from `br_table` jump tables (`recover_dispatch.ml`), `match` from `br_on_cast`/`br_on_null` ladders (`recover_match.ml`), and `while` from the loop back-branch idiom (`recover_loops.ml`) are recovered; plain `if`/`else` from `block`+`br_if` still TODO

### Validation and typing: clear error messages — in progress
- [x] Fix spec test failures: `core/func.wast`, `core/stack.wast`, `core/elem.wast` (all fixed by implicit-type handling, commit `2fcf2e9`); `core/exceptions/tag.wast` (tag-result validation is intentionally relaxed for stack switching — test commented out by design, commit `578b885`)
- [~] Replace user-reachable `assert false` / `failwith` with diagnostics. `failwith` is essentially gone (2 in `text_to_binary.ml`). `assert false` counts are now `validation.ml` 19, `typing.ml` 31, `to_wasm.ml` 31, `from_wasm.ml` 11 — but most are genuine invariants or unimplemented features, not reachable crashes: the user-reachable ones were audited and classified in `INVARIANTS.md`, and the worst were converted to diagnostics (see `ROADMAP.md` §1). Remaining reachable `typing.ml` crashes are unimplemented Wax features (§2).
- [ ] `ZZZ` placeholders remain (`validation.ml` 4, `typing.ml` 6; ~15 across `src/`), some marking imprecise diagnostic source locations
- [x] Complete GC struct/array field validation (signage, field index) — implemented in `validation.ml`
- [x] Fix TryTable handler stack context threading — functional (minor `ZZZ` cleanup notes remain)
- [x] Fix `select` with multi-element type lists — full type unification / LUB in `typing.ml`
- [ ] Enable validation for the `wasm -> wasm` pipeline (still commented out in `wasm_to_wasm`, `main.ml`)

### Pretty-printers: comment preservation — done
- [x] Attach comments to AST nodes during lexing/parsing (Wax and WAT) — `lib-utils/trivia.ml`, both lexers
- [x] Thread comment data through the Wax pretty-printer (`lib-wax/output.ml`)
- [x] Thread comment data through the WAT pretty-printer (`lib-wasm/output.ml`)
- [x] Handle edge cases + cross-format delimiter rewriting; cram tests for wax→wax, wat→wax, wax→wat

### Conditional compilation — done
- [x] Extend parser attribute rule for `#[if(...)]` and `#[else]` (rich condition language: vars, comparisons, versions, `all`/`any`/`not`)
- [x] All-reachable-configurations type checking under `--validate` (`cond_solver.ml`, `cond_explore.ml`)
- [x] Tests and documentation (`docs/src/language.md`, several cram tests)
- [x] Add `-D` / `--define` CLI flag (`main.ml`, parsed via `Cond_specialize.parse_define`)
- [x] Implement module field filtering pre-pass (`Cond_specialize.module_` in both `lib-wasm` and `lib-wax`, applied after parse in `specialize_wat`/`specialize_wax`)

### Documentation — mostly done
- [x] Document conditional compilation (`#[if]` / `#[else]`) — `docs/src/language.md`
- [x] Document new Wasm 3.0 features in correspondence tables — SIMD/memory/table/`dispatch`/`match` in `docs/src/correspondence/`
- [x] Update language guide with the newer Wax syntax — imports/exports, recursive & subtyped types, SIMD, stack switching, holes, and the attribute system are now covered in `language.md`
- [x] Feature-support / proposal matrix — `docs/src/features.md` (also the partial home for known limitations)
- [x] Compile-check the guide's code blocks in CI (`docs-examples.t`, `docs-intro.t`, `docs-language.t`)
- [~] Known limitations & conversion fidelity — partial (in `features.md`); no dedicated page yet
- [ ] Contributor guide
- [ ] Changelog
- [ ] Blog post introducing Wax

## People

- **Project lead:** Jérôme Vouillon
- **Process master:**  @...
- **Product owner:**  @...
- **Communication master:** @...
- **Documentation master:** @...
- **Maintenance master:** @...

## Project start checklist:
- [ ] Update all **input fields** in the [Objectives (Team) project](https://github.com/orgs/tarides/projects/27/views/1)
- [ ] Create a **communication channel** with the client
- [ ] Have a **meeting with your head of engineering** before starting to review project objectives (this document)
- [ ] Set up regular **meetings** with the client (kick-off meeting, bi-weekly meetings)
- [ ] Create a **project log** in [this repository](https://github.com/tarides/objectives/tree/main/reports), following the [template](https://github.com/tarides/objectives/blob/main/reports/NNN-project-template.md) and assign to the process master the responsibility to make sure it is updated every week.
- [ ] If the project is more than 6 months long, please **split** it into several projects.
- [ ] It is highly recommended to use an **issue tracker** and **kanban board** to track the progress. Please fill the corresponding fields [here](https://github.com/orgs/tarides/projects/27/views/1).
- [ ] Split the project into **sub-tasks** and list them as sub-tasks of this issue above.
- [ ] Kick-off meeting.
- [ ] Mid-term meeting. Review time estimates, schedule communication, blog posts.
- [ ] Closure meeting.

*Please report any difficulty as soon as possible to your head of engineering, so that we can find solutions, especially if you think there is a risk that the deadline cannot be met, if the technical scope should be changed, or if you think the project members should change.*

---

## Handoff: parser error recovery (in progress)

Panic-mode recovery for `parse_recover` (`src/lib-wasm/parsing.ml`), consumed
in-process by the editor/LSP and `wax check --all-errors`. It collects *all*
syntax errors and returns a best-effort AST. WAT support is new and partial.

### Engine (`src/lib-wasm/parsing.ml`, `parse_recover`)

Strategy order at each `HandlingError`, all using only the vanilla incremental
API (`acceptable`/`offer`/`pop`; no `--inspection`, no `error` productions):

1. `try_insert` — offer a candidate token in front of the offending one, kept
   only if the offending token then shifts (validated). Candidates: `?insert`, a
   `(token * Message.t) list`. One position tried once (`last_insert`).
2. `close_pending` — offending token is a boundary/EOF with an inner construct
   still open: insert `?closers` (and, between them, insert candidates) until the
   boundary is acceptable, so the inner construct reduces into the AST.
3. barrier (WAT) — a `( field-keyword` starting a new field. `?barrier` = the
   `(` token + a field-keyword predicate. Two entry routes: (a) `find_sync`
   returns `` `Barrier `` when it scans `( field-kw` (Leader-equivalent, any
   depth); (b) `try_barrier`, when the held token is a field keyword whose `(`
   already shifted — guarded by `preceded_by_open` so a bare keyword typed as an
   instruction is not fabricated into a field. Both call `place_pair`, which
   offers `(` then the keyword from the closest accepting level, reached by
   inserting closers (keeps the field body) or, failing that, popping the stack
   (re-opens a field closed too early). Two-token trial is essential: `(` alone
   is acceptable at every nesting level.
4. `skip` — nesting-aware panic skip (`find_sync` tracks bracket depth; `sync`
   classifies Open/Close/Boundary/Leader/Terminal/Skip), then `unwind`.

Per-language config lives in `Recover` modules: `src/lib-wax/recover.ml` (Wax:
`;` separator + closers + statement/keyword leaders) and
`src/lib-wasm/recover.ml` (WAT: parens Open/Close, `NAT "0"` placeholder,
`[RPAREN]` closer, field-keyword barrier). Driver entry points
`Wax_conversion.Driver.{wax,wat}_parse_recover`.

### WAT state

Works: single-token-repairable operands (`(i32.const)`→`(i32.const 0)`, `(br)`,
`(ref.null)`→type index), missing closers (`(func … (func …`→both funcs),
balanced garbage, unclosed-at-EOF. Fuzz clean (Wax + WAT, ~50k). Tests:
`test/recovery-wat/`.

### Group-drop (done)

Un-repairable constructs whose repair needs *multiple* tokens — `(v128.const)`
(shape + 16 lanes), `(import "m")` (name + descriptor) — used to drop the whole
enclosing field. **Group-drop** now fires inside `skip`'s `Sync` handler when the
resync token is a closer `)` the error state cannot itself shift (guarded on
`barrier <> None`, so Wax is untouched): the closer belongs to an *inner* group
whose production is incomplete, and offering it via `unwind` would climb to an
ancestor and steal *that* construct's closer. Instead `pop_to` climbs past the
broken group's opener on the live error env, its `)` is discarded, and the *next*
boundary is resynchronized from the enclosing state — so `(func (v128.const))`
becomes `(func)` + sibling, and `(import "m")` drops cleanly without absorbing the
following `(func …)` as its descriptor. No snapshot stack (the reviewer was
right). Tests in `test/recovery-wat/`; WAT recovery fuzz-clean at 240k.

A later review (commit 6692218e) found and fixed four "recovery destroys more
than it saves" regressions in this machinery: group-drop misfiring on a stray
`)` after a complete construct (now gated on a source `paren_depth`); `place_pair`
popping reduced fields (removed — `place_field` only inserts closers); the
barrier firing at any depth (now depth-0 only, restoring the invariant that
skipped nested content is not reinterpreted); and the barrier not seeing the
fused `(type`/`(import`/`(export` openers (now single-token barriers). Plus:
`try_barrier` reads the previously-offered token instead of scanning raw source
(commit `6692218e`); `unwind`/`close_pending` share helpers with `pop_to`/
barrier placement (`2fb90624`); `?barrier` documented (`555d3f4a`).

Aside (fixed, commit 910ee5bc): `wax_parse_recover` used to raise
`Failure "Int64.of_string"` on an overlong integer literal (a huge `memory`/table
limit, page size, or `#[if]` version component — the literals the Wax parser
converts eagerly rather than carrying as strings). `fuzz_recover` caught it at
seed 0. Each conversion is now bounds-checked and rejects an out-of-range literal
with a recoverable `Syntax_error` (as the Wasm parser already did). Regression
test `test/cram-tests/wax-limit-overflow.t`.

### Consumers wired (done)

`symbolsWat` and `checkWat` (`src/lib-editor/wax_editor.ml`) now parse WAT under
recovery, so the editor outline and diagnostics survive a syntax error the way
the Wax side already did. `check_wat_string` validates the best-effort AST with
`set_recovery` on, and `lib-wasm/validation.ml` gained the matching suppression
(mirroring the Wax typer): in recovery mode it drops all warnings and the
stack-shape error cascades (`empty_stack`/`non_empty_stack`/`leftover_values`)
that a dropped or auto-closed body triggers, while every genuine error in an
intact region still surfaces. Suppression is gated on `in_recovery`, so the CLI
validator is unchanged. Unbound-index/label errors are deliberately *not*
suppressed — group-drop preserves field shells (names survive a dropped body), so
those cascades are rare, and keeping them live surfaces real typos during
editing. Tested in `test/editor-wat-recovery/`.

### Possible follow-ups

`wax check --all-errors` now covers WAT too (commit 03e422df: the `Wat` arm in
`main.ml` recovers, then validates in recovery mode). The overlong-integer-literal
crash is fixed (commit 910ee5bc; see the aside above).
