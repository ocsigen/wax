open Ast.Binary

module RecTypeTbl = Hashtbl.Make (struct
  type t = rectype

  let hash t =
    (* We have large structs, that tend to hash to the same value *)
    Hashtbl.hash_param 15 100 t

  let heaptype_eq t1 t2 =
    t1 == t2
    ||
    match (t1, t2) with
    | Type i1, Type i2 | Exact i1, Exact i2 -> i1 = i2
    | _ -> false

  let reftype_eq { nullable = n1; typ = t1 } { nullable = n2; typ = t2 } =
    n1 = n2 && heaptype_eq t1 t2

  let valtype_eq t1 t2 =
    t1 == t2
    || match (t1, t2) with Ref t1, Ref t2 -> reftype_eq t1 t2 | _ -> false

  let storagetype_eq t1 t2 =
    match (t1, t2) with
    | Value v1, Value v2 -> valtype_eq v1 v2
    | Packed p1, Packed p2 -> p1 == p2
    | _ -> false

  let fieldtype_eq { mut = m1; typ = t1 } { mut = m2; typ = t2 } =
    m1 = m2 && storagetype_eq t1 t2

  (* Does not allocate and return false on length mismatch *)
  let array_for_all2 p a1 a2 =
    let n1 = Array.length a1 and n2 = Array.length a2 in
    n1 = n2
    &&
    let rec loop p a1 a2 n1 i =
      i = n1 || (p a1.(i) a2.(i) && loop p a1 a2 n1 (succ i))
    in
    loop p a1 a2 n1 0

  let comptype_eq (t1 : comptype) (t2 : comptype) =
    match (t1, t2) with
    | Func { params = p1; results = r1 }, Func { params = p2; results = r2 } ->
        array_for_all2 valtype_eq p1 p2 && array_for_all2 valtype_eq r1 r2
    | Struct l1, Struct l2 -> array_for_all2 fieldtype_eq l1 l2
    | Array f1, Array f2 -> fieldtype_eq f1 f2
    | Cont i1, Cont i2 -> heaptype_eq (Type i1) (Type i2)
    | _ -> false

  let subtype_eq { final = f1; supertype = s1; typ = t1; _ }
      { final = f2; supertype = s2; typ = t2; _ } =
    f1 = f2
    && (match (s1, s2) with
      | Some _, None | None, Some _ -> false
      | None, None -> true
      | Some i1, Some i2 -> i1 = i2)
    && comptype_eq t1 t2

  let equal t1 t2 =
    match (t1, t2) with
    | [| t1 |], [| t2 |] -> subtype_eq t1 t2
    | _ -> array_for_all2 subtype_eq t1 t2
end)

type t = {
  types : int RecTypeTbl.t;
  mutable last_index : int;
  mutable rev_list : (int * rectype) list;
}

let create () =
  { types = RecTypeTbl.create 2000; last_index = 0; rev_list = [] }

let last_index types = types.last_index

(* Interim backstop for the normalization contract (see [add_rectype] in the
   .mli). A normalized rec group references its own members by a negative
   back-reference [lnot pos] and every already-defined type by its non-negative
   canonical index; the two currencies must never cross. A mis-normalized group
   — the source-vs-canonical index confusion class behind a known V8 soundness
   bug — is caught here at its origin rather than silently corrupting the
   subtyping relation. [types.last_index] is the base index this group is about
   to receive, so a well-formed non-negative reference is strictly below it. *)
let check_normalized types typ =
  let n = Array.length typ in
  let check_index i =
    if i < 0 then (
      if lnot i >= n then
        invalid_arg "Types.add_rectype: back-reference outside the rec group")
    else if i >= types.last_index then
      invalid_arg
        "Types.add_rectype: self/forward reference must be a back-reference"
  in
  let check_heaptype (ty : heaptype) =
    match ty with
    | Func | NoFunc | Exn | NoExn | Cont | NoCont | Extern | NoExtern | Any | Eq
    | I31 | Struct | Array | None_ ->
        ()
    | Type i | Exact i -> check_index i
  in
  let check_valtype (ty : valtype) =
    match ty with
    | I32 | I64 | F32 | F64 | V128 -> ()
    | Ref { typ; _ } -> check_heaptype typ
  in
  let check_storagetype (ty : storagetype) =
    match ty with Value v -> check_valtype v | Packed _ -> ()
  in
  let check_comptype (ty : comptype) =
    match ty with
    | Func { params; results } ->
        Array.iter check_valtype params;
        Array.iter check_valtype results
    | Struct fields ->
        Array.iter
          (fun ({ typ; _ } : fieldtype) -> check_storagetype typ)
          fields
    | Array { typ; _ } -> check_storagetype typ
    | Cont i -> check_index i
  in
  Array.iter
    (fun { typ; supertype; descriptor; describes; final = _ } ->
      check_comptype typ;
      Option.iter check_index supertype;
      Option.iter check_index descriptor;
      Option.iter check_index describes)
    typ

