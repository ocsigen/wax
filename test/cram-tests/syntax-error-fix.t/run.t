A syntax error carries the same structured payload as any other diagnostic: a
prose `hint`, `related` labels, and — when panic-mode recovery repairs the parse
by inserting a token — a machine-applicable quick `fix` derived from that
insertion (reusing `Diagnostic.edit`, so it flows through the same JSON /
editor / LSP code-action path as the type-checker's suggestions).

A dropped statement separator is repaired by inserting a `;`. In the human
format the derived fix is shown as a `Help:` line spelling out the edit:

  $ cat > missing-semi.wax <<'WAX'
  > fn f() -> i32 {
  >     let x = 1
  >     let y = 2;
  >     x + y;
  > }
  > WAX

  $ wax check --all-errors missing-semi.wax
  Error: Missing ';'.
   ──➤  missing-semi.wax:2:14
  1 │ fn f() -> i32 {
  2 │     let x = 1
    ·              ^
  3 │     let y = 2;
  4 │     x + y;
  Help: insert ';'
  [128]

The same fix is serialized by `--error-format json` as an `edit` object: a
zero-width span at the insertion point (the caret) with the inserted text as its
`newText`. This is the one-keystroke repair an editor applies as a quick fix.

  $ wax check --all-errors --error-format json missing-semi.wax
  {"severity":"error","file":"missing-semi.wax","startLine":2,"startColumn":13,"endLine":2,"endColumn":13,"startOffset":29,"endOffset":29,"message":"Missing ';'.","warning":null,"hint":null,"related":[],"edit":{"startLine":2,"startColumn":13,"endLine":2,"endColumn":13,"startOffset":29,"endOffset":29,"newText":";"}}
  [128]

The `short` format is line-based and carries no fix, so it is unchanged:

  $ wax check --all-errors --error-format short missing-semi.wax
  missing-semi.wax:2:14: error: Missing ';'.
  [128]

A raise-site error can attach a `related` label and a `hint` through the smart
constructor. A WAT block whose closing label does not match its opening one
points a related label back at the opening block and hints at the rule:

  $ cat > label.wat <<'WAT'
  > (module (func block $a end $b))
  > WAT

  $ wax check label.wat
  Error: Label mismatch.
   ──➤  label.wat:1:28
  1 │ (module (func block $a end $b))
    ·                            ^^
    ·                     ^^ The block was opened here.
  2 │ 
  Hint: The closing label must match the opening label, or be omitted.
  [128]

The same `hint` and `related` are serialized in the JSON form:

  $ wax check --error-format json label.wat
  {"severity":"error","file":"label.wat","startLine":1,"startColumn":27,"endLine":1,"endColumn":29,"startOffset":27,"endOffset":29,"message":"Label mismatch.","warning":null,"hint":"The closing label must match the opening label, or be omitted.","related":[{"startLine":1,"startColumn":20,"endLine":1,"endColumn":22,"startOffset":20,"endOffset":22,"message":"The block was opened here."}]}
  [128]

A missing closing bracket is repaired the same way: when panic-mode recovery
auto-closes a construct still open in front of a boundary (or at end of input)
by inserting the closer the parser accepts, the derived fix inserts that closer
at the caret. A block left open with its last statement already terminated
closes with a single `}`:

  $ cat > close-one.wax <<'WAX'
  > fn f() {
  >     nop;
  > WAX

  $ wax check --all-errors close-one.wax
  Error: Assuming that the statement list is complete, expecting '}'.
   ──➤  close-one.wax:3:1
  1 │ fn f() {
    ·        ^ This '{' opens the enclosing construct.
  2 │     nop;
  3 │ 
      ^
  Help: insert '}'
  [128]

When several constructs are open at once, the closers the repair inserts are
concatenated into one edit, in insertion order — here a nested `if` block and
its enclosing function body both close with `}}`:

  $ cat > close-nested.wax <<'WAX'
  > fn f() {
  >     if x {
  >         nop;
  > WAX

  $ wax check --all-errors close-nested.wax
  Error: Assuming that the statement list is complete, expecting '}'.
   ──➤  close-nested.wax:4:1
  1 │ fn f() {
  2 │     if x {
    ·          ^ This '{' opens the enclosing construct.
  3 │         nop;
  4 │ 
      ^
  Help: insert '}}'
  [128]

The same mechanism serves WAT, whose only closer is `)`. An unclosed
folded-instruction nest closes with as many `)` as needed:

  $ cat > close.wat <<'WAT'
  > (module (func (i32.add (i32.const 1))
  > WAT

  $ wax check --all-errors close.wat
  Error: Expecting instructions.
   ──➤  close.wat:2:1
  1 │ (module (func (i32.add (i32.const 1))
  2 │ 
      ^
  Help: insert '))'
  [128]

The closer fix is a zero-width insertion edit at the caret, serialized in JSON
just like the missing-`;` one:

  $ wax check --all-errors --error-format json close-one.wax
  {"severity":"error","file":"close-one.wax","startLine":3,"startColumn":0,"endLine":3,"endColumn":0,"startOffset":18,"endOffset":18,"message":"Assuming that the statement list is complete, expecting '}'.","warning":null,"hint":null,"related":[{"startLine":1,"startColumn":7,"endLine":1,"endColumn":8,"startOffset":7,"endOffset":8,"message":"This '{' opens the enclosing construct."}],"edit":{"startLine":3,"startColumn":0,"endLine":3,"endColumn":0,"startOffset":18,"endOffset":18,"newText":"}"}}
  [128]

Recovery also derives a *deletion* fix for the unambiguous single-token case: a
stray closing bracket that no open construct matches. Deleting it (and nothing
else) makes the region parse, so the fix removes just that token. Here a `}` too
many at the top level:

  $ cat > stray-brace.wax <<'WAX'
  > fn f() {
  >     nop;
  > }
  > }
  > WAX

  $ wax check --all-errors stray-brace.wax
  Error: Assuming that the attributes are complete, expecting a definition.
   ──➤  stray-brace.wax:4:1
  2 │     nop;
  3 │ }
  4 │ }
    · ^
  5 │ 
  Help: remove this
  [128]

The deletion fix is an edit whose span covers the stray token with an empty
`newText`:

  $ wax check --all-errors --error-format json stray-brace.wax
  {"severity":"error","file":"stray-brace.wax","startLine":4,"startColumn":0,"endLine":4,"endColumn":1,"startOffset":20,"endOffset":21,"message":"Assuming that the attributes are complete, expecting a definition.","warning":null,"hint":null,"related":[],"edit":{"startLine":4,"startColumn":0,"endLine":4,"endColumn":1,"startOffset":20,"endOffset":21,"newText":""}}
  [128]

The deletion fix is deliberately conservative: it fires only when exactly one
structural token is dropped and the parse resumes in place. A stretch of garbage
that recovery skips over many tokens to resynchronize past is never turned into a
"delete these" edit — there is no `Help:` line here, only the plain errors:

  $ cat > garbage.wax <<'WAX'
  > fn f() {
  >     @ ! ~ junk tokens more junk here
  >     nop;
  > }
  > WAX

  $ wax check --all-errors garbage.wax
  Error: Assuming that the statement list is complete, expecting '}'.
   ──➤  garbage.wax:2:5
  1 │ fn f() {
    ·        ^ This '{' opens the enclosing construct.
  2 │     @ ! ~ junk tokens more junk here
    ·     ^
  3 │     nop;
  4 │ }
  Error: Unexpected character '~'.
   ──➤  garbage.wax:2:9
  1 │ fn f() {
  2 │     @ ! ~ junk tokens more junk here
    ·         ^
  3 │     nop;
  4 │ }
  [128]

The two tiers above are derived by the recovery driver. A third tier is
hand-authored: a raise site whose message already names the exact repair carries
that repair as a quick `fix`, and one whose message benefits from extra guidance
carries a prose `hint`. These fire in ordinary (non-recovery) parsing too.

A function or tag declared without a parameter list is the canonical fix: the
message says to write `()`, so the error carries an insertion of `()` at the
caret where the empty signature belongs (right after the name):

  $ cat > no-params.wax <<'WAX'
  > fn f {
  >     nop;
  > }
  > WAX

  $ wax check no-params.wax
  Error: A parameter list is required.
   ──➤  no-params.wax:1:1
  1 │ fn f {
    · ^^^^
  2 │     nop;
  3 │ }
  Help: insert '()'
  [128]

The fix is a zero-width insertion edit; in JSON its `edit` object places `()` at
the caret (the offset just past `fn f`):

  $ wax check --error-format json no-params.wax
  {"severity":"error","file":"no-params.wax","startLine":1,"startColumn":0,"endLine":1,"endColumn":4,"startOffset":0,"endOffset":4,"message":"A parameter list is required.","warning":null,"hint":null,"related":[],"edit":{"startLine":1,"startColumn":4,"endLine":1,"endColumn":4,"startOffset":4,"endOffset":4,"newText":"()"}}
  [128]

Applying that edit by hand — inserting `()` after `fn f` — makes the source parse
cleanly past the error:

  $ cat > with-params.wax <<'WAX'
  > fn f() {
  >     nop;
  > }
  > WAX

  $ wax check with-params.wax

A hint-only site adds prose without a machine edit. An integer literal beyond the
unsigned 64-bit range (a memory limit here) reports the valid range:

  $ cat > big-limit.wax <<'WAX'
  > memory m: i64 [999999999999999999999999999];
  > WAX

  $ wax check big-limit.wax
  Error: The integer literal 999999999999999999999999999 is out of range.
   ──➤  big-limit.wax:1:16
  1 │ memory m: i64 [999999999999999999999999999];
    ·                ^^^^^^^^^^^^^^^^^^^^^^^^^^^
  2 │ 
  Hint:
    This integer must fit in an unsigned 64-bit value (0 to
    18446744073709551615).
  [128]

The hint is serialized as the diagnostic's `hint` field, with no `edit`:

  $ wax check --error-format json big-limit.wax
  {"severity":"error","file":"big-limit.wax","startLine":1,"startColumn":15,"endLine":1,"endColumn":42,"startOffset":15,"endOffset":42,"message":"The integer literal 999999999999999999999999999 is out of range.","warning":null,"hint":"This integer must fit in an unsigned 64-bit value (0 to 18446744073709551615).","related":[]}
  [128]

A lexer-level raise carries a hint the same way. An unterminated block comment
explains the missing closer, in both Wax (`*/`) and WAT (`;)`):

  $ cat > open-comment.wax <<'WAX'
  > fn f() {
  >     /* never closed
  > }
  > WAX

  $ wax check open-comment.wax
  Error: Malformed comment.
   ──➤  open-comment.wax:4:1
  2 │     /* never closed
  3 │ }
  4 │ 
      ^
  Hint: A block comment must be closed with '*/'.
  [128]

  $ cat > open-comment.wat <<'WAT'
  > (module (; never closed
  > WAT

  $ wax check open-comment.wat
  Error: Malformed comment.
   ──➤  open-comment.wat:2:1
  1 │ (module (; never closed
  2 │ 
      ^
  Hint: A block comment must be closed with ';)'.
  [128]

A malformed Unicode escape names the well-formed shape (Wax and WAT alike):

  $ cat > bad-escape.wax <<'WAX'
  > data d = "\u{110000}";
  > WAX

  $ wax check bad-escape.wax
  Error: Malformed Unicode escape.
   ──➤  bad-escape.wax:1:11
  1 │ data d = "\u{110000}";
    ·           ^^^^^^^^^^
  2 │ 
  Hint:
    A Unicode escape has the form '\u{XXXX}', where 'XXXX' is the hexadecimal
    code of a Unicode scalar value.
  [128]
