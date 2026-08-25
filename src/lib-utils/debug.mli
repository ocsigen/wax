(** Developer-facing debug output, enabled per category with [--debug]. *)

type category =
  | Timing
  | Width_check
      (** [Width_check] turns on the Wasm-to-Wax differential width check (see
          {!Wax_lang.Typing.f}'s [~width_check]): a decompiled expression whose
          printed form Wax would re-infer at another width is reported instead
          of being printed. Extend with future debug features. *)
  | Width_record
      (** [Width_record] turns on the recording-gap census: on a Wasm-to-Wax
          conversion, report (to stderr) every numeric-valued node the
          conversion emitted without recording the type its opcode states —
          [Ast.expectation]'s [Unset], as opposed to a deliberate [Contextual].
          Such a node is invisible to the width check above by construction, so
          a gap can only surface as a silent drift; this makes the class
          enumerable instead. *)

val categories : string list
(** Known category names, for help text and error messages. Currently
    [["timing"; "width-check"; "width-record"]]. *)

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
