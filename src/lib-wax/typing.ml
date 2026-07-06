open Ast
module Cond = Wax_wasm.Cond_solver

type typed_module_annotation = Ast.storagetype option array * Ast.location

open Infer

(*** Diagnostics ***)

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

  (* A module field (a function or global) declared but never referenced,
     exported, or used as the start function. Prefix its name with [_] to
     silence the warning. *)
  let unused_field context ~location kind name =
    warn ~warning:Wax_utils.Warning.Unused_field ~universal:true context
      ~location "The %s %a is never used." kind print_name name

  (* A block label declared but never branched to. Prefix its name with [_] to
     silence the warning. *)
  let unused_label context ~location name =
    warn ~warning:Wax_utils.Warning.Unused_label ~universal:true context
      ~location "The label %a is never used." print_name name

  (* A shift whose constant count is at least the operand's bit width. Wasm
     shifts mask the count modulo the width, so the result is very likely not
     what was intended. *)
  let shift_overflow context ~location ~width count =
    warn ~warning:Wax_utils.Warning.Shift_overflow ~universal:true context
      ~location
      ~hint:(fun f () ->
        Format.fprintf f
          "Wasm masks the count modulo %d, shifting by %Ld instead." width
          (Int64.rem count (Int64.of_int width)))
      "The shift count %Ld is at least the operand width (%d bits)." count width

  (* An integer division or remainder by a constant zero: it always traps. *)
  let division_by_zero context ~location =
    warn ~warning:Wax_utils.Warning.Constant_trap ~universal:true context
      ~location "This integer division or remainder by zero always traps."

  (* A comparison whose result does not depend on its variable operand. *)
  let tautological_comparison context ~location ~value =
    warn ~warning:Wax_utils.Warning.Tautological_comparison ~universal:true
      context ~location "This comparison is always %b." value

  (* A branch, loop, or [select] condition that is a constant. *)
  let constant_condition context ~location ~value =
    warn ~warning:Wax_utils.Warning.Constant_condition ~universal:true context
      ~location "This condition is always %b." value

  (* A side-effect-free expression whose result is computed and then dropped. *)
  let unused_result context ~location =
    warn ~warning:Wax_utils.Warning.Unused_result ~universal:true context
      ~location
      "The result of this expression is discarded, and computing it has no \
       effect."

  (* A trapping float-to-integer conversion of a constant that lies outside the
     target type's range (or is NaN/infinite): it always traps. *)
  let conversion_out_of_range context ~location =
    warn ~warning:Wax_utils.Warning.Constant_trap ~universal:true context
      ~location
      "This conversion always traps: the constant is out of the target type's \
       range."

  (* A statement that can never be reached: it follows an unconditional branch,
     [return], or [unreachable]. [related] points at the diverging instruction. *)
  let dead_code context ~location ~related =
    warn ~warning:Wax_utils.Warning.Dead_code ~universal:true context ~location
      ~related "This code is unreachable."

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

  let multiple_module context ~location =
    report context ~location "A module can have at most one name annotation."

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

  let descriptor_outside_rec_group context ~location ~described =
    report context ~location "The %s type must be in the same recursion group."
      (if described then "described" else "descriptor")

  let descriptor_not_reciprocal context ~location ~described =
    if described then
      report context ~location
        "This descriptor does not describe the type it is attached to."
    else
      report context ~location
        "The descriptor of this type does not describe it back."

  let forward_use_of_described context ~location =
    report context ~location
      "A described type must be declared before its descriptor."

  let descriptor_not_struct context ~location ~described =
    report context ~location "A %s type must be a struct type."
      (if described then "described" else "descriptor")

  let type_without_descriptor context ~location =
    report context ~location
      "This descriptor instruction requires a type that has a descriptor."

  let descriptor_allocation_required context ~location =
    report context ~location
      "A type with a descriptor must be allocated with a descriptor: {T \
       descriptor d | …}."

  let feature_disabled context ~location feature =
    report context ~location
      "This uses the %s feature, which is not enabled; pass --feature %s."
      (Wax_utils.Feature.name feature)
      (Wax_utils.Feature.name feature)

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

  (* The exit values of a block-like construct (an [if]'s two branches, or a
     [do]/[loop]/[try]'s fall-through and/or values branched to its label) do not
     join to a common supertype. A caret marks each offending value. *)
  let block_exit_type_mismatch context ~location ~loc1 ~loc2 ty1 ty2 =
    report context ~location
      ~related:[ typed_branch_label loc1 ty1; typed_branch_label loc2 ty2 ]
      "The values reaching this block's exit have no common supertype, so its \
       result type cannot be inferred."

  (* A value delivered by [br_if] stays on the stack (the fall-through) typed as
     the block's result, so its type must equal the inferred result exactly, not
     merely be a subtype. Here it is a strict subtype and there is no annotation
     to pin the result, so the block cannot be given a result type consistent with
     both. *)
  let br_if_result_mismatch context ~location ~loc ~result ty =
    report context ~location
      ~related:[ typed_branch_label loc ty; typed_branch_label location result ]
      "This [br_if] value stays on the stack as the block's result, so its \
       type must match the inferred result exactly; add a result annotation to \
       the block."

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

  let unknown_intrinsic context ~location ns name =
    report context ~location "There is no %s::%s intrinsic." ns name

  let intrinsic_not_called context ~location ns name =
    report context ~location
      "The qualified name %s::%s can only be used as a function call." ns name

  let before_hole context ~location =
    report context ~location "This expression occurs before a hole '_'."

  let duplicated_field context ~location x =
    report context ~location "Several fields have the same name %a." print_name
      x

  let splice_without_supertype context ~location =
    report context ~location
      "'..' requires a supertype to inherit fields from (write 'type t: super \
       = { .., ... }')."

  let splice_non_struct context ~location x =
    report context ~location
      "'..' can only inherit fields from a struct supertype; %a is not a \
       struct."
      print_name x

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

  let atomic_alignment context ~location natural =
    report context ~location
      "The alignment of an atomic access must be its natural alignment %d."
      natural

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

  let invalid_page_size context ~location =
    report context ~location "The custom page size must be 1 or 65536."

  let shared_memory_without_max context ~location =
    report context ~location "A shared memory must have a maximum size."

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
      "A string literal can only build an [i8] or [i16] array."

  let string_not_unicode context ~location =
    report context ~location
      "A string building an [i16] array must be a valid Unicode string."

  let expected_ref context ~location =
    report context ~location "A reference type is expected here."

  let dispatch_duplicate_arm context ~location x =
    report context ~location "This dispatch has several cases named %a."
      print_name x
end

(*** Symbol tables and namespaces ***)

module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

(* The option let-operators (the [@] suffix denotes "optional"): [let*@] binds
   through [Some]/short-circuits on [None] (Option.bind), [let+@] maps the
   payload (Option.map), and [let>@] runs an effect only when [Some]
   (Option.iter). Distinct from the stack-threading [let*]/[let*!] defined with
   the typing monad further down. *)
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
    (* Names referenced (looked up) through this table, so a declaration that is
       never referenced can be reported as unused. Populated by [resolve];
       queried by [is_used]. *)
    used : (string, unit) Hashtbl.t;
  }

  let make namespace kind =
    { kind; namespace; tbl = Hashtbl.create 16; used = Hashtbl.create 16 }

  (* Whether a name declared in this table has been referenced. *)
  let is_used env name = Hashtbl.mem env.used name
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
     falling back to one merely compatible with it, then to the most recent.
     A successful lookup marks the name referenced (for the unused-field lint);
     [resolve] is only ever called to look up a reference, never for a
     declaration (which goes through [add]). *)
  let resolve env x =
    let r =
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
    in
    (match r with Some _ -> Hashtbl.replace env.used x.desc () | None -> ());
    r

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

(*** Types and the type context ***)

type types = (int * subtype) Tbl.t

type type_context = {
  internal_types : Wax_wasm.Types.t;
  types : (int * subtype) Tbl.t;
  features : Wax_utils.Feature.set;
      (* The enabled optional features / proposals, and which are used. *)
}

let get_type_definition d types nm = Option.map snd (Tbl.find d types nm)

let resolve_type_name d ctx name =
  let+@ res = Tbl.find d ctx.types name in
  fst res

(* Record that [feature] is used and, if it is disabled, report it at
   [location]. Typing continues either way (error recovery). *)
let require_feature d (ctx : type_context) ~location feature =
  Wax_utils.Feature.mark_used ctx.features feature;
  if not (Wax_utils.Feature.is_enabled ctx.features feature) then
    Error.feature_disabled d ~location feature

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
  | Exact idx ->
      require_feature d ctx ~location:idx.info
        Wax_utils.Feature.Custom_descriptors;
      let+@ ty = resolve_type_name d ctx idx in
      (Exact ty : Internal.heaptype)

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

let subtype d ctx current { typ; supertype; final; descriptor; describes } =
  let*@ typ = comptype d ctx typ in
  let*@ supertype =
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
  (* [descriptor]/[describes] may refer mutually within the rec group, so no
     declared-before restriction applies. *)
  let resolve_opt = function
    | None -> Some None
    | Some idx ->
        require_feature d ctx ~location:idx.info
          Wax_utils.Feature.Custom_descriptors;
        let+@ ty = resolve_type_name d ctx idx in
        Some ty
  in
  let*@ descriptor = resolve_opt descriptor in
  let+@ describes = resolve_opt describes in
  { Internal.typ; supertype; final; descriptor; describes }

let rectype d ctx ty =
  array_mapi_opt (fun i elt -> subtype d ctx i (snd elt.desc)) ty

(* Replace a leading [..] splice sentinel in each struct of the rec group with
   the supertype's fields. Called after the group's names are temporarily
   registered (so an in-group supertype resolves), and expands members in source
   order so an earlier member is already expanded when a later one inherits from
   it. Returns a fresh array; the parsed module AST keeps its sentinel (for
   [format] / decompilation round-trip), while the internal type and [ctx.types]
   get the expanded fields. *)
