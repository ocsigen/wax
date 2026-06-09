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
%token QUESTIONMARK "?"
%token LPAREN "("
%token RPAREN ")"
%token LBRACE "{"
%token RBRACE "}"
%token LBRACKET "["
%token RBRACKET "]"
%token COMMA ","
%token COLON ":"
%token ARROW "->"
%token FATARROW "=>"
%token EQUAL "="
%token COLONEQUAL ":="
%token QUOTE "'"
%token DOT "."
%token DOTDOT ".."
%token BANG "!"
%token PLUS "+"
%token MINUS "-"
%token STAR "*"
%token SLASH "/"
%token SLASHS "/s"
%token SLASHU "/u"
%token PERCENTS "%s"
%token PERCENTU "%u"
%token AMPERSAND "&"
%token PIPE "|"
%token CARET "^"
%token SHL "<<"
%token SHRS ">>s"
%token SHRU ">>u"
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
%token DO LOOP IF ELSE
%token CONST LET AS IS
%token BECOME
%token BR BR_IF BR_TABLE RETURN THROW THROW_REF
%token BR_ON_CAST BR_ON_CAST_FAIL
%token BR_ON_NULL BR_ON_NON_NULL
%token TRY CATCH
%token CONT_NEW CONT_BIND
%token SUSPEND RESUME RESUME_THROW RESUME_THROW_REF SWITCH
%token DISPATCH

%on_error_reduce statement plaininstr separated_nonempty_list(",",structure_type_field) list(module_field) separated_nonempty_list(",",value_type) block_type separated_nonempty_list(",",function_parameter) list(label) list(attribute) list(typedef) list(legacy_catch) separated_nonempty_list(",",catch) separated_nonempty_list(",",let_pattern) blockinstr statement_list loption(separated_nonempty_list(",",catch)) separated_nonempty_list(",",expression) let_pattern structure_field separated_nonempty_list(",",structure_field) constant_expression attribute_expression parenthesized_expression index_expression then_branch condition_expression length_expression optional_function_type structure_type result_type_ expression_list structure


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

%parameter <Context : sig type t val context : Utils.Trivia.context end>

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
   Utils.Trivia.with_pos Context.context {loc_start = fst loc; loc_end = snd loc} desc

let blocktype bt = Option.value ~default:{params = [||]; results = [||]} bt
%}

%start <location module_> parse

 (* To refer to Context in the mli *)
%start <Context.t> dummy_ctx

%%

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
| DISPATCH { "dispatch" }
| INF { "inf" }
| NAN { "nan" }

label_name:
| l = ident_or_keyword { l }

%inline label:
| "'" l = label_name { with_loc $sloc l }

heap_type:
| t = ident { try Hashtbl.find absheaptype_tbl t.desc with Not_found -> Type t }

reference_type:
| "&" nullable = boption("?") typ = heap_type
  { { nullable; typ } }

value_type:
| t = IDENT
   { try Hashtbl.find valtype_tbl t with Not_found ->
       raise (Wasm.Parsing.Syntax_error ($sloc, Printf.sprintf "Identifier '%s' is not a value type.\n" t )) }
| t = reference_type { Ref t }

cast_type:
| t = IDENT
   { try Valtype (Hashtbl.find valtype_tbl t) with Not_found ->
       try Hashtbl.find casttype_tbl t with Not_found ->
         raise (Wasm.Parsing.Syntax_error
                  ($sloc, Printf.sprintf "Identifier '%s' is not a cast type.\n" t )) }
| t = reference_type { Valtype (Ref t) }
(*
| functype { assert false }
*)

result_type_:
| l = separated_nonempty_list(",", value_type) { l }

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
       raise (Wasm.Parsing.Syntax_error ($sloc, Printf.sprintf "Identifier '%s' is not a storage type.\n" t )) }
| t = reference_type { Value (Ref t) }

field_type:
| mut = boption(MUT) typ = storage_type { {mut; typ } }

field_name:
| i = ident { i }

structure_type_field:
| x = field_name ":" t = field_type { (x, t) }

structure_type:
| l = separated_list(",", structure_type_field) { l }

structtype:
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
      raise (Wasm.Parsing.Syntax_error ($sloc,
        Printf.sprintf "Expecting a composite type.\n"));
    Cont t }

