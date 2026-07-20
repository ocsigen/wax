A `switch` whose inner continuation is named by an *exact* reference
(`(ref (exact $c))`) must not crash. The internal helper accepts both
`Type`/`Exact`, so the text-side reconstruction must too — otherwise an
`assert false` fired (uncaught, exit 125). Without `custom-descriptors` only the
feature-disabled errors are reported; with it, the module is valid.

  $ cat > switch-exact.wat <<'WAT'
  > (module
  >   (type $f (func))
  >   (type $c (cont $f))
  >   (type $g (func (param (ref (exact $c)))))
  >   (type $c2 (cont $g))
  >   (tag $t)
  >   (func (param (ref null $c2)) (param (ref (exact $c)))
  >     local.get 1
  >     local.get 0
  >     switch $c2 $t
  >     drop))
  > WAT

  $ wax check switch-exact.wat
  Error:
    This uses the custom-descriptors feature, which is not enabled; pass
    --feature custom-descriptors.
   ──➤  switch-exact.wat:4:37
  2 │   (type $f (func))
  3 │   (type $c (cont $f))
  4 │   (type $g (func (param (ref (exact $c)))))
    ·                                     ^^
  5 │   (type $c2 (cont $g))
  6 │   (tag $t)
  Error:
    This uses the custom-descriptors feature, which is not enabled; pass
    --feature custom-descriptors.
   ──➤  switch-exact.wat:7:51
  5 │   (type $c2 (cont $g))
  6 │   (tag $t)
  7 │   (func (param (ref null $c2)) (param (ref (exact $c)))
    ·                                                   ^^
  8 │     local.get 1
  9 │     local.get 0
  [128]

  $ wax check -X custom-descriptors switch-exact.wat

On a polymorphic (unreachable) stack, `extern.convert_any` / `any.convert_extern`
push a non-null result — the most precise principal type — so these modules are
valid (the reference interpreter agrees).

  $ cat > convert-any.wat <<'WAT'
  > (module (func (result (ref extern)) unreachable extern.convert_any))
  > WAT
  $ wax check convert-any.wat

  $ cat > convert-extern.wat <<'WAT'
  > (module (func (result (ref any)) unreachable any.convert_extern))
  > WAT
  $ wax check convert-extern.wat

When a definition's own resolution fails (here its typeuse names an unbound
type) the definition still claims its index, so later definitions keep their
positions and numeric references stay aligned. Only the definition-site error is
reported — a reference to the broken entity, by index or by name, resolves
silently. Function space: `call 1` resolves to `$ok`, `call $broken` to the
poisoned index 0, both without an "unknown function" cascade.

  $ cat > func.wat <<'WAT'
  > (module
  >   (func $broken (type $undef))
  >   (func $ok (result i32) (i32.const 1))
  >   (func (result i32) (call 1))
  >   (func (result i32) (call $broken) (drop) (i32.const 2)))
  > WAT
  $ wax check func.wat
  Error: Unknown type: index '$undef' is not bound.
   ──➤  func.wat:2:23
  1 │ (module
  2 │   (func $broken (type $undef))
    ·                       ^^^^^^
  3 │   (func $ok (result i32) (i32.const 1))
  4 │   (func (result i32) (call 1))
  [128]

Global space: `global.get 1` resolves to `$g2` (i32), not to the broken `$g1`.

  $ cat > global.wat <<'WAT'
  > (module
  >   (global $g1 (ref $undef) (ref.null func))
  >   (global $g2 i32 (i32.const 5))
  >   (func (result i32) (global.get 1)))
  > WAT
  $ wax check global.wat
  Error: Unknown type: index '$undef' is not bound.
   ──➤  global.wat:2:20
  1 │ (module
  2 │   (global $g1 (ref $undef) (ref.null func))
    ·                    ^^^^^^
  3 │   (global $g2 i32 (i32.const 5))
  4 │   (func (result i32) (global.get 1)))
  [128]

Table and tag spaces align the same way (`table.size 1` → `$good`, `throw 1` →
`$good`).

  $ cat > table.wat <<'WAT'
  > (module
  >   (table $bad 1 (ref $undef))
  >   (table $good 1 funcref)
  >   (func (result i32) (table.size 1)))
  > WAT
  $ wax check table.wat
  Error: Unknown type: index '$undef' is not bound.
   ──➤  table.wat:2:22
  1 │ (module
  2 │   (table $bad 1 (ref $undef))
    ·                      ^^^^^^
  3 │   (table $good 1 funcref)
  4 │   (func (result i32) (table.size 1)))
  [128]

  $ cat > tag.wat <<'WAT'
  > (module
  >   (tag $bad (type $undef))
  >   (tag $good (param i32))
  >   (func (i32.const 7) (throw 1)))
  > WAT
  $ wax check tag.wat
  Error: Unknown type: index '$undef' is not bound.
   ──➤  tag.wat:2:19
  1 │ (module
  2 │   (tag $bad (type $undef))
    ·                   ^^^^^^
  3 │   (tag $good (param i32))
  4 │   (func (i32.const 7) (throw 1)))
  [128]

A rec group that fails to resolve advances the type index space by its size, so
later `(type N)` numeric references are not shifted: here `(type 2)` still names
`$t2`, and only the unbound `$nope` is reported.

  $ cat > type.wat <<'WAT'
  > (module
  >   (type $t0 (func))
  >   (rec (type $bad (struct (field (ref $nope)))))
  >   (type $t2 (func (result i32)))
  >   (func (type 2) (i32.const 1)))
  > WAT
  $ wax check type.wat
  Error: Unknown type: index '$nope' is not bound.
   ──➤  type.wat:3:39
  1 │ (module
  2 │   (type $t0 (func))
  3 │   (rec (type $bad (struct (field (ref $nope)))))
    ·                                       ^^^^^
  4 │   (type $t2 (func (result i32)))
  5 │   (func (type 2) (i32.const 1)))
  [128]
