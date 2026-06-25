(** Embedding API for the Wax toolchain: assemble WAT or Wax source into a
    WebAssembly binary module, with conditional-compilation variables resolved.

    This is the entry point intended for use from other programs. The per-stage
    libraries ([wax.wasm], [wax.conversion], ...) expose toolchain internals
    whose names only make sense from within Wax; prefer this module. *)

type binary_module = Wax_conversion.Driver.binary_module

(** Conditional-compilation variables — the [-D]/[--define] bindings against
    which [(@if ...)] annotations are specialized. *)
module Define : sig
  type value = Bool of bool | Version of int * int * int | String of string

  type t
  (** A set of name-to-value bindings. *)

  val of_list : (string * value) list -> t
  (** Build bindings from name/value pairs; on a duplicate name the last wins.
  *)
end

val wat_to_binary :
  ?defines:Define.t ->
  ?name_functions:bool ->
  ?validate:bool ->
  filename:string ->
  string ->
  binary_module
(** [wat_to_binary ~filename contents] parses the WAT [contents], specializes
    its [(@if ...)] annotations against [defines] (default empty), optionally
    [validate]s it (default [false]), and lowers it to the binary format. When
    [name_functions] is set (default [false]), each anonymous exported function
    is named after its export so it appears in the binary "name" section.

    All conditional annotations must be resolved (binary cannot represent them);
    an exception is raised if one survives specialization, so [defines] should
    determine every [(@if ...)] reached. *)

val wax_to_binary :
  ?defines:Define.t ->
  ?validate:bool ->
  filename:string ->
  string ->
  binary_module
(** As {!wat_to_binary}, but the [contents] are in the Wax language: the module
    is type-checked and compiled to a WebAssembly text module before being
    lowered to binary. (Wax functions always carry a name, so there is no
    [name_functions] option.) *)

val output_binary :
  out_channel:out_channel ->
  ?opt_source_map_file:string ->
  binary_module ->
  unit
(** Write a binary module to [out_channel], optionally emitting a source map to
    [opt_source_map_file]. *)
