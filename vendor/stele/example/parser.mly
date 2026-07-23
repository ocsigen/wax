(* A tiny calculator grammar: the template a stele adopter copies. It exercises
   every feature the generator keys on:
   - aliased delimiters ['('/')'/'{'/'}'], so the derived delimiter hint fires;
   - a nullable stdlib list ([stmts]) sitting before a required '}', folded by
     [%on_error_reduce] into the "Assuming that the … are complete, …" hedge;
   - short enumeration heads a hand override can improve.

   The semantic actions evaluate the program (a '{'-delimited block of
   ';'-terminated expressions) to the list of statement values, so [calc] is a
   real little interpreter; but the error messages depend only on the grammar's
   *shape*, so evaluating changes none of them. *)

%token <int> INT
%token PLUS "+"
%token STAR "*"
%token SEMI ";"
%token LPAREN "("
%token RPAREN ")"
%token LBRACE "{"
%token RBRACE "}"
%token EOF

%start <int list> prog

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
  | LBRACE s = stmts RBRACE EOF { s }

(* A nullable, right-recursive statement list before the required '}'. *)
stmts:
  | { [] }
  | v = stmt r = stmts { v :: r }

stmt:
  | e = expr SEMI { e }

expr:
  | i = INT { i }
  | LPAREN e = expr RPAREN { e }
  | a = expr PLUS b = expr { a + b }
  | a = expr STAR b = expr { a * b }
