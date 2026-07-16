(** WebAssembly Abstract Syntax Tree. *)

type ('desc, 'info) annotated = ('desc, 'info) Wax_utils.Ast.annotated = {
  desc : 'desc;
  info : 'info;
}
(** An annotated tree node. *)

type location = Wax_utils.Ast.location = {
  loc_start : Lexing.position;
  loc_end : Lexing.position;
}
(** A source code location. *)

val no_loc : 'desc -> ('desc, location) annotated
(** [no_loc d] creates an annotated node with a dummy location. *)

val dummy_loc : location
(** A location with dummy start/end positions, for synthesized nodes. *)

module Uint32 = Wax_utils.Uint32
module Uint64 = Wax_utils.Uint64

(* Types *)

type packedtype = I8 | I16
type 'typ muttype = { mut : bool; typ : 'typ }

type limits = {
  mi : Uint64.t;
  ma : Uint64.t option;
  address_type : [ `I32 | `I64 ];
  (* Custom page size as its base-2 logarithm ([None] is the default 65536-byte
     page, exponent 16); always [None] for a table. *)
  page_size_log2 : int option;
  (* A shared memory (the threads proposal); always [false] for a table. *)
  shared : bool;
}

(** The set of types produced by {!Make_types}, abstracted over the index and
    array-wrapper representations. Naming it lets {!Map_types} map the whole
    family from one instance to another. *)
