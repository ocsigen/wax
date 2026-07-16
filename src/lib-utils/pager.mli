val use : (out_channel -> unit) -> unit
(** [use f] calls [f] with standard output, routed through a pager when it is a
    terminal. Read any standard-input content before calling [use]: the pager
    takes over the terminal as soon as it starts (raw mode, echo off), which
    would hide input still being typed. *)

val allows_color : unit -> bool
(** Whether output written through [use] may carry ANSI escape sequences: either
    it is not paged at all, or the pager renders them ([less -R]; a user-chosen
    [$PAGER] is trusted to). Windows' default [more] passes them through raw,
    which legacy consoles display as garbage. *)
