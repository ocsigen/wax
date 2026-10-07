A field access outside a conditional annotation is converted once for every
configuration, from the struct type its value has in one of them. Here make()
returns an s1 in one configuration and an s2 in the other, and s2 has the
field f at another position: struct.get $s1 $f is valid on an s2, but reads
its field a. Each configuration is fine on its own, so check accepts it;
converting the module unresolved rejects it.

  $ wax check moved.wax
  $ wax -f wat moved.wax
  Error:
    The field 'f' is at a different position in the struct types this value has
    under different conditional annotations, so this access has no single
    WebAssembly form.
    ──➤  moved.wax:17:12
  15 │ #[export]
  16 │ fn get() -> i32 {
  17 │     return make().f;
     ·            ^^^^^^^^
  18 │ }
  19 │ 
  Hint:
    Access it in the branches of a conditional, or resolve the conditionals with
    -D.
  [128]
  $ wax -D p=false -f wat moved.wax
  (type $s1 (sub (struct (field $f i32))))
  (type $s2 (sub final $s1 (struct (field $a i32) (field $f i32))))
  (func $make (result (ref $s2))
    (return (struct.new $s2 (i32.const 1) (i32.const 2)))
  )
  (func $get (export "get") (result i32)
    (return (struct.get $s2 $f (call $make)))
  )

Where the field is at the same position in every configuration, the access
converts.

  $ wax check same.wax
  $ wax -f wat same.wax
  (type $s1 (sub (struct (field $f i32))))
  (type $s2 (sub final $s1 (struct (field $f i32) (field $g i32))))
  (@if $p
    (@then
      (func $make (result (ref $s1)) (return (struct.new $s1 (i32.const 1)))))
    (@else
      (func $make (result (ref $s2))
        (return (struct.new $s2 (i32.const 1) (i32.const 2)))))
  )
  (func $get (export "get") (result i32)
    (return (struct.get $s1 $f (call $make)))
  )
