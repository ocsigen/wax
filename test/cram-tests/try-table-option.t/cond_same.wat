(module
  (@if $wide
    (@then (tag $e (param i32)))
    (@else (tag $e (param i32))))
  (func
    try
    catch $e
      drop
    catch_all
    end))
