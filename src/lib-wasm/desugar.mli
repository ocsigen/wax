open Ast

exception Conditional_remains of location
(** Raised by {!module_} when an [(@if ...)] conditional-compilation annotation
    is still present. Such annotations have no core-wasm form; they must have
    been resolved beforehand (e.g. with [-D]/[--define]). Carries the
    annotation's source location so the caller can report a located diagnostic.
*)

val module_ : location Text.module_ -> location Text.module_
(** Expand the Wax-specific [@string] and [@char] annotations of a WAT module
    into core WebAssembly ([array.new_fixed] / [i32.const]) — including
    module-level [(@string ...)] globals — so the result is plain WebAssembly
    text. A synthesised [i8] array type is appended when an untyped string needs
    one. Also synthesises the declarative element segment for any [ref.func]
    that Wax's lenient reader let the module omit (via {!Declare_refs}), so the
    output passes strict/spec reference validation. Raises
    {!Conditional_remains} on any remaining [(@if ...)]. *)
