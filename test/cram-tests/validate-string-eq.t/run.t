Validating a module that uses an unnamed string (`@string`, whose implicit
`[mut i8]` array type the module does not otherwise declare) where a heap type
is expected must not crash: the validator now pre-registers that type, so the
`<string>` heap-subtype check resolves instead of indexing out of bounds.

  $ wax convert --validate --format wat s.wax
  (func $f (param $c i32) (result (ref eq))
    (if (result (ref eq)) (local.get $c)
      (then (@string "x"))
      (else (ref.cast (ref eq) (ref.null eq))))
  )
