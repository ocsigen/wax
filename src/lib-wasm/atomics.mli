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

val method_name : Ast.atomicop -> string
(** The Wax method spelling on a memory receiver, e.g. [i32_atomic_load],
    [atomic_notify] (the inverse of {!of_method_name}). *)

val of_method_name : string -> Ast.atomicop option
(** Recognise a Wax atomic method name. *)

val natural_align_log2 : Ast.atomicop -> int
(** The base-2 logarithm of the access size; the memarg alignment must equal it
    exactly. *)

val signature : Ast.atomicop -> [ `I32 | `I64 ] list * [ `I32 | `I64 ] list
(** The operands after the address (which takes the memory's address type) and
    the results. *)
