(module
  (@if $oxcaml
    (@then
      (func $a (result i32) (i32.const 1)))
    (@else
      (func $a (result i32) (i32.const 2))))
  (func $f (result i32)
    (@if (and $oxcaml
              (or (= $ocaml_version (5 2 0))
                  (<> $flavour "default")
                  (< $a (1 0 0))
                  (> $b (2 0 0))
                  (<= $c (3 0 0))
                  (>= $d (4 0 0))))
      (@then
        (@if (not $debug)
          (@then
            (nop)))
        (i32.const 1))
      (@else
        (i32.const 2)))))
