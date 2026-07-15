%token <string> NAT
%token <string> INT
%token <string> FLOAT
%token <(string, Ast.location) Ast.annotated> STRING
%token <(string, Ast.location) Ast.annotated> ID
%token I32 I64 F32 F64
%token <Ast.Text.packedtype> PACKEDTYPE
%token LPAREN "("
%token RPAREN ")"
%token EOF
%token ANY
%token EQ
%token I31
%token STRUCT
%token ARRAY
%token NONE
%token FUNC
%token NOFUNC
%token EXN
%token NOEXN
%token CONT
%token NOCONT
%token EXTERN
%token NOEXTERN
%token EXACT
%token LPAREN_DESCRIPTOR "(descriptor"
%token LPAREN_DESCRIBES "(describes"
%token ANYREF
%token EQREF
%token I31REF
%token STRUCTREF
%token ARRAYREF
%token NULLREF
%token FUNCREF
%token NULLFUNCREF
%token EXNREF
%token NULLEXNREF
%token CONTREF
%token NULLCONTREF
%token EXTERNREF
%token NULLEXTERNREF
%token REF
%token NULL
%token MUT
%token FIELD
%token REC
%token SUB
%token FINAL
%token LPAREN_CATCH
%token LPAREN_CATCH_ALL
%token LPAREN_CATCH_ALL_REF
%token LPAREN_CATCH_REF
%token LPAREN_ON
%token LPAREN_EXPORT
%token LPAREN_IMPORT
%token LPAREN_LOCAL
%token LPAREN_PARAM
%token LPAREN_RESULT
%token LPAREN_THEN
%token LPAREN_TYPE
%token GLOBAL
%token START
%token ELEM
%token DECLARE
%token ITEM
%token MEMORY
%token PAGESIZE
%token SHARED
%token TABLE
%token DATA
%token OFFSET
%token MODULE
%token BLOCK
%token LOOP
%token END
%token IF
%token ELSE
%token BR
%token BR_IF
%token BR_TABLE
%token BR_ON_NULL
%token BR_ON_NON_NULL
%token BR_ON_CAST
%token BR_ON_CAST_FAIL
%token BR_ON_CAST_DESC_EQ
%token BR_ON_CAST_DESC_EQ_FAIL
%token CALL
%token CALL_REF
%token CALL_INDIRECT
%token RETURN_CALL
%token RETURN_CALL_REF
%token RETURN_CALL_INDIRECT
%token SELECT
%token LOCAL_GET
%token LOCAL_SET
%token LOCAL_TEE
%token GLOBAL_GET
%token GLOBAL_SET
%token <Ast.Text.num_type> STORE
%token <[`I32|`I64] * [`I8 | `I16 | `I32]> STORES
%token <Ast.atomicop> ATOMIC
%token <Ast.Text.num_type> LOAD
%token <Ast.Text.vec_load_op> VEC_LOAD
%token VEC_STORE
%token <Ast.vec_shift_op> VEC_SHIFT_OP
%token <Ast.vec_bitmask_op> VEC_BITMASK_OP
%token <Ast.vec_tern_op> VEC_TERN_OP
%token VEC_BITSELECT
%token <Ast.vec_shape * Ast.signage option> VEC_EXTRACT
%token <Ast.vec_shape> VEC_REPLACE
%token <[ `I8 | `I16 | `I32 | `I64 ]> VEC_LOAD_LANE VEC_STORE_LANE VEC_LOAD_SPLAT
%token VEC_SHUFFLE
%token <[`I32|`I64] * [`I8 | `I16 | `I32] * Ast.Text.signage> LOADS
%token MEMORY_SIZE
%token MEMORY_GROW
%token MEMORY_FILL
%token MEMORY_COPY
%token MEMORY_INIT
%token DATA_DROP
%token TABLE_GET
%token TABLE_SET
%token TABLE_SIZE
%token TABLE_GROW
%token TABLE_FILL
%token TABLE_COPY
%token TABLE_INIT
%token ELEM_DROP
%token REF_NULL
%token REF_FUNC
%token REF_TEST
%token REF_CAST
%token REF_CAST_DESC_EQ
%token REF_GET_DESC
%token STRUCT_NEW
%token STRUCT_NEW_DEFAULT
%token STRUCT_NEW_DESC
%token STRUCT_NEW_DEFAULT_DESC
%token <Ast.Text.signage option> STRUCT_GET
%token STRUCT_SET
%token ARRAY_NEW
%token ARRAY_NEW_DEFAULT
%token ARRAY_NEW_FIXED
%token ARRAY_NEW_DATA
%token ARRAY_NEW_ELEM
%token <Ast.Text.signage option> ARRAY_GET
%token ARRAY_SET
%token ARRAY_FILL
%token ARRAY_COPY
%token ARRAY_INIT_DATA
%token ARRAY_INIT_ELEM
%token I32_CONST
%token I64_CONST
%token F32_CONST
%token F64_CONST
%token <Ast.location Ast.Text.instr_desc> INSTR
%token TAG
%token TRY
%token TRY_TABLE
%token DO
%token CATCH
%token CATCH_ALL
%token THROW
%token THROW_REF
%token CONT_NEW
%token CONT_BIND
%token SUSPEND
%token RESUME
%token RESUME_THROW
%token RESUME_THROW_REF
%token SWITCH
%token <string> MEM_ALIGN
%token <string> MEM_OFFSET
(* Binaryen extensions *)
%token STRING_ANNOT CHAR_ANNOT
%token BRANCH_HINT_ANNOT
%token IF_ANNOT THEN_ANNOT ELSE_ANNOT
%token AND OR NOT
%token CMP_EQ CMP_NE CMP_LT CMP_GT CMP_LE CMP_GE

%token DEFINITION
%token BINARY
%token QUOTE
%token INSTANCE
%token REGISTER
%token INVOKE
%token GET
%token THREAD
%token WAIT
%token NAN
%token V128
%token REF_HOST
%token I8X16
%token I16X8
%token I32X4
%token I64X2
%token F32X4
%token F64X2
%token ASSERT_RETURN
%token ASSERT_RETURN_NAN
%token ASSERT_EXCEPTION
%token ASSERT_SUSPENSION
%token ASSERT_TRAP
%token ASSERT_EXHAUSTION
%token ASSERT_MALFORMED
%token ASSERT_INVALID
%token ASSERT_MALFORMED_CUSTOM
%token ASSERT_INVALID_CUSTOM
%token ASSERT_UNLINKABLE
%token V128_CONST
%token REF_EXTERN
%token REF_STRUCT
%token REF_ARRAY
%token EITHER
%token SCRIPT
%token INPUT
%token OUTPUT

%on_error_reduce plain_instruction list(STRING) list(value_type) list(field_type) list(field) limits list(folded_instruction) list(typedef) list(index) list(elemexpr) list(module_field) nonempty_list(f64) list(const) nonempty_list(float_or_nan) nonempty_list(result_pat) list(result_pat) list(cmd) nonempty_list(module_field) nonempty_list(index) string_list

%parameter <Context : sig type t = Wax_utils.Trivia.context val context : t end>

