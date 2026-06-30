(* The inferred-type lattice used while type checking ([inferred_type]), the
   mutable union-find cells that carry it ([Cell]), and the shared output
   printers and type aliases built on top. [infer.mli] documents the interface
   and keeps [Cell.t] abstract. *)

open Ast

module Output = struct
  include Output

  let valtype f t = Wax_utils.Printer.run f (fun pp -> Output.valtype pp t)
  let comptype f t = Wax_utils.Printer.run f (fun pp -> Output.comptype pp t)
  let instr f i = Wax_utils.Printer.run f (fun pp -> Output.instr pp i)
end

module Cell = struct
  type 'a state = Link of 'a t | Root of 'a
  and 'a t = { mutable state : 'a state }

  let make v = { state = Root v }

  (* The root of [node]'s class, compressing the path to it as a side effect:
     every link followed is repointed straight at the root. *)
  let rec representative node =
    match node.state with
    | Root _ -> node
    | Link next ->
        let root = representative next in
        if next != root then node.state <- Link root;
        root

  let get node =
    let root = representative node in
    (* [representative] returns a root, so the [Link] case cannot arise. *)
    match root.state with
    | Root v -> v
    | Link _ -> assert false

  let merge t1 t2 new_val =
    let root1 = representative t1 in
    let root2 = representative t2 in
    if root1 == root2 then root1.state <- Root new_val
    else begin
      root1.state <- Link root2;
      root2.state <- Root new_val
    end

  let set t new_val =
    let root = representative t in
    root.state <- Root new_val
end

module Internal = Wax_wasm.Ast.Binary.Types
module Simd = Wax_wasm.Simd

type inferred_valtype = {
  typ : valtype;
  internal : Internal.valtype;
  (* For a synthesized reference type that has no source name — a string's byte
     array, an inline function-type cast target — the referenced composite type.
     [typ] keeps the synthetic [<..>] name (so name-based type lookups still
     resolve it), but diagnostics render this composite type inline (e.g.
     [[mut i8]] or [fn(..) -> ..]) rather than the meaningless synthetic name.
     [None] for every other type. *)
  anon_comptype : comptype option;
}

type inferred_type =
  | Unknown
      (** The genuinely polymorphic type of a value taken off the stack of
          unreachable or branch-terminated code. No error has been reported for
          it: an instruction that needs its operand's concrete type to be
          compiled (a call, a field/array access, …) reports one when it meets
          an [Unknown] operand. *)
  | Error
      (** The recovery type of a value whose own typing already failed (a poison
          local/global read, an out-of-range value, an unresolved construction,
          …). An error has already been reported, so [Error] propagates silently
          — instructions treat it like [Unknown] but raise no further error. *)
  | UnknownRef
      (** A non-null reference of unknown heap type — the Wax counterpart of the
          Wasm [(ref bot)]. Produced when a reference is recovered from an
          otherwise-polymorphic value: [null!] / [br_on_null] on an [Unknown]
          operand or a bare [null]. Like [Unknown] it carries no concrete type
          (so it behaves exactly like [Unknown] everywhere — reporting an error
          at a compile-needs-the-type site), except that [subtype] knows it is a
          reference: a subtype of every reference type but of no numeric or
          vector type, so a numeric use of it is still rejected. *)
  | Null
  | Number
  | Int8
  | Int16
  | Int
  | LargeInt
    (* An integer literal too large for i32: it can still be i64, f32 or f64
         (a numeric literal narrowed by context), but never i32 — and it defaults
         to i64 rather than i32. Lets a decompiled out-of-range constant keep its
         width instead of overflowing. *)
  | Float
  | Valtype of inferred_valtype
  | Collecting of collecting
      (** Transient state of a fresh cell used as the result / branch-target
          type of a block whose result is being inferred (see
          [block_infer_general]). A value checked against such a cell (a [br]
          target value, or the fall-through) is recorded into [collected] rather
          than unified — [subtype] would otherwise assert on an unconstrained
          right-hand side. After the body is typed the list is joined by
          [val_lub] to give the result. The cell never escapes inference, so
          other uses treat it like [Unknown]. *)

and collecting = {
  mutable collected : (Ast.location option * inferred_type Cell.t) list;
      (** Each value reaching the block's exit (a [br]/[br_on_*] target value or
          the fall-through), paired with the location it was produced at when
          the caller has one, so a join failure can point at the offending exits
          ([None] otherwise). *)
  declared : inferred_type Cell.t option;
      (** The single result type the block already carries while it is being
          inferred — a Wasm->Wax annotation under test, or [None] when omitted.
          A consumer that needs a concrete type, rather than an ordinary exit
          value (a [resume] handler reading its target label's type), resolves
          to it. *)
  mutable needed : bool;
      (** Set when [declared] is relied upon in a way the join cannot re-derive
          (e.g. read by a [resume] handler), forcing the annotation to be kept.
      *)
}

let rec output_inferred_type f ty =
  match Cell.get ty with
  (* A block result still being inferred renders as the annotation under test (the
     type a reader, e.g. a mismatched [br]/catch, is checked against), not [any]. *)
  | Collecting { declared = Some d; _ } -> output_inferred_type f d
  | Unknown | Error | Collecting _ -> Format.fprintf f "any"
  | UnknownRef -> Format.fprintf f "&_"
  | Null -> Format.fprintf f "null"
  | Number -> Format.fprintf f "number"
  | Int -> Format.fprintf f "int"
  | LargeInt -> Format.fprintf f "int"
  | Int16 -> Format.fprintf f "i16"
  | Int8 -> Format.fprintf f "i8"
  | Float -> Format.fprintf f "float"
  | Valtype { anon_comptype = Some c; _ } -> Output.comptype f c
  | Valtype ty -> Output.valtype f ty.typ

(* [Unknown] (unreachable/branch), [Error] (recovery) and [UnknownRef] (a
   reference of unknown heap type) all stand for "no concrete type known". They
   behave identically except that an [Unknown]/[UnknownRef] operand still
   triggers a fresh diagnostic at a compile-needs-the-type site, whereas an
   [Error] operand stays silent. This predicate is for the many places that need
   only the common "type unknown" test. *)
let is_unknown_or_error ty =
  match Cell.get ty with Unknown | Error | UnknownRef -> true | _ -> false

(* The numeric value types, and shared cells holding them. A concrete base type
   is never re-resolved during inference (only floating cells are unified into a
   concrete type), so a base-type cell's value is invariant and one shared cell
   per type is safe — no need to reallocate one on every use. *)
let i32_valtype = { typ = I32; internal = I32; anon_comptype = None }
let i64_valtype = { typ = I64; internal = I64; anon_comptype = None }
let f32_valtype = { typ = F32; internal = F32; anon_comptype = None }
let f64_valtype = { typ = F64; internal = F64; anon_comptype = None }

(* Wrap a (fully resolved) value type in a fresh cell. *)
let valtype_cell v = Cell.make (Valtype v)
let i32_cell = valtype_cell i32_valtype
let i64_cell = valtype_cell i64_valtype
let f32_cell = valtype_cell f32_valtype
let f64_cell = valtype_cell f64_valtype
