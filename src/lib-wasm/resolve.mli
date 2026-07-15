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

val f : Ast.location Ast.Text.module_ -> binding list
(** [f modul] returns one binding per named symbol, across every module-level
    index space (functions, globals, types, memories, tables, tags, elem and
    data segments), plus each function's locals and labels and each struct
    type's fields. Labels obey lexical scoping with shadowing; locals are
    per-function. A name defined in several conditional-compilation branches
    yields one binding carrying all its definition spans. A binding with an
    empty [uses] list is simply unreferenced. *)
