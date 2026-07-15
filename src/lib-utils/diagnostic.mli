type context
type severity = Error | Warning

type output_format =
  | Human
  | Json
  | Short
      (** How diagnostics are rendered: [Human] (source snippets, the default),
          [Json] (one JSON object per diagnostic per line, i.e. JSON Lines), or
          [Short] (one [file:line:col: severity: message] line per diagnostic,
          gcc/rustc style, for editors with a simple line-based error parser).
      *)

type label = { location : Ast.location; message : Message.t }

val run :
  color:Colors.flag ->
  ?palette:Colors.theme ->
  source:string option ->
  ?related:label list ->
  ?exit:bool ->
  ?output:Format.formatter ->
  ?policy:Warning.policy ->
  (context -> 'a) ->
  'a
(** [run ~color ?palette ~source ?related ?exit ?output ?policy f] runs the
    diagnostic context [f], a {e rendering} context that prints its diagnostics.
    [color] is mandatory: a rendering context must decide up front whether to
    emit ANSI colour, so a caller cannot silently fall back to the [Auto]
    default (which sniffs stderr) — contrast {!collector}, which renders nothing
    and takes no [color]. [palette] (default {!Colors.wax_theme}) is the source
    palette used to colour AST fragments embedded in messages; pass
    {!Colors.wat_theme} for a checker whose diagnostics embed WebAssembly-text
    types (e.g. {!Wax_wasm.Validation}), so they match WAT source colouring.
    [source] is the source code for the diagnostics (if available). [policy]
    sets the level — hidden, displayed, or promoted to an error — of each
    {e named} warning reported with [report]'s [warning] argument; it defaults
    to the policy installed by {!set_policy}. *)

val source : context -> string option
(** [source context] is the source code the context was created with (via
    {!run}'s [~source]), if any. Byte offsets in a diagnostic's [location]
    ([pos_cnum]) index into this string; used by lints that need to inspect the
    original text, e.g. to tell whether a subexpression was parenthesized. *)

val set_policy : Warning.policy -> unit
(** [set_policy policy] installs [policy] as the default for every context
    created afterwards (those that do not pass an explicit [?policy]). Intended
    to be called once, from the command line. *)

val set_format : output_format -> unit
(** [set_format fmt] selects how diagnostics are rendered (default [Human]).
    With [Json], every diagnostic — errors, warnings, and syntax errors — is
    written to stderr as one JSON object per line. Intended to be called once,
    from the command line. *)

val report :
  context ->
  location:Ast.location ->
  severity:severity ->
  ?warning:Warning.t ->
  ?universal:bool ->
  ?hint:Message.t ->
  ?related:label list ->
  message:Message.t ->
  unit ->
  unit
(** [report context ~location ~severity ?warning ?universal ?hint ?related
     ~message ()] reports a diagnostic. [warning] names the warning so the
    context's policy can decide its level (hide it, display it, or promote it to
    an error); it is meaningful only with [~severity:Warning] and is ignored for
    errors. [universal] (default [false]) marks a diagnostic that is meaningful
    only when it holds in {e every} reachable configuration; during
    path-sensitive exploration (see {!Cond_explore.check_all}) such a diagnostic
    is reported only if it arises under all assumptions, not just some. The
    unused-local warning is universal: a local used in one conditional branch is
    not "unused" merely because another configuration prunes that branch. *)

exception Aborted
(** Raised by {!abort} to unwind a pass that cannot meaningfully continue after
    an error. {!run} catches it, flushes the queued diagnostics (exiting the
    process when its context exits on error), and otherwise re-raises it. *)

val abort : unit -> 'a
(** [abort ()] raises {!Aborted}. Use after {!report} in a pass (such as a
    format conversion) where continuing past the error would only produce
    spurious failures. *)

(** {1 Collecting diagnostics}

    A [collector] context accumulates reported errors instead of printing them,
    so they can be inspected and re-reported. Used for path-sensitive
    validation, where the same code is validated under several assumptions. *)

val collector : ?parent:context -> ?source:string -> unit -> context
(** A context that buffers reported errors without printing or exiting. It never
    renders diagnostics, so it needs none of {!run}'s rendering parameters
    ([color], [output]); pass [?source] only when a lint reads the original text
    via {!source} while reporting against this context. When [parent] is given
    (the collector checks part of a larger run — e.g. one configuration of a
    path-sensitive check), it inherits the parent's error-recovery mode (see
    {!set_recovery}) so cascade suppression carries into it. *)

val set_recovery : context -> bool -> unit
(** Put [context] into (or out of) error-recovery mode. In recovery mode a
    consumer that type-checks a best-effort AST recovered past syntax errors
    (see {!Wax_wasm.Parsing}'s [parse_recover]) has told the checker that name
    resolution is unreliable — content dropped at a sync boundary leaves its
    bindings absent — so "not bound" diagnostics are suppressed as likely
    cascades while real type errors still surface. Off by default. *)

val in_recovery : context -> bool
(** Whether [context] is in error-recovery mode (see {!set_recovery}). *)

type entry
(** A collected diagnostic. *)

val collected : context -> entry list
(** [collected context] returns the errors accumulated in [context] (without
    clearing or printing them). *)

val entry_location : entry -> Ast.location
val entry_severity : entry -> severity
val entry_warning : entry -> Warning.t option
val entry_universal : entry -> bool
val entry_message : entry -> Message.t
val entry_hint : entry -> Message.t option
val entry_related : entry -> label list

type theme
(** A theme for diagnostic output. *)

val output_error_with_source :
  ?output:Format.formatter ->
  theme:theme ->
  source:string ->
  location:Ast.location ->
  severity:severity ->
  ?hint:Message.t ->
  ?related:label list ->
  Message.t ->
  unit
(** [output_error_with_source ?output ~theme ~source ~location ~severity ?hint
     ?related message] prints an error message with a source code snippet. *)

val get_theme : ?color:Colors.flag -> ?palette:Colors.theme -> unit -> theme
(** [get_theme ?color ?palette ()] returns the diagnostic theme. [palette]
    (default {!Colors.wax_theme}) is the source palette for AST fragments
    embedded in message bodies. *)
