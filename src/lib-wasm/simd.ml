(* Shared registry mapping wax SIMD intrinsic names to WebAssembly [Vec*]
   instructions and back. This is the single source of truth consumed by
   [to_wasm] (forward lowering), [from_wasm] (reverse reconstruction) and
   [Wax_lang.Typing] (operand/result signatures).

   Surface convention: a vector op is written as a method intrinsic with the
   lane shape baked into the name, e.g. [a.add_i32x4(b)], [v.splat_i32x4()],
   [v.extract_lane_s_i8x16(0)]. The wax name is the WAT mnemonic [A.B] rewritten
   as [B_A] (so [i32x4.add] -> [add_i32x4], [v128.and] -> [and_v128]). Constants
   and bitselect are free functions ([v128_i32x4(...)], [v128_bitselect]);
   loads/stores are methods on a memory object ([mem.loadv128(addr)]). *)

module Text = Ast.Text

(* Operand / result valtype of a SIMD intrinsic, kept abstract from the wax and
   wasm valtype representations so each consumer maps it to its own. *)
type ty = TV128 | TI32 | TI64 | TF32 | TF64

let shape_str : Ast.vec_shape -> string = function
  | I8x16 -> "i8x16"
  | I16x8 -> "i16x8"
  | I32x4 -> "i32x4"
  | I64x2 -> "i64x2"
  | F32x4 -> "f32x4"
  | F64x2 -> "f64x2"

let lane_count : Ast.vec_shape -> int = function
  | I8x16 -> 16
  | I16x8 -> 8
  | I32x4 | F32x4 -> 4
  | I64x2 | F64x2 -> 2

(* Scalar type of one lane, used for splat operand / extract result / replace
   value. *)
let lane_scalar : Ast.vec_shape -> ty = function
  | I8x16 | I16x8 | I32x4 -> TI32
  | I64x2 -> TI64
  | F32x4 -> TF32
  | F64x2 -> TF64

let sgn : Ast.signage -> string = function Signed -> "_s" | Unsigned -> "_u"
let int_shapes = [ Ast.I8x16; Ast.I16x8; Ast.I32x4; Ast.I64x2 ]
let float_shapes = [ Ast.F32x4; Ast.F64x2 ]
let all_shapes = int_shapes @ float_shapes
let signs = [ Ast.Signed; Ast.Unsigned ]

(****)
(* Per-family naming (authoritative). The forward table below is derived by
   applying these to the enumerated set of valid ops, so the two directions
   cannot disagree. *)

let unop_name (op : Ast.vec_un_op) : string =
  let suffix, prefix =
    match op with
    | VecNeg s -> ("neg", shape_str s)
    | VecAbs s -> ("abs", shape_str s)
    | VecSqrt f -> ("sqrt", match f with `F32 -> "f32x4" | `F64 -> "f64x2")
    | VecNot -> ("not", "v128")
    | VecTruncSat (f, s) ->
        let fs = match f with `F32 -> "f32x4" | `F64 -> "f64x2" in
        ("trunc_sat_" ^ fs ^ sgn s, "i32x4")
    | VecConvert (f, s) ->
        let low = match f with `F32 -> "" | `F64 -> "low_" in
        let pfx = match f with `F32 -> "f32x4" | `F64 -> "f64x2" in
        ("convert_" ^ low ^ "i32x4" ^ sgn s, pfx)
    | VecExtend (h, sz, s) ->
        let hs = match h with `Low -> "low" | `High -> "high" in
        let szs =
          match sz with `_8 -> "i8x16" | `_16 -> "i16x8" | `_32 -> "i32x4"
        in
        let pfx =
          match sz with `_8 -> "i16x8" | `_16 -> "i32x4" | `_32 -> "i64x2"
        in
        ("extend_" ^ hs ^ "_" ^ szs ^ sgn s, pfx)
    | VecPromote -> ("promote_low_f32x4", "f64x2")
    | VecDemote -> ("demote_f64x2_zero", "f32x4")
    | VecCeil f -> ("ceil", match f with `F32 -> "f32x4" | `F64 -> "f64x2")
    | VecFloor f -> ("floor", match f with `F32 -> "f32x4" | `F64 -> "f64x2")
    | VecTrunc f -> ("trunc", match f with `F32 -> "f32x4" | `F64 -> "f64x2")
    | VecNearest f ->
        ("nearest", match f with `F32 -> "f32x4" | `F64 -> "f64x2")
    | VecPopcnt -> ("popcnt", "i8x16")
    | VecExtAddPairwise (s, sz) ->
        let szs = match sz with `I8 -> "i8x16" | `I16 -> "i16x8" in
        let pfx = match sz with `I8 -> "i16x8" | `I16 -> "i32x4" in
        ("extadd_pairwise_" ^ szs ^ sgn s, pfx)
    | VecRelaxedTrunc s -> ("relaxed_trunc_f32x4" ^ sgn s, "i32x4")
    | VecRelaxedTruncZero s -> ("relaxed_trunc_f64x2" ^ sgn s ^ "_zero", "i32x4")
  in
  suffix ^ "_" ^ prefix

