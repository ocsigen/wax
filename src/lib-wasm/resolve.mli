(** Name resolution for Wasm-text modules: maps each use of an index (a symbolic
    [$id] or a numeric index) to the definition it refers to, with source spans
    on both ends. This is the WAT counterpart of the use -> definition table the
    Wax type checker builds ({!Wax_lang.Typing.reference}), and it powers the
    editor's go-to-definition, find-references, document-highlight and rename
    for Wasm text.

    It is a pure structural pass over the AST — no type checking — so it is
    cheap and never raises, and is safe to run on the best-effort parse of a
    broken buffer. *)

type kind =
  | Func
  | Global
  | Type
  | Param
  | Local
  | Label
  | Memory
  | Table
  | Tag
  | Elem
  | Data
  | Field

type binding = {
  defs : Ast.location list;
      (** The span of each definition's [$id]. Usually one; several when the
          same name is defined in more than one conditional-compilation branch
          (each an alternative). Empty for an anonymous (numeric-only)
          definition. *)
  uses : Ast.location list;
      (** Every use site's span — the [$id] or numeric-index token of each
          reference. *)
  kind : kind;
  hover : string option;  (** A one-line summary for hover over the name. *)
}

type expected = {
  e_loc : Ast.location;
      (** The span of an index use — a symbolic [$id], a numeric index, or the
          zero-width point where error recovery inserted a placeholder [0] for a
          missing one. *)
  e_candidates : unit -> (string * kind * string option) list;
      (** The named definitions in scope at [e_loc] for the index space expected
          there: each [(name without [$], kind, hover)]. A thunk so a consumer
          pays the snapshot only for the one use-site it cares about. Empty when
          nothing of that kind is in scope. *)
}
(** Where an index is expected, for completion: the kind of index a position
    wants is fixed by the instruction it sits in, so recovery inserting a
    placeholder index lets the editor offer exactly the names of that space. *)

val f :
  ?expected:expected list ref -> Ast.location Ast.Text.module_ -> binding list
(** [f modul] returns one binding per named symbol, across every module-level
    index space (functions, globals, types, memories, tables, tags, elem and
    data segments), plus each function's locals and labels and each struct
    type's fields. Labels obey lexical scoping with shadowing; locals are
    per-function. A name defined in several conditional-compilation branches
    yields one binding carrying all its definition spans. A binding with an
    empty [uses] list is simply unreferenced.

    When [expected] is given, every index use-site is appended to it as an
    {!expected} (whether or not it resolves), so completion can find the one at
    the cursor and offer the in-scope names of the space it wants. Off (no
    recording) otherwise. *)
