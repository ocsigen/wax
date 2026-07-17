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
