type lr1_item = {
  lhs : string;  (** The left-hand side of the production rule. *)
  rhs_before : string list;
      (** The symbols on the right-hand side before the dot. *)
  rhs_after : string list;
      (** The symbols on the right-hand side after the dot. *)
  lookaheads : string list;  (** The lookahead terminal symbols. *)
}
(** Structured representation of an LR(1) item. *)

type spurious_reduction = { symbol : string; production : string }
(** Structured representation of a spurious reduction warning. *)

type comment_data = {
  state : int;  (** The error state number. *)
  lr1_items : lr1_item list;  (** The LR(1) items describing the state. *)
  stack_suffix : string list;  (** The known suffix of the stack. *)
  spurious_reductions : spurious_reduction list;
      (** List of spurious reductions. *)
}
(** Information extracted from the auto-generated comments in the .messages
    file. *)

type entry = {
  entry_point : string;  (** The entry point, e.g. "parse" *)
  sentence : string;  (** The input sentence that reaches the error state. *)
  data : comment_data;  (** The metadata extracted from the comment block. *)
  message : string;  (** The error message text. *)
  original_comments : string list;  (** The raw comment lines. *)
}
(** A single entry in the messages file. *)

val parse_file : string -> entry list
(** [parse_file filename] reads a Menhir .messages file and returns a list of
    parsed entries. It handles reading the file, parsing comments, and
    separating entries. *)

val read_lines : string -> string list
(** [read_lines filename] returns the file's lines with any trailing carriage
    return stripped. Shared with the generator's [.overrides] loader. *)
