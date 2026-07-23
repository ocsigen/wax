(* The calc lexer: turns source text into the tokens [parser.mly] declares.
   Positions are tracked ([new_line] on each newline) so the driver can point a
   diagnostic at the exact column. A character that starts no token is itself a
   (lexical) error, reported the same way as a parse error. *)

{
open Parser

exception Lex_error of string
}

let digit = ['0'-'9']
let white = [' ' '\t']

rule token = parse
  | white+      { token lexbuf }
  | '\n'        { Lexing.new_line lexbuf; token lexbuf }
  | digit+ as n { INT (int_of_string n) }
  | '+'         { PLUS }
  | '*'         { STAR }
  | ';'         { SEMI }
  | '('         { LPAREN }
  | ')'         { RPAREN }
  | '{'         { LBRACE }
  | '}'         { RBRACE }
  | eof         { EOF }
  | _ as c      { raise (Lex_error (Printf.sprintf "unexpected character %C" c)) }
