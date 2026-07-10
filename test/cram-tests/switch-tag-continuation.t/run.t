A `(resume $ct (on $t switch) …)` handler is valid only when the switch tag's
results are a subtype of the resumed continuation's results (the stack-switching
`resume` rule requires each handler to have the continuation's result type, and
a switch handler `(on $t switch)` has the tag's result type). wax checks this on
both the wasm validator and the Wax typer.

A switch tag whose results (i32) do not match the continuation's (i64) is
rejected:

  $ wax check mismatch.wat
  Error: Type mismatch in this stack switching instruction:
    the results of a 'switch' handler's tag must match the resumed continuation's results.
   ──➤  mismatch.wat:7:6
  5 │   (tag $t (type $tag_ft))
  6 │   (func (export "f") (result i64)
  7 │     (resume $ct (on $t switch) (ref.null $ct))))
    ·      ^^^^^^^^^^^^^^^^^^^^^^^^^
  8 │ 
  [128]

Matching results are accepted:

  $ wax check ok.wat
