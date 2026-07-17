WebAssembly requires every import to precede all definitions, so conversion
hoists imports to the front. The presence of an unrelated conditional block no
longer disables this: the import is still moved ahead of the definitions and the
`(@if …)` guard is preserved untouched.

  $ wax reorder.wax -f wat -o reorder.wat && cat reorder.wat
  (import "env" "g" (func $g))
  (func $f (export "f") (call $g))
  (@if $FOO (@then (func $h (export "h"))))

The hoisted module validates:

  $ wax --validate -i wat -f wat reorder.wat -o /dev/null && echo ok
  ok

When a conditional block itself mixes an import with a definition, the guarded
import is hoisted inside its own `(@if …)` block placed before the definitions,
while the guarded definition keeps its guard in place. Both stay under the same
condition, so every configuration is unchanged apart from the ordering.

  $ wax mixed.wax -f wat -o mixed.wat && cat mixed.wat
  (@if $FOO (@then (import "env" "b" (func $b))))
  (func $top (export "top"))
  (@if $FOO (@then (func $a (export "a") (call $b))))

  $ wax --validate -i wat -f wat mixed.wat -o /dev/null && echo ok
  ok

Specializing the conditional (here `FOO=true`) collapses the two guarded blocks
and still lands the import first:

  $ wax mixed.wax -D FOO=true -f wat
  (import "env" "b" (func $b))
  (func $top (export "top"))
  (func $a (export "a") (call $b))
