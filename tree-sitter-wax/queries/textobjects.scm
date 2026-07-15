; Structural text objects, for nvim-treesitter-textobjects (@function.inner, …).

(function_definition) @function.outer
(function_definition body: (block) @function.inner)

(type_definition) @class.outer
(type_definition body: (_) @class.inner)

(parameter) @parameter.inner
(parameter) @parameter.outer

(call_expression) @call.outer
(call_expression arguments: (argument_list) @call.inner)

[
  (if_expression)
  (match_expression)
  (dispatch_expression)
] @conditional.outer

[
  (while_expression)
  (loop_expression)
  (do_expression)
] @loop.outer

[
  (line_comment)
  (block_comment)
] @comment.outer
