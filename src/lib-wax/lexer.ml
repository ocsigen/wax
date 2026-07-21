let white = [%sedlex.regexp? Plus (' ' | '\t')]
let newline = [%sedlex.regexp? '\r' | '\n' | "\r\n"]
let id_start_c = [%sedlex.regexp? 'a' .. 'z' | 'A' .. 'Z' | 0x80 .. 0x10FFFF]

let id_cont_c =
  [%sedlex.regexp?
    'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | 0x80 .. 0x10FFFF | '\'']

(* Coarse identifier rule: ASCII identifier characters plus any non-ASCII scalar.
   The strict Unicode XID check is done separately in [validate_identifier],
   keeping the large XID character classes out of the sedlex DFA. *)
let ident = [%sedlex.regexp? id_start_c, Star id_cont_c | '_', Plus id_cont_c]

(* Revalidate a coarsely-lexed identifier against the strict XID classes. ASCII
   characters accepted by the coarse rule are exactly the intended identifier
   characters, so only non-ASCII scalars need checking: the first against
   XID_Start, the rest against XID_Continue. Returns the byte offset and byte
   length of the first character that is not allowed, or [None] if the whole
   identifier is valid. *)
let invalid_identifier_char s =
  let n = String.length s in
  let rec go i first =
    if i >= n then None
    else
      let d = String.get_utf_8_uchar s i in
      let len = Uchar.utf_decode_length d in
      let c = Uchar.to_int (Uchar.utf_decode_uchar d) in
      let ok =
        if c < 0x80 then true
        else if first then Wax_utils.Xid.is_xid_start c
        else Wax_utils.Xid.is_xid_continue c
      in
      if ok then go (i + len) false else Some (i, len)
  in
  go 0 true

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
      let loc_start, loc_end = Sedlexing.lexing_bytes_positions lexbuf in
      Wax_wasm.Parsing.syntax_error
        ~location:{ Wax_utils.Ast.loc_start; loc_end }
        ~hint:
          (Wax_utils.Message.text "A block comment must be closed with '*/'.")
        (Wax_utils.Message.text (Printf.sprintf "Malformed comment.\n"))

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
      let loc_start, loc_end = Sedlexing.lexing_bytes_positions lexbuf in
      Wax_wasm.Parsing.syntax_error
        ~location:{ Wax_utils.Ast.loc_start; loc_end }
        ~hint:
          (Wax_utils.Message.text
             "A Unicode escape has the form '\\u{XXXX}', where 'XXXX' is the \
              hexadecimal code of a Unicode scalar value.")
        (Wax_utils.Message.text (Printf.sprintf "Malformed Unicode escape.\n"))

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
        (Wax_wasm.Parsing.syntax_error_pair
           ( Sedlexing.lexing_bytes_positions lexbuf,
             Wax_utils.Message.text (Printf.sprintf "Malformed string.\n") ))

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
  | "++" -> PLUSPLUS
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
  | "try_legacy" -> TRY_LEGACY
  | "catch" -> CATCH
  | "throw" -> THROW
  | "throw_ref" -> THROW_REF
  | "cont" -> CONT
  | "suspend" -> SUSPEND
  | "on" -> ON
  | "memory" -> MEMORY
  | "import" -> IMPORT
  | "pagesize" -> PAGESIZE
  | "shared" -> SHARED
  | "descriptor" -> DESCRIPTOR
  | "describes" -> DESCRIBES
  | "data" -> DATA
  | "table" -> TABLE
  | "elem" -> ELEM
  | int -> INT (Sedlexing.Utf8.lexeme lexbuf)
  | float -> FLOAT (Sedlexing.Utf8.lexeme lexbuf)
  | ident -> (
      let s = Sedlexing.Utf8.lexeme lexbuf in
      match invalid_identifier_char s with
      | None -> IDENT s
      | Some (off, len) ->
          (* Report the offending character exactly as the [Compl 'x'] arm below
             would have on the strict lexer: same message, same one-character
             location. The coarse rule only ever absorbs a non-ASCII character
             that could not start a valid token anyway, so this is equivalent. *)
          let startp, _ = Sedlexing.lexing_bytes_positions lexbuf in
          let p0 = { startp with Lexing.pos_cnum = startp.pos_cnum + off } in
          let p1 = { p0 with Lexing.pos_cnum = p0.pos_cnum + len } in
          raise
            (Wax_wasm.Parsing.syntax_error_pair
               ( (p0, p1),
                 Wax_utils.Message.text
                   (Printf.sprintf "Unexpected character '%s'.\n"
                      (String.sub s off len)) )))
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
          (Wax_wasm.Parsing.syntax_error_pair
             ( Sedlexing.lexing_bytes_positions lexbuf,
               Wax_utils.Message.text
                 (Printf.sprintf "Invalid Unicode character.\n") ));
      CHAR (Uchar.of_int n)
  | eof -> EOF
  | Compl 'x' ->
      raise
        (Wax_wasm.Parsing.syntax_error_pair
           ( Sedlexing.lexing_bytes_positions lexbuf,
             Wax_utils.Message.text
               (Printf.sprintf "Unexpected character '%s'.\n"
                  (Sedlexing.Utf8.lexeme lexbuf)) ))
  | _ ->
      raise
        (Wax_wasm.Parsing.syntax_error_pair
           ( Sedlexing.lexing_bytes_positions lexbuf,
             Wax_utils.Message.text (Printf.sprintf "Syntax error.\n") ))

