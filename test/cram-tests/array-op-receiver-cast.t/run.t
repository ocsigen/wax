The array operations array.len / array.fill / array.copy / array.init carry no
self-resolving type for their array receiver, so when the receiver is a value
taken off a polymorphic stack (unreachable code) its type cannot be determined
and the method fails to resolve. The decompiler now ascribes the receiver — the
array type from the instruction's immediate (or the abstract `&?array` for
array.len, which has none) — so the call type-checks; a redundant cast on a
concrete receiver is dropped by simplify. Previously these failed with "Cannot
determine the type of this expression". Regression: differential-validation fuzzer.

  $ cat > al.wat <<'WAT'
  > (module
  >   (type $a (array i32))
  >   (func (export "f") (result i32)
  >     unreachable
  >     array.len))
  > WAT
  $ wax -i wat -f wax al.wat
  type a = [i32];
  #[export]
  fn f() -> i32 {
      unreachable;
      (_ as &?array).length();
  }
  $ wax -i wat -f wax al.wat -o al.wax && wax -i wax -f wasm al.wax -o /dev/null --validate

  $ cat > af.wat <<'WAT'
  > (module
  >   (type $a (array (mut i32)))
  >   (func (export "g")
  >     unreachable
  >     array.fill $a))
  > WAT
  $ wax -i wat -f wax af.wat
  type a = [mut i32];
  #[export]
  fn g() {
      unreachable;
      (_ as &?a).fill(_, _, _);
  }
  $ wax -i wat -f wax af.wat -o af.wax && wax -i wax -f wasm af.wax -o /dev/null --validate
