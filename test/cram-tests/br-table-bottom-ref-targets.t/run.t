A `br_table` checks its one set of operands against *every* target label, and a
bottom reference (here `_!`, a non-null hole taken off the polymorphic stack of
dead code) is a subtype of each. Its targets can legitimately have different
reference types — a `&func` label and a `&t` label — so the operand must not be
pinned to the first target's type: doing so would make the check against a later,
differently-typed target fail. The typer therefore checks a `br_table`'s values
without pinning (`~pin:false`), so the module is accepted whatever the target
order.

  $ cat > t.wax <<'EOF'
  > type t = fn();
  > #[export]
  > fn f() -> &?func {
  >     'a: do &?func {
  >         'b: do &t {
  >             unreachable;
  >             br_table [ 'a, else 'b ] (_!, 0);
  >         }
  >     }
  > }
  > EOF
  $ wax -i wax t.wax -f wat --validate -W dead-code=hidden
  (type $t (func))
  (func $f (export "f") (result funcref)
    (block $a (result funcref)
      (block $b (result (ref $t))
        (unreachable)
        (br_table $a $b (ref.as_non_null) (i32.const 0))))
  )

The reverse target order (`&t` first, `&func` second) is accepted too — before
the `~pin:false` fix the bottom reference was pinned to `&t` by the first target
and then wrongly rejected against the `&?func` target.

  $ cat > t2.wax <<'EOF'
  > type t = fn();
  > #[export]
  > fn f() -> &?func {
  >     'a: do &?func {
  >         'b: do &t {
  >             unreachable;
  >             br_table [ 'b, else 'a ] (_!, 0);
  >         }
  >     }
  > }
  > EOF
  $ wax -i wax t2.wax -f wat --validate -W dead-code=hidden
  (type $t (func))
  (func $f (export "f") (result funcref)
    (block $a (result funcref)
      (block $b (result (ref $t))
        (unreachable)
        (br_table $b $a (ref.as_non_null) (i32.const 0))))
  )
