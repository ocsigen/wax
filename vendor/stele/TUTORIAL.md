# Tutorial: from "Syntax error" to meaningful messages

This walkthrough takes a tiny calculator grammar from
[Menhir](https://gitlab.inria.fr/fpottier/menhir)'s bare "Syntax error" to the
full stele setup, one feature at a time. We follow three broken inputs all the
way through:

| Input | Text | What is wrong |
|---|---|---|
| A | `{ (1 }` | an unclosed parenthesis inside a block |
| B | `{ 1; ) }` | a stray token where a statement or `}` should be |
| C | `)` | garbage where the program should start |

Every message shown below is real output from the stage that produced it.

The tutorial ends at the `example/` directory, with the same grammar, lexer,
driver, config, overrides and dune rules, all checked by `dune runtest`. When
anything here is unclear, those files are the reference.

**Before you start.** You should be able to run `menhir` and `dune`, and it
helps to have written a Menhir grammar before.

## Stage 1: every error is "Syntax error"

Here is a minimal calculator grammar, with bare tokens. A program is a
`{ ... }` block of expressions, each ending in `;`:

```
%token <int> INT
%token PLUS STAR SEMI LPAREN RPAREN LBRACE RBRACE EOF
%start <int list> prog
%left PLUS
%left STAR
%%
prog:       | LBRACE s = stmts RBRACE EOF { s }
stmts:      | { [] } | v = stmt r = stmts { v :: r }
stmt:       | e = expression SEMI { e }
expression: | i = INT { i } | LPAREN e = expression RPAREN { e }
            | a = expression PLUS b = expression { a + b }
            | a = expression STAR b = expression { a * b }
```

The semantic actions evaluate each expression, so `calc` is a real little
interpreter. That part does not matter here: error messages depend only on the
grammar's rules.

All three inputs fail the same way, with `Parser.Error`, which most drivers show
as "Syntax error". The parser knows which tokens it would have accepted, but
none of that reaches the user.

## Stage 2: generate a message for every error state

Hooking stele into the build takes four dune rules. Here they are, taken from
[`example/dune`](example/dune) without the options that later stages add:

```lisp
(rule (with-stdout-to calc.auto.messages
  (run menhir %{dep:parser.mly} --list-errors)))

(rule (target calc.cmly) (deps parser.mly)
  (action (run menhir %{dep:parser.mly} --cmly --no-code-generation --base calc)))

(rule (with-stdout-to calc.messages
  (run stele generate --cmly %{dep:calc.cmly} %{dep:calc.auto.messages})))

(rule (with-stdout-to parser_messages.ml
  (run menhir %{dep:parser.mly} --compile-errors %{dep:calc.messages})))
```

In order, they:

1. list every *error state* (each specific way the parse can fail), with one
   sample input per state;
2. dump the grammar in a machine-readable form, the `.cmly` file;
3. have stele write one message per error state;
4. compile those messages into a `Parser_messages` module. Its function
   `Parser_messages.message : int -> string` maps an error state's number to
   its message. When the parser fails, your driver reads the current state
   number from Menhir's incremental API (`I.current_state_number env`) and looks
   up the message, as stage 4 shows.

Input A now says:

```
Expecting 'plus', 'rparen', or 'star'.
```

The content is already right (`;` is correctly missing, since we are inside
parentheses), but the words are token names, not what the user typed.

Input B says `Expecting 'rbrace' or a stmt.` The "a stmt" comes from the rule
name: a lowercase rule is shown as its name with an article, so grammar names
leak straight into the message.

Both are naming problems, and the next stages fix them in the grammar and
its config.

## Stage 3: alias the tokens so messages show source syntax

Give every fixed-spelling token an **alias**, the text the user types:

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

Two things happened:

- the tokens now read as source syntax;
- a **delimiter hint** appeared, with no extra work. A token aliased `)` is
  paired with the token aliased `(`, and stele finds that opener on the parser's
  stack.

The `<2>` means "position 2 on the stack". The next stage turns it into an
underline.

## Stage 4: underline the source at run time

The `<N>` marker can only be resolved while the parser is running, by the
runtime helper in the `stele.runtime` library. Instantiate its functor over
your parser's incremental API and call it from your error handler. This is from
the example's driver, [`example/calc.ml`](example/calc.ml):

```ocaml
module I = Parser.MenhirInterpreter

module R = Parser_error_runtime.Make (struct
  type 'a env = 'a I.env
  type element = I.element

  let get = I.get
  let positions (I.Element (_, _, p1, p2)) = (p1, p2)
end)

(* In the HandlingError case, with the error [env] in hand: *)
let msg = Parser_messages.message (I.current_state_number env) in
let main, labels = R.resolve ~source ~env msg
```

`labels` holds a source span and a text for each marker. Pass the message
and the labels to a source-diagnostics renderer (such as
[Grace](https://github.com/johnyob/grace)), and input A now reads:

```
Error: Expecting ')', '*', or '+'.
 --> input:1:6
1 | { (1 }
  ·      ^
  ·   ^ This '(' opens the enclosing construct.
```

The same helper also handles a second marker, `<^N>`, which the next stage
introduces. Where `<N>` underlines an opening delimiter, `<^N>` underlines a
whole construct. See [The runtime helper](README.md#the-runtime-helper) in the
README for the details.

## Stage 5: assume a finished list is complete

Input B says `Expecting '}' or a stmt.` That is true, but it reads as if the
stray `)` were a statement gone wrong. More likely, the user has finished the
statements and meant to close the block. The message also has no delimiter
hint: the parser is somewhere inside a list of any number of statements, so it
cannot tell how far down its stack the `{` is.

The `%on_error_reduce` annotation tells menhir to finish (to "fold") a construct
it has fully read before reporting the error. stele can then phrase the message
in terms of that finished construct. Add one line to the grammar:

```
%on_error_reduce stmts
```

Input B now says:

```
Assuming that the stmts are complete, expecting '}'.
<^1>these stmts
<2>This '{' opens the enclosing construct.
```

This is a **hedge**. It is generated from menhir's own record of the fold, so it
never claims more than the parser did. Stage 7 fixes the wording "the stmts".

The delimiter hint is there too: once the statements are folded into one list,
the `{` sits right below it on the stack.

The `<^1>` line is the **hedge subject**. At run time it becomes an underline
beneath the finished statement list, labelled `these stmts`. If the list is
empty there is nothing to underline, so the label is dropped and the hedge
stands alone.

## Stage 6: review every message change in a diff

The messages are now part of your code, so test them like code. Two more rules
compare the generated messages with a committed golden file, and `dune promote`
accepts a change once you have reviewed it:

```lisp
(rule (with-stdout-to calc.actual
  (run stele generate --no-comments --cmly %{dep:calc.cmly} %{dep:calc.auto.messages})))
(rule (alias runtest) (action (diff calc.expected calc.actual)))
```

`--no-comments` removes the state numbers and sorts the messages by their
sample input. Renumbered states then change nothing in the diff, and a new
construct adds only its own entries. From now on, `dune runtest` shows
you how each grammar change affects the messages before you commit it.

## Stage 7: fix the wording in a config file

Grammar-specific wording goes in a small config file, passed with `--config`:

```
[names]
stmts = statements

[class an operator]
PLUS
STAR
```

- The `[names]` entry fixes the hedge. Input B now says "Assuming that the
  statements are complete, ...".
- The `[class]` groups the two operators under one label wherever both are
  legal. Input A becomes:

  ```
  Expecting ')' or an operator.
  <2>This '(' opens the enclosing construct.
  ```

A class is used only when at least two of its members are legal, so a lone `+`
keeps its own spelling.

If an entry names a symbol the grammar no longer has, the build fails with an
error naming the entry.

Before adding a `[names]` entry, consider renaming the rule in the grammar
instead. The README's [Naming](README.md#naming) section explains when each is
right.

## Stage 8: override the messages that do not help

Input C fails in the very first state, where the generated message can only
name the start symbol: `Expecting a prog.` That is true, but it does not tell
the user what to type.

For states like this, write the message by hand in an overrides file, passed
with `--overrides`. Each override is keyed by the state's sample input:

```
prog: STAR
Expecting a program: a '{' block.
```

The key is checked on every build. If a grammar change removes the state or
changes its sample input, the build fails and names the override to fix.

On a large grammar, `stele fallbacks` prints a ready-to-paste override for every
state whose message is just "Syntax error". calc has none, and the command says
so:

```
0 fallback state(s) without an override
```

## Stage 9: catch quality regressions

`stele stats` summarises everything measurable: how many states have a real
Expecting list, how many hedges and hints there are, whether any message claims
a token is legal when it is not, unused classes, and unused names.

Pin it as a second golden file (`calc.stats.expected`). A change that makes
the messages worse then shows up as a worse counter in `dune runtest`, even when
the message diff looks plausible.

Two more commands help when a diff needs a closer look:

- `stele census` lists each distinct message once, with a count;
- `stele names` shows how each symbol is turned into words, and which rule did
  it.

## Stage 10: retune the annotations as the grammar grows

As the grammar grows, the best set of `%on_error_reduce` annotations changes.
`stele tune` tries out changes without touching your files:

```
stele tune dead    --grammar parser.mly --config calc.config
stele tune advise  --grammar parser.mly --config calc.config --overrides calc.overrides
```

- `dead` finds annotations whose removal changes nothing.
- `advise` tries adding or removing each annotation, measures the effect, and
  ranks the results. It also flags changes whose whole benefit lands on states
  you already overrode by hand.

On calc, `advise` suggests one change: removing `stmts`, which turns input B's
hedge back into a plain list. It comes with a caveat: the list would read
"Expecting '}' or a stmt.", so `stmt` first needs a readable name, such as a
`[names]` entry. Its wording diff also shows what the counts miss: input B
would lose its delimiter hint again. Weighing that is your call, which is why
the tuner only recommends.

It only recommends. The decisions stay with you, and the golden files show you
their consequences.

## Where you ended up

The [`example/`](example/) directory holds this tutorial's final state:

- the grammar [`parser.mly`](example/parser.mly), the lexer
  [`lexer.mll`](example/lexer.mll), and the driver
  [`calc.ml`](example/calc.ml);
- the sidecars [`calc.config`](example/calc.config) and
  [`calc.overrides`](example/calc.overrides);
- the dune rules, in [`dune`](example/dune);
- the generator's golden files [`calc.expected`](example/calc.expected),
  [`calc.stats.expected`](example/calc.stats.expected),
  [`calc.census.expected`](example/calc.census.expected) and
  [`calc.names.expected`](example/calc.names.expected), and the tuner's advice,
  [`calc.tune-advise.expected`](example/calc.tune-advise.expected);
- the driver's output on one good and three broken inputs, as `calc.run.*`.

It builds a runnable `calc` you can point at a file. The three inputs now
read:

```
$ calc ok.calc
=> 7
=> 9

$ calc unclosed.calc
Error: Expecting ')' or an operator.
 --> unclosed.calc:1:6
1 | { (1 }
  ·      ^
  ·   ^ This '(' opens the enclosing construct.

$ calc stray.calc
Error: Assuming that the statements are complete, expecting '}'.
 --> stray.calc:1:6
1 | { 1; ) }
  ·      ^
  ·   ^^ these statements
  · ^ This '{' opens the enclosing construct.

$ calc garbage.calc
Error: Expecting a program: a '{' block.
 --> garbage.calc:1:1
1 | )
  · ^
```

`dune runtest` checks these four outputs against `calc.run.*.expected`, so
this final state cannot drift from what stele does.

The method builds on François Pottier's *Reachability and Error Diagnosis in
LR(1) Parsers* (CC 2016), the paper behind Menhir's `--list-errors`. Several of
the conventions you just saw come from it; see the README's
[Credit](README.md#credit) section.
