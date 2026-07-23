(** Give exported functions a name derived from their export. *)

val name_functions_from_exports :
  Wax_wasm.Ast.location Wax_wasm.Ast.Text.module_ ->
  Wax_wasm.Ast.location Wax_wasm.Ast.Text.module_
(** Assign to each function that has no explicit identifier but is exported an
    identifier derived from its first export name, when that name is a valid
    Wasm identifier. This makes the function appear named in the binary "name"
    custom section (and in textual output), matching the [name-wasm-functions]
    behavior of the js_of_ocaml WAT preprocessor. Functions that already have an
    identifier, or whose first export name is not a valid identifier, are left
    unchanged. Conditional ([(@if ...)]) branches are traversed as well. *)
