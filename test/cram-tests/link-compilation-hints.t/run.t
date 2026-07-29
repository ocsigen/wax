The linker carries the `metadata.code.*` hint sections of the branch-hinting and
compilation-hints proposals across a merge. All four are keyed by function index,
and the three instruction-level ones also by the byte offset of the instruction
they decorate, so merging has to re-key every entry: the function's index changes,
and renumbering an index inside a body may change a LEB's width and so move every
later offset in it. `metadata.code.call_targets` needs one thing more, its payload
naming functions itself.

`lib` carries a function-level priority and an instruction frequency:
  $ cat > lib.wat <<EOF
  > (module
  >   (type \$ft (func (param i32) (result i32)))
  >   (func \$a (param i32) (result i32) (local.get 0))
  >   (func \$b (export "helper") (param i32) (result i32)
  >     (@metadata.code.compilation_priority (priority 5) (optimization 10))
  >     (@metadata.code.instr_freq (freq 16))
  >     (call \$a (local.get 0)))
  > )
  > EOF

`app` carries all four, and its call targets name both a function of its own and
the import that linking resolves against `lib` (so one target is renumbered into
another module's index space):
  $ cat > app.wat <<EOF
  > (module
  >   (type \$ft (func (param i32) (result i32)))
  >   (import "lib" "helper" (func \$helper (param i32) (result i32)))
  >   (func \$local (param i32) (result i32) (local.get 0))
  >   (table \$t funcref (elem \$helper \$local))
  >   (func (export "go") (param i32) (result i32)
  >     (@metadata.code.compilation_priority (priority 3))
  >     (@metadata.code.instr_freq (freq 8))
  >     (@metadata.code.branch_hint "\01")
  >     (if (result i32) (local.get 0)
  >       (then (@metadata.code.call_targets (target \$local 0.75) (target \$helper 0.20))
  >             (call_indirect \$t (type \$ft) (local.get 0) (local.get 0)))
  >       (else (i32.const 0))))
  > )
  > EOF
  $ wax lib.wat -o lib.wasm
  $ wax app.wat -o app.wasm
  $ wax link -o linked.wasm app:app.wasm lib:lib.wasm

Every hint comes back on the instruction it was written on, and the call targets
name the merged module's functions: `$local` is still `app`'s own, while
`$helper` has become `lib`'s `$b`, the definition the import resolved to:
  $ wax linked.wasm -f wat
  (type $ft (func (param i32) (result i32)))
  (func $local (param i32) (result i32)
    local.get 0
  )
  (func (param i32) (result i32)
    (@metadata.code.compilation_priority (priority 3))
    local.get 0
    (@metadata.code.branch_hint "\01")
    (@metadata.code.instr_freq (freq 8))
    if (result i32)
      local.get 0
      local.get 0
      (@metadata.code.call_targets (target $local 0.75) (target $b 0.2))
      call_indirect $t (type $ft)
    else
      i32.const 0
    end
  )
  (func $a (param i32) (result i32)
    local.get 0
  )
  (func $b (param i32) (result i32)
    (@metadata.code.compilation_priority (priority 5) (optimization 10))
    local.get 0
    (@metadata.code.instr_freq (freq 16)) call $a
  )
  (table $t 2 2 funcref)
  (export "go" (func 1))
  (export "helper" (func $b))
  (elem (table $t) (offset i32.const 0) func $b $local)

An offset moves when the bytes before it grow. `big` has enough functions that the
index of its export needs a second LEB byte in the merged module, where `caller`
spelled it as the one-byte import index 0:
  $ { echo '(module'; \
  >   for i in $(seq 0 129); do echo "  (func \$f$i (result i32) (i32.const $i))"; done; \
  >   echo '  (func $helper (export "helper") (result i32) (i32.const 99))'; \
  >   echo ')'; } > big.wat
  $ cat > caller.wat <<EOF
  > (module
  >   (import "big" "helper" (func \$helper (result i32)))
  >   (func (export "go") (result i32)
  >     call \$helper
  >     drop
  >     (@metadata.code.instr_freq (freq 8))
  >     call \$helper)
  > )
  > EOF
  $ wax big.wat -o big.wasm
  $ wax caller.wat -o caller.wasm
  $ wax link -o wide.wasm caller:caller.wasm big:big.wasm

The hint still sits on the second call, not on the `drop` its unshifted offset
would name:
  $ wax wide.wasm -f wat | grep -A1 instr_freq
    (@metadata.code.instr_freq (freq 8)) call $helper
  )

Its recorded offset says the same, having moved by the one byte the first call
grew by (and its entry is now keyed by the internalised function's new index):
  $ cat > hint_offsets.py <<'EOF'
  > import sys
  > def leb(b, i):
  >     r = s = 0
  >     while True:
  >         x = b[i]; i += 1; r |= (x & 0x7f) << s; s += 7
  >         if not x & 0x80: return r, i
  > b = open(sys.argv[1], 'rb').read()
  > key = b'metadata.code.' + sys.argv[2].encode()
  > i = b.find(key) + len(key)
  > n, i = leb(b, i)
  > for _ in range(n):
  >     funcidx, i = leb(b, i); m, i = leb(b, i)
  >     for _ in range(m):
  >         off, i = leb(b, i); ln, i = leb(b, i)
  >         print('func %d offset %d payload %s' % (funcidx, off, b[i:i+ln].hex()))
  >         i += ln
  > EOF
  $ python3 hint_offsets.py caller.wasm instr_freq
  func 1 offset 4 payload 23
  $ python3 hint_offsets.py wide.wasm instr_freq
  func 0 offset 5 payload 23

A hint whose payload the merge cannot re-key is dropped rather than carried on to
name something else. Patching a target index to one the module does not define
(127, where it has two functions) leaves a payload that cannot be renumbered:
  $ python3 - <<'EOF'
  > b = bytearray(open('app.wasm', 'rb').read())
  > def leb(bs, i):
  >     r = s = 0
  >     while True:
  >         x = bs[i]; i += 1; r |= (x & 0x7f) << s; s += 7
  >         if not x & 0x80: return r, i
  > key = b'metadata.code.call_targets'
  > i = b.find(key) + len(key)
  > n, i = leb(b, i)            # entries
  > _, i = leb(b, i)            # function index
  > _, i = leb(b, i)            # hints for it
  > _, i = leb(b, i)            # offset
  > _, i = leb(b, i)            # payload length
  > b[i] = 0x7f                 # the first target index, same LEB width
  > open('bad.wasm', 'wb').write(bytes(b))
  > EOF
  $ wax bad.wasm -f wat | grep -c call_targets
  1
  $ wax link -o bad_linked.wasm app:bad.wasm lib:lib.wasm
  $ wax bad_linked.wasm -f wat | grep -c call_targets
  0
  [1]

The other three sections of the same module are unaffected, so only the hint that
could not be carried is gone:
  $ wax bad_linked.wasm -f wat | grep -c metadata
  5
