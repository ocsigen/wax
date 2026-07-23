---
title: "Inside Stele: The Algorithms Behind Generated Parser Error Messages"
date: 2026-07-23 12:00:00+02:00
categories: [Compilers, Parsing]
tags: [ocaml, menhir, parsing, error-messages, lr-parsing]
description: A walk through stele's passes over a Menhir grammar: the continuation walk, the symbol-to-words pipeline, delimiter pairing and the stack scan, hedges past a fold, the soundness oracle, golden-file stability, and the tuner. Each step is a small algorithm with a stated invariant.
draft: true
slug: "stele-internals"
---

<!-- Draft: companion to the announcement post. Re-verify against the shipped
     code before publishing. -->

The [announcement post](/posts/stele/) tells the story; this one explains the
machinery. stele turns two artifacts Menhir already produces into error messages,
and every step in between is a small algorithm with a stateable
invariant. This post walks through each one: what question it answers,
what rule it applies, and why the rule is safe.

The two inputs:

- the error sentences (`menhir --list-errors`): one representative token
  sentence per error state of the LR(1) automaton, each annotated with
  the state's items, the known stack suffix, and any spurious reductions
  performed on the way. This enumeration is François Pottier's
  reachability algorithm (CC 2016); stele consumes its output and does
  not re-derive it.
- the compiled grammar (`menhir --cmly`, read with menhirSdk): exact
  productions, nullability, FIRST sets, token aliases, and the LR(1)
  automaton itself (items, transitions, reductions per state).

Everything below is a pass over these. Nothing is asymptotically
interesting; both grammars in the home repository (680 and 541 error
states) regenerate in well under a second. The content is in the
invariants.

## What can come next

**Question.** In error state S, which symbols may come next?

The state's LR(1) items say it directly, but rawly: each item is a
production with a dot, and the answer is the union over items of "what
the dot can move over". The walk, per item:

- Take the symbols after the dot, left to right.
- A menhir-generated wrapper is expanded through its productions; a
  user-named nonterminal is kept opaque. This is the single most
  important rendering decision in stele: the message will say "an
  expression", never the forty tokens an expression can start with.
- If the symbol is nullable, the walk may continue past it to the next
  symbol: after an optional list, the closing brace behind it is a
  legitimate continuation.
- When the dot reaches the end of the production, the item's lookahead
  set is the continuation.

