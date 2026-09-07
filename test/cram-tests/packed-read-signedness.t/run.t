A packed (i8/i16) array or field read whose signedness is never resolved must
be rejected by the typer, not just by the compiled module's own validation:
WebAssembly has no unsigned-by-default read of a packed value (array.get /
struct.get on one is invalid — only the _s/_u forms exist), so the i32 default
an omitted annotation would give it has no lowering. `wax check` used to
accept these and the conversion then failed its own output validation (a
wax-mutation-fuzzer under-reject finding).

  $ cat > packed.wax <<'WAX'
  > type bytes = [mut i8];
  > type pair = { f: mut i16 };
  > #[export = "a"]
  > fn a(arr: &bytes) -> i32 {
  >     let x = arr[0];
  >     x
  > }
  > #[export = "b"]
  > fn b(r: &pair) {
  >     _ = r.f;
  > }
  > WAX
  $ wax check packed.wax
  Error:
    This value is read from a packed (i8/i16) array or field; specify the sign
    extension with 'as i32_s' or 'as i32_u'.
   ──➤  packed.wax:5:13
  3 │ #[export = "a"]
  4 │ fn a(arr: &bytes) -> i32 {
  5 │     let x = arr[0];
    ·             ^^^^^^
  6 │     x
  7 │ }
  Error:
    This value is read from a packed (i8/i16) array or field; specify the sign
    extension with 'as i32_s' or 'as i32_u'.
    ──➤  packed.wax:10:9
   8 │ #[export = "b"]
   9 │ fn b(r: &pair) {
  10 │     _ = r.f;
     ·         ^^^
  11 │ }
  12 │ 
  [128]

The resolved forms stay accepted, and the annotated form is rejected by the
ordinary type check (a packed read is not an i32 until a signedness says so):

  $ cat > ok.wax <<'WAX'
  > type bytes = [mut i8];
  > #[export = "a"]
  > fn a(arr: &bytes) -> i32 {
  >     let x = arr[0] as i32_u;
  >     x + (arr[1] as i32_s)
  > }
  > WAX
  $ wax check ok.wax
