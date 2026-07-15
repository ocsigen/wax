; Highlight queries for Wax, using Helix's capture-name vocabulary.
; (Neovim/nvim-treesitter uses a different vocabulary — see ../highlights.scm.)
; Ordering is last-match-wins, so the catch-all `(identifier)` comes first.

(identifier) @variable

; Keywords
["if" "else" "match" "dispatch"] @keyword.control.conditional
["do" "while" "loop"] @keyword.control.repeat
["return" "become"] @keyword.control.return
["throw" "throw_ref" "try" "catch"] @keyword.control.exception
[
  "br" "br_if" "br_table"
  "br_on_null" "br_on_non_null" "br_on_cast" "br_on_cast_fail"
] @keyword.control
"import" @keyword.control.import
[
  "tag" "cont" "cont_new" "cont_bind" "suspend"
  "resume" "resume_throw" "resume_throw_ref" "switch"
] @keyword
["fn" "let" "const" "type" "rec" "memory" "data" "table" "elem"] @keyword.storage.type
["mut" "open" "shared" "pagesize" "descriptor" "describes"] @keyword.storage.modifier
["as" "is"] @keyword.operator

(attribute (["if"] @keyword.directive))
(conditional_if_statement (["if"] @keyword.directive))
(conditional_else_statement (["else"] @keyword.directive))
(conditional_if_field (["if"] @keyword.directive))
(conditional_else_field (["else"] @keyword.directive))
(condition_combinator kind: _ @keyword.directive)

; Constants / special values
[(null) (nop) (unreachable) (inf) (nan)] @constant.builtin

; Literals
(integer_literal) @constant.numeric.integer
(float_literal) @constant.numeric.float
(string_literal) @string
(escape_sequence) @constant.character.escape
(char_literal) @constant.character

(line_comment) @comment.line
(block_comment) @comment.block

; Types
(primitive_type (identifier) @type.builtin)
(type_identifier) @type
((type_identifier) @type.builtin
  (#any-of? @type.builtin
    "func" "nofunc" "exn" "noexn" "nocont" "extern" "noextern"
    "any" "eq" "i31" "struct" "array" "none"))
(type_definition name: (identifier) @type)

; Functions, parameters, fields, labels
(function_definition name: (identifier) @function)
(import_function name: (identifier) @function)
(call_expression function: (identifier) @function)
(become_statement function: (identifier) @function)
(parameter name: (identifier) @variable.parameter)
(field_initializer name: (identifier) @variable.other.member)
(struct_get_expression field: (identifier) @variable.other.member)
(struct_type_field name: (identifier) @variable.other.member)
(path_expression root: (identifier) @type member: (identifier) @function)
(label) @label
(attribute name: (identifier) @attribute)
(inner_attribute name: (identifier) @attribute)

; Operators & punctuation
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
