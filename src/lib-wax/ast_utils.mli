val map_instr : ('a -> 'b) -> 'a Ast.instr -> 'b Ast.instr
(** [map_instr f instr] applies the function [f] to the info field of [instr]
    and recursively applies it to all nested instructions. *)

val lower_dispatch :
  block_info:'info ->
  index:'info Ast.instr ->
  cases:Ast.label list ->
  default:Ast.label ->
  arms:(Ast.label * 'info Ast.instr list) list ->
  'info Ast.instr list
(** [lower_dispatch] desugars a [dispatch] to its
    nested-block-around-a-[br_table] form: a list of the outermost case block
    followed by the first arm's trailing body (see the implementation). It is
    the inverse of {!Recover_dispatch} and is used by both type checking and
    Wax-to-Wasm conversion. *)

val synthetic_loop_label : string
(** Placeholder loop label used only in the discarded type-check lowering (the
    name never reaches emitted Wat; see {!lower_while} and [To_wasm]). *)

val lower_while :
  block_info:'info ->
  fresh_loop:Ast.label ->
  label:Ast.label option ->
  cond:'info Ast.instr ->
  step:'info Ast.instr option ->
  block:'info Ast.instr list ->
  'info Ast.instr list
(** [lower_while] desugars a leading-test [while C { B }] to
    ['L: loop { if C { B; br 'L; } }]. A continue-expression [step] runs at the
    end of every iteration: an unlabelled loop appends it to the body; a
    labelled loop wraps the body in a block (the continue target) so a
    [continue] runs the step before the [fresh_loop] back-edge. Inverse of the
    [while] case of {!Recover_loops}; used by both type checking and Wax-to-Wasm
    conversion. *)

val lower_match :
  block_info:'info ->
  labels:Ast.label list ->
  scrutinee:'info Ast.instr ->
  arms:(Ast.match_pattern * 'info Ast.instr list) list ->
  default:'info Ast.instr list ->
  'info Ast.instr list
(** [lower_match] desugars a [match] to a nested type-test ladder: the scrutinee
    is evaluated once and threaded through a [br_on_cast]/[br_on_null] chain in
    the innermost block, each test branching out to its arm's block (carrying
    the narrowed value), with the arm body just after that block and an outer
    void [escape] block past all the bodies. [labels] supplies [n+1] fresh block
    labels — one per arm in order, then the escape label. It is the inverse of
    {!Recover_match} and is used by both type checking and Wax-to-Wasm
    conversion. *)

val map_modulefield : ('a -> 'b) -> 'a Ast.modulefield -> 'b Ast.modulefield
(** [map_modulefield f modulefield] applies the function [f] to the info field
    of instructions within [modulefield] and returns a new [modulefield]. *)

val iter_fields :
  (('info Ast.modulefield, Ast.location) Ast.annotated -> unit) ->
  'info Ast.module_ ->
  unit

type binop_kind = [ `Shift | `Arith | `Bitwise | `Comparison ]
(** The precedence class of a binary operator, shared by the [precedence] lint
    ({!Typing}) and the Wax printer ({!Output}) so the parentheses the printer
    emits match exactly the operator mixes the lint would flag. *)

val binop_kind : Ast.binop -> binop_kind
(** [binop_kind op] is the precedence class of [op]. *)

val confusing_precedence : binop_kind -> binop_kind -> bool
(** [confusing_precedence outer inner] is whether a binary operator of kind
    [outer] whose operand is a binary operator of kind [inner] is a precedence
    footgun — a shift mixed with arithmetic, or a comparison mixed with a
    bitwise operator. Symmetric. *)

val import_name : Ast.import_decl -> (string, Ast.location) Ast.annotated
(** [import_name decl] is the name [decl] is imported under: its [import_as]
    override if present, else the Wax name [decl.id]. *)