%{
module Uint32 = Wax_utils.Uint32
module Uint64 = Wax_utils.Uint64
module V128 = Wax_utils.V128
(* Empty module shadowing the library's wrapper module so menhir's [--infer]
   type printer cannot qualify inferred types with it (which would make this
   module depend on the wrapper — a cycle); it falls back to the bare [Ast]
   alias instead. Must stay named after the library (see [name] in dune). *)
module Wax_wasm = struct
end
open Ast.Text

let lane_width : [ `I8 | `I16 | `I32 | `I64 ] -> Uint64.t = function
  | `I8 -> Uint64.of_int 1
  | `I16 -> Uint64.of_int 2
  | `I32 -> Uint64.of_int 4
  | `I64 -> Uint64.of_int 8

(* Natural alignment (the access size, in bytes) of a memory access. An omitted
   [align=] defaults to this, per the spec. *)
let storage_width : [ `I8 | `I16 | `I32 ] -> Uint64.t = function
  | `I8 -> Uint64.of_int 1
  | `I16 -> Uint64.of_int 2
  | `I32 -> Uint64.of_int 4

let num_type_width : num_type -> Uint64.t = function
  | NumI32 | NumF32 -> Uint64.of_int 4
  | NumI64 | NumF64 -> Uint64.of_int 8

let vec_load_width : vec_load_op -> Uint64.t = function
  | Load128 -> Uint64.of_int 16
  | Load8x8S | Load8x8U | Load16x4S | Load16x4U | Load32x2S | Load32x2U
  | Load64Zero ->
      Uint64.of_int 8
  | Load32Zero -> Uint64.of_int 4

(* A custom page size is written in WAT as its byte value [(pagesize 65536)] but
   the format stores its base-2 logarithm, so require a power of two here (the
   further restriction to 1 or 65536 is a validation check). *)
let page_size_log2 loc (n : Uint32.t) =
  let n = Uint32.to_int n in
  if n > 0 && n land (n - 1) = 0 then
    let rec exp v p = if v = 1 then p else exp (v lsr 1) (p + 1) in
    exp n 0
  else
    raise
      (Parsing.Syntax_error (loc, "The page size must be a power of two.\n"))

let with_loc loc desc =
  Wax_utils.Trivia.with_pos Context.context {loc_start = fst loc; loc_end = snd loc} desc

let map_fst f (x, y) = (f x, y)

let check_constant f loc s =
  if not (f s) then
    raise
      (Parsing.Syntax_error
         ( loc,
           Printf.sprintf "Constant %s is out of range.\n" s))

(* Build a compact import group [(import "m" (item …) …)] from its elements
   (compact-import-section proposal). Each item is [(item $id? "name" <type>?)]:
   the [$id] is a wax extension over the standard name-only form. Either every
   item carries its own type ([Import_group1], id living in that type) or all
   items are name-only and share one final type that binds no id ([Import_group2],
   where the per-item [$id] extension applies); mixing is rejected. *)
let compact_import loc module_ elems : _ Ast.Text.modulefield =
  let as_item = function
    | `Item it -> it
    | `Type _ ->
        raise (Parsing.Syntax_error
                 (loc, "A shared import type must be the group's last element.\n"))
  in
  let items, trailing =
    match List.rev elems with
    | `Type t :: rev_rest -> (List.rev_map as_item rev_rest, Some t)
    | _ -> (List.map as_item elems, None)
  in
  match trailing with
  | Some (tid, tdesc) ->
      if Option.is_some tid then
        raise (Parsing.Syntax_error
                 (loc, "A shared import type may not bind an identifier.\n"));
      if List.exists (fun (_, _, t) -> Option.is_some t) items then
        raise (Parsing.Syntax_error
                 (loc, "With a shared type, each import item names only.\n"));
      Import_group2
        { module_; desc = tdesc; items = List.map (fun (id, name, _) -> (name, id)) items }
  | None ->
      let items =
        List.map
          (fun (id, name, t) ->
            match t with
            | Some (tid, desc) ->
                if Option.is_some id then
                  raise (Parsing.Syntax_error
                           (loc, "An import item with its own type binds its id in that type.\n"));
                (name, tid, desc)
            | None ->
                raise (Parsing.Syntax_error
                         (loc, "This import item needs a type, or a shared final type.\n")))
          items
      in
      Import_group1 { module_; items }

(* Range-checked NAT conversions: a plain [Uint32/Uint64.of_string] raises (and
   [Uint64.of_string] also prints) on an out-of-range literal, so guard with
   [check_constant] first to report a clean "out of range" parse error instead of
   crashing. [Misc.is_int32]/[is_int64] accept the full unsigned width for a NAT. *)
let u32_of_string loc s = check_constant Misc.is_int32 loc s; Uint32.of_string s
let u64_of_string loc s = check_constant Misc.is_int64 loc s; Uint64.of_string s

let check_labels lab (lab' : Ast.Text.name option) =
  match lab' with
  | None -> ()
  | Some lab' ->
      let mismatch =
        match lab with
        | Some lab -> lab.Ast.desc <> lab'.desc
        | None -> true
      in
      if mismatch then
        raise
          (Parsing.Syntax_error
             ( (lab'.info.loc_start, lab'.info.loc_end),
               Printf.sprintf "Label mismatch.\n"))

(* Branch-hinting proposal: decode a [(@metadata.code.branch_hint "…")] payload.
   The string is a single byte: 0x00 = unlikely, otherwise likely. *)
let branch_hint_of_annotation loc (s : (string, Ast.location) Ast.annotated) =
  match if String.length s.Ast.desc = 1 then Char.code s.Ast.desc.[0] else -1 with
  | 0 -> false
  | 1 -> true
  | _ ->
      raise
        (Parsing.Syntax_error
           (loc, "A branch hint must be \"\\00\" or \"\\01\".\n"))

(* The branch hint wraps the instruction that follows it. Whether that
   instruction is a legal target (only [if]/[br_if]/[br_on_*]) is a *validation*
   concern, not a syntactic one — the reference tools attach the annotation
   during parsing and diagnose a bad placement afterwards, which also lets a
   malformed inline module inside an [assert_invalid] parse far enough to be
   rejected. So the grammar attaches it unconditionally; [validation] (and the
   Wax typer) reject a hint on anything but a conditional branch. *)
let hinted loc h (i : _ instr) = with_loc loc (Hinted (h, i))


%}

%start <Ast.location Ast.Text.module_> parse
%start <([`Valid | `Invalid of string | `Malformed of string ] *
         [`Parsed of Ast.location Ast.Text.module_
         | `Text of string | `Binary of string ]) list> parse_script

 (* To avoid unused token report and refer to Context in the mli *)
%start <Context.t> dummy_ctx

%%

dummy_ctx: EOF { assert false }

u32: n = NAT { u32_of_string $sloc n }

u64: n = NAT { u64_of_string $sloc n }

u8: n = NAT { check_constant Misc.is_int8 $sloc n; n }

i8:
  i = NAT
| i = INT
{ check_constant Misc.is_int8 $sloc i; i }

i16:
  i = NAT
| i = INT
{ check_constant Misc.is_int16 $sloc i; i }

i32:
  i = NAT
| i = INT
{ check_constant Misc.is_int32 $sloc i; i }

i64:
  i = NAT
| i = INT
{ check_constant Misc.is_int64 $sloc i; i }

f32:
  f = NAT
| f = INT
| f = FLOAT
{ check_constant Misc.is_float32 $sloc f; f }

f64:
  f = NAT
| f = INT
| f = FLOAT
{ check_constant Misc.is_float64 $sloc f; f }

index:
| n = u32 { with_loc $sloc (Num n) }
| i = ID { {info = i.info; desc = (Id i.Ast.desc)} }

name: s = STRING
  { if not (String.is_valid_utf_8 s.Ast.desc) then
      raise
        (Parsing.Syntax_error
           ( (s.info.Ast.loc_start, s.info.loc_end),
             Printf.sprintf "Malformed name \"%s\".\n"
               (snd (Wax_utils.Unicode.escape_string s.desc))));
    s
  }

(* Types *)

heap_type:
| ANY { Any }
| EQ { Eq }
| I31 { I31 }
| STRUCT { Struct }
| ARRAY { Array }
| NONE { None_ }
| FUNC { Func }
| NOFUNC { NoFunc }
| EXN { Exn }
| NOEXN { NoExn }
| CONT { Cont }
| NOCONT { NoCont }
| EXTERN { Extern }
| NOEXTERN { NoExtern }
| "(" EXACT i = index ")" { Exact i }
| i = index { Type i }

reference_type:
| "(" REF nullable = boption(NULL) typ = heap_type ")"
  { { nullable; typ } }
| ANYREF { {nullable = true; typ = Any} }
| EQREF { {nullable = true; typ = Eq} }
| I31REF { {nullable = true; typ = I31} }
| STRUCTREF { {nullable = true; typ = Struct} }
| ARRAYREF { {nullable = true; typ = Array} }
| NULLREF { {nullable = true; typ = None_} }
| FUNCREF { {nullable = true; typ = Func} }
| NULLFUNCREF { {nullable = true; typ = NoFunc} }
| EXNREF { {nullable = true; typ = Exn} }
| NULLEXNREF { {nullable = true; typ = NoExn} }
| CONTREF { {nullable = true; typ = Cont} }
| NULLCONTREF { {nullable = true; typ = NoCont} }
| EXTERNREF { {nullable = true; typ = Extern} }
| NULLEXTERNREF { {nullable = true; typ = NoExtern} }

value_type:
| I32 { I32 }
| I64 { I64 }
| F32 { F32 }
| F64 { F64 }
| V128 { V128 }
| t = reference_type { Ref t }

functype:
| "(" FUNC r = parameters_and_results ")"{ r }

(* A single unnamed parameter, located at its value type, so an anonymous
   [(param t1 t2 …)] yields one located entry per type (distinct spans, unlike
   the [field] case which shares one span and must fall back to no location). *)
unnamed_param:
| t = value_type { with_loc $sloc (None, t) }

(* A single [(param …)] group. Kept non-recursive so its [$sloc] spans just the
   group: folding the list tail in here (as a recursive [parameters] rule would)
   makes [$sloc] reach to the end of the whole list, so each parameter's
   location would overlap every following one. *)
param_group:
| LPAREN_PARAM i = ID t = value_type ")" { [ with_loc $sloc (Some i, t) ] }
| LPAREN_PARAM l = unnamed_param * ")" { l }

parameters:
| { [] }
| g = param_group rem = parameters { g @ rem }

parameters_without_bindings:
| { [] }
| LPAREN_PARAM l = unnamed_param * ")" rem = parameters_without_bindings
  { l @ rem }

results:
| { [] }
| LPAREN_RESULT l = value_type * ")" rem = results
  { l @ rem }

parameters_and_results:
| p = parameters r = results
  { {params = Array.of_list p; results = Array.of_list r} }

parameters_and_results_without_bindings:
| p = parameters_without_bindings r = results
  { {params = Array.of_list p;
     results = Array.of_list r } }

field:
| "(" FIELD i = ID t = field_type ")" { [ with_loc $sloc (Some i, t) ] }
(* An anonymous (field t1 t2 ...) declares several fields sharing one source
   span; locating them all at $sloc would create duplicate keys, so only the
   single-field case gets a real (comment-anchoring) location. *)
| "(" FIELD l = field_type * ")"
  { match l with
    | [ t ] -> [ with_loc $sloc (None, t) ]
    | _ -> List.map (fun t -> Ast.no_loc (None, t)) l }

field_type:
| typ = storage_type { {mut = false; typ} }
| "(" MUT typ = storage_type ")" { {mut = true; typ} }

storage_type:
| t = value_type { Value t }
| t = PACKEDTYPE { Packed t }

composite_type:
| "(" ARRAY t = field_type ")" { Array t }
| "(" STRUCT l = field * ")" { Struct (Array.of_list (List.flatten l)) }
| "(" CONT i = index ")" { Cont i }
| t = functype { Func t }

rectype:
| "(" REC l = typedef * ")"
  { with_loc $sloc (Types (Array.of_list l)) }
| t = typedef { {t with desc = Types [| t |]} }

typedef:
| LPAREN_TYPE name = ID ? t = subtype ")"
 { with_loc $sloc (name, t) }

(* custom-descriptors: optional [(describes $o)] then [(descriptor $d)] clauses
   preceding the composite type. Inside [(sub …)] the (possibly empty) form is
   fine — the clauses start with the glued [(describes]/[(descriptor] tokens,
   distinct from the composite type's [(]. At the top level of a subtype an
   empty prefix would clash with [(sub …)] on [(], so the non-empty form is
   split out and the plain composite type kept as its own alternative. *)
descriptor_clauses:
| describes = ioption("(describes" o = index ")" { o })
  descriptor = ioption("(descriptor" d = index ")" { d })
  { (describes, descriptor) }

descriptor_clauses_nonempty:
| "(describes" o = index ")"
  descriptor = ioption("(descriptor" d = index ")" { d })
  { (Some o, descriptor) }
| "(descriptor" d = index ")"
  { (None, Some d) }

subtype:
| "(" SUB final = boption(FINAL) supertype = index ?
  c = descriptor_clauses typ = composite_type ")"
  { let (describes, descriptor) = c in
    {final; supertype; typ; descriptor; describes} }
| c = descriptor_clauses_nonempty typ = composite_type
  { let (describes, descriptor) = c in
    {final = true; supertype = None; typ; descriptor; describes} }
| typ = composite_type
  { {final = true; supertype = None; typ; descriptor = None; describes = None} }

address_type:
| I32 { `I32 }
| I64 { `I64 }

limits:
| mi = u64
  { with_loc $sloc {mi; ma = None; address_type = `I32; page_size_log2 = None; shared = false} }
