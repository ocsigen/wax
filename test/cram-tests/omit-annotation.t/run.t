A struct or array literal may omit its type name when the type is supplied by an
expected type (a let/const annotation, parameter, field, …) or — for a struct —
inferred from its set of fields when exactly one type matches:

  $ wax check ok.wax

When the field set matches several struct types, the literal is ambiguous and
the type cannot be inferred:

  $ wax check ambiguous-struct.wax
  Error:
    Cannot infer the struct type here; add an explicit type, as in '{T| ..}'.
   ──➤  ambiguous-struct.wax:6:13
  4 │ // {x, y} matches two struct types, so the literal is ambiguous.
  5 │ fn f() -> &point {
  6 │     let p = {x: 1, y: 2,};
    ·             ^^^^^^^^^^^^^
  7 │     return p;
  8 │ }
  [123]

The same holds for a global, and its use does not cascade into a second error:

  $ wax check ambiguous-global.wax
  Error:
    Cannot infer the struct type here; add an explicit type, as in '{T| ..}'.
   ──➤  ambiguous-global.wax:6:11
  4 │ // As for a local, an ambiguous global initializer is reported once: the global
  5 │ // becomes poison, so its use does not cascade into a second error.
  6 │ const g = {x: 1, y: 2,};
    ·           ^^^^^^^^^^^^^
  7 │ 
  8 │ fn use_g() -> &point {
  [123]

An array literal has no field-based inference, so with no expected type its
element type cannot be inferred either:

  $ wax check no-array-context.wax
  Error:
    Cannot infer the array type here; add an explicit type, as in '[T| ..]'.
   ──➤  no-array-context.wax:4:13
  2 │ 
  3 │ fn f() -> &ints {
  4 │     let a = [0; 8];
    ·             ^^^^^^
  5 │     return a;
  6 │ }
  [123]
