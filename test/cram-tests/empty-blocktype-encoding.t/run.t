A block instruction with no type annotation has the empty blocktype, which the
binary format spells with the dedicated `0x40` shorthand. The text parser builds
an absent type use as an *empty functype*, so it used to fall through to the
general `(type N)` case: the assembler interned a `(func)` type nobody wrote and
pointed every bare `block`/`loop`/`if` at it. Both encodings validate and mean
the same thing, so nothing caught it, but it inflated the type section and made
a `wat` module and its round trip through Wax disagree byte for byte.

  $ cat > b.wat <<'WAT'
  > (module
  >   (func $f
  >     block
  >     end
  >     loop
  >     end
  >     i32.const 1
  >     if
  >     end))
  > WAT

No `(func)` type is minted, and each block keeps the shorthand:

  $ wax -i wat -f wasm b.wat -o b.wasm && wax -i wasm -f wat b.wasm
  (type (func))
  (func $f
    block
    end
    loop
    end
    i32.const 1
    if
    end
  )

The only type is `$f`'s own signature, and the three block instructions encode
as `02 40`, `03 40` and `04 40`:

  $ od -An -tx1 -j 23 -N 12 b.wasm
   02 40 0b 03 40 0b 41 01 04 40 0b 0b

A type use that is *written* still round-trips as written, so the fix does not
normalise away a module that genuinely spells the long form:

  $ cat > e.wat <<'WAT'
  > (module
  >   (type $e (func))
  >   (func $f
  >     block
  >     end
  >     block (type $e)
  >     end))
  > WAT

  $ wax -i wat -f wasm e.wat -o e.wasm && wax -i wasm -f wat e.wasm
  (type $e (func))
  (func $f
    block
    end
    block (type $e)
    end
  )

  $ od -An -tx1 -j 23 -N 6 e.wasm
   02 40 0b 02 00 0b
