(* A tiny calculator grammar: the template a stele adopter copies. It exercises
   every feature the generator keys on:
   - aliased delimiters ['('/')'/'{'/'}'], so the derived delimiter hint fires;
   - a nullable stdlib list ([stmts]) sitting before a required '}', folded by
     [%on_error_reduce] into the "Assuming that the … are complete, …" hedge;
   - short enumeration heads a hand override can improve. *)

%token <int> INT
%token PLUS "+"
%token STAR "*"
%token SEMI ";"
%token LPAREN "("
%token RPAREN ")"
%token LBRACE "{"
%token RBRACE "}"
%token EOF

%start <unit> prog

(* Usual arithmetic precedence, so the ambiguous [expr op expr] rules carry no
   conflicts (a clean template). *)
%left PLUS
%left STAR

(* Fold a completed statement list before reporting the error, so a program with
   a stray token where the block should close reads "Assuming that the
   statements are complete, expecting '}'." rather than listing statement heads. *)
%on_error_reduce stmts

%%

prog:
  | LBRACE stmts RBRACE EOF { () }

(* A nullable, right-recursive statement list before the required '}'. *)
stmts:
  | { () }
  | stmt stmts { () }

stmt:
  | e = expr SEMI { ignore e }

expr:
  | INT { () }
  | LPAREN expr RPAREN { () }
  | expr PLUS expr { () }
  | expr STAR expr { () }
