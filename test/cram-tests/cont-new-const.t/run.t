`cont.new` allocates a fresh continuation from a (constant) function reference,
so it is itself a constant expression and may appear in a global initializer.
(This tracks the open stack-switching spec PR; the spec and reference tools do
not list it yet.)

  $ wax check global.wat

It round-trips through the binary form, keeping the initializer:

  $ wax -i wat -f wat global.wat
  (type $ft (func))
  (type $ct (cont $ft))
  (func $g)
  (global (export "c") (ref $ct) (cont.new $ct (ref.func $g)))
  (elem declare func $g)

`cont.bind` is not a constant expression (it operates on an existing
continuation), so it is still rejected in an initializer:

  $ wax check bind.wat
  Error: Only constant expressions are allowed here.
    ──➤  bind.wat:8:23
   6 │   (func $g (param i32))
   7 │   (global $c (ref $ct) (cont.new $ct (ref.func $g)))
   8 │   (global (ref $ct2) (cont.bind $ct $ct2 (i32.const 0) (global.get $c)))
     ·                       ^^^^^^^^^^^^^^^^^^
   9 │   (elem declare func $g))
  10 │ 
  [128]

The Wax typer mirrors the rule: `cont_new` is allowed in a `const` global.

  $ wax check const.wax

  $ wax const.wax -f wat
  (type $ft (func))
  (type $k (cont $ft))
  
  (func $g)
  
  (global $C (ref $k) (cont.new $k (ref.func $g)))
  
  (func $use_it (result (ref $k)) (return (global.get $C)))



