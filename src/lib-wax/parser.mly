%token <string> IDENT
%token <string> INT
%token <string> FLOAT
%token <(string, Ast.location) Ast.annotated> STRING
%token <Uchar.t> CHAR

%token EOF
%token INF NAN
%token SEMI ";"
%token SHARP "#"
%token QUESTIONMARK "?"
%token LPAREN "("
%token RPAREN ")"
%token LBRACE "{"
%token RBRACE "}"
%token LBRACKET "["
%token RBRACKET "]"
%token COMMA ","
%token COLON ":"
%token COLONCOLON "::"
%token ARROW "->"
%token FATARROW "=>"
%token EQUAL "="
%token COLONEQUAL ":="
%token AT "@"
%token QUOTE "'"
%token DOT "."
%token DOTDOT ".."
%token BANG "!"
%token PLUS "+"
%token PLUSPLUS "++"
%token PLUSEQUAL "+="
%token MINUS "-"
%token MINUSEQUAL "-="
%token STAR "*"
%token STAREQUAL "*="
%token SLASH "/"
%token SLASHEQUAL "/="
%token SLASHS "/s"
%token SLASHSEQUAL "/s="
%token SLASHU "/u"
%token SLASHUEQUAL "/u="
%token PERCENTS "%s"
%token PERCENTSEQUAL "%s="
%token PERCENTU "%u"
%token PERCENTUEQUAL "%u="
%token AMPERSAND "&"
%token AMPERSANDEQUAL "&="
%token PIPE "|"
%token PIPEEQUAL "|="
%token CARET "^"
%token CARETEQUAL "^="
%token SHL "<<"
%token SHLEQUAL "<<="
%token SHRS ">>s"
%token SHRSEQUAL ">>s="
%token SHRU ">>u"
%token SHRUEQUAL ">>u="
%token EQUALEQUAL "=="
%token BANGEQUAL "!="
%token GT ">"
%token GTS ">s"
%token GTU ">u"
%token LT "<"
%token LTS "<s"
%token LTU "<u"
%token GE ">="
%token GES ">=s"
%token GEU ">=u"
%token LE "<="
%token LES "<=s"
%token LEU "<=u"
%token UNDERSCORE "_"

%token FN
%token TAG
%token MUT
%token TYPE
%token REC
%token OPEN
%token NOP UNREACHABLE NULL
%token DO WHILE LOOP IF ELSE
%token CONST LET AS IS
%token BECOME
%token BR BR_IF BR_TABLE RETURN THROW THROW_REF
%token BR_ON_CAST BR_ON_CAST_FAIL
%token BR_ON_NULL BR_ON_NON_NULL
%token TRY TRY_LEGACY CATCH
%token CONT
%token SUSPEND ON
%token DISPATCH
%token MATCH
%token MEMORY DATA TABLE ELEM PAGESIZE SHARED
%token DESCRIPTOR DESCRIBES
%token IMPORT

(* Nonterminals Menhir should reduce *before* reporting a syntax error, so the
   error surfaces one state higher — where the enclosing construct's closer is
   expected — rather than deep inside the nonterminal itself. This matters most
   for the list-like/emptyable contents of a bracketed construct: without the
   directive, an unclosed "{ … EOF" reports the internal "Expecting a raw
   statement list" with no idea a "}" is missing; with it, the empty tail reduces
   and the error becomes "expecting '}'" with a hint pointing back at the opener.
   INVARIANT: every list-like nonterminal that sits directly inside a "{ … }" /
   "( … )" / "[ … ]" belongs here — the semi_list/list instantiations used as
   brace-block bodies (statement_list/raw_statement_list, the match/dispatch/
   import/try/module-field arm lists, list(data_item)) and the separated lists.
   When you add a new brace-delimited list construct, add its list nonterminal
   here too.

   Note the tradeoff: because the same error state is reached whether the
   construct is unclosed (EOF) or has an invalid token inside an already-closed
   one, the opener hint is worded locationally ("opens the enclosing construct",
   see generate_error_messages.ml) rather than claiming it is unmatched, which
   would be false in the latter case. *)
%on_error_reduce statement plaininstr separated_nonempty_list_trailing(",",structure_type_field) semi_list(module_field) separated_nonempty_list_trailing(",",value_type) separated_nonempty_list_trailing(",",function_parameter) list(attribute) separated_nonempty_list_trailing(",",let_pattern) separated_nonempty_list_trailing(",",block_param_type) blockinstr raw_statement_list semi_list(import_item) separated_nonempty_list_trailing(",",expression) structure_field separated_nonempty_list_trailing(",",structure_field) constant_expression attribute_expression parenthesized_expression index_expression then_branch condition_expression length_expression argument separated_nonempty_list_trailing(",",argument)


%nonassoc prec_ident (* {a|...} *) prec_block
%right prec_branch
%right ":=" "="
%right "?" ":"
%nonassoc "==" "!=" "<" "<u" "<s" ">" ">u" ">s" "<=" "<=u" "<=s" ">=" ">=u" ">=s"
%left "|"
%left "^"
%left "&"
%left "<<" ">>u" ">>s"
%left "+" "-"
%left "*" "/" "/u" "/s" "%u" "%s"
%left AS IS ON
%nonassoc prec_unary
%nonassoc "!"
%left "." "(" "["

(* BR 'foo 1 + 2 understood as BR 'foo (1 + 2)
   BR_TABLE { ...} 1 + 2 understood as BR_TABLE { ...} (1 + 2)
   BR foo { ... } understood as a single instruction
   LET x = br foo LET --> LET x = (br foo) LET  (LET < branch)
   { ... } ( ... } --> sequence (instr < LPAREN)
   {a| b:}  ==> struct; {a|b} should need parenthesis <<< special case??
                            (IDENT < PIPE)
*)

%parameter <Context : sig type t val context : Wax_utils.Trivia.context end>

%{
open Ast

let tbl_from_list l =
 let h = Hashtbl.create (2 * List.length l) in
 List.iter (fun (k, v) -> Hashtbl.add h k v) l;
 h

let absheaptype_tbl =
  tbl_from_list
    ["func", (Func : heaptype);
     "nofunc", NoFunc;
     "exn", Exn;
     "noexn", NoExn;
     "nocont", NoCont;
     "extern", Extern;
     "noextern", NoExtern;
     "any", Any;
     "eq", Eq;
     "i31", I31;
     "struct", Struct;
     "array", Array;
     "none", None_]

let valtype_tbl =
  tbl_from_list
    ["i32", (I32 : valtype); "i64", I64; "f32", F32; "f64", F64; "v128", V128]

let casttype_tbl =
  let f t s s' =
    format_signed_type t s s', Signedtype {typ = t; signage = s; strict = s'} in
  tbl_from_list
    [
      f `I32 Signed false;
      f `I32 Signed true;
      f `I32 Unsigned false;
      f `I32 Unsigned true;
      f `I64 Signed false;
      f `I64 Signed true;
      f `I64 Unsigned false;
      f `I64 Unsigned true;
      f `F32 Signed false;
      f `F32 Unsigned false;
      f `F64 Signed false;
      f `F64 Unsigned false;
    ]

let storagetype_tbl =
  tbl_from_list
    ["i8", (Packed I8 : storagetype); "i16", Packed I16;
     "i32", Value I32; "i64", Value I64; "f32", Value F32; "f64", Value F64;
     "v128", Value V128]

let with_loc loc desc =
   Wax_utils.Trivia.with_pos Context.context {loc_start = fst loc; loc_end = snd loc} desc

let location_of loc : location = {loc_start = fst loc; loc_end = snd loc}

