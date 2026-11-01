exception Missing_string_imports of Ast.location
(** Raised by {!module_} on a string literal building a JavaScript string in a
    module that does not declare the import module of its string constants.
    Carries the literal's location. *)

val module_ : Ast.location Ast.Text.module_ -> Ast.location Ast.Text.module_
(** Apply the module's string settings to its string literals, leaving a module
    without [(@string_type …)] or [(@string_imports …)] annotations:

    - an untyped [(@string …)] takes the type [(@string_type $t)] designates,
      when the module designates one;
    - a string literal building a JavaScript string — a plain one
      ([(@string extern …)]), or one wrapped in a struct whose single field is
      an [anyref] or an [externref] — is expanded into a [global.get] of an
      imported string constant,
      [(import "<module>" "<text>" (global (ref extern)))], wrapped by a
      [struct.new] for a struct (internalized first for an [anyref] field), the
      import module being the one [(@string_imports "<module>")] declares. One
      import is synthesised per distinct text, after the module's own imports;
      numeric references to the module's own globals are shifted past them.

    Literals building an array are left for the callers ({!Desugar},
    {!Text_to_binary}) to lower. A module containing a conditional annotation is
    returned unchanged, for the caller to report the conditional. Raises
    {!Missing_string_imports} on a JavaScript-string literal in a module without
    a [(@string_imports …)] annotation. *)

val untyped_literal : Ast.location Ast.Text.module_ -> Ast.location option
(** The location of the first untyped string literal ([(@string "…")], or a
    [(@string $id "…")] global) of a module that does not designate a string
    type with [(@string_type …)]: such a literal builds a byte array. [None]
    when the module designates a string type, or has no untyped literal. Meant
    for a build in which string literals must not silently fall back to byte
    arrays, e.g. one where strings are JavaScript strings. *)
