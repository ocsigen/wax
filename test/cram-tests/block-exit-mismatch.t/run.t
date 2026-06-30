A value-producing `do` block infers its result from the values reaching its
exit. When those values have no common supertype the block has no result type,
and the error points a caret at each offending value — whether the values come
from a `br` to the block's label and the fall-through:

  $ wax check br-and-fall-through.wax
  Error:
    The values reaching this block's exit have no common supertype, so its result type cannot be inferred.
   ──➤  br-and-fall-through.wax:2:9
  1 │ fn f(c: i32) {
  2 │     _ = 'l: do {
    ·         ^^^^^^^^^
  3 │         if c { br 'l 5; }
    · ^^^^^^^^^^^^^^^^^^^^^^^^^^
    ·                      ^ number
  4 │         null as &any;
    · ^^^^^^^^^^^^^^^^^^^^^^
    ·         ^^^^^^^^^^^^ &any
  5 │     };
    · ^^^^^
  6 │ }
  7 │ 
  [123]

…or from two different branches to the label:

  $ wax check two-br.wax
  Error:
    The values reaching this block's exit have no common supertype, so its result type cannot be inferred.
   ──➤  two-br.wax:2:9
  1 │ fn f(c: i32) {
  2 │     _ = 'l: do {
    ·         ^^^^^^^^^
  3 │         if c { br 'l 5; }
    · ^^^^^^^^^^^^^^^^^^^^^^^^^^
    ·                      ^ number
  4 │         if c { br 'l (null as &any); }
    · ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    ·                       ^^^^^^^^^^^^ &any
  5 │         unreachable;
    · ^^^^^^^^^^^^^^^^^^^^^
  6 │     };
    · ^^^^^
  7 │ }
  8 │ 
  [123]
