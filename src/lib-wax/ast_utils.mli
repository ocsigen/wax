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

val lower_while :
  block_info:'info ->
  label:Ast.label option ->
  cond:'info Ast.instr ->
  block:'info Ast.instr list ->
  'info Ast.instr list
(** [lower_while] desugars a leading-test [while C { B }] to
    ['L: loop { if C { B; br 'L; } }] (synthesising ['L] when [label] is
    [None]). Inverse of the [while] case of {!Recover_loops}; used by both type
    checking and Wax-to-Wasm conversion. *)

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
