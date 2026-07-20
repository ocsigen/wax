(** The naming/context layer shared by the type checker and its extracted passes
    ({!Typing_lint}, {!Typing_suggest}): the typed-tree annotation types, the
    resolved-reference and member-completion sinks, the conditional-branch-aware
    name tables ({!Namespace} / {!Tbl}), the type and module contexts, the
    error-free accessor variants the lint/suggest code reads through, and the
    source-slice utilities the quick fixes build edits from. Its concrete types
    are re-exported by {!Typing} through type equations, so external consumers
    keep seeing them as [Wax_lang.Typing.reference] etc. *)

module Cond = Wax_wasm.Cond_solver

type typed_module_annotation = Ast.storagetype option array * Ast.location
(** The resolved per-node annotation of the typed tree: the storage types a node
    leaves on the stack, plus its span. *)

type inferred_module_annotation =
  Infer.inferred_type Infer.Cell.t array * Ast.location
(** As {!typed_module_annotation}, but before the inference cells are resolved
    to storage types — the form the editor reads. *)

type hover_target =
  | Value_type of Infer.inferred_valtype
  | Type_def of Ast.subtype
      (** What a resolved reference summarises for a hover on a name that is not
          itself an expression: a variable's type, or a referenced type's
          definition. *)

type reference = {
  use : Ast.location;
  definitions : Ast.location list;
  hover : hover_target option;
}
(** A resolved name/label reference: a use span, the definition span(s) it binds
    to (several only under conditional compilation), and an optional hover
    summary. *)

type resolve_sink = reference list ref option
(** Where name/label references are accumulated for the editor; [None] disables
    recording (an ordinary compile). *)

val is_source : Ast.location -> bool
(** Whether a location is a genuine source span (not a synthesized node's
    [Ast.dummy_loc]). *)

val same_span : Ast.location -> Ast.location -> bool
(** Whether two locations cover the same byte range. *)

val expression_type_opt : ('a, 'b array * 'c) Ast.annotated -> 'b option
(** The single inference cell an instruction leaves on the stack, or [None] if
    it is not a one-value expression. The error-free counterpart of the typer's
    [expression_type]: a lint/suggest site reads it silently and skips
    otherwise, never emitting the duplicate diagnostic the typer already owns.
*)

val ref_none_valtype : nullable:bool -> Infer.inferred_valtype
(** The precomputed value type [&?none] / [&none] (the nullable / non-nullable
    bottom reference), built without a type context. *)

val standalone_valtype :
  Infer.inferred_type Infer.Cell.t -> Infer.inferred_valtype option
(** The concrete value type an inference cell stands for on its own, or [None]
    when it has none yet. Pure and context-free (its only reference result is
    the built-in [None_] bottom); the typer's ctx-threading [standalone_valtype]
    delegates here. *)

val record_pun : Ast.location list ref option -> Ast.location -> unit
(** Record a punned struct-literal field's span, for the editor's rename. *)

val record_members :
  (Ast.location * Members.member_receiver) list ref option ->
  Ast.location ->
  Members.member_receiver ->
  unit
(** Record, at a struct field access, the field's span and the receiver it is
    on, for member completion. *)

val record_reference :
  ?hover:hover_target option ->
  resolve_sink ->
  Ast.location ->
  Ast.location list ->
  unit
(** Record a use -> definition(s) reference (dropping synthesized and
    self-referential definitions). *)

module StringSet : Set.S with type elt = string
module StringMap : Map.S with type key = string

val ( let*@ ) : 'a option -> ('a -> 'b option) -> 'b option
val ( let+@ ) : 'a option -> ('a -> 'b) -> 'b option

val ( let>@ ) : 'a option -> ('a -> unit) -> unit
(** The option let-operators: bind through [Some] / map the payload / run an
    effect only when [Some]. *)

(** A conditional-branch-aware name table: declarations carry the assumption
    under which they hold, so mutually-exclusive branches do not conflict. Only
    the type is exposed here; the operations live in {!Typing}'s [Namespace]
    (they emit diagnostics through its [Error]). *)
