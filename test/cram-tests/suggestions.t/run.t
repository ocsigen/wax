The type-checker can emit machine-applicable simplifications as `Suggestion`
diagnostics (used by the editor for quick fixes). They are hidden by default and
revealed with `-W`, either individually or through the `suggestion` group.

  $ cat > m.wax <<'WAX'
  > type point = { x: i32, y: i32 };
  > 
  > fn f(x: i32) -> i32 {
  >     let a: i32 = x;
  >     a = a + 1;
  >     a;
  > }
  > 
  > fn g(x: i32) -> &point {
  >     {point| x: x, y: 0};
  > }
  > WAX

By default `check` is silent (suggestions are hidden):

  $ wax check m.wax

`-W suggestion=warning` reveals them: a redundant `let` annotation, a compound
assignment, a construction type name the fields already pin, and a field that can
be punned.

  $ wax check -W suggestion=warning m.wax
  Suggestion:
    This type annotation is redundant; the initializer's type is inferred.
   ──➤  m.wax:4:12
  2 │ 
  3 │ fn f(x: i32) -> i32 {
  4 │     let a: i32 = x;
    ·            ^^^
  5 │     a = a + 1;
  6 │     a;
  Suggestion: This assignment can use the compound form 'a += …'.
   ──➤  m.wax:5:5
  3 │ fn f(x: i32) -> i32 {
  4 │     let a: i32 = x;
  5 │     a = a + 1;
    ·     ^^^^^^^^^
  6 │     a;
  7 │ }
  Suggestion: This field can use the punning shorthand 'x'.
    ──➤  m.wax:10:13
   8 │ 
   9 │ fn g(x: i32) -> &point {
  10 │     {point| x: x, y: 0};
     ·             ^
  11 │ }
  12 │ 
  Suggestion: This type name is redundant; it is inferred here.
    ──➤  m.wax:10:6
   8 │ 
   9 │ fn g(x: i32) -> &point {
  10 │     {point| x: x, y: 0};
     ·      ^^^^^
  11 │ }
  12 │ 

A single suggestion can be enabled on its own:

  $ wax check -W field-punning=warning m.wax
  Suggestion: This field can use the punning shorthand 'x'.
    ──➤  m.wax:10:13
   8 │ 
   9 │ fn g(x: i32) -> &point {
  10 │     {point| x: x, y: 0};
     ·             ^
  11 │ }
  12 │ 

The redundant `let` annotation is also offered for the anonymous `_` drop and for
each binding of a multi-value `let`, and a redundant block result type is dropped
too:

  $ cat > b.wax <<'WAX'
  > fn divmod(a: i32, b: i32) -> (i32, i32) {
  >     a + b;
  >     a - b;
  > }
  > 
  > fn h(n: i32) -> i32 {
  >     _: i32 = 5;
  >     let (p: i32, q: i32) = divmod(17, 5);
  >     let r: i32 = do i32 { n + 1; };
  >     p + q + r;
  > }
  > WAX
  $ wax check -W redundant-annotation=warning b.wax
  Suggestion:
    This type annotation is redundant; the initializer's type is inferred.
   ──➤  b.wax:7:8
  5 │ 
  6 │ fn h(n: i32) -> i32 {
  7 │     _: i32 = 5;
    ·        ^^^
  8 │     let (p: i32, q: i32) = divmod(17, 5);
  9 │     let r: i32 = do i32 { n + 1; };
  Suggestion:
    This type annotation is redundant; the initializer's type is inferred.
    ──➤  b.wax:8:13
   6 │ fn h(n: i32) -> i32 {
   7 │     _: i32 = 5;
   8 │     let (p: i32, q: i32) = divmod(17, 5);
     ·             ^^^
   9 │     let r: i32 = do i32 { n + 1; };
  10 │     p + q + r;
  Suggestion:
    This type annotation is redundant; the initializer's type is inferred.
    ──➤  b.wax:8:21
   6 │ fn h(n: i32) -> i32 {
   7 │     _: i32 = 5;
   8 │     let (p: i32, q: i32) = divmod(17, 5);
     ·                     ^^^
   9 │     let r: i32 = do i32 { n + 1; };
  10 │     p + q + r;
  Suggestion: This result type is redundant; it is inferred from the context.
    ──➤  b.wax:9:21
   7 │     _: i32 = 5;
   8 │     let (p: i32, q: i32) = divmod(17, 5);
   9 │     let r: i32 = do i32 { n + 1; };
     ·                     ^^^
  10 │     p + q + r;
  11 │ }
  Suggestion:
    This type annotation is redundant; the initializer's type is inferred.
    ──➤  b.wax:9:12
   7 │     _: i32 = 5;
   8 │     let (p: i32, q: i32) = divmod(17, 5);
   9 │     let r: i32 = do i32 { n + 1; };
     ·            ^^^
  10 │     p + q + r;
  11 │ }

A redundant cast is a `redundant-operation` warning that also carries a fix:

  $ cat > c.wax <<'WAX'
  > type point = { x: i32 };
  > fn k(p: &point) -> &point {
  >     p as &point;
  > }
  > WAX
  $ wax check -W redundant-operation=warning c.wax
  Warning: This cast is redundant: the value already has this type.
   ──➤  c.wax:3:5
  1 │ type point = { x: i32 };
  2 │ fn k(p: &point) -> &point {
  3 │     p as &point;
    ·     ^^^^^^^^^^^
  4 │ }
  5 │ 

The source scan that recovers the annotation span ignores comments, so a comment
containing a ':' does not fool it: the suggestion still points at the real type.

  $ cat > d.wax <<'WAX'
  > fn f(n: i32) -> i32 {
  >     let a /*:*/ : i32 = n;
  >     a;
  > }
  > WAX
  $ wax check -W redundant-annotation=warning d.wax
  Suggestion:
    This type annotation is redundant; the initializer's type is inferred.
   ──➤  d.wax:2:19
  1 │ fn f(n: i32) -> i32 {
  2 │     let a /*:*/ : i32 = n;
    ·                   ^^^
  3 │     a;
  4 │ }
