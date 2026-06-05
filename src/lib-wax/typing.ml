(*
TODO:
- Check that import correspond to a declaration
- fix typeuse validation (add a type if not already present)
  + typeuse when converting to binary
- error messages
- locations on the heap when push several values?
- more methods rather than global functions (no ambiguity)?
  rotl(..), rotr(..), min(..), max(..), copysign(..)
- try to use declared types instead of adding <string>
- floating type String? (with default to array<i8>)
- desugar by default
- handle double casts: i31 then i32_s
- utf-16 string / js strings
- suggestion for unknown keywords 

Optimizations
- move lets at more appropriate places
- remove redundant type annotations/casts
- option to tighten casts to any/extern / eliminate redundant casts
  and type annotations

Comments
- process the flow of tokens
  => keep track of the line of the previous token
  => comment/newline ==>
     register in a side table the blank lines and comments,
     and do not propagate
- emission:
  before: grab all the comment/newline before the current location /
          output comments
  after: grab all the comment/newline after the current location and
     before the next sibling (and in the parent); split a last newline;
     push back the comments after last newline;
     output comments

Syntax changes:
- names in result type (symmetry with params)
- no need to have func type for tags (declaration tag : ty)
- we may not need Sequence (change branch expressions instead)

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

Typing with conditionals:
- when a conditional is encountered, refine the assumptions to take
  the first branch (if possible) and register that the other branch
  needs to be visited.
  A --> A /\ B
        A /\ not B
- store somehow a mapping conditional branch ==> code
- to transform the code, we need to cover all the branches; to type,
  we need to test all combinations
==> take a branch which is not covered. find a condition so that it is
    covered and run the typer again with this assumption
vs
==> stack of possible conditions; when we encounter a branch, we split
    the current condition in two, push one one the stack, and continue
    with the other
*)

open Ast

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

  let empty_stack context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () -> Format.fprintf f "The stack is empty.")
      ()

  let non_empty_stack context ~location output_stack =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "Some values remain on the stack:%a" output_stack ())
      ()

  let expected_func_type context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () -> Format.fprintf f "Expected function type.")
      ()

  let expected_struct_type context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () -> Format.fprintf f "Expected struct type.")
      ()

  let expected_array_type context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () -> Format.fprintf f "Expected array type.")
      ()

  let _type_mismatch context ~location ty' ty =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "Expecting type@ @[<2>%a@]@ but got type@ @[<2>%a@]."
          output_inferred_type ty output_inferred_type ty')
      ()

  let not_an_expression context ~location n =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "An expression is expected here. This instruction returns %d values."
          n)
      ()

  let instruction_type_mismatch context ~location ty ty' =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "This instruction has type@ @[<2>%a@]@ but is expected to have type@ \
           @[<2>%a@]."
          output_inferred_type ty output_inferred_type ty')
      ()

  let select_type_mismatch context ~location ty1 ty2 =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f
          "The two branches of the select does not have a common supertype. \
           There types are respectively@ @[<2>%a@]@ and@ @[<2>%a@]."
          output_inferred_type ty1 output_inferred_type ty2)
      ()

  let name_already_bound context ~location kind x =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "A %s named %a is already bound." kind print_name x)
      ()

  let unbound_name context ~location kind x =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "The %s %a is not bound." kind print_name x)
      ()

  let before_hole context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "This expression occurs before a hole '_'.")
      ()

  let unsupported_tuple_type context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "Tuple types are not supported yet.")
      ()

  let duplicated_field context ~location x =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "Several fields have the same name %a." print_name x)
      ()

  let duplicated_parameter context ~location x =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "Several parameters have the same name %a." print_name
          x)
      ()

  let constant_expression_required context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "Only constant expressions are allowed here.")
      ()

  let constant_global_required context ~location =
    Diagnostic.report context ~location ~severity:Error
      ~message:(fun f () ->
        Format.fprintf f "Only accessing a constant global is allowed here.")
      ()
end

module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

let ( let*@ ) = Option.bind
let ( let+@ ) o f = Option.map f o
let ( let>@ ) o f = Option.iter f o

module Namespace = struct
  type t = (string, string * location) Hashtbl.t

  let make () = Hashtbl.create 16

  let exists d ns x =
    match Hashtbl.find_opt ns x.desc with
    | None -> false
    | Some (kind, _) ->
        Error.name_already_bound d ~location:x.info kind x;
        true

  let register d ns kind x =
    match Hashtbl.find_opt ns x.desc with
    | None -> Hashtbl.replace ns x.desc (kind, x.info)
    | Some (kind', _loc') -> Error.name_already_bound d ~location:x.info kind' x
end

module Tbl = struct
  type 'a t = {
    kind : string;
    namespace : Namespace.t;
    tbl : (string, 'a) Hashtbl.t;
  }

  let make namespace kind = { kind; namespace; tbl = Hashtbl.create 16 }

  let add d env x v =
    Namespace.register d env.namespace env.kind x;
    Hashtbl.replace env.tbl x.desc v

  let exists d env x = Namespace.exists d env.namespace x
  let override env x v = Hashtbl.replace env.tbl x.desc v

  let find d env x =
    try Some (Hashtbl.find env.tbl x.desc)
    with Not_found ->
      Error.unbound_name d ~location:x.info env.kind x;
      None

  let find_opt env x = Hashtbl.find_opt env.tbl x.desc
  let iter env f = Hashtbl.iter f env.tbl
  let remove env x = Hashtbl.remove env.tbl x.desc
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
  | Tuple _ ->
      Error.unsupported_tuple_type d ~location:(Ast.no_loc ()).info;
      None

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

let functype d ctx { params; results } =
  let _ : StringSet.t =
    Array.fold_left
      (fun s (name_opt, _) ->
        match name_opt with
        | None -> s
        | Some name ->
            if StringSet.mem name.desc s then
              Error.duplicated_parameter d ~location:name.info name;
            StringSet.add name.desc s)
      StringSet.empty params
  in
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
          (fun s (name, _) ->
            if StringSet.mem name.desc s then
              Error.duplicated_field d ~location:name.info name;
            StringSet.add name.desc s)
          StringSet.empty fields
      in
      let+@ fields = array_map_opt (fun (_, ty) -> fieldtype d ctx ty) fields in
      (Struct fields : Internal.comptype)
  | Array field ->
      let+@ field = fieldtype d ctx field in
      (Array field : Internal.comptype)

let subtype d ctx current { typ; supertype; final } =
  let*@ typ = comptype d ctx typ in
  let+@ supertype =
    match supertype with
    | None -> Some None
    | Some ty ->
        let+@ ty = resolve_type_name d ctx ty in
        assert (ty > lnot current);
        Some ty
  in
  { Internal.typ; supertype; final }

let rectype d ctx ty = array_mapi_opt (fun i (_, ty) -> subtype d ctx i ty) ty

