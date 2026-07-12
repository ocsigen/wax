The linker rewrites the "name" custom section of every input, remapping each
index into the merged module's index space. Engines ignore a malformed name
section, so this is checked here by linking two richly-named modules and reading
the names back with the disassembler (`-f wat`), an independent decode path from
the linker's name-section writer.

`std` defines named functions (with named params/locals and a labelled block), a
named struct type with named fields, a named global, table, memory and tag:
  $ cat > std.wat <<EOF
  > (module
  >   (type \$Pair (struct (field \$fst i32) (field \$snd i32)))
  >   (global \$base (mut i32) (i32.const 7))
  >   (table \$t 1 funcref)
  >   (memory \$m 1)
  >   (tag \$err (param i32))
  >   (func \$helper (param \$x i32) (result i32)
  >     (local \$acc i32)
  >     (block \$chk)
  >     local.get \$x
  >     local.set \$acc
  >     local.get \$acc
  >     global.get \$base
  >     i32.add)
  >   (func \$exported (result i32)
  >     i32.const 1
  >     call \$helper)
  >   (export "helper" (func \$helper))
  >   (export "run" (func \$exported)))
  > EOF
  $ wax std.wat -o std.wasm

`main` imports std:helper (resolved away by linking) and adds its own named type,
global, function and locals, so its own definitions land at remapped indices:
  $ cat > main.wat <<EOF
  > (module
  >   (import "std" "helper" (func \$helper (param i32) (result i32)))
  >   (type \$Vec (struct (field \$len i32)))
  >   (global \$scale (mut i32) (i32.const 3))
  >   (func \$compute (param \$in i32) (result i32)
  >     (local \$doubled i32)
  >     (block \$step)
  >     local.get \$in
  >     local.get \$in
  >     i32.add
  >     local.set \$doubled
  >     local.get \$doubled
  >     call \$helper)
  >   (func \$main (result i32)
  >     i32.const 10
  >     call \$compute)
  >   (export "main" (func \$main)))
  > EOF
  $ wax main.wat -o main.wasm

  $ wax link -o linked.wasm std:std.wasm main:main.wasm

Every name survives at its remapped index: `main`'s type ($Vec), global ($scale),
functions ($compute, $main), locals ($in, $doubled) and label ($step) are placed
after `std`'s definitions, and the resolved import leaves a single $helper (no
dangling duplicate). Labels ($chk, $step) exercise the indirect name map's outer
index; the empty labelled blocks are there only to carry a label name:
  $ wax linked.wasm -f wat
  (type $Pair (struct (field $fst i32) (field $snd i32)))
  (type (func (param i32) (result i32)))
  (type (func (result i32)))
  (type (func))
  (type (func (param i32)))
  (type $Vec (struct (field $len i32)))
  (func $helper (param $x i32) (result i32)
    (local $acc i32)
    block $chk (type 3)
    end
    local.get $x
    local.set $acc
    local.get $acc
    global.get $base
    i32.add
  )
  (func $exported (result i32)
    i32.const 1
    call $helper
  )
  (func $compute (param $in i32) (result i32)
    (local $doubled i32)
    block $step (type 3)
    end
    local.get $in
    local.get $in
    i32.add
    local.set $doubled
    local.get $doubled
    call $helper
  )
  (func $main (result i32)
    i32.const 10
    call $compute
  )
  (table $t 1 funcref)
  (memory $m 1)
  (global $base (mut i32)
    i32.const 7
  )
  (global $scale (mut i32)
    i32.const 3
  )
  (export "helper" (func $helper))
  (export "run" (func $exported))
  (export "main" (func $main))
  (tag $err (type 4))

  $ wax -v -f wasm -o /dev/null linked.wasm && echo OK
  OK

Function names whose *output* index crosses the 128 LEB-width boundary. A small
module placed first shifts a 130-function module's indices up by three, so
$f125..$f129 land at output indices 128..132. Their names must still round-trip:
  $ cat > small.wat <<EOF
  > (module (func \$s0) (func \$s1) (func \$s2) (export "s" (func \$s0)))
  > EOF
  $ wax small.wat -o small.wasm
  $ (echo "(module"; for i in $(seq 0 129); do echo "  (func \$f$i)"; done; echo "  (export \"last\" (func \$f129)))") > big.wat
  $ wax big.wat -o big.wasm
  $ wax link -o big_linked.wasm s:small.wasm b:big.wasm
  $ wax big_linked.wasm -f wat | grep -E '^\(func \$f12[5-9]\)$'
  (func $f125)
  (func $f126)
  (func $f127)
  (func $f128)
  (func $f129)
  $ wax big_linked.wasm -f wat | grep 'export "last"'
  (export "last" (func $f129))
