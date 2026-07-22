Create a standard library Wasm module and compile it:
  $ cat > std.wat <<EOF
  > (module
  >   (func (export "hello") (result i32)
  >     i32.const 42
  >   )
  > )
  > EOF
  $ wax std.wat -o std.wasm

Create a main module importing std:hello and compile it:
  $ cat > main.wat <<EOF
  > (module
  >   (import "std" "hello" (func \$hello (result i32)))
  >   (func (export "start") (result i32)
  >     call \$hello
  >   )
  > )
  > EOF
  $ wax main.wat -o main.wasm

Link main and std together:
  $ wax link -o linked.wasm main:main.wasm std:std.wasm

Disassemble the linked output to verify it resolves and compiles correctly:
  $ wax linked.wasm -f wat
  (type (func (result i32)))
  (func (result i32)
    call 1
  )
  (func (result i32)
    i32.const 42
  )
  (export "start" (func 0))
  (export "hello" (func 1))

Link with a non-wasm file (should fail with a clean diagnostic error message):
  $ echo "not a Wasm binary" > invalid.wasm
  $ wax link -o invalid_linked.wasm main:invalid.wasm std:std.wasm
  Error: magic header not detected
   ──➤  invalid.wasm:1:1
  1 │ not a Wasm binary
    · ^
  2 │ 
  [128]

Link with duplicate exports (should fail with duplicated export error):
  $ cat > duplicate1.wat <<EOF
  > (module (func (export "foo")))
  > EOF
  $ cat > duplicate2.wat <<EOF
  > (module (func (export "foo")))
  > EOF
  $ wax duplicate1.wat -o duplicate1.wasm
  $ wax duplicate2.wat -o duplicate2.wasm
  $ wax link -o duplicate_linked.wasm m1:duplicate1.wasm m2:duplicate2.wasm
  Error:
    Duplicated export "foo" found in multiple input modules: "duplicate1.wasm"
    and "duplicate2.wasm".
  [128]

Link with incompatible types (should fail with incompatible type error):
  $ cat > incompatible1.wat <<EOF
  > (module (import "m2" "foo" (func (param i32))))
  > EOF
  $ cat > incompatible2.wat <<EOF
  > (module (func (export "foo") (param i64)))
  > EOF
  $ wax incompatible1.wat -o incompatible1.wasm
  $ wax incompatible2.wat -o incompatible2.wasm
  $ wax link -o incompatible_linked.wasm m1:incompatible1.wasm m2:incompatible2.wasm
  Error:
    In module "incompatible1.wasm", the import "m2" / "foo" refers to an export
    in module "incompatible2.wasm" of an incompatible type.
  [128]

Link with an import loop (should fail with import loop error):
  $ cat > loop1.wat <<EOF
  > (module (import "m2" "foo" (func)) (export "foo" (func 0)))
  > EOF
  $ cat > loop2.wat <<EOF
  > (module (import "m1" "foo" (func)) (export "foo" (func 0)))
  > EOF
  $ wax loop1.wat -o loop1.wasm
  $ wax loop2.wat -o loop2.wasm
  $ wax link -o loop_linked.wasm m1:loop1.wasm m2:loop2.wasm
  Error: Import loop on "m1" / "foo".
  [128]

Link two modules with branch hints and verify hints are merged and preserved at correct locations:
  $ cat > hints1.wat <<EOF
  > (module
  >   (func (export "f1") (param i32) (result i32)
  >     local.get 0
  >     (@metadata.code.branch_hint "\01")
  >     if (result i32)
  >       i32.const 10
  >     else
  >       i32.const 20
  >     end)
  > )
  > EOF
  $ cat > hints2.wat <<EOF
  > (module
  >   (func (export "f2") (param i32)
  >     block
  >       local.get 0
  >       (@metadata.code.branch_hint "\00") br_if 0
  >     end)
  > )
  > EOF
  $ wax hints1.wat -o hints1.wasm
  $ wax hints2.wat -o hints2.wasm
  $ wax link -o hints_linked.wasm m1:hints1.wasm m2:hints2.wasm
  $ wax hints_linked.wasm -f wat
  (type (func (param i32) (result i32)))
  (type (func (param i32)))
  (type (func))
  (func (param i32) (result i32)
    local.get 0
    (@metadata.code.branch_hint "\01")
    if (result i32)
      i32.const 10
    else
      i32.const 20
    end
  )
  (func (param i32)
    block (type 2)
      local.get 0
      (@metadata.code.branch_hint "\00") br_if 0
    end
  )
  (export "f1" (func 0))
  (export "f2" (func 1))
