(*
TODO:
- locations on the heap when push several values?
- desugar by default? (or option)
- utf-16 string / js strings

Syntax changes:
- names in result type (symmetry with params)
- no need to have func type for tags (declaration tag : ty)

Misc:
- blocks in an expression context return one value;
  otherwise, no value by default
  (or infer return type when no type is given?)
*)

open Ast
module Cond = Wax_wasm.Cond_solver

type typed_module_annotation = Ast.storagetype option array * Ast.location

open Infer

module Error = struct
  open Wax_utils

  let print_name f x = Format.fprintf f "'%s'" x.desc

  (* All errors share the same envelope: severity [Error], a formatted message,
     and an optional hint. [report] captures that boilerplate so each error
     below is just its message (and, where relevant, a hint). *)
  let report ?hint ?related context ~location fmt =
    Format.kdprintf
      (fun msg ->
        Diagnostic.report context ~location ~severity:Error ?hint ?related
          ~message:(fun f () -> msg f)
          ())
      fmt

  (* Warnings share the same envelope as [report] but with severity [Warning],
     so they are printed without aborting the pass. [warning] names the warning
     so its level can be configured (see {!Wax_utils.Warning}). *)
  let warn ?warning ?universal ?hint ?related context ~location fmt =
    Format.kdprintf
      (fun msg ->
        Diagnostic.report context ~location ~severity:Warning ?warning
          ?universal ?hint ?related
          ~message:(fun f () -> msg f)
          ())
      fmt

  (* A local declared by a [let] but never read. Prefix its name with [_] to
     silence the warning. *)
  let unused_local context ~location name =
    warn ~warning:Wax_utils.Warning.Unused_local ~universal:true context
      ~location "The local variable %a is never used." print_name name

  let empty_stack context ~location =
    report context ~location "The stack is empty."

  let let_in_conditional context ~location =
    report context ~location
      "A let binding is not allowed inside a conditional annotation; declare \
       the local before the conditional."

  let non_empty_stack context ~location output_stack =
    report context ~location "Some values remain on the stack:%a" output_stack
      ()

  (* Report the values still on the stack by pointing a caret at each of them.
     [location] carries the topmost value; [related] the others. *)
  let leftover_values context ~location ~related =
    report context ~location ~related
      (if related = [] then "This value remains on the stack."
       else "These values remain on the stack.")

  let expected_func_type context ~location =
    report context ~location "Expected function type."

  let inline_function_type_mismatch context ~location =
    report context ~location
      "The inline function type does not match the type definition."

  let expected_struct_type context ~location =
    report context ~location "Expected struct type."

  let expected_array_type context ~location =
    report context ~location "Expected array type."

  (* An operation (a call, a field/array access, …) needs its operand's concrete
     type to be compiled, but the operand's type is unknown: it was taken off the
     polymorphic stack of unreachable or branch-terminated code. This is the
     first error for the operand (an already-failed operand reads as the [Error]
     type and stays silent), so it is reported here. *)
  let unknown_operand_type context ~location =
    report context ~location
      "Cannot determine the type of this expression, which is needed to \
       compile this operation."

  (* A struct literal omitted its type name in a position where the expected
     type does not pin an exact struct type, so the type cannot be inferred. *)
  let cannot_infer_struct_type context ~location =
    report context ~location
      "Cannot infer the struct type here; add an explicit type, as in '{T| \
       ..}'."

  let cannot_infer_array_type context ~location =
    report context ~location
      "Cannot infer the array type here; add an explicit type, as in '[T| ..]'."

  let method_needs_parentheses context ~location name =
    report context ~location
      "'%s' is an instruction method and must be called with parentheses, as \
       '%s()'."
      name name

  let type_mismatch context ~location ty' ty =
    report context ~location
      "Expecting type@ @[<2>%a@]@ but got type@ @[<2>%a@]." output_inferred_type
      ty output_inferred_type ty'

  let not_an_expression context ~location n =
    report context ~location
      "An expression is expected here. This instruction returns %d values." n

  let binop_type_mismatch context ~location ty1 ty2 =
    report context ~location
      "This operator cannot be applied to operands of types@ @[<2>%a@]@ and@ \
       @[<2>%a@]."
      output_inferred_type ty1 output_inferred_type ty2

  let instruction_type_mismatch context ~location ty ty' =
    report context ~location
      "This instruction has type@ @[<2>%a@]@ but is expected to have type@ \
       @[<2>%a@]."
      output_inferred_type ty output_inferred_type ty'

  let value_count_mismatch context ~location ~expected ~provided =
    report context ~location
      "This instruction provides %d value(s) but %d was/were expected." provided
      expected

  let invalid_method_receiver context ~location ty =
    report context ~location
      "This operation cannot be applied to a value of type@ @[<2>%a@]."
      output_inferred_type ty

  let if_without_else context ~location =
    report context ~location
      "This 'if' must produce a value and so requires an 'else' branch."

  let parameterized_block_expression context ~location =
    report context ~location
      "A block, loop or if used as an expression cannot take parameters."

  let uninitialized_local context ~location name =
    report context ~location "The local variable %a has not been initialized."
      print_name name

  let non_nullable_table context ~location =
    report context ~location
      "A table with a non-nullable element type must have an initializer."

  let start_function_signature context ~location =
    report context ~location
      "The start function must have no parameters and no results."

  let multiple_start context ~location =
    report context ~location "A module can have at most one start function."

  let unknown_annotation context ~location name =
    report context ~location "Unknown annotation %S." name

  let annotation_value_mismatch context ~location name expected =
    report context ~location "The %s annotation expects %s." name expected

  let annotation_not_allowed context ~location name =
    report context ~location "The %s annotation is not allowed here." name

  let declaration_without_import context ~location =
    report context ~location
      "This declaration has no definition; it needs an import annotation."

  let multiple_import context ~location =
    report context ~location "A field can have at most one import annotation."

  let final_supertype context ~location name =
    report context ~location
      "The type %a is final and cannot be extended; declare it 'open'."
      print_name name

  let invalid_subtype context ~location name =
    report context ~location "This type is not a valid subtype of %a."
      print_name name

  (* A secondary caret at [location] labelled with an inferred value type. Used
     to point at each branch of an [if]/select whose branches are in
     incompatible type hierarchies: there is no common supertype — and, unlike a
     checked position which can name one expected type, no annotation that would
     reconcile them — so we just show what each branch produces. *)
  let typed_branch_label location ty =
    {
      Wax_utils.Diagnostic.location;
      message =
        (fun f () -> Format.fprintf f "@[<2>%a@]" output_inferred_type ty);
    }

  let select_type_mismatch context ~location ~loc1 ~loc2 ty1 ty2 =
    report context ~location
      ~related:[ typed_branch_label loc1 ty1; typed_branch_label loc2 ty2 ]
      "The two branches of this select have no common supertype, so its result \
       type cannot be inferred."

  let if_branch_type_mismatch context ~location ~loc1 ~loc2 ty1 ty2 =
    report context ~location
      ~related:[ typed_branch_label loc1 ty1; typed_branch_label loc2 ty2 ]
      "The branches of this if produce values with no common supertype, so its \
       result type cannot be inferred."

  (* As [if_branch_type_mismatch], but for a [do]/labelled block whose exit
     values (a fall-through and/or values branched to its label) do not join. *)
  let block_exit_type_mismatch context ~location ~loc1 ~loc2 ty1 ty2 =
    report context ~location
      ~related:[ typed_branch_label loc1 ty1; typed_branch_label loc2 ty2 ]
      "The values reaching this block's exit have no common supertype, so its \
       result type cannot be inferred."

  let name_already_bound context ~location kind x =
    report context ~location "A %s named %a is already bound." kind print_name x

  let did_you_mean suggestions =
    match List.rev suggestions with
    | [] -> None
    | last :: rest ->
        let rest = List.rev rest in
        let pp f = Format.fprintf f "%s" in
        Some
          (fun f () ->
            Format.fprintf f "Did@ you@ mean@ %a%s%a?"
              (Format.pp_print_list
                 ~pp_sep:(fun f () -> Format.fprintf f ",@ ")
                 pp)
              rest
              (if rest = [] then "" else " or ")
              pp last)

  let unbound_name context ~location ?(suggestions = []) kind x =
    report ?hint:(did_you_mean suggestions) context ~location
      "The %s %a is not bound." kind print_name x

  let before_hole context ~location =
    report context ~location "This expression occurs before a hole '_'."

  let duplicated_field context ~location x =
    report context ~location "Several fields have the same name %a." print_name
      x

  let duplicated_parameter context ~location x =
    report context ~location "Several parameters have the same name %a."
      print_name x

  let constant_expression_required context ~location =
    report context ~location "Only constant expressions are allowed here."

  let memory_offset_too_large context ~location max_offset =
    report context ~location "The memory offset should be less than 0x%Lx."
      (Wax_utils.Uint64.to_int64 max_offset)

  let memory_align_too_large context ~location natural =
    report context ~location
      "The memory alignment is larger than the natural alignment %d." natural

  let memory_immediate_too_large context ~location =
    report context ~location
      "This memory offset or alignment must fit a 64-bit unsigned integer."

  let bad_memory_align context ~location =
    report context ~location "The memory alignment should be a power of two."

  let invalid_lane_index context ~location max_lane =
    report context ~location "The lane index should be less than %d." max_lane

  let lane_value_out_of_range context ~location bits =
    report context ~location "The lane value does not fit in %d bits." bits

  let limit_too_large context ~location kind max =
    report context ~location
      "The %s size is too large. It should be less than 0x%Lx." kind
      (Wax_utils.Uint64.to_int64 max)

  let limit_mismatch context ~location kind =
    report context ~location
      "The %s maximum size should be larger than the minimal size." kind

  let duplicated_export context ~location name =
    report context ~location "There is already an export of name %S." name

  let invalid_cast_type context ~location =
    report context ~location
      "Continuation types cannot be used in a cast instruction."

  let stack_switching_type_mismatch context ~location ~descr =
    report context ~location
      "Type mismatch in this stack switching instruction:@ %s." descr

  let constant_global_required context ~location =
    report context ~location "Only accessing a constant global is allowed here."

  let immutable context ~location what =
    report context ~location "This %s is immutable and cannot be assigned." what

  let not_assignable context ~location x =
    report context ~location "%a cannot be assigned." print_name x

  let field_count_mismatch context ~location ~expected ~provided =
    report context ~location
      "This structure provides %d field(s) but %d was/were expected." provided
      expected

  let missing_field context ~location x =
    report context ~location "There is no field named %a." print_name x

  let invalid_cast context ~location ty' =
    report context ~location
      "This value of type@ @[<2>%a@]@ cannot be cast to the target type."
      output_inferred_type ty'

  let tag_with_results context ~location =
    report context ~location "An exception tag cannot have result values."

  let catch_target_mismatch context ~location provided expected =
    report context ~location
      "Catching this exception provides a value of type@ @[<2>%a@]@ but the \
       handler's branch target expects@ @[<2>%a@]."
      output_inferred_type provided output_inferred_type expected

  let not_defaultable context ~location =
    report context ~location
      "This type has no default value for all its fields."

  let incompatible_array_elements context ~location =
    report context ~location
      "The source and destination array element types are incompatible."

  let incompatible_element_type context ~location provided expected =
    report context ~location
      "The element type@ @[<2>%a@]@ is not compatible with the expected \
       element type@ @[<2>%a@]."
      output_inferred_type provided output_inferred_type expected

  let invalid_string_element_type context ~location =
    report context ~location
      "A string literal can only build an array with numeric or packed \
       elements."

  let expected_ref context ~location =
    report context ~location "A reference type is expected here."

  let dispatch_duplicate_arm context ~location x =
    report context ~location "This dispatch has several cases named %a."
      print_name x
end

module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

let ( let*@ ) = Option.bind
let ( let+@ ) o f = Option.map f o
let ( let>@ ) o f = Option.iter f o

