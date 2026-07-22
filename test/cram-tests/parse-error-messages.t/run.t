Parse-error messages name grammar constructs in readable terms. These guard a
few that the message generator (scripts/generate_error_messages.ml) used to
render as internal jargon, a raw Menhir list name, or with a wrong article.

A block-shaped construct is "a block", not "a braced block" / "a blockinstr":

  $ wax check block.wax
  Error:
    Assuming that the condition expression is complete, expecting '=>', or a
    block.
   ──➤  block.wax:2:22
  1 │ #[export = "f"]
  2 │ fn f() -> i32 { if 1 5 }
    ·                      ^
  3 │ 
  [128]

A plural construct drops the article ("memory limits", not "a mem limits"), and
the page-size clause is spelled out:

  $ wax check limits.wax
  Error: Expecting ';', 'shared', a page-size clause, or memory limits.
   ──➤  limits.wax:2:17
  1 │ import "env" {
  2 │   memory m: i32 5
    ·                 ^
  3 │ }
  4 │ 
  [128]

A completed trailing-comma list is named cleanly in the hedge ("the on clauses
are complete"), rather than leaking the raw
`separated_nonempty_list_trailing(comma,on_clause)`:

  $ wax check onclause.wax
  Error: Expecting ']', or an on clause.
   ──➤  onclause.wax:2:18
  1 │ fn f() {
  2 │   c.resume() on [_ => switch 5]
    ·                  ^
    ·                 ^ This '[' opens the enclosing construct.
  3 │ }
  4 │ 
  [128]

The same generator drives the WAT parser. Here the head noun governs agreement
("the list of indices is complete", not "are"), and the "unmatched" hint
underlines just the '(' — not the whole `(elem` region:

  $ wax check indices.wat
  Error: Assuming that the list of indices is complete, expecting ')'.
   ──➤  indices.wat:3:28
  1 │ (module
  2 │   (func $f)
  3 │   (table funcref (elem $f (nop))))
    ·                            ^^^
    ·                  ^ This '(' opens the enclosing construct.
  4 │ 
  [128]

The "unmatched" caret is a single delimiter character even when the opener is a
multi-character token — WAT lexes `(result` (and `(then`, `(param`, …) as one
token. The lexer gives that token the '(' as its start (so the location really
begins at the paren), and the hint shrinks the range to that one character:

  $ wax check result.wat
  Error: Expecting ')', or a value type.
   ──➤  result.wat:1:27
  1 │ (module (func (result i32 $x)))
    ·                           ^^
  2 │ 
  [128]

The delimiter-opener table is derived from the grammar's token aliases, so
compound WAT openers that the old hand-list forgot — here `(descriptor`, from
the custom-descriptors proposal — are hinted too, with the caret on their '(':

  $ wax check descriptor.wat
  Error: Expecting ')'.
   ──➤  descriptor.wat:1:29
  1 │ (module (type (descriptor 0 0)))
    ·                             ^
    ·               ^ This '(' opens the enclosing construct.
  2 │ 
  [128]