let expand_splices d ctx ty =
  let expanded = Array.copy ty in
  Array.iteri
    (fun i elt ->
      let name, (sub : subtype) = elt.desc in
      match sub.typ with
      | Struct fields
        when Array.length fields > 0 && Ast.is_splice_field fields.(0) ->
          let delta = Array.sub fields 1 (Array.length fields - 1) in
          let parent_fields =
            match sub.supertype with
            | None ->
                Error.splice_without_supertype d ~location:fields.(0).info;
                None
            | Some sup -> (
                match Tbl.find_opt ctx.types sup with
                | Some (idx, parent) -> (
                    (* An in-group member has a negative placeholder index; use
                       its already-expanded form. A self/forward reference
                       ([j >= i]) is reported as unbound by [subtype], so skip. *)
                    let parent =
                      if idx < 0 then
                        let j = lnot idx in
                        if j < i then Some (snd expanded.(j).desc) else None
                      else Some parent
                    in
                    match parent with
                    | Some { typ = Struct pf; _ } -> Some pf
                    | Some _ ->
                        Error.splice_non_struct d ~location:sup.info sup;
                        None
                    | None -> None)
                | None -> None (* unbound supertype: reported by [subtype] *))
          in
          let fields' =
            match parent_fields with
            | Some pf -> Array.append pf delta
            | None -> delta
          in
          expanded.(i) <-
            { elt with desc = (name, { sub with typ = Struct fields' }) }
      | _ -> ())
    ty;
  expanded

let add_type d ctx ty =
  Array.iteri
    (fun i elt ->
      let name, (typ : subtype) = elt.desc in
      Tbl.add d ctx.types name (lnot i, typ))
    ty;
  (* Expand [..] splices before building the internal type and before the final
     [ctx.types] override below, so both see the supertype's fields. *)
  let ty = expand_splices d ctx ty in
  match rectype d ctx ty with
  | None ->
      (* Remove temporary names on failure *)
      Array.iter (fun elt -> Tbl.remove ctx.types (fst elt.desc)) ty;
      None
  | Some ity ->
      (* Well-formedness of [descriptor]/[describes] clauses, which must link two
         struct types within the same recursion group. In [ity] an in-group type
         reference is a negative placeholder [lnot pos]; a non-negative index
         denotes an already-defined type, i.e. one outside this group. *)
      let in_group idx = if idx < 0 then Some (lnot idx) else None in
      Array.iteri
        (fun i (sub : Wax_wasm.Ast.Binary.subtype) ->
          let location = ty.(i).info in
          (match sub.descriptor with
          | None -> ()
          | Some di -> (
              match in_group di with
              | None ->
                  Error.descriptor_outside_rec_group d ~location
                    ~described:false
              | Some pos -> (
                  match ity.(pos).describes with
                  | Some o when in_group o = Some i -> ()
                  | _ ->
                      Error.descriptor_not_reciprocal d ~location
                        ~described:false)));
          (match sub.describes with
          | None -> ()
          | Some oi -> (
              match in_group oi with
              | None ->
                  Error.descriptor_outside_rec_group d ~location ~described:true
              | Some pos -> (
                  if pos >= i then Error.forward_use_of_described d ~location;
                  match ity.(pos).descriptor with
                  | Some dd when in_group dd = Some i -> ()
                  | _ ->
                      Error.descriptor_not_reciprocal d ~location
                        ~described:true)));
          if
            (sub.descriptor <> None || sub.describes <> None)
            && match sub.typ with Struct _ -> false | _ -> true
          then
            Error.descriptor_not_struct d ~location
              ~described:(sub.describes <> None))
        ity;
      let i' = Wax_wasm.Types.add_rectype ctx.internal_types ity in
      Array.iteri
        (fun i elt ->
          let name, (typ : subtype) = elt.desc in
          Tbl.override ctx.types name (i' + i, typ))
        ty;
      Some i'

(*** The module context ***)

type module_context = {
  (* --- Diagnostics and whole-run configuration --- *)
  diagnostics : Wax_utils.Diagnostic.context;
  warn_unused : bool;
      (* Whether to report locals declared by a [let] but never read. Enabled
         only when validation is requested. *)
  simplify : bool;
  (* Whether to rewrite the AST while typing: drop casts the inferred types
         make redundant and tighten [&?extern]/[&?any] casts to
         [&extern]/[&any]. Enabled only when converting from Wasm; for
         hand-written Wax (formatting, or compiling to Wasm) casts are kept as
         written. *)
  (* --- Module-wide type and name tables (built once, before any body) --- *)
  type_context : type_context;
  subtyping_info : Wax_wasm.Types.subtyping_info;
  types : (int * subtype) Tbl.t;
  (* Per function: interned type index, type name, and whether a reference to it
     is exact (a defined function or an exact import — custom-descriptors). *)
  functions : (int * string * bool) Tbl.t;
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
  structs_by_fields : (string, ident option) Hashtbl.t;
  (* Maps a struct's canonical field-set key (see [field_set_key]) to the
         unique struct type with that field set, or [None] when several share
         it. Lets a struct literal whose name is omitted resolve from its fields
         alone (and the name be dropped when the fields make it unambiguous).
         Built once at module-context creation. *)
  (* --- Per-function state (reset on entry to each function) --- *)
  mutable locals : inferred_valtype option StringMap.t;
      (* The local's type, or [None] when it could not be determined because its
         initializer failed to type — an error-recovery "poison" local, read as
         the [Error] type so its uses don't cascade into further errors. *)
  mutable initialized_locals : StringSet.t;
      (* Locals known to hold a value at the current point. A non-defaultable
         (non-nullable reference) local starts uninitialized and must be
         assigned before it is read. The set is captured by [{ ctx with ... }]
         on block entry, so an assignment inside a block does not escape it. *)
  read_locals : StringSet.t ref;
      (* Names of locals read so far in the current function. A [ref] (rather
         than a snapshot field) so reads inside a block propagate to the
         function level. Reset per function. *)
  local_decls : ident list ref;
      (* The [let]-bound locals declared in the current function, in declaration
         order, so an unread one can be reported as unused. Reset per function. *)
  used_labels : StringSet.t ref;
      (* Names of block labels branched to so far in the current function
         (marked by [branch_target]). A [ref] so a branch nested in a block
         propagates to the function level. Reset per function. *)
  label_decls : ident list;
      (* The block labels declared in the current function's body, collected up
         front from the source AST (see [collect_labels]), so one never branched
         to can be reported as unused. Reset per function. *)
  assigned_locals : StringSet.t;
      (* Names of locals assigned ([Set]/[Tee] targets) anywhere in the current
         function, collected once on entry (see [collect_assigned_locals]). Lets
         the annotation-drop on a fused [let x: T = e] tell a write-once local —
         which may narrow to [e]'s subtype just like an immutable global — from
         one a later assignment still needs the wider [T] for. Reset per
         function. *)
  control_types : (string option * inferred_type Cell.t array) list;
  return_types : inferred_type Cell.t array;
  (* --- Conditional-compilation branch assumption --- *)
  cond : Cond.t ref;
      (* Current branch assumption (shared with every namespace/table above);
         set while typing a conditional branch so names resolve per branch. *)
  cond_env : Cond.env;
}

(*** Name resolution and subtyping ***)

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

(* A struct-literal field's value. A punned field ([None], written [{x}]) stands
   for the like-named local/global, i.e. [Get x]; typing resolves it to that
   explicit [Get], which is what is type-checked and emitted, so lowering never
   sees a pun. *)
let field_value (name : ident) = function
  | Some i -> i
  | None -> { desc = Get name; info = name.info }

let lookup_array_type ?location ctx name =
  let*@ ty = Tbl.find_opt ctx.type_context.types name in
  match (snd ty).typ with
  | Array field -> Some field
  | Func _ | Struct _ | Cont _ ->
      Error.expected_array_type ctx.diagnostics
        ~location:(Option.value ~default:name.info location);
      None

(* The composite type of a synthesized type (its name starting with ['<'], e.g.
   [<string>] or an inline function type) — used as the [anon_comptype] of an
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
  | Type ty | Exact ty -> (
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
  | Type ty | Exact ty -> (
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

(* Whether [ty] is the result cell of a block whose type is being inferred. *)
let is_inferring ty = match Cell.get ty with Collecting _ -> true | _ -> false

(* The type a value passing through a branch to [ty] takes: it continues on the
   stack typed as the target's result. When the target is a block being inferred
   ([Collecting]) with a declared result (an annotation under test, or the context
   type in expression position), that result is the right type — resolve to it, so
   the pass-through is typed as the block's result rather than its own, possibly
   narrower, operand (which would be unsound, see [Collecting.exacts]). With no
   declared result (a fully-inferred block) the [Collecting] cell would leak as a
   value, so the caller keeps the operand's own type instead. *)
let rec resolve_declared ty =
  match Cell.get ty with
  | Collecting { declared = Some d; _ } -> resolve_declared d
  | _ -> ty

(* Whether the inferred type [ty] is a subtype of the expected type [ty'].
   Not a pure relation: when the two are compatible it *unifies* their
   union-find cells (so an as-yet-unconstrained literal like [Int]/[Number]
   gets pinned to the concrete type it is checked against). [Unknown] or [Error]
   on the left (dead code / error recovery) is a subtype of anything;
   [UnknownRef] is a subtype of every reference type but of no other (so a
   numeric use of it is rejected). None of the three appears on the right
   because expected types always come from a real declaration, annotation or
   instruction signature — hence the [assert]. *)
let rec subtype ?location ctx ty ty' =
  let ity = Cell.get ty in
  let ity' = Cell.get ty' in
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
      match st.declared with
      | Some d ->
          (* An annotation is under test: the [subtype] check below may resolve
             [ty], so record a snapshot of its natural type first — the keep-bool
             decision compares that pre-validation type against the annotation. *)
          st.collected <- (location, Cell.make ity) :: st.collected;
          subtype ?location ctx ty d
      | None ->
          (* No annotation under test, so nothing here resolves [ty]: record the
             live cell. When the join later settles the block's result to a
             concrete width, that propagates back to a flexible numeric literal
             reaching the exit (the only types [join_value_types] merges) — else
             the literal keeps its default width and [To_wasm] emits, e.g., an f64
             const as the fall-through of an f32-typed block (invalid). *)
          st.collected <- (location, ty) :: st.collected;
          true)
  | Collecting _, _ -> true
  | Valtype ty, Valtype ty' ->
      Wax_wasm.Types.val_subtype ctx.subtyping_info ty.internal ty'.internal
  (* A flexible numeric literal ([Number]/[Int]/[LargeInt]/[Float]) never appears
     as the expected (right-hand) type: an expected type comes from a declaration,
     annotation or instruction signature — always a concrete valtype, or a
     [Collecting] block result (handled above). This is the numeric counterpart of
     the [Unknown]/[Error]/[UnknownRef] right-hand assertion below. *)
  | _, (Number | Int | LargeInt | Float) -> assert false
  | Null, Null ->
      Cell.merge ty ty' ity;
      true
  | Number, Valtype { internal = I32 | I64 | F32 | F64; _ }
  | Int, Valtype { internal = I32 | I64; _ }
  | Float, Valtype { internal = F32 | F64; _ }
  (* LargeInt — a numeric literal too big for i32: never i32, defaults to i64; the
     concrete types it accepts are i64, f32 and f64. *)
  | LargeInt, Valtype { internal = I64 | F32 | F64; _ }
  | Null, Valtype { internal = Ref { nullable = true; _ }; _ } ->
      Cell.merge ty ty' ity';
      true
  | ( Null,
      Valtype
        {
          internal = I32 | I64 | F32 | F64 | V128 | Ref { nullable = false; _ };
          _;
        } )
  | Valtype _, Null
  | Number, (Null | Valtype { internal = V128 | Ref _; _ })
  | Int, (Null | Valtype { internal = F32 | F64 | V128 | Ref _; _ })
  | Float, (Null | Valtype { internal = I32 | I64 | V128 | Ref _; _ })
  | LargeInt, (Null | Valtype _) ->
      false
  | (Int8 | Int16), _ | _, (Int8 | Int16) -> false
  | (Unknown | Error), _ -> true
  | UnknownRef, (Valtype { internal = Ref _; _ } as t) ->
      (* The bottom reference is a subtype of every reference; pin it to the
         hierarchy it is checked against, so it resolves to a concrete type in
         that hierarchy rather than the default any-hierarchy [&none]. *)
      Cell.set ty t;
      true
  | _, (Unknown | Error | UnknownRef) -> assert false
  | UnknownRef, _ -> false

let cast ctx ty ty' =
  let ity = Cell.get ty in
  match (ity, ty') with
  | (Number | Int), Ref { typ = I31 | Extern; _ } ->
      Cell.set ty (Valtype i32_valtype);
      true
  | (Number | Int), I32 ->
      Cell.set ty (Valtype i32_valtype);
      true
  | (Number | Int), I64 ->
      Cell.set ty (Valtype i64_valtype);
      true
  (* A still-flexible numeric literal ([Number]) folds straight to the target
     float constant. A value already committed to a family — [Int] (an integer
     operation such as [x & y] or [clz]) or [Float] (a float operation, or a
     float literal) — is *not* accepted here for the opposite family: a plain
     [int <-> float] cast needs a signedness ([as f32_s], [as i32_u]) to lower to
     a [convert]/[trunc], so it falls through to the cast error, exactly as a cast
     of a concrete [i32]/[f32] value does. (An integer-to-float [convert] would
     carry a sign, as [signed_cast].) *)
  | (Number | Float), F32 ->
      Cell.set ty (Valtype f32_valtype);
      true
  | (Number | Float), F64 ->
      Cell.set ty (Valtype f64_valtype);
      true
  (* The literal is always i64 here since it is too big for i32. A cast to
     [i32] wraps it (the low 32 bits), as produced when decompiling e.g.
     [i64.extend32_s] of a constant; a cast to [i64] is the identity. *)
  | LargeInt, (I32 | I64) ->
      Cell.set ty (Valtype i64_valtype);
      true
  (* A cast to a float folds the literal to a float constant, exactly like a
     small [Number] literal above (a runtime integer-to-float [convert] would
     carry a sign, as [signed_cast]). Settle the operand at the target float type
     so [to_wasm] emits [f32.const]/[f64.const] rather than an unlowerable [i64]
     value. *)
  | LargeInt, F32 ->
      Cell.set ty (Valtype f32_valtype);
      true
  | LargeInt, F64 ->
      Cell.set ty (Valtype f64_valtype);
      true
  (* [ref.i31] takes an [i32]; the i64-sized literal wraps to [i32] first, exactly
     like [i64 as &i31] below ([to_wasm] re-emits [i32.wrap_i64] then [ref.i31]).
     This is the residue of [(big as i32) as &i31] after [simplify] fuses the
     inner wrap into the [i31] cast. *)
  | LargeInt, Ref { typ = I31; _ } ->
      Cell.set ty (Valtype i64_valtype);
      true
  | LargeInt, _ -> false (* not v128 or another reference *)
  | Null, Ref { typ = ty'; _ } ->
      (let>@ typ = top_heap_type ctx ty' in
       let ty' = Ref { nullable = true; typ } in
       let>@ ity' = valtype ctx.diagnostics ctx.type_context ty' in
       Cell.set ty
         (Valtype { typ = ty'; internal = ity'; anon_comptype = None }));
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
  | Valtype { internal = Ref _ as ity; _ }, Ref { typ = ty'; _ } -> (
      let sub a b = Wax_wasm.Types.val_subtype ctx.subtyping_info a b in
      Option.value ~default:true
        (let*@ typ = top_heap_type ctx ty' in
         let+@ ity' =
           valtype ctx.diagnostics ctx.type_context
             (Ref { nullable = true; typ })
         in
         sub ity ity')
      ||
      (* [extern] <-> [any] across hierarchies ([any.convert_extern] /
         [extern.convert_any]), then a [ref.cast] to the concrete target. The
         [ref.cast] handles nullability, so only hierarchy membership is checked
         here — test the operand against a *nullable* reference regardless of the
         target's nullability (a nullable operand cast to a non-null target is a
         valid convert-then-null-checking-cast). *)
      match ty' with
      | Extern -> sub ity (Ref { nullable = true; typ = Any })
      | Any -> sub ity (Ref { nullable = true; typ = Extern })
      | _ ->
          Option.value ~default:false
            (let+@ top = top_heap_type ctx ty' in
             (sub ity (Ref { nullable = true; typ = Extern }) && top = Any)
             || (sub ity (Ref { nullable = true; typ = Any }) && top = Extern)))
  | ( (Number | Int | Float | Valtype { internal = I32 | F32 | I64 | F64; _ }),
      ( Ref
          {
            typ =
              ( Func | NoFunc | Exn | NoExn | Cont | NoCont | Extern | NoExtern
              | Any | Eq | Array | Struct | Type _ | Exact _ | None_ );
            _;
          }
      | V128 ) )
  | Valtype { internal = F32 | F64; _ }, (I32 | I64)
  | Valtype { internal = I32 | I64; _ }, (F32 | F64)
  | Valtype { internal = I32; _ }, I64
  (* A value committed to one numeric family cast to the other with a plain
     (unsigned) cast: it needs a signedness to lower to a [convert]/[trunc], so
     it is rejected here (a still-flexible [Number] literal folds above). *)
  | Int, (F32 | F64)
  | Float, I64
  | ( (Float | Valtype { internal = F32 | F64 | V128; _ }),
      (I32 | Ref { typ = I31; _ }) )
  | (Null | Valtype { internal = Ref _; _ }), (I32 | I64 | F32 | F64 | V128)
  | Valtype { internal = V128; _ }, (I64 | F32 | F64 | Ref _)
  | (Int8 | Int16), _ ->
      false
  | (Unknown | Error | UnknownRef | Collecting _), _ -> true

let signed_cast ctx ty ty' =
  let ity = Cell.get ty in
  match (ity, ty') with
  | (Int8 | Int16), (`I32 | `I64) -> true
  | Valtype { internal = Ref _ as ity; _ }, (`I32 | `I64) ->
      (* [i31.get] extracts an [i32]; [&ref as i64_X] widens it further. *)
      Wax_wasm.Types.val_subtype ctx.subtyping_info ity
        (Ref { nullable = true; typ = Any })
  | Null, `I32 ->
      Cell.set ty
        (Valtype
           {
             typ = Ref { typ = Any; nullable = true };
             internal = Ref { typ = Any; nullable = true };
             anon_comptype = None;
           });
      true
  | (Number | Int), (`I64 | `F32 | `F64) ->
      (* [i64.extend_i32], [f*.convert_i32]: default the integer source to i32. *)
      Cell.set ty (Valtype i32_valtype);
      true
  | LargeInt, (`F32 | `F64) ->
      (* [f*.convert_i64]: a [LargeInt] source defaults to i64. *)
      Cell.set ty (Valtype i64_valtype);
      true
  | LargeInt, (`I32 | `I64) ->
      (* The only numeric -> i32/i64 signed cast is a float truncation
         ([iNN.trunc_f*_X]) — there is no i64->i32 or i64->i64 signed *integer*
         conversion — so the flexible source is a float and defaults to f64, as
         the [Number, `I32] case below. Without this a [LargeInt] there was
         rejected, so a decompiled [iNN.trunc_f* (f*.const <big>)] — which
         renders the const as a large integer literal — failed to recompile. *)
      Cell.set ty (Valtype f64_valtype);
      true
  | Valtype { internal = I32; _ }, `I64
  | Valtype { internal = I32 | I64; _ }, (`F32 | `F64)
  | Valtype { internal = F32 | F64; _ }, (`I32 | `I64) ->
      true
  | Number, `I32 ->
      (* The only numeric -> i32 signed cast is a float truncation
         ([i32.trunc_f*_s]), so a flexible [Number] source is a float and defaults
         to f64 (like the [Float] case below). ([Int] is rejected below: no
         integer -> i32 signed conversion exists.) *)
      Cell.set ty (Valtype f64_valtype);
      true
  | Int, `I32 (* no integer-to-i32 signed conversion exists *)
  | Valtype { internal = I32; _ }, `I32
  | Valtype { internal = I64; _ }, (`I32 | `I64)
  (* A signed cast to a float is an integer->float [convert]; float->float has no
     signedness, so a float source (concrete or the abstract [Float]) is rejected
     for a float target — only [demote]/[promote] via a plain cast. *)
  | (Float | Valtype { internal = F32 | F64; _ }), (`F32 | `F64)
  | (Int8 | Int16), (`F32 | `F64)
  | ( ( Null
      | Valtype
          {
            internal =
              Ref
                {
                  typ =
                    Type _ | Exact _ | None_ | Struct | Array | I31 | Eq | Any;
                  _;
                };
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
  | Float, (`I32 | `I64) ->
      Cell.set ty (Valtype f64_valtype);
      true
  (* A polymorphic reference (the bottom [UnknownRef], e.g. [null!] in dead code)
     is a reference: a signed cast to [i32]/[i64] is [i31.get] (as for a concrete
     any-hierarchy reference above), but it can never convert to a float. *)
  | UnknownRef, (`I32 | `I64) -> true
  | UnknownRef, (`F32 | `F64) -> false
  | (Unknown | Error | Collecting _), _ -> true

(*** The typing stack ***)

type stack =
  | Unreachable
  | Empty
  | Cons of location * inferred_type Cell.t * stack

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

(* The typing monad. A monadic action is a function [stack -> stack * 'a]: it
   reads the operand stack, may push/pop, and returns the new stack alongside
   its result. This threads the stack implicitly so the instruction cases read
   top-to-bottom instead of passing [st] by hand. The operators:

   - [return v]      lift a value, leaving the stack unchanged;
   - [let* x = e]    bind: run [e], thread its stack into the continuation;
   - [let*! x = e]   run [e : _ option], short-circuiting a [None] (a failed
                     lookup) by returning an [unreachable] recovery instruction
                     so typing continues without cascading errors;
   - [unreachable e] run [e] but mark the resulting stack [Unreachable] (the
                     polymorphic stack of code after a [br]/[return]/etc.).

   Not to be confused with the pure-option [let*@]/[let+@]/[let>@] above. *)
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
          info = ([| Cell.make Error |], (Ast.no_loc ()).info);
        }

(* Pop the top operand's type. An [Unreachable] (polymorphic) stack yields a
   fresh [Unknown] and consumes nothing; [Empty] is a genuine stack underflow. *)
let pop_any ctx i st =
  match st with
  | Unreachable -> (st, Cell.make Unknown)
  | Cons (_, ty, r) -> (r, ty)
  | Empty ->
      Error.empty_stack ctx.diagnostics ~location:i.info;
      (st, Cell.make Error)

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

(*** Instruction-checking helpers ***)

let internalize_valtype ctx typ =
  let+@ internal = valtype ctx.diagnostics ctx.type_context typ in
  { typ; internal; anon_comptype = None }

let internalize ?inline ctx typ =
  let+@ internal = valtype ctx.diagnostics ctx.type_context typ in
  valtype_cell { typ; internal; anon_comptype = inline }

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
          (valtype_cell s) (valtype_cell d)
  | _ -> ()

(* The inferred type of a value read from a field: a packed [i8]/[i16] field
   reads back as the unpacked [Int8]/[Int16] cell, any other as its value type.
   (Distinct from the [fieldtype] type converter above, which maps a source
   field type to its [Internal] form.) *)
let field_read_type ctx (f : fieldtype) =
  match f.typ with
  | Value typ -> internalize ctx typ
  | Packed I8 -> Some (Cell.make Int8)
  | Packed I16 -> Some (Cell.make Int16)

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
    | (Some label', res) :: _ when label.desc = label' ->
        ctx.used_labels := StringSet.add label.desc !(ctx.used_labels);
        res
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
  | Func_ref of int * string * bool
  | Unbound

let resolve_variable ctx idx =
  match StringMap.find_opt idx.desc ctx.locals with
  | Some ty -> Local ty
  | None -> (
      match Tbl.find_opt ctx.globals idx with
      | Some (mut, ty) -> Global (mut, ty)
      | None -> (
          match Tbl.find_opt ctx.functions idx with
          | Some (ty, ty', exact) -> Func_ref (ty, ty', exact)
          | None -> Unbound))

(* Whether [name] denotes a memory (resp. table) usable as a method/index
   receiver — [mem.load(..)], [tab[..]], [tab.size()]. A local of the same name
   shadows it: Wax resolves a bare name to a local first, and globals, functions,
   memories and tables share one namespace (so only a local can collide), so the
   receiver form must defer to the local just as [Get name] does. *)
let memory_receiver ctx name =
  (not (StringMap.mem name.desc ctx.locals))
  && Tbl.find_opt ctx.memories name <> None

let table_receiver ctx name =
  (not (StringMap.mem name.desc ctx.locals))
  && Tbl.find_opt ctx.tables name <> None

(* Likewise for a data/element segment named by [seg.drop()] (and the segment
   operand of [mem.init]/[tab.init]/array segment ops): usable as such only when
   not shadowed by a local. *)
let segment_receiver ctx name =
  (not (StringMap.mem name.desc ctx.locals))
  && (Tbl.find_opt ctx.datas name <> None || Tbl.find_opt ctx.elems name <> None)

(* Check the operands of an integer (resp. float) binary operator and return
   the unified result-type cell — the two operand cells are merged on success,
   so the caller takes [typ1] as the operator's result type. *)
let check_int_bin_op ctx ~location typ1 typ2 =
  (match (Cell.get typ1, Cell.get typ2) with
  | Valtype { internal = I32; _ }, Valtype { internal = I32; _ }
  | Valtype { internal = I64; _ }, Valtype { internal = I64; _ }
  | (Valtype { internal = I32 | I64; _ } | Int), (Number | Int) ->
      Cell.merge typ1 typ2 (Cell.get typ1)
  | (Number | Int), Valtype { internal = I32 | I64; _ } ->
      Cell.merge typ1 typ2 (Cell.get typ2)
  | Number, Number -> Cell.merge typ1 typ2 Int
  (* A LargeInt operand forces i64: it pairs with i64 or another flexible integer
     (never i32). *)
  | Valtype { internal = I64; _ }, LargeInt ->
      Cell.merge typ1 typ2 (Cell.get typ1)
  | LargeInt, Valtype { internal = I64; _ } ->
      Cell.merge typ1 typ2 (Cell.get typ2)
  (* An integer-only operator pins every [LargeInt] operand to i64: it exceeds
     i32, and the result is a committed integer (never a float), so the pair takes
     i64 rather than the still-float-capable [LargeInt]. *)
  | LargeInt, (LargeInt | Number | Int) | (Number | Int), LargeInt ->
      Cell.merge typ1 typ2 (Valtype i64_valtype)
  (* A fully-flexible [Number] on the left pairs with a flexible [Int] (the
     symmetric [Int, Number] and [Number, Number] cases are above). *)
  | Number, Int -> Cell.merge typ1 typ2 Int
  | _ -> Error.binop_type_mismatch ctx.diagnostics ~location typ1 typ2);
  typ1

let check_float_bin_op ctx ~location typ1 typ2 =
  (match (Cell.get typ1, Cell.get typ2) with
  | Valtype { internal = F32; _ }, Valtype { internal = F32; _ }
  | Valtype { internal = F64; _ }, Valtype { internal = F64; _ }
  | (Valtype { internal = F32 | F64; _ } | Float), (Number | Float | LargeInt)
    ->
      Cell.merge typ1 typ2 (Cell.get typ1)
  | (Number | Float | LargeInt), Valtype { internal = F32 | F64; _ } ->
      Cell.merge typ1 typ2 (Cell.get typ2)
  (* Two flexible operands of a float operator (the [Float, _] cases are above):
     a large-int literal is taken as a float here, so anything pairs to [Float]. *)
  | (Number | LargeInt), (Number | Float | LargeInt) ->
      Cell.merge typ1 typ2 Float
  | _ -> Error.binop_type_mismatch ctx.diagnostics ~location typ1 typ2);
  typ1

(* Check and unify the operands of a numeric binary operator that accepts either
   integers or floats (+, -, *, ==, !=); the two cells are merged to their common
   type. Operands here are concrete or flexible numeric literals — the caller
   handles the abstract [Unknown]/[Error] arms. Two fully-flexible [Number]s stay
   [Number] (the operator could still resolve either way); any more committed
   operand pins the pair to its group. Mirrors [check_int_bin_op] (int group) and
   [check_float_bin_op] (float group) unioned. *)
let check_num_concrete ctx ~location ty1 ty2 =
  match (Cell.get ty1, Cell.get ty2) with
  | Valtype { internal = I32; _ }, Valtype { internal = I32; _ }
  | Valtype { internal = I64; _ }, Valtype { internal = I64; _ }
  | Valtype { internal = F32; _ }, Valtype { internal = F32; _ }
  | Valtype { internal = F64; _ }, Valtype { internal = F64; _ } ->
      ()
  | (Valtype { internal = I32 | I64; _ } | Int), (Number | Int)
  | (Valtype { internal = F32 | F64; _ } | Float), (Number | Float | LargeInt)
    ->
      Cell.merge ty1 ty2 (Cell.get ty1)
  | (Number | Int), Valtype { internal = I32 | I64; _ }
  | (Number | Float | LargeInt), Valtype { internal = F32 | F64; _ } ->
      Cell.merge ty1 ty2 (Cell.get ty2)
  | Valtype { internal = I64; _ }, LargeInt -> Cell.merge ty1 ty2 (Cell.get ty1)
  | LargeInt, Valtype { internal = I64; _ } -> Cell.merge ty1 ty2 (Cell.get ty2)
  (* Two flexible literals (the [Float, _] and [LargeInt, Valtype] cases are
     above). A [LargeInt] with a committed [Int] must be an integer — the [Int]
     cannot be a float — and a [LargeInt] cannot be i32, so their sole common type
     is i64; with another [LargeInt] or a fully-flexible [Number] it stays
     [LargeInt] (the operator could still resolve to a float). *)
  | LargeInt, Int | Int, LargeInt -> Cell.merge ty1 ty2 (Valtype i64_valtype)
  | LargeInt, (LargeInt | Number) | Number, LargeInt ->
      Cell.merge ty1 ty2 LargeInt
  | LargeInt, Float -> Cell.merge ty1 ty2 Float
  | Number, Float -> Cell.merge ty1 ty2 Float
  | Number, Int -> Cell.merge ty1 ty2 Int
  | Number, Number -> Cell.merge ty1 ty2 Number
  | _ -> Error.binop_type_mismatch ctx.diagnostics ~location ty1 ty2

let field_has_default (ty : fieldtype) =
  match ty.typ with
  | Packed _ -> true
  | Value ty -> (
      match ty with
      | I32 | I64 | F32 | F64 | V128 -> true
      | Ref { nullable; _ } -> nullable)

let return_statement (i : location instr)
    (desc : (inferred_type Cell.t array * location) instr_desc) (ty : _ array)
    st =
  (st, { desc; info = ((ty : _ array), i.info) })

let return_expression i desc ty = return_statement i desc [| ty |]

let expression_type ctx i =
  let typ, location = i.info in
  match typ with
  | [| ty |] -> ty
  | _ ->
      Error.not_an_expression ctx.diagnostics ~location (Array.length typ);
      Cell.make Error

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

(*** Lint checks on constant operands ***)

(* Parse a Wax integer literal (decimal or [0x] hex, with [_] separators) to an
   [int64], or [None] if it is malformed or does not fit. *)
let int_literal_value s =
  Int64.of_string_opt (String.concat "" (String.split_on_char '_' s))

(* Whether [e] is the integer literal zero. *)
let int_literal_value_is_zero (e : _ Ast.instr) =
  match e.desc with Ast.Int s -> int_literal_value s = Some 0L | _ -> false

(* [x << n] / [x >> n] with a constant [n] at least the operand's bit width:
   Wasm masks [n] modulo the width, so the shift is almost certainly not what
   was meant. Only fires when the operand is a concrete i32/i64 (so the width is
   known) and [n] a non-negative literal. *)
let lint_shift ctx op result rhs =
  match op.desc with
  | Shl | Shr _ -> (
      match rhs.desc with
      | Ast.Int s -> (
          match (int_literal_value s, Cell.get result) with
          | Some n, Valtype { internal = (I32 | I64) as t; _ } when n >= 0L ->
              let width = match t with I32 -> 32 | _ -> 64 in
              if n >= Int64.of_int width then
                Error.shift_overflow ctx.diagnostics ~location:op.info ~width n
          | _ -> ())
      | _ -> ())
  | _ -> ()

(* Integer [/] or [%] by a constant zero always traps. [Div (Some _)] and
   [Rem _] are the integer forms ([Div None] is float division, which does not
   trap on a zero divisor). *)
let lint_division ctx op rhs =
  match op.desc with
  | (Div (Some _) | Rem _) when int_literal_value_is_zero rhs ->
      Error.division_by_zero ctx.diagnostics ~location:op.info
  | _ -> ()

(* Parse a Wax float literal (decimal or hex float with [_] separators, or the
   [nan:0x…] form) to an OCaml float, or [None] if it is malformed. *)
let float_literal_value s =
  if String.length s >= 3 && String.equal (String.sub s 0 3) "nan" then
    Some Float.nan
  else float_of_string_opt (String.concat "" (String.split_on_char '_' s))

(* The float value of a constant operand, looking through a leading sign. *)
let rec float_operand_value i =
  match i.desc with
  | Ast.Float s -> float_literal_value s
  | UnOp ({ desc = Neg; _ }, e) -> Option.map Float.neg (float_operand_value e)
  | UnOp ({ desc = Pos; _ }, e) -> float_operand_value e
  | _ -> None

(* Whether a trapping (toward-zero) float-to-integer conversion of [f] to the
   given target/signage would trap: [f] is NaN or infinite, or its truncation
   lies outside the target range. Bounds are the exact powers of two, so a value
   is flagged only when it is definitely out of range (no false positives near a
   boundary the float type cannot represent exactly). *)
let float_conversion_traps target signage f =
  if not (Float.is_finite f) then true
  else
    let t = Float.trunc f in
    let pow2 n = Float.ldexp 1. n in
    match (target, signage) with
    | `I32, Signed -> t < -.pow2 31 || t >= pow2 31
    | `I32, Unsigned -> t < 0. || t >= pow2 32
    | `I64, Signed -> t < -.pow2 63 || t >= pow2 63
    | `I64, Unsigned -> t < 0. || t >= pow2 64

(* A trapping float-to-integer conversion ([e as i32_s] and the like — the
   [strict] cast forms lower to [trunc], which traps, rather than [trunc_sat])
   of a constant float that is out of the target range: it always traps. *)
let lint_conversion ctx ~location typ operand =
  match typ with
  | Signedtype { typ = (`I32 | `I64) as target; signage; strict = true } -> (
      match float_operand_value operand with
      | Some f when float_conversion_traps target signage f ->
          Error.conversion_out_of_range ctx.diagnostics ~location
      | _ -> ())
  | _ -> ()

(* Whether two operands are the same pure read (a local or global [get]), so the
   two evaluations yield the same value with no side effect. Restricted to [get]
   to stay conservative — no calls, no field/array reads that could trap. *)
let identical_operands (l : _ Ast.instr) (r : _ Ast.instr) =
  match (l.desc, r.desc) with
  | Get a, Get b -> String.equal a.desc b.desc
  | _ -> false

(* A comparison whose result is constant regardless of its variable operand: an
   unsigned comparison against zero ([a <u 0] is false, [a >=u 0] is true), or a
   comparison of two identical operands ([a < a] is false, [a == a] is true).
   The signed/unsigned option marks an integer comparison; [Eq]/[Ne] carry no
   signage, so a self-comparison is only flagged for a concrete integer operand
   (a float [a == a] is false on NaN, and reference identity is a separate
   concern). *)
let lint_comparison ctx op l r =
  let is_int e =
    match Cell.get (expression_type ctx e) with
    | Valtype { internal = I32 | I64; _ } -> true
    | _ -> false
  in
  let tautology =
    match op.desc with
    | Lt (Some Unsigned) when int_literal_value_is_zero r -> Some false
    | Ge (Some Unsigned) when int_literal_value_is_zero r -> Some true
    | Gt (Some Unsigned) when int_literal_value_is_zero l -> Some false
    | Le (Some Unsigned) when int_literal_value_is_zero l -> Some true
    | (Lt (Some _) | Gt (Some _)) when identical_operands l r -> Some false
    | (Le (Some _) | Ge (Some _)) when identical_operands l r -> Some true
    | Eq when identical_operands l r && is_int l -> Some true
    | Ne when identical_operands l r && is_int l -> Some false
    | _ -> None
  in
  match tautology with
  | Some value ->
      Error.tautological_comparison ctx.diagnostics ~location:op.info ~value
  | None -> ()

(* A branch, loop, or [select] condition that is a constant literal, so it
   always takes the same path. [is_while] excludes the idiomatic infinite loop
   [while <nonzero>] (only [while 0], a loop that never runs, is flagged). *)
let lint_condition ctx ?(is_while = false) (cond : _ Ast.instr) =
  match cond.desc with
  | Ast.Int s -> (
      match int_literal_value s with
      | Some n ->
          let value = n <> 0L in
          if not (is_while && value) then
            Error.constant_condition ctx.diagnostics ~location:cond.info ~value
      | None -> ())
  | _ -> ()

(* Whether evaluating [e] has no side effect and cannot trap, so computing it
   only to discard the result is pointless. Conservative: reads of locals/
   globals and constants, and pure arithmetic/logic over them, but not calls,
   assignments, memory/field/array accesses, casts, or trapping arithmetic
   ([/]/[%]). *)
let rec is_effectless (e : _ Ast.instr) =
  match e.desc with
  | Get _ | Int _ | Float _ | Char _ | String _ | Null | StructDefault _ -> true
  | UnOp (_, a) -> is_effectless a
  | BinOp ({ desc = Div _ | Rem _; _ }, _, _) -> false
  | BinOp (_, a, b) -> is_effectless a && is_effectless b
  | Select (a, b, c) -> is_effectless a && is_effectless b && is_effectless c
  | Test (a, _) -> is_effectless a
  | _ -> false

(* The concrete type an initializer would take with no annotation, matching the
   resolution of the unannotated [let] case. Returns [None] for types we never
   want to drop an annotation for (packed or still unconstrained). Pure: it does
   not mutate [ty], so it can be read before [check_type] constrains it. *)
let standalone_valtype ctx ty =
  match Cell.get ty with
  | Valtype v -> Some v
  | Int | Number -> Some i32_valtype
  | LargeInt -> Some i64_valtype
  | Float -> Some f64_valtype
  | Null -> internalize_valtype ctx (Ref { nullable = true; typ = None_ })
  (* The bottom reference concretizes to the non-null [&none], matching the type
     [null!] produced before [UnknownRef] existed. *)
  | UnknownRef ->
      internalize_valtype ctx (Ref { nullable = false; typ = None_ })
  | Int8 | Int16 | Unknown | Error | Collecting _ -> None

(* Resolve the type that an omitted annotation takes from its initializer, as in
   [let x = e] or [const x = e]: an as-yet-unconstrained literal is pinned to a
   concrete type the way the final type erasure does (int/number -> i32,
   float -> f64, null -> nullref), so the binding gets a definite type. Mutates
   [ty] so later uses observe the resolved type. *)
let resolve_omitted_valtype ctx ty =
  match Cell.get ty with
  | Valtype v -> Some v
  | LargeInt ->
      let v = i64_valtype in
      Cell.set ty (Valtype v);
      Some v
  | Int | Number | Int8 | Int16 | Unknown | Error | Collecting _ ->
      let v = i32_valtype in
      Cell.set ty (Valtype v);
      Some v
  | Float ->
      let v = f64_valtype in
      Cell.set ty (Valtype v);
      Some v
  | Null ->
      let+@ v =
        internalize_valtype ctx (Ref { nullable = true; typ = None_ })
      in
      Cell.set ty (Valtype v);
      v
  (* The bottom reference concretizes to the non-null [&none], matching the type
     [null!] produced before [UnknownRef] existed. *)
  | UnknownRef ->
      let+@ v =
        internalize_valtype ctx (Ref { nullable = false; typ = None_ })
      in
      Cell.set ty (Valtype v);
      v

(* The type an unannotated [let]/global binding takes from its initializer,
   recording a poison ([None]) type when the initializer has no concrete one. An
   [Unknown] initializer (unreachable / branch code) reports an error here: a
   binding needs a determinable type to be compiled, and silently demoting it to
   the [Error] type would mask that. An [Error] initializer (already reported)
   stays silent. *)
let bound_value_type ctx ~location result_ty =
  match Cell.get result_ty with
  | Error -> None
  | Unknown ->
      Error.unknown_operand_type ctx.diagnostics ~location;
      None
  | _ -> resolve_omitted_valtype ctx result_ty

(* --- Annotation dropping (the "keep-bool" machinery) -----------------------

   When converting from Wasm, the typed AST is rewritten ([ctx.simplify]) to
   drop type annotations that the inferred types make redundant, so the printed
   Wax is not littered with annotations a reader (or a re-parse) would recover
   anyway. The decision is a "keep-bool": when [check_instruction] types a value
   against an expected type (the annotation), it returns whether that annotation
   is load-bearing — i.e. whether omitting it would change what the value
   re-infers to. The binding/construct site then drops the annotation precisely
   when [simplify] is on and the keep-bool says it is not needed.

   The pieces, by where the annotation lives:
   - a scalar value vs. its annotation: [annotation_needed] (the leaf keep-bool,
     comparing the value's standalone type to the expected one);
   - a block/loop/try result type: [block_keep_bool] / [block_keep_needed],
     with [context_block_typ] / [finalize_inferred] filling an omitted result
     from context or dropping a redundant declared one;
   - [is_null_initializer] is the one exception to the "equal type ⇒ drop" rule
     (a bare [null] re-infers a floating type), and [drop_supertype] the one
     relaxation (an immutable binding may drop a mere-supertype annotation).
   --------------------------------------------------------------------------- *)

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
  match (standalone, Cell.get expected) with
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
  match Cell.get expected with Unknown | Collecting _ -> false | _ -> true

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
  match Cell.get expected with
  | Valtype { typ = Ref { typ = Type ident | Exact ident; _ }; _ } -> Some ident
  | _ -> None

(* The user type name a heap type refers to ([Type]/[Exact]), or [None] for an
   abstract/bottom heap type. *)
let named_heaptype (t : heaptype) =
  match t with Type ident | Exact ident -> Some ident | _ -> None

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
           check_subtype ctx ~location result_ty (valtype_cell ity);
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
      (* A named binding [let x = _] or an anonymous drop [_ = _] (both a
         single-binding [Let] over a hole): peel one value each. *)
      | { desc = Let ([ b ], Some v); _ } :: r when is_hole v ->
          take (n - 1) (b :: acc) r
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
    match Cell.get ty with
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
                (match Cell.get ts'.(n - 1) with
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
  | Set (_, _, i)
  | Tee (_, i)
  | UnOp (_, i)
  | Cast (i, _)
  | Test (i, _)
  | NonNull i
  | Br (_, Some i)
  | Br_if (_, i)
  | Hinted (_, i)
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
  | StructDefaultDesc i
  | GetDescriptor i
  | StructGet (i, _) ->
      count_holes i
  | CastDesc (i1, _, i2)
  | Br_on_cast_desc_eq (_, _, i1, i2)
  | Br_on_cast_desc_eq_fail (_, _, i1, i2)
  | StructSet (i1, _, i2) ->
      count_holes i1 + count_holes i2
  (* A punned field ([None]) is a [Get], which contains no holes. *)
  | Struct (_, l) ->
      List.fold_left
        (fun acc (_, i) -> acc + Option.fold ~none:0 ~some:count_holes i)
        0 l
  | StructDesc (d, l) ->
      count_holes d
      + List.fold_left
          (fun acc (_, i) -> acc + Option.fold ~none:0 ~some:count_holes i)
          0 l
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
  | Get _ | Path _ | Null | Unreachable | Nop
  | Let (_, None)
  | Br (_, None)
  | Throw (_, None)
  | Return None ->
      0

(* Accumulate into [acc] the local names assigned ([Set]/[Tee] targets) anywhere
   in [i], recursing through every sub-instruction. Mirrors the case coverage of
   {!Sink_let.occurs}: only [Set]/[Tee] write a local, every other case just
   recurses. A drop ([_ = e], an anonymous [Let]) names no local, so it just
   recurses via the [Let] case. Wasm-derived locals are uniquely named within a
   function, so the
   resulting by-name set is exact; a stray name collision could only keep an
   annotation, never wrongly drop one. *)
let rec collect_assigned_locals acc i =
  let in_list acc l = List.fold_left collect_assigned_locals acc l in
  let in_opt acc o =
    match o with Some i -> collect_assigned_locals acc i | None -> acc
  in
  match i.desc with
  | Set (id, _, e) | Tee (id, e) ->
      collect_assigned_locals (StringSet.add id.desc acc) e
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } ->
      in_list acc block
  | While { cond; step; block; _ } ->
      let acc = collect_assigned_locals acc cond in
      let acc =
        Option.fold ~none:acc ~some:(collect_assigned_locals acc) step
      in
      in_list acc block
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
  | GetDescriptor e
  | StructDefaultDesc e
  | UnOp (_, e)
  | Br_if (_, e)
  | Hinted (_, e)
  | Br_table (_, e)
  | Br_on_null (_, e)
  | Br_on_non_null (_, e)
  | Br_on_cast (_, _, e)
  | Br_on_cast_fail (_, _, e)
  | ThrowRef e
  | ArrayDefault (_, e)
  | ContNew (_, e) ->
      collect_assigned_locals acc e
  (* A punned field ([None]) is a [Get] and assigns nothing. *)
  | Struct (_, fields) ->
      List.fold_left
        (fun acc (_, e) ->
          Option.fold ~none:acc ~some:(collect_assigned_locals acc) e)
        acc fields
  | StructDesc (d, fields) ->
      List.fold_left
        (fun acc (_, e) ->
          Option.fold ~none:acc ~some:(collect_assigned_locals acc) e)
        (collect_assigned_locals acc d)
        fields
  | CastDesc (e1, _, e2)
  | Br_on_cast_desc_eq (_, _, e1, e2)
  | Br_on_cast_desc_eq_fail (_, _, e1, e2)
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
  | Get _ | Path _ | Unreachable | Nop | Hole | Null | Char _ | String _ | Int _
  | Float _ | StructDefault _ ->
      acc

(* Accumulate into [acc] the block labels declared anywhere in [i], from the
   source AST (before any lowering, so synthesized labels from [while]/[dispatch]/
   [match] desugaring are never collected). Every case recurses; the labelled
   constructs also contribute their own label. The [dispatch]/[match] arm labels
   are branch targets, not declarations, so they are not collected. Mirrors the
   case coverage of {!collect_assigned_locals}. *)
let rec collect_labels acc (i : _ Ast.instr) =
  let in_list acc l = List.fold_left collect_labels acc l in
  let in_opt acc o =
    match o with Some i -> collect_labels acc i | None -> acc
  in
  let add acc label = match label with Some l -> l :: acc | None -> acc in
  match i.desc with
  | Block { label; block; _ }
  | Loop { label; block; _ }
  | TryTable { label; block; _ } ->
      in_list (add acc label) block
  | While { label; cond; step; block; _ } ->
      let acc = collect_labels (add acc label) cond in
      let acc = Option.fold ~none:acc ~some:(collect_labels acc) step in
      in_list acc block
  | If { label; cond; if_block; else_block; _ } ->
      let acc = in_list (collect_labels (add acc label) cond) if_block.desc in
      Option.fold ~none:acc ~some:(fun b -> in_list acc b.desc) else_block
  | Try { label; block; catches; catch_all; _ } ->
      let acc = in_list (add acc label) block in
      let acc = List.fold_left (fun acc (_, b) -> in_list acc b) acc catches in
      Option.fold ~none:acc ~some:(in_list acc) catch_all
  | Call (t, args) | TailCall (t, args) -> in_list (collect_labels acc t) args
  | Set (_, _, e)
  | Tee (_, e)
  | Cast (e, _)
  | Test (e, _)
  | NonNull e
  | StructGet (e, _)
  | GetDescriptor e
  | StructDefaultDesc e
  | UnOp (_, e)
  | Br_if (_, e)
  | Hinted (_, e)
  | Br_table (_, e)
  | Br_on_null (_, e)
  | Br_on_non_null (_, e)
  | Br_on_cast (_, _, e)
  | Br_on_cast_fail (_, _, e)
  | ThrowRef e
  | ArrayDefault (_, e)
  | ContNew (_, e) ->
      collect_labels acc e
  | Struct (_, fields) ->
      List.fold_left (fun acc (_, e) -> in_opt acc e) acc fields
  | StructDesc (d, fields) ->
      List.fold_left
        (fun acc (_, e) -> in_opt acc e)
        (collect_labels acc d) fields
  | CastDesc (e1, _, e2)
  | Br_on_cast_desc_eq (_, _, e1, e2)
  | Br_on_cast_desc_eq_fail (_, _, e1, e2)
  | StructSet (e1, _, e2)
  | Array (_, e1, e2)
  | ArraySegment (_, _, e1, e2)
  | ArrayGet (e1, e2)
  | BinOp (_, e1, e2) ->
      collect_labels (collect_labels acc e1) e2
  | ArraySet (e1, e2, e3) | Select (e1, e2, e3) ->
      collect_labels (collect_labels (collect_labels acc e1) e2) e3
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
        (collect_labels acc index) arms
  | Match { scrutinee; arms; default } ->
      let acc = collect_labels acc scrutinee in
      let acc = List.fold_left (fun acc (_, b) -> in_list acc b) acc arms in
      in_list acc default
  | Let (_, body) -> in_opt acc body
  | Br (_, o) | Throw (_, o) | Return o -> in_opt acc o
  | If_annotation { then_body; else_body; _ } ->
      let acc = in_list acc then_body in
      Option.fold ~none:acc ~some:(in_list acc) else_body
  | Get _ | Path _ | Unreachable | Nop | Hole | Null | Char _ | String _ | Int _
  | Float _ | StructDefault _ ->
      acc

(* Walk the source AST (before any lowering, so [while] keeps its own condition
   rather than the [if] it desugars to) and report the purely-syntactic lints: a
   constant branch/loop/select condition, and a drop ([_ = e]) of a
   side-effect-free expression. Runs once over the source rather than in the type
   checker's expression handling. Mirrors the case coverage of
   {!collect_labels}. *)
let rec lint_source ctx (i : _ Ast.instr) =
  let list l = List.iter (lint_source ctx) l in
  let opt o = Option.iter (lint_source ctx) o in
  match i.desc with
  | If { cond; if_block; else_block; _ } ->
      lint_condition ctx cond;
      lint_source ctx cond;
      list if_block.desc;
      Option.iter (fun b -> list b.desc) else_block
  | While { cond; step; block; _ } ->
      lint_condition ctx ~is_while:true cond;
      lint_source ctx cond;
      opt step;
      list block
  | Select (c, t, e) ->
      lint_condition ctx c;
      lint_source ctx c;
      lint_source ctx t;
      lint_source ctx e
  | Br_if (_, c) ->
      lint_condition ctx c;
      lint_source ctx c
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } -> list block
  | Try { block; catches; catch_all; _ } ->
      list block;
      List.iter (fun (_, b) -> list b) catches;
      Option.iter list catch_all
  | Call (t, args) | TailCall (t, args) ->
      lint_source ctx t;
      list args
  | Set (_, _, e) ->
      (* An assignment to a named target; the pointless-drop check lives in the
         [Let] case, since a drop [_ = e] is an anonymous binding. *)
      lint_source ctx e
  | Tee (_, e)
  | Cast (e, _)
  | Test (e, _)
  | NonNull e
  | StructGet (e, _)
  | GetDescriptor e
  | StructDefaultDesc e
  | UnOp (_, e)
  | Hinted (_, e)
  | Br_table (_, e)
  | Br_on_null (_, e)
  | Br_on_non_null (_, e)
  | Br_on_cast (_, _, e)
  | Br_on_cast_fail (_, _, e)
  | ThrowRef e
  | ArrayDefault (_, e)
  | ContNew (_, e) ->
      lint_source ctx e
  | Struct (_, fields) ->
      List.iter (fun (_, e) -> Option.iter (lint_source ctx) e) fields
  | StructDesc (d, fields) ->
      lint_source ctx d;
      List.iter (fun (_, e) -> Option.iter (lint_source ctx) e) fields
  | CastDesc (e1, _, e2)
  | Br_on_cast_desc_eq (_, _, e1, e2)
  | Br_on_cast_desc_eq_fail (_, _, e1, e2)
  | StructSet (e1, _, e2)
  | Array (_, e1, e2)
  | ArraySegment (_, _, e1, e2)
  | ArrayGet (e1, e2)
  | BinOp (_, e1, e2) ->
      lint_source ctx e1;
      lint_source ctx e2
  | ArraySet (e1, e2, e3) ->
      lint_source ctx e1;
      lint_source ctx e2;
      lint_source ctx e3
  | ArrayFixed (_, l)
  | ContBind (_, _, l)
  | Suspend (_, l)
  | Resume (_, _, l)
  | ResumeThrow (_, _, _, l)
  | ResumeThrowRef (_, _, l)
  | Switch (_, _, l)
  | Sequence l ->
      list l
  | Dispatch { index; arms; _ } ->
      lint_source ctx index;
      List.iter (fun (_, b) -> list b) arms
  | Match { scrutinee; arms; default } ->
      lint_source ctx scrutinee;
      List.iter (fun (_, b) -> list b) arms;
      list default
  | Let (bindings, body) ->
      (* A drop [_ = e] is a single anonymous binding; if [e] is effect-free,
         computing it only to discard the result is pointless. *)
      (match (bindings, body) with
      | [ (None, _) ], Some e when is_effectless e ->
          Error.unused_result ctx.diagnostics ~location:e.info
      | _ -> ());
      opt body
  | Br (_, o) | Throw (_, o) | Return o -> opt o
  | If_annotation { then_body; else_body; _ } ->
      list then_body;
      Option.iter list else_body
  | Get _ | Path _ | Unreachable | Nop | Hole | Null | Char _ | String _ | Int _
  | Float _ | StructDefault _ ->
      ()

(* If [meth] names an intrinsic written as a method on a value receiver — a SIMD
   lane/vector op [v.add_i32x4(b)], or a scalar [x.copysign(y)], [x.min(y)],
   [x.rotl(y)] — the number of leading constant lane immediates in its argument
   list (always 0 for the scalar ops), else [None]. Such a call evaluates the
   receiver before its operands, unlike a generic call whose callee is evaluated
   last; the leading SIMD lane immediates are static and never reach the stack.
   The set of names matches the call dispatch (see [type_simd_vector_op_call],
   [type_binary_intrinsic_call]). This is decided by name alone — but the same
   names are only receiver-first when the receiver is actually a value, see
   [receiver_is_value]. *)
let intrinsic_method_imms meth =
  match Wax_wasm.Simd.classify meth with
  | Some { free = false; imm; _ } -> (
      match imm with No_imm -> Some 0 | Lane _ -> Some 1 | Shuffle -> Some 16)
  | _ -> (
      match meth with
      | "rotl" | "rotr" | "copysign" | "min" | "max" -> Some 0
      | _ -> None)

(* Whether [obj], the receiver of an [obj.meth(args)] call, is a value rather
   than a reference. Only a value receiver makes [meth] an intrinsic evaluated
   receiver-first: when [obj] is a reference, [obj.meth] may instead load a
   function-pointer field, so the call is an indirect call whose arguments are
   evaluated first (then the loaded callee). Treating that as receiver-first
   could hide a value occurring before a hole, so the reorder is gated on this. *)
let receiver_is_value ctx obj =
  match Cell.get (expression_type ctx obj) with
  | Null | Valtype { internal = Ref _; _ } -> false
  | _ -> true

(* Whether the receiver of an [obj.meth(..)] call is a concrete array — the case
   that makes a [fill]/[copy]/[init] method an array operation (evaluated
   receiver-first), as opposed to a struct-field/indirect call or a static
   memory/table form (both args-first / static-receiver). Reads the receiver's
   type cell directly: a memory/table receiver carries no value type ([||]), for
   which [expression_type] would spuriously report "not an expression". *)
let receiver_is_array ctx recv =
  match fst recv.Ast.info with
  | [| cell |] -> (
      match Cell.get cell with
      | Valtype { typ = Ref { typ = Type ty | Exact ty; _ }; _ } -> (
          match Tbl.find_opt ctx.type_context.types ty with
          | Some t -> ( match (snd t).typ with Array _ -> true | _ -> false)
          | None -> false)
      | _ -> false)
  | _ -> false

(* A cast is transparent to the hole-order check exactly when [to_wasm] lowers it
   to no instruction (so it occupies its operand's position and produces nothing):
   an operand with no value type — unreachable / failed code, where the cast emits
   nothing — or a numeric-scalar identity, the only [Nop] case in [to_wasm]'s cast
   lowering. Everything else IS emitted: a numeric conversion ([_ as f32] on an
   [f64] hole is [f32.demote_f64]) or a reference cast (always a [ref.cast], even
   an up-cast), and operates on the stack top, so it must be ordered like any
   other value-producing expression. *)
let cast_is_transparent ctx ~cast ~operand =
  match Cell.get (expression_type ctx operand) with
  | Unknown | Error -> true
  | Valtype { internal = (I32 | I64 | F32 | F64) as src; _ } -> (
      match Cell.get (expression_type ctx cast) with
      | Valtype { internal = dst; _ } -> src = dst
      | _ -> false)
  | _ -> false

let rec check_hole_order_rec ctx i n =
  match i.desc with
  | Hole -> n - 1
  | Get name
    when memory_receiver ctx name || table_receiver ctx name
         || segment_receiver ctx name ->
      (* A memory/table name (a method/index receiver [mem.load(..)], [tab[..]],
         or a cross-mem/table [copy] source) or a data/element segment name (a
         [seg.drop()] receiver or an [init] operand) is a static immediate, not a
         stack value, so it never counts as occurring before a hole. *)
      n
  | _ when n <= 0 -> n
  | Cast (inner, _) when cast_is_transparent ctx ~cast:i ~operand:inner ->
      (* A nop cast (see [cast_is_transparent]) is transparent: recurse into the
         operand, which is itself flagged if it is a value occurring before a
         hole, without counting the cast as such — so [(_ as T)] with a hole
         already of type [T] is fine even when later holes remain. A non-nop
         cast falls through to the normal handling below. *)
      check_hole_order_rec ctx inner n
  | _ ->
      let n =
        match i.desc with
        | Block _ | Loop _ | While _ | TryTable _ | Try _ | If_annotation _
        | Dispatch _ | Match _ | StructDefault _ | Char _ | String _ | Int _
        | Float _ | Get _ | Path _ | Null | Unreachable | Nop
        | Let (_, None)
        | Br (_, None)
        | Throw (_, None)
        | Return None ->
            n
        (* A table reference [tab[..]] has a static receiver (the table name),
           not an evaluated operand, so it does not count as occurring before a
           hole; only the index/value do. *)
        | ArrayGet ({ desc = Get tab; _ }, r) when table_receiver ctx tab ->
            check_hole_order_rec ctx r n
        | ArraySet ({ desc = Get tab; _ }, idx, v) when table_receiver ctx tab
          ->
            n |> check_hole_order_rec ctx idx |> check_hole_order_rec ctx v
        | BinOp (_, l, r)
        | Array (_, l, r)
        | ArraySegment (_, _, l, r)
        | ArrayGet (l, r) ->
            n |> check_hole_order_rec ctx l |> check_hole_order_rec ctx r
        | ArraySet (t, i, v) ->
            n |> check_hole_order_rec ctx t |> check_hole_order_rec ctx i
            |> check_hole_order_rec ctx v
        | Call ({ desc = StructGet (obj, meth); _ }, args)
          when intrinsic_method_imms meth.desc <> None
               && receiver_is_value ctx obj ->
            (* An intrinsic method on a value receiver, [recv.op(imms.., ops..)].
               [to_wasm] evaluates the receiver first, then the non-immediate
               stack operands; any leading SIMD lane immediates ([Lane]/[Shuffle])
               are static and never reach the operand stack. Mirror that order so
               a static lane index — or an operand of a receiver-first scalar op
               like [copysign] — is not mistaken for a value before a hole. A
               reference receiver is excluded ([receiver_is_value]): it could be a
               function-pointer field, i.e. an args-first indirect call. *)
            let nimm = Option.get (intrinsic_method_imms meth.desc) in
            let operands = List.filteri (fun k _ -> k >= nimm) args in
            n
            |> check_hole_order_rec ctx obj
            |> check_hole_order_in_list ctx operands
        | Call ({ desc = StructGet (recv, meth); _ }, args)
          when (match meth.desc with
                 | "fill" | "copy" | "init" -> true
                 | _ -> false)
               && receiver_is_array ctx recv ->
            (* [arr.fill/copy/init] on an array receiver is a receiver-first array
               operation, like the intrinsics above: [to_wasm] and the type
               checker both evaluate the array receiver before the operands, so
               mirror that order. The same method name on a non-array receiver is
               a struct-field/indirect call or a static memory/table form, all of
               which the general case below handles (args-first, with a static
               [Get name] receiver not counted). The arity is not re-checked —
               typing has already validated it. *)
            n
            |> check_hole_order_rec ctx recv
            |> check_hole_order_in_list ctx args
        | Call (f, args) | TailCall (f, args) ->
            n |> check_hole_order_in_list ctx args |> check_hole_order_rec ctx f
        | If { cond = i; _ }
        | Let (_, Some i)
        | Set (_, _, i)
        | Tee (_, i)
        | UnOp (_, i)
        | Cast (i, _)
        | Test (i, _)
        | NonNull i
        | Br (_, Some i)
        | Br_if (_, i)
        | Hinted (_, i)
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
        | StructDefaultDesc i
        | GetDescriptor i
        | StructGet (i, _) ->
            check_hole_order_rec ctx i n
        | CastDesc (i1, _, i2)
        | Br_on_cast_desc_eq (_, _, i1, i2)
        | Br_on_cast_desc_eq_fail (_, _, i1, i2)
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
              match Cell.get (expression_type ctx i) with
              | Valtype { typ = Ref { typ = Type t | Exact t; _ }; _ } -> (
                  match lookup_struct_type ctx t with
                  | Some fields ->
                      let field_map =
                        List.fold_left
                          (fun acc (name, instr) ->
                            StringMap.add name.desc instr acc)
                          StringMap.empty l
                      in
                      (* Reorder fields according to definition. Pinned fields
                         ([None]) are [Get]s with no hole, so drop them. *)
                      Array.map
                        (fun field ->
                          StringMap.find (fst field.desc).desc field_map)
                        fields
                      |> Array.to_list |> List.filter_map Fun.id
                  | None -> List.filter_map snd l)
              | _ -> List.filter_map snd l
            in
            check_hole_order_in_list ctx fields n
        | StructDesc (d, l) ->
            (* As [Struct], with the descriptor operand evaluated last (after the
               field values). *)
            let fields =
              match Cell.get (expression_type ctx i) with
              | Valtype { typ = Ref { typ = Type t | Exact t; _ }; _ } -> (
                  match lookup_struct_type ctx t with
                  | Some fields ->
                      let field_map =
                        List.fold_left
                          (fun acc (name, instr) ->
                            StringMap.add name.desc instr acc)
                          StringMap.empty l
                      in
                      Array.map
                        (fun field ->
                          StringMap.find (fst field.desc).desc field_map)
                        fields
                      |> Array.to_list |> List.filter_map Fun.id
                  | None -> List.filter_map snd l)
              | _ -> List.filter_map snd l
            in
            check_hole_order_in_list ctx (fields @ [ d ]) n
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
    (Cell.make Error, [||]))
  else (a.(len - 1), Array.sub a 0 (len - 1))

let immediate_supertype s : Ast.heaptype =
  match (s.supertype, s.typ) with
  | Some t, _ -> Type t
  | None, Struct _ -> Struct
  | None, Array _ -> Array
  | None, Func _ -> Func
  | None, Cont _ -> Cont

(* The top of [h]'s subtyping hierarchy ([Any]/[Func]/[Extern]/[Exn]/[Cont]),
   without reporting an unbound type ([None] then). *)
let heaptype_top ctx (h : Ast.heaptype) : Ast.heaptype option =
  match h with
  | Any | Eq | I31 | Struct | Array | None_ -> Some Any
  | Func | NoFunc -> Some Func
  | Extern | NoExtern -> Some Extern
  | Exn | NoExn -> Some Exn
  | Cont | NoCont -> Some Cont
  | Type id | Exact id -> (
      match Tbl.find_opt ctx.type_context.types id with
      | Some (_, s) -> (
          match s.typ with
          | Struct _ | Array _ -> Some Any
          | Func _ -> Some Func
          | Cont _ -> Some Cont)
      | None -> None)

(* A bottom reference of a hierarchy. *)
let is_bottom_heaptype = function
  | None_ | NoFunc | NoExtern | NoExn | NoCont -> true
  | _ -> false

(* The type lookups below never fail *)
let rec heap_lub ctx (h1 : Ast.heaptype) (h2 : Ast.heaptype) =
  match (h1, h2) with
  (* A bottom reference is below everything in its hierarchy, so its lub with any
     type of that same hierarchy is that other type. Handle this before walking a
     concrete [Type] up to its supertype, which would otherwise discard the
     bottom and over-generalise (e.g. [lub(none, $t)] giving [struct] not [$t]). *)
  | b, h when is_bottom_heaptype b && heaptype_top ctx b = heaptype_top ctx h ->
      Some h
  | h, b when is_bottom_heaptype b && heaptype_top ctx b = heaptype_top ctx h ->
      Some h
  (* [exact] survives a lub only when both sides are the same exact type; any
     generalization drops exactness (an [exact a]/[exact b] pair joins at their
     common non-exact supertype). *)
  | Exact id1, Exact id2 ->
      let*@ i1, _ = Tbl.find_opt ctx.type_context.types id1 in
      let*@ i2, _ = Tbl.find_opt ctx.type_context.types id2 in
      if i1 = i2 then Some (Exact id1) else heap_lub ctx (Type id1) (Type id2)
  | Exact id1, h -> heap_lub ctx (Type id1) h
  | h, Exact id2 -> heap_lub ctx h (Type id2)
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
  match (Cell.get ty1, Cell.get ty2) with
  (* [Unknown]/[Error] are the universal bottom: the other side wins (the lub of
     [Unknown] and [UnknownRef] is the more informative [UnknownRef]). [UnknownRef]
     (a bottom reference) joins with any other reference — concrete, [Null] or
     another [UnknownRef] — which, being a supertype, wins; a bottom reference
     paired with a non-reference (e.g. [i32]) has no common type and falls
     through to a mismatch. *)
  (* An [Unknown] value reaching a block's exit (a hole on the polymorphic stack of
     dead code) genuinely takes the block's result type: pin it (merge), so a
     branch that also passes it through — a [br_if]/[br_on_null] whose value is then
     cast — sees the resolved width rather than staying [Unknown], which would make
     [To_wasm] drop the cast. [Error] (already reported) stays the untouched bottom. *)
  | _, Unknown ->
      Cell.merge ty1 ty2 (Cell.get ty1);
      Some ty1
  | Unknown, _ ->
      Cell.merge ty1 ty2 (Cell.get ty2);
      Some ty2
  | _, Error -> Some ty1
  | Error, _ -> Some ty2
  | UnknownRef, UnknownRef ->
      (* Merge the two bottom references so pinning one (later, against a concrete
         type) pins the other too. *)
      Cell.merge ty1 ty2 UnknownRef;
      Some ty1
  | (Valtype { internal = Ref _; _ } | Null), UnknownRef ->
      Cell.set ty2 (Cell.get ty1);
      Some ty1
  | UnknownRef, (Valtype { internal = Ref _; _ } | Null) ->
      Cell.set ty1 (Cell.get ty2);
      Some ty2
  | Null, Null ->
      (* Unify the two nulls so pinning one (later, to a reference type) pins the
         other too. *)
      Cell.merge ty1 ty2 Null;
      Some ty1
  | Valtype { internal = I32; _ }, Valtype { internal = I32; _ }
  | Valtype { internal = I64; _ }, Valtype { internal = I64; _ }
  | Valtype { internal = F32; _ }, Valtype { internal = F32; _ }
  | Valtype { internal = F64; _ }, Valtype { internal = F64; _ } ->
      Some ty2
  | (Int | Number), (Int | Valtype { internal = I32 | I64; _ })
  | (Float | Number), (Float | Valtype { internal = F32 | F64; _ })
  | Number, Number ->
      Cell.merge ty1 ty2 (Cell.get ty2);
      Some ty2
  | ( (Valtype { internal = I32; _ } | Valtype { internal = I64; _ }),
      (Int | Number) )
  | ( (Valtype { internal = F32; _ } | Valtype { internal = F64; _ }),
      (Float | Number) )
  | (Int | Float), Number ->
      Cell.merge ty1 ty2 (Cell.get ty1);
      Some ty1
  (* A [LargeInt] (literal too big for i32) defaults to i64 and is also
     convertible to a float. It joins with another [LargeInt] or a fully-flexible
     [Number] staying [LargeInt] (i64/f32/f64), or with a concrete i64/f32/f64 or a
     flexible float taking that type, but never with i32. A committed [Int], being
     integer-only, has i64 as its sole common type with a [LargeInt] — pin it
     there, so the join cannot later be coerced to a float the [Int] cannot be.
     Mirrors [check_int_bin_op]/[check_num_concrete]. *)
  | LargeInt, Int | Int, LargeInt ->
      Cell.merge ty1 ty2 (Valtype i64_valtype);
      Some ty1
  | LargeInt, (LargeInt | Number) ->
      Cell.merge ty1 ty2 LargeInt;
      Some ty1
  | Number, LargeInt ->
      Cell.merge ty1 ty2 LargeInt;
      Some ty2
  | LargeInt, (Float | Valtype { internal = I64 | F32 | F64; _ }) ->
      Cell.merge ty1 ty2 (Cell.get ty2);
      Some ty2
  | (Float | Valtype { internal = I64 | F32 | F64; _ }), LargeInt ->
      Cell.merge ty1 ty2 (Cell.get ty1);
      Some ty1
  | Valtype { typ = typ1; _ }, Valtype { typ = typ2; _ } -> (
      match val_lub ctx typ1 typ2 with
      | Some ty -> internalize ctx ty
      | None -> None)
  | Valtype { typ = Ref { typ; _ }; _ }, Null -> (
      match internalize ctx (Ref { typ; nullable = true }) with
      | Some ty ->
          Cell.set ty2 (Cell.get ty);
          Some ty
      | None -> None)
  | Null, Valtype { typ = Ref { typ; _ }; _ } -> (
      match internalize ctx (Ref { typ; nullable = true }) with
      | Some ty ->
          Cell.set ty1 (Cell.get ty);
          Some ty
      | None -> None)
  | _ -> None

let address_valtype (at : [ `I32 | `I64 ]) : inferred_valtype =
  match at with `I32 -> i32_valtype | `I64 -> i64_valtype

let address_cell at = valtype_cell (address_valtype at)

(* Expected operand/result type of a SIMD intrinsic, as a fresh type cell. *)
let simd_valtype : Simd.ty -> inferred_valtype = function
  | TV128 -> { typ = V128; internal = V128; anon_comptype = None }
  | TI32 -> i32_valtype
  | TI64 -> i64_valtype
  | TF32 -> f32_valtype
  | TF64 -> f64_valtype

let simd_cell t = valtype_cell (simd_valtype t)

(* Memory access method names. The value width is in the name; signedness and the
   i32/i64 result come from a surrounding [as iN_s/u] cast (see [to_wasm]). *)
let mem_load_result meth : inferred_type option =
  match meth with
  | "load8" -> Some Int8
  | "load16" -> Some Int16
  | "load32" -> Some (Valtype i32_valtype)
  | "load64" -> Some (Valtype i64_valtype)
  | "loadf32" -> Some (Valtype f32_valtype)
  | "loadf64" -> Some (Valtype f64_valtype)
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

(* [min(2^bits - 1, 2^(bits - p))]; mirrors [Validation.max_memory_size]. *)
let max_memory_size address_type page_size_log2 =
  let p = match page_size_log2 with None -> 16 | Some p -> p in
  let bits, index_max =
    match address_type with
    | `I32 -> (32, Wax_utils.Uint64.of_string "0xffff_ffff")
    | `I64 -> (64, Wax_utils.Uint64.of_string "0xffff_ffff_ffff_ffff")
  in
  let e = bits - p in
  let by_page =
    if e >= 64 then index_max
    else if e <= 0 then Wax_utils.Uint64.zero
    else Wax_utils.Uint64.of_int64 (Int64.shift_left 1L e)
  in
  if Wax_utils.Uint64.compare index_max by_page <= 0 then index_max else by_page

let max_table_size address_type _page_size_log2 =
  match address_type with
  | `I32 -> Wax_utils.Uint64.of_string "0xffff_ffff"
  | `I64 -> Wax_utils.Uint64.of_string "0xffff_ffff_ffff_ffff"

(* Validate a memory/table size limit and page size. Mirrors [Validation.limits]. *)
let check_limits ctx ~location kind ~shared address_type page_size_log2 limits
    max_fn =
  (match page_size_log2 with
  | None | Some (0 | 16) -> ()
  | Some _ -> Error.invalid_page_size ctx.diagnostics ~location);
  if shared && match limits with Some (_, Some _) -> false | _ -> true then
    Error.shared_memory_without_max ctx.diagnostics ~location;
  match limits with
  | None -> ()
  | Some (mi, ma) -> (
      let max = max_fn address_type page_size_log2 in
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

(* Register (once) a type definition for an anonymous function signature and
   return the synthetic name standing for it — used when a cast or [call_ref]
   needs a named [func] type but the source wrote the signature inline. The name
   is a deterministic mangling of the signature, so identical signatures map to
   the same definition; [to_wasm] materialises it through the [<..>]
   synthetic-type path. *)
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
      | Type id -> "$" ^ id.desc
      | Exact id -> "!$" ^ id.desc)
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
           Ast.no_loc
             ( name,
               {
                 supertype = None;
                 typ = Func sign;
                 final = true;
                 descriptor = None;
                 describes = None;
               } );
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
   typed condition, continue-expression and body, dropping the synthesised loop,
   [if] and back-edge. Deterministic — the lowering we just type-checked
   guarantees the shape. [stepped]/[labelled] pick which of the three shapes
   [lower_while] produced. *)
let rebuild_while ~stepped ~labelled typed_list =
  match typed_list with
  | [
   {
     desc = Ast.Loop { block = [ { desc = If { cond; if_block; _ }; _ } ]; _ };
     _;
   };
  ] -> (
      match (stepped, labelled) with
      (* Labelled step: [ block { body } ; step ; br ] *)
      | true, true -> (
          match if_block.desc with
          | [
           { desc = Ast.Block { block = body; _ }; _ }; step; { desc = Br _; _ };
          ] ->
              (cond, Some step, body)
          | _ -> assert false)
      (* Unlabelled step: [ body… ; step ; br ]; else just [ body… ; br ]. *)
      | _ -> (
          match List.rev if_block.desc with
          | { desc = Ast.Br _; _ } :: step :: rev_body when stepped ->
              (cond, Some step, List.rev rev_body)
          | { desc = Ast.Br _; _ } :: rev_body -> (cond, None, List.rev rev_body)
          | _ -> assert false))
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
        | ( Ast.MatchCast (None, _),
            { desc = Ast.Let ([ (None, _) ], Some inner); _ } :: body ) ->
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

(* Classify how a block's trailing instruction produces the block's value, as
   [(needs_context, self_resolving)]. [needs_context] is a construction whose
   type the surrounding context must pin (an ambiguous/named/default struct, an
   array, a string, a [null] cast, or a [?:] with such a branch): it is checked
   against the result, so a surrounding result annotation is load-bearing.
   [self_resolving] resolves its own type (a nested block with no parameters, or
   a struct named unambiguously by its fields). Anything else — a plain
   statement, a parameterized block, a scalar [?:] — sets neither; a block then
   types it on the statement path rather than against its result. *)
let rec classify_trailing ctx desc =
  match desc with
  | Struct (_, fields) | StructDesc (_, fields) -> (
      match infer_struct_by_fields ctx fields with
      | Some _ -> (false, true)
      | None -> (true, false))
  | StructDefault _ | StructDefaultDesc _ | Array _ | ArrayDefault _
  | ArrayFixed _ | ArraySegment _ | String _ ->
      (true, false)
  | If { typ; _ }
  | Block { typ; _ }
  | Loop { typ; _ }
  | TryTable { typ; _ }
  | Try { typ; _ } ->
      if Array.length typ.params = 0 then (false, true) else (false, false)
  | Cast (e, _) -> (is_null_initializer e, false)
  | Select (_, a, b) ->
      (* Needs the context iff a branch does; a select is not itself a
         self-resolving nested block. *)
      ( fst (classify_trailing ctx a.desc) || fst (classify_trailing ctx b.desc),
        false )
  | _ -> (false, false)

(*** The instruction type-checker ***)

(* Set to [true] to trace each instruction as it is type-checked. *)
let debug = false

(* Deliver the values below a [br_if]/[br_on_null] operand to the branch target
   and return their fall-through result types. Shared by both branches (their only
   difference is what each appends to the result afterward: [br_on_null] adds the
   non-null reference). [types] are the delivered values' types and [params] the
   target's parameter types, both at [loc].

   When the target is a block result being inferred, each delivered value is an
   [exact] exit: its natural type — snapshotted here, before the delivery below
   pins it — must equal the block's result, not merely be a subtype. A flexible
   numeric literal among them can be pinned to a non-default width by a downstream
   op on re-parse, so the annotation is kept ([cs.needed]). On the fall-through
   the values stay typed as the target's result ([resolve_declared]); when the
   target has no declared result that cell would leak, so fall back to the
   operands' own [types]. *)
let deliver_to_branch_target ctx ~loc ~types ~params =
  if Array.length types = Array.length params then
    Array.iter2
      (fun ty param ->
        match Cell.get param with
        | Collecting cs -> (
            cs.exacts <- (Some loc, Cell.make (Cell.get ty)) :: cs.exacts;
            match Cell.get ty with
            | Number | Int | LargeInt | Float -> cs.needed <- true
            | _ -> ())
        | _ -> ())
      types params;
  check_subtypes ctx ~location:loc types params;
  (* Guard the arity as the snapshot loop does: on a mismatch [check_subtypes]
     has reported the arity error, so [map2] would only crash on the unequal
     lengths — fall back to the target's params. *)
  if
    Array.exists is_inferring params && Array.length types = Array.length params
  then
    Array.map2
      (fun ty param ->
        match Cell.get param with
        | Collecting { declared = None; _ } -> ty
        | _ -> resolve_declared param)
      types params
  else params

let rec instruction ctx i : 'a list -> 'a list * (_, _ array * _) annotated =
  if debug then Format.eprintf "%a@." Output.instr i;
  match i.desc with
  | Block _ | Dispatch _ | Match _ | Loop _ | While _ | If _ | If_annotation _
  | TryTable _ | Try _ ->
      type_block_construct ctx i
  | (Unreachable | Nop) as desc ->
      (* [unreachable] and [nop] are statements that yield no value; they are
         only meaningful in statement (top-level) position, where
         [toplevel_instruction] handles them. Reaching here means one was used
         where a value is expected, so report it and recover with an unknown
         value. *)
      Error.not_an_expression ctx.diagnostics ~location:i.info 0;
      return_expression i desc (Cell.make Error)
  | Hole ->
      let* ty = pop_parameter in
      return_expression i Hole ty
  | Null -> return_expression i Null (Cell.make Null)
  | Get _ | Set _ | Tee _ -> type_variable_access ctx i
  | Path (ns, name) ->
      Error.intrinsic_not_called ctx.diagnostics ~location:i.info ns.desc
        name.desc;
      return_expression i (Path (ns, name)) (Cell.make Error)
  | Call _ -> call_instruction ctx i
  | TailCall (i', l) -> (
      (* Type it exactly as the corresponding call — reusing the whole intrinsic
         dispatch, so [become mem.grow(n)] etc. are accepted like [mem.grow(n)]
         — then re-tag it as a tail call and require the callee's results to be
         subtypes of this function's declared results. *)
      let* typed = call_instruction ctx { i with desc = Call (i', l) } in
      match typed.desc with
      | Call (i'', l') ->
          check_subtypes ctx ~location:i.info (fst typed.info) ctx.return_types;
          return_statement i (TailCall (i'', l')) [||]
      | _ ->
          (* The target types to a non-[Call] only when typing it already
             failed: a [let*!] on a [None] lookup yields an [Unreachable] node
             typed [Error] (with the error already reported). A call that
             type-checks is always a [Call] — an ill-formed or indirect callee
             too, via [type_indirect_call] — so there is no tail call to form
             here; propagate the failed result rather than re-reporting or
             [assert false]. *)
          return typed)
  | Char _ as desc -> return_expression i desc i32_cell
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
      return_expression i desc (Cell.make lattice)
  | Float _ as desc -> return_expression i desc (Cell.make Float)
  | Cast _ | CastDesc _ | Test _ -> type_cast ctx i
  | Struct _ | StructDefault _ | StructDesc _ | StructDefaultDesc _ | Array _
  | ArrayDefault _ | ArrayFixed _ | ArraySegment _ | String _ ->
      let* i', _ = check_instruction ctx (Cell.make Unknown) i in
      return i'
  | StructGet _ | GetDescriptor _ | StructSet _ | ArrayGet _ | ArraySet _ ->
      type_aggregate_access ctx i
  | BinOp _ | UnOp _ -> type_arith ctx i
  | Let _ -> type_let ctx i
  | Br _ | Br_if _ | Br_table _ | Br_on_null _ | Br_on_non_null _ | Br_on_cast _
  | Br_on_cast_fail _ | Br_on_cast_desc_eq _ | Br_on_cast_desc_eq_fail _
  | Hinted _ ->
      type_branch ctx i
  | Throw _ | ThrowRef _ -> type_exception ctx i
  | ContNew _ | ContBind _ | Suspend _ | Resume _ | ResumeThrow _
  | ResumeThrowRef _ | Switch _ ->
      type_stack_switching ctx i
  | NonNull i' -> (
      let* i' = instruction ctx i' in
      match Cell.get (expression_type ctx i') with
      | Valtype
          {
            typ = Ref { nullable = _; typ; _ };
            internal = Ref { nullable = _; typ = ityp; _ };
            anon_comptype;
          } ->
          return_expression i (NonNull i')
            (Cell.make
               (Valtype
                  {
                    typ = Ref { nullable = false; typ };
                    internal = Ref { nullable = false; typ = ityp };
                    anon_comptype;
                  }))
      | Unknown | UnknownRef | Null ->
          (* A reference recovered from a polymorphic value — dead/branch code, a
             value already known only as a reference, or a bare [null]: the
             non-null bottom reference [UnknownRef], a subtype of every reference
             type (so it satisfies any consumer). [ref.as_non_null] of a null is
             valid Wasm (it just always traps), so a bare [null] is accepted here
             too — like [br_on_null] and [ref.is_null] on a bottom reference. *)
          return_expression i (NonNull i') (Cell.make UnknownRef)
      | Error -> return_expression i (NonNull i') (expression_type ctx i')
      | _ ->
          Error.expected_ref ctx.diagnostics ~location:(snd i'.info);
          return_expression i (NonNull i') (Cell.make Error))
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
      check_type ctx i1' i32_cell;
      let*! ty =
        let ty1 = expression_type ctx i2' in
        let ty2 = expression_type ctx i3' in
        (* A select's two branch values join exactly as the values reaching a
           block's exit do; reuse [join_value_types] and, on no common type,
           report it against the select. *)
        match join_value_types ctx ty1 ty2 with
        | Some _ as r -> r
        | None ->
            Error.select_type_mismatch ctx.diagnostics ~location:i.info
              ~loc1:i2.info ~loc2:i3.info ty1 ty2;
            None
      in
      return_expression i (Select (i1', i2', i3')) ty

and descriptor_target ctx ~location ~nullable d =
  (* The custom-descriptors casts/branches write only the descriptor operand [d];
     the target reference type is recovered from it. [d : (ref null? (exact_1 Y))]
     with [Y describes X], so the target is [(ref nullable (exact_1 X))]: the
     described type [X] and the exactness [exact_1] both come from [d], and only
     the result nullability is written (the leading [?]). Returns the typed
     operand and the recovered target reftype ([None] once an error is reported —
     [d] is not a reference to a descriptor type). *)
  let* d' = instruction ctx d in
  let target =
    match Cell.get (expression_type ctx d') with
    | Valtype { typ = Ref { typ = (Type y | Exact y) as yt; _ }; _ } -> (
        match Tbl.find_opt ctx.type_context.types y with
        | Some (_, { describes = Some x; _ }) ->
            let exact = match yt with Exact _ -> true | _ -> false in
            Some { nullable; typ = (if exact then Exact x else Type x) }
        | _ -> None)
    | _ -> None
  in
  (match target with
  | Some _ -> ()
  | None -> Error.type_without_descriptor ctx.diagnostics ~location);
  return (d', target)

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
      check_subtype ctx ~location:loc ty i32_cell;
      let params = branch_target ctx label in
      let result = deliver_to_branch_target ctx ~loc ~types ~params in
      return_statement i (Br_if (label, i')) result
  (* Branch-hinting proposal: the hint is advisory; type the wrapped branch and
     carry its result through unchanged. *)
  | Hinted (h, inner) ->
      let* inner = instruction ctx inner in
      return_statement i (Hinted (h, inner)) (fst inner.info)
  | Br_table (labels, i') ->
      let* i' = instruction ctx i' in
      let loc = snd i'.info in
      let ty, types = split_on_last_type ctx ~location:loc i' in
      check_subtype ctx ~location:loc ty i32_cell;
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
      let typ = Cell.get typ in
      let typ' =
        match typ with
        | Valtype
            {
              typ = Ref { nullable = _; typ; _ };
              internal = Ref { nullable = _; typ = ityp; _ };
              anon_comptype;
            } ->
            Cell.make
              (Valtype
                 {
                   typ = Ref { nullable = false; typ };
                   internal = Ref { nullable = false; typ = ityp };
                   anon_comptype;
                 })
        | Unknown | UnknownRef | Null ->
            (* A reference recovered from a polymorphic value, or a bare [null]
               (always null, so the branch is always taken): the non-null
               fall-through value is the bottom reference type [UnknownRef].
               Unlike [null!], this is a well-defined branch, not a contradiction
               — so a bare null is accepted here. *)
            Cell.make UnknownRef
        | Error -> Cell.make Error
        | _ ->
            Error.expected_ref ctx.diagnostics ~location:(snd i'.info);
            Cell.make Error
      in
      let loc = snd i'.info in
      let params = branch_target ctx idx in
      (* Like [br_if]: the values below the reference are delivered to the target
         and continue on the non-null fall-through, and the recovered non-null
         reference is appended. *)
      let result = deliver_to_branch_target ctx ~loc ~types ~params in
      return_statement i (Br_on_null (idx, i')) (Array.append result [| typ' |])
  | Br_on_non_null (idx, i') ->
      let* i' = instruction ctx i' in
      let params = branch_target ctx idx in
      let typ, types = split_on_last_type ctx ~location:(snd i'.info) i' in
      let typ = Cell.get typ in
      (match typ with
      | Unknown | Error | UnknownRef -> ()
      | Valtype
          {
            typ = Ref { nullable = _; typ; _ };
            internal = Ref { nullable = _; typ = ityp; _ };
            anon_comptype;
          } ->
          check_subtypes ctx ~location:(snd i'.info)
            (Array.append types
               [|
                 Cell.make
                   (Valtype
                      {
                        typ = Ref { nullable = false; typ };
                        internal = Ref { nullable = false; typ = ityp };
                        anon_comptype;
                      });
               |])
            params
      | Null ->
          (* A bare [null] is always null, so the branch is never taken; the
             popped value's non-null form is the [any]-hierarchy bottom [&none].
             (A non-[any] null keeps its [as &?H] annotation in [type_cast], so
             only [any]-hierarchy bare nulls reach here.) *)
          check_subtypes ctx ~location:(snd i'.info)
            (Array.append types
               [|
                 Cell.make
                   (Valtype
                      {
                        typ = Ref { nullable = false; typ = None_ };
                        internal = Ref { nullable = false; typ = None_ };
                        anon_comptype = None;
                      });
               |])
            params
      | _ -> Error.expected_ref ctx.diagnostics ~location:(snd i'.info));
      return_statement i
        (Br_on_non_null (idx, i'))
        (* The branch delivers [types ++ [ref]] to the target and the fall-through
           keeps all but that trailing ref. A target with no params is malformed
           (already reported by [check_subtypes] above); [max 0] avoids
           [Array.sub _ 0 (-1)] and leaves an empty fall-through. *)
        (Array.sub params 0 (max 0 (Array.length params - 1)))
  | Br_on_cast (label, ty, i') ->
      let* i' = instruction ctx i' in
      if is_cont_heaptype ctx ty.typ then
        Error.invalid_cast_type ctx.diagnostics ~location:i.info;
      let typ', types = split_on_last_type ctx ~location:(snd i'.info) i' in
      let params = branch_target ctx label in
      (let>@ ityp = reftype ctx.diagnostics ctx.type_context ty in
       let typ =
         Cell.make
           (Valtype { typ = Ref ty; internal = Ref ityp; anon_comptype = None })
       in
       check_subtypes ctx ~location:(snd i'.info)
         (Array.append types [| typ |])
         params);
      (* On success the branch carries the cast target [ty] (via [params]); the
         fall-through keeps the value at its residual type [typ2] ([ty'] minus
         [ty]). [typ1] re-types the operand as the lub of its type and [ty]. *)
      let*! typ1, typ2 =
        match Cell.get typ' with
        | Valtype { typ = Ref ty'; _ } ->
            (* The fall-through residual must be [diff(source, ty)] for the source
               [to_wasm] emits — [lub(ty, operand)] — not the operand's own [ty'];
               see the matching note in [Br_on_cast_fail]. A no-op when [ty <: ty']
               (a plain cast), where the lub is [ty']. A failed [val_lub] means
               [ty] and the operand are in different hierarchies — an invalid
               cast; report it and recover with the cast target. *)
            let ty1 =
              match val_lub ctx (Ref ty) (Ref ty') with
              | Some t -> t
              | None ->
                  Error.invalid_cast ctx.diagnostics ~location:(snd i'.info)
                    typ';
                  Ref ty
            in
            let*@ typ1 = internalize ctx ty1 in
            let+@ typ2 =
              internalize ctx
                (match ty1 with
                | Ref lub -> Ref (diff_ref_type lub ty)
                | _ -> Ref (diff_ref_type ty' ty))
            in
            (typ1, typ2)
        (* A polymorphic operand (unreachable / branch code): [to_wasm] recovers the
           source type as the cast target [ty], so the fall-through is [ty \ ty]
           (as the [Valtype] case computes with the operand's own type) — a concrete
           reference matching the emitted instruction. Not [Unknown]: the residual is
           always a reference, and not the bottom [UnknownRef] either, or a chained
           [br_on_cast] would recover a source that mismatches this one. *)
        | Unknown | UnknownRef ->
            let+@ typ2 = internalize ctx (Ref (diff_ref_type ty ty)) in
            (typ', typ2)
        | Error -> Some (typ', Cell.make Error)
        | Null ->
            (* A bare [null] operand carries no type wider than the cast target,
               so [to_wasm] reconstructs the source as [ty] made nullable and
               emits [br_on_cast (ref null H) ty]; the residual must be
               [diff(source, ty)] to match what wasm validation derives from
               those immediates. A null always matches a nullable [ty] and falls
               through, so the residual is unreachable at runtime, but wasm types
               it from the immediates, not the operand's nullness — typing it as
               the [(ref none)] bottom instead would accept programs whose
               emitted wasm the validator rejects. *)
            let source = { ty with nullable = true } in
            let*@ typ1 = internalize ctx (Ref source) in
            let+@ typ2 = internalize ctx (Ref (diff_ref_type source ty)) in
            (typ1, typ2)
        | _ ->
            Error.expected_ref ctx.diagnostics ~location:(snd i'.info);
            None
      in
      return_statement i
        (Br_on_cast
           ( label,
             ty,
             { i' with info = (Array.append types [| typ1 |], snd i'.info) } ))
        (Array.append
           (Array.sub params 0 (max 0 (Array.length params - 1)))
           [| typ2 |])
  | Br_on_cast_fail (label, ty, i') ->
      let* i' = instruction ctx i' in
      if is_cont_heaptype ctx ty.typ then
        Error.invalid_cast_type ctx.diagnostics ~location:i.info;
      let typ', types = split_on_last_type ctx ~location:(snd i'.info) i' in
      let*! ityp = reftype ctx.diagnostics ctx.type_context ty in
      (* [br_on_cast_fail] branches when the cast fails, carrying the residual
         type [typ2] ([ty'] minus [ty]) to the label; the fall-through (cast
         succeeded) carries the cast target [ty]. [typ1] re-types the operand as
         the lub of its type and [ty]. *)
      let*! typ1, typ2 =
        match Cell.get typ' with
        | Valtype { typ = Ref ty'; _ } ->
            (* [to_wasm] emits the source as [lub(ty, operand)] — widened so the
               target [ty] is a subtype of it — and wasm then derives the branch
               residual as [diff(source, ty)]. Type the residual from that same
               [lub] source, not the operand's own [ty']: otherwise, when the
               operand and target are unrelated (a chained cast whose source
               widens to their common supertype), the residual the typer feeds
               the label's join is narrower than the one the emitted instruction
               delivers, and the block infers too narrow to accept it. When
               [ty <: ty'] (a plain cast) the lub is [ty'] and this is unchanged.
               A failed [val_lub] means different hierarchies — an invalid cast;
               report it and recover with the cast target. *)
            let ty1 =
              match val_lub ctx (Ref ty) (Ref ty') with
              | Some t -> t
              | None ->
                  Error.invalid_cast ctx.diagnostics ~location:(snd i'.info)
                    typ';
                  Ref ty
            in
            let*@ typ1 = internalize ctx ty1 in
            let+@ typ2 =
              internalize ctx
                (match ty1 with
                | Ref lub -> Ref (diff_ref_type lub ty)
                | _ -> Ref (diff_ref_type ty' ty))
            in
            (typ1, typ2)
        (* A polymorphic operand: as for [br_on_cast] above, [to_wasm] recovers the
           source as the cast target [ty], so the residual sent to the branch is
           [ty \ ty] — a concrete reference matching the emitted instruction, not
           [Unknown] (the residual is always a reference) nor the bottom [UnknownRef]
           (a chained cast would then recover a mismatching source). *)
        | Unknown | UnknownRef ->
            let+@ typ2 = internalize ctx (Ref (diff_ref_type ty ty)) in
            (typ', typ2)
        | Error -> Some (typ', Cell.make Error)
        | Null ->
            (* A bare [null] operand, as in [br_on_cast] above: [to_wasm] emits
               the source as [ty] made nullable, so the residual sent to the
               branch is [diff(source, ty)] — mirroring wasm validation rather
               than the narrower [(ref none)] bottom, which would let programs
               through whose emitted wasm the validator rejects. *)
            let source = { ty with nullable = true } in
            let*@ typ1 = internalize ctx (Ref source) in
            let+@ typ2 = internalize ctx (Ref (diff_ref_type source ty)) in
            (typ1, typ2)
        | _ ->
            Error.expected_ref ctx.diagnostics ~location:(snd i'.info);
            None
      in
      let params = branch_target ctx label in
      check_subtypes ctx ~location:(snd i'.info)
        (Array.append types [| typ2 |])
        params;
      let typ =
        Cell.make
          (Valtype { typ = Ref ty; internal = Ref ityp; anon_comptype = None })
      in
      return_statement i
        (Br_on_cast_fail
           ( label,
             ty,
             { i' with info = (Array.append types [| typ1 |], snd i'.info) } ))
        (Array.append
           (Array.sub params 0 (max 0 (Array.length params - 1)))
           [| typ |])
  | Br_on_cast_desc_eq (label, nullable, i', d) ->
      (* As [br_on_cast]; the target [ty] is recovered from the descriptor
         operand [d] ([d : (ref null? (exact_1 Y))], [Y describes X] ⇒ target
         [(ref nullable (exact_1 X))]). *)
      let* d, target = descriptor_target ctx ~location:i.info ~nullable d in
      let* i' = instruction ctx i' in
      let*! ty = target in
      if is_cont_heaptype ctx ty.typ then
        Error.invalid_cast_type ctx.diagnostics ~location:i.info;
      let typ', types = split_on_last_type ctx ~location:(snd i'.info) i' in
      let params = branch_target ctx label in
      (let>@ ityp = reftype ctx.diagnostics ctx.type_context ty in
       let typ =
         Cell.make
           (Valtype { typ = Ref ty; internal = Ref ityp; anon_comptype = None })
       in
       check_subtypes ctx ~location:(snd i'.info)
         (Array.append types [| typ |])
         params);
      let*! typ1, typ2 =
        match Cell.get typ' with
        | Valtype { typ = Ref ty'; _ } ->
            (* The operand keeps its own type [typ'] (the descriptor already fixes
               the target's exactness); [ty] and the operand must share a
               supertype — a failed [val_lub] means different hierarchies. *)
            if Option.is_none (val_lub ctx (Ref ty) (Ref ty')) then
              Error.invalid_cast ctx.diagnostics ~location:(snd i'.info) typ';
            let+@ typ2 = internalize ctx (Ref (diff_ref_type ty' ty)) in
            (typ', typ2)
        | Unknown | UnknownRef ->
            let+@ typ2 = internalize ctx (Ref (diff_ref_type ty ty)) in
            (typ', typ2)
        | Error -> Some (typ', Cell.make Error)
        | _ ->
            Error.expected_ref ctx.diagnostics ~location:(snd i'.info);
            None
      in
      return_statement i
        (Br_on_cast_desc_eq
           ( label,
             nullable,
             { i' with info = (Array.append types [| typ1 |], snd i'.info) },
             d ))
        (Array.append
           (Array.sub params 0 (max 0 (Array.length params - 1)))
           [| typ2 |])
  | Br_on_cast_desc_eq_fail (label, nullable, i', d) ->
      let* d, target = descriptor_target ctx ~location:i.info ~nullable d in
      let* i' = instruction ctx i' in
      let*! ty = target in
      if is_cont_heaptype ctx ty.typ then
        Error.invalid_cast_type ctx.diagnostics ~location:i.info;
      let typ', types = split_on_last_type ctx ~location:(snd i'.info) i' in
      let*! ityp = reftype ctx.diagnostics ctx.type_context ty in
      let*! typ1, typ2 =
        match Cell.get typ' with
        | Valtype { typ = Ref ty'; _ } ->
            (* See [Br_on_cast_desc_eq]. *)
            if Option.is_none (val_lub ctx (Ref ty) (Ref ty')) then
              Error.invalid_cast ctx.diagnostics ~location:(snd i'.info) typ';
            let+@ typ2 = internalize ctx (Ref (diff_ref_type ty' ty)) in
            (typ', typ2)
        | Unknown | UnknownRef ->
            let+@ typ2 = internalize ctx (Ref (diff_ref_type ty ty)) in
            (typ', typ2)
        | Error -> Some (typ', Cell.make Error)
        | _ ->
            Error.expected_ref ctx.diagnostics ~location:(snd i'.info);
            None
      in
      let params = branch_target ctx label in
      check_subtypes ctx ~location:(snd i'.info)
        (Array.append types [| typ2 |])
        params;
      let typ =
        Cell.make
          (Valtype { typ = Ref ty; internal = Ref ityp; anon_comptype = None })
      in
      return_statement i
        (Br_on_cast_desc_eq_fail
           ( label,
             nullable,
             { i' with info = (Array.append types [| typ1 |], snd i'.info) },
             d ))
        (Array.append
           (Array.sub params 0 (max 0 (Array.length params - 1)))
           [| typ |])
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
        | Some (Ref { typ = Type ct2 | Exact ct2; _ }) ->
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
        (* Split on how many operands are still abstract ([Unknown]/[Error]).
           Both abstract: unify the two cells to the operator's default type so a
           result is still produced. One abstract: unify it onto the known
           operand's type and validate that. Both concrete (the arms below):
           just validate. The abstract arms unify operand cells in place. *)
        match (Cell.get ty1, Cell.get ty2) with
        | (Unknown | Error), (Unknown | Error) -> (
            match op.desc with
            | Add | Sub | Mul ->
                Cell.merge ty1 ty2 Number;
                ty1
            | Div (Some _) | Rem _ | And | Or | Xor | Shl | Shr _ ->
                Cell.merge ty1 ty2 Int;
                ty1
            | Lt (Some _) | Gt (Some _) | Le (Some _) | Ge (Some _) | Eq | Ne ->
                Cell.merge ty1 ty2 (Valtype i32_valtype);
                i32_cell
            | Div None ->
                Cell.merge ty1 ty2 Float;
                ty1
            | Lt None | Gt None | Le None | Ge None ->
                Cell.merge ty1 ty2 (Valtype f32_valtype);
                i32_cell)
        | typ, (Unknown | Error) | (Unknown | Error), typ -> (
            Cell.merge ty1 ty2 typ;
            match op.desc with
            | Eq | Ne ->
                (* [==]/[!=] on references are both [ref.eq] (the latter negated
                   in lowering), so they take the same operands: [eqref] or a
                   number. *)
                (match typ with
                | Valtype { internal = Ref _ as ty; _ } ->
                    if
                      not
                        (Wax_wasm.Types.val_subtype ctx.subtyping_info ty
                           (Ref { nullable = true; typ = Eq }))
                    then mismatch ()
                | Null ->
                    Cell.set ty1
                      (Valtype
                         {
                           typ = Ref { nullable = true; typ = Eq };
                           internal = Ref { nullable = true; typ = Eq };
                           anon_comptype = None;
                         })
                | Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }
                | Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }
                | Number | Int | LargeInt | Float ->
                    ()
                (* The bottom reference is [eqref], so [ref.eq] accepts it. *)
                | UnknownRef -> ()
                | _ -> mismatch ());
                i32_cell
            | Add | Sub | Mul ->
                (match typ with
                | Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }
                | Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }
                | Number | Int | LargeInt | Float ->
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
                | Number -> Cell.set ty1 Int
                (* A signed integer comparison forces a [LargeInt] operand to i64
                   (it cannot be i32, and this is an integer op), pinning it rather
                   than leaving it float-capable. *)
                | LargeInt -> Cell.set ty1 (Valtype i64_valtype)
                | _ -> mismatch ());
                i32_cell
            | Lt None | Gt None | Le None | Ge None ->
                (match typ with
                | Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }
                | Float ->
                    ()
                (* A float comparison takes a [LargeInt] operand as a float (it is
                   a numeric literal, so float-capable), like a [Number]. *)
                | Number | LargeInt -> Cell.set ty1 Float
                | _ -> mismatch ());
                i32_cell)
        | _ -> (
            match op.desc with
            | Eq | Ne ->
                (match (Cell.get ty1, Cell.get ty2) with
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
                    Cell.merge ty1 ty2 (Cell.get ty2)
                | Null, Valtype { internal = Ref _ as typ2; _ } ->
                    if
                      not
                        (Wax_wasm.Types.val_subtype ctx.subtyping_info typ2
                           (Ref { nullable = true; typ = Eq }))
                    then mismatch ();
                    Cell.merge ty1 ty2 (Cell.get ty2)
                (* [ref.eq] needs both operands [eqref]; the bottom reference
                   [UnknownRef] always is, so only a concrete side is checked. *)
                | Valtype { internal = Ref _ as ty; _ }, UnknownRef
                | UnknownRef, Valtype { internal = Ref _ as ty; _ } ->
                    if
                      not
                        (Wax_wasm.Types.val_subtype ctx.subtyping_info ty
                           (Ref { nullable = true; typ = Eq }))
                    then mismatch ()
                | UnknownRef, (UnknownRef | Null) | Null, UnknownRef -> ()
                (* Any non-reference operands are the ordinary numeric comparison.
                   [check_num_concrete] reports the same mismatch otherwise. *)
                | _ -> check_num_concrete ctx ~location:op.info ty1 ty2);
                i32_cell
            | Add | Sub | Mul ->
                check_num_concrete ctx ~location:op.info ty1 ty2;
                ty1
            | Div (Some _) | Rem _ | And | Or | Xor | Shl | Shr _ ->
                check_int_bin_op ctx ~location:op.info ty1 ty2
            | Div None -> check_float_bin_op ctx ~location:op.info ty1 ty2
            | Lt (Some _) | Gt (Some _) | Le (Some _) | Ge (Some _) ->
                ignore (check_int_bin_op ctx ~location:op.info ty1 ty2);
                i32_cell
            | Lt None | Gt None | Le None | Ge None ->
                ignore (check_float_bin_op ctx ~location:op.info ty1 ty2);
                i32_cell)
      in
      if ctx.warn_unused then begin
        lint_shift ctx op ty i2';
        lint_division ctx op i2';
        lint_comparison ctx op i1' i2'
      end;
      return_expression i (BinOp (op, i1', i2')) ty
  | UnOp (op, i') ->
      let* i' = instruction ctx i' in
      let typ = expression_type ctx i' in
      let ty =
        match Cell.get typ with
        | Unknown | Error -> (
            match op.desc with Not -> i32_cell | Neg | Pos -> Cell.make Number)
        | _ -> (
            match op.desc with
            | Not ->
                (match Cell.get typ with
                (* [!] is [i32.eqz] on an integer and [ref.is_null] on a
                   reference; [UnknownRef] is a (bottom) reference, so it takes
                   the [ref.is_null] reading like any other ref. *)
                | Valtype { internal = I32 | I64 | Ref _; _ }
                | Null | Int | UnknownRef ->
                    ()
                | Number -> Cell.set typ Int
                (* [!] on a [LargeInt] is [i64.eqz]; pin it to i64 so it cannot be
                   left float-capable (there is no float [eqz]). *)
                | LargeInt -> Cell.set typ (Valtype i64_valtype)
                | _ ->
                    Error.instruction_type_mismatch ctx.diagnostics
                      ~location:op.info typ (Cell.make Int));
                i32_cell
            | Neg | Pos ->
                (match Cell.get typ with
                | Valtype { internal = I32 | I64 | F32 | F64; _ }
                | Int | LargeInt | Float | Number ->
                    ()
                | _ ->
                    Error.instruction_type_mismatch ctx.diagnostics
                      ~location:op.info typ (Cell.make Number));
                typ)
      in
      return_expression i (UnOp (op, i')) ty
  | _ -> assert false (* only invoked on BinOp/UnOp *)

and type_cast ctx i =
  (* Type casts ([e as t]) and type tests ([e is t]). *)
  match i.desc with
  | Cast (i', typ) ->
      let* i' = instruction ctx i' in
      if ctx.warn_unused then lint_conversion ctx ~location:i.info typ i';
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
        match Cell.get (expression_type ctx e) with
        | Int8 | Int16 -> true
        | _ -> false
      in
      let is_ref e =
        match Cell.get (expression_type ctx e) with
        | Valtype { internal = Ref _; _ } -> true
        | _ -> false
      in
      (* A non-[i31] reference in the [any] hierarchy — the operand of a plain
         [ref.cast] to [&i31]. [extern]/[noextern] are excluded: [e as &i31] for an
         [extern] is not a [ref.cast] but a cross-hierarchy convert then cast
         ([any.convert_extern]; [ref.cast]), so fusing it with a trailing [i31.get]
         into [e as i32] would leave an untranslatable [&extern as i32]. *)
      let is_non_i31_ref e =
        match Cell.get (expression_type ctx e) with
        | Valtype { internal = Ref { typ = I31 | Extern | NoExtern; _ }; _ } ->
            false
        | Valtype { internal = Ref _; _ } -> true
        | _ -> false
      in
      let is_i64 e =
        match Cell.get (expression_type ctx e) with
        | Valtype { internal = I64; _ } -> true
        | _ -> false
      in
      let is_i32 e =
        match Cell.get (expression_type ctx e) with
        | Valtype { internal = I32; _ } -> true
        | _ -> false
      in
      let is_extern e =
        match Cell.get (expression_type ctx e) with
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
      let ty'_natural = Cell.get ty' in
      (* [extern.convert_any]/[any.convert_extern] preserve non-nullness, so a
         cast to [&?extern]/[&?any] of a non-nullable argument actually yields
         [&extern]/[&any]; refine the target accordingly. Like the
         redundant-cast removal below, this only applies when converting from
         Wasm ([ctx.simplify]); otherwise the cast is kept as written. *)
      let arg_non_nullable =
        match Cell.get ty' with
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
        | Null | UnknownRef | Valtype _ | Unknown | Error | Collecting _ -> None
      in
      let load_bearing_literal =
        match (natural_typ, Cell.get ty) with
        | Some d, Valtype { typ; _ } -> d <> typ
        | _ -> false
      in
      (* A cast of a bare [null] to a non-[any]-hierarchy reference is also load
         bearing: dropping it leaves a bare [null], whose non-null / branch
         consumers ([null!], [br_on_*]) fall back to the [any]-hierarchy bottom
         [&none] — not a subtype of a func/extern/exn/cont type — so the
         reconstructed module no longer type-checks. (An [any]-hierarchy null is
         safe to drop: [&none] satisfies every [any]-hierarchy consumer.) *)
      let load_bearing_null =
        match (ty'_natural, Cell.get ty) with
        | Null, Valtype { typ = Ref { typ = ht; _ }; _ } ->
            top_heap_type ctx ht <> Some Any
        | _ -> false
      in
      (* Likewise a cast of a bottom reference (the residual of a polymorphic
         [br_on_cast] in dead code, or [ref.null nofunc]) to a type the bottom
         cannot stand in for. The bottom heap type carries no usable type, so
         dropping the cast leaves a value that no longer names one: a [(ref
         nofunc)] feeding [call_ref] has no function type to resolve (any
         non-[any]-hierarchy target), and — even in the [any] hierarchy — a
         bottom [&none] feeding a struct/array field access ([s.f], [a[i]])
         names no concrete type for the field to resolve against (Wasm's
         [struct.get] carries the type index; Wax's [.f] recovers it from the
         receiver). An *abstract* [any]-hierarchy target ([any]/[eq]/[struct]/…)
         is still safe: [&none] satisfies those consumers. *)
      let load_bearing_bottom_ref =
        match (ty'_natural, Cell.get ty) with
        | ( Valtype { typ = Ref { typ = bot; _ }; _ },
            Valtype { typ = Ref { typ = ht; _ }; _ } )
          when is_bottom_heaptype bot && not (is_bottom_heaptype ht) -> (
            top_heap_type ctx ht <> Some Any
            || match ht with Type _ -> true | _ -> false)
        | _ -> false
      in
      (* Drop a cast the inferred types already make redundant. This is only
         desirable when converting from Wasm ([ctx.simplify]): there casts are
         inserted to pin types and precise inference makes some unnecessary. For
         hand-written Wax (formatting, or compiling to Wasm) we keep casts as
         written.
         ZZZ Handle select instruction better *)
      let unnecessary_cast =
        ctx.simplify && (not load_bearing_literal) && (not load_bearing_null)
        && (not load_bearing_bottom_ref)
        && (not (is_unknown_or_error ty'))
        && subtype ctx ty' ty
      in
      if unnecessary_cast then return { i' with info = ([| ty |], snd i'.info) }
      else return_expression i (Cast (i', typ)) ty
  | CastDesc (value, nullable, d) ->
      (* [value as [?]descriptor(d)]: a descriptor-equality cast. The target type
         is recovered from [d] ([d : (ref null? (exact_1 Y))], [Y describes X] ⇒
         target [(ref nullable (exact_1 X))]). *)
      let* value' = instruction ctx value in
      let* d', target = descriptor_target ctx ~location:i.info ~nullable d in
      let*! t = target in
      let*! ty = internalize ctx (Ref t) in
      let ty' = expression_type ctx value' in
      if not (cast ctx ty' (Ref t)) then
        Error.invalid_cast ctx.diagnostics ~location:i.info ty';
      return_expression i (CastDesc (value', nullable, d')) ty
  | Test (i, ty) ->
      let* i' = instruction ctx i in
      if is_cont_heaptype ctx ty.typ then
        Error.invalid_cast_type ctx.diagnostics ~location:i.info;
      (let>@ typ = top_heap_type ctx ty.typ in
       let>@ typ = internalize ctx (Ref { nullable = true; typ }) in
       check_type ctx i' typ);
      return_expression i (Test (i', ty)) i32_cell
  (* Construction literals carry an optional type name that can be inferred from
     an expected type. Their typing lives in [check_instruction]; in synthesis position
     there is no expectation, so [check_instruction] against the [Unknown] sentinel keeps a
     present name and reports [cannot_infer_*] when one is omitted. *)
  | _ -> assert false (* only invoked on Cast/Test *)

and type_aggregate_access ctx i =
  (* Field and element access: struct field reads/writes ([s.f], [s.f = v]) and
     array or table indexing ([a[i]], [a[i] = v]). *)
  match i.desc with
  | StructGet (i', field) ->
      let* i' = instruction ctx i' in
      let*! ty =
        let ty = expression_type ctx i' in
        match (Cell.get ty, field.desc) with
        | Valtype { typ = Ref { typ = Type ty | Exact ty; _ }; _ }, _ -> (
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
        | Error, _ -> Some (Cell.make Error)
        (* The receiver's type is unknown (unreachable / branch code) or only a
           reference (its struct type cannot be resolved), so the field cannot
           be read. *)
        | (Unknown | UnknownRef), _ ->
            Error.unknown_operand_type ctx.diagnostics ~location:(snd i'.info);
            Some (Cell.make Error)
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
  | GetDescriptor i' ->
      let* i' = instruction ctx i' in
      let*! ty =
        match Cell.get (expression_type ctx i') with
        | Valtype { typ = Ref { typ = (Type ty | Exact ty) as ht; _ }; _ } -> (
            let exact = match ht with Exact _ -> true | _ -> false in
            let*@ _, def = Tbl.find_opt ctx.type_context.types ty in
            match def.descriptor with
            | None ->
                Error.type_without_descriptor ctx.diagnostics
                  ~location:(snd i'.info);
                None
            | Some descname ->
                internalize ctx
                  (Ref
                     {
                       nullable = false;
                       typ = (if exact then Exact descname else Type descname);
                     }))
        | Error -> Some (Cell.make Error)
        | Unknown | UnknownRef ->
            Error.unknown_operand_type ctx.diagnostics ~location:(snd i'.info);
            Some (Cell.make Error)
        | _ ->
            Error.expected_struct_type ctx.diagnostics ~location:(snd i'.info);
            None
      in
      return_expression i (GetDescriptor i') ty
  | StructSet (i1, field, i2) ->
      let* i1' = instruction ctx i1 in
      (* Resolve the field's declared type (pure, reporting any field error)
         before typing the value, so the value can be checked against it and a
         struct/array literal can drop its name. The value is then typed on
         every path, so its holes are always consumed. *)
      let expected =
        match Cell.get (expression_type ctx i1') with
        | Valtype { typ = Ref { typ = Type ty | Exact ty; _ }; _ } -> (
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
        | Unknown | UnknownRef ->
            (* The receiver's type is unknown (unreachable / branch code) or
               only a reference (its struct type cannot be resolved), so the
               field cannot be written. *)
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
    when table_receiver ctx tabname ->
      let at, rt = Option.get (Tbl.find_opt ctx.tables tabname) in
      let* i2' = instruction ctx i2 in
      check_type ctx i2' (address_cell at);
      let*! typ = internalize ctx (Ref rt) in
      return_expression i
        (ArrayGet ({ desc = Get tabname; info = ([||], recv.info) }, i2'))
        typ
  | ArrayGet (i1, i2) -> (
      let* i1' = instruction ctx i1 in
      let* i2' = instruction ctx i2 in
      check_type ctx i2' i32_cell;
      match Cell.get (expression_type ctx i1') with
      | Valtype { typ = Ref { typ = Type ty | Exact ty; _ }; _ } ->
          let*! typ = lookup_array_type ~location:i1.info ctx ty in
          let*! ty = field_read_type ctx typ in
          return_expression i (ArrayGet (i1', i2')) ty
      | Error ->
          (* Receiver already failed to type; recover silently. *)
          return_expression i (ArrayGet (i1', i2')) (Cell.make Error)
      | Unknown | UnknownRef ->
          (* The receiver's type is unknown (unreachable / branch code) or only
             a reference (its array type cannot be resolved), so the element
             cannot be read. *)
          Error.unknown_operand_type ctx.diagnostics ~location:i1.info;
          return_expression i (ArrayGet (i1', i2')) (Cell.make Error)
      | _ ->
          Error.expected_array_type ctx.diagnostics ~location:i1.info;
          return_expression i (ArrayGet (i1', i2')) (Cell.make Error))
  (* [tab[i] = v] on a table name is [table.set]; the receiver is not a value. *)
  | ArraySet (({ desc = Get tabname; _ } as recv), i2, i3)
    when table_receiver ctx tabname ->
      let at, rt = Option.get (Tbl.find_opt ctx.tables tabname) in
      let* i2' = instruction ctx i2 in
      check_type ctx i2' (address_cell at);
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
      check_type ctx i2' i32_cell;
      match Cell.get (expression_type ctx i1') with
      | Valtype { typ = Ref { typ = Type ty | Exact ty; _ }; _ } ->
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
      | Unknown | UnknownRef ->
          (* The receiver's type is unknown (unreachable / branch code) or only
             a reference (its array type cannot be resolved), so the element
             cannot be written. Still type the value so its holes are
             consumed. *)
          let* i3' = instruction ctx i3 in
          Error.unknown_operand_type ctx.diagnostics ~location:i1.info;
          return_statement i (ArraySet (i1', i2', i3')) [||]
      | _ ->
          let* i3' = instruction ctx i3 in
          Error.expected_array_type ctx.diagnostics ~location:i1.info;
          return_statement i (ArraySet (i1', i2', i3')) [||])
  | _ -> assert false (* only invoked on a struct/array access *)

and type_variable_access ctx i =
  (* Reading and assigning a local or global: [x] ([Get]), [x = v] ([Set]) and
     the tee form [Tee] that also leaves the value on the stack. *)
  match i.desc with
  | Get idx as desc ->
      let ty =
        match resolve_variable ctx idx with
        | Local ty ->
            ctx.read_locals := StringSet.add idx.desc !(ctx.read_locals);
            if not (StringSet.mem idx.desc ctx.initialized_locals) then
              Error.uninitialized_local ctx.diagnostics ~location:idx.info idx;
            (* A poison local ([None]) reads as [Error] so its uses don't
               cascade. *)
            Cell.make (match ty with Some ity -> Valtype ity | None -> Error)
        | Global (_, ty) ->
            Cell.make (match ty with Some ity -> Valtype ity | None -> Error)
        | Func_ref (ty, ty', exact) ->
            let name = Ast.no_loc ty' in
            Cell.make
              (Valtype
                 {
                   typ =
                     Ref
                       {
                         nullable = false;
                         typ = (if exact then Exact name else Type name);
                       };
                   internal =
                     Ref
                       {
                         nullable = false;
                         typ = (if exact then Exact ty else Type ty);
                       };
                   anon_comptype = inline_comptype ctx name;
                 })
        | Unbound ->
            Error.unbound_name ctx.diagnostics ~location:idx.info
              ~suggestions:(get_suggestions ctx idx.desc)
              "variable" idx;
            Cell.make Error
      in
      return_expression i desc ty
  | Set (idx, op, i') ->
      (* Resolve the target first (a pure lookup) so the value can be checked
         against its type, letting a struct/array literal drop its name. The
         local is marked initialized only after the value is typed, so an
         assignment reading the same local (e.g. [x = x + 1]) still sees its
         pre-assignment state. *)
      let resolved = resolve_variable ctx idx in
      (* A compound assignment [x op= e] is type-checked as [x = x op e]: reading
         [x] requires it to be initialized already, and the operator is validated
         against its type by the ordinary [BinOp] path. The compound form is kept
         in the typed AST (so it round-trips and lowers back to a get/op/set); the
         typed right-hand side is the [BinOp]'s second operand. *)
      let to_check =
        match op with
        | None -> i'
        | Some op ->
            { i' with desc = BinOp (op, { idx with desc = Get idx }, i') }
      in
      let* checked =
        match resolved with
        | Local (Some ity) | Global (_, Some ity) ->
            let* c, _ = check_instruction ctx (valtype_cell ity) to_check in
            return c
        | Local None | Global (_, None) | Func_ref _ | Unbound ->
            instruction ctx to_check
      in
      let value =
        match (op, checked.desc) with
        | None, _ -> checked
        (* A numeric [BinOp] is never wrapped by [check_instruction], so its typed
           right operand is recoverable directly. *)
        | Some _, BinOp (_, _, rhs) -> rhs
        | Some _, _ -> assert false
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
      return_statement i (Set (idx, op, value)) [||]
  | Tee (idx, i') -> (
      (* Only a local is assignable. Resolve it first so the value can be
         checked against the local's type (letting a struct/array literal drop
         its name); anything else is an error, after which we recover with the
         operand's own type rather than [Unknown], which [check_type] cannot
         match against. *)
      match resolve_variable ctx idx with
      | Local (Some ity) ->
          let typ = valtype_cell ity in
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
  | _ -> assert false (* only invoked on Get/Set/Tee *)

and type_let ctx i =
  (* Let bindings: a single annotated binding, a multi-value binding, and a bare
     declaration ([let x: t;]). *)
  match i.desc with
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
            check_instruction ~drop_supertype ctx (valtype_cell ity) i'
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
                  else Cell.make Error
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
  | _ -> assert false (* only invoked on Let *)

and type_exception ctx i =
  (* Raising exceptions: [throw tag(..)] ([Throw]) and re-raising a caught
     exnref ([ThrowRef]). *)
  match i.desc with
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
  | _ -> assert false (* only invoked on Throw/ThrowRef *)

and type_block_construct ctx i =
  (* The block-like control constructs (block, loop, while, if, dispatch, match,
     try, try_table), which type their bodies and results through the
     block-inference helpers. *)
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
  | While { label; cond; step; block = instrs } ->
      (* Type-check the equivalent loop (see [Ast_utils.lower_while]): this
         validates that [cond] is an [i32], the continue-expression and body are
         well-typed, and — for a labelled step — that a [br] to the loop label
         (continue) runs the step. Then rebuild a typed [While], keeping the
         high-level form for the formatter and for the identical re-lowering in
         [To_wasm]. *)
      let lowered =
        Ast_utils.lower_while ~block_info:i.info
          ~fresh_loop:(Ast.no_loc Ast_utils.synthetic_loop_label)
          ~label ~cond ~step ~block:instrs
      in
      let typed = block ctx i.info None [||] [||] [||] lowered in
      let cond', step', instrs' =
        rebuild_while ~stepped:(step <> None) ~labelled:(label <> None) typed
      in
      return_statement i
        (While { label; cond = cond'; step = step'; block = instrs' })
        [||]
  | If { label; typ; cond; if_block; else_block } -> (
      let* cond' = instruction ctx cond in
      check_type ctx cond' i32_cell;
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
  | _ -> assert false (* only invoked on a block-like construct *)

and type_mem_method_call ctx i func recv memname meth args =
  let _, address_type = Option.get (Tbl.find_opt ctx.memories memname) in
  let addr_vt = address_cell address_type in
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
            | "store64" -> check_type ctx value' i64_cell
            | "storef32" -> check_type ctx value' f32_cell
            | "storef64" -> check_type ctx value' f64_cell
            | _ -> (
                match Cell.get vty with
                | Valtype { internal = I32 | I64; _ }
                | Int | Number | LargeInt | Unknown | Error ->
                    (* A narrowing store ([store8]/[store16]/[store32]) wraps, so
                       it also accepts an i64-wide value, including a [LargeInt]
                       literal too big for i32. *)
                    ()
                | _ ->
                    Error.instruction_type_mismatch ctx.diagnostics
                      ~location:(snd value'.info) vty (Cell.make Int)))
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
      | Some t -> [| Cell.make t |]
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

and type_atomic_method_call ctx i func recv memname meth op args =
  let _, address_type = Option.get (Tbl.find_opt ctx.memories memname) in
  let vt_cell = function
    | `I32 -> valtype_cell i32_valtype
    | `I64 -> valtype_cell i64_valtype
  in
  let operands, results = Wax_wasm.Atomics.signature op in
  (* The address, then the value operands; then optional align/offset literals. *)
  let nstack = 1 + List.length operands in
  let* args' = instructions ctx args in
  let nargs = List.length args' in
  if nargs < nstack || nargs > nstack + 2 then
    Error.value_count_mismatch ctx.diagnostics ~location:i.info ~expected:nstack
      ~provided:nargs;
  (match args' with
  | addr' :: rest ->
      check_type ctx addr' (address_cell address_type);
      List.iteri
        (fun k t ->
          match List.nth_opt rest k with
          | Some a -> check_type ctx a (vt_cell t)
          | None -> ())
        operands
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
  let natural = 1 lsl Wax_wasm.Atomics.natural_align_log2 op in
  (* Only the offset immediate is range-checked here; an atomic access requires
     exactly its natural alignment, not merely at most, so check that below. *)
  check_memarg ctx ~address_type ~natural ~align:None
    ~offset:(List.nth_opt args' (nstack + 1));
  (match List.nth_opt args' nstack with
  | Some a -> (
      match int_literal a with
      | Some v
        when Wax_utils.Uint64.compare v (Wax_utils.Uint64.of_int natural) = 0 ->
          ()
      | _ ->
          Error.atomic_alignment ctx.diagnostics ~location:(snd a.info) natural)
  | None -> ());
  let result = match results with [] -> [||] | t :: _ -> [| vt_cell t |] in
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
  let addr_vt = address_cell address_type in
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
     let max_lane = 16 / mop.m_nat_align in
     (* Compare unsigned, and reject an [Ast.Int] too large even for [u64]
        ([int_literal] = [None]): otherwise it slips past this check and crashes
        [to_wasm]'s [int_of_string] (as for the SIMD lane index in
        [type_simd_method_call]). A non-constant lane is reported above. *)
     match lane.desc with
     | Ast.Int _ -> (
         match int_literal lane with
         | Some l
           when Wax_utils.Uint64.compare l (Wax_utils.Uint64.of_int max_lane)
                < 0 ->
             ()
         | _ ->
             Error.invalid_lane_index ctx.diagnostics ~location:(snd lane.info)
               max_lane)
     | _ -> ());
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
  let addr () = address_cell at in
  let i32 () = i32_cell in
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
    when memory_receiver ctx src ->
      let src_at =
        match Tbl.find_opt ctx.memories src with Some (_, a) -> a | None -> at
      in
      let addr_of a = address_cell a in
      (* The length [n] indexes both the source and destination, so it is typed
         at the narrower of the two address types ([I32] if either is 32-bit). *)
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
  let addr () = address_cell at in
  let i32 () = i32_cell in
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
    when table_receiver ctx src ->
      let src_at =
        match Tbl.find_opt ctx.tables src with
        | Some (a, src_rt) ->
            check_elem_subtype ctx ~location:i.info ~src:src_rt ~dst:rt;
            a
        | None -> at
      in
      let addr_of a = address_cell a in
      (* The length [n] indexes both the source and destination, so it is typed
         at the narrower of the two address types ([I32] if either is 32-bit). *)
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
  check_type ctx n' i32_cell;
  check_type ctx j' i32_cell;
  (match Cell.get (expression_type ctx a') with
  | Valtype { typ = Ref { typ = Type ty | Exact ty; _ }; _ } ->
      let>@ typ = lookup_array_type ~location:a.info ctx ty in
      if not typ.mut then
        Error.immutable ctx.diagnostics ~location:a.info "array";
      let>@ ty = internalize ctx (unpack_type typ) in
      let ty' = expression_type ctx v' in
      if not (subtype ctx ty' ty) then
        Error.instruction_type_mismatch ctx.diagnostics ~location:(snd v'.info)
          ty' ty
  | Error -> (* receiver already failed to type; recover silently *) ()
  | Unknown | UnknownRef ->
      (* The receiver's type is unknown (unreachable / branch code) or only a
         reference (its array type cannot be resolved), so the operation cannot
         be compiled. *)
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
  check_type ctx n' i32_cell;
  check_type ctx i2' i32_cell;
  let ty' = expression_type ctx a2' in
  check_type ctx i1' i32_cell;
  let ty = expression_type ctx a1' in
  (match (Cell.get ty, Cell.get ty') with
  (* Either array already failed to type; recover silently. *)
  | Error, _ | _, Error -> ()
  (* An array's type is unknown (unreachable / branch code): its element type
     cannot be resolved, so the copy cannot be compiled. Point at the offending
     array. *)
  | (Unknown | UnknownRef), _ ->
      Error.unknown_operand_type ctx.diagnostics ~location:a1.info
  | _, (Unknown | UnknownRef) ->
      Error.unknown_operand_type ctx.diagnostics ~location:a2.info
  | ( Valtype { typ = Ref { typ = Type ty | Exact ty; _ }; _ },
      Valtype { typ = Ref { typ = Type ty' | Exact ty'; _ }; _ } ) ->
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
  let i32 = i32_cell in
  (match rest' with
  | [ d'; s'; n' ] ->
      check_type ctx d' i32;
      check_type ctx s' i32;
      check_type ctx n' i32
  | _ -> ());
  (match Cell.get (expression_type ctx a') with
  | Valtype { typ = Ref { typ = Type ty | Exact ty; _ }; _ } -> (
      let>@ field = lookup_array_type ~location:a.info ctx ty in
      if not field.mut then
        Error.immutable ctx.diagnostics ~location:a.info "array";
      match field.typ with
      | Value (Ref dst) ->
          let>@ src = Tbl.find ctx.diagnostics ctx.elems seg in
          check_elem_subtype ctx ~location:a.info ~src ~dst
      | _ -> ignore (Tbl.find ctx.diagnostics ctx.datas seg : unit option))
  | Error -> (* receiver already failed to type; recover silently *) ()
  | Unknown | UnknownRef ->
      (* The receiver's type is unknown (unreachable / branch code) or only a
         reference (its array type cannot be resolved), so the operation cannot
         be compiled. *)
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
  let ty1 = expression_type ctx i1' in
  let ty2 = expression_type ctx i2' in
  let is_int = match op with "rotl" | "rotr" -> true | _ -> false in
  let check ty1 ty2 =
    if is_int then check_int_bin_op ctx ~location:meth.info ty1 ty2
    else check_float_bin_op ctx ~location:meth.info ty1 ty2
  in
  (* An abstract operand (a hole on the polymorphic stack of unreachable / branch
     code) is unified onto the other operand's type; two abstract operands take the
     operator's family default (int for [rotl]/[rotr], float for
     [copysign]/[min]/[max]). [check_int_bin_op]/[check_float_bin_op] leave the
     [Unknown]/[Error] arms to their caller, as the [BinOp] arms of [type_arith] do. *)
  let ty =
    match (Cell.get ty1, Cell.get ty2) with
    | (Unknown | Error), (Unknown | Error) ->
        Cell.merge ty1 ty2 (if is_int then Int else Float);
        ty1
    | (Unknown | Error), _ ->
        Cell.merge ty1 ty2 (Cell.get ty2);
        check ty1 ty2
    | _, (Unknown | Error) ->
        Cell.merge ty1 ty2 (Cell.get ty1);
        check ty1 ty2
    | _ -> check ty1 ty2
  in
  return_expression i
    (Call ({ desc = StructGet (i1', meth); info = ([||], func.info) }, [ i2' ]))
    ty

and type_unary_intrinsic_call ctx i func recv meth =
  let* recv' = instruction ctx recv in
  let*! ty =
    let ty = expression_type ctx recv' in
    match (Cell.get ty, meth.desc) with
    | Valtype { typ = Ref { typ = Type t | Exact t; _ }; _ }, "length" -> (
        let*@ _, def = Tbl.find_opt ctx.type_context.types t in
        match def.typ with
        | Array _ -> Some i32_cell
        | Struct _ | Func _ | Cont _ ->
            Error.expected_array_type ctx.diagnostics ~location:i.info;
            None)
    (* [array.len] accepts any subtype of [(ref null array)]: the abstract
       array, a bare [null], and the bottom reference [&none] (which is below
       [array]). A concrete array is handled above. *)
    | (Null | Valtype { typ = Ref { typ = Array | None_; _ }; _ }), "length" ->
        Some i32_cell
    | Valtype { typ = I32; _ }, "from_bits" -> Some f32_cell
    | Valtype { typ = I64; _ }, "from_bits" -> Some f64_cell
    | Valtype { typ = F32; _ }, "to_bits" -> Some i32_cell
    | Valtype { typ = F64; _ }, "to_bits" -> Some i64_cell
    (* An abstract numeric receiver (e.g. a bare float literal whose redundant
       cast [simplify] dropped) defaults like any other operation: [to_bits] on a
       [Float] is f64->i64, [from_bits] on an integer is i32->f32 (or i64->f64
       for a [LargeInt]). The non-default widths keep their cast (load-bearing),
       so they reach the concrete arms above. A fully-polymorphic [Unknown]
       receiver (a value taken off the polymorphic stack of unreachable code) is
       resolved the same way: the method alone fixes the int/float family, so it
       defaults to that family's natural width rather than failing to compile.
       [to_bits] needs a float receiver, so an integer-valued float constant
       decompiled to a bare integer literal ([Number]/[LargeInt]) coerces to
       [f64] too (like the [LargeInt] coercion in a float binop). A receiver
       already committed to the integer family ([Int], e.g. the result of
       [clz]/[extend8_s]) is *not* coerced: [to_bits] on an integer is
       meaningless, and coercing its shared cell to [f64] would make the
       integer-producing operation below it lower against an [f64] operand. It
       falls through to the receiver-type error, mirroring [from_bits] rejecting
       a [Float] receiver. *)
    | (Float | Number | LargeInt | Unknown), "to_bits" ->
        Cell.set ty (Valtype f64_valtype);
        Some i64_cell
    | (Number | Int | Unknown), "from_bits" ->
        Cell.set ty (Valtype i32_valtype);
        Some f32_cell
    | LargeInt, "from_bits" ->
        Cell.set ty (Valtype i64_valtype);
        Some f64_cell
    | ( ((Number | Int | LargeInt | Unknown | Valtype { typ = I32 | I64; _ }) as
         ty'),
        ("clz" | "ctz" | "popcnt" | "extend8_s" | "extend16_s") ) ->
        if ty' = Number || ty' = Unknown then Cell.set ty Int
        else if ty' = LargeInt then Cell.set ty (Valtype i64_valtype);
        Some ty
    | ( ((Number | Float | Unknown | LargeInt | Valtype { typ = F32 | F64; _ })
         as ty'),
        ("abs" | "ceil" | "floor" | "trunc" | "nearest" | "sqrt") ) ->
        (* A [LargeInt] receiver is a float here (a float intrinsic), like a
           [Number]/[Unknown] one. *)
        if ty' = Number || ty' = Unknown || ty' = LargeInt then
          Cell.set ty Float;
        Some ty
    | Error, _ -> Some (Cell.make Error)
    | (Unknown | UnknownRef), _ ->
        (* The receiver is only a reference (its method cannot be resolved), or it
           is [Unknown] with a method that fixes no numeric family, so the call
           cannot be compiled. *)
        Error.unknown_operand_type ctx.diagnostics ~location:(snd recv'.info);
        Some (Cell.make Error)
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
      if k < nimm then
        (* A lane immediate must be a constant integer in range. Unsigned
           compare, and reject an [Ast.Int] too large even for [u64]
           ([int_literal] = [None]) — otherwise it reaches [to_wasm]'s
           [int_of_string] and crashes (as for the memory lane index in
           [type_simd_mem_method_call]). *)
        match a.desc with
        | Ast.Int _ -> (
            let>@ bound = lane_bound in
            match int_literal a with
            | Some l
              when Wax_utils.Uint64.compare l (Wax_utils.Uint64.of_int bound)
                   < 0 ->
                ()
            | _ ->
                Error.invalid_lane_index ctx.diagnostics ~location:(snd a.info)
                  bound)
        | _ ->
            Error.constant_expression_required ctx.diagnostics
              ~location:(snd a.info)
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

and type_simd_free_intrinsic_call ctx i func ns name args =
  let full = Simd.free_full name.desc in
  let callee = { desc = Path (ns, name); info = ([||], func.info) } in
  let* args' = instructions ctx args in
  if not (Simd.is_free_intrinsic full) then (
    Error.unknown_intrinsic ctx.diagnostics ~location:i.info ns.desc name.desc;
    return_expression i (Call (callee, args')) (Cell.make Error))
  else (
    (match Simd.const_shape_of_name full with
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
                   Int64.unsigned_compare v
                     (Int64.sub (Int64.shift_left 1L b) 1L)
                   <= 0
           in
           fun a ->
             match (bits, a.desc) with
             | Some b, Ast.Int _ ->
                 if not (lane_in_range b false a) then
                   Error.lane_value_out_of_range ctx.diagnostics
                     ~location:(snd a.info) b
             | ( Some b,
                 Ast.UnOp ({ desc = Neg; _ }, ({ desc = Ast.Int _; _ } as l)) )
               ->
                 if not (lane_in_range b true l) then
                   Error.lane_value_out_of_range ctx.diagnostics
                     ~location:(snd a.info) b
             | ( Some b,
                 ( Ast.Float _
                 | Ast.UnOp ({ desc = Neg; _ }, { desc = Ast.Float _; _ }) ) )
               ->
                 (* a float literal is not a valid integer lane *)
                 Error.lane_value_out_of_range ctx.diagnostics
                   ~location:(snd a.info) b
             | ( None,
                 ( Ast.Int _ | Ast.Float _
                 | Ast.UnOp
                     ({ desc = Neg; _ }, { desc = Ast.Int _ | Ast.Float _; _ })
                   ) ) ->
                 () (* a float shape accepts any numeric literal lane *)
             | _ ->
                 Error.constant_expression_required ctx.diagnostics
                   ~location:(snd a.info))
          args'
    | None -> List.iter (fun a -> check_type ctx a (simd_cell TV128)) args');
    return_expression i (Call (callee, args')) (simd_cell TV128))

(* Bidirectional checking mode: type [i] against an [expected] type and report
   whether the contextual annotation is load-bearing (the keep-bool). A
   construction literal can fill an omitted type name from [expected] and shed a
   redundant one; every other expression delegates to [instruction] and reports
   whether it determined its own type. [expected] is the [Unknown] sentinel when
   [check_instruction] is entered from [instruction] with no context (synthesis). *)
and check_instruction ?(drop_supertype = false) ctx expected
    (i : location instr) =
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
    (* A concrete allocator ([struct.new] / [array.new*]) yields an *exact*
       reference at the Wasm level. We type it exact only when custom-descriptors
       is enabled (exact reference types are part of that proposal); otherwise it
       is the plain inexact reference, as before the proposal. *)
    let want_exact =
      Wax_utils.Feature.is_enabled ctx.type_context.features
        Wax_utils.Feature.Custom_descriptors
    in
    let result =
      internalize ?inline:(inline_comptype ctx name) ctx
        (Ref
           {
             nullable = false;
             typ = (if want_exact then Exact name else Type name);
           })
    in
    Option.iter
      (fun result ->
        if has_expectation expected then
          check_subtype ctx ~location:i.info result expected)
      result;
    result
  in
  (* A type carrying a [descriptor] clause must be allocated with a descriptor
     ([{T descriptor d | …}]), not a plain [{T | …}]. *)
  let require_no_descriptor typ =
    match Tbl.find_opt ctx.type_context.types typ with
    | Some (_, def) when Option.is_some def.descriptor ->
        Error.descriptor_allocation_required ctx.diagnostics ~location:i.info
    | _ -> ()
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
                (fun prev (name, written) ->
                  let* l = prev in
                  let* fi' = instruction ctx (field_value name written) in
                  return ((name, Option.map (fun _ -> fi') written) :: l))
                (return []) fields
            in
            return_expression i
              (Struct (None, List.rev fields'))
              (Cell.make Error)
        | Some typ ->
            require_no_descriptor typ;
            let*! field_types = lookup_struct_type ctx typ in
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
                  | Some (name, written) ->
                      let* l = prev in
                      (* Check the field value against its declared type, so a
                         nested struct/array literal can drop its own name. *)
                      let* checked =
                        let i' = field_value name written in
                        match internalize ctx (unpack_type f) with
                        | Some cell ->
                            let* i', _ = check_instruction ctx cell i' in
                            return i'
                        | None -> instruction ctx i'
                      in
                      (* Preserve punning: a punned field ([written = None]) stays
                         [None] so the printer re-emits [{x}]; the check above
                         still validates it and gives it its stack effect. *)
                      return ((name, Option.map (fun _ -> checked) written) :: l))
                (return []) field_types
            in
            (* The fields alone pin this type (re-parse re-resolves to it via
               field inference, which takes precedence over the expected type),
               so a present name is redundant. *)
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
        | Some n, Some { typ = Ref { typ = Type t | Exact t; _ }; _ } ->
            t.desc = n.desc
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
        | None -> return_expression i (StructDefault None) (Cell.make Error)
        | Some typ ->
            let*! fields = lookup_struct_type ctx typ in
            if
              not
                (Array.for_all
                   (fun field -> field_has_default (snd field.desc))
                   fields)
            then Error.not_defaultable ctx.diagnostics ~location:i.info;
            require_no_descriptor typ;
            let emitted =
              emitted_name ty typ ~parseable:true ~field_unique:false
            in
            let*! result = construction_result typ in
            return_expression i (StructDefault emitted) result
      in
      return (node, true)
  | StructDesc (d, fields) ->
      (* [{ descriptor(d) | fields }]: the struct type [X] is recovered from [d]
         ([d : (ref (exact Y))], [Y describes X]); the field values are then
         checked against [X]'s fields. *)
      let* d, target =
        descriptor_target ctx ~location:i.info ~nullable:false d
      in
      let* node =
        match Option.map (fun (t : reftype) -> named_heaptype t.typ) target with
        | None | Some None ->
            let* fields' =
              List.fold_left
                (fun prev (name, written) ->
                  let* l = prev in
                  let* fi' = instruction ctx (field_value name written) in
                  return ((name, Option.map (fun _ -> fi') written) :: l))
                (return []) fields
            in
            return_expression i
              (StructDesc (d, List.rev fields'))
              (Cell.make Error)
        | Some (Some typ) ->
            let*! field_types = lookup_struct_type ctx typ in
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
                  | Some (name, written) ->
                      let* l = prev in
                      let* checked =
                        let i' = field_value name written in
                        match internalize ctx (unpack_type f) with
                        | Some cell ->
                            let* i', _ = check_instruction ctx cell i' in
                            return i'
                        | None -> instruction ctx i'
                      in
                      return ((name, Option.map (fun _ -> checked) written) :: l))
                (return []) field_types
            in
            let*! result = construction_result typ in
            return_expression i (StructDesc (d, List.rev fields')) result
      in
      return (node, true)
  | StructDefaultDesc d ->
      let* d, target =
        descriptor_target ctx ~location:i.info ~nullable:false d
      in
      let* node =
        match Option.map (fun (t : reftype) -> named_heaptype t.typ) target with
        | None | Some None ->
            return_expression i (StructDefaultDesc d) (Cell.make Error)
        | Some (Some typ) ->
            let*! fields = lookup_struct_type ctx typ in
            if
              not
                (Array.for_all
                   (fun field -> field_has_default (snd field.desc))
                   fields)
            then Error.not_defaultable ctx.diagnostics ~location:i.info;
            let*! result = construction_result typ in
            return_expression i (StructDefaultDesc d) result
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
            check_type ctx i2' i32_cell;
            return_expression i (Array (None, i1', i2')) (Cell.make Error)
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
            check_type ctx i2' i32_cell;
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
            check_type ctx n' i32_cell;
            return_expression i (ArrayDefault (None, n')) (Cell.make Error)
        | Some typ ->
            let* n' = instruction ctx n in
            check_type ctx n' i32_cell;
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
              (Cell.make Error)
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
            check_type ctx off' i32_cell;
            check_type ctx len' i32_cell;
            return_expression i
              (ArraySegment (None, seg, off', len'))
              (Cell.make Error)
        | Some typ ->
            let* off' = instruction ctx off in
            let* len' = instruction ctx len in
            check_type ctx off' i32_cell;
            check_type ctx len' i32_cell;
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
      (* The natural type a bare string re-infers to: the default [<string>]
         array, allocated exactly as [construction_result] would (exact only
         when custom-descriptors is enabled). This — not the always-inexact
         [string_valtype], used only for the structural [is_default] check — is
         what decides whether a binding annotation is redundant. *)
      let string_valtype_natural =
        internalize_valtype ctx
          (Ref
             {
               nullable = false;
               typ =
                 (if
                    Wax_utils.Feature.is_enabled ctx.type_context.features
                      Wax_utils.Feature.Custom_descriptors
                  then Exact string_typ
                  else Type string_typ);
             })
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
       | Packed I8 -> ()
       | Packed I16 ->
           if not (String.is_valid_utf_8 s) then
             Error.string_not_unicode ctx.diagnostics ~location:i.info
       | Value _ ->
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
        ( node,
          annotation_needed ~drop_supertype ctx string_valtype_natural expected
        )
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
          match (typ, Cell.get expected) with
          | Ast.Valtype vt, Valtype b -> (
              match internalize_valtype ctx vt with
              | Some a -> valtype_equal ctx a b
              | None -> false)
          | _ -> false
        then
          match i'.desc with
          (* Only drop down to a *bare* null: it re-checks to [expected], which
             the context re-supplies. A nested cast operand (e.g. [extern.convert_any]
             over a typed [ref.null], decompiled as [(null as &?t) as &?extern])
             pins a different type, so dropping the outer cast would change the
             value's type — keep both casts. *)
          | Cast (({ desc = Null; _ } as inner), _) ->
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
      check_type ctx cond' i32_cell;
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
  | Select (i1, i2, i3) when has_expectation expected ->
      (* The expression form of an annotated [if]: push the context's [expected]
         type into both value branches, so a construction there can drop its
         type name (re-parse re-pushes it through this same arm); the condition
         [i1] is an [i32]. The branches are evaluated before the condition, as in
         synthesis. The keep-bool is the disjunction of the branches' — the
         surrounding binding annotation is load-bearing iff a branch relied on it
         (e.g. to drop a name, or because its own type differs from [expected]). *)
      let* i2', needed2 = check_instruction ~drop_supertype ctx expected i2 in
      let* i3', needed3 = check_instruction ~drop_supertype ctx expected i3 in
      let* i1' = instruction ctx i1 in
      check_type ctx i1' i32_cell;
      (* The result is the branches' join, not [expected]: each branch is already
         [<: expected], so this keeps the select's precise type (e.g. [&bytes]
         rather than the [&eq] the context happened to ask for). *)
      let ty =
        match
          join_value_types ctx (expression_type ctx i2')
            (expression_type ctx i3')
        with
        | Some ty -> ty
        | None -> expected
      in
      let* node = return_expression i (Select (i1', i2', i3')) ty in
      return (node, needed2 || needed3)
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
        | Func_ref (_, ty', _) -> Some (Ast.no_loc ty')
        | Local (Some { typ = Ref { typ = Type t | Exact t; _ }; _ })
        | Global (_, Some { typ = Ref { typ = Type t | Exact t; _ }; _ }) ->
            Some t
        | Local _ | Global _ | Unbound -> None)
    (* A cast target names the value's type directly; [from_wasm] inserts these
       on a receiver before a field access (e.g. [(k as &cont_2).cont_func]). *)
    | Cast (_, Valtype (Ref { typ = Type t | Exact t; _ })) -> Some t
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
                      | Value (Ref { typ = Type t | Exact t; _ }) -> Some t
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
  match Cell.get (expression_type ctx i') with
  | Valtype { typ = Ref { typ = Type ty | Exact ty; _ }; _ } ->
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
  | Unknown | UnknownRef ->
      (* The callee's type is unknown (unreachable / branch code) or only a
         reference (its function type cannot be resolved), so the call cannot be
         compiled. *)
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
    when Wax_wasm.Atomics.of_method_name meth.desc <> None
         && memory_receiver ctx memname ->
      let op = Option.get (Wax_wasm.Atomics.of_method_name meth.desc) in
      type_atomic_method_call ctx i func recv memname meth op args
  | Call
      ( ({ desc = StructGet (({ desc = Get memname; _ } as recv), meth); _ } as
         func),
        args )
    when is_mem_method meth.desc && memory_receiver ctx memname ->
      type_mem_method_call ctx i func recv memname meth args
  (* SIMD memory accesses: mem.v128_load(addr), mem.v128_store(addr, v),
     mem.v128_load8_lane(addr, v, lane), etc. Stack operands first, then the
     constant lane immediate (if any), then the usual align/offset literals. *)
  | Call
      ( ({ desc = StructGet (({ desc = Get memname; _ } as recv), meth); _ } as
         func),
        args )
    when Simd.is_mem_method meth.desc && memory_receiver ctx memname ->
      type_simd_mem_method_call ctx i func recv memname meth args
  (* Memory management: mem.size/grow/fill/copy/init, on a memory name. *)
  | Call
      ( ({ desc = StructGet (({ desc = Get name; _ } as recv), meth); _ } as func),
        args )
    when is_mgmt_method meth.desc && memory_receiver ctx name ->
      type_mem_mgmt_call ctx i func recv name meth args
  (* Table management: tab.size/grow/fill/copy/init, on a table name. *)
  | Call
      ( ({ desc = StructGet (({ desc = Get name; _ } as recv), meth); _ } as func),
        args )
    when is_mgmt_method meth.desc && table_receiver ctx name ->
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
    when segment_receiver ctx name ->
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
  (* Built-in intrinsics written as a qualified path, [i64::add128(...)] or
     [v128::bitselect(...)]. *)
  | Call (({ desc = Path (ns, name); _ } as func), args) ->
      type_path_intrinsic_call ctx i func ns name args
  | Call (i', l) -> type_indirect_call ctx i i' l
  | _ -> assert false (* only invoked on [Call] *)

(* A qualified-path intrinsic call [ns::name(args)]. The [v128] namespace holds
   the SIMD free-function intrinsics ([const_<shape>], [bitselect]); the [i64]
   namespace holds the wide-arithmetic instructions. *)
and type_path_intrinsic_call ctx i func ns name args =
  match ns.desc with
  | "v128" -> type_simd_free_intrinsic_call ctx i func ns name args
  | "i64" -> type_wide_arith_call ctx i func ns name args
  | "atomic" when name.desc = "fence" ->
      let* args' = instructions ctx args in
      if args' <> [] then
        Error.value_count_mismatch ctx.diagnostics ~location:i.info ~expected:0
          ~provided:(List.length args');
      return_statement i
        (Call ({ desc = Path (ns, name); info = ([||], func.info) }, args'))
        [||]
  | _ ->
      let* args' = instructions ctx args in
      Error.unknown_intrinsic ctx.diagnostics ~location:i.info ns.desc name.desc;
      return_expression i
        (Call ({ desc = Path (ns, name); info = ([||], func.info) }, args'))
        (Cell.make Error)

(* The [i64::] wide-arithmetic intrinsics: [add128]/[sub128] take four i64
   operands (each of the two 128-bit inputs as low/high) and
   [mul_wide_s]/[mul_wide_u] take two, all returning two i64 results
   (low, high). *)
and type_wide_arith_call ctx i func ns name args =
  let* args' = instructions ctx args in
  let arity =
    match name.desc with
    | "add128" | "sub128" -> Some 4
    | "mul_wide_s" | "mul_wide_u" -> Some 2
    | _ -> None
  in
  match arity with
  | None ->
      Error.unknown_intrinsic ctx.diagnostics ~location:i.info ns.desc name.desc;
      (* Recover with two [Error] results (the arity every wide-arithmetic
         intrinsic has), so a typo does not cascade into a value-count error. *)
      return_statement i
        (Call ({ desc = Path (ns, name); info = ([||], func.info) }, args'))
        [| Cell.make Error; Cell.make Error |]
  | Some n ->
      if List.length args' <> n then
        Error.value_count_mismatch ctx.diagnostics ~location:i.info ~expected:n
          ~provided:(List.length args');
      List.iter (fun a -> check_type ctx a i64_cell) args';
      return_statement i
        (Call ({ desc = Path (ns, name); info = ([||], func.info) }, args'))
        [| valtype_cell i64_valtype; valtype_cell i64_valtype |]

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
  | If { label; typ; cond; if_block; else_block } ->
      (* A statement-position [if] is void (a value-producing one is consumed by
         its context, so it is typed in expression position). Like a
         statement-position [block]/[loop] it is not inferred — only its
         expression-position form is ([if_inference], from [type_block_construct]).
         This also keeps a void [if] reached by a [br] to its own label working:
         the label's branch-target is then the void result, not an inferred
         single value. *)
      let* cond = toplevel_instruction ctx cond in
      check_type ctx cond i32_cell;
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
      return_statement i (If { label; typ; cond; if_block; else_block }) results
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
  (* A trailing instruction that produces the block's single value is routed
     through [check_instruction] (against the result type) rather than synthesized,
     so the result type flows into it: a nested block's own result annotation then
     drops, a construction drops its name, and a [?:] propagates the type into
     both its branches. [classify_trailing] decides which forms qualify (a
     parameterized block does not — it stays on the statement path, which pops its
     parameters off the stack, as expression position has no stack to take them
     from). *)
  | [ i ]
    when Array.length results = 1
         &&
         match classify_trailing ctx i.desc with
         | false, false -> false
         | _ -> true ->
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
      fun st ->
        let st_after, i' = toplevel_instruction ctx i st in
        (* Dead code: the stack was reachable before [i], typing [i] left it
           polymorphic ([Unreachable] — [i] is a [br]/[return]/[unreachable] or
           the like), and a statement still follows. Report the first such
           statement, pointing back at the divergence. The following statements
           are then typed on the [Unreachable] stack, so this fires once, at the
           point control is lost. *)
        (match (st, st_after, r) with
        | (Empty | Cons _), Unreachable, dead :: _ when ctx.warn_unused ->
            Error.dead_code ctx.diagnostics ~location:dead.info
              ~related:
                [
                  {
                    Wax_utils.Diagnostic.location = i.info;
                    message =
                      (fun f () ->
                        Format.fprintf f "Control never returns from here.");
                  };
                ]
        | _ -> ());
        let st_after, () =
          push_results
            (Array.to_list (Array.map (fun ty -> (i.info, ty)) (fst i'.info)))
            st_after
        in
        let st_after, r' = block_contents ctx results r st_after in
        (st_after, merge_let_tuple ctx i' r')

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
    | last :: _ -> classify_trailing ctx last.desc
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
           cs.collected <- (Some loc', Cell.make (Cell.get tv)) :: cs.collected
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
  match Cell.get r with
  | Collecting cs -> (
      cs.needed
      ||
      match join_collected ctx ~location:loc cs.collected with
      | Some j -> annotation_needed ctx (standalone_valtype ctx j) result
      | None -> true)
  | _ -> true

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
(* The concrete width an exact ([br_if]) exit value re-defaults to on re-parse
   ([resolve_omitted_valtype]: a flexible int/number/int8/int16 -> i32, large-int
   -> i64, float -> f64, a concrete value -> itself). A polymorphic ([Unknown])
   exact is a [br_if] value on the polymorphic stack of dead code, snapshotted here
   before its own downstream context (an arithmetic op, a cast) could type it; with
   the annotation dropped that context re-defaults it to i32 (the dead-code
   default), so treat it as i32 rather than "no constraint" — otherwise a block
   whose result is wider (an i64 fall-through alongside such a [br_if]) would drop
   the load-bearing annotation and no longer re-infer. [None] only for [Error]
   (recovery) and a bottom reference, which impose no width constraint. Used for the
   drop decision: an annotation dropped here must be re-derivable. *)
and exact_reparse_internal ctx ty =
  match Cell.get ty with
  | Int8 | Int16 | Unknown -> Some i32_valtype.internal
  | _ -> Option.map (fun v -> v.internal) (standalone_valtype ctx ty)

(* Whether an exact exit's re-parse type equals a candidate result [internal]. *)
and exact_reparse_matches ctx ~result ty =
  match exact_reparse_internal ctx ty with None -> true | Some e -> e = result

(* The width a flexible numeric literal re-defaults to on re-parse (int/number ->
   i32, large-int -> i64, float -> f64); [None] for anything already concrete or
   non-numeric. *)
and flexible_default_internal = function
  | Int | Number | Int8 | Int16 -> Some i32_valtype.internal
  | LargeInt -> Some i64_valtype.internal
  | Float -> Some f64_valtype.internal
  | _ -> None

(* Whether keeping the result annotation is load-bearing because dropping it would
   change the width on re-parse. [natural] are the exit types snapshotted before
   [join_collected] pinned them. When the join settled to a concrete type only
   because the declared annotation pinned a flexible exit to it (e.g. a bare float
   literal reaching an [f32] block, which the annotation pins to f32 but which
   re-defaults to f64 without it), dropping the annotation lets that exit re-infer
   the block to a different width — so keep it. Gated on [inferred] being concrete:
   when the join stayed flexible (an [if] over a [LargeInt] and an [Int] branch
   joins to a [LargeInt]) it self-resolves the same way on re-parse and the
   annotation is redundant. *)
and natural_width_forces_annotation ~natural ~inferred =
  match Option.map (fun c -> Cell.get c) inferred with
  | Some (Valtype rv) ->
      List.exists
        (fun ty ->
          match flexible_default_internal ty with
          | Some def -> def <> rv.internal
          | None -> false)
        natural
  | _ -> false

(* Snapshot the natural types of a block's collected exit values before
   [join_collected] pins them (for [natural_width_forces_annotation]). *)
and collected_natural collected =
  List.map (fun (_, ty) -> Cell.get ty) collected

(* A [br_if] value stays on the stack typed as the block's result; when the result
   is fixed (a present annotation, a context type, or the inferred join, all of
   which pin a flexible exact), only a *concrete* exact of a different type is a
   genuine mismatch — a flexible one is coerced to the result. Report each such
   exact against [result] (a concrete width). *)
and report_exact_mismatches ctx ~location ~result exacts =
  match standalone_valtype ctx result with
  | None -> ()
  | Some t ->
      List.iter
        (fun (loc, ty) ->
          match Cell.get ty with
          | Valtype v when v.internal <> t.internal ->
              Error.br_if_result_mismatch ctx.diagnostics ~location
                ~loc:(Option.value loc ~default:location)
                ~result ty
          | _ -> ())
        exacts

and finalize_inferred ?(needed = false) ?(exacts = []) ?(natural = []) ?location
    ctx typ ~inferred =
  if typ.results = [||] then
    match Option.bind inferred (resolve_omitted_valtype ctx) with
    | Some iv ->
        (* The inferred result pins a flexible exact, so only a concrete exact of a
           different type is unsound; without an annotation there is nothing to make
           it match, so report it. *)
        (match location with
        | Some location ->
            report_exact_mismatches ctx ~location ~result:(valtype_cell iv)
              exacts
        | None -> ());
        ([| valtype_cell iv |], { typ with results = [| iv.typ |] })
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
      (* Keep the annotation if any exit (a fall-through / [br_table] value, …)
         would re-default to a different width on re-parse. *)
      && (not (natural_width_forces_annotation ~natural ~inferred))
      (* Only drop the annotation when every exact ([br_if]) exit re-defaults to
         exactly the result; otherwise re-parse would re-infer a different result
         and the pass-through value would no longer match it. *)
      && (match standalone_valtype ctx result_cells.(0) with
        | Some t ->
            List.for_all
              (fun (_, ty) -> exact_reparse_matches ctx ~result:t.internal ty)
              exacts
        | None -> exacts = [])
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

(* Shared scaffold for the five expression-position synthesis inferers
   ([if]/[block]/[loop]/[try_table]/[try]). They are identical apart from the
   guard, how the body is typed, and the node they rebuild: each types its body
   against a fresh [Collecting] result cell, then joins the collected exits and
   (on [simplify]) drops a redundant annotation the same way. [applies] is an
   extra guard on top of [infer_block_applies] ([if] also requires an [else]);
   [type_body ~cs ~r] types the body against the shared cell and returns whatever
   [rebuild ~typ] needs to reconstruct the node. *)
and infer_synthesized ?(applies = true) ctx i typ ~type_body =
  if not (infer_block_applies ctx typ && applies) then None
  else
    let cs, r = fresh_collecting (declared_result ctx typ) in
    (* [type_body] types the body against the shared cell (its side effects on
       [cs] are what the join below reads) and returns a [rebuild] closure that
       reconstructs the node from the finalized result type. *)
    let rebuild = type_body ~cs ~r in
    let natural = collected_natural cs.collected in
    let inferred = join_collected ctx ~location:i.info cs.collected in
    let results, typ =
      finalize_inferred ~needed:cs.needed ~exacts:cs.exacts ~natural
        ~location:i.info ctx typ ~inferred
    in
    Some (rebuild typ, results)

(* Try to infer (and, on [simplify], drop) an [if]'s result type from the values
   reaching its exit, returning the typed node when it applies and [None] to fall
   back to the annotated path. Called from the expression-position [If] case
   ([type_block_construct]); a statement-position [if] is void and not inferred,
   like a statement [block]/[loop]. [cond] is the already-typed condition.
   Applies with an [else] and under the same conditions as the other block forms
   ([infer_block_applies]). Like them, both branches are typed against one shared
   [Collecting] cell (via [collect_into]), so every value reaching the exit —
   each branch's fall-through and any value branched to the [if]'s own label — is
   recorded and then joined. A trailing construction still synthesizes its own
   type (its natural type is what is collected), so [finalize_inferred] only
   drops [=> T] when that synthesized type is a subtype of it (a tail that cannot
   synthesize on its own, e.g. a bare [null], keeps it). *)
and if_inference ctx i label typ ~cond ~if_block ~else_block =
  infer_synthesized ~applies:(Option.is_some else_block) ctx i typ
    ~type_body:(fun ~cs ~r ->
      let if_block' = collect_into ctx i.info label ~cs ~r if_block.desc in
      let else_block' =
        collect_into ctx i.info label ~cs ~r (Option.get else_block).desc
      in
      fun typ ->
        If
          {
            label;
            typ;
            cond;
            if_block = { if_block with desc = if_block' };
            else_block =
              Some { (Option.get else_block) with desc = else_block' };
          })

(* The block's declared single result internalized to a cell, or [None] when the
   result is omitted. *)
and declared_result ctx typ =
  match typ.results with [| t |] -> internalize ctx t | _ -> None

(* A fresh [Collecting] result cell and its backing record: [declared] is the
   annotation under test (or [None]), [needed] preset when it is already known to
   be load-bearing. *)
and fresh_collecting ?(needed = false) declared =
  let cs = { collected = []; exacts = []; declared; needed } in
  (cs, Cell.make (Collecting cs))

(* Type one block body against the shared [Collecting] result cell [r] (backed
   by [cs]), in synthesis, recording every value reaching its exit — the
   fall-through plus each value branched to [label] — into [cs.collected] (via
   [subtype]) rather than unifying. The label is bound to [r] so [br]/[br_on_*]
   record their value; [r] is also passed as the body's result so a trailing
   nested block is routed and synthesized (its value collected) rather than typed
   as a void statement and lost — the fall-through is still read off the stack
   below. Returns the typed body. Every inferring block routes through this; [if]
   calls it once per branch with a shared cell so both branches' exits join. *)
and collect_into ctx loc label ~cs ~r instrs =
  with_empty_stack ctx ~location:loc ~kind:Block
    (let* body' =
       block_contents
         {
           ctx with
           control_types =
             (Option.map (fun l -> l.desc) label, [| r |]) :: ctx.control_types;
         }
         [| r |] instrs
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
           (Empty, body')
       | Cons (loc, tv, Unreachable) ->
           cs.collected <- (Some loc, tv) :: cs.collected;
           (Unreachable, body')
       | Empty -> (Empty, body')
       | Unreachable -> (Unreachable, body')
       | Cons _ -> (st, body'))

(* Join the values reaching a block's exit into its inferred result, or [None]
   when none do (a void or fully divergent body). Incompatible exit types are
   reported with a caret at each offending value (falling back to [location], the
   block, when a value carries none); this is unreachable for well-typed input,
   where every exit is a subtype of the declared result. One type is kept so a
   single result is still produced. *)
and join_collected ctx ~location collected =
  (* [collected] is built in reverse (cons as each exit is met); fold in source
     order so a mismatch points at the values that way and recovers with the
     first. *)
  match List.rev collected with
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

(* Whether to infer a block's result in expression (synthesis) position: only
   for the single-result, parameterless forms, and only when the annotation is
   omitted (a re-parse of a dropped one, which must be re-inferred) or [simplify]
   is converting from Wasm (so a redundant annotation can be dropped). *)
and infer_block_applies ctx typ =
  Array.length typ.params = 0
  && (typ.results = [||] || (ctx.simplify && Array.length typ.results = 1))

(* Infer (and, on [simplify], drop) the result type of a [do]/labelled block
   from the values reaching its exit. The single-branch counterpart of
   [if_inference]: same [fresh_collecting] / [collect_into] / [join_collected]
   shape, with one body. *)
and block_inference ctx i label typ ~instrs =
  infer_synthesized ctx i typ ~type_body:(fun ~cs ~r ->
      let body' = collect_into ctx i.info label ~cs ~r instrs in
      fun typ -> Block { label; typ; block = body' })

(* Expression-position synthesis inference for [loop]/[try]/[try_table], the
   analogue of [block_inference] for [do]. Type the body (and, for [try], the
   handlers) against a fresh [Collecting] result cell so every value reaching the
   exit — the fall-through, and values branched to the block's label — is
   recorded, then join them and (on [simplify]) drop a redundant annotation. A
   [br] to a loop re-enters at its top (branch-target = the empty params), so a
   loop's value is only its fall-through; the others deliver to their label. *)
and loop_inference ctx i label typ ~instrs =
  infer_synthesized ctx i typ ~type_body:(fun ~cs:_ ~r ->
      let instrs' = block ctx i.info label [||] [| r |] [||] instrs in
      fun typ -> Loop { label; typ; block = instrs' })

and trytable_inference ctx i label typ ~body ~catches =
  infer_synthesized ctx i typ ~type_body:(fun ~cs:_ ~r ->
      let results = [| r |] in
      let body' = block ctx i.info label [||] results results body in
      check_trytable_catches ctx catches;
      fun typ -> TryTable { label; typ; block = body'; catches })

and try_inference ctx i label typ ~body ~catches ~catch_all =
  infer_synthesized ctx i typ ~type_body:(fun ~cs:_ ~r ->
      let results = [| r |] in
      let body' = block ctx i.info label [||] results results body in
      let catches, catch_all =
        type_try_catches ctx i label ~results catches catch_all
      in
      fun typ -> Try { label; typ; block = body'; catches; catch_all })

(*** Module type and constant checking ***)

let check_type_definitions ctx =
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
            let descriptor_ok =
              (* If the supertype has a descriptor, the subtype must too, and its
                 descriptor must be a subtype of the supertype's. (A subtype may
                 add a descriptor that its supertype lacks.) *)
              match ty'.descriptor with
              | None -> true
              | Some dp -> (
                  match ty.descriptor with
                  | Some ds ->
                      Wax_wasm.Types.heap_subtype ctx.subtyping_info (Type ds)
                        (Type dp)
                  | None -> false)
            in
            let describes_ok =
              (* A subtype has a described type iff its supertype does, and the
                 subtype's described type must be a subtype of the supertype's. *)
              match (ty.describes, ty'.describes) with
              | None, None -> true
              | Some os, Some op ->
                  Wax_wasm.Types.heap_subtype ctx.subtyping_info (Type os)
                    (Type op)
              | Some _, None | None, Some _ -> false
            in
            if not (valid_subtype && descriptor_ok && describes_ok) then
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
  (* A punned field ([None], written [{x}]) is a [Get] of the like-named global,
     so it must satisfy the same constant-global rule; check that implicit [Get].
     The [storagetype] array of the fabricated node is unused by the [Get] arm. *)
  | Struct (_, l) -> List.iter (check_constant_field ctx) l
  | StructDesc (d, l) ->
      check_constant_instruction ctx d;
      List.iter (check_constant_field ctx) l
  | StructDefaultDesc d -> check_constant_instruction ctx d
  | ArrayFixed (_, l) -> List.iter (check_constant_instruction ctx) l
  | Array (_, i1, i2) ->
      check_constant_instruction ctx i1;
      check_constant_instruction ctx i2
  | BinOp ({ desc = Add | Sub | Mul; _ }, i1, i2) -> (
      check_constant_instruction ctx i1;
      check_constant_instruction ctx i2;
      match Cell.get (expression_type ctx i) with
      | Int | Valtype { internal = I32 | I64; _ } -> ()
      | _ -> Error.constant_expression_required ctx.diagnostics ~location)
  | Cast ({ desc = Null; _ }, Valtype (Ref { nullable = true; _ })) ->
      (* ref.null *)
      ()
  | Cast (i', Valtype (Ref { typ = I31; _ })) -> (
      (* ref.i31 *)
      check_constant_instruction ctx i';
      match Cell.get (expression_type ctx i') with
      | Valtype { internal = I32; _ } -> ()
      | _ -> Error.constant_expression_required ctx.diagnostics ~location)
  | Cast (i', Valtype (Ref { typ = Extern; nullable })) ->
      (* extern.convert_any *)
      check_constant_instruction ctx i';
      if
        match (Cell.get (expression_type ctx i') : inferred_type) with
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
        match (Cell.get (expression_type ctx i') : inferred_type) with
        | Valtype { internal; _ } ->
            not
              (Wax_wasm.Types.val_subtype ctx.subtyping_info internal
                 (Ref { nullable; typ = Extern }))
        | _ -> true
      then Error.constant_expression_required ctx.diagnostics ~location
  | UnOp ({ desc = Pos; _ }, i') -> check_constant_instruction ctx i'
  | UnOp ({ desc = Neg; _ }, { desc = Float _ | Int _; _ }) -> ()
  (* [v128::const_<shape>(..)] is a constant expression; its lanes are literals.
     Other SIMD ops are not constant. *)
  | Call ({ desc = Path (ns, name); _ }, args)
    when ns.desc = Simd.free_namespace
         && Simd.const_shape_of_name (Simd.free_full name.desc) <> None ->
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
  | Match _ | Unreachable | Nop | Hole | Path _ | Set _ | Tee _ | Call _
  | TailCall _ | Cast _ | CastDesc _ | Test _ | NonNull _ | StructGet _
  | GetDescriptor _ | StructSet _ | ArraySegment _ | ArrayGet _ | ArraySet _
  | Let _ | Br _ | Br_if _ | Br_table _ | Br_on_null _ | Br_on_non_null _
  | Br_on_cast _ | Br_on_cast_fail _ | Br_on_cast_desc_eq _
  | Br_on_cast_desc_eq_fail _ | Hinted _ | Throw _ | ThrowRef _ | ContNew _
  | ContBind _ | Suspend _ | Resume _ | ResumeThrow _ | ResumeThrowRef _
  | Switch _ | Return _ | Sequence _ | Select _ | If_annotation _ ->
      Error.constant_expression_required ctx.diagnostics ~location

(* A struct-literal field in a constant expression. An explicit value is checked
   directly; a punned field ([None]) is the implicit [Get] of the like-named
   global, which must also be an immutable global. *)
and check_constant_field ctx (name, i) =
  match i with
  | Some i -> check_constant_instruction ctx i
  | None ->
      check_constant_instruction ctx
        { desc = Get name; info = ([||], name.info) }

(*** Globals, functions, and declarations ***)

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
  check_type ctx off' (address_cell address_type);
  check_constant_instruction ctx off';
  off'

let rec globals ctx fields =
  List.map
    (fun field ->
      match field.desc with
      | Memory ({ address_type; data; _ } as m) ->
          check_limits ctx ~location:field.info "memory" ~shared:m.shared
            address_type m.page_size_log2 m.limits max_memory_size;
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
          check_limits ctx ~location:field.info "table" ~shared:false
            t.address_type None t.limits max_table_size;
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
                           (valtype_cell ity) def)
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
              let*@ _, tname, _ = Tbl.find ctx.diagnostics ctx.functions name in
              Tbl.find ctx.diagnostics ctx.types { name with desc = tname }
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
              (* Fresh per-function tracking of branched-to labels, and the
                 labels declared in the body (collected once, up front). *)
              used_labels = ref StringSet.empty;
              label_decls = List.fold_left collect_labels [] body;
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
          (* The syntactic lints (constant conditions, dropped pure values) read
             the source body, before typing shadows [body] with the typed one. *)
          if ctx.warn_unused then List.iter (lint_source ctx) body;
          let body =
            with_empty_stack ctx ~location ~kind:Function
              (let* body = block_contents ctx return_types body in
               let* () = pop_args ctx ~location return_types in
               return body)
          in
          (* A local or label whose name starts with [_] is intentionally
             unused. *)
          if ctx.warn_unused then begin
            List.iter
              (fun name ->
                let n = name.desc in
                if
                  (not (StringSet.mem n !(ctx.read_locals)))
                  && not (String.length n > 0 && n.[0] = '_')
                then Error.unused_local ctx.diagnostics ~location:name.info name)
              (List.rev !(ctx.local_decls));
            List.iter
              (fun name ->
                let n = name.desc in
                if
                  (not (StringSet.mem n !(ctx.used_labels)))
                  && not (String.length n > 0 && n.[0] = '_')
                then Error.unused_label ctx.diagnostics ~location:name.info name)
              (List.rev ctx.label_decls)
          end;
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
      | Before
          ({
             desc =
               Type _ | Module_annotation _ | Fundecl _ | GlobalDecl _ | Tag _;
             _;
           } as f) ->
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
                    ( name,
                      {
                        supertype = None;
                        typ = Func sign;
                        final = true;
                        descriptor = None;
                        describes = None;
                      } );
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
  | Group { attributes; _ }
  | Module_annotation attributes ->
      attributes
  | Type _ | Conditional _ -> []

(* Validate the annotations on a module field: reject unknown ones, check the
   value shape of [export] / [import] / [start], allow each only where it is
   meaningful, and require an [import] on a body-less declaration. *)
let check_attributes diagnostics field =
  let export_ok, import_ok, start_ok, module_ok =
    match field.desc with
    | Func _ -> (true, false, true, false)
    | Fundecl _ | GlobalDecl _ -> (true, true, false, false)
    | Global _ -> (true, false, false, false)
    | Memory _ | Table _ | Tag _ -> (true, true, false, false)
    | Module_annotation _ -> (false, false, false, true)
    | Data _ | Elem _ | Type _ | Group _ | Conditional _ ->
        (false, false, false, false)
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
      | "module" ->
          (match value with
          | Some { desc = String _; _ } -> ()
          | _ ->
              Error.annotation_value_mismatch diagnostics ~location "module"
                "a string");
          if not module_ok then
            Error.annotation_not_allowed diagnostics ~location "module"
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

(*** Type-checking a configuration ***)

let type_configuration ?(warn_unused = false) ?(build = true)
    ?(features = Wax_utils.Feature.default ()) ~simplify diagnostics fields =
  let cond = ref Cond.true_ in
  let cond_env = Cond.create () in
  let type_context =
    {
      internal_types = Wax_wasm.Types.create ();
      types = Tbl.make (Namespace.make cond) "type";
      features;
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
      used_labels = ref StringSet.empty;
      label_decls = [];
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
      | Fundecl { name; typ; sign; exact; _ } ->
          let>@ i, n = fundecl ctx name typ sign in
          Tbl.add diagnostics ctx.functions name (i, n, exact)
      | GlobalDecl { name; mut; typ; _ } ->
          let>@ typ = internalize_valtype ctx typ in
          Tbl.add diagnostics ctx.globals name (mut, Some typ)
      | Func { name; typ; sign; _ } ->
          (* A module-defined function has exactly its declared type, so a
             reference to it is exact — but exact reference types are part of
             custom-descriptors; without it, type it as the plain inexact
             reference, as before the proposal. *)
          let>@ i, n = fundecl ctx name typ sign in
          let exact =
            Wax_utils.Feature.is_enabled ctx.type_context.features
              Wax_utils.Feature.Custom_descriptors
          in
          Tbl.add diagnostics ctx.functions name (i, n, exact)
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
      | Group _ | Conditional _ | Type _ | Global _ | Module_annotation _ -> ())
    fields;
  (* A module may not export the same name twice. Each [#[export = "..."]]
     attribute is one export; [walk_fields] descends into groups and resolves
     conditionals per branch, so exports in mutually exclusive branches do not
     clash. *)
  let exports = Hashtbl.create 16 in
  let start_seen = ref false in
  let module_seen = ref false in
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
          | "module", _ ->
              (* A module may carry at most one name annotation. *)
              if !module_seen then
                Error.multiple_module diagnostics ~location:field.info
              else module_seen := true
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
              descriptor = None;
              describes = None;
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
  (* Report module fields — functions and globals — that are defined but never
     referenced (the module-level analog of an unused local). A field is exempt
     if its name starts with [_], if it is exported or is the start function
     (both externally reachable), or if it is an import (an external contract,
     not a definition; those are [Fundecl]/[GlobalDecl] and never reach the
     arms below). Uses are collected by [Tbl.resolve] as names are looked up
     while typing the globals and function bodies above. *)
  if warn_unused then begin
    let exempt field =
      List.exists
        (fun (k, _) -> k = "export" || k = "start" || k = "import")
        (field_attributes field)
    in
    let unused tbl (name : ident) =
      (not (String.length name.desc > 0 && name.desc.[0] = '_'))
      && not (Tbl.is_used tbl name.desc)
    in
    walk_fields
      (fun field ->
        match field.desc with
        | Func { name; _ }
          when (not (exempt field.desc)) && unused ctx.functions name ->
            Error.unused_field ctx.diagnostics ~location:name.info "function"
              name
        | Global { name; _ }
          when (not (exempt field.desc)) && unused ctx.globals name ->
            Error.unused_field ctx.diagnostics ~location:name.info "global" name
        | _ -> ())
      fields
  end;
  ( ctx.type_context.types,
    (* Building the annotated module is only needed for the deferred conversion
       to Wasm/WAT; a validation-only pass ([~build:false]) runs the checking
       above for its diagnostics and skips this projection. *)
    if not build then []
    else
      List.map
        (fun f ->
          let desc =
            Ast_utils.map_modulefield
              (fun (types, loc) ->
                ( Array.map
                    (fun ty ->
                      match Cell.get ty with
                      | Unknown | Error | Collecting _ -> None
                      | Null ->
                          Some (Value (Ref { nullable = true; typ = None_ }))
                      | UnknownRef ->
                          Some (Value (Ref { nullable = false; typ = None_ }))
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

(*** Conditional compilation and entry points ***)

let rec instr_has_conditional (i : (_ instr_desc, _) annotated) =
  let any = List.exists instr_has_conditional in
  let opt = Option.fold ~none:false ~some:instr_has_conditional in
  match i.desc with
  | If_annotation _ -> true
  | Block { block; _ } | Loop { block; _ } | TryTable { block; _ } -> any block
  | While { cond; step; block; _ } ->
      instr_has_conditional cond
      || Option.fold ~none:false ~some:instr_has_conditional step
      || any block
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
  (* A punned field ([None]) is a [Get] and carries no conditional. *)
  | Struct (_, l) ->
      List.exists
        (fun (_, i) -> Option.fold ~none:false ~some:instr_has_conditional i)
        l
  | StructDesc (d, l) ->
      instr_has_conditional d
      || List.exists
           (fun (_, i) -> Option.fold ~none:false ~some:instr_has_conditional i)
           l
  | CastDesc (a, _, b)
  | Br_on_cast_desc_eq (_, _, a, b)
  | Br_on_cast_desc_eq_fail (_, _, a, b)
  | BinOp (_, a, b)
  | Array (_, a, b)
  | ArraySegment (_, _, a, b)
  | ArrayGet (a, b)
  | StructSet (a, _, b) ->
      instr_has_conditional a || instr_has_conditional b
  | ArraySet (a, b, c) | Select (a, b, c) ->
      instr_has_conditional a || instr_has_conditional b
      || instr_has_conditional c
  | Set (_, _, i)
  | Tee (_, i)
  | Cast (i, _)
  | Test (i, _)
  | NonNull i
  | UnOp (_, i)
  | StructGet (i, _)
  | GetDescriptor i
  | StructDefaultDesc i
  | ArrayDefault (_, i)
  | Br_if (_, i)
  | Hinted (_, i)
  | Br_table (_, i)
  | Br_on_null (_, i)
  | Br_on_non_null (_, i)
  | Br_on_cast (_, _, i)
  | Br_on_cast_fail (_, _, i)
  | ThrowRef i
  | ContNew (_, i) ->
      instr_has_conditional i
  | Let (_, i) | Br (_, i) | Throw (_, i) | Return i -> opt i
  | Unreachable | Nop | Hole | Null | Get _ | Path _ | Char _ | String _ | Int _
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
    | While { label; cond; step; block } ->
        While
          {
            label;
            cond = sone asm cond;
            step = Option.map (sone asm) step;
            block = sinstrs asm block;
          }
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
    | Set (idx, op, v) -> Set (idx, op, sone asm v)
    | Tee (idx, v) -> Tee (idx, sone asm v)
    | Call (t, args) -> Call (sone asm t, List.map (sone asm) args)
    | TailCall (t, args) -> TailCall (sone asm t, List.map (sone asm) args)
    | Cast (v, t) -> Cast (sone asm v, t)
    | CastDesc (v, t, d) -> CastDesc (sone asm v, t, sone asm d)
    | Test (v, t) -> Test (sone asm v, t)
    | NonNull v -> NonNull (sone asm v)
    | Struct (idx, fields) ->
        Struct
          (idx, List.map (fun (i, v) -> (i, Option.map (sone asm) v)) fields)
    | StructDesc (d, fields) ->
        StructDesc
          ( sone asm d,
            List.map (fun (i, v) -> (i, Option.map (sone asm) v)) fields )
    | StructDefaultDesc d -> StructDefaultDesc (sone asm d)
    | StructGet (v, idx) -> StructGet (sone asm v, idx)
    | GetDescriptor v -> GetDescriptor (sone asm v)
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
    | Hinted (h, v) -> Hinted (h, sone asm v)
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
    | Br_on_cast_desc_eq (l, t, v, d) ->
        Br_on_cast_desc_eq (l, t, sone asm v, sone asm d)
    | Br_on_cast_desc_eq_fail (l, t, v, d) ->
        Br_on_cast_desc_eq_fail (l, t, sone asm v, sone asm d)
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
    | ( Unreachable | Nop | Hole | Null | Get _ | Path _ | Char _ | String _
      | Int _ | Float _ | StructDefault _ ) as x ->
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
  | While { cond; step; block; _ } -> (cond :: Option.to_list step) @ block
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
  (* A punned field ([None]) is a leaf [Get] with no sub-instruction. *)
  | Struct (_, l) -> List.filter_map snd l
  | StructDesc (d, l) -> List.filter_map snd l @ [ d ]
  | CastDesc (a, _, b)
  | Br_on_cast_desc_eq (_, _, a, b)
  | Br_on_cast_desc_eq_fail (_, _, a, b)
  | BinOp (_, a, b)
  | Array (_, a, b)
  | ArraySegment (_, _, a, b)
  | ArrayGet (a, b)
  | StructSet (a, _, b) ->
      [ a; b ]
  | ArraySet (a, b, c) | Select (a, b, c) -> [ a; b; c ]
  | Set (_, _, i)
  | Tee (_, i)
  | Cast (i, _)
  | Test (i, _)
  | NonNull i
  | UnOp (_, i)
  | StructGet (i, _)
  | GetDescriptor i
  | StructDefaultDesc i
  | ArrayDefault (_, i)
  | Br_if (_, i)
  | Hinted (_, i)
  | Br_table (_, i)
  | Br_on_null (_, i)
  | Br_on_non_null (_, i)
  | Br_on_cast (_, _, i)
  | Br_on_cast_fail (_, _, i)
  | ThrowRef i
  | ContNew (_, i) ->
      [ i ]
  | Let (_, o) | Br (_, o) | Throw (_, o) | Return o -> Option.to_list o
  | Unreachable | Nop | Hole | Null | Get _ | Path _ | Char _ | String _ | Int _
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
            (* Only a binding that introduces a name would leak; an anonymous
               [Let] ([_ = e], a drop) binds nothing, so it is allowed. *)
            | Let (bindings, _)
              when List.exists (fun (name, _) -> Option.is_some name) bindings
              ->
                Error.let_in_conditional diagnostics ~location:s.info
            | _ -> ())
      in
      check_branch then_body;
      Option.iter check_branch else_body
  | _ -> ());
  List.iter (check_let_in_conditionals diagnostics) (sub_instrs i)

let check_let_bindings diagnostics fields =
  Ast_utils.iter_fields
    (fun (field : (_ modulefield, _) annotated) ->
      match field.desc with
      | Func { body = _, instrs; _ } ->
          List.iter (check_let_in_conditionals diagnostics) instrs
      | Global { def; _ } -> check_let_in_conditionals diagnostics def
      | _ -> ())
    fields

(* Check every reachable configuration of a conditional module: each is
   specialized to be conditional-free and typed independently, so a diagnostic
   is reported once with the assumption under which it is reachable. Only the
   diagnostics matter here, so the typed module is not built ([~build:false]). *)
let check_configurations ~warn_unused ~features ~simplify diagnostics fields =
  Wax_wasm.Cond_explore.check_all diagnostics
    ?truncation_location:
      (match fields with hd :: _ -> Some hd.info | [] -> None)
    ~explain:(fun env c -> Wax_wasm.Cond_solver.explain env ~style:`Wax c)
    ~specialize:(fun env asm ~enqueue ~record ->
      specialize_fields env diagnostics ~enqueue ~record asm fields)
    ~check:(fun ctx m ->
      ignore
        (type_configuration ~build:false ~warn_unused ~features ~simplify ctx m
          : _ * _))
    ()

let f ?(simplify = false) ?(warn_unused = false)
    ?(features = Wax_utils.Feature.default ()) diagnostics fields =
  Wax_utils.Debug.timed "type-check" @@ fun () ->
  check_let_bindings diagnostics fields;
  if not (List.exists field_has_conditional fields) then
    type_configuration ~warn_unused ~features ~simplify diagnostics fields
  else begin
    check_configurations ~warn_unused ~features ~simplify diagnostics fields;
    (* Build the typed module (consumed only by the deferred WAT conversion;
       validation-only paths use [check] and never reach here) by typing the
       module with conditionals preserved. [type_configuration] resolves names
       per branch (condition-aware tables), so each branch is typed under its
       own assumption. Diagnostics are discarded — [check_configurations] above
       did the real checking. *)
    type_configuration ~features ~simplify
      (Wax_utils.Diagnostic.collector ())
      fields
  end

let check ?(warn_unused = false) ?(features = Wax_utils.Feature.default ())
    diagnostics fields =
  Wax_utils.Debug.timed "type-check" @@ fun () ->
  check_let_bindings diagnostics fields;
  if not (List.exists field_has_conditional fields) then
    ignore
      (type_configuration ~build:false ~warn_unused ~features ~simplify:false
         diagnostics fields
        : _ * _)
  else
    check_configurations ~warn_unused ~features ~simplify:false diagnostics
      fields

let erase_types m =
  List.map (fun m -> { m with desc = Ast_utils.map_modulefield snd m.desc }) m