(* Names are resolved relative to a "current assumption" — the conjunction of
   the conditional-branch conditions enclosing the point being typed. The cell
   is shared by every namespace and table of one module typing, and updated as
   the passes descend into [#[if]]/[#[else]] branches. When no conditionals are
   present (or when checking a single specialized configuration) it stays
   [true_] and these structures behave like plain name-keyed tables. *)
module Namespace = struct
  type t = {
    cond : Cond.t ref;
    tbl : (string, (string * location * Cond.t) list) Hashtbl.t;
  }

  let make cond = { cond; tbl = Hashtbl.create 16 }
  let entries ns x = try Hashtbl.find ns.tbl x.desc with Not_found -> []

  (* A name conflicts with an earlier declaration only if their assumptions can
     both hold; declarations in mutually-exclusive branches do not conflict. *)
  let conflict ns x =
    let c = !(ns.cond) in
    List.find_opt
      (fun (_, _, c') -> Cond.is_satisfiable (Cond.and_ c c'))
      (entries ns x)

  let register d ns kind x =
    (match conflict ns x with
    | Some (kind', _, _) -> Error.name_already_bound d ~location:x.info kind' x
    | None -> ());
    Hashtbl.replace ns.tbl x.desc ((kind, x.info, !(ns.cond)) :: entries ns x)

  let exists d ns x =
    match conflict ns x with
    | Some (kind', _, _) ->
        Error.name_already_bound d ~location:x.info kind' x;
        true
    | None -> false
end

module Tbl = struct
  type 'a t = {
    kind : string;
    namespace : Namespace.t;
    tbl : (string, (Cond.t * 'a) list) Hashtbl.t;
  }

  let make namespace kind = { kind; namespace; tbl = Hashtbl.create 16 }
  let cur env = !(env.namespace.cond)
  let entries env x = try Hashtbl.find env.tbl x.desc with Not_found -> []

  let add d env x v =
    Namespace.register d env.namespace env.kind x;
    Hashtbl.replace env.tbl x.desc ((cur env, v) :: entries env x)

  let exists d env x = Namespace.exists d env.namespace x

  (* Replace the most recently added entry (added by [add] under the current
     assumption); used by [add_type] to fix up rectype indices in place. *)
  let override env x v =
    match entries env x with
    | _ :: tl -> Hashtbl.replace env.tbl x.desc ((cur env, v) :: tl)
    | [] -> Hashtbl.replace env.tbl x.desc [ (cur env, v) ]

  (* Pick the declaration whose assumption is entailed by the current one,
     falling back to one merely compatible with it, then to the most recent. *)
  let resolve env x =
    match entries env x with
    | [] -> None
    | [ (_, v) ] -> Some v
    | l -> (
        let c = cur env in
        let pick p = Option.map snd (List.find_opt (fun (c', _) -> p c') l) in
        match pick (fun c' -> Cond.logical_implies c c') with
        | Some _ as r -> r
        | None -> (
            match pick (fun c' -> Cond.is_satisfiable (Cond.and_ c c')) with
            | Some _ as r -> r
            | None -> ( match l with (_, v) :: _ -> Some v | [] -> None)))

  let find d env x =
    match resolve env x with
    | Some _ as r -> r
    | None ->
        let suggestions =
          Wax_utils.Spell_check.f
            (fun f -> Hashtbl.iter (fun k _ -> f k) env.tbl)
            x.desc
        in
        Error.unbound_name d ~location:x.info ~suggestions env.kind x;
        None

  let find_opt env x = resolve env x

  let iter env f =
    Hashtbl.iter (fun k l -> List.iter (fun (_, v) -> f k v) l) env.tbl

  (* Drop the most recently added entry (the temporary [add_type] placeholder),
     keeping any declaration of the same name from another branch. *)
  let remove env x =
    match entries env x with
    | _ :: (_ :: _ as tl) -> Hashtbl.replace env.tbl x.desc tl
    | _ -> Hashtbl.remove env.tbl x.desc
end

type types = (int * subtype) Tbl.t

type type_context = {
  internal_types : Wax_wasm.Types.t;
  types : (int * subtype) Tbl.t;
}

let get_type_definition d types nm = Option.map snd (Tbl.find d types nm)

let resolve_type_name d ctx name =
  let+@ res = Tbl.find d ctx.types name in
  fst res

let heaptype d ctx (h : heaptype) : Internal.heaptype option =
  match h with
  | Func -> Some Func
  | NoFunc -> Some NoFunc
  | Exn -> Some Exn
  | NoExn -> Some NoExn
  | Cont -> Some Cont
  | NoCont -> Some NoCont
  | Extern -> Some Extern
  | NoExtern -> Some NoExtern
  | Any -> Some Any
  | Eq -> Some Eq
  | I31 -> Some I31
  | Struct -> Some Struct
  | Array -> Some Array
  | None_ -> Some None_
  | Type idx ->
      let+@ ty = resolve_type_name d ctx idx in
      (Type ty : Internal.heaptype)

let reftype d ctx { nullable; typ } =
  let+@ typ = heaptype d ctx typ in
  { Internal.nullable; typ }

let valtype d ctx ty : Internal.valtype option =
  match ty with
  | I32 -> Some I32
  | I64 -> Some I64
  | F32 -> Some F32
  | F64 -> Some F64
  | V128 -> Some V128
  | Ref r ->
      let+@ ty = reftype d ctx r in
      (Ref ty : Internal.valtype)

(* Like [Array.map] into an option, returning [None] as soon as [f] returns
   [None] on any element (so [let*!] propagates a single failure). *)
let array_map_opt f arr =
  let exception Short_circuit in
  try
    let result =
      Array.init (Array.length arr) (fun i ->
          match f arr.(i) with Some v -> v | None -> raise Short_circuit)
    in
    Some result
  with Short_circuit -> None

let array_mapi_opt f arr =
  let exception Short_circuit in
  try
    let result =
      Array.init (Array.length arr) (fun i ->
          match f i arr.(i) with Some v -> v | None -> raise Short_circuit)
    in
    Some result
  with Short_circuit -> None

(* Report any parameter name used more than once in a signature. *)
let check_unique_param_names d params =
  ignore
    (Array.fold_left
       (fun s p ->
         match fst p.desc with
         | None -> s
         | Some name ->
             if StringSet.mem name.desc s then
               Error.duplicated_parameter d ~location:name.info name;
             StringSet.add name.desc s)
       StringSet.empty params
      : StringSet.t)

let functype d ctx { params; results } =
  check_unique_param_names d params;
  let*@ params = array_map_opt (fun p -> valtype d ctx (snd p.desc)) params in
  let+@ results = array_map_opt (fun ty -> valtype d ctx ty) results in
  { Internal.params; results }

let storagetype d ctx ty =
  match ty with
  | Value ty ->
      let+@ ty = valtype d ctx ty in
      (Value ty : Internal.storagetype)
  | Packed ty -> Some (Packed ty)

let muttype f d ctx { mut; typ } =
  let+@ typ = f d ctx typ in
  { mut; typ }

let fieldtype d ctx ty = muttype storagetype d ctx ty

let comptype d ctx (ty : comptype) =
  match ty with
  | Func ty ->
      let+@ ty = functype d ctx ty in
      (Func ty : Internal.comptype)
  | Struct fields ->
      let _ : StringSet.t =
        Array.fold_left
          (fun s field ->
            let name, _ = field.desc in
            if StringSet.mem name.desc s then
              Error.duplicated_field d ~location:name.info name;
            StringSet.add name.desc s)
          StringSet.empty fields
      in
      let+@ fields =
        array_map_opt (fun field -> fieldtype d ctx (snd field.desc)) fields
      in
      (Struct fields : Internal.comptype)
  | Array field ->
      let+@ field = fieldtype d ctx field in
      (Array field : Internal.comptype)
  | Cont idx ->
      let+@ ty = resolve_type_name d ctx idx in
      (Cont ty : Internal.comptype)

let subtype d ctx current { typ; supertype; final } =
  let*@ typ = comptype d ctx typ in
  let+@ supertype =
    match supertype with
    | None -> Some None
    | Some sup ->
        let+@ ty = resolve_type_name d ctx sup in
        (* A supertype must be declared before; a self-reference or a forward
           reference within the same rec group is treated as unbound, matching
           the validator (rather than crashing). *)
        if ty <= lnot current then
          Error.unbound_name d ~location:sup.info "type" sup;
        Some ty
  in
  { Internal.typ; supertype; final }

let rectype d ctx ty =
  array_mapi_opt (fun i elt -> subtype d ctx i (snd elt.desc)) ty

let add_type d ctx ty =
  Array.iteri
    (fun i elt ->
      let name, (typ : subtype) = elt.desc in
      Tbl.add d ctx.types name (lnot i, typ))
    ty;
  match rectype d ctx ty with
  | None ->
      (* Remove temporary names on failure *)
      Array.iter (fun elt -> Tbl.remove ctx.types (fst elt.desc)) ty;
      None
  | Some ity ->
      let i' = Wax_wasm.Types.add_rectype ctx.internal_types ity in
      Array.iteri
        (fun i elt ->
          let name, (typ : subtype) = elt.desc in
          Tbl.override ctx.types name (i' + i, typ))
        ty;
      Some i'

type module_context = {
  diagnostics : Wax_utils.Diagnostic.context;
  type_context : type_context;
  subtyping_info : Wax_wasm.Types.subtyping_info;
  types : (int * subtype) Tbl.t;
  functions : (int * string) Tbl.t;
  globals : (*mutable:*) (bool * inferred_valtype option) Tbl.t;
      (* As for [locals], the type is [None] for a global whose initializer
         failed to type — a poison global read as [Error] to avoid cascades. *)
  import_globals : (bool * inferred_valtype option) Tbl.t;
      (* The globals in scope for a table initializer: only the imported ones.
         A table is typed before the module's own globals are registered, so its
         initializer can reference only imports (unlike a global initializer,
         which sees the globals declared before it). *)
  tags : functype Tbl.t;
  memories : (int * [ `I32 | `I64 ]) Tbl.t;
  datas : unit Tbl.t;
  tables : ([ `I32 | `I64 ] * reftype) Tbl.t;
  elems : reftype Tbl.t;
  mutable locals : inferred_valtype option StringMap.t;
      (* The local's type, or [None] when it could not be determined because its
         initializer failed to type — an error-recovery "poison" local, read as
         the [Error] type so its uses don't cascade into further errors. *)
  warn_unused : bool;
      (* Whether to report locals declared by a [let] but never read. Enabled
         only when validation is requested. *)
  read_locals : StringSet.t ref;
      (* Names of locals read so far in the current function. A [ref] (rather
         than a snapshot field) so reads inside a block propagate to the
         function level. Reset per function. *)
  local_decls : ident list ref;
      (* The [let]-bound locals declared in the current function, in declaration
         order, so an unread one can be reported as unused. Reset per function. *)
  assigned_locals : StringSet.t;
      (* Names of locals assigned ([Set]/[Tee] targets) anywhere in the current
         function, collected once on entry (see [collect_assigned_locals]). Lets
         the annotation-drop on a fused [let x: T = e] tell a write-once local —
         which may narrow to [e]'s subtype just like an immutable global — from
         one a later assignment still needs the wider [T] for. Reset per
         function. *)
  mutable initialized_locals : StringSet.t;
      (* Locals known to hold a value at the current point. A non-defaultable
         (non-nullable reference) local starts uninitialized and must be
         assigned before it is read. The set is captured by [{ ctx with ... }]
         on block entry, so an assignment inside a block does not escape it. *)
  control_types : (string option * inferred_type UnionFind.t array) list;
  return_types : inferred_type UnionFind.t array;
  cond : Cond.t ref;
      (* Current branch assumption (shared with every namespace/table above);
         set while typing a conditional branch so names resolve per branch. *)
  cond_env : Cond.env;
  simplify : bool;
      (* Whether to rewrite the AST while typing: drop casts the inferred types
         make redundant and tighten [&?extern]/[&?any] casts to
         [&extern]/[&any]. Enabled only when converting from Wasm; for
         hand-written Wax (formatting, or compiling to Wasm) casts are kept as
         written. *)
  structs_by_fields : (string, ident option) Hashtbl.t;
      (* Maps a struct's canonical field-set key (see [field_set_key]) to the
         unique struct type with that field set, or [None] when several share
         it. Lets a struct literal whose name is omitted resolve from its fields
         alone (and the name be dropped when the fields make it unambiguous).
         Built once at module-context creation. *)
}

(* Type [f] under the assumption of a conditional branch ([positive] for
   [@then], negative for [@else]), restoring the previous assumption after. *)
let with_cond_ref cond_ref cond_env diagnostics ~location cond positive f =
  let saved = !cond_ref in
  let c = Cond.of_cond cond_env diagnostics ~location cond in
  cond_ref := Cond.and_ saved (if positive then c else Cond.not_ c);
  Fun.protect ~finally:(fun () -> cond_ref := saved) f

let with_cond ctx ~location cond positive f =
  with_cond_ref ctx.cond ctx.cond_env ctx.diagnostics ~location cond positive f

let lookup_func_type ?location ctx name =
  let*@ ty = Tbl.find_opt ctx.type_context.types name in
  match (snd ty).typ with
  | Func f -> Some f
  | Struct _ | Array _ | Cont _ ->
      Error.expected_func_type ctx.diagnostics
        ~location:(Option.value ~default:name.info location);
      None

let lookup_struct_type ?location ctx name =
  let*@ ty = Tbl.find_opt ctx.type_context.types name in
  match (snd ty).typ with
  | Struct fields -> Some fields
  | Func _ | Array _ | Cont _ ->
      Error.expected_struct_type ctx.diagnostics
        ~location:(Option.value ~default:name.info location);
      None

(* A canonical key for a set of field names, so two structs with the same fields
   (in any order) get the same key. Identifiers never contain a comma. *)
let field_set_key names = String.concat "," (List.sort_uniq compare names)

(* The unique struct type whose field-set matches the literal's [fields], or
   [None] when none or several do (then the type is ambiguous and must be
   named). O(#fields) given the precomputed [ctx.structs_by_fields] map. *)
let infer_struct_by_fields ctx fields =
  let key = field_set_key (List.map (fun (idx, _) -> idx.desc) fields) in
  match Hashtbl.find_opt ctx.structs_by_fields key with
  | Some (Some name) -> Some name
  | Some None | None -> None

let lookup_array_type ?location ctx name =
  let*@ ty = Tbl.find_opt ctx.type_context.types name in
  match (snd ty).typ with
  | Array field -> Some field
  | Func _ | Struct _ | Cont _ ->
      Error.expected_array_type ctx.diagnostics
        ~location:(Option.value ~default:name.info location);
      None

(* The composite type of a synthesized type (its name starting with ['<'], e.g.
   [<string>] or an inline function type) — used as the [inline] form of an
   [inferred_valtype] so a reference to it renders by that composite type rather
   than by its meaningless synthetic name. [None] for a source-named type. *)
let inline_comptype ctx (name : ident) =
  if name.desc <> "" && name.desc.[0] = '<' then
    Option.map
      (fun (_, (sub : subtype)) -> sub.typ)
      (Tbl.find_opt ctx.type_context.types name)
  else None

(* The name of the function type a continuation type wraps. *)
let lookup_cont_inner ?location ctx name =
  let*@ ty = Tbl.find_opt ctx.type_context.types name in
  match (snd ty).typ with
  | Cont ft -> Some ft
  | Func _ | Struct _ | Array _ ->
      Error.expected_func_type ctx.diagnostics
        ~location:(Option.value ~default:name.info location);
      None

let top_heap_type ctx (t : heaptype) : heaptype option =
  match t with
  | Any | Eq | I31 | Struct | Array | None_ -> Some Any
  | Func | NoFunc -> Some Func
  | Exn | NoExn -> Some Exn
  | Cont | NoCont -> Some Cont
  | Extern | NoExtern -> Some Extern
  | Type ty -> (
      let+@ ty = Tbl.find ctx.diagnostics ctx.types ty in
      match (snd ty).typ with
      | Struct _ | Array _ -> Any
      | Func _ -> Func
      | Cont _ -> Cont)

(* Whether a heap type belongs to the continuation hierarchy, without reporting
   an unbound reference (the caller's normal resolution handles that). *)
let is_cont_heaptype ctx (t : heaptype) =
  match t with
  | Cont | NoCont -> true
  | Type ty -> (
      match Tbl.find_opt ctx.types ty with
      | Some x -> ( match (snd x).typ with Cont _ -> true | _ -> false)
      | None -> false)
  | Any | Eq | I31 | Struct | Array | None_ | Func | NoFunc | Exn | NoExn
  | Extern | NoExtern ->
      false

let diff_ref_type t1 t2 =
  { nullable = t1.nullable && not t2.nullable; typ = t1.typ }

let storage_subtype ctx ty ty' =
  match (ty, ty') with
  | Packed I8, Packed I8 | Packed I16, Packed I16 -> true
  | Value ty, Value ty' ->
      Option.value ~default:true (* Do not generate a spurious error *)
        (let*@ ty = valtype ctx.diagnostics ctx.type_context ty in
         let+@ ty' = valtype ctx.diagnostics ctx.type_context ty' in
         Wax_wasm.Types.val_subtype ctx.subtyping_info ty ty')
  | Packed I8, Packed I16
  | Packed I16, Packed I8
  | Packed _, Value _
  | Value _, Packed _ ->
      false

let storage_subtype' ctx (ty : Wax_wasm.Ast.Binary.storagetype)
    (ty' : Wax_wasm.Ast.Binary.storagetype) =
  match (ty, ty') with
  | Packed I8, Packed I8 | Packed I16, Packed I16 -> true
  | Value ty, Value ty' -> Wax_wasm.Types.val_subtype ctx.subtyping_info ty ty'
  | Packed I8, Packed I16
  | Packed I16, Packed I8
  | Packed _, Value _
  | Value _, Packed _ ->
      false

let field_subtype info (ty : Wax_wasm.Ast.Binary.fieldtype)
    (ty' : Wax_wasm.Ast.Binary.fieldtype) =
  ty.mut = ty'.mut
  && storage_subtype' info ty.typ ty'.typ
  && ((not ty.mut) || storage_subtype' info ty'.typ ty.typ)

(* Whether the inferred type [ty] is a subtype of the expected type [ty'].
   Not a pure relation: when the two are compatible it *unifies* their
   union-find cells (so an as-yet-unconstrained literal like [Int]/[Number]
   gets pinned to the concrete type it is checked against). [Unknown] or [Error]
   on the left (dead code / error recovery) is a subtype of anything; neither
   appears on the right because expected types always come from a real
   declaration, annotation or instruction signature — hence the [assert]. *)
(* Whether [ty] is the result cell of a block whose type is being inferred. *)
let is_inferring ty =
  match UnionFind.find ty with Collecting _ -> true | _ -> false

let rec subtype ?location ctx ty ty' =
  let ity = UnionFind.find ty in
  let ity' = UnionFind.find ty' in
  match (ity, ity') with
  (* [ty'] is a block result being inferred. Record [ty]'s natural type — a
     snapshot taken before any validation below resolves it — as a value reaching
     the block's exit, to be joined later (see [block_infer_general]); pair it with
     [location] when the caller has one, so a join failure can point at the exit.
     When an annotation is under test ([declared]), also validate [ty] against it
     per-delivery and return that result, so a [br]/catch carrying the wrong type
     is reported precisely at its site rather than once, generically, at the join.
     A [Collecting] cell never appears as a real value type, so the left-hand
     cases below treat it like [Unknown]. *)
  | _, Collecting st -> (
      st.collected <- (location, UnionFind.make ity) :: st.collected;
      match st.declared with
      | Some d -> subtype ?location ctx ty d
      | None -> true)
  | Collecting _, _ -> true
  | Valtype ty, Valtype ty' ->
      Wax_wasm.Types.val_subtype ctx.subtyping_info ty.internal ty'.internal
  | Null, Null
  | Int, Int
  | Float, Float
  | Number, Number
  | (Int | Float | Valtype { internal = I32 | I64 | F32 | F64; _ }), Number
  | Valtype { internal = I32 | I64; _ }, Int
  | Valtype { internal = F32 | F64; _ }, Float ->
      UnionFind.merge ty ty' ity;
      true
  | Number, Valtype { internal = I32 | I64 | F32 | F64; _ }
  | Int, Valtype { internal = I32 | I64; _ }
  | Float, Valtype { internal = F32 | F64; _ }
  | Null, Valtype { internal = Ref { nullable = true; _ }; _ } ->
      UnionFind.merge ty ty' ity';
      true
  | ( Null,
      ( Number | Int | Float
      | Valtype
          {
            internal =
              I32 | I64 | F32 | F64 | V128 | Ref { nullable = false; _ };
            _;
          } ) )
  | Valtype _, Null
  | Valtype { internal = V128 | Ref _; _ }, Number
  | Valtype { internal = F32 | F64 | V128 | Ref _; _ }, Int
  | Valtype { internal = I32 | I64 | V128 | Ref _; _ }, Float
  | Number, (Null | Int | Float | Valtype { internal = V128 | Ref _; _ })
  | Int, (Null | Float | Valtype { internal = F32 | F64 | V128 | Ref _; _ })
  | Float, (Null | Int | Valtype { internal = I32 | I64 | V128 | Ref _; _ }) ->
      false
  (* LargeInt — a numeric literal too big for i32. It is a numeric literal like
     [Number] (so it can be a float — an integer-valued f32/f64 constant), only
     it can never be i32 and defaults to i64. Meeting it with Number or Int keeps
     LargeInt; with Float it narrows to Float; the concrete types it accepts are
     i64, f32 and f64. *)
  | LargeInt, (LargeInt | Number | Int) | (Number | Int), LargeInt ->
      UnionFind.merge ty ty' LargeInt;
      true
  | LargeInt, Float | Float, LargeInt ->
      UnionFind.merge ty ty' Float;
      true
  | LargeInt, Valtype { internal = I64 | F32 | F64; _ } ->
      UnionFind.merge ty ty' ity';
      true
  | Valtype { internal = I64 | F32 | F64; _ }, LargeInt ->
      UnionFind.merge ty ty' ity;
      true
  | LargeInt, (Null | Valtype _) | (Null | Valtype _), LargeInt -> false
  | (Int8 | Int16), _ | _, (Int8 | Int16) -> false
  | (Unknown | Error), _ -> true
  | _, (Unknown | Error) -> assert false

let cast ctx ty ty' =
  let ity = UnionFind.find ty in
  match (ity, ty') with
  | (Number | Int), Ref { typ = I31 | Extern; _ } ->
      UnionFind.set ty (Valtype { typ = I32; internal = I32; inline = None });
      true
  | (Number | Int), I32 | Int, F32 ->
      UnionFind.set ty (Valtype { typ = I32; internal = I32; inline = None });
      true
  | (Number | Int), I64 | Int, F64 ->
      UnionFind.set ty (Valtype { typ = I64; internal = I64; inline = None });
      true
  | (Number | Float), F32 | Float, I32 ->
      UnionFind.set ty (Valtype { typ = F32; internal = F32; inline = None });
      true
  | (Number | Float), F64 | Float, I64 ->
      UnionFind.set ty (Valtype { typ = F64; internal = F64; inline = None });
      true
  (* As with Int, a cast to a float is allowed (it converts from the integer);
     the literal is always i64 here since it is too big for i32. *)
  | LargeInt, (I64 | F32 | F64) ->
      UnionFind.set ty (Valtype { typ = I64; internal = I64; inline = None });
      true
  | LargeInt, _ -> false (* too big for i32; not v128 or a reference *)
  | Null, Ref { typ = ty'; _ } ->
      (let>@ typ = top_heap_type ctx ty' in
       let ty' = Ref { nullable = true; typ } in
       let>@ ity' = valtype ctx.diagnostics ctx.type_context ty' in
       UnionFind.set ty (Valtype { typ = ty'; internal = ity'; inline = None }));
      true
  | Valtype { internal = F32 | F64; _ }, (F32 | F64)
  | Valtype { internal = I32 | I64; _ }, I32
  | Valtype { internal = I64; _ }, I64
  | Valtype { internal = V128; _ }, V128
  (* [i32 as &i31] is [ref.i31]; [i64 as &i31] wraps to [i32] first. *)
  | Valtype { internal = I32 | I64; _ }, Ref { typ = I31; _ }
  (* [i32 as &extern]: [ref.i31] then [extern.convert_any]. *)
  | Valtype { internal = I32; _ }, Ref { typ = Extern; _ } ->
      true
  | Valtype { internal = Ref _ as ity; _ }, Ref { typ = ty'; nullable } -> (
      let sub a b = Wax_wasm.Types.val_subtype ctx.subtyping_info a b in
      Option.value ~default:true
        (let*@ typ = top_heap_type ctx ty' in
         let+@ ity' =
           valtype ctx.diagnostics ctx.type_context
             (Ref { nullable = true; typ })
         in
         sub ity ity')
      ||
      (*ZZZ Replace nullable by non nullable if possible *)
      match ty' with
      | Extern -> sub ity (Ref { nullable; typ = Any })
      | Any -> sub ity (Ref { nullable; typ = Extern })
      | _ ->
          (* [extern] <-> [any] across hierarchies, then a [ref.cast] to the
             concrete target. The [ref.cast] handles nullability, so only
             hierarchy membership is checked here. *)
          Option.value ~default:false
            (let+@ top = top_heap_type ctx ty' in
             (sub ity (Ref { nullable = true; typ = Extern }) && top = Any)
             || (sub ity (Ref { nullable = true; typ = Any }) && top = Extern)))
  | ( (Number | Int | Float | Valtype { internal = I32 | F32 | I64 | F64; _ }),
      ( Ref
          {
            typ =
              ( Func | NoFunc | Exn | NoExn | Cont | NoCont | Extern | NoExtern
              | Any | Eq | Array | Struct | Type _ | None_ );
            _;
          }
      | V128 ) )
  | Valtype { internal = F32 | F64; _ }, (I32 | I64)
  | Valtype { internal = I32 | I64; _ }, (F32 | F64)
  | Valtype { internal = I32; _ }, I64
  | ( (Float | Valtype { internal = F32 | F64 | V128; _ }),
      (I32 | Ref { typ = I31; _ }) )
  | (Null | Valtype { internal = Ref _; _ }), (I32 | I64 | F32 | F64 | V128)
  | Valtype { internal = V128; _ }, (I64 | F32 | F64 | Ref _)
  | (Int8 | Int16), _ ->
      false
  | (Unknown | Error | Collecting _), _ -> true

let signed_cast ctx ty ty' =
  let ity = UnionFind.find ty in
  match (ity, ty') with
  | (Int8 | Int16), (`I32 | `I64) -> true
  | Valtype { internal = Ref _ as ity; _ }, (`I32 | `I64) ->
      (* [i31.get] extracts an [i32]; [&ref as i64_X] widens it further. *)
      Wax_wasm.Types.val_subtype ctx.subtyping_info ity
        (Ref { nullable = true; typ = Any })
  | Null, `I32 ->
      UnionFind.set ty
        (Valtype
           {
             typ = Ref { typ = Any; nullable = true };
             internal = Ref { typ = Any; nullable = true };
             inline = None;
           });
      true
  | (Number | Int), `I64 ->
      UnionFind.set ty (Valtype { typ = I32; internal = I32; inline = None });
      true
  | LargeInt, `I64 ->
      UnionFind.set ty (Valtype { typ = I64; internal = I64; inline = None });
      true
  | LargeInt, _ ->
      false (* never i32; a signed cast to a float is rejected too *)
  | Valtype { internal = I32; _ }, `I64
  | Valtype { internal = I32 | I64; _ }, (`F32 | `F64)
  | Valtype { internal = F32 | F64; _ }, (`I32 | `I64) ->
      true
  | (Number | Int), (`I32 | `F32 | `F64) (* Floating types can make this fail *)
  | Valtype { internal = I32; _ }, `I32
  | Valtype { internal = I64; _ }, (`I32 | `I64)
  | Valtype { internal = F32 | F64; _ }, (`F32 | `F64)
  | (Int8 | Int16), (`F32 | `F64)
  | ( ( Null
      | Valtype
          {
            internal =
              Ref { typ = Type _ | None_ | Struct | Array | I31 | Eq | Any; _ };
            _;
          } ),
      (`I64 | `F32 | `F64) )
  | ( Valtype
        {
          internal =
            ( V128
            | Ref
                {
                  typ =
                    ( Func | NoFunc | Exn | NoExn | Cont | NoCont | Extern
                    | NoExtern );
                  _;
                } );
          _;
        },
      _ ) ->
      false
  (* A bare float literal carries the abstract [Float]; default it to its
     canonical f64 (like the concrete [F32 | F64] arms above) so a strict cast on
     it — e.g. [1.5 as i64_s_strict], the [i64.trunc_f64_s] a decompiled
     [f64.const] produces — type-checks instead of being rejected as float. *)
  | Float, (`I32 | `I64 | `F32 | `F64) ->
      UnionFind.set ty (Valtype { typ = F64; internal = F64; inline = None });
      true
  | (Unknown | Error | Collecting _), _ -> true

type stack =
  | Unreachable
  | Empty
  | Cons of location * inferred_type UnionFind.t * stack

let rec output_stack f st =
  match st with
  | Empty -> ()
  | Unreachable -> Format.fprintf f "@ unreachable"
  | Cons (_, ty, st) ->
      Format.fprintf f "@ %a%a" output_inferred_type ty output_stack st

let print_stack st =
  Format.eprintf "@[Stack:%a@]@." output_stack st;
  (st, ())

let _ = print_stack

let unreachable e st =
  let _, v = e st in
  (Unreachable, v)

let return v st = (st, v)

let ( let* ) e f st =
  let st, v = e st in
  f v st

let ( let*! ) e f =
  match e with
  | Some v -> f v
  | None ->
      return
        {
          desc = Ast.Unreachable;
          info = ([| UnionFind.make Error |], (Ast.no_loc ()).info);
        }

let pop_any ctx i st =
  match st with
  | Unreachable -> (st, UnionFind.make Unknown)
  | Cons (_, ty, r) -> (r, ty)
  | Empty ->
      Error.empty_stack ctx.diagnostics ~location:i.info;
      (st, UnionFind.make Error)

let rec pop_many ctx i n accu =
  if n = 0 then return accu
  else
    let* ty = pop_any ctx i in
    pop_many ctx i (n - 1) (ty :: accu)

(*ZZZ This is for block parameters and return values:
  there should be n .. on the stack, but there are ...
  (with type)
  The nth argument should have type BLA but has type BLA
  (unless we have a locationfrom the stack)
*)
let pop ctx ~location ty st =
  match st with
  | Unreachable -> (st, ())
  | Cons (loc, ty', r) ->
      if not (subtype ctx ty' ty) then
        Error.type_mismatch ctx.diagnostics ~location:loc ty' ty;
      (r, ())
  | Empty ->
      Error.empty_stack ctx.diagnostics ~location;
      (st, ())

let pop_args ctx ~location args =
  Array.fold_right
    (fun ty rem ->
      let* () = rem in
      pop ctx ~location ty)
    args (return ())

let push loc ty st = (Cons (loc, ty, st), ())

let rec push_results results =
  match results with
  | [] ->
      if false then prerr_endline "PUSH";
      return ()
  | (loc, ty) :: rem ->
      let* () = push loc ty in
      push_results rem

type empty_stack_context = Expression | Block | Function

let with_empty_stack ctx ~kind:_ ~location f =
  let st, res = f Empty in
  (* The source locations of the values still on the stack, topmost first.
     Values left behind by error recovery carry a placeholder location and are
     dropped. *)
  let rec locations = function
    | Cons (loc, _, st) ->
        let rest = locations st in
        if loc.loc_start.Lexing.pos_cnum >= 0 then loc :: rest else rest
    | Empty | Unreachable -> []
  in
  (match st with
  | Empty | Unreachable -> ()
  | Cons _ -> (
      match locations st with
      | location :: rest ->
          (* Point a caret right at each leftover value rather than at the
             (potentially large) enclosing construct. *)
          let related =
            List.map
              (fun location ->
                { Wax_utils.Diagnostic.location; message = (fun _ () -> ()) })
              rest
          in
          Error.leftover_values ctx.diagnostics ~location ~related
      | [] ->
          (* No value carries a usable location (only error-recovery
             placeholders): point at the construct and list what remains. *)
          Error.non_empty_stack ctx.diagnostics ~location (fun f () ->
              Format.fprintf f "@[%a@]" output_stack st)));
  res

let internalize_valtype ctx typ =
  let+@ internal = valtype ctx.diagnostics ctx.type_context typ in
  { typ; internal; inline = None }

let internalize ?inline ctx typ =
  let+@ internal = valtype ctx.diagnostics ctx.type_context typ in
  UnionFind.make (Valtype { typ; internal; inline })

(* Check that a source element reference type can be stored where [dst] elements
   are expected (table.copy / table.init / array.init_elem): [src] must be a
   subtype of [dst]. *)
let check_elem_subtype ctx ~location ~src ~dst =
  match
    (internalize_valtype ctx (Ref src), internalize_valtype ctx (Ref dst))
  with
  | Some s, Some d ->
      if
        not
          (Wax_wasm.Types.val_subtype ctx.subtyping_info s.internal d.internal)
      then
        Error.incompatible_element_type ctx.diagnostics ~location
          (UnionFind.make (Valtype s))
          (UnionFind.make (Valtype d))
  | _ -> ()

(* The inferred type of a value read from a field: a packed [i8]/[i16] field
   reads back as the unpacked [Int8]/[Int16] cell, any other as its value type.
   (Distinct from the [fieldtype] type converter above, which maps a source
   field type to its [Internal] form.) *)
let field_read_type ctx (f : fieldtype) =
  match f.typ with
  | Value typ -> internalize ctx typ
  | Packed I8 -> Some (UnionFind.make Int8)
  | Packed I16 -> Some (UnionFind.make Int16)

let unpack_type (f : fieldtype) =
  match f.typ with Value v -> v | Packed _ -> I32

let branch_target ctx label =
  let rec find l label =
    match l with
    | [] ->
        let suggestions =
          Wax_utils.Spell_check.f
            (fun f ->
              List.iter (fun (l, _) -> Option.iter f l) ctx.control_types)
            label.desc
        in
        Error.unbound_name ctx.diagnostics ~location:label.info ~suggestions
          "label" label;
        [||]
    | (Some label', res) :: _ when label.desc = label' -> res
    | _ :: rem -> find rem label
  in
  find ctx.control_types label

(* Draw "did you mean" suggestions from the namespaces an identifier may
   legitimately name, which depends on how it is used:
   - [Get] reads any value, so a local, a global or a function;
   - [Set] assigns, so a local or a mutable global;
   - [Tee] only ever targets a local. *)
let get_suggestions ctx name =
  Wax_utils.Spell_check.f
    (fun f ->
      StringMap.iter (fun k _ -> f k) ctx.locals;
      Tbl.iter ctx.globals (fun k _ -> f k);
      Tbl.iter ctx.functions (fun k _ -> f k))
    name

let set_suggestions ctx name =
  Wax_utils.Spell_check.f
    (fun f ->
      StringMap.iter (fun k _ -> f k) ctx.locals;
      Tbl.iter ctx.globals (fun k (mut, _) -> if mut then f k))
    name

let local_suggestions ctx name =
  Wax_utils.Spell_check.f
    (fun f -> StringMap.iter (fun k _ -> f k) ctx.locals)
    name

(* A name in value position resolves, in order, to a local, then a global, then
   a function (as a non-null reference); [Get]/[Set]/[Tee] share this ladder and
   only differ in what they do with each outcome. *)
type resolved_var =
  | Local of inferred_valtype option
  | Global of bool (* mutable *) * inferred_valtype option
  | Func_ref of int * string
  | Unbound

let resolve_variable ctx idx =
  match StringMap.find_opt idx.desc ctx.locals with
  | Some ty -> Local ty
  | None -> (
      match Tbl.find_opt ctx.globals idx with
      | Some (mut, ty) -> Global (mut, ty)
      | None -> (
          match Tbl.find_opt ctx.functions idx with
          | Some (ty, ty') -> Func_ref (ty, ty')
          | None -> Unbound))

(* Check the operands of an integer (resp. float) binary operator and return
   the unified result-type cell — the two operand cells are merged on success,
   so the caller takes [typ1] as the operator's result type. *)
let check_int_bin_op ctx ~location typ1 typ2 =
  (match (UnionFind.find typ1, UnionFind.find typ2) with
  | Valtype { internal = I32; _ }, Valtype { internal = I32; _ }
  | Valtype { internal = I64; _ }, Valtype { internal = I64; _ }
  | (Valtype { internal = I32 | I64; _ } | Int), (Number | Int) ->
      UnionFind.merge typ1 typ2 (UnionFind.find typ1)
  | (Number | Int), Valtype { internal = I32 | I64; _ } ->
      UnionFind.merge typ1 typ2 (UnionFind.find typ2)
  | Number, Number -> UnionFind.merge typ1 typ2 Int
  (* A LargeInt operand forces i64: it pairs with i64 or another flexible integer
     (never i32). *)
  | Valtype { internal = I64; _ }, LargeInt ->
      UnionFind.merge typ1 typ2 (UnionFind.find typ1)
  | LargeInt, Valtype { internal = I64; _ } ->
      UnionFind.merge typ1 typ2 (UnionFind.find typ2)
  | LargeInt, (LargeInt | Number | Int) | (Number | Int), LargeInt ->
      UnionFind.merge typ1 typ2 LargeInt
  | _ -> Error.binop_type_mismatch ctx.diagnostics ~location typ1 typ2);
  typ1

let check_float_bin_op ctx ~location typ1 typ2 =
  (match (UnionFind.find typ1, UnionFind.find typ2) with
  | Valtype { internal = F32; _ }, Valtype { internal = F32; _ }
  | Valtype { internal = F64; _ }, Valtype { internal = F64; _ }
  | (Valtype { internal = F32 | F64; _ } | Float), (Number | Float | LargeInt)
    ->
      UnionFind.merge typ1 typ2 (UnionFind.find typ1)
  | (Number | Float | LargeInt), Valtype { internal = F32 | F64; _ } ->
      UnionFind.merge typ1 typ2 (UnionFind.find typ2)
  | Number, Number -> UnionFind.merge typ1 typ2 Float
  | _ -> Error.binop_type_mismatch ctx.diagnostics ~location typ1 typ2);
  typ1

let field_has_default (ty : fieldtype) =
  match ty.typ with
  | Packed _ -> true
  | Value ty -> (
      match ty with
      | I32 | I64 | F32 | F64 | V128 -> true
      | Ref { nullable; _ } -> nullable)

let return_statement (i : location instr)
    (desc : (inferred_type UnionFind.t array * location) instr_desc)
    (ty : _ array) st =
  (st, { desc; info = ((ty : _ array), i.info) })

let return_expression i desc ty = return_statement i desc [| ty |]

let expression_type ctx i =
  let typ, location = i.info in
  match typ with
  | [| ty |] -> ty
  | _ ->
      Error.not_an_expression ctx.diagnostics ~location (Array.length typ);
      UnionFind.make Error

let check_subtype ctx ~location ty' ty =
  (* Pass [location] so that, when [ty] is an inferring block result, the value
     is recorded with its branch site (see [Collecting]). *)
  if not (subtype ~location ctx ty' ty) then
    Error.instruction_type_mismatch ctx.diagnostics ~location ty' ty

let check_subtypes ctx ~location types' types =
  if Array.length types' <> Array.length types then
    Error.value_count_mismatch ctx.diagnostics ~location
      ~expected:(Array.length types) ~provided:(Array.length types')
  else
    Array.iter2 (fun ty' ty -> check_subtype ctx ~location ty' ty) types' types

let check_type ctx i ty =
  let ty' = expression_type ctx i in
  let ok = subtype ctx ty' ty in
  if not ok then
    Error.instruction_type_mismatch ctx.diagnostics ~location:(snd i.info) ty'
      ty

(* The concrete type an initializer would take with no annotation, matching the
   resolution of the unannotated [let] case. Returns [None] for types we never
   want to drop an annotation for (packed or still unconstrained). Pure: it does
   not mutate [ty], so it can be read before [check_type] constrains it. *)
let standalone_valtype ctx ty =
  match UnionFind.find ty with
  | Valtype v -> Some v
  | Int | Number -> Some { typ = I32; internal = I32; inline = None }
  | LargeInt -> Some { typ = I64; internal = I64; inline = None }
  | Float -> Some { typ = F64; internal = F64; inline = None }
  | Null -> internalize_valtype ctx (Ref { nullable = true; typ = None_ })
  | Int8 | Int16 | Unknown | Error | Collecting _ -> None

(* Resolve the type that an omitted annotation takes from its initializer, as in
   [let x = e] or [const x = e]: an as-yet-unconstrained literal is pinned to a
   concrete type the way the final type erasure does (int/number -> i32,
   float -> f64, null -> nullref), so the binding gets a definite type. Mutates
   [ty] so later uses observe the resolved type. *)
let resolve_omitted_valtype ctx ty =
  match UnionFind.find ty with
  | Valtype v -> Some v
  | LargeInt ->
      let v = { typ = I64; internal = I64; inline = None } in
      UnionFind.set ty (Valtype v);
      Some v
  | Int | Number | Int8 | Int16 | Unknown | Error | Collecting _ ->
      let v = { typ = I32; internal = I32; inline = None } in
      UnionFind.set ty (Valtype v);
      Some v
  | Float ->
      let v = { typ = F64; internal = F64; inline = None } in
      UnionFind.set ty (Valtype v);
      Some v
  | Null ->
      let+@ v =
        internalize_valtype ctx (Ref { nullable = true; typ = None_ })
      in
      UnionFind.set ty (Valtype v);
      v

(* The type an unannotated [let]/global binding takes from its initializer,
   recording a poison ([None]) type when the initializer has no concrete one. An
   [Unknown] initializer (unreachable / branch code) reports an error here: a
   binding needs a determinable type to be compiled, and silently demoting it to
   the [Error] type would mask that. An [Error] initializer (already reported)
   stays silent. *)
let bound_value_type ctx ~location result_ty =
  match UnionFind.find result_ty with
  | Error -> None
  | Unknown ->
      Error.unknown_operand_type ctx.diagnostics ~location;
      None
  | _ -> resolve_omitted_valtype ctx result_ty

(* Whether [i] is a (possibly cast-wrapped) [null].

   This guards the dropping of a redundant type annotation on an initialized
   binding ([let]/[const]) when converting from Wasm. The general rule is to
   drop the annotation when the initializer's type already equals it. That is
   unsound for [null]: [from_wasm] lowers [ref.null t] to [(null : &?t)] (a cast),
   so the initializer's inferred type is the concrete [&?t] and the comparison
   reports the annotation as redundant — but the printed bare [null] re-infers to
   the *floating* null type [&?none], not [&?t], so dropping the annotation would
   not round-trip. The annotation (or the cast) is what pins the type, so we must
   keep it.

   A cleaner fix would compare against what omitting the annotation actually
   re-infers to (resolving the floating [null] under the cast to [&?none] rather
   than reading the cast's concrete type); until then we keep the annotation
   whenever the initializer is a [null]. *)
let rec is_null_initializer (i : _ instr) =
  match i.desc with
  | Null -> true
  | Cast (e, _) -> is_null_initializer e
  | _ -> false

let valtype_equal ctx (a : inferred_valtype) (b : inferred_valtype) =
  Wax_wasm.Types.val_subtype ctx.subtyping_info a.internal b.internal
  && Wax_wasm.Types.val_subtype ctx.subtyping_info b.internal a.internal

(* Bidirectional checking helpers (see [check_instruction] below).

   The keep-bool for a non-construction value: the contextual annotation is
   load-bearing unless the value's own standalone-resolved type ([standalone],
   captured BEFORE [check_type] mutates the cell) already equals it. This
   mirrors exactly the drop test [bind_let_value]/globals applied via
   [standalone_valtype], so routing those sites through [check_instruction] preserves their
   behaviour — e.g. [let x: i32 = 1] still drops to [let x = 1] (a floating
   number resolves to [i32]), while [let x: i64 = 1] keeps its annotation.

   [drop_supertype] loosens the test for an immutable binding (a [const] global):
   there the annotation is no more than a supertype of the value's own type, so
   dropping it narrows the binding to that subtype — sound because nothing
   reassigns it, and a narrower immutable global still satisfies every use (and
   every import) expecting the wider type. The standalone value must therefore
   only be a *subtype* of the annotation, not equal to it. *)
let annotation_needed ?(drop_supertype = false) ctx
    (standalone : inferred_valtype option) expected =
  match (standalone, UnionFind.find expected) with
  | Some v, Valtype b ->
      if drop_supertype then
        not
          (Wax_wasm.Types.val_subtype ctx.subtyping_info v.internal b.internal)
      else not (valtype_equal ctx v b)
  | _ -> true

(* Whether [expected] carries a real type expectation (vs. the [Unknown]
   sentinel used when [check_instruction] is entered from synthesis with no context).
   [subtype] asserts on an [Unknown] right-hand side, so callers guard with
   this before checking against [expected]. *)
let has_expectation expected =
  match UnionFind.find expected with
  | Unknown | Collecting _ -> false
  | _ -> true

(* For a block-like construct (do/loop/try/try_table) checked against [expected]:
   the single cell to type its body and handlers against — its declared result,
   or [expected] when the annotation was omitted (a re-parse of a dropped one). *)
let context_result_cell ctx typ ~expected =
  if typ.results = [||] then expected
  else
    match array_map_opt (internalize ctx) typ.results with
    | Some [| c |] -> c
    | _ -> expected

(* The [typ] to store for such a construct after its body is typed: fill an
   omitted result from [expected] (so re-parse / [to_wasm] recovers it), or drop
   a declared result on [simplify] when it equals the context — then re-parse
   recovers the same type from the same context, so nothing is lost. *)
let context_block_typ ctx typ ~expected ~result_cell =
  if typ.results = [||] then
    match standalone_valtype ctx expected with
    | Some iv -> { typ with results = [| iv.typ |] }
    | None -> typ
  else if
    ctx.simplify
    &&
    match
      (standalone_valtype ctx expected, standalone_valtype ctx result_cell)
    with
    | Some a, Some b -> valtype_equal ctx a b
    | _ -> false
  then { typ with results = [||] }
  else typ

(* The exact user heap-type name [expected] pins, if any — usable to supply an
   omitted struct/array type name. A supertype top ([any]/[eq]/[struct]/[array]/
   …) or a floating/non-ref cell returns [None]: construction needs the exact
   type, never a supertype. *)
let exact_named_type expected =
  match UnionFind.find expected with
  | Valtype { typ = Ref { typ = Type ident; _ }; _ } -> Some ident
  | _ -> None

(* A value type is defaultable unless it is a non-nullable reference: such a
   local has no zero value and must be assigned before use. *)
let is_defaultable (ty : valtype) =
  match ty with Ref { nullable; _ } -> nullable | _ -> true

let mark_initialized ctx name =
  ctx.initialized_locals <- StringSet.add name ctx.initialized_locals

(* Type-check one [let] binding against [result_ty] — the value it takes off the
   stack — and record the local. Returns the binding to emit: an annotation that
   [simplify] finds redundant (it equals what the value would infer to on its
   own) is dropped, so Wax printed back from Wasm omits it. Used for both the
   single-value form and each name of a multi-value [let]. *)
let bind_let_value ctx ~location result_ty (name, typ) =
  match typ with
  | Some typ ->
      (* The type the value would take on its own, captured before
         [check_subtype] constrains it. *)
      let standalone = standalone_valtype ctx result_ty in
      let drop =
        Option.value ~default:false
          (let+@ ity = internalize_valtype ctx typ in
           check_subtype ctx ~location result_ty (UnionFind.make (Valtype ity));
           Option.iter
             (fun name ->
               ctx.locals <- StringMap.add name.desc (Some ity) ctx.locals;
               ctx.local_decls := name :: !(ctx.local_decls);
               mark_initialized ctx name.desc)
             name;
           ctx.simplify
           && Option.fold ~none:false
                ~some:(fun v -> valtype_equal ctx v ity)
                standalone)
      in
      (name, if drop then None else Some typ)
  | None ->
      Option.iter
        (fun name ->
          (* The local takes its initializer's type; an [Unknown]/[Error]
             initializer has no determinable one, so the local is recorded as
             poison ([None]) rather than defaulting to [i32], and an [Unknown]
             initializer is additionally reported (see [bound_value_type]). *)
          let ity = bound_value_type ctx ~location result_ty in
          ctx.locals <- StringMap.add name.desc ity ctx.locals;
          ctx.local_decls := name :: !(ctx.local_decls);
          mark_initialized ctx name.desc)
        name;
      (name, None)

(* When converting from Wasm, an expression producing several values (typically
   a call) is emitted as a bare statement, and the values it leaves on the stack
   are peeled off by a following run of [let x = _] declarations (and [_ = _]
   drops for results that are discarded). [merge_let_tuple] folds that run back
   into a single multi-binding [let (..) = expr] — the exact inverse of how such
   a [let] lowers, so the rewrite preserves semantics.

   The run consumed is exactly [head]'s result arity, read from the typed info,
   so we never absorb a [let x = _] that draws from a value sitting below
   [head]. Each bound name takes one value left to right, whereas the lowering
   stores the topmost value first, so the bindings are the run in reverse. Only
   done while simplifying, i.e. on the Wasm-to-Wax path. *)
let merge_let_tuple ctx head rest =
  let is_hole i = match i.desc with Hole -> true | _ -> false in
  let arity = Array.length (fst head.info) in
  let rec take n acc l =
    if n = 0 then Some (List.rev acc, l)
    else
      match l with
      | { desc = Let ([ ((Some _, _) as b) ], Some v); _ } :: r when is_hole v
        ->
          take (n - 1) (b :: acc) r
      | { desc = Set (None, v); _ } :: r when is_hole v ->
          take (n - 1) ((None, None) :: acc) r
      | _ -> None
  in
  if (not ctx.simplify) || arity < 2 then head :: rest
  else
    match take arity [] rest with
    | Some (bindings, rest')
      when List.exists (fun (name, _) -> Option.is_some name) bindings ->
        let info = ([||], snd head.info) in
        { desc = Let (List.rev bindings, Some head); info } :: rest'
    | _ -> head :: rest

(* Check a list of typed operands against an array of expected types. *)
let check_operands ctx l expected =
  if Array.length expected = List.length l then
    List.iter2 (fun i ty -> check_type ctx i ty) l (Array.to_list expected)

(* A missing else branch behaves like an empty one: it leaves the block
   parameters on the stack, so it is valid only when those already match the
   results (in particular, an if that produces a value needs an explicit else). *)
let missing_else_ok ctx params results =
  Array.length params = Array.length results
  && Array.for_all2 (fun p r -> subtype ctx p r) params results

(* The function type wrapped by a continuation type, given its (canonical) heap
   type. Mirrors [Validation.cont_functype_of_heaptype]. *)
let cont_functype ctx (h : Internal.heaptype) : Internal.functype option =
  match h with
  | Type ty -> (
      match (Wax_wasm.Types.get_subtype ctx.subtyping_info ty).typ with
      | Cont ft -> (
          match (Wax_wasm.Types.get_subtype ctx.subtyping_info ft).typ with
          | Func f -> Some f
          | Struct _ | Array _ | Cont _ -> None)
      | Func _ | Struct _ | Array _ -> None)
  | _ -> None

(* [ft] matches [ft'] when their arities agree and [ft']'s parameters /
   [ft]'s results are respectively subtypes. Mirrors [Validation.functype_matches]. *)
let functype_matches info (ft : Internal.functype) (ft' : Internal.functype) =
  Array.length ft.params = Array.length ft'.params
  && Array.length ft.results = Array.length ft'.results
  && Array.for_all Fun.id
       (Array.mapi
          (fun i p -> Wax_wasm.Types.val_subtype info ft'.params.(i) p)
          ft.params)
  && Array.for_all Fun.id
       (Array.mapi
          (fun i r -> Wax_wasm.Types.val_subtype info r ft'.results.(i))
          ft.results)

(* A source function type with its parameter and result types resolved to their
   canonical (Binary) form, for structural comparison with [functype_matches]. *)
let internal_functype ctx (ft : functype) : Internal.functype option =
  let*@ params =
    array_map_opt
      (fun p ->
        let+@ iv = internalize_valtype ctx (snd p.desc) in
        iv.internal)
      ft.params
  in
  let+@ results =
    array_map_opt
      (fun t ->
        let+@ iv = internalize_valtype ctx t in
        iv.internal)
      ft.results
  in
  ({ params; results } : Internal.functype)

(* Validate a [resume]/[resume_throw] handler table. [result_types] is the
   result type of the resumed continuation. Mirrors
   [Validation.check_resume_table]. *)
let check_resume_handlers ctx ~result_types handlers =
  let info = ctx.subtyping_info in
  (* A block whose result is being inferred presents its label as a [Collecting]
     cell. The handler reads the label's type to validate the contract, which the
     join cannot re-derive, so resolve to the declared annotation under test and
     mark it needed (kept). *)
  let rec internal_of_inferred ty =
    match UnionFind.find ty with
    | Valtype { internal; _ } -> Some internal
    | Collecting { declared = Some d; _ } -> internal_of_inferred d
    | _ -> None
  in
  let to_internal arr =
    array_map_opt
      (fun typ ->
        let+@ iv = internalize_valtype ctx typ in
        iv.internal)
      arr
  in
  List.iter
    (fun handler ->
      match handler with
      | OnLabel (tag, label) -> (
          match Tbl.find ctx.diagnostics ctx.tags tag with
          | None -> ignore (branch_target ctx label)
          | Some { params = ts3; results = ts4 } ->
              let ts' = branch_target ctx label in
              let mismatch () =
                Error.stack_switching_type_mismatch ctx.diagnostics
                  ~location:label.info
                  ~descr:
                    "this handler must take the tag's parameters followed by a \
                     continuation of the remaining result type"
              in
              (* The handler label receives the tag's parameters followed by a
                 continuation of type [cont (ts4 -> result_types)]. *)
              let n = Array.length ts' in
              if n <> Array.length ts3 + 1 then mismatch ()
              else begin
                (* The continuation slot may be a block result still being
                   inferred (the Wasm->Wax [simplify] pass), presented as a
                   [Collecting] cell. Reading it to validate the contract is a use
                   the join cannot re-derive, so mark its annotation needed (kept);
                   [internal_of_inferred] resolves the cell to that declared type
                   below. Only this last slot can be under inference: a block being
                   inferred has a single result, so a handler with tag parameters
                   (n > 1) is never inferred and its slots are concrete. A cell
                   inferring with no declared annotation resolves to [None] below
                   and so fails the contract check, as it must. *)
                (match UnionFind.find ts'.(n - 1) with
                | Collecting cs -> cs.needed <- true
                | _ -> ());
                Array.iteri
                  (fun i p ->
                    let _, t = p.desc in
                    match
                      (internalize_valtype ctx t, internal_of_inferred ts'.(i))
                    with
                    | Some it, Some it' ->
                        if not (Wax_wasm.Types.val_subtype info it.internal it')
                        then mismatch ()
                    | _ -> ())
                  ts3;
                match internal_of_inferred ts'.(n - 1) with
                | Some (Ref { typ = ht; _ }) -> (
                    match cont_functype ctx ht with
                    | Some ft' -> (
                        match (to_internal ts4, to_internal result_types) with
                        | Some params, Some results ->
                            if
                              not
                                (functype_matches info { params; results } ft')
                            then mismatch ()
                        | _ -> ())
                    | None -> mismatch ())
                | _ -> mismatch ()
              end)
      | OnSwitch tag -> (
          match Tbl.find ctx.diagnostics ctx.tags tag with
          | None -> ()
          | Some { params = ts3; _ } ->
              if Array.length ts3 <> 0 then
                Error.stack_switching_type_mismatch ctx.diagnostics
                  ~location:tag.info
                  ~descr:"the tag of a 'switch' handler must take no parameters"
          ))
    handlers

let rec count_holes i =
  match i.desc with
  | Hole -> 1
  | BinOp (_, l, r)
  | Array (_, l, r)
  | ArraySegment (_, _, l, r)
  | ArrayGet (l, r) ->
      count_holes l + count_holes r
  | ArraySet (t, i, v) -> count_holes t + count_holes i + count_holes v
  | Call (f, args) | TailCall (f, args) ->
      count_holes f + List.fold_left (fun acc i -> acc + count_holes i) 0 args
  | If { cond = i; _ }
  | Let (_, Some i)
  | Set (_, i)
  | Tee (_, i)
  | UnOp (_, i)
  | Cast (i, _)
  | Test (i, _)
  | NonNull i
  | Br (_, Some i)
  | Br_if (_, i)
  | Br_table (_, i)
  | Br_on_null (_, i)
  | Br_on_non_null (_, i)
  | Br_on_cast (_, _, i)
  | Br_on_cast_fail (_, _, i)
  | ArrayDefault (_, i)
  | Throw (_, Some i)
  | ThrowRef i
  | ContNew (_, i)
  | Return (Some i)
  | StructGet (i, _) ->
      count_holes i
  | StructSet (i1, _, i2) -> count_holes i1 + count_holes i2
  | Struct (_, l) -> List.fold_left (fun acc (_, i) -> acc + count_holes i) 0 l
  | Sequence l
  | ArrayFixed (_, l)
  | ContBind (_, _, l)
  | Suspend (_, l)
  | Resume (_, _, l)
  | ResumeThrow (_, _, _, l)
  | ResumeThrowRef (_, _, l)
  | Switch (_, _, l) ->
      List.fold_left (fun acc i -> acc + count_holes i) 0 l
  | Select (c, t, e) -> count_holes c + count_holes t + count_holes e
  (* [dispatch]/[match], [while] and [do]-[while] are block-like: their
     operands/scrutinee and bodies are checked inside the blocks they desugar
     to, so no hole at this level draws from the stack. *)
  | Block _ | Loop _ | While _ | TryTable _ | Try _ | If_annotation _
  | Dispatch _ | Match _ | StructDefault _ | Char _ | String _ | Int _ | Float _
  | Get _ | Null | Unreachable | Nop
  | Let (_, None)
  | Br (_, None)
  | Throw (_, None)
  | Return None ->
      0

(* Accumulate into [acc] the local names assigned ([Set]/[Tee] targets) anywhere
   in [i], recursing through every sub-instruction. Mirrors the case coverage of
   {!Sink_let.occurs}: only [Set]/[Tee] write a local, every other case just
   recurses. A [Set None] (a value left on the stack, not a named write) names no
   local. Wasm-derived locals are uniquely named within a function, so the
   resulting by-name set is exact; a stray name collision could only keep an
   annotation, never wrongly drop one. *)
let rec collect_assigned_locals acc i =
  let in_list acc l = List.fold_left collect_assigned_locals acc l in
  let in_opt acc o =
    match o with Some i -> collect_assigned_locals acc i | None -> acc
  in
  match i.desc with
  | Set (Some id, e) | Tee (id, e) ->
      collect_assigned_locals (StringSet.add id.desc acc) e
  | Set (None, e) -> collect_assigned_locals acc e
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
      in_list acc block
  | While { cond; block; _ } -> in_list (collect_assigned_locals acc cond) block
  | If { cond; if_block; else_block; _ } ->
      let acc = in_list (collect_assigned_locals acc cond) if_block.desc in
      Option.fold ~none:acc ~some:(fun b -> in_list acc b.desc) else_block
  | Try { block; catches; catch_all; _ } ->
      let acc = in_list acc block in
      let acc = List.fold_left (fun acc (_, b) -> in_list acc b) acc catches in
      Option.fold ~none:acc ~some:(in_list acc) catch_all
  | Call (t, args) | TailCall (t, args) ->
      in_list (collect_assigned_locals acc t) args
  | Cast (e, _)
  | Test (e, _)
  | NonNull e
  | StructGet (e, _)
  | UnOp (_, e)
  | Br_if (_, e)
  | Br_table (_, e)
  | Br_on_null (_, e)
  | Br_on_non_null (_, e)
  | Br_on_cast (_, _, e)
  | Br_on_cast_fail (_, _, e)
  | ThrowRef e
  | ArrayDefault (_, e)
  | ContNew (_, e) ->
      collect_assigned_locals acc e
  | Struct (_, fields) ->
      List.fold_left
        (fun acc (_, e) -> collect_assigned_locals acc e)
        acc fields
  | StructSet (e1, _, e2)
  | Array (_, e1, e2)
  | ArraySegment (_, _, e1, e2)
  | ArrayGet (e1, e2)
  | BinOp (_, e1, e2) ->
      collect_assigned_locals (collect_assigned_locals acc e1) e2
  | ArraySet (e1, e2, e3) | Select (e1, e2, e3) ->
      collect_assigned_locals
        (collect_assigned_locals (collect_assigned_locals acc e1) e2)
        e3
  | ArrayFixed (_, l)
  | ContBind (_, _, l)
  | Suspend (_, l)
  | Resume (_, _, l)
  | ResumeThrow (_, _, _, l)
  | ResumeThrowRef (_, _, l)
  | Switch (_, _, l)
  | Sequence l ->
      in_list acc l
  | Dispatch { index; arms; _ } ->
      List.fold_left
        (fun acc (_, b) -> in_list acc b)
        (collect_assigned_locals acc index)
        arms
  | Match { scrutinee; arms; default } ->
      let acc = collect_assigned_locals acc scrutinee in
      let acc = List.fold_left (fun acc (_, b) -> in_list acc b) acc arms in
      in_list acc default
  | Let (_, body) -> in_opt acc body
  | Br (_, o) | Throw (_, o) | Return o -> in_opt acc o
  | If_annotation { then_body; else_body; _ } ->
      let acc = in_list acc then_body in
      Option.fold ~none:acc ~some:(in_list acc) else_body
  | Get _ | Unreachable | Nop | Hole | Null | Char _ | String _ | Int _
  | Float _ | StructDefault _ ->
      acc

let rec check_hole_order_rec ctx i n =
  match i.desc with
  | Hole -> n - 1
  | Cast (i, _) when is_unknown_or_error (expression_type ctx i) ->
      (* Casts in unreachable / failed code should be ignored: they are here to
         guide the translation but are not emitted. *)
      check_hole_order_rec ctx i n
  | _ when n <= 0 -> n
  | _ ->
      let n =
        match i.desc with
        | Block _ | Loop _ | While _ | TryTable _ | Try _ | If_annotation _
        | Dispatch _ | Match _ | StructDefault _ | Char _ | String _ | Int _
        | Float _ | Get _ | Null | Unreachable | Nop
        | Let (_, None)
        | Br (_, None)
        | Throw (_, None)
        | Return None ->
            n
        (* A table reference [tab[..]] has a static receiver (the table name),
           not an evaluated operand, so it does not count as occurring before a
           hole; only the index/value do. *)
        | ArrayGet ({ desc = Get tab; _ }, r)
          when Tbl.find_opt ctx.tables tab <> None ->
            check_hole_order_rec ctx r n
        | ArraySet ({ desc = Get tab; _ }, idx, v)
          when Tbl.find_opt ctx.tables tab <> None ->
            n |> check_hole_order_rec ctx idx |> check_hole_order_rec ctx v
        | BinOp (_, l, r)
        | Array (_, l, r)
        | ArraySegment (_, _, l, r)
        | ArrayGet (l, r) ->
            n |> check_hole_order_rec ctx l |> check_hole_order_rec ctx r
        | ArraySet (t, i, v) ->
            n |> check_hole_order_rec ctx t |> check_hole_order_rec ctx i
            |> check_hole_order_rec ctx v
        | Call (f, args) | TailCall (f, args) ->
            n |> check_hole_order_in_list ctx args |> check_hole_order_rec ctx f
        | If { cond = i; _ }
        | Let (_, Some i)
        | Set (_, i)
        | Tee (_, i)
        | UnOp (_, i)
        | Cast (i, _)
        | Test (i, _)
        | NonNull i
        | Br (_, Some i)
        | Br_if (_, i)
        | Br_table (_, i)
        | Br_on_null (_, i)
        | Br_on_non_null (_, i)
        | Br_on_cast (_, _, i)
        | Br_on_cast_fail (_, _, i)
        | ArrayDefault (_, i)
        | Throw (_, Some i)
        | ThrowRef i
        | ContNew (_, i)
        | Return (Some i)
        | StructGet (i, _) ->
            check_hole_order_rec ctx i n
        | StructSet (i1, _, i2) ->
            n |> check_hole_order_rec ctx i1 |> check_hole_order_rec ctx i2
        | Sequence l
        | ArrayFixed (_, l)
        | ContBind (_, _, l)
        | Suspend (_, l)
        | Resume (_, _, l)
        | ResumeThrow (_, _, _, l)
        | ResumeThrowRef (_, _, l)
        | Switch (_, _, l) ->
            check_hole_order_in_list ctx l n
        | Struct (_, l) ->
            let fields =
              match UnionFind.find (expression_type ctx i) with
              | Valtype { typ = Ref { typ = Type t; _ }; _ } -> (
                  match lookup_struct_type ctx t with
                  | Some fields ->
                      let field_map =
                        List.fold_left
                          (fun acc (name, instr) ->
                            StringMap.add name.desc instr acc)
                          StringMap.empty l
                      in
                      (* Reorder fields according to definition *)
                      Array.map
                        (fun field ->
                          StringMap.find (fst field.desc).desc field_map)
                        fields
                      |> Array.to_list
                  | None -> List.map snd l)
              | _ -> List.map snd l
            in
            check_hole_order_in_list ctx fields n
        | Select (c, t, e) ->
            n |> check_hole_order_rec ctx t |> check_hole_order_rec ctx e
            |> check_hole_order_rec ctx c
        | Hole -> assert false
      in
      if n = 0 then 0
      else (
        Error.before_hole ctx.diagnostics ~location:(snd i.info);
        raise Exit)

and check_hole_order_in_list ctx l n =
  List.fold_left (fun n i -> check_hole_order_rec ctx i n) n l

let check_hole_order ctx l n =
  try
    let _ : int = check_hole_order_rec ctx l n in
    true
  with Exit -> false

let pop_parameter st = match st with [] -> assert false | x :: r -> (r, x)

let _print_arg_stack f l =
  Format.pp_print_list
    ~pp_sep:(fun f () -> Format.fprintf f "@ ")
    output_inferred_type f l

(* Split [i]'s inferred result types into (last type, preceding types). Only
   called on an instruction known to produce at least one value, so the array
   is non-empty. *)
(* Peel the condition / reference operand off the last slot of a branch
   instruction's operand types, returning it together with the remaining branch
   parameters. The operand is an arbitrary expression, which may type to no
   value at all (e.g. a call to a function with no results); rather than assert,
   report the missing operand and recover with an unknown value. *)
let split_on_last_type ctx ~location i =
  let a = fst i.info in
  let len = Array.length a in
  if len = 0 then (
    Error.value_count_mismatch ctx.diagnostics ~location ~expected:1 ~provided:0;
    (UnionFind.make Error, [||]))
  else (a.(len - 1), Array.sub a 0 (len - 1))

let immediate_supertype s : Ast.heaptype =
  match (s.supertype, s.typ) with
  | Some t, _ -> Type t
  | None, Struct _ -> Struct
  | None, Array _ -> Array
  | None, Func _ -> Func
  | None, Cont _ -> Cont

(* The type lookups below never fail *)
let rec heap_lub ctx (h1 : Ast.heaptype) (h2 : Ast.heaptype) =
  match (h1, h2) with
  | Type id1, Type id2 ->
      let*@ i1, s1 = Tbl.find_opt ctx.type_context.types id1 in
      let*@ i2, s2 = Tbl.find_opt ctx.type_context.types id2 in
      if i1 > i2 then heap_lub ctx (immediate_supertype s1) h2
      else if i2 > i1 then heap_lub ctx h1 (immediate_supertype s2)
      else Some h1
  | Type id1, _ ->
      let*@ _, s1 = Tbl.find_opt ctx.type_context.types id1 in
      heap_lub ctx (immediate_supertype s1) h2
  | _, Type id2 ->
      let*@ _, s2 = Tbl.find_opt ctx.type_context.types id2 in
      heap_lub ctx h1 (immediate_supertype s2)
      (* Abstract hierarchy *)
  | None_, None_ -> Some None_
  | (None_ | I31), I31 | I31, None_ -> Some I31
  | (None_ | Struct), Struct | Struct, None_ -> Some Struct
  | (None_ | Array), Array | Array, None_ -> Some Array
  | (None_ | I31 | Struct | Array | Eq), Eq
  | Eq, (None_ | I31 | Struct | Array)
  | (Struct | Array), I31
  | I31, (Struct | Array)
  | Struct, Array
  | Array, Struct ->
      Some Eq
  | (None_ | I31 | Struct | Array | Eq | Any), Any
  | Any, (None_ | Eq | I31 | Struct | Array) ->
      Some Any
  | NoFunc, NoFunc -> Some NoFunc
  | (NoFunc | Func), Func | Func, NoFunc -> Some Func
  | NoExtern, NoExtern -> Some NoExtern
  | (NoExtern | Extern), Extern | Extern, NoExtern -> Some Extern
  | NoExn, NoExn -> Some NoExn
  | (NoExn | Exn), Exn | Exn, NoExn -> Some Exn
  | NoCont, NoCont -> Some NoCont
  | (NoCont | Cont), Cont | Cont, NoCont -> Some Cont
  | ( (None_ | Eq | I31 | Struct | Array | Any),
      (NoExtern | Extern | NoExn | Exn | NoFunc | Func) )
  | ( (NoExtern | Extern | NoExn | Exn | NoFunc | Func),
      (None_ | Eq | I31 | Struct | Array | Any) )
  | (NoFunc | Func), (NoExtern | Extern | NoExn | Exn)
  | (NoExtern | Extern | NoExn | Exn), (NoFunc | Func)
  | (NoExtern | Extern), (NoExn | Exn)
  | (NoExn | Exn), (NoExtern | Extern)
  (* Continuation types form their own hierarchy, incompatible with all
     others (and have no Wax surface syntax). *)
  | (Cont | NoCont), _
  | _, (Cont | NoCont) ->
      None

let val_lub ctx v1 v2 =
  match (v1, v2) with
  | Ref r1, Ref r2 ->
      let+@ lub = heap_lub ctx r1.typ r2.typ in
      let nullable = r1.nullable || r2.nullable in
      Ref { nullable; typ = lub }
  | _ -> if v1 = v2 then Some v1 else None

(* The least upper bound of two value type cells, or [None] when they have no
   common type. Mirrors the [Select] (?:) reconciliation: it pins an
   as-yet-unconstrained literal/[null] to the other side and lubs two reference
   types via [val_lub]. Used to combine the values reaching a block's exit (the
   branches of an [if], etc.) when inferring the block's result type. *)
let join_value_types ctx ty1 ty2 =
  match (UnionFind.find ty1, UnionFind.find ty2) with
  | _, (Unknown | Error) -> Some ty1
  | (Unknown | Error), _ -> Some ty2
  | Null, Null -> Some ty1
  | Valtype { internal = I32; _ }, Valtype { internal = I32; _ }
  | Valtype { internal = I64; _ }, Valtype { internal = I64; _ }
  | Valtype { internal = F32; _ }, Valtype { internal = F32; _ }
  | Valtype { internal = F64; _ }, Valtype { internal = F64; _ } ->
      Some ty2
  | (Int | Number), (Int | Valtype { internal = I32 | I64; _ })
  | (Float | Number), (Float | Valtype { internal = F32 | F64; _ })
  | Number, Number ->
      UnionFind.merge ty1 ty2 (UnionFind.find ty2);
      Some ty2
  | ( (Valtype { internal = I32; _ } | Valtype { internal = I64; _ }),
      (Int | Number) )
  | ( (Valtype { internal = F32; _ } | Valtype { internal = F64; _ }),
      (Float | Number) )
  | (Int | Float), Number ->
      UnionFind.merge ty1 ty2 (UnionFind.find ty1);
      Some ty1
  | Valtype { typ = typ1; _ }, Valtype { typ = typ2; _ } -> (
      match val_lub ctx typ1 typ2 with
      | Some ty -> internalize ctx ty
      | None -> None)
  | Valtype { typ = Ref { typ; _ }; _ }, Null -> (
      match internalize ctx (Ref { typ; nullable = true }) with
      | Some ty ->
          UnionFind.set ty2 (UnionFind.find ty);
          Some ty
      | None -> None)
  | Null, Valtype { typ = Ref { typ; _ }; _ } -> (
      match internalize ctx (Ref { typ; nullable = true }) with
      | Some ty ->
          UnionFind.set ty1 (UnionFind.find ty);
          Some ty
      | None -> None)
  | _ -> None

let address_valtype (at : [ `I32 | `I64 ]) : inferred_valtype =
  match at with
  | `I32 -> { typ = I32; internal = I32; inline = None }
  | `I64 -> { typ = I64; internal = I64; inline = None }

(* Expected operand/result type of a SIMD intrinsic, as a fresh type cell. *)
let simd_valtype : Simd.ty -> inferred_valtype = function
  | TV128 -> { typ = V128; internal = V128; inline = None }
  | TI32 -> { typ = I32; internal = I32; inline = None }
  | TI64 -> { typ = I64; internal = I64; inline = None }
  | TF32 -> { typ = F32; internal = F32; inline = None }
  | TF64 -> { typ = F64; internal = F64; inline = None }

let simd_cell t = UnionFind.make (Valtype (simd_valtype t))

(* Memory access method names. The value width is in the name; signedness and the
   i32/i64 result come from a surrounding [as iN_s/u] cast (see [to_wasm]). *)
let mem_load_result meth : inferred_type option =
  match meth with
  | "load8" -> Some Int8
  | "load16" -> Some Int16
  | "load32" -> Some (Valtype { typ = I32; internal = I32; inline = None })
  | "load64" -> Some (Valtype { typ = I64; internal = I64; inline = None })
  | "loadf32" -> Some (Valtype { typ = F32; internal = F32; inline = None })
  | "loadf64" -> Some (Valtype { typ = F64; internal = F64; inline = None })
  | _ -> None

let mem_store_method meth =
  match meth with
  | "store8" | "store16" | "store32" | "store64" | "storef32" | "storef64" ->
      true
  | _ -> false

let is_mem_method meth = mem_load_result meth <> None || mem_store_method meth

(* Natural alignment (in bytes) of a scalar memory access. *)
let mem_natural_align meth =
  match meth with
  | "load8" | "store8" -> 1
  | "load16" | "store16" -> 2
  | "load32" | "store32" | "loadf32" | "storef32" -> 4
  | "load64" | "store64" | "loadf64" | "storef64" -> 8
  | _ -> 1

(* The unsigned integer denoted by a constant literal argument, if any. *)
(* The unsigned 64-bit value of an integer literal, or [None] if it is not an
   integer literal or does not fit u64. Parsed quietly (a plain [of_string] would
   print "Unsigned int overflow" before raising on an out-of-range value). *)
let int_literal a =
  match a.Ast.desc with
  | Ast.Int s ->
      (if String.starts_with ~prefix:"0x" s then Int64.of_string_opt s
       else Int64.of_string_opt ("0u" ^ s))
      |> Option.map Wax_utils.Uint64.of_int64
  | _ -> None

let max_offset_i32_exclusive =
  Wax_utils.Uint64.of_string "0x1_0000_0000" (* 2^32 *)

let max_align = Wax_utils.Uint64.of_int 16

(* Validate the trailing [align]/[offset] literals of a memory access against
   the access's natural alignment (in bytes) and the address type. Mirrors
   [Validation.check_memarg]. [align] and [offset] are the corresponding
   argument expressions, when present. *)
let check_memarg ctx ~address_type ~natural ~align ~offset =
  (let>@ offset = offset in
   match int_literal offset with
   | None ->
       (* The literal does not fit u64, so it cannot be a memory offset. *)
       Error.memory_immediate_too_large ctx.diagnostics
         ~location:(snd offset.info)
   | Some o ->
       if
         address_type = `I32
         && Wax_utils.Uint64.compare o max_offset_i32_exclusive >= 0
       then
         Error.memory_offset_too_large ctx.diagnostics
           ~location:(snd offset.info) max_offset_i32_exclusive);
  let>@ align = align in
  match int_literal align with
  | None ->
      Error.memory_immediate_too_large ctx.diagnostics
        ~location:(snd align.info)
  | Some a -> (
      if
        Wax_utils.Uint64.compare a max_align > 0
        || Wax_utils.Uint64.to_int a > natural
      then
        Error.memory_align_too_large ctx.diagnostics ~location:(snd align.info)
          natural
      else
        match Wax_utils.Uint64.to_int a with
        | 1 | 2 | 4 | 8 | 16 -> ()
        | _ -> Error.bad_memory_align ctx.diagnostics ~location:(snd align.info)
      )

let max_memory_size = function
  | `I32 -> Wax_utils.Uint64.of_int 65536
  | `I64 -> Wax_utils.Uint64.of_string "0x1_0000_0000_0000"

let max_table_size = function
  | `I32 -> Wax_utils.Uint64.of_string "0xffff_ffff"
  | `I64 -> Wax_utils.Uint64.of_string "0xffff_ffff_ffff_ffff"

(* Validate a memory/table size limit. Mirrors [Validation.limits]. *)
let check_limits ctx ~location kind address_type limits max_fn =
  match limits with
  | None -> ()
  | Some (mi, ma) -> (
      let max = max_fn address_type in
      match ma with
      | None ->
          if Wax_utils.Uint64.compare mi max > 0 then
            Error.limit_too_large ctx.diagnostics ~location kind max
      | Some ma ->
          if Wax_utils.Uint64.compare mi ma > 0 then
            Error.limit_mismatch ctx.diagnostics ~location kind;
          if Wax_utils.Uint64.compare ma max > 0 then
            Error.limit_too_large ctx.diagnostics ~location kind max)

(* Management methods shared by memories and tables, dispatched by the receiver
   (a memory or table name). *)
let is_mgmt_method m =
  match m with "size" | "grow" | "fill" | "copy" | "init" -> true | _ -> false

(* No-argument instruction methods written as a call on a value, [x.sqrt()]:
   the integer and float unary operators, the [to_bits]/[from_bits] reinterpret
   casts, and [arr.length()]. They are parsed as [Call (StructGet …, [])] and
   kept in that form so they print back with their parentheses. *)
let is_unary_method m =
  match m with
  | "clz" | "ctz" | "popcnt" | "extend8_s" | "extend16_s" | "abs" | "ceil"
  | "floor" | "trunc" | "nearest" | "sqrt" | "to_bits" | "from_bits" | "length"
    ->
      true
  | _ -> false

(* Mint (or reuse) an anonymous function type for an inline [as &fn(..) -> ..]
   cast target. The name encodes the signature so identical casts share one
   type, and to_wasm materialises it through the [<..>] synthetic-type path. *)
(* Register (once) a type definition for an anonymous function signature and
   return the synthetic name standing for it — used when a cast or [call_ref]
   needs a named [func] type but the source wrote the signature inline. The name
   is a deterministic mangling of the signature, so identical signatures map to
   the same definition. *)
let anon_function_type ctx (sign : functype) =
  let buf = Buffer.create 32 in
  let rec vt (t : valtype) =
    match t with
    | I32 -> Buffer.add_char buf 'i'
    | I64 -> Buffer.add_char buf 'I'
    | F32 -> Buffer.add_char buf 'f'
    | F64 -> Buffer.add_char buf 'F'
    | V128 -> Buffer.add_char buf 'v'
    | Ref { nullable; typ } ->
        Buffer.add_char buf '&';
        if nullable then Buffer.add_char buf '?';
        ht typ
  and ht (h : heaptype) =
    Buffer.add_string buf
      (match h with
      | Func -> "func"
      | NoFunc -> "nofunc"
      | Exn -> "exn"
      | NoExn -> "noexn"
      | Cont -> "cont"
      | NoCont -> "nocont"
      | Extern -> "extern"
      | NoExtern -> "noextern"
      | Any -> "any"
      | Eq -> "eq"
      | I31 -> "i31"
      | Struct -> "struct"
      | Array -> "array"
      | None_ -> "none"
      | Type id -> "$" ^ id.desc)
  in
  Buffer.add_string buf "<fn:";
  Array.iter
    (fun p ->
      vt (snd p.desc);
      Buffer.add_char buf ';')
    sign.params;
  Buffer.add_string buf "->";
  Array.iter
    (fun t ->
      vt t;
      Buffer.add_char buf ';')
    sign.results;
  Buffer.add_char buf '>';
  let name = Ast.no_loc (Buffer.contents buf) in
  (* A pure existence check: [Tbl.exists] would also *report* a spurious
     "already bound" error on the second cast with the same signature. *)
  if Tbl.find_opt ctx.type_context.types name = None then
    ignore
      (add_type ctx.diagnostics ctx.type_context
         [|
           Ast.no_loc (name, { supertype = None; typ = Func sign; final = true });
         |]
        : int option);
  name

(* Peel a type-checked [dispatch] lowering (see [Ast_utils.lower_dispatch]) back
   apart: descend [k] case blocks, collecting each case body, and return the
   [br_table] index together with the bodies in arm order. Deterministic — the
   lowering we just type-checked guarantees the shape. *)
let extract_dispatch wrapper k =
  let body_of w =
    match w.desc with Ast.Block { block; _ } -> block | _ -> assert false
  in
  let rec peel block n =
    if n = 0 then
      match block with
      | [ { desc = Ast.Br_table (_, idx); _ } ] -> (idx, [])
      | _ -> assert false
    else
      match block with
      | head :: tail ->
          let idx, bodies = peel (body_of head) (n - 1) in
          (idx, tail :: bodies)
      | [] -> assert false
  in
  peel (body_of wrapper) k

(* Rebuild a typed [dispatch] from the type-checked lowering [typed_list] (the
   outermost case block followed by its trailing body) and the original [arms]
   (for the labels). Arms are in fall-through order, the reverse of the block
   nesting (see [Ast_utils.lower_dispatch]), so we peel against the reversed arm
   list — outermost first — and reverse the result back. Returns the typed index
   and arms. *)
let rebuild_dispatch typed_list arms =
  match (List.rev arms, typed_list) with
  | [], [ { desc = Ast.Br_table (_, idx); _ } ] -> (idx, [])
  | (outer_label, _) :: rest_arms, outer :: outer_body ->
      let idx, rest_bodies = extract_dispatch outer (List.length rest_arms) in
      ( idx,
        List.rev
          ((outer_label, outer_body)
          :: List.map2 (fun (l, _) b -> (l, b)) rest_arms rest_bodies) )
  | _ -> assert false

(* Peel a type-checked [while] lowering (see [Ast_utils.lower_while]) back to the
   typed condition and body, dropping the synthesised loop, [if] and back-edge.
   Deterministic — the lowering we just type-checked guarantees the shape. *)
let rebuild_while typed_list =
  match typed_list with
  | [
   {
     desc = Ast.Loop { block = [ { desc = If { cond; if_block; _ }; _ } ]; _ };
     _;
   };
  ] -> (
      match List.rev if_block.desc with
      | { desc = Ast.Br _; _ } :: rev_body -> (cond, List.rev rev_body)
      | _ -> assert false)
  | _ -> assert false

(* Peel a type-checked [match] lowering (see [Ast_utils.lower_match]) apart. The
   lowering nests one block per arm inside an outer void [escape] block, each
   wrapping the previous block (its result consumed for the previous arm) then
   that arm's body; the innermost block holds the threaded test chain and the
   [escape] branch, and the [default] follows the [escape] block as trailing
   code. Descending from the [escape] block consumes the arms in reverse source
   order. Returns the typed arm bodies (paired with the original patterns) and
   the typed default. *)
let rebuild_match typed_list arms =
  match arms with
  | [] -> ([], typed_list)
  | _ ->
      let block_body blk =
        match blk.desc with
        | Ast.Block { block; _ } -> block
        | _ -> assert false
      in
      (* Strip a wrapper block's leading consume of its inner block, returning
         that inner block and the arm body following it. *)
      let unwrap pat stmts =
        match (pat, stmts) with
        | ( Ast.MatchCast (Some _, _),
            { desc = Ast.Let (_, Some inner); _ } :: body ) ->
            (inner, body)
        | Ast.MatchCast (None, _), { desc = Ast.Set (None, inner); _ } :: body
          ->
            (inner, body)
        | Ast.MatchNull, inner :: body -> (inner, body)
        | _ -> assert false
      in
      let escape, default =
        match typed_list with x :: r -> (x, r) | [] -> assert false
      in
      let rec peel blk = function
        | [] -> [] (* [blk] is the innermost block (test chain + escape). *)
        | (pat, _) :: rest_rev ->
            let inner, arm_body = unwrap pat (block_body blk) in
            (pat, arm_body) :: peel inner rest_rev
      in
      let arms_rev = peel escape (List.rev arms) in
      (List.rev arms_rev, default)

(* Synthesise the block labels for a [match] lowering: one per arm, then the
   outer [escape] label ([n+1] in all). The [<…>] form is outside the source
   identifier grammar, so it cannot capture a user branch. *)
let match_labels info arms =
  List.init
    (List.length arms + 1)
    (fun k -> { desc = Printf.sprintf "<match%d>" k; info })

(* The scrutinee's external reference type, used as the arm blocks' result type
   (a failed test forwards the scrutinee there). [None] if it is not a single
   reference value. *)
let match_scrut_reftype ctx scrut' =
  match standalone_valtype ctx (expression_type ctx scrut') with
  | Some { typ = Ref _ as typ; _ } -> Some typ
  | _ -> None

(* Set to [true] to trace each instruction as it is type-checked. *)
let debug = false

let rec instruction ctx i : 'a list -> 'a list * (_, _ array * _) annotated =
  if debug then Format.eprintf "%a@." Output.instr i;
  match i.desc with
  | Block { label; typ; block = instrs } -> (
      (* An expression-position block draws nothing from a stack, so a parameter
         type has no source; report it, then recover by supplying the declared
         parameters anyway so the body does not underflow into spurious "stack
         empty" errors. (With no parameters this is the empty stack, unchanged.) *)
      if Array.length typ.params > 0 then
        Error.parameterized_block_expression ctx.diagnostics ~location:i.info;
      (* The block's value is consumed here, so it is value-producing: infer (and
         on [simplify] drop) its result type, admitting branches to its own
         label (unlike [if]). An omitted annotation is therefore always a dropped
         single result, never a void block. *)
      match block_inference ctx i label typ ~instrs with
      | Some (desc, results) -> return_statement i desc results
      | None ->
          let*! params =
            array_map_opt (fun p -> internalize ctx (snd p.desc)) typ.params
          in
          let*! results = array_map_opt (internalize ctx) typ.results in
          let instrs' = block ctx i.info label params results results instrs in
          return_statement i (Block { label; typ; block = instrs' }) results)
  | Dispatch { index; cases; default; arms } ->
      (* The case (arm) labels become distinct block labels in the lowering and
         key the arm bodies, so they must be distinct. *)
      let rec check_dups seen = function
        | [] -> ()
        | (l, _) :: r ->
            if List.exists (fun s -> s = l.desc) seen then
              Error.dispatch_duplicate_arm ctx.diagnostics ~location:l.info l;
            check_dups (l.desc :: seen) r
      in
      check_dups [] arms;
      (* Type-check against the equivalent blocks (see [Ast_utils.lower_dispatch])
         as a void block body — the outermost case block followed by the first
         arm's trailing body. This validates the index is an [i32], every
         [br_table] target resolves to a 0-ary label, and each case body is
         well-typed. Then rebuild a typed [Dispatch], preserving the high-level
         form for the formatter and for the identical re-lowering in [To_wasm]. *)
      let lowered =
        Ast_utils.lower_dispatch ~block_info:i.info ~index ~cases ~default ~arms
      in
      (* In expression position the dispatch is checked in isolation (a void
         block body); a divergence in the trailing case body is propagated only
         in statement position — see [toplevel_instruction]. *)
      let typed = block ctx i.info None [||] [||] [||] lowered in
      let index', arms' = rebuild_dispatch typed arms in
      return_statement i
        (Dispatch { index = index'; cases; default; arms = arms' })
        [||]
  | Match { scrutinee; arms; default } ->
      (* Type-check against the nested type-test ladder (see
         [Ast_utils.lower_match]): the scrutinee is threaded once through a
         [br_on_cast]/[br_on_null] chain whose tests branch out to the arm
         blocks. The arm bodies must diverge (a block's result is supplied only
         on the matching-branch path); the lowered block check enforces this.
         Rebuild a typed [Match] for the formatter and the identical re-lowering
         in [To_wasm]. *)
      let* scrut' = instruction ctx scrutinee in
      (* The chain's casts require a reference scrutinee; flag a non-reference
         here (the failed cast in the lowered form reports at the same spot). *)
      (match match_scrut_reftype ctx scrut' with
      | Some _ -> ()
      | None -> Error.expected_ref ctx.diagnostics ~location:(snd scrut'.info));
      let labels = match_labels i.info arms in
      let lowered =
        Ast_utils.lower_match ~block_info:i.info ~labels ~scrutinee ~arms
          ~default
      in
      let typed = block ctx i.info None [||] [||] [||] lowered in
      let arms', default' = rebuild_match typed arms in
      return_statement i
        (Match { scrutinee = scrut'; arms = arms'; default = default' })
        [||]
  | Loop { label; typ; block = instrs } -> (
      if Array.length typ.params > 0 then
        Error.parameterized_block_expression ctx.diagnostics ~location:i.info;
      match loop_inference ctx i label typ ~instrs with
      | Some (desc, results) -> return_statement i desc results
      | None ->
          let*! params =
            array_map_opt (fun p -> internalize ctx (snd p.desc)) typ.params
          in
          let*! results = array_map_opt (internalize ctx) typ.results in
          let instrs' = block ctx i.info label params results params instrs in
          return_statement i (Loop { label; typ; block = instrs' }) results)
  | While { label; cond; block = instrs } ->
      (* Type-check the equivalent loop (see [Ast_utils.lower_while]): this
         validates that [cond] is an [i32] and the body is well-typed, with the
         loop label in scope so a [br] to it (continue) resolves. Then rebuild a
         typed [While], keeping the high-level form for the formatter and for the
         identical re-lowering in [To_wasm]. *)
      let lowered =
        Ast_utils.lower_while ~block_info:i.info ~label ~cond ~block:instrs
      in
      let typed = block ctx i.info None [||] [||] [||] lowered in
      let cond', instrs' = rebuild_while typed in
      return_statement i (While { label; cond = cond'; block = instrs' }) [||]
  | If { label; typ; cond; if_block; else_block } -> (
      let* cond' = instruction ctx cond in
      check_type ctx cond'
        (UnionFind.make (Valtype { typ = I32; internal = I32; inline = None }));
      if Array.length typ.params > 0 then
        Error.parameterized_block_expression ctx.diagnostics ~location:i.info;
      match if_inference ctx i label typ ~cond:cond' ~if_block ~else_block with
      | Some (desc, results) -> return_statement i desc results
      | None ->
          let*! params =
            array_map_opt (fun p -> internalize ctx (snd p.desc)) typ.params
          in
          let*! results = array_map_opt (internalize ctx) typ.results in
          let if_block' =
            {
              if_block with
              desc = block ctx i.info label params results results if_block.desc;
            }
          in
          let else_block' =
            match else_block with
            | Some b ->
                Some
                  {
                    b with
                    desc = block ctx i.info label params results results b.desc;
                  }
            | None ->
                if not (missing_else_ok ctx params results) then
                  Error.if_without_else ctx.diagnostics ~location:i.info;
                None
          in
          return_statement i
            (If
               {
                 label;
                 typ;
                 cond = cond';
                 if_block = if_block';
                 else_block = else_block';
               })
            results)
  | If_annotation { cond; then_body; else_body } ->
      (* Type each branch as an isolated block, under the branch's assumption so
         names resolve per branch (a name may be declared only in, or with a
         different type in, the matching configuration). *)
      let then_body' =
        with_cond ctx ~location:i.info cond true (fun () ->
            block ctx i.info None [||] [||] [||] then_body)
      in
      let else_body' =
        Option.map
          (fun b ->
            with_cond ctx ~location:i.info cond false (fun () ->
                block ctx i.info None [||] [||] [||] b))
          else_body
      in
      return_statement i
        (If_annotation { cond; then_body = then_body'; else_body = else_body' })
        [||]
  | TryTable { label; typ; block = body; catches } -> (
      if Array.length typ.params > 0 then
        Error.parameterized_block_expression ctx.diagnostics ~location:i.info;
      match trytable_inference ctx i label typ ~body ~catches with
      | Some (desc, results) -> return_statement i desc results
      | None ->
          let*! params =
            array_map_opt (fun p -> internalize ctx (snd p.desc)) typ.params
          in
          let*! results = array_map_opt (internalize ctx) typ.results in
          let body' = block ctx i.info label params results results body in
          check_trytable_catches ctx catches;
          return_statement i
            (TryTable { label; typ; block = body'; catches })
            results)
  | Try { label; typ; block = body; catches; catch_all } -> (
      assert (typ.params = [||]);
      match try_inference ctx i label typ ~body ~catches ~catch_all with
      | Some (desc, results) -> return_statement i desc results
      | None ->
          let*! results = array_map_opt (internalize ctx) typ.results in
          let body' = block ctx i.info label [||] results results body in
          let catches, catch_all =
            type_try_catches ctx i label ~results catches catch_all
          in
          return_statement i
            (Try { label; typ; block = body'; catches; catch_all })
            results)
  | (Unreachable | Nop) as desc ->
      (* [unreachable] and [nop] are statements that yield no value; they are
         only meaningful in statement (top-level) position, where
         [toplevel_instruction] handles them. Reaching here means one was used
         where a value is expected, so report it and recover with an unknown
         value. *)
      Error.not_an_expression ctx.diagnostics ~location:i.info 0;
      return_expression i desc (UnionFind.make Error)
  | Hole ->
      let* ty = pop_parameter in
      return_expression i Hole ty
  | Null -> return_expression i Null (UnionFind.make Null)
  | Get idx as desc ->
      let ty =
        match resolve_variable ctx idx with
        | Local ty ->
            ctx.read_locals := StringSet.add idx.desc !(ctx.read_locals);
            if not (StringSet.mem idx.desc ctx.initialized_locals) then
              Error.uninitialized_local ctx.diagnostics ~location:idx.info idx;
            (* A poison local ([None]) reads as [Error] so its uses don't
               cascade. *)
            UnionFind.make
              (match ty with Some ity -> Valtype ity | None -> Error)
        | Global (_, ty) ->
            UnionFind.make
              (match ty with Some ity -> Valtype ity | None -> Error)
        | Func_ref (ty, ty') ->
            let name = Ast.no_loc ty' in
            UnionFind.make
              (Valtype
                 {
                   typ = Ref { nullable = false; typ = Type name };
                   internal = Ref { nullable = false; typ = Type ty };
                   inline = inline_comptype ctx name;
                 })
        | Unbound ->
            Error.unbound_name ctx.diagnostics ~location:idx.info
              ~suggestions:(get_suggestions ctx idx.desc)
              "variable" idx;
            UnionFind.make Error
      in
      return_expression i desc ty
  | Set (None, i') ->
      let* i' = instruction ctx i' in
      (* [_ = e] drops one value, so [e] must produce exactly one; otherwise wax
         emits a [drop] with nothing (or too much) on the stack. [expression_type]
         reports [not_an_expression] when the arity is not 1. *)
      ignore (expression_type ctx i' : inferred_type UnionFind.t);
      return_statement i (Set (None, i')) [||]
  | Set (Some idx, i') ->
      (* Resolve the target first (a pure lookup) so the value can be checked
         against its type, letting a struct/array literal drop its name. The
         local is marked initialized only after the value is typed, so an
         assignment reading the same local (e.g. [x = x + 1]) still sees its
         pre-assignment state. *)
      let resolved = resolve_variable ctx idx in
      let* i' =
        match resolved with
        | Local (Some ity) | Global (_, Some ity) ->
            let* i', _ =
              check_instruction ctx (UnionFind.make (Valtype ity)) i'
            in
            return i'
        | Local None | Global (_, None) | Func_ref _ | Unbound ->
            instruction ctx i'
      in
      (match resolved with
      | Local _ -> mark_initialized ctx idx.desc
      | Global (mut, _) ->
          if not mut then
            Error.immutable ctx.diagnostics ~location:idx.info "global"
      | Func_ref _ ->
          Error.not_assignable ctx.diagnostics ~location:idx.info idx
      | Unbound ->
          Error.unbound_name ctx.diagnostics ~location:idx.info
            ~suggestions:(set_suggestions ctx idx.desc)
            "variable" idx);
      return_statement i (Set (Some idx, i')) [||]
  | Tee (idx, i') -> (
      (* Only a local is assignable. Resolve it first so the value can be
         checked against the local's type (letting a struct/array literal drop
         its name); anything else is an error, after which we recover with the
         operand's own type rather than [Unknown], which [check_type] cannot
         match against. *)
      match resolve_variable ctx idx with
      | Local (Some ity) ->
          let typ = UnionFind.make (Valtype ity) in
          let* i', _ = check_instruction ctx typ i' in
          mark_initialized ctx idx.desc;
          return_expression i (Tee (idx, i')) typ
      | Local None ->
          (* Poison local: recover with the operand's own type, no check. *)
          let* i' = instruction ctx i' in
          mark_initialized ctx idx.desc;
          return_expression i (Tee (idx, i')) (expression_type ctx i')
      | Global _ | Func_ref _ ->
          let* i' = instruction ctx i' in
          Error.not_assignable ctx.diagnostics ~location:idx.info idx;
          return_expression i (Tee (idx, i')) (expression_type ctx i')
      | Unbound ->
          let* i' = instruction ctx i' in
          Error.unbound_name ctx.diagnostics ~location:idx.info
            ~suggestions:(local_suggestions ctx idx.desc)
            "variable" idx;
          return_expression i (Tee (idx, i')) (expression_type ctx i'))
  | Call _ -> call_instruction ctx i
  | TailCall (i', l) -> (
      let param_types = peek_call_params ctx i' in
      let* l' = typed_call_args ctx l param_types in
      let* i' = instruction ctx i' in
      match UnionFind.find (expression_type ctx i') with
      | Valtype { typ = Ref { typ = Type ty; _ }; _ } ->
          let*! typ = lookup_func_type ctx ty in
          (let>@ param_types =
             array_map_opt (fun p -> internalize ctx (snd p.desc)) typ.params
           in
           if Array.length param_types <> List.length l' then
             Error.value_count_mismatch ctx.diagnostics ~location:i.info
               ~expected:(Array.length param_types) ~provided:(List.length l')
           else
             Array.iter2
               (fun i ty -> check_type ctx i ty)
               (Array.of_list l') param_types);
          (let>@ returned_types = array_map_opt (internalize ctx) typ.results in
           check_subtypes ctx ~location:i.info returned_types ctx.return_types);
          return_statement i (TailCall (i', l')) [||]
      | Error ->
          (* The callee already failed to type; recover without a spurious
             "expected function type". *)
          return_statement i (TailCall (i', l')) [||]
      | Unknown ->
          (* The callee's type is unknown (unreachable / branch code): the
             function type cannot be resolved, so the call cannot be compiled. *)
          Error.unknown_operand_type ctx.diagnostics ~location:(snd i'.info);
          return_statement i (TailCall (i', l')) [||]
      | _ ->
          Error.expected_func_type ctx.diagnostics ~location:i.info;
          return_statement i (TailCall (i', l')) [||])
  | Char _ as desc ->
      return_expression i desc
        (UnionFind.make (Valtype { typ = I32; internal = I32; inline = None }))
  | Int s as desc ->
      (* Pick the lattice type from the magnitude (the sign is a separate [Neg],
         so this is unsigned): a value over the 32-bit range cannot be i32, so it
         is [LargeInt] (which defaults to i64) rather than the i32-defaulting
         [Number]; one that does not even fit u64 cannot be any integer type, so
         it is [Float] (representable only by f32/f64) — using it as an integer is
         then a clean type error rather than an [Int64.of_string] crash in the
         encoder. *)
      let lattice =
        match
          if String.starts_with ~prefix:"0x" s then Int64.of_string_opt s
          else Int64.of_string_opt ("0u" ^ s)
        with
        | None -> Float
        | Some v when Int64.unsigned_compare v 0xFFFFFFFFL > 0 -> LargeInt
        | Some _ -> Number
      in
      return_expression i desc (UnionFind.make lattice)
  | Float _ as desc -> return_expression i desc (UnionFind.make Float)
  | Cast _ | Test _ -> type_cast ctx i
  | Struct _ | StructDefault _ | Array _ | ArrayDefault _ | ArrayFixed _
  | ArraySegment _ | String _ ->
      let* i', _ = check_instruction ctx (UnionFind.make Unknown) i in
      return i'
  | StructGet (i', field) ->
      let* i' = instruction ctx i' in
      let*! ty =
        let ty = expression_type ctx i' in
        match (UnionFind.find ty, field.desc) with
        | Valtype { typ = Ref { typ = Type ty; _ }; _ }, _ -> (
            let*@ _, def = Tbl.find_opt ctx.type_context.types ty in
            match def.typ with
            | Struct fields -> (
                match
                  Array.find_map
                    (fun f ->
                      let nm, typ = f.desc in
                      if nm.desc = field.desc then Some typ else None)
                    fields
                with
                | Some typ -> field_read_type ctx typ
                | None ->
                    Error.missing_field ctx.diagnostics ~location:field.info
                      field;
                    None)
            | Func _ | Array _ | Cont _ ->
                if is_unary_method field.desc then
                  Error.method_needs_parentheses ctx.diagnostics
                    ~location:field.info field.desc
                else
                  Error.expected_struct_type ctx.diagnostics
                    ~location:(snd i'.info);
                None)
        (* Leave a receiver that already failed to type alone (its error is
           reported elsewhere): keep the access with an error result type rather
           than giving up, which would drop a hole receiver and desync hole
           counting. *)
        | Error, _ -> Some (UnionFind.make Error)
        (* The receiver's type is unknown (unreachable / branch code): the
           struct type cannot be resolved, so the field cannot be read. *)
        | Unknown, _ ->
            Error.unknown_operand_type ctx.diagnostics ~location:(snd i'.info);
            Some (UnionFind.make Error)
        (* A name that is an instruction method was likely meant as the
           parenthesised call [x.sqrt()]; any other field access on a non-struct
           type has no fields to find. *)
        | _ when is_unary_method field.desc ->
            Error.method_needs_parentheses ctx.diagnostics ~location:field.info
              field.desc;
            None
        | _ ->
            Error.expected_struct_type ctx.diagnostics ~location:(snd i'.info);
            None
      in
      return_expression i (StructGet (i', field)) ty
  | StructSet (i1, field, i2) ->
      let* i1' = instruction ctx i1 in
      (* Resolve the field's declared type (pure, reporting any field error)
         before typing the value, so the value can be checked against it and a
         struct/array literal can drop its name. The value is then typed on
         every path, so its holes are always consumed. *)
      let expected =
        match UnionFind.find (expression_type ctx i1') with
        | Valtype { typ = Ref { typ = Type ty; _ }; _ } -> (
            match lookup_struct_type ctx ty with
            | None -> None
            | Some fields -> (
                match
                  Array.find_map
                    (fun f ->
                      let nm, ftyp = f.desc in
                      if nm.desc = field.desc then Some ftyp else None)
                    fields
                with
                | None ->
                    Error.missing_field ctx.diagnostics ~location:field.info
                      field;
                    None
                | Some ftyp ->
                    if not ftyp.mut then
                      Error.immutable ctx.diagnostics ~location:field.info
                        "field";
                    internalize ctx (unpack_type ftyp)))
        | Error ->
            (* Receiver already failed to type; recover without a spurious
               "expected struct type". *)
            None
        | Unknown ->
            (* The receiver's type is unknown (unreachable / branch code): the
               struct type cannot be resolved, so the field cannot be written. *)
            Error.unknown_operand_type ctx.diagnostics ~location:i1.info;
            None
        | _ ->
            Error.expected_struct_type ctx.diagnostics ~location:i1.info;
            None
      in
      let* i2' =
        match expected with
        | Some cell ->
            let* i2', _ = check_instruction ctx cell i2 in
            return i2'
        | None -> instruction ctx i2
      in
      return_statement i (StructSet (i1', field, i2')) [||]
  (* [tab[i]] on a table name is [table.get]; the receiver is not a value. *)
  | ArrayGet (({ desc = Get tabname; _ } as recv), i2)
    when Tbl.find_opt ctx.tables tabname <> None ->
      let at, rt = Option.get (Tbl.find_opt ctx.tables tabname) in
      let* i2' = instruction ctx i2 in
      check_type ctx i2' (UnionFind.make (Valtype (address_valtype at)));
      let*! typ = internalize ctx (Ref rt) in
      return_expression i
        (ArrayGet ({ desc = Get tabname; info = ([||], recv.info) }, i2'))
        typ
  | ArrayGet (i1, i2) -> (
      let* i1' = instruction ctx i1 in
      let* i2' = instruction ctx i2 in
      check_type ctx i2'
        (UnionFind.make (Valtype { typ = I32; internal = I32; inline = None }));
      match UnionFind.find (expression_type ctx i1') with
      | Valtype { typ = Ref { typ = Type ty; _ }; _ } ->
          let*! typ = lookup_array_type ~location:i1.info ctx ty in
          let*! ty = field_read_type ctx typ in
          return_expression i (ArrayGet (i1', i2')) ty
      | Error ->
          (* Receiver already failed to type; recover silently. *)
          return_expression i (ArrayGet (i1', i2')) (UnionFind.make Error)
      | Unknown ->
          (* The receiver's type is unknown (unreachable / branch code): the
             array type cannot be resolved, so the element cannot be read. *)
          Error.unknown_operand_type ctx.diagnostics ~location:i1.info;
          return_expression i (ArrayGet (i1', i2')) (UnionFind.make Error)
      | _ ->
          Error.expected_array_type ctx.diagnostics ~location:i1.info;
          return_expression i (ArrayGet (i1', i2')) (UnionFind.make Error))
  (* [tab[i] = v] on a table name is [table.set]; the receiver is not a value. *)
  | ArraySet (({ desc = Get tabname; _ } as recv), i2, i3)
    when Tbl.find_opt ctx.tables tabname <> None ->
      let at, rt = Option.get (Tbl.find_opt ctx.tables tabname) in
      let* i2' = instruction ctx i2 in
      check_type ctx i2' (UnionFind.make (Valtype (address_valtype at)));
      (* Check the stored value against the table's element type, so a
         struct/array literal can drop its name. *)
      let* i3' =
        match internalize ctx (Ref rt) with
        | Some cell ->
            let* i3', _ = check_instruction ctx cell i3 in
            return i3'
        | None -> instruction ctx i3
      in
      return_statement i
        (ArraySet ({ desc = Get tabname; info = ([||], recv.info) }, i2', i3'))
        [||]
  | ArraySet (i1, i2, i3) -> (
      let* i1' = instruction ctx i1 in
      let* i2' = instruction ctx i2 in
      check_type ctx i2'
        (UnionFind.make (Valtype { typ = I32; internal = I32; inline = None }));
      match UnionFind.find (expression_type ctx i1') with
      | Valtype { typ = Ref { typ = Type ty; _ }; _ } ->
          (* Resolve the element type (pure) before typing the value, so a
             struct/array literal value can drop its name. *)
          let expected =
            match lookup_array_type ~location:i1.info ctx ty with
            | None -> None
            | Some typ ->
                if not typ.mut then
                  Error.immutable ctx.diagnostics ~location:i1.info "array";
                internalize ctx (unpack_type typ)
          in
          let* i3' =
            match expected with
            | Some cell ->
                let* i3', _ = check_instruction ctx cell i3 in
                return i3'
            | None -> instruction ctx i3
          in
          return_statement i (ArraySet (i1', i2', i3')) [||]
      | Error ->
          (* Receiver already failed to type; recover silently (still type the
             value so its holes are consumed). *)
          let* i3' = instruction ctx i3 in
          return_statement i (ArraySet (i1', i2', i3')) [||]
      | Unknown ->
          (* The receiver's type is unknown (unreachable / branch code): the
             array type cannot be resolved, so the element cannot be written.
             Still type the value so its holes are consumed. *)
          let* i3' = instruction ctx i3 in
          Error.unknown_operand_type ctx.diagnostics ~location:i1.info;
          return_statement i (ArraySet (i1', i2', i3')) [||]
      | _ ->
          let* i3' = instruction ctx i3 in
          Error.expected_array_type ctx.diagnostics ~location:i1.info;
          return_statement i (ArraySet (i1', i2', i3')) [||])
  | BinOp _ | UnOp _ -> type_arith ctx i
  | Let ([ (name_opt, Some annot) ], Some i') -> (
      (* Bidirectional single annotated binding: type the initializer in
         checking mode against the annotation, so an omitted struct/array name
         is inferred from it; the keep-bool then says whether the annotation is
         load-bearing. Dropping a present annotation stays gated on [simplify]
         (Wasm->Wax), so hand-written Wax is never rewritten. A binding no later
         assignment writes is effectively immutable, so — like a [const] global
         — it also drops an annotation that is a mere supertype of the
         initializer's type ([drop_supertype]), narrowing to that subtype. *)
      match internalize_valtype ctx annot with
      | None ->
          let* i' = instruction ctx i' in
          return_statement i (Let ([ (name_opt, Some annot) ], Some i')) [||]
      | Some ity ->
          let drop_supertype =
            match name_opt with
            | Some name -> not (StringSet.mem name.desc ctx.assigned_locals)
            | None -> true
          in
          let* i', needed =
            check_instruction ~drop_supertype ctx
              (UnionFind.make (Valtype ity))
              i'
          in
          Option.iter
            (fun name ->
              ctx.locals <- StringMap.add name.desc (Some ity) ctx.locals;
              ctx.local_decls := name :: !(ctx.local_decls);
              mark_initialized ctx name.desc)
            name_opt;
          let drop = ctx.simplify && not needed in
          return_statement i
            (Let ([ (name_opt, if drop then None else Some annot) ], Some i'))
            [||])
  | Let (bindings, Some i') ->
      let* i' = instruction ctx i' in
      let bindings =
        match bindings with
        | [ binding ] ->
            (* Single binding: the initializer must be a one-value expression;
               [expression_type] reports it if it is not. *)
            [
              bind_let_value ctx ~location:(snd i'.info)
                (expression_type ctx i') binding;
            ]
        | _ ->
            (* Each name takes one value off a multi-value initializer, left to
               right (the names match the values in order). *)
            let result_types = fst i'.info in
            let n = List.length bindings in
            if Array.length result_types <> n then
              Error.value_count_mismatch ctx.diagnostics ~location:i.info
                ~expected:n
                ~provided:(Array.length result_types);
            List.mapi
              (fun idx binding ->
                let result_ty =
                  if idx < Array.length result_types then result_types.(idx)
                  else UnionFind.make Error
                in
                bind_let_value ctx ~location:i.info result_ty binding)
              bindings
      in
      return_statement i (Let (bindings, Some i')) [||]
  | Let (bindings, None) ->
      (* No initializer: each annotated name declares a local at its zero
         value; an unannotated name has no type to take and is left out. *)
      List.iter
        (fun (name, typ) ->
          match (name, typ) with
          | Some name, Some typ ->
              let>@ ity = internalize_valtype ctx typ in
              ctx.locals <- StringMap.add name.desc (Some ity) ctx.locals;
              ctx.local_decls := name :: !(ctx.local_decls);
              (* A defaultable local holds its zero value; a non-defaultable one
                 stays uninitialized until assigned. *)
              if is_defaultable typ then mark_initialized ctx name.desc
          | _ -> ())
        bindings;
      return_statement i (Let (bindings, None)) [||]
  | Br _ | Br_if _ | Br_table _ | Br_on_null _ | Br_on_non_null _ | Br_on_cast _
  | Br_on_cast_fail _ ->
      type_branch ctx i
  | Throw (tag, i') ->
      let* i' =
        match i' with
        | Some i' ->
            let* i' = instruction ctx i' in
            return (Some i')
        | None -> return None
      in
      (let>@ { params; results } = Tbl.find ctx.diagnostics ctx.tags tag in
       if results <> [||] then
         Error.tag_with_results ctx.diagnostics ~location:tag.info;
       let>@ types =
         array_map_opt (fun p -> internalize ctx (snd p.desc)) params
       in
       match i' with
       | Some i' ->
           check_subtypes ctx ~location:(snd i'.info) (fst i'.info) types
       | None ->
           if types <> [||] then
             Error.value_count_mismatch ctx.diagnostics ~location:i.info
               ~expected:(Array.length types) ~provided:0);
      return_statement i (Throw (tag, i')) [||]
  | ThrowRef i' ->
      let* i' = instruction ctx i' in
      (let>@ typ = internalize ctx (Ref { nullable = true; typ = Exn }) in
       check_type ctx i' typ);
      return_statement i (ThrowRef i') [||]
  | ContNew _ | ContBind _ | Suspend _ | Resume _ | ResumeThrow _
  | ResumeThrowRef _ | Switch _ ->
      type_stack_switching ctx i
  | NonNull i' -> (
      let* i' = instruction ctx i' in
      match UnionFind.find (expression_type ctx i') with
      | Valtype
          {
            typ = Ref { nullable = _; typ; _ };
            internal = Ref { nullable = _; typ = ityp; _ };
            inline;
          } ->
          return_expression i (NonNull i')
            (UnionFind.make
               (Valtype
                  {
                    typ = Ref { nullable = false; typ };
                    internal = Ref { nullable = false; typ = ityp };
                    inline;
                  }))
      | Unknown | Error ->
          return_expression i (NonNull i') (expression_type ctx i')
      | _ ->
          Error.expected_ref ctx.diagnostics ~location:(snd i'.info);
          return_expression i (NonNull i') (UnionFind.make Error))
  | Return i' ->
      let* i' =
        match i' with
        | Some i' ->
            let* i' = check_against ctx ctx.return_types i' in
            return (Some i')
        | None ->
            if ctx.return_types <> [||] then
              Error.value_count_mismatch ctx.diagnostics ~location:i.info
                ~expected:(Array.length ctx.return_types)
                ~provided:0;
            return None
      in
      return_statement i (Return i') [||]
  | Sequence l ->
      let* l' = instructions ctx l in
      return_statement i (Sequence l')
        (Array.map (expression_type ctx) (Array.of_list l'))
  | Select (i1, i2, i3) ->
      let* i2' = instruction ctx i2 in
      let* i3' = instruction ctx i3 in
      let* i1' = instruction ctx i1 in
      check_type ctx i1'
        (UnionFind.make (Valtype { typ = I32; internal = I32; inline = None }));
      let*! ty =
        let ty1 = expression_type ctx i2' in
        let ty2 = expression_type ctx i3' in
        match (UnionFind.find ty1, UnionFind.find ty2) with
        | _, (Unknown | Error) -> Some ty1
        | (Unknown | Error), _ -> Some ty2
        | Valtype { internal = I32; _ }, Valtype { internal = I32; _ }
        | Valtype { internal = I64; _ }, Valtype { internal = I64; _ }
        | Valtype { internal = F32; _ }, Valtype { internal = F32; _ }
        | Valtype { internal = F64; _ }, Valtype { internal = F64; _ } ->
            Some ty2
        | (Int | Number), (Int | Valtype { internal = I32 | I64; _ })
        | (Float | Number), (Float | Valtype { internal = F32 | F64; _ })
        | Number, Number ->
            UnionFind.merge ty1 ty2 (UnionFind.find ty2);
            Some ty2
        | ( (Valtype { internal = I32; _ } | Valtype { internal = I64; _ }),
            (Int | Number) )
        | ( (Valtype { internal = F32; _ } | Valtype { internal = F64; _ }),
            (Float | Number) )
        | (Int | Float), Number ->
            UnionFind.merge ty1 ty2 (UnionFind.find ty1);
            Some ty1
        | Valtype { typ = typ1; _ }, Valtype { typ = typ2; _ } -> (
            match val_lub ctx typ1 typ2 with
            | Some ty -> internalize ctx ty
            | None ->
                Error.select_type_mismatch ctx.diagnostics ~location:i.info
                  ~loc1:i2.info ~loc2:i3.info ty1 ty2;
                None)
        | Valtype { typ = Ref { typ; _ }; _ }, Null ->
            let*@ ty = internalize ctx (Ref { typ; nullable = true }) in
            UnionFind.set ty2 (UnionFind.find ty);
            Some ty
        | Null, Valtype { typ = Ref { typ; _ }; _ } ->
            let*@ ty = internalize ctx (Ref { typ; nullable = true }) in
            UnionFind.set ty1 (UnionFind.find ty);
            Some ty
        | _ ->
            Error.select_type_mismatch ctx.diagnostics ~location:i.info
              ~loc1:i2.info ~loc2:i3.info ty1 ty2;
            None
      in
      return_expression i (Select (i1', i2', i3')) ty

and type_branch ctx i =
  (* The branch instructions: [br], [br_if], [br_table] and the [br_on_*]
     family, each checking its operand(s) against the target label's
     parameter types. *)
  match i.desc with
  | Br (label, i') ->
      (* Sequence of instructions *)
      let params = branch_target ctx label in
      let* i' =
        match i' with
        | Some i' ->
            let* i' = check_against ctx params i' in
            return (Some i')
        | None ->
            if params <> [||] then
              Error.value_count_mismatch ctx.diagnostics ~location:i.info
                ~expected:(Array.length params) ~provided:0;
            return None
      in
      return_statement i (Br (label, i')) [||]
  | Br_if (label, i') ->
      let* i' = instruction ctx i' in
      let loc = snd i'.info in
      let ty, types = split_on_last_type ctx ~location:loc i' in
      check_subtype ctx ~location:loc ty
        (UnionFind.make (Valtype { typ = I32; internal = I32; inline = None }));
      let params = branch_target ctx label in
      check_subtypes ctx ~location:loc types params;
      (* On the fall-through the values stay on the stack; type them by what they
         already are ([types], checked against the target just above) rather than
         by [params]. For a concrete target the two coincide, but when the target
         is a block result still being inferred ([params] is a [Collecting] cell),
         returning [params] would leak that cell onto the stack as [any]. *)
      let result = if Array.exists is_inferring params then types else params in
      return_statement i (Br_if (label, i')) result
  | Br_table (labels, i') ->
      let* i' = instruction ctx i' in
      let loc = snd i'.info in
      let ty, types = split_on_last_type ctx ~location:loc i' in
      check_subtype ctx ~location:loc ty
        (UnionFind.make (Valtype { typ = I32; internal = I32; inline = None }));
      let len = Array.length (branch_target ctx (List.hd labels)) in
      List.iter
        (fun label ->
          let params = branch_target ctx label in
          if Array.length params <> len then
            Error.value_count_mismatch ctx.diagnostics ~location:i.info
              ~expected:len ~provided:(Array.length params);
          check_subtypes ctx ~location:loc types params)
        labels;
      return_statement i (Br_table (labels, i')) [||]
  | Br_on_null (idx, i') ->
      let* i' = instruction ctx i' in
      let typ, types = split_on_last_type ctx ~location:(snd i'.info) i' in
      let typ = UnionFind.find typ in
      let typ' =
        match typ with
        | Valtype
            {
              typ = Ref { nullable = _; typ; _ };
              internal = Ref { nullable = _; typ = ityp; _ };
              inline;
            } ->
            UnionFind.make
              (Valtype
                 {
                   typ = Ref { nullable = false; typ };
                   internal = Ref { nullable = false; typ = ityp };
                   inline;
                 })
        | (Unknown | Error) as ity -> UnionFind.make ity
        | _ ->
            Error.expected_ref ctx.diagnostics ~location:(snd i'.info);
            UnionFind.make Error
      in
      let params = branch_target ctx idx in
      check_subtypes ctx ~location:(snd i'.info) types params;
      return_statement i (Br_on_null (idx, i')) (Array.append params [| typ' |])
  | Br_on_non_null (idx, i') ->
      let* i' = instruction ctx i' in
      let params = branch_target ctx idx in
      let typ, types = split_on_last_type ctx ~location:(snd i'.info) i' in
      let typ = UnionFind.find typ in
      (match typ with
      | Unknown | Error -> ()
      | Valtype
          {
            typ = Ref { nullable = _; typ; _ };
            internal = Ref { nullable = _; typ = ityp; _ };
            inline;
          } ->
          check_subtypes ctx ~location:(snd i'.info)
            (Array.append types
               [|
                 UnionFind.make
                   (Valtype
                      {
                        typ = Ref { nullable = false; typ };
                        internal = Ref { nullable = false; typ = ityp };
                        inline;
                      });
               |])
            params
      | _ -> Error.expected_ref ctx.diagnostics ~location:(snd i'.info));
      return_statement i
        (Br_on_non_null (idx, i'))
        (Array.sub params 0 (Array.length params - 1))
  | Br_on_cast (label, ty, i') ->
      let* i' = instruction ctx i' in
      if is_cont_heaptype ctx ty.typ then
        Error.invalid_cast_type ctx.diagnostics ~location:i.info;
      let typ', types = split_on_last_type ctx ~location:(snd i'.info) i' in
      let params = branch_target ctx label in
      (let>@ ityp = reftype ctx.diagnostics ctx.type_context ty in
       let typ =
         UnionFind.make
           (Valtype { typ = Ref ty; internal = Ref ityp; inline = None })
       in
       check_subtypes ctx ~location:(snd i'.info)
         (Array.append types [| typ |])
         params);
      let*! typ1, typ2 =
        match UnionFind.find typ' with
        | Valtype { typ = Ref ty'; _ } ->
            let*@ ty1 = val_lub ctx (Ref ty) (Ref ty') in
            let*@ typ1 = internalize ctx ty1 in
            let+@ typ2 = internalize ctx (Ref (diff_ref_type ty' ty)) in
            (typ1, typ2)
        | (Unknown | Error) as ity -> Some (typ', UnionFind.make ity)
        | _ ->
            Error.expected_ref ctx.diagnostics ~location:(snd i'.info);
            None
      in
      return_statement i
        (Br_on_cast
           ( label,
             ty,
             { i' with info = (Array.append types [| typ1 |], snd i'.info) } ))
        (Array.append (Array.sub params 0 (Array.length params - 1)) [| typ2 |])
  | Br_on_cast_fail (label, ty, i') ->
      let* i' = instruction ctx i' in
      if is_cont_heaptype ctx ty.typ then
        Error.invalid_cast_type ctx.diagnostics ~location:i.info;
      let typ', types = split_on_last_type ctx ~location:(snd i'.info) i' in
      let*! ityp = reftype ctx.diagnostics ctx.type_context ty in
      let*! typ1, typ2 =
        match UnionFind.find typ' with
        | Valtype { typ = Ref ty'; _ } ->
            let*@ ty1 = val_lub ctx (Ref ty) (Ref ty') in
            let*@ typ1 = internalize ctx ty1 in
            let+@ typ2 = internalize ctx (Ref (diff_ref_type ty' ty)) in
            (typ1, typ2)
        | (Unknown | Error) as ity -> Some (typ', UnionFind.make ity)
        | _ ->
            Error.expected_ref ctx.diagnostics ~location:(snd i'.info);
            None
      in
      let params = branch_target ctx label in
      check_subtypes ctx ~location:(snd i'.info)
        (Array.append types [| typ2 |])
        params;
      let typ =
        UnionFind.make
          (Valtype { typ = Ref ty; internal = Ref ityp; inline = None })
      in
      return_statement i
        (Br_on_cast_fail
           ( label,
             ty,
             { i' with info = (Array.append types [| typ1 |], snd i'.info) } ))
        (Array.append (Array.sub params 0 (Array.length params - 1)) [| typ |])
  | _ -> assert false (* only invoked on a branch instruction *)

and type_stack_switching ctx i =
  (* The typed-continuation / stack-switching instructions: cont.new, cont.bind,
     suspend, resume(.throw), and switch. *)
  match i.desc with
  | ContNew (ct, f) ->
      let* f' = instruction ctx f in
      let*! ft = lookup_cont_inner ctx ct in
      (let>@ fref = internalize ctx (Ref { nullable = true; typ = Type ft }) in
       check_type ctx f' fref);
      let*! cref = internalize ctx (Ref { nullable = false; typ = Type ct }) in
      return_expression i (ContNew (ct, f')) cref
  | ContBind (src, dst, l) ->
      let* l' = instructions ctx l in
      let*! src_inner = lookup_cont_inner ctx src in
      let*! src_sig = lookup_func_type ctx src_inner in
      let*! dst_inner = lookup_cont_inner ctx dst in
      let*! dst_sig = lookup_func_type ctx dst_inner in
      let np = Array.length src_sig.params - Array.length dst_sig.params in
      (* The destination continuation must be [src] with its leading [np]
         parameters bound away: the unbound tail and the results must match.
         Mirrors [Validation]'s [ContBind] check. *)
      (if np < 0 then
         Error.stack_switching_type_mismatch ctx.diagnostics ~location:i.info
           ~descr:
             "the resulting continuation takes more parameters than the \
              original one"
       else
         let>@ src_ft = internal_functype ctx src_sig in
         let>@ dst_ft = internal_functype ctx dst_sig in
         let ts12 = Array.sub src_ft.params np (Array.length dst_ft.params) in
         if
           not
             (functype_matches ctx.subtyping_info
                { params = ts12; results = src_ft.results }
                dst_ft)
         then
           Error.stack_switching_type_mismatch ctx.diagnostics ~location:i.info
             ~descr:
               "the bound parameters and results do not match between the two \
                continuation types");
      (let n = max 0 np in
       let>@ bound =
         array_map_opt
           (fun p -> internalize ctx (snd p.desc))
           (Array.sub src_sig.params 0 n)
       in
       let>@ srcref =
         internalize ctx (Ref { nullable = true; typ = Type src })
       in
       check_operands ctx l' (Array.append bound [| srcref |]));
      let*! dstref =
        internalize ctx (Ref { nullable = false; typ = Type dst })
      in
      return_expression i (ContBind (src, dst, l')) dstref
  | Suspend (tag, l) ->
      let* l' = instructions ctx l in
      let*! { params; results } = Tbl.find ctx.diagnostics ctx.tags tag in
      (let>@ ptypes =
         array_map_opt (fun p -> internalize ctx (snd p.desc)) params
       in
       check_operands ctx l' ptypes);
      let*! rtypes = array_map_opt (internalize ctx) results in
      return_statement i (Suspend (tag, l')) rtypes
  | Resume (ct, handlers, l) ->
      let* l' = instructions ctx l in
      let*! inner = lookup_cont_inner ctx ct in
      let*! sg = lookup_func_type ctx inner in
      (let>@ ptypes =
         array_map_opt (fun p -> internalize ctx (snd p.desc)) sg.params
       in
       let>@ cref = internalize ctx (Ref { nullable = true; typ = Type ct }) in
       check_operands ctx l' (Array.append ptypes [| cref |]));
      check_resume_handlers ctx ~result_types:sg.results handlers;
      let*! rtypes = array_map_opt (internalize ctx) sg.results in
      return_statement i (Resume (ct, handlers, l')) rtypes
  | ResumeThrow (ct, tag, handlers, l) ->
      let* l' = instructions ctx l in
      let*! inner = lookup_cont_inner ctx ct in
      let*! sg = lookup_func_type ctx inner in
      let*! { params = tparams; _ } = Tbl.find ctx.diagnostics ctx.tags tag in
      (let>@ ptypes =
         array_map_opt (fun p -> internalize ctx (snd p.desc)) tparams
       in
       let>@ cref = internalize ctx (Ref { nullable = true; typ = Type ct }) in
       check_operands ctx l' (Array.append ptypes [| cref |]));
      check_resume_handlers ctx ~result_types:sg.results handlers;
      let*! rtypes = array_map_opt (internalize ctx) sg.results in
      return_statement i (ResumeThrow (ct, tag, handlers, l')) rtypes
  | ResumeThrowRef (ct, handlers, l) ->
      let* l' = instructions ctx l in
      let*! inner = lookup_cont_inner ctx ct in
      let*! sg = lookup_func_type ctx inner in
      (let>@ exnref = internalize ctx (Ref { nullable = true; typ = Exn }) in
       let>@ cref = internalize ctx (Ref { nullable = true; typ = Type ct }) in
       check_operands ctx l' [| exnref; cref |]);
      check_resume_handlers ctx ~result_types:sg.results handlers;
      let*! rtypes = array_map_opt (internalize ctx) sg.results in
      return_statement i (ResumeThrowRef (ct, handlers, l')) rtypes
  | Switch (ct, tag, l) ->
      let* l' = instructions ctx l in
      let*! inner = lookup_cont_inner ctx ct in
      let*! sg = lookup_func_type ctx inner in
      let tag_sig = Tbl.find ctx.diagnostics ctx.tags tag in
      let np = Array.length sg.params in
      (if np >= 1 then
         let>@ lead =
           array_map_opt
             (fun p -> internalize ctx (snd p.desc))
             (Array.sub sg.params 0 (np - 1))
         in
         let>@ cref =
           internalize ctx (Ref { nullable = true; typ = Type ct })
         in
         check_operands ctx l' (Array.append lead [| cref |]));
      (* The last parameter of [ct]'s function type must itself be a
         continuation type; the result is that inner continuation's parameter
         types. *)
      let inner_sg =
        match if np = 0 then None else Some (snd sg.params.(np - 1).desc) with
        | Some (Ref { typ = Type ct2; _ }) ->
            let*@ inner2 = lookup_cont_inner ctx ct2 in
            lookup_func_type ctx inner2
        | _ -> None
      in
      (* The 'switch' tag must take no parameters and its results must match
         both continuation types. Mirrors [Validation]'s [Switch] check. *)
      let to_internal arr =
        array_map_opt
          (fun typ ->
            let+@ iv = internalize_valtype ctx typ in
            iv.internal)
          arr
      in
      let result_subtype a b =
        match (to_internal a, to_internal b) with
        | Some a, Some b ->
            Array.length a = Array.length b
            && Array.for_all Fun.id
                 (Array.mapi
                    (fun i t ->
                      Wax_wasm.Types.val_subtype ctx.subtyping_info t b.(i))
                    a)
        | _ -> true
      in
      (match inner_sg with
      | None ->
          Error.stack_switching_type_mismatch ctx.diagnostics ~location:i.info
            ~descr:
              "the continuation's last parameter must itself be a continuation \
               type"
      | Some inner_sg -> (
          match tag_sig with
          | None -> ()
          | Some { params = tparams; results = tresults } ->
              if
                Array.length tparams <> 0
                || (not (result_subtype sg.results tresults))
                || not (result_subtype tresults inner_sg.results)
              then
                Error.stack_switching_type_mismatch ctx.diagnostics
                  ~location:i.info
                  ~descr:
                    "the 'switch' tag must take no parameters and its results \
                     must match the two continuation types"));
      let result_params =
        match inner_sg with Some s2 -> s2.params | None -> [||]
      in
      let*! rtypes =
        array_map_opt (fun p -> internalize ctx (snd p.desc)) result_params
      in
      return_statement i (Switch (ct, tag, l')) rtypes
  | _ -> assert false (* only invoked on a stack-switching instruction *)

and type_arith ctx i =
  (* Arithmetic, comparison and conversion operators in binary ([a + b]) and
     unary ([-a], [a as i64]) form. *)
  match i.desc with
  | BinOp (op, i1, i2) ->
      let* i1' = instruction ctx i1 in
      let* i2' = instruction ctx i2 in
      let ty =
        let ty1 = expression_type ctx i1' in
        let ty2 = expression_type ctx i2' in
        let mismatch () =
          (* Point at the operator itself, not the whole expression. *)
          Error.binop_type_mismatch ctx.diagnostics ~location:op.info ty1 ty2
        in
        match (UnionFind.find ty1, UnionFind.find ty2) with
        | (Unknown | Error), (Unknown | Error) -> (
            match op.desc with
            | Add | Sub | Mul ->
                UnionFind.merge ty1 ty2 Number;
                ty1
            | Div (Some _) | Rem _ | And | Or | Xor | Shl | Shr _ ->
                UnionFind.merge ty1 ty2 Int;
                ty1
            | Lt (Some _) | Gt (Some _) | Le (Some _) | Ge (Some _) | Eq | Ne ->
                UnionFind.merge ty1 ty2
                  (Valtype { typ = I32; internal = I32; inline = None });
                UnionFind.make
                  (Valtype { typ = I32; internal = I32; inline = None })
            | Div None ->
                UnionFind.merge ty1 ty2 Float;
                ty1
            | Lt None | Gt None | Le None | Ge None ->
                UnionFind.merge ty1 ty2
                  (Valtype { typ = F32; internal = F32; inline = None });
                UnionFind.make
                  (Valtype { typ = I32; internal = I32; inline = None }))
        | typ, (Unknown | Error) | (Unknown | Error), typ -> (
            UnionFind.merge ty1 ty2 typ;
            match op.desc with
            | Eq ->
                (match typ with
                | Valtype { internal = Ref _ as ty; _ } ->
                    if
                      not
                        (Wax_wasm.Types.val_subtype ctx.subtyping_info ty
                           (Ref { nullable = true; typ = Eq }))
                    then mismatch ()
                | Null ->
                    UnionFind.set ty1
                      (Valtype
                         {
                           typ = Ref { nullable = true; typ = Eq };
                           internal = Ref { nullable = true; typ = Eq };
                           inline = None;
                         })
                | Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }
                | Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }
                | Number | Int | Float ->
                    ()
                | _ -> mismatch ());
                UnionFind.make
                  (Valtype { typ = I32; internal = I32; inline = None })
            | Add | Sub | Mul ->
                (match typ with
                | Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }
                | Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }
                | Number | Int | Float ->
                    ()
                | _ -> mismatch ());
                ty1
            | Div (Some _) | Rem _ | And | Or | Xor | Shl | Shr _ ->
                check_int_bin_op ctx ~location:op.info ty1 ty2
            | Div None -> check_float_bin_op ctx ~location:op.info ty1 ty2
            | Lt (Some _) | Gt (Some _) | Le (Some _) | Ge (Some _) ->
                (match typ with
                | Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }
                | Int ->
                    ()
                | Number -> UnionFind.set ty1 Int
                | _ -> mismatch ());
                UnionFind.make
                  (Valtype { typ = I32; internal = I32; inline = None })
            | Lt None | Gt None | Le None | Ge None ->
                (match typ with
                | Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }
                | Float ->
                    ()
                | Number -> UnionFind.set ty1 Float
                | _ -> mismatch ());
                UnionFind.make
                  (Valtype { typ = I32; internal = I32; inline = None })
            | Ne ->
                (match typ with
                | Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }
                | Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }
                | Number | Int | Float ->
                    ()
                | _ -> mismatch ());
                UnionFind.make
                  (Valtype { typ = I32; internal = I32; inline = None }))
        | _ -> (
            match op.desc with
            | Eq ->
                (match (UnionFind.find ty1, UnionFind.find ty2) with
                | ( Valtype { internal = Ref _ as ty1; _ },
                    Valtype { internal = Ref _ as ty2; _ } ) ->
                    if
                      not
                        (Wax_wasm.Types.val_subtype ctx.subtyping_info ty1
                           (Ref { nullable = true; typ = Eq })
                        && Wax_wasm.Types.val_subtype ctx.subtyping_info ty2
                             (Ref { nullable = true; typ = Eq }))
                    then mismatch ()
                | Valtype { internal = Ref _ as typ1; _ }, Null ->
                    if
                      not
                        (Wax_wasm.Types.val_subtype ctx.subtyping_info typ1
                           (Ref { nullable = true; typ = Eq }))
                    then mismatch ();
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | Null, Valtype { internal = Ref _ as typ2; _ } ->
                    if
                      not
                        (Wax_wasm.Types.val_subtype ctx.subtyping_info typ2
                           (Ref { nullable = true; typ = Eq }))
                    then mismatch ();
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | Valtype { internal = I32; _ }, Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }, Valtype { internal = I64; _ }
                | Valtype { internal = F32; _ }, Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }, Valtype { internal = F64; _ }
                  ->
                    ()
                | (Valtype { internal = I32 | I64; _ } | Int), (Number | Int)
                | ( (Valtype { internal = F32 | F64; _ } | Float),
                    (Number | Float | LargeInt) )
                | Number, Number ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty1)
                | (Number | Int), Valtype { internal = I32 | I64; _ }
                | ( (Number | Float | LargeInt),
                    Valtype { internal = F32 | F64; _ } ) ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | Valtype { internal = I64; _ }, LargeInt
                | LargeInt, (LargeInt | Number | Int) ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty1)
                | LargeInt, Valtype { internal = I64; _ }
                | (Number | Int), LargeInt ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | _ -> mismatch ());
                UnionFind.make
                  (Valtype { typ = I32; internal = I32; inline = None })
            | Add | Sub | Mul ->
                (match (UnionFind.find ty1, UnionFind.find ty2) with
                | Valtype { internal = I32; _ }, Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }, Valtype { internal = I64; _ }
                | Valtype { internal = F32; _ }, Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }, Valtype { internal = F64; _ }
                  ->
                    ()
                | (Valtype { internal = I32 | I64; _ } | Int), (Number | Int)
                | ( (Valtype { internal = F32 | F64; _ } | Float),
                    (Number | Float | LargeInt) )
                | Number, Number ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty1)
                | (Number | Int), Valtype { internal = I32 | I64; _ }
                | ( (Number | Float | LargeInt),
                    Valtype { internal = F32 | F64; _ } ) ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | Valtype { internal = I64; _ }, LargeInt
                | LargeInt, (LargeInt | Number | Int) ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty1)
                | LargeInt, Valtype { internal = I64; _ }
                | (Number | Int), LargeInt ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | _ -> mismatch ());
                ty1
            | Div (Some _) | Rem _ | And | Or | Xor | Shl | Shr _ ->
                check_int_bin_op ctx ~location:op.info ty1 ty2
            | Div None -> check_float_bin_op ctx ~location:op.info ty1 ty2
            | Lt (Some _) | Gt (Some _) | Le (Some _) | Ge (Some _) ->
                (match (UnionFind.find ty1, UnionFind.find ty2) with
                | Valtype { internal = I32; _ }, Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }, Valtype { internal = I64; _ }
                | (Valtype { internal = I32 | I64; _ } | Int), (Number | Int) ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty1)
                | (Number | Int), Valtype { internal = I32 | I64; _ } ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | Number, Number -> UnionFind.merge ty1 ty2 Int
                | Valtype { internal = I64; _ }, LargeInt
                | LargeInt, (LargeInt | Number | Int) ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty1)
                | LargeInt, Valtype { internal = I64; _ }
                | (Number | Int), LargeInt ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | _ -> mismatch ());
                UnionFind.make
                  (Valtype { typ = I32; internal = I32; inline = None })
            | Lt None | Gt None | Le None | Ge None ->
                (match (UnionFind.find ty1, UnionFind.find ty2) with
                | Valtype { internal = F32; _ }, Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }, Valtype { internal = F64; _ }
                | ( (Valtype { internal = F32 | F64; _ } | Float),
                    (Number | Float | LargeInt) ) ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty1)
                | ( (Number | Float | LargeInt),
                    Valtype { internal = F32 | F64; _ } ) ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | Number, Number -> UnionFind.merge ty1 ty2 Float
                | _ -> mismatch ());
                UnionFind.make
                  (Valtype { typ = I32; internal = I32; inline = None })
            | Ne ->
                (match (UnionFind.find ty1, UnionFind.find ty2) with
                | Valtype { internal = I32; _ }, Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }, Valtype { internal = I64; _ }
                | Valtype { internal = F32; _ }, Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }, Valtype { internal = F64; _ }
                  ->
                    ()
                | (Valtype { internal = I32 | I64; _ } | Int), (Number | Int)
                | ( (Valtype { internal = F32 | F64; _ } | Float),
                    (Number | Float | LargeInt) )
                | Number, Number ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty1)
                | (Number | Int), Valtype { internal = I32 | I64; _ }
                | ( (Number | Float | LargeInt),
                    Valtype { internal = F32 | F64; _ } ) ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | Valtype { internal = I64; _ }, LargeInt
                | LargeInt, (LargeInt | Number | Int) ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty1)
                | LargeInt, Valtype { internal = I64; _ }
                | (Number | Int), LargeInt ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | _ -> mismatch ());
                UnionFind.make
                  (Valtype { typ = I32; internal = I32; inline = None }))
      in
      return_expression i (BinOp (op, i1', i2')) ty
  | UnOp (op, i') ->
      let* i' = instruction ctx i' in
      let typ = expression_type ctx i' in
      let ty =
        match UnionFind.find typ with
        | Unknown | Error -> (
            match op.desc with
            | Not ->
                UnionFind.make
                  (Valtype { typ = I32; internal = I32; inline = None })
            | Neg | Pos -> UnionFind.make Number)
        | _ -> (
            match op.desc with
            | Not ->
                (match UnionFind.find typ with
                | Valtype { internal = I32 | I64 | Ref _; _ }
                | Null | Int | LargeInt ->
                    ()
                | Number -> UnionFind.set typ Int
                | _ ->
                    Error.instruction_type_mismatch ctx.diagnostics
                      ~location:op.info typ (UnionFind.make Int));
                UnionFind.make
                  (Valtype { typ = I32; internal = I32; inline = None })
            | Neg | Pos ->
                (match UnionFind.find typ with
                | Valtype { internal = I32 | I64 | F32 | F64; _ }
                | Int | LargeInt | Float | Number ->
                    ()
                | _ ->
                    Error.instruction_type_mismatch ctx.diagnostics
                      ~location:op.info typ (UnionFind.make Number));
                typ)
      in
      return_expression i (UnOp (op, i')) ty
  | _ -> assert false (* only invoked on BinOp/UnOp *)

and type_cast ctx i =
  (* Type casts ([e as t]) and type tests ([e is t]). *)
  match i.desc with
  | Cast (i', typ) ->
      let* i' = instruction ctx i' in
      (* When converting from Wasm, fuse two casts whose inserted intermediate
         type is superfluous (only when [ctx.simplify]); [to_wasm] re-expands
         each single cast to the same instructions:
         - [(e as i32_X) as i64_X] -> [e as i64_X]: a narrow [i32]-producing
           read widened to [i64]. [e] is a packed [Int8]/[Int16] read (the
           [i32] is [i64.extend_i32_X]) or a reference (the [i32] is [i31.get],
           the [i64] [i64.extend_i32_X]).
         - [(e as &i31) as i32_X] -> [e as i32_X]: a [ref.cast] feeding
           [i31.get]. A reference already typed [&i31]/[&?i31] never reaches
           here (its [&i31] cast is dropped as redundant first); an [i31] built
           from an [i32] ([ref.i31]) is excluded by the [is_*_ref] guard.
         - [(e as i32) as &i31] -> [e as &i31]: an [i64] wrapped to [i32]
           before [ref.i31] (which takes an [i32]).
         - [(e as &any) as &T] -> [e as &T]: an [extern] converted to the
           [any] hierarchy ([any.convert_extern]) before a [ref.cast] to a
           concrete [any]-hierarchy type [T].
         - [(e as &i31) as &extern] -> [e as &extern]: an [i32] boxed as an
           [i31] ([ref.i31]) before [extern.convert_any]. *)
      let is_packed_read e =
        match UnionFind.find (expression_type ctx e) with
        | Int8 | Int16 -> true
        | _ -> false
      in
      let is_ref e =
        match UnionFind.find (expression_type ctx e) with
        | Valtype { internal = Ref _; _ } -> true
        | _ -> false
      in
      let is_non_i31_ref e =
        match UnionFind.find (expression_type ctx e) with
        | Valtype { internal = Ref { typ = I31; _ }; _ } -> false
        | Valtype { internal = Ref _; _ } -> true
        | _ -> false
      in
      let is_i64 e =
        match UnionFind.find (expression_type ctx e) with
        | Valtype { internal = I64; _ } -> true
        | _ -> false
      in
      let is_i32 e =
        match UnionFind.find (expression_type ctx e) with
        | Valtype { internal = I32; _ } -> true
        | _ -> false
      in
      let is_extern e =
        match UnionFind.find (expression_type ctx e) with
        | Valtype { internal = Ref { typ = Extern | NoExtern; _ }; _ } -> true
        | _ -> false
      in
      let i', typ =
        match (typ, i'.desc) with
        | ( Signedtype { typ = `I64; signage = s2; strict = false },
            Cast (e, Signedtype { typ = `I32; signage = s1; strict = false }) )
          when ctx.simplify && s1 = s2 && (is_packed_read e || is_ref e) ->
            (e, typ)
        | ( Signedtype { typ = `I32; _ },
            Cast (e, Valtype (Ref { typ = I31; nullable = false })) )
          when ctx.simplify && is_non_i31_ref e ->
            (e, typ)
        | Valtype (Ref { typ = I31; nullable = false }), Cast (e, Valtype I32)
          when ctx.simplify && is_i64 e ->
            (e, typ)
        | ( Valtype (Ref ({ typ = Extern; _ } as r)),
            Cast (e, Valtype (Ref { typ = I31; nullable = false })) )
          when ctx.simplify && is_i32 e ->
            (* [ref.i31] is non-null and [extern.convert_any] preserves that,
               so the fused [i32 as &extern] is non-null. *)
            (e, Valtype (Ref { r with nullable = false }))
        | ( Valtype
              (Ref { typ = Any | Eq | I31 | Struct | Array | None_ | Type _; _ }),
            Cast (e, Valtype (Ref { typ = Any; _ })) )
          when ctx.simplify && is_extern e ->
            (e, typ)
        | _ -> (i', typ)
      in
      let ty' = expression_type ctx i' in
      (* Snapshot the inner type *before* [cast]/[signed_cast] below concretize it
         to the cast target: this is the type the inner expression would settle on
         if the cast were removed (see [load_bearing_literal]). *)
      let ty'_natural = UnionFind.find ty' in
      (* [extern.convert_any]/[any.convert_extern] preserve non-nullness, so a
         cast to [&?extern]/[&?any] of a non-nullable argument actually yields
         [&extern]/[&any]; refine the target accordingly. Like the
         redundant-cast removal below, this only applies when converting from
         Wasm ([ctx.simplify]); otherwise the cast is kept as written. *)
      let arg_non_nullable =
        match UnionFind.find ty' with
        | Valtype { typ = Ref { nullable = false; _ }; _ } -> true
        | _ -> false
      in
      let typ =
        match typ with
        | Valtype (Ref ({ typ = Extern | Any; nullable = true } as r))
          when ctx.simplify && arg_non_nullable ->
            Ast.Valtype (Ref { r with nullable = false })
        | _ -> typ
      in
      (* The cast target as a valtype, resolving an inline function type
         [&fn(..)] to a minted anonymous function type. The AST node keeps the
         original [typ] (so an inline function-type cast prints and lowers
         faithfully); only [ty]/validation use the resolved type. *)
      let target_valtype =
        match typ with
        | Valtype t -> Some t
        | Functype { nullable; sign } ->
            Some (Ref { nullable; typ = Type (anon_function_type ctx sign) })
        | Signedtype _ -> None
      in
      (* A continuation type cannot be the target of a cast instruction. A null
         cast to a nullable reference lowers to [ref.null] (no cast) and is
         allowed; every other form lowers to a [ref.cast]. *)
      (match target_valtype with
      | Some (Ref { typ; nullable })
        when is_cont_heaptype ctx typ && not (nullable && is_null_initializer i')
        ->
          Error.invalid_cast_type ctx.diagnostics ~location:i.info
      | _ -> ());
      (* An inline function-type cast target [&fn(..)] is lowered through a
         synthesized type (see [anon_function_type]); carry its signature so the
         result renders as [&fn(..)] rather than that synthetic name. *)
      let inline : comptype option =
        match typ with Functype { sign; _ } -> Some (Func sign) | _ -> None
      in
      let*! ty =
        internalize ?inline ctx
          (match target_valtype with
          | Some t -> t
          | None -> (
              match typ with
              | Signedtype { typ = `I32; _ } -> I32
              | Signedtype { typ = `I64; _ } -> I64
              | Signedtype { typ = `F32; _ } -> F32
              | Signedtype { typ = `F64; _ } -> F64
              | Valtype _ | Functype _ -> assert false))
      in
      let () =
        match target_valtype with
        | Some t ->
            if not (cast ctx ty' t) then
              Error.invalid_cast ctx.diagnostics ~location:i.info ty'
        | None -> (
            match typ with
            | Signedtype { typ; _ } ->
                if not (signed_cast ctx ty' typ) then
                  Error.invalid_cast ctx.diagnostics ~location:i.info ty'
            | Valtype _ | Functype _ -> assert false)
      in
      (* A cast is load-bearing when its target differs from the type the inner
         expression would settle on if the cast were removed — its natural
         default, read from [ty'_natural] (the inner type *before* [cast] above
         concretized it to the target). A still-abstract numeric value re-parses
         at its default width (int -> i32, an out-of-i32-range int -> i64,
         float -> f64), so a cast to any other width must be kept or the value
         changes on the round-trip. This keeps e.g. [(nan as f32).to_bits()] /
         [(5 as i64).from_bits()] from losing the operand's type. Only an abstract
         numeric inner has such a default; a concrete inner (numeric or reference)
         is already pinned, so [subtype] below is the right redundancy test. *)
      let natural_typ =
        match ty'_natural with
        | Number | Int | Int8 | Int16 -> Some I32
        | LargeInt -> Some I64
        | Float -> Some F64
        | Null | Valtype _ | Unknown | Error | Collecting _ -> None
      in
      let load_bearing_literal =
        match (natural_typ, UnionFind.find ty) with
        | Some d, Valtype { typ; _ } -> d <> typ
        | _ -> false
      in
      (* Drop a cast the inferred types already make redundant. This is only
         desirable when converting from Wasm ([ctx.simplify]): there casts are
         inserted to pin types and precise inference makes some unnecessary. For
         hand-written Wax (formatting, or compiling to Wasm) we keep casts as
         written.
         ZZZ Handle select instruction better *)
      let unnecessary_cast =
        ctx.simplify && (not load_bearing_literal)
        && (not (is_unknown_or_error ty'))
        && subtype ctx ty' ty
      in
      if unnecessary_cast then return { i' with info = ([| ty |], snd i'.info) }
      else return_expression i (Cast (i', typ)) ty
  | Test (i, ty) ->
      let* i' = instruction ctx i in
      if is_cont_heaptype ctx ty.typ then
        Error.invalid_cast_type ctx.diagnostics ~location:i.info;
      (let>@ typ = top_heap_type ctx ty.typ in
       let>@ typ = internalize ctx (Ref { nullable = true; typ }) in
       check_type ctx i' typ);
      return_expression i
        (Test (i', ty))
        (UnionFind.make (Valtype { typ = I32; internal = I32; inline = None }))
  (* Construction literals carry an optional type name that can be inferred from
     an expected type. Their typing lives in [check_instruction]; in synthesis position
     there is no expectation, so [check_instruction] against the [Unknown] sentinel keeps a
     present name and reports [cannot_infer_*] when one is omitted. *)
  | _ -> assert false (* only invoked on Cast/Test *)

and type_mem_method_call ctx i func recv memname meth args =
  let _, address_type = Option.get (Tbl.find_opt ctx.memories memname) in
  let addr_vt = UnionFind.make (Valtype (address_valtype address_type)) in
  let is_store = mem_store_method meth.desc in
  let nstack = if is_store then 2 else 1 in
  let* args' = instructions ctx args in
  let nargs = List.length args' in
  if nargs < nstack || nargs > nstack + 2 then
    Error.value_count_mismatch ctx.diagnostics ~location:i.info ~expected:nstack
      ~provided:nargs;
  (match args' with
  | addr' :: rest -> (
      check_type ctx addr' addr_vt;
      if is_store then
        match rest with
        | value' :: _ -> (
            let vty = expression_type ctx value' in
            match meth.desc with
            | "store64" ->
                check_type ctx value'
                  (UnionFind.make
                     (Valtype { typ = I64; internal = I64; inline = None }))
            | "storef32" ->
                check_type ctx value'
                  (UnionFind.make
                     (Valtype { typ = F32; internal = F32; inline = None }))
            | "storef64" ->
                check_type ctx value'
                  (UnionFind.make
                     (Valtype { typ = F64; internal = F64; inline = None }))
            | _ -> (
                match UnionFind.find vty with
                | Valtype { internal = I32 | I64; _ }
                | Int | Number | Unknown | Error ->
                    ()
                | _ ->
                    Error.instruction_type_mismatch ctx.diagnostics
                      ~location:(snd value'.info) vty (UnionFind.make Int)))
        | [] -> ())
  | [] -> ());
  List.iteri
    (fun k a ->
      if k >= nstack then
        match a.desc with
        | Ast.Int _ -> ()
        | _ ->
            Error.constant_expression_required ctx.diagnostics
              ~location:(snd a.info))
    args';
  check_memarg ctx ~address_type
    ~natural:(mem_natural_align meth.desc)
    ~align:(List.nth_opt args' nstack)
    ~offset:(List.nth_opt args' (nstack + 1));
  let result =
    if is_store then [||]
    else
      match mem_load_result meth.desc with
      | Some t -> [| UnionFind.make t |]
      | None -> [||]
  in
  return_statement i
    (Call
       ( {
           desc =
             StructGet ({ desc = Get memname; info = ([||], recv.info) }, meth);
           info = ([||], func.info);
         },
         args' ))
    result

and type_simd_mem_method_call ctx i func recv memname meth args =
  let mop = Option.get (Simd.mem_method meth.desc) in
  let _, address_type = Option.get (Tbl.find_opt ctx.memories memname) in
  let addr_vt = UnionFind.make (Valtype (address_valtype address_type)) in
  let nstack = List.length mop.m_operands in
  let nimm = if mop.m_lane then 1 else 0 in
  let* args' = instructions ctx args in
  let nargs = List.length args' in
  if nargs < nstack + nimm || nargs > nstack + nimm + 2 then
    Error.value_count_mismatch ctx.diagnostics ~location:i.info
      ~expected:(nstack + nimm) ~provided:nargs;
  List.iteri
    (fun k a ->
      if k = 0 then check_type ctx a addr_vt
      else if k < nstack then
        check_type ctx a (simd_cell (List.nth mop.m_operands k))
      else
        match a.desc with
        | Ast.Int _ -> ()
        | _ ->
            Error.constant_expression_required ctx.diagnostics
              ~location:(snd a.info))
    args';
  (if mop.m_lane then
     let>@ lane = List.nth_opt args' nstack in
     let>@ l = int_literal lane in
     let max_lane = 16 / mop.m_nat_align in
     (* Compare unsigned: a lane index too large even for an [int] (e.g. a
        literal near [u64] max) must still be rejected, not crash [Uint64.to_int]
        with an assertion. *)
     if Wax_utils.Uint64.compare l (Wax_utils.Uint64.of_int max_lane) >= 0 then
       Error.invalid_lane_index ctx.diagnostics ~location:(snd lane.info)
         max_lane);
  check_memarg ctx ~address_type ~natural:mop.m_nat_align
    ~align:(List.nth_opt args' (nstack + nimm))
    ~offset:(List.nth_opt args' (nstack + nimm + 1));
  let result =
    match mop.m_result with Some t -> [| simd_cell t |] | None -> [||]
  in
  return_statement i
    (Call
       ( {
           desc =
             StructGet ({ desc = Get memname; info = ([||], recv.info) }, meth);
           info = ([||], func.info);
         },
         args' ))
    result

and type_mem_mgmt_call ctx i func recv name meth args =
  let _, at = Option.get (Tbl.find_opt ctx.memories name) in
  let addr () = UnionFind.make (Valtype (address_valtype at)) in
  let i32 () =
    UnionFind.make (Valtype { typ = I32; internal = I32; inline = None })
  in
  let recv' = { desc = Get name; info = ([||], recv.info) } in
  let mk args' =
    Ast.Call
      ({ desc = StructGet (recv', meth); info = ([||], func.info) }, args')
  in
  let bad () =
    Error.value_count_mismatch ctx.diagnostics ~location:i.info ~expected:0
      ~provided:(List.length args);
    return_statement i (mk []) [||]
  in
  match (meth.desc, args) with
  | "size", [] -> return_expression i (mk []) (addr ())
  | "grow", [ d ] ->
      let* d' = instruction ctx d in
      check_type ctx d' (addr ());
      return_expression i (mk [ d' ]) (addr ())
  | "fill", [ d; v; n ] ->
      let* d' = instruction ctx d in
      let* v' = instruction ctx v in
      let* n' = instruction ctx n in
      check_type ctx d' (addr ());
      check_type ctx v' (i32 ());
      check_type ctx n' (addr ());
      return_statement i (mk [ d'; v'; n' ]) [||]
  | "copy", [ d; s; n ] ->
      let* d' = instruction ctx d in
      let* s' = instruction ctx s in
      let* n' = instruction ctx n in
      check_type ctx d' (addr ());
      check_type ctx s' (addr ());
      check_type ctx n' (addr ());
      return_statement i (mk [ d'; s'; n' ]) [||]
  | "copy", { desc = Get src; info = sinfo } :: ([ _; _; _ ] as rest)
    when Tbl.find_opt ctx.memories src <> None ->
      let src_at =
        match Tbl.find_opt ctx.memories src with Some (_, a) -> a | None -> at
      in
      let addr_of a = UnionFind.make (Valtype (address_valtype a)) in
      let min_at =
        match (at, src_at) with `I32, _ | _, `I32 -> `I32 | `I64, `I64 -> `I64
      in
      let src' = { desc = Get src; info = ([||], sinfo) } in
      let* rest' = instructions ctx rest in
      (match rest' with
      | [ d'; s'; n' ] ->
          check_type ctx d' (addr_of at);
          check_type ctx s' (addr_of src_at);
          check_type ctx n' (addr_of min_at)
      | _ -> ());
      return_statement i (mk (src' :: rest')) [||]
  | "init", { desc = Get seg; info = sinfo } :: ([ _; _; _ ] as rest) ->
      ignore (Tbl.find ctx.diagnostics ctx.datas seg : unit option);
      let seg' = { desc = Get seg; info = ([||], sinfo) } in
      let* rest' = instructions ctx rest in
      (match rest' with
      | [ d'; s'; n' ] ->
          check_type ctx d' (addr ());
          check_type ctx s' (i32 ());
          check_type ctx n' (i32 ())
      | _ -> ());
      return_statement i (mk (seg' :: rest')) [||]
  | _ -> bad ()

and type_table_mgmt_call ctx i func recv name meth args =
  let at, rt = Option.get (Tbl.find_opt ctx.tables name) in
  let addr () = UnionFind.make (Valtype (address_valtype at)) in
  let i32 () =
    UnionFind.make (Valtype { typ = I32; internal = I32; inline = None })
  in
  let check_elt e =
    let>@ t = internalize ctx (Ref rt) in
    check_type ctx e t
  in
  let recv' = { desc = Get name; info = ([||], recv.info) } in
  let mk args' =
    Ast.Call
      ({ desc = StructGet (recv', meth); info = ([||], func.info) }, args')
  in
  let bad () =
    Error.value_count_mismatch ctx.diagnostics ~location:i.info ~expected:0
      ~provided:(List.length args);
    return_statement i (mk []) [||]
  in
  match (meth.desc, args) with
  | "size", [] -> return_expression i (mk []) (addr ())
  | "grow", [ v; n ] ->
      let* v' = instruction ctx v in
      let* n' = instruction ctx n in
      check_elt v';
      check_type ctx n' (addr ());
      return_expression i (mk [ v'; n' ]) (addr ())
  | "fill", [ d; v; n ] ->
      let* d' = instruction ctx d in
      let* v' = instruction ctx v in
      let* n' = instruction ctx n in
      check_type ctx d' (addr ());
      check_elt v';
      check_type ctx n' (addr ());
      return_statement i (mk [ d'; v'; n' ]) [||]
  | "copy", [ d; s; n ] ->
      let* d' = instruction ctx d in
      let* s' = instruction ctx s in
      let* n' = instruction ctx n in
      check_type ctx d' (addr ());
      check_type ctx s' (addr ());
      check_type ctx n' (addr ());
      return_statement i (mk [ d'; s'; n' ]) [||]
  | "copy", { desc = Get src; info = sinfo } :: ([ _; _; _ ] as rest)
    when Tbl.find_opt ctx.tables src <> None ->
      let src_at =
        match Tbl.find_opt ctx.tables src with
        | Some (a, src_rt) ->
            check_elem_subtype ctx ~location:i.info ~src:src_rt ~dst:rt;
            a
        | None -> at
      in
      let addr_of a = UnionFind.make (Valtype (address_valtype a)) in
      let min_at =
        match (at, src_at) with `I32, _ | _, `I32 -> `I32 | `I64, `I64 -> `I64
      in
      let src' = { desc = Get src; info = ([||], sinfo) } in
      let* rest' = instructions ctx rest in
      (match rest' with
      | [ d'; s'; n' ] ->
          check_type ctx d' (addr_of at);
          check_type ctx s' (addr_of src_at);
          check_type ctx n' (addr_of min_at)
      | _ -> ());
      return_statement i (mk (src' :: rest')) [||]
  | "init", { desc = Get seg; info = sinfo } :: ([ _; _; _ ] as rest) ->
      (let>@ src_rt = Tbl.find ctx.diagnostics ctx.elems seg in
       check_elem_subtype ctx ~location:i.info ~src:src_rt ~dst:rt);
      let seg' = { desc = Get seg; info = ([||], sinfo) } in
      let* rest' = instructions ctx rest in
      (match rest' with
      | [ d'; s'; n' ] ->
          check_type ctx d' (addr ());
          check_type ctx s' (i32 ());
          check_type ctx n' (i32 ())
      | _ -> ());
      return_statement i (mk (seg' :: rest')) [||]
  | _ -> bad ()

and type_array_fill_call ctx i func a meth j v n =
  let* a' = instruction ctx a in
  let* j' = instruction ctx j in
  let* v' = instruction ctx v in
  let* n' = instruction ctx n in
  check_type ctx n'
    (UnionFind.make (Valtype { typ = I32; internal = I32; inline = None }));
  check_type ctx j'
    (UnionFind.make (Valtype { typ = I32; internal = I32; inline = None }));
  (match UnionFind.find (expression_type ctx a') with
  | Valtype { typ = Ref { typ = Type ty; _ }; _ } ->
      let>@ typ = lookup_array_type ctx ty in
      if not typ.mut then
        Error.immutable ctx.diagnostics ~location:a.info "array";
      let>@ ty = internalize ctx (unpack_type typ) in
      let ty' = expression_type ctx v' in
      if not (subtype ctx ty' ty) then
        Error.instruction_type_mismatch ctx.diagnostics ~location:(snd v'.info)
          ty' ty
  | Error -> (* receiver already failed to type; recover silently *) ()
  | Unknown ->
      (* The receiver's type is unknown (unreachable / branch code): the array
         type cannot be resolved, so the operation cannot be compiled. *)
      Error.unknown_operand_type ctx.diagnostics ~location:a.info
  | _ -> Error.expected_array_type ctx.diagnostics ~location:a.info);
  return_statement i
    (Call
       ( { desc = StructGet (a', meth); info = ([||], func.info) },
         [ j'; v'; n' ] ))
    [||]

and type_array_copy_call ctx i func a1 meth i1 a2 i2 n =
  let* a1' = instruction ctx a1 in
  let* i1' = instruction ctx i1 in
  let* a2' = instruction ctx a2 in
  let* i2' = instruction ctx i2 in
  let* n' = instruction ctx n in
  check_type ctx n'
    (UnionFind.make (Valtype { typ = I32; internal = I32; inline = None }));
  check_type ctx i2'
    (UnionFind.make (Valtype { typ = I32; internal = I32; inline = None }));
  let ty' = expression_type ctx a2' in
  check_type ctx i1'
    (UnionFind.make (Valtype { typ = I32; internal = I32; inline = None }));
  let ty = expression_type ctx a1' in
  (match (UnionFind.find ty, UnionFind.find ty') with
  (* Either array already failed to type; recover silently. *)
  | Error, _ | _, Error -> ()
  (* An array's type is unknown (unreachable / branch code): its element type
     cannot be resolved, so the copy cannot be compiled. Point at the offending
     array. *)
  | Unknown, _ -> Error.unknown_operand_type ctx.diagnostics ~location:a1.info
  | _, Unknown -> Error.unknown_operand_type ctx.diagnostics ~location:a2.info
  | ( Valtype { typ = Ref { typ = Type ty; _ }; _ },
      Valtype { typ = Ref { typ = Type ty'; _ }; _ } ) ->
      let>@ typ = lookup_array_type ~location:a1.info ctx ty in
      let>@ typ' = lookup_array_type ~location:a2.info ctx ty' in
      if not typ.mut then
        Error.immutable ctx.diagnostics ~location:a1.info "array";
      if not (storage_subtype ctx typ'.typ typ.typ) then
        Error.incompatible_array_elements ctx.diagnostics ~location:a2.info
  | _ -> Error.expected_array_type ctx.diagnostics ~location:a1.info);
  return_statement i
    (Call
       ( { desc = StructGet (a1', meth); info = ([||], func.info) },
         [ i1'; a2'; i2'; n' ] ))
    [||]

and type_array_init_call ctx i func a meth seg sinfo rest =
  let* a' = instruction ctx a in
  let* rest' = instructions ctx rest in
  let i32 =
    UnionFind.make (Valtype { typ = I32; internal = I32; inline = None })
  in
  (match rest' with
  | [ d'; s'; n' ] ->
      check_type ctx d' i32;
      check_type ctx s' i32;
      check_type ctx n' i32
  | _ -> ());
  (match UnionFind.find (expression_type ctx a') with
  | Valtype { typ = Ref { typ = Type ty; _ }; _ } -> (
      let>@ field = lookup_array_type ctx ty in
      if not field.mut then
        Error.immutable ctx.diagnostics ~location:a.info "array";
      match field.typ with
      | Value (Ref dst) ->
          let>@ src = Tbl.find ctx.diagnostics ctx.elems seg in
          check_elem_subtype ctx ~location:a.info ~src ~dst
      | _ -> ignore (Tbl.find ctx.diagnostics ctx.datas seg : unit option))
  | Error -> (* receiver already failed to type; recover silently *) ()
  | Unknown ->
      (* The receiver's type is unknown (unreachable / branch code): the array
         type cannot be resolved, so the operation cannot be compiled. *)
      Error.unknown_operand_type ctx.diagnostics ~location:a.info
  | _ -> Error.expected_array_type ctx.diagnostics ~location:a.info);
  let seg' = { desc = Get seg; info = ([||], sinfo) } in
  return_statement i
    (Call
       ({ desc = StructGet (a', meth); info = ([||], func.info) }, seg' :: rest'))
    [||]

and type_binary_intrinsic_call ctx i func i1 meth op i2 =
  let* i1' = instruction ctx i1 in
  let* i2' = instruction ctx i2 in
  let ty =
    match op with
    | "rotl" | "rotr" ->
        check_int_bin_op ctx ~location:meth.info (expression_type ctx i1')
          (expression_type ctx i2')
    | _ ->
        check_float_bin_op ctx ~location:meth.info (expression_type ctx i1')
          (expression_type ctx i2')
  in
  return_expression i
    (Call ({ desc = StructGet (i1', meth); info = ([||], func.info) }, [ i2' ]))
    ty

and type_unary_intrinsic_call ctx i func recv meth =
  let* recv' = instruction ctx recv in
  let*! ty =
    let ty = expression_type ctx recv' in
    match (UnionFind.find ty, meth.desc) with
    | Valtype { typ = Ref { typ = Type t; _ }; _ }, "length" -> (
        let*@ _, def = Tbl.find_opt ctx.type_context.types t in
        match def.typ with
        | Array _ ->
            Some
              (UnionFind.make
                 (Valtype { typ = I32; internal = I32; inline = None }))
        | Struct _ | Func _ | Cont _ ->
            Error.expected_array_type ctx.diagnostics ~location:i.info;
            None)
    | (Null | Valtype { typ = Ref { typ = Array; _ }; _ }), "length" ->
        Some
          (UnionFind.make
             (Valtype { typ = I32; internal = I32; inline = None }))
    | Valtype { typ = I32; _ }, "from_bits" ->
        Some
          (UnionFind.make
             (Valtype { typ = F32; internal = F32; inline = None }))
    | Valtype { typ = I64; _ }, "from_bits" ->
        Some
          (UnionFind.make
             (Valtype { typ = F64; internal = F64; inline = None }))
    | Valtype { typ = F32; _ }, "to_bits" ->
        Some
          (UnionFind.make
             (Valtype { typ = I32; internal = I32; inline = None }))
    | Valtype { typ = F64; _ }, "to_bits" ->
        Some
          (UnionFind.make
             (Valtype { typ = I64; internal = I64; inline = None }))
    (* An abstract numeric receiver (e.g. a bare float literal whose redundant
       cast [simplify] dropped) defaults like any other operation: [to_bits] on a
       [Float] is f64->i64, [from_bits] on an integer is i32->f32 (or i64->f64
       for a [LargeInt]). The non-default widths keep their cast (load-bearing),
       so they reach the concrete arms above. *)
    | Float, "to_bits" ->
        UnionFind.set ty (Valtype { typ = F64; internal = F64; inline = None });
        Some
          (UnionFind.make
             (Valtype { typ = I64; internal = I64; inline = None }))
    | (Number | Int), "from_bits" ->
        UnionFind.set ty (Valtype { typ = I32; internal = I32; inline = None });
        Some
          (UnionFind.make
             (Valtype { typ = F32; internal = F32; inline = None }))
    | LargeInt, "from_bits" ->
        UnionFind.set ty (Valtype { typ = I64; internal = I64; inline = None });
        Some
          (UnionFind.make
             (Valtype { typ = F64; internal = F64; inline = None }))
    | ( ((Number | Int | Valtype { typ = I32 | I64; _ }) as ty'),
        ("clz" | "ctz" | "popcnt" | "extend8_s" | "extend16_s") ) ->
        if ty' = Number then UnionFind.set ty Int;
        Some ty
    | ( ((Number | Float | Valtype { typ = F32 | F64; _ }) as ty'),
        ("abs" | "ceil" | "floor" | "trunc" | "nearest" | "sqrt") ) ->
        if ty' = Number then UnionFind.set ty Float;
        Some ty
    | Error, _ -> Some (UnionFind.make Error)
    | Unknown, _ ->
        (* The receiver's type is unknown (unreachable / branch code): the
           method cannot be resolved, so the call cannot be compiled. *)
        Error.unknown_operand_type ctx.diagnostics ~location:(snd recv'.info);
        Some (UnionFind.make Error)
    | _ ->
        Error.invalid_method_receiver ctx.diagnostics ~location:meth.info ty;
        None
  in
  return_expression i
    (Call ({ desc = StructGet (recv', meth); info = ([||], func.info) }, []))
    ty

and type_simd_vector_op_call ctx i func recv meth args =
  let op = Option.get (Simd.classify meth.desc) in
  let* recv' = instruction ctx recv in
  let* args' = instructions ctx args in
  let nimm = match op.imm with No_imm -> 0 | Lane _ -> 1 | Shuffle -> 16 in
  let nstack_extra = List.length op.operands - 1 in
  let nargs = List.length args' in
  if nargs <> nimm + nstack_extra then
    Error.value_count_mismatch ctx.diagnostics ~location:i.info
      ~expected:(nimm + nstack_extra) ~provided:nargs;
  check_type ctx recv' (simd_cell (List.hd op.operands));
  let lane_bound =
    match op.imm with
    | No_imm -> None
    | Lane shape -> Some (Simd.lane_count shape)
    | Shuffle -> Some 32
  in
  List.iteri
    (fun k a ->
      if k < nimm then (
        (match a.desc with
        | Ast.Int _ -> ()
        | _ ->
            Error.constant_expression_required ctx.diagnostics
              ~location:(snd a.info));
        let>@ bound = lane_bound in
        let>@ l = int_literal a in
        (* Unsigned compare: a lane index too large even for an [int] must be
           rejected, not crash [Uint64.to_int]'s assertion (as for the memory
           lane index in [type_simd_mem_method_call]). *)
        if Wax_utils.Uint64.compare l (Wax_utils.Uint64.of_int bound) >= 0 then
          Error.invalid_lane_index ctx.diagnostics ~location:(snd a.info) bound)
      else
        let operand = 1 + (k - nimm) in
        if operand < List.length op.operands then
          check_type ctx a (simd_cell (List.nth op.operands operand)))
    args';
  let result =
    match op.result with Some t -> [| simd_cell t |] | None -> [||]
  in
  return_statement i
    (Call ({ desc = StructGet (recv', meth); info = ([||], func.info) }, args'))
    result

and type_simd_free_intrinsic_call ctx i func name args =
  let* args' = instructions ctx args in
  (match Simd.const_shape_of_name name.desc with
  | Some shape ->
      let arity = Simd.const_arity shape in
      if List.length args' <> arity then
        Error.value_count_mismatch ctx.diagnostics ~location:i.info
          ~expected:arity ~provided:(List.length args');
      (* Each lane of an integer shape must fit its width, accepting both the
         signed and unsigned range [-2^(b-1), 2^b-1] (so an i8 lane is
         [-128, 255]). Beyond rejecting a malformed const, this stops an
         out-of-[int]-range literal from later crashing [V128.to_string]'s
         [int_of_string] in the binary encoder. *)
      let bits =
        match shape with
        | I8x16 -> Some 8
        | I16x8 -> Some 16
        | I32x4 -> Some 32
        | I64x2 -> Some 64
        | F32x4 | F64x2 -> None
      in
      List.iter
        (let lane_in_range b neg l =
           match int_literal l with
           | None -> false (* exceeds u64 *)
           | Some v ->
               let v = Wax_utils.Uint64.to_int64 v in
               if neg then
                 (* magnitude <= 2^(b-1) *)
                 Int64.unsigned_compare v (Int64.shift_left 1L (b - 1)) <= 0
               else if b = 64 then true
               else
                 Int64.unsigned_compare v (Int64.sub (Int64.shift_left 1L b) 1L)
                 <= 0
         in
         fun a ->
           match (bits, a.desc) with
           | Some b, Ast.Int _ ->
               if not (lane_in_range b false a) then
                 Error.lane_value_out_of_range ctx.diagnostics
                   ~location:(snd a.info) b
           | Some b, Ast.UnOp ({ desc = Neg; _ }, ({ desc = Ast.Int _; _ } as l))
             ->
               if not (lane_in_range b true l) then
                 Error.lane_value_out_of_range ctx.diagnostics
                   ~location:(snd a.info) b
           | ( Some b,
               ( Ast.Float _
               | Ast.UnOp ({ desc = Neg; _ }, { desc = Ast.Float _; _ }) ) ) ->
               (* a float literal is not a valid integer lane *)
               Error.lane_value_out_of_range ctx.diagnostics
                 ~location:(snd a.info) b
           | ( None,
               ( Ast.Int _ | Ast.Float _
               | Ast.UnOp
                   ({ desc = Neg; _ }, { desc = Ast.Int _ | Ast.Float _; _ }) )
             ) ->
               () (* a float shape accepts any numeric literal lane *)
           | _ ->
               Error.constant_expression_required ctx.diagnostics
                 ~location:(snd a.info))
        args'
  | None -> List.iter (fun a -> check_type ctx a (simd_cell TV128)) args');
  return_expression i
    (Call ({ desc = Get name; info = ([||], func.info) }, args'))
    (simd_cell TV128)

(* Bidirectional checking mode: type [i] against an [expected] type and report
   whether the contextual annotation is load-bearing (the keep-bool). A
   construction literal can fill an omitted type name from [expected] and shed a
   redundant one; every other expression delegates to [instruction] and reports
   whether it determined its own type. [expected] is the [Unknown] sentinel when
   [check_instruction] is entered from [instruction] with no context (synthesis). *)
and check_instruction ?(drop_supertype = false) ctx expected
    (i : location instr) =
  let i32_cell () =
    UnionFind.make (Valtype { typ = I32; internal = I32; inline = None })
  in
  (* The construction's type name: explicit, or inferred from an exact expected
     type; [missing] reports a [cannot_infer_*] error and yields [None]. *)
  let resolve_name ty ~missing =
    match ty with
    | Some _ -> ty
    | None -> (
        match exact_named_type expected with
        | Some name -> Some name
        | None ->
            missing ();
            None)
  in
  (* The name is redundant precisely when [expected] pins the identical heap
     type, so it can be dropped (and is, on output). *)
  let name_redundant name =
    match exact_named_type expected with
    | Some n -> n.desc = name.desc
    | None -> false
  in
  (* The type name to emit for a construction whose source name was [original]
     and whose resolved name is [typ]. A name omitted in the source stays
     omitted. A present name is dropped only when converting from Wasm
     ([simplify], so hand-written Wax is never rewritten), the expected type
     makes it redundant, and the name-less surface form re-parses ([parseable] —
     false only for a field-less struct, whose name-less form [{}] has no
     syntax). *)
  let emitted_name original typ ~parseable ~field_unique =
    match original with
    | None -> None
    | Some _ ->
        if ctx.simplify && parseable && (name_redundant typ || field_unique)
        then None
        else Some typ
  in
  (* The result reference type of a construction of [name]; validates it against
     [expected] when there is one. *)
  let construction_result name =
    let result =
      internalize ?inline:(inline_comptype ctx name) ctx
        (Ref { nullable = false; typ = Type name })
    in
    Option.iter
      (fun result ->
        if has_expectation expected then
          check_subtype ctx ~location:i.info result expected)
      result;
    result
  in
  match i.desc with
  | Struct (ty, fields) ->
      (* The unique struct type these fields name, if any: used to resolve an
         omitted name and to drop a present one that the fields already pin. *)
      let field_match = infer_struct_by_fields ctx fields in
      let* node =
        match
          match ty with
          | Some _ -> ty
          | None -> (
              (* Field inference takes precedence over the expected type: the
                 fields name the exact struct constructed, whereas [expected]
                 may be a supertype. Fall back to [expected] only when the
                 fields are ambiguous. *)
              match field_match with
              | Some name -> Some name
              | None -> (
                  match exact_named_type expected with
                  | Some name -> Some name
                  | None ->
                      Error.cannot_infer_struct_type ctx.diagnostics
                        ~location:i.info;
                      None))
        with
        | None ->
            (* Unresolved: still type the field values for error recovery (and
               so they consume their stack slots / holes), then recover with an
               [Error] result. *)
            let* fields' =
              List.fold_left
                (fun prev (name, fi) ->
                  let* l = prev in
                  let* fi' = instruction ctx fi in
                  return ((name, fi') :: l))
                (return []) fields
            in
            return_expression i
              (Struct (None, List.rev fields'))
              (UnionFind.make Error)
        | Some typ ->
            let*! field_types = lookup_struct_type ctx typ in
            (* ZZZ We should check the evaluation order*)
            if List.length fields <> Array.length field_types then
              Error.field_count_mismatch ctx.diagnostics ~location:i.info
                ~expected:(Array.length field_types)
                ~provided:(List.length fields);
            let* fields' =
              Array.fold_left
                (fun prev field ->
                  let name, (f : fieldtype) = field.desc in
                  match
                    List.find_opt (fun (idx, _) -> name.desc = idx.desc) fields
                  with
                  | None ->
                      Error.missing_field ctx.diagnostics ~location:i.info name;
                      prev
                  | Some (name, i') ->
                      let* l = prev in
                      (* Check the field value against its declared type, so a
                         nested struct/array literal can drop its own name. *)
                      let* i' =
                        match internalize ctx (unpack_type f) with
                        | Some cell ->
                            let* i', _ = check_instruction ctx cell i' in
                            return i'
                        | None -> instruction ctx i'
                      in
                      return ((name, i') :: l))
                (return []) field_types
            in
            (* The fields alone pin this type (re-parse re-resolves to it via
               field inference, which now takes precedence), so a present name
               is redundant. *)
            let field_unique =
              match field_match with
              | Some n -> n.desc = typ.desc
              | None -> false
            in
            let emitted =
              emitted_name ty typ ~parseable:(fields <> []) ~field_unique
            in
            let*! result = construction_result typ in
            return_expression i (Struct (emitted, List.rev fields')) result
      in
      (* The outer binding annotation is redundant when the fields alone
         re-infer this exact type — [field_match] names [node]'s own result heap
         type, so the bare [{..}] re-resolves to it — and the annotation names
         that identical type (so dropping it neither widens it nor changes its
         nullability). Read back from [node] rather than the branch-local [typ],
         so the keep-bool needs no mutable cell to escape the [let*!] arms.
         Mirrors the scalar keep-bool [annotation_needed]; the drop itself stays
         gated on [simplify] at the binding sites. *)
      let standalone = standalone_valtype ctx (expression_type ctx node) in
      let fields_pin_result =
        match (field_match, standalone) with
        | Some n, Some { typ = Ref { typ = Type t; _ }; _ } -> t.desc = n.desc
        | _ -> false
      in
      return
        ( node,
          if fields_pin_result then
            annotation_needed ~drop_supertype ctx standalone expected
          else true )
  | StructDefault ty ->
      let* node =
        match
          resolve_name ty ~missing:(fun () ->
              Error.cannot_infer_struct_type ctx.diagnostics ~location:i.info)
        with
        | None ->
            return_expression i (StructDefault None) (UnionFind.make Error)
        | Some typ ->
            let*! fields = lookup_struct_type ctx typ in
            if
              not
                (Array.for_all
                   (fun field -> field_has_default (snd field.desc))
                   fields)
            then Error.not_defaultable ctx.diagnostics ~location:i.info;
            let emitted =
              emitted_name ty typ ~parseable:true ~field_unique:false
            in
            let*! result = construction_result typ in
            return_expression i (StructDefault emitted) result
      in
      return (node, true)
  | Array (ty, i1, i2) ->
      let* node =
        match
          resolve_name ty ~missing:(fun () ->
              Error.cannot_infer_array_type ctx.diagnostics ~location:i.info)
        with
        | None ->
            let* i1' = instruction ctx i1 in
            let* i2' = instruction ctx i2 in
            check_type ctx i2' (i32_cell ());
            return_expression i (Array (None, i1', i2')) (UnionFind.make Error)
        | Some typ ->
            (* Resolve the element type (pure) before typing the element value,
               so a struct/array literal or null cast there can be inferred /
               drop its name. The value is still typed first (then the count),
               preserving the source order and hole consumption. *)
            let elt =
              match lookup_array_type ctx typ with
              | Some field' -> internalize ctx (unpack_type field')
              | None -> None
            in
            let* i1' =
              match elt with
              | Some cell ->
                  let* i1', _ = check_instruction ctx cell i1 in
                  return i1'
              | None -> instruction ctx i1
            in
            let* i2' = instruction ctx i2 in
            check_type ctx i2' (i32_cell ());
            let emitted =
              emitted_name ty typ ~parseable:true ~field_unique:false
            in
            let*! result = construction_result typ in
            return_expression i (Array (emitted, i1', i2')) result
      in
      return (node, true)
  | ArrayDefault (ty, n) ->
      let* node =
        match
          resolve_name ty ~missing:(fun () ->
              Error.cannot_infer_array_type ctx.diagnostics ~location:i.info)
        with
        | None ->
            let* n' = instruction ctx n in
            check_type ctx n' (i32_cell ());
            return_expression i (ArrayDefault (None, n')) (UnionFind.make Error)
        | Some typ ->
            let* n' = instruction ctx n in
            check_type ctx n' (i32_cell ());
            (let>@ field = lookup_array_type ctx typ in
             if not (field_has_default field) then
               Error.not_defaultable ctx.diagnostics ~location:typ.info);
            let emitted =
              emitted_name ty typ ~parseable:true ~field_unique:false
            in
            let*! result = construction_result typ in
            return_expression i (ArrayDefault (emitted, n')) result
      in
      return (node, true)
  | ArrayFixed (ty, instrs) ->
      let* node =
        match
          resolve_name ty ~missing:(fun () ->
              Error.cannot_infer_array_type ctx.diagnostics ~location:i.info)
        with
        | None ->
            let* instrs' =
              List.fold_left
                (fun prev i' ->
                  let* l = prev in
                  let* i' = instruction ctx i' in
                  return (i' :: l))
                (return []) instrs
            in
            return_expression i
              (ArrayFixed (None, List.rev instrs'))
              (UnionFind.make Error)
        | Some typ ->
            let*! field' = lookup_array_type ctx typ in
            let elt = internalize ctx (unpack_type field') in
            let* instrs' =
              List.fold_left
                (fun prev i' ->
                  let* l = prev in
                  (* Check each element against the element type, so a nested
                     struct/array literal can drop its own name. *)
                  let* i' =
                    match elt with
                    | Some cell ->
                        let* i', _ = check_instruction ctx cell i' in
                        return i'
                    | None -> instruction ctx i'
                  in
                  return (i' :: l))
                (return []) instrs
            in
            let emitted =
              emitted_name ty typ ~parseable:(instrs <> []) ~field_unique:false
            in
            let*! result = construction_result typ in
            return_expression i (ArrayFixed (emitted, List.rev instrs')) result
      in
      return (node, true)
  | ArraySegment (ty, seg, off, len) ->
      let* node =
        match
          resolve_name ty ~missing:(fun () ->
              Error.cannot_infer_array_type ctx.diagnostics ~location:i.info)
        with
        | None ->
            let* off' = instruction ctx off in
            let* len' = instruction ctx len in
            check_type ctx off' (i32_cell ());
            check_type ctx len' (i32_cell ());
            return_expression i
              (ArraySegment (None, seg, off', len'))
              (UnionFind.make Error)
        | Some typ ->
            let* off' = instruction ctx off in
            let* len' = instruction ctx len in
            check_type ctx off' (i32_cell ());
            check_type ctx len' (i32_cell ());
            (* A reference element means [array.new_elem] (the segment is an
               element segment); a numeric/packed element means [array.new_data]
               (a data segment). *)
            (let>@ field = lookup_array_type ctx typ in
             match field.typ with
             | Value (Ref dst) ->
                 let>@ src = Tbl.find ctx.diagnostics ctx.elems seg in
                 check_elem_subtype ctx ~location:i.info ~src ~dst
             | _ ->
                 ignore (Tbl.find ctx.diagnostics ctx.datas seg : unit option));
            let emitted =
              emitted_name ty typ ~parseable:true ~field_unique:false
            in
            let*! result = construction_result typ in
            return_expression i (ArraySegment (emitted, seg, off', len')) result
      in
      return (node, true)
  | String (ty, s) ->
      (* A string builds a byte array. Its natural type is the built-in
         [<string>] ([mut i8]); it adopts a different array type only when the
         context demands one — an explicit name, or one inferred from an exact
         expected type — that is not structurally that default (e.g. an immutable
         [chars]). As for the array literals a redundant name is dropped (on
         conversion from Wasm); the annotation is kept only when a bare string
         would not already take the expected type. *)
      let string_typ = { i with desc = "<string>" } in
      let string_valtype =
        internalize_valtype ctx
          (Ref { nullable = false; typ = Type string_typ })
      in
      let is_default name =
        match
          ( internalize_valtype ctx (Ref { nullable = false; typ = Type name }),
            string_valtype )
        with
        | Some a, Some b -> valtype_equal ctx a b
        | _ -> false
      in
      let typ =
        match
          match ty with Some _ -> ty | None -> exact_named_type expected
        with
        | Some name when not (is_default name) -> name
        | _ -> string_typ
      in
      (let>@ field = lookup_array_type ctx typ in
       match field.typ with
       | Value (I32 | I64 | F32 | F64) | Packed _ -> ()
       | Value (Ref _ | V128) ->
           Error.invalid_string_element_type ctx.diagnostics ~location:i.info);
      let emitted =
        if typ.desc = string_typ.desc then None
        else emitted_name ty typ ~parseable:true ~field_unique:false
      in
      let* node =
        let*! result = construction_result typ in
        return_expression i (String (emitted, s)) result
      in
      return
        (node, annotation_needed ~drop_supertype ctx string_valtype expected)
  | Cast (e, typ) when is_null_initializer e ->
      let* i' = instruction ctx i in
      (* A cast of [null] is redundant when the checking context already
           provides the very type it pins: drop it to bare [null], which
           re-checks to the same type (the context re-supplies it) and lowers to
           the same [ref.null]. Gated on [simplify] so hand-written casts are
           kept; matched exactly so the lowered [ref.null] is unchanged. *)
      let i' =
        if
          ctx.simplify
          &&
          match (typ, UnionFind.find expected) with
          | Ast.Valtype vt, Valtype b -> (
              match internalize_valtype ctx vt with
              | Some a -> valtype_equal ctx a b
              | None -> false)
          | _ -> false
        then
          match i'.desc with
          | Cast (inner, _) ->
              { inner with info = (fst i'.info, snd inner.info) }
          | _ -> i'
        else i'
      in
      if has_expectation expected then check_type ctx i' expected;
      return (i', true)
  | If { label; typ; cond; if_block; else_block } when has_expectation expected
    ->
      (* The checking context supplies a result type. Drop a redundant [=> T]
         (on [simplify]) when the context's [expected] is exactly the annotation
         — then re-parse recovers it from the same source (a function's [-> T],
         a typed binding, a call argument), so nothing is lost or loosened. On
         re-parse the annotation is absent, so fill the result type back in from
         [expected] for [to_wasm]. A [br] to the if's own label is fine: its
         value is checked against the result like the branch tails. *)
      let* cond' = instruction ctx cond in
      check_type ctx cond' (i32_cell ());
      if Array.length typ.params > 0 then
        Error.parameterized_block_expression ctx.diagnostics ~location:i.info;
      let omitted = typ.results = [||] in
      (* Type the branches against the if's own declared result when annotated,
         else against the context (a re-parsed, dropped annotation). *)
      let result_cell =
        if omitted then expected
        else
          match array_map_opt (internalize ctx) typ.results with
          | Some [| c |] -> c
          | _ -> expected
      in
      let results = [| result_cell |] in
      let if_block' =
        {
          if_block with
          desc = block ctx i.info label [||] results results if_block.desc;
        }
      in
      let else_block' =
        match else_block with
        | Some b ->
            Some
              {
                b with
                desc = block ctx i.info label [||] results results b.desc;
              }
        | None ->
            if not (missing_else_ok ctx [||] results) then
              Error.if_without_else ctx.diagnostics ~location:i.info;
            None
      in
      (* The if's result (its annotation, or [expected] when omitted) must fit
         the context — catches e.g. an [=> i64] if where [i32] is expected. *)
      check_subtype ctx ~location:i.info result_cell expected;
      let typ =
        if omitted then
          match standalone_valtype ctx expected with
          | Some iv -> { typ with results = [| iv.typ |] }
          | None -> typ
        else if
          ctx.simplify
          &&
          match
            (standalone_valtype ctx expected, standalone_valtype ctx result_cell)
          with
          | Some a, Some b -> valtype_equal ctx a b
          | _ -> false
        then { typ with results = [||] }
        else typ
      in
      (* The caller's binding annotation (e.g. [let x: T = ..]) is redundant iff
         the branches alone infer exactly [expected] — i.e. an unannotated [let]
         would re-infer it. Read each branch's fall-through type (its lub) and
         compare; a branch that diverges contributes none. *)
      let branch_last b =
        match List.rev b with
        | last :: _ -> (
            match fst last.info with [| c |] -> Some c | _ -> None)
        | [] -> None
      in
      let contents_lub =
        match
          ( branch_last if_block'.desc,
            match else_block' with Some b -> branch_last b.desc | None -> None
          )
        with
        | Some a, Some b -> join_value_types ctx a b
        | (Some _ as r), None | None, (Some _ as r) -> r
        | None, None -> None
      in
      let needed =
        match contents_lub with
        | Some v -> (
            match
              (standalone_valtype ctx v, standalone_valtype ctx expected)
            with
            | Some a, Some b -> not (valtype_equal ctx a b)
            | _ -> true)
        | None -> true
      in
      let* node =
        return_statement i
          (If
             {
               label;
               typ;
               cond = cond';
               if_block = if_block';
               else_block = else_block';
             })
          results
      in
      return (node, needed)
  (* A [do]/[loop]/[try]/[try_table] block in a checking context need not
     annotate its own result: thread [expected] in as the result type so a
     redundant annotation drops (on [simplify]) and re-parse recovers it from the
     same context ([context_result_cell] / [context_block_typ]). Branches to the
     block's own label, and (for [try]) the catch handlers, are checked against
     [expected] like the fall-through value. The keep-bool is conservatively
     [true]: unlike an [if], the value may arrive via a branch the cheap
     fall-through test would miss, so a surrounding binding annotation is kept —
     safe, at worst occasionally redundant. *)
  | Block { label; typ; block = instrs } when has_expectation expected ->
      if Array.length typ.params > 0 then
        Error.parameterized_block_expression ctx.diagnostics ~location:i.info;
      let result_cell = context_result_cell ctx typ ~expected in
      let instrs', r =
        block_keep_bool ctx i.info label ~result:result_cell
          ~br_params:[| result_cell |] instrs
      in
      let needed = block_keep_needed ctx ~loc:i.info ~result:result_cell r in
      check_subtype ctx ~location:i.info result_cell expected;
      let typ = context_block_typ ctx typ ~expected ~result_cell in
      let* node =
        return_statement i
          (Block { label; typ; block = instrs' })
          [| result_cell |]
      in
      return (node, needed)
  | Loop { label; typ; block = instrs } when has_expectation expected ->
      if Array.length typ.params > 0 then
        Error.parameterized_block_expression ctx.diagnostics ~location:i.info;
      let result_cell = context_result_cell ctx typ ~expected in
      (* A [br] to a loop re-enters at its top with the loop's parameters, so it
         carries no result; the loop's value is its fall-through. Hence the
         branch-target type is the (empty) parameters, not the result, and a
         branch to the loop's label does not deliver the value. *)
      let instrs', r =
        block_keep_bool ctx i.info label ~result:result_cell ~br_params:[||]
          instrs
      in
      let needed = block_keep_needed ctx ~loc:i.info ~result:result_cell r in
      check_subtype ctx ~location:i.info result_cell expected;
      let typ = context_block_typ ctx typ ~expected ~result_cell in
      let* node =
        return_statement i
          (Loop { label; typ; block = instrs' })
          [| result_cell |]
      in
      return (node, needed)
  | TryTable { label; typ; block = body; catches } when has_expectation expected
    ->
      if Array.length typ.params > 0 then
        Error.parameterized_block_expression ctx.diagnostics ~location:i.info;
      let result_cell = context_result_cell ctx typ ~expected in
      (* A [try_table]'s catches branch to other targets, not its own label, so
         its value is the body's (the fall-through, or a [br] to its label). *)
      let body', r =
        block_keep_bool ctx i.info label ~result:result_cell
          ~br_params:[| result_cell |] body
      in
      check_trytable_catches ctx catches;
      let needed = block_keep_needed ctx ~loc:i.info ~result:result_cell r in
      check_subtype ctx ~location:i.info result_cell expected;
      let typ = context_block_typ ctx typ ~expected ~result_cell in
      let* node =
        return_statement i
          (TryTable { label; typ; block = body'; catches })
          [| result_cell |]
      in
      return (node, needed)
  | Try { label; typ; block = body; catches; catch_all }
    when has_expectation expected ->
      assert (typ.params = [||]);
      let result_cell = context_result_cell ctx typ ~expected in
      (* A catch handler also produces the try's value. Type the handlers against
         the same inferring cell [r] as the body, so their values are collected too
         (a [try] whose body diverges takes its value entirely from the handlers);
         the keep-bool then sees every exit. *)
      let body', r =
        block_keep_bool ctx i.info label ~result:result_cell
          ~br_params:[| result_cell |] body
      in
      let catches, catch_all =
        type_try_catches ctx i label ~results:[| r |] catches catch_all
      in
      let needed = block_keep_needed ctx ~loc:i.info ~result:result_cell r in
      check_subtype ctx ~location:i.info result_cell expected;
      let typ = context_block_typ ctx typ ~expected ~result_cell in
      let* node =
        return_statement i
          (Try { label; typ; block = body'; catches; catch_all })
          [| result_cell |]
      in
      return (node, needed)
  | _ ->
      let* i' = instruction ctx i in
      (* Capture the value's own standalone-resolved type BEFORE [check_type]
           mutates the cell, then decide whether the annotation is load-bearing
           (see [annotation_needed]). *)
      let standalone = standalone_valtype ctx (expression_type ctx i') in
      let needed = annotation_needed ~drop_supertype ctx standalone expected in
      if has_expectation expected then check_type ctx i' expected;
      return (i', needed)

(* Run [check_instruction] in statement (empty-stack) position, mirroring the expression
   bridge in [toplevel_instruction]'s default arm: pop the hole operands off the
   stack into the parameter list, run [check_instruction] on them, and surface its keep-bool.
   Used for an annotated global initializer (a constant expression). *)
and check_toplevel ?(drop_supertype = false) ctx expected i =
  let count = count_holes i in
  let* args = pop_many ctx i count [] in
  let args, (i', needed) =
    check_instruction ~drop_supertype ctx expected i args
  in
  assert (args = []);
  (* A misplaced hole ([_] after a value) is reported by [check_hole_order];
     it returns [false] only after reporting that error, so recover rather than
     asserting. *)
  ignore (check_hole_order ctx i' count : bool);
  return (i', needed)

(* Peek the parameter types of a call's callee syntactically, when it is a name
   referring to a function or a funcref-typed variable. This reads no stack and
   reports nothing, so the evaluation order (arguments, then callee) and hole
   binding are unchanged; the callee is still typed normally afterwards. The
   result is used only to check each argument against its parameter. *)
and peek_call_params ctx callee =
  (* The user heap-type name a hole-free callee resolves to, computed purely (no
     typing, no stack effect): a function name, a funcref-typed variable, or a
     chain of struct-field reads ending in a funcref field — e.g.
     [cont.cont_func]. [None] for anything else. *)
  let rec callee_heaptype c =
    match c.desc with
    | Get name -> (
        match resolve_variable ctx name with
        | Func_ref (_, ty') -> Some (Ast.no_loc ty')
        | Local (Some { typ = Ref { typ = Type t; _ }; _ })
        | Global (_, Some { typ = Ref { typ = Type t; _ }; _ }) ->
            Some t
        | Local _ | Global _ | Unbound -> None)
    (* A cast target names the value's type directly; [from_wasm] inserts these
       on a receiver before a field access (e.g. [(k as &cont_2).cont_func]). *)
    | Cast (_, Valtype (Ref { typ = Type t; _ })) -> Some t
    | NonNull e -> callee_heaptype e
    | StructGet (recv, field) -> (
        match callee_heaptype recv with
        | None -> None
        | Some struct_name -> (
            match Tbl.find_opt ctx.type_context.types struct_name with
            | Some (_, { typ = Struct fields; _ }) ->
                Array.find_map
                  (fun f ->
                    let nm, (ftyp : fieldtype) = f.desc in
                    if nm.desc = field.desc then
                      match ftyp.typ with
                      | Value (Ref { typ = Type t; _ }) -> Some t
                      | Value _ | Packed _ -> None
                    else None)
                  fields
            | _ -> None))
    | _ -> None
  in
  match callee_heaptype callee with
  | None -> None
  | Some t -> (
      match Tbl.find_opt ctx.type_context.types t with
      | Some (_, { typ = Func ft; _ }) ->
          array_map_opt (fun p -> internalize ctx (snd p.desc)) ft.params
      | _ -> None)

(* Type call arguments. When the callee's parameter types are known and the
   arity matches, check each argument against its parameter (so a struct/array
   literal argument can be inferred and have its name dropped); otherwise
   synthesize them. Either way arguments are processed left-to-right, so hole
   consumption matches [instructions]. *)
and typed_call_args ctx l param_types =
  match param_types with
  | Some params when Array.length params = List.length l ->
      let rec go k = function
        | [] -> return []
        | a :: r ->
            let* a', _ = check_instruction ctx params.(k) a in
            let* r' = go (k + 1) r in
            return (a' :: r')
      in
      go 0 l
  | _ -> instructions ctx l

(* Type a value carried to a known result/branch type (a [return], [br], …).
   When exactly one value is expected, check the operand against it so a
   struct/array literal can be inferred and drop its name; otherwise synthesize
   and check the whole tuple, as before. *)
and check_against ctx expected i =
  match expected with
  | [| ty |] when is_inferring ty ->
      (* The block's result type is being inferred: synthesize the branched
         value and record it instead of checking it against the not-yet-known
         result (a plain [check_instruction] would discard it, as [has_expectation] is false
         for a [Collecting] cell). *)
      let* i' = instruction ctx i in
      ignore
        (subtype ~location:(snd i'.info) ctx (expression_type ctx i') ty : bool);
      return i'
  | [| ty |] ->
      let* i', _ = check_instruction ctx ty i in
      return i'
  | _ ->
      let* i' = instruction ctx i in
      check_subtypes ctx ~location:(snd i'.info) (fst i'.info) expected;
      return i'

and type_indirect_call ctx i i' l =
  let param_types = peek_call_params ctx i' in
  let* l' = typed_call_args ctx l param_types in
  let* i' = instruction ctx i' in
  match UnionFind.find (expression_type ctx i') with
  | Valtype { typ = Ref { typ = Type ty; _ }; _ } ->
      let*! typ = lookup_func_type ctx ty in
      (let>@ param_types =
         array_map_opt (fun p -> internalize ctx (snd p.desc)) typ.params
       in
       if Array.length param_types <> List.length l' then
         Error.value_count_mismatch ctx.diagnostics ~location:i.info
           ~expected:(Array.length param_types) ~provided:(List.length l')
       else
         Array.iter2
           (fun i ty -> check_type ctx i ty)
           (Array.of_list l') param_types);
      let*! returned_types = array_map_opt (internalize ctx) typ.results in
      return_statement i (Call (i', l')) returned_types
  | Error ->
      (* The callee already failed to type (e.g. an unbound name); recover
         silently rather than adding a spurious "expected function type". *)
      return_statement i (Call (i', l')) [||]
  | Unknown ->
      (* The callee's type is unknown (unreachable / branch code): the function
         type cannot be resolved, so the call cannot be compiled. *)
      Error.unknown_operand_type ctx.diagnostics ~location:(snd i'.info);
      return_statement i (Call (i', l')) [||]
  | _ ->
      Error.expected_func_type ctx.diagnostics ~location:i.info;
      return_statement i (Call (i', l')) [||]

and call_instruction ctx i =
  (* Dispatches a [Call]: first the intrinsic method/free-function
     forms (memory, table, segment, array, numeric, and SIMD
     operations written as [recv.meth(..)] or [name(..)]), then an
     ordinary call through a function reference. *)
  match i.desc with
  | Call
      ( ({ desc = StructGet (({ desc = Get memname; _ } as recv), meth); _ } as
         func),
        args )
    when is_mem_method meth.desc && Tbl.find_opt ctx.memories memname <> None ->
      type_mem_method_call ctx i func recv memname meth args
  (* SIMD memory accesses: mem.v128_load(addr), mem.v128_store(addr, v),
     mem.v128_load8_lane(addr, v, lane), etc. Stack operands first, then the
     constant lane immediate (if any), then the usual align/offset literals. *)
  | Call
      ( ({ desc = StructGet (({ desc = Get memname; _ } as recv), meth); _ } as
         func),
        args )
    when Simd.is_mem_method meth.desc
         && Tbl.find_opt ctx.memories memname <> None ->
      type_simd_mem_method_call ctx i func recv memname meth args
  (* Memory management: mem.size/grow/fill/copy/init, on a memory name. *)
  | Call
      ( ({ desc = StructGet (({ desc = Get name; _ } as recv), meth); _ } as func),
        args )
    when is_mgmt_method meth.desc && Tbl.find_opt ctx.memories name <> None ->
      type_mem_mgmt_call ctx i func recv name meth args
  (* Table management: tab.size/grow/fill/copy/init, on a table name. *)
  | Call
      ( ({ desc = StructGet (({ desc = Get name; _ } as recv), meth); _ } as func),
        args )
    when is_mgmt_method meth.desc && Tbl.find_opt ctx.tables name <> None ->
      type_table_mgmt_call ctx i func recv name meth args
  (* data.drop / elem.drop, on a segment name. *)
  | Call
      ( ({
           desc =
             StructGet
               (({ desc = Get name; _ } as recv), ({ desc = "drop"; _ } as meth));
           _;
         } as func),
        [] )
    when Tbl.find_opt ctx.datas name <> None
         || Tbl.find_opt ctx.elems name <> None ->
      let recv' = { desc = Get name; info = ([||], recv.info) } in
      return_statement i
        (Call ({ desc = StructGet (recv', meth); info = ([||], func.info) }, []))
        [||]
  | Call
      ( ({ desc = StructGet (a, ({ desc = "fill"; _ } as meth)); _ } as func),
        [ j; v; n ] ) ->
      type_array_fill_call ctx i func a meth j v n
  | Call
      ( ({ desc = StructGet (a1, ({ desc = "copy"; _ } as meth)); _ } as func),
        [ i1; a2; i2; n ] ) ->
      type_array_copy_call ctx i func a1 meth i1 a2 i2 n
  (* array.init_data / array.init_elem: arr.init(seg, dest, src, len). The
     element type selects data vs elem (as for array.new). *)
  | Call
      ( ({ desc = StructGet (a, ({ desc = "init"; _ } as meth)); _ } as func),
        { desc = Get seg; info = sinfo } :: ([ _; _; _ ] as rest) ) ->
      type_array_init_call ctx i func a meth seg sinfo rest
  | Call
      ( ({
           desc = StructGet (i1, ({ desc = ("rotl" | "rotr") as op; _ } as meth));
           _;
         } as func),
        [ i2 ] ) ->
      type_binary_intrinsic_call ctx i func i1 meth op i2
  | Call
      ( ({
           desc =
             StructGet
               (i1, ({ desc = ("copysign" | "min" | "max") as op; _ } as meth));
           _;
         } as func),
        [ i2 ] ) ->
      type_binary_intrinsic_call ctx i func i1 meth op i2
  (* No-argument instruction methods on a value: [x.sqrt()], [x.clz()],
     [x.to_bits()], [arr.length()]. Kept in call form so they print back with
     their parentheses; the result type is read from the receiver. *)
  | Call (({ desc = StructGet (recv, meth); _ } as func), [])
    when is_unary_method meth.desc ->
      type_unary_intrinsic_call ctx i func recv meth
  (* SIMD vector op written as a method intrinsic, [recv.add_i32x4(b)]. The lane
     shape is read from the method name (the receiver is always v128, or a scalar
     for splat); arguments are the lane immediates (if any) followed by the
     remaining stack operands. *)
  | Call (({ desc = StructGet (recv, meth); _ } as func), args)
    when Simd.classify meth.desc <> None ->
      type_simd_vector_op_call ctx i func recv meth args
  (* SIMD free-function intrinsics: [v128_const_<shape>(...)] and
     [v128_bitselect(a, b, mask)]. A user binding of the same name takes
     precedence (these only fire when the name is unbound). *)
  | Call (({ desc = Get name; _ } as func), args)
    when Simd.is_free_intrinsic name.desc
         && StringMap.find_opt name.desc ctx.locals = None
         && Tbl.find_opt ctx.globals name = None
         && Tbl.find_opt ctx.functions name = None ->
      type_simd_free_intrinsic_call ctx i func name args
  | Call (i', l) -> type_indirect_call ctx i i' l
  | _ -> assert false (* only invoked on [Call] *)

and instructions ctx l : _ -> _ * _ list =
  match l with
  | [] -> return []
  | i :: r ->
      let* i' = instruction ctx i in
      let* r' = instructions ctx r in
      return (i' :: r')

and toplevel_instruction ctx i : stack -> stack * 'b =
  if debug then Format.eprintf "%a@." Output.instr i;
  match i.desc with
  | Block { label; typ; block = instrs } ->
      (*ZZZ Blocks take argument from the stack *)
      (*ZZZ Grab the arguments from the stack before internalizing the types;
       push the right number of values in case of failure *)
      let*! params =
        array_map_opt (fun p -> internalize ctx (snd p.desc)) typ.params
      in
      let*! results = array_map_opt (internalize ctx) typ.results in
      let* () = pop_args ctx ~location:i.info params in
      let instrs' = block ctx i.info label params results results instrs in
      return_statement i (Block { label; typ; block = instrs' }) results
  | Loop { label; typ; block = instrs } ->
      let*! params =
        array_map_opt (fun p -> internalize ctx (snd p.desc)) typ.params
      in
      let*! results = array_map_opt (internalize ctx) typ.results in
      let* () = pop_args ctx ~location:i.info params in
      let instrs' = block ctx i.info label params results params instrs in
      return_statement i (Loop { label; typ; block = instrs' }) results
  | If { label; typ; cond; if_block; else_block } -> (
      let* cond = toplevel_instruction ctx cond in
      check_type ctx cond
        (UnionFind.make (Valtype { typ = I32; internal = I32; inline = None }));
      match if_inference ctx i label typ ~cond ~if_block ~else_block with
      | Some (desc, results) -> return_statement i desc results
      | None ->
          let*! params =
            array_map_opt (fun p -> internalize ctx (snd p.desc)) typ.params
          in
          let*! results = array_map_opt (internalize ctx) typ.results in
          let* () = pop_args ctx ~location:i.info params in
          let if_block =
            {
              if_block with
              desc = block ctx i.info label params results results if_block.desc;
            }
          in
          let else_block =
            match else_block with
            | Some b ->
                Some
                  {
                    b with
                    desc = block ctx i.info label params results results b.desc;
                  }
            | None ->
                if not (missing_else_ok ctx params results) then
                  Error.if_without_else ctx.diagnostics ~location:i.info;
                None
          in
          return_statement i
            (If { label; typ; cond; if_block; else_block })
            results)
  | TryTable { label; typ; block = body; catches } ->
      let*! params =
        array_map_opt (fun p -> internalize ctx (snd p.desc)) typ.params
      in
      let*! results = array_map_opt (internalize ctx) typ.results in
      let* () = pop_args ctx ~location:i.info params in
      let body' = block ctx i.info label params results results body in
      check_trytable_catches ctx catches;
      return_statement i
        (TryTable { label; typ; block = body'; catches })
        results
  | Try { label; typ; block = body; catches; catch_all } ->
      let*! params =
        array_map_opt (fun p -> internalize ctx (snd p.desc)) typ.params
      in
      let*! results = array_map_opt (internalize ctx) typ.results in
      let* () = pop_args ctx ~location:i.info params in
      let body' = block ctx i.info label params results results body in
      let catches, catch_all =
        type_try_catches ctx i label ~results catches catch_all
      in
      return_statement i
        (Try { label; typ; block = body'; catches; catch_all })
        results
  | Nop -> return_statement i Nop [||]
  | Unreachable -> return_statement i Unreachable [||] |> unreachable
  | Dispatch { index; cases; default; arms } ->
      (* As a statement, type-check the lowering (see [Ast_utils.lower_dispatch])
         as a sequence in the current stack — so a divergence in the trailing
         case body (e.g. every case ends in [return]) propagates, as it would for
         the equivalent blocks. *)
      let rec check_dups seen = function
        | [] -> ()
        | (l, _) :: r ->
            if List.exists (fun s -> s = l.desc) seen then
              Error.dispatch_duplicate_arm ctx.diagnostics ~location:l.info l;
            check_dups (l.desc :: seen) r
      in
      check_dups [] arms;
      let lowered =
        Ast_utils.lower_dispatch ~block_info:i.info ~index ~cases ~default ~arms
      in
      let* typed = block_contents ctx [||] lowered in
      let index', arms' = rebuild_dispatch typed arms in
      return_statement i
        (Dispatch { index = index'; cases; default; arms = arms' })
        [||]
  | Match { scrutinee; arms; default } ->
      (* As a statement, type-check the lowering (see [Ast_utils.lower_match]) in
         the current stack, so the void escape block's fall-through (the no-match
         path through the default) propagates. The scrutinee is block-like (no
         outer holes), so it is type-checked on its own to flag a non-reference. *)
      let _, scrut' = instruction ctx scrutinee [] in
      (match match_scrut_reftype ctx scrut' with
      | Some _ -> ()
      | None -> Error.expected_ref ctx.diagnostics ~location:(snd scrut'.info));
      let labels = match_labels i.info arms in
      let lowered =
        Ast_utils.lower_match ~block_info:i.info ~labels ~scrutinee ~arms
          ~default
      in
      let* typed = block_contents ctx [||] lowered in
      let arms', default' = rebuild_match typed arms in
      return_statement i
        (Match { scrutinee = scrut'; arms = arms'; default = default' })
        [||]
  | TailCall _ | Br _ | Br_table _ | Throw _ | ThrowRef _ | Return _ ->
      let count = count_holes i in
      let* args = pop_many ctx i count [] in
      let args, res = instruction ctx i args in
      (* Should not fail *)
      assert (args = []);
      (* [check_hole_order] reports a misplaced hole and returns [false]; recover
         rather than asserting. *)
      ignore (check_hole_order ctx res count : bool);
      return res |> unreachable
  | _ ->
      let count = count_holes i in
      let* args = pop_many ctx i count [] in
      let args, res = instruction ctx i args in
      (* Should not fail *)
      assert (args = []);
      ignore (check_hole_order ctx res count : bool);
      return res

(* Check that each [try_table] catch clause forwards the right value types to its
   branch target. The handler is a separate block (the target label), so unlike
   [try] the catch contributes nothing to the [try_table]'s own result. Reported
   at the target label, framed as a handler/target mismatch. Shared by the
   expression-, statement-, and checking-position [TryTable] cases. *)
and check_trytable_catches ctx catches =
  let check_catch types label =
    let params = branch_target ctx label in
    if Array.length types <> Array.length params then
      Error.value_count_mismatch ctx.diagnostics ~location:label.info
        ~expected:(Array.length params) ~provided:(Array.length types)
    else
      Array.iter2
        (fun provided expected ->
          if not (subtype ctx provided expected) then
            Error.catch_target_mismatch ctx.diagnostics ~location:label.info
              provided expected)
        types params
  in
  List.iter
    (fun catch ->
      match catch with
      | Catch (tag, label) ->
          let>@ { params; results = r } =
            Tbl.find ctx.diagnostics ctx.tags tag
          in
          if r <> [||] then
            Error.tag_with_results ctx.diagnostics ~location:tag.info;
          let>@ params =
            array_map_opt (fun p -> internalize ctx (snd p.desc)) params
          in
          check_catch params label
      | CatchRef (tag, label) ->
          let>@ { params; results = r } =
            Tbl.find ctx.diagnostics ctx.tags tag
          in
          if r <> [||] then
            Error.tag_with_results ctx.diagnostics ~location:tag.info;
          let>@ params =
            array_map_opt (fun p -> internalize ctx (snd p.desc)) params
          in
          let>@ ref_exn =
            internalize ctx (Ref { nullable = false; typ = Exn })
          in
          check_catch (Array.append params [| ref_exn |]) label
      | CatchAll label -> check_catch [||] label
      | CatchAllRef label ->
          let>@ ref_exn =
            internalize ctx (Ref { nullable = false; typ = Exn })
          in
          check_catch [| ref_exn |] label)
    catches

(* Type a [try]'s catch handlers (and catch-all) against [results] — each handler
   is a block that produces the try's result, like the body. Shared by the
   expression-, statement-, and checking-position [Try] cases; the body is typed
   by the caller. *)
and type_try_catches ctx i label ~results catches catch_all =
  let catches =
    List.filter_map
      (fun (tag, body) ->
        let*@ { params; results = r } = Tbl.find ctx.diagnostics ctx.tags tag in
        if r <> [||] then
          Error.tag_with_results ctx.diagnostics ~location:tag.info;
        let+@ params =
          array_map_opt (fun p -> internalize ctx (snd p.desc)) params
        in
        let body' = block ctx i.info label params results results body in
        (tag, body'))
      catches
  in
  let catch_all =
    Option.map
      (fun body -> block ctx i.info label [||] results results body)
      catch_all
  in
  (catches, catch_all)

and block_contents ctx results l =
  match l with
  | [] -> return []
  | [ i ]
    when Array.length results = 1
         &&
         match i.desc with
         | Struct _ | StructDefault _ | Array _ | ArrayDefault _ | ArrayFixed _
         | ArraySegment _ | String _ ->
             true
         (* A trailing block (if / do / loop / try / try_table) is routed through
            [check_instruction] too, so the outer block's result type flows into it
            (context-driven inference): the inner block's own result annotation
            then drops, and the type propagates further into a nested trailing
            block or construction. A parameterized block stays on the statement
            path, which pops its parameters off the stack (expression position
            has no stack to take them from). *)
         | If { typ; _ }
         | Block { typ; _ }
         | Loop { typ; _ }
         | TryTable { typ; _ }
         | Try { typ; _ } ->
             Array.length typ.params = 0
         | Cast (e, _) -> is_null_initializer e
         | _ -> false ->
      fun st ->
        (match st with
        | Empty when is_inferring results.(0) ->
            (* The block's own result type is being inferred (synthesis), so the
               result cell is a [Collecting] one: checking this trailing value
               against it would discard it ([has_expectation] is false). Instead
               synthesize the value — a nested block runs its own inference — and
               push its type, to be collected by the enclosing block. *)
            let count = count_holes i in
            let* args = pop_many ctx i count [] in
            let args, i' = instruction ctx i args in
            assert (args = []);
            ignore (check_hole_order ctx i' count : bool);
            let* () =
              push_results
                (Array.to_list
                   (Array.map (fun ty -> (i.info, ty)) (fst i'.info)))
            in
            return [ i' ]
        | Empty ->
            (* The stack is empty, so this trailing instruction must produce the
                block's value: a construction literal (incl. a string) or null
                cast, or a nested [if]/[do] block. Check it against the single
                result type so it can be inferred / drop its name, redundant
                cast, or its own result annotation, just like a [return].
                [check_instruction] has already validated the value against [results.(0)]
                (reporting any mismatch once), so push the result type itself
                rather than the value's own type — that keeps the block's
                [pop_args] from reporting the same mismatch a second time. *)
            let* i', _ = check_toplevel ctx results.(0) i in
            let* () =
              push_results
                (Array.to_list (Array.map (fun ty -> (i.info, ty)) results))
            in
            return [ i' ]
        | Cons _ | Unreachable ->
            (* The block's value is already on the stack, produced by an earlier
                instruction (or the code is unreachable); this trailing one is a
                statement, not the result-producer, so type it as such rather
                than routing it through [check_instruction]. *)
            let* i' = toplevel_instruction ctx i in
            let* () =
              push_results
                (Array.to_list
                   (Array.map (fun ty -> (i.info, ty)) (fst i'.info)))
            in
            return [ i' ])
          st
  | i :: r ->
      let* i' = toplevel_instruction ctx i in
      let* () =
        push_results
          (Array.to_list (Array.map (fun ty -> (i.info, ty)) (fst i'.info)))
      in
      let* r' = block_contents ctx results r in
      return (merge_let_tuple ctx i' r')

and block ctx loc label params results br_params block =
  with_empty_stack ctx ~location:loc ~kind:Block
    (let* () =
       push_results (Array.to_list (Array.map (fun ty -> (loc, ty)) params))
     in
     let* block' =
       block_contents
         {
           ctx with
           control_types =
             (Option.map (fun l -> l.desc) label, br_params)
             :: ctx.control_types;
         }
         results block
     in
     let* () = pop_args ctx ~location:loc results in
     return block')

(* Like [block] for a paramless block checked against a single [result] type, but
   also report whether the surrounding binding annotation is needed — i.e. would
   [let x = <block>] (no annotation) re-infer a different type? It is *not* needed
   exactly when the value the block produces already has type [result] on its
   own, without the context forcing it. The block's value is the join of the
   values reaching its exit, all of which are checked to be subtypes of [result];
   so when the fall-through's own natural type is already [result], that join is
   [result] regardless of any value branched to the block's label — and the
   annotation is redundant. Read the fall-through's natural type off the stack,
   unconstrained, before [pop_args] coerces it to [result], and compare
   ([annotation_needed], as the leaf [check_instruction] arm does). Stay conservative
   (needed) only when the trailing instruction is a construction — routed through
   [result] to resolve a context-pinned type name, which hides its natural type. A
   trailing nested block is instead synthesized (routed through the inferring cell)
   so its type joins like any other exit value. Returns the typed body and that
   keep-bool. *)
and block_keep_bool ctx loc label ~result ~br_params body =
  (* The keep-bool is decided from every value reaching the exit: the fall-through
     plus values branched to the label, collected at their natural types into [cs]
     (the branch-target [r] is a [Collecting] cell), then joined. The trailing
     instruction needs care: one that resolves its own type joins like any other
     exit value (route it through [r] — it synthesizes), but one that needs the
     context to pin its type must be routed through the concrete [result], which
     hides its natural type, so keep the annotation for it. A nested block always
     resolves itself; a struct does iff its fields name a unique type
     ([infer_struct_by_fields]) — then it synthesizes the same with or without the
     context, so route it through [r]; a field-ambiguous struct needs the context
     to pin its type (a named one still relies on it to drop its redundant name),
     so keep the annotation. (Only structs are field-checked here; other
     constructions stay conservative.) *)
  let trailing_construction, trailing_nested_block =
    match List.rev body with
    | last :: _ -> (
        match last.desc with
        | Struct (_, fields) -> (
            match infer_struct_by_fields ctx fields with
            | Some _ -> (false, true)
            | None -> (true, false))
        | StructDefault _ | Array _ | ArrayDefault _ | ArrayFixed _
        | ArraySegment _ | String _ ->
            (true, false)
        | If _ | Block _ | Loop _ | TryTable _ | Try _ -> (false, true)
        | Cast (e, _) -> (is_null_initializer e, false)
        | _ -> (false, false))
    | [] -> (false, false)
  in
  (* A trailing construction is routed through [result], hiding its natural type,
     so its annotation is load-bearing — mark the cell needed up front. *)
  let cs, r = fresh_collecting ~needed:trailing_construction (Some result) in
  (* Branches deliver the result for every kind but [loop] (where they re-enter):
     mirror the caller's [br_params] arity with the [Collecting] cell so their
     values are recorded. *)
  let br = if Array.length br_params > 0 then [| r |] else [||] in
  (* Route a trailing nested block through the inferring cell so it synthesizes;
     a construction or leaf is checked against the concrete result. *)
  let result_routing = if trailing_nested_block then r else result in
  with_empty_stack ctx ~location:loc ~kind:Block
    (let* block' =
       block_contents
         {
           ctx with
           control_types =
             (Option.map (fun l -> l.desc) label, br) :: ctx.control_types;
         }
         [| result_routing |] body
     in
     fun st ->
       (* Snapshot the fall-through's natural type before [pop_args] resolves it
          to [result], so it joins with the branched values at its own type. *)
       (match st with
       | Cons (loc', tv, _) ->
           cs.collected <-
             (Some loc', UnionFind.make (UnionFind.find tv)) :: cs.collected
       | Empty | Unreachable -> ());
       let st, () = pop_args ctx ~location:loc [| result |] st in
       (* Return the cell: the caller may deliver more values to it (a [try]'s catch
          handlers) before [block_keep_needed] reads the join. Every value reaching
          the exit is already validated against [result] — the fall-through by
          [pop_args], the branched/caught values per-delivery as they were
          collected — so the join only decides the keep-bool. *)
       (st, (block', r)))

(* The keep-bool for a checked block typed by [block_keep_bool]: keep the
   annotation when a delivery relied on it ([cs.needed] — a trailing construction,
   or a [resume] handler that read the cell) or the join of the values reaching the
   exit differs from the context type [result]. Read after any extra deliveries
   (a [try]'s catch handlers) have been collected. *)
and block_keep_needed ctx ~loc ~result r =
  match UnionFind.find r with
  | Collecting cs -> (
      cs.needed
      ||
      match join_collected ctx ~location:loc cs.collected with
      | Some j -> annotation_needed ctx (standalone_valtype ctx j) result
      | None -> true)
  | _ -> true

(* Type a block body in synthesis (no expected result), inferring its single
   fall-through value as the block's result. Only valid where no branch targets
   the block's label (the caller checks via [Ast_utils.refs_label_list]), so the
   label is never used as a branch target and the value reaching the exit is
   exactly the trailing fall-through one. Returns the typed body and the inferred
   result cell, paired with the location where that value was pushed (for
   diagnostics): [Some (loc, tv)] for a single trailing value, [None] for a void
   or divergent body (the caller then keeps the source annotation / treats it as
   void). *)
and block_infer ctx loc label body =
  with_empty_stack ctx ~location:loc ~kind:Block
    (let* body' =
       block_contents
         {
           ctx with
           control_types =
             (Option.map (fun l -> l.desc) label, [||]) :: ctx.control_types;
         }
         [||] body
     in
     fun st ->
       match st with
       | Cons (loc, tv, Empty) -> (Empty, (body', Some (loc, tv)))
       | Empty -> (Empty, (body', None))
       | Unreachable -> (Unreachable, (body', None))
       | Cons _ -> (st, (body', None)))

(* From the [inferred] result of an inferring block (already joined across an
   [if]'s branches) and the source [typ], produce the result-type cells for the
   stack effect and the [typ] to store on the node. For an omitted annotation
   ([typ.results = [||]]) the inferred type fills it in; for an explicit single
   result the annotation is dropped (cleared) when [simplify] and the inferred
   type is a subtype of it, else kept. (When it is a strict subtype the block
   re-infers to that subtype — a more precise but still valid result type that
   the surrounding context, which accepted the declared supertype, still
   accepts; the round-trip is then more precise than the source rather than
   byte-identical, as elsewhere.) *)
and finalize_inferred ?(needed = false) ctx typ ~inferred =
  if typ.results = [||] then
    match Option.bind inferred (resolve_omitted_valtype ctx) with
    | Some iv ->
        ([| UnionFind.make (Valtype iv) |], { typ with results = [| iv.typ |] })
    | None -> ([||], typ)
  else
    let result_cells =
      match array_map_opt (internalize ctx) typ.results with
      | Some a -> a
      | None -> [||]
    in
    let drop =
      ctx.simplify && (not needed)
      && Array.length result_cells = 1
      &&
      match
        ( Option.bind inferred (standalone_valtype ctx),
          standalone_valtype ctx result_cells.(0) )
      with
      | Some v, Some t ->
          Wax_wasm.Types.val_subtype ctx.subtyping_info v.internal t.internal
      | _ -> false
    in
    (result_cells, if drop then { typ with results = [||] } else typ)

(* Try to infer (and, on [simplify], drop) an [if]'s result type from its two
   branches' fall-through values, returning the typed node when it applies and
   [None] to fall back to the annotated path. Shared by the expression-position
   ([instruction]) and statement-position ([toplevel_instruction]) [If] cases;
   [cond] is the already-typed condition. Applies only with an [else], no branch
   to the [if]'s own label, at most one result, and either an omitted annotation
   (re-parse, must re-infer) or [simplify]. The branches are typed in synthesis
   (via [block_infer]), so a trailing construction synthesizes its own type —
   keeping its type name only when the fields don't pin it — rather than taking
   it from the result as the [check_instruction] path does; [finalize_inferred] then only
   drops [=> T] when that synthesized type is a subtype of it, so a tail that
   cannot synthesize on its own (a bare [null]) keeps it. *)
and if_inference ctx i label typ ~cond ~if_block ~else_block =
  let no_self_branch =
    match label with
    | None -> true
    | Some l ->
        not
          (Ast_utils.refs_label_list l.desc if_block.desc
          ||
          match else_block with
          | Some b -> Ast_utils.refs_label_list l.desc b.desc
          | None -> false)
  in
  let omitted = typ.results = [||] in
  let use_infer =
    Array.length typ.params = 0
    && Option.is_some else_block && no_self_branch
    && Array.length typ.results <= 1
    && (omitted || ctx.simplify)
  in
  if not use_infer then None
  else
    let if_block', r1 = block_infer ctx i.info label if_block.desc in
    let else_block', r2 =
      block_infer ctx i.info label (Option.get else_block).desc
    in
    let inferred =
      match (r1, r2) with
      | Some (loc1, a), Some (loc2, b) -> (
          match join_value_types ctx a b with
          | Some _ as r -> r
          | None ->
              Error.if_branch_type_mismatch ctx.diagnostics ~location:i.info
                ~loc1 ~loc2 a b;
              (* Recover with one branch's type so the result is still a single
                 value (avoids a cascading empty-stack error downstream). *)
              Some a)
      | Some (_, a), None | None, Some (_, a) -> Some a
      | None, None -> None
    in
    let results, typ = finalize_inferred ctx typ ~inferred in
    Some
      ( If
          {
            label;
            typ;
            cond;
            if_block = { if_block with desc = if_block' };
            else_block =
              Some { (Option.get else_block) with desc = else_block' };
          },
        results )

(* The block's declared single result internalized to a cell, or [None] when the
   result is omitted. *)
and declared_result ctx typ =
  match typ.results with [| t |] -> internalize ctx t | _ -> None

(* A fresh [Collecting] result cell and its backing record: [declared] is the
   annotation under test (or [None]), [needed] preset when it is already known to
   be load-bearing. *)
and fresh_collecting ?(needed = false) declared =
  let cs = { collected = []; declared; needed } in
  (cs, UnionFind.make (Collecting cs))

(* Type a (possibly branch-targeted) block body in synthesis, inferring its
   single result from every value that reaches its exit: the fall-through value
   plus each value branched to its label. Unlike [block_infer] (used for [if],
   which forbids self-branches), the label is bound to a fresh [Unknown] result
   cell ([Collecting]), so [br]/[br_on_*] to it record their value (via
   [subtype]) rather than unifying. Returns the typed body and the collected
   values reaching the exit. *)
and block_infer_general ctx loc label ~declared instrs =
  let cs, r = fresh_collecting declared in
  with_empty_stack ctx ~location:loc ~kind:Block
    (let* body' =
       block_contents
         {
           ctx with
           control_types =
             (Option.map (fun l -> l.desc) label, [| r |]) :: ctx.control_types;
         }
         (* Pass the [Collecting] cell as the result too (not [||]): a trailing
            nested block is then routed and synthesized (its value collected),
            rather than typed as a void statement and lost. The fall-through is
            still read off the stack below. *)
         [| r |]
         instrs
     in
     fun st ->
       (* The fall-through value (if any) reaches the exit alongside the
          branched ones. A single leftover is consumed; anything else is left
          for [with_empty_stack] to report. A value sitting on an [Unreachable]
          base is a dead fall-through (e.g. after a [br]): consume it just as
          [pop_args] would in check position, leaving the unreachable base. *)
       match st with
       | Cons (loc, tv, Empty) ->
           cs.collected <- (Some loc, tv) :: cs.collected;
           (Empty, (body', cs))
       | Cons (loc, tv, Unreachable) ->
           cs.collected <- (Some loc, tv) :: cs.collected;
           (Unreachable, (body', cs))
       | Empty -> (Empty, (body', cs))
       | Unreachable -> (Unreachable, (body', cs))
       | Cons _ -> (st, (body', cs)))

(* Join the values reaching a block's exit into its inferred result, or [None]
   when none do (a void or fully divergent body). Incompatible exit types are
   reported with a caret at each offending value (falling back to [location], the
   block, when a value carries none); this is unreachable for well-typed input,
   where every exit is a subtype of the declared result. One type is kept so a
   single result is still produced. *)
and join_collected ctx ~location collected =
  match collected with
  | [] -> None
  | (loc0, first) :: rest ->
      Some
        (snd
           (List.fold_left
              (fun (loc_acc, acc) (loc, ty) ->
                match join_value_types ctx acc ty with
                | Some r -> (loc_acc, r)
                | None ->
                    Error.block_exit_type_mismatch ctx.diagnostics ~location
                      ~loc1:(Option.value loc_acc ~default:location)
                      ~loc2:(Option.value loc ~default:location)
                      acc ty;
                    (loc_acc, acc))
              (loc0, first) rest))

(* Try to infer (and, on [simplify], drop) the result type of a [do]/labelled
   block from the values reaching its exit. Mirrors [if_inference] for the
   single-branch [Block] form, but admits branches to the block's own label. *)
(* Whether to infer a block's result in expression (synthesis) position: only
   for the single-result, parameterless forms, and only when the annotation is
   omitted (a re-parse of a dropped one, which must be re-inferred) or [simplify]
   is converting from Wasm (so a redundant annotation can be dropped). *)
and infer_block_applies ctx typ =
  Array.length typ.params = 0
  && (typ.results = [||] || (ctx.simplify && Array.length typ.results = 1))

and block_inference ctx i label typ ~instrs =
  if not (infer_block_applies ctx typ) then None
  else
    let body', cs =
      block_infer_general ctx i.info label ~declared:(declared_result ctx typ)
        instrs
    in
    let inferred = join_collected ctx ~location:i.info cs.collected in
    let results, typ = finalize_inferred ~needed:cs.needed ctx typ ~inferred in
    Some (Block { label; typ; block = body' }, results)

(* Expression-position synthesis inference for [loop]/[try]/[try_table], the
   analogue of [block_inference] for [do]. Type the body (and, for [try], the
   handlers) against a fresh [Collecting] result cell so every value reaching the
   exit — the fall-through, and values branched to the block's label — is
   recorded, then join them and (on [simplify]) drop a redundant annotation. A
   [br] to a loop re-enters at its top (branch-target = the empty params), so a
   loop's value is only its fall-through; the others deliver to their label. *)
and loop_inference ctx i label typ ~instrs =
  if not (infer_block_applies ctx typ) then None
  else
    let cs, r = fresh_collecting (declared_result ctx typ) in
    let results = [| r |] in
    let instrs' = block ctx i.info label [||] results [||] instrs in
    let inferred = join_collected ctx ~location:i.info cs.collected in
    let results, typ = finalize_inferred ~needed:cs.needed ctx typ ~inferred in
    Some (Loop { label; typ; block = instrs' }, results)

and trytable_inference ctx i label typ ~body ~catches =
  if not (infer_block_applies ctx typ) then None
  else
    let cs, r = fresh_collecting (declared_result ctx typ) in
    let results = [| r |] in
    let body' = block ctx i.info label [||] results results body in
    check_trytable_catches ctx catches;
    let inferred = join_collected ctx ~location:i.info cs.collected in
    let results, typ = finalize_inferred ~needed:cs.needed ctx typ ~inferred in
    Some (TryTable { label; typ; block = body'; catches }, results)

and try_inference ctx i label typ ~body ~catches ~catch_all =
  if not (infer_block_applies ctx typ) then None
  else
    let cs, r = fresh_collecting (declared_result ctx typ) in
    let results = [| r |] in
    let body' = block ctx i.info label [||] results results body in
    let catches, catch_all =
      type_try_catches ctx i label ~results catches catch_all
    in
    let inferred = join_collected ctx ~location:i.info cs.collected in
    let results, typ = finalize_inferred ~needed:cs.needed ctx typ ~inferred in
    Some (Try { label; typ; block = body'; catches; catch_all }, results)

let check_type_definitions ctx =
  (*ZZZ In-order check? *)
  Tbl.iter ctx.types (fun _ (i, (st : subtype)) ->
      let ty = Wax_wasm.Types.get_subtype ctx.subtyping_info i in
      (* A continuation type must wrap a function type. Point at the wrapped
         type as the source wrote it. *)
      (match (ty.typ, st.typ) with
      | Cont ft, Cont src_ref -> (
          match (Wax_wasm.Types.get_subtype ctx.subtyping_info ft).typ with
          | Func _ -> ()
          | Struct _ | Array _ | Cont _ ->
              Error.expected_func_type ctx.diagnostics ~location:src_ref.info)
      | _ -> ());
      (* Every check below is about the type's relationship to its declared
         supertype, so the supertype reference [sup] is the place to point. *)
      match (ty.supertype, st.supertype) with
      | None, _ | _, None -> ()
      | Some j, Some sup ->
          let location = sup.info in
          let ty' = Wax_wasm.Types.get_subtype ctx.subtyping_info j in
          if ty'.final then Error.final_supertype ctx.diagnostics ~location sup
          else
            let valid_subtype =
              match (ty.typ, ty'.typ) with
              | ( Func { params; results },
                  Func { params = params'; results = results' } ) ->
                  Array.length params = Array.length params'
                  && Array.length results = Array.length results'
                  && Array.for_all2
                       (fun p p' ->
                         Wax_wasm.Types.val_subtype ctx.subtyping_info p' p)
                       params params'
                  && Array.for_all2
                       (fun r r' ->
                         Wax_wasm.Types.val_subtype ctx.subtyping_info r r')
                       results results'
              | Struct fields, Struct fields' ->
                  Array.length fields' <= Array.length fields
                  &&
                  let rec loop k =
                    k >= Array.length fields'
                    || (field_subtype ctx fields.(k) fields'.(k) && loop (k + 1))
                  in
                  loop 0
              | Array field, Array field' -> field_subtype ctx field field'
              | Cont ft, Cont ft' ->
                  Wax_wasm.Types.heap_subtype ctx.subtyping_info (Type ft)
                    (Type ft')
              | Func _, (Struct _ | Array _ | Cont _)
              | Struct _, (Func _ | Array _ | Cont _)
              | Array _, (Func _ | Struct _ | Cont _)
              | Cont _, (Func _ | Struct _ | Array _) ->
                  false
            in
            if not valid_subtype then
              Error.invalid_subtype ctx.diagnostics ~location sup)

let rec check_constant_instruction ctx i =
  let location = snd i.info in
  match i.desc with
  | Get idx -> (
      match Tbl.find_opt ctx.globals idx with
      | Some (mut, _) ->
          if mut then Error.constant_global_required ctx.diagnostics ~location
      | None -> (* ref.func *) ())
  | Null | StructDefault _ | ArrayDefault _ | Int _ | Float _ | Char _
  | String _ ->
      ()
  | Struct (_, l) ->
      List.iter (fun (_, i) -> check_constant_instruction ctx i) l
  | ArrayFixed (_, l) -> List.iter (check_constant_instruction ctx) l
  | Array (_, i1, i2) ->
      check_constant_instruction ctx i1;
      check_constant_instruction ctx i2
  | BinOp ({ desc = Add | Sub | Mul; _ }, i1, i2) -> (
      check_constant_instruction ctx i1;
      check_constant_instruction ctx i2;
      match UnionFind.find (expression_type ctx i) with
      | Int | Valtype { internal = I32 | I64; _ } -> ()
      | _ -> Error.constant_expression_required ctx.diagnostics ~location)
  | Cast ({ desc = Null; _ }, Valtype (Ref { nullable = true; _ })) ->
      (* ref.null *)
      ()
  | Cast (i', Valtype (Ref { typ = I31; _ })) -> (
      (* ref.i31 *)
      check_constant_instruction ctx i';
      match UnionFind.find (expression_type ctx i') with
      | Valtype { internal = I32; _ } -> ()
      | _ -> Error.constant_expression_required ctx.diagnostics ~location)
  | Cast (i', Valtype (Ref { typ = Extern; nullable })) ->
      (* extern.convert_any *)
      check_constant_instruction ctx i';
      if
        match (UnionFind.find (expression_type ctx i') : inferred_type) with
        | Valtype { internal; _ } ->
            not
              (Wax_wasm.Types.val_subtype ctx.subtyping_info internal
                 (Ref { nullable; typ = Any }))
        | _ -> true
      then Error.constant_expression_required ctx.diagnostics ~location
  | Cast (i', Valtype (Ref { typ = Any; nullable })) ->
      (* any.convert_extern *)
      check_constant_instruction ctx i';
      if
        match (UnionFind.find (expression_type ctx i') : inferred_type) with
        | Valtype { internal; _ } ->
            not
              (Wax_wasm.Types.val_subtype ctx.subtyping_info internal
                 (Ref { nullable; typ = Extern }))
        | _ -> true
      then Error.constant_expression_required ctx.diagnostics ~location
  | UnOp ({ desc = Pos; _ }, i') -> check_constant_instruction ctx i'
  | UnOp ({ desc = Neg; _ }, { desc = Float _ | Int _; _ }) -> ()
  (* [v128.const] is a constant expression; its lanes are literals. Other SIMD
     ops are not constant. *)
  | Call ({ desc = Get name; _ }, args)
    when Simd.const_shape_of_name name.desc <> None ->
      List.iter (check_constant_instruction ctx) args
  | UnOp ({ desc = Neg | Not; _ }, _)
  | BinOp
      ( {
          desc =
            ( Div _ | Rem _ | And | Or | Xor | Shl | Shr _ | Eq | Ne | Lt _
            | Gt _ | Le _ | Ge _ );
          _;
        },
        _,
        _ )
  | Block _ | Loop _ | While _ | If _ | TryTable _ | Try _ | Dispatch _
  | Match _ | Unreachable | Nop | Hole | Set _ | Tee _ | Call _ | TailCall _
  | Cast _ | Test _ | NonNull _ | StructGet _ | StructSet _ | ArraySegment _
  | ArrayGet _ | ArraySet _ | Let _ | Br _ | Br_if _ | Br_table _ | Br_on_null _
  | Br_on_non_null _ | Br_on_cast _ | Br_on_cast_fail _ | Throw _ | ThrowRef _
  | ContNew _ | ContBind _ | Suspend _ | Resume _ | ResumeThrow _
  | ResumeThrowRef _ | Switch _ | Return _ | Sequence _ | Select _
  | If_annotation _ ->
      Error.constant_expression_required ctx.diagnostics ~location

type ('before, 'after) phased =
  | Before of 'before
  | After of 'after
  | PhasedGroup of { before : 'before; fields : ('before, 'after) phased list }
  | PhasedConditional of {
      before : 'before;
      then_ : ('before, 'after) phased list;
      else_ : ('before, 'after) phased list option;
    }

(* Type a data-segment offset as a constant expression of the memory address type. *)
let type_data_offset ctx address_type off =
  let off' =
    with_empty_stack ctx ~location:off.info ~kind:Expression
      (toplevel_instruction ctx off)
  in
  check_type ctx off' (UnionFind.make (Valtype (address_valtype address_type)));
  check_constant_instruction ctx off';
  off'

let rec globals ctx fields =
  List.map
    (fun field ->
      match field.desc with
      | Memory ({ address_type; data; _ } as m) ->
          check_limits ctx ~location:field.info "memory" address_type m.limits
            max_memory_size;
          let data =
            List.map
              (fun (d : _ Ast.memdata) ->
                { d with offset = type_data_offset ctx address_type d.offset })
              data
          in
          After { field with desc = Memory { m with data } }
      | Data ({ mode; _ } as d) ->
          let mode =
            match mode with
            | Passive -> Passive
            | Active (mem, off) ->
                let address_type =
                  match Tbl.find_opt ctx.memories mem with
                  | Some (_, at) -> at
                  | None ->
                      let suggestions =
                        Wax_utils.Spell_check.f
                          (fun f -> Tbl.iter ctx.memories (fun k _ -> f k))
                          mem.desc
                      in
                      Error.unbound_name ctx.diagnostics ~location:mem.info
                        ~suggestions "memory" mem;
                      `I32
                in
                Active (mem, type_data_offset ctx address_type off)
          in
          After { field with desc = Data { d with mode } }
      | Elem ({ reftype = rt; mode; init; _ } as e) ->
          let mode =
            match mode with
            | EPassive -> EPassive
            | EActive (tab, off) ->
                (* The offset indexes [tab], whose address type may be i64. *)
                let address_type =
                  match Tbl.find_opt ctx.tables tab with
                  | Some (at, _) -> at
                  | None ->
                      let suggestions =
                        Wax_utils.Spell_check.f
                          (fun f -> Tbl.iter ctx.tables (fun k _ -> f k))
                          tab.desc
                      in
                      Error.unbound_name ctx.diagnostics ~location:tab.info
                        ~suggestions "table" tab;
                      `I32
                in
                EActive (tab, type_data_offset ctx address_type off)
          in
          let elem_typ = internalize ctx (Ref rt) in
          let init =
            List.map
              (fun i ->
                let i' =
                  with_empty_stack ctx ~location:i.info ~kind:Expression
                    (toplevel_instruction ctx i)
                in
                (let>@ typ = elem_typ in
                 check_type ctx i' typ);
                check_constant_instruction ctx i';
                i')
              init
          in
          After { field with desc = Elem { e with mode; init } }
      | Table ({ reftype = rt; init; _ } as t) ->
          check_limits ctx ~location:field.info "table" t.address_type t.limits
            max_table_size;
          (* Without an initializer the table is filled with the element type's
             default value, which a non-nullable reference does not have. *)
          if Option.is_none init && not rt.nullable then
            Error.non_nullable_table ctx.diagnostics ~location:field.info;
          (* A table initializer may reference only imported globals. *)
          let init_ctx = { ctx with globals = ctx.import_globals } in
          let init =
            Option.map
              (fun e ->
                let e' =
                  with_empty_stack init_ctx ~location:e.info ~kind:Expression
                    (toplevel_instruction init_ctx e)
                in
                (let>@ typ = internalize ctx (Ref rt) in
                 check_type ctx e' typ);
                check_constant_instruction init_ctx e';
                e')
              init
          in
          After { field with desc = Table { t with init } }
      | Global ({ name; mut; typ; def; _ } as g) ->
          let typ, def' =
            match typ with
            | Some annot -> (
                (* Type the initializer in checking mode against the annotation,
                   mirroring a [let] binding: an omitted struct/array name is
                   inferred from it, and the keep-bool decides whether the
                   annotation is redundant (dropped only when converting from
                   Wasm, and never for a [null] whose bare form would re-infer a
                   floating type — see [is_null_initializer]). An immutable
                   ([const]) global additionally drops an annotation that is a
                   mere supertype of the initializer's type ([drop_supertype]),
                   narrowing the global to that subtype — sound since nothing
                   reassigns it (see [annotation_needed]). *)
                match internalize_valtype ctx annot with
                | None ->
                    let def' =
                      with_empty_stack ctx ~location:def.info ~kind:Expression
                        (toplevel_instruction ctx def)
                    in
                    (Some annot, def')
                | Some ity ->
                    (* Type the initializer before registering the global, so a
                       self-reference (an initializer mentioning this global) is
                       still reported as an unknown name. *)
                    let def', needed =
                      with_empty_stack ctx ~location:def.info ~kind:Expression
                        (check_toplevel ~drop_supertype:(not mut) ctx
                           (UnionFind.make (Valtype ity))
                           def)
                    in
                    Tbl.add ctx.diagnostics ctx.globals name (mut, Some ity);
                    let drop =
                      ctx.simplify && (not needed)
                      && not (is_null_initializer def')
                    in
                    ((if drop then None else Some annot), def'))
            | None ->
                (* No annotation: the global takes the initializer's type, the
                   way a [let] binding without an annotation does. An
                   [Unknown]/[Error] initializer makes the global poison
                   ([None]) rather than defaulting to [i32], so its uses do not
                   cascade; an [Unknown] one is additionally reported (see
                   [bound_value_type]). *)
                let def' =
                  with_empty_stack ctx ~location:def.info ~kind:Expression
                    (toplevel_instruction ctx def)
                in
                let ity =
                  bound_value_type ctx ~location:def.info
                    (expression_type ctx def')
                in
                Tbl.add ctx.diagnostics ctx.globals name (mut, ity);
                (None, def')
          in
          check_constant_instruction ctx def';
          After { field with desc = Global { g with typ; def = def' } }
      | Group { fields; _ } ->
          let fields = globals ctx fields in
          PhasedGroup { before = field; fields }
      | Conditional { cond; then_fields; else_fields } ->
          PhasedConditional
            {
              before = field;
              then_ =
                with_cond ctx ~location:field.info cond true (fun () ->
                    globals ctx then_fields);
              else_ =
                Option.map
                  (fun e ->
                    with_cond ctx ~location:field.info cond false (fun () ->
                        globals ctx e))
                  else_fields;
            }
      | _ -> Before field)
    fields

let rec functions ctx fields =
  List.filter_map
    (fun field ->
      match field with
      | Before
          ({
             desc = Func { name; sign; body = label, body; typ; attributes };
             info = location;
           } as f) ->
          let*@ func_typ =
            let*@ ty =
              let*@ func_typ = Tbl.find ctx.diagnostics ctx.functions name in
              Tbl.find ctx.diagnostics ctx.types
                { name with desc = snd func_typ }
            in
            match ty with
            | _, { typ = Func typ; _ } -> Some typ
            | _ ->
                Error.expected_func_type ctx.diagnostics ~location:name.info;
                None
          in
          (* A [#[start]] function must have no parameters and no results. *)
          if
            List.exists (fun (k, _) -> k = "start") attributes
            && not
                 (Array.length func_typ.params = 0
                 && Array.length func_typ.results = 0)
          then
            Error.start_function_signature ctx.diagnostics ~location:name.info;
          let*@ return_types =
            array_map_opt (fun typ -> internalize ctx typ) func_typ.results
          in
          let locals = ref StringMap.empty in
          (match sign with
          | Some { params; _ } ->
              Array.iter
                (fun p ->
                  let id, typ = p.desc in
                  match id with
                  | Some id ->
                      let>@ typ = internalize_valtype ctx typ in
                      locals := StringMap.add id.desc (Some typ) !locals
                  | None -> ())
                params
          | _ -> ());
          if debug then Format.eprintf "=== %s@." name.desc;
          let ctx =
            {
              ctx with
              locals = !locals;
              (* Parameters are always initialized. *)
              initialized_locals =
                StringMap.fold
                  (fun k _ s -> StringSet.add k s)
                  !locals StringSet.empty;
              (* Fresh per-function tracking of declared and read locals. *)
              read_locals = ref StringSet.empty;
              local_decls = ref [];
              (* Locals a later assignment writes, collected up front so a
                 fused [let]'s drop can spot a write-once binding (linear: one
                 traversal per function, not per binding). *)
              assigned_locals =
                List.fold_left collect_assigned_locals StringSet.empty body;
              control_types =
                [ (Option.map (fun l -> l.desc) label, return_types) ];
              return_types;
            }
          in
          let body =
            with_empty_stack ctx ~location ~kind:Function
              (let* body = block_contents ctx return_types body in
               let* () = pop_args ctx ~location return_types in
               return body)
          in
          (* A local whose name starts with [_] is intentionally unused. *)
          if ctx.warn_unused then
            List.iter
              (fun name ->
                let n = name.desc in
                if
                  (not (StringSet.mem n !(ctx.read_locals)))
                  && not (String.length n > 0 && n.[0] = '_')
                then Error.unused_local ctx.diagnostics ~location:name.info name)
              (List.rev !(ctx.local_decls));
          Some
            {
              f with
              desc = Func { name; sign; body = (label, body); typ; attributes };
            }
      | PhasedGroup
          { before = { desc = Group { attributes; _ }; info }; fields } ->
          Some
            { info; desc = Group { attributes; fields = functions ctx fields } }
      | PhasedConditional
          { before = { desc = Conditional { cond; _ }; info }; then_; else_ } ->
          Some
            {
              info;
              desc =
                Conditional
                  {
                    cond;
                    then_fields =
                      with_cond ctx ~location:info cond true (fun () ->
                          functions ctx then_);
                    else_fields =
                      Option.map
                        (fun e ->
                          with_cond ctx ~location:info cond false (fun () ->
                              functions ctx e))
                        else_;
                  };
            }
      | PhasedGroup _ | PhasedConditional _
      | Before
          {
            desc =
              ( Global _ | Group _ | Conditional _ | Memory _ | Data _ | Elem _
              | Table _ );
            _;
          } ->
          assert false
      | After f -> Some f
      | Before ({ desc = Type _ | Fundecl _ | GlobalDecl _ | Tag _; _ } as f) ->
          Some f)
    fields

let funsig ctx sign =
  check_unique_param_names ctx.diagnostics sign.params;
  sign

(* A function or tag may give both a type reference and an inline signature
   (e.g. [fn f: T (i32) -> i32]); the inline signature must then match the
   referenced function type [referenced]. The two are compared in canonical
   [Internal] form. Mirrors [Validation.check_inline_type]. *)
let check_inline_type ctx ~location referenced sign =
  match sign with
  | None -> ()
  | Some sign -> (
      match (internal_functype ctx referenced, internal_functype ctx sign) with
      | Some f, Some f' ->
          if f <> f' then
            Error.inline_function_type_mismatch ctx.diagnostics ~location
      | _ -> ())

let fundecl ctx name typ sign =
  if Tbl.exists ctx.diagnostics ctx.functions name then None
  else
    match typ with
    | Some typ -> (
        let*@ info = Tbl.find ctx.diagnostics ctx.types typ in
        (* The referenced type must be a function type (as for tags below); if
           an inline signature is also given, it must match. *)
        match snd info with
        | { typ = Func ft; _ } ->
            check_inline_type ctx ~location:typ.info ft sign;
            Some (fst info, typ.desc)
        | _ ->
            Error.expected_func_type ctx.diagnostics ~location:typ.info;
            None)
    | None -> (
        match sign with
        | Some sign ->
            let name = { name with desc = "<func:" ^ name.desc ^ ">" } in
            let+@ i =
              (* [add_type] runs the [functype] converter, which already checks
                 parameter-name uniqueness, so [sign] needs no separate
                 [funsig] pass here (that would report duplicates twice). *)
              add_type ctx.diagnostics ctx.type_context
                [|
                  Ast.no_loc
                    (name, { supertype = None; typ = Func sign; final = true });
                |]
            in
            (i, name.desc)
        | None -> assert false)

let field_attributes (field : _ modulefield) =
  match field with
  | Fundecl { attributes; _ }
  | Func { attributes; _ }
  | GlobalDecl { attributes; _ }
  | Global { attributes; _ }
  | Tag { attributes; _ }
  | Memory { attributes; _ }
  | Data { attributes; _ }
  | Table { attributes; _ }
  | Elem { attributes; _ }
  | Group { attributes; _ } ->
      attributes
  | Type _ | Conditional _ -> []

(* Validate the annotations on a module field: reject unknown ones, check the
   value shape of [export] / [import] / [start], allow each only where it is
   meaningful, and require an [import] on a body-less declaration. *)
let check_attributes diagnostics field =
  let export_ok, import_ok, start_ok =
    match field.desc with
    | Func _ -> (true, false, true)
    | Fundecl _ | GlobalDecl _ -> (true, true, false)
    | Global _ -> (true, false, false)
    | Memory _ | Table _ | Tag _ -> (true, true, false)
    | Data _ | Elem _ | Type _ | Group _ | Conditional _ -> (false, false, false)
  in
  List.iter
    (fun (name, value) ->
      let location = match value with Some v -> v.info | None -> field.info in
      match name with
      | "export" ->
          (match value with
          | Some { desc = String _; _ } -> ()
          | _ ->
              Error.annotation_value_mismatch diagnostics ~location "export"
                "a string");
          if not export_ok then
            Error.annotation_not_allowed diagnostics ~location "export"
      | "import" ->
          (match value with
          | Some
              {
                desc =
                  Sequence [ { desc = String _; _ }; { desc = String _; _ } ];
                _;
              } ->
              ()
          | _ ->
              Error.annotation_value_mismatch diagnostics ~location "import"
                "a module and name, e.g. (\"env\", \"f\")");
          if not import_ok then
            Error.annotation_not_allowed diagnostics ~location "import"
      | "start" ->
          (match value with
          | None -> ()
          | Some _ ->
              Error.annotation_value_mismatch diagnostics ~location "start"
                "no value");
          if not start_ok then
            Error.annotation_not_allowed diagnostics ~location "start"
      | _ -> Error.unknown_annotation diagnostics ~location name)
    (field_attributes field.desc);
  let imports =
    List.filter (fun (n, _) -> n = "import") (field_attributes field.desc)
  in
  (match imports with
  | _ :: (_, value) :: _ ->
      let location = match value with Some v -> v.info | None -> field.info in
      Error.multiple_import diagnostics ~location
  | _ -> ());
  match field.desc with
  | (Fundecl _ | GlobalDecl _) when imports = [] ->
      Error.declaration_without_import diagnostics ~location:field.info
  | _ -> ()

let type_configuration ?(warn_unused = false) ~simplify diagnostics fields =
  let cond = ref Cond.true_ in
  let cond_env = Cond.create () in
  let type_context =
    {
      internal_types = Wax_wasm.Types.create ();
      types = Tbl.make (Namespace.make cond) "type";
    }
  in
  (* Walk module fields, recursing into groups and threading the branch
     assumption through conditionals so each [Type]/declaration is registered
     under the assumption of the branch it appears in. *)
  let rec walk_fields f fields =
    List.iter
      (fun (field : (_ modulefield, _) annotated) ->
        match field.desc with
        | Group { fields; _ } -> walk_fields f fields
        | Conditional { cond = c; then_fields; else_fields } ->
            with_cond_ref cond cond_env diagnostics ~location:field.info c true
              (fun () -> walk_fields f then_fields);
            Option.iter
              (fun e ->
                with_cond_ref cond cond_env diagnostics ~location:field.info c
                  false (fun () -> walk_fields f e))
              else_fields
        | _ -> f field)
      fields
  in
  walk_fields
    (fun (field : (_ modulefield, _) annotated) ->
      match field.desc with
      | Type rectype ->
          let _ : int option = add_type diagnostics type_context rectype in
          ()
      | _ -> ())
    fields;
  (* Index the struct types by their field set, so a literal whose name is
     omitted can be resolved from its fields. All types are registered above, so
     this is complete; a later distinct name for the same key marks it ambiguous
     ([None]), while a conditional variant of the same name does not. *)
  let structs_by_fields = Hashtbl.create 16 in
  Tbl.iter type_context.types (fun name (_, (st : subtype)) ->
      match st.typ with
      | Struct sfields -> (
          let key =
            field_set_key
              (Array.to_list (Array.map (fun f -> (fst f.desc).desc) sfields))
          in
          match Hashtbl.find_opt structs_by_fields key with
          | None ->
              Hashtbl.replace structs_by_fields key (Some (Ast.no_loc name))
          | Some (Some n) when n.desc = name -> ()
          | Some _ -> Hashtbl.replace structs_by_fields key None)
      | Func _ | Array _ | Cont _ -> ());
  let ctx =
    let namespace = Namespace.make cond in
    {
      diagnostics;
      type_context;
      subtyping_info = Wax_wasm.Types.subtyping_info type_context.internal_types;
      types = type_context.types;
      structs_by_fields;
      functions = Tbl.make namespace "function";
      globals = Tbl.make namespace "global";
      import_globals = Tbl.make namespace "global";
      memories = Tbl.make namespace "memory";
      datas = Tbl.make (Namespace.make cond) "data segment";
      tables = Tbl.make namespace "table";
      elems = Tbl.make (Namespace.make cond) "element segment";
      tags = Tbl.make (Namespace.make cond) "tag";
      locals = StringMap.empty;
      warn_unused;
      read_locals = ref StringSet.empty;
      local_decls = ref [];
      assigned_locals = StringSet.empty;
      initialized_locals = StringSet.empty;
      control_types = [];
      return_types = [||];
      cond;
      cond_env;
      simplify;
    }
  in
  check_type_definitions ctx;
  let memory_index = ref 0 in
  walk_fields
    (fun field ->
      match field.desc with
      | Memory { name; address_type; data; _ } ->
          let i = !memory_index in
          incr memory_index;
          Tbl.add diagnostics ctx.memories name (i, address_type);
          List.iter
            (fun (d : _ Ast.memdata) ->
              Option.iter
                (fun n -> Tbl.add diagnostics ctx.datas n ())
                d.data_name)
            data
      | Fundecl { name; typ; sign; _ } ->
          let>@ decl = fundecl ctx name typ sign in
          Tbl.add diagnostics ctx.functions name decl
      | GlobalDecl { name; mut; typ; _ } ->
          let>@ typ = internalize_valtype ctx typ in
          Tbl.add diagnostics ctx.globals name (mut, Some typ)
      | Func { name; typ; sign; _ } ->
          let>@ decl = fundecl ctx name typ sign in
          Tbl.add diagnostics ctx.functions name decl
      | Tag { name; typ; sign; _ } ->
          let>@ typ =
            match (typ, sign) with
            | Some typ, _ -> (
                let*@ info = Tbl.find ctx.diagnostics ctx.types typ in
                match snd info with
                | { typ = Func ft; _ } ->
                    check_inline_type ctx ~location:typ.info ft sign;
                    Some ft
                | _ ->
                    Error.expected_func_type ctx.diagnostics ~location:typ.info;
                    None)
            | None, Some sign -> Some (funsig ctx sign)
            | None, None -> assert false
          in
          Tbl.add diagnostics ctx.tags name typ
      | Data { name; _ } ->
          Option.iter (fun n -> Tbl.add diagnostics ctx.datas n ()) name
      | Table { name; address_type; reftype = rt; _ } ->
          Tbl.add diagnostics ctx.tables name (address_type, rt)
      | Elem { name; reftype = rt; _ } -> Tbl.add diagnostics ctx.elems name rt
      | Group _ | Conditional _ | Type _ | Global _ -> ())
    fields;
  (* A module may not export the same name twice. Each [#[export = "..."]]
     attribute is one export; [walk_fields] descends into groups and resolves
     conditionals per branch, so exports in mutually exclusive branches do not
     clash. *)
  let exports = Hashtbl.create 16 in
  let start_seen = ref false in
  walk_fields
    (fun field ->
      check_attributes diagnostics field;
      List.iter
        (fun (key, v) ->
          match (key, Option.map (fun (v : _ instr) -> v.desc) v) with
          | "export", Some (String (_, name)) ->
              (* Two exports of the same name clash only when the conditional
                 branches guarding them can hold at once; the same name in
                 mutually exclusive branches is fine. Each remembered guard is
                 the path condition ([!cond]) under which an export was seen. *)
              let guards =
                Option.value ~default:[] (Hashtbl.find_opt exports name)
              in
              if
                List.exists
                  (fun g -> Cond.is_satisfiable (Cond.and_ g !cond))
                  guards
              then
                Error.duplicated_export diagnostics
                  ~location:(Option.get v).info name;
              Hashtbl.replace exports name (!cond :: guards)
          | "start", _ ->
              (* A module may name at most one start function. *)
              if !start_seen then
                Error.multiple_start diagnostics ~location:field.info
              else start_seen := true
          | _ -> ())
        (field_attributes field.desc))
    fields;
  let _ : _ option =
    let name = Ast.no_loc "<string>" in
    add_type ctx.diagnostics ctx.type_context
      [|
        Ast.no_loc
          ( name,
            {
              supertype = None;
              typ = Array { mut = true; typ = Packed I8 };
              final = true;
            } );
      |]
  in
  let ctx =
    {
      ctx with
      subtyping_info = Wax_wasm.Types.subtyping_info type_context.internal_types;
      (* Only imports are registered at this point; snapshot them as the global
         scope visible to table initializers. *)
      import_globals = { ctx.globals with tbl = Hashtbl.copy ctx.globals.tbl };
    }
  in
  let phased_fields = globals ctx fields in
  let typed_fields = functions ctx phased_fields in
  ( ctx.type_context.types,
    List.map
      (fun f ->
        let desc =
          Ast_utils.map_modulefield
            (fun (types, loc) ->
              ( Array.map
                  (fun ty ->
                    match UnionFind.find ty with
                    | Unknown | Error | Collecting _ -> None
                    | Null ->
                        Some (Value (Ref { nullable = true; typ = None_ }))
                    | Number -> Some (Value I32)
                    | Int8 -> Some (Packed I8)
                    | Int16 -> Some (Packed I16)
                    | Int -> Some (Value I32)
                    | LargeInt -> Some (Value I64)
                    | Float -> Some (Value F64)
                    | Valtype { typ; _ } -> Some (Value typ))
                  types,
                loc ))
            f.desc
        in
        { f with desc })
      typed_fields )

(* Conditional annotations denote mutually-exclusive branches, so they are
   type-checked by exploring every reachable configuration (as the WAT validator
   does), rather than checking both branches as if they coexisted. *)

let rec instr_has_conditional (i : (_ instr_desc, _) annotated) =
  let any = List.exists instr_has_conditional in
  let opt = Option.fold ~none:false ~some:instr_has_conditional in
  match i.desc with
  | If_annotation _ -> true
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } -> any block
  | While { cond; block; _ } -> instr_has_conditional cond || any block
  | If { cond; if_block; else_block; _ } ->
      instr_has_conditional cond || any if_block.desc
      || Option.fold ~none:false ~some:(fun b -> any b.desc) else_block
  | Try { block; catches; catch_all; _ } ->
      any block
      || List.exists (fun (_, l) -> any l) catches
      || Option.fold ~none:false ~some:any catch_all
  | Sequence l -> any l
  | ArrayFixed (_, l) -> any l
  | Dispatch { index; arms; _ } ->
      instr_has_conditional index
      || List.exists (fun (_, body) -> any body) arms
  | Match { scrutinee; arms; default } ->
      instr_has_conditional scrutinee
      || List.exists (fun (_, body) -> any body) arms
      || any default
  | ContBind (_, _, l)
  | Suspend (_, l)
  | Resume (_, _, l)
  | ResumeThrow (_, _, _, l)
  | ResumeThrowRef (_, _, l)
  | Switch (_, _, l) ->
      any l
  | Call (a, l) | TailCall (a, l) -> instr_has_conditional a || any l
  | Struct (_, l) -> List.exists (fun (_, i) -> instr_has_conditional i) l
  | BinOp (_, a, b)
  | Array (_, a, b)
  | ArraySegment (_, _, a, b)
  | ArrayGet (a, b)
  | StructSet (a, _, b) ->
      instr_has_conditional a || instr_has_conditional b
  | ArraySet (a, b, c) | Select (a, b, c) ->
      instr_has_conditional a || instr_has_conditional b
      || instr_has_conditional c
  | Set (_, i)
  | Tee (_, i)
  | Cast (i, _)
  | Test (i, _)
  | NonNull i
  | UnOp (_, i)
  | StructGet (i, _)
  | ArrayDefault (_, i)
  | Br_if (_, i)
  | Br_table (_, i)
  | Br_on_null (_, i)
  | Br_on_non_null (_, i)
  | Br_on_cast (_, _, i)
  | Br_on_cast_fail (_, _, i)
  | ThrowRef i
  | ContNew (_, i) ->
      instr_has_conditional i
  | Let (_, i) | Br (_, i) | Throw (_, i) | Return i -> opt i
  | Unreachable | Nop | Hole | Null | Get _ | Char _ | String _ | Int _
  | Float _ | StructDefault _ ->
      false

let rec field_has_conditional (f : (_ modulefield, _) annotated) =
  match f.desc with
  | Conditional _ -> true
  | Group { fields; _ } -> List.exists field_has_conditional fields
  | Func { body = _, instrs; _ } -> List.exists instr_has_conditional instrs
  | Global { def; _ } -> instr_has_conditional def
  | _ -> false

(* Resolve every conditional against the assumption [asm], inlining the selected
   branch to produce a conditional-free module (groups are kept and recursed
   into). For an undetermined conditional, select [then], [enqueue] the [else]
   configuration, and [record] the chosen literal. *)
let specialize_fields env diagnostics ~enqueue ~record asm0 fields =
  let module S = Wax_wasm.Cond_solver in
  (* Resolve one conditional and return both the specialized branch and the
     assumption that holds afterwards. Each branch is taken only if it is
     reachable under [asm] (its conjunction with the branch condition is
     satisfiable); an unreachable branch is pruned, so we never explore an
     infeasible configuration. The surviving assumption is threaded into the
     following siblings, so e.g. once [cond1] forces [$wasi], a sibling
     [#[if(not wasi)]] has its [@then] pruned. *)
  let choose asm cond ~location ~then_branch ~else_branch =
    let c = S.of_cond env diagnostics ~location cond in
    let then_asm = S.and_ asm c and else_asm = S.and_ asm (S.not_ c) in
    if not (S.is_satisfiable then_asm) then (
      record (S.not_ c);
      (else_branch else_asm, else_asm))
    else if not (S.is_satisfiable else_asm) then (
      record c;
      (then_branch then_asm, then_asm))
    else (
      enqueue else_asm;
      record c;
      (then_branch then_asm, then_asm))
  in
  (* Instruction-level specializer: resolve each [If_annotation] by splicing the
     selected branch into the enclosing list; recurse into every sub-instruction
     and nested block body. [sone] is for single-instruction positions, where an
     [If_annotation] cannot appear (it is statement-only). *)
  let rec sinstrs asm l =
    match l with
    | [] -> []
    | i :: rest ->
        let instrs, asm = sinstr asm i in
        instrs @ sinstrs asm rest
  and sinstr asm (i : (_ instr_desc, _) annotated) =
    match i.desc with
    | If_annotation { cond; then_body; else_body } ->
        choose asm cond ~location:i.info
          ~then_branch:(fun asm' -> sinstrs asm' then_body)
          ~else_branch:(fun asm' ->
            match else_body with Some e -> sinstrs asm' e | None -> [])
    | desc -> ([ { i with desc = sdesc asm desc } ], asm)
  and sone asm i = match sinstr asm i with [ x ], _ -> x | _ -> assert false
  and sdesc asm (desc : _ instr_desc) : _ instr_desc =
    match desc with
    | Block { label; typ; block } ->
        Block { label; typ; block = sinstrs asm block }
    | Loop { label; typ; block } ->
        Loop { label; typ; block = sinstrs asm block }
    | While { label; cond; block } ->
        While { label; cond = sone asm cond; block = sinstrs asm block }
    | If { label; typ; cond; if_block; else_block } ->
        If
          {
            label;
            typ;
            cond = sone asm cond;
            if_block = { if_block with desc = sinstrs asm if_block.desc };
            else_block =
              Option.map
                (fun b -> { b with desc = sinstrs asm b.desc })
                else_block;
          }
    | TryTable { label; typ; catches; block } ->
        TryTable { label; typ; catches; block = sinstrs asm block }
    | Try { label; typ; block; catches; catch_all } ->
        Try
          {
            label;
            typ;
            block = sinstrs asm block;
            catches = List.map (fun (t, l) -> (t, sinstrs asm l)) catches;
            catch_all = Option.map (sinstrs asm) catch_all;
          }
    | Set (idx, v) -> Set (idx, sone asm v)
    | Tee (idx, v) -> Tee (idx, sone asm v)
    | Call (t, args) -> Call (sone asm t, List.map (sone asm) args)
    | TailCall (t, args) -> TailCall (sone asm t, List.map (sone asm) args)
    | Cast (v, t) -> Cast (sone asm v, t)
    | Test (v, t) -> Test (sone asm v, t)
    | NonNull v -> NonNull (sone asm v)
    | Struct (idx, fields) ->
        Struct (idx, List.map (fun (i, v) -> (i, sone asm v)) fields)
    | StructGet (v, idx) -> StructGet (sone asm v, idx)
    | StructSet (v, idx, w) -> StructSet (sone asm v, idx, sone asm w)
    | Array (idx, a, b) -> Array (idx, sone asm a, sone asm b)
    | ArrayDefault (idx, v) -> ArrayDefault (idx, sone asm v)
    | ArrayFixed (idx, l) -> ArrayFixed (idx, List.map (sone asm) l)
    | ArraySegment (idx, d, a, b) ->
        ArraySegment (idx, d, sone asm a, sone asm b)
    | ArrayGet (a, b) -> ArrayGet (sone asm a, sone asm b)
    | ArraySet (a, b, c) -> ArraySet (sone asm a, sone asm b, sone asm c)
    | BinOp (op, a, b) -> BinOp (op, sone asm a, sone asm b)
    | UnOp (op, v) -> UnOp (op, sone asm v)
    | Let (bs, body) -> Let (bs, Option.map (sone asm) body)
    | Br (l, v) -> Br (l, Option.map (sone asm) v)
    | Br_if (l, v) -> Br_if (l, sone asm v)
    | Br_table (ls, v) -> Br_table (ls, sone asm v)
    | Dispatch { index; cases; default; arms } ->
        Dispatch
          {
            index = sone asm index;
            cases;
            default;
            arms = List.map (fun (l, body) -> (l, sinstrs asm body)) arms;
          }
    | Match { scrutinee; arms; default } ->
        Match
          {
            scrutinee = sone asm scrutinee;
            arms = List.map (fun (pat, body) -> (pat, sinstrs asm body)) arms;
            default = sinstrs asm default;
          }
    | Br_on_null (l, v) -> Br_on_null (l, sone asm v)
    | Br_on_non_null (l, v) -> Br_on_non_null (l, sone asm v)
    | Br_on_cast (l, t, v) -> Br_on_cast (l, t, sone asm v)
    | Br_on_cast_fail (l, t, v) -> Br_on_cast_fail (l, t, sone asm v)
    | Throw (idx, v) -> Throw (idx, Option.map (sone asm) v)
    | ThrowRef v -> ThrowRef (sone asm v)
    | ContNew (ct, v) -> ContNew (ct, sone asm v)
    | ContBind (src, dst, l) -> ContBind (src, dst, List.map (sone asm) l)
    | Suspend (tag, l) -> Suspend (tag, List.map (sone asm) l)
    | Resume (ct, h, l) -> Resume (ct, h, List.map (sone asm) l)
    | ResumeThrow (ct, tag, h, l) ->
        ResumeThrow (ct, tag, h, List.map (sone asm) l)
    | ResumeThrowRef (ct, h, l) -> ResumeThrowRef (ct, h, List.map (sone asm) l)
    | Switch (ct, tag, l) -> Switch (ct, tag, List.map (sone asm) l)
    | Return v -> Return (Option.map (sone asm) v)
    | Sequence l -> Sequence (sinstrs asm l)
    | Select (c, t, e) -> Select (sone asm c, sone asm t, sone asm e)
    | If_annotation _ -> assert false (* handled in [sinstr] *)
    | ( Unreachable | Nop | Hole | Null | Get _ | Char _ | String _ | Int _
      | Float _ | StructDefault _ ) as x ->
        x
  in
  let rec sfields asm fl =
    match fl with
    | [] -> []
    | f :: rest ->
        let fields, asm = sfield asm f in
        fields @ sfields asm rest
  and sfield asm (f : (_ modulefield, _) annotated) =
    match f.desc with
    | Conditional { cond; then_fields; else_fields } ->
        choose asm cond ~location:f.info
          ~then_branch:(fun asm' -> sfields asm' then_fields)
          ~else_branch:(fun asm' ->
            match else_fields with Some e -> sfields asm' e | None -> [])
    | Group { attributes; fields } ->
        ( [ { f with desc = Group { attributes; fields = sfields asm fields } } ],
          asm )
    | Func ({ body = lbl, instrs; _ } as r) ->
        ( [ { f with desc = Func { r with body = (lbl, sinstrs asm instrs) } } ],
          asm )
    | Global ({ def; _ } as g) ->
        ([ { f with desc = Global { g with def = sone asm def } } ], asm)
    | _ -> ([ f ], asm)
  in
  sfields asm0 fields

(* Immediate sub-instructions of an instruction (lists flattened), for generic
   traversals. *)
let sub_instrs (i : (_ instr_desc, _) annotated) =
  match i.desc with
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } -> block
  | While { cond; block; _ } -> cond :: block
  | If { cond; if_block; else_block; _ } ->
      (cond :: if_block.desc)
      @ Option.fold ~none:[] ~some:(fun b -> b.desc) else_block
  | Try { block; catches; catch_all; _ } ->
      block @ List.concat_map snd catches @ Option.value ~default:[] catch_all
  | If_annotation { then_body; else_body; _ } ->
      then_body @ Option.value ~default:[] else_body
  | Sequence l | ArrayFixed (_, l) -> l
  | Dispatch { index; arms; _ } -> index :: List.concat_map snd arms
  | Match { scrutinee; arms; default } ->
      (scrutinee :: List.concat_map snd arms) @ default
  | ContBind (_, _, l)
  | Suspend (_, l)
  | Resume (_, _, l)
  | ResumeThrow (_, _, _, l)
  | ResumeThrowRef (_, _, l)
  | Switch (_, _, l) ->
      l
  | Call (a, l) | TailCall (a, l) -> a :: l
  | Struct (_, l) -> List.map snd l
  | BinOp (_, a, b)
  | Array (_, a, b)
  | ArraySegment (_, _, a, b)
  | ArrayGet (a, b)
  | StructSet (a, _, b) ->
      [ a; b ]
  | ArraySet (a, b, c) | Select (a, b, c) -> [ a; b; c ]
  | Set (_, i)
  | Tee (_, i)
  | Cast (i, _)
  | Test (i, _)
  | NonNull i
  | UnOp (_, i)
  | StructGet (i, _)
  | ArrayDefault (_, i)
  | Br_if (_, i)
  | Br_table (_, i)
  | Br_on_null (_, i)
  | Br_on_non_null (_, i)
  | Br_on_cast (_, _, i)
  | Br_on_cast_fail (_, _, i)
  | ThrowRef i
  | ContNew (_, i) ->
      [ i ]
  | Let (_, o) | Br (_, o) | Throw (_, o) | Return o -> Option.to_list o
  | Unreachable | Nop | Hole | Null | Get _ | Char _ | String _ | Int _
  | Float _ | StructDefault _ ->
      []

(* [let] bindings are not allowed inside a conditional branch: branches are
   transparent and mutually exclusive, so a binding declared in one would leak
   past the conditional and clash with the other branch. *)
let rec check_let_in_conditionals diagnostics (i : (_ instr_desc, _) annotated)
    =
  (match i.desc with
  | If_annotation { then_body; else_body; _ } ->
      let check_branch =
        List.iter (fun (s : (_ instr_desc, _) annotated) ->
            match s.desc with
            | Let _ -> Error.let_in_conditional diagnostics ~location:s.info
            | _ -> ())
      in
      check_branch then_body;
      Option.iter check_branch else_body
  | _ -> ());
  List.iter (check_let_in_conditionals diagnostics) (sub_instrs i)

let f ?(simplify = false) ?(warn_unused = false) diagnostics fields =
  Wax_utils.Debug.timed "type-check" @@ fun () ->
  Ast_utils.iter_fields
    (fun (field : (_ modulefield, _) annotated) ->
      match field.desc with
      | Func { body = _, instrs; _ } ->
          List.iter (check_let_in_conditionals diagnostics) instrs
      | Global { def; _ } -> check_let_in_conditionals diagnostics def
      | _ -> ())
    fields;
  if not (List.exists field_has_conditional fields) then
    type_configuration ~warn_unused ~simplify diagnostics fields
  else begin
    (* Check every reachable configuration: each is specialized to be
       conditional-free and typed independently, so a diagnostic is reported
       once with the assumption under which it is reachable. *)
    Wax_wasm.Cond_explore.check_all diagnostics
      ?truncation_location:
        (match fields with hd :: _ -> Some hd.info | [] -> None)
      ~explain:(fun env c -> Wax_wasm.Cond_solver.explain env ~style:`Wax c)
      ~specialize:(fun env asm ~enqueue ~record ->
        specialize_fields env diagnostics ~enqueue ~record asm fields)
      ~check:(fun ctx m ->
        ignore (type_configuration ~warn_unused ~simplify ctx m))
      ();
    (* Build the typed module (consumed only by the deferred WAT conversion;
       wax -> wax ignores it) by typing the module with conditionals preserved.
       [type_configuration] resolves names per branch (condition-aware tables),
       so each branch is typed under its own assumption. Diagnostics are
       discarded — the exploration above did the real checking. *)
    type_configuration ~simplify (Wax_utils.Diagnostic.collector ()) fields
  end

let erase_types m =
  List.map (fun m -> { m with desc = Ast_utils.map_modulefield snd m.desc }) m
