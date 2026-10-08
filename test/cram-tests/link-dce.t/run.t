Dead code elimination in the linker (`wax link --dependencies`). The dependency
graph uses the JSON format of binaryen's wasm-metadce: the exports reachable from
its root nodes are kept, together with what they use.

`std` provides a function `main` uses, and several entities nothing uses: a
function, a global, a type only the dead function uses, a passive data segment
and an import:
  $ cat > std.wat <<EOF
  > (module
  >   (type \$unused (struct (field i64)))
  >   (import "env" "dead_import" (func \$dead_import))
  >   (global \$dead_global (mut i32) (i32.const 1))
  >   (memory 1)
  >   (data \$dead_data "dead")
  >   (func \$used (export "used") (result i32) (i32.const 42))
  >   (func \$dead (export "dead") (result i32)
  >     (call \$dead_import)
  >     (drop (struct.new \$unused (i64.const 0)))
  >     (memory.init \$dead_data (i32.const 0) (i32.const 0) (i32.const 4))
  >     (global.get \$dead_global)))
  > EOF
  $ cat > main.wat <<EOF
  > (module
  >   (import "std" "used" (func \$used (result i32)))
  >   (func (export "main") (result i32) (call \$used)))
  > EOF
  $ wax std.wat -o std.wasm
  $ wax main.wat -o main.wasm
  $ cat > deps.json <<EOF
  > [{"name": "root", "reaches": ["main"], "root": true},
  >  {"name": "main", "export": "main"}]
  > EOF

Without the dependency graph, everything is kept:
  $ wax link -o all.wasm main:main.wasm std:std.wasm
  $ wax all.wasm -f wat | grep -c dead
  8

With it, only `main` and what it uses remain:
  $ wax link --dependencies deps.json -o main_only.wasm main:main.wasm std:std.wasm
  $ wax main_only.wasm -f wat
  (type (func (result i32)))
  (func (result i32)
    call $used
  )
  (func $used (result i32)
    i32.const 42
  )
  (memory 1)
  (export "main" (func 0))
  $ wax -v -f wasm -o /dev/null main_only.wasm && echo OK
  OK

An import node of the graph is reached when the import is used, and keeps the
exports it reaches: here, the JavaScript side of `env.dead_import` calls back
into `used`. Exports not reached are removed:
  $ cat > deps2.json <<EOF
  > [{"name": "root", "reaches": ["dead"], "root": true},
  >  {"name": "dead", "export": "dead"},
  >  {"name": "used", "export": "used"},
  >  {"name": "callback", "import": ["env", "dead_import"], "reaches": ["used"]}]
  > EOF
  $ wax link --dependencies deps2.json -o dead.wasm std:std.wasm
  $ wax dead.wasm -f wat | grep -E 'import|export'
  (import "env" "dead_import" (func $dead_import))
    call $dead_import
  (export "used" (func $used))
  (export "dead" (func $dead))

A function referenced by `ref.func` must be declared (in an element segment, a
table initializer, an export or a global initializer). When the only declarations are removed, the
linker declares it in a declarative element segment:
  $ cat > decl.wat <<EOF
  > (module
  >   (type \$t (func (result i32)))
  >   (func \$h (export "h") (result i32) (i32.const 6))
  >   (global \$g funcref (ref.func \$h))
  >   (func (export "main") (result i32) (call_ref \$t (ref.func \$h))))
  > EOF
  $ wax decl.wat -o decl.wasm
  $ wax link --dependencies deps.json -o decl_linked.wasm a:decl.wasm
  $ wax decl_linked.wasm -f wat | grep -E 'elem|export|global'
  (export "main" (func 1))
  (elem declare func $h)
  $ wax -v -f wasm -o /dev/null decl_linked.wasm && echo OK
  OK

