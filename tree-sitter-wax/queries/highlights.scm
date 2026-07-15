; Highlight queries for Wax. Capture names follow the nvim-treesitter
; conventions; the groupings mirror editors/vscode/syntaxes/wax.tmLanguage.json
; so tree-sitter coloring lines up with the existing VS Code / docs highlighting.
;
; Ordering matters: consumers apply a last-match-wins rule, so the catch-all
; `(identifier) @variable` comes first and every more specific identifier
; capture comes after it.

(identifier) @variable

; ---------------------------------------------------------------------------
; Keywords
; ---------------------------------------------------------------------------
[
  "if" "else" "match" "dispatch" "do" "while" "loop"
  "return" "become" "try" "catch"
] @keyword.control

[
  "br" "br_if" "br_table"
  "br_on_null" "br_on_non_null" "br_on_cast" "br_on_cast_fail"
] @keyword.control

[
  "throw" "throw_ref" "tag"
  "cont" "cont_new" "cont_bind" "suspend"
  "resume" "resume_throw" "resume_throw_ref" "switch"
] @keyword

[
  "fn" "let" "const" "type" "rec"
  "memory" "data" "table" "elem" "import"
] @keyword

[
  "mut" "open" "shared" "pagesize" "descriptor" "describes"
] @keyword.modifier

["as" "is"] @keyword.operator

; Conditional-compilation and attribute keywords
(attribute (["if"] @keyword.directive))
(conditional_if_statement (["if"] @keyword.directive))
(conditional_else_statement (["else"] @keyword.directive))
(conditional_if_field (["if"] @keyword.directive))
(conditional_else_field (["else"] @keyword.directive))
(condition_combinator kind: _ @keyword.directive)

; ---------------------------------------------------------------------------
; Constants / special values
; ---------------------------------------------------------------------------
[(null) (nop) (unreachable) (inf) (nan)] @constant.builtin

; ---------------------------------------------------------------------------
; Literals
; ---------------------------------------------------------------------------
(integer_literal) @number
(float_literal) @number.float
(string_literal) @string
(escape_sequence) @string.escape
(char_literal) @character

(line_comment) @comment
(block_comment) @comment

; ---------------------------------------------------------------------------
; Types
; ---------------------------------------------------------------------------
(primitive_type (identifier) @type.builtin)
(type_identifier) @type

; Abstract heap types are builtins, not user types.
((type_identifier) @type.builtin
  (#any-of? @type.builtin
    "func" "nofunc" "exn" "noexn" "nocont" "extern" "noextern"
    "any" "eq" "i31" "struct" "array" "none"))

(type_definition name: (identifier) @type)

; ---------------------------------------------------------------------------
; Functions, parameters, fields, labels
; ---------------------------------------------------------------------------
(function_definition name: (identifier) @function)
(import_function name: (identifier) @function)
(call_expression function: (identifier) @function.call)
(become_statement function: (identifier) @function.call)

(parameter name: (identifier) @variable.parameter)

(field_initializer name: (identifier) @property)
(labelled_argument label: (identifier) @property)
(struct_get_expression field: (identifier) @property)
(struct_type_field name: (identifier) @property)

; Qualified intrinsic paths, e.g. `v128::i32x4`, `atomic::fence`.
(path_expression root: (identifier) @type member: (identifier) @function)

(label) @label

; Attributes
(attribute name: (identifier) @attribute)
(inner_attribute name: (identifier) @attribute)

; ---------------------------------------------------------------------------
; Operators & punctuation
; ---------------------------------------------------------------------------
[
  "+" "-" "*" "/" "/s" "/u" "%s" "%u"
  "&" "|" "^" "<<" ">>s" ">>u"
  "==" "!=" "<" "<s" "<u" ">" ">s" ">u"
  "<=" "<=s" "<=u" ">=" ">=s" ">=u"
  "+=" "-=" "*=" "/=" "/s=" "/u=" "%s=" "%u="
  "&=" "|=" "^=" "<<=" ">>s=" ">>u="
  "=" ":=" "!" "?" "->" "=>" ".." "@"
] @operator

["(" ")" "{" "}" "[" "]"] @punctuation.bracket
["," ";" ":" "::" "#" "|"] @punctuation.delimiter
