(** Type checking and validation for Wax modules. *)

type typed_module_annotation = Ast.storagetype option array * Ast.location

type inferred_module_annotation =
  Infer.inferred_type Infer.Cell.t array * Ast.location
(** The typed-tree annotation before the inference cells are resolved to
    {!typed_module_annotation}: each node carries the inference cells for the
    values it leaves on the stack, plus its span. Unlike the resolved form it
    keeps the distinctions {!Infer.output_inferred_type} renders — flexible
    numeric literals ([number]/[int]/…), unknown/unreachable types ([any]), and
    inline anonymous composite types — which resolution collapses. Produced by
    {!f_infer}. *)

type types

val f :
  ?simplify:bool ->
  ?warn_unused:bool ->
  ?features:Wax_utils.Feature.set ->
  Wax_utils.Diagnostic.context ->
  Ast.location Ast.module_ ->
  types * typed_module_annotation Ast.module_
(** [f fields] performs type checking on the given list of Wax module fields. It
    verifies types, signatures, and other semantic rules.

    When [simplify] is set (default [false]), the typed AST is also rewritten:
    casts the inferred types make redundant are dropped, and [&?extern]/[&?any]
    casts of non-nullable arguments are tightened to [&extern]/[&any]. This is
    intended for the Wasm-to-Wax conversion, where casts are inserted to pin
    types; hand-written Wax is left untouched.

    When [warn_unused] is set (default [false]), a [let]-bound local that is
    never read is reported as a warning (unless its name starts with [_]). A
    conditional module is checked per reachable configuration, so the warning
    fires there too. *)

val reserved_type_names : string list
(** The built-in type names a [type] declaration (or a [rec] member) may not
    take: the value types ([i32] … [v128]), the abstract heap types, and the
    [atomic] intrinsic namespace. The typer rejects such a declaration;
    [From_wasm] renames a colliding [$type] name. *)

type member_kind = Field | Method | Function

type member_candidate = {
  member_name : string;
  member_kind : member_kind;
  member_detail : string;
}
(** A candidate for member completion at [recv.<here>] or [ns::<here>]: a struct
    field, a value method, or a namespace free function, with the [member_kind]
    driving the editor's icon and [member_detail] a rendered type/signature —
    the field's declared type ([i32], [mut i32], [&point]) or the
    method/function's signature ([fn() -> i32]). Collected by {!f_infer} via
    [member_completions], or produced by {!namespace_members}. *)

type method_result =
  | Same
  | Reinterpret
      (** A value method's result type relative to its receiver: [Same] type, or
          the equal-width opposite numeric family ([i32]<->[f32],
          [i64]<->[f64]), as [from_bits] / [to_bits] reinterpret. *)