A table initializer declares the functions it refers to, so no declarative
segment is added for them:
  $ cat > tabinit.wat <<EOF
  > (module
  >   (type \$t (func (result i32)))
  >   (func \$h (result i32) (i32.const 6))
  >   (table 1 funcref (ref.func \$h))
  >   (func (export "main") (result i32) (call_ref \$t (ref.func \$h))))
  > EOF
  $ wax tabinit.wat -o tabinit.wasm
  $ wax link --dependencies deps.json -o tabinit_linked.wasm a:tabinit.wasm
  $ wax tabinit_linked.wasm -f wat | grep -E 'elem|table'
  (table 1 funcref
  $ wax -v -f wasm -o /dev/null tabinit_linked.wasm && echo OK
  OK

A passive segment which is not used only keeps the live functions it mentions,
as declarations. A segment of expressions becomes a segment of function
indices, since its type may be removed:
  $ cat > passive.wat <<EOF
  > (module
  >   (type \$t (func (result i32)))
  >   (type \$u (func (result i64)))
  >   (func \$h (result i32) (i32.const 6))
  >   (func \$dead (result i32) (i32.const 7))
  >   (func \$dead2 (result i64) (i64.const 8))
  >   (elem (ref null \$t) (item (ref.func \$h)) (item (ref.func \$dead)) (item (ref.null \$t)))
  >   (elem (ref null \$u) (item (ref.func \$dead2)))
  >   (func (export "main") (result i32) (call_ref \$t (ref.func \$h))))
  > EOF
  $ wax passive.wat -o passive.wasm
  $ wax link --dependencies deps.json -o passive_linked.wasm a:passive.wasm
  $ wax passive_linked.wasm -f wat | grep -E 'elem|func|type'
  (type $t (func (result i32)))
  (func $h (result i32)
  (func (result i32)
    ref.func $h
  (export "main" (func 1))
  (elem func $h)
  (elem func )
  $ wax -v -f wasm -o /dev/null passive_linked.wasm && echo OK
  OK

When removing dead code, the most used globals get the smallest indices (and so
the shortest encoding):
  $ cat > gord.wat <<EOF
  > (module
  >   (global \$rare (mut i32) (i32.const 1))
  >   (global \$base i32 (i32.const 3))
  >   (global \$derived i32 (global.get \$base))
  >   (global \$often (mut i32) (i32.const 2))
  >   (func (export "main") (result i32)
  >     (global.set \$rare (global.get \$derived))
  >     (global.set \$often (i32.const 4))
  >     (drop (global.get \$often))
  >     (drop (global.get \$often))
  >     (global.get \$often)))
  > EOF
  $ wax gord.wat -o gord.wasm
  $ wax link --dependencies deps.json -o gord_linked.wasm a:gord.wasm
  $ wax gord_linked.wasm -f wat | grep '(global'
  (global $often (mut i32)
  (global $rare (mut i32)
  (global $base i32
  (global $derived i32
  $ wax -v -f wasm -o /dev/null gord_linked.wasm && echo OK
  OK

Source maps: the mappings of a removed function are dropped, and the ones of the
functions after it are shifted. Here the second function of `sm1` is removed:
  $ cat > sm1.wat <<EOF
  > (module
  >   (import "m2" "f2" (func \$f2 (param i32) (result i32)))
  >   (func (export "main") (param i32) (result i32)
  >     local.get 0
  >     call \$f2)
  >   (func (export "dead") (param i32) (result i32)
  >     local.get 0
  >     i32.const 7
  >     i32.mul)
  >   (func (export "kept") (param i32) (result i32)
  >     local.get 0
  >     i32.const 2
  >     i32.add)
  > )
  > EOF
  $ cat > sm2.wat <<EOF
  > (module
  >   (func (export "f2") (param i32) (result i32)
  >     local.get 0
  >     i32.const 3
  >     i32.mul)
  > )
  > EOF
  $ wax sm1.wat -o sm1.wasm --source-map
  $ wax sm2.wat -o sm2.wasm --source-map
  $ cat > deps3.json <<EOF
  > [{"name": "root", "reaches": ["main", "kept"], "root": true},
  >  {"name": "main", "export": "main"},
  >  {"name": "kept", "export": "kept"}]
  > EOF
  $ wax link --dependencies deps3.json -o sm_linked.wasm --source-map m1:sm1.wasm m2:sm2.wasm
  $ wax sm_linked.wasm -f wat | grep export
  (export "main" (func 0))
  (export "kept" (func 1))
  $ ../../check-sourcemap/check_sourcemap.exe --removed sm1.wasm:1 sm_linked.wasm sm_linked.wasm.map sm1.wasm sm2.wasm
  Instruction-boundary source map verification successful!

(Without `--removed`, the checker expects every instruction of `sm1` to be
kept, and fails.)
  $ ../../check-sourcemap/check_sourcemap.exe sm_linked.wasm sm_linked.wasm.map sm1.wasm sm2.wasm > /dev/null 2>&1 || echo FAILED
  FAILED

Compilation hints: the hints of a removed function are dropped, and so are the
call targets naming a removed function (one that cannot be called):
  $ cat > hints.wat <<EOF
  > (module
  >   (type \$ft (func (param i32) (result i32)))
  >   (func \$local (param i32) (result i32) (local.get 0))
  >   (func \$unused (param i32) (result i32) (local.get 0))
  >   (func \$dead (param i32) (result i32)
  >     (@metadata.code.compilation_priority (priority 7))
  >     (@metadata.code.instr_freq (freq 4))
  >     (call \$local (local.get 0)))
  >   (table \$t funcref (elem \$local))
  >   (func (export "main") (param i32) (result i32)
  >     (@metadata.code.compilation_priority (priority 3))
  >     (@metadata.code.call_targets (target \$local 0.75) (target \$unused 0.20))
  >     (call_indirect \$t (type \$ft) (local.get 0) (i32.const 0)))
  > )
  > EOF
  $ wax hints.wat -o hints.wasm
  $ wax link --dependencies deps.json -o hints_linked.wasm a:hints.wasm
  $ wax hints_linked.wasm -f wat | grep metadata
    (@metadata.code.compilation_priority (priority 3))
    (@metadata.code.call_targets (target $local 0.75))

Imports are checked against the exports they resolve to, also when dead code
elimination removes them:
  $ cat > badimp.wat <<EOF
  > (module
  >   (import "s" "f" (func (param i64) (result f32)))
  >   (import "s" "t" (tag (param f64)))
  >   (func (export "main") (result i32) (i32.const 0)))
  > EOF
  $ cat > badexp.wat <<EOF
  > (module
  >   (tag (export "t") (param i32))
  >   (func (export "f") (result i32) (i32.const 1)))
  > EOF
  $ wax badimp.wat -o badimp.wasm
  $ wax badexp.wat -o badexp.wasm
  $ wax link --dependencies deps.json -o bad_linked.wasm m:badimp.wasm s:badexp.wasm
  Error:
    In module "badimp.wasm", the import "s" / "f" refers to an export in module
    "badexp.wasm" of an incompatible type.
  [128]

Tables and memories are always kept, so their import nodes are reached, like
the node of a function import which is used:
  $ cat > memimp.wat <<EOF
  > (module
  >   (import "env" "mem" (memory 1))
  >   (import "env" "f" (func \$f))
  >   (func (export "main") (result i32) (call \$f) (i32.load (i32.const 0)))
  >   (func (export "cb_mem") (result i32) (i32.const 1))
  >   (func (export "cb_f") (result i32) (i32.const 2))
  >   (func (export "cb_unused") (result i32) (i32.const 3)))
  > EOF
  $ cat > memdeps.json <<EOF
  > [{"name": "root", "root": true, "reaches": ["main"]},
  >  {"name": "main", "export": "main"},
  >  {"name": "cb_mem", "export": "cb_mem"},
  >  {"name": "cb_f", "export": "cb_f"},
  >  {"name": "cb_unused", "export": "cb_unused"},
  >  {"name": "mem", "import": ["env", "mem"], "reaches": ["cb_mem"]},
  >  {"name": "f", "import": ["env", "f"], "reaches": ["cb_f"]},
  >  {"name": "g", "import": ["env", "g"], "reaches": ["cb_unused"]}]
  > EOF
  $ wax memimp.wat -o memimp.wasm
  $ wax link --dependencies memdeps.json -o memimp_linked.wasm a:memimp.wasm
  $ wax memimp_linked.wasm -f wat | grep export
  (export "main" (func 1))
  (export "cb_mem" (func 2))
  (export "cb_f" (func 3))

Element segments: an active segment of a module whose table is not the first
one is retargeted, while a declarative segment only keeps the functions that
are live:
  $ cat > tab1.wat <<EOF
  > (module
  >   (table 1 funcref)
  >   (func \$one (result i32) (i32.const 1))
  >   (elem (i32.const 0) \$one))
  > EOF
  $ cat > tab2.wat <<EOF
  > (module
  >   (type \$t (func (result i32)))
  >   (table 2 funcref)
  >   (func \$two (result i32) (i32.const 2))
  >   (func \$dead (result i32) (ref.func \$dead) (drop) (i32.const 3))
  >   (elem (i32.const 1) \$two)
  >   (elem declare func \$dead)
  >   (func (export "main") (result i32)
  >     (call_indirect (type \$t) (i32.const 1))))
  > EOF
  $ wax tab1.wat -o tab1.wasm
  $ wax tab2.wat -o tab2.wasm
  $ wax link --dependencies deps.json -o tab_linked.wasm a:tab1.wasm b:tab2.wasm
  $ wax tab_linked.wasm -f wat | grep -E '\(elem|\(table|\(func'
  (type $t (func (result i32)))
  (func $one (result i32)
  (func $two (result i32)
  (func (result i32)
  (table 1 funcref)
  (table 2 funcref)
  (export "main" (func 2))
  (elem (offset i32.const 0) func $one)
  (elem (table 1) (offset i32.const 1) func $two)
  (elem declare func )
  $ wax -v -f wasm -o /dev/null tab_linked.wasm && echo OK
  OK

Start functions are roots, and several of them are called from a synthesized
start function:
  $ cat > start1.wat <<EOF
  > (module
  >   (global \$g (mut i32) (i32.const 0))
  >   (func \$s1 (global.set \$g (i32.const 1)))
  >   (func \$unused1)
  >   (start \$s1))
  > EOF
  $ cat > start2.wat <<EOF
  > (module
  >   (func \$s2 (call \$helper))
  >   (func \$helper)
  >   (func \$unused2)
  >   (start \$s2)
  >   (func (export "main") (result i32) (i32.const 0)))
  > EOF
  $ wax start1.wat -o start1.wasm
  $ wax start2.wat -o start2.wasm
  $ wax link --dependencies deps.json -o start_linked.wasm a:start1.wasm b:start2.wasm
  $ wax start_linked.wasm -f wat | grep -E '\(func|\(start|call'
  (type (func))
  (type (func (result i32)))
  (func $s1
  (func $s2
    call $helper
  (func $helper)
  (func (result i32)
  (func
    call $s1
    call $s2
  (export "main" (func 3))
  (start 4)
  $ wax -v -f wasm -o /dev/null start_linked.wasm && echo OK
  OK
