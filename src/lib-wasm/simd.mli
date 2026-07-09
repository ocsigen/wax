(** Shared registry mapping wax SIMD intrinsic names to WebAssembly [Vec*]
    instructions and back. Single source of truth for [to_wasm] (forward),
    [from_wasm] (reverse) and [Wax_lang.Typing] (signatures).

    Surface convention: vector ops are method intrinsics with the lane shape in
    the name ([a.add_i32x4(b)], [v.extract_lane_s_i8x16(0)]); the wax name is
    the WAT mnemonic [A.B] rewritten as [B_A]. Constants and bitselect are free
    functions; loads/stores are methods on a memory object. *)

module Text = Ast.Text

(** Operand / result valtype of an intrinsic, abstract from the wax/wasm valtype
    representations. *)
type ty = TV128 | TI32 | TI64 | TF32 | TF64

val lane_count : Ast.vec_shape -> int
(** Number of lanes in a shape (e.g. [I32x4 -> 4]); also the exclusive upper
    bound for a lane index of that shape. *)

val lane_scalar : Ast.vec_shape -> ty
(** Scalar type of one lane (splat operand, extract result, replace value). *)

(** {1 Reverse direction: op -> wax name} *)

val unop_name : Ast.vec_un_op -> string
val binop_name : Ast.vec_bin_op -> string
val ternop_name : Ast.vec_tern_op -> string
val shift_name : Ast.vec_shift_op -> string
val test_name : Ast.vec_test_op -> string
val bitmask_name : Ast.vec_bitmask_op -> string
val splat_name : Ast.vec_shape -> string
val extract_name : Ast.vec_shape -> Ast.signage option -> string
val replace_name : Ast.vec_shape -> string
val shuffle_name : string
val bitselect_name : string
val const_name : Wax_utils.V128.shape -> string

val free_namespace : string
(** The namespace of the free-function intrinsics, spelled [v128::<member>]. *)

val free_full : string -> string
(** [free_full member] is the registry key [v128_<member>] for a [v128::member]
    path (the inverse of {!free_member}). *)

val free_member : string -> string
(** [free_member "v128_bitselect" = "bitselect"]: the [v128::] member name for a
    full registry key (the inverse of {!free_full}). *)

val vec_load_name : Ast.vec_load_op -> string
val load_lane_name : [ `I8 | `I16 | `I32 | `I64 ] -> string
val store_lane_name : [ `I8 | `I16 | `I32 | `I64 ] -> string
val load_splat_name : [ `I8 | `I16 | `I32 | `I64 ] -> string
val store_name : string
val vec_load_nat_align : Ast.vec_load_op -> int
val lane_nat_align : [ `I8 | `I16 | `I32 | `I64 ] -> int

(** {1 Forward direction: wax name -> op} *)

(** Trailing constant lane immediates (memory ops handled by {!mem_method}). *)
type imm =
  | No_imm
  | Lane of Ast.vec_shape  (** one index, [0 <= n < lane_count shape] *)
  | Shuffle  (** exactly 16 indices, each [0 <= n < 32] *)

type intrinsic = {
  operands : ty list;  (** receiver-first stack operand types *)
  result : ty option;
  imm : imm;
  free : bool;  (** [true]: free function; [false]: method on the receiver *)
  build : int list -> Ast.location Text.instr_desc;
      (** lane immediates (source order) -> instruction *)
}

val classify : string -> intrinsic option
(** Recognise a method or free-function SIMD intrinsic by name. *)

val is_free_intrinsic : string -> bool
(** A reserved free-function name ([v128_const_*], [v128_bitselect]); these
    shadow a user function of the same name only when it is unbound. *)

val const_shape_of_name : string -> Wax_utils.V128.shape option

val const_arity : Wax_utils.V128.shape -> int
(** Number of lane literals in a [v128_const_<shape>] call. *)

val const_is_float : Wax_utils.V128.shape -> bool

(** {1 Memory loads/stores ([mem.v128_*])} *)

type mem_intrinsic = {
  m_operands : ty list;
      (** address first, then the vector for store/lane ops *)
  m_result : ty option;
  m_lane : bool;  (** a trailing constant lane immediate is present *)
  m_nat_align : int;
  m_make : Text.idx -> Ast.memarg -> int -> Ast.location Text.instr_desc;
      (** memory index, memarg, lane (0 when [not m_lane]) -> instruction *)
}

val mem_method : string -> mem_intrinsic option
val is_mem_method : string -> bool

(** {1 WAT mnemonics for plain vector instructions}

    The plain vector instructions are those the WAT lexer emits as a single
    [INSTR] token (splat, unop, binop, shift, test, bitmask); the single source
    of their WAT mnemonics, shared by [output.ml] and the WAT lexer. *)

val wat_mnemonic : _ Ast.Text.instr_desc -> string option
(** The WAT mnemonic of a plain vector instruction; [None] for anything else. *)

val plain_vec_instrs : Ast.location Ast.Text.instr_desc list
(** Every plain vector instruction, for the WAT lexer's keyword table. *)
