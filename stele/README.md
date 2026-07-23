# stele

Machine-generated, user-friendly syntax-error messages for any
[Menhir](https://gitlab.inria.fr/fpottier/menhir) grammar.

Menhir can attach a hand-written message to every error state
(`--list-errors` / `--compile-errors`), but writing hundreds of them by hand,
and keeping them current as the grammar evolves, is the hard part. stele
generates the messages from the grammar itself and guards them with promoted
golden files, so a grammar change shows up as a reviewable message diff rather
than as silent staleness.

It powers the error messages of both grammars in the
[Wax](https://github.com/ocsigen/wax) toolchain (WebAssembly text and the Wax
language).

New here? Start with [TUTORIAL.md](TUTORIAL.md): a ten-stage walkthrough
that takes a tiny calculator grammar from menhir's bare "Syntax error" to
the full setup, with the same error shown improving at every stage. Its
final state is the tested example in `test/`.

> Two honest caveats. The message templates are English-only. And the
> heuristics are validated on exactly two grammars, so adopters will find edges.

## What it produces

From a grammar's `--list-errors` sentences and its `.cmly`, for each error
state:

- an **Expecting** list of the legal continuations, computed from the real
  grammar (productions, nullability, FIRST sets), rendered with readable names
  and a `<= 5` cap ("Expecting ')', ';', or an operator.");
- a **delimiter hint** anchored at the opening `(` / `[` / `{` of the construct
  the error sits inside ("`<2>This '{' opens the enclosing construct.`"), whose
  `<N>` marker the runtime helper resolves against the live parser stack;
- a **hedge** for a state reached past an `%on_error_reduce` fold ("Assuming
  that the statements are complete, expecting '}'."), carrying a **subject
  marker** `<^1>these statements` that the runtime helper resolves to an
  underline spanning the whole construct the hedge assumes complete;
- a **hand override** for the handful of states heuristics cannot serve.

It also self-checks: a **soundness oracle** verifies every claimed continuation
against the automaton, and a **state-correspondence** check confirms the
`.messages` state numbering matches the `.cmly`'s (the property that lets stele
validate its two inputs against each other; keep it in mind when debugging).

## The pipeline (dune rules)

The generator is a build-time tool. Wire four menhir/stele steps; see
[`test/dune`](test/dune) for the complete, runnable miniature. In outline:

```lisp
; 1. representative error sentences, one per error state
(rule (with-stdout-to g.auto.messages
        (run menhir %{dep:parser.mly} --list-errors)))

; 2. the exact grammar (--no-code-generation keeps --cmly from running the
;    code back-end, which would need dune's type inference)
(rule (target g.cmly) (deps parser.mly)
      (action (run menhir %{dep:parser.mly} --cmly --no-code-generation --base g)))

; 3. the generated messages, comments stripped and sorted — the golden projection
(rule (with-stdout-to g.actual
        (run %{project_root}/stele/generate_error_messages.exe generate
             --no-comments --cmly %{dep:g.cmly} --config %{dep:parser_messages.config}
             --overrides %{dep:parser_messages.overrides} %{dep:g.auto.messages})))
(rule (alias runtest) (action (diff parser_messages.expected g.actual)))

; 4. the full messages (with comments), compiled into a Parser_messages module
(rule (with-stdout-to g.messages
        (run %{project_root}/stele/generate_error_messages.exe generate
             --cmly %{dep:g.cmly} --config %{dep:parser_messages.config}
             --overrides %{dep:parser_messages.overrides} %{dep:g.auto.messages})))
(rule (with-stdout-to parser_messages.ml
        (run menhir %{dep:parser.mly} --compile-errors %{dep:g.messages})))
```

`Parser_messages.message : int -> string` is what the parser calls at an error.

## The command line

stele is a `Cmd.group` of subcommands, one per output: `generate`
(`--no-comments` for the golden projection), `stats`, `census`, `names`,
`fallbacks`, `suggest-classes`, and `transitions`. Each takes the same inputs — the required
`--cmly FILE`, the optional `--config FILE` / `--overrides FILE`, and the
positional `.messages` file — so every command line reads
`stele <command> --cmly g.cmly [--config …] [--overrides …] g.messages`. Run
`stele --help` or `stele <command> --help` for the man pages. A subcommand runs
exactly one mode; the modes do not compose in a single invocation (the earlier
single-dash CLI concatenated their output, but nothing used the combination).

One further command, `stele tune`, is itself a group (`dead` / `advise` /
`calibrate`) with a different input shape — it generates the `.cmly` and
`.messages` itself, per trial, from a `--grammar FILE.mly` via a `--menhir`
subprocess. See [The annotation tuner](#the-annotation-tuner).

## The three-goldens promote loop

stele emits three views of the same generation; pin each as a promoted golden:

| Golden | Mode | What it pins |
|---|---|---|
| `parser_messages.expected` | `stele generate --no-comments` | the sentence to message projection (sorted by sentence, so a state renumber does not churn it) |
| `parser_messages.stats.expected` | `stele stats` | the quality counters and self-lints (the ratchet) |
| `parser_messages.census.expected` | `stele census` | the distinct message bodies with counts (the compact wording surface) |

The loop for any grammar or generator change: `dune runtest`, read the three
diffs, then `dune promote`. A message diff you agree with is fine; a **stats**
counter moving the wrong way without a message-diff justification means the
change regressed quality. Never hand-edit a `.expected` file.

Useful modes while working:

- `stats` prints the counters: entries, with-an-expected-list, fallbacks (empty
  and over-cap, split by whether an override covers them), delimiter hints,
  missed hints, jargon, cascade depth, and the oracle lines (`state/automaton
  item-set match`, `unsound claims`, uncovered actions). It ends with one
  **dormancy line per configured class**, in file order:

  ```
  class "an operator": collapsed in 33 entries
  ```

  `N` is how many entries had the class collapse fire in their computed expected
  list (two or more members co-occurring). It counts the collapse computation,
  not the shown text: an override or an over-cap overflow may supersede the
  phrase, yet the class is live while its members co-occur. `N = 0` is legitimate
  (a class waiting for a qualifying state), but the ratchet now makes a class
  going quiet after a grammar change visible as a stats diff. A grammar with no
  classes prints no such line.
- `census` prints each distinct message body once with its occurrence count,
  the delimiter-hint depth normalized to `<_>`, so sentence re-picking at most
  bumps a count and a wording change is a one-line diff.
- `names` reviews how every symbol reaches its wording: a table of each symbol
  that surfaces in the emitted messages with its rendered form, the pipeline
  step that produced it (token alias, `[names]` entry, the list-element chase,
  the Assuming-subject plural rendering, the lowercase auto-derivation, a
  `[class]` label, or the quoted-lowercase fallback), and how often it appears
  in the Expecting list versus the Assuming subject. Usage is counted per
  position because a symbol can render differently in each (a list name
  singularises via the chase in the Expecting list but keeps its plural as a
  subject) and a `[names]` entry can be dead in one position yet live in the
  other. After the table it lists any `[names]` entries whose curated phrase won
  in neither position. The audit surface for two directions: awkward auto-derived
  or fallback renderings that deserve a `[names]` entry (a quoted-lowercase
  fallback that is not a real keyword — the token name shown as if it were
  literal syntax), and `[names]` entries nothing uses. `stats` mirrors the
  second half as the ratchet: a `names configured: X, unused: Y` line plus one
  indented per-position line per fully-unused entry, so an entry going quiet
  becomes a golden diff.
- `fallbacks` prints a ready-to-paste `.overrides` block for every
  generic-fallback ("Syntax error") state not yet overridden. Empty output means
  every fallback is covered, the condition the stats ratchet pins at zero.
- `suggest-classes` proposes new `[class]` blocks for the config. It clusters
  unclassed terminals by their **signature** (the set of entries whose raw
  expected list mentions them); terminals with the identical signature always
  co-occur, so collapsing them never drops a token a single state needed. It
  keeps clusters of three or more, ranks them by how many entries the collapse
  newly fits under the cap (then by list-item reduction), and emits paste-ready
  blocks with impact `#` comments and a `<LABEL>` placeholder:

  ```
  # cluster of 5 tokens co-occurring in 6 state(s); collapsing them
  # newly fits 4 entrie(s) under the <=5 cap and removes 24 list item(s).
  [class <LABEL>]
  BLOCK
  IF
  LOOP
  TRY
  TRY_TABLE
  ```

  Like every command it needs `--cmly`. Because arithmetic
  and comparison operators are often legal in exactly the same states, they share
  a signature and land in one cluster; splitting them into two readable labels is
  the human decision the config records.

## Day-to-day commands (in the wax tree)

Every stele mode is wired as a per-grammar dune alias, defined once in the
shared `src/lib-wasm/dune.menhir` and instantiated by both grammar directories,
so you never retype the four artifact paths (and cannot silently drop
`--overrides`). Prefix the alias with the grammar directory: `src/lib-wasm` for
the WebAssembly text grammar, `src/lib-wax` for the Wax language grammar.

| Alias | Example run | Answers |
|---|---|---|
| `names` | `dune build @src/lib-wasm/names` | how every symbol reaches its wording, and any unused `[names]` entry |
| `fallbacks` | `dune build @src/lib-wax/fallbacks` | which fallback states still need an override (empty output means none) |
| `suggest-classes` | `dune build @src/lib-wasm/suggest-classes` | candidate `[class]` blocks worth adding to the config |
| `transitions` | `dune build @src/lib-wax/transitions` | the raw per-state continuation dump (debug) |
| `tune-dead` | `dune build @src/lib-wasm/tune-dead` | which `%on_error_reduce` annotations are dead (slow: tens of seconds) |
| `tune-advise` | `dune build @src/lib-wax/tune-advise` | ranked single `%on_error_reduce` moves (slow: tens of seconds) |

Each alias re-runs and re-prints on every invocation (a `(universe)` dep), so
there is nothing to clean between runs. The four inspection aliases are cheap.
The two `tune` aliases re-run menhir once per trial (pinned to the switch's
`menhir` via `%{bin:menhir}`) and take tens of seconds, so they run only when
asked; `tune-advise` also reads the `.overrides` file to price each move's rot
cost, `tune-dead` does not.

## The `.overrides` file

A per-grammar sidecar of hand-written messages for states heuristics cannot
serve (chiefly enumeration heads whose FIRST set overflows the cap). It is keyed
by the **sentence**, which is stable across state renumbering, and merged after
generation. Format: blocks separated by blank lines; within a block, `#` lines
are comments, the first surviving line is the `entry_point: sentence` header,
and the rest is the replacement body (one message line, optionally followed by a
`<N>This '(' opens …` delimiter-hint line).

**Rot guard.** An override whose sentence matches no live error state fails the
build, so the file cannot drift silently. When a grammar change births a new
fallback, run `-list-fallbacks`, paste the block, and write the message in place
of the placeholder.

## The config format

Everything grammar-specific that is not derivable from the `.cmly` lives in the
`-config` sidecar, so the generator itself is grammar-agnostic. It is a small
line format: `#` comments and blank lines anywhere, `[section]` headers, one
entry per line. Absent, the generator falls back to no curated names, no
classes, and alias-only delimiter hints. Four sections (all optional):

```
# Readable names for symbols whose auto-derived rendering would be jargon or
# grammatically wrong. NAME = readable phrase.
[names]
IDENT = an identifier
stmts = statements

# Token classes collapsed to one readable label before the <=5 cap. One member
# terminal per line; a class fires only when >=2 of its members are legal in a
# state, so a lone member keeps its own spelling. The header repeats per class.
[class an operator]
PLUS
STAR

# Extra opener-name nets for the missed-hint lint, keyed by opener character.
# A token whose ALIAS begins with the opener character is recognized already;
# these catch openers by name pattern. OPENER_CHAR KIND ARG, KIND in
# prefix | suffix | exact.
[opener-nets]
( prefix LPAREN
{ exact LBRACE

# Escape hatch for the structural wrapper classification. A parametric-rule
# base head (the text before '(') listed here always classifies as a
# menhir-generated wrapper and is expanded through its productions, even when
# the structural test (list- or option-shaped body) would keep it opaque. One
# head per line. Empty for both real grammars — their parameterized symbols are
# all genuine wrappers the structural test already recognises; it exists for a
# grammar whose home-grown combinator the test misjudges.
[wrappers]
my_list_combinator
```

Delimiter **closers** need no config at all: a terminal whose alias *ends* with
`)` / `]` / `}` is a closer of that kind, mirroring the opener rule (an alias
*beginning* with `(` / `[` / `{`), so a multi-character delimiter like `[|` /
`|]` is recognized just as a compound opener like `(then` is. A grammar that
aliases its delimiters gets hints for free; one that does not simply gets none.

The exact **opener↔closer pairs** are derived from the grammar's productions,
not guessed from the shared bracket kind: in each production a closer mates the
nearest still-open opener of the same character (a stack pop over the
right-hand side), collected over every production. The balance scan then pairs
per exact token, so a plain `[` `]` and a compound `[|` `|]` that share the `[`
kind stay distinct — a `]` never matches a `[|`, and an invisible `|]` no longer
walks the scan past the wrong opener. The hint names, and the runtime underlines,
the opener's full alias: a closer with a unique mate prints that mate verbatim
(`This '[|' opens …`, underlined two columns), a closer with several mates
(wasm's `)` pairs with `(`, `(then`, `(param`, …) falls back to the shared
opener character. The `[|`/`|]` coexistence is exercised by the `delim` test
grammar under `stele/test/delim/`.

The config is per-grammar: every entry must name a symbol that grammar actually
has, so two grammars do not share one file.

**Rot guard.** Like the `.overrides` file, the config is checked at load (in
every config-consuming mode, which already reads the `.cmly`). A `[class]`
member that is not a terminal, a `[names]` key that is neither a terminal nor a
nonterminal, an `[opener-nets]` pattern that matches no terminal, or a
`[wrappers]` head that is the base of no parameterized nonterminal is a hard
error naming the file, section, and stale entry, so a config left behind by a
grammar change fails the build instead of firing on nothing. Use
`stele suggest-classes` to discover new classes worth adding, and
`stele names` to audit the whole naming surface.

## Naming

How a symbol becomes words in a message, in precedence order:

1. A token alias renders as the quoted alias: `')'`, `'(export'`.
2. A `[names]` config entry renders as its phrase.
3. In the "Expecting" position, a list-shaped nonterminal is chased to its
   leftmost mandatory symbol, so the message names one element (or the
   leading keyword) instead of the list: "a parameter" rather than
   "a parameter list". The chase only fires when every non-empty production
   starts with the same symbol; a list with several distinct element openers
   keeps its list name, which is the honest reading.
4. A lowercase nonterminal is auto-derived: underscores become spaces and an
   article is added (`condition_expression` reads "a condition expression").
   A plural head drops the article and agrees in the "Assuming that the X
   are complete" template.
5. A `[class LABEL]` collapses its member tokens into the label.
6. An unaliased ALL-CAPS terminal falls back to its quoted lowercase name.
   This is right for keywords (`'func'`, `'mut'`) and wrong for value tokens
   (an identifier token would read `'id'` as if the user should type the
   letters). The jargon lint flags multi-word cases; single-word cases need
   the `stele names` audit.

The practical consequence: **your nonterminal names are the message
vocabulary**. The generator deliberately keeps a user-named nonterminal
opaque, saying "an expression" rather than enumerating its FIRST set, so a
name that reads as a noun phrase is a better error message with no further
work.

Three techniques follow:

- **Add a rule purely to name a construct.** Instead of inlining a wrapper
  at the use site:

  ```
  structure: "{" separated_list_trailing(",", structure_type_field) "}"
  ```

  factor it through a named nonterminal:

  ```
  structure: "{" l = structure_type "}"
  structure_type: separated_list_trailing(",", structure_type_field)
  ```

  Messages now say "a structure type" instead of exposing wrapper internals.
  The named rule is also a valid `%on_error_reduce` target, which gives the
  hedge a good subject. Do not `%inline` such a rule: an inlined rule
  vanishes from the automaton, and the name only exists if the nonterminal
  does.

- **Name the element of a list.** A list rule whose element is spelled out
  inline chases to the element's first token; factoring the element into its
  own rule makes the chase land on the construct name:

  ```
  exports: /* empty */ | n = export r = exports
  export: "(export" n = name ")"
  ```

  renders "an export" where the inline form rendered `'(export'`.

- **Split a shared rule to unblend contexts.** When one nonterminal serves
  several syntactic homes, menhir gives it merged error states whose
  lookahead set is the union over all homes, and the message lists
  continuations from contexts the user cannot be in. Example: a
  `function_type` rule used both by a declaration (`fn f() -> t { ... }`,
  where only `->` and `{` can follow) and as a type inside expressions
  (where the surrounding expression's operators follow) produces one state
  whose message offers both.

  The preferred fix is a **phantom parameter** (Pottier, "Reachability and
  Error Diagnosis in LR(1) Parsers", CC 2016, §4 "Selective Duplication").
  Parameterize the rule with an unused formal and instantiate it at each home
  with a distinct argument:

  ```
  function_type(ctx):                (* ctx is unused — a phantom *)
    | "(" p = parameter_list ")" ioption("->" result_type) { ... }
  ```

  used as, say, `function_type(TYPE)` at the type homes and
  `function_type(FN)` at the declaration. Any two distinct symbols the
  grammar already uses will do as arguments: the parameter never appears in
  the body, and the instantiation name never reaches a message, so the
  choice is cosmetic; pick evocative ones and leave a comment. (Fresh empty
  marker nonterminals also work but make menhir warn that they are
  unreachable, and there is no flag to silence that warning class.) Menhir
  expands the two instantiations to distinct automaton nonterminals with
  their own LR items, so the states stop merging and each home gets its own
  precise message ("Expecting '->', or '{'." for the declaration). One
  definition, no copies to keep in step.
  stele renders the instantiation opaquely by its base name ("a function
  type"), because it classifies wrappers structurally (list- or option-shaped
  bodies), not by the '(' in the name; a phantom split is neither shape, so it
  stays a named construct. (If the structural test ever misjudged a real
  wrapper as a construct, the `[wrappers]` config section forces it to expand.)

  The **textual-duplication fallback** does the same split without a
  parameter, for a grammar that cannot use the phantom form: copy the rule
  under a second name with identical productions
  (`function_signature: | "(" p = parameter_list ")" { ... } | ...`). Distinct
  nonterminals, distinct LR items, same effect; the cost is keeping the two
  copies in step. The symptom to hunt for either form: a message mixing
  vocabularies no single context accepts. Nothing mechanical flags this class
  (a hand-written override saying too much is sound token by token), so it is
  found by reading the census, or an override against its own sentence.

  `%on_error_reduce` on the shared rule is the lighter alternative when
  the state has a completed production: the spurious reduction's goto
  lands in a context-specific state, so the report unblends without
  duplicating anything. The trade: continuations still inside the
  construct fold into the hedge ("Assuming that the function type is
  complete, expecting '{'." hides the '->' option), so prefer the
  annotation when the completed reading dominates, and duplication when
  in-construct continuations must stay visible.

- **Alias every token with its source spelling**, including multi-character
  openers (`"(then"`, `"(@if"`). Aliases feed both the rendering and the
  delimiter-hint machinery for free.

Prefer a grammar rename over a `[names]` entry when both would work; the
config entry is for names that are right for the grammar but wrong for
prose.

## The runtime helper

A generated message may carry two marker kinds, both a 1-based index `N` into the
parser's stack suffix: a **delimiter hint** `<N>This '(' opens …` and a **hedge
subject** `<^N>this expression`. Resolving either needs the running parser's
environment, so the adopter's error handler does it, once, via the
`stele.runtime` library (`Parser_error_runtime`). It is a functor over the
minimal slice of a Menhir incremental engine it needs, and depends on `menhirLib`
and the standard library only (so it compiles under `js_of_ocaml` /
`wasm_of_ocaml` too):

```ocaml
module R = Parser_error_runtime.Make (struct
  type 'a env = 'a MenhirInterpreter.env
  type element = MenhirInterpreter.element
  let get = MenhirInterpreter.get
  let positions (MenhirInterpreter.Element (_, _, p1, p2)) = (p1, p2)
end)

(* At a HandlingError checkpoint, with [env] the error environment: *)
let main_message, labels =
  R.resolve ~source ~env (Parser_messages.message state)
(* [labels] carries, per marker: for <N>, a span at the opening delimiter as
   wide as the alias the label names (one column for a plain '(', two for a
   compound '[|'; walked back over blanks when the cell's start is not itself the
   delimiter); for <^N>, the whole construct's span (however many lines it
   crosses — the diagnostic renderer draws a multi-line span as a spine — and
   dropped when zero-width — an epsilon reduction),
   each with the marker's label text. Labels come back in emission order,
   subject before delimiter hint. *)
```

The two markers extend one vocabulary compatibly: a resolver that understands
only `<N>` leaves a `<^N>` line inline (the `^`-tagged depth fails its integer
parse), so a newer generator's output stays readable to an older helper.

## The annotation tuner

`stele tune` is a read-only advisor for a grammar's `%on_error_reduce` list. It
recommends single add/remove moves; it never applies them and never touches the
source tree. It is wired into no runtest alias (the three promoted goldens
already guard the committed state); run it on demand when the grammar has grown.

Each trial re-runs `menhir` (a subprocess: `--list-errors` and `--cmly`) on a
scratch copy of the grammar with one annotation added or removed, then
regenerates the messages **in-process** (the same generator internals the other
modes use) and classifies the move by its effect on the quality counters. The
scratch directory is removed on exit, on failure, and on Ctrl-C, so the source
tree is byte-identical after any run.

Three subcommands, all sharing `--grammar FILE.mly` (the source, copied and
mutated in scratch), `--config`, and `--menhir CMD` (default `menhir`; a clear
error if not executable):

```
stele tune dead     --grammar g.mly [--config g.config]
stele tune advise   --grammar g.mly [--config g.config] [--overrides g.overrides]
stele tune calibrate --grammar g.mly [--config g.config] --verdicts g.verdicts
```

- **dead** — remove each current annotation; one whose removal leaves the stats,
  census, and message projection all unchanged is dead and reported for deletion.
- **advise** — rank every single move (removing a current annotation, or adding
  one for a nonterminal reduced somewhere in the automaton) by its stats-vector
  delta. Each improving move is priced by its **override-rot cost** — the
  `--overrides` sentence keys the trial's state re-pick would strand; a move whose
  whole win lands on already-overridden states is reported separately as
  `RELOCATES-OVERRIDDEN`.
- **calibrate** — replay a recorded keep/remove log (`--verdicts`); removing each
  `keep` annotation and re-adding each `removed` one must score non-improving.
  Reports the agreement fraction and every disagreement. The verdicts format is
  one `keep NONTERMINAL` / `removed NONTERMINAL` per line, `#` comments and blanks
  ignored; the wax/wasm prune-audit logs ship as
  [`examples/wax.verdicts`](examples/wax.verdicts) and
  [`examples/wasm.verdicts`](examples/wasm.verdicts) (50/50 and 25/25 agreement).

**Why trials run override-free.** Changing the annotation list merges/renumbers
states, so `menhir --list-errors` re-picks its per-state representative sentence,
which can make a sentence-keyed `.overrides` entry fail the generator's rot guard
and kill the trial. So every generation here runs *without* overrides, baseline
and trials alike; the would-be-overridden states then sit uniformly on both sides
of every comparison. Consequence: `advise`'s "over 5" fallback figure is the raw
pre-override number (18 wasm / 34 wax), not the post-override 0. The overrides are
still read (via `--overrides`) only to price each move's rot cost.

**The wax toolchain runs two grammars** — one command each:

```
stele tune advise --grammar src/lib-wasm/parser.mly \
  --config src/lib-wasm/parser_messages.config \
  --overrides src/lib-wasm/parser_messages.overrides
stele tune advise --grammar src/lib-wax/parser.mly \
  --config src/lib-wax/parser_messages.config \
  --overrides src/lib-wax/parser_messages.overrides
```

## Layout

```
stele/
  dune                       ; the `stele` executable
  generate_error_messages.ml ; the generator (incl. the `stele tune` subcommand)
  parse_messages.ml{,i}      ; the --list-errors parser (a module of the exe)
  examples/                  ; the annotation-tuner calibration logs
    wax.verdicts  wasm.verdicts
  runtime/                   ; the stele.runtime helper library
    parser_error_runtime.ml{,i}
    dune
  test/                      ; the toy calc grammar (the copyable template)
    parser.mly  calc.config  calc.overrides
    calc.expected  calc.stats.expected  calc.names.expected
    calc-rot.config  calc-rot.expected  ; the config rot-guard case
    dune
  README.md
```
