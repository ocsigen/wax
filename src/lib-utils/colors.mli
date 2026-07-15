(** Determines whether color output should be used. *)
type flag = Never | Always | Auto

val should_use_color : color:flag -> out_channel:out_channel option -> bool
(** [should_use_color ~color ~out_channel] checks if ANSI color codes should be
    emitted based on the [color] flag and the [out_channel]. If [Auto], it
    checks for `NO_COLOR` environment variable, `TERM` environment variable, and
    if [out_channel] is a TTY. *)

val update_flag : color:flag -> flag
(** [update_flag ~color ~out_channel] checks if ANSI color codes should be
    emitted based on the [color] flag and stdout. If [Auto], it checks for
    `NO_COLOR` environment variable, `TERM` environment variable, and if stdout
    is a TTY. *)

(** ANSI escape codes for basic text formatting and colors. *)
module Ansi : sig
  val reset : string
  val bold : string
  val red : string
  val high_red : string
  val green : string
  val yellow : string
  val high_yellow : string
  val blue : string
  val magenta : string
  val cyan : string
  val white : string
  val grey : string
end

(** [style] represents a semantic category for syntax highlighting. *)
type style =
  | Keyword
      (** For language keywords (e.g., `func`, `let`, `if` in Wax; `module`,
          `func`, `(type ...)` in Wasm). *)
  | Instruction  (** For Wasm instructions (e.g., `i32.add`, `call $func`). *)
  | Attribute
      (** For attributes (e.g., `offset=4`, `align=2` in Wasm; Rust-like
          attributes like `#[derive(...)]`). *)
  | Type  (** For type names (e.g., `i32`, `f64`, `funcref`). *)
  | Identifier  (** For variable, function, or type identifiers. *)
  | Constant
      (** For numeric or boolean literals (e.g., `123`, `0.5`, `true`). *)
  | String  (** For string literals. *)
  | Operator  (** For operators (e.g., `+`, `-`, `=`, `!`). *)
  | Annotation
      (** For annotations (e.g., `(@custom)` in Wasm; Rust macros like
          `vec![]`). *)
  | Comment  (** For comments in the code. *)
  | Punctuation  (** For structural punctuation (e.g., (, ), :, ;, ,). *)

type theme = {
  keyword : string;
  instruction : string;
  attribute : string;
  type_ : string;
  identifier : string;
  constant : string;
  string : string;
  operator : string;
  annotation : string;
  comment : string;
  punctuation : string;
  reset : string;
}
(** [theme] defines the ANSI escape codes for each syntax [style]. *)

val escape_sequence : theme -> style -> string
(** [escape_sequence theme style] returns the ANSI escape code for the given
    [style] from the provided [theme]. *)

val wax_theme : theme
(** The Wax source palette: used by {!Wax_lang.Output} to render Wax source, and
    by diagnostics to colour a Wax AST fragment embedded in a message. *)

val wat_theme : theme
(** The WebAssembly-text source palette: used by {!Wax_wasm.Output} to render
    WAT source, and by diagnostics to colour a WAT AST fragment embedded in a
    message (e.g. types in red rather than the Wax cyan). *)

val no_color : theme
(** A theme that produces no color output, used when coloring is disabled. *)
