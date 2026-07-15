Label names (name-section subsection 0x03) are collected from the text AST and
must survive a binary round-trip regardless of how the control instructions are
written. The collector has to see through the wrapper nodes the parser produces
-- folded instructions and branch hints -- and number labels in binary-emission
order, or names are dropped and later label indices are misattributed.

A folded block/loop keeps its labels through wasm:

  $ cat > folded.wat <<'WAT'
  > (module
  >   (func $f (result i32)
  >     (block $outer (result i32)
  >       (loop $inner (br $outer (i32.const 42)))
  >       (i32.const 0))))
  > WAT

  $ wax -i wat -f wasm folded.wat -o folded.wasm
  $ wax -i wasm -f wat folded.wasm
  (type (func (result i32)))
  (type (func))
  (func $f (result i32)
    block $outer (result i32)
      loop $inner (type 1)
        i32.const 42
        br $outer
      end
      i32.const 0
    end
  )

A function mixing unfolded and folded blocks keeps every label on the right one
(a folded block must still advance the label index, or `$c` below would land on
`$b`'s slot):

  $ cat > mixed.wat <<'WAT'
  > (module
  >   (func $f
  >     block $a
  >     end
  >     (block $b)
  >     block $c
  >     end))
  > WAT

  $ wax -i wat -f wasm mixed.wat -o mixed.wasm
  $ wax -i wasm -f wat mixed.wasm
  (type (func))
  (func $f
    block $a (type 0)
    end
    block $b (type 0)
    end
    block $c (type 0)
    end
  )

A branch hint is a transparent wrapper, so a hinted labelled `if` keeps its
label too:

  $ cat > hinted.wat <<'WAT'
  > (module
  >   (func $f (param i32)
  >     local.get 0
  >     (@metadata.code.branch_hint "\01")
  >     if $lbl
  >     end))
  > WAT

  $ wax -i wat -f wasm hinted.wat -o hinted.wasm
  $ wax -i wasm -f wat hinted.wasm
  (type (func (param i32)))
  (type (func))
  (func $f (param i32)
    local.get 0
    (@metadata.code.branch_hint "\01")
    if $lbl (type 1)
    end
  )
