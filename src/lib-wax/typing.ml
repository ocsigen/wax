(*
TODO:
- error messages
- locations on the heap when push several values?
- try to use declared types instead of adding <string>
- floating type String? (with default to array<i8>)
- desugar by default
- handle double casts: i31 then i32_s
- utf-16 string / js strings

Optimizations
- remove redundant type annotations/casts

Syntax changes:
- names in result type (symmetry with params)
- no need to have func type for tags (declaration tag : ty)

Syntax ideas:
- dispatch foo ['a 'b ... else 'c] { 'a { } 'b { } ... }
- br 'a (e1, ..., en) if cond   / if cond br 'a (e1, ..., en) / br_if 'a cond (...)

Misc:
- blocks in an expression context return one value;
  otherwise, no value by default
  (or infer return type when no type is given?)

Explicit types?
   fn(..)->(..)
==> for function types
==> for call_indirect
(But we don't have a cast to a typeuse in WAT)
*)

open Ast
module Cond = Wasm.Cond_solver

type typed_module_annotation = Ast.storagetype option array * Ast.location

module Output = struct
  include Output

  let valtype f t = Utils.Printer.run f (fun pp -> Output.valtype pp t)
  let instr f i = Utils.Printer.run f (fun pp -> Output.instr pp i)
end

module UnionFind = struct
  type 'a state = Link of 'a t | Root of 'a
  and 'a t = { mutable state : 'a state }

  let make v = { state = Root v }

  let rec representative node =
    match node.state with
    | Root _ -> node
    | Link next ->
        let root = representative next in
        if next != root then node.state <- Link root;
        root

  let find node =
    let root = representative node in
    match root.state with Root v -> v | Link _ -> assert false

  let merge t1 t2 new_val =
    let root1 = representative t1 in
    let root2 = representative t2 in
    if root1 == root2 then root1.state <- Root new_val
    else begin
      root1.state <- Link root2;
      root2.state <- Root new_val
    end

  let set t new_val =
    let root = representative t in
    root.state <- Root new_val
end

module Internal = Wasm.Ast.Binary.Types
module Simd = Wasm.Simd

type inferred_valtype = { typ : valtype; internal : Internal.valtype }

type inferred_type =
  | Unknown
  | Null
  | Number
  | Int8
  | Int16
  | Int
  | Float
  | Valtype of inferred_valtype

let output_inferred_type f ty =
  match UnionFind.find ty with
  | Unknown -> Format.fprintf f "any"
  | Null -> Format.fprintf f "null"
  | Number -> Format.fprintf f "number"
  | Int -> Format.fprintf f "int"
  | Int16 -> Format.fprintf f "i16"
  | Int8 -> Format.fprintf f "i8"
  | Float -> Format.fprintf f "float"
  | Valtype ty -> Output.valtype f ty.typ

module Error = struct
  open Utils

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
     so they are printed without aborting the pass. *)
  let warn ?hint ?related context ~location fmt =
    Format.kdprintf
      (fun msg ->
        Diagnostic.report context ~location ~severity:Warning ?hint ?related
          ~message:(fun f () -> msg f)
          ())
      fmt

  (* A local declared by a [let] but never read. Prefix its name with [_] to
     silence the warning. *)
  let unused_local context ~location name =
    warn context ~location "The local variable %a is never used." print_name
      name

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

  let select_type_mismatch context ~location ty1 ty2 =
    report context ~location
      "The two branches of the select does not have a common supertype. There \
       types are respectively@ @[<2>%a@]@ and@ @[<2>%a@]."
      output_inferred_type ty1 output_inferred_type ty2

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
      (Utils.Uint64.to_int64 max_offset)

  let memory_align_too_large context ~location natural =
    report context ~location
      "The memory alignment is larger than the natural alignment %d." natural

  let bad_memory_align context ~location =
    report context ~location "The memory alignment should be a power of two."

  let invalid_lane_index context ~location max_lane =
    report context ~location "The lane index should be less than %d." max_lane

  let limit_too_large context ~location kind max =
    report context ~location
      "The %s size is too large. It should be less than 0x%Lx." kind
      (Utils.Uint64.to_int64 max)

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
          Utils.Spell_check.f
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
  internal_types : Wasm.Types.t;
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
       (fun s (name_opt, _) ->
         match name_opt with
         | None -> s
         | Some name ->
             if StringSet.mem name.desc s then
               Error.duplicated_parameter d ~location:name.info name;
             StringSet.add name.desc s)
       StringSet.empty params
      : StringSet.t)