let cmp_name base (s : Ast.signage option) (sh : Ast.vec_shape) : string =
  match (sh, s) with
  | (I8x16 | I16x8 | I32x4 | I64x2), Some Signed -> base ^ "_s"
  | (I8x16 | I16x8 | I32x4), Some Unsigned -> base ^ "_u"
  | (F32x4 | F64x2), None -> base
  | _ -> invalid_arg "Simd.cmp_name"

let binop_name (op : Ast.vec_bin_op) : string =
  let suffix, prefix =
    match op with
    | VecAdd s -> ("add", shape_str s)
    | VecSub s -> ("sub", shape_str s)
    | VecMul s -> ("mul", shape_str s)
    | VecDiv f -> ("div", match f with `F32 -> "f32x4" | `F64 -> "f64x2")
    | VecMin (s, sh) ->
        (("min" ^ match s with Some x -> sgn x | None -> ""), shape_str sh)
    | VecMax (s, sh) ->
        (("max" ^ match s with Some x -> sgn x | None -> ""), shape_str sh)
    | VecPMin f -> ("pmin", match f with `F32 -> "f32x4" | `F64 -> "f64x2")
    | VecPMax f -> ("pmax", match f with `F32 -> "f32x4" | `F64 -> "f64x2")
    | VecAvgr sz -> ("avgr_u", match sz with `I8 -> "i8x16" | `I16 -> "i16x8")
    | VecQ15MulrSat -> ("q15mulr_sat_s", "i16x8")
    | VecAddSat (s, sz) ->
        ("add_sat" ^ sgn s, match sz with `I8 -> "i8x16" | `I16 -> "i16x8")
    | VecSubSat (s, sz) ->
        ("sub_sat" ^ sgn s, match sz with `I8 -> "i8x16" | `I16 -> "i16x8")
    | VecDot -> ("dot_i16x8_s", "i32x4")
    | VecEq s -> ("eq", shape_str s)
    | VecNe s -> ("ne", shape_str s)
    | VecLt (s, sh) -> (cmp_name "lt" s sh, shape_str sh)
    | VecGt (s, sh) -> (cmp_name "gt" s sh, shape_str sh)
    | VecLe (s, sh) -> (cmp_name "le" s sh, shape_str sh)
    | VecGe (s, sh) -> (cmp_name "ge" s sh, shape_str sh)
    | VecAnd -> ("and", "v128")
    | VecOr -> ("or", "v128")
    | VecXor -> ("xor", "v128")
    | VecAndNot -> ("andnot", "v128")
    | VecNarrow (s, sz) ->
        let ins = match sz with `I8 -> "i16x8" | `I16 -> "i32x4" in
        let pfx = match sz with `I8 -> "i8x16" | `I16 -> "i16x8" in
        ("narrow_" ^ ins ^ sgn s, pfx)
    | VecSwizzle -> ("swizzle", "i8x16")
    | VecExtMulLow (s, sz) ->
        let ins =
          match sz with `_8 -> "i8x16" | `_16 -> "i16x8" | `_32 -> "i32x4"
        in
        let pfx =
          match sz with `_8 -> "i16x8" | `_16 -> "i32x4" | `_32 -> "i64x2"
        in
        ("extmul_low_" ^ ins ^ sgn s, pfx)
    | VecExtMulHigh (s, sz) ->
        let ins =
          match sz with `_8 -> "i8x16" | `_16 -> "i16x8" | `_32 -> "i32x4"
        in
        let pfx =
          match sz with `_8 -> "i16x8" | `_16 -> "i32x4" | `_32 -> "i64x2"
        in
        ("extmul_high_" ^ ins ^ sgn s, pfx)
    | VecRelaxedSwizzle -> ("relaxed_swizzle", "i8x16")
    | VecRelaxedMin s -> ("relaxed_min", shape_str s)
    | VecRelaxedMax s -> ("relaxed_max", shape_str s)
    | VecRelaxedQ15Mulr -> ("relaxed_q15mulr_s", "i16x8")
    | VecRelaxedDot -> ("relaxed_dot_i8x16_i7x16_s", "i16x8")
  in
  suffix ^ "_" ^ prefix

let ternop_name (op : Ast.vec_tern_op) : string =
  let suffix, prefix =
    match op with
    | VecRelaxedMAdd f ->
        ("relaxed_madd", match f with `F32 -> "f32x4" | `F64 -> "f64x2")
    | VecRelaxedNMAdd f ->
        ("relaxed_nmadd", match f with `F32 -> "f32x4" | `F64 -> "f64x2")
    | VecRelaxedLaneSelect s -> ("relaxed_laneselect", shape_str s)
    | VecRelaxedDotAdd -> ("relaxed_dot_i8x16_i7x16_add_s", "i32x4")
  in
  suffix ^ "_" ^ prefix

