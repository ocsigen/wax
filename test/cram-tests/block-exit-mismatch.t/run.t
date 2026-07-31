A value-producing `do` block infers its result from the values reaching its
exit. When those values have no common supertype the block has no result type,
and the error points a caret at each offending value — whether the values come
from a `br` to the block's label and the fall-through:

  $ wax check br-and-fall-through.wax
  Error:
    The values reaching this block's exit have no common supertype, so its
    result type cannot be inferred.
   ──➤  br-and-fall-through.wax:2:9
  1 │ fn f(c: i32) {
  2 │     _ = 'l: do {
    · ╭───────^
  3 │         if c { br 'l 5; }
    · │
    ·                      ^ 'i32'
  4 │         null as &any;
    · │
    ·         ^^^^^^^^^^^^ '&any'
  5 │     };
    · ╰───^
  6 │ }
  7 │ 
  [128]

…or from two different branches to the label:

  $ wax check two-br.wax
  Error:
    The values reaching this block's exit have no common supertype, so its
    result type cannot be inferred.
   ──➤  two-br.wax:2:9
  1 │ fn f(c: i32) {
  2 │     _ = 'l: do {
    · ╭───────^
  3 │         if c { br 'l 5; }
    · │
    ·                      ^ 'i32'
  4 │         if c { br 'l (null as &any); }
    · │
    ·                       ^^^^^^^^^^^^ '&any'
  5 │         unreachable;
    · │
  6 │     };
    · ╰───^
  7 │ }
  8 │ 
  [128]

A block whose result is INFERRED must have that result delivered by every exit,
just as a declared one must. Here the `br` delivers a value and the reachable
fall-through delivers none, so the block would yield a result its own exit never
produces — the lowering would emit a block whose declared result the body never
leaves, which is what the fuzz oracle caught as an under-rejection (`wax check`
accepting what the conversion then rejects). It is reported at the block's
closing token, like every other missing returned value:

  $ wax check br-no-fall-through.wax
  Error: Expecting 1 returned value(s) from the stack, but there are 0.
   ──➤  br-no-fall-through.wax:6:9
  4 │         'inner: do {
  5 │             if c { br 'inner 5; }
  6 │         }
    ·         ^
  7 │     };
  8 │ }
  [128]

An `unreachable` fall-through needs no value: nothing reaches the exit that way.

  $ cat > br-diverging.wax <<'WAX'
  > #[export]
  > fn f(c: i32) -> i32 {
  >     'l: do {
  >         'inner: do {
  >             if c { br 'inner 5; }
  >             unreachable;
  >         }
  >     };
  > }
  > WAX
  $ wax check br-diverging.wax

Which exit delivers nothing cannot be decided as that exit is met — a block every
exit of which delivers nothing is simply void — and an `if` types its arms in
order, so the two arms must be judged together. Deciding it per exit reported an
empty `else` (a value was already collected from the `then` arm) but accepted an
empty `then`, whose emptiness nothing revisited once the `else` delivered a
value: the same under-rejection as above, in the arm order the oracle happened
not to hit first. Both orders are reported now, each at the closing token of the
arm that delivers nothing — the arms carry their own spans, so the two reports an
`if` with two empty arms produces do not render as one line twice:

  $ cat > empty-then.wax <<'WAX'
  > fn h(c: i32) -> i32 {
  >     let b =
  >         if c {
  >         } else {
  >             7;
  >         };
  >     b
  > }
  > WAX
  $ wax check empty-then.wax
  Error: Expecting 1 returned value(s) from the stack, but there are 0.
   ──➤  empty-then.wax:4:9
  2 │     let b =
  3 │         if c {
  4 │         } else {
    ·         ^
  5 │             7;
  6 │         };
  [128]

  $ cat > empty-else.wax <<'WAX'
  > fn h(c: i32) -> i32 {
  >     let b =
  >         if c {
  >             7;
  >         } else {
  >         };
  >     b
  > }
  > WAX
  $ wax check empty-else.wax
  Error: Expecting 1 returned value(s) from the stack, but there are 0.
   ──➤  empty-else.wax:6:9
  4 │             7;
  5 │         } else {
  6 │         };
    ·         ^
  7 │     b
  8 │ }
  [128]