| mi = u64 ma = u64
  { with_loc $sloc {mi; ma = Some ma; address_type = `I32; page_size_log2 = None; shared = false} }
| at = address_type mi = u64
  { with_loc $sloc {mi; ma = None; address_type = at; page_size_log2 = None; shared = false} }
| at = address_type mi = u64 ma = u64
  { with_loc $sloc {mi; ma = Some ma; address_type = at; page_size_log2 = None; shared = false} }

pagesize_clause:
| "(" PAGESIZE p = u32 ")" { page_size_log2 $loc(p) p }

memory_type:
| l = limits sh = boption(SHARED) ps = ioption(pagesize_clause)
  { { l with Ast.desc = { l.Ast.desc with shared = sh; page_size_log2 = ps } } }

table_type:
| l = limits t = reference_type { {limits = l; reftype = t} }

(* Instructions *)

(* Branch-hinting proposal: the annotation prefixing a hinted [if]/[br_if]. *)
branch_hint_annot:
| BRANCH_HINT_ANNOT s = STRING ")" { branch_hint_of_annotation $loc(s) s }

blockinstr:
| BLOCK label = label typ = block_type block =instructions END label2 = label
  { check_labels label label2;
    with_loc $sloc (Block {label; typ; block = Ast.no_loc block}) }
| LOOP label = label typ = block_type block = instructions END label2 = label
  { check_labels label label2;
    with_loc $sloc (Loop {label; typ; block = Ast.no_loc block}) }
| IF label = label typ = block_type if_block = instructions ELSE
  label2 = label else_block = instructions END
  label3 = label
  { check_labels label label2;
    check_labels label label3;
    with_loc $sloc
      (If {label; typ; if_block = Ast.no_loc if_block;
           else_block = Ast.no_loc else_block }) }
| IF label = label typ = block_type if_block = instructions END
  label2 = label
  { check_labels label label2;
    with_loc $sloc
      (If {label; typ; if_block = Ast.no_loc if_block;
           else_block = Ast.no_loc [] }) }
| TRY_TABLE label = label typ = block_type catches = catches block = instructions
  END label2 = label
   { check_labels label label2;
     with_loc $sloc (TryTable {label; typ; catches; block = Ast.no_loc block}) }
| TRY label = label typ = block_type block = instructions c = legacy_catches label2 = label
  { check_labels label label2;
    let (catches, catch_all) = c in
    with_loc $sloc (Try {label; typ; block = Ast.no_loc block; catches; catch_all}) }

catches:
| { [] }
| LPAREN_CATCH x = index l = index ")" c = catches
  { Catch(x, l) :: c }
| LPAREN_CATCH_REF x = index l = index ")" c = catches
  { CatchRef(x, l) :: c }
| LPAREN_CATCH_ALL l = index ")" c = catches
  { CatchAll l :: c }
| LPAREN_CATCH_ALL_REF l = index ")" c = catches
  { CatchAllRef l :: c }

on_clauses:
| { [] }
| LPAREN_ON x = index l = index ")" c = on_clauses
  { OnLabel(x, l) :: c }
| LPAREN_ON x = index SWITCH ")" c = on_clauses
  { OnSwitch x :: c }

legacy_catches:
| END { [], None }
| CATCH_ALL l = instructions END { [], Some (Ast.no_loc l) }
| CATCH i = index l = instructions rem = legacy_catches
  { map_fst (fun r -> (i, Ast.no_loc l) :: r) rem }

label:
| i = ID ? { i }

block_type:
| tu = type_use_without_bindings
  { match tu with
    | None, Some {params = [||]; results = [|typ|]} -> Some (Valtype typ)
    | None, None -> None
    | _ -> Some (Typeuse tu) }

%inline memindex:
| i = ioption(index) { Option.value ~default:(with_loc $sloc (Num Uint32.zero)) i}

%inline tableindex:
| i = ioption(index) { Option.value ~default:(with_loc $sloc (Num Uint32.zero)) i}

list_of_indices: l = index+ { l }

plain_instruction:
| THROW i = index { with_loc $sloc (Throw i) }
| THROW_REF { with_loc $sloc ThrowRef }
| CONT_NEW i = index { with_loc $sloc (ContNew i) }
| CONT_BIND i = index j = index { with_loc $sloc (ContBind (i, j)) }
| SUSPEND i = index { with_loc $sloc (Suspend i) }
| RESUME i = index c = on_clauses { with_loc $sloc (Resume (i, c)) }
| RESUME_THROW i = index j = index c = on_clauses
  { with_loc $sloc (ResumeThrow (i, j, c)) }
| RESUME_THROW_REF i = index c = on_clauses
  { with_loc $sloc (ResumeThrowRef (i, c)) }
| SWITCH i = index j = index { with_loc $sloc (Switch (i, j)) }
| BR i = index { with_loc $sloc (Br i) }
| BR_IF i = index { with_loc $sloc (Br_if i) }
| BR_TABLE l = index+
  { let l = List.rev l in
    with_loc $sloc (Br_table (List.rev (List.tl l), List.hd l)) }
| BR_ON_NULL i = index { with_loc $sloc (Br_on_null i) }
| BR_ON_NON_NULL i = index { with_loc $sloc (Br_on_non_null i) }
| BR_ON_CAST i = index t1 = reference_type t2 = reference_type
  { with_loc $sloc (Br_on_cast (i, t1, t2)) }
| BR_ON_CAST_FAIL i = index t1 = reference_type t2 = reference_type
  { with_loc $sloc (Br_on_cast_fail (i, t1, t2)) }
| BR_ON_CAST_DESC_EQ i = index t1 = reference_type t2 = reference_type
  { with_loc $sloc (Br_on_cast_desc_eq (i, t1, t2)) }
| BR_ON_CAST_DESC_EQ_FAIL i = index t1 = reference_type t2 = reference_type
  { with_loc $sloc (Br_on_cast_desc_eq_fail (i, t1, t2)) }
| CALL i = index { with_loc $sloc (Call i) }
| CALL_REF i = index { with_loc $sloc (CallRef i) }
| RETURN_CALL i = index { with_loc $sloc (ReturnCall i) }
| RETURN_CALL_REF i = index { with_loc $sloc (ReturnCallRef i) }
| LOCAL_GET i = index { with_loc $sloc (LocalGet i) }
| LOCAL_SET i = index { with_loc $sloc (LocalSet i) }
| LOCAL_TEE i = index { with_loc $sloc (LocalTee i) }
| op = VEC_SHIFT_OP { with_loc $sloc (VecShift op) }
| op = VEC_BITMASK_OP { with_loc $sloc (VecBitmask op) }
| op = VEC_TERN_OP { with_loc $sloc (VecTernOp op) }
| VEC_BITSELECT { with_loc $sloc VecBitselect }
| GLOBAL_GET i = index { with_loc $sloc (GlobalGet i) }
| GLOBAL_SET i = index { with_loc $sloc (GlobalSet i) }
| sz = LOAD i = memindex m = memarg
  { with_loc $sloc (Load (i, m (num_type_width sz), sz)) }
| op = VEC_LOAD i = memindex m = memarg
  { with_loc $sloc (VecLoad (i, op, m (vec_load_width op))) }
| k = LOADS i = memindex m = memarg
  { let (sz, sz', s) = k in
    with_loc $sloc (LoadS (i, m (storage_width sz'), sz, sz', s)) }
| sz = STORE i = memindex m = memarg
  { with_loc $sloc (Store (i, m (num_type_width sz), sz)) }
| VEC_STORE i = memindex m = memarg
  { with_loc $sloc (VecStore (i, m (Uint64.of_int 16))) }
| sz = STORES i = memindex m = memarg
  { with_loc $sloc (StoreS (i, m (storage_width (snd sz)), fst sz, snd sz)) }
| op = ATOMIC i = memindex m = memarg
  { let nat = Uint64.of_int (1 lsl Atomics.natural_align_log2 op) in
    with_loc $sloc (Atomic (i, op, m nat)) }
| MEMORY_SIZE i = memindex { with_loc $sloc (MemorySize i) }
| MEMORY_GROW i = memindex { with_loc $sloc (MemoryGrow i) }
| MEMORY_FILL i = memindex { with_loc $sloc (MemoryFill i) }
| MEMORY_COPY p = ioption(i1 = index i2 = index { (i1, i2) })
  { let zero = with_loc $loc(p) (Num Uint32.zero) in
    let (i, i') = Option.value ~default:(zero, zero) p in
    with_loc $sloc (MemoryCopy (i, i')) }
| MEMORY_INIT i = memindex d = index { with_loc $sloc (MemoryInit (i, d)) }
| DATA_DROP d = index { with_loc $sloc (DataDrop d) }
| TABLE_GET i = tableindex { with_loc $sloc (TableGet i) }
| TABLE_SET i = tableindex { with_loc $sloc (TableSet i) }
| TABLE_SIZE i = tableindex { with_loc $sloc (TableSize i) }
| TABLE_GROW i = tableindex { with_loc $sloc (TableGrow i) }
| TABLE_FILL i = tableindex { with_loc $sloc (TableFill i) }
| TABLE_COPY p = ioption(i1 = index i2 = index { (i1, i2) })
  { let zero = with_loc $loc(p) (Num Uint32.zero) in
    let (i, i') = Option.value ~default:(zero, zero) p in
    with_loc $sloc (TableCopy (i, i')) }
| TABLE_INIT i = tableindex d = index { with_loc $sloc (TableInit (i, d)) }
| ELEM_DROP e = index { with_loc $sloc (ElemDrop e) }
| REF_NULL t = heap_type { with_loc $sloc (RefNull t) }
| REF_FUNC i = index { with_loc $sloc (RefFunc i) }
| REF_TEST t = reference_type { with_loc $sloc (RefTest t) }
| REF_CAST t = reference_type { with_loc $sloc (RefCast t) }
| REF_CAST_DESC_EQ t = reference_type { with_loc $sloc (RefCastDescEq t) }
| REF_GET_DESC i = index { with_loc $sloc (RefGetDesc i) }
| STRUCT_NEW i = index { with_loc $sloc (StructNew i) }
| STRUCT_NEW_DEFAULT i = index { with_loc $sloc (StructNewDefault i) }
| STRUCT_NEW_DESC i = index { with_loc $sloc (StructNewDesc i) }
| STRUCT_NEW_DEFAULT_DESC i = index { with_loc $sloc (StructNewDefaultDesc i) }
| s = STRUCT_GET i1 = index i2 = index { with_loc $sloc (StructGet (s, i1, i2)) }
| STRUCT_SET i1 = index i2 = index { with_loc $sloc (StructSet (i1, i2)) }
| ARRAY_NEW i = index { with_loc $sloc (ArrayNew i) }
| ARRAY_NEW_DEFAULT i = index { with_loc $sloc (ArrayNewDefault i) }
| ARRAY_NEW_FIXED i = index l = u32
  { with_loc $sloc (ArrayNewFixed (i, l)) }
| ARRAY_NEW_DATA i1 = index i2 = index { with_loc $sloc (ArrayNewData (i1, i2)) }
| ARRAY_NEW_ELEM i1 = index i2 = index { with_loc $sloc (ArrayNewElem (i1, i2)) }
| s = ARRAY_GET i = index { with_loc $sloc (ArrayGet (s, i)) }
| ARRAY_SET i = index { with_loc $sloc (ArraySet i) }
| ARRAY_FILL i = index { with_loc $sloc (ArrayFill i) }
| ARRAY_COPY i1 = index i2 = index { with_loc $sloc (ArrayCopy (i1, i2)) }
| ARRAY_INIT_DATA i1 = index i2 = index { with_loc $sloc (ArrayInitData (i1, i2)) }
| ARRAY_INIT_ELEM i1 = index i2 = index { with_loc $sloc (ArrayInitElem (i1, i2)) }
| I32_CONST i = i32
  { with_loc $sloc (Const (I32 i)) }
| I64_CONST i = i64
  { with_loc $sloc (Const (I64 i)) }
| F32_CONST f = f32
  { with_loc $sloc (Const (F32 f)) }
| F64_CONST f = f64
  { with_loc $sloc (Const (F64 f)) }
| V128_CONST I8X16 i8 i8 i8 i8 i8 i8 i8 i8 i8 i8 i8 i8 i8 i8 i8 i8
  { let components =
      [$3; $4; $5; $6; $7; $8; $9; $10; $11; $12; $13; $14; $15; $16; $17; $18]
    in
    with_loc $sloc (VecConst {V128.shape = I8x16; components}) }
| V128_CONST I16X8 i16 i16 i16 i16 i16 i16 i16 i16
  { let components = [$3; $4; $5; $6; $7; $8; $9; $10] in
    with_loc $sloc (VecConst {V128.shape = I16x8; components}) }
| V128_CONST I32X4 i0 = i32 i1 = i32 i2 = i32 i3 = i32
  { let components = [i0; i1; i2; i3] in
    with_loc $sloc (VecConst {V128.shape = I32x4; components}) }
| V128_CONST I64X2 i0 = i64 i1 = i64
  { let components = [i0; i1] in
    with_loc $sloc (VecConst {V128.shape = I64x2; components}) }
| V128_CONST F32X4 f0 = f32 f1 = f32 f2 = f32 f3 = f32
  { let components = [f0; f1; f2; f3] in
    with_loc $sloc (VecConst {V128.shape = F32x4; components}) }
| V128_CONST F64X2 f0 = f64 f1 = f64
  { let components = [f0; f1] in
    with_loc $sloc (VecConst {V128.shape = F64x2; components}) }
| op = VEC_EXTRACT i = u8
  { with_loc $sloc (VecExtract (fst op, snd op, int_of_string i)) }
| op = VEC_REPLACE i = u8
  { with_loc $sloc (VecReplace (op, int_of_string i)) }
| VEC_SHUFFLE i0=u8 i1=u8 i2=u8 i3=u8 i4=u8 i5=u8 i6=u8 i7=u8 i8=u8
              i9=u8 i10=u8 i11=u8 i12=u8 i13=u8 i14=u8 i15=u8
  { let lanes =
      String.concat ""
        (List.map (fun l -> String.make 1 (Char.chr (int_of_string l)))
           [i0; i1; i2; i3; i4; i5; i6; i7; i8;
            i9; i10; i11; i12; i13; i14; i15])
    in
    with_loc $sloc (VecShuffle lanes) }
| op = VEC_LOAD_LANE i = memindex m = memarg l = u8
  { with_loc $sloc (VecLoadLane (i, op, m (lane_width op), int_of_string l)) }
| op = VEC_STORE_LANE i = memindex m = memarg l = u8
  { with_loc $sloc
      (VecStoreLane (i, op, m (lane_width op), int_of_string l)) }
| op = VEC_LOAD_SPLAT i = memindex m = memarg
  { with_loc $sloc (VecLoadSplat (i, op, m (lane_width op))) }
| i = INSTR { with_loc $sloc i }
| i = callindirect { i }
| i = select { i }

%inline memarg:
| o = ioption(MEM_OFFSET) a = ioption(MEM_ALIGN)
  { let loc = $sloc in
    fun width ->
    {offset = Option.value ~default:Uint64.zero (Option.map (u64_of_string loc) o);
     align = Option.value ~default:(width : Uint64.t) (Option.map (u64_of_string loc) a)} }

callindirect:
| CALL_INDIRECT i = index t = type_use_without_bindings
  { with_loc $sloc (CallIndirect (i, t)) }
| CALL_INDIRECT t = type_use_without_bindings
  { with_loc $sloc (CallIndirect (Ast.no_loc (Num Uint32.zero), t)) }
| RETURN_CALL_INDIRECT i = index t = type_use_without_bindings
  { with_loc $sloc (ReturnCallIndirect (i, t)) }
| RETURN_CALL_INDIRECT t = type_use_without_bindings
  { with_loc $sloc (ReturnCallIndirect (Ast.no_loc (Num Uint32.zero), t)) }

select_result_type:
| { ([]) }
| LPAREN_RESULT l = value_type * ")" rem = select_result_type
  { l :: rem }

select:
| SELECT l = select_result_type
  { with_loc $sloc  (Select (if l = [] then None else Some (List.concat l))) }

instructions:
| { [] }
| i = plain_instruction r = instructions { i :: r }
| i = blockinstr r = instructions { i :: r }
| i = folded_instruction r = instructions { i :: r }
| i = cond_instr r = instructions { i :: r }
(* Branch-hinting proposal: the [(@metadata.code.branch_hint …)] annotation wraps
   the conditional branch that follows it (unfolded [if]/[br_if]/[br_on_*] or the
   folded form). [hinted] rejects the annotation on any other instruction. *)
| h = branch_hint_annot i = plain_instruction r = instructions
  { hinted $sloc h i :: r }
| h = branch_hint_annot i = blockinstr r = instructions
  { hinted $sloc h i :: r }
| h = branch_hint_annot i = folded_instruction r = instructions
  { hinted $sloc h i :: r }

string_list: l = list(STRING) { l }

(* Conditional annotations, as used by the js_of_ocaml WAT preprocessor.
   The condition is parsed and preserved but not evaluated. *)

cond:
| s = STRING { Ast.Cond_string s }
| v = ID { Ast.Cond_var v }
| "(" maj = NAT min = NAT pat = NAT ")"
    { Ast.Cond_version (int_of_string maj, int_of_string min, int_of_string pat) }
| "(" AND l = cond+ ")" { Ast.Cond_and l }
| "(" OR l = cond+ ")" { Ast.Cond_or l }
| "(" NOT e = cond ")" { Ast.Cond_not e }
| "(" op = cmp_op a = cond b = cond ")" { Ast.Cond_cmp (op, a, b) }

cmp_op:
| CMP_EQ { Ast.Eq }
| CMP_NE { Ast.Ne }
| CMP_LT { Ast.Lt }
| CMP_GT { Ast.Gt }
| CMP_LE { Ast.Le }
| CMP_GE { Ast.Ge }

(* Each [(@then ...)] / [(@else ...)] clause carries the location of the whole
   clause (the annotation and closing paren included) so a comment trailing the
   clause attaches to it rather than leaking into the next one. *)
cond_then:
| THEN_ANNOT then_body = instructions ")" { with_loc $sloc then_body }

cond_else:
| ELSE_ANNOT e = instructions ")" { with_loc $sloc e }

cond_instr:
| IF_ANNOT c = cond
  then_body = cond_then
  else_body = option(cond_else)
  ")"
  { with_loc $sloc (If_annotation { cond = c; then_body; else_body }) }

folded_instruction:
| "(" i = plain_instruction l = folded_instruction * ")"
  { with_loc $sloc (Folded (i, l)) }
(* The inner block-family node is given a span ending at the body
   ($endpos(<body>)), i.e. before the closing paren, so it differs from
   the enclosing Folded's $sloc. Otherwise the two nodes share an
   identical location and collide as duplicate keys in the comment-trivia
   table; worse, a comment trailing the closing paren would attach to the
   inner node (which the printer never looks up) and be dropped. Ending
   the inner span before ")" leaves the outer Folded as the sole owner of
   that closing position. *)
| "(" BLOCK label = label typ = block_type block = instructions ")"
  { with_loc $sloc
      (Folded (with_loc ($startpos, $endpos(block)) (Block {label; typ; block = with_loc ($startpos(block), $endpos(block)) block}), [])) }
| "(" LOOP label = label typ = block_type block = instructions ")"
  { with_loc $sloc
      (Folded (with_loc ($startpos, $endpos(block)) (Loop {label; typ; block = with_loc ($startpos(block), $endpos(block)) block}), [])) }
| "(" IF label = label
  typ = block_type l = folded_instructions if_block = folded_then
  else_block = option(folded_else)
  ")"
  { with_loc $sloc
      (Folded
        (with_loc ($startpos, $endpos(else_block))
          (If {label; typ; if_block;
               else_block = Option.value ~default:(Ast.no_loc []) else_block }),
         l)) }
| "(" TRY_TABLE label = label typ = block_type catches = catches
  block = instructions  ")"
   { with_loc $sloc
       (Folded
          (with_loc ($startpos, $endpos(block)) (TryTable {label; typ; catches; block = with_loc ($startpos(block), $endpos(block)) block}),
          [])) }
| "(" TRY label = label
  typ = block_type "(" DO block = instructions ")"
  c = folded_catches ")"
  { let (catches, catch_all) = c in
    with_loc $sloc
      (Folded
        (with_loc ($startpos, $endpos(c)) (Try {label; typ; block = with_loc ($startpos(block), $endpos(block)) block; catches; catch_all}), [])) }
| STRING_ANNOT id = option(index) l = string_list ")"
    { with_loc $sloc (String (id, l)) }
| CHAR_ANNOT s = STRING ")"
    { let c = String.get_utf_8_uchar s.Ast.desc 0 in
      if
        not (Uchar.utf_decode_is_valid c) ||
        Uchar.utf_decode_length c <> String.length s.desc
      then
        raise
          (Parsing.Syntax_error
             ( $sloc,
               Printf.sprintf "Malformed char \"%s\".\n"
                 (snd (Wax_utils.Unicode.escape_string s.desc))));
      with_loc $sloc (Char (Uchar.utf_decode_uchar c)) }

(* The (then ...) / (else ...) clauses of a folded if. Each carries the
   location of the whole clause (parens included) so a comment trailing
   the clause attaches to it rather than leaking into the next clause. *)
folded_then:
| LPAREN_THEN block = instructions ")" { with_loc $sloc block }

folded_else:
| "(" ELSE block = instructions ")" { with_loc $sloc block }

folded_catches:
| { [], None }
| LPAREN_CATCH_ALL l = instructions ")" { [], Some (with_loc ($startpos(l), $endpos(l)) l) }
| LPAREN_CATCH i = index l = instructions ")" rem = folded_catches
  { map_fst (fun r -> (i, with_loc ($startpos(l), $endpos(l)) l) :: r) rem }

folded_instructions:
| { [] }
| i = folded_instruction r = folded_instructions { i :: r }

expression:
| l = instructions { l }

(* Modules *)

type_use:
| LPAREN_TYPE i = index ")" s = parameters_and_results
  { match s with
    | {params = [||]; results = [||]} -> Some i, None
    | _ -> Some i, Some s }
| s = parameters_and_results { (None, Some s)}

type_use_without_bindings:
| LPAREN_TYPE i = index ")" s = parameters_and_results_without_bindings
  { match s with
    | {params = [||]; results = [||]} -> Some i, None
    | _ -> Some i, Some s }
| s = parameters_and_results_without_bindings
  { (None, Some s) }

import:
| LPAREN_IMPORT module_ = name name = name desc = external_type ")"
    { let (id, desc) = desc in
      with_loc $sloc (Import {module_; name; id; desc; exports = [] }) }
| LPAREN_IMPORT module_ = name elems = nonempty_list(import_group_elem) ")"
    { with_loc $sloc (compact_import $sloc module_ elems) }

import_group_elem:
| "(" ITEM id = ioption(ID) name = name t = ioption(external_type) ")"
    { `Item (id, name, t) }
| e = external_type { `Type e }

external_type:
| "(" FUNC i = ID ? t = type_use ")"
    { (i, Func { exact = false; typ = t }) }
| "(" FUNC i = ID ? "(" EXACT t = type_use ")" ")"
    { (i, Func { exact = true; typ = t }) }
| "(" MEMORY i = ID ? l = memory_type ")"
    { (i, (Memory l)) }
| "(" TABLE i = ID ? t = table_type ")"
    { (i, (Table t)) }
| "(" GLOBAL i = ID ? t = global_type ")"
    { (i, (Global t)) }
| "(" TAG i = ID ? t = type_use ")"
    { (i, (Tag t : importdesc)) }

func:
| "(" FUNC id = ID ? exports = exports typ = type_use
   locals = locals instrs = instructions ")"
  { with_loc $sloc (Func {id; typ; locals; instrs; exports}) }
| "(" FUNC id = ID ?
  exports = exports LPAREN_IMPORT module_ = name name = name ")"
  t = type_use ")"
  { with_loc $sloc
      (Import {module_; name; id; desc = Func { exact = false; typ = t }; exports }) }
| "(" FUNC id = ID ?
  exports = exports LPAREN_IMPORT module_ = name name = name ")"
  "(" EXACT t = type_use ")" ")"
  { with_loc $sloc
      (Import {module_; name; id; desc = Func { exact = true; typ = t }; exports }) }

exports:
| { [] }
| LPAREN_EXPORT n = name ")" r = exports { n :: r }

locals:
| { [] }
| l = local_decl r = locals { l @ r }

(* One [(local …)] declaration. Kept a separate nonterminal so its [$sloc] spans
   just this declaration — a rule that also matched the following [locals] would
   stretch the span (and an anonymous local's diagnostic, which has no name to
   point at) across every later local. *)
local_decl:
| LPAREN_LOCAL i = ID t = value_type ")"
  { [ with_loc $sloc (Some i, t) ] }
(* As for fields, only the single-local case gets a comment-anchoring
   location; an anonymous (local t1 t2 ...) shares one span. *)
| LPAREN_LOCAL l = value_type * ")"
  { match l with
    | [ t ] -> [ with_loc $sloc (None, t) ]
    | _ -> List.map (fun t -> Ast.no_loc (None, t)) l }

memory:
| "(" MEMORY id = ID? exports = exports limits = memory_type ")"
  { with_loc $sloc (Memory {id; limits; init = None; exports}) }
| "(" MEMORY id = ID?
  exports = exports at = ioption(address_type) ps = ioption(pagesize_clause)
  "(" DATA s = data_string ")" ")"
  { let address_type = Option.value ~default:`I32 at in
    let data_len = Misc.dataval_byte_length s in
    (* Size in whole pages of the (custom or default) page size. *)
    let page_bits = match ps with Some p -> p | None -> 16 in
    let page_mask = (1 lsl page_bits) - 1 in
    let sz = Uint64.of_int ((data_len + page_mask) lsr page_bits) in
    let limits =
      Ast.no_loc
        {mi = sz; ma = Some sz; address_type; page_size_log2 = ps;
         shared = false} in
    with_loc $sloc (Memory {id; limits; init = Some s; exports}) }
| "(" MEMORY id = ID ?
  exports = exports LPAREN_IMPORT module_ = name name = name ")" t = memory_type ")"
  { with_loc $sloc (Import {module_; name; id; desc = Memory t; exports}) }

table:
| "(" TABLE id = ID? exports = exports typ = table_type e = expression ")"
  { let init = if e = [] then Init_default else Init_expr e in
    with_loc $sloc (Table {id; typ; init; exports}) }
| "(" TABLE id = ID?
  exports = exports at = ioption(address_type) reftype = reference_type
  "(" ELEM elem = list(elemexpr) ")" ")"
  { let address_type = Option.value ~default:`I32 at in
    let len = Uint64.of_int (List.length elem) in
    let limits =
      Ast.no_loc {mi=len; ma =Some len; address_type; page_size_log2 = None; shared = false} in
    with_loc $sloc
      (Table {id; typ = {limits; reftype};
              init = Init_segment elem; exports}) }
| "(" TABLE id = ID?
  exports = exports at = ioption(address_type) reftype = reference_type
  "(" ELEM elem = list_of_indices ")" ")"
  { let address_type = Option.value ~default:`I32 at in
    let len = Uint64.of_int (List.length elem) in
    let elem = List.map (fun i -> [{i with Ast.desc = RefFunc i}]) elem in
    let limits =
      Ast.no_loc {mi=len; ma =Some len; address_type; page_size_log2 = None; shared = false} in
    with_loc $sloc
      (Table {id; typ = { limits; reftype };
              init = Init_segment elem; exports}) }
| "(" TABLE id = ID ?
  exports = exports LPAREN_IMPORT module_ = name name = name ")"
  t = table_type ")"
  { with_loc $sloc (Import {module_; name; id; desc = Table t; exports }) }

tag:
| "(" TAG id = ID ? exports = exports typ = type_use ")"
    { with_loc $sloc (Tag {id; typ; exports}) }
| "(" TAG id = ID ?
  exports = exports LPAREN_IMPORT module_ = name name = name ")"
  typ = type_use")"
  { with_loc $sloc (Import {module_; name; id; desc = Tag typ; exports }) }

global:
| "(" GLOBAL id = ID ? exports = exports typ = global_type init = expression ")"
  { with_loc $sloc (Global {id; typ; init; exports}) }
| "(" GLOBAL id = ID ?
  exports = exports LPAREN_IMPORT module_ = name name = name ")"
  typ = global_type ")"
  { with_loc $sloc (Import {module_; name; id; desc = Global typ; exports }) }

global_type:
| typ = value_type { {mut = false; typ} }
| "(" MUT typ = value_type ")" { {mut = true; typ} }

export:
| LPAREN_EXPORT name = name d = extern_index ")"
  { let (index, kind) = d in
    with_loc $sloc (Export {name; kind; index}) }

extern_index:
| "(" FUNC i = index ")" { (i, Func) }
| "(" GLOBAL i = index ")" { (i, Global) }
| "(" MEMORY i = index ")" { (i, Memory) }
| "(" TABLE i = index ")" { (i, Table) }
| "(" TAG i = index ")" { (i, (Tag : exportable)) }

start:
| "(" START i = index ")" { with_loc $sloc (Start i) }

elem:
| "(" ELEM id = ID ? l = element_list ")"
  { let (typ, init) = l in
    with_loc $sloc (Elem {id; mode = Passive; typ; init}) }
| "(" ELEM id = ID ? t = tableuse o = offset l = element_list ")"
  { let (typ, init) = l in
    with_loc $sloc (Elem {id; mode = Active (t, o); typ; init}) }
| "(" ELEM id = ID ? DECLARE l = element_list ")"
  { let (typ, init) = l in
    with_loc $sloc (Elem {id; mode = Declare; typ; init}) }
| "(" ELEM id = ID ? o = offset init = list(index) ")"
  { let init = List.map (fun i -> [{i with Ast.desc = RefFunc i}]) init in
    with_loc $sloc
      (Elem {id; mode = Active (Ast.no_loc (Num Uint32.zero), o);
             typ = { nullable = false ; typ = Func }; init}) }

element_list:
| t = reference_type l = elemexpr * { (t, l) }
| FUNC l = list(index)
  { let l = List.map (fun i -> [{i with Ast.desc = RefFunc i}]) l in
    ({nullable = false; typ = Func}, l) }

elemexpr:
| "(" ITEM  e = expression ")" { e }
| instr = folded_instruction { [instr] }

%inline tableuse:
| "(" TABLE i = index ")" { i }
| { with_loc $sloc (Num Uint32.zero) }

data:
| "(" DATA id = ID ? init = data_string ")"
  { with_loc $sloc (Data { id; init; mode = Passive }) }
| "(" DATA id = ID ? m = memuse e = offset init = data_string ")"
  { with_loc $sloc (Data { id; init; mode = Active (m, e) }) }

offset:
| "(" OFFSET e = expression ")" { e }
| instr = folded_instruction { [instr] }

(* A data segment's contents (WAT numeric-values proposal): a sequence of byte
   strings, typed numeric runs [(i16 -1 2)], and [v128] constant runs. Values are
   kept as raw literal strings; they are range-checked here and encoded little-
   endian at lowering. *)
data_string:
| l = list(data_elem) { l }

data_elem:
| s = STRING { { s with Ast.desc = Str s.Ast.desc } }
| "(" t = PACKEDTYPE l = list(int_lit) ")"
  { List.iter
      (check_constant (match t with I8 -> Misc.is_int8 | I16 -> Misc.is_int16) $sloc)
      l;
    with_loc $sloc (Numlist (Packed t, l)) }
| "(" I32 l = list(int_lit) ")"
  { List.iter (check_constant Misc.is_int32 $sloc) l;
    with_loc $sloc (Numlist (Value I32, l)) }
| "(" I64 l = list(int_lit) ")"
  { List.iter (check_constant Misc.is_int64 $sloc) l;
    with_loc $sloc (Numlist (Value I64, l)) }
| "(" F32 l = list(float_lit) ")"
  { List.iter (check_constant Misc.is_float32 $sloc) l;
    with_loc $sloc (Numlist (Value F32, l)) }
| "(" F64 l = list(float_lit) ")"
  { List.iter (check_constant Misc.is_float64 $sloc) l;
    with_loc $sloc (Numlist (Value F64, l)) }
| "(" V128 l = nonempty_list(v128_const_body) ")"
  { with_loc $sloc (V128list l) }

int_lit:
| n = NAT { n }
| n = INT { n }

float_lit:
| f = NAT { f }
| f = INT { f }
| f = FLOAT { f }

v128_const_body:
| I8X16 c0=i8 c1=i8 c2=i8 c3=i8 c4=i8 c5=i8 c6=i8 c7=i8
        c8=i8 c9=i8 c10=i8 c11=i8 c12=i8 c13=i8 c14=i8 c15=i8
  { {V128.shape = I8x16;
     components = [c0;c1;c2;c3;c4;c5;c6;c7;c8;c9;c10;c11;c12;c13;c14;c15]} }
| I16X8 c0=i16 c1=i16 c2=i16 c3=i16 c4=i16 c5=i16 c6=i16 c7=i16
  { {V128.shape = I16x8; components = [c0;c1;c2;c3;c4;c5;c6;c7]} }
| I32X4 c0=i32 c1=i32 c2=i32 c3=i32
  { {V128.shape = I32x4; components = [c0;c1;c2;c3]} }
| I64X2 c0=i64 c1=i64 { {V128.shape = I64x2; components = [c0;c1]} }
| F32X4 c0=f32 c1=f32 c2=f32 c3=f32
  { {V128.shape = F32x4; components = [c0;c1;c2;c3]} }
| F64X2 c0=f64 c1=f64 { {V128.shape = F64x2; components = [c0;c1]} }

%inline memuse:
| "(" MEMORY i = index ")" { i }
| { with_loc $sloc (Num Uint32.zero) }

globalstring:
| STRING_ANNOT id = ID typ = option(index) init = string_list ")"
  { with_loc $sloc (String_global {id; typ; init}) }

module_field:
| f = rectype
| f = import
| f = func
| f = tag
| f = memory
| f = table
| f = global
| f = export
| f = start
| f = elem
| f = data
| f = globalstring
| f = cond_module_field
  { f }

cond_then_fields:
| THEN_ANNOT then_fields = list(module_field) ")" { with_loc $sloc then_fields }

cond_else_fields:
| ELSE_ANNOT e = list(module_field) ")" { with_loc $sloc e }

cond_module_field:
| IF_ANNOT c = cond
  then_fields = cond_then_fields
  else_fields = option(cond_else_fields)
  ")"
  { with_loc $sloc
      (Module_if_annotation { cond = c; then_fields; else_fields }) }

parse:
| "(" MODULE name = ID ? l = module_field * ")" EOF
  { (name, l) }
| l = module_field * EOF
  { (None, l) }

parse_script:
| s = script EOF { s }
| inline_module EOF { [] }

script:
| c = cmd* { List.concat c }

inline_module:
| l = module_field + { [(`Valid, `Parsed (None, l))] }

cmd:
| m = module_ { m `Valid }
| instance { [] }
| register { [] }
| action { [] }
| thread { [] }
| wait { [] }
| c = assertion { c }
| c = meta { c }

(* The threads test format wraps modules/actions in [(thread $T (shared (module
   $M)) …)] with [(wait $T)] barriers. We don't run threads, so both are parsed
   and ignored (their inner modules are not tested). *)
thread:
| "(" THREAD ID? ioption(shared_clause) cmd* ")" {}

shared_clause:
| "(" SHARED nonempty_list("(" MODULE ID ")" {}) ")" {}

wait:
| "(" WAIT ID? ")" {}


module_:
| "(" MODULE DEFINITION ? name = ID ? l = module_field * ")"
  { fun status -> [(status, `Parsed (name, l))] }
