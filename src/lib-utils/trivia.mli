(** Parsing context for collecting comments and annotations. *)

type position = Line_start | Inline
type kind = Line_comment | Block_comment | Annotation
type trivia = Item of { content : string; kind : kind } | Blank_line
type entry = { anchor : int; trivia : trivia; position : position }
type context

type associated = {
  before : entry list;
  within : entry list;
  after : entry list;
}

type t = (Ast.location, associated) Hashtbl.t

val associate :
  ?only:(Ast.location, unit) Hashtbl.t -> context -> t * entry list
(** [associate ctx] associates trivia to locations. The second component holds
    the leftover comments that no location owns (trailing comments, or every
    comment when there are no locations); the caller prints them as tail trivia.

    [only] restricts the association to the given set of locations — those the
    printer will actually look up (see {!val:get}). Comments that would
    otherwise attach to a non-emitted node bubble up to an emitted one instead
    of being lost. Collect the set with a dry printing pass. *)

val make : unit -> context
(** Create a new trivia context. *)

val report_item : context -> kind -> string -> unit
(** [report_item ctx kind content] reports a comment or an annotation. *)

val report_newline : context -> unit
(** [report_newline ctx] reports a newline. *)

val report_token : context -> int -> unit
(** [report_token ctx pos] records that a meaningful token ending at byte [pos]
    has been encountered on the current line. *)

val with_pos : context -> Ast.location -> 'a -> ('a, Ast.location) Ast.annotated
(** [with_pos ctx loc v] wraps [v] with location [loc]. *)

val drop_in_ranges : context -> (int * int) list -> unit
(** [drop_in_ranges ctx ranges] removes every comment whose anchor falls within
    one of the half-open byte ranges [\[start, end)]. Used after conditional
    specialization splices out a branch: the comments inside the removed source
    span are discarded rather than re-attaching to a surviving neighbour. The
    ranges and comments are each sorted once and swept together in a single
    pass. *)

(** {1 Association lookup}

    Looking up the trivia attached to a location. Rendering it to styled output
    lives in {!Styled_printer}, which owns the colour theme. *)

val dummy_assoc : associated
(** The empty association ([before], [within] and [after] all empty). *)

val get :
  ?collect:(Ast.location, unit) Hashtbl.t ->
  t ->
  seen:(Ast.location, unit) Hashtbl.t ->
  Ast.location option ->
  associated
(** [get trivia ~seen loc] returns the trivia associated with [loc], with
    de-duplication: it returns {!dummy_assoc} for [None], a missing location, or
    a location already present in [seen]; on the first real hit it records the
    location in [seen] and returns its association. De-duplication is a no-op
    for formatters (each parser location occurs once) and prevents a comment
    from being emitted repeatedly when conversion replicates one source location
    onto several output nodes. *)

val drop_trailing_blank_lines : entry list -> entry list
(** Drop blank-line entries at the end of the list, so emitted tail trivia does
    not leave spurious blank lines at the end of the file. *)

(** {1 Cross-format translation}

    The comment text stored by a lexer keeps the source syntax's delimiters
    ([;; …]/[(; … ;)] for WebAssembly, [// …]/[/* … */] for Wax). When trivia
    collected from one format is replayed onto an AST that is printed in the
    other format (during conversion), the delimiters must be rewritten. *)

type comment_syntax = {
  line : string;  (** line-comment prefix, e.g. [";;"] or ["//"] *)
  block_open : string;  (** block-comment opener, e.g. ["(;"] or ["/*"] *)
  block_close : string;  (** block-comment closer, e.g. [";)"] or ["*/"] *)
}

val wax_syntax : comment_syntax
val wat_syntax : comment_syntax

val retarget :
  src:comment_syntax -> dst:comment_syntax -> t -> entry list -> t * entry list
(** [retarget ~src ~dst trivia tail] rewrites every comment's delimiters from
    the [src] syntax to the [dst] syntax (line-comment prefix and block-comment
    delimiters), leaving blank lines and annotations untouched. Block delimiters
    are balanced in stored content, so a global swap preserves nesting. *)
