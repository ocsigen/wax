(* A grammar whose rule names exercise how stele turns names into words: a
   camelCase rule, a singular noun ending in 's', a list whose element pluralises
   with -ies, an option used as a hedge subject, and a phantom-parameterized
   rule named by a [names] entry on its base name (see naming.config). *)

%token <string> ID
%token LBRACE "{"
%token RBRACE "}"
%token SEMI ";"
%token COLON ":"
%token AT "@"
%token TYPE "type"
%token EOF

%start <unit> main

%on_error_reduce list(entry) option(annotation)

%%

main:
  | TYPE typeAlias access block EOF {}

typeAlias:
  | ID {}

access:
  | COLON ID {}

block:
  | LBRACE list(entry) RBRACE {}

entry:
  | ID COLON fieldType(SEMI) option(annotation) SEMI {}

(* [ctx] is a phantom: it only gives this use its own states. *)
fieldType(ctx):
  | ID {}

annotation:
  | AT ID {}
