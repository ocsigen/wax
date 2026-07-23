# Tutorial: from "Syntax error" to messages worth reading

This walkthrough takes a tiny calculator grammar from menhir's bare parse
failure to the full stele setup, one feature at a time. Three broken inputs
stay with us the whole way, and every message shown below is real output of
the stage that produced it:

- input A: `{ (1 }` (an unclosed parenthesis inside a block)
- input B: `{ 1; ) }` (a stray token where a statement or `}` should be)
- input C: `)` (garbage where the program should start)

The destination is exactly `example/` in the stele tree: the same
grammar, lexer, driver, config, overrides, and dune rules, kept compiling and
golden-checked by `dune runtest`. When in doubt, read those files; the
tutorial is their story.

Prerequisites: you should be able to run `menhir` and `dune`, and it helps to
have written a Menhir grammar before. No parsing theory is assumed, and you do
not need a grammar of your own; we build a tiny one here.

## Stage 1: the starting point

A minimal calc grammar, tokens still bare. The semantic actions evaluate the
program (a `{`-delimited block of `;`-terminated expressions) to the list of
statement values, so `calc` is a real little interpreter; but the error messages
depend only on the grammar's *shape*, so none of what follows turns on the
evaluation:

```
%token <int> INT
%token PLUS STAR SEMI LPAREN RPAREN LBRACE RBRACE EOF
%start <int list> prog
%left PLUS
%left STAR
%%
prog:  | LBRACE s = stmts RBRACE EOF { s }
stmts: | { [] } | v = stmt r = stmts { v :: r }
stmt:  | e = expr SEMI { e }
expr:  | i = INT { i } | LPAREN e = expr RPAREN { e }
       | a = expr PLUS b = expr { a + b } | a = expr STAR b = expr { a * b }
```

All three inputs produce the same thing: `Parser.Error`, rendered by most
drivers as "Syntax error". The parser knows exactly which tokens it would
have accepted; none of that knowledge reaches the user.

## Stage 2: wire the pipeline

Three dune rules connect menhir's error machinery to stele (these are the
first three rules of `example/dune`, minus the options we have not
introduced yet):

```
(rule (with-stdout-to calc.auto.messages
  (run menhir %{dep:parser.mly} --list-errors)))

(rule (target calc.cmly) (deps parser.mly)
  (action (run menhir %{dep:parser.mly} --cmly --no-code-generation --base calc)))

(rule (with-stdout-to calc.messages
  (run stele generate --cmly %{dep:calc.cmly} %{dep:calc.auto.messages})))

(rule (with-stdout-to parser_messages.ml
  (run menhir %{dep:parser.mly} --compile-errors %{dep:calc.messages})))
```

An *error state* is one specific way the parse can fail; a realistic grammar
has hundreds. `--list-errors` enumerates them, giving one sample input per
state; stele generates a message for each from the exact grammar in the `.cmly`
(the machine-readable grammar dump); and `--compile-errors` compiles the result
into a `Parser_messages` module your driver queries by state number. Input A now
says:

```
Expecting 'plus', 'rparen', or 'star'.
```

Already state-exact (`;` is rightly absent: we are inside parentheses), but
the words are token names, not syntax. Input B says `Expecting 'rbrace', or
a stmt.` Note "a stmt": a lowercase nonterminal renders as itself with an
article, so grammar names leak straight into prose. Both problems are
naming problems, and the next stages fix them without touching the
generator.

## Stage 3: alias the tokens

Give every fixed-spelling token its source text:

```
%token PLUS "+"
%token STAR "*"
%token SEMI ";"
%token LPAREN "("
%token RPAREN ")"
%token LBRACE "{"
%token RBRACE "}"
```

Input A becomes:

```
Expecting ')', '*', or '+'.
<2>This '(' opens the enclosing construct.
```

Two things happened. The renderings became source syntax, and a delimiter
hint appeared for free: a terminal aliased `)` pairs automatically with the
`(` opener alias, and stele locates the matching opener on the parser
stack. The `<2>` marker means "stack cell 2"; the next stage turns it into
an underline.

## Stage 4: resolve hints at runtime

The `<N>` marker is resolved against the live parser by the runtime helper
(library `stele.runtime`): instantiate its functor over the slice of your
parser's incremental engine it needs, and call it in your error handler. This is
`calc.ml` in the example:

```ocaml
module I = Parser.MenhirInterpreter

module R = Parser_error_runtime.Make (struct
  type 'a env = 'a I.env
  type element = I.element

  let get = I.get
  let positions (I.Element (_, _, p1, p2)) = (p1, p2)
end)

(* In the HandlingError case, with the error [env] in hand: *)
let main, labels = R.resolve ~source ~env (Parser_messages.message state)
```