let add_rectype types typ =
  check_normalized types typ;
  try RecTypeTbl.find types.types typ
  with Not_found ->
    let index = types.last_index in
    RecTypeTbl.add types.types typ index;
    types.last_index <- Array.length typ + index;
    types.rev_list <- (index, typ) :: types.rev_list;
    index

type subtyping_info = subtype array

let subtyping_info t =
  let update_index i i' = if i' >= 0 then i' else i + lnot i' in
  let update_heaptype i (ty : heaptype) =
    match ty with
    | Func | NoFunc | Exn | NoExn | Cont | NoCont | Extern | NoExtern | Any | Eq
    | I31 | Struct | Array | None_ ->
        ty
    | Type i' -> Type (update_index i i')
    | Exact i' -> Exact (update_index i i')
  in
  let update_valtype i (ty : valtype) =
    match ty with
    | I32 | I64 | F32 | F64 | V128 -> ty
    | Ref { nullable; typ } -> Ref { nullable; typ = update_heaptype i typ }
  in
  let update_functype i { params; results } =
    {
      params = Array.map (update_valtype i) params;
      results = Array.map (update_valtype i) results;
    }
  in
  let update_fieldtype i ({ mut; typ } as ty) =
    match typ with
    | Value v -> { mut; typ = Value (update_valtype i v) }
    | Packed _ -> ty
  in
  let update_comptype i (ty : comptype) : comptype =
    match ty with
    | Func ty -> Func (update_functype i ty)
    | Struct a -> Struct (Array.map (update_fieldtype i) a)
    | Array ty -> Array (update_fieldtype i ty)
    | Cont i' -> Cont (update_index i i')
  in
  let l =
    List.map
      (fun (i, a) ->
        Array.map
          (fun { typ; supertype; final; descriptor; describes } ->
            {
              typ = update_comptype i typ;
              supertype = Option.map (update_index i) supertype;
              final;
              descriptor = Option.map (update_index i) descriptor;
              describes = Option.map (update_index i) describes;
            })
          a)
      t.rev_list
  in
  Array.concat (List.rev l)

let get_subtype a i = a.(i)
let get_all_rectypes t = List.map (fun (_idx, typ) -> typ) (List.rev t.rev_list)

let rec subtype subtyping_info (i : int) i' =
  i = i'
  ||
  match subtyping_info.(i).supertype with
  | None -> false
  | Some s -> subtype subtyping_info s i'

