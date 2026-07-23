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

The rest of this file is a systematic end-to-end corpus (ERROR-MESSAGES.md step
6): one real-source fixture per message *shape* the generator pipeline can
produce, exercising the full chain — the message text, the `<N>` depth-marker
resolution against the live parser stack, and the delimiter underline position.
Each case names the shape it pins and the step (1–5) that introduced it.

--- Delimiter hints: caret lands on the innermost open delimiter (step 1a/1d) ---

The `<N>` marker is the riskiest link: the generator computes a stack-cell depth
and the runtime resolves it via MenhirInterpreter.get, so an off-by-one would
visibly misplace the caret. Here three parens are open — `(module`, `(global`,
`(mut` — and the ')' hint must point at the *innermost* one (`(mut`, column 17),
not the module or global paren:

  $ wax check nested.wat
  Error: Expecting ')'.
   ──➤  nested.wat:1:26
  1 │ (module (global (mut i32 i32)))
    ·                          ^^^
    ·                 ^ This '(' opens the enclosing construct.
  2 │ 
  [128]

The same depth resolution for a '}' closer with nested braces: the inner `do {`
block is the one left open, so its '{' (line 2) is underlined, not the enclosing
function body's '{'. The hedge is the %on_error_reduce statement-list reduction
(step 4/4b):

  $ wax check nested-brace.wax
  Error: Assuming that the statement list is complete, expecting '}'.
   ──➤  nested-brace.wax:4:5
  1 │ fn f() {
  2 │   do {
    ·      ^ This '{' opens the enclosing construct.
  3 │     nop;
  4 │     @
    ·     ^
  5 │   }
  6 │ }
  [128]

A '}' delimiter hint on a Wax structure-type field list, hedged by the
%on_error_reduce fold of the completed first field (a hedge + hint combined, the
step-7 census's largest shape family):

  $ wax check struct-type.wax
  Error: Assuming that the structure type is complete, expecting '}'.
   ──➤  struct-type.wax:1:19
  1 │ type t = { a: i32 b: i32 };
    ·                   ^
    ·          ^ This '{' opens the enclosing construct.
  2 │ 
  [128]

A ']' hint on an array-body literal, again hedge + hint — the third closer kind,
completing `)` / `}` / `]` coverage:

  $ wax check array.wax
  Error: Assuming that the array body is complete, expecting ']'.
   ──➤  array.wax:1:27
  1 │ fn f() { let a = [1, 2, 3 }; }
    ·                           ^
    ·                  ^ This '[' opens the enclosing construct.
  2 │ 
  [128]

--- The "Assuming …" hedge: the epsilon case (step 4 regex fix) ---

A hedge whose completed construct is *empty*: `(global $g)` has no exports, so
the parser reduces the empty `exports` list and reports past it. The step-4
`parse_messages.ml` regex fix (`… ->` with no trailing space) is what keeps the
hedge from being silently dropped here, so the elided '(export' opener is
signalled rather than vanishing. This is also the pluralised-wrapper subject
shape ("the exports are complete", step 4's clean subject_name rendering):

  $ wax check global.wat
  Error:
    Assuming that the exports are complete, expecting a global type, or an
    inline import.
   ──➤  global.wat:1:19
  1 │ (module (global $g))
    ·                   ^
  2 │ 
  [128]

A non-empty completed construct in the same hedge template, on the WAT side: the
block type `(result i32)` is complete, so the message names it and points the
hint back at its `(block` opener:

  $ wax check block-type.wat
  Error:
    Assuming that the block type is complete, expecting ')', or instructions.
   ──➤  block-type.wat:1:35
  1 │ (module (func (block (result i32) end extra)))
    ·                                   ^^^
    ·               ^ This '(' opens the enclosing construct.
  2 │ 
  [128]

--- Singular element wording in the Expecting position (step 3b) ---

A list-shaped nonterminal is rendered as one element where the user types one
next: `string_list` → "a string" (here inside a `(@string …)` annotation):

  $ wax check string.wat
  Error: Expecting ')', or a string.
   ──➤  string.wat:1:28
  1 │ (module (func (@string "a" 5)))
    ·                            ^
  2 │ 
  [128]

`folded_instructions` → "a folded instruction" (an extra operand after a folded
instruction's arguments):

  $ wax check folded.wat
  Error: Expecting ')', or a folded instruction.
   ──➤  folded.wat:1:52
  1 │ (module (func (i32.add (i32.const 1) (i32.const 2) 3)))
    ·                                                    ^
  2 │ 
  [128]

`exports` → the singular compound token `'(export'` (a bare number where a
func's optional export clause or id belongs):

  $ wax check export-head.wat
  Error: Expecting an identifier ('$...'), or an inline export.
   ──➤  export-head.wat:1:15
  1 │ (module (func 5))
    ·               ^
  2 │ 
  [128]

--- Operator-class rendering (step 1e / step 5) ---

The `#[if(…)]` conditional-compilation grammar collapses its comparison tokens
into one readable class, "a comparison operator":

  $ wax check cmp-op.wax
  Error: Expecting '(', ')', ',', or a comparison operator.
   ──➤  cmp-op.wax:1:14
  1 │ #[if(VERSION 1)]
    ·              ^
  2 │ fn f() {}
  3 │ 
  [128]

--- Hand-override messages (step 5) ---

The WASM enumeration heads carry curated category messages instead of a bare
"Syntax error". A top-level bare '(' names the module-field keywords:

  $ wax check module-field.wat
  Error:
    Expecting a module field: 'func', 'global', 'table', 'memory', 'tag',
    'data', 'elem', 'start', 'rec', or 'module'.
   ──➤  module-field.wat:2:1
  1 │ (
  2 │ 
      ^
  [128]

A '(' opening an import descriptor names that set (including 'item'):

  $ wax check import-desc.wat
  Error:
    Expecting an import descriptor: 'func', 'memory', 'table', 'global', 'tag',
    or 'item'.
   ──➤  import-desc.wat:1:22
  1 │ (module (import "m" (5)))
    ·                      ^
  2 │ 
  [128]

The residual misleading bare "Expecting '(result'." on a tag's type use is
overridden to reveal that the type use may also continue or end (state 127):

  $ wax check tag-result.wat
  Error: Expecting another '(result' group, an instruction, or ')'.
   ──➤  tag-result.wat:1:27
  1 │ (module (tag (result i32) 5))
    ·                           ^
  2 │ 
  [128]

The Wax expression-FOLLOW states all share one uniform override — after a
complete expression the parser accepts an infix operator, a postfix operator, or
a closer ending it, a set that always overflows the readable cap. This also
exercises the "an operator" operator-class name:

  $ wax check expr-follow.wax
  Error:
    Expecting an operator, a postfix operator ('.', '[', '(', '!', 'as', 'is',
    'on', or '?'), or the end of the expression.
   ──➤  expr-follow.wax:1:18
  1 │ const x = 1 == 2 3;
    ·                  ^
  2 │ 
  [128]

The Wax labeled-block head (`'l:` must be followed by a block) is a bespoke
override:

  $ wax check labeled-block.wax
  Error:
    Expecting a labeled block: 'do', 'while', 'loop', 'if', 'try', or
    'try_legacy'.
   ──➤  labeled-block.wax:2:7
  1 │ fn f() {
  2 │   'l: 5
    ·       ^
  3 │ }
  4 │ 
  [128]
