;; Host "spectest" module for the linker test harness (bin/run_link_testsuite.ml).
;;
;; The WebAssembly reference interpreter provides a built-in "spectest" module
;; whose exports the spec test suite imports from. We are a static merge linker
;; with no host, so we supply an equivalent module and register it as
;; "spectest" before linking each script. Only the *types* of these exports
;; matter for linking (the bodies/values are never run), so functions have
;; empty bodies and globals use arbitrary constants.
;;
;; The surface mirrors the reference interpreter's spectest module and covers
;; every "spectest" import used across test/wasm-test-suite/core. Note that
;; "unknown" is deliberately absent — the "unknown import" unlinkable tests
;; rely on it not existing.
(module
  (func (export "print"))
  (func (export "print_i32") (param i32))
  (func (export "print_i64") (param i64))
  (func (export "print_f32") (param f32))
  (func (export "print_f64") (param f64))
  (func (export "print_i32_f32") (param i32 f32))
  (func (export "print_f64_f64") (param f64 f64))

  (global (export "global_i32") i32 (i32.const 666))
  (global (export "global_i64") i64 (i64.const 666))
  (global (export "global_f32") f32 (f32.const 666))
  (global (export "global_f64") f64 (f64.const 666))

  (table (export "table") 10 20 funcref)
  (table (export "table64") i64 10 20 funcref)

  (memory (export "memory") 1 2)
)
