(* The canonical index of a type. Abstract outside this module (its .mli exposes
   neither [of_int] nor [to_int]), so an [Id.t] elsewhere can only originate from
   the store — never be fabricated from, or mistaken for, a source-level or
   wire-level integer. *)
module Id = struct
  type t = int

  let of_int i = i
  let to_int i = i
  let to_int_for_tests_only = to_int
  let equal = Int.equal
  let add id n = id + n
end

(* The internal (resolved) type representation: type references carry the
   abstract canonical [Id.t] rather than the wire format's plain [int]. The type
   store and validation reason about this; the binary/text codec stays on
   [Ast.Binary]. *)
module Internal = struct
  module X = struct
    type idx = Id.t
    type 'a annotated_array = 'a array
    type 'a opt_annotated_array = 'a array
  end

  include Ast.Make_types (X)

  type tabletype = { limits : limits; reftype : reftype }
end

module I = Internal

(* A reference inside a *normalized* rec-type. An intra-group back-reference is
   the constructor [Rec] carrying the referenced member's position in the group;
   a reference to an already-defined type is [Def] carrying its canonical index.
   Making these two distinct constructors — rather than a canonical index and a
   negative sign-bit sharing one integer space — means they can no longer be
   confused, and an [Id.t] is only ever a genuine store index. A caller resolving
   a source rec group builds [Normalized.rectype] directly. *)
type ref_index = Def of Id.t | Rec of int

module Normalized = struct
  module X = struct
    type idx = ref_index
    type 'a annotated_array = 'a array
    type 'a opt_annotated_array = 'a array
  end

  include Ast.Make_types (X)
end

module N = Normalized

type normalized_rectype = N.rectype

(* Deduplication keys on the normalized form directly: two structurally-equal rec
   groups yield equal normalized values. The structural hash/equality below is
   the tuned one carried over from the binary representation, now over [N]. *)
module RecTypeTbl = Hashtbl.Make (struct
  open N

  type t = N.rectype

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
  mutable rev_list : (int * normalized_rectype) list;
}

let create () =
  { types = RecTypeTbl.create 2000; last_index = 0; rev_list = [] }

let last_index types = types.last_index

(* Lower a normalized subtype to the internal (resolved) form, mapping every
   reference with [f]. Both forms use plain arrays, so the array wrappers are a
   straight [Array.map]; only the [idx] arms change. Shared by
   [subtyping_info]/[get_all_rectypes] (resolving a back-reference to its
   absolute canonical index) and the backstop (visiting every reference to
   validate it). *)
module N_to_I =
  Ast.Map_types (N) (I)
    (struct
      type ctx = ref_index -> Id.t

      let idx f i = f i
      let params _ f a = Array.map f a
      let fields _ f a = Array.map f a
      let members _ f a = Array.map f a
    end)

let subtype_to_internal (f : ref_index -> Id.t) (s : N.subtype) : I.subtype =
  N_to_I.subtype f s

(* Backstop for the normalization contract (see [add_rectype] in the .mli). A
   [Rec] back-reference must fall inside the group and a [Def] must denote an
   already-defined type; [last_index] is the base index this group is about to
   receive, so a well-formed [Def] is strictly below it. A violation is a
   mis-normalized group (the source-vs-canonical index confusion class) and is
   rejected here rather than silently corrupting the subtyping relation. *)
let check_normalized types (rt : normalized_rectype) =
  let n = Array.length rt in
  let check_ref = function
    | Rec pos ->
        if pos < 0 || pos >= n then
          invalid_arg "Types.add_rectype: back-reference outside the rec group"
    | Def id ->
        if Id.to_int id < 0 || Id.to_int id >= types.last_index then
          invalid_arg
            "Types.add_rectype: reference to an undefined or in-group type"
  in
  Array.iter
    (fun s ->
      ignore
        (subtype_to_internal
           (fun r ->
             check_ref r;
             Id.of_int 0)
           s))
    rt

