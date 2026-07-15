; Indentation for Helix (uses @indent / @outdent).
; Block-shaped constructs and bracketed groups indent their contents; the
; closing delimiter outdents back to the parent.

[
  (block)
  (do_expression)
  (while_expression)
  (loop_expression)
  (if_expression)
  (match_expression)
  (dispatch_expression)
  (try_table_expression)
  (try_expression)
  (struct_type)
  (struct_expression)
  (struct_default_expression)
  (array_expression)
  (parameter_list)
  (argument_list)
  (rec_type)
  (import_group)
] @indent

[
  "}"
  ")"
  "]"
] @outdent
