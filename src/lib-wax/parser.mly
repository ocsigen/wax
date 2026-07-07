%token <string> IDENT
%token <string> INT
%token <string> FLOAT
%token <(string, Ast.location) Ast.annotated> STRING
%token <Uchar.t> CHAR

%token EOF
%token INF NAN
%token SEMI ";"
%token SHARP "#"
%token HASH_IF "#[if("
%token HASH_ELSE "#[else]"
%token LIKELY_HINT "#[likely]"
%token UNLIKELY_HINT "#[unlikely]"
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
%token TRY CATCH
%token CONT_NEW CONT_BIND
%token SUSPEND RESUME RESUME_THROW RESUME_THROW_REF SWITCH
%token DISPATCH
%token MATCH
%token MEMORY DATA TABLE ELEM PAGESIZE SHARED
%token DESCRIPTOR DESCRIBES

%on_error_reduce statement plaininstr separated_nonempty_list_trailing(",",structure_type_field) list(module_field) separated_nonempty_list_trailing(",",value_type) block_type separated_nonempty_list_trailing(",",function_parameter) list(label) list(attribute) list(typedef) list(legacy_catch) separated_nonempty_list_trailing(",",catch) separated_nonempty_list_trailing(",",let_pattern) blockinstr statement_list loption(separated_nonempty_list_trailing(",",catch)) separated_nonempty_list_trailing(",",expression) let_pattern structure_field separated_nonempty_list_trailing(",",structure_field) constant_expression attribute_expression parenthesized_expression index_expression then_branch condition_expression length_expression optional_function_type structure_type result_type_ expression_list structure


