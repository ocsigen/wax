The f64x2->i32x4 saturating truncations are spelled with a trailing `_zero` (the
upper two i32x4 lanes are zeroed) — the only spec names for these opcodes. wax
must print that suffix (a WAT emitter regression printed the bare name, which
wasm-tools and the spec reject) and must not accept the bare name on input.

  $ cat > m.wat <<'WAT'
  > (module (func (param v128) (result v128)
  >   (i32x4.trunc_sat_f64x2_u_zero (i32x4.trunc_sat_f64x2_s_zero (local.get 0)))))
  > WAT
  $ wax -i wat -f wasm m.wat -o m.wasm && wax -i wasm -f wat m.wasm | grep -o 'i32x4.trunc_sat_f64x2_[su]_zero'
  i32x4.trunc_sat_f64x2_s_zero
  i32x4.trunc_sat_f64x2_u_zero

The bare, non-spec name is rejected:

  $ echo '(module (func (param v128) (result v128) (i32x4.trunc_sat_f64x2_s (local.get 0))))' > bare.wat
  $ wax check -f wat bare.wat
  Error: Unknown keyword 'i32x4.trunc_sat_f64x2_s'.
  
   ──➤  bare.wat:1:43
  1 │ (module (func (param v128) (result v128) (i32x4.trunc_sat_f64x2_s (local.get 0))))
    ·                                           ^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  [128]
