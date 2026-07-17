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

A module-level global gets the same redundant-annotation suggestion as a `let`,
for both a mutable `let` global and an immutable `const`:

  $ cat > g.wax <<'WAX'
  > let counter: i32 = 0;
  > const PI: f64 = 3.14159;
  > fn use() -> f64 { counter; PI; }
  > WAX
  $ wax check -W redundant-annotation=warning g.wax
  Suggestion:
    This type annotation is redundant; the initializer's type is inferred.
   ──➤  g.wax:1:14
  1 │ let counter: i32 = 0;
    ·              ^^^
  2 │ const PI: f64 = 3.14159;
  3 │ fn use() -> f64 { counter; PI; }
  Suggestion:
    This type annotation is redundant; the initializer's type is inferred.
   ──➤  g.wax:2:11
  1 │ let counter: i32 = 0;
  2 │ const PI: f64 = 3.14159;
    ·           ^^^
  3 │ fn use() -> f64 { counter; PI; }
  4 │ 
  Error: This value remains on the stack.
   ──➤  g.wax:3:19
  1 │ let counter: i32 = 0;
  2 │ const PI: f64 = 3.14159;
  3 │ fn use() -> f64 { counter; PI; }
    ·                   ^^^^^^^
  4 │ 
  [128]

An `if` whose `=> t` result type the context already pins is redundant too; the
suggestion's edit deletes the whole `=> t`:

  $ cat > i.wax <<'WAX'
  > fn f(c: i32) -> i32 {
  >     if c => i32 { 1; } else { 2; };
  > }
  > WAX
  $ wax check -W redundant-annotation=warning i.wax
  Suggestion: This result type is redundant; it is inferred from the context.
   ──➤  i.wax:2:13
  1 │ fn f(c: i32) -> i32 {
  2 │     if c => i32 { 1; } else { 2; };
    ·             ^^^
  3 │ }
  4 │ 

A suggestion's machine-applicable edit is serialized by `--error-format json`, as
an `edit` object with the replacement span and its `newText`. Here the redundant
`if` result type's edit deletes `=> i32`:

  $ wax check -W redundant-annotation=warning --error-format json i.wax
  {"severity":"suggestion","file":"i.wax","startLine":2,"startColumn":12,"endLine":2,"endColumn":15,"startOffset":34,"endOffset":37,"message":"This result type is redundant; it is inferred from the context.","warning":"redundant-annotation","hint":null,"related":[],"edit":{"startLine":2,"startColumn":9,"endLine":2,"endColumn":15,"startOffset":31,"endOffset":37,"newText":""}}

Some correctness/`unused` warnings also carry a quick-fix `edit`, surfaced the
same way in JSON: `unused-local` inserts a `_` at the name's start, `unused-label`
deletes the whole `'name:` prefix, and `precedence` wraps the confusing
sub-expression in parentheses:

  $ cat > w.wax <<'WAX'
  > fn f(a: i32, b: i32) -> i32 {
  >     let x = 1;
  >     'lbl: do i32 { 0; };
  >     a & b == 0;
  > }
  > WAX
  $ wax check -W unused-local=warning -W unused-label=warning -W precedence=warning --error-format json w.wax
  {"severity":"warning","file":"w.wax","startLine":4,"startColumn":10,"endLine":4,"endColumn":12,"startOffset":80,"endOffset":82,"message":"Operator precedence here is easy to misread.","warning":"precedence","hint":"Add parentheses to make the grouping explicit.","related":[{"startLine":4,"startColumn":6,"endLine":4,"endColumn":7,"startOffset":76,"endOffset":77,"message":"This bitwise operator binds tighter than the comparison operator."}],"edit":{"startLine":4,"startColumn":4,"endLine":4,"endColumn":9,"startOffset":74,"endOffset":79,"newText":"(a & b)"}}
  {"severity":"error","file":"w.wax","startLine":3,"startColumn":4,"endLine":3,"endColumn":23,"startOffset":49,"endOffset":68,"message":"This value remains on the stack.","warning":null,"hint":null,"related":[]}
  {"severity":"warning","file":"w.wax","startLine":2,"startColumn":8,"endLine":2,"endColumn":9,"startOffset":38,"endOffset":39,"message":"The local variable 'x' is never used.","warning":"unused-local","hint":null,"related":[],"edit":{"startLine":2,"startColumn":8,"endLine":2,"endColumn":8,"startOffset":38,"endOffset":38,"newText":"_"}}
  {"severity":"warning","file":"w.wax","startLine":3,"startColumn":4,"endLine":3,"endColumn":8,"startOffset":49,"endOffset":53,"message":"The label 'lbl' is never used.","warning":"unused-label","hint":null,"related":[],"edit":{"startLine":3,"startColumn":4,"endLine":3,"endColumn":10,"startOffset":49,"endOffset":55,"newText":""}}
  [128]
