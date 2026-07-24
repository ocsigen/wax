`i31.get_s`/`i31.get_u` erase their source hierarchy through the Wax `as` surface
(spelled `operand as i32_s`), so a dead-code operand must be grounded with the
source cast or the op drops on re-parse — the same reason `convert-adaptive-
operand.t` grounds the cross-hierarchy converts. A bare hole was already pinned
(`(_ as &?i31) as i32_s`); a `select` operand is adaptive the same way (an untyped
`select` of holes re-parses to i32, so a bare `(_?_:_) as i32_s` re-types straight
to i32 and drops the `i31.get_s`), so `From_wasm`'s `type_hole_src` grounds it too.
A concrete select fixes the type on its own, so the default path prunes the pin
(no noise on live code).

  $ cat > m.wat <<'WAT'
  > (module (memory 1)
  >   (func $dead (result i32)
  >     unreachable
  >     select
  >     i31.get_s)
  >   (func $live (param i32) (result i32)
  >     (i31.get_s (select (result (ref i31)) (ref.i31 (i32.const 1)) (ref.i31 (i32.const 2)) (local.get 0)))))
  > WAT
  $ wax -i wat -f wax --faithful m.wat
  memory m: i32 [1];
  fn dead() -> i32 {
      unreachable;
      (_?_:_) as &?i31 as i32_s;
  }
  fn live(x: i32) -> i32 {
      (x?1 as &i31:2 as &i31) as i32_s;
  }

The dead-code select keeps its inner `as &?i31` (load-bearing); the concrete live
select does not, so only one pin survives the default (simplified) path:

  $ wax -i wat -f wax m.wat | grep -c 'as &?i31'
  1

Both keep `i31.get_s` across the round trip:

  $ wax -i wat -f wax --faithful m.wat -o m.wax && wax -i wax -f wat m.wax | grep -oE 'i31.get_s'
  i31.get_s
  i31.get_s
