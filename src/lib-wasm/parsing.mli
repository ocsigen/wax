(** Generic parsing utilities. *)

type syntax_error = {
  location : Wax_utils.Ast.location;
  message : Wax_utils.Message.t;
  related : Wax_utils.Diagnostic.label list;
  hint : Wax_utils.Message.t option;
  fix : Wax_utils.Diagnostic.edit option;
}
(** A syntax error, both the payload of {!Syntax_error} and the value
    [parse_diagnostics] / [parse_recover] return: the location range, the
    human-readable message, any related labels (e.g. the matching opening
    delimiter), an optional prose [hint], and an optional machine-applicable
    quick [fix] (a text edit, reusing {!Wax_utils.Diagnostic.edit} so a syntax
    error's fix flows through the same editor/LSP code-action path as the
    typer's suggestions). Recovery derives a [fix] mechanically from an
    insertion repair (see {!Make.parse_recover}). *)

exception Syntax_error of syntax_error
(** Raised when a syntax error occurs, carrying the structured payload above. *)

val syntax_error :
  location:Wax_utils.Ast.location ->
  ?related:Wax_utils.Diagnostic.label list ->
  ?hint:Wax_utils.Message.t ->
  ?fix:Wax_utils.Diagnostic.edit ->
  Wax_utils.Message.t ->
  'a
(** [syntax_error ~location ?related ?hint ?fix message] raises {!Syntax_error}
    with the structured payload. Smart constructor used by every enriched raise
    site (the lexers and both grammars), so the payload shape is spelled once.
*)

val syntax_error_pair :
  (Lexing.position * Lexing.position) * Wax_utils.Message.t -> exn
(** [syntax_error_pair ((loc_start, loc_end), message)] builds (without raising)
    the {!Syntax_error} value from the legacy position-pair payload, with no
    [related]/[hint]/[fix]. It keeps the many pre-existing
    [raise (Syntax_error (pair, msg))] sites in the lexers and grammars a
    one-token change; new code should prefer the raising {!syntax_error}. *)

type sync_class =
  | Open
  | Close
  | Boundary
  | Leader
  | Terminal
  | Skip
      (** How the panic-mode recovery of {!Make.parse_recover} treats a token
          when it is scanning for a place to resynchronize. The skip is
          nesting-aware: it tracks the bracket depth entered {e while skipping}
          so a boundary belonging to a group opened inside the skipped span does
          not resynchronize the enclosing construct.

          - [Open] — an opening bracket. Descends one nesting level; never
            itself a resync point.
          - [Close] — a closing bracket. At the outer level (depth 0) it is a
            resync point closing an enclosing construct; otherwise it ascends
            one level (matching an [Open] met while skipping) and scanning
            continues.
          - [Boundary] — a non-bracket resync point (typically a statement
            separator), counted only at the outer level, like a [Close].
            Recovery stops there, unwinds the parser stack to the closest state
            that can shift it, shifts it, and resumes.
          - [Leader] — a resync point valid at {e any} depth: an
            item/statement-leading keyword. Recovery stops at one even inside an
            unbalanced opener, so a stray bracket cannot swallow the next
            top-level item.
          - [Terminal] — the end-of-input token. Recovery stops at it but never
            discards it; if no stacked state can accept it, parsing gives up
            (the best-effort AST is then absent).
          - [Skip] — anything else: discarded while scanning for the next
            boundary. *)

(** Core parser over a Menhir incremental API, {e without} the fast parser. The
    incremental parser produces both the AST and, via [Parser_messages], the
    error in a single pass, so this is all an in-process consumer that only
    wants [parse_diagnostics] needs. See {!Make_parser} for the fast-path
    variant. *)
module Make (Output : sig
  type t
end) (Tokens : sig
  type token
end) (_ : sig
  module Make (_ : sig
    type t = Wax_utils.Trivia.context

    val context : t
  end) : sig
    type token = Tokens.token

    module MenhirInterpreter :
      MenhirLib.IncrementalEngine.INCREMENTAL_ENGINE with type token = token

    module Incremental : sig
      val parse : Lexing.position -> Output.t MenhirInterpreter.checkpoint
    end
  end
end) (_ : sig
  val message : int -> string
end) (_ : sig
  val token :
    Wax_utils.Trivia.context ->
    (Sedlexing.lexbuf -> Tokens.token) * Lexing.position option ref
end) : sig
  val parse :
    ?color:Wax_utils.Colors.flag ->
    filename:string ->
    unit ->
    Output.t * Wax_utils.Trivia.context
  (** Parse a file from a filename (reads from stdin if filename is empty or
      "-"). On a syntax error the diagnostic is printed and {!Syntax_error} is
      raised; the caller decides how to terminate (the CLI exits 128). *)

  val parse_from_string :
    ?color:Wax_utils.Colors.flag ->
    filename:string ->
    string ->
    Output.t * Wax_utils.Trivia.context
  (** Parse from a string. On a syntax error the diagnostic is printed and
      {!Syntax_error} is raised; the caller decides how to terminate (the CLI
      exits 128). *)

  val parse_diagnostics :
    filename:string ->
    string ->
    (Output.t * Wax_utils.Trivia.context, syntax_error) result
  (** Parse from a string, returning [Ok (ast, context)] or [Error error]
      without printing or exiting. For in-process use — e.g. an editor that
      wants the syntax error as data to report as a diagnostic — where the
      print-and-exit behaviour of {!parse_from_string} is unwanted. *)

  val parse_recover :
    filename:string ->
    sync:(Tokens.token -> sync_class) ->
    ?insert:(Tokens.token * Wax_utils.Message.t * bool * string) list ->
    ?closers:(Tokens.token * string) list ->
    ?barrier:Tokens.token * (Tokens.token -> bool) * (Tokens.token -> bool) ->
    string ->
    Output.t option * syntax_error list * Wax_utils.Trivia.context
  (** Parse with panic-mode error recovery, collecting {e every} syntax error
      instead of stopping at the first. On each error the parser stack is
      resynchronized: tokens are discarded up to the next boundary (as
      classified by [sync]), the stack is unwound to the closest state that can
      shift that boundary, the boundary is shifted, and parsing resumes; see
      {!sync_class}. A lexer error (bad character, malformed byte) is likewise
      recorded and skipped, so a stray character does not truncate the parse.
      Returns the best-effort AST ([Some ast] if parsing reached an accepting
      state, [None] if recovery could not), the errors in source order, and the
      trivia context. Nothing is printed. Intended for in-process consumers such
      as a language server that must report all errors and keep a partial AST
      across them.

      [insert] is a list of candidate tokens (each
      [(token, diagnostic, move_pos, source_text)]: the token to insert, the
      diagnostic to report, whether to place the caret at the previous token's
      end rather than the offending token, and the token's source spelling used
      as the derived quick fix's [new_text]) that recovery may {e insert} in
      front of an offending token instead of skipping to a boundary — a
      statement separator like [;], or a placeholder operand like a zero [0]
      that lets an incomplete construct complete. The candidates are tried in
      order; the engine's [acceptable] answers whether one fits, and the repair
      is kept only if the offending token then shifts too (validated, so a wrong
      guess is discarded); a validated repair also attaches [source_text] as a
      machine-applicable [fix]. Insertion is attempted at most once per source
      position, so it cannot loop; it falls back to skip-based recovery. The
      candidates also serve [close_pending] (e.g. completing an unclosed
      construct at EOF). Omit ([[]]) to disable insertion.

      [closers] lists the closing-bracket tokens, each with its source spelling.
      At end of input inside an unclosed bracketed construct, recovery
      auto-closes: it inserts whichever of these the parser accepts (and,
      between them, the [insert] separator when a statement must be terminated
      first), repeatedly, until EOF is accepted, so the construct the user is
      still typing reduces into the best-effort AST instead of being unwound
      away and dropped. The syntax error is still reported; only the recovered
      AST improves. When the auto-close used {e closers alone} (no [insert]
      separator), the concatenation of their spellings is attached to that error
      as a machine-applicable [fix] — a single edit inserting the missing
      closers at the boundary. Omit to keep the unwind-and-discard behaviour.

      [barrier] adapts recovery to a {e fully parenthesized} grammar (WAT),
      which has no separator or leader token: a missing closer then surfaces not
      as an unclosed construct but as a new field offered where an instruction
      was expected. It is a triple — the [(] token to re-offer, a predicate for
      a field keyword written after a bare [(] (offered as the pair [( ; kw]),
      and a predicate for a fused [(type]/[(import]/[(export] opener the lexer
      folds into one token (offered alone) — and lets recovery close the
      enclosing field and restart at the new one instead of letting paren-depth
      counting swallow the sibling; both predicates fire only at the enclosing
      level, so a field-like opener nested in skipped content is not mistaken
      for a field. Supplying [barrier] {e also} enables {e group-drop}: when a
      closer cannot be shifted because an inner group's production is incomplete
      and needs more than one token to repair (e.g. [(v128.const)]), the broken
      group is dropped whole and its enclosing field kept. Omit (the default) in
      a grammar with real separator/leader anchors (Wax), where neither applies.
  *)
end

(** {!Make} plus a fast parser, whose only role is speed on the happy path:
    [parse_from_string] tries it and, on a syntax error, falls back to the
    core's incremental parser to produce the message. Same result signature as
    {!Make}. The CLI uses this; an in-process consumer can use {!Make} directly.
*)
module Make_parser (Output : sig
  type t
end) (Tokens : sig
  type token
end) (_ : sig
  module Make (_ : sig
    type t = Wax_utils.Trivia.context

    val context : t
  end) : sig
    type token = Tokens.token

    module MenhirInterpreter :
      MenhirLib.IncrementalEngine.INCREMENTAL_ENGINE with type token = token

    module Incremental : sig
      val parse : Lexing.position -> Output.t MenhirInterpreter.checkpoint
    end
  end
end) (_ : sig
  module Make (_ : sig
    type t = Wax_utils.Trivia.context

    val context : t
  end) : sig
    type token = Tokens.token

    exception Error

    val parse : (Lexing.lexbuf -> token) -> Lexing.lexbuf -> Output.t
  end
end) (_ : sig
  val message : int -> string
end) (_ : sig
  val token :
    Wax_utils.Trivia.context ->
    (Sedlexing.lexbuf -> Tokens.token) * Lexing.position option ref
end) : sig
  val parse :
    ?color:Wax_utils.Colors.flag ->
    filename:string ->
    unit ->
    Output.t * Wax_utils.Trivia.context
  (** As {!Make.parse}, using the fast parser on the happy path. *)

  val parse_from_string :
    ?color:Wax_utils.Colors.flag ->
    filename:string ->
    string ->
    Output.t * Wax_utils.Trivia.context
  (** As {!Make.parse_from_string}, using the fast parser on the happy path. *)

  val parse_diagnostics :
    filename:string ->
    string ->
    (Output.t * Wax_utils.Trivia.context, syntax_error) result
  (** As {!Make.parse_diagnostics}. *)

  val parse_recover :
    filename:string ->
    sync:(Tokens.token -> sync_class) ->
    ?insert:(Tokens.token * Wax_utils.Message.t * bool * string) list ->
    ?closers:(Tokens.token * string) list ->
    ?barrier:Tokens.token * (Tokens.token -> bool) * (Tokens.token -> bool) ->
    string ->
    Output.t option * syntax_error list * Wax_utils.Trivia.context
  (** As {!Make.parse_recover}. (Recovery always uses the incremental engine;
      there is no fast-path variant.) *)
end