let heap_subtype (subtyping_info : subtype array) (ty : heaptype)
    (ty' : heaptype) =
  (* Which top hierarchy a concrete type index [i] belongs to. Enumerating the
     comptype constructors (no [_]) means a newly added comptype forces every
     concrete-type arm below to be revisited. *)
  let is_struct i =
    match subtyping_info.(i).typ with
    | Struct _ -> true
    | Func _ | Array _ | Cont _ -> false
  in
  let is_array i =
    match subtyping_info.(i).typ with
    | Array _ -> true
    | Func _ | Struct _ | Cont _ -> false
  in
  let is_func i =
    match subtyping_info.(i).typ with
    | Func _ -> true
    | Struct _ | Array _ | Cont _ -> false
  in
  let is_cont i =
    match subtyping_info.(i).typ with
    | Cont _ -> true
    | Func _ | Struct _ | Array _ -> false
  in
  let is_aggregate i = is_struct i || is_array i in
  (* Matched supertype-first, then subtype, both exhaustively and without a [_]
     row, so a new heap type constructor forces every relevant arm to be
     revisited. An [exact i] reference has the same proper supertypes as [i]
     (via [exact i <: i]), so on the left it follows the [Type i] rules; the
     bottom heap types are subtypes of the exact concrete types too. *)
  match ty' with
  | Func -> (
      match ty with
      | Func | NoFunc -> true
      | Type i | Exact i -> is_func i
      | Exn | NoExn | Cont | NoCont | Extern | NoExtern | Any | Eq | I31
      | Struct | Array | None_ ->
          false)
  | NoFunc -> (
      match ty with
      | NoFunc -> true
      | Func | Exn | NoExn | Cont | NoCont | Extern | NoExtern | Any | Eq | I31
      | Struct | Array | None_ | Type _ | Exact _ ->
          false)
  | Exn -> (
      match ty with
      | Exn | NoExn -> true
      | Func | NoFunc | Cont | NoCont | Extern | NoExtern | Any | Eq | I31
      | Struct | Array | None_ | Type _ | Exact _ ->
          false)
  | NoExn -> (
      match ty with
      | NoExn -> true
      | Func | NoFunc | Exn | Cont | NoCont | Extern | NoExtern | Any | Eq | I31
      | Struct | Array | None_ | Type _ | Exact _ ->
          false)
  | Cont -> (
      match ty with
      | Cont | NoCont -> true
      | Type i | Exact i -> is_cont i
      | Func | NoFunc | Exn | NoExn | Extern | NoExtern | Any | Eq | I31
      | Struct | Array | None_ ->
          false)
  | NoCont -> (
      match ty with
      | NoCont -> true
      | Func | NoFunc | Exn | NoExn | Cont | Extern | NoExtern | Any | Eq | I31
      | Struct | Array | None_ | Type _ | Exact _ ->
          false)
  | Extern -> (
      match ty with
      | Extern | NoExtern -> true
      | Func | NoFunc | Exn | NoExn | Cont | NoCont | Any | Eq | I31 | Struct
      | Array | None_ | Type _ | Exact _ ->
          false)
  | NoExtern -> (
      match ty with
      | NoExtern -> true
      | Func | NoFunc | Exn | NoExn | Cont | NoCont | Extern | Any | Eq | I31
      | Struct | Array | None_ | Type _ | Exact _ ->
          false)
  | Any -> (
      match ty with
      | Any | Eq | I31 | Struct | Array | None_ -> true
      | Type i | Exact i -> is_aggregate i
      | Func | NoFunc | Exn | NoExn | Cont | NoCont | Extern | NoExtern -> false
      )
  | Eq -> (
      match ty with
      | Eq | I31 | Struct | Array | None_ -> true
      | Type i | Exact i -> is_aggregate i
      | Any | Func | NoFunc | Exn | NoExn | Cont | NoCont | Extern | NoExtern ->
          false)
  | I31 -> (
      match ty with
      | I31 | None_ -> true
      | Any | Eq | Struct | Array | Func | NoFunc | Exn | NoExn | Cont | NoCont
      | Extern | NoExtern | Type _ | Exact _ ->
          false)
  | Struct -> (
      match ty with
      | Struct | None_ -> true
      | Type i | Exact i -> is_struct i
      | Any | Eq | I31 | Array | Func | NoFunc | Exn | NoExn | Cont | NoCont
      | Extern | NoExtern ->
          false)
  | Array -> (
      match ty with
      | Array | None_ -> true
      | Type i | Exact i -> is_array i
      | Any | Eq | I31 | Struct | Func | NoFunc | Exn | NoExn | Cont | NoCont
      | Extern | NoExtern ->
          false)
  | None_ -> (
      match ty with
      | None_ -> true
      | Any | Eq | I31 | Struct | Array | Func | NoFunc | Exn | NoExn | Cont
      | NoCont | Extern | NoExtern | Type _ | Exact _ ->
          false)
  | Type i' -> (
      match ty with
      | Type i | Exact i -> subtype subtyping_info i i'
      | None_ -> is_aggregate i'
      | NoFunc -> is_func i'
      | NoCont -> is_cont i'
      | Func | Exn | NoExn | Cont | Extern | NoExtern | Any | Eq | I31 | Struct
      | Array ->
          false)
  | Exact i' -> (
      match ty with
      (* [exact] is invariant among concrete types: only the same exact type. *)
      | Exact i -> i = i'
      | None_ -> is_aggregate i'
      | NoFunc -> is_func i'
      | NoCont -> is_cont i'
      | Type _ | Func | Exn | NoExn | Cont | Extern | NoExtern | Any | Eq | I31
      | Struct | Array ->
          false)

let ref_subtype subtyping_info { nullable; typ }
    { nullable = nullable'; typ = typ' } =
  ((not nullable) || nullable') && heap_subtype subtyping_info typ typ'

let val_subtype subtyping_info ty ty' =
  match (ty, ty') with
  | Ref t, Ref t' -> ref_subtype subtyping_info t t'
  | _ -> ty == ty'
