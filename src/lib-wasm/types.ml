open Ast.Binary

module RecTypeTbl = Hashtbl.Make (struct
  type t = rectype

  let hash t =
    (* We have large structs, that tend to hash to the same value *)
    Hashtbl.hash_param 15 100 t

  let heaptype_eq t1 t2 =
    t1 == t2 || match (t1, t2) with Type i1, Type i2 -> i1 = i2 | _ -> false

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

let add_rectype types typ =
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
  in
  let update_valtype i (ty : valtype) =
    match ty with
    | I32 | I64 | F32 | F64 | V128 -> ty
    | Ref { nullable; typ } -> Ref { nullable; typ = update_heaptype i typ }
    | Tuple _ -> assert false
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
          (fun { typ; supertype; final } ->
            {
              typ = update_comptype i typ;
              supertype = Option.map (update_index i) supertype;
              final;
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
  match (ty, ty') with
  | (Func | NoFunc), Func
  | NoFunc, NoFunc
  | (Exn | NoExn), Exn
  | NoExn, NoExn
  | (Cont | NoCont), Cont
  | NoCont, NoCont
  | (Extern | NoExtern), Extern
  | NoExtern, NoExtern
  | (Any | Eq | I31 | Struct | Array | None_), Any
  | (Eq | I31 | Struct | Array | None_), Eq
  | (I31 | None_), I31
  | (Struct | None_), Struct
  | (Array | None_), Array
  | None_, None_ ->
      true
  | Type i, (Any | Eq) -> (
      match subtyping_info.(i).typ with
      | Struct _ | Array _ -> true
      | Func _ | Cont _ -> false)
  | Type i, Struct -> (
      match subtyping_info.(i).typ with
      | Struct _ -> true
      | Array _ | Func _ | Cont _ -> false)
  | Type i, Array -> (
      match subtyping_info.(i).typ with
      | Array _ -> true
      | Struct _ | Func _ | Cont _ -> false)
  | Type i, Func -> (
      match subtyping_info.(i).typ with
      | Func _ -> true
      | Struct _ | Array _ | Cont _ -> false)
  | Type i, Cont -> (
      match subtyping_info.(i).typ with
      | Cont _ -> true
      | Func _ | Struct _ | Array _ -> false)
  | None_, Type i -> (
      match subtyping_info.(i).typ with
      | Struct _ | Array _ -> true
      | Func _ | Cont _ -> false)
  | NoFunc, Type i -> (
      match subtyping_info.(i).typ with
      | Func _ -> true
      | Struct _ | Array _ | Cont _ -> false)
  | NoCont, Type i -> (
      match subtyping_info.(i).typ with
      | Cont _ -> true
      | Func _ | Struct _ | Array _ -> false)
  | Type i, Type i' -> subtype subtyping_info i i'
  | _ -> false

let ref_subtype subtyping_info { nullable; typ }
    { nullable = nullable'; typ = typ' } =
  ((not nullable) || nullable') && heap_subtype subtyping_info typ typ'

let val_subtype subtyping_info ty ty' =
  match (ty, ty') with
  | Ref t, Ref t' -> ref_subtype subtyping_info t t'
  | _ -> ty == ty'
