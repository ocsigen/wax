The compilation-hints proposal's frequency attributes in Wax: `#[freq = n]` gives
an executions-per-call ratio, `#[never_opt]` and `#[always_opt]` are its reserved
values. A hint attribute prefixes an *expression* and takes the whole of it, so it
reaches calls as well as the control instructions `#[likely]` prefixes, and several
hints may stack on one instruction.

A hint on a block statement keeps the `;`-less form a plain block statement
has, stacked hints included; a hint on anything else takes the statement's `;`:

  $ wax -i wax -f wax hints.wax
  type ft = fn(i32) -> i32;
  
  fn a(x: i32) -> i32 {
      x;
  }
  
  fn side(x: i32) {}
  
  fn spin(n: i32) {
      #[always_opt]
      'l: loop {
          #[unlikely]
          br_if 'l n;
      }
  }
  
  fn hot(c: i32) -> i32 {
      #[likely]
      #[freq = 16]
      if c => i32 {
          1;
      } else {
          2;
      }
  }
  
  fn calls(p: &?ft, x: i32) -> i32 {
      #[freq = 4]
      side(x);
      let y = #[never_opt] a(x);
      (#[freq = 2] #[targets(a: 0.73)] p(y)) + a(#[always_opt] a(x));
  }

Each lowers to its own `metadata.code.*` annotation, on the instruction it
prefixed — including a call nested in a folded operand, where the annotation sits
inside the group:

  $ wax -i wax -f wat hints.wax
  (type $ft (func (param i32) (result i32)))
  
  (func $a (param $x i32) (result i32) (local.get $x))
  
  (func $side (param $x i32))
  
  (func $spin (param $n i32)
    (@metadata.code.instr_freq (always_opt))
    (loop $l (@metadata.code.branch_hint "\00") (br_if $l (local.get $n)))
  )
  
  (func $hot (param $c i32) (result i32)
    (@metadata.code.branch_hint "\01") (@metadata.code.instr_freq (freq 16))
    (if (result i32) (local.get $c) (then (i32.const 1)) (else (i32.const 2)))
  )
  
  (func $calls (param $p (ref null $ft)) (param $x i32) (result i32)
    (local $y i32)
    (@metadata.code.instr_freq (freq 4)) (call $side (local.get $x))
    (local.set $y
      (@metadata.code.instr_freq (never_opt)) (call $a (local.get $x)))
    (i32.add
      (@metadata.code.instr_freq (freq 2))
      (@metadata.code.call_targets (target $a 0.73))
      (call_ref $ft (local.get $y) (local.get $p))
      (call $a
        (@metadata.code.instr_freq (always_opt)) (call $a (local.get $x))))
  )

All seven survive a binary round trip, back into the same seven placements:

  $ wax -i wax -f wasm hints.wax -o hints.wasm
  $ wax -i wasm -f wax hints.wasm | grep 'freq\|likely\|opt'
      #[always_opt]
          #[unlikely]
      #[likely]
      #[freq = 16]
      #[freq = 4]
      let y = #[never_opt] a(x);
      (#[freq = 2] #[targets(a: 0.73)] p(y)) + a(#[always_opt] a(x));

Printing is idempotent, so the attributes survive any number of round trips:

  $ wax -i wax -f wax hints.wax > once.wax
  $ wax -i wax -f wax once.wax > twice.wax
  $ diff once.wax twice.wax

At statement level a hint is a prefix of the statement list, attached to the
statement that follows, so a stacked-hinted block statement followed by another
statement needs no `;`; and the `while` continue-expression, the one statement
position outside a list, takes its own hint prefix:

  $ wax -i wax -f wat stack.wax
  (func $side (param $x i32))
  
  (func $f (param $c i32)
    (@metadata.code.branch_hint "\01") (@metadata.code.instr_freq (freq 16))
    (if (local.get $c) (then (nop)))
    (loop $loop
      (if (local.get $c)
        (then
          (nop)
          (@metadata.code.instr_freq (freq 128)) (call $side (local.get $c))
          (br $loop))))
  )

The prefix must sit directly on its instruction — an empty `;` statement in
between, or nothing at all, is rejected at the attribute:

  $ wax check straysemi.wax
  Error: A hint may only prefix an instruction.
   ──➤  straysemi.wax:4:5
  2 │ 
  3 │ fn f() {
  4 │     #[freq = 2] ; g();
    ·     ^^^^^^^^^^^
  5 │ }
  6 │ 
  [128]

  $ wax check dangling.wax
  Error: A hint may only prefix an instruction.
   ──➤  dangling.wax:3:5
  1 │ fn f() {
  2 │     nop;
  3 │     #[likely]
    ·     ^^^^^^^^^
  4 │ }
  5 │ 
  [128]

A hint on a statement that cannot carry one is rejected by the same placement
rule as everywhere else, not as a parse error:

  $ wax check notarget.wax
  Error: A frequency hint may only prefix a call or a control instruction.
   ──➤  notarget.wax:2:5
  1 │ fn f() {
  2 │     #[freq = 4] unreachable;
    ·     ^^^^^^^^^^^
  3 │ }
  4 │ 
  [128]

A branch hint needs a conditional branch, and a plain block is not one. The
diagnostic is blamed at the attribute, not at the instruction it decorates:

  $ wax check bad.wax
  Error:
    A branch hint may only prefix a conditional branch (if, br_if, or br_on_*).
   ──➤  bad.wax:2:5
  1 │ fn f(x: i32) {
  2 │     #[likely]
    ·     ^^^^^^^^^
  3 │     do {
  4 │         nop;
  [128]

Because the attribute takes the *whole* expression that follows it, a placement
whose extent a reader could not guess is rejected rather than silently bound to one
of the two readings — Rust's `stmt_expr_attributes` refuses the same case. Here the
hint lands on the `+`, and parentheses say which operand was meant:

  $ wax check greedy.wax
  Error: A frequency hint may only prefix a call or a control instruction.
   ──➤  greedy.wax:4:5
  2 │ 
  3 │ fn f(x: i32) -> i32 {
  4 │     #[freq = 4] a(x) + 1
    ·     ^^^^^^^^^^^
  5 │ }
  6 │ 
  Hint:
    A hint takes the whole expression that follows it. Parenthesize the part you
    meant.
  [128]

`metadata.code.call_targets` is spelled `#[targets(f: 0.73, …)]`. It takes a list,
which neither attribute shape (`#[name]`, `#[name = expr]`) can carry, so it has its
own production; the name is an ordinary identifier and the `(` after it is what
selects that production. Each frequency is a fraction of 1, stored as a whole
percent, so a decompiled binary reads back as the fraction it was written as:

  $ wax -i wat -f wax callhint.wat
  type ft = fn(i32) -> i32;
  fn a(x: i32) -> i32 {
      x;
  }
  #[export]
  fn go(f: &?ft, x: i32) -> i32 {
      #[freq = 8]
      #[targets(a: 1)]
      f(x);
  }

Three things a target list needs beyond prefixing a call, each mirroring the same
check on the Wasm side (`wax check` never converts, so a problem only the lowering
would hit has to be caught here). The listed frequencies must total at most 100% — a
shortfall is how the hint says other, unlisted targets take the remainder, so
exceeding it is meaningless rather than merely imprecise:

  $ wax check over.wax
  Error:
    The call-target frequencies add up to 130%, more than 100%. A shortfall is
    how the hint says other, unlisted targets take the remainder.
    ──➤  over.wax:8:5
   6 │ #[export]
   7 │ fn go(p: &?ft, x: i32) -> i32 {
   8 │     #[targets(a: 0.8, b: 0.5)]
     ·     ^^^^^^^^^^^^^^^^^^^^^^^^^^
   9 │     p(x)
  10 │ }
  [128]

The call must be indirect. A bare name that denotes a module function lowers to a
direct `call`, whose target is already known:

  $ wax check direct.wax
  Error:
    A call-target hint may only prefix an indirect call. This callee is a
    function, so the call is direct and its target is already known.
   ──➤  direct.wax:6:5
  4 │ #[export]
  5 │ fn go(x: i32) -> i32 {
  6 │     #[targets(a: 0.5)]
    ·     ^^^^^^^^^^^^^^^^^^
  7 │     a(x)
  8 │ }
  [128]

And each target must name a function. Naming one is not a *use* of it, though, so a
function reachable only through a target list still trips the `unused-field` lint —
the same rule the Wasm validator follows:

  $ wax check unbound.wax
  Error: The function 'nope' is not bound.
   ──➤  unbound.wax:5:15
  3 │ #[export]
  4 │ fn go(p: &?ft, x: i32) -> i32 {
  5 │     #[targets(nope: 0.5)]
    ·               ^^^^
  6 │     p(x)
  7 │ }
  [128]
