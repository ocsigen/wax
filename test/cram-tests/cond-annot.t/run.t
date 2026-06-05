Conditional annotations (@if/@then/@else) are parsed and preserved through a
WAT round-trip, both at the instruction level and the module-field level.

  $ wax cond.wat -o out.wat && cat out.wat
  (@if $oxcaml (@then (func $a (result i32) (i32.const 1)) )
  (@else (func $a (result i32) (i32.const 2)) ) )
  (func $f (result i32)
    (@if
    (and
      $oxcaml
      (or
        (= $ocaml_version (5 2 0))
        (<> $flavour "default")
        (< $a (1 0 0))
        (> $b (2 0 0))
        (<= $c (3 0 0))
        (>= $d (4 0 0))))
    (@then (@if (not $debug) (@then (nop) ) ) (i32.const 1) )
    (@else (i32.const 2) ) )
  )

The output round-trips to itself (it is idempotent).

  $ wax out.wat -o out2.wat && diff out.wat out2.wat

They cannot be lowered to the binary format.

  $ wax cond.wat -o out.wasm
  wax: internal error, uncaught exception:
       Failure("Conditional annotations are not supported in binary output.")
       
  [125]