| "(" MODULE DEFINITION ? ID ? BINARY s = STRING *  ")"
  { fun status ->
    [(status, `Binary (Wax_utils.Ast.concat_desc s))] }
| "(" MODULE DEFINITION ? ID ? QUOTE s = STRING *  ")"
  { fun status ->
    [(status, `Text (String.concat "\n" (List.map (fun s -> s.Ast.desc) s)))] }

script_instance:
| instance { fun _ -> [] }
| m = module_ { m }

instance:
| "(" MODULE INSTANCE option(ID ID ? {}) ")" { }

register:
| "(" REGISTER STRING ID ? ")" {}

action:
| "(" INVOKE ID ? STRING const * ")"
| "(" GET ID? STRING ")"
{}

const:
| "(" I32_CONST i32 ")"
| "(" I64_CONST i64 ")"
| "(" F32_CONST f32 ")"
| "(" F64_CONST f64 ")"
| "(" V128_CONST vec_shape f64+ ")"
| "(" REF_NULL heap_type ")"
| "(" REF_HOST NAT ")"
| "(" REF_EXTERN NAT ")"
{}

vec_shape:
| I8X16
| I16X8
| I32X4
| I64X2
| F32X4
| F64X2
| V128
{}

assertion:
| "(" ASSERT_RETURN action result_pat* ")" { [] }
| "(" ASSERT_RETURN_NAN action ")" { [] }
| "(" ASSERT_EXCEPTION action ")" { [] }
| "(" ASSERT_SUSPENSION action STRING ")" { [] }
| "(" ASSERT_TRAP action STRING ")" { [] }
| "(" ASSERT_EXHAUSTION action STRING ")" { [] }
| "(" ASSERT_MALFORMED m = module_ r = STRING ")"
  { m (`Malformed ((fun s -> s.Ast.desc) r)) }
| "(" ASSERT_INVALID m = module_ r = STRING ")"
  { m (`Invalid ((fun s -> s.Ast.desc) r)) }
