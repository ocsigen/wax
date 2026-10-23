(* A grammar whose %on_error_reduce declarations a line-based reader would get
   wrong: they are indented, split over several declarations and lines, carry
   comments and a parameterized symbol, and the text "%on_error_reduce" also
   appears in places that are not declarations, including after a type with a
   '<' inside it. One annotation is on an %inline symbol, which menhir ignores.
   `stele tune` must find exactly the annotations menhir reports, report the
   ignored one as dead, and edit them in place. *)

%{
  (* Not a declaration: %on_error_reduce stmt *)
  let _ = "%on_error_reduce stmt"
%}

%token <int> INT
%token PLUS "+"
%token SEMI ";"
%token LBRACE "{"
%token RBRACE "}"
%token EOF

%start <unit> main

/* Not a declaration either: %on_error_reduce expr */
%type <[< `A | `B ] -> unit> unused_type_holder

%left PLUS

  %on_error_reduce expr
%on_error_reduce
  (* a comment inside the declaration *)
  list(stmt)
  block
%on_error_reduce plus

%%

main:
  | list(stmt) EOF {}

stmt:
  | expr SEMI {}
  | block {}

block:
  | LBRACE list(stmt) RBRACE {}

expr:
  | INT {}
  | expr plus expr {}

%inline plus:
  | PLUS {}

unused_type_holder:
  | INT { fun _ -> () }
