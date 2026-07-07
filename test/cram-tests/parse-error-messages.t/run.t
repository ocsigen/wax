Parse-error messages name grammar constructs in readable terms. These guard a
few that the message generator (scripts/generate_error_messages.ml) used to
render as internal jargon, a raw Menhir list name, or with a wrong article.

A block-shaped construct is "a block", not "a braced block" / "a blockinstr":

  $ wax check block.wax
  Error:
    Assuming that the condition expression is complete, expecting '=>', or a block.
  
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

A trailing-comma list names its element ("an on clause"), rather than leaking
the raw `separated_nonempty_list_trailing(comma,on_clause)`:

  $ wax check onclause.wax
  Error: Expecting ']', or an on clause.
   ──➤  onclause.wax:2:16
  1 │ fn f() {
  2 │   resume cont [_ => switch 5] ()
    ·                ^
    ·               ^ This '[' might be unmatched.
  3 │ }
  4 │ 
  [128]
