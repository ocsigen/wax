An allocation yields the type allocated EXACTLY, and so does a `ref.func` of a
module-defined function — but exact reference types are part of
custom-descriptors, so without the feature both are the plain inexact reference,
as before the proposal. The Wax typer has always gated this; the Wasm validator
did not, and the difference is observable through the `cast-always-fails` lint.

Both tests below downcast to a type from a structurally identical `rec` group.
Identical rec groups are the same canonical type, so `$sd` is `$sb` and `$fd` is
`$fb` — each test is an ordinary downcast that can succeed at runtime, provided
the value's type is inexact. With the feature off, nothing is reported:

  $ wax check -W correctness=warning -W unused=hidden --error-format short alloc.wat

  $ wax alloc.wat -f wax -o alloc.wax && wax check -W correctness=warning -W unused=hidden --error-format short alloc.wax

With the feature on, the values ARE exact, so neither test can ever succeed and
both sides say so — the point being that the two agree in each state:

  $ wax check -X custom-descriptors -W correctness=warning -W unused=hidden --error-format short alloc.wat
  alloc.wat:7:40: warning: This type test is always false: the value can never have this type. [cast-always-fails]
  alloc.wat:8:42: warning: This type test is always false: the value can never have this type. [cast-always-fails]

  $ wax alloc.wat -f wax -X custom-descriptors -o allocx.wax && wax check -X custom-descriptors -W correctness=warning -W unused=hidden --error-format short allocx.wax
  allocx.wax:22:5: warning: This type test is always false: the value can never have this type. [cast-always-fails]
  allocx.wax:26:5: warning: This type test is always false: the value can never have this type. [cast-always-fails]

The gate covers every allocation, not just the two exercised above: `struct.new`
and `struct.new_default`, the five `array.new*` forms, `cont.new`/`cont.bind`, and
the `(@string …)` allocations. The `*_desc` forms are deliberately left exact —
those instructions exist only under the feature, so there is nothing to gate.
