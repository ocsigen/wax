(module
  ;; Two branches importing different sets of functions, in different orders,
  ;; with a shared $id ($g) in both. Names must stay attached to the right
  ;; import (the converter must visit @then before @else, matching the order
  ;; names were registered).
  (@if $wasi
    (@then
      (import "a" "x" (func $x (result i32)))
      (import "a" "g" (func $g (result i32))))
    (@else
      (import "b" "y" (func $y (result i32)))
      (import "b" "g" (func $g (result i32)))
      (import "b" "z" (func $z (result i32)))))
  ;; A sibling conditional on the negated condition. $h is defined and used
  ;; only when (not $wasi); the explorer must not build the infeasible
  ;; $wasi & (not $wasi) configuration where $h would be used but undefined.
  (@if (not $wasi)
    (@then (func $h (result i32) (call $g))))
  (func $f (result i32) (call $g)))