(* Dangling [#[else]]: an [#[else]] binds to the nearest [#[if]], i.e. shifting
   is preferred over reducing the empty [else_clause]. *)
%nonassoc prec_no_else
%nonassoc "#[else]"

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
%left AS IS
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
     "cont", Cont;
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
      (Wax_wasm.Parsing.Syntax_error
         (loc,
          "A branch hint may only prefix a conditional branch (if, br_if, or \
           br_on_*).\n"))

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

let blocktype bt = Option.value ~default:{params = [||]; results = [||]} bt

(* A function or tag is declared with either a type reference ([: name]) or a
   parenthesized signature; one is required. A bare [tag stop;] or [fn f { ... }]
   is rejected — write [()] for an empty signature. With a type reference, the
   signature comes from it, so [sign] stays [None]. *)
let decl_sign loc t sign =
  match (t, sign) with
  | None, None ->
      raise (Wax_wasm.Parsing.Syntax_error
               (loc, "A parameter list is required; write '()' for none.\n"))
  | _ -> sign

(* Parse an integer literal (decimal, hex, with [_] separators) to a [Uint64].
   Used for memory/table limits; a table64 bound may exceed [Int64.max_int],
   so parse across the full unsigned range. *)
let u64_of_int_literal n = Wax_utils.Uint64.of_string n

(* A custom page size is written [pagesize 65536] but stored as its base-2
   logarithm, so require a power of two (the restriction to 1 or 65536 is a
   type-checking concern). *)
let page_size_log2 loc n =
  (* Compute the base-2 logarithm on the 64-bit value directly, without first
     narrowing to [int]: a literal above [max_int] would overflow
     [Uint64.to_int]. A power of two has a single set bit; its log2 is that
     bit's position, which always fits an [int]. *)
  let v = Wax_utils.Uint64.to_int64 (Wax_utils.Uint64.of_string n) in
  if (not (Int64.equal v 0L)) && Int64.equal (Int64.logand v (Int64.sub v 1L)) 0L
  then
    let rec exp x p =
      if Int64.equal x 1L then p else exp (Int64.shift_right_logical x 1) (p + 1)
    in
    exp v 0
  else
    raise
      (Wax_wasm.Parsing.Syntax_error
         (loc, "The page size must be a power of two.\n"))
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
| CATCH { "catch" }
| CONT_NEW { "cont_new" }
| CONT_BIND { "cont_bind" }
| SUSPEND { "suspend" }
| RESUME { "resume" }
| RESUME_THROW { "resume_throw" }
| RESUME_THROW_REF { "resume_throw_ref" }
| SWITCH { "switch" }
| MEMORY { "memory" }
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

heap_type:
| t = ident { try Hashtbl.find absheaptype_tbl t.desc with Not_found -> Type t }

reference_type:
| "&" nullable = boption("?") exact = boption("!") typ = heap_type
  { let typ =
      if exact then
        match (typ : heaptype) with
        | Type t -> Exact t
        | _ ->
            raise (Wax_wasm.Parsing.Syntax_error
                     ($sloc, "Only a concrete type can be exact.\n"))
      else typ
    in
    { nullable; typ } }

value_type:
| t = IDENT
   { try Hashtbl.find valtype_tbl t with Not_found ->
       raise (Wax_wasm.Parsing.Syntax_error ($sloc, Printf.sprintf "Identifier '%s' is not a value type.\n" t )) }
| t = reference_type { Ref t }

cast_type:
| t = IDENT
   { try Valtype (Hashtbl.find valtype_tbl t) with Not_found ->
       try Hashtbl.find casttype_tbl t with Not_found ->
         raise (Wax_wasm.Parsing.Syntax_error
                  ($sloc, Printf.sprintf "Identifier '%s' is not a cast type.\n" t )) }
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
       raise (Wax_wasm.Parsing.Syntax_error ($sloc, Printf.sprintf "Identifier '%s' is not a storage type.\n" t )) }
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
(* [cont] is not a reserved word (it is used as an ordinary identifier, e.g.
   user type names and labels), so a continuation type is recognised here by
   matching the identifier [cont] followed by the function type name. *)
| name = ident t = type_name
  { if name.desc <> "cont" then
      raise (Wax_wasm.Parsing.Syntax_error ($sloc,
        Printf.sprintf "Expecting a composite type.\n"));
    Cont t }

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

attribute:
| "#" "[" name = IDENT "=" i = attribute_expression "]" { (name, Some i) }
| "#" "[" name = IDENT "]" { (name, None) }

(* Branch-hinting proposal: [#[likely]]/[#[unlikely]] prefixing an [if]/[br_if].
   Lexed as dedicated tokens (like [#[if(]) so the form does not collide with the
   general [#[name]] module-field attribute. *)
%inline branch_hint_attr:
| LIKELY_HINT { true }
| UNLIKELY_HINT { false }

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
| "#" "!" "[" name = IDENT "=" i = attribute_expression "]" { (name, Some i) }
| "#" "!" "[" name = IDENT "]" { (name, None) }

simple_pattern:
| x = ident { Some x }
| "_" { None }

function_parameter:
| x = simple_pattern ":" t = value_type { with_loc $sloc (x, t) }
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
      raise (Wax_wasm.Parsing.Syntax_error
               ($sloc, "Duplicate exact marker '!'.\n"));
    (name, t, decl_sign $sloc t sign, ex1 || ex2) }

func:
| f = fundecl body = block
  { fun attributes ->
    let (name, typ, sign, exact) = f in
    if exact then
      raise (Wax_wasm.Parsing.Syntax_error
               ($sloc, "A function definition is always exact; the '!' marker \
                        is only allowed on an (imported) function declaration.\n"));
    with_loc $sloc (Func {name; typ; sign; body; attributes}) }

tag_name:
| i = ident { i }

tag:
| TAG name = tag_name
  t = ioption(":" t = type_name { t } )
  sign = optional_function_type ";"
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
| t = ident "->" SWITCH { OnSwitch t }

on_clauses:
| "[" l = separated_list_trailing(",", on_clause) "]" { l }

legacy_catch:
| t = ident "=>" "{" l = statement_list "}" { (t, l) }

legacy_catch_all:
| "_" "=>"  "{" l = statement_list "}" { l }

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
| l = label ":" "{" body = statement_list "}" { (l, body) }

(* A [match] arm: a reference-type test (optionally binding the narrowed value)
   or a [null] test, then a brace-delimited body that must leave the [match]
   (the body diverges); see {!Ast_utils.lower_match}. *)
match_pattern:
| x = ident ":" t = reference_type { MatchCast (Some x, t) }
| t = reference_type { MatchCast (None, t) }
| NULL { MatchNull }

match_arm:
| p = match_pattern "=>" "{" body = statement_list "}" { (p, body) }

(* The default arm is required (like a [dispatch]'s [else]): no-match always has
   a written destination. *)
match_default:
| "_" "=>" "{" body = statement_list "}" { body }

blockinstr:
(* Branch-hinting proposal: a hinted [if] stays a [blockinstr] (so, like a plain
   [if], it needs no trailing [;]); [hinted] rejects the attribute on any other
   block form. *)
| h = branch_hint_attr i = blockinstr { hinted $sloc h i }
| DISPATCH index = expression
  "[" cases = list(label) ELSE default = label "]"
  "{" arms = list(dispatch_arm) "}"
  { with_loc $sloc (Dispatch {index; cases; default; arms}) }
| MATCH scrutinee = expression
  "{" arms = list(match_arm) default = match_default "}"
  { with_loc $sloc (Match {scrutinee; arms; default}) }
| label = block_label DO bt = option(block_type) "{" l = statement_list "}"
  { with_loc $sloc (Block{label; typ = blocktype bt; block = l}) }
| label = block_label WHILE cond = condition_expression
  "{" l = statement_list "}"
  { with_loc $sloc (While{label; cond; step = None; block = l}) }
(* Zig-style continue-expression: [while c : (step) { … }]. The step is a
   parenthesized statement run at the end of every iteration (incl. [continue]).
   Parentheses are required (a bare statement would collide with the body brace
   for branch statements). *)
| label = block_label WHILE cond = condition_expression
  ":" "(" step = statement ")"
  "{" l = statement_list "}"
  { with_loc $sloc (While{label; cond; step = Some step; block = l}) }
| label = block_label LOOP bt = option(block_type)
  "{" l = statement_list "}"
  { with_loc $sloc (Loop{label; typ = blocktype bt; block = l}) }
| label = block_label IF e = condition_expression
  bt = option("=>" bt = block_type { bt })
  l1 = braced_block
  l2 = ioption(ELSE l = braced_block { l })
  { with_loc $sloc (If{label; typ = blocktype bt; cond = e; if_block = l1; else_block = l2}) }
| label = block_label TRY bt = option(block_type) "{" l = statement_list "}"
  CATCH "[" catches = separated_list_trailing(",", catch) "]"
  { with_loc $sloc (TryTable {label; typ = blocktype bt; catches; block = l}) }
| label = block_label TRY bt = option(block_type) "{" l = statement_list "}"
  CATCH
  "{" catches = list(legacy_catch); catch_all = option(legacy_catch_all) "}"
  { with_loc $sloc
      (Try {label; typ = blocktype bt; block = l; catches; catch_all}) }

(* A brace-delimited statement list carrying a location, so a comment opening
   the block attaches to it rather than leaking onto the preceding condition
   (see the (then ...)/(else ...) clauses of a folded Wasm if). The location
   starts at the opening brace but stops at the statement list, excluding the
   closing brace: the enclosing [if] reaches the [}], so it stays strictly
   larger than the block and a comment trailing the [}] attaches to the [if]
   rather than to the block (as a folded Wasm if owns the comment after its
   outer paren). *)
braced_block:
| "{" l = statement_list "}" { with_loc ($startpos, $endpos(l)) l }

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

plaininstr:
| NULL { with_loc $sloc Null }
| "_" {with_loc $sloc Hole }
| x = ident { with_loc $sloc (Get x) } %prec prec_ident
| x = ident "::" y = ident { with_loc $sloc (Path (x, y)) }
| "(" l = parenthesized_expression ")" { l }
| "(" i = expression "," l = expression_list ")"
  { with_loc $sloc (Sequence (i :: l)) }
| i = expression "(" l = expression_list ")"
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
| CONT_NEW t = type_name "(" i = expression ")"
  { with_loc $sloc (ContNew (t, i)) }
| CONT_BIND src = type_name dst = type_name "(" l = expression_list ")"
  { with_loc $sloc (ContBind (src, dst, l)) }
| SUSPEND t = tag_name "(" l = expression_list ")"
  { with_loc $sloc (Suspend (t, l)) }
| RESUME t = type_name h = on_clauses "(" l = expression_list ")"
  { with_loc $sloc (Resume (t, h, l)) }
| RESUME_THROW t = type_name tag = tag_name h = on_clauses "(" l = expression_list ")"
  { with_loc $sloc (ResumeThrow (t, tag, h, l)) }
| RESUME_THROW_REF t = type_name h = on_clauses "(" l = expression_list ")"
  { with_loc $sloc (ResumeThrowRef (t, h, l)) }
| SWITCH t = type_name tag = tag_name "(" l = expression_list ")"
  { with_loc $sloc (Switch (t, tag, l)) }
| i1 = expression "[" i2 = index_expression "]"
  { with_loc $sloc (ArrayGet (i1, i2)) }
| i1 = expression "?" i2 = then_branch ":" i3 = expression
  { with_loc $sloc (Select (i1, i2, i3)) }
| o = "!" i = expression { unop $sloc o $loc(o) Not i } %prec prec_unary
| o = "+" i = expression { unop $sloc o $loc(o) Pos i } %prec prec_unary
| o = "-" i = expression { unop $sloc o $loc(o) Neg i } %prec prec_unary
| i = expression "!" { with_loc $sloc (NonNull i) }

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
| BR_TABLE "[" lst = list(label) ELSE l = label  "]" i = expression
  { with_loc $sloc (Br_table (lst @ [l], i)) }
| RETURN i = ioption(expression) { with_loc $sloc (Return i) }
| THROW t = tag_name  i = ioption(expression)
  { with_loc $sloc (Throw (t, i)) }
| THROW_REF i = expression
  { with_loc $sloc (ThrowRef i) }
| BECOME i = expression "(" l = expression_list ")"
   { with_loc $sloc (TailCall(i, l)) }
| i1 = expression "[" i2 = index_expression "]" "=" i3 = expression
  { with_loc $sloc (ArraySet (i1, i2, i3)) }

statement_list:
| { [] }
(*
| i = statement { [i] }
*)
(* A block-shaped statement ([do]/[if]/[while]/[loop]/[dispatch]/[match]/[try])
   needs no trailing [;], but one is accepted and ignored: the [;]-per-statement
   habit is strong, and the docs' own author wrote the [;] form more than once.
   The redundant [;] is safe here — a bare block reaches statement position only
   through this rule (there is no [plaininstr: expression], so a block cannot
   become a statement via the expression/plaininstr path), so shifting the [;]
   does not clash with reducing [expression: blockinstr] (which continues a
   plaininstr on an operator, never on [;]). *)
| i = blockinstr ioption(";") l = statement_list { i :: l }
| i = statement ";" l = statement_list { i :: l }
| i = cond_stmt l = statement_list { i :: l }

(* Instruction-level conditional annotation. Braces are required, so the body
   is a transparent statement list (not a block). *)
cond_stmt:
| "#[if(" c = condition ")" "]" "{" t = statement_list "}" e = cond_else
  { with_loc $sloc (If_annotation {cond = c; then_body = t; else_body = e}) }

cond_else:
| { None }
| "#[else]" "{" b = statement_list "}" { Some b }

globalmut:
| LET { true }
| CONST { false }

constant_expression: e = expression { e }

global:
| mut = globalmut name = ident
  typ = ioption(":" typ = value_type { typ })
  "=" def = constant_expression ";"
  { fun attributes -> with_loc $sloc (Global {name; mut; typ; def; attributes}) }

globaldecl:
| mut = globalmut name = ident ":" typ = value_type ";"
  { fun attributes ->
    with_loc $sloc (GlobalDecl {name; mut; typ; attributes}) }

declaration:
| f = fundecl ";"
  { fun attributes ->
    let (name, typ, sign, exact) = f in
    with_loc $sloc (Fundecl {name; typ; sign; exact; attributes}) }
| g = globaldecl { g }
| f = tag
  { fun attributes ->
    let (name, typ, sign) = f in
    with_loc $sloc (Tag {name; typ; sign; attributes}) }

definition:
| f = func { f }
| g = global { g }
| m = memory { m }
| d = data { d }
| t = table { t }
| e = elem { e }

address_type:
| t = IDENT
  { match t with
    | "i32" -> `I32
    | "i64" -> `I64
    | _ ->
        raise (Wax_wasm.Parsing.Syntax_error
                 ($sloc, "Expected a memory address type 'i32' or 'i64'.\n")) }

mem_limits:
| "[" mi = INT ma = ioption("," m = INT { u64_of_int_literal m }) "]"
  { (u64_of_int_literal mi, ma) }

data_name:
| "_" { None }
| x = ident { Some x }

data_item:
| DATA n = data_name "@" "[" off = constant_expression "]" "=" s = STRING ";"
  { { data_name = n; offset = off; init = s.desc } }

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
| DATA n = data_name "=" s = STRING ";"
  { fun attributes ->
      with_loc $sloc (Data {name = n; mode = Passive; init = s.desc; attributes}) }
| DATA n = data_name "@" mem = ident "[" off = constant_expression "]"
  "=" s = STRING ";"
  { fun attributes ->
      with_loc $sloc
        (Data {name = n; mode = Active (mem, off); init = s.desc; attributes}) }

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

module_field:
| r = rectype { {desc = Type r.desc; info = r.info} }
| a = inner_attribute { with_loc $sloc (Module_annotation [a]) }
| attributes = list(attribute) d = declaration { attributed $sloc attributes d }
| attributes = list(attribute) d = definition { attributed $sloc attributes d }
| attributes = list(attribute) "{" fields = list(module_field) "}"
  { with_loc $sloc (Group {attributes; fields}) }
| "#[if(" c = condition ")" "]" t = module_field e = else_clause
  { with_loc $sloc (Conditional {cond = c; then_fields = [t]; else_fields = e}) }

else_clause:
| %prec prec_no_else { None }
| "#[else]" e = module_field { Some [e] }

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
        (Wax_wasm.Parsing.Syntax_error
           ($loc, "Expected 'all', 'any', or 'not(<cond>)' in a condition.")) }

condition_literal:
| "(" a = INT "," b = INT "," c = INT ")"
  { Wax_wasm.Ast.Cond_version (int_of_string a, int_of_string b, int_of_string c) }
| s = STRING { Wax_wasm.Ast.Cond_string s }

condition_relop:
| "=" { Wax_wasm.Ast.Eq } | "!=" { Wax_wasm.Ast.Ne } | "<" { Wax_wasm.Ast.Lt }
| ">" { Wax_wasm.Ast.Gt } | "<=" { Wax_wasm.Ast.Le } | ">=" { Wax_wasm.Ast.Ge }

parse: 
| EOF { [] }
| f = module_field r = parse { f :: r }