let add_type d ctx ty =
  Array.iteri
    (fun i (name, (typ : subtype)) -> Tbl.add d ctx.types name (lnot i, typ))
    ty;
  match rectype d ctx ty with
  | None ->
      (* Remove temporary names on failure *)
      Array.iter (fun (name, _) -> Tbl.remove ctx.types name) ty;
      None
  | Some ity ->
      let i' = Wasm.Types.add_rectype ctx.internal_types ity in
      Array.iteri
        (fun i (name, (typ : subtype)) ->
          Tbl.override ctx.types name (i' + i, typ))
        ty;
      Some i'

type module_context = {
  diagnostics : Utils.Diagnostic.context;
  type_context : type_context;
  subtyping_info : Wasm.Types.subtyping_info;
  types : (int * subtype) Tbl.t;
  functions : (int * string) Tbl.t;
  globals : (*mutable:*) (bool * inferred_valtype) Tbl.t;
  tags : functype Tbl.t; (*  memories : limits Tbl.t;*)
  mutable locals : inferred_valtype StringMap.t;
  control_types : (string option * inferred_type UnionFind.t array) list;
  return_types : inferred_type UnionFind.t array;
}

let lookup_func_type ?location ctx name =
  let*@ ty = Tbl.find_opt ctx.type_context.types name in
  match (snd ty).typ with
  | Func f -> Some f
  | Struct _ | Array _ ->
      Error.expected_func_type ctx.diagnostics
        ~location:(Option.value ~default:name.info location);
      None

let lookup_struct_type ?location ctx name =
  let*@ ty = Tbl.find_opt ctx.type_context.types name in
  match (snd ty).typ with
  | Struct fields -> Some fields
  | Func _ | Array _ ->
      Error.expected_struct_type ctx.diagnostics
        ~location:(Option.value ~default:name.info location);
      None

let lookup_array_type ?location ctx name =
  let*@ ty = Tbl.find_opt ctx.type_context.types name in
  match (snd ty).typ with
  | Array field -> Some field
  | Func _ | Struct _ ->
      Error.expected_array_type ctx.diagnostics
        ~location:(Option.value ~default:name.info location);
      None

let top_heap_type ctx (t : heaptype) : heaptype option =
  match t with
  | Any | Eq | I31 | Struct | Array | None_ -> Some Any
  | Func | NoFunc -> Some Func
  | Exn | NoExn -> Some Exn
  | Extern | NoExtern -> Some Extern
  | Type ty -> (
      let+@ ty = Tbl.find ctx.diagnostics ctx.types ty in
      match (snd ty).typ with Struct _ | Array _ -> Any | Func _ -> Func)

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
              ( I32 | I64 | F32 | F64 | V128
              | Ref { nullable = false; _ }
              | Tuple _ );
            _;
          } ) )
  | Valtype _, Null
  | Valtype { internal = V128 | Ref _ | Tuple _; _ }, Number
  | Valtype { internal = F32 | F64 | V128 | Ref _ | Tuple _; _ }, Int
  | Valtype { internal = I32 | I64 | V128 | Ref _ | Tuple _; _ }, Float
  | ( Number,
      (Null | Int | Float | Valtype { internal = V128 | Ref _ | Tuple _; _ }) )
  | ( Int,
      ( Null | Float
      | Valtype { internal = F32 | F64 | V128 | Ref _ | Tuple _; _ } ) )
  | ( Float,
      (Null | Int | Valtype { internal = I32 | I64 | V128 | Ref _ | Tuple _; _ })
    )
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
              ( Func | NoFunc | Exn | NoExn | Extern | NoExtern | Any | Eq
              | Array | Struct | Type _ | None_ );
            _;
          }
      | V128 | Tuple _ ) )
  | Valtype { internal = F32 | F64; _ }, (I32 | I64)
  | Valtype { internal = I32 | I64; _ }, (F32 | F64)
  | Valtype { internal = I32; _ }, I64
  | ( (Float | Valtype { internal = I64 | F32 | F64 | V128; _ }),
      (I32 | Ref { typ = I31; _ }) )
  | ( (Null | Valtype { internal = Ref _; _ }),
      (I32 | I64 | F32 | F64 | V128 | Tuple _) )
  | Valtype { internal = V128; _ }, (I64 | F32 | F64 | Ref _ | Tuple _)
  | Valtype { internal = Tuple _; _ }, _
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
              | Ref { typ = Func | NoFunc | Exn | NoExn | Extern | NoExtern; _ }
              | Tuple _ );
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
let pop ctx ty st =
  match st with
  | Unreachable -> (st, ())
  | Cons (_, ty', r) ->
      let ok = subtype ctx ty' ty in
      if not ok then
        Format.eprintf "%a <: %a@." output_inferred_type ty'
          output_inferred_type ty;
      assert ok;
      (r, ())
  | Empty ->
      (*ZZZ*)
      Error.empty_stack ctx.diagnostics ~location:(Ast.no_loc ()).info;
      (st, ())

let pop_args ctx args =
  Array.fold_right
    (fun ty rem ->
      let* () = rem in
      pop ctx ty)
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
  (*ZZZ*)
  if false then prerr_endline "START";
  let st, res = f Empty in
  if false then prerr_endline "DONE";
  (match st with
  | Cons _ ->
      Error.non_empty_stack ctx.diagnostics ~location (fun f () ->
          Format.fprintf f "@[%a@]" output_stack st)
  | Empty | Unreachable -> ());
  res

let internalize_valtype ctx typ =
  let+@ internal = valtype ctx.diagnostics ctx.type_context typ in
  { typ; internal }

let internalize ctx typ =
  let+@ internal = valtype ctx.diagnostics ctx.type_context typ in
  UnionFind.make (Valtype { typ; internal })

let fieldtype ctx (f : fieldtype) =
  match f.typ with
  | Value typ -> internalize ctx typ
  | Packed I8 -> Some (UnionFind.make Int8)
  | Packed I16 -> Some (UnionFind.make Int16)

let unpack_type (f : fieldtype) =
  match f.typ with Value v -> v | Packed _ -> I32

let branch_target ctx label =
  let rec find l label =
    match l with
    | [] -> assert false (* ZZZ *)
    | (Some label', res) :: _ when label.desc = label' -> res
    | _ :: rem -> find rem label
  in
  find ctx.control_types label

let check_int_bin_op typ1 typ2 =
  (match (UnionFind.find typ1, UnionFind.find typ2) with
  | Valtype { internal = I32; _ }, Valtype { internal = I32; _ }
  | Valtype { internal = I64; _ }, Valtype { internal = I64; _ }
  | (Valtype { internal = I32 | I64; _ } | Int), (Number | Int) ->
      UnionFind.merge typ1 typ2 (UnionFind.find typ1)
  | (Number | Int), Valtype { internal = I32 | I64; _ } ->
      UnionFind.merge typ1 typ2 (UnionFind.find typ2)
  | Number, Number -> UnionFind.merge typ1 typ2 Int
  | _ -> assert false (*ZZZ*));
  typ1

let check_float_bin_op typ1 typ2 =
  (match (UnionFind.find typ1, UnionFind.find typ2) with
  | Valtype { internal = F32; _ }, Valtype { internal = F32; _ }
  | Valtype { internal = F64; _ }, Valtype { internal = F64; _ }
  | (Valtype { internal = F32 | F64; _ } | Float), (Number | Float) ->
      UnionFind.merge typ1 typ2 (UnionFind.find typ1)
  | (Number | Float), Valtype { internal = F32 | F64; _ } ->
      UnionFind.merge typ1 typ2 (UnionFind.find typ2)
  | Number, Number -> UnionFind.merge typ1 typ2 Float
  | _ -> assert false (*ZZZ*));
  typ1

let field_has_default (ty : fieldtype) =
  match ty.typ with
  | Packed _ -> true
  | Value ty -> (
      match ty with
      | I32 | I64 | F32 | F64 | V128 -> true
      | Ref { nullable; _ } -> nullable
      | Tuple _ -> assert false)

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

let check_subtype ctx ty' ty =
  let ok = subtype ctx ty' ty in
  if not ok then
    Format.eprintf "%a <: %a@." output_inferred_type ty' output_inferred_type ty;
  assert ok

let check_subtypes ctx types' types =
  assert (Array.length types' = Array.length types);
  Array.iter2 (fun ty' ty -> check_subtype ctx ty' ty) types' types

let check_type ctx i ty =
  let ty' = expression_type ctx i in
  let ok = subtype ctx ty' ty in
  if not ok then
    Error.instruction_type_mismatch ctx.diagnostics ~location:(snd i.info) ty'
      ty

let rec count_holes i =
  match i.desc with
  | Hole -> 1
  | BinOp (_, l, r) | Array (_, l, r) | ArrayGet (l, r) ->
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
  | Return (Some i)
  | StructGet (i, _) ->
      count_holes i
  | StructSet (i1, _, i2) -> count_holes i1 + count_holes i2
  | Struct (_, l) -> List.fold_left (fun acc (_, i) -> acc + count_holes i) 0 l
  | Sequence l | ArrayFixed (_, l) ->
      List.fold_left (fun acc i -> acc + count_holes i) 0 l
  | Select (c, t, e) -> count_holes c + count_holes t + count_holes e
  | Block _ | Loop _ | TryTable _ | Try _ | StructDefault _ | Char _ | String _
  | Int _ | Float _ | Get _ | Null | Unreachable | Nop
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
        | Block _ | Loop _ | TryTable _ | Try _ | StructDefault _ | Char _
        | String _ | Int _ | Float _ | Get _ | Null | Unreachable | Nop
        | Let (_, None)
        | Br (_, None)
        | Throw (_, None)
        | Return None ->
            n
        | BinOp (_, l, r) | Array (_, l, r) | ArrayGet (l, r) ->
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
        | Return (Some i)
        | StructGet (i, _) ->
            check_hole_order_rec ctx i n
        | StructSet (i1, _, i2) ->
            n |> check_hole_order_rec ctx i1 |> check_hole_order_rec ctx i2
        | Sequence l | ArrayFixed (_, l) -> check_hole_order_in_list ctx l n
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
                        (fun (name, _) -> StringMap.find name.desc field_map)
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

let split_on_last_type i =
  let a = fst i.info in
  let len = Array.length a in
  assert (len > 0);
  (a.(len - 1), Array.sub a 0 (len - 1))

let immediate_supertype s : Ast.heaptype =
  match (s.supertype, s.typ) with
  | Some t, _ -> Type t
  | None, Struct _ -> Struct
  | None, Array _ -> Array
  | None, Func _ -> Func

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
  | ( (None_ | Eq | I31 | Struct | Array | Any),
      (NoExtern | Extern | NoExn | Exn | NoFunc | Func) )
  | ( (NoExtern | Extern | NoExn | Exn | NoFunc | Func),
      (None_ | Eq | I31 | Struct | Array | Any) )
  | (NoFunc | Func), (NoExtern | Extern | NoExn | Exn)
  | (NoExtern | Extern | NoExn | Exn), (NoFunc | Func)
  | (NoExtern | Extern), (NoExn | Exn)
  | (NoExn | Exn), (NoExtern | Extern) ->
      None

let val_lub ctx v1 v2 =
  match (v1, v2) with
  | Ref r1, Ref r2 ->
      let+@ lub = heap_lub ctx r1.typ r2.typ in
      let nullable = r1.nullable || r2.nullable in
      Ref { nullable; typ = lub }
  | _ -> if v1 = v2 then Some v1 else None

let rec instruction ctx i : 'a list -> 'a list * (_, _ array * _) annotated =
  (*
  let* () = print_stack in
*)
  if false then Format.eprintf "%a@." Output.instr i;
  match i.desc with
  | Block { label; typ; block = instrs } ->
      (*ZZZ Blocks take argument from the stack *)
      assert (typ.params = [||]);
      let*! results = array_map_opt (internalize ctx) typ.results in
      let instrs' = block ctx i.info label [||] results results instrs in
      return_statement i (Block { label; typ; block = instrs' }) results
  | Loop { label; typ; block = instrs } ->
      assert (typ.params = [||]);
      let*! results = array_map_opt (internalize ctx) typ.results in
      let instrs' = block ctx i.info label [||] results [||] instrs in
      return_statement i (Loop { label; typ; block = instrs' }) results
  | If { label; typ; cond; if_block; else_block } ->
      let* cond' = instruction ctx cond in
      assert (typ.params = [||]);
      (*ZZZ*)
      let*! results = array_map_opt (internalize ctx) typ.results in
      let if_block' = block ctx i.info label [||] results results if_block in
      let else_block' =
        Option.map
          (fun b -> block ctx i.info label [||] results results b)
          else_block
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
  | TryTable { label; typ; block = body; catches } ->
      assert (typ.params = [||]);
      let*! results = array_map_opt (internalize ctx) typ.results in
      let body' = block ctx i.info label [||] results results body in
      let check_catch types label =
        let params = branch_target ctx label in
        check_subtypes ctx types params
      in
      List.iter
        (fun catch ->
          match catch with
          | Catch (tag, label) ->
              let>@ { params; results = r } =
                Tbl.find ctx.diagnostics ctx.tags tag
              in
              assert (r = [||]);
              let>@ params =
                array_map_opt (fun (_, typ) -> internalize ctx typ) params
              in
              check_catch params label
          | CatchRef (tag, label) ->
              let>@ { params; results = r } =
                Tbl.find ctx.diagnostics ctx.tags tag
              in
              assert (r = [||]);
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
            assert (r = [||]);
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
  | Unreachable ->
      (* ZZZ Only at top_level *)
      return_statement i Unreachable [||]
  | Nop ->
      (* ZZZ Only at top_level *)
      return_statement i Nop [||]
  | Hole ->
      let* ty = pop_parameter in
      return_expression i Hole ty
  | Null -> return_expression i Null (UnionFind.make Null)
  | Get idx as desc ->
      let ty =
        match StringMap.find_opt idx.desc ctx.locals with
        | Some ty -> ty
        | None -> (
            match Tbl.find_opt ctx.globals idx with
            | Some (_, ty) -> ty
            | None -> (
                match Tbl.find_opt ctx.functions idx with
                | Some (ty, ty') ->
                    {
                      typ =
                        Ref { nullable = false; typ = Type (Ast.no_loc ty') };
                      internal = Ref { nullable = false; typ = Type ty };
                    }
                | None ->
                    Format.eprintf "%a@." Output.instr i;
                    assert false))
      in
      return_expression i desc (UnionFind.make (Valtype ty))
  | Set (None, i') ->
      let* i' = instruction ctx i' in
      return_statement i (Set (None, i')) [||]
  | Set (Some idx, i') ->
      let ty =
        match StringMap.find_opt idx.desc ctx.locals with
        | Some ty -> ty
        | None -> (
            match Tbl.find_opt ctx.globals idx with
            | Some (mut, ty) ->
                assert mut;
                (*ZZZ*)
                ty
            | None -> (
                match Tbl.find_opt ctx.functions idx with
                | Some _ -> assert false (*ZZZ*)
                | None -> assert false))
      in
      let* i' = instruction ctx i' in
      check_type ctx i' (UnionFind.make (Valtype ty));
      return_statement i (Set (Some idx, i')) [||]
  | Tee (idx, i') ->
      let* i' = instruction ctx i' in
      (*ZZZ local *)
      let ty =
        match StringMap.find_opt idx.desc ctx.locals with
        | Some ty -> UnionFind.make (Valtype ty)
        | None -> (
            match Tbl.find_opt ctx.globals idx with
            | Some _ -> assert false
            (*ZZZ*)
            | None -> (
                match Tbl.find_opt ctx.functions idx with
                | Some _ -> assert false (*ZZZ*)
                | None -> assert false))
      in
      check_type ctx i' ty;
      return_expression i (Tee (idx, i')) ty
  | Call
      ( ({ desc = StructGet (a, ({ desc = "fill"; _ } as meth)); _ } as func),
        [ j; v; n ] ) ->
      let* a' = instruction ctx a in
      let* j' = instruction ctx j in
      let* v' = instruction ctx v in
      let* n' = instruction ctx n in
      check_type ctx n' (UnionFind.make (Valtype { typ = I32; internal = I32 }));
      check_type ctx j' (UnionFind.make (Valtype { typ = I32; internal = I32 }));
      (match UnionFind.find (expression_type ctx a') with
      | Valtype { typ = Ref { typ = Type ty; _ }; _ } ->
          let>@ typ = lookup_array_type ctx ty in
          assert typ.mut;
          let>@ ty = internalize ctx (unpack_type typ) in
          let ty' = expression_type ctx v' in
          let ok = subtype ctx ty' ty in
          if not ok then
            Format.eprintf "%a <: %a@." output_inferred_type ty'
              output_inferred_type ty;
          assert ok
      | _ -> assert false (*ZZZ*));
      return_statement i
        (Call
           ( {
               desc = StructGet (a', meth);
               info = ([| (*ignored*) |], func.info);
             },
             [ j'; v'; n' ] ))
        [||]
  | Call
      ( ({ desc = StructGet (a1, ({ desc = "copy"; _ } as meth)); _ } as func),
        [ i1; a2; i2; n ] ) ->
      let* a1' = instruction ctx a1 in
      let* i1' = instruction ctx i1 in
      let* a2' = instruction ctx a2 in
      let* i2' = instruction ctx i2 in
      let* n' = instruction ctx n in
      check_type ctx n' (UnionFind.make (Valtype { typ = I32; internal = I32 }));
      check_type ctx i2'
        (UnionFind.make (Valtype { typ = I32; internal = I32 }));
      let ty' = expression_type ctx a2' in
      check_type ctx i1'
        (UnionFind.make (Valtype { typ = I32; internal = I32 }));
      let ty = expression_type ctx a1' in
      (match (UnionFind.find ty, UnionFind.find ty') with
      | Unknown, _ | _, Unknown -> ()
      | ( Valtype { typ = Ref { typ = Type ty; _ }; _ },
          Valtype { typ = Ref { typ = Type ty'; _ }; _ } ) ->
          let>@ typ = lookup_array_type ~location:a1.info ctx ty in
          let>@ typ' = lookup_array_type ~location:a2.info ctx ty' in
          assert typ.mut;
          let ok = storage_subtype ctx typ'.typ typ.typ in
          assert ok
      | _ -> assert false (*ZZZ*));
      return_statement i
        (Call
           ( {
               desc = StructGet (a1', meth);
               info = ([| (*unused*) |], func.info);
             },
             [ i1'; a2'; i2'; n' ] ))
        [||]
  | Call
      ( ({ desc = Get ({ desc = "rotl" | "rotr"; _ } as meth); _ } as func),
        [ i1; i2 ] ) ->
      let* i1' = instruction ctx i1 in
      let* i2' = instruction ctx i2 in
      let ty =
        check_int_bin_op (expression_type ctx i1') (expression_type ctx i2')
      in
      return_expression i
        (Call
           ( { desc = Get meth; info = ([| (*unused*) |], func.info) },
             [ i1'; i2' ] ))
        ty
  | Call
      ( ({ desc = Get ({ desc = "copysign" | "min" | "max"; _ } as meth); _ } as
         func),
        [ i1; i2 ] ) ->
      let* i1' = instruction ctx i1 in
      let* i2' = instruction ctx i2 in
      let ty =
        check_float_bin_op (expression_type ctx i1') (expression_type ctx i2')
      in
      return_expression i
        (Call
           ( { desc = Get meth; info = ([| (*unused*) |], func.info) },
             [ i1'; i2' ] ))
        ty
  | Call (i', l) -> (
      let* l' = instructions ctx l in
      let* i' = instruction ctx i' in
      match UnionFind.find (expression_type ctx i') with
      | Valtype { typ = Ref { typ = Type ty; _ }; _ } ->
          let*! typ = lookup_func_type ctx ty in
          (let>@ param_types =
             array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
           in
           assert (Array.length param_types = List.length l');
           Array.iter2
             (fun i ty -> check_type ctx i ty)
             (Array.of_list l') param_types);
          let*! returned_types = array_map_opt (internalize ctx) typ.results in
          return_statement i (Call (i', l')) returned_types
      | _ -> assert false (*ZZZ*))
  | TailCall (i', l) -> (
      let* l' = instructions ctx l in
      let* i' = instruction ctx i' in
      match UnionFind.find (expression_type ctx i') with
      | Valtype { typ = Ref { typ = Type ty; _ }; _ } ->
          let*! typ = lookup_func_type ctx ty in
          (let>@ param_types =
             array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
           in
           assert (Array.length param_types = List.length l');
           Array.iter2
             (fun i ty -> check_type ctx i ty)
             (Array.of_list l') param_types);
          (let>@ returned_types = array_map_opt (internalize ctx) typ.results in
           check_subtypes ctx returned_types ctx.return_types);
          return_statement i (TailCall (i', l')) [||]
      | _ ->
          Format.eprintf "%a@." Output.instr i;
          assert false)
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
             | Value (Ref _ | V128 | Tuple _) -> assert false (*ZZZ*));
            ty
      in
      let*! typ = internalize ctx (Ref { nullable = false; typ = Type ty }) in
      return_expression i desc typ
  | Int _ as desc -> return_expression i desc (UnionFind.make Number)
  | Float _ as desc -> return_expression i desc (UnionFind.make Float)
  | Cast (i', typ) ->
      let* i' = instruction ctx i' in
      let ty' = expression_type ctx i' in
      let*! ty =
        internalize ctx
          (match typ with
          | Valtype typ -> typ
          | Signedtype { typ; _ } -> (
              match typ with
              | `I32 -> I32
              | `I64 -> I64
              | `F32 -> F32
              | `F64 -> F64))
      in
      let () =
        match typ with
        | Valtype typ ->
            let ok = cast ctx ty' typ in
            if not ok then (
              Format.eprintf "%a@." Output.instr i;
              Format.eprintf "cast %a => %a@." output_inferred_type ty'
                Output.valtype typ);
            assert ok
        | Signedtype { typ; _ } ->
            let ok = signed_cast ctx ty' typ in
            if not ok then (
              Format.eprintf "%a@." Output.instr i;
              Format.eprintf "signed cast %a => %s@." output_inferred_type ty'
                (match typ with
                | `I32 -> "i32"
                | `I64 -> "i64"
                | `F32 -> "f32"
                | `F64 -> "f64"));
            assert ok
      in
      (* We skip unnecessary cast:
         - when converting to Wax, we introduce them to avoid loosing
           type information
         - when converting to Wasm, we add precise types, so some
           casts used to resolve ambiguities become unnecessary.
         ZZZ Handle select instruction better
         ZZZ Do not do it when just formatting the code
      *)
      let unnecessary_cast =
        UnionFind.find ty' <> Unknown && subtype ctx ty' ty
      in
      if unnecessary_cast then return { i' with info = ([| ty |], snd i'.info) }
      else return_expression i (Cast (i', typ)) ty
  | Test (i, ty) ->
      let* i' = instruction ctx i in
      (let>@ typ = top_heap_type ctx ty.typ in
       let>@ typ = internalize ctx (Ref { nullable = true; typ }) in
       check_type ctx i' typ);
      return_expression i
        (Test (i', ty))
        (UnionFind.make (Valtype { typ = I32; internal = I32 }))
  | Struct (ty, fields) -> (
      match ty with
      | None -> assert false (*ZZZ*)
      | Some typ ->
          let*! field_types = lookup_struct_type ctx typ in
          (* ZZZ We should check the evaluation order*)
          assert (List.length fields = Array.length field_types);
          (*ZZZ*)
          let* fields' =
            Array.fold_left
              (fun prev (name, (f : fieldtype)) ->
                match
                  List.find_opt (fun (idx, _) -> name.desc = idx.desc) fields
                with
                | None -> assert false (*ZZZ*)
                | Some (name, i') ->
                    let* l = prev in
                    let* i' = instruction ctx i' in
                    (let>@ typ = internalize ctx (unpack_type f) in
                     check_type ctx i' typ);
                    return ((name, i') :: l))
              (return []) field_types
          in
          let*! typ =
            internalize ctx (Ref { nullable = false; typ = Type typ })
          in
          return_expression i (Struct (ty, List.rev fields')) typ)
  | StructDefault ty as desc -> (
      match ty with
      | None -> assert false (*ZZZ*)
      | Some ty ->
          let*! fields = lookup_struct_type ctx ty in
          (*ZZZ*)
          assert (Array.for_all (fun (_, ty) -> field_has_default ty) fields);
          let*! typ =
            internalize ctx (Ref { nullable = false; typ = Type ty })
          in
          return_expression i desc typ)
  | StructGet (i', field) ->
      let* i' = instruction ctx i' in
      let*! ty =
        let ty = expression_type ctx i' in
        match (UnionFind.find ty, field.desc) with
        | Valtype { typ = Ref { typ = Type ty; _ }; _ }, _ -> (
            let*@ _, def = Tbl.find_opt ctx.type_context.types ty in
            match def.typ with
            | Struct fields ->
                let*@ typ =
                  Array.find_map
                    (fun (nm, typ) ->
                      if nm.desc = field.desc then Some typ else None)
                    fields
                in
                fieldtype ctx typ
            | Array _ when field.desc = "length" ->
                Some (UnionFind.make (Valtype { typ = I32; internal = I32 }))
            | Func _ | Array _ ->
                (*ZZZ Fix location*)
                if field.desc = "length" then
                  Error.expected_array_type ctx.diagnostics ~location:ty.info
                else
                  Error.expected_struct_type ctx.diagnostics ~location:ty.info;
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
            ("clz" | "ctz" | "popcnt") ) ->
            if ty' = Number then UnionFind.set ty Int;
            Some ty
        | ( ((Number | Float | Valtype { typ = F32 | F64; _ }) as ty'),
            ("abs" | "ceil" | "floor" | "trunc" | "nearest" | "sqrt") ) ->
            if ty' = Number then UnionFind.set ty Float;
            Some ty
        | _ -> None
      in
      return_expression i (StructGet (i', field)) ty
  | StructSet (i1, field, i2) -> (
      let* i1' = instruction ctx i1 in
      let* i2' = instruction ctx i2 in
      let ty1 = expression_type ctx i1' in
      match UnionFind.find ty1 with
      | Valtype { typ = Ref { typ = Type ty; _ }; _ } -> (
          let*! typ = lookup_struct_type ctx ty in
          match
            Array.find_map
              (fun (nm, typ) -> if nm.desc = field.desc then Some typ else None)
              typ
          with
          | None ->
              Format.eprintf "struct.set %s/%s@." ty.desc field.desc;
              assert false
          | Some typ ->
              assert typ.mut;
              (let>@ ty = internalize ctx (unpack_type typ) in
               check_type ctx i2' ty);
              return_statement i (StructSet (i1', field, i2')) [||])
      | _ -> assert false (*ZZZ*))
  | Array (ty, i1, i2) -> (
      let* i1' = instruction ctx i1 in
      let* i2' = instruction ctx i2 in
      check_type ctx i2'
        (UnionFind.make (Valtype { typ = I32; internal = I32 }));
      match ty with
      | None -> assert false (*ZZZ*)
      | Some ty ->
          (let>@ field' = lookup_array_type ctx ty in
           let>@ typ = internalize ctx (unpack_type field') in
           check_type ctx i1' typ);
          let*! typ =
            internalize ctx (Ref { nullable = false; typ = Type ty })
          in
          return_expression i (Array (Some ty, i1', i2')) typ)
  | ArrayDefault (ty, i) -> (
      let* i' = instruction ctx i in
      match ty with
      | None -> assert false (*ZZZ*)
      | Some ty ->
          check_type ctx i'
            (UnionFind.make (Valtype { typ = I32; internal = I32 }));
          (let>@ field = lookup_array_type ctx ty in
           assert (field_has_default field));
          let*! typ =
            internalize ctx (Ref { nullable = false; typ = Type ty })
          in
          return_expression i (ArrayDefault (Some ty, i')) typ)
  | ArrayFixed (ty, instrs) -> (
      match ty with
      | None -> assert false (*ZZZ*)
      | Some ty ->
          let*! field' = lookup_array_type ctx ty in
          let typ = internalize ctx (unpack_type field') in
          let* instrs' =
            List.fold_left
              (fun prev i' ->
                let* l = prev in
                let* i' = instruction ctx i' in
                (let>@ typ = typ in
                 check_type ctx i' typ);
                return (i' :: l))
              (return []) instrs
          in
          let*! typ =
            internalize ctx (Ref { nullable = false; typ = Type ty })
          in
          return_expression i (ArrayFixed (Some ty, List.rev instrs')) typ)
  | ArrayGet (i1, i2) -> (
      let* i1' = instruction ctx i1 in
      let* i2' = instruction ctx i2 in
      check_type ctx i2'
        (UnionFind.make (Valtype { typ = I32; internal = I32 }));
      match UnionFind.find (expression_type ctx i1') with
      | Valtype { typ = Ref { typ = Type ty; _ }; _ } ->
          let*! typ = lookup_array_type ~location:i1.info ctx ty in
          let*! ty = fieldtype ctx typ in
          return_expression i (ArrayGet (i1', i2')) ty
      | _ -> assert false (*ZZZ*))
  | ArraySet (i1, i2, i3) -> (
      let* i1' = instruction ctx i1 in
      let* i2' = instruction ctx i2 in
      let* i3' = instruction ctx i3 in
      check_type ctx i2'
        (UnionFind.make (Valtype { typ = I32; internal = I32 }));
      match UnionFind.find (expression_type ctx i1') with
      | Valtype { typ = Ref { typ = Type ty; _ }; _ } ->
          (let>@ typ = lookup_array_type ~location:i1.info ctx ty in
           assert typ.mut;
           let>@ ty = internalize ctx (unpack_type typ) in
           let ty' = expression_type ctx i3' in
           let ok = subtype ctx ty' ty in
           if not ok then
             Format.eprintf "%a <: %a@." output_inferred_type ty'
               output_inferred_type ty;
           assert ok);
          return_statement i (ArraySet (i1', i2', i3')) [||]
      | Unknown ->
          Format.eprintf "@[%a@]@." Output.instr i;
          (*return_statement i (ArraySet (i1', i2', i3')) [||]*)
          assert false
      | _ -> assert false)
  | BinOp (op, i1, i2) ->
      let* i1' = instruction ctx i1 in
      let* i2' = instruction ctx i2 in
      let ty =
        let ty1 = expression_type ctx i1' in
        let ty2 = expression_type ctx i2' in
        match (UnionFind.find ty1, UnionFind.find ty2) with
        | Unknown, Unknown -> (
            match op with
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
            match op with
            | Eq ->
                (match typ with
                | Valtype { internal = Ref _ as ty; _ } ->
                    assert (
                      Wasm.Types.val_subtype ctx.subtyping_info ty
                        (Ref { nullable = true; typ = Eq }))
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
                | _ -> assert false (*ZZZ*));
                UnionFind.make (Valtype { typ = I32; internal = I32 })
            | Add | Sub | Mul ->
                (match typ with
                | Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }
                | Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }
                | Number | Int | Float ->
                    ()
                | _ -> assert false (*ZZZ*));
                ty1
            | Div (Some _) | Rem _ | And | Or | Xor | Shl | Shr _ ->
                check_int_bin_op ty1 ty2
            | Div None -> check_float_bin_op ty1 ty2
            | Lt (Some _) | Gt (Some _) | Le (Some _) | Ge (Some _) ->
                (match typ with
                | Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }
                | Int ->
                    ()
                | Number -> UnionFind.set ty1 Int
                | _ -> assert false (*ZZZ*));
                UnionFind.make (Valtype { typ = I32; internal = I32 })
            | Lt None | Gt None | Le None | Ge None ->
                (match typ with
                | Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }
                | Float ->
                    ()
                | Number -> UnionFind.set ty1 Float
                | _ -> assert false (*ZZZ*));
                UnionFind.make (Valtype { typ = I32; internal = I32 })
            | Ne ->
                (match typ with
                | Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }
                | Valtype { internal = F32; _ }
                | Valtype { internal = F64; _ }
                | Number | Int | Float ->
                    ()
                | _ -> assert false (*ZZZ*));
                UnionFind.make (Valtype { typ = I32; internal = I32 }))
        | _ -> (
            match op with
            | Eq ->
                (match (UnionFind.find ty1, UnionFind.find ty2) with
                | ( Valtype { internal = Ref _ as ty1; _ },
                    Valtype { internal = Ref _ as ty2; _ } ) ->
                    assert (
                      Wasm.Types.val_subtype ctx.subtyping_info ty1
                        (Ref { nullable = true; typ = Eq }));
                    assert (
                      Wasm.Types.val_subtype ctx.subtyping_info ty2
                        (Ref { nullable = true; typ = Eq }))
                | Valtype { internal = Ref _ as typ1; _ }, Null ->
                    assert (
                      Wasm.Types.val_subtype ctx.subtyping_info typ1
                        (Ref { nullable = true; typ = Eq }));
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | Null, Valtype { internal = Ref _ as typ2; _ } ->
                    assert (
                      Wasm.Types.val_subtype ctx.subtyping_info typ2
                        (Ref { nullable = true; typ = Eq }));
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
                | _ -> assert false (*ZZZ*));
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
                | _ -> assert false (*ZZZ*));
                ty1
            | Div (Some _) | Rem _ | And | Or | Xor | Shl | Shr _ ->
                check_int_bin_op ty1 ty2
            | Div None -> check_float_bin_op ty1 ty2
            | Lt (Some _) | Gt (Some _) | Le (Some _) | Ge (Some _) ->
                (match (UnionFind.find ty1, UnionFind.find ty2) with
                | Valtype { internal = I32; _ }, Valtype { internal = I32; _ }
                | Valtype { internal = I64; _ }, Valtype { internal = I64; _ }
                | (Valtype { internal = I32 | I64; _ } | Int), (Number | Int) ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty1)
                | (Number | Int), Valtype { internal = I32 | I64; _ } ->
                    UnionFind.merge ty1 ty2 (UnionFind.find ty2)
                | Number, Number -> UnionFind.merge ty1 ty2 Int
                | _ -> assert false (*ZZZ*));
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
                | _ -> assert false (*ZZZ*));
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
                | _ -> assert false (*ZZZ*));
                UnionFind.make (Valtype { typ = I32; internal = I32 }))
      in
      return_expression i (BinOp (op, i1', i2')) ty
  | UnOp (op, i') ->
      let* i' = instruction ctx i' in
      let typ = expression_type ctx i' in
      let ty =
        match UnionFind.find typ with
        | Unknown -> (
            match op with
            | Not -> UnionFind.make (Valtype { typ = I32; internal = I32 })
            | Neg | Pos -> UnionFind.make Number)
        | _ -> (
            match op with
            | Not ->
                (match UnionFind.find typ with
                | Valtype { internal = I32 | I64 | Ref _; _ } | Null | Int -> ()
                | Number -> UnionFind.set typ Int
                | _ -> assert false);
                UnionFind.make (Valtype { typ = I32; internal = I32 })
            | Neg | Pos ->
                (match UnionFind.find typ with
                | Valtype { internal = I32 | I64 | F32 | F64; _ }
                | Int | Float | Number ->
                    ()
                | _ -> assert false);
                typ)
      in
      return_expression i (UnOp (op, i')) ty
  | Let ([ (Some name, Some typ) ], None) as desc ->
      (let>@ typ = internalize_valtype ctx typ in
       ctx.locals <- StringMap.add name.desc typ ctx.locals);
      return_statement i desc [||]
  | Let ([ (None, None) ], Some i') ->
      let* i' = instruction ctx i' in
      return_statement i (Let ([ (None, None) ], Some i')) [||]
  (*
  | Let of (idx option * valtype option) list * instr option
*)
  | Br (label, i') ->
      (* Sequence of instructions *)
      let params = branch_target ctx label in
      let* i' =
        match i' with
        | Some i' ->
            let* i' = instruction ctx i' in
            check_subtypes ctx (fst i'.info) params;
            return (Some i')
        | None ->
            assert (params = [||]);
            return None
      in
      return_statement i (Br (label, i')) [||]
  | Br_if (label, i') ->
      let* i' = instruction ctx i' in
      let ty, types = split_on_last_type i' in
      check_subtype ctx ty
        (UnionFind.make (Valtype { typ = I32; internal = I32 }));
      let params = branch_target ctx label in
      check_subtypes ctx types params;
      return_statement i (Br_if (label, i')) params
  | Br_table (labels, i') ->
      let* i' = instruction ctx i' in
      let ty, types = split_on_last_type i' in
      check_subtype ctx ty
        (UnionFind.make (Valtype { typ = I32; internal = I32 }));
      let len = Array.length (branch_target ctx (List.hd labels)) in
      List.iter
        (fun label ->
          let params = branch_target ctx label in
          assert (Array.length params = len);
          (*ZZZ*)
          check_subtypes ctx types params)
        labels;
      return_statement i (Br_table (labels, i')) [||]
  | Br_on_null (idx, i') ->
      let* i' = instruction ctx i' in
      let typ, types = split_on_last_type i' in
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
        | _ -> assert false (*ZZZ*)
      in
      let params = branch_target ctx idx in
      check_subtypes ctx types params;
      return_statement i (Br_on_null (idx, i')) (Array.append params [| typ' |])
  | Br_on_non_null (idx, i') ->
      let* i' = instruction ctx i' in
      let params = branch_target ctx idx in
      let typ, types = split_on_last_type i' in
      let typ = UnionFind.find typ in
      (match typ with
      | Unknown -> ()
      | Valtype
          {
            typ = Ref { nullable = _; typ; _ };
            internal = Ref { nullable = _; typ = ityp; _ };
          } ->
          check_subtypes ctx
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
      | _ -> assert false (*ZZZ*));
      return_statement i
        (Br_on_non_null (idx, i'))
        (Array.sub params 0 (Array.length params - 1))
  | Br_on_cast (label, ty, i') ->
      let* i' = instruction ctx i' in
      let typ', types = split_on_last_type i' in
      let params = branch_target ctx label in
      (let>@ ityp = reftype ctx.diagnostics ctx.type_context ty in
       let typ =
         UnionFind.make (Valtype { typ = Ref ty; internal = Ref ityp })
       in
       check_subtypes ctx (Array.append types [| typ |]) params);
      let*! typ1, typ2 =
        match UnionFind.find typ' with
        | Valtype { typ = Ref ty'; _ } ->
            let*@ ty1 = val_lub ctx (Ref ty) (Ref ty') in
            let*@ typ1 = internalize ctx ty1 in
            let+@ typ2 = internalize ctx (Ref (diff_ref_type ty' ty)) in
            (typ1, typ2)
        | Unknown -> Some (typ', UnionFind.make Unknown)
        | _ -> assert false
      in
      return_statement i
        (Br_on_cast
           ( label,
             ty,
             { i' with info = (Array.append types [| typ1 |], snd i'.info) } ))
        (Array.append (Array.sub params 0 (Array.length params - 1)) [| typ2 |])
  | Br_on_cast_fail (label, ty, i') ->
      let* i' = instruction ctx i' in
      let typ', types = split_on_last_type i' in
      let*! ityp = reftype ctx.diagnostics ctx.type_context ty in
      let*! typ1, typ2 =
        match UnionFind.find typ' with
        | Valtype { typ = Ref ty'; _ } ->
            let*@ ty1 = val_lub ctx (Ref ty) (Ref ty') in
            let*@ typ1 = internalize ctx ty1 in
            let+@ typ2 = internalize ctx (Ref (diff_ref_type ty' ty)) in
            (typ1, typ2)
        | Unknown -> Some (typ', UnionFind.make Unknown)
        | _ -> assert false
      in
      let params = branch_target ctx label in
      check_subtypes ctx (Array.append types [| typ2 |]) params;
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
       assert (results = [||]);
       let>@ types =
         array_map_opt (fun (_, typ) -> internalize ctx typ) params
       in
       match i' with
       | Some i' -> check_subtypes ctx (fst i'.info) types
       | None -> assert (types = [||]));
      return_statement i (Throw (tag, i')) [||]
  | ThrowRef i' ->
      let* i' = instruction ctx i' in
      (let>@ typ = internalize ctx (Ref { nullable = true; typ = Exn }) in
       check_type ctx i' typ);
      return_statement i (ThrowRef i') [||]
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
      | _ -> assert false (*ZZZ*))
  | Return i' ->
      (*ZZZ List of instructions? *)
      let* i' =
        match i' with
        | Some i' ->
            let* i' = instruction ctx i' in
            check_subtypes ctx (fst i'.info) ctx.return_types;
            return (Some i')
        | None ->
            assert (ctx.return_types = [||]);
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
  | Let (([] | _ :: _), _) ->
      Format.eprintf "%a@." Output.instr i;
      assert false

and instructions ctx l : _ -> _ * _ list =
  match l with
  | [] -> return []
  | i :: r ->
      let* i' = instruction ctx i in
      let* r' = instructions ctx r in
      return (i' :: r')

and toplevel_instruction ctx i : stack -> stack * 'b =
  (*
  let* () = print_stack in
*)
  if false then Format.eprintf "%a@." Output.instr i;
  match i.desc with
  | Block { label; typ; block = instrs } ->
      (*ZZZ Blocks take argument from the stack *)
      (*ZZZ Grab the arguments from the stack before internalizing the types;
       push the right number of values in case of failure *)
      let*! params =
        array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
      in
      let*! results = array_map_opt (internalize ctx) typ.results in
      let* () = pop_args ctx params in
      let instrs' = block ctx i.info label params results results instrs in
      return_statement i (Block { label; typ; block = instrs' }) results
  | Loop { label; typ; block = instrs } ->
      let*! params =
        array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
      in
      let*! results = array_map_opt (internalize ctx) typ.results in
      let* () = pop_args ctx params in
      let instrs' = block ctx i.info label params results params instrs in
      return_statement i (Loop { label; typ; block = instrs' }) results
  | If { label; typ; cond; if_block; else_block } ->
      let* cond = toplevel_instruction ctx cond in
      let*! params =
        array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
      in
      let*! results = array_map_opt (internalize ctx) typ.results in
      let* () = pop_args ctx params in
      let if_block = block ctx i.info label params results results if_block in
      let else_block =
        Option.map
          (fun b -> block ctx i.info label params results results b)
          else_block
      in
      return_statement i (If { label; typ; cond; if_block; else_block }) results
  | TryTable { label; typ; block = body; catches } ->
      let*! params =
        array_map_opt (fun (_, typ) -> internalize ctx typ) typ.params
      in
      let*! results = array_map_opt (internalize ctx) typ.results in
      let* () = pop_args ctx params in
      let body' = block ctx i.info label params results results body in
      let check_catch types label =
        let params = branch_target ctx label in
        check_subtypes ctx types params
      in
      List.iter
        (fun catch ->
          match catch with
          | Catch (tag, label) ->
              let>@ { params; results = r } =
                Tbl.find ctx.diagnostics ctx.tags tag
              in
              assert (r = [||]);
              let>@ params =
                array_map_opt (fun (_, typ) -> internalize ctx typ) params
              in
              check_catch params label
          | CatchRef (tag, label) ->
              let>@ { params; results = r } =
                Tbl.find ctx.diagnostics ctx.tags tag
              in
              assert (r = [||]);
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
      let* () = pop_args ctx params in
      let body' = block ctx i.info label params results results body in
      let catches =
        List.filter_map
          (fun (tag, body) ->
            let*@ { params; results = r } =
              Tbl.find ctx.diagnostics ctx.tags tag
            in
            assert (r = [||]);
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
  | Unreachable | TailCall _ | Br _ | Br_table _ | Throw _ | ThrowRef _
  | Return _ ->
      let count = count_holes i in
      let* args = pop_many ctx i count [] in
      let args, res = instruction ctx i args in
      (* Should not fail *)
      assert (args = []);
      if not (check_hole_order ctx res count) then assert false;
      return res |> unreachable
  | _ ->
      let count = count_holes i in
      let* args = pop_many ctx i count [] in
      let args, res = instruction ctx i args in
      (* Should not fail *)
      assert (args = []);
      if not (check_hole_order ctx res count) then (
        Format.eprintf "%d %a@." count Output.instr i;
        assert false);
      return res

and block_contents ctx l =
  match l with
  | [] -> return []
  | i :: r ->
      let* i' = toplevel_instruction ctx i in
      let* () =
        push_results
          (Array.to_list (Array.map (fun ty -> (i.info, ty)) (fst i'.info)))
      in
      let* r' = block_contents ctx r in
      return (i' :: r')

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
         block
     in
     let* () = pop_args ctx results in
     return block')

(*ZZZ
let fundecl ctx typ sign =
  match (typ, sign) with
  | Some idx, _ ->
      (*ZZZ Validate signature *)
      resolve_type_name ctx idx
  | _, Some sign ->
      (* The type of function [name] *)
      Wasm.Types.add_rectype ctx.internal_types
        [|
          { typ = Func (signature ctx sign); supertype = None; final = true };
        |]
  | None, None -> assert false (*ZZZ*)
*)

let check_type_definitions ctx =
  (*ZZZ In-order check? *)
  Tbl.iter ctx.types (fun _ (i, _) ->
      let ty = Wasm.Types.get_subtype ctx.subtyping_info i in
      match ty.supertype with
      | None -> ()
      | Some j -> (
          let ty' = Wasm.Types.get_subtype ctx.subtyping_info j in
          assert (not ty'.final);
          match (ty.typ, ty'.typ) with
          | ( Func { params; results },
              Func { params = params'; results = results' } ) ->
              assert (Array.length params = Array.length params');
              assert (Array.length results = Array.length results');
              Array.iter2
                (fun p p' ->
                  assert (Wasm.Types.val_subtype ctx.subtyping_info p' p))
                params params';
              Array.iter2
                (fun r r' ->
                  assert (Wasm.Types.val_subtype ctx.subtyping_info r r'))
                results results'
          | Struct fields, Struct fields' ->
              assert (Array.length fields' <= Array.length fields);
              for i = 0 to Array.length fields' - 1 do
                assert (field_subtype ctx fields.(i) fields'.(i))
              done
          | Array field, Array field' -> assert (field_subtype ctx field field')
          | Func _, (Struct _ | Array _)
          | Struct _, (Func _ | Array _)
          | Array _, (Func _ | Struct _) ->
              assert false))

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
  | BinOp ((Add | Sub | Mul), i1, i2) -> (
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
  | UnOp (Pos, i') -> check_constant_instruction ctx i'
  | UnOp (Neg, { desc = Float _ | Int _; _ }) -> ()
  | UnOp ((Neg | Not), _)
  | BinOp
      ( ( Div _ | Rem _ | And | Or | Xor | Shl | Shr _ | Eq | Ne | Lt _ | Gt _
        | Le _ | Ge _ ),
        _,
        _ )
  | Block _ | Loop _ | If _ | TryTable _ | Try _ | Unreachable | Nop | Hole
  | Set _ | Tee _ | Call _ | TailCall _ | Cast _ | Test _ | NonNull _
  | StructGet _ | StructSet _ | ArrayGet _ | ArraySet _ | Let _ | Br _ | Br_if _
  | Br_table _ | Br_on_null _ | Br_on_non_null _ | Br_on_cast _
  | Br_on_cast_fail _ | Throw _ | ThrowRef _ | Return _ | Sequence _ | Select _
    ->
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

let rec globals ctx fields =
  List.map
    (fun field ->
      match field.desc with
      | Global ({ name; mut; typ; def; _ } as g) ->
          let def' =
            with_empty_stack ctx ~location:def.info ~kind:Expression
              (toplevel_instruction ctx def)
          in
          (match typ with
          | Some typ ->
              let>@ typ = internalize_valtype ctx typ in
              Tbl.add ctx.diagnostics ctx.globals name (mut, typ);
              check_type ctx def' (UnionFind.make (Valtype typ))
          | None -> (
              let typ = UnionFind.find (expression_type ctx def') in
              match typ with
              | Valtype typ ->
                  Tbl.add ctx.diagnostics ctx.globals name (mut, typ)
              | _ -> assert false (*ZZZ floating*)));
          check_constant_instruction ctx def';
          After { field with desc = Global { g with def = def' } }
      | Group { fields; _ } ->
          let fields = globals ctx fields in
          PhasedGroup { before = field; fields }
      | Conditional { then_fields; else_fields; _ } ->
          PhasedConditional
            {
              before = field;
              then_ = globals ctx then_fields;
              else_ = Option.map (globals ctx) else_fields;
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
            let+@ ty =
              let*@ func_typ = Tbl.find ctx.diagnostics ctx.functions name in
              Tbl.find ctx.diagnostics ctx.types
                { name with desc = snd func_typ }
            in
            match ty with _, { typ = Func typ; _ } -> typ | _ -> assert false
          in
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
                      locals := StringMap.add id.desc typ !locals
                  | None -> ())
                params
          | _ -> ());
          if false then Format.eprintf "=== %s@." name.desc;
          let ctx =
            {
              ctx with
              locals = !locals;
              control_types =
                [ (Option.map (fun l -> l.desc) label, return_types) ];
              return_types;
            }
          in
          let body =
            with_empty_stack ctx ~location ~kind:Function
              (let* body = block_contents ctx body in
               let* () = pop_args ctx return_types in
               return body)
          in
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
                    then_fields = functions ctx then_;
                    else_fields = Option.map (functions ctx) else_;
                  };
            }
      | PhasedGroup _ | PhasedConditional _
      | Before { desc = Global _ | Group _ | Conditional _; _ } ->
          assert false
      | After f -> Some f
      | Before ({ desc = Type _ | Fundecl _ | GlobalDecl _ | Tag _; _ } as f) ->
          Some f)
    fields

let funsig _ctx sign =
  (*ZZZ Check signature (unique names) *)
  sign

let fundecl ctx name typ sign =
  if Tbl.exists ctx.diagnostics ctx.functions name then None
  else
    match typ with
    | Some typ ->
        let+@ info = Tbl.find ctx.diagnostics ctx.types typ in
        (*ZZZ Check signature*)
        (fst info, typ.desc)
    | None -> (
        match sign with
        | Some sign ->
            let name = { name with desc = "<func:" ^ name.desc ^ ">" } in
            let+@ i =
              add_type ctx.diagnostics ctx.type_context
                [|
                  ( name,
                    {
                      supertype = None;
                      typ = Func (funsig ctx sign);
                      final = true;
                    } );
                |]
            in
            (i, name.desc)
        | None -> assert false (*ZZZ*))

let type_configuration diagnostics fields =
  let type_context =
    {
      internal_types = Wasm.Types.create ();
      types = Tbl.make (Namespace.make ()) "type";
    }
  in
  let rec register_types fields =
    Ast_utils.iter_fields
      (fun (field : (_ modulefield, _) annotated) ->
        match field.desc with
        | Type rectype ->
            let _ : int option = add_type diagnostics type_context rectype in
            ()
        | Group { fields; _ } -> register_types fields
        | _ -> ())
      fields
  in
  register_types fields;
  let ctx =
    let namespace = Namespace.make () in
    {
      diagnostics;
      type_context;
      subtyping_info = Wasm.Types.subtyping_info type_context.internal_types;
      types = type_context.types;
      functions = Tbl.make namespace "function";
      globals = Tbl.make namespace "global";
      (*      memories = Tbl.make (Namespace.make ()) "memories";*)
      tags = Tbl.make (Namespace.make ()) "tag";
      locals = StringMap.empty;
      control_types = [];
      return_types = [||];
    }
  in
  check_type_definitions ctx;
  Ast_utils.iter_fields
    (fun field ->
      match field.desc with
      | Fundecl { name; typ; sign; _ } ->
          let>@ decl = fundecl ctx name typ sign in
          Tbl.add diagnostics ctx.functions name decl
      | GlobalDecl { name; mut; typ; _ } ->
          let>@ typ = internalize_valtype ctx typ in
          Tbl.add diagnostics ctx.globals name (mut, typ)
      | Func { name; typ; sign; _ } ->
          let>@ decl = fundecl ctx name typ sign in
          Tbl.add diagnostics ctx.functions name decl
      | Tag { name; typ; sign; _ } ->
          let>@ typ =
            match (typ, sign) with
            | Some typ, _ -> (
                let+@ info = Tbl.find ctx.diagnostics ctx.types typ in
                match snd info with
                | { typ = Func typ; _ } -> typ
                | _ -> assert false)
            | None, Some sign -> Some (funsig ctx sign)
            | None, None -> assert false (*ZZZ*)
          in
          Tbl.add diagnostics ctx.tags name typ
      | Group _ | Conditional _ | Type _ | Global _ -> ())
    fields;
  let _ : _ option =
    let name = Ast.no_loc "<string>" in
    add_type ctx.diagnostics ctx.type_context
      [|
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

let rec field_has_conditional (f : (_ modulefield, _) annotated) =
  match f.desc with
  | Conditional _ -> true
  | Group { fields; _ } -> List.exists field_has_conditional fields
  | _ -> false

(* Resolve every conditional against the assumption [asm], inlining the selected
   branch to produce a conditional-free module (groups are kept and recursed
   into). For an undetermined conditional, select [then], [enqueue] the [else]
   configuration, and [record] the chosen literal. *)
let specialize_fields env diagnostics ~enqueue ~record asm0 fields =
  let module S = Wasm.Cond_solver in
  let choose asm cond ~location ~then_branch ~else_branch =
    let c = S.of_cond env diagnostics ~location cond in
    if S.logical_implies asm c then (
      record c;
      then_branch (S.and_ asm c))
    else if S.logical_implies asm (S.not_ c) then (
      record (S.not_ c);
      else_branch (S.and_ asm (S.not_ c)))
    else (
      enqueue (S.and_ asm (S.not_ c));
      record c;
      then_branch (S.and_ asm c))
  in
  let rec sfields asm fl = List.concat_map (sfield asm) fl
  and sfield asm (f : (_ modulefield, _) annotated) =
    match f.desc with
    | Conditional { cond; then_fields; else_fields } ->
        choose asm cond ~location:f.info
          ~then_branch:(fun asm' -> sfields asm' then_fields)
          ~else_branch:(fun asm' ->
            match else_fields with Some e -> sfields asm' e | None -> [])
    | Group { attributes; fields } ->
        [ { f with desc = Group { attributes; fields = sfields asm fields } } ]
    | _ -> [ f ]
  in
  sfields asm0 fields

let f diagnostics fields =
  if not (List.exists field_has_conditional fields) then
    type_configuration diagnostics fields
  else begin
    Wasm.Cond_explore.check_all diagnostics
      ?truncation_location:
        (match fields with hd :: _ -> Some hd.info | [] -> None)
      ~explain:(fun env c -> Wasm.Cond_solver.explain env ~style:`Wax c)
      ~specialize:(fun env asm ~enqueue ~record ->
        specialize_fields env diagnostics ~enqueue ~record asm fields)
      ~check:(fun ctx m -> ignore (type_configuration ctx m))
      ();
    (* The typed module is consumed only by the (deferred) WAT conversion;
       wax -> wax ignores it. Produce it by typing the full module with
       conditionals preserved, discarding its (imprecise, cross-branch)
       diagnostics — the exploration above did the real checking. *)
    type_configuration (Utils.Diagnostic.collector ~source:None ()) fields
  end

let erase_types m =
  List.map (fun m -> { m with desc = Ast_utils.map_modulefield snd m.desc }) m
