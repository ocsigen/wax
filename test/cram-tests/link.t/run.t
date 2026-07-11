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

Link two modules with source maps and verify instruction boundaries match:
  $ cat > map1.wat <<EOF
  > (module
  >   (func (export "f1") (param i32) (result i32)
  >     local.get 0
  >     i32.const 2
  >     i32.add)
  > )
  > EOF
  $ cat > map2.wat <<EOF
  > (module
  >   (func (export "f2") (param i32) (result i32)
  >     local.get 0
  >     i32.const 3
  >     i32.mul)
  > )
  > EOF
  $ wax map1.wat -o map1.wasm --source-map
  $ wax map2.wat -o map2.wasm --source-map
  $ wax link -o map_linked.wasm --source-map-file map_linked.wasm.map m1:map1.wasm m2:map2.wasm
  $ ../../check-sourcemap/check_sourcemap.exe map_linked.wasm map_linked.wasm.map map1.wasm map2.wasm
  Instruction-boundary source map verification successful!

Name-aware type coalescing (--distinct-named-types). Two modules define a
structurally-identical struct under different type and field names:
  $ cat > ta.wat <<EOF2
  > (module
  >   (type \$Point (struct (field \$x i32) (field \$y i32)))
  >   (func (export "mk_a") (result (ref \$Point))
  >     (struct.new \$Point (i32.const 1) (i32.const 2))))
  > EOF2
  $ cat > tb.wat <<EOF2
  > (module
  >   (type \$Pt (struct (field \$a i32) (field \$b i32)))
  >   (func (export "mk_b") (result (ref \$Pt))
  >     (struct.new \$Pt (i32.const 3) (i32.const 4))))
  > EOF2
  $ wax ta.wat -o ta.wasm
  $ wax tb.wat -o tb.wasm

By default the two structs are merged structurally into a single type; both
functions reference it and tb's names are dropped:
  $ wax link -o tdef.wasm a:ta.wasm b:tb.wasm
  $ wax tdef.wasm -f wat | grep -E 'type |struct.new'
  (type $Point (struct (field $x i32) (field $y i32)))
  (type (func (result (ref $Point))))
    struct.new $Point
    struct.new $Point

With --distinct-named-types the differently-named struct is kept as a separate,
structurally-identical copy so its names survive:
  $ wax link --distinct-named-types -o tdist.wasm a:ta.wasm b:tb.wasm
  $ wax tdist.wasm -f wat | grep -E 'type |struct.new'
  (type $Point (struct (field $x i32) (field $y i32)))
  (type (func (result (ref $Point))))
  (type $Pt (struct (field $a i32) (field $b i32)))
  (type (func (result (ref $Pt))))
    struct.new $Point
    struct.new $Pt

The result still validates:
  $ wax -v -f wasm -o /dev/null tdist.wasm && echo OK
  OK
