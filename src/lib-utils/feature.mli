(** Optional language features / WebAssembly proposals.

    A feature is enabled or disabled (per its default, overridden on the command
    line). Validation queries {!is_enabled} / {!require} to accept or reject a
    construct, and {!mark_used} / {!used} track which features a module actually
    exercises. *)

type t = Custom_descriptors | Compact_import_section

val all : t list
(** Every known feature. *)

val name : t -> string
(** The command-line / diagnostic name, e.g. ["custom-descriptors"]. *)

val description : t -> string

val enabled_by_default : t -> bool
(** Whether the feature is on when it is not mentioned on the command line. *)

val of_name : string -> t option

type set
(** A resolved configuration: which features are enabled, together with a
    mutable record of which have been used. Create one per module (usage is
    per-module). *)

val configure : (t * bool) list -> set
(** [configure specs] takes each feature's default and applies [specs] over it
    (later entries win). *)

val set_config : (t * bool) list -> unit
(** Install a process-wide default configuration (like the warning policy), read
    by {!default}. Intended to be called once, from the command line. *)

val default : unit -> set
(** A fresh set using the configuration installed by {!set_config} (the built-in
    defaults if none), nothing used yet. *)

val is_enabled : set -> t -> bool
(** Whether [t] is enabled. Does not record usage. *)

val mark_used : set -> t -> unit
(** Record that [t] is used (whether or not it is enabled). Idempotent. *)

val used : set -> t list
(** The features recorded by {!mark_used}, in {!all} order. *)

val parse_spec : string -> (t * bool, string) result
(** Parse a command-line spec: ["NAME"] or ["NAME=on"] enables the feature,
    ["NAME=off"] disables it. *)
