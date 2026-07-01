(** The inferred-type lattice used while type checking, the mutable cells
    ([Cell]) that carry it, and the shared printers/type aliases built on top.
*)

(** Output printers wrapping {!module:Output} so they take a [Format.formatter]
    directly (rather than a {!Wax_utils.Printer.t}), for use in diagnostics. *)
module Output : sig
  val instr : Format.formatter -> _ Ast.instr -> unit
  val valtype : Format.formatter -> Ast.valtype -> unit
  val comptype : Format.formatter -> Ast.comptype -> unit
end

(** A mutable cell carrying a value, backed by union-find: [merge] unifies two
    cells so they share one value, and [get] resolves a cell to that value. *)
module Cell : sig
  type 'a t

  val make : 'a -> 'a t
  val get : 'a t -> 'a

  val merge : 'a t -> 'a t -> 'a -> unit
  (** [merge a b v] unions [a] and [b] and sets the shared root to [v]. *)

  val set : 'a t -> 'a -> unit
  (** [set t v] overwrites the value at [t]'s root with [v]. *)
end

module Internal = Wax_wasm.Ast.Binary.Types
module Simd = Wax_wasm.Simd

type inferred_valtype = {
  typ : Ast.valtype;
  internal : Internal.valtype;
  anon_comptype : Ast.comptype option;
      (** For a synthesized reference type with no source name — a string's byte
          array, an inline function-type cast target — the referenced composite
          type, which diagnostics render inline (e.g. [[mut i8]]) instead of the
          meaningless synthetic [<..>] name kept in [typ]. [None] otherwise. *)
}

type inferred_type =
  | Unknown
      (** The genuinely polymorphic type of a value taken off the stack of
          unreachable or branch-terminated code. No error has been reported for
          it: an instruction that needs its operand's concrete type to be
          compiled reports one when it meets an [Unknown] operand. *)
  | Error
      (** The recovery type of a value whose own typing already failed. An error
          has already been reported, so [Error] propagates silently — treated
          like [Unknown] but raising no further error. *)
  | UnknownRef
      (** A non-null reference of unknown heap type — the Wax counterpart of the
          Wasm [(ref bot)]. Produced when a reference is recovered from an
          otherwise-polymorphic value ([null!] / [br_on_null] on an [Unknown]
          operand or a bare [null]). Behaves like [Unknown] everywhere except
          that [subtype] knows it is a reference: a subtype of every reference
          type but of no numeric or vector type. *)
  | Null
      (** A bare [null] literal: a null reference whose heap type is not yet
          fixed. Narrowed to a concrete reference type by context; with none it
          takes the bottom of the relevant hierarchy. *)
  (* The flexible numeric-literal types below form a small lattice: each is a
     literal with no fixed type that a context (an annotation, an operator, a
     result type) narrows to one concrete numeric type, and that defaults to a
     chosen width when nothing constrains it. [Number] is the bottom (any of the
     four numeric types); [Int]/[Float] commit to the integer/float family;
     [LargeInt] is a [Number] restricted to exclude i32 (still float-capable), NOT
     an integer-committed type. [output_inferred_type] renders them by family —
     [number], [int], [large number], [float] — so a diagnostic distinguishes them
     from one another and from a concrete valtype. *)
  | Number
      (** Any numeric literal: narrows to i32, i64, f32 or f64, defaulting to
          i32. The bottom of the flexible-literal lattice. *)
  | Int8
      (** A packed narrow read — a [load8] or an [i8] struct/array field — which
          yields an i32 value tracked as 8-bit wide so a following widening cast
          ([as i64_s]/[i64_u]) fuses into the read. Defaults to i32. *)
  | Int16
      (** A packed narrow read — a [load16] or an [i16] field — as [Int8] but
          16-bit. Defaults to i32. *)
  | Int
      (** An integer literal committed to the integer family (e.g. by a bitwise
          or shift operator): narrows to i32 or i64, defaulting to i32. It can
          no longer become a float by inference — only an explicit [as] cast,
          which emits a conversion, does that. *)
  | LargeInt
      (** A numeric literal too large for i32: narrows to i64, f32 or f64 (never
          i32), defaulting to i64. Despite the name it is float-capable and so
          belongs to the [number] family, not [Int] — it is [Number] with i32
          excluded by magnitude. Lets a decompiled out-of-range constant keep
          its width instead of overflowing, and renders as [large number]. *)
  | Float
      (** A floating-point literal: narrows to f32 or f64, defaulting to f64. *)
  | Valtype of inferred_valtype
  | Collecting of collecting
      (** Transient state of a fresh cell used as the result / branch-target
          type of a block whose result is being inferred. A value checked
          against it is recorded into [collected] rather than unified, then
          joined by [val_lub] once the body is typed. The cell never escapes
          inference, so other uses treat it like [Unknown]. *)

and collecting = {
  mutable collected : (Ast.location option * inferred_type Cell.t) list;
      (** Each value reaching the block's exit, paired with the location it was
          produced at (when known) so a join failure can point at the offending
          exits. *)
  mutable exacts : (Ast.location option * inferred_type Cell.t) list;
      (** Snapshots of the natural types of values delivered by [br_if] (and
          other pass-through branches). Such a value continues on the stack and
          is typed as the block result, so — unlike an ordinary exit, which need
          only be a subtype — its type must be [exact]ly the result. Recorded
          before the delivery pins the live cell; used to decide the keep-bool
          (drop the annotation only if every exact matches it) and to reject an
          inferred block whose result would differ from an exact. *)
  declared : inferred_type Cell.t option;
      (** The single result type the block already carries while being inferred
          — a Wasm->Wax annotation under test, or [None] when omitted. *)
  mutable needed : bool;
      (** Set when [declared] is relied upon in a way the join cannot re-derive,
          forcing the annotation to be kept. *)
}

val output_inferred_type : Format.formatter -> inferred_type Cell.t -> unit
(** Render an inferred type for diagnostics (an unresolved one prints as [any]).
*)

val is_unknown_or_error : inferred_type Cell.t -> bool
(** Whether a cell resolves to [Unknown], [Error] or [UnknownRef] — the common
    "no concrete type known" test. *)

(** The numeric value types, and shared cells holding them. A concrete base type
    is never re-resolved during inference, so a base-type cell's value never
    changes and a single shared cell per type can stand in for a fresh one. *)

val i32_valtype : inferred_valtype
val i64_valtype : inferred_valtype
val f32_valtype : inferred_valtype
val f64_valtype : inferred_valtype

val valtype_cell : inferred_valtype -> inferred_type Cell.t
(** [valtype_cell v] wraps a fully resolved value type in a fresh cell. *)

val i32_cell : inferred_type Cell.t
val i64_cell : inferred_type Cell.t
val f32_cell : inferred_type Cell.t
val f64_cell : inferred_type Cell.t