let shift_name : Ast.vec_shift_op -> string = function
  | Shl s -> "shl_" ^ shape_str s
  | Shr (sg, s) -> "shr" ^ sgn sg ^ "_" ^ shape_str s

let test_name : Ast.vec_test_op -> string = function
  | AnyTrue -> "any_true_v128"
  | AllTrue s -> "all_true_" ^ shape_str s

let bitmask_name : Ast.vec_bitmask_op -> string = function
  | Bitmask s -> "bitmask_" ^ shape_str s

let v128_shape_str : Wax_utils.V128.shape -> string = function
  | I8x16 -> "i8x16"
  | I16x8 -> "i16x8"
  | I32x4 -> "i32x4"
  | I64x2 -> "i64x2"
  | F32x4 -> "f32x4"
  | F64x2 -> "f64x2"

let splat_name s = "splat_" ^ shape_str s
let replace_name s = "replace_lane_" ^ shape_str s
let shuffle_name = "shuffle_i8x16"
let bitselect_name = "v128_bitselect"
let const_name (s : Wax_utils.V128.shape) = "v128_" ^ v128_shape_str s

(* The free-function intrinsics are spelled [v128::<member>] in Wax; the registry
   keys them by the full [v128_<member>] mnemonic. These convert between the two:
   [free_full "bitselect" = "v128_bitselect"], [free_member "v128_bitselect" =
   "bitselect"]. *)
let free_namespace = "v128"
let free_full member = free_namespace ^ "_" ^ member

let free_member full =
  let p = String.length free_namespace + 1 in
  String.sub full p (String.length full - p)

(* The [v128::] free-function members: [bitselect] and one const constructor per
   shape ([i8x16] … [f64x2]). *)
let free_member_names =
  free_member bitselect_name
  :: List.map
       (fun s -> free_member (const_name s))
       [ I8x16; I16x8; I32x4; I64x2; F32x4; F64x2 ]

let extract_name s (sign : Ast.signage option) =
  "extract_lane"
  ^ (match sign with Some x -> sgn x | None -> "")
  ^ "_" ^ shape_str s

(* Memory load/store names: like the scalar accesses, the access width (or the
   full-width family letter, [loadv128] beside [loadf32]) is in the method
   name; the widening loads keep their [_s]/[_u] suffix (both variants exist,
   so the suffix carries information). *)
let vec_load_name : Ast.vec_load_op -> string = function
  | Load128 -> "loadv128"
  | Load8x8S -> "load8x8_s"
  | Load8x8U -> "load8x8_u"
  | Load16x4S -> "load16x4_s"
  | Load16x4U -> "load16x4_u"
  | Load32x2S -> "load32x2_s"
  | Load32x2U -> "load32x2_u"
  | Load32Zero -> "load32_zero"
  | Load64Zero -> "load64_zero"

let lane_width_str : [ `I8 | `I16 | `I32 | `I64 ] -> string = function
  | `I8 -> "8"
  | `I16 -> "16"
  | `I32 -> "32"
  | `I64 -> "64"

let load_lane_name w = "load" ^ lane_width_str w ^ "_lane"
let store_lane_name w = "store" ^ lane_width_str w ^ "_lane"
let load_splat_name w = "load" ^ lane_width_str w ^ "_splat"
let store_name = "storev128"

let vec_load_nat_align : Ast.vec_load_op -> int = function
  | Load128 -> 16
  | Load8x8S | Load8x8U | Load16x4S | Load16x4U | Load32x2S | Load32x2U
  | Load64Zero ->
      8
  | Load32Zero -> 4

let lane_nat_align : [ `I8 | `I16 | `I32 | `I64 ] -> int = function
  | `I8 -> 1
  | `I16 -> 2
  | `I32 -> 4
  | `I64 -> 8

(****)
(* Forward direction: a method or free-function intrinsic taking stack operands
   and possibly trailing constant lane immediates (memory ops are handled
   separately by [mem_method]). *)

type imm =
  | No_imm
  | Lane of Ast.vec_shape  (** one lane index, [0 <= n < lane_count shape] *)
  | Shuffle  (** exactly 16 indices, each [0 <= n < 32] *)

type intrinsic = {
  operands : ty list;  (** receiver-first stack operand types *)
  result : ty option;
  imm : imm;
  free : bool;
      (** [true]: free function [f(args)]; [false]: method [recv.f(args)] *)
  build : int list -> Ast.location Text.instr_desc;
      (** lane immediates (in source order) -> instruction *)
}

let shuffle_string lanes =
  String.init 16 (fun i -> Char.chr (List.nth lanes i land 0xff))