type_name:
| i = ident { i }

typedef:
| TYPE name = type_name
  supertype = option(":" s = type_name { s })
  "=" op = boption(OPEN) typ = composite_type ";"
    { (name, {typ; supertype; final = not op}) }

rectype:
| REC "{" l = list(typedef) "}" { with_loc $loc($1) (Array.of_list l) }
| t = typedef { with_loc $sloc [|t|] }

attribute_expression: e = expression { e }

attribute:
| "#" "[" name = IDENT "=" i = attribute_expression "]" { (name, i) }

simple_pattern:
| x = ident { Some x }
| "_" { None }

function_parameter:
| x = simple_pattern ":" t = value_type { x, t }
| t = value_type { None, t }

parameter_list:
| l = separated_list(",", function_parameter)
  { Array.of_list l }

function_type:
| "(" params = parameter_list ")" results = ioption("->" r = result_type {r})
  { {params; results = Option.value ~default:[||] results} }

function_name:
| i = ident { i }

optional_function_type: sign = option (function_type) { sign }

%inline fundecl:
| FN name = function_name
  t = ioption(":" t = type_name { t } )
  sign = optional_function_type
  { (name, t, sign) }

func:
| f = fundecl body = block
  { fun attributes ->
    let (name, typ, sign) = f in
    with_loc $sloc (Func {name; typ; sign; body; attributes}) }

tag_name:
| i = ident { i }

tag:
| TAG name = tag_name
  t = ioption(":" t = type_name { t } )
  sign = optional_function_type ";"
  { (name, t, sign) }

%inline block_label: l = ioption(l = label ":" { l }) { l }

parameter_types:
| l = separated_list(",", value_type) { l }