let functype d ctx { params; results } =
  check_unique_param_names d params;
  let*@ params = array_map_opt (fun (_, ty) -> valtype d ctx ty) params in
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
      let i' = Wasm.Types.add_rectype ctx.internal_types ity in
      Array.iteri
        (fun i elt ->
          let name, (typ : subtype) = elt.desc in
          Tbl.override ctx.types name (i' + i, typ))
        ty;
      Some i'

type module_context = {
  diagnostics : Utils.Diagnostic.context;
  type_context : type_context;
  subtyping_info : Wasm.Types.subtyping_info;
  types : (int * subtype) Tbl.t;
  functions : (int * string) Tbl.t;
  globals : (*mutable:*) (bool * inferred_valtype option) Tbl.t;
      (* As for [locals], the type is [None] for a global whose initializer
         failed to type — a poison global read as [Unknown] to avoid cascades. *)
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
         the [Unknown] type so its uses don't cascade into further errors. *)
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
         Wasm.Types.val_subtype ctx.subtyping_info ty ty')
  | Packed I8, Packed I16
  | Packed I16, Packed I8
  | Packed _, Value _
  | Value _, Packed _ ->
      false

let storage_subtype' ctx (ty : Wasm.Ast.Binary.storagetype)
    (ty' : Wasm.Ast.Binary.storagetype) =
  match (ty, ty') with
  | Packed I8, Packed I8 | Packed I16, Packed I16 -> true
  | Value ty, Value ty' -> Wasm.Types.val_subtype ctx.subtyping_info ty ty'
  | Packed I8, Packed I16
  | Packed I16, Packed I8
  | Packed _, Value _
  | Value _, Packed _ ->
      false

let field_subtype info (ty : Wasm.Ast.Binary.fieldtype)
    (ty' : Wasm.Ast.Binary.fieldtype) =
  ty.mut = ty'.mut
  && storage_subtype' info ty.typ ty'.typ
  && ((not ty.mut) || storage_subtype' info ty'.typ ty.typ)

(* Whether the inferred type [ty] is a subtype of the expected type [ty'].
   Not a pure relation: when the two are compatible it *unifies* their
   union-find cells (so an as-yet-unconstrained literal like [Int]/[Number]
   gets pinned to the concrete type it is checked against). [Unknown] on the
   left (error-recovery / dead code) is a subtype of anything; [Unknown] never
   appears on the right because expected types always come from a real
   declaration, annotation or instruction signature — hence the [assert]. *)
let subtype ctx ty ty' =
  let ity = UnionFind.find ty in
  let ity' = UnionFind.find ty' in
  match (ity, ity') with
  | Valtype ty, Valtype ty' ->
      Wasm.Types.val_subtype ctx.subtyping_info ty.internal ty'.internal
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
  | Float, (Null | Int | Valtype { internal = I32 | I64 | V128 | Ref _; _ })
  | (Int8 | Int16), _
  | _, (Int8 | Int16) ->
      false
  | Unknown, _ -> true
  | _, Unknown -> assert false

let cast ctx ty ty' =
  let ity = UnionFind.find ty in
  match (ity, ty') with
  | (Number | Int), Ref { typ = I31; _ } ->
      UnionFind.set ty (Valtype { typ = I32; internal = I32 });
      true
  | (Number | Int), I32 | Int, F32 ->
      UnionFind.set ty (Valtype { typ = I32; internal = I32 });
      true
  | (Number | Int), I64 | Int, F64 ->
      UnionFind.set ty (Valtype { typ = I64; internal = I64 });
      true
  | (Number | Float), F32 | Float, I32 ->
      UnionFind.set ty (Valtype { typ = F32; internal = F32 });
      true
  | (Number | Float), F64 | Float, I64 ->
      UnionFind.set ty (Valtype { typ = F64; internal = F64 });
      true
  | Null, Ref { typ = ty'; _ } ->
      (let>@ typ = top_heap_type ctx ty' in
       let ty' = Ref { nullable = true; typ } in
       let>@ ity' = valtype ctx.diagnostics ctx.type_context ty' in
       UnionFind.set ty (Valtype { typ = ty'; internal = ity' }));
      true
  | Valtype { internal = F32 | F64; _ }, (F32 | F64)
  | Valtype { internal = I32 | I64; _ }, I32
  | Valtype { internal = I64; _ }, I64
  | Valtype { internal = V128; _ }, V128
  | Valtype { internal = I32; _ }, Ref { typ = I31; _ } ->
      true
  | Valtype { internal = Ref _ as ity; _ }, Ref { typ = ty'; nullable } -> (
      Option.value ~default:true
        (let*@ typ = top_heap_type ctx ty' in
         let ty' = Ref { nullable = true; typ } in
         let+@ ity' = valtype ctx.diagnostics ctx.type_context ty' in
         Wasm.Types.val_subtype ctx.subtyping_info ity ity')
      ||
      (*ZZZ Replace nullable by non nullable if possible *)
      match ty' with
      | Extern ->
          Wasm.Types.val_subtype ctx.subtyping_info ity
            (Ref { nullable; typ = Any })
      | Any ->
          Wasm.Types.val_subtype ctx.subtyping_info ity
            (Ref { nullable; typ = Extern })
      | _ -> false)
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
  | ( (Float | Valtype { internal = I64 | F32 | F64 | V128; _ }),
      (I32 | Ref { typ = I31; _ }) )
  | (Null | Valtype { internal = Ref _; _ }), (I32 | I64 | F32 | F64 | V128)
  | Valtype { internal = V128; _ }, (I64 | F32 | F64 | Ref _)
  | (Int8 | Int16), _ ->
      false
  | Unknown, _ -> true

let signed_cast ctx ty ty' =
  let ity = UnionFind.find ty in
  match (ity, ty') with
  | (Int8 | Int16), `I32 -> true
  | Valtype { internal = Ref _ as ity; _ }, `I32 ->
      Wasm.Types.val_subtype ctx.subtyping_info ity
        (Ref { nullable = true; typ = Any })
  | Null, `I32 ->
      UnionFind.set ty
        (Valtype
           {
             typ = Ref { typ = Any; nullable = true };
             internal = Ref { typ = Any; nullable = true };
           });
      true
  | (Number | Int), `I64 ->
      UnionFind.set ty (Valtype { typ = I32; internal = I32 });
      true
  | Valtype { internal = I32; _ }, `I64
  | Valtype { internal = I32 | I64; _ }, (`F32 | `F64)
  | Valtype { internal = F32 | F64; _ }, (`I32 | `I64) ->
      true
  | (Number | Int), (`I32 | `F32 | `F64) (* Floating types can make this fail *)
  | Valtype { internal = I32; _ }, `I32
  | Valtype { internal = I64; _ }, (`I32 | `I64)
  | Valtype { internal = F32 | F64; _ }, (`F32 | `F64)
  | ( ( Int8 | Int16 | Null
      | Valtype
          {
            internal =
              Ref { typ = Type _ | None_ | Struct | Array | I31 | Eq | Any; _ };
            _;
          } ),
      (`I64 | `F32 | `F64) )
  | ( ( Float
      | Valtype
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
          } ),
      _ ) ->
      false
  | Unknown, _ -> true

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
          info = ([| UnionFind.make Unknown |], (Ast.no_loc ()).info);
        }

let pop_any ctx i st =
  match st with
  | Unreachable -> (st, UnionFind.make Unknown)
  | Cons (_, ty, r) -> (r, ty)
  | Empty ->
      Error.empty_stack ctx.diagnostics ~location:i.info;
      (st, UnionFind.make Unknown)

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
                { Utils.Diagnostic.location; message = (fun _ () -> ()) })
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
  { typ; internal }

let internalize ctx typ =
  let+@ internal = valtype ctx.diagnostics ctx.type_context typ in
  UnionFind.make (Valtype { typ; internal })

(* Check that a source element reference type can be stored where [dst] elements
   are expected (table.copy / table.init / array.init_elem): [src] must be a
   subtype of [dst]. *)
let check_elem_subtype ctx ~location ~src ~dst =
  match
    (internalize_valtype ctx (Ref src), internalize_valtype ctx (Ref dst))
  with
  | Some s, Some d ->
      if not (Wasm.Types.val_subtype ctx.subtyping_info s.internal d.internal)
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
          Utils.Spell_check.f
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
  Utils.Spell_check.f
    (fun f ->
      StringMap.iter (fun k _ -> f k) ctx.locals;
      Tbl.iter ctx.globals (fun k _ -> f k);
      Tbl.iter ctx.functions (fun k _ -> f k))
    name

let set_suggestions ctx name =
  Utils.Spell_check.f
    (fun f ->
      StringMap.iter (fun k _ -> f k) ctx.locals;
      Tbl.iter ctx.globals (fun k (mut, _) -> if mut then f k))
    name

let local_suggestions ctx name =
  Utils.Spell_check.f (fun f -> StringMap.iter (fun k _ -> f k) ctx.locals) name

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
  | _ -> Error.binop_type_mismatch ctx.diagnostics ~location typ1 typ2);
  typ1

let check_float_bin_op ctx ~location typ1 typ2 =
  (match (UnionFind.find typ1, UnionFind.find typ2) with
  | Valtype { internal = F32; _ }, Valtype { internal = F32; _ }
  | Valtype { internal = F64; _ }, Valtype { internal = F64; _ }
  | (Valtype { internal = F32 | F64; _ } | Float), (Number | Float) ->
      UnionFind.merge typ1 typ2 (UnionFind.find typ1)
  | (Number | Float), Valtype { internal = F32 | F64; _ } ->
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
      UnionFind.make Unknown

let check_subtype ctx ~location ty' ty =
  if not (subtype ctx ty' ty) then
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
  | Int | Number -> Some { typ = I32; internal = I32 }
  | Float -> Some { typ = F64; internal = F64 }
  | Null -> internalize_valtype ctx (Ref { nullable = true; typ = None_ })
  | Int8 | Int16 | Unknown -> None

(* Resolve the type that an omitted annotation takes from its initializer, as in
   [let x = e] or [const x = e]: an as-yet-unconstrained literal is pinned to a
   concrete type the way the final type erasure does (int/number -> i32,
   float -> f64, null -> nullref), so the binding gets a definite type. Mutates
   [ty] so later uses observe the resolved type. *)
let resolve_omitted_valtype ctx ty =
  match UnionFind.find ty with
  | Valtype v -> Some v
  | Int | Number | Int8 | Int16 | Unknown ->
      let v = { typ = I32; internal = I32 } in
      UnionFind.set ty (Valtype v);
      Some v
  | Float ->
      let v = { typ = F64; internal = F64 } in
      UnionFind.set ty (Valtype v);
      Some v
  | Null ->
      let+@ v =
        internalize_valtype ctx (Ref { nullable = true; typ = None_ })
      in
      UnionFind.set ty (Valtype v);
      v

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
  Wasm.Types.val_subtype ctx.subtyping_info a.internal b.internal
  && Wasm.Types.val_subtype ctx.subtyping_info b.internal a.internal

(* Bidirectional checking helpers (see [check] below).

   The keep-bool for a non-construction value: the contextual annotation is
   load-bearing unless the value's own standalone-resolved type ([standalone],
   captured BEFORE [check_type] mutates the cell) already equals it. This
   mirrors exactly the drop test [bind_let_value]/globals applied via
   [standalone_valtype], so routing those sites through [check] preserves their
   behaviour — e.g. [let x: i32 = 1] still drops to [let x = 1] (a floating
   number resolves to [i32]), while [let x: i64 = 1] keeps its annotation. *)
let annotation_needed ctx (standalone : inferred_valtype option) expected =
  match (standalone, UnionFind.find expected) with
  | Some v, Valtype b -> not (valtype_equal ctx v b)
  | _ -> true

(* Whether [expected] carries a real type expectation (vs. the [Unknown]
   sentinel used when [check] is entered from synthesis with no context).
   [subtype] asserts on an [Unknown] right-hand side, so callers guard with
   this before checking against [expected]. *)
let has_expectation expected = UnionFind.find expected <> Unknown

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
          (* An [Unknown] initializer means its typing already failed; record
             the local as poison ([None]) rather than defaulting it to [i32], so
             later uses do not cascade into spurious mismatches. *)
          let ity =
            if UnionFind.find result_ty = Unknown then None
            else resolve_omitted_valtype ctx result_ty
          in
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
      match (Wasm.Types.get_subtype ctx.subtyping_info ty).typ with
      | Cont ft -> (
          match (Wasm.Types.get_subtype ctx.subtyping_info ft).typ with
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
          (fun i p -> Wasm.Types.val_subtype info ft'.params.(i) p)
          ft.params)
  && Array.for_all Fun.id
       (Array.mapi
          (fun i r -> Wasm.Types.val_subtype info r ft'.results.(i))
          ft.results)

(* A source function type with its parameter and result types resolved to their
   canonical (Binary) form, for structural comparison with [functype_matches]. *)
let internal_functype ctx (ft : functype) : Internal.functype option =
  let*@ params =
    array_map_opt
      (fun (_, t) ->
        let+@ iv = internalize_valtype ctx t in
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
  let internal_of_inferred ty =
    match UnionFind.find ty with
    | Valtype { internal; _ } -> Some internal
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
                Array.iteri
                  (fun i (_, t) ->
                    match
                      (internalize_valtype ctx t, internal_of_inferred ts'.(i))
                    with
                    | Some it, Some it' ->
                        if not (Wasm.Types.val_subtype info it.internal it')
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
  (* [dispatch], [while] and [do]-[while] are block-like: their operands and
     bodies are checked inside the blocks they desugar to, so no hole at this
     level draws from the stack. *)
  | Block _ | Loop _ | While _ | DoWhile _ | TryTable _ | Try _
  | If_annotation _ | Dispatch _ | StructDefault _ | Char _ | String _ | Int _
  | Float _ | Get _ | Null | Unreachable | Nop
  | Let (_, None)
  | Br (_, None)
  | Throw (_, None)
  | Return None ->
      0

let rec check_hole_order_rec ctx i n =
  match i.desc with
  | Hole -> n - 1
  | Cast (i, _) when UnionFind.find (expression_type ctx i) = Unknown ->
      (* Casts in unreachable code should be ignored: they are here to
         guide the translation but are not emitted. *)
      check_hole_order_rec ctx i n
  | _ when n <= 0 -> n
  | _ ->
      let n =
        match i.desc with
        | Block _ | Loop _ | While _ | DoWhile _ | TryTable _ | Try _
        | If_annotation _ | Dispatch _ | StructDefault _ | Char _ | String _
        | Int _ | Float _ | Get _ | Null | Unreachable | Nop
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
    (UnionFind.make Unknown, [||]))
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

let address_valtype (at : [ `I32 | `I64 ]) : inferred_valtype =
  match at with
  | `I32 -> { typ = I32; internal = I32 }
  | `I64 -> { typ = I64; internal = I64 }

(* Expected operand/result type of a SIMD intrinsic, as a fresh type cell. *)
let simd_valtype : Simd.ty -> inferred_valtype = function
  | TV128 -> { typ = V128; internal = V128 }
  | TI32 -> { typ = I32; internal = I32 }
  | TI64 -> { typ = I64; internal = I64 }
  | TF32 -> { typ = F32; internal = F32 }
  | TF64 -> { typ = F64; internal = F64 }

let simd_cell t = UnionFind.make (Valtype (simd_valtype t))

(* Memory access method names. The value width is in the name; signedness and the
   i32/i64 result come from a surrounding [as iN_s/u] cast (see [to_wasm]). *)
let mem_load_result meth : inferred_type option =
  match meth with
  | "load8" -> Some Int8
  | "load16" -> Some Int16
  | "load32" -> Some (Valtype { typ = I32; internal = I32 })
  | "load64" -> Some (Valtype { typ = I64; internal = I64 })
  | "loadf32" -> Some (Valtype { typ = F32; internal = F32 })
  | "loadf64" -> Some (Valtype { typ = F64; internal = F64 })
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
let int_literal a =
  match a.Ast.desc with
  | Ast.Int s -> ( try Some (Utils.Uint64.of_string s) with _ -> None)
  | _ -> None

let max_offset_i32_exclusive = Utils.Uint64.of_string "0x1_0000_0000" (* 2^32 *)
let max_align = Utils.Uint64.of_int 16

(* Validate the trailing [align]/[offset] literals of a memory access against
   the access's natural alignment (in bytes) and the address type. Mirrors
   [Validation.check_memarg]. [align] and [offset] are the corresponding
   argument expressions, when present. *)
let check_memarg ctx ~address_type ~natural ~align ~offset =
  (let>@ offset = offset in
   let>@ o = int_literal offset in
   if
     address_type = `I32 && Utils.Uint64.compare o max_offset_i32_exclusive >= 0
   then
     Error.memory_offset_too_large ctx.diagnostics ~location:(snd offset.info)
       max_offset_i32_exclusive);
  let>@ align = align in
  let>@ a = int_literal align in
  if Utils.Uint64.compare a max_align > 0 || Utils.Uint64.to_int a > natural
  then
    Error.memory_align_too_large ctx.diagnostics ~location:(snd align.info)
      natural
  else
    match Utils.Uint64.to_int a with
    | 1 | 2 | 4 | 8 | 16 -> ()
    | _ -> Error.bad_memory_align ctx.diagnostics ~location:(snd align.info)

let max_memory_size = function
  | `I32 -> Utils.Uint64.of_int 65536
  | `I64 -> Utils.Uint64.of_string "0x1_0000_0000_0000"

let max_table_size = function
  | `I32 -> Utils.Uint64.of_string "0xffff_ffff"
  | `I64 -> Utils.Uint64.of_string "0xffff_ffff_ffff_ffff"

(* Validate a memory/table size limit. Mirrors [Validation.limits]. *)
let check_limits ctx ~location kind address_type limits max_fn =
  match limits with
  | None -> ()
  | Some (mi, ma) -> (
      let max = max_fn address_type in
      match ma with
      | None ->
          if Utils.Uint64.compare mi max > 0 then
            Error.limit_too_large ctx.diagnostics ~location kind max
      | Some ma ->
          if Utils.Uint64.compare mi ma > 0 then
            Error.limit_mismatch ctx.diagnostics ~location kind;
          if Utils.Uint64.compare ma max > 0 then
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
    (fun (_, t) ->
      vt t;
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

(* Likewise for a [do]-[while] lowering (see [Ast_utils.lower_dowhile]): drop the
   synthesised loop and the trailing [br_if] back-edge. *)
let rebuild_dowhile typed_list =
  match typed_list with
  | [ { desc = Ast.Loop { block; _ }; _ } ] -> (
      match List.rev block with
      | { desc = Ast.Br_if (_, cond); _ } :: rev_body ->
          (cond, List.rev rev_body)
      | _ -> assert false)
  | _ -> assert false

(* Set to [true] to trace each instruction as it is type-checked. *)
let debug = false

let rec instruction ctx i : 'a list -> 'a list * (_, _ array * _) annotated =
  if debug then Format.eprintf "%a@." Output.instr i;
  match i.desc with
  | Block { label; typ; block = instrs } ->
      (* An expression-position block draws nothing from a stack, so a parameter
         type has no source; report it, then recover by supplying the declared
         parameters anyway so the body does not underflow into spurious "stack
         empty" errors. (With no parameters this is the empty stack, unchanged.) *)
      if Array.length typ.params > 0 then
        Error.parameterized_block_expression ctx.diagnostics ~location:i.info;
      let*! params =
        array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
      in
      let*! results = array_map_opt (internalize ctx) typ.results in
      let instrs' = block ctx i.info label params results results instrs in
      return_statement i (Block { label; typ; block = instrs' }) results
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
  | Loop { label; typ; block = instrs } ->
      if Array.length typ.params > 0 then
        Error.parameterized_block_expression ctx.diagnostics ~location:i.info;
      let*! params =
        array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
      in
      let*! results = array_map_opt (internalize ctx) typ.results in
      let instrs' = block ctx i.info label params results params instrs in
      return_statement i (Loop { label; typ; block = instrs' }) results
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
  | DoWhile { label; block = instrs; cond } ->
      (* Likewise via [Ast_utils.lower_dowhile]: validate the body and the
         trailing [br_if] condition, then rebuild a typed [DoWhile]. *)
      let lowered =
        Ast_utils.lower_dowhile ~block_info:i.info ~label ~cond ~block:instrs
      in
      let typed = block ctx i.info None [||] [||] [||] lowered in
      let cond', instrs' = rebuild_dowhile typed in
      return_statement i (DoWhile { label; block = instrs'; cond = cond' }) [||]
  | If { label; typ; cond; if_block; else_block } ->
      let* cond' = instruction ctx cond in
      check_type ctx cond'
        (UnionFind.make (Valtype { typ = I32; internal = I32 }));
      if Array.length typ.params > 0 then
        Error.parameterized_block_expression ctx.diagnostics ~location:i.info;
      let*! params =
        array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
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
        results
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
  | TryTable { label; typ; block = body; catches } ->
      if Array.length typ.params > 0 then
        Error.parameterized_block_expression ctx.diagnostics ~location:i.info;
      let*! params =
        array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
      in
      let*! results = array_map_opt (internalize ctx) typ.results in
      let body' = block ctx i.info label params results results body in
      (* Catching an exception passes the tag's values (and, for the [_ref]
         variants, the exception reference) to the handler's branch target, so
         they must match that target. Report at the target label rather than at
         the whole [try], and frame it as a handler/target mismatch. *)
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
                array_map_opt (fun (_, typ) -> internalize ctx typ) params
              in
              check_catch params label
          | CatchRef (tag, label) ->
              let>@ { params; results = r } =
                Tbl.find ctx.diagnostics ctx.tags tag
              in
              if r <> [||] then
                Error.tag_with_results ctx.diagnostics ~location:tag.info;
              let>@ params =
                array_map_opt (fun (_, typ) -> internalize ctx typ) params
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
        catches;
      return_statement i
        (TryTable { label; typ; block = body'; catches })
        results
  | Try { label; typ; block = body; catches; catch_all } ->
      assert (typ.params = [||]);
      let*! results = array_map_opt (internalize ctx) typ.results in
      let body' = block ctx i.info label [||] results results body in
      let catches =
        List.filter_map
          (fun (tag, body) ->
            let*@ { params; results = r } =
              Tbl.find ctx.diagnostics ctx.tags tag
            in
            if r <> [||] then
              Error.tag_with_results ctx.diagnostics ~location:tag.info;
            let+@ params =
              array_map_opt (fun (_, typ) -> internalize ctx typ) params
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
      return_statement i
        (Try { label; typ; block = body'; catches; catch_all })
        results
  | (Unreachable | Nop) as desc ->
      (* [unreachable] and [nop] are statements that yield no value; they are
         only meaningful in statement (top-level) position, where
         [toplevel_instruction] handles them. Reaching here means one was used
         where a value is expected, so report it and recover with an unknown
         value. *)
      Error.not_an_expression ctx.diagnostics ~location:i.info 0;
      return_expression i desc (UnionFind.make Unknown)
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
            (* A poison local ([None]) reads as [Unknown] so its uses don't
               cascade. *)
            UnionFind.make
              (match ty with Some ity -> Valtype ity | None -> Unknown)
        | Global (_, ty) ->
            UnionFind.make
              (match ty with Some ity -> Valtype ity | None -> Unknown)
        | Func_ref (ty, ty') ->
            UnionFind.make
              (Valtype
                 {
                   typ = Ref { nullable = false; typ = Type (Ast.no_loc ty') };
                   internal = Ref { nullable = false; typ = Type ty };
                 })
        | Unbound ->
            Error.unbound_name ctx.diagnostics ~location:idx.info
              ~suggestions:(get_suggestions ctx idx.desc)
              "variable" idx;
            UnionFind.make Unknown
      in
      return_expression i desc ty
  | Set (None, i') ->
      let* i' = instruction ctx i' in
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
            let* i', _ = check ctx (UnionFind.make (Valtype ity)) i' in
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
          let* i', _ = check ctx typ i' in
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
             array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
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
      | Unknown ->
          (* The callee already failed to type; recover without a spurious
             "expected function type". *)
          return_statement i (TailCall (i', l')) [||]
      | _ ->
          Error.expected_func_type ctx.diagnostics ~location:i.info;
          return_statement i (TailCall (i', l')) [||])
  | Char _ as desc ->
      return_expression i desc
        (UnionFind.make (Valtype { typ = I32; internal = I32 }))
  | String (ty, _) as desc ->
      let ty =
        match ty with
        | None -> { i with desc = "<string>" }
        | Some ty ->
            (let>@ field = lookup_array_type ctx ty in
             match field.typ with
             | Value (I32 | I64 | F32 | F64) | Packed _ -> ()
             | Value (Ref _ | V128) -> assert false (*ZZZ*));
            ty
      in
      let*! typ = internalize ctx (Ref { nullable = false; typ = Type ty }) in
      return_expression i desc typ
  | Int _ as desc -> return_expression i desc (UnionFind.make Number)
  | Float _ as desc -> return_expression i desc (UnionFind.make Float)
  | Cast (i', typ) ->
      let* i' = instruction ctx i' in
      let ty' = expression_type ctx i' in
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
      let*! ty =
        internalize ctx
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
      (* Drop a cast the inferred types already make redundant. This is only
         desirable when converting from Wasm ([ctx.simplify]): there casts are
         inserted to pin types and precise inference makes some unnecessary. For
         hand-written Wax (formatting, or compiling to Wasm) we keep casts as
         written.
         ZZZ Handle select instruction better *)
      let unnecessary_cast =
        ctx.simplify && UnionFind.find ty' <> Unknown && subtype ctx ty' ty
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
        (UnionFind.make (Valtype { typ = I32; internal = I32 }))
  (* Construction literals carry an optional type name that can be inferred from
     an expected type. Their typing lives in [check]; in synthesis position
     there is no expectation, so [check] against the [Unknown] sentinel keeps a
     present name and reports [cannot_infer_*] when one is omitted. *)
  | Struct _ | StructDefault _ | Array _ | ArrayDefault _ | ArrayFixed _
  | ArraySegment _ ->
      let* i', _ = check ctx (UnionFind.make Unknown) i in
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
        (* Leave an unresolved receiver alone (its own error, if any, is
           reported elsewhere): keep the access with an unknown result type
           rather than giving up, which would drop a hole receiver and desync
           hole counting. A name that is an instruction method was likely meant
           as the parenthesised call [x.sqrt()]; any other field access on a
           non-struct type has no fields to find. *)
        | Unknown, _ -> Some (UnionFind.make Unknown)
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
        | Unknown ->
            (* Receiver already failed to type; recover without a spurious
               "expected struct type". *)
            None
        | _ ->
            Error.expected_struct_type ctx.diagnostics ~location:i1.info;
            None
      in
      let* i2' =
        match expected with
        | Some cell ->
            let* i2', _ = check ctx cell i2 in
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
        (UnionFind.make (Valtype { typ = I32; internal = I32 }));
      match UnionFind.find (expression_type ctx i1') with
      | Valtype { typ = Ref { typ = Type ty; _ }; _ } ->
          let*! typ = lookup_array_type ~location:i1.info ctx ty in
          let*! ty = field_read_type ctx typ in
          return_expression i (ArrayGet (i1', i2')) ty
      | Unknown ->
          (* Receiver already failed to type; recover silently. *)
          return_expression i (ArrayGet (i1', i2')) (UnionFind.make Unknown)
      | _ ->
          Error.expected_array_type ctx.diagnostics ~location:i1.info;
          return_expression i (ArrayGet (i1', i2')) (UnionFind.make Unknown))
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
            let* i3', _ = check ctx cell i3 in
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
        (UnionFind.make (Valtype { typ = I32; internal = I32 }));
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
                let* i3', _ = check ctx cell i3 in
                return i3'
            | None -> instruction ctx i3
          in
          return_statement i (ArraySet (i1', i2', i3')) [||]
      | Unknown ->
          (* Receiver already failed to type; recover silently (still type the
             value so its holes are consumed). *)
          let* i3' = instruction ctx i3 in
          return_statement i (ArraySet (i1', i2', i3')) [||]
      | _ ->
          let* i3' = instruction ctx i3 in
          Error.expected_array_type ctx.diagnostics ~location:i1.info;
          return_statement i (ArraySet (i1', i2', i3')) [||])
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
        | Unknown, Unknown -> (
            match op.desc with
            | Add | Sub | Mul ->
                UnionFind.merge ty1 ty2 Number;
                ty1
            | Div (Some _) | Rem _ | And | Or | Xor | Shl | Shr _ ->
                UnionFind.merge ty1 ty2 Int;
                ty1
            | Lt (Some _) | Gt (Some _) | Le (Some _) | Ge (Some _) | Eq | Ne ->
                UnionFind.merge ty1 ty2 (Valtype { typ = I32; internal = I32 });
                UnionFind.make (Valtype { typ = I32; internal = I32 })
            | Div None ->
                UnionFind.merge ty1 ty2 Float;
                ty1
            | Lt None | Gt None | Le None | Ge None ->
                UnionFind.merge ty1 ty2 (Valtype { typ = F32; internal = F32 });
                UnionFind.make (Valtype { typ = I32; internal = I32 }))
        | typ, Unknown | Unknown, typ -> (
            UnionFind.merge ty1 ty2 typ;
            match op.desc with
            | Eq ->
                (match typ with
                | Valtype { internal = Ref _ as ty; _ } ->
                    if
                      not
                        (Wasm.Types.val_subtype ctx.subtyping_info ty
                           (Ref { nullable = true; typ = Eq }))
                    then mismatch ()
                | Null ->
                    UnionFind.set ty1
                      (Valtype
                         {
                           typ = Ref { nullable = true; typ = Eq };
                           internal = Ref { nullable = true; typ = Eq };
                         })
                | Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }
                | Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }
                | Number | Int | Float ->
                    ()
                | _ -> mismatch ());
                UnionFind.make (Valtype { typ = I32; internal = I32 })
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
                UnionFind.make (Valtype { typ = I32; internal = I32 })
            | Lt None | Gt None | Le None | Ge None ->
                (match typ with
                | Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }
                | Float ->
                    ()
                | Number -> UnionFind.set ty1 Float
                | _ -> mismatch ());
                UnionFind.make (Valtype { typ = I32; internal = I32 })
            | Ne ->
                (match typ with
                | Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }
                | Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }
                | Number | Int | Float ->
                    ()
                | _ -> mismatch ());
                UnionFind.make (Valtype { typ = I32; internal = I32 }))
        | _ -> (
            match op.desc with
            | Eq ->
                (match (UnionFind.find ty1, UnionFind.find ty2) with
                | ( Valtype { internal = Ref _ as ty1; _ },
                    Valtype { internal = Ref _ as ty2; _ } ) ->
                    if
                      not
                        (Wasm.Types.val_subtype ctx.subtyping_info ty1
                           (Ref { nullable = true; typ = Eq })
                        && Wasm.Types.val_subtype ctx.subtyping_info ty2
                             (Ref { nullable = true; typ = Eq }))
                    then mismatch ()
                | Valtype { internal = Ref _ as typ1; _ }, Null ->
                    if
                      not
                        (Wasm.Types.val_subtype ctx.subtyping_info typ1
                           (Ref { nullable = true; typ = Eq }))
                    then mismatch ();
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | Null, Valtype { internal = Ref _ as typ2; _ } ->
                    if
                      not
                        (Wasm.Types.val_subtype ctx.subtyping_info typ2
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
                | (Valtype { internal = F32 | F64; _ } | Float), (Number | Float)
                | Number, Number ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty1)
                | (Number | Int), Valtype { internal = I32 | I64; _ }
                | (Number | Float), Valtype { internal = F32 | F64; _ } ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | _ -> mismatch ());
                UnionFind.make (Valtype { typ = I32; internal = I32 })
            | Add | Sub | Mul ->
                (match (UnionFind.find ty1, UnionFind.find ty2) with
                | Valtype { internal = I32; _ }, Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }, Valtype { internal = I64; _ }
                | Valtype { internal = F32; _ }, Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }, Valtype { internal = F64; _ }
                  ->
                    ()
                | (Valtype { internal = I32 | I64; _ } | Int), (Number | Int)
                | (Valtype { internal = F32 | F64; _ } | Float), (Number | Float)
                | Number, Number ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty1)
                | (Number | Int), Valtype { internal = I32 | I64; _ }
                | (Number | Float), Valtype { internal = F32 | F64; _ } ->
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
                | _ -> mismatch ());
                UnionFind.make (Valtype { typ = I32; internal = I32 })
            | Lt None | Gt None | Le None | Ge None ->
                (match (UnionFind.find ty1, UnionFind.find ty2) with
                | Valtype { internal = F32; _ }, Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }, Valtype { internal = F64; _ }
                | (Valtype { internal = F32 | F64; _ } | Float), (Number | Float)
                  ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty1)
                | (Number | Float), Valtype { internal = F32 | F64; _ } ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | Number, Number -> UnionFind.merge ty1 ty2 Float
                | _ -> mismatch ());
                UnionFind.make (Valtype { typ = I32; internal = I32 })
            | Ne ->
                (match (UnionFind.find ty1, UnionFind.find ty2) with
                | Valtype { internal = I32; _ }, Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }, Valtype { internal = I64; _ }
                | Valtype { internal = F32; _ }, Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }, Valtype { internal = F64; _ }
                  ->
                    ()
                | (Valtype { internal = I32 | I64; _ } | Int), (Number | Int)
                | (Valtype { internal = F32 | F64; _ } | Float), (Number | Float)
                | Number, Number ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty1)
                | (Number | Int), Valtype { internal = I32 | I64; _ }
                | (Number | Float), Valtype { internal = F32 | F64; _ } ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | _ -> mismatch ());
                UnionFind.make (Valtype { typ = I32; internal = I32 }))
      in
      return_expression i (BinOp (op, i1', i2')) ty
  | UnOp (op, i') ->
      let* i' = instruction ctx i' in
      let typ = expression_type ctx i' in
      let ty =
        match UnionFind.find typ with
        | Unknown -> (
            match op.desc with
            | Not -> UnionFind.make (Valtype { typ = I32; internal = I32 })
            | Neg | Pos -> UnionFind.make Number)
        | _ -> (
            match op.desc with
            | Not ->
                (match UnionFind.find typ with
                | Valtype { internal = I32 | I64 | Ref _; _ } | Null | Int -> ()
                | Number -> UnionFind.set typ Int
                | _ ->
                    Error.instruction_type_mismatch ctx.diagnostics
                      ~location:op.info typ (UnionFind.make Int));
                UnionFind.make (Valtype { typ = I32; internal = I32 })
            | Neg | Pos ->
                (match UnionFind.find typ with
                | Valtype { internal = I32 | I64 | F32 | F64; _ }
                | Int | Float | Number ->
                    ()
                | _ ->
                    Error.instruction_type_mismatch ctx.diagnostics
                      ~location:op.info typ (UnionFind.make Number));
                typ)
      in
      return_expression i (UnOp (op, i')) ty
  | Let ([ (name_opt, Some annot) ], Some i') -> (
      (* Bidirectional single annotated binding: type the initializer in
         checking mode against the annotation, so an omitted struct/array name
         is inferred from it; the keep-bool then says whether the annotation is
         load-bearing. Dropping a present annotation stays gated on [simplify]
         (Wasm->Wax), so hand-written Wax is never rewritten. *)
      match internalize_valtype ctx annot with
      | None ->
          let* i' = instruction ctx i' in
          return_statement i (Let ([ (name_opt, Some annot) ], Some i')) [||]
      | Some ity ->
          let* i', needed = check ctx (UnionFind.make (Valtype ity)) i' in
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
                  else UnionFind.make Unknown
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
        (UnionFind.make (Valtype { typ = I32; internal = I32 }));
      let params = branch_target ctx label in
      check_subtypes ctx ~location:loc types params;
      return_statement i (Br_if (label, i')) params
  | Br_table (labels, i') ->
      let* i' = instruction ctx i' in
      let loc = snd i'.info in
      let ty, types = split_on_last_type ctx ~location:loc i' in
      check_subtype ctx ~location:loc ty
        (UnionFind.make (Valtype { typ = I32; internal = I32 }));
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
            } ->
            UnionFind.make
              (Valtype
                 {
                   typ = Ref { nullable = false; typ };
                   internal = Ref { nullable = false; typ = ityp };
                 })
        | Unknown -> UnionFind.make Unknown
        | _ ->
            Error.expected_ref ctx.diagnostics ~location:(snd i'.info);
            UnionFind.make Unknown
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
      | Unknown -> ()
      | Valtype
          {
            typ = Ref { nullable = _; typ; _ };
            internal = Ref { nullable = _; typ = ityp; _ };
          } ->
          check_subtypes ctx ~location:(snd i'.info)
            (Array.append types
               [|
                 UnionFind.make
                   (Valtype
                      {
                        typ = Ref { nullable = false; typ };
                        internal = Ref { nullable = false; typ = ityp };
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
         UnionFind.make (Valtype { typ = Ref ty; internal = Ref ityp })
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
        | Unknown -> Some (typ', UnionFind.make Unknown)
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
        | Unknown -> Some (typ', UnionFind.make Unknown)
        | _ ->
            Error.expected_ref ctx.diagnostics ~location:(snd i'.info);
            None
      in
      let params = branch_target ctx label in
      check_subtypes ctx ~location:(snd i'.info)
        (Array.append types [| typ2 |])
        params;
      let typ =
        UnionFind.make (Valtype { typ = Ref ty; internal = Ref ityp })
      in
      return_statement i
        (Br_on_cast_fail
           ( label,
             ty,
             { i' with info = (Array.append types [| typ1 |], snd i'.info) } ))
        (Array.append (Array.sub params 0 (Array.length params - 1)) [| typ |])
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
         array_map_opt (fun (_, typ) -> internalize ctx typ) params
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
           (fun (_, typ) -> internalize ctx typ)
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
         array_map_opt (fun (_, typ) -> internalize ctx typ) params
       in
       check_operands ctx l' ptypes);
      let*! rtypes = array_map_opt (internalize ctx) results in
      return_statement i (Suspend (tag, l')) rtypes
  | Resume (ct, handlers, l) ->
      let* l' = instructions ctx l in
      let*! inner = lookup_cont_inner ctx ct in
      let*! sg = lookup_func_type ctx inner in
      (let>@ ptypes =
         array_map_opt (fun (_, typ) -> internalize ctx typ) sg.params
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
         array_map_opt (fun (_, typ) -> internalize ctx typ) tparams
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
             (fun (_, typ) -> internalize ctx typ)
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
        match if np = 0 then None else Some (snd sg.params.(np - 1)) with
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
                      Wasm.Types.val_subtype ctx.subtyping_info t b.(i))
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
        array_map_opt (fun (_, typ) -> internalize ctx typ) result_params
      in
      return_statement i (Switch (ct, tag, l')) rtypes
  | NonNull i' -> (
      let* i' = instruction ctx i' in
      match UnionFind.find (expression_type ctx i') with
      | Valtype
          {
            typ = Ref { nullable = _; typ; _ };
            internal = Ref { nullable = _; typ = ityp; _ };
          } ->
          return_expression i (NonNull i')
            (UnionFind.make
               (Valtype
                  {
                    typ = Ref { nullable = false; typ };
                    internal = Ref { nullable = false; typ = ityp };
                  }))
      | Unknown -> return_expression i (NonNull i') (expression_type ctx i')
      | _ ->
          Error.expected_ref ctx.diagnostics ~location:(snd i'.info);
          return_expression i (NonNull i') (UnionFind.make Unknown))
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
        (UnionFind.make (Valtype { typ = I32; internal = I32 }));
      let*! ty =
        let ty1 = expression_type ctx i2' in
        let ty2 = expression_type ctx i3' in
        match (UnionFind.find ty1, UnionFind.find ty2) with
        | _, Unknown -> Some ty1
        | Unknown, _ -> Some ty2
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
                Error.select_type_mismatch ctx.diagnostics ~location:i.info ty1
                  ty2;
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
            Error.select_type_mismatch ctx.diagnostics ~location:i.info ty1 ty2;
            None
      in
      return_expression i (Select (i1', i2', i3')) ty

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
                  (UnionFind.make (Valtype { typ = I64; internal = I64 }))
            | "storef32" ->
                check_type ctx value'
                  (UnionFind.make (Valtype { typ = F32; internal = F32 }))
            | "storef64" ->
                check_type ctx value'
                  (UnionFind.make (Valtype { typ = F64; internal = F64 }))
            | _ -> (
                match UnionFind.find vty with
                | Valtype { internal = I32 | I64; _ } | Int | Number | Unknown
                  ->
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
     if Utils.Uint64.to_int l >= max_lane then
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
  let i32 () = UnionFind.make (Valtype { typ = I32; internal = I32 }) in
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
  let i32 () = UnionFind.make (Valtype { typ = I32; internal = I32 }) in
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
  check_type ctx n' (UnionFind.make (Valtype { typ = I32; internal = I32 }));
  check_type ctx j' (UnionFind.make (Valtype { typ = I32; internal = I32 }));
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
  | Unknown -> (* receiver already failed to type; recover silently *) ()
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
  check_type ctx n' (UnionFind.make (Valtype { typ = I32; internal = I32 }));
  check_type ctx i2' (UnionFind.make (Valtype { typ = I32; internal = I32 }));
  let ty' = expression_type ctx a2' in
  check_type ctx i1' (UnionFind.make (Valtype { typ = I32; internal = I32 }));
  let ty = expression_type ctx a1' in
  (match (UnionFind.find ty, UnionFind.find ty') with
  | Unknown, _ | _, Unknown -> ()
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
  let i32 = UnionFind.make (Valtype { typ = I32; internal = I32 }) in
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
  | Unknown -> (* receiver already failed to type; recover silently *) ()
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
            Some (UnionFind.make (Valtype { typ = I32; internal = I32 }))
        | Struct _ | Func _ | Cont _ ->
            Error.expected_array_type ctx.diagnostics ~location:i.info;
            None)
    | (Null | Valtype { typ = Ref { typ = Array; _ }; _ }), "length" ->
        Some (UnionFind.make (Valtype { typ = I32; internal = I32 }))
    | Valtype { typ = I32; _ }, "from_bits" ->
        Some (UnionFind.make (Valtype { typ = F32; internal = F32 }))
    | Valtype { typ = I64; _ }, "from_bits" ->
        Some (UnionFind.make (Valtype { typ = F64; internal = F64 }))
    | Valtype { typ = F32; _ }, "to_bits" ->
        Some (UnionFind.make (Valtype { typ = I32; internal = I32 }))
    | Valtype { typ = F64; _ }, "to_bits" ->
        Some (UnionFind.make (Valtype { typ = I64; internal = I64 }))
    | ( ((Number | Int | Valtype { typ = I32 | I64; _ }) as ty'),
        ("clz" | "ctz" | "popcnt" | "extend8_s" | "extend16_s") ) ->
        if ty' = Number then UnionFind.set ty Int;
        Some ty
    | ( ((Number | Float | Valtype { typ = F32 | F64; _ }) as ty'),
        ("abs" | "ceil" | "floor" | "trunc" | "nearest" | "sqrt") ) ->
        if ty' = Number then UnionFind.set ty Float;
        Some ty
    | Unknown, _ -> Some (UnionFind.make Unknown)
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
        if Utils.Uint64.to_int l >= bound then
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
      List.iter
        (fun a ->
          match a.desc with
          | Ast.Int _ | Ast.Float _ -> ()
          | Ast.UnOp ({ desc = Neg; _ }, { desc = Ast.Int _ | Ast.Float _; _ })
            ->
              ()
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
   [check] is entered from [instruction] with no context (synthesis). *)
and check ctx expected (i : location instr) =
  let i32_cell () = UnionFind.make (Valtype { typ = I32; internal = I32 }) in
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
    let result = internalize ctx (Ref { nullable = false; typ = Type name }) in
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
               [Unknown] result. *)
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
              (UnionFind.make Unknown)
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
                            let* i', _ = check ctx cell i' in
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
      return (node, true)
  | StructDefault ty ->
      let* node =
        match
          resolve_name ty ~missing:(fun () ->
              Error.cannot_infer_struct_type ctx.diagnostics ~location:i.info)
        with
        | None ->
            return_expression i (StructDefault None) (UnionFind.make Unknown)
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
            return_expression i
              (Array (None, i1', i2'))
              (UnionFind.make Unknown)
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
                  let* i1', _ = check ctx cell i1 in
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
            return_expression i
              (ArrayDefault (None, n'))
              (UnionFind.make Unknown)
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
              (UnionFind.make Unknown)
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
                        let* i', _ = check ctx cell i' in
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
              (UnionFind.make Unknown)
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
  | Cast (e, typ) when is_null_initializer e ->
      fun st ->
        let st, i' = instruction ctx i st in
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
        (st, (i', true))
  | _ ->
      fun st ->
        let st, i' = instruction ctx i st in
        (* Capture the value's own standalone-resolved type BEFORE [check_type]
           mutates the cell, then decide whether the annotation is load-bearing
           (see [annotation_needed]). *)
        let standalone = standalone_valtype ctx (expression_type ctx i') in
        let needed = annotation_needed ctx standalone expected in
        if has_expectation expected then check_type ctx i' expected;
        (st, (i', needed))

(* Run [check] in statement (empty-stack) position, mirroring the expression
   bridge in [toplevel_instruction]'s default arm: pop the hole operands off the
   stack into the parameter list, run [check] on them, and surface its keep-bool.
   Used for an annotated global initializer (a constant expression). *)
and check_toplevel ctx expected i =
  let count = count_holes i in
  let* args = pop_many ctx i count [] in
  let args, (i', needed) = check ctx expected i args in
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
          array_map_opt (fun (_, vt) -> internalize ctx vt) ft.params
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
            let* a', _ = check ctx params.(k) a in
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
  | [| ty |] ->
      let* i', _ = check ctx ty i in
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
         array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
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
  | Unknown ->
      (* The callee already failed to type (e.g. an unbound name); recover
         silently rather than adding a spurious "expected function type". *)
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
        array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
      in
      let*! results = array_map_opt (internalize ctx) typ.results in
      let* () = pop_args ctx ~location:i.info params in
      let instrs' = block ctx i.info label params results results instrs in
      return_statement i (Block { label; typ; block = instrs' }) results
  | Loop { label; typ; block = instrs } ->
      let*! params =
        array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
      in
      let*! results = array_map_opt (internalize ctx) typ.results in
      let* () = pop_args ctx ~location:i.info params in
      let instrs' = block ctx i.info label params results params instrs in
      return_statement i (Loop { label; typ; block = instrs' }) results
  | If { label; typ; cond; if_block; else_block } ->
      let* cond = toplevel_instruction ctx cond in
      check_type ctx cond
        (UnionFind.make (Valtype { typ = I32; internal = I32 }));
      let*! params =
        array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
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
        array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
      in
      let*! results = array_map_opt (internalize ctx) typ.results in
      let* () = pop_args ctx ~location:i.info params in
      let body' = block ctx i.info label params results results body in
      (* Catching an exception passes the tag's values (and, for the [_ref]
         variants, the exception reference) to the handler's branch target, so
         they must match that target. Report at the target label rather than at
         the whole [try], and frame it as a handler/target mismatch. *)
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
                array_map_opt (fun (_, typ) -> internalize ctx typ) params
              in
              check_catch params label
          | CatchRef (tag, label) ->
              let>@ { params; results = r } =
                Tbl.find ctx.diagnostics ctx.tags tag
              in
              if r <> [||] then
                Error.tag_with_results ctx.diagnostics ~location:tag.info;
              let>@ params =
                array_map_opt (fun (_, typ) -> internalize ctx typ) params
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
        catches;
      return_statement i
        (TryTable { label; typ; block = body'; catches })
        results
  | Try { label; typ; block = body; catches; catch_all } ->
      let*! params =
        array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
      in
      let*! results = array_map_opt (internalize ctx) typ.results in
      let* () = pop_args ctx ~location:i.info params in
      let body' = block ctx i.info label params results results body in
      let catches =
        List.filter_map
          (fun (tag, body) ->
            let*@ { params; results = r } =
              Tbl.find ctx.diagnostics ctx.tags tag
            in
            if r <> [||] then
              Error.tag_with_results ctx.diagnostics ~location:tag.info;
            let+@ params =
              array_map_opt (fun (_, typ) -> internalize ctx typ) params
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

and block_contents ctx results l =
  match l with
  | [] -> return []
  | [ i ]
    when Array.length results = 1
         &&
         match i.desc with
         | Struct _ | StructDefault _ | Array _ | ArrayDefault _ | ArrayFixed _
         | ArraySegment _ ->
             true
         | Cast (e, _) -> is_null_initializer e
         | _ -> false ->
      (* The block's value is a trailing construction literal or null cast;
         check it against the single result type so it can be inferred / drop
         its name or redundant cast, just like a [return]. Only these
         single-value forms are routed this way, so a divergent or void trailing
         statement is never disturbed. *)
      let* i', _ = check_toplevel ctx results.(0) i in
      let* () =
        push_results
          (Array.to_list (Array.map (fun ty -> (i.info, ty)) (fst i'.info)))
      in
      return [ i' ]
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

let check_type_definitions ctx =
  (*ZZZ In-order check? *)
  Tbl.iter ctx.types (fun _ (i, (st : subtype)) ->
      let ty = Wasm.Types.get_subtype ctx.subtyping_info i in
      (* A continuation type must wrap a function type. Point at the wrapped
         type as the source wrote it. *)
      (match (ty.typ, st.typ) with
      | Cont ft, Cont src_ref -> (
          match (Wasm.Types.get_subtype ctx.subtyping_info ft).typ with
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
          let ty' = Wasm.Types.get_subtype ctx.subtyping_info j in
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
                         Wasm.Types.val_subtype ctx.subtyping_info p' p)
                       params params'
                  && Array.for_all2
                       (fun r r' ->
                         Wasm.Types.val_subtype ctx.subtyping_info r r')
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
                  Wasm.Types.heap_subtype ctx.subtyping_info (Type ft)
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
              (Wasm.Types.val_subtype ctx.subtyping_info internal
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
              (Wasm.Types.val_subtype ctx.subtyping_info internal
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
  | Block _ | Loop _ | While _ | DoWhile _ | If _ | TryTable _ | Try _
  | Dispatch _ | Unreachable | Nop | Hole | Set _ | Tee _ | Call _ | TailCall _
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
                        Utils.Spell_check.f
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
                        Utils.Spell_check.f
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
                   floating type — see [is_null_initializer]). *)
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
                        (check_toplevel ctx (UnionFind.make (Valtype ity)) def)
                    in
                    Tbl.add ctx.diagnostics ctx.globals name (mut, Some ity);
                    let drop =
                      ctx.simplify && (not needed)
                      && not (is_null_initializer def')
                    in
                    ((if drop then None else Some annot), def'))
            | None ->
                (* No annotation: the global takes the initializer's type, the
                   way a [let] binding without an annotation does. An [Unknown]
                   initializer (its typing failed) makes the global poison
                   ([None]) rather than defaulting to [i32], so its uses do not
                   cascade. *)
                let def' =
                  with_empty_stack ctx ~location:def.info ~kind:Expression
                    (toplevel_instruction ctx def)
                in
                let ity =
                  if UnionFind.find (expression_type ctx def') = Unknown then
                    None
                  else resolve_omitted_valtype ctx (expression_type ctx def')
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
                (fun (id, typ) ->
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
      internal_types = Wasm.Types.create ();
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
      subtyping_info = Wasm.Types.subtyping_info type_context.internal_types;
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
      subtyping_info = Wasm.Types.subtyping_info type_context.internal_types;
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
                    | Unknown -> None
                    | Null ->
                        Some (Value (Ref { nullable = true; typ = None_ }))
                    | Number -> Some (Value I32)
                    | Int8 -> Some (Packed I8)
                    | Int16 -> Some (Packed I16)
                    | Int -> Some (Value I32)
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
  | DoWhile { block; cond; _ } -> any block || instr_has_conditional cond
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
  let module S = Wasm.Cond_solver in
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
    | DoWhile { label; block; cond } ->
        DoWhile { label; block = sinstrs asm block; cond = sone asm cond }
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
  | While { cond; block; _ } | DoWhile { block; cond; _ } -> cond :: block
  | If { cond; if_block; else_block; _ } ->
      (cond :: if_block.desc)
      @ Option.fold ~none:[] ~some:(fun b -> b.desc) else_block
  | Try { block; catches; catch_all; _ } ->
      block @ List.concat_map snd catches @ Option.value ~default:[] catch_all
  | If_annotation { then_body; else_body; _ } ->
      then_body @ Option.value ~default:[] else_body
  | Sequence l | ArrayFixed (_, l) -> l
  | Dispatch { index; arms; _ } -> index :: List.concat_map snd arms
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
  Utils.Debug.timed "type-check" @@ fun () ->
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
    Wasm.Cond_explore.check_all diagnostics
      ?truncation_location:
        (match fields with hd :: _ -> Some hd.info | [] -> None)
      ~explain:(fun env c -> Wasm.Cond_solver.explain env ~style:`Wax c)
      ~specialize:(fun env asm ~enqueue ~record ->
        specialize_fields env diagnostics ~enqueue ~record asm fields)
      ~check:(fun ctx m -> ignore (type_configuration ~simplify ctx m))
      ();
    (* Build the typed module (consumed only by the deferred WAT conversion;
       wax -> wax ignores it) by typing the module with conditionals preserved.
       [type_configuration] resolves names per branch (condition-aware tables),
       so each branch is typed under its own assumption. Diagnostics are
       discarded — the exploration above did the real checking. *)
    type_configuration ~simplify (Utils.Diagnostic.collector ()) fields
  end

let erase_types m =
  List.map (fun m -> { m with desc = Ast_utils.map_modulefield snd m.desc }) m