**Which nonterminals count as "generated"?** Not by name. A
parameterized instantiation (`option(X)`, `separated_list(SEP,X)`, but
also a user's own `semi_list(X)`) is classified structurally: a body
that is list-shaped (a production recursing through the head, or that is
itself a list wrapper) or option-shaped (an empty production, all others
a single symbol) is a wrapper and expands. Anything else, including a
phantom-parameterized rule used for state splitting, renders opaquely by
its base name. The rule is checked against the grammar, so a user
combinator that behaves like a list is treated like one without any
configuration.

**The cap, and the two-tier policy.** A message may list at most five
alternatives; beyond that it degrades (and a hand override takes over).
Nullability creates a tension: looking past every nullable symbol gives
the most complete answer, but a nullable tail whose FOLLOW is huge
(WebAssembly's instruction set, say) floods the list. stele computes
both answers and picks monotonically: the aggressive walk (skip every
nullable) is used when its result fits the cap; otherwise the
conservative walk (skip only generated wrappers). Because the aggressive
result is a superset of the conservative one, the fallback never drops a
symbol the smaller answer contained. One inequality buys completeness
where it is affordable and honesty where it is not.

## From symbols to words

**Question.** The walk produced `RPAREN`, `separated_list(COMMA,expr)`,
`statement_list`. What words appear in the message?

A precedence chain, first match wins:

1. A token alias renders as the quoted alias: `')'`, `'(export'`.
2. A curated `[names]` entry from the per-grammar config.
3. In the Expecting position, a list-shaped nonterminal is chased to its
   leftmost mandatory symbol: if every non-empty production starts with
   the same symbol, the message names one element ("a parameter") or the
   leading keyword, not the list. A list with several distinct openers
   keeps its list name; the chase refuses to invent an element that the
   grammar does not single out.
4. A lowercase nonterminal auto-derives: underscores become spaces, an
   article is added, a plural head drops the article and switches the
   hedge to "are". Your rule names are your message vocabulary, which is
   why renaming a nonterminal is documentation work in this system.
5. A configured token class collapses its members ("an operator") when
   at least two are legal in the state; a lone member keeps its own
   spelling.
6. An unaliased ALL-CAPS token falls back to its quoted lowercase name.
   Right for keywords, wrong for value tokens; a lint catches the
   multi-word cases and an audit table (`stele names`, which reports
   every rendering with the pipeline stage that produced it and
   per-position usage counts) exists to catch the rest.

## Which bracket is unclosed

**Question.** The state expects `')'`. Which `(` is unclosed, and how do
we tell the user?

Three sub-algorithms:

**Classification.** A token whose alias starts with `(`, `[`, or `{` is
an opener; one whose alias ends with `)`, `]`, or `}` is a closer. This
is how compound openers (`(export`, `(@if`) and compound closers (`|]`)
participate with no configuration.

**Pair derivation.** Kinds are not enough once `[ ]` and `[| |]`
coexist: a kind-level balance scan would happily match `[|` with `]`.
The mates are derived from the grammar instead: in every production, an
opener-classified token is paired with the closer-classified token that
follows it in that production. The result is an exact pair table (one
opener may have several legitimate mates), and the balance scan matches
tokens only against their mates.

**The scan and the marker.** When a closer is expected, stele scans the
state's known stack suffix from the top, balancing per pair, and finds
the unmatched opener. The crucial subtlety is what "position" means: the
suffix is a list of parser stack cells, where an already-reduced
construct (with all its internal, balanced delimiters) occupies a single
cell and is invisible to the balance count. The scan therefore reports a
1-based stack cell index, emitted into the message as `<N>`.

At runtime, a small helper resolves that marker against the live parser: cell N
of the incremental engine's stack carries the opener's source position, and the
CLI underlines it. When the closer has a unique mate, the hint names the mate's
full alias and the underline spans its full width ("This '[|' opens ..."); a
closer with many mates (WebAssembly's ')' closes 22 different openers) names the
shared bracket character. The same mechanism carries a second marker kind,
`<^N>`, for hedge subjects, resolved to the full source span of a folded
construct; a message may carry several labels.

The invariant that makes `<N>` safe: the generator computes depths over
the known stack suffix and never over the raw sentence, because token
positions stop corresponding to stack cells the moment any reduction has
happened.

## What to say after a fold

**Question.** `%on_error_reduce` folded a completed construct before the
error was reported. What may the message claim?

Menhir records the spurious reductions in the error sentence's
annotations. stele turns the outermost one into the hedge subject:
"Assuming that the statements are complete, expecting '}'." The choice
of outermost is not taste: the Expecting tokens are computed in the
post-fold state, whose continuations belong to the outermost frame, so
naming an inner construct would pair a subject with an expectation it
does not have. The hedge phrasing itself is the honesty device, taken
from Pottier's convention: everything after "assuming" is conditional on
an assumption the parser made, not verified fact.

Two edge cases earn their own handling. An empty fold ("assuming the
exports are complete" when zero exports were written) is a real hedge
whose subject has a zero-width span; the message keeps the hedge, the
underline is skipped. And the subject marker always points at the top
post-fold stack cell, verified against the reduction record rather than
assumed.

## Keeping the output honest

Generated text lies in two ways: claiming a continuation the parser
rejects (unsoundness) or omitting one it accepts (incompleteness). Both
are checkable against the automaton in the cmly.

**Soundness.** Every claim that surfaces in a message is checked: a
claimed terminal must have a shift or reduce action in the state (a
default reduction accepts every terminal); a claimed nonterminal M must
have a goto, or FIRST(M) must be included in the state's action set. The
second disjunct is not a relaxation but a correction: a nonterminal
claimed after looking past a nullable prefix acts through the empty
reduction, token by token, and has no goto in that state. The oracle
itself had to learn this; its first run flagged 104 such claims, all
sound.

**Correspondence.** The `.messages` file and the `.cmly` come from two
menhir invocations, so the oracle first proves their state numberings
agree: the LR(0) core item set of state N in one must equal the other's,
for every state. This is cheap and it converts an assumption into a
checked input.

**Rot guards.** Hand-written inputs are checked at build time: an
overrides entry whose key sentence no longer reaches an error state, a
config name for a symbol the grammar lost, a class member that is not a
terminal, an opener net matching nothing: each is a hard build error
naming the stale entry. Hand-written text cannot drift silently; it can
only be wrong out loud.

## Why the diffs stay small

The whole system is reviewed through three promoted golden files, so
their diff behavior under grammar change is itself designed:

- State numbers churn wholesale on any edit, so they are stripped; the
  projection is keyed by the representative sentence and sorted by it,
  making a state renumbering diff zero lines and a new construct diff
  exactly its own entries.
- Sentences themselves are re-picked by `--list-errors` when states
  merge, so a second golden, the census, contains only the distinct
  message bodies with occurrence counts and no sentences at all. A
  re-pick bumps nothing; a wording change is one line; a message
  disappearing outright, the signal that matters most when tuning, is
  one line too. Depth markers are normalized (`<N>` to `<_>`) so one
  wording at different depths stays one census line.
- The stats golden pins every measurable property (fallbacks, hints,
  hedge counts, oracle results, class and name dormancy) as a ratchet:
  a quality regression fails the build even when the message diff reads
  plausibly.

## Tools that recommend, never apply

Two tools recommend rather than apply.

**The annotation tuner** evaluates `%on_error_reduce` changes by trial:
copy the grammar to scratch, toggle one annotation, regenerate, and
compare the stats vector and census against a baseline. Two design
points matter. Trials run without the overrides file, because annotation
changes re-pick sentences and would trip the override rot guard
mid-trial; comparing two override-free views keeps every delta
meaningful. And each move's override impact is priced anyway: sentences
that disappear from the projection are intersected with the override
keys, and a move whose entire counter win lands on hand-overridden
states is classified as merely relocating them. The tool's ranking was
calibrated by replaying a 75-verdict human audit; it reproduces all 75,
with the hint-versus-hedge trades landing in an explicit "needs a human"
class.

**The class suggester** discovers candidate token classes by signature
clustering: for each terminal, the set of error states whose raw
expected list contains it; terminals with identical signatures cluster.
The clusters are exact, not similarity-based, which is what keeps
delimiters from clustering with operators: `+` and `*` are legal in
exactly the same states, `)` is not. Stripping the home grammar's
operator classes and re-running recovers all thirty tokens as one
cluster; that they should be two classes with two labels is semantic
knowledge, which is why the tool emits a paste-ready block with the
label left as a placeholder.

## The pattern underneath

None of these algorithms is deep; most are one fold over the grammar or
the automaton with a stated invariant. The system's property comes from
their composition: exact inputs (the cmly, not name heuristics),
checkable outputs (the oracle, the correspondence proof), reviewable
change (the goldens' diff algebra), and loud staleness (the rot
guards). The tutorial builds the whole pipeline on a fifteen-line
grammar; the code is one OCaml file for the generator and one small
functor for the runtime.

## References

- François Pottier, [Reachability and Error Diagnosis in LR(1)
  Parsers](https://inria.hal.science/hal-01417004), CC 2016.
- [Menhir](https://gitlab.inria.fr/fpottier/menhir), François Pottier and
  Yann Régis-Gianas.
