(module
  (@if $debug
    (@then
      (func $f (result i32)
        (@if (not $debug) (@then i32.const 1) (@else i32.const 2)))))
  (@if (and $fast (not $fast)) (@then (func $never))))