(* Build an import declaration from its parsed attributes and kind. The
   attributes (a name-only [#[import = "name"]] override, [#[export]], …) are
   kept as-is and interpreted downstream. *)
let make_import_decl loc attributes (id, kind) =
  with_loc loc {id; kind; attributes}

(* Branch-hinting proposal: [#[likely]]/[#[unlikely]] may only prefix a
   conditional branch. Wrap it in [Hinted]; reject the attribute anywhere else. *)
let is_branch_hint_target = function
  | If _ | Br_if _ | Br_on_null _ | Br_on_non_null _ | Br_on_cast _
  | Br_on_cast_fail _ | Br_on_cast_desc_eq _ | Br_on_cast_desc_eq_fail _ -> true
  | _ -> false

let hinted loc h (i : _ instr) =
  if is_branch_hint_target i.desc then with_loc loc (Hinted (h, i))
  else
    raise
      (Wax_wasm.Parsing.syntax_error_pair
         (loc,
           Wax_utils.Message.text ("A branch hint may only prefix a conditional branch (if, br_if, or \
           br_on_*).\n") ))

(* [#[likely]]/[#[unlikely]] are parsed as ordinary attributes (the lexer no
   longer has dedicated tokens); recover the hint's boolean, rejecting any other
   attribute in a branch-hint position. *)
let branch_hint_of_attr loc (name, value, _guard) =
  match (name, value) with
  | "likely", None -> true
  | "unlikely", None -> false
  | _ ->
      raise
        (Wax_wasm.Parsing.syntax_error_pair
           (loc,
           Wax_utils.Message.text ("Expected a branch hint '#[likely]' or '#[unlikely]'.\n") ))

(* Statement-level conditional annotations. The parser cannot pair [#[if]] with a
   following [#[else]] itself: with [#[else]] no longer a single token, that
   dangling-else decision is not LALR(1). So each brace group is parsed into a
   marker and [process_stmts] pairs adjacent [#[if]]/[#[else]] groups into an
   [If_annotation], leaving every other statement untouched. *)
type raw_stmt =
  | RS_plain of location instr
  | RS_if of (Lexing.position * Lexing.position) * Wax_wasm.Ast.cond
      * (location instr list, location) annotated
  | RS_else of (Lexing.position * Lexing.position)
      * (location instr list, location) annotated

let rec process_stmts = function
  | [] -> []
  | RS_plain i :: rest -> i :: process_stmts rest
  | RS_if (loc, cond, then_body) :: RS_else (eloc, else_body) :: rest ->
      (* Keep each branch's own [#[if]/#[else] { … }] span (marker included) on
         its located body, not just the combined span on the node, so a consumer
         (the editor's dead-branch dimming) can locate a single branch. *)
      with_loc (fst loc, snd eloc)
        (If_annotation
           {
             cond;
             then_body = { then_body with info = location_of loc };
             else_body = Some { else_body with info = location_of eloc };
           })
      :: process_stmts rest
  | RS_if (loc, cond, then_body) :: rest ->
      with_loc loc
        (If_annotation
           {
             cond;
             then_body = { then_body with info = location_of loc };
             else_body = None;
           })
      :: process_stmts rest
  | RS_else (loc, _) :: _ ->
      raise
        (Wax_wasm.Parsing.syntax_error_pair
           (loc,
           Wax_utils.Message.text ("An '#[else]' must directly follow an '#[if(...)]' group.\n") ))

(* Build a binary/unary operator node, giving the operator itself a source
   location (its token span [oploc]) so a comment sitting between an operand and
   the operator attaches to the right place. [_tok] is the operator token's
   (unit) value, taken only so its [o = "..."] binder counts as used. *)
let binop sloc _tok oploc op i j = with_loc sloc (BinOp (with_loc oploc op, i, j))
let unop sloc _tok oploc op i = with_loc sloc (UnOp (with_loc oploc op, i))

(* Apply a module field's leading attributes. When there are attributes, widen
   the field location (built by [d] from the definition alone) to span them, so
   comments and blank lines preceding the attributes attach to the field rather
   than to an attribute's inner expression. *)
let attributed loc attributes d =
  let f = d attributes in
  match attributes with [] -> f | _ :: _ -> with_loc loc f.desc

(* Module-field conditional annotations, the [#[if(...)]]/[#[else]] counterpart
   of [raw_stmt]. Braces are mandatory: [#[if(c)] { fields }] and
   [#[else] { fields }] carry a located field list, and [lower_fields] pairs a
   marker with the following [#[else]] sibling into a [Conditional]. Nesting is
   expressed by the braces (a nested [#[if]] lives inside a branch's field list),
   so pairing is plain adjacency — no dangling-else search. *)
type located_fields = (location module_, location) annotated

type raw_field =
  | RF_plain of (location modulefield, location) annotated
  | RF_if of (Lexing.position * Lexing.position) * Wax_wasm.Ast.cond
      * located_fields
  | RF_else of (Lexing.position * Lexing.position) * located_fields

let rec lower_fields = function
  | [] -> []
  | RF_plain f :: rest -> f :: lower_fields rest
  | RF_if (loc, cond, then_fields) :: RF_else (eloc, else_fields) :: rest ->
      (* Keep each branch's own [#[if]/#[else] { … }] span (marker included) on
         its located body — see [process_stmts]. *)
      with_loc (fst loc, snd eloc)
        (Conditional
           {
             cond;
             then_fields = { then_fields with info = location_of loc };
             else_fields = Some { else_fields with info = location_of eloc };
           })
      :: lower_fields rest
  | RF_if (loc, cond, then_fields) :: rest ->
      with_loc loc
        (Conditional
           {
             cond;
             then_fields = { then_fields with info = location_of loc };
             else_fields = None;
           })
      :: lower_fields rest
  | RF_else (loc, _) :: _ ->
      raise
        (Wax_wasm.Parsing.syntax_error_pair
           (loc,
           Wax_utils.Message.text ("An '#[else]' must directly follow an '#[if(...)]' field.\n") ))

let blocktype bt = Option.value ~default:{params = [||]; results = [||]} bt

(* A function or tag is declared with either a type reference ([: name]) or a
   parenthesized signature; one is required. A bare [tag stop;] or [fn f { ... }]
   is rejected — write [()] for an empty signature. With a type reference, the
   signature comes from it, so [sign] stays [None]. *)
let decl_sign loc t sign =
  match (t, sign) with
  | None, None ->
      (* The message names the exact repair, so derive a quick fix from it: a
         zero-width insertion of "()" at the end of the declaration parsed so far
         (the caret [snd loc], right after the name or the [: type] reference),
         where an empty parameter list belongs. *)
      let caret = snd loc in
      Wax_wasm.Parsing.syntax_error
        ~location:{ Wax_utils.Ast.loc_start = fst loc; loc_end = snd loc }
        ~fix:
          {
            Wax_utils.Diagnostic.edit_location =
              { Wax_utils.Ast.loc_start = caret; loc_end = caret };
            new_text = "()";
          }
        (Wax_utils.Message.text ("A parameter list is required.\n"))
  | _ -> sign

(* Parse an integer literal (decimal, hex, with [_] separators) to a [Uint64].
   Used for memory/table limits; a table64 bound may exceed [Int64.max_int],
   so parse across the full unsigned range. Bounds-check first: an out-of-range
   literal must surface as a recoverable syntax error, not crash
   [Uint64.of_string] (whose .mli contract requires callers to bound-check).
   The Wasm parser guards the same way ([check_constant]); the [INT] token is
   digit/hex only (never signed), so [is_int64] and [Uint64.of_string] agree. *)
let u64_of_int_literal loc n =
  if not (Wax_wasm.Misc.is_int64 n) then
    Wax_wasm.Parsing.syntax_error
      ~location:{ Wax_utils.Ast.loc_start = fst loc; loc_end = snd loc }
      ~hint:
        (Wax_utils.Message.text
           "This integer must fit in an unsigned 64-bit value (0 to \
            18446744073709551615).")
      (Wax_utils.Message.text
         (Printf.sprintf "The integer literal %s is out of range.\n" n))
  else Wax_utils.Uint64.of_string n

module V128 = Wax_utils.V128

let syntax_error loc (msg : Wax_utils.Message.t) =
  raise (Wax_wasm.Parsing.syntax_error_pair (loc, msg))

(* A version component of a conditional-compilation predicate ([#[if version =
   (1, 2, 3)]]), converted to a native [int]. Guarded with [int_of_string_opt] so
   an over-long component surfaces as a recoverable syntax error rather than
   crashing [int_of_string]. *)
let int_of_version_component loc s =
  match int_of_string_opt s with
  | Some i -> i
  | None ->
      syntax_error loc
        (Wax_utils.Message.text
           (Printf.sprintf "The version component %s is out of range.\n" s))


(* The scalar storage type named by a data-segment numeric run [[f32: …]].
   [i8]/[i16] are [Packed]; the rest are [Value]. *)
let scalar_storagetype loc (t : ident) : storagetype =
  match t.desc with
  | "i8" -> Packed I8
  | "i16" -> Packed I16
  | "i32" -> Value I32
  | "i64" -> Value I64
  | "f32" -> Value F32
  | "f64" -> Value F64
  | _ ->
      syntax_error loc
        Wax_utils.Message.(
          text "A data numeric run needs a scalar element type ("
          ^^ enumerate ~conj:"or"
               [
                 type_ "i8";
                 type_ "i16";
                 type_ "i32";
                 type_ "i64";
                 type_ "f32";
                 type_ "f64";
               ]
          ^^ text ").")

(* The vector shape named by a [v128] run element [i32x4(…)]. *)
let vec_shape loc (s : ident) : V128.shape =
  match s.desc with
  | "i8x16" -> I8x16
  | "i16x8" -> I16x8
  | "i32x4" -> I32x4
  | "i64x2" -> I64x2
  | "f32x4" -> F32x4
  | "f64x2" -> F64x2
  | _ ->
      syntax_error loc
        (Wax_utils.Message.text
           "A v128 run element is a lane group like i32x4(1, 2, 3, 4).")

(* Build a data numeric run [[t: …]]: a [v128] run of lane groups, or a scalar
   run of literals. Elements are tagged [`Vec]/[`Num] by their shape; the wrong
   kind for the run type is a syntax error. *)
let data_run loc (t : ident) items =
  let bad (info : location) msg =
    syntax_error (info.loc_start, info.loc_end) (Wax_utils.Message.text msg)
  in
  if t.desc = "v128" then
    Data_v128
      (List.map
         (function
           | `Vec v -> v
           | `Num (n : (string, location) annotated) ->
               bad n.info "Expected a v128 lane group like i32x4(1, 2, 3, 4).")
         items)
  else
    Data_run
      ( scalar_storagetype loc t,
        List.map
          (function
            | `Num n -> n
            | `Vec (v : (V128.t, location) annotated) ->
                bad v.info "Expected a scalar literal, not a v128 lane group.")
          items )

(* A custom page size is written [pagesize 65536] but stored as its base-2
   logarithm, so require a power of two (the restriction to 1 or 65536 is a
   type-checking concern). *)
let page_size_log2 loc n =
  (* Compute the base-2 logarithm on the 64-bit value directly, without first
     narrowing to [int]: a literal above [max_int] would overflow
     [Uint64.to_int]. A power of two has a single set bit; its log2 is that
     bit's position, which always fits an [int]. [u64_of_int_literal] rejects an
     out-of-range literal with a recoverable syntax error. *)
  let v = Wax_utils.Uint64.to_int64 (u64_of_int_literal loc n) in
  if (not (Int64.equal v 0L)) && Int64.equal (Int64.logand v (Int64.sub v 1L)) 0L
  then
    let rec exp x p =
      if Int64.equal x 1L then p else exp (Int64.shift_right_logical x 1) (p + 1)
    in
    exp v 0
  else
    raise
      (Wax_wasm.Parsing.syntax_error_pair
         (loc,
           Wax_utils.Message.text ("The page size must be a power of two.\n") ))
%}

%start <location module_> parse

 (* To refer to Context in the mli *)
%start <Context.t> dummy_ctx

%%

%inline separated_list_trailing(sep, X):
  | xs = loption(separated_nonempty_list_trailing(sep, X)) { xs }

separated_nonempty_list_trailing(sep, X):
  | x = X { [x] }
  | x = X; sep { [x] }
  | x = X; sep; xs = separated_nonempty_list_trailing(sep, X) { x :: xs }

dummy_ctx: EOF { assert false }

%inline ident:
| t = IDENT { with_loc $sloc t }

ident_or_keyword:
| t = IDENT { t }
| FN { "fn" }
| TAG { "tag" }
| MUT { "mut" }
| TYPE { "type" }
| REC { "rec" }
| OPEN { "open" }
| NOP { "nop" }
| UNREACHABLE { "unreachable" }
| NULL { "null" }
| DO { "do" }
| WHILE { "while" }
| LOOP { "loop" }
| IF { "if" }
| ELSE { "else" }
| CONST { "const" }
| LET { "let" }
| AS { "as" }
| IS { "is" }
| BECOME { "become" }
| BR { "br" }
| BR_IF { "br_if" }
| BR_TABLE { "br_table" }
| RETURN { "return" }
| THROW { "throw" }
| THROW_REF { "throw_ref" }
| BR_ON_CAST { "br_on_cast" }
| BR_ON_CAST_FAIL { "br_on_cast_fail" }
| BR_ON_NULL { "br_on_null" }
| BR_ON_NON_NULL { "br_on_non_null" }
| TRY { "try" }
| TRY_LEGACY { "try_legacy" }
| CATCH { "catch" }
| CONT { "cont" }
| SUSPEND { "suspend" }
| ON { "on" }
| MEMORY { "memory" }
| IMPORT { "import" }
| PAGESIZE { "pagesize" }
| SHARED { "shared" }
| DATA { "data" }
| TABLE { "table" }
| ELEM { "elem" }
| DISPATCH { "dispatch" }
| MATCH { "match" }
| DESCRIPTOR { "descriptor" }
| DESCRIBES { "describes" }
| INF { "inf" }
| NAN { "nan" }

label_name:
| l = ident_or_keyword { l }

%inline label:
| "'" l = label_name { with_loc $sloc l }

(* The comma-separated case labels of a [br_table]/[dispatch] bracket, ending
   in the mandatory [else <default>]: ['a, 'b, else 'd] or [else 'd]. *)
labels_else:
| ELSE d = label { ([], d) }
| x = label "," rest = labels_else
  { let ls, d = rest in (x :: ls, d) }

heap_type:
| CONT { (Cont : heaptype) }
| t = ident { try Hashtbl.find absheaptype_tbl t.desc with Not_found -> Type t }

reference_type:
| "&" nullable = boption("?") exact = boption("!") typ = heap_type
  { let typ =
      if exact then
        match (typ : heaptype) with
        | Type t -> Exact t
        | _ ->
            raise (Wax_wasm.Parsing.syntax_error_pair
                     ($sloc,
           Wax_utils.Message.text ("Only a concrete type can be exact.\n") ))
      else typ
    in
    { nullable; typ } }

value_type:
| t = IDENT
   { try Hashtbl.find valtype_tbl t with Not_found ->
       raise (Wax_wasm.Parsing.syntax_error_pair ($sloc,
           Wax_utils.Message.text (Printf.sprintf "Identifier '%s' is not a value type.\n" t) )) }
| t = reference_type { Ref t }

cast_type:
| t = IDENT
   { try Valtype (Hashtbl.find valtype_tbl t) with Not_found ->
       try Hashtbl.find casttype_tbl t with Not_found ->
         raise (Wax_wasm.Parsing.syntax_error_pair
                  ($sloc,
           Wax_utils.Message.text (Printf.sprintf "Identifier '%s' is not a cast type.\n" t) )) }
| t = reference_type { Valtype (Ref t) }
| "&" nullable = boption("?") FN s = function_type
   { Functype { nullable; sign = s } }
(*
| functype { assert false }
*)

result_type_:
| l = separated_nonempty_list_trailing(",", value_type) { l }

result_type:
| "(" ")" { [||] }
| t = value_type { [|t|] }
| "(" l = result_type_ ")" { Array.of_list l }

function_type_definition:
| FN s = function_type
  { s }

storage_type:
| t = IDENT
   { try Hashtbl.find storagetype_tbl t with Not_found ->
       raise (Wax_wasm.Parsing.syntax_error_pair ($sloc,
           Wax_utils.Message.text (Printf.sprintf "Identifier '%s' is not a storage type.\n" t) )) }
| t = reference_type { Value (Ref t) }

field_type:
| mut = boption(MUT) typ = storage_type { {mut; typ } }

field_name:
| i = ident { i }

structure_type_field:
| x = field_name ":" t = field_type { with_loc $sloc (x, t) }

structure_type:
| l = separated_list_trailing(",", structure_type_field) { l }

structtype:
(* A leading [..] inherits the supertype's fields (see [Ast.splice_field]); it
   must come first and appear at most once, which these productions enforce. *)
| "{" ".." "}" { [| splice_field (location_of $sloc) |] }
| "{" ".." "," l = structure_type "}"
  { Array.of_list (splice_field (location_of $sloc) :: l) }
| "{" l = structure_type "}" { Array.of_list l }

arraytype:
| "[" t = field_type "]" { t }

composite_type:
| t = structtype { Struct t }
| t = function_type_definition { Func t }
| t = arraytype { Array t }
(* A continuation type wraps a named function type: [cont ft]. *)
| CONT t = type_name { Cont t }

type_name:
| i = ident { i }

typedef:
| TYPE name = type_name
  supertype = option(":" s = type_name { s })
  "=" op = boption(OPEN)
  describes = ioption(DESCRIBES o = type_name { o })
  descriptor = ioption(DESCRIPTOR d = type_name { d })
  typ = composite_type ";"
    { with_loc $sloc
        (name, {typ; supertype; final = not op; descriptor; describes}) }

rectype:
| REC "{" l = list(typedef) "}" { with_loc $loc($1) (Array.of_list l) }
(* Reuse the typedef's own (already registered) location rather than register a
   duplicate one for the same span, which would split trivia between them. *)
| t = typedef { {desc = [|t|]; info = t.info} }

attribute_expression: e = expression { e }

(* [import] is a keyword (it heads a grouped-import block), so it is not lexed as
   an [IDENT]; accept it explicitly as an attribute name so [#[import = ...]]
   keeps working. *)
%inline attribute_name:
| name = IDENT { name }
| IMPORT { "import" }

(* An optional conditional-compilation guard on a single attribute,
   [#[export = "n", if(not(portable))]]. The guard reuses the [#[if(...)]]
   condition grammar, parentheses included; only [export] accepts one (checked
   in the typer). *)
attribute_guard:
| { None }
| "," _kw = IF "(" c = condition ")"
  { Some {desc = c; info = location_of $loc(_kw)} }

attribute:
| "#" "[" name = attribute_name "=" i = attribute_expression g = attribute_guard "]" { (name, Some i, g) }
| "#" "[" name = attribute_name g = attribute_guard "]" { (name, None, g) }

(* Branch-hinting proposal: [#[likely]]/[#[unlikely]] prefixing an [if]/[br_if].
   Parsed as an ordinary attribute (the lexer no longer has dedicated tokens);
   [branch_hint_of_attr] recovers the hint and rejects any other attribute. *)
%inline branch_hint_attr:
| a = attribute { branch_hint_of_attr $loc(a) a }

(* The conditional branches that carry an operand ([if] is a [blockinstr], handled
   separately). Shared by the plain plaininstr productions and the hinted wrapper
   so a [#[likely]]/[#[unlikely]] prefix needs no per-branch duplication. *)
branch_expr:
| BR_IF l = label i = expression { with_loc $sloc (Br_if (l, i)) } %prec prec_branch
| BR_ON_NULL l = label i = expression { with_loc $sloc (Br_on_null (l, i)) } %prec prec_branch
| BR_ON_NON_NULL l = label i = expression { with_loc $sloc (Br_on_non_null (l, i)) } %prec prec_branch
| BR_ON_CAST l = label t = reference_type i = expression { with_loc $sloc (Br_on_cast (l, t, i)) } %prec prec_branch
| BR_ON_CAST_FAIL l = label t = reference_type i = expression { with_loc $sloc (Br_on_cast_fail (l, t, i)) } %prec prec_branch
| BR_ON_CAST l = label nullable = boption("?") d = descriptor_operand i = expression { with_loc $sloc (Br_on_cast_desc_eq (l, nullable, i, d)) } %prec prec_branch
| BR_ON_CAST_FAIL l = label nullable = boption("?") d = descriptor_operand i = expression { with_loc $sloc (Br_on_cast_desc_eq_fail (l, nullable, i, d)) } %prec prec_branch

(* A module-level inner attribute, [#![module = "name"]]. *)
inner_attribute:
| "#" "!" "[" name = IDENT "=" i = attribute_expression "]" { (name, Some i, None) }
| "#" "!" "[" name = IDENT "]" { (name, None, None) }

simple_pattern:
| x = ident { Some x }
| "_" { None }

function_parameter:
| x = ident ":" t = value_type { with_loc $sloc (Some x, t) }
| t = value_type { with_loc $sloc (None, t) }

parameter_list:
| l = separated_list_trailing(",", function_parameter)
  { Array.of_list l }

function_type:
| "(" params = parameter_list ")" results = ioption("->" r = result_type {r})
  { {params; results = Option.value ~default:[||] results} }

function_name:
| i = ident { i }

optional_function_type: sign = option (function_type) { sign }

%inline fundecl:
| FN name = function_name
  ex1 = boption("!")
  t = ioption(":" ex2 = boption("!") t = type_name { (ex2, t) } )
  sign = optional_function_type
  { let ex2, t =
      match t with Some (e, t) -> (e, Some t) | None -> (false, None) in
    if ex1 && ex2 then
      raise (Wax_wasm.Parsing.syntax_error_pair
               ($sloc,
           Wax_utils.Message.text ("Duplicate exact marker '!'.\n") ));
    (name, t, decl_sign $sloc t sign, ex1 || ex2) }

func:
| f = fundecl body = block
  { fun attributes ->
    let (name, typ, sign, exact) = f in
    if exact then
      raise (Wax_wasm.Parsing.syntax_error_pair
               ($sloc,
           Wax_utils.Message.text ("A function definition is always exact; the '!' marker \
                        is only allowed on an (imported) function declaration.\n") ));
    with_loc $sloc (Func {name; typ; sign; body; attributes}) }

tag_name:
| i = ident { i }

tag_sig:
| TAG name = tag_name
  t = ioption(":" t = type_name { t } )
  sign = optional_function_type
  { (name, t, decl_sign $sloc t sign) }

%inline block_label: l = ioption(l = label ":" { l }) { l }

(* An anonymous block parameter, located at its value type so a trailing
   comment attaches to it. *)
block_param_type:
| t = value_type { with_loc $sloc (None, t) }

parameter_types:
| l = separated_list_trailing(",", block_param_type) { l }

block_type:
| "(" params = parameter_types ")"
  results = ioption("->" results = result_type {results})
  { {params = Array.of_list params;
     results = Option.value ~default:[||] results} }
| t = value_type { {params = [||]; results = [|t|] } }

catch:
| t = ident "->" l = label { Catch (t, l) }
| t = ident "&" "->" l = label { CatchRef (t, l) }
| "_" "->" l = label { CatchAll l }
| "_" "&" "->" l = label { CatchAllRef l }

on_clause:
| t = ident "->" l = label { OnLabel (t, l) }
(* [switch] is a contextual identifier here (no longer a keyword). *)
| t = ident "->" s = ident
  { if s.desc = "switch" then OnSwitch t
    else
      raise
        (Wax_wasm.Parsing.syntax_error_pair
           ($loc(s),
            Wax_utils.Message.(
              text "Expected a label or" ++ code "switch"
              ++ text "as the handler target.\n"))) }

on_clauses:
| "[" l = separated_list_trailing(",", on_clause) "]" { l }

legacy_catch:
| t = ident "=>" l = braced_block { (t, l) }

(* A structured [try]'s catch arm: [tag => { … }], [tag & => { … }] (catch_ref:
   the [&exn] is delivered above the payload); the catch-all ([_ => { … }],
   [_ & => { … }]) is grammar-enforced last, matching try_table's
   first-match-wins clause order. *)
trycatch_arm:
| t = ident "=>" l = braced_block
  { {arm_tag = Some t; arm_ref = false; arm_types = [||]; arm_body = l} }
| t = ident "&" "=>" l = braced_block
  { {arm_tag = Some t; arm_ref = true; arm_types = [||]; arm_body = l} }

trycatch_all:
| "_" "=>" l = braced_block
  { {arm_tag = None; arm_ref = false; arm_types = [||]; arm_body = l} }
| "_" "&" "=>" l = braced_block
  { {arm_tag = None; arm_ref = true; arm_types = [||]; arm_body = l} }

legacy_catch_all:
| "_" "=>" l = braced_block { l }

%inline block:
| label = block_label "{" l = statement_list "}" { (label, l) }

structure_field:
| y = field_name ":" i = expression { (y, Some i) }
(* Field shorthand (punning): [{x}] abbreviates [{x: x}], taking the field's
   value from the like-named local/global. Carried as [None] (see [Ast.Struct]). *)
| y = field_name { (y, None) }

structure:
| l = separated_list_trailing(",", structure_field) { l }

(* A [dispatch] case: a labelled, brace-delimited statement list. The label
   names the case (matched to one of the bracket labels); the body runs when the
   index selects it (and falls through into the following cases). *)
dispatch_arm:
| l = label ":" body = braced_block { (l, body) }

(* A [match] arm: a reference-type test (optionally binding the narrowed value)
   or a [null] test, then a brace-delimited body that must leave the [match]
   (the body diverges); see {!Ast_utils.lower_match}. *)
match_pattern:
| x = ident ":" t = reference_type { MatchCast (Some x, t) }
| t = reference_type { MatchCast (None, t) }
| NULL { MatchNull }

match_arm:
| p = match_pattern "=>" body = braced_block { (p, body) }

(* The default arm is required (like a [dispatch]'s [else]): no-match always has
   a written destination. *)
match_default:
| "_" "=>" body = braced_block { body }

(* A [list(X)] that also swallows bare [;] empty elements — the list analogue of
   [statement_list]'s empty statement (see there). Used for the lists where an
   [X] carries no separator of its own: module fields, import items, and the arm
   lists of [dispatch]/[match]/[try]. So a stray or reflexive [;] between (or
   after) entries is harmless, just as between statements. Each [X] begins with a
   distinctive token, none of them [;], so the empty case never clashes. *)
semi_list(X):
| { [] }
| ";" l = semi_list(X) { l }
| x = X l = semi_list(X) { x :: l }

blockinstr:
(* Branch-hinting proposal: a hinted [if] stays a [blockinstr] (so, like a plain
   [if], it needs no trailing [;]); [hinted] rejects the attribute on any other
   block form. *)
| h = branch_hint_attr i = blockinstr { hinted $sloc h i }
| DISPATCH index = expression
  "[" le = labels_else "]"
  "{" arms = semi_list(dispatch_arm) "}"
  { let cases, default = le in
    with_loc $sloc (Dispatch {index; cases; default; arms}) }
| MATCH scrutinee = expression
  "{" arms = semi_list(match_arm) default = match_default "}"
  { with_loc $sloc (Match {scrutinee; arms; default}) }
| label = block_label DO bt = option(block_type) l = braced_block
  { with_loc $sloc (Block{label; typ = blocktype bt; block = l}) }
| label = block_label WHILE cond = condition_expression
  l = braced_block
  { with_loc $sloc (While{label; cond; step = None; block = l}) }
(* Zig-style continue-expression: [while c : (step) { … }]. The step is a
   parenthesized statement run at the end of every iteration (incl. [continue]).
   Parentheses are required (a bare statement would collide with the body brace
   for branch statements). *)
| label = block_label WHILE cond = condition_expression
  ":" "(" step = statement ")"
  l = braced_block
  { with_loc $sloc (While{label; cond; step = Some step; block = l}) }
| label = block_label LOOP bt = option(block_type)
  l = braced_block
  { with_loc $sloc (Loop{label; typ = blocktype bt; block = l}) }
| label = block_label IF e = condition_expression
  bt = option("=>" bt = block_type { bt })
  l1 = braced_block
  l2 = ioption(ELSE l = braced_block { l })
  { with_loc $sloc (If{label; typ = blocktype bt; cond = e; if_block = l1; else_block = l2}) }
| label = block_label TRY bt = option(block_type) l = braced_block
  CATCH "[" catches = separated_list_trailing(",", catch) "]"
  { with_loc $sloc (TryTable {label; typ = blocktype bt; catches; block = l}) }
| label = block_label TRY bt = option(block_type) l = braced_block
  CATCH
  "{" arms = semi_list(trycatch_arm); catch_all = option(trycatch_all) "}"
  { with_loc $sloc
      (TryCatch {label; typ = blocktype bt; block = l;
                 arms = arms @ Option.to_list catch_all}) }
| label = block_label TRY_LEGACY bt = option(block_type) l = braced_block
  CATCH
  "{" catches = semi_list(legacy_catch); catch_all = option(legacy_catch_all) "}"
  { with_loc $sloc
      (Try {label; typ = blocktype bt; block = l; catches; catch_all}) }

(* A brace-delimited statement list carrying a location spanning the whole
   [{ … }], both braces included. An own-line comment trailing the last statement
   falls *within* the block's span and renders inside it; a comment past the [}]
   is the block's [after], which the printer emits on the far side of the closing
   brace (see [located_block_contents]/[close_block] in [output.ml]). *)
braced_block:
| "{" l = statement_list "}"
  { with_loc $sloc l }

parenthesized_expression: e = expression { e }
(* The [descriptor(d)] clause shared by the custom-descriptors instructions
   ([struct.new_desc], [ref.cast_desc_eq], [br_on_cast_desc_eq]): the target type
   is recovered from [d]'s (descriptor) type, so only the operand is written. *)
descriptor_operand: DESCRIPTOR "(" d = expression ")" { d }
index_expression: e = expression { e }
then_branch: e = expression { e }
condition_expression: e = expression { e }
length_expression: e = expression { e }

expression_list:
| l = separated_list_trailing(",", expression) { l }

(* A call argument: either an expression or a labelled immediate [name: expr]
   (the [offset]/[align]/[lane] immediates of a memory access; typing rejects
   labels anywhere else). *)
argument:
| e = expression { e }
| l = ident ":" e = expression { with_loc $sloc (Labelled (l, e)) }
(* [tag] is a keyword (tag declarations), so the [tag: t] immediate of a
   [switch] needs its own arm. *)
| t = TAG ":" e = expression
  { ignore t; with_loc $sloc (Labelled (with_loc $loc(t) "tag", e)) }

argument_list:
| l = separated_list_trailing(",", argument) { l }

plaininstr:
| NULL { with_loc $sloc Null }
| "_" {with_loc $sloc Hole }
| x = ident { with_loc $sloc (Get x) } %prec prec_ident
| x = ident "::" y = ident { with_loc $sloc (Path (x, y)) }
| "(" l = parenthesized_expression ")" { l }
| "(" i = expression "," l = expression_list ")"
  { with_loc $sloc (Sequence (i :: l)) }
| i = expression "(" l = argument_list ")"
   { with_loc $sloc (Call(i, l)) }
| c = CHAR
  { with_loc $loc (Char c) }
| s = STRING
  { with_loc (s.info.loc_start, s.info.loc_end) (String (None, s.desc)) }
| t = ident "#" s = STRING
  { with_loc ($symbolstartpos, s.info.loc_end) (String (Some t, s.desc)) }
| i = INT { with_loc $sloc (Int i) }
| f = FLOAT { with_loc $sloc (Float f) }
| INF { with_loc $sloc (Float "inf") }
| NAN { with_loc $sloc (Float "nan") }
| "{" x = ident "|" l = structure "}"
  { with_loc $sloc (Struct (Some x, l)) }
| "{" f = structure_field "," l = structure "}"
  { with_loc $sloc (Struct (None, f :: l)) }
| "{" f = structure_field "}"
  { with_loc $sloc (Struct (None, [f])) }
| "{" "}"
  { with_loc $sloc (Struct (None, [])) }
| "{" x = ident "|" ".." "}"
  { with_loc $sloc (StructDefault (Some x)) }
| "{" ".." "}"
  { with_loc $sloc (StructDefault (None)) }
| "{" d = descriptor_operand "|" l = structure "}"
  { with_loc $sloc (StructDesc (d, l)) }
| "{" d = descriptor_operand "|" ".." "}"
  { with_loc $sloc (StructDefaultDesc d) }
| "[" b = array_body "]" { with_loc $sloc (b None) }
| "[" t = ident "|" b = array_body "]" { with_loc $sloc (b (Some t)) }
| x = ident ":=" i = expression { with_loc $sloc (Tee (x, i)) }
| i = expression AS t = cast_type { with_loc $sloc (Cast(i, t)) }
| i = expression AS nullable = boption("?") d = descriptor_operand
  { with_loc $sloc (CastDesc(i, nullable, d)) }
| i = expression IS t = reference_type { with_loc $sloc (Test(i, t)) }
| i = expression "." x = ident { with_loc $sloc (StructGet(i, x)) }
| i = expression "." DESCRIPTOR { with_loc $sloc (GetDescriptor i) }
| i = expression "." x = ident "=" j = expression { with_loc $sloc (StructSet(i, x, j)) }
| i = expression o = "+" j = expression { binop $sloc o $loc(o) Add i j }
| i = expression o = "-" j = expression { binop $sloc o $loc(o) Sub i j }
| i = expression o = "*" j = expression { binop $sloc o $loc(o) Mul i j }
| i = expression o = "/" j = expression { binop $sloc o $loc(o) (Div None) i j }
| i = expression o = "/s" j = expression { binop $sloc o $loc(o) (Div (Some Signed)) i j }
| i = expression o = "/u" j = expression { binop $sloc o $loc(o) (Div (Some Unsigned)) i j }
| i = expression o = "%s" j = expression { binop $sloc o $loc(o) (Rem Signed) i j }
| i = expression o = "%u" j = expression { binop $sloc o $loc(o) (Rem Unsigned) i j }
| i = expression o = "&" j = expression { binop $sloc o $loc(o) And i j }
| i = expression o = "^" j = expression { binop $sloc o $loc(o) Xor i j }
| i = expression o = "|" j = expression { binop $sloc o $loc(o) Or i j }
| i = expression o = "<<" j = expression { binop $sloc o $loc(o) Shl i j }
| i = expression o = ">>s" j = expression { binop $sloc o $loc(o) (Shr Signed) i j }
| i = expression o = ">>u" j = expression { binop $sloc o $loc(o) (Shr Unsigned) i j }
| i = expression o = "==" j = expression { binop $sloc o $loc(o) Eq i j }
| i = expression o = "!=" j = expression { binop $sloc o $loc(o) Ne i j }
| i = expression o = ">" j = expression { binop $sloc o $loc(o) (Gt None) i j }
| i = expression o = ">s" j = expression { binop $sloc o $loc(o) (Gt (Some Signed)) i j }
| i = expression o = ">u" j = expression { binop $sloc o $loc(o) (Gt (Some Unsigned)) i j }
| i = expression o = "<" j = expression { binop $sloc o $loc(o) (Lt None) i j }
| i = expression o = "<s" j = expression { binop $sloc o $loc(o) (Lt (Some Signed)) i j }
| i = expression o = "<u" j = expression { binop $sloc o $loc(o) (Lt (Some Unsigned)) i j }
| i = expression o = ">=" j = expression { binop $sloc o $loc(o) (Ge None) i j }
| i = expression o = ">=s" j = expression { binop $sloc o $loc(o) (Ge (Some Signed)) i j }
| i = expression o = ">=u" j = expression { binop $sloc o $loc(o) (Ge (Some Unsigned)) i j }
| i = expression o = "<=" j = expression { binop $sloc o $loc(o) (Le None) i j }
| i = expression o = "<=s" j = expression { binop $sloc o $loc(o) (Le (Some Signed)) i j }
| i = expression o = "<=u" j = expression { binop $sloc o $loc(o) (Le (Some Unsigned)) i j }
| b = branch_expr { b }
(* Branch-hinting proposal: [#[likely]] / [#[unlikely]] wraps the [br_if]/[br_on_*]
   that follows; a hinted [if] is a [blockinstr] (above). *)
| h = branch_hint_attr b = branch_expr
  { with_loc $sloc (Hinted (h, b)) }
| SUSPEND t = tag_name "(" l = expression_list ")"
  { with_loc $sloc (Suspend (t, l)) }
(* The postfix handler clause of a [resume]-family method call, binding tightly
   like [as]/[is]: [c.resume(x) on [t -> 'l, t2 -> switch]]. Grammatically it
   attaches to any expression; the typer accepts it only on the resume forms. *)
| i = expression ON h = on_clauses
  { with_loc $sloc (On (i, h)) }
| i1 = expression "[" i2 = index_expression "]"
  { with_loc $sloc (ArrayGet (i1, i2)) }
| i1 = expression "?" i2 = then_branch ":" i3 = expression
  { with_loc $sloc (Select (i1, i2, i3)) }
| o = "!" i = expression { unop $sloc o $loc(o) Not i } %prec prec_unary
| o = "+" i = expression { unop $sloc o $loc(o) Pos i } %prec prec_unary
| o = "-" i = expression { unop $sloc o $loc(o) Neg i } %prec prec_unary
| i = expression "!" { with_loc $sloc (NonNull i) }
| i1 = expression "[" i2 = index_expression "]" "=" i3 = expression
  { with_loc $sloc (ArraySet (i1, i2, i3)) }

array_body:
| l = expression_list { fun t -> ArrayFixed (t, l) }
| i1 = expression ";" i2 = length_expression { fun t -> Array (t, i1, i2) }
| ".." ";" i = length_expression { fun t -> ArrayDefault (t, i) }
| d = ident "@" off = expression ";" len = length_expression
  { fun t -> ArraySegment (t, d, off, len) }

expression:
| i = blockinstr %prec prec_block { i }
| i = plaininstr { i }

let_pattern:
| p = simple_pattern t = ioption(":" t = value_type {t}) { (p, t) }

let_pattern_:
| p = separated_list_trailing(",", let_pattern) { p }

(* The operator of a compound assignment [x op= e]. Mirrors the value-producing
   arithmetic and bitwise binary operators; comparisons are excluded. *)
compound_assign_op:
| "+=" { with_loc $sloc Add }
| "-=" { with_loc $sloc Sub }
| "*=" { with_loc $sloc Mul }
| "/=" { with_loc $sloc (Div None) }
| "/s=" { with_loc $sloc (Div (Some Signed)) }
| "/u=" { with_loc $sloc (Div (Some Unsigned)) }
| "%s=" { with_loc $sloc (Rem Signed) }
| "%u=" { with_loc $sloc (Rem Unsigned) }
| "&=" { with_loc $sloc And }
| "|=" { with_loc $sloc Or }
| "^=" { with_loc $sloc Xor }
| "<<=" { with_loc $sloc Shl }
| ">>s=" { with_loc $sloc (Shr Signed) }
| ">>u=" { with_loc $sloc (Shr Unsigned) }

statement:
| i = plaininstr { i }
| NOP { with_loc $sloc Nop }
| UNREACHABLE { with_loc $sloc Unreachable }
| x = ident "=" i = expression { with_loc $sloc (Set (x, None, i)) }
(* A discarded value: [_ = e] drops [e]. An optional type annotation ([_: t = e])
   pins a width that the surface syntax of the value would otherwise not carry,
   so the value round-trips at its original width; it lowers to the value
   followed by [drop]. Represented as an anonymous [Let] (nothing is bound), not
   a [Set]. *)
| "_" "=" i = expression { with_loc $sloc (Let ([(None, None)], Some i)) }
| "_" ":" t = value_type "=" i = expression
  { with_loc $sloc (Let ([(None, Some t)], Some i)) }
| x = ident o = compound_assign_op i = expression
  { with_loc $sloc (Set (x, Some o, i)) }
| LET x = simple_pattern
  { with_loc $sloc (Let ([(x, None)], None)) }
| LET x = simple_pattern "=" i = expression
  { with_loc $sloc (Let ([(x, None)], Some i)) }
| LET x = simple_pattern ":" t = value_type "=" i = expression
  { with_loc $sloc (Let ([(x, Some t)], Some i)) }
| LET x = simple_pattern ":" t = value_type
  { with_loc $sloc (Let ([(x, Some t)], None)) }
| LET
  "(" l = let_pattern_ ")" i = ioption("=" i = expression {i})
  { with_loc $sloc (Let (l, i)) }
| BR l = label i = ioption(expression)
  { with_loc $sloc (Br (l, i)) }
| BR_TABLE "[" le = labels_else "]" i = expression
  { let lst, l = le in with_loc $sloc (Br_table (lst @ [l], i)) }
| RETURN i = ioption(expression) { with_loc $sloc (Return i) }
| THROW t = tag_name "(" l = expression_list ")"
  { with_loc $sloc (Throw (t, l)) }
| THROW_REF i = expression
  { with_loc $sloc (ThrowRef i) }
| BECOME i = expression "(" l = argument_list ")"
   { with_loc $sloc (TailCall(i, l)) }

(* [process_stmts] pairs adjacent [#[if]]/[#[else]] groups (see the header). *)
statement_list:
| l = raw_statement_list { process_stmts l }

raw_statement_list:
| { [] }
(*
| i = statement { [i] }
*)
(* A bare [;] is an empty statement: it contributes nothing to the list. This
   makes a redundant [;] harmless anywhere — most usefully after a block-shaped
   statement ([do]/[if]/[while]/[loop]/[dispatch]/[match]/[try]), which needs
   none (its [}] ends it) but where the [;]-per-statement habit is strong (the
   docs' own author wrote the [;] form more than once). A block followed by [;]
   parses as the block then this empty statement; it is conflict-free because a
   block reaches statement position only through [statement_list] (there is no
   [plaininstr: expression], so it cannot arrive via the expression/plaininstr
   path), so a following [;] never clashes with reducing [expression: blockinstr]
   (which continues a plaininstr on an operator, never on [;]). *)
| ";" l = raw_statement_list { l }
| i = blockinstr l = raw_statement_list { RS_plain i :: l }
| i = statement ";" l = raw_statement_list { RS_plain i :: l }
| i = cond_stmt l = raw_statement_list { i :: l }

(* Instruction-level conditional annotation. Braces are required, so the body
   is a transparent statement list (not a block). Each [#[if]]/[#[else]] group is
   a marker; [process_stmts] pairs adjacent ones into an [If_annotation]. *)
cond_stmt:
| "#" "[" IF "(" c = condition ")" "]" t = braced_block { RS_if ($sloc, c, t) }
| "#" "[" ELSE "]" b = braced_block { RS_else ($sloc, b) }

globalmut:
| LET { true }
| CONST { false }

constant_expression: e = expression { e }

global:
| mut = globalmut name = ident
  typ = ioption(":" typ = value_type { typ })
  "=" def = constant_expression ";"
  { fun attributes -> with_loc $sloc (Global {name; mut; typ; def; attributes}) }

tag_def:
| s = tag_sig ";"
  { fun attributes ->
    let (name, typ, sign) = s in
    with_loc $sloc (Tag {name; typ; sign; attributes}) }

definition:
| f = func { f }
| g = global { g }
| m = memory { m }
| d = data { d }
| t = table { t }
| e = elem { e }
| t = tag_def { t }

address_type:
| t = IDENT
  { match t with
    | "i32" -> `I32
    | "i64" -> `I64
    | _ ->
        raise (Wax_wasm.Parsing.syntax_error_pair
                 ($sloc,
           Wax_utils.Message.text ("Expected a memory address type 'i32' or 'i64'.\n") )) }

mem_limits:
| "[" mi = INT ma = ioption("," m = INT { u64_of_int_literal $loc(m) m }) "]"
  { (u64_of_int_literal $loc(mi) mi, ma) }

data_name:
| "_" { None }
| x = ident { Some x }

(* A data segment's contents: one or more elements (a string literal, a numeric
   run [[f32: 1.5, nan]], or a [v128] constant), concatenated with [++]. See
   {!Ast.Data}. *)
data_init:
| l = separated_nonempty_list("++", data_elem) { l }

data_elem:
| s = STRING { Data_string s.desc }
| "[" t = ident ":" l = separated_list_trailing(",", data_run_item) "]"
  { data_run $loc(t) t l }

(* One element of a data run: a scalar literal, or a [v128] lane group
   [shape(lane, …)]. [data_run] checks it matches the run's element type. *)
data_run_item:
| n = data_number { `Num n }
| sh = ident "(" l = separated_list_trailing(",", data_number) ")"
  { `Vec
      (with_loc $sloc
         { V128.shape = vec_shape $loc(sh) sh;
           components = List.map (fun (n : _ Ast.annotated) -> n.desc) l }) }

(* A bare numeric literal in a data run: an [int]/[float]/[inf]/[nan] literal
   with an optional sign, kept as its raw text (values are range-checked and
   encoded at typing/lowering, like the WAT numlist form). *)
data_number:
| s = ioption(data_sign) n = raw_number
  { with_loc $sloc (Option.value ~default:"" s ^ n) }

data_sign:
| "-" { "-" }
| "+" { "" }

raw_number:
| n = INT { n }
| f = FLOAT { f }
| INF { "inf" }
| NAN { "nan" }

data_item:
| DATA n = data_name "@" "[" off = constant_expression "]"
  init = loption("=" i = data_init { i }) ";"
  { { data_name = n; offset = off; init } }

mem_pagesize:
| PAGESIZE n = INT { page_size_log2 $loc(n) n }

memory:
| MEMORY name = ident ":" at = address_type lim = ioption(mem_limits)
  ps = ioption(mem_pagesize) sh = boption(SHARED) ";"
  { fun attributes ->
      with_loc $sloc
        (Memory {name; address_type = at; limits = lim; page_size_log2 = ps;
                 shared = sh; data = []; attributes}) }
| MEMORY name = ident ":" at = address_type lim = ioption(mem_limits)
  ps = ioption(mem_pagesize) sh = boption(SHARED) "{" items = list(data_item) "}"
  { fun attributes ->
      with_loc $sloc
        (Memory
           {name; address_type = at; limits = lim; page_size_log2 = ps;
            shared = sh; data = items; attributes}) }

data:
| DATA n = data_name init = loption("=" i = data_init { i }) ";"
  { fun attributes ->
      with_loc $sloc (Data {name = n; mode = Passive; init; attributes}) }
| DATA n = data_name "@" mem = ident "[" off = constant_expression "]"
  init = loption("=" i = data_init { i }) ";"
  { fun attributes ->
      with_loc $sloc
        (Data {name = n; mode = Active (mem, off); init; attributes}) }

table:
| TABLE name = ident ":" at = ioption(address_type) rt = reference_type
  lim = ioption(mem_limits) init = ioption("=" e = expression { e }) ";"
  { fun attributes ->
      with_loc $sloc
        (Table {name; address_type = Option.value ~default:`I32 at;
                reftype = rt; limits = lim; init; attributes}) }

elem:
| ELEM name = ident ":" rt = reference_type "=" "[" l = expression_list "]" ";"
  { fun attributes ->
      with_loc $sloc
        (Elem {name; reftype = rt; mode = EPassive; init = l; attributes}) }
| ELEM name = ident ":" rt = reference_type
  "@" tab = ident "[" off = constant_expression "]"
  "=" "[" l = expression_list "]" ";"
  { fun attributes ->
      with_loc $sloc
        (Elem {name; reftype = rt; mode = EActive (tab, off); init = l;
               attributes}) }

(* A module field returns a [raw_field]. [#[if(c)] { … }]/[#[else] { … }] carry a
   located field list (braces mandatory) and become markers that [lower_fields]
   pairs into [Conditional]s (see the header); every other production is a plain
   field. There is no standalone brace group: [{ … }] only appears as a
   conditional branch body. *)
module_field:
| r = rectype { RF_plain {desc = Type r.desc; info = r.info} }
| a = inner_attribute { RF_plain (with_loc $sloc (Module_annotation [a])) }
| attributes = list(attribute) d = definition
  { RF_plain (attributed $sloc attributes d) }
| IMPORT m = STRING d = import_item
  { RF_plain (with_loc $sloc (Import {module_ = m; decl = d})) }
| IMPORT m = STRING "{" decls = semi_list(import_item) "}"
  { RF_plain (with_loc $sloc (Import_group {module_ = m; decls})) }
| "#" "[" IF "(" c = condition ")" "]" b = braced_fields { RF_if ($sloc, c, b) }
| "#" "[" ELSE "]" b = braced_fields { RF_else ($sloc, b) }

(* A brace-delimited, lowered field list carrying a location spanning the whole
   [{ … }] (like [braced_block]); a comment past the [}] is the branch's [after],
   emitted on the far side of the closing brace. *)
braced_fields:
| "{" fields = semi_list(module_field) "}"
  { with_loc $sloc (lower_fields fields) }

(* One entry of an import block: an [fn]/[const]/[let]/[tag]/[memory]/[table]
   declaration, optionally carrying a name-only [#[import = "name"]] (imported
   under that name rather than the Wax name) or other attributes like
   [#[export]]. *)
import_item:
| attributes = list(attribute) k = import_kind_decl ";"
  { make_import_decl $sloc attributes k }

import_kind_decl:
| f = fundecl
  { let (name, typ, sign, exact) = f in
    (name, Import_func {typ; sign; exact}) }
| mut = globalmut name = ident ":" typ = value_type
  { (name, Import_global {mut; typ}) }
| s = tag_sig
  { let (name, typ, sign) = s in (name, Import_tag {typ; sign}) }
| MEMORY name = ident ":" at = address_type lim = ioption(mem_limits)
  ps = ioption(mem_pagesize) sh = boption(SHARED)
  { (name,
     Import_memory {address_type = at; limits = lim; page_size_log2 = ps;
                    shared = sh}) }
| TABLE name = ident ":" at = ioption(address_type) rt = reference_type
  lim = ioption(mem_limits)
  { (name,
     Import_table {address_type = Option.value ~default:`I32 at; reftype = rt;
                   limits = lim}) }

(* Conditions of conditional annotations. Reuse the WAT-level [Wax_wasm.Ast.cond]
   (we do not evaluate them; they are preserved for the preprocessor). *)
condition:
| name = ident { Wax_wasm.Ast.Cond_var name }
| name = ident op = condition_relop rhs = condition_literal
  { Wax_wasm.Ast.Cond_cmp (op, Wax_wasm.Ast.Cond_var name, rhs) }
| name = ident "(" l = separated_list_trailing(",", condition) ")"
  { match name.desc, l with
    | "all", _ -> Wax_wasm.Ast.Cond_and l
    | "any", _ -> Wax_wasm.Ast.Cond_or l
    | "not", [c] -> Wax_wasm.Ast.Cond_not c
    | _ ->
      raise
        (Wax_wasm.Parsing.syntax_error_pair
           ($loc,
           Wax_utils.Message.text ("Expected 'all', 'any', or 'not(<cond>)' in a condition.") )) }

condition_literal:
| "(" a = INT "," b = INT "," c = INT ")"
  { Wax_wasm.Ast.Cond_version
      (int_of_version_component $loc(a) a, int_of_version_component $loc(b) b,
       int_of_version_component $loc(c) c) }
| s = STRING { Wax_wasm.Ast.Cond_string s }

condition_relop:
| "=" { Wax_wasm.Ast.Eq } | "!=" { Wax_wasm.Ast.Ne } | "<" { Wax_wasm.Ast.Lt }
| ">" { Wax_wasm.Ast.Gt } | "<=" { Wax_wasm.Ast.Le } | ">=" { Wax_wasm.Ast.Ge }

(* [lower_fields] pairs top-level [#[if]]/[#[else]] fields into [Conditional]s. *)
parse:
| l = raw_parse { lower_fields l }

raw_parse:
| EOF { [] }
| ";" r = raw_parse { r }
| f = module_field r = raw_parse { f :: r }
