let white = [%sedlex.regexp? Plus (' ' | '\t')]
let newline = [%sedlex.regexp? '\r' | '\n' | "\r\n"]

let ident =
  [%sedlex.regexp?
    xid_start, Star (xid_continue | '\'') | '_', Plus (xid_continue | '\'')]

let sign = [%sedlex.regexp? Opt ('+' | '-')]
let digit = [%sedlex.regexp? '0' .. '9']
let hexdigit = [%sedlex.regexp? '0' .. '9' | 'a' .. 'f' | 'A' .. 'F']
let num = [%sedlex.regexp? digit, Star (Opt '_', digit)]
let hexnum = [%sedlex.regexp? hexdigit, Star (Opt '_', hexdigit)]
let int = [%sedlex.regexp? num | "0x", hexnum]

let decfloat =
  [%sedlex.regexp?
    num, Opt ('.', Opt num), (('e' | 'E'), sign, num) | num, '.', Opt num]

let hexfloat =
  [%sedlex.regexp?
    ( "0x", hexnum, Opt ('.', Opt hexnum), (('p' | 'P'), sign, num)
    | "0x", hexnum, '.', Opt hexnum )]

let float = [%sedlex.regexp? decfloat | hexfloat | "nan:0x", hexnum]

let stringchar =
  [%sedlex.regexp?
    ( Sub (any, (0 .. 31 | 0x7f | '"' | '\\'))
    | "\\t" | "\\n" | "\\r" | "\\'" | "\\\"" | "\\\\"
    | "\\u{", hexnum, "}" )]

let stringelem = [%sedlex.regexp? stringchar | "\\x", hexdigit, hexdigit]
let linechar = [%sedlex.regexp? Sub (any, (10 | 13))]
let linecomment = [%sedlex.regexp? "//", Star linechar, (newline | eof)]
let string_buffer = Buffer.create 256

let rec comment_rec lexbuf =
  match%sedlex lexbuf with
  | "*/" -> Buffer.add_string string_buffer "*/"
  | "/*" ->
      Buffer.add_string string_buffer "/*";
      comment_rec lexbuf;
      comment_rec lexbuf
  | '*' | '/' | Plus (Sub (any, ('*' | '/'))) ->
      Buffer.add_string string_buffer (Sedlexing.Utf8.lexeme lexbuf);
      comment_rec lexbuf
  | _ ->
      raise
        (Wax_wasm.Parsing.Syntax_error
           ( Sedlexing.lexing_bytes_positions lexbuf,
             Printf.sprintf "Malformed comment.\n" ))

let comment lexbuf =
  Buffer.add_string string_buffer "/*";
  comment_rec lexbuf;
  let s = Buffer.contents string_buffer in
  Buffer.clear string_buffer;
  s

let unicode_escape lexbuf s =
  match Wax_utils.Unicode.scalar_of_hex s with
  | Some u -> u
  | None ->
      raise
        (Wax_wasm.Parsing.Syntax_error
           ( Sedlexing.lexing_bytes_positions lexbuf,
             Printf.sprintf "Malformed Unicode escape.\n" ))

let rec string lexbuf =
  match%sedlex lexbuf with
  | '"' ->
      let s = Buffer.contents string_buffer in
      Buffer.clear string_buffer;
      s
  | Plus (Sub (any, (0 .. 31 | 0x7f | '"' | '\\'))) ->
      Buffer.add_string string_buffer (Sedlexing.Utf8.lexeme lexbuf);
      string lexbuf
  | "\\t" ->
      Buffer.add_char string_buffer '\t';
      string lexbuf
  | "\\n" ->
      Buffer.add_char string_buffer '\n';
      string lexbuf
  | "\\r" ->
      Buffer.add_char string_buffer '\r';
      string lexbuf
  | "\\'" ->
      Buffer.add_char string_buffer '\'';
      string lexbuf
  | "\\\"" ->
      Buffer.add_char string_buffer '"';
      string lexbuf
  | "\\\\" ->
      Buffer.add_char string_buffer '\\';
      string lexbuf
  | "\\x", hexdigit, hexdigit ->
      let s = String.sub (Sedlexing.Utf8.lexeme lexbuf) 2 2 in
      Buffer.add_char string_buffer (Char.chr (int_of_string ("0x" ^ s)));
      string lexbuf
  | "\\u{", hexnum, "}" ->
      let n =
        Sedlexing.Utf8.sub_lexeme lexbuf 3 (Sedlexing.lexeme_length lexbuf - 4)
      in
      Buffer.add_utf_8_uchar string_buffer (unicode_escape lexbuf n);
      string lexbuf
  | _ ->
      raise
        (Wax_wasm.Parsing.Syntax_error
           ( Sedlexing.lexing_bytes_positions lexbuf,
             Printf.sprintf "Malformed string.\n" ))

