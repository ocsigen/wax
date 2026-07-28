Like a resume operand (see resume-operand-inferred-block.t), a `suspend` payload
and a `cont.bind` bound operand that are unannotated blocks whose result is
inferable must lower the same as the explicitly annotated form: the block is the
expression the instruction consumes, so its inferred result is materialized onto
the block and flows into the trailing `try_table`'s result. Both once compiled
(check accepted) but failed to lower ("expecting 1 returned value, but 0"); now
they lower to the same wasm the annotated form does.

`suspend` takes its operand types from the tag (an immediate, so no reordering):

  $ wax -i wax -f wat suspend.wax
  (type $ff (func))
  (type $yt (func (param exnref)))
  (tag $yield (type $yt))
  (func $h (export "h")
    (suspend $yield
      (block $h (result exnref)
        (try_table (result exnref) (catch_ref $e0 $h) (throw $e0))))
  )
  (tag $e0 (type $ff))

`cont.bind` takes them from the source continuation (the last operand), so it is
typed first, as a resume receiver is:

  $ wax -i wax -f wat bind.wax
  (type $ff (func))
  (type $inner (func (param exnref)))
  (type $ki (cont $inner))
  (type $outer (func))
  (type $ko (cont $outer))
  (func $h (export "h") (param $c (ref $ki)) (result (ref $ko))
    (cont.bind $ki $ko
      (block $h (result exnref)
        (try_table (result exnref) (catch_ref $e0 $h) (throw $e0)))
      (local.get $c))
  )
  (tag $e0 (type $ff))

Both also lower to a binary (wax validates the emission).

  $ wax -i wax -f wasm suspend.wax -o s.wasm && wax -i wax -f wasm bind.wax -o b.wasm && echo ok
  ok