type value_method = {
  vm_name : string;
  vm_binary : bool;  (** takes a second operand of the receiver's type *)
  vm_result : method_result;
}

val integer_methods : value_method list

val float_methods : value_method list
(** The value methods member completion offers for an integer / float receiver
    (e.g. [x.sqrt()]). A curated registry, since the method dispatch is
    match-based and not enumerable; the test in test/method-consistency
    type-checks each — arity and result type included — to keep it in step with
    the typer. *)

val simd_v128_methods : unit -> member_candidate list
(** The value methods member completion offers for a [v128] receiver — the
    vector ops [v.add_i32x4(w)], with their signatures. Enumerated from the SIMD
    registry ({!Wax_wasm.Simd.method_names}), which is also what the typer
    dispatches through, so the list cannot drift from what type-checks. *)

val numeric_receiver_candidates :
  Infer.inferred_type -> member_candidate list option
(** The value-method candidates member completion offers for a numeric receiver
    of the given inferred type — a concrete numeric valtype ([i32] … [v128]) or
    a still-flexible literal ([number]/[int]/[large number]/[float], which take
    their integer and/or float methods by family). [None] when the type has no
    value methods (a packed [i8]/[i16], which must be cast first, or a
    non-numeric type). *)

val memory_method_candidates : addr_name:string -> member_candidate list
(** The methods member completion offers on a memory receiver
    ([mem.load8(addr)]) — the scalar loads/stores, size/grow/fill/copy/init, and
    the atomic and SIMD memory accesses — with [addr_name] the memory's address
    type ([i32]/[i64]) for their signatures. *)

val table_method_candidates :
  addr_name:string -> elem_name:string -> member_candidate list
(** The methods member completion offers on a table receiver ([tab.size()]) —
    size/grow/fill/copy/init — with [addr_name] the table's address type and
    [elem_name] its element type for their signatures. *)

val array_method_candidates : Ast.fieldtype -> member_candidate list
(** The methods member completion offers on an array receiver ([a.length()]) of
    the given element type — [length] and the [fill]/[copy]/[init] bulk
    operations. *)

val namespace_members : string -> member_candidate list
(** The free functions completion offers after an intrinsic namespace path
    [ns::]: [v128::] (SIMD const constructors and [bitselect]), [i64::]
    (wide-arithmetic ops) and [atomic::] ([fence]), each with its signature.
    Empty for any other [ns] — a declared continuation type's [new]/[bind]
    members need the module's declarations (the editor resolves them from the
    buffer's AST). *)

val cont_method_candidates :
  params:string list ->
  results:string list ->
  switch_results:string list ->
  member_candidate list
(** The methods member completion offers on a continuation-typed receiver — the
    resume family and [switch] — from the rendered parameter/result types of the
    continuation's function type ([switch_results] the last parameter's own
    continuation parameters, when it has one). Recorded prebuilt as {!R_cont};
    also used by the editor's signature help, which renders the types from the
    buffer's declarations. *)

type member_receiver =
  | R_numeric of Infer.inferred_type
  | R_struct of Ast.fieldtype Ast.annotated_array
  | R_array of Ast.fieldtype
  | R_memory of [ `I32 | `I64 ]
  | R_table of [ `I32 | `I64 ] * Ast.reftype
  | R_cont of member_candidate list
      (** What a member access [recv.<here>] is on, recorded by {!f_infer} (via
          [member_completions]) so completion can derive its candidates with
          {!member_candidates} only for the access under the cursor — the list,
          large for a v128 / memory receiver, is not built at every access in
          the file. *)

val member_candidates : member_receiver -> member_candidate list
(** The member-completion candidates a recorded {!member_receiver} stands for.
*)

val intrinsic_namespaces : string list
(** The intrinsic namespace names ([v128]/[i64]/[atomic]) — the [ns] a [::] path
    can start with — for completion of the namespace itself. *)

type hover_target =
  | Value_type of Infer.inferred_valtype
  | Type_def of Ast.subtype
      (** What a resolved reference summarises for a hover on a name that is not
          itself an expression: a variable's type, or a referenced type's
          definition. Kept as data so the consumer renders only the one it needs
          (a check formats nothing). *)

type reference = {
  use : Ast.location;
  definitions : Ast.location list;
  hover : hover_target option;
}
(** A resolved name or label reference: the source span of a *use*, the span(s)
    of the *definition(s)* it binds to — several only under conditional
    compilation — and, for a name that is not itself an expression (a type
    reference, an assignment target, a bare global), what it resolves to for a
    hover. Collected by {!f_infer} for go-to-definition and hover. *)

val f_infer :
  ?simplify:bool ->
  ?warn_unused:bool ->
  ?resolve_links:reference list ref option ->
  ?pun_spans:Ast.location list ref option ->
  ?member_completions:(Ast.location * member_receiver) list ref option ->
  ?features:Wax_utils.Feature.set ->
  Wax_utils.Diagnostic.context ->
  Ast.location Ast.module_ ->
  types * inferred_module_annotation Ast.module_
(** As {!f}, but returns the typed tree with its inference cells intact rather
    than resolved to storage types — {!f} is exactly [f_infer] followed by that
    resolution, and both emit the same diagnostics. Lets a consumer render types
    the way diagnostics do (via {!Infer.output_inferred_type}); used by the
    editor for hover.

    When [resolve_links] is a [Some ref], every name and label reference
    resolved while type checking is appended to it as a {!reference} (use span
    -> definition spans), for go-to-definition. When [pun_spans] is a
    [Some ref], the span of each punned struct-literal field (the bare-name form
    [x] for [x: x]) is appended to it — such a span is both a field name and a
    variable use, so a rename must expand it rather than replace it. When
    [member_completions] is a [Some ref], each member access [recv.field]
    appends the field's span and a {!member_receiver} describing what it is on,
    from which {!member_candidates} derives the completion list on demand. All
    default to [None], so an ordinary run records nothing. *)

val check :
  ?warn_unused:bool ->
  ?features:Wax_utils.Feature.set ->
  Wax_utils.Diagnostic.context ->
  Ast.location Ast.module_ ->
  unit
(** [check] type-checks the module for errors like [f], but does not build the
    typed module. Use it on the validation-only paths (a same-format wax -> wax
    conversion, the [check] command) that discard the typed AST; [f] is reserved
    for conversion to Wasm/WAT, which consumes it.

    [warn_unused] behaves as for [f]. *)

val erase_types :
  typed_module_annotation Ast.module_ -> Ast.location Ast.module_
(** [erase_types modul] removes type annotations from the module, returning it
    to its original location-only annotation state. *)

val get_type_definition :
  Wax_utils.Diagnostic.context ->
  types ->
  (string, Ast.location) Ast.annotated ->
  Ast.subtype option
(** [get_type_definition context types id] returns the subtype definition for
    the given identifier, if it exists. *)
