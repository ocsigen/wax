; Structural text objects for Helix (uses .inside / .around).

(function_definition) @function.around
(function_definition body: (block) @function.inside)

(type_definition) @class.around
(type_definition body: (_) @class.inside)

(parameter) @parameter.inside
(parameter) @parameter.around

[
  (line_comment)
  (block_comment)
] @comment.around
