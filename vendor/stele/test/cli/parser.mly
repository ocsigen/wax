(* A small expression language with more binary operators than the five-item
   cap, so that some states fall back to "Syntax error": the review commands
   (fallbacks, suggest-classes, transitions) and the overrides checks have
   something to work on. *)

%token <int> INT
%token PLUS "+"
%token MINUS "-"
%token STAR "*"
%token SLASH "/"
%token LT "<"
%token GT ">"
%token LPAREN "("
%token RPAREN ")"
%token SEMI ";"
%token EOF

%start <unit> main

%left LT GT
%left PLUS MINUS
%left STAR SLASH

%%

main:
  | list(stmt) EOF {}

stmt:
  | expr SEMI {}

expr:
  | INT {}
  | LPAREN expr RPAREN {}
  | expr PLUS expr {}
  | expr MINUS expr {}
  | expr STAR expr {}
  | expr SLASH expr {}
  | expr LT expr {}
  | expr GT expr {}
