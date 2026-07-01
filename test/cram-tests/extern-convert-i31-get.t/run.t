Decompiling `extern.convert_any; any.convert_extern; ref.cast (ref i31);
i31.get_u` fused two casts too far. The `any.convert_extern; ref.cast` pair fuses
to `as &i31` on the `&extern` (correct — to_wasm re-expands it), but then the
`(_ as &i31) as i32_u` fusion (a plain `ref.cast` feeding `i31.get`) also fired on
that `&extern`, collapsing it to `as i32_u` — an untranslatable `&extern as i32`,
which wax then rejected ("This value of type &extern cannot be cast to the target
type"), so it could not decompile a module the reference accepts. That fusion no
longer treats an `extern`/`noextern` operand as a plain `ref.cast` receiver:

  $ cat > f.wat <<'WAT'
  > (module
  >   (type $s (struct))
  >   (func (export "f") (result i32)
  >     (struct.new_default $s)
  >     extern.convert_any
  >     any.convert_extern
  >     ref.cast (ref i31)
  >     i31.get_u))
  > WAT
  $ wax -i wat -f wax f.wat
  type s = { };
  #[export = "f"]
  fn f() -> i32 {
      {s| .. } as &extern as &i31 as i32_u;
  }
  $ wax -i wat -f wax f.wat -o f.wax && wax -i wax -f wasm f.wax -o /dev/null --validate
