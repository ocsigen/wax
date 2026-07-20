(** Member-completion candidates and value-method tables for [recv.<here>] and
    [ns::<here>]: the fields, value methods and namespace free functions the
    editor offers there, with their rendered types and signatures. Shared
    between the type checker (which records a {!member_receiver} at each access
    and dispatches through the same registries) and {!Wax_editor}. *)

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
    method/function's signature ([fn() -> i32]). Collected by {!Typing.f_infer}
    via [member_completions], or produced by {!namespace_members}. *)

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

val simd_valtype : Infer.Simd.ty -> Infer.inferred_valtype
(** The value type a SIMD intrinsic operand / result stands for, as a fresh
    resolved value type. *)

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
      (** What a member access [recv.<here>] is on, recorded by
          {!Typing.f_infer} (via [member_completions]) so completion can derive
          its candidates with {!member_candidates} only for the access under the
          cursor — the list, large for a v128 / memory receiver, is not built at
          every access in the file. *)

val numeric_receiver_kind : Infer.inferred_type -> member_receiver option
(** Whether a value receiver of the given type has value methods, as the
    lightweight [R_numeric] descriptor the recorder classifies with before
    building any candidate list. Its domain matches
    {!numeric_receiver_candidates} returning [Some]. *)

val member_candidates : member_receiver -> member_candidate list
(** The member-completion candidates a recorded {!member_receiver} stands for.
*)

val intrinsic_namespaces : string list
(** The intrinsic namespace names ([v128]/[i64]/[atomic]) — the [ns] a [::] path
    can start with — for completion of the namespace itself. *)
