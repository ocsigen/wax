(** Unicode identifier character properties, from a table generated from uucp
    (see [xid.ml], regenerated with [dune build @src/lib-utils/regenerate-xid]).
    Used to validate identifiers lexed by a coarse rule, so the strict XID
    classes stay out of the lexer's DFA. *)

val is_xid_start : int -> bool
(** [is_xid_start cp] is whether the Unicode codepoint [cp] has the [XID_Start]
    property. *)

val is_xid_continue : int -> bool
(** [is_xid_continue cp] is whether the Unicode codepoint [cp] has the
    [XID_Continue] property. *)
