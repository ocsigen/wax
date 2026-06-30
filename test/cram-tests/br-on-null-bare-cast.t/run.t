br_on_non_null and br_on_cast accept a bare (floating) null operand, as arises
from a decompiled ref.null in unreachable code whose annotation was dropped.
br_on_non_null never branches (the value is always null); br_on_cast treats the
null as the bottom nullable reference. Both previously failed to recompile with
"a reference type is expected here". Regression: found by the smith fuzzer
(smith-153, smith-2518).

  $ cat > nn.wat <<'WAT'
  > (module (func (export "f") (param $p anyref) (result anyref)
  >   block $l (result anyref) ref.null any br_on_non_null $l local.get $p end))
  > WAT
  $ wax -i wat -f wax nn.wat -o nn.wax && wax -i wax -f wasm nn.wax -o /dev/null --validate

  $ cat > bc.wat <<'WAT'
  > (module (func (export "f") (result i31ref)
  >   block $l (result i31ref) ref.null any br_on_cast $l anyref i31ref unreachable end))
  > WAT
  $ wax -i wat -f wax bc.wat -o bc.wax && wax -i wax -f wasm bc.wax -o /dev/null --validate
