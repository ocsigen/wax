(* The atomic memory instructions (the threads proposal): the mapping between an
   [Ast.atomicop], its WAT mnemonic, its [0xFE]-prefix sub-opcode, its natural
   alignment and its stack signature. [atomic.fence] is handled separately. *)

val name : Ast.atomicop -> string
(** The WAT mnemonic, e.g. [i64.atomic.rmw16.add_u]. *)

val all : Ast.atomicop list
(** Every atomic op ([atomic.fence] excluded), for enumerating their mnemonics.
*)

val opcode : Ast.atomicop -> int
(** The sub-opcode following the [0xFE] prefix. *)

val of_opcode : int -> Ast.atomicop option

(** The Wax surface: a method name carries the access width only
    ([atomic_load16], [atomic_rmw_add8]), so it denotes a {e family} of concrete
    ops — the i32/i64 value type is resolved from the operand and result types
    during typing, mirroring the plain scalar accesses. *)

type width = [ `W8 | `W16 | `W32 | `W64 ]

type family =
  | Load of width
  | Store of width
  | Rmw of Ast.atomic_rmwop * width
  | Wait of [ `I32 | `I64 ]
  | Notify

val families : family list
(** Every Wax method family (39 names), in completion order. *)

val method_name : family -> string
(** The Wax method spelling on a memory receiver, e.g. [atomic_load16],
    [atomic_rmw_add8], [atomic_notify] (the inverse of {!of_method_name}). *)

val of_method_name : string -> family option
(** Recognise a Wax atomic method name. *)

val family : Ast.atomicop -> family
(** The family a concrete op belongs to (its width is the access width). *)

val width_bytes : width -> int
(** Number of bytes a width accesses. *)

val family_bytes : family -> int
(** Number of bytes a family accesses — the width from the name, independent of
    which i32/i64 value type the operands select; its base-2 logarithm is the
    required (exact) alignment. *)

val natural_align_log2 : Ast.atomicop -> int
(** The base-2 logarithm of the access size; the memarg alignment must equal it
    exactly. *)

val signature : Ast.atomicop -> [ `I32 | `I64 ] list * [ `I32 | `I64 ] list
(** The operands after the address (which takes the memory's address type) and
    the results. *)
