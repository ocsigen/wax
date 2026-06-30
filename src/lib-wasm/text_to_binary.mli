open Ast

exception Conditional_in_binary of location
(** Raised by {!module_} when the module still contains a conditional annotation
    ([(@if ...)] / [#[if(...)]]), which the binary format cannot represent.
    Carries the annotation's source location so the caller can report a located
    diagnostic. Resolve the conditionals (e.g. with [-D]/[--define]) or target a
    text format instead. *)

exception Unresolved_reference of location * string
(** Raised by {!module_} when a named index or label reference resolves to
    nothing (an undeclared identifier or an out-of-scope label). Carries the
    reference's location and a human-readable message, so the caller can report
    a located diagnostic rather than crash. *)

val module_ : location Text.module_ -> location Binary.module_
