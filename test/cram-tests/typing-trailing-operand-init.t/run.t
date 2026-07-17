A construct whose trailing operand is emitted last but typed first — a call
callee (its parameter types check the arguments) and a [struct.new_desc]
descriptor (its type fixes the struct type the fields check against) — must still
thread the initialized-local analysis in EMISSION order: the earlier operands run
first at runtime, so a [local.tee] in one of them is visible to the trailing
operand, while a tee in the trailing operand is NOT visible to the earlier ones.

A field tees a non-defaultable local that the descriptor then reads. The field
runs first, so the local is initialized by the time the descriptor reads it:
accepted.

  $ cat > desc-field-tee.wax <<'WAX'
  > #![feature = "custom-descriptors"]
  > rec {
  >   type a = descriptor b { link: &b };
  >   type b = describes a { };
  > }
  > fn f(v: &b) -> &a {
  >   let k: &b;
  >   let r: &a = { descriptor(k) | link: (k := v) };
  >   return r;
  > }
  > WAX
  $ wax check desc-field-tee.wax

The mirror image: the descriptor tees the local, a field reads it. The field runs
first, so the read is of an uninitialized local: rejected (the tee in the
descriptor must not leak back into the fields).

  $ cat > desc-desc-tee.wax <<'WAX'
  > #![feature = "custom-descriptors"]
  > rec {
  >   type a = descriptor b { link: &b };
  >   type b = describes a { };
  > }
  > fn f(v: &b) -> &a {
  >   let k: &b;
  >   let r: &a = { descriptor(k := v) | link: k };
  >   return r;
  > }
  > WAX
  $ wax check desc-desc-tee.wax
  Error: The local variable 'k' has not been initialized.
    ──➤  desc-desc-tee.wax:8:44
   6 │ fn f(v: &b) -> &a {
   7 │   let k: &b;
   8 │   let r: &a = { descriptor(k := v) | link: k };
     ·                                            ^
   9 │   return r;
  10 │ }
  [128]

An argument tees a non-defaultable local that the callee reads. Arguments are
pushed before the callee, so the local is initialized when the callee reads it:
accepted.

  $ cat > call-tee.wax <<'WAX'
  > type FT = fn(&FT);
  > fn f(g: &FT) {
  >   let k: &FT;
  >   k((k := g));
  > }
  > WAX
  $ wax check call-tee.wax

The callee is now typed first, so its parameter types direct the arguments even
for a callee form no syntactic peek could resolve — here a call returning a
funcref — letting a name-less struct-literal argument that is otherwise ambiguous
(both [P] and [Q] have field [x]) infer its type from the parameter.

  $ cat > call-infer.wax <<'WAX'
  > type P = { x: i32 };
  > type Q = { x: i32 };
  > type FT = fn(&P);
  > fn pick(g: &FT) -> &FT { return g; }
  > fn f(g: &FT) {
  >   pick(g)({ x: 0 });
  > }
  > WAX
  $ wax check call-infer.wax

Nested trailing operands compose: the outer call's callee is itself a call whose
own callee reads the local, and the outer argument (emitted first) tees it. The
inner read is deferred, re-checked at its emission slot, still uninitialized
there, so re-deferred to the outer collector, and finally rescued by the outer
argument's tee: accepted, and it lowers with the tee emitted before the read.

  $ cat > call-nested.wax <<'WAX'
  > type FT = fn(&FT) -> &FT;
  > fn f(g: &FT) -> &FT {
  >   let k: &FT;
  >   return k(g)(k := g);
  > }
  > WAX
  $ wax call-nested.wax -f wat
  (type $FT (func (param (ref $FT)) (result (ref $FT))))
  (func $f (param $g (ref $FT)) (result (ref $FT))
    (local $k (ref $FT))
    (return
      (call_ref $FT (local.tee $k (local.get $g))
        (call_ref $FT (local.get $g) (local.get $k))))
  )

Holes still slice correctly: a hole flows into a call argument (leaving the
callee its own slice) and into a [struct.new_desc] field.

  $ cat > call-hole.wax <<'WAX'
  > type FT = fn(i32);
  > fn f(g: &FT) {
  >   1;
  >   g;
  >   (_)(_);
  > }
  > WAX
  $ wax call-hole.wax -f wat
  (type $FT (func (param i32)))
  (func $f (param $g (ref $FT)) (i32.const 1) (local.get $g) (call_ref $FT))

  $ cat > desc-hole.wax <<'WAX'
  > #![feature = "custom-descriptors"]
  > rec {
  >   type a = descriptor b { link: &b };
  >   type b = describes a { };
  > }
  > fn f(v1: &b) -> &a {
  >   v1;
  >   let r: &a = { descriptor({b| }) | link: _ };
  >   return r;
  > }
  > WAX
  $ wax -X custom-descriptors desc-hole.wax -f wat
  (@feature "custom-descriptors")
  (rec
    (type $a (descriptor $b) (struct (field $link (ref $b))))
    (type $b (describes $a) (struct))
  )
  (func $f (param $v1 (ref $b)) (result (ref $a))
    (local $r (ref $a))
    (local.get $v1)
    (local.set $r (struct.new_desc $a (struct.new $b)))
    (return (local.get $r))
  )
