(** Developer-facing debug output, enabled per category with [--debug]. *)

type category = Timing  (** Extend with future debug features. *)

val categories : string list
(** Known category names, for help text and error messages. Currently
    [["timing"]]. *)

val parse : string -> (category, string) result
(** Parse one category name; [Error msg] names the valid categories. *)

val enable : category list -> unit
(** Record which debug categories are active. Call once at startup. *)

val is_enabled : category -> bool
(** Whether the given category was enabled by [enable]. *)

val timed : string -> (unit -> 'a) -> 'a
(** [timed label f] runs [f ()]. When [Timing] is enabled, it measures the
    wall-clock duration of [f] and prints ["<label>: <n> ms"] to stderr;
    otherwise it just runs [f] with no measurement and no output. *)

val timed_if : bool -> string -> (unit -> 'a) -> 'a
(** [timed_if cond label f] is [timed label f] when [cond] holds, and [f ()]
    untimed otherwise. Used to skip timing a measurement-only sub-pass (e.g. the
    dry trivia-collection traversal of the printer). *)
