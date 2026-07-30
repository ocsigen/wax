`unused-field` asks whether a definition can actually be reached, not merely
whether some reference to it exists somewhere. The difference shows up on a dead
*cycle*: two functions that only call each other do reference one another, so a
presence check calls both used, yet neither can ever run.

Liveness starts from the roots — a function reachable from outside (exported, or
the start function) and every reference made from a module-level context, which
runs at instantiation: a global or table initializer, an element or data segment.
From there it follows calls, and a function *reference* counts as a call, since
where the reference ends up is not tracked. So the analysis stays conservative:
it never reports a function that might run.

The parent `dune` sets `WAX_WARN=correctness=hidden`, so re-enable the `unused`
group explicitly.

  $ wax check -W unused=warning reach.wat
  Warning [unused-field]: The function '$a' is never used.
    ──➤  reach.wat:9:9
   7 │ 
   8 │   ;; dead cycle, plus a helper only the cycle reaches
   9 │   (func $a (result i32) (call $b))
     ·         ^^
  10 │   (func $b (result i32) (call $helper_of_dead))
  11 │   (func $helper_of_dead (result i32)
  Warning [unused-field]: The function '$b' is never used.
    ──➤  reach.wat:10:9
   8 │   ;; dead cycle, plus a helper only the cycle reaches
   9 │   (func $a (result i32) (call $b))
  10 │   (func $b (result i32) (call $helper_of_dead))
     ·         ^^
  11 │   (func $helper_of_dead (result i32)
  12 │     (global.set $dead_g (memory.size $dead_mem))
  Warning [unused-field]: The function '$helper_of_dead' is never used.
    ──➤  reach.wat:11:9
   9 │   (func $a (result i32) (call $b))
  10 │   (func $b (result i32) (call $helper_of_dead))
  11 │   (func $helper_of_dead (result i32)
     ·         ^^^^^^^^^^^^^^^
  12 │     (global.set $dead_g (memory.size $dead_mem))
  13 │     (call $a))
  Warning [unused-field]: The function '$selfrec' is never used.
    ──➤  reach.wat:16:9
  14 │ 
  15 │   ;; self-recursive and dead
  16 │   (func $selfrec (result i32) (call $selfrec))
     ·         ^^^^^^^^
  17 │ 
  18 │   ;; live chain from an export
  Warning [unused-field]: The global '$dead_g' is never used.
   ──➤  reach.wat:3:11
  1 │ (module
  2 │   (memory $dead_mem 1)
  3 │   (global $dead_g (mut i32) (i32.const 0))
    ·           ^^^^^^^
  4 │   (tag $dead_tag (param i32))
  5 │   (table $t 1 funcref)
  Warning [unused-field]: The memory '$dead_mem' is never used.
   ──➤  reach.wat:2:11
  1 │ (module
  2 │   (memory $dead_mem 1)
    ·           ^^^^^^^^^
  3 │   (global $dead_g (mut i32) (i32.const 0))
  4 │   (tag $dead_tag (param i32))
  Warning [unused-field]: The tag '$dead_tag' is never used.
   ──➤  reach.wat:4:8
  2 │   (memory $dead_mem 1)
  3 │   (global $dead_g (mut i32) (i32.const 0))
  4 │   (tag $dead_tag (param i32))
    ·        ^^^^^^^^^
  5 │   (table $t 1 funcref)
  6 │   (elem (table $t) (i32.const 0) funcref (ref.func $rooted_by_elem))

`$a`, `$b` and `$helper_of_dead` form a dead cycle; `$selfrec` is a one-function
one. `$live`/`$live_leaf` are reachable from the export and `$rooted_by_elem` from
the element segment, so none of those is reported, nor is the table the segment
initializes. The fields `$helper_of_dead` touches — `$dead_g`, `$dead_mem` — are
reported too: a reference from dead code keeps nothing alive. Note `$dead_g` draws
`unused-field` rather than `unnecessary-mut`, even though the only `global.set` on
it sits in dead code: the stronger report wins, one per declaration.

The Wax type checker computes the same thing over names instead of indices. The
same module written in Wax reports the same seven fields (the order differs: the
typer walks the module once, reporting each field where it is declared):

  $ wax check -W unused=warning reach.wax
  Warning [unused-field]: The memory 'dead_mem' is never used.
   ──➤  reach.wax:1:8
  1 │ memory dead_mem: i32 [1];
    ·        ^^^^^^^^
  2 │ let dead_g: i32 = 0;
  3 │ tag dead_tag(i32);
  Warning [unused-field]: The global 'dead_g' is never used.
   ──➤  reach.wax:2:5
  1 │ memory dead_mem: i32 [1];
  2 │ let dead_g: i32 = 0;
    ·     ^^^^^^
  3 │ tag dead_tag(i32);
  4 │ table t: &?func [1];
  Warning [unused-field]: The tag 'dead_tag' is never used.
   ──➤  reach.wax:3:5
  1 │ memory dead_mem: i32 [1];
  2 │ let dead_g: i32 = 0;
  3 │ tag dead_tag(i32);
    ·     ^^^^^^^^
  4 │ table t: &?func [1];
  5 │ elem roots: &?func @ t[0] = [rooted_by_elem];
  Warning [unused-field]: The function 'a' is never used.
    ──➤  reach.wax:8:4
   6 │ 
   7 │ // dead cycle, plus a helper only the cycle reaches
   8 │ fn a() -> i32 { b() }
     ·    ^
   9 │ fn b() -> i32 { helper_of_dead() }
  10 │ fn helper_of_dead() -> i32 {
  Warning [unused-field]: The function 'b' is never used.
    ──➤  reach.wax:9:4
   7 │ // dead cycle, plus a helper only the cycle reaches
   8 │ fn a() -> i32 { b() }
   9 │ fn b() -> i32 { helper_of_dead() }
     ·    ^
  10 │ fn helper_of_dead() -> i32 {
  11 │   dead_g = dead_mem.size();
  Warning [unused-field]: The function 'helper_of_dead' is never used.
    ──➤  reach.wax:10:4
   8 │ fn a() -> i32 { b() }
   9 │ fn b() -> i32 { helper_of_dead() }
  10 │ fn helper_of_dead() -> i32 {
     ·    ^^^^^^^^^^^^^^
  11 │   dead_g = dead_mem.size();
  12 │   a()
  Warning [unused-field]: The function 'selfrec' is never used.
    ──➤  reach.wax:16:4
  14 │ 
  15 │ // self-recursive and dead
  16 │ fn selfrec() -> i32 { selfrec() }
     ·    ^^^^^^^
  17 │ 
  18 │ // live chain from an export

An `(elem declare …)` segment is not a root. It installs nothing and runs
nothing: it exists so that a `ref.func` elsewhere validates, so the function it
names is reachable exactly when that other `ref.func` is. `$dead_self` here takes
a reference of itself and nothing else reaches it, so the declaration does not
keep it alive, while `$reached` — referenced from an exported function's body —
stays live. (An *active* segment does install into a table, and a *passive* one
can be `table.init`ed, so both keep rooting their references.)

  $ cat > declare.wat <<'WAT'
  > (module
  >   (func $live (export "live") (result funcref) (ref.func $reached))
  >   (func $reached)
  >   (func $dead_self (result funcref) (ref.func $dead_self))
  >   (elem declare func $reached $dead_self))
  > WAT
  $ wax check -W unused=warning --error-format short declare.wat
  declare.wat:4:9: warning: The function '$dead_self' is never used. [unused-field]

The Wax surface leaves that segment implicit — the lowering synthesizes it for a
body-only `ref.func` — so the two forms agreed only once the segment stopped
rooting. Regression: the wasm-smith lint-parity oracle, where a `mut` global read
only by such a function was reported `unnecessary-mut` as wat and
`unused-field` as wax.

  $ wax -i wat -f wax declare.wat -o declare.wax && wax check -W unused=warning --error-format short declare.wax
  declare.wax:6:4: warning: The function 'dead_self' is never used. [unused-field]