module type TYPES = sig
  type idx
  type 'a annotated_array
  type 'a opt_annotated_array

  type heaptype =
    | Func
    | NoFunc
    | Exn
    | NoExn
    | Cont
    | NoCont
    | Extern
    | NoExtern
    | Any
    | Eq
    | I31
    | Struct
    | Array
    | None_
    | Type of idx
    | Exact of idx

  type reftype = { nullable : bool; typ : heaptype }
  type valtype = I32 | I64 | F32 | F64 | V128 | Ref of reftype

  type functype = {
    params : valtype opt_annotated_array;
    results : valtype array;
  }

  type nonrec packedtype = packedtype = I8 | I16
  type storagetype = Value of valtype | Packed of packedtype
  type nonrec 'typ muttype = 'typ muttype = { mut : bool; typ : 'typ }
  type fieldtype = storagetype muttype

  type comptype =
    | Func of functype
    | Struct of fieldtype annotated_array
    | Array of fieldtype
    | Cont of idx

  type subtype = {
    typ : comptype;
    supertype : idx option;
    final : bool;
    descriptor : idx option;
    describes : idx option;
  }

  type rectype = subtype annotated_array

  type nonrec limits = limits = {
    mi : Uint64.t;
    ma : Uint64.t option;
    address_type : [ `I32 | `I64 ];
    page_size_log2 : int option;
    shared : bool;
  }

  type globaltype = valtype muttype

  val heaptype_keyword : heaptype -> string option
  (** The keyword naming a heap type (e.g. [Some "func"]); [None] for the [Type]
      case, whose index each printer renders in its own way. *)
end

module Make_types (X : sig
  type idx
  type 'a annotated_array
  type 'a opt_annotated_array
end) :
  TYPES
    with type idx = X.idx
     and type 'a annotated_array = 'a X.annotated_array
     and type 'a opt_annotated_array = 'a X.opt_annotated_array

(** Map the [heaptype]/[reftype]/[valtype]/[storagetype]/[fieldtype] family from
    one {!Make_types} instance to another. Only the [idx]-carrying arms differ
    between instances; everything else is copied through. [ctx] is threaded to
    [M.idx] so a mapper that resolves or renames indices can carry its context
    (a name map, a symbol table, …). *)
module Map_types_spine
    (Src : TYPES)
    (Dst : TYPES)
    (M : sig
      type ctx

      val idx : ctx -> Src.idx -> Dst.idx
    end) : sig
  val heaptype : M.ctx -> Src.heaptype -> Dst.heaptype
  val reftype : M.ctx -> Src.reftype -> Dst.reftype
  val valtype : M.ctx -> Src.valtype -> Dst.valtype
  val storagetype : M.ctx -> Src.storagetype -> Dst.storagetype
  val fieldtype : M.ctx -> Src.fieldtype -> Dst.fieldtype
end

(** Extends {!Map_types_spine} to the whole type family. The array wrappers
    differ per instance, so the caller supplies how to map each one; the
    [functype]/[comptype]/[subtype]/[rectype] structure is copied through. *)
module Map_types
    (Src : TYPES)
    (Dst : TYPES)
    (M : sig
      type ctx

      val idx : ctx -> Src.idx -> Dst.idx

      val params :
        ctx ->
        (Src.valtype -> Dst.valtype) ->
        Src.valtype Src.opt_annotated_array ->
        Dst.valtype Dst.opt_annotated_array

      val fields :
        ctx ->
        (Src.fieldtype -> Dst.fieldtype) ->
        Src.fieldtype Src.annotated_array ->
        Dst.fieldtype Dst.annotated_array

      val members :
        ctx ->
        (Src.subtype -> Dst.subtype) ->
        Src.subtype Src.annotated_array ->
        Dst.subtype Dst.annotated_array
    end) : sig
  val heaptype : M.ctx -> Src.heaptype -> Dst.heaptype
  val reftype : M.ctx -> Src.reftype -> Dst.reftype
  val valtype : M.ctx -> Src.valtype -> Dst.valtype
  val storagetype : M.ctx -> Src.storagetype -> Dst.storagetype
  val fieldtype : M.ctx -> Src.fieldtype -> Dst.fieldtype
  val functype : M.ctx -> Src.functype -> Dst.functype
  val comptype : M.ctx -> Src.comptype -> Dst.comptype
  val subtype : M.ctx -> Src.subtype -> Dst.subtype
  val rectype : M.ctx -> Src.rectype -> Dst.rectype
end

(* Instructions *)

type signage = Signed | Unsigned

type int_un_op =
  | Clz
  | Ctz
  | Popcnt
  | Eqz
  | Trunc of [ `F32 | `F64 ] * signage
  | TruncSat of [ `F32 | `F64 ] * signage
  | Reinterpret
  | ExtendS of [ `_8 | `_16 | `_32 ]

type int_bin_op =
  | Add
  | Sub
  | Mul
  | Div of signage
  | Rem of signage
  | And
  | Or
  | Xor
  | Shl
  | Shr of signage
  | Rotl
  | Rotr
  | Eq
  | Ne
  | Lt of signage
  | Gt of signage
  | Le of signage
  | Ge of signage

type float_un_op =
  | Neg
  | Abs
  | Ceil
  | Floor
  | Trunc
  | Nearest
  | Sqrt
  | Convert of [ `I32 | `I64 ] * signage
  | Reinterpret

type float_bin_op =
  | Add
  | Sub
  | Mul
  | Div
  | Min
  | Max
  | CopySign
  | Eq
  | Ne
  | Lt
  | Gt
  | Le
  | Ge

type num_type = NumI32 | NumI64 | NumF32 | NumF64
type vec_shape = I8x16 | I16x8 | I32x4 | I64x2 | F32x4 | F64x2

type vec_un_op =
  | VecNeg of vec_shape
  | VecAbs of vec_shape
  | VecSqrt of [ `F32 | `F64 ]
  | VecNot
  | VecTruncSat of [ `F32 | `F64 ] * signage
  | VecConvert of [ `F32 | `F64 ] * signage
  | VecExtend of [ `Low | `High ] * [ `_8 | `_16 | `_32 ] * signage
  | VecPromote (* f32x4 => f64x2 *)
  | VecDemote (* f64x2 => f32x2 *)
  | VecCeil of [ `F32 | `F64 ]
  | VecFloor of [ `F32 | `F64 ]
  | VecTrunc of [ `F32 | `F64 ]
  | VecNearest of [ `F32 | `F64 ]
  | VecPopcnt
  | VecExtAddPairwise of signage * [ `I8 | `I16 ]
  (* Relaxed SIMD *)
  | VecRelaxedTrunc of signage
  | VecRelaxedTruncZero of signage

type vec_bin_op =
  | VecAdd of vec_shape
  | VecSub of vec_shape
  | VecMul of vec_shape
  | VecDiv of [ `F32 | `F64 ]
  | VecMin of signage option * vec_shape
  | VecMax of signage option * vec_shape
  | VecPMin of [ `F32 | `F64 ]
  | VecPMax of [ `F32 | `F64 ]
  | VecAvgr of [ `I8 | `I16 ]
  | VecQ15MulrSat
  | VecAddSat of signage * [ `I8 | `I16 ]
  | VecSubSat of signage * [ `I8 | `I16 ]
  | VecDot
  | VecEq of vec_shape
  | VecNe of vec_shape
  | VecLt of signage option * vec_shape
  | VecGt of signage option * vec_shape
  | VecLe of signage option * vec_shape
  | VecGe of signage option * vec_shape
  | VecAnd
  | VecOr
  | VecXor
  | VecAndNot
  | VecNarrow of signage * [ `I8 | `I16 ]
  | VecSwizzle
  | VecExtMulLow of signage * [ `_8 | `_16 | `_32 ]
  | VecExtMulHigh of signage * [ `_8 | `_16 | `_32 ]
  (* Relaxed SIMD *)
  | VecRelaxedSwizzle
  | VecRelaxedMin of vec_shape
  | VecRelaxedMax of vec_shape
  | VecRelaxedQ15Mulr
  | VecRelaxedDot

type vec_test_op = AnyTrue | AllTrue of vec_shape
type vec_shift_op = Shl of vec_shape | Shr of signage * vec_shape
type vec_bitmask_op = Bitmask of vec_shape

type vec_tern_op =
  | VecRelaxedMAdd of [ `F32 | `F64 ]
  | VecRelaxedNMAdd of [ `F32 | `F64 ]
  | VecRelaxedLaneSelect of vec_shape
  | VecRelaxedDotAdd

type vec_load_op =
  | Load128
  | Load8x8S
  | Load8x8U
  | Load16x4S
  | Load16x4U
  | Load32x2S
  | Load32x2U
  | Load32Zero
  | Load64Zero

(* Atomic memory operations (the threads proposal). The width option is [None]
   for the value type's full width and [Some w] for a narrower, zero-extended
   access (the [_u] mnemonics). *)
type atomic_rmwop =
  | AtomicAdd
  | AtomicSub
  | AtomicAnd
  | AtomicOr
  | AtomicXor
  | AtomicXchg
  | AtomicCmpxchg

type atomicop =
  | AtomicNotify
  | AtomicWait of [ `I32 | `I64 ]
  | AtomicLoad of [ `I32 | `I64 ] * [ `I8 | `I16 | `I32 ] option
  | AtomicStore of [ `I32 | `I64 ] * [ `I8 | `I16 | `I32 ] option
  | AtomicRmw of atomic_rmwop * [ `I32 | `I64 ] * [ `I8 | `I16 | `I32 ] option

type ('i32, 'i64, 'f32, 'f64) op =
  | I32 of 'i32
  | I64 of 'i64
  | F32 of 'f32
  | F64 of 'f64

type memarg = {
  offset : Uint64.t;
  align : Uint64.t (* The wasm test suite contains large align values *);
}

(* Condition of a conditional annotation [(@if ...)], as used by the
   js_of_ocaml WAT preprocessor. We parse and preserve these conditions but
   do not evaluate them. *)
type cmp_op = Eq | Ne | Lt | Gt | Le | Ge

type cond =
  | Cond_var of (string, location) annotated (* a variable, written [$name] *)
  | Cond_string of (string, location) annotated
  | Cond_version of int * int * int
  | Cond_and of cond list
  | Cond_or of cond list
  | Cond_not of cond
  | Cond_cmp of cmp_op * cond * cond

module Make_instructions (X : sig
  type idx
  type typeuse
  type label
  type heaptype
  type reftype
  type valtype
  type int32_t
  type int64_t
  type f32_t
  type float_t
  type v128_t
end) : sig
  type nonrec ('i32, 'i64, 'f32, 'f64) op = ('i32, 'i64, 'f32, 'f64) op =
    | I32 of 'i32
    | I64 of 'i64
    | F32 of 'f32
    | F64 of 'f64

  type nonrec signage = signage = Signed | Unsigned

  type nonrec int_un_op = int_un_op =
    | Clz
    | Ctz
    | Popcnt
    | Eqz
    | Trunc of [ `F32 | `F64 ] * signage
    | TruncSat of [ `F32 | `F64 ] * signage
    | Reinterpret
    | ExtendS of [ `_8 | `_16 | `_32 ]

  type nonrec int_bin_op = int_bin_op =
    | Add
    | Sub
    | Mul
    | Div of signage
    | Rem of signage
    | And
    | Or
    | Xor
    | Shl
    | Shr of signage
    | Rotl
    | Rotr
    | Eq
    | Ne
    | Lt of signage
    | Gt of signage
    | Le of signage
    | Ge of signage

  type nonrec float_un_op = float_un_op =
    | Neg
    | Abs
    | Ceil
    | Floor
    | Trunc
    | Nearest
    | Sqrt
    | Convert of [ `I32 | `I64 ] * signage
    | Reinterpret

  type nonrec float_bin_op = float_bin_op =
    | Add
    | Sub
    | Mul
    | Div
    | Min
    | Max
    | CopySign
    | Eq
    | Ne
    | Lt
    | Gt
    | Le
    | Ge

  type nonrec num_type = num_type = NumI32 | NumI64 | NumF32 | NumF64

  type nonrec vec_shape = vec_shape =
    | I8x16
    | I16x8
    | I32x4
    | I64x2
    | F32x4
    | F64x2

  type nonrec vec_un_op = vec_un_op =
    | VecNeg of vec_shape
    | VecAbs of vec_shape
    | VecSqrt of [ `F32 | `F64 ]
    | VecNot
    | VecTruncSat of [ `F32 | `F64 ] * signage
    | VecConvert of [ `F32 | `F64 ] * signage
    | VecExtend of [ `Low | `High ] * [ `_8 | `_16 | `_32 ] * signage
    | VecPromote (* f32x4 => f64x2 *)
    | VecDemote (* f64x2 => f32x2 *)
    | VecCeil of [ `F32 | `F64 ]
    | VecFloor of [ `F32 | `F64 ]
    | VecTrunc of [ `F32 | `F64 ]
    | VecNearest of [ `F32 | `F64 ]
    | VecPopcnt
    | VecExtAddPairwise of signage * [ `I8 | `I16 ]
    (* Relaxed SIMD *)
    | VecRelaxedTrunc of signage
    | VecRelaxedTruncZero of signage

  type nonrec vec_bin_op = vec_bin_op =
    | VecAdd of vec_shape
    | VecSub of vec_shape
    | VecMul of vec_shape
    | VecDiv of [ `F32 | `F64 ]
    | VecMin of signage option * vec_shape
    | VecMax of signage option * vec_shape
    | VecPMin of [ `F32 | `F64 ]
    | VecPMax of [ `F32 | `F64 ]
    | VecAvgr of [ `I8 | `I16 ]
    | VecQ15MulrSat
    | VecAddSat of signage * [ `I8 | `I16 ]
    | VecSubSat of signage * [ `I8 | `I16 ]
    | VecDot
    | VecEq of vec_shape
    | VecNe of vec_shape
    | VecLt of signage option * vec_shape
    | VecGt of signage option * vec_shape
    | VecLe of signage option * vec_shape
    | VecGe of signage option * vec_shape
    | VecAnd
    | VecOr
    | VecXor
    | VecAndNot
    | VecNarrow of signage * [ `I8 | `I16 ]
    | VecSwizzle
    | VecExtMulLow of signage * [ `_8 | `_16 | `_32 ]
    | VecExtMulHigh of signage * [ `_8 | `_16 | `_32 ]
    (* Relaxed SIMD *)
    | VecRelaxedSwizzle
    | VecRelaxedMin of vec_shape
    | VecRelaxedMax of vec_shape
    | VecRelaxedQ15Mulr
    | VecRelaxedDot

  type nonrec vec_test_op = vec_test_op = AnyTrue | AllTrue of vec_shape

  type nonrec vec_shift_op = vec_shift_op =
    | Shl of vec_shape
    | Shr of signage * vec_shape

  type nonrec vec_bitmask_op = vec_bitmask_op = Bitmask of vec_shape

  type nonrec vec_tern_op = vec_tern_op =
    | VecRelaxedMAdd of [ `F32 | `F64 ]
    | VecRelaxedNMAdd of [ `F32 | `F64 ]
    | VecRelaxedLaneSelect of vec_shape
    | VecRelaxedDotAdd

  type nonrec vec_load_op = vec_load_op =
    | Load128
    | Load8x8S
    | Load8x8U
    | Load16x4S
    | Load16x4U
    | Load32x2S
    | Load32x2U
    | Load32Zero
    | Load64Zero

  type blocktype = Typeuse of X.typeuse | Valtype of X.valtype

  type nonrec memarg = memarg = {
    offset : Uint64.t;
    align : Uint64.t (* The wasm test suite contains large align values *);
  }

  type catch =
    | Catch of X.idx * X.idx
    | CatchRef of X.idx * X.idx
    | CatchAll of X.idx
    | CatchAllRef of X.idx

  type on_clause = OnLabel of X.idx * X.idx | OnSwitch of X.idx

  type 'info instr_desc =
    | Block of {
        label : X.label;
        typ : blocktype option;
        block : ('info instr list, location) annotated;
      }
    | Loop of {
        label : X.label;
        typ : blocktype option;
        block : ('info instr list, location) annotated;
      }
    | If of {
        label : X.label;
        typ : blocktype option;
        if_block : ('info instr list, location) annotated;
        else_block : ('info instr list, location) annotated;
      }
    | TryTable of {
        label : X.label;
        typ : blocktype option;
        catches : catch list;
        block : ('info instr list, location) annotated;
      }
    | Try of {
        label : X.label;
        typ : blocktype option;
        block : ('info instr list, location) annotated;
        catches : (X.idx * ('info instr list, location) annotated) list;
        catch_all : ('info instr list, location) annotated option;
      }
    | Unreachable
    | Nop
    | Throw of X.idx
    | ThrowRef
    | ContNew of X.idx
    | ContBind of X.idx * X.idx
    | Suspend of X.idx
    | Resume of X.idx * on_clause list
    | ResumeThrow of X.idx * X.idx * on_clause list
    | ResumeThrowRef of X.idx * on_clause list
    | Switch of X.idx * X.idx
    | Br of X.idx
    | Br_if of X.idx
    | Br_table of X.idx list * X.idx
    | Br_on_null of X.idx
    | Br_on_non_null of X.idx
    | Br_on_cast of X.idx * X.reftype * X.reftype
    | Br_on_cast_fail of X.idx * X.reftype * X.reftype
    | Br_on_cast_desc_eq of X.idx * X.reftype * X.reftype
    | Br_on_cast_desc_eq_fail of X.idx * X.reftype * X.reftype
    (* Branch-hinting proposal: wraps a conditional branch ([if], [br_if], or a
       [br_on_*]) with its hint ([true] = likely taken, [false] = unlikely). No
       bytecode of its own; the hint is emitted into the [metadata.code.branch_hint]
       section at the wrapped instruction's offset. *)
    | Hinted of (* likely *) bool * 'info instr
    | Return
    | Call of X.idx
    | CallRef of X.idx
    | CallIndirect of X.idx * X.typeuse
    | ReturnCall of X.idx
    | ReturnCallRef of X.idx
    | ReturnCallIndirect of X.idx * X.typeuse
    | Drop
    | Select of X.valtype list option
    | LocalGet of X.idx
    | LocalSet of X.idx
    | LocalTee of X.idx
    | GlobalGet of X.idx
    | GlobalSet of X.idx
    | Load of X.idx * memarg * num_type
    | LoadS of
        X.idx * memarg * [ `I32 | `I64 ] * [ `I8 | `I16 | `I32 ] * signage
    | Store of X.idx * memarg * num_type
    | StoreS of X.idx * memarg * [ `I32 | `I64 ] * [ `I8 | `I16 | `I32 ]
    | Atomic of X.idx * atomicop * memarg
    | AtomicFence
    | MemorySize of X.idx
    | MemoryGrow of X.idx
    | MemoryFill of X.idx
    | MemoryCopy of X.idx * X.idx
    | MemoryInit of X.idx * X.idx
    | DataDrop of X.idx
    | TableGet of X.idx
    | TableSet of X.idx
    | TableSize of X.idx
    | TableGrow of X.idx
    | TableFill of X.idx
    | TableCopy of X.idx * X.idx
    | TableInit of X.idx * X.idx
    | ElemDrop of X.idx
    | RefNull of X.heaptype
    | RefFunc of X.idx
    | RefIsNull
    | RefAsNonNull
    | RefEq
    | RefTest of X.reftype
    | RefCast of X.reftype
    | RefCastDescEq of X.reftype
    | RefGetDesc of X.idx
    | StructNew of X.idx
    | StructNewDefault of X.idx
    | StructNewDesc of X.idx
    | StructNewDefaultDesc of X.idx
    | StructGet of signage option * X.idx * X.idx
    | StructSet of X.idx * X.idx
    | ArrayNew of X.idx
    | ArrayNewDefault of X.idx
    | ArrayNewFixed of X.idx * Uint32.t
    | ArrayNewData of X.idx * X.idx
    | ArrayNewElem of X.idx * X.idx
    | ArrayGet of signage option * X.idx
    | ArraySet of X.idx
    | ArrayLen
    | ArrayFill of X.idx
    | ArrayCopy of X.idx * X.idx
    | ArrayInitData of X.idx * X.idx
    | ArrayInitElem of X.idx * X.idx
    | RefI31
    | I31Get of signage
    | Const of (X.int32_t, X.int64_t, X.f32_t, X.float_t) op
    | BinOp of (int_bin_op, int_bin_op, float_bin_op, float_bin_op) op
    | UnOp of (int_un_op, int_un_op, float_un_op, float_un_op) op
    (* Wide arithmetic: [i64 i64 i64 i64] -> [i64 i64] and, for [MulWide],
       [i64 i64] -> [i64 i64]. Each operand/result pair is (low, high). *)
    | Add128
    | Sub128
    | MulWide of signage
    | VecConst of X.v128_t
    | VecUnOp of vec_un_op
    | VecBinOp of vec_bin_op
    | VecTest of vec_test_op
    | VecShift of vec_shift_op
    | VecBitmask of vec_bitmask_op
    (* Relaxed SIMD *)
    | VecTernOp of vec_tern_op
    | VecBitselect
    | VecLoad of X.idx * vec_load_op * memarg
    | VecStore of X.idx * memarg
    | VecLoadLane of X.idx * [ `I8 | `I16 | `I32 | `I64 ] * memarg * int
    | VecStoreLane of X.idx * [ `I8 | `I16 | `I32 | `I64 ] * memarg * int
    | VecLoadSplat of X.idx * [ `I8 | `I16 | `I32 | `I64 ] * memarg
    | VecExtract of vec_shape * signage option * int
    | VecReplace of vec_shape * int
    | VecSplat of vec_shape
    | VecShuffle of string
    | I32WrapI64
    | I64ExtendI32 of signage
    | F32DemoteF64
    | F64PromoteF32
    | ExternConvertAny
    | AnyConvertExtern
    | Folded of 'info instr * 'info instr list
    (* Our extensions *)
    | String of X.idx option * (string, location) annotated list
    | Char of Uchar.t
    | If_annotation of {
        cond : cond;
        then_body : ('info instr list, location) annotated;
        else_body : ('info instr list, location) annotated option;
      }

  and 'info instr = ('info instr_desc, 'info) annotated

  type 'info expr = 'info instr list
  (** A sequence of instructions. *)
end

(** Functor to create instructions for a given implementation of indices and
    types. *)

(* Modules *)

type exportable = Func | Memory | Table | Tag | Global

module Text : sig
  type name = (string, location) annotated
  type idx_desc = Num of Uint32.t | Id of string
  type idx = (idx_desc, location) annotated

  module X : sig
    type nonrec idx = idx
    type 'a annotated_array = (name option * 'a, location) annotated array
    type 'a opt_annotated_array = (name option * 'a, location) annotated array
    type label = name option
  end

  module Types : module type of Make_types (X)
  include module type of Make_types (X) with type idx := idx

  type typeuse = idx option * functype option
  type tabletype = { limits : (limits, location) annotated; reftype : reftype }

  include module type of Make_instructions (struct
    include X
    (* include Types *)
    (* Can't include module type directly if not named, but Instructions expects fields *)

    type heaptype = Make_types(X).heaptype
    type reftype = Make_types(X).reftype
    type valtype = Make_types(X).valtype
    type nonrec typeuse = typeuse
    type int32_t = string
    type int64_t = string
    type f32_t = string
    type float_t = string
    type v128_t = Wax_utils.V128.t
  end)

  type datastring = (string, location) annotated list

  (* A data segment's contents (WAT numeric-values proposal): a sequence of
     elements, each a byte string, a typed numeric run ([(i16 -1 2)], values kept
     as raw literal strings), or a run of [v128] constants. Encoded little-endian
     and concatenated at lowering. *)
  type datavalelem =
    | Str of string
    | Numlist of storagetype * string list
    | V128list of Wax_utils.V128.t list

  type dataval = (datavalelem, location) annotated list

  type importdesc =
    | Func of { exact : bool; typ : typeuse }
    | Memory of (limits, location) annotated
    | Table of tabletype
    | Global of globaltype
    | Tag of typeuse

  type nonrec exportable = exportable = Func | Memory | Table | Tag | Global
  type 'info datamode = Passive | Active of idx * 'info expr
  type 'info elemmode = Passive | Active of idx * 'info expr | Declare

  type 'info tableinit =
    | Init_default
    | Init_expr of 'info expr
    | Init_segment of 'info expr list

  type 'info modulefield =
    | Types of rectype
    | Import of {
        module_ : name;
        name : name;
        id : name option;
        desc : importdesc;
        exports : name list;
      }
    | Import_group1 of {
        module_ : name;
        items : (name * name option * importdesc) list;
      }
    | Import_group2 of {
        module_ : name;
        desc : importdesc;
        items : (name * name option) list;
      }
    | Func of {
        id : name option;
        typ : typeuse;
        locals : (name option * valtype, location) annotated list;
        instrs : 'info instr list;
        exports : name list;
      }
    | Memory of {
        id : name option;
        limits : (limits, location) annotated;
        init : dataval option;
        exports : name list;
      }
    | Table of {
        id : name option;
        typ : tabletype;
        init : 'info tableinit;
        exports : name list;
      }
    | Tag of { id : name option; typ : typeuse; exports : name list }
    | Global of {
        id : name option;
        typ : globaltype;
        init : 'info expr;
        exports : name list;
      }
    | Export of { name : name; kind : exportable; index : idx }
    | Start of idx
    | Elem of {
        id : name option;
        typ : reftype;
        init : 'info expr list;
        mode : 'info elemmode;
      }
    | Data of { id : name option; init : dataval; mode : 'info datamode }
    (* Our extensions *)
    | String_global of { id : name; typ : idx option; init : datastring }
    (* A module-level [(@feature "name")] annotation: the module declares it
       uses the named optional proposal (the Wax [#![feature = "…"]] inner
       attribute). *)
    | Feature_annotation of name
    | Module_if_annotation of {
        cond : cond;
        then_fields :
          (('info modulefield, location) annotated list, location) annotated;
        else_fields :
          (('info modulefield, location) annotated list, location) annotated
          option;
      }

  type 'info module_ =
    name option * ('info modulefield, location) annotated list
  (** A Wasm module in text format. *)
  end

(** Wasm Text format specific AST. *)

module Binary : sig
  type idx = int

  module X : sig
    type nonrec idx = idx
    type 'a annotated_array = 'a array
    type 'a opt_annotated_array = 'a array
    type label = unit
  end

  module Types : module type of Make_types (X)
  include module type of Make_types (X) with type idx := idx

  type typeuse = idx
  type tabletype = { limits : limits; reftype : reftype }

  include module type of Make_instructions (struct
    include X

    type heaptype = Make_types(X).heaptype
    type reftype = Make_types(X).reftype
    type valtype = Make_types(X).valtype
    type nonrec typeuse = typeuse
    type int32_t = Int32.t
    type int64_t = Int64.t
    type f32_t = Int32.t
    type float_t = float
    type v128_t = string
  end)

  type nonrec exportable = exportable = Func | Memory | Table | Tag | Global
  type 'info datamode = Passive | Active of idx * 'info expr
  type 'info elemmode = Passive | Active of idx * 'info expr | Declare

  type importdesc =
    | Func of { exact : bool; typ : typeuse }
    | Memory of limits
    | Table of tabletype
    | Global of globaltype
    | Tag of typeuse

  type import = { module_ : string; name : string; desc : importdesc }

  type import_entry =
    | Single of import
    | Group1 of { module_ : string; items : (string * importdesc) list }
    | Group2 of { module_ : string; desc : importdesc; names : string list }

  type 'info table = { typ : tabletype; expr : 'info expr option }

  type 'info memory = {
    limits : limits;
    init : string option;
    exports : string list;
  }

  type tag = { typ : typeuse; exports : string list }
  type 'info global = { typ : globaltype; init : 'info expr }
  type export = { name : string; kind : exportable; index : idx }

  type 'info elem = {
    typ : reftype;
    init : 'info expr list;
    mode : 'info elemmode;
  }

  type 'info code = {
    locals : valtype list;
    instrs : 'info instr list;
    loc : location;
        (** The defining function's source span; its [loc_end] locates the
            body's terminating [end] opcode (closing brace) in a source map.
            [dummy_loc] for a function decoded from a binary. *)
  }

  type 'info data = { init : string; mode : 'info datamode }

  module IntMap : Map.S with type key = idx

  type name_map = string IntMap.t
  type indirect_name_map = string IntMap.t IntMap.t

  type names = {
    module_ : string option;
    functions : name_map;
    locals : indirect_name_map;
    labels : indirect_name_map;
    types : name_map;
    fields : indirect_name_map;
    tags : name_map;
    globals : name_map;
    tables : name_map;
    memories : name_map;
    data : name_map;
    elem : name_map;
  }

  type 'info module_ = {
    types : rectype list;
    imports : import_entry list;
    functions : idx list;
    tables : 'info table list;
    memories : limits list;
    tags : idx list;
    globals : 'info global list;
    exports : export list;
    start : idx option;
    elem : 'info elem list;
    code : 'info code list;
    data : 'info data list;
    names : names;
    (* The [target_features] custom section (tool-conventions): one entry per
       feature, a one-byte prefix (['+'] used/required, ['-'] disallowed) and
       an opaque name. Third-party entries are preserved verbatim; our own
       declarations use the [Wax_utils.Feature.name] spelling with ['+']. *)
    target_features : (char * string) list;
  }
  (** A Wasm module in binary format. *)
  end

(** Wasm Binary format specific AST. *)
