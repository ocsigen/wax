--error-format=json renders each diagnostic as one JSON object on its own line
(JSON Lines), on stderr, for an editor / CI job / AI assistant to parse. Exit
codes are unchanged.

A type error, as JSON (still exit 128):

  $ wax check --error-format=json bad.wax
  {"severity":"error","file":"bad.wax","startLine":1,"startColumn":16,"endLine":1,"endColumn":19,"startOffset":16,"endOffset":19,"message":"Expecting type 'i32' but got type 'float'.","warning":null,"hint":null,"related":[]}
  [128]

A warning (an unused local) carries its severity and its -W name; exit stays 0:

  $ wax check --error-format=json unused.wax
  {"severity":"warning","file":"unused.wax","startLine":1,"startColumn":20,"endLine":1,"endColumn":21,"startOffset":20,"endOffset":21,"message":"The local variable 'x' is never used.","warning":"unused-local","hint":null,"related":[],"edit":{"startLine":1,"startColumn":20,"endLine":1,"endColumn":20,"startOffset":20,"endOffset":20,"newText":"_"}}

The default output is unchanged, human-readable with a source snippet:

  $ wax check bad.wax
  Error: Expecting type 'i32' but got type 'float'.
   ──➤  bad.wax:1:17
  1 │ fn h() -> i32 { 1.0; }
    ·                 ^^^
  2 │ 
  [128]