block_type:
| "(" params = parameter_types ")"
  results = ioption("->" results = result_type {results})
  { {params = Array.of_list (List.map (fun t -> (None, t)) params);
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
| "[" l = separated_list(",", on_clause) "]" { l }

legacy_catch:
| t = ident "=>" "{" l = statement_list "}" { (t, l) }

legacy_catch_all:
| "_" "=>"  "{" l = statement_list "}" { l }

%inline block:
| label = block_label "{" l = statement_list "}" { (label, l) }

structure_field:
| y = field_name ":" i = expression { (y, i) }

structure:
| l = separated_list(",", structure_field) { l }

blockinstr:
| b = block
  { let (label, l) = b in with_loc $sloc (Block{label; typ = blocktype None; block = l}) }
| label = block_label DO bt = option(block_type) "{" l = statement_list "}"
  { with_loc $sloc (Block{label; typ = blocktype bt; block = l}) }
| label = block_label LOOP bt = option(block_type)
  "{" l = statement_list "}"
  { with_loc $sloc (Loop{label; typ = blocktype bt; block = l}) }
| label = block_label IF e = condition_expression
  bt = option("=>" bt = block_type { bt })
  "{" l1 = statement_list "}"
  l2 = ioption(ELSE  "{" l = statement_list "}" { l })
  { with_loc $sloc (If{label; typ = blocktype bt; cond = e; if_block = l1; else_block = l2}) }
| label = block_label TRY bt = option(block_type) "{" l = statement_list "}"
  CATCH "[" catches = separated_list(",", catch) "]"
  { with_loc $sloc (TryTable {label; typ = blocktype bt; catches; block = l}) }
| label = block_label TRY bt = option(block_type) "{" l = statement_list "}"
  CATCH
  "{" catches = list(legacy_catch); catch_all = option(legacy_catch_all) "}"
  { with_loc $sloc
      (Try {label; typ = blocktype bt; block = l; catches; catch_all}) }

parenthesized_expression: e = expression { e }
index_expression: e = expression { e }
then_branch: e = expression { e }
condition_expression: e = expression { e }
length_expression: e = expression { e }

expression_list:
| l = separated_list(",", expression) { l }

plaininstr:
| NULL { with_loc $sloc Null }
| "_" {with_loc $sloc Hole }
| x = ident { with_loc $sloc (Get x) } %prec prec_ident
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
| "{" x = ident "|" ".." "}"
  { with_loc $sloc (StructDefault (Some x)) }
| "{" ".." "}"
  { with_loc $sloc (StructDefault (None)) }
| "[" l = expression_list "]"
  { with_loc $sloc (ArrayFixed (None, l)) }
| "[" i1 = expression ";" i2 = length_expression "]"
  { with_loc $sloc (Array (None, i1, i2)) }
| "[" ".." ";" i = length_expression "]"
  { with_loc $sloc (ArrayDefault (None, i)) }
| "[" t = ident "|" l = expression_list "]"
  { with_loc $sloc (ArrayFixed (Some t, l)) }
| "[" t = ident "|" i1 = expression ";" i2 = length_expression "]"
  { with_loc $sloc (Array (Some t, i1, i2)) }
| "[" t = ident "|" ".." ";" i = length_expression "]"
  { with_loc $sloc (ArrayDefault (Some t, i)) }
| x = ident ":=" i = expression { with_loc $sloc (Tee (x, i)) }
| i = expression AS t = cast_type { with_loc $sloc (Cast(i, t)) }
| i = expression IS t = reference_type { with_loc $sloc (Test(i, t)) }
| i = expression "." x = ident { with_loc $sloc (StructGet(i, x)) }
| i = expression "." x = ident "=" j = expression { with_loc $sloc (StructSet(i, x, j)) }
| i = expression "+" j = expression { with_loc $sloc (BinOp(Add, i, j)) }
| i = expression "-" j = expression { with_loc $sloc (BinOp(Sub, i, j)) }
| i = expression "*" j = expression { with_loc $sloc (BinOp(Mul, i, j)) }
| i = expression "/" j = expression { with_loc $sloc (BinOp(Div None, i, j)) }
| i = expression "/s" j = expression { with_loc $sloc (BinOp(Div (Some Signed), i, j)) }
| i = expression "/u" j = expression { with_loc $sloc (BinOp(Div (Some Unsigned), i, j)) }
| i = expression "%s" j = expression { with_loc $sloc (BinOp(Rem Signed, i, j)) }
| i = expression "%u" j = expression { with_loc $sloc (BinOp(Rem Unsigned, i, j)) }
| i = expression "&" j = expression { with_loc $sloc (BinOp(And, i, j)) }
| i = expression "^" j = expression { with_loc $sloc (BinOp(Xor, i, j)) }
| i = expression "|" j = expression { with_loc $sloc (BinOp(Or, i, j)) }
| i = expression "<<" j = expression { with_loc $sloc (BinOp(Shl, i, j)) }
| i = expression ">>s" j = expression { with_loc $sloc (BinOp(Shr Signed, i, j)) }
| i = expression ">>u" j = expression { with_loc $sloc (BinOp(Shr Unsigned, i, j)) }
| i = expression "==" j = expression { with_loc $sloc (BinOp(Eq, i, j)) }
| i = expression "!=" j = expression { with_loc $sloc (BinOp(Ne, i, j)) }
| i = expression ">" j = expression { with_loc $sloc (BinOp(Gt None, i, j)) }
| i = expression ">s" j = expression { with_loc $sloc (BinOp(Gt (Some Signed), i, j)) }
| i = expression ">u" j = expression { with_loc $sloc (BinOp(Gt (Some Unsigned), i, j)) }
| i = expression "<" j = expression { with_loc $sloc (BinOp(Lt None, i, j)) }
| i = expression "<s" j = expression { with_loc $sloc (BinOp(Lt (Some Signed), i, j)) }
| i = expression "<u" j = expression { with_loc $sloc (BinOp(Lt (Some Unsigned), i, j)) }
| i = expression ">=" j = expression { with_loc $sloc (BinOp(Ge None, i, j)) }
| i = expression ">=s" j = expression { with_loc $sloc (BinOp(Ge (Some Signed), i, j)) }
| i = expression ">=u" j = expression { with_loc $sloc (BinOp(Ge (Some Unsigned), i, j)) }
| i = expression "<=" j = expression { with_loc $sloc (BinOp(Le None, i, j)) }
| i = expression "<=s" j = expression { with_loc $sloc (BinOp(Le (Some Signed), i, j)) }
| i = expression "<=u" j = expression { with_loc $sloc (BinOp(Le (Some Unsigned), i, j)) }
| BR_IF l = label i = expression %prec prec_branch
  { with_loc $sloc (Br_if (l, i))} 
(*
| BR l = label IF i = expression
  { with_loc $sloc (Br_if (l, i)) } %prec prec_branch
*)
| DISPATCH expression "["   list(label) ELSE label "]" "{" expression "}"
 { with_loc $sloc Nop }
| BR_ON_NULL l = label i = expression { with_loc $sloc (Br_on_null (l, i)) } %prec prec_branch
| BR_ON_NON_NULL l = label i = expression { with_loc $sloc (Br_on_non_null (l, i)) }  %prec prec_branch
| BR_ON_CAST l = label t = reference_type i = expression { with_loc $sloc (Br_on_cast (l, t, i)) } %prec prec_branch
| BR_ON_CAST_FAIL l = label t = reference_type i = expression { with_loc $sloc (Br_on_cast_fail (l, t, i)) } %prec prec_branch
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
| "!" i = expression { with_loc $sloc (UnOp (Not, i)) } %prec prec_unary
| "+" i = expression { with_loc $sloc (UnOp (Pos, i)) } %prec prec_unary
| "-" i = expression { with_loc $sloc (UnOp (Neg, i)) } %prec prec_unary
| i = expression "!" { with_loc $sloc (NonNull i) }

expression:
| i = blockinstr %prec prec_block { i }
| i = plaininstr { i }

let_pattern:
| p = simple_pattern t = ioption(":" t = value_type {t}) { (p, t) }

let_pattern_:
| p = separated_list(",", let_pattern) { p }

statement:
| i = plaininstr { i }
| NOP { with_loc $sloc Nop }
| UNREACHABLE { with_loc $sloc Unreachable }
| x = simple_pattern "=" i = expression { with_loc $sloc (Set (x, i)) }
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
| i = blockinstr l = statement_list { i :: l }
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
    let (name, typ, sign) = f in
    with_loc $sloc (Fundecl {name; typ; sign; attributes}) }
| g = globaldecl { g }
| f = tag
  { fun attributes ->
    let (name, typ, sign) = f in
    with_loc $sloc (Tag {name; typ; sign; attributes}) }

definition:
| f = func { f }
| g = global { g }

module_field:
| r = rectype { {desc = Type r.desc; info = r.info} }
| attributes = list(attribute) d = declaration { d attributes }
| attributes = list(attribute) d = definition { d attributes }
| attributes = list(attribute) "{" fields = list(module_field) "}"
  { with_loc $sloc (Group {attributes; fields}) }
| "#[if(" c = condition ")" "]" t = module_field e = else_clause
  { with_loc $sloc (Conditional {cond = c; then_fields = [t]; else_fields = e}) }

else_clause:
| { None }
| "#[else]" e = module_field { Some [e] }

(* Conditions of conditional annotations. Reuse the WAT-level [Wasm.Ast.cond]
   (we do not evaluate them; they are preserved for the preprocessor). *)
condition:
| name = ident { Wasm.Ast.Cond_var name }
| name = ident op = condition_relop rhs = condition_literal
  { Wasm.Ast.Cond_cmp (op, Wasm.Ast.Cond_var name, rhs) }
| name = ident "(" l = separated_list(",", condition) ")"
  { match name.desc, l with
    | "all", _ -> Wasm.Ast.Cond_and l
    | "any", _ -> Wasm.Ast.Cond_or l
    | "not", [c] -> Wasm.Ast.Cond_not c
    | _ ->
      raise
        (Wasm.Parsing.Syntax_error
           ($loc, "Expected 'all', 'any', or 'not(<cond>)' in a condition.")) }

condition_literal:
| "(" a = INT "," b = INT "," c = INT ")"
  { Wasm.Ast.Cond_version (int_of_string a, int_of_string b, int_of_string c) }
| s = STRING { Wasm.Ast.Cond_string s }

condition_relop:
| "=" { Wasm.Ast.Eq } | "!=" { Wasm.Ast.Ne } | "<" { Wasm.Ast.Lt }
| ">" { Wasm.Ast.Gt } | "<=" { Wasm.Ast.Le } | ">=" { Wasm.Ast.Ge }

parse: 
| EOF { [] }
| f = module_field r = parse { f :: r }
