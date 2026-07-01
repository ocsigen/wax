`null!` (ref.as_non_null) on a bare, floating `null` is accepted: it is the
bottom non-null reference (`&none`, the `any`-hierarchy bottom). Like
`ref.as_non_null` in Wasm — and like `br_on_null` / `ref.is_null` on a bottom
reference — it is valid (it just always traps at run time), so the decompiler can
round-trip it.

  $ cat > t.wax <<'EOF'
  > fn f() -> &none {
  >     null!;
  > }
  > EOF
  $ wax -f wat t.wax
  (func $f (result (ref none)) (ref.as_non_null (ref.null none)))
