open Ast

exception Conditional_in_binary of location
(** Raised by {!module_} when the module still contains a conditional annotation
    ([(@if ...)] / [#[if(...)]]), which the binary format cannot represent.
    Carries the annotation's source location so the caller can report a located
    diagnostic. Resolve the conditionals (e.g. with [-D]/[--define]) or target a
    text format instead. *)

val module_ : location Text.module_ -> location Binary.module_
