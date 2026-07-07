(*ZZZ Fix string/ident location*)

(*** Regexp definitions ***)

let sign = [%sedlex.regexp? Opt ('+' | '-')]
let digit = [%sedlex.regexp? '0' .. '9']
let hexdigit = [%sedlex.regexp? '0' .. '9' | 'a' .. 'f' | 'A' .. 'F']
let num = [%sedlex.regexp? digit, Star (Opt '_', digit)]
let hexnum = [%sedlex.regexp? hexdigit, Star (Opt '_', hexdigit)]
let uN = [%sedlex.regexp? num | "0x", hexnum]
let sN = [%sedlex.regexp? sign, uN]
let iN = [%sedlex.regexp? uN | sN]

let float =
  [%sedlex.regexp? num, Opt ('.', Opt num), Opt (('e' | 'E'), sign, num)]

let hexfloat =
  [%sedlex.regexp?
    "0x", hexnum, Opt ('.', Opt hexnum), Opt (('p' | 'P'), sign, num)]

let fN =
  [%sedlex.regexp? sign, (float | hexfloat | "inf" | "nan" | "nan:0x", hexnum)]

let idchar =
  [%sedlex.regexp?
    ( '0' .. '9'
    | 'A' .. 'Z'
    | 'a' .. 'z'
    | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '/' | ':'
    | '<' | '=' | '>' | '?' | '@' | '\\' | '^' | '_' | '`' | '|' | '~' )]

let id = [%sedlex.regexp? '$', Plus idchar]
let linechar = [%sedlex.regexp? Sub (any, (10 | 13))]
let newline = [%sedlex.regexp? 10 | 13 | 13, 10]
let linecomment = [%sedlex.regexp? ";;", Star linechar, (newline | eof)]
let format = [%sedlex.regexp? '\n' | 9]

let stringchar =
  [%sedlex.regexp?
    ( Sub (any, (0 .. 31 | 0x7f | '"' | '\\'))
    | "\\t" | "\\n" | "\\r" | "\\'" | "\\\"" | "\\\\"
    | "\\u{", hexnum, "}" )]

let stringelem = [%sedlex.regexp? stringchar | "\\", hexdigit, hexdigit]
let string = [%sedlex.regexp? '"', Star stringelem, '"']
let reserved = [%sedlex.regexp? Plus (idchar | ',' | '[' | ']' | '{' | '}')]

(*
let space = [%sedlex.regexp? ' ' | format | comment]
*)
let keyword = [%sedlex.regexp? 'a' .. 'z', Star idchar]
(*** String and comment scanning ***)

let string_buffer = Buffer.create 256

let rec comment_rec lexbuf =
  match%sedlex lexbuf with
  | ";)" -> Buffer.add_string string_buffer ";)"
  | "(;" ->
      Buffer.add_string string_buffer "(;";
      comment_rec lexbuf;
      comment_rec lexbuf
  | ';' | '(' | Plus (Sub (any, (';' | '('))) ->
      Buffer.add_string string_buffer (Sedlexing.Utf8.lexeme lexbuf);
      comment_rec lexbuf
  | _ ->
      raise
        (Parsing.Syntax_error
           ( Sedlexing.lexing_bytes_positions lexbuf,
             Printf.sprintf "Malformed comment.\n" ))

let comment lexbuf =
  Buffer.add_string string_buffer "(;";
  comment_rec lexbuf;
  let s = Buffer.contents string_buffer in
  Buffer.clear string_buffer;
  s

let unicode_escape lexbuf s =
  match Wax_utils.Unicode.scalar_of_hex s with
  | Some u -> u
  | None ->
      raise
        (Parsing.Syntax_error
           ( Sedlexing.lexing_bytes_positions lexbuf,
             Printf.sprintf "Malformed Unicode escape.\n" ))

let rec string lexbuf =
  match%sedlex lexbuf with
  | '"' ->
      let s = Buffer.contents string_buffer in
      Buffer.clear string_buffer;
      s
  | '"', ('"' | reserved) ->
      raise
        (Parsing.Syntax_error
           ( Sedlexing.lexing_bytes_positions lexbuf,
             Printf.sprintf "Unknown token '%s'.\n"
               (Sedlexing.Utf8.lexeme lexbuf) ))
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
  | '\\', hexdigit, hexdigit ->
      let s = String.sub (Sedlexing.Utf8.lexeme lexbuf) 1 2 in
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
        (Parsing.Syntax_error
           ( Sedlexing.lexing_bytes_positions lexbuf,
             Printf.sprintf "Malformed string.\n" ))

let rec scan_string lexbuf =
  match%sedlex lexbuf with
  | '"' -> ()
  | '\\', any -> scan_string lexbuf
  | any -> scan_string lexbuf
  | _ ->
      raise
        (Parsing.Syntax_error
           ( Sedlexing.lexing_bytes_positions lexbuf,
             Printf.sprintf "Unclosed string in annotation.\n" ))

let rec skip_annotation depth lexbuf =
  match%sedlex lexbuf with
  | '(' -> skip_annotation (depth + 1) lexbuf
  | ')' -> if depth > 1 then skip_annotation (depth - 1) lexbuf
  | '"' ->
      scan_string lexbuf;
      skip_annotation depth lexbuf
  | "(;" ->
      comment_rec lexbuf;
      skip_annotation depth lexbuf
  | linecomment -> skip_annotation depth lexbuf
  | Plus (' ' | '\t' | '\n' | '\r') -> skip_annotation depth lexbuf
  | reserved | ';' -> skip_annotation depth lexbuf
  | _ ->
      raise
        (Parsing.Syntax_error
           ( Sedlexing.lexing_bytes_positions lexbuf,
             Printf.sprintf "Illegal character.\n" ))

let with_loc ctx f lexbuf =
  let loc_start = Sedlexing.lexing_bytes_position_start lexbuf in
  let desc = f lexbuf in
  Wax_utils.Trivia.with_pos ctx
    { loc_start; loc_end = Sedlexing.lexing_bytes_position_curr lexbuf }
    desc

open Tokens

(*** The tokenizer ***)