let with_loc f lexbuf =
  let loc_start = Sedlexing.lexing_bytes_position_start lexbuf in
  let desc = f lexbuf in
  {
    Ast.desc;
    info =
      { Ast.loc_start; loc_end = Sedlexing.lexing_bytes_position_curr lexbuf };
  }

open Tokens

let rec token_rec ctx lexbuf =
  match%sedlex lexbuf with
  | white -> token_rec ctx lexbuf
  | newline ->
      Wax_utils.Trivia.report_newline ctx;
      token_rec ctx lexbuf
  | linecomment ->
      let content = Sedlexing.Utf8.lexeme lexbuf in
      Wax_utils.Trivia.report_item ctx Line_comment content;
      token_rec ctx lexbuf
  | "/*" ->
      let s = comment lexbuf in
      Wax_utils.Trivia.report_item ctx Block_comment s;
      token_rec ctx lexbuf
  | ';' -> SEMI
  | "#[if(" -> HASH_IF
  | "#[else]" -> HASH_ELSE
  | "#[likely]" -> LIKELY_HINT
  | "#[unlikely]" -> UNLIKELY_HINT
  | '#' -> SHARP
  | '?' -> QUESTIONMARK
  | '(' -> LPAREN
  | ')' -> RPAREN
  | "{" -> LBRACE
  | '}' -> RBRACE
  | '[' -> LBRACKET
  | ']' -> RBRACKET
  | ',' -> COMMA
  | "::" -> COLONCOLON
  | ':' -> COLON
  | "->" -> ARROW
  | "=>" -> FATARROW
  | '=' -> EQUAL
  | ":=" -> COLONEQUAL
  | "@" -> AT
  | "'" -> QUOTE
  | "." -> DOT
  | ".." -> DOTDOT
  | "!" -> BANG
  | "+" -> PLUS
  | "+=" -> PLUSEQUAL
  | "-" -> MINUS
  | "-=" -> MINUSEQUAL
  | "*" -> STAR
  | "*=" -> STAREQUAL
  | "/" -> SLASH
  | "/=" -> SLASHEQUAL
  | "/s" -> SLASHS
  | "/s=" -> SLASHSEQUAL
  | "/u" -> SLASHU
  | "/u=" -> SLASHUEQUAL
  | "%s" -> PERCENTS
  | "%s=" -> PERCENTSEQUAL
  | "%u" -> PERCENTU
  | "%u=" -> PERCENTUEQUAL
  | '&' -> AMPERSAND
  | "&=" -> AMPERSANDEQUAL
  | '|' -> PIPE
  | "|=" -> PIPEEQUAL
  | '^' -> CARET
  | "^=" -> CARETEQUAL
  | "<<" -> SHL
  | "<<=" -> SHLEQUAL
  | ">>s" -> SHRS
  | ">>s=" -> SHRSEQUAL
  | ">>u" -> SHRU
  | ">>u=" -> SHRUEQUAL
  | "==" -> EQUALEQUAL
  | "!=" -> BANGEQUAL
  | "_" -> UNDERSCORE
  | ">" -> GT
  | ">s" -> GTS
  | ">u" -> GTU
  | "<" -> LT
  | "<s" -> LTS
  | "<u" -> LTU
  | ">=" -> GE
  | ">=s" -> GES
  | ">=u" -> GEU
  | "<=" -> LE
  | "<=s" -> LES
  | "<=u" -> LEU
  | "null" -> NULL
  | "inf" -> INF
  | "nan" -> NAN
  | "tag" -> TAG
  | "fn" -> FN
  | "mut" -> MUT
  | "type" -> TYPE
  | "rec" -> REC
  | "open" -> OPEN
  | "nop" -> NOP
  | "unreachable" -> UNREACHABLE
  | "do" -> DO
  | "while" -> WHILE
  | "loop" -> LOOP
  | "if" -> IF
  | "else" -> ELSE
  | "let" -> LET
  | "const" -> CONST
  | "as" -> AS
  | "is" -> IS
  | "become" -> BECOME
  | "br" -> BR
  | "br_if" -> BR_IF
  | "br_table" -> BR_TABLE
  | "dispatch" -> DISPATCH
  | "match" -> MATCH
  | "br_on_null" -> BR_ON_NULL
  | "br_on_non_null" -> BR_ON_NON_NULL
  | "br_on_cast" -> BR_ON_CAST
  | "br_on_cast_fail" -> BR_ON_CAST_FAIL
  | "return" -> RETURN
  | "try" -> TRY
  | "catch" -> CATCH
  | "throw" -> THROW
  | "throw_ref" -> THROW_REF
  | "cont_new" -> CONT_NEW
  | "cont_bind" -> CONT_BIND
  | "suspend" -> SUSPEND
  | "resume" -> RESUME
  | "resume_throw" -> RESUME_THROW
  | "resume_throw_ref" -> RESUME_THROW_REF
  | "switch" -> SWITCH
  | "memory" -> MEMORY
  | "pagesize" -> PAGESIZE
  | "shared" -> SHARED
  | "descriptor" -> DESCRIPTOR
  | "describes" -> DESCRIBES
  | "data" -> DATA
  | "table" -> TABLE
  | "elem" -> ELEM
  | int -> INT (Sedlexing.Utf8.lexeme lexbuf)
  | float -> FLOAT (Sedlexing.Utf8.lexeme lexbuf)
  | ident -> IDENT (Sedlexing.Utf8.lexeme lexbuf)
  | '"' -> STRING (with_loc string lexbuf)
  | "'", Sub (any, (0 .. 31 | 0x7f | '"' | '\\')), "'" ->
      (* One code point between the quotes; it may be multibyte (e.g. an emoji),
         so decode it from UTF-8 rather than assuming a single byte. *)
      let s = Sedlexing.Utf8.lexeme lexbuf in
      CHAR (Uchar.utf_decode_uchar (String.get_utf_8_uchar s 1))
  | "'", ("\\t" | "\\n" | "\\r" | "\\'" | "\\\"" | "\\\\"), "'" ->
      let s = Sedlexing.Utf8.lexeme lexbuf in
      assert (String.length s = 4);
      CHAR
        (Uchar.of_char
           (match s.[2] with 't' -> '\t' | 'n' -> '\n' | 'r' -> '\r' | c -> c))
  | "'\\u{", hexnum, "}'" ->
      let n =
        Sedlexing.Utf8.sub_lexeme lexbuf 4 (Sedlexing.lexeme_length lexbuf - 6)
      in
      CHAR (unicode_escape lexbuf n)
  | "'\\x", hexdigit, hexdigit, "'" ->
      let s = String.sub (Sedlexing.Utf8.lexeme lexbuf) 3 2 in
      let n = int_of_string ("0x" ^ s) in
      if n > 127 then
        raise
          (Wax_wasm.Parsing.Syntax_error
             ( Sedlexing.lexing_bytes_positions lexbuf,
               Printf.sprintf "Invalid Unicode character.\n" ));
      CHAR (Uchar.of_int n)
  | eof -> EOF
  | Compl 'x' ->
      raise
        (Wax_wasm.Parsing.Syntax_error
           ( Sedlexing.lexing_bytes_positions lexbuf,
             Printf.sprintf "Unexpected character '%s'.\n"
               (Sedlexing.Utf8.lexeme lexbuf) ))
  | _ ->
      raise
        (Wax_wasm.Parsing.Syntax_error
           ( Sedlexing.lexing_bytes_positions lexbuf,
             Printf.sprintf "Syntax error.\n" ))

let token ctx lexbuf =
  let t = token_rec ctx lexbuf in
  let end_ = Sedlexing.lexing_bytes_position_curr lexbuf in
  Wax_utils.Trivia.report_token ctx end_.pos_cnum;
  t

let is_valid_identifier s =
  let buf = Sedlexing.Utf8.from_string s in
  match%sedlex buf with ident, eof -> true | _ -> false
