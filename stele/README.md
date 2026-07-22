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
language). The name is provisional.

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
  that the statements are complete, expecting '}'.");
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
        (run %{project_root}/stele/generate_error_messages.exe
             -cmly %{dep:g.cmly} -config %{dep:parser_messages.config}
             -overrides %{dep:parser_messages.overrides}
             -generate-messages -no-comments %{dep:g.auto.messages})))
(rule (alias runtest) (action (diff parser_messages.expected g.actual)))

; 4. the full messages (with comments), compiled into a Parser_messages module
(rule (with-stdout-to g.messages
        (run %{project_root}/stele/generate_error_messages.exe
             -cmly %{dep:g.cmly} -config %{dep:parser_messages.config}
             -overrides %{dep:parser_messages.overrides}
             -generate-messages %{dep:g.auto.messages})))
(rule (with-stdout-to parser_messages.ml
        (run menhir %{dep:parser.mly} --compile-errors %{dep:g.messages})))
```

`Parser_messages.message : int -> string` is what the parser calls at an error.

## The three-goldens promote loop

stele emits three views of the same generation; pin each as a promoted golden:

| Golden | Mode | What it pins |
|---|---|---|
| `parser_messages.expected` | `-generate-messages -no-comments` | the sentence to message projection (sorted by sentence, so a state renumber does not churn it) |
| `parser_messages.stats.expected` | `-stats` | the quality counters and self-lints (the ratchet) |
| `parser_messages.census.expected` | `-census` | the distinct message bodies with counts (the compact wording surface) |

The loop for any grammar or generator change: `dune runtest`, read the three
diffs, then `dune promote`. A message diff you agree with is fine; a **stats**
counter moving the wrong way without a message-diff justification means the
change regressed quality. Never hand-edit a `.expected` file.

Useful modes while working:

- `-stats` prints the counters: entries, with-an-expected-list, fallbacks (empty
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
- `-census` prints each distinct message body once with its occurrence count,
  the delimiter-hint depth normalized to `<_>`, so sentence re-picking at most
  bumps a count and a wording change is a one-line diff.
- `-list-fallbacks` prints a ready-to-paste `.overrides` block for every
  generic-fallback ("Syntax error") state not yet overridden. Empty output means
  every fallback is covered, the condition the stats ratchet pins at zero.
- `-suggest-classes` proposes new `[class]` blocks for the config. It clusters
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

  It composes with the other output modes and needs `-cmly`. Because arithmetic
  and comparison operators are often legal in exactly the same states, they share
  a signature and land in one cluster; splitting them into two readable labels is
  the human decision the config records.

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
classes, and alias-only delimiter hints. Three sections (all optional):

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
```

Delimiter **closers** need no config at all: a terminal aliased `)` / `]` / `}`
is paired with its `(` / `[` / `{` opener automatically. A grammar that aliases
its delimiters gets hints for free; one that does not simply gets none.

The config is per-grammar: every entry must name a symbol that grammar actually
has, so two grammars do not share one file.

**Rot guard.** Like the `.overrides` file, the config is checked at load (in
every config-consuming mode, which already reads the `.cmly`). A `[class]`
member that is not a terminal, a `[names]` key that is neither a terminal nor a
nonterminal, or an `[opener-nets]` pattern that matches no terminal is a hard
error naming the file, section, and stale entry, so a config left behind by a
grammar change fails the build instead of firing on nothing. Use
`-suggest-classes` to discover new classes worth adding.

## The runtime helper

A generated message may carry a `<N>` marker, where `N` is a 1-based index into
the parser's stack suffix. Resolving it needs the running parser's environment,
so the adopter's error handler does it, once, via the `stele.runtime` library
(`Parser_error_runtime`). It is a functor over the minimal slice of a Menhir
incremental engine it needs, and depends on `menhirLib` and the standard library
only (so it compiles under `js_of_ocaml` / `wasm_of_ocaml` too):

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
(* [labels] carries, per <N> marker, a one-character span at the opening
   delimiter (walked back over blanks when the cell's start is not itself the
   delimiter) and the marker's label text. *)
```

## The annotation tuner

[`tune_on_error_reduce.sh`](tune_on_error_reduce.sh) is a standalone review tool
(bash driving menhir plus the generator on a scratch grammar copy; it mutates
nothing and is wired into no runtest alias). It sweeps the grammar's
`%on_error_reduce` list for dead annotations, advises single add/remove moves by
their stats-vector delta and census diff, and can calibrate itself against a
recorded keep/remove log. Run it on demand when the grammar has grown. It
recommends; it never applies.

## Layout

```
stele/
  dune                       ; the `stele` executable
  generate_error_messages.ml ; the generator
  parse_messages.ml{,i}      ; the --list-errors parser (a module of the exe)
  tune_on_error_reduce.sh    ; the annotation tuner
  runtime/                   ; the stele.runtime helper library
    parser_error_runtime.ml{,i}
    dune
  test/                      ; the toy calc grammar (the copyable template)
    parser.mly  calc.config  calc.overrides
    calc.expected  calc.stats.expected
    calc-rot.config  calc-rot.expected  ; the config rot-guard case
    dune
  README.md
```