let rec token_rec ctx lexbuf =
  match%sedlex lexbuf with
  | '(' -> LPAREN
  | ')' -> RPAREN
  | uN -> NAT (Sedlexing.Utf8.lexeme lexbuf)
  | sN -> INT (Sedlexing.Utf8.lexeme lexbuf)
  | fN -> FLOAT (Sedlexing.Utf8.lexeme lexbuf)
  | '"' -> STRING (with_loc ctx string lexbuf)
  | "$\"" ->
      let s = with_loc ctx string lexbuf in
      if not (String.is_valid_utf_8 s.desc) then
        raise
          (Parsing.Syntax_error
             ( (s.info.loc_start, s.info.loc_end),
               "Identifier contains malformed UTF-8 byte sequences" ));
      if s.desc = "" then
        raise
          (Parsing.Syntax_error
             ( (s.info.loc_start, s.info.loc_end),
               "An identifier cannot be the empty string" ));
      ID s
  | newline ->
      Wax_utils.Trivia.report_newline ctx;
      token_rec ctx lexbuf (* Skip standalone newlines in Wat *)
  | linecomment ->
      let content = Sedlexing.Utf8.lexeme lexbuf in
      Wax_utils.Trivia.report_item ctx Line_comment content;
      token_rec ctx lexbuf
  | Plus (' ' | '\t') -> token_rec ctx lexbuf
  | "(;" ->
      let s = comment lexbuf in
      Wax_utils.Trivia.report_item ctx Block_comment s;
      token_rec ctx lexbuf
  | "(@string" -> STRING_ANNOT
  | "(@char" -> CHAR_ANNOT
  | "(@if" -> IF_ANNOT
  | "(@then" -> THEN_ANNOT
  | "(@else" -> ELSE_ANNOT
  (* Branch-hinting proposal: [(@metadata.code.branch_hint "\00"|"\01")]. *)
  | "(@metadata.code.branch_hint" -> BRANCH_HINT_ANNOT
  | "(@", Plus idchar ->
      skip_annotation 1 lexbuf;
      Wax_utils.Trivia.report_item ctx Annotation "";
      token_rec ctx lexbuf
  | "(@\"" ->
      let s = string lexbuf in
      if s = "string" then STRING_ANNOT
      else if s = "char" then CHAR_ANNOT
      else if s = "if" then IF_ANNOT
      else if s = "then" then THEN_ANNOT
      else if s = "else" then ELSE_ANNOT
      else (
        if not (String.is_valid_utf_8 s) then
          raise
            (Parsing.Syntax_error
               ( Sedlexing.lexing_bytes_positions lexbuf,
                 "The annotation id contains malformed UTF-8 byte sequences." ));
        if s = "" then
          raise
            (Parsing.Syntax_error
               ( Sedlexing.lexing_bytes_positions lexbuf,
                 "An annotation id cannot be the empty string." ));
        skip_annotation 1 lexbuf;
        Wax_utils.Trivia.report_item ctx Annotation "";
        token_rec ctx lexbuf)
  | id ->
      let loc_start, loc_end = Sedlexing.lexing_bytes_positions lexbuf in
      ID
        (Wax_utils.Trivia.with_pos ctx { Ast.loc_start; loc_end }
           (Sedlexing.Utf8.sub_lexeme lexbuf 1
              (Sedlexing.lexeme_length lexbuf - 1)))
  | eof -> EOF
  | "i32" -> I32
  | "i64" -> I64
  | "f32" -> F32
  | "f64" -> F64
  | "v128" -> V128
  | "i8" -> PACKEDTYPE I8
  | "i16" -> PACKEDTYPE I16
  | "any" -> ANY
  | "eq" -> EQ
  | "i31" -> I31
  | "struct" -> STRUCT
  | "array" -> ARRAY
  | "none" -> NONE
  | "func" -> FUNC
  | "nofunc" -> NOFUNC
  | "exn" -> EXN
  | "noexn" -> NOEXN
  | "cont" -> CONT
  | "nocont" -> NOCONT
  | "extern" -> EXTERN
  | "noextern" -> NOEXTERN
  | "exact" -> EXACT
  | "descriptor" -> LPAREN_DESCRIPTOR
  | "describes" -> LPAREN_DESCRIBES
  | "anyref" -> ANYREF
  | "eqref" -> EQREF
  | "i31ref" -> I31REF
  | "structref" -> STRUCTREF
  | "arrayref" -> ARRAYREF
  | "nullref" -> NULLREF
  | "funcref" -> FUNCREF
  | "nullfuncref" -> NULLFUNCREF
  | "exnref" -> EXNREF
  | "nullexnref" -> NULLEXNREF
  | "contref" -> CONTREF
  | "nullcontref" -> NULLCONTREF
  | "externref" -> EXTERNREF
  | "nullexternref" -> NULLEXTERNREF
  | "ref" -> REF
  | "null" -> NULL
  | "param" -> LPAREN_PARAM
  | "result" -> LPAREN_RESULT
  | "mut" -> MUT
  | "field" -> FIELD
  | "rec" -> REC
  | "type" -> LPAREN_TYPE
  | "sub" -> SUB
  | "final" -> FINAL
  | "import" -> LPAREN_IMPORT
  | "export" -> LPAREN_EXPORT
  | "local" -> LPAREN_LOCAL
  | "global" -> GLOBAL
  | "start" -> START
  | "elem" -> ELEM
  | "declare" -> DECLARE
  | "item" -> ITEM
  | "memory" -> MEMORY
  | "pagesize" -> PAGESIZE
  | "shared" -> SHARED
  | "table" -> TABLE
  | "data" -> DATA
  | "offset" -> OFFSET
  | "module" -> MODULE
  | "block" -> BLOCK
  | "loop" -> LOOP
  | "if" -> IF
  | "then" -> LPAREN_THEN
  | "else" -> ELSE
  | "end" -> END
  | "unreachable" -> INSTR Unreachable
  | "nop" -> INSTR Nop
  | "br" -> BR
  | "br_if" -> BR_IF
  | "br_table" -> BR_TABLE
  | "br_on_null" -> BR_ON_NULL
  | "br_on_non_null" -> BR_ON_NON_NULL
  | "br_on_cast" -> BR_ON_CAST
  | "br_on_cast_desc_eq" -> BR_ON_CAST_DESC_EQ
  | "br_on_cast_desc_eq_fail" -> BR_ON_CAST_DESC_EQ_FAIL
  | "i8x16" -> I8X16
  | "i16x8" -> I16X8
  | "i32x4" -> I32X4
  | "i64x2" -> I64X2
  | "f32x4" -> F32X4
  | "f64x2" -> F64X2
  | "br_on_cast_fail" -> BR_ON_CAST_FAIL
  | "return" -> INSTR Return
  | "call" -> CALL
  | "call_ref" -> CALL_REF
  | "call_indirect" -> CALL_INDIRECT
  | "return_call" -> RETURN_CALL
  | "return_call_ref" -> RETURN_CALL_REF
  | "return_call_indirect" -> RETURN_CALL_INDIRECT
  | "drop" -> INSTR Drop
  | "select" -> SELECT
  | "local.get" -> LOCAL_GET
  | "local.set" -> LOCAL_SET
  | "local.tee" -> LOCAL_TEE
  | "global.get" -> GLOBAL_GET
  | "global.set" -> GLOBAL_SET
  | "atomic.fence" -> INSTR AtomicFence
  | "i32.load" -> LOAD NumI32
  | "i64.load" -> LOAD NumI64
  | "f32.load" -> LOAD NumF32
  | "f64.load" -> LOAD NumF64
  | "v128.load" -> VEC_LOAD Load128
  | "v128.load8x8_s" -> VEC_LOAD Load8x8S
  | "v128.load8x8_u" -> VEC_LOAD Load8x8U
  | "v128.load16x4_s" -> VEC_LOAD Load16x4S
  | "v128.load16x4_u" -> VEC_LOAD Load16x4U
  | "v128.load32x2_s" -> VEC_LOAD Load32x2S
  | "v128.load32x2_u" -> VEC_LOAD Load32x2U
  | "v128.load8_lane" -> VEC_LOAD_LANE `I8
  | "v128.load16_lane" -> VEC_LOAD_LANE `I16
  | "v128.load32_lane" -> VEC_LOAD_LANE `I32
  | "v128.load64_lane" -> VEC_LOAD_LANE `I64
  | "v128.store8_lane" -> VEC_STORE_LANE `I8
  | "v128.store16_lane" -> VEC_STORE_LANE `I16
  | "v128.store32_lane" -> VEC_STORE_LANE `I32
  | "v128.store64_lane" -> VEC_STORE_LANE `I64
  | "v128.load8_splat" -> VEC_LOAD_SPLAT `I8
  | "v128.load16_splat" -> VEC_LOAD_SPLAT `I16
  | "v128.load32_splat" -> VEC_LOAD_SPLAT `I32
  | "v128.load64_splat" -> VEC_LOAD_SPLAT `I64
  | "v128.load32_zero" -> VEC_LOAD Load32Zero
  | "v128.load64_zero" -> VEC_LOAD Load64Zero
  | "i32.load8_u" -> LOADS (`I32, `I8, Unsigned)
  | "i32.load8_s" -> LOADS (`I32, `I8, Signed)
  | "i64.load8_u" -> LOADS (`I64, `I8, Unsigned)
  | "i64.load8_s" -> LOADS (`I64, `I8, Signed)
  | "i32.load16_u" -> LOADS (`I32, `I16, Unsigned)
  | "i32.load16_s" -> LOADS (`I32, `I16, Signed)
  | "i64.load16_u" -> LOADS (`I64, `I16, Unsigned)
  | "i64.load16_s" -> LOADS (`I64, `I16, Signed)
  | "i64.load32_u" -> LOADS (`I64, `I32, Unsigned)
  | "i64.load32_s" -> LOADS (`I64, `I32, Signed)
  | "i32.store" -> STORE NumI32
  | "i64.store" -> STORE NumI64
  | "f32.store" -> STORE NumF32
  | "f64.store" -> STORE NumF64
  | "v128.store" -> VEC_STORE
  | "i8x16.extract_lane_s" -> VEC_EXTRACT (I8x16, Some Signed)
  | "i8x16.extract_lane_u" -> VEC_EXTRACT (I8x16, Some Unsigned)
  | "i8x16.replace_lane" -> VEC_REPLACE I8x16
  | "i16x8.extract_lane_s" -> VEC_EXTRACT (I16x8, Some Signed)
  | "i16x8.extract_lane_u" -> VEC_EXTRACT (I16x8, Some Unsigned)
  | "i16x8.replace_lane" -> VEC_REPLACE I16x8
  | "i32x4.extract_lane" -> VEC_EXTRACT (I32x4, None)
  | "i32x4.replace_lane" -> VEC_REPLACE I32x4
  | "i64x2.extract_lane" -> VEC_EXTRACT (I64x2, None)
  | "i64x2.replace_lane" -> VEC_REPLACE I64x2
  | "f32x4.extract_lane" -> VEC_EXTRACT (F32x4, None)
  | "f32x4.replace_lane" -> VEC_REPLACE F32x4
  | "f64x2.extract_lane" -> VEC_EXTRACT (F64x2, None)
  | "f64x2.replace_lane" -> VEC_REPLACE F64x2
  | "i8x16.splat" -> INSTR (VecSplat I8x16)
  | "i16x8.splat" -> INSTR (VecSplat I16x8)
  | "i32x4.splat" -> INSTR (VecSplat I32x4)
  | "i64x2.splat" -> INSTR (VecSplat I64x2)
  | "f32x4.splat" -> INSTR (VecSplat F32x4)
  | "f64x2.splat" -> INSTR (VecSplat F64x2)
  | "i8x16.shuffle" -> VEC_SHUFFLE
  | "i8x16.swizzle" -> INSTR (VecBinOp VecSwizzle)
  | "i32.store8" -> STORES (`I32, `I8)
  | "i64.store8" -> STORES (`I64, `I8)
  | "i32.store16" -> STORES (`I32, `I16)
  | "i64.store16" -> STORES (`I64, `I16)
  | "i64.store32" -> STORES (`I64, `I32)
  | "memory.size" -> MEMORY_SIZE
  | "memory.grow" -> MEMORY_GROW
  | "memory.fill" -> MEMORY_FILL
  | "memory.copy" -> MEMORY_COPY
  | "memory.init" -> MEMORY_INIT
  | "data.drop" -> DATA_DROP
  | "table.get" -> TABLE_GET
  | "table.set" -> TABLE_SET
  | "table.size" -> TABLE_SIZE
  | "table.grow" -> TABLE_GROW
  | "table.fill" -> TABLE_FILL
  | "table.copy" -> TABLE_COPY
  | "table.init" -> TABLE_INIT
  | "elem.drop" -> ELEM_DROP
  | "ref.null" -> REF_NULL
  | "ref.func" -> REF_FUNC
  | "ref.is_null" -> INSTR RefIsNull
  | "ref.as_non_null" -> INSTR RefAsNonNull
  | "ref.eq" -> INSTR RefEq
  | "ref.test" -> REF_TEST
  | "ref.cast" -> REF_CAST
  | "ref.cast_desc_eq" -> REF_CAST_DESC_EQ
  | "ref.get_desc" -> REF_GET_DESC
  | "struct.new" -> STRUCT_NEW
  | "struct.new_default" -> STRUCT_NEW_DEFAULT
  | "struct.new_desc" -> STRUCT_NEW_DESC
  | "struct.new_default_desc" -> STRUCT_NEW_DEFAULT_DESC
  | "struct.get" -> STRUCT_GET None
  | "struct.get_u" -> STRUCT_GET (Some Unsigned)
  | "struct.get_s" -> STRUCT_GET (Some Signed)
  | "struct.set" -> STRUCT_SET
  | "array.new" -> ARRAY_NEW
  | "array.new_default" -> ARRAY_NEW_DEFAULT
  | "array.new_fixed" -> ARRAY_NEW_FIXED
  | "array.new_data" -> ARRAY_NEW_DATA
  | "array.new_elem" -> ARRAY_NEW_ELEM
  | "array.get" -> ARRAY_GET None
  | "array.get_u" -> ARRAY_GET (Some Unsigned)
  | "array.get_s" -> ARRAY_GET (Some Signed)
  | "array.set" -> ARRAY_SET
  | "array.len" -> INSTR ArrayLen
  | "array.fill" -> ARRAY_FILL
  | "array.copy" -> ARRAY_COPY
  | "array.init_data" -> ARRAY_INIT_DATA
  | "array.init_elem" -> ARRAY_INIT_ELEM
  | "ref.i31" -> INSTR RefI31
  | "i31.get_s" -> INSTR (I31Get Signed)
  | "i31.get_u" -> INSTR (I31Get Unsigned)
  | "i32.const" -> I32_CONST
  | "i64.const" -> I64_CONST
  | "f32.const" -> F32_CONST
  | "f64.const" -> F64_CONST
  | "v128.const" -> V128_CONST
  | "i32.clz" -> INSTR (UnOp (I32 Clz))
  | "i32.ctz" -> INSTR (UnOp (I32 Ctz))
  | "i32.popcnt" -> INSTR (UnOp (I32 Popcnt))
  | "i32.eqz" -> INSTR (UnOp (I32 Eqz))
  | "i32.add" -> INSTR (BinOp (I32 Add))
  | "i32.sub" -> INSTR (BinOp (I32 Sub))
  | "i32.mul" -> INSTR (BinOp (I32 Mul))
  | "i32.div_s" -> INSTR (BinOp (I32 (Div Signed)))
  | "i32.div_u" -> INSTR (BinOp (I32 (Div Unsigned)))
  | "i32.rem_s" -> INSTR (BinOp (I32 (Rem Signed)))
  | "i32.rem_u" -> INSTR (BinOp (I32 (Rem Unsigned)))
  | "i32.and" -> INSTR (BinOp (I32 And))
  | "i32.or" -> INSTR (BinOp (I32 Or))
  | "i32.xor" -> INSTR (BinOp (I32 Xor))
  | "i32.shl" -> INSTR (BinOp (I32 Shl))
  | "i32.shr_s" -> INSTR (BinOp (I32 (Shr Signed)))
  | "i32.shr_u" -> INSTR (BinOp (I32 (Shr Unsigned)))
  | "i32.rotl" -> INSTR (BinOp (I32 Rotl))
  | "i32.rotr" -> INSTR (BinOp (I32 Rotr))
  | "i32.eq" -> INSTR (BinOp (I32 Eq))
  | "i32.ne" -> INSTR (BinOp (I32 Ne))
  | "i32.lt_s" -> INSTR (BinOp (I32 (Lt Signed)))
  | "i32.lt_u" -> INSTR (BinOp (I32 (Lt Unsigned)))
  | "i32.gt_s" -> INSTR (BinOp (I32 (Gt Signed)))
  | "i32.gt_u" -> INSTR (BinOp (I32 (Gt Unsigned)))
  | "i32.le_s" -> INSTR (BinOp (I32 (Le Signed)))
  | "i32.le_u" -> INSTR (BinOp (I32 (Le Unsigned)))
  | "i32.ge_s" -> INSTR (BinOp (I32 (Ge Signed)))
  | "i32.ge_u" -> INSTR (BinOp (I32 (Ge Unsigned)))
  | "i64.clz" -> INSTR (UnOp (I64 Clz))
  | "i64.ctz" -> INSTR (UnOp (I64 Ctz))
  | "i64.popcnt" -> INSTR (UnOp (I64 Popcnt))
  | "i64.eqz" -> INSTR (UnOp (I64 Eqz))
  | "i64.add" -> INSTR (BinOp (I64 Add))
  | "i64.sub" -> INSTR (BinOp (I64 Sub))
  | "i64.mul" -> INSTR (BinOp (I64 Mul))
  | "i64.div_s" -> INSTR (BinOp (I64 (Div Signed)))
  | "i64.div_u" -> INSTR (BinOp (I64 (Div Unsigned)))
  | "i64.rem_s" -> INSTR (BinOp (I64 (Rem Signed)))
  | "i64.rem_u" -> INSTR (BinOp (I64 (Rem Unsigned)))
  | "i64.and" -> INSTR (BinOp (I64 And))
  | "i64.or" -> INSTR (BinOp (I64 Or))
  | "i64.xor" -> INSTR (BinOp (I64 Xor))
  | "i64.shl" -> INSTR (BinOp (I64 Shl))
  | "i64.shr_s" -> INSTR (BinOp (I64 (Shr Signed)))
  | "i64.shr_u" -> INSTR (BinOp (I64 (Shr Unsigned)))
  | "i64.rotl" -> INSTR (BinOp (I64 Rotl))
  | "i64.rotr" -> INSTR (BinOp (I64 Rotr))
  | "i64.add128" -> INSTR Add128
  | "i64.sub128" -> INSTR Sub128
  | "i64.mul_wide_s" -> INSTR (MulWide Signed)
  | "i64.mul_wide_u" -> INSTR (MulWide Unsigned)
  | "i64.eq" -> INSTR (BinOp (I64 Eq))
  | "i64.ne" -> INSTR (BinOp (I64 Ne))
  | "i64.lt_s" -> INSTR (BinOp (I64 (Lt Signed)))
  | "i64.lt_u" -> INSTR (BinOp (I64 (Lt Unsigned)))
  | "i64.gt_s" -> INSTR (BinOp (I64 (Gt Signed)))
  | "i64.gt_u" -> INSTR (BinOp (I64 (Gt Unsigned)))
  | "i64.le_s" -> INSTR (BinOp (I64 (Le Signed)))
  | "i64.le_u" -> INSTR (BinOp (I64 (Le Unsigned)))
  | "i64.ge_s" -> INSTR (BinOp (I64 (Ge Signed)))
  | "i64.ge_u" -> INSTR (BinOp (I64 (Ge Unsigned)))
  | "f32.abs" -> INSTR (UnOp (F32 Abs))
  | "f32.neg" -> INSTR (UnOp (F32 Neg))
  | "f32.ceil" -> INSTR (UnOp (F32 Ceil))
  | "f32.floor" -> INSTR (UnOp (F32 Floor))
  | "f32.trunc" -> INSTR (UnOp (F32 Trunc))
  | "f32.nearest" -> INSTR (UnOp (F32 Nearest))
  | "f32.sqrt" -> INSTR (UnOp (F32 Sqrt))
  | "f32.add" -> INSTR (BinOp (F32 Add))
  | "f32.sub" -> INSTR (BinOp (F32 Sub))
  | "f32.mul" -> INSTR (BinOp (F32 Mul))
  | "f32.div" -> INSTR (BinOp (F32 Div))
  | "f32.min" -> INSTR (BinOp (F32 Min))
  | "f32.max" -> INSTR (BinOp (F32 Max))
  | "f32.copysign" -> INSTR (BinOp (F32 CopySign))
  | "f32.eq" -> INSTR (BinOp (F32 Eq))
  | "f32.ne" -> INSTR (BinOp (F32 Ne))
  | "f32.lt" -> INSTR (BinOp (F32 Lt))
  | "f32.gt" -> INSTR (BinOp (F32 Gt))
  | "f32.le" -> INSTR (BinOp (F32 Le))
  | "f32.ge" -> INSTR (BinOp (F32 Ge))
  | "f64.abs" -> INSTR (UnOp (F64 Abs))
  | "f64.neg" -> INSTR (UnOp (F64 Neg))
  | "f64.ceil" -> INSTR (UnOp (F64 Ceil))
  | "f64.floor" -> INSTR (UnOp (F64 Floor))
  | "f64.trunc" -> INSTR (UnOp (F64 Trunc))
  | "f64.nearest" -> INSTR (UnOp (F64 Nearest))
  | "f64.sqrt" -> INSTR (UnOp (F64 Sqrt))
  | "f64.add" -> INSTR (BinOp (F64 Add))
  | "f64.sub" -> INSTR (BinOp (F64 Sub))
  | "f64.mul" -> INSTR (BinOp (F64 Mul))
  | "f64.div" -> INSTR (BinOp (F64 Div))
  | "f64.min" -> INSTR (BinOp (F64 Min))
  | "f64.max" -> INSTR (BinOp (F64 Max))
  | "f64.copysign" -> INSTR (BinOp (F64 CopySign))
  | "f64.eq" -> INSTR (BinOp (F64 Eq))
  | "f64.ne" -> INSTR (BinOp (F64 Ne))
  | "f64.lt" -> INSTR (BinOp (F64 Lt))
  | "f64.gt" -> INSTR (BinOp (F64 Gt))
  | "f64.le" -> INSTR (BinOp (F64 Le))
  | "f64.ge" -> INSTR (BinOp (F64 Ge))
  | "v128.not" -> INSTR (VecUnOp VecNot)
  | "v128.and" -> INSTR (VecBinOp VecAnd)
  | "v128.andnot" -> INSTR (VecBinOp VecAndNot)
  | "v128.or" -> INSTR (VecBinOp VecOr)
  | "v128.xor" -> INSTR (VecBinOp VecXor)
  | "v128.bitselect" -> INSTR VecBitselect
  | "v128.any_true" -> INSTR (VecTest AnyTrue)
  | "i8x16.abs" -> INSTR (VecUnOp (VecAbs I8x16))
  | "i8x16.neg" -> INSTR (VecUnOp (VecNeg I8x16))
  | "i8x16.popcnt" -> INSTR (VecUnOp VecPopcnt)
  | "i8x16.all_true" -> INSTR (VecTest (AllTrue I8x16))
  | "i8x16.bitmask" -> INSTR (VecBitmask (Bitmask I8x16))
  | "i8x16.narrow_i16x8_s" -> INSTR (VecBinOp (VecNarrow (Signed, `I8)))
  | "i8x16.narrow_i16x8_u" -> INSTR (VecBinOp (VecNarrow (Unsigned, `I8)))
  | "i8x16.shl" -> INSTR (VecShift (Shl I8x16))
  | "i8x16.shr_s" -> INSTR (VecShift (Shr (Signed, I8x16)))
  | "i8x16.shr_u" -> INSTR (VecShift (Shr (Unsigned, I8x16)))
  | "i8x16.add" -> INSTR (VecBinOp (VecAdd I8x16))
  | "i8x16.add_sat_s" -> INSTR (VecBinOp (VecAddSat (Signed, `I8)))
  | "i8x16.add_sat_u" -> INSTR (VecBinOp (VecAddSat (Unsigned, `I8)))
  | "i8x16.sub" -> INSTR (VecBinOp (VecSub I8x16))
  | "i8x16.sub_sat_s" -> INSTR (VecBinOp (VecSubSat (Signed, `I8)))
  | "i8x16.sub_sat_u" -> INSTR (VecBinOp (VecSubSat (Unsigned, `I8)))
  | "i8x16.min_s" -> INSTR (VecBinOp (VecMin (Some Signed, I8x16)))
  | "i8x16.min_u" -> INSTR (VecBinOp (VecMin (Some Unsigned, I8x16)))
  | "i8x16.max_s" -> INSTR (VecBinOp (VecMax (Some Signed, I8x16)))
  | "i8x16.max_u" -> INSTR (VecBinOp (VecMax (Some Unsigned, I8x16)))
  | "i8x16.avgr_u" -> INSTR (VecBinOp (VecAvgr `I8))
  | "i8x16.eq" -> INSTR (VecBinOp (VecEq I8x16))
  | "i8x16.ne" -> INSTR (VecBinOp (VecNe I8x16))
  | "i8x16.lt_s" -> INSTR (VecBinOp (VecLt (Some Signed, I8x16)))
  | "i8x16.lt_u" -> INSTR (VecBinOp (VecLt (Some Unsigned, I8x16)))
  | "i8x16.gt_s" -> INSTR (VecBinOp (VecGt (Some Signed, I8x16)))
  | "i8x16.gt_u" -> INSTR (VecBinOp (VecGt (Some Unsigned, I8x16)))
  | "i8x16.le_s" -> INSTR (VecBinOp (VecLe (Some Signed, I8x16)))
  | "i8x16.le_u" -> INSTR (VecBinOp (VecLe (Some Unsigned, I8x16)))
  | "i8x16.ge_s" -> INSTR (VecBinOp (VecGe (Some Signed, I8x16)))
  | "i8x16.ge_u" -> INSTR (VecBinOp (VecGe (Some Unsigned, I8x16)))
  | "i16x8.abs" -> INSTR (VecUnOp (VecAbs I16x8))
  | "i16x8.neg" -> INSTR (VecUnOp (VecNeg I16x8))
  | "i16x8.all_true" -> INSTR (VecTest (AllTrue I16x8))
  | "i16x8.bitmask" -> INSTR (VecBitmask (Bitmask I16x8))
  | "i16x8.narrow_i32x4_s" -> INSTR (VecBinOp (VecNarrow (Signed, `I16)))
  | "i16x8.narrow_i32x4_u" -> INSTR (VecBinOp (VecNarrow (Unsigned, `I16)))
  | "i16x8.extend_low_i8x16_s" ->
      INSTR (VecUnOp (VecExtend (`Low, `_8, Signed)))
  | "i16x8.extend_high_i8x16_s" ->
      INSTR (VecUnOp (VecExtend (`High, `_8, Signed)))
  | "i16x8.extend_low_i8x16_u" ->
      INSTR (VecUnOp (VecExtend (`Low, `_8, Unsigned)))
  | "i16x8.extend_high_i8x16_u" ->
      INSTR (VecUnOp (VecExtend (`High, `_8, Unsigned)))
  | "i16x8.shl" -> INSTR (VecShift (Shl I16x8))
  | "i16x8.shr_s" -> INSTR (VecShift (Shr (Signed, I16x8)))
  | "i16x8.shr_u" -> INSTR (VecShift (Shr (Unsigned, I16x8)))
  | "i16x8.add" -> INSTR (VecBinOp (VecAdd I16x8))
  | "i16x8.add_sat_s" -> INSTR (VecBinOp (VecAddSat (Signed, `I16)))
  | "i16x8.add_sat_u" -> INSTR (VecBinOp (VecAddSat (Unsigned, `I16)))
  | "i16x8.sub" -> INSTR (VecBinOp (VecSub I16x8))
  | "i16x8.sub_sat_s" -> INSTR (VecBinOp (VecSubSat (Signed, `I16)))
  | "i16x8.sub_sat_u" -> INSTR (VecBinOp (VecSubSat (Unsigned, `I16)))
  | "i16x8.mul" -> INSTR (VecBinOp (VecMul I16x8))
  | "i16x8.min_s" -> INSTR (VecBinOp (VecMin (Some Signed, I16x8)))
  | "i16x8.min_u" -> INSTR (VecBinOp (VecMin (Some Unsigned, I16x8)))
  | "i16x8.max_s" -> INSTR (VecBinOp (VecMax (Some Signed, I16x8)))
  | "i16x8.max_u" -> INSTR (VecBinOp (VecMax (Some Unsigned, I16x8)))
  | "i16x8.avgr_u" -> INSTR (VecBinOp (VecAvgr `I16))
  | "i16x8.q15mulr_sat_s" -> INSTR (VecBinOp VecQ15MulrSat)
  | "i16x8.extadd_pairwise_i8x16_s" ->
      INSTR (VecUnOp (VecExtAddPairwise (Signed, `I8)))
  | "i16x8.extadd_pairwise_i8x16_u" ->
      INSTR (VecUnOp (VecExtAddPairwise (Unsigned, `I8)))
  | "i16x8.eq" -> INSTR (VecBinOp (VecEq I16x8))
  | "i16x8.ne" -> INSTR (VecBinOp (VecNe I16x8))
  | "i16x8.lt_s" -> INSTR (VecBinOp (VecLt (Some Signed, I16x8)))
  | "i16x8.lt_u" -> INSTR (VecBinOp (VecLt (Some Unsigned, I16x8)))
  | "i16x8.gt_s" -> INSTR (VecBinOp (VecGt (Some Signed, I16x8)))
  | "i16x8.gt_u" -> INSTR (VecBinOp (VecGt (Some Unsigned, I16x8)))
  | "i16x8.le_s" -> INSTR (VecBinOp (VecLe (Some Signed, I16x8)))
  | "i16x8.le_u" -> INSTR (VecBinOp (VecLe (Some Unsigned, I16x8)))
  | "i16x8.ge_s" -> INSTR (VecBinOp (VecGe (Some Signed, I16x8)))
  | "i16x8.ge_u" -> INSTR (VecBinOp (VecGe (Some Unsigned, I16x8)))
  | "i32x4.abs" -> INSTR (VecUnOp (VecAbs I32x4))
  | "i32x4.neg" -> INSTR (VecUnOp (VecNeg I32x4))
  | "i32x4.max_u" -> INSTR (VecBinOp (VecMax (Some Unsigned, I32x4)))
  | "i32x4.all_true" -> INSTR (VecTest (AllTrue I32x4))
  | "i32x4.bitmask" -> INSTR (VecBitmask (Bitmask I32x4))
  | "i32x4.extend_low_i16x8_s" ->
      INSTR (VecUnOp (VecExtend (`Low, `_16, Signed)))
  | "i32x4.extend_high_i16x8_s" ->
      INSTR (VecUnOp (VecExtend (`High, `_16, Signed)))
  | "i32x4.extend_low_i16x8_u" ->
      INSTR (VecUnOp (VecExtend (`Low, `_16, Unsigned)))
  | "i32x4.extend_high_i16x8_u" ->
      INSTR (VecUnOp (VecExtend (`High, `_16, Unsigned)))
  | "i32x4.shl" -> INSTR (VecShift (Shl I32x4))
  | "i32x4.shr_s" -> INSTR (VecShift (Shr (Signed, I32x4)))
  | "i32x4.shr_u" -> INSTR (VecShift (Shr (Unsigned, I32x4)))
  | "i32x4.add" -> INSTR (VecBinOp (VecAdd I32x4))
  | "i32x4.sub" -> INSTR (VecBinOp (VecSub I32x4))
  | "i32x4.mul" -> INSTR (VecBinOp (VecMul I32x4))
  | "i32x4.min_s" -> INSTR (VecBinOp (VecMin (Some Signed, I32x4)))
  | "i32x4.min_u" -> INSTR (VecBinOp (VecMin (Some Unsigned, I32x4)))
  | "i32x4.max_s" -> INSTR (VecBinOp (VecMax (Some Signed, I32x4)))
  | "i32x4.max_u" -> INSTR (VecBinOp (VecMax (Some Unsigned, I32x4)))
  | "i8x16.relaxed_swizzle" -> INSTR (VecBinOp VecRelaxedSwizzle)
  | "v128.i8x16.swizzle" -> INSTR (VecBinOp VecSwizzle)
  | "i32x4.relaxed_trunc_f32x4_s" -> INSTR (VecUnOp (VecRelaxedTrunc Signed))
  | "i32x4.relaxed_trunc_f32x4_u" -> INSTR (VecUnOp (VecRelaxedTrunc Unsigned))
  | "i32x4.relaxed_trunc_f64x2_s_zero" ->
      INSTR (VecUnOp (VecRelaxedTruncZero Signed))
  | "i32x4.relaxed_trunc_f64x2_u_zero" ->
      INSTR (VecUnOp (VecRelaxedTruncZero Unsigned))
  | "f32x4.relaxed_madd" -> VEC_TERN_OP (VecRelaxedMAdd `F32)
  | "f32x4.relaxed_nmadd" -> VEC_TERN_OP (VecRelaxedNMAdd `F32)
  | "f64x2.relaxed_madd" -> VEC_TERN_OP (VecRelaxedMAdd `F64)
  | "f64x2.relaxed_nmadd" -> VEC_TERN_OP (VecRelaxedNMAdd `F64)
  | "i8x16.relaxed_laneselect" -> VEC_TERN_OP (VecRelaxedLaneSelect I8x16)
  | "i16x8.relaxed_laneselect" -> VEC_TERN_OP (VecRelaxedLaneSelect I16x8)
  | "i32x4.relaxed_laneselect" -> VEC_TERN_OP (VecRelaxedLaneSelect I32x4)
  | "i64x2.relaxed_laneselect" -> VEC_TERN_OP (VecRelaxedLaneSelect I64x2)
  | "f32x4.relaxed_min" -> INSTR (VecBinOp (VecRelaxedMin F32x4))
  | "f32x4.relaxed_max" -> INSTR (VecBinOp (VecRelaxedMax F32x4))
  | "f64x2.relaxed_min" -> INSTR (VecBinOp (VecRelaxedMin F64x2))
  | "f64x2.relaxed_max" -> INSTR (VecBinOp (VecRelaxedMax F64x2))
  | "i16x8.relaxed_q15mulr_s" -> INSTR (VecBinOp VecRelaxedQ15Mulr)
  | "i16x8.relaxed_dot_i8x16_i7x16_s" -> INSTR (VecBinOp VecRelaxedDot)
  | "i32x4.relaxed_dot_i8x16_i7x16_add_s" -> VEC_TERN_OP VecRelaxedDotAdd
  | "i32x4.dot_i16x8_s" -> INSTR (VecBinOp VecDot)
  | "i16x8.extmul_low_i8x16_s" -> INSTR (VecBinOp (VecExtMulLow (Signed, `_8)))
  | "i16x8.extmul_high_i8x16_s" ->
      INSTR (VecBinOp (VecExtMulHigh (Signed, `_8)))
  | "i16x8.extmul_low_i8x16_u" ->
      INSTR (VecBinOp (VecExtMulLow (Unsigned, `_8)))
  | "i16x8.extmul_high_i8x16_u" ->
      INSTR (VecBinOp (VecExtMulHigh (Unsigned, `_8)))
  | "i32x4.extmul_low_i16x8_s" -> INSTR (VecBinOp (VecExtMulLow (Signed, `_16)))
  | "i32x4.extmul_high_i16x8_s" ->
      INSTR (VecBinOp (VecExtMulHigh (Signed, `_16)))
  | "i32x4.extmul_low_i16x8_u" ->
      INSTR (VecBinOp (VecExtMulLow (Unsigned, `_16)))
  | "i32x4.extmul_high_i16x8_u" ->
      INSTR (VecBinOp (VecExtMulHigh (Unsigned, `_16)))
  | "i64x2.extmul_low_i32x4_s" -> INSTR (VecBinOp (VecExtMulLow (Signed, `_32)))
  | "i64x2.extmul_high_i32x4_s" ->
      INSTR (VecBinOp (VecExtMulHigh (Signed, `_32)))
  | "i64x2.extmul_low_i32x4_u" ->
      INSTR (VecBinOp (VecExtMulLow (Unsigned, `_32)))
  | "i64x2.extmul_high_i32x4_u" ->
      INSTR (VecBinOp (VecExtMulHigh (Unsigned, `_32)))
  | "i32x4.extadd_pairwise_i16x8_s" ->
      INSTR (VecUnOp (VecExtAddPairwise (Signed, `I16)))
  | "i32x4.extadd_pairwise_i16x8_u" ->
      INSTR (VecUnOp (VecExtAddPairwise (Unsigned, `I16)))
  | "i32x4.eq" -> INSTR (VecBinOp (VecEq I32x4))
  | "i32x4.ne" -> INSTR (VecBinOp (VecNe I32x4))
  | "i32x4.lt_s" -> INSTR (VecBinOp (VecLt (Some Signed, I32x4)))
  | "i32x4.lt_u" -> INSTR (VecBinOp (VecLt (Some Unsigned, I32x4)))
  | "i32x4.gt_s" -> INSTR (VecBinOp (VecGt (Some Signed, I32x4)))
  | "i32x4.gt_u" -> INSTR (VecBinOp (VecGt (Some Unsigned, I32x4)))
  | "i32x4.le_s" -> INSTR (VecBinOp (VecLe (Some Signed, I32x4)))
  | "i32x4.le_u" -> INSTR (VecBinOp (VecLe (Some Unsigned, I32x4)))
  | "i32x4.ge_s" -> INSTR (VecBinOp (VecGe (Some Signed, I32x4)))
  | "i32x4.ge_u" -> INSTR (VecBinOp (VecGe (Some Unsigned, I32x4)))
  | "i64x2.abs" -> INSTR (VecUnOp (VecAbs I64x2))
  | "i64x2.neg" -> INSTR (VecUnOp (VecNeg I64x2))
  | "i64x2.all_true" -> INSTR (VecTest (AllTrue I64x2))
  | "i64x2.bitmask" -> INSTR (VecBitmask (Bitmask I64x2))
  | "f32x4.eq" -> INSTR (VecBinOp (VecEq F32x4))
  | "f32x4.ne" -> INSTR (VecBinOp (VecNe F32x4))
  | "f32x4.lt" -> INSTR (VecBinOp (VecLt (None, F32x4)))
  | "f32x4.gt" -> INSTR (VecBinOp (VecGt (None, F32x4)))
  | "f32x4.le" -> INSTR (VecBinOp (VecLe (None, F32x4)))
  | "f32x4.ge" -> INSTR (VecBinOp (VecGe (None, F32x4)))
  | "f64x2.eq" -> INSTR (VecBinOp (VecEq F64x2))
  | "f64x2.ne" -> INSTR (VecBinOp (VecNe F64x2))
  | "f64x2.lt" -> INSTR (VecBinOp (VecLt (None, F64x2)))
  | "f64x2.gt" -> INSTR (VecBinOp (VecGt (None, F64x2)))
  | "f64x2.le" -> INSTR (VecBinOp (VecLe (None, F64x2)))
  | "f64x2.ge" -> INSTR (VecBinOp (VecGe (None, F64x2)))
  | "i64x2.extend_low_i32x4_s" ->
      INSTR (VecUnOp (VecExtend (`Low, `_32, Signed)))
  | "i64x2.extend_high_i32x4_s" ->
      INSTR (VecUnOp (VecExtend (`High, `_32, Signed)))
  | "i64x2.extend_low_i32x4_u" ->
      INSTR (VecUnOp (VecExtend (`Low, `_32, Unsigned)))
  | "i64x2.extend_high_i32x4_u" ->
      INSTR (VecUnOp (VecExtend (`High, `_32, Unsigned)))
  | "i64x2.shl" -> INSTR (VecShift (Shl I64x2))
  | "i64x2.shr_s" -> INSTR (VecShift (Shr (Signed, I64x2)))
  | "i64x2.shr_u" -> INSTR (VecShift (Shr (Unsigned, I64x2)))
  | "i64x2.add" -> INSTR (VecBinOp (VecAdd I64x2))
  | "i64x2.sub" -> INSTR (VecBinOp (VecSub I64x2))
  | "i64x2.mul" -> INSTR (VecBinOp (VecMul I64x2))
  | "i64x2.eq" -> INSTR (VecBinOp (VecEq I64x2))
  | "i64x2.ne" -> INSTR (VecBinOp (VecNe I64x2))
  | "i64x2.lt_s" -> INSTR (VecBinOp (VecLt (Some Signed, I64x2)))
  | "i64x2.gt_s" -> INSTR (VecBinOp (VecGt (Some Signed, I64x2)))
  | "i64x2.le_s" -> INSTR (VecBinOp (VecLe (Some Signed, I64x2)))
  | "i64x2.ge_s" -> INSTR (VecBinOp (VecGe (Some Signed, I64x2)))
  | "f32x4.abs" -> INSTR (VecUnOp (VecAbs F32x4))
  | "f32x4.neg" -> INSTR (VecUnOp (VecNeg F32x4))
  | "f32x4.sqrt" -> INSTR (VecUnOp (VecSqrt `F32))
  | "f32x4.ceil" -> INSTR (VecUnOp (VecCeil `F32))
  | "f32x4.floor" -> INSTR (VecUnOp (VecFloor `F32))
  | "f32x4.trunc" -> INSTR (VecUnOp (VecTrunc `F32))
  | "f32x4.nearest" -> INSTR (VecUnOp (VecNearest `F32))
  | "f32x4.add" -> INSTR (VecBinOp (VecAdd F32x4))
  | "f32x4.sub" -> INSTR (VecBinOp (VecSub F32x4))
  | "f32x4.mul" -> INSTR (VecBinOp (VecMul F32x4))
  | "f32x4.div" -> INSTR (VecBinOp (VecDiv `F32))
  | "f32x4.min" -> INSTR (VecBinOp (VecMin (None, F32x4)))
  | "f32x4.max" -> INSTR (VecBinOp (VecMax (None, F32x4)))
  | "f32x4.pmin" -> INSTR (VecBinOp (VecPMin `F32))
  | "f32x4.pmax" -> INSTR (VecBinOp (VecPMax `F32))
  | "f32x4.eq" -> INSTR (VecBinOp (VecEq F32x4))
  | "f32x4.ne" -> INSTR (VecBinOp (VecNe F32x4))
  | "f32x4.lt" -> INSTR (VecBinOp (VecLt (None, F32x4)))
  | "f32x4.gt" -> INSTR (VecBinOp (VecGt (None, F32x4)))
  | "f32x4.le" -> INSTR (VecBinOp (VecLe (None, F32x4)))
  | "f32x4.ge" -> INSTR (VecBinOp (VecGe (None, F32x4)))
  | "f64x2.abs" -> INSTR (VecUnOp (VecAbs F64x2))
  | "f64x2.neg" -> INSTR (VecUnOp (VecNeg F64x2))
  | "f64x2.sqrt" -> INSTR (VecUnOp (VecSqrt `F64))
  | "f64x2.ceil" -> INSTR (VecUnOp (VecCeil `F64))
  | "f64x2.floor" -> INSTR (VecUnOp (VecFloor `F64))
  | "f64x2.trunc" -> INSTR (VecUnOp (VecTrunc `F64))
  | "f64x2.nearest" -> INSTR (VecUnOp (VecNearest `F64))
  | "f64x2.add" -> INSTR (VecBinOp (VecAdd F64x2))
  | "f64x2.sub" -> INSTR (VecBinOp (VecSub F64x2))
  | "f64x2.mul" -> INSTR (VecBinOp (VecMul F64x2))
  | "f64x2.div" -> INSTR (VecBinOp (VecDiv `F64))
  | "f64x2.min" -> INSTR (VecBinOp (VecMin (None, F64x2)))
  | "f64x2.max" -> INSTR (VecBinOp (VecMax (None, F64x2)))
  | "f64x2.pmin" -> INSTR (VecBinOp (VecPMin `F64))
  | "f64x2.pmax" -> INSTR (VecBinOp (VecPMax `F64))
  | "f64x2.eq" -> INSTR (VecBinOp (VecEq F64x2))
  | "f64x2.ne" -> INSTR (VecBinOp (VecNe F64x2))
  | "f64x2.lt" -> INSTR (VecBinOp (VecLt (None, F64x2)))
  | "f64x2.gt" -> INSTR (VecBinOp (VecGt (None, F64x2)))
  | "f64x2.le" -> INSTR (VecBinOp (VecLe (None, F64x2)))
  | "f64x2.ge" -> INSTR (VecBinOp (VecGe (None, F64x2)))
  | "i32x4.trunc_sat_f32x4_s" -> INSTR (VecUnOp (VecTruncSat (`F32, Signed)))
  | "i32x4.trunc_sat_f32x4_u" -> INSTR (VecUnOp (VecTruncSat (`F32, Unsigned)))
  | "f32x4.convert_i32x4_s" -> INSTR (VecUnOp (VecConvert (`F32, Signed)))
  | "f32x4.convert_i32x4_u" -> INSTR (VecUnOp (VecConvert (`F32, Unsigned)))
  | "i32x4.trunc_sat_f64x2_s_zero" ->
      INSTR (VecUnOp (VecTruncSat (`F64, Signed)))
  | "i32x4.trunc_sat_f64x2_u_zero" ->
      INSTR (VecUnOp (VecTruncSat (`F64, Unsigned)))
  | "f64x2.convert_low_i32x4_s" -> INSTR (VecUnOp (VecConvert (`F64, Signed)))
  | "f64x2.convert_low_i32x4_u" -> INSTR (VecUnOp (VecConvert (`F64, Unsigned)))
  | "f32x4.demote_f64x2_zero" -> INSTR (VecUnOp VecDemote)
  | "f64x2.promote_low_f32x4" -> INSTR (VecUnOp VecPromote)
  | "i32.wrap_i64" -> INSTR I32WrapI64
  | "i32.trunc_f32_s" -> INSTR (UnOp (I32 (Trunc (`F32, Signed))))
  | "i32.trunc_f32_u" -> INSTR (UnOp (I32 (Trunc (`F32, Unsigned))))
  | "i32.trunc_f64_s" -> INSTR (UnOp (I32 (Trunc (`F64, Signed))))
  | "i32.trunc_f64_u" -> INSTR (UnOp (I32 (Trunc (`F64, Unsigned))))
  | "i32.trunc_sat_f32_s" -> INSTR (UnOp (I32 (TruncSat (`F32, Signed))))
  | "i32.trunc_sat_f32_u" -> INSTR (UnOp (I32 (TruncSat (`F32, Unsigned))))
  | "i32.trunc_sat_f64_s" -> INSTR (UnOp (I32 (TruncSat (`F64, Signed))))
  | "i32.trunc_sat_f64_u" -> INSTR (UnOp (I32 (TruncSat (`F64, Unsigned))))
  | "i64.extend_i32_s" -> INSTR (I64ExtendI32 Signed)
  | "i64.extend_i32_u" -> INSTR (I64ExtendI32 Unsigned)
  | "i64.trunc_f32_s" -> INSTR (UnOp (I64 (Trunc (`F32, Signed))))
  | "i64.trunc_f32_u" -> INSTR (UnOp (I64 (Trunc (`F32, Unsigned))))
  | "i64.trunc_f64_s" -> INSTR (UnOp (I64 (Trunc (`F64, Signed))))
  | "i64.trunc_f64_u" -> INSTR (UnOp (I64 (Trunc (`F64, Unsigned))))
  | "i64.trunc_sat_f32_s" -> INSTR (UnOp (I64 (TruncSat (`F32, Signed))))
  | "i64.trunc_sat_f32_u" -> INSTR (UnOp (I64 (TruncSat (`F32, Unsigned))))
  | "i64.trunc_sat_f64_s" -> INSTR (UnOp (I64 (TruncSat (`F64, Signed))))
  | "i64.trunc_sat_f64_u" -> INSTR (UnOp (I64 (TruncSat (`F64, Unsigned))))
  | "f32.convert_i32_s" -> INSTR (UnOp (F32 (Convert (`I32, Signed))))
  | "f32.convert_i32_u" -> INSTR (UnOp (F32 (Convert (`I32, Unsigned))))
  | "f32.convert_i64_s" -> INSTR (UnOp (F32 (Convert (`I64, Signed))))
  | "f32.convert_i64_u" -> INSTR (UnOp (F32 (Convert (`I64, Unsigned))))
  | "f32.demote_f64" -> INSTR F32DemoteF64
  | "f64.convert_i32_s" -> INSTR (UnOp (F64 (Convert (`I32, Signed))))
  | "f64.convert_i32_u" -> INSTR (UnOp (F64 (Convert (`I32, Unsigned))))
  | "f64.convert_i64_s" -> INSTR (UnOp (F64 (Convert (`I64, Signed))))
  | "f64.convert_i64_u" -> INSTR (UnOp (F64 (Convert (`I64, Unsigned))))
  | "f64.promote_f32" -> INSTR F64PromoteF32
  | "i32.reinterpret_f32" -> INSTR (UnOp (I32 Reinterpret))
  | "i64.reinterpret_f64" -> INSTR (UnOp (I64 Reinterpret))
  | "f32.reinterpret_i32" -> INSTR (UnOp (F32 Reinterpret))
  | "f64.reinterpret_i64" -> INSTR (UnOp (F64 Reinterpret))
  | "i32.extend8_s" -> INSTR (UnOp (I32 (ExtendS `_8)))
  | "i32.extend16_s" -> INSTR (UnOp (I32 (ExtendS `_16)))
  | "i64.extend8_s" -> INSTR (UnOp (I64 (ExtendS `_8)))
  | "i64.extend16_s" -> INSTR (UnOp (I64 (ExtendS `_16)))
  | "i64.extend32_s" -> INSTR (UnOp (I64 (ExtendS `_32)))
  | "extern.convert_any" -> INSTR ExternConvertAny
  | "any.convert_extern" -> INSTR AnyConvertExtern
  | "tag" -> TAG
  | "try" -> TRY
  | "try_table" -> TRY_TABLE
  | "do" -> DO
  | "catch" -> CATCH
  | "catch_ref" -> LPAREN_CATCH_REF
  | "catch_all" -> CATCH_ALL
  | "catch_all_ref" -> LPAREN_CATCH_ALL_REF
  | "throw" -> THROW
  | "throw_ref" -> THROW_REF
  | "cont.new" -> CONT_NEW
  | "cont.bind" -> CONT_BIND
  | "suspend" -> SUSPEND
  | "resume" -> RESUME
  | "resume_throw" -> RESUME_THROW
  | "resume_throw_ref" -> RESUME_THROW_REF
  | "switch" -> SWITCH
  | "on" -> LPAREN_ON
  | "align=", uN ->
      MEM_ALIGN
        (Sedlexing.Utf8.sub_lexeme lexbuf 6
           (Sedlexing.lexeme_length lexbuf - 6))
  | "offset=", uN ->
      MEM_OFFSET
        (Sedlexing.Utf8.sub_lexeme lexbuf 7
           (Sedlexing.lexeme_length lexbuf - 7))
  | "definition" -> DEFINITION
  | "binary" -> BINARY
  | "quote" -> QUOTE
  | "instance" -> INSTANCE
  | "register" -> REGISTER
  | "invoke" -> INVOKE
  | "get" -> GET
  | "ref.host" -> REF_HOST
  | "assert_return" -> ASSERT_RETURN
  | "assert_exception" -> ASSERT_EXCEPTION
  | "assert_suspension" -> ASSERT_SUSPENSION
  | "assert_trap" -> ASSERT_TRAP
  | "assert_exhaustion" -> ASSERT_EXHAUSTION
  | "assert_malformed" -> ASSERT_MALFORMED
  | "assert_invalid" -> ASSERT_INVALID
  | "assert_unlinkable" -> ASSERT_UNLINKABLE
  | "assert_return_arithmetic_nan" | "assert_return_canonical_nan" ->
      ASSERT_RETURN_NAN
  | "nan:canonical" | "nan:arithmetic" -> NAN
  | "ref.extern" -> REF_EXTERN
  | "ref.struct" -> REF_STRUCT
  | "ref.array" -> REF_ARRAY
  | "either" -> EITHER
  | "script" -> SCRIPT
  | "input" -> INPUT
  | "output" -> OUTPUT
  (* Operators of conditional annotation conditions *)
  | "and" -> AND
  | "or" -> OR
  | "not" -> NOT
  | "=" -> CMP_EQ
  | "<>" -> CMP_NE
  | "<" -> CMP_LT
  | ">" -> CMP_GT
  | "<=" -> CMP_LE
  | ">=" -> CMP_GE
  | keyword -> (
      let s = Sedlexing.Utf8.lexeme lexbuf in
      (* The atomic mnemonics are matched here via the shared table rather than
         as ~66 explicit arms (see {!Atomics}). *)
      match Atomics.of_name s with
      | Some op -> ATOMIC op
      | None ->
          raise
            (Parsing.Syntax_error
               ( Sedlexing.lexing_bytes_positions lexbuf,
                 Printf.sprintf "Unknown keyword '%s'.\n" s )))
  | reserved, Opt '"' ->
      raise
        (Parsing.Syntax_error
           ( Sedlexing.lexing_bytes_positions lexbuf,
             Printf.sprintf "Unknown token '%s'.\n"
               (Sedlexing.Utf8.lexeme lexbuf) ))
  | _ ->
      raise
        (Parsing.Syntax_error
           ( Sedlexing.lexing_bytes_positions lexbuf,
             Printf.sprintf "Syntax error.\n" ))

(*** Entry points ***)

let token ctx =
  let prev_token = ref None in
  (* A compound opener — [(param], [(then], [(catch], … — is two lexemes: the
     [(] is read first (stashed as [LPAREN]) and the keyword next, so the
     lexbuf's reported start would be the keyword's, not the [(]'s. Capture the
     [(] position when it is stashed and, when the pair is combined into one
     token, report it as that token's start via [start_override] (read by the
     supplier in [Parsing]). The combined token's span thus really begins at its
     opening parenthesis. *)
  let paren_start = ref Lexing.dummy_pos in
  let start_override = ref None in
  let f lexbuf =
    start_override := None;
    let rec loop () =
      let t = token_rec ctx lexbuf in
      let end_ = Sedlexing.lexing_bytes_position_curr lexbuf in
      Wax_utils.Trivia.report_token ctx end_.pos_cnum;
      (* Emit a token combined from the stashed [(] and its keyword, starting at
         the [(]. *)
      let combined tok =
        prev_token := None;
        start_override := Some !paren_start;
        tok
      in
      match (!prev_token, t) with
      | ( None,
          ( LPAREN_CATCH_ALL_REF | LPAREN_CATCH_REF | LPAREN_EXPORT
          | LPAREN_IMPORT | LPAREN_LOCAL | LPAREN_PARAM | LPAREN_RESULT
          | LPAREN_THEN | LPAREN_TYPE | LPAREN_ON | LPAREN_DESCRIPTOR
          | LPAREN_DESCRIBES ) ) ->
          raise
            (Parsing.Syntax_error
               ( Sedlexing.lexing_bytes_positions lexbuf,
                 Printf.sprintf "Unexpected keyword '%s'.\n"
                   (Sedlexing.Utf8.lexeme lexbuf) ))
      | None, LPAREN ->
          paren_start := fst (Sedlexing.lexing_bytes_positions lexbuf);
          prev_token := Some t;
          loop ()
      | None, _ -> t
      | Some LPAREN, CATCH -> combined LPAREN_CATCH
      | Some LPAREN, CATCH_ALL -> combined LPAREN_CATCH_ALL
      | ( Some LPAREN,
          ( LPAREN_CATCH_ALL_REF | LPAREN_CATCH_REF | LPAREN_EXPORT
          | LPAREN_IMPORT | LPAREN_LOCAL | LPAREN_PARAM | LPAREN_RESULT
          | LPAREN_THEN | LPAREN_TYPE | LPAREN_ON | LPAREN_DESCRIPTOR
          | LPAREN_DESCRIBES ) ) ->
          combined t
      | Some t', _ ->
          prev_token := Some t;
          t'
    in
    match !prev_token with
    | Some t when t <> LPAREN ->
        prev_token := None;
        t
    | _ -> loop ()
  in
  (f, start_override)

let is_valid_identifier s =
  let buf = Sedlexing.Utf8.from_string s in
  match%sedlex buf with Plus idchar, eof -> true | _ -> false
