A cross-hierarchy convert (`any.convert_extern` / `extern.convert_any`) after a
`br_on_null` into a block with a reference result. The `br_on_null` pushes a
multi-value residual (the delivered branch value plus the fall-through non-null
ref) that `from_wasm` cannot split, so the convert pops a fresh hole which, on
re-parse, reconnects to the fall-through ref — typed by the block's declared
`(ref null any)` result. The convert's source pin on that hole would then cross
hierarchies and materialise a spurious extra opcode (`extern.convert_any` ahead
of the `any.convert_extern`). `from_wasm` instead pins the `br_on_null`'s tested
ref to the convert source (`br_on_null $l (_, _ as &?extern)`), grounding the
fall-through ref at the source hierarchy so the convert lowers to exactly one
opcode on both the default and the `--faithful` path.

  $ cat > m.wat <<'WAT'
  > (module
  >   (func (export "f") (param $n (ref null any)) (result (ref null any))
  >     block $l (result (ref null any))
  >     unreachable
  >     br_on_null $l
  >     any.convert_extern
  >     unreachable
  >     end))
  > WAT

The tested ref is pinned to the convert source; the fall-through hole then
reconnects there rather than at the block's `&?any` result:

  $ wax -i wat -f wax --faithful m.wat
  #[export]
  fn f(n: &?any) -> &?any {
      'l: do &?any {
          unreachable;
          br_on_null 'l (_, _ as &?extern);
          _ as &extern as &any;
          unreachable;
      }
  }

The round trip re-emits exactly `any.convert_extern` — no doubled convert — on
both paths:

  $ wax -i wat -f wax --faithful m.wat -o f.wax && wax -i wax -f wat f.wax | grep -oE 'br_on_null|any.convert_extern|extern.convert_any'
  br_on_null
  any.convert_extern
  $ wax -i wat -f wax m.wat -o d.wax && wax -i wax -f wat d.wax | grep -oE 'br_on_null|any.convert_extern|extern.convert_any'
  br_on_null
  any.convert_extern
