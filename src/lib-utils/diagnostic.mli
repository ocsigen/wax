type context
type severity = Error | Warning

type label = {
  location : Ast.location;
  message : Format.formatter -> unit -> unit;
}

val run :
  ?color:Colors.flag ->
  source:string option ->
  ?related:label list ->
  ?exit:bool ->
  ?output:Format.formatter ->
  ?policy:Warning.policy ->
  (context -> 'a) ->
  'a
(** [run ?color ~source ?related ?exit ?output ?policy f] runs the diagnostic
    context [f]. [source] is the source code for the diagnostics (if available).
    [policy] sets the level — hidden, displayed, or promoted to an error — of
    each {e named} warning reported with [report]'s [warning] argument; it
    defaults to the policy installed by {!set_policy}. *)

val source : context -> string option
(** [source context] is the source code the context was created with (via
    {!run}'s [~source]), if any. Byte offsets in a diagnostic's [location]
    ([pos_cnum]) index into this string; used by lints that need to inspect the
    original text, e.g. to tell whether a subexpression was parenthesized. *)

val set_policy : Warning.policy -> unit
(** [set_policy policy] installs [policy] as the default for every context
    created afterwards (those that do not pass an explicit [?policy]). Intended
    to be called once, from the command line. *)

val report :
  context ->
  location:Ast.location ->
  severity:severity ->
  ?warning:Warning.t ->
  ?universal:bool ->
  ?hint:(Format.formatter -> unit -> unit) ->
  ?related:label list ->
  message:(Format.formatter -> unit -> unit) ->
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

val collector : ?source:string -> unit -> context
(** A context that buffers reported errors without printing or exiting. It never
    renders diagnostics, so it needs none of {!run}'s rendering parameters
    ([color], [output]); pass [?source] only when a lint reads the original text
    via {!source} while reporting against this context. *)

type entry
(** A collected diagnostic. *)

val collected : context -> entry list
(** [collected context] returns the errors accumulated in [context] (without
    clearing or printing them). *)

val entry_location : entry -> Ast.location
val entry_severity : entry -> severity
val entry_warning : entry -> Warning.t option
val entry_universal : entry -> bool
val entry_message : entry -> Format.formatter -> unit -> unit
val entry_hint : entry -> (Format.formatter -> unit -> unit) option
val entry_related : entry -> label list

type theme
(** A theme for diagnostic output. *)

val output_error_with_source :
  ?output:Format.formatter ->
  theme:theme ->
  source:string ->
  location:Ast.location ->
  severity:severity ->
  ?hint:(Format.formatter -> unit -> unit) ->
  ?related:label list ->
  (Format.formatter -> unit -> unit) ->
  unit
(** [output_error_with_source ?output ~theme ~source ~location ~severity ?hint
     ?related message] prints an error message with a source code snippet. *)

val get_theme : ?color:Colors.flag -> unit -> theme
(** [get_theme ?color ()] returns the diagnostic theme. *)
