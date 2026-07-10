# wasm-tools self-checking test corpus

Vendored `.wast` scripts from the [wasm-tools](https://github.com/bytecodealliance/wasm-tools)
project's `tests/cli/` tree — the subset that carries spec assertions
(`assert_invalid` / `assert_malformed` / `assert_return` / `assert_trap`), so
each file is self-checking: the assertions are the ground truth, independent of
any single validator's leniency.

These complement `test/wasm-test-suite/` (the upstream WebAssembly spec suite)
with the hand-written edge cases and regression crashers the wasm-tools
maintainers added. They are run by `run_wasm_testsuite`, which honours the
assertions and records deviations in `test/wasm_tools_suite.expected`.

Component-model, feature-gating (`missing-features/`) and the plain `spec/`
copies were excluded (not core wasm, or duplicates of the vendored spec suite).

Source: wasm-tools 1.246.2 (commit 4c40f5195521abb47667b7ddd922464f9a72720b).
Licensed under Apache-2.0-WITH-LLVM-exception OR Apache-2.0 OR MIT; see the
LICENSE-* files in this directory.