(* Enumerations of valid ops, mirroring what the WAT validator accepts. *)
let unops : Ast.vec_un_op list =
  let f32f64 = [ `F32; `F64 ] in
  List.concat
    [
      List.map (fun s -> Ast.VecNeg s) all_shapes;
      List.map (fun s -> Ast.VecAbs s) all_shapes;
      List.map (fun f -> Ast.VecSqrt f) f32f64;
      [ VecNot; VecPopcnt; VecPromote; VecDemote ];
      List.concat_map
        (fun f -> List.map (fun s -> Ast.VecTruncSat (f, s)) signs)
        f32f64;
      List.concat_map
        (fun f -> List.map (fun s -> Ast.VecConvert (f, s)) signs)
        f32f64;
      List.concat_map
        (fun h ->
          List.concat_map
            (fun sz -> List.map (fun s -> Ast.VecExtend (h, sz, s)) signs)
            [ `_8; `_16; `_32 ])
        [ `Low; `High ];
      List.map (fun f -> Ast.VecCeil f) f32f64;
      List.map (fun f -> Ast.VecFloor f) f32f64;
      List.map (fun f -> Ast.VecTrunc f) f32f64;
      List.map (fun f -> Ast.VecNearest f) f32f64;
      List.concat_map
        (fun sz -> List.map (fun s -> Ast.VecExtAddPairwise (s, sz)) signs)
        [ `I8; `I16 ];
      List.map (fun s -> Ast.VecRelaxedTrunc s) signs;
      List.map (fun s -> Ast.VecRelaxedTruncZero s) signs;
    ]

let binops : Ast.vec_bin_op list =
  let f32f64 = [ `F32; `F64 ] in
  let i8i16 = [ `I8; `I16 ] in
  let i8i16i32 = [ `_8; `_16; `_32 ] in
  let int_min_max = [ Ast.I8x16; Ast.I16x8; Ast.I32x4 ] in
  let cmp_combos =
    List.concat
      [
        List.map (fun sh -> (Some Ast.Signed, sh)) int_shapes;
        List.map
          (fun sh -> (Some Ast.Unsigned, sh))
          [ Ast.I8x16; Ast.I16x8; Ast.I32x4 ];
        List.map (fun sh -> (None, sh)) float_shapes;
      ]
  in
  List.concat
    [
      List.map (fun s -> Ast.VecAdd s) all_shapes;
      List.map (fun s -> Ast.VecSub s) all_shapes;
      List.map
        (fun s -> Ast.VecMul s)
        [ Ast.I16x8; Ast.I32x4; Ast.I64x2; Ast.F32x4; Ast.F64x2 ];
      List.map (fun f -> Ast.VecDiv f) f32f64;
      List.concat_map
        (fun s -> List.map (fun sh -> Ast.VecMin (Some s, sh)) int_min_max)
        signs;
      List.map (fun sh -> Ast.VecMin (None, sh)) float_shapes;
      List.concat_map
        (fun s -> List.map (fun sh -> Ast.VecMax (Some s, sh)) int_min_max)
        signs;
      List.map (fun sh -> Ast.VecMax (None, sh)) float_shapes;
      List.map (fun f -> Ast.VecPMin f) f32f64;
      List.map (fun f -> Ast.VecPMax f) f32f64;
      List.map (fun sz -> Ast.VecAvgr sz) i8i16;
      [ VecQ15MulrSat; VecDot ];
      List.concat_map
        (fun s -> List.map (fun sz -> Ast.VecAddSat (s, sz)) i8i16)
        signs;
      List.concat_map
        (fun s -> List.map (fun sz -> Ast.VecSubSat (s, sz)) i8i16)
        signs;
      List.map (fun s -> Ast.VecEq s) all_shapes;
      List.map (fun s -> Ast.VecNe s) all_shapes;
      List.map (fun (s, sh) -> Ast.VecLt (s, sh)) cmp_combos;
      List.map (fun (s, sh) -> Ast.VecGt (s, sh)) cmp_combos;
      List.map (fun (s, sh) -> Ast.VecLe (s, sh)) cmp_combos;
      List.map (fun (s, sh) -> Ast.VecGe (s, sh)) cmp_combos;
      [ VecAnd; VecOr; VecXor; VecAndNot; VecSwizzle; VecRelaxedSwizzle ];
      List.concat_map
        (fun s -> List.map (fun sz -> Ast.VecNarrow (s, sz)) i8i16)
        signs;
      List.concat_map
        (fun s -> List.map (fun sz -> Ast.VecExtMulLow (s, sz)) i8i16i32)
        signs;
      List.concat_map
        (fun s -> List.map (fun sz -> Ast.VecExtMulHigh (s, sz)) i8i16i32)
        signs;
      List.map (fun s -> Ast.VecRelaxedMin s) float_shapes;
      List.map (fun s -> Ast.VecRelaxedMax s) float_shapes;
      [ VecRelaxedQ15Mulr; VecRelaxedDot ];
    ]

let ternops : Ast.vec_tern_op list =
  let f32f64 = [ `F32; `F64 ] in
  List.concat
    [
      List.map (fun f -> Ast.VecRelaxedMAdd f) f32f64;
      List.map (fun f -> Ast.VecRelaxedNMAdd f) f32f64;
      List.map (fun s -> Ast.VecRelaxedLaneSelect s) all_shapes;
      [ VecRelaxedDotAdd ];
    ]

let v128 = Some TV128
let uniform1 = [ TV128 ]
let uniform2 = [ TV128; TV128 ]

let table : (string, intrinsic) Hashtbl.t =
  let t = Hashtbl.create 512 in
  let add name i = Hashtbl.replace t name i in
  let simple name operands result instr =
    add name
      { operands; result; imm = No_imm; free = false; build = (fun _ -> instr) }
  in
  List.iter
    (fun op -> simple (unop_name op) uniform1 v128 (Text.VecUnOp op))
    unops;
  List.iter
    (fun op -> simple (binop_name op) uniform2 v128 (Text.VecBinOp op))
    binops;
  List.iter
    (fun op ->
      simple (ternop_name op) [ TV128; TV128; TV128 ] v128 (Text.VecTernOp op))
    ternops;
  (* shifts: vector, then i32 count *)
  List.iter
    (fun s ->
      simple (shift_name (Shl s)) [ TV128; TI32 ] v128 (Text.VecShift (Shl s)))
    int_shapes;
  List.iter
    (fun sg ->
      List.iter
        (fun s ->
          simple
            (shift_name (Shr (sg, s)))
            [ TV128; TI32 ] v128
            (Text.VecShift (Shr (sg, s))))
        int_shapes)
    signs;
  (* tests / bitmask: vector -> i32 *)
  simple (test_name AnyTrue) uniform1 (Some TI32) (Text.VecTest AnyTrue);
  List.iter
    (fun s ->
      simple (test_name (AllTrue s)) uniform1 (Some TI32)
        (Text.VecTest (AllTrue s)))
    int_shapes;
  List.iter
    (fun s ->
      simple (bitmask_name (Bitmask s)) uniform1 (Some TI32)
        (Text.VecBitmask (Bitmask s)))
    int_shapes;
  (* splat: scalar lane -> vector *)
  List.iter
    (fun s -> simple (splat_name s) [ lane_scalar s ] v128 (Text.VecSplat s))
    all_shapes;
  (* bitselect: three vectors -> vector (free function) *)
  add bitselect_name
    {
      operands = [ TV128; TV128; TV128 ];
      result = v128;
      imm = No_imm;
      free = true;
      build = (fun _ -> Text.VecBitselect);
    };
  (* extract_lane: vector + lane immediate -> scalar *)
  List.iter
    (fun s ->
      let signs_for =
        match s with
        | Ast.I8x16 | Ast.I16x8 -> [ Some Ast.Signed; Some Ast.Unsigned ]
        | _ -> [ None ]
      in
      List.iter
        (fun sign ->
          add (extract_name s sign)
            {
              operands = uniform1;
              result = Some (lane_scalar s);
              imm = Lane s;
              free = false;
              build = (fun lanes -> Text.VecExtract (s, sign, List.hd lanes));
            })
        signs_for)
    all_shapes;
  (* replace_lane: vector + scalar value + lane immediate -> vector *)
  List.iter
    (fun s ->
      add (replace_name s)
        {
          operands = [ TV128; lane_scalar s ];
          result = v128;
          imm = Lane s;
          free = false;
          build = (fun lanes -> Text.VecReplace (s, List.hd lanes));
        })
    all_shapes;
  (* shuffle: two vectors + 16 lane immediates -> vector *)
  add shuffle_name
    {
      operands = uniform2;
      result = v128;
      imm = Shuffle;
      free = false;
      build = (fun lanes -> Text.VecShuffle (shuffle_string lanes));
    };
  t

let classify name = Hashtbl.find_opt table name

let method_names recv_ty =
  Hashtbl.fold
    (fun name i acc ->
      match i.operands with
      | hd :: _ when (not i.free) && hd = recv_ty -> name :: acc
      | _ -> acc)
    table []
  |> List.sort compare

let const_shape_of_name name : Wax_utils.V128.shape option =
  let prefix = "v128_" in
  if
    String.length name > String.length prefix
    && String.sub name 0 (String.length prefix) = prefix
  then
    match
      String.sub name (String.length prefix)
        (String.length name - String.length prefix)
    with
    | "i8x16" -> Some I8x16
    | "i16x8" -> Some I16x8
    | "i32x4" -> Some I32x4
    | "i64x2" -> Some I64x2
    | "f32x4" -> Some F32x4
    | "f64x2" -> Some F64x2
    | _ -> None
  else None

(* Reserved free-function intrinsic names (vs. user functions). *)
let is_free_intrinsic name =
  name = bitselect_name || const_shape_of_name name <> None

(* Number of lane literals in a [v128_<shape>] const call. *)
let const_arity : Wax_utils.V128.shape -> int = function
  | I8x16 -> 16
  | I16x8 -> 8
  | I32x4 | F32x4 -> 4
  | I64x2 | F64x2 -> 2

let const_is_float : Wax_utils.V128.shape -> bool = function
  | F32x4 | F64x2 -> true
  | _ -> false

(****)
(* Memory loads/stores ([mem.loadv128], [mem.load8_lane], …). The receiver is the memory object, not a
   stack value; [m_operands] are the stack operands (address, then maybe the
   stored/lane vector), followed by an optional constant lane immediate and the
   usual trailing [align]/[offset] literals. *)

type mem_intrinsic = {
  m_operands : ty list;  (** address first, then vector for store/lane ops *)
  m_result : ty option;
  m_lane : bool;  (** a trailing constant lane immediate is present *)
  m_nat_align : int;
  m_make : Text.idx -> Ast.memarg -> int -> Ast.location Text.instr_desc;
      (** memory index, memarg, lane (0 if [not m_lane]) -> instruction *)
}

let mem_method name : mem_intrinsic option =
  let load op nat =
    Some
      {
        m_operands = [ TI32 ];
        m_result = v128;
        m_lane = false;
        m_nat_align = nat;
        m_make = (fun m ma _ -> Text.VecLoad (m, op, ma));
      }
  in
  let load_splat w nat =
    Some
      {
        m_operands = [ TI32 ];
        m_result = v128;
        m_lane = false;
        m_nat_align = nat;
        m_make = (fun m ma _ -> Text.VecLoadSplat (m, w, ma));
      }
  in
  let load_lane w nat =
    Some
      {
        m_operands = [ TI32; TV128 ];
        m_result = v128;
        m_lane = true;
        m_nat_align = nat;
        m_make = (fun m ma l -> Text.VecLoadLane (m, w, ma, l));
      }
  in
  let store_lane w nat =
    Some
      {
        m_operands = [ TI32; TV128 ];
        m_result = None;
        m_lane = true;
        m_nat_align = nat;
        m_make = (fun m ma l -> Text.VecStoreLane (m, w, ma, l));
      }
  in
  match name with
  | "loadv128" -> load Load128 16
  | "load8x8_s" -> load Load8x8S 8
  | "load8x8_u" -> load Load8x8U 8
  | "load16x4_s" -> load Load16x4S 8
  | "load16x4_u" -> load Load16x4U 8
  | "load32x2_s" -> load Load32x2S 8
  | "load32x2_u" -> load Load32x2U 8
  | "load32_zero" -> load Load32Zero 4
  | "load64_zero" -> load Load64Zero 8
  | "storev128" ->
      Some
        {
          m_operands = [ TI32; TV128 ];
          m_result = None;
          m_lane = false;
          m_nat_align = 16;
          m_make = (fun m ma _ -> Text.VecStore (m, ma));
        }
  | "load8_splat" -> load_splat `I8 1
  | "load16_splat" -> load_splat `I16 2
  | "load32_splat" -> load_splat `I32 4
  | "load64_splat" -> load_splat `I64 8
  | "load8_lane" -> load_lane `I8 1
  | "load16_lane" -> load_lane `I16 2
  | "load32_lane" -> load_lane `I32 4
  | "load64_lane" -> load_lane `I64 8
  | "store8_lane" -> store_lane `I8 1
  | "store16_lane" -> store_lane `I16 2
  | "store32_lane" -> store_lane `I32 4
  | "store64_lane" -> store_lane `I64 8
  | _ -> None

let is_mem_method name = mem_method name <> None

(* Every SIMD memory-access method name ([loadv128], [store8_lane], …),
   for completion after [mem.]. The set [mem_method] recognises. *)
let mem_method_names =
  let widths = [ `I8; `I16; `I32; `I64 ] in
  List.map vec_load_name
    [
      Load128;
      Load8x8S;
      Load8x8U;
      Load16x4S;
      Load16x4U;
      Load32x2S;
      Load32x2U;
      Load32Zero;
      Load64Zero;
    ]
  @ (store_name :: List.map load_splat_name widths)
  @ List.map load_lane_name widths
  @ List.map store_lane_name widths

(* {1 WebAssembly text (WAT) mnemonics for plain vector instructions}

   The "plain" vector instructions are those the WAT lexer emits as a single
   [INSTR] token — splat, unop, binop, shift, test, bitmask — i.e. those with no
   trailing immediate. Their WAT mnemonics live here so that output.ml (printing)
   and the WAT lexer (recognising) share one source. The immediate/memory ops
   (extract, replace, shuffle, ternary, loads/stores) use dedicated tokens and
   keep their own handling. *)

let wat_shape = function
  | Ast.I8x16 -> "i8x16"
  | Ast.I16x8 -> "i16x8"
  | Ast.I32x4 -> "i32x4"
  | Ast.I64x2 -> "i64x2"
  | Ast.F32x4 -> "f32x4"
  | Ast.F64x2 -> "f64x2"

let wat_signage op (s : Ast.signage) =
  op ^ match s with Ast.Signed -> "_s" | Ast.Unsigned -> "_u"

let wat_un_op op =
  let open Ast in
  match op with
  | VecNeg _ -> "neg"
  | VecAbs _ -> "abs"
  | VecSqrt _ -> "sqrt"
  | VecNot -> "not"
  | VecTruncSat (f, s) -> (
      match f with
      | `F32 -> wat_signage "trunc_sat_f32x4" s
      | `F64 -> wat_signage "trunc_sat_f64x2" s ^ "_zero")
  | VecConvert (f, s) ->
      let low = match f with `F32 -> "" | `F64 -> "low_" in
      wat_signage ("convert_" ^ low ^ "i32x4") s
  | VecExtend (h, sz, s) ->
      let h_str = match h with `Low -> "low" | `High -> "high" in
      let sz_str =
        match sz with `_8 -> "i8x16" | `_16 -> "i16x8" | `_32 -> "i32x4"
      in
      wat_signage ("extend_" ^ h_str ^ "_" ^ sz_str) s
  | VecPromote -> "promote_low_f32x4"
  | VecDemote -> "demote_f64x2_zero"
  | VecCeil _ -> "ceil"
  | VecFloor _ -> "floor"
  | VecTrunc _ -> "trunc"
  | VecNearest _ -> "nearest"
  | VecPopcnt -> "popcnt"
  | VecExtAddPairwise (s, sz) ->
      wat_signage
        ("extadd_pairwise_" ^ match sz with `I8 -> "i8x16" | `I16 -> "i16x8")
        s
  | VecRelaxedTrunc s -> wat_signage "relaxed_trunc_f32x4" s
  | VecRelaxedTruncZero s -> wat_signage "relaxed_trunc_f64x2" s ^ "_zero"

let wat_bin_op op =
  let open Ast in
  match op with
  | VecAdd _ -> "add"
  | VecSub _ -> "sub"
  | VecMul _ -> "mul"
  | VecDiv _ -> "div"
  | VecMin (s, _) ->
      "min" ^ Option.fold ~none:"" ~some:(fun s -> wat_signage "" s) s
  | VecMax (s, _) ->
      "max" ^ Option.fold ~none:"" ~some:(fun s -> wat_signage "" s) s
  | VecPMin _ -> "pmin"
  | VecPMax _ -> "pmax"
  | VecAvgr _ -> "avgr_u"
  | VecQ15MulrSat -> "q15mulr_sat_s"
  | VecAddSat (s, _) -> wat_signage "add_sat" s
  | VecSubSat (s, _) -> wat_signage "sub_sat" s
  | VecDot -> "dot_i16x8_s"
  | VecEq _ -> "eq"
  | VecNe _ -> "ne"
  | VecLt (s, shape) -> (
      match (shape, s) with
      | (I8x16 | I16x8 | I32x4 | I64x2), Some Signed -> "lt_s"
      | (I8x16 | I16x8 | I32x4), Some Unsigned -> "lt_u"
      | (F32x4 | F64x2), None -> "lt"
      | _ -> assert false)
  | VecGt (s, shape) -> (
      match (shape, s) with
      | (I8x16 | I16x8 | I32x4 | I64x2), Some Signed -> "gt_s"
      | (I8x16 | I16x8 | I32x4), Some Unsigned -> "gt_u"
      | (F32x4 | F64x2), None -> "gt"
      | _ -> assert false)
  | VecLe (s, shape) -> (
      match (shape, s) with
      | (I8x16 | I16x8 | I32x4 | I64x2), Some Signed -> "le_s"
      | (I8x16 | I16x8 | I32x4), Some Unsigned -> "le_u"
      | (F32x4 | F64x2), None -> "le"
      | _ -> assert false)
  | VecGe (s, shape) -> (
      match (shape, s) with
      | (I8x16 | I16x8 | I32x4 | I64x2), Some Signed -> "ge_s"
      | (I8x16 | I16x8 | I32x4), Some Unsigned -> "ge_u"
      | (F32x4 | F64x2), None -> "ge"
      | _ -> assert false)
  | VecAnd -> "and"
  | VecOr -> "or"
  | VecXor -> "xor"
  | VecAndNot -> "andnot"
  | VecNarrow (s, sh) ->
      let in_shape = match sh with `I8 -> "i16x8" | `I16 -> "i32x4" in
      wat_signage ("narrow_" ^ in_shape) s
  | VecSwizzle -> "swizzle"
  | VecExtMulLow (s, sh) ->
      let in_shape =
        match sh with `_8 -> "i8x16" | `_16 -> "i16x8" | `_32 -> "i32x4"
      in
      wat_signage ("extmul_low_" ^ in_shape) s
  | VecExtMulHigh (s, sh) ->
      let in_shape =
        match sh with `_8 -> "i8x16" | `_16 -> "i16x8" | `_32 -> "i32x4"
      in
      wat_signage ("extmul_high_" ^ in_shape) s
  | VecRelaxedSwizzle -> "relaxed_swizzle"
  | VecRelaxedMin _ -> "relaxed_min"
  | VecRelaxedMax _ -> "relaxed_max"
  | VecRelaxedQ15Mulr -> "relaxed_q15mulr_s"
  | VecRelaxedDot -> "relaxed_dot_i8x16_i7x16_s"

let wat_un_op_shape op =
  let open Ast in
  match op with
  | VecNeg s | VecAbs s -> wat_shape s
  | VecPopcnt -> "i8x16"
  | VecNot -> "v128"
  | VecTruncSat _ -> wat_shape I32x4
  | VecCeil f
  | VecFloor f
  | VecTrunc f
  | VecNearest f
  | VecSqrt f
  | VecConvert (f, _) ->
      wat_shape (match f with `F32 -> F32x4 | `F64 -> F64x2)
  | VecExtend (_, sz, _) ->
      wat_shape (match sz with `_8 -> I16x8 | `_16 -> I32x4 | `_32 -> I64x2)
  | VecPromote -> wat_shape F64x2
  | VecDemote -> wat_shape F32x4
  | VecExtAddPairwise (_, sz) ->
      wat_shape (match sz with `I8 -> I16x8 | `I16 -> I32x4)
  | VecRelaxedTrunc _ | VecRelaxedTruncZero _ -> wat_shape I32x4

let wat_bin_op_shape op =
  let open Ast in
  match op with
  | VecAdd s
  | VecSub s
  | VecMul s
  | VecMin (_, s)
  | VecMax (_, s)
  | VecEq s
  | VecNe s
  | VecLt (_, s)
  | VecGt (_, s)
  | VecLe (_, s)
  | VecGe (_, s) ->
      wat_shape s
  | VecDiv s | VecPMin s | VecPMax s -> (
      match s with `F32 -> "f32x4" | `F64 -> "f64x2")
  | VecDot -> "i32x4"
  | VecNarrow (_, s) | VecAvgr s | VecAddSat (_, s) | VecSubSat (_, s) -> (
      match s with `I8 -> "i8x16" | `I16 -> "i16x8")
  | VecAnd | VecOr | VecXor | VecAndNot -> "v128"
  | VecSwizzle | VecRelaxedSwizzle -> "i8x16"
  | VecQ15MulrSat -> "i16x8"
  | VecRelaxedMin s | VecRelaxedMax s -> wat_shape s
  | VecRelaxedQ15Mulr -> "i16x8"
  | VecRelaxedDot -> "i16x8"
  | VecExtMulLow (_, s) | VecExtMulHigh (_, s) ->
      wat_shape (match s with `_8 -> I16x8 | `_16 -> I32x4 | `_32 -> I64x2)

(* The WAT mnemonic of a plain vector instruction; [None] for any other. *)
let wat_mnemonic (desc : _ Ast.Text.instr_desc) : string option =
  let open Ast.Text in
  match desc with
  | VecSplat sh -> Some (wat_shape sh ^ ".splat")
  | VecUnOp op -> Some (wat_un_op_shape op ^ "." ^ wat_un_op op)
  | VecBinOp op -> Some (wat_bin_op_shape op ^ "." ^ wat_bin_op op)
  | VecTest op -> (
      match op with
      | AnyTrue -> Some "v128.any_true"
      | AllTrue shape -> Some (wat_shape shape ^ ".all_true"))
  | VecShift op -> (
      match op with
      | Shl shape -> Some (wat_shape shape ^ ".shl")
      | Shr (s, shape) -> Some (wat_signage (wat_shape shape ^ ".shr") s))
  | VecBitmask (Bitmask s) -> Some (wat_shape s ^ ".bitmask")
  | _ -> None

(* Every plain vector instruction, for the WAT lexer to fold into its keyword
   table. Mirrors the valid sets accepted by the validator. *)
let plain_vec_instrs : Ast.location Ast.Text.instr_desc list =
  let open Ast.Text in
  List.concat
    [
      List.map (fun s -> VecSplat s) all_shapes;
      List.map (fun o -> VecUnOp o) unops;
      List.map (fun o -> VecBinOp o) binops;
      List.map (fun s -> VecTest (AllTrue s)) int_shapes;
      [ VecTest AnyTrue ];
      List.concat_map
        (fun s ->
          [
            VecShift (Shl s);
            VecShift (Shr (Signed, s));
            VecShift (Shr (Unsigned, s));
          ])
        int_shapes;
      List.map (fun s -> VecBitmask (Bitmask s)) int_shapes;
    ]
