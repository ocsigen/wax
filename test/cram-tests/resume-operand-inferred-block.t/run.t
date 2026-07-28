A stack-switching value operand that is an unannotated `do`-block whose result is
inferable (here `'h: do { … }`, whose only exit is a caught `exnref` branched to
`'h`) must lower the same as the explicitly annotated `'h: do &?exn { … }`. The
operand is an expression `resume_throw_ref` consumes, so its inferred result is
materialized onto the block and flows into the trailing `try_table`'s result —
`(try_table (result exnref) …)` — which its unreachable `throw` body satisfies.
Previously `check` accepted this but lowering rejected it ("expecting 1 returned
value, but 0"), because Typing typed the operand as a statement and never
materialised the result the emitter needed. Found by fuzz/mutate-wax.

  $ wax -i wax -f wat m.wax
  (type $f (func))
  (type $k (cont $f))
  (func $no_handler (unreachable))
  (func $g (export "g")
    (resume_throw_ref $k
      (block $h (result exnref)
        (try_table (result exnref) (catch_ref $e0 $h) (throw $e0)))
      (cont.new $k (ref.func $no_handler)))
  )
  (tag $e0 (type $f))
  (elem declare func $no_handler)

It also lowers to a binary (wax validates the emission), where it once failed.

  $ wax -i wax -f wasm m.wax -o m.wasm && echo ok
  ok
