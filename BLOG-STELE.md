---
title: "Stele: Parser Error Messages You Can Test Like Code"
date: 2026-07-23 12:00:00+02:00
categories: [Compilers, Parsing]
tags: [ocaml, menhir, parsing, error-messages, webassembly]
description: We stopped hand-writing the Wax toolchain's parser error messages and started generating them from the grammar, then guarding them like code with golden files, a soundness oracle, and a tuner. Stele packages this for any Menhir grammar.
draft: true
slug: "stele"
---

<!-- Draft: venue TBD (Tarides blog or a discuss.ocaml.org announcement),
     alongside the opam publication. Numbers reflect the state at writing time. -->

Here is what the Wax toolchain's WebAssembly text parser used to say when
you wrote `(v128.const)` and forgot the shape:

```
Syntax error
```

Here is what it says now:

```
Expecting a v128 shape: 'i8x16', 'i16x8', 'i32x4', 'i64x2', 'f32x4', or 'f64x2'.
```

And when a `(global $g` is cut short:

```
Assuming that the exports are complete, expecting a global type, or an
inline import.
 --> input.wat:4:13
4 |   (global $g)
  ·             ^
```

This post is about how we got there, and about stele, the tool we
extracted so any Menhir grammar can do the same.

## The approach in one paragraph

Menhir lets you attach a message to every error state of the LR automaton
(`--list-errors`, `--compile-errors`). That machinery, and much of the
method here, comes from François Pottier's CC 2016 paper "Reachability and
Error Diagnosis in LR(1) Parsers", which enumerated every error state of
CompCert's C parser and hand-wrote a complete, maintained message
collection for it. stele mechanizes what the paper left to the human
expert. The catch the paper's experts absorbed by hand is scale: our two
grammars have 680 and 541 error states, and they change every time the
grammar does. So we stopped writing messages and started generating them
from the grammar itself, then treated the output like code: promoted
golden files pin every message, a census golden pins the distinct
wordings, and a stats golden pins every measurable quality property, so
`dune runtest` fails on any regression. Hand-written text survives only
where heuristics cannot serve, in a small overrides file whose entries
fail the build if the grammar moves under them. Nothing depends on
discipline; everything is a diff you review.

## What the generator knows

The generator reads two artifacts Menhir already produces: the error
sentences (`--list-errors`) and the compiled grammar (`--cmly`, via
menhirSdk). From those it derives, per error state:

- the expected continuations, computed with real nullability so a message
  can see past an optional list to the `'}'` behind it;
