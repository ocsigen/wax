# TODO

## Detect messages made imprecise by merged states

By default, menhir merges LR(1) states that differ only in their lookahead
sets. A merged state's message then lists tokens that are legal in only some
of the contexts it serves. In the calc example, `{ 1 + 1 }` gets "Expecting
')', ';', or an operator." with no `(` open. Since lookaheads only matter for
reductions, such a token is always one the state accepts by reducing.

Nothing flags these today. The soundness check passes, because the token really
is accepted in the merged state. `stele tune advise` rates the fix below as
neutral, because none of its counters move.

Proposal: also read a `.cmly` built with `--canonical`. Replay each entry's
sample sentence through the canonical tables, and flag every claimed token the
canonical parser rejects after that sentence. Report the count in `stats` (and
the entries, like `listed tokens the parser rejects`), and add it to the
tuner's score so that a move that clears some is "improving". The check is one-sided: it only tests
menhir's sample sentence, so it can miss cases, but anything it flags is a real
wrong message.

Fixes the user can apply once a state is found (checked on calc; the README's
"Merged states" section describes them):

| calc | error states | LR(1) states | `{ 1 + 1 }` |
|---|---|---|---|
| default | 9 | 18 | `')', ';', or an operator` |
| `%on_error_reduce expression` | 8 | 18 | `';' or an operator` |
| phantom split `expression(ctx)` | 14 | 26 | `';' or an operator` |
| `--canonical` | 14 | 26 | `';' or an operator` |

- `%on_error_reduce` on the reduced nonterminal: on an error, the parser does
  the reduction and reports from the context-specific state after the goto.
  Cheap, with the usual trade-off of folding the construct's continuations
  into a hedge.
- A phantom parameter naming the token that closes the context
  (`expression(SEMI)` in a statement, `expression(RPAREN)` inside parentheses,
  threaded through the recursive uses): exact, at the cost of more states, but
  only for the rules that need it.

## Score tuner moves per input, not per state

`stele tune` compares counters summed over error states, so a move can lose
something for one input while another state gains the same thing, and the
counts do not move. On calc, removing `%on_error_reduce stmts` costs input B
(`{ 1; ) }`) its delimiter hint, yet the hint count stays at 2, because the
state for `{ )` gains one. Only the census diff in the report shows it.

Proposal: replay the sample sentences of both the baseline and the trial
through both automata (the `.cmly` tables), so that each input is scored by the
message it gets before and after the move. Report the inputs that lose a hint,
fall back to "Syntax error", or gain jargon, and count them in the verdict.
This needs the same sentence replay as the merged-state check above.

## Goldens that depend on the menhir version

`test/cli/ops.fallbacks.expected` and `test/cli/ops.transitions.expected`
include menhir's state numbers, so a menhir release that renumbers states would
break them. If that happens, consider filtering the numbers out in the dune
rules.
