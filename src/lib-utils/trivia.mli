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

type t
(** A location-keyed trivia table (built by {!associate}). *)

val empty : unit -> t
(** An empty trivia table (for a printing pass that carries no comments — e.g. a
    binary-input conversion, or the dry pass that only populates [collect]). *)

type locations
(** An opaque set of source locations — the [collect]/[seen] tables. It keys on
    the start/end byte offsets only (cheap to hash and compare, no
    filename-string traversal), which the location-keyed lookup on every printed
    atom used to be dominated by. A caller only ever fills the one {!associate}
    hands its [collect] function; all lookups happen inside {!Trivia}. *)

val create_locations : unit -> locations

val mark : locations -> Ast.location -> unit
(** [mark set loc] records [loc] in [set]. Lets {!associate}'s [collect] build
    its set by walking the document it is about to print, instead of driving a
    discarded dry print pass whose only effect is the same {!val:get}-time
    [collect]. *)

val associate : collect:(locations -> unit) -> context -> t * entry list
(** [associate ~collect ctx] associates trivia to locations. The second
    component holds the leftover comments that no location owns (trailing
    comments, or every comment when there are no locations); the caller prints
    them as tail trivia.

    [collect] records the locations the printer will actually look up (see
    {!val:get}) into a set of this function's making — it is the language's
    [Output.collect] (a walk of the laid-out document, or a dry printing pass).
    The association covers the spans in that set that are also parse nodes: a
    comment would otherwise either attach to a node the printer skips (and be
    lost) or to a looked-up span that is no source construct at all — a
    conversion also stamps output nodes with token spans and with
    {!Ast.dummy_loc}. *)

val make : unit -> context
(** Create a new trivia context. *)

val report_item : context -> kind -> string -> unit
(** [report_item ctx kind content] reports a comment or an annotation. *)

val report_newline : context -> unit
(** [report_newline ctx] reports a newline. *)

val report_token : context -> int -> unit
(** [report_token ctx pos] records that a meaningful token ending at byte [pos]
    has been encountered on the current line. *)

val record_pos : context -> Ast.location -> unit
(** [record_pos ctx loc] records that a node spans [loc], without building the
    wrapper. For a node whose record is not an {!Ast.annotated} — an
    instruction, which carries hints besides its location — and so cannot go
    through {!with_pos}. *)

val with_pos : context -> Ast.location -> 'a -> ('a, Ast.location) Ast.annotated
(** [with_pos ctx loc v] wraps [v] with location [loc], recording the span as
    {!record_pos} does. *)

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
  ?collect:locations -> t -> seen:locations -> Ast.location option -> associated
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
    other format, the delimiters must be rewritten; a conversion does so on the
    context it carries over. *)

type comment_syntax = {
  line : string;  (** line-comment prefix, e.g. [";;"] or ["//"] *)
  block_open : string;  (** block-comment opener, e.g. ["(;"] or ["/*"] *)
  block_close : string;  (** block-comment closer, e.g. [";)"] or ["*/"] *)
}

val wax_syntax : comment_syntax
val wat_syntax : comment_syntax

val retarget : src:comment_syntax -> dst:comment_syntax -> context -> unit
(** [retarget ~src ~dst ctx] rewrites the delimiters of every comment collected
    in [ctx] from the [src] syntax to the [dst] syntax (line-comment prefix and
    block-comment delimiters), leaving blank lines and annotations untouched.
    Block delimiters are balanced in stored content, so a global swap preserves
    nesting.

    Called by a cross-format conversion, on the context whose trivia will be
    replayed onto the converted AST — the rewrite belongs to the translation,
    not to printing. It touches only comment text, never an anchor or a kind, so
    it commutes with {!associate}. *)