- readable names: token aliases render as source syntax, a list-shaped
  nonterminal renders as one element ("a parameter", not "a parameter
  list"), everything else as a noun phrase derived from its rule name;
- delimiter hints: a token aliased `)` pairs with the `(` aliases
  automatically, and the message carries a marker that a small runtime
  library resolves to an underline under the exact unclosed opener;
- hedges: when `%on_error_reduce` folds a completed construct before the
  error is reported, the message says so honestly: "Assuming that the
  statements are complete, expecting '}'." This hypothetical form is the
  paper's own convention ("If this expression is complete, then ..."),
  and the fold-then-report idea is its "spurious reductions considered
  beneficial" section.

Two facts keep the generated text trustworthy. A soundness oracle checks
every claim against the automaton itself: a message may only announce a
token the state really accepts. Both grammars sit at zero unsound claims,
and the check is pinned in the ratchet. And where generation gives up, it
gives up loudly: a state whose expected list overflows what a human can
read degrades to a counter that must be zero unless a hand-written
override covers it. Fifty-three overrides later, no state in either
grammar says just "Syntax error".

## Numbers over adjectives

The campaign that produced all this was measured at every step. A few of
the results:

- 1,221 error states across the two grammars, every one with a reviewed
  message; 225 and 182 distinct message bodies.
- 332 delimiter hints, each resolving to an underline under the right
  opener, including compound ones like `(@if` and `(export`.
- The `%on_error_reduce` lists were audited by removal trial: 37 of 75
  annotations turned out to hide more than they helped and were dropped,
  cutting hedged messages from 153 to 122 while every other counter held.
- The audit is now a tool. `stele tune` replays it: dead-annotation
  sweep, a ranked advisor for additions and removals, and a calibration
  mode that reproduces the human audit's 75 verdicts at 100%.

## Three war stories

Honesty section. The machinery above did not spring fully formed, and
its best parts exist because something embarrassing surfaced.

**The hedge that never fired.** Menhir marks spurious reductions in its
error sentences, and our hedge template was driven by that marker. For an
*empty* production the marker line ends right at the arrow, and our
parser of that line required a space after it. Result: every "assuming
the list is empty" hedge silently never fired, and messages dropped
tokens with no compensation. Nobody noticed until a human read a two-line
diff and asked "why no Assuming here?". The fix was one character class;
hedged messages jumped from 65 to 86 and from 48 to 67. The lesson is
pinned as a counter now.

**'id'.** For months, thirty-one messages said things like "Expecting
'(export', or 'id'." That quoted `'id'` reads as syntax, as if you should
type the letters i and d. It was the renderer's last-resort fallback for
an unaliased token that nobody had named, and it looked plausible enough
that five review passes sailed past it. A human asked "why 'id' and not
'an identifier'?" The answer became a subcommand: `stele names` prints
every symbol that reaches a message, the rendering it got, which pipeline
stage produced it, and whether a configured name is stale. The message
now says "an identifier ('$...')".

**The advisor that had to learn humility.** The tuner's first advisor
ranked five annotation changes as improvements. A human review declined
all five: each "win" merely displaced a state whose message was already
hand-written, which the advisor could not see because trials must run
without overrides. So the advisor now prices every move's override impact
and classifies a move whose whole gain lands on overridden states as
relocating them, not improving anything. Recommend, never apply, and say
what you cannot judge.

**The feature we had turned off.** The deepest cut: Wax's grammar had a
commented-out production, the one making a block's final semicolon
optional, with a note that it ruined the error messages. That was true
when it was written; nobody could say precisely how anymore. With the
tooling in place we measured it: one regression, exactly located - a
missing semicolon *between* statements stopped saying "expecting ';'"
and started blaming the block's closing brace, because the error fold
now ran past the statement. Three designs later (a reader caught two
more regressions in the diffs: the machine-applicable "insert ';'" fix
vanished, and the unclosed-brace pointer went with it), the fix was a
grammar restructure that stops the fold at the statement: the feature
is on, the missing-semicolon message got *better* ("expecting ';', or
'}'" - the brace is honestly legal now), and the recovery fix and
which-brace pointer are untouched. Total reviewed diff: one line.
Error-message quality had been a reason to constrain the language;
now it is a measured property you can negotiate with.

## Your grammar's names are your messages

The single highest-leverage discovery needs no tooling at all. The
generator deliberately renders a user-named nonterminal as a noun phrase
instead of enumerating its FIRST set, which means the quality of your
messages is the quality of your rule names. When a list's element is
spelled inline, the message can only show its first token; factor it into
a named rule and the message names the construct:

```
exports:
  | { [] }
  | n = inline_export r = exports { n :: r }
inline_export:
  | "(export" n = name ")" { n }
```

and the messages that showed the raw opener `'(export'` now say "an
inline export" instead. Add a rule purely to name a thing, and never
`%inline` it: the name only exists if the nonterminal does. The
state-splitting variant of the same move, where a rule shared by several
contexts is duplicated so each context stops sharing one error state and
one blended message, is the paper's "selective duplication"; stele's
naming guide covers it, and when `%on_error_reduce` is the lighter
alternative.

## Try it

Stele is a standalone opam package: the generator, the golden and census
and stats modes, the overrides mechanism with its rot guard, the runtime
library for the underlines, and the tuner. It works with any Menhir
grammar; a grammar that merely aliases its delimiter tokens gets hints on
day one.

The tutorial takes a fifteen-line calculator from "Syntax error" to the
full setup in ten stages, with the same broken input shown improving at
every stage, and its final state is the repository's tested example, so
it cannot drift from the truth.

Two caveats, stated in the README too: the message templates are
English-only, and the heuristics are validated on exactly two grammars.
You will find edges; the goldens will show them to you.

One more idea came straight from the paper. CompCert's messages echo the
recognized construct back at the user ("Up to this point, an expression
has been recognized: 'c * 255.0'"). stele points instead of echoing: a
hedge now underlines the construct it assumes complete, in the margin,
alongside the unclosed-opener underline the hints already had:

```
Assuming that the argument list is complete, expecting ')'.
  .            ^^^^ this argument list
  .           ^ This '(' opens the enclosing construct.
```

If you want the mechanics rather than the story, the companion post,
[*Inside Stele*](/posts/stele-internals/), walks through each algorithm and its
invariant.

## References

- François Pottier, [Reachability and Error Diagnosis in LR(1)
  Parsers](https://inria.hal.science/hal-01417004), CC 2016. Menhir's
  `--list-errors` is that paper's reachability algorithm, so if you use stele
  you are using it too.
- [Menhir](https://gitlab.inria.fr/fpottier/menhir), François Pottier and
  Yann Régis-Gianas.