let add_rectype types (typ : normalized_rectype) =
  check_normalized types typ;
  Id.of_int
    (try RecTypeTbl.find types.types typ
     with Not_found ->
       let index = types.last_index in
       RecTypeTbl.add types.types typ index;
       types.last_index <- Array.length typ + index;
       types.rev_list <- (index, typ) :: types.rev_list;
       index)

type subtyping_info = I.subtype array

(* Resolve every reference to an absolute canonical index: a [Def] is already
   one; a [Rec pos] is the [pos]-th member of a group based at [base]. *)
let resolve_ref base = function
  | Def id -> id
  | Rec pos -> Id.of_int (base + pos)

let subtyping_info t =
  let l =
    List.map
      (fun (base, a) -> Array.map (subtype_to_internal (resolve_ref base)) a)
      t.rev_list
  in
  Array.concat (List.rev l)

let get_subtype a i = a.(Id.to_int i)

let get_all_rectypes t =
  List.map
    (fun (base, a) -> Array.map (subtype_to_internal (resolve_ref base)) a)
    (List.rev t.rev_list)

let rec subtype subtyping_info (i : Id.t) i' =
  Id.equal i i'
  ||
  match subtyping_info.(Id.to_int i).I.supertype with
  | None -> false
  | Some s -> subtype subtyping_info s i'

let heap_subtype (subtyping_info : I.subtype array) (ty : I.heaptype)
    (ty' : I.heaptype) =
  let open I in
  (* Which top hierarchy a concrete type index [i] belongs to. Enumerating the
     comptype constructors (no [_]) means a newly added comptype forces every
     concrete-type arm below to be revisited. *)
  let is_struct i =
    match subtyping_info.(Id.to_int i).typ with
    | Struct _ -> true
    | Func _ | Array _ | Cont _ -> false
  in
  let is_array i =
    match subtyping_info.(Id.to_int i).typ with
    | Array _ -> true
    | Func _ | Struct _ | Cont _ -> false
  in
  let is_func i =
    match subtyping_info.(Id.to_int i).typ with
    | Func _ -> true
    | Struct _ | Array _ | Cont _ -> false
  in
  let is_cont i =
    match subtyping_info.(Id.to_int i).typ with
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
      | Exact i -> Id.equal i i'
      | None_ -> is_aggregate i'
      | NoFunc -> is_func i'
      | NoCont -> is_cont i'
      | Type _ | Func | Exn | NoExn | Cont | Extern | NoExtern | Any | Eq | I31
      | Struct | Array ->
          false)

let ref_subtype subtyping_info { I.nullable; typ }
    { I.nullable = nullable'; typ = typ' } =
  ((not nullable) || nullable') && heap_subtype subtyping_info typ typ'

let val_subtype subtyping_info ty ty' =
  match (ty, ty') with
  | I.Ref t, I.Ref t' -> ref_subtype subtyping_info t t'
  | _ -> ty == ty'

let rec heaptype_equal (t1 : I.heaptype) (t2 : I.heaptype) =
  t1 == t2
  ||
  match (t1, t2) with
  | Type id1, Type id2 | Exact id1, Exact id2 -> Id.equal id1 id2
  | Func, Func
  | NoFunc, NoFunc
  | Extern, Extern
  | NoExtern, NoExtern
  | Exn, Exn
  | NoExn, NoExn
  | Cont, Cont
  | NoCont, NoCont
  | Any, Any
  | Eq, Eq
  | I31, I31
  | Struct, Struct
  | Array, Array
  | None_, None_ ->
      true
  | _ -> false

and reftype_equal (rt1 : I.reftype) (rt2 : I.reftype) =
  rt1.nullable = rt2.nullable && heaptype_equal rt1.typ rt2.typ

and valtype_equal (vt1 : I.valtype) (vt2 : I.valtype) =
  vt1 == vt2
  ||
  match (vt1, vt2) with
  | Ref rt1, Ref rt2 -> reftype_equal rt1 rt2
  | I32, I32 | I64, I64 | F32, F32 | F64, F64 | V128, V128 -> true
  | _ -> false