`labels` carries a position and text for each marker. Feed the message and those
labels to a source-diagnostics renderer (such as
[Grace](https://github.com/johnyob/grace)) and input A now reads:

```
Error: Expecting ')', '*', or '+'.
 --> input:1:6
1 | { (1 }
  ·      ^
  ·   ^ This '(' opens the enclosing construct.
```

The same helper resolves a second marker kind, `<^N>`, that the next stage
introduces: where `<N>` underlines one opening delimiter, `<^N>` underlines a
whole construct's span. A resolver that only knows `<N>` leaves a `<^N>` line
inline (the `^`-tagged depth fails the integer parse), so the vocabulary
extends compatibly.

See "The runtime helper" in the README for the full signature.

## Stage 5: fold completed lists

Input B still enumerates what a statement may start with. But the user is
standing at a stray token *after* a complete list of statements; they are better
served by hearing where the block should end than by a fresh list of what a
statement can start with. The `%on_error_reduce` annotation tells menhir to
finish (to "fold") any construct it has fully read before it reports the error,
which lets stele phrase the message in terms of that finished construct. One
declaration:

```
%on_error_reduce stmts
```

Now the parser folds the finished statement list before reporting, and
input B says:

```
Assuming that the stmts are complete, expecting '}'.
<^1>these stmts
<2>This '{' opens the enclosing construct.
```

The hedge ("Assuming that ...") is generated from menhir's own record of
the fold, so it never claims more than the parser did. One blemish: "the
stmts". Stage 7 fixes it.

The `<^1>` line is the **hedge subject**: at runtime it becomes an underline
under the construct the hedge assumes complete (here, the finished statement
list), with `these stmts` labelling it in the margin. The `1` is where that
construct sits on the parser stack. An *empty* fold (a completed list that
matched nothing) has nothing to underline, so the runtime drops the label and
the plain hedge stands alone. The census normalizes the depth (`<^_>`) just like
the `<N>` hint's.

## Stage 6: pin the output with goldens

Messages are code now; test them like code. Two more rules diff the
generated output against committed goldens (`dune promote` accepts a
reviewed change):

```
(rule (with-stdout-to calc.actual
  (run stele generate --no-comments --cmly %{dep:calc.cmly} %{dep:calc.auto.messages})))
(rule (alias runtest) (action (diff calc.expected calc.actual)))
```

`--no-comments` strips the state-numbered comments and sorts by sentence,
so the golden is stable under grammar edits: a renumbering diffs zero
lines, a new construct diffs exactly its own entries. From here on, every
change to the grammar shows you its message consequences in `dune runtest`
before you commit it.

## Stage 7: the config sidecar

Grammar-specific wording lives in a small config file passed with
`--config`:

```
[names]
stmts = statements

[class an operator]
PLUS
STAR
```

The `[names]` entry fixes the hedge: input B now says "Assuming that the
statements are complete, ...". The class collapses the two infix operators
wherever both are legal, so input A tightens to:

```
Expecting ')', or an operator.
<2>This '(' opens the enclosing construct.
```

A class only fires when at least two members are legal in a state; a lone
`+` keeps its own spelling. Config entries are rot-guarded: an entry naming
a symbol the grammar no longer has fails the build with a one-line error.
Before adding a `[names]` entry, consider renaming the nonterminal in the
grammar instead; the README's "Naming" section explains when each is right.

## Stage 8: hand-write the stubborn ones

Input C hits the initial state, where the generated message can only name
the start symbol: `Expecting a prog.` True, and useless. States beyond
heuristics get a hand-written message in an `.overrides` file, keyed by the
state's representative sentence:

```
prog: STAR
Expecting a program: a '{' block.
```

Pass it with `--overrides`. The key is checked on every build: if a grammar
change removes or re-keys the state, the build fails and tells you, so an
override can never rot silently. For a large grammar, `stele fallbacks`
prints a ready-to-paste override template for every state whose generated
message degraded to "Syntax error"; calc has none, and the command reports
exactly that:

```
0 fallback state(s) without an override
```

## Stage 9: the quality ratchet

`stele stats` summarizes everything measurable: how many states have a real
expected list, how many hedges and hints, whether any claim is unsound
against the automaton, dormant classes, unused names. Pin it as a third
golden (`calc.stats.expected`) and quality regressions fail `dune runtest`
even when a message diff looks plausible. `stele census` (distinct message
bodies with counts) and `stele names` (every rendering with its provenance
and usage) are the review surfaces when a diff needs judgment.

## Stage 10: keep the annotations honest

As the grammar grows, `%on_error_reduce` choices age. `stele tune` explores
them without touching your tree:

```
stele tune dead    --grammar parser.mly --config calc.config
stele tune advise  --grammar parser.mly --config calc.config --overrides calc.overrides
```

`dead` finds annotations whose removal changes nothing; `advise` ranks
add/remove candidates by measured effect, prices each move's override
impact, and recommends rather than applies: a move whose whole win lands on
hand-overridden states is classified as merely relocating them. Decisions
stay with you; the goldens show you their consequences.

## Where you ended up

The complete files are `parser.mly`, the `lexer.mll` and driver `calc.ml`,
`calc.config`, `calc.overrides`, and `dune`, with the generator goldens
`calc.expected`, `calc.stats.expected`, `calc.names.expected` and the driver's
own output on one good and three broken inputs (`calc.run.*`). That directory is
this tutorial's final state: a runnable `calc` you can point at a file.

```
$ calc ok.calc
=> 7
=> 9
$ calc unclosed.calc
Error: Expecting ')', or an operator.
 --> unclosed.calc:1:6
1 | { (1 }
  ·      ^
  ·   ^ This '(' opens the enclosing construct.
```

Every golden is checked by `dune runtest`, so the story above cannot silently
drift from the truth.
