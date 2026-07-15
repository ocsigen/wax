; Local scopes and definitions, for reference highlighting and rename.

; Scopes
(function_definition) @local.scope
(block) @local.scope
(do_expression) @local.scope
(while_expression) @local.scope
(loop_expression) @local.scope
(if_expression) @local.scope

; Definitions
(parameter name: (identifier) @local.definition.parameter)
(let_statement pattern: (identifier) @local.definition.var)
(let_binding pattern: (identifier) @local.definition.var)
(global_definition name: (identifier) @local.definition.var)
(function_definition name: (identifier) @local.definition.function)

; References
(identifier) @local.reference