(* The Wax lexer never combines tokens, so a token's lexbuf position is always
   its true start; the [start_override] ref (part of the shared lexer interface,
   see {!Wax_wasm.Lexer.token}) therefore stays [None]. *)
let token ctx =
  ( (fun lexbuf ->
      let t = token_rec ctx lexbuf in
      let end_ = Sedlexing.lexing_bytes_position_curr lexbuf in
      Wax_utils.Trivia.report_token ctx end_.pos_cnum;
      t),
    ref None )

(* Whether [s] is a valid Wax identifier. Called once per name during
   Wasm-to-Wax name assignment (thousands of times on a large module), so it must
   not allocate: a manual UTF-8 scan replaces the old [Sedlexing.Utf8.from_string]
   + [match%sedlex], which built a fresh lexbuf (and its refill buffer) per call.
   It fuses the coarse structural rule the sedlex [ident] regexp enforced with the
   strict XID check {!invalid_identifier_char} did separately: an ASCII scalar must be
   an identifier character in the right position; a non-ASCII scalar must satisfy
   [XID_Start] (first) or [XID_Continue] (rest) — the coarse rule admitted any
   non-ASCII scalar and the XID check then narrowed it, so requiring XID directly
   is equivalent. A leading ['_'] needs at least one further character, matching
   the regexp's [ '_', Plus id_cont_c ] alternative. *)
let is_valid_identifier s =
  let n = String.length s in
  let ascii_start c =
    (c >= Char.code 'a' && c <= Char.code 'z')
    || (c >= Char.code 'A' && c <= Char.code 'Z')
  in
  let ascii_cont c =
    ascii_start c
    || (c >= Char.code '0' && c <= Char.code '9')
    || c = Char.code '_'
    || c = Char.code '\''
  in
  let rec cont i =
    if i >= n then true
    else
      let d = String.get_utf_8_uchar s i in
      if not (Uchar.utf_decode_is_valid d) then false
      else
        let c = Uchar.to_int (Uchar.utf_decode_uchar d) in
        let ok =
          if c < 0x80 then ascii_cont c else Wax_utils.Xid.is_xid_continue c
        in
        ok && cont (i + Uchar.utf_decode_length d)
  in
  n > 0
  &&
  let d = String.get_utf_8_uchar s 0 in
  Uchar.utf_decode_is_valid d
  &&
  let c = Uchar.to_int (Uchar.utf_decode_uchar d) in
  let len = Uchar.utf_decode_length d in
  if c < 0x80 then
    if c = Char.code '_' then len < n && cont len else ascii_start c && cont len
  else Wax_utils.Xid.is_xid_start c && cont len
