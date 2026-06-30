(module
  (tag $e)
  ;; The do block's value (inner * inner) is naturally i32 — the binding's i32
  ;; annotation is redundant and drops.
  (func $drops (export "drops") (param $x i32) (result i32)
    (local $outer i32) (local $inner i32)
    (local.set $outer
      (block (result i32)
        (local.set $inner (i32.add (local.get $x) (i32.const 1)))
        (i32.mul (local.get $inner) (local.get $inner))))
    (local.get $outer))
  ;; The do block's value is a bare i64 literal, which would default to i32 on
  ;; its own — the i64 annotation is doing real work, so it is kept.
  (func $keeps (export "keeps") (result i64)
    (local $x i64)
    (local.set $x (block (result i64) (i64.const 42)))
    (local.get $x))
  ;; The value can also arrive by a branch to the block's label; that delivered
  ;; value is still a subtype of the result, so when the fall-through ($n) is
  ;; already i64 the annotation drops anyway.
  (func $br_drops (export "br_drops") (param $c i32) (param $n i64) (result i64)
    (local $x i64)
    (local.set $x
      (block $l (result i64)
        (if (local.get $c) (then (br $l (i64.const 42))))
        (local.get $n)))
    (local.get $x))
  ;; A try's catch handler likewise produces a subtype of the result, so it does
  ;; not change the inference: the body's fall-through ($n) is already i64, so
  ;; the annotation drops.
  (func $try_drops (export "try_drops") (param $n i64) (result i64)
    (local $x i64)
    (local.set $x
      (try (result i64) (do (local.get $n)) (catch $e (i64.const 0))))
    (local.get $x))
  ;; The value reaches the block only by a branch to its label; the fall-through
  ;; diverges (unreachable), so there is nothing on the stack to read. The
  ;; branched value ($n, already i64) is still collected at its natural type, so
  ;; the annotation drops anyway.
  (func $divergent_drops (export "divergent_drops") (param $n i64) (result i64)
    (local $x i64)
    (local.set $x
      (block $l (result i64) (br $l (local.get $n)) (unreachable)))
    (local.get $x))
  ;; The trailing value is itself a nested block; it synthesizes its own type
  ;; ($n, i64) rather than being forced to the context, so the annotation drops.
  (func $nested_block_drops (export "nested_block_drops") (param $n i64)
    (result i64)
    (local $x i64)
    (local.set $x
      (block (result i64) (block (result i64) (local.get $n))))
    (local.get $x))
  ;; The try's body diverges (it returns), so the value comes only from the catch
  ;; handler; that handler's value ($n, already i64) is collected too, so the
  ;; annotation drops.
  (func $try_handler_drops (export "try_handler_drops") (param $n i64)
    (result i64)
    (local $x i64)
    (local.set $x
      (try (result i64) (do (return (local.get $n))) (catch $e (local.get $n))))
    (local.get $x)))