module Namespace : sig
  type t = {
    cond : Cond.t ref;
    tbl : (string, (string * Ast.location * Cond.t) list) Hashtbl.t;
    links : resolve_sink;
  }
end

(** A name-keyed table layered over a {!Namespace}, tracking references (for the
    unused lints) and an optional hover summary. Only the type is exposed here;
    the operations live in {!Typing}'s [Tbl]. *)
module Tbl : sig
  type 'a t = {
    kind : string;
    namespace : Namespace.t;
    tbl : (string, (Cond.t * 'a) list) Hashtbl.t;
    used : (string, unit) Hashtbl.t;
    hover : 'a -> hover_target option;
  }
end

type types = (Wax_wasm.Types.ref_index * Ast.subtype) Tbl.t
(** The module's type table: each name to its interned index and subtype. *)

type type_context = {
  internal_types : Wax_wasm.Types.t;
  types : (Wax_wasm.Types.ref_index * Ast.subtype) Tbl.t;
  features : Wax_utils.Feature.set;
  mutable subtyping_info_cache : Wax_wasm.Types.subtyping_info option;
}
(** The module-wide type space and its memoised subtyping info (see the field
    comments in [typing_env.ml]). *)

type module_context = {
  diagnostics : Wax_utils.Diagnostic.context;
  warn_unused : bool;
  simplify : bool;
  suggest : bool;
  type_context : type_context;
  types : (Wax_wasm.Types.ref_index * Ast.subtype) Tbl.t;
  functions : (Wax_wasm.Types.Id.t * string * bool) option Tbl.t;
  globals : (bool * Infer.inferred_valtype option) Tbl.t;
  import_globals : (bool * Infer.inferred_valtype option) Tbl.t;
  tags : Ast.functype Tbl.t;
  memories : (int * [ `I32 | `I64 ]) Tbl.t;
  datas : unit Tbl.t;
  tables : ([ `I32 | `I64 ] * Ast.reftype) Tbl.t;
  elems : Ast.reftype Tbl.t;
  structs_by_fields : (string, Ast.ident option) Hashtbl.t;
  not_expression_reported : (int * int, unit) Hashtbl.t;
  mutable locals : (Infer.inferred_valtype option * Ast.location) StringMap.t;
  mutable initialized_locals : StringSet.t;
  mutable deferred_uninit : Ast.ident list ref list;
  unresolved_label : bool ref;
  read_locals : StringSet.t ref;
  local_decls : Ast.ident list ref;
  used_labels : StringSet.t ref;
  deferred_lints : (unit -> unit) list ref;
  label_decls : Ast.ident list;
  assigned_locals : StringSet.t;
  control_types :
    (Ast.label option * Infer.inferred_type Infer.Cell.t array) list;
  return_types : Infer.inferred_type Infer.Cell.t array;
  cond : Cond.t ref;
  cond_env : Cond.env;
  resolve_links : resolve_sink;
  pun_spans : Ast.location list ref option;
  member_completions : (Ast.location * Members.member_receiver) list ref option;
}
(** The per-module type-checking context: diagnostics and run configuration, the
    module-wide type and name tables, the per-function state (reset on entry to
    each function), the conditional-branch assumption, and the editor sinks. See
    the field comments in [typing_env.ml]. *)

val source_slice : module_context -> Ast.location -> string option
(** The source text a location spans, or [None] when unavailable / out of range.
*)

val span : Lexing.position -> Lexing.position -> Ast.location
(** The location running from one position to another. *)

val deletion_edit : Ast.location -> Wax_utils.Diagnostic.edit
(** A machine-applicable edit that removes the given span. *)

val blank_comments : string -> string
(** [s] with every comment blanked to spaces (newlines kept), so a delimiter
    inside a comment is never mistaken for real syntax by the source-scanning
    suggestions. *)