(* The [_custom] variants (reference-interpreter custom-section tests) assert
   malformedness / invalidity arising from a custom section — for our purposes
   the module must still be rejected, exactly like the base assertions. *)
| "(" ASSERT_MALFORMED_CUSTOM m = module_ r = STRING ")"
  { m (`Malformed ((fun s -> s.Ast.desc) r)) }
| "(" ASSERT_INVALID_CUSTOM m = module_ r = STRING ")"
  { m (`Invalid ((fun s -> s.Ast.desc) r)) }
| "(" ASSERT_UNLINKABLE m = script_instance STRING ")" { m `Valid }
| "(" ASSERT_TRAP m = script_instance STRING ")" { m `Valid }

float_or_nan: f64 | NAN {}

result_pat:
| "(" I32_CONST i32 ")"
| "(" I64_CONST i64 ")"
| "(" F32_CONST f32 ")"
| "(" F32_CONST NAN ")"
| "(" F64_CONST f64 ")"
| "(" F64_CONST NAN ")"
| "(" V128_CONST vec_shape float_or_nan+ ")"
| "(" REF ")"
| "(" REF_NULL ")"
| "(" REF_FUNC ")"
| "(" REF_EXTERN ")"
| "(" REF_STRUCT ")"
| "(" REF_ARRAY ")"
| "(" REF_NULL heap_type ")"
| "(" REF_HOST NAT ")"
| "(" REF_EXTERN NAT ")"
| "(" INSTR (*RefI31*) ")"
| "(" EITHER result_pat+ ")"
{}

meta:
| "(" SCRIPT ID? s = script ")" { s }
| "(" INPUT ID? STRING ")" { [] }
| "(" OUTPUT ID? STRING? ")" { [] }
