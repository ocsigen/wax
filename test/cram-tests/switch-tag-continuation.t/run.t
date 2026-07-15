A `(resume $ct (on $t switch) …)` handler is valid only when the switch tag's
results are *equivalent* to (not merely a subtype of) the resumed continuation's
results. The canonical stack-switching rule reifies the current continuation as
`cont [t2*] -> [t*]` (where `t*` is the tag's result) and runs it to this
`resume` boundary, whose results are the continuation's; consistency forces
`t*` to equal them. A subtype would let a continuation whose completion produces
the boundary results be observed by a peer at the narrower tag type — an
unchecked narrowing. wax checks this on both the wasm validator and the Wax
typer.

A switch tag whose results (i32) do not match the continuation's (i64) is
rejected:

  $ wax check mismatch.wat
  Error:
    Type mismatch in this stack switching instruction: the results of a 'switch'
    handler's tag must match the resumed continuation's results.
   ──➤  mismatch.wat:7:6
  5 │   (tag $t (type $tag_ft))
  6 │   (func (export "f") (result i64)
  7 │     (resume $ct (on $t switch) (ref.null $ct))))
    ·      ^^^^^^^^^^^^^^^^^^^^^^^^^
  8 │ 
  [128]

A subtype is not enough: a `nullfuncref`-result tag on a `funcref`-result
continuation is rejected even though `nullfuncref <: funcref`:

  $ wax check subtype.wat
  Error:
    Type mismatch in this stack switching instruction: the results of a 'switch'
    handler's tag must match the resumed continuation's results.
   ──➤  subtype.wat:7:6
  5 │   (tag $t (type $tag_ft))
  6 │   (func (export "f") (result funcref)
  7 │     (resume $ct (on $t switch) (ref.null $ct))))
    ·      ^^^^^^^^^^^^^^^^^^^^^^^^^
  8 │ 
  [128]

Equivalent results are accepted:

  $ wax check ok.wat
