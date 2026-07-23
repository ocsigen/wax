(* A delimiter-coexistence grammar: the case the generic-pair derivation
   exists for. Two bracket pairs share the '['
   kind — a plain '[' ']' and a compound '[|' '|]' — and nest in either order.
   The kind-based balance scan cannot tell them apart (it would pair a plain ']'
   with a '[|' opener and walk straight through an invisible '|]'); the exact
   opener<->closer pairs derived from these productions keep them distinct, so a
   hint inside a '[|' names '[|' and a hint inside a '[' names '['. *)

%token <int> INT
%token LBRACK "["
%token RBRACK "]"
%token LBRACKPIPE "[|"
%token RBRACKPIPE "|]"
%token COMMA ","
%token EOF

%start <unit> main

(* Fold a completed element list before reporting, so an unclosed bracket reads
   "Assuming that the elements are complete, expecting ']'." and carries the
   opener hint — the shape that pins the full-alias underline. *)
%on_error_reduce elems

%%

main:
  | e = expr EOF { ignore e }

expr:
  | INT { () }
  | "[" elems "]" { () }
  | "[|" elems "|]" { () }

(* A nullable, right-recursive element list, so '[]' / '[||]' are valid and a
   dangling opener folds an empty list into the hedge. *)
elems:
  | { () }
  | expr { () }
  | expr "," elems { () }
