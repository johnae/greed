-- What counts as a function, a type, a parameter and a comment in each
-- language with a grammar: tree-sitter queries capturing
-- `@<object>.around` and, optionally, `@<object>.inside`. See
-- core/syntax.luau for how they're used.

local queries: { [string]: string } = {
	rust = [[
(function_item body: (_) @function.inside) @function.around
(function_signature_item) @function.around
(closure_expression body: (_) @function.inside) @function.around
(struct_item body: (_) @type.inside) @type.around
(enum_item body: (_) @type.inside) @type.around
(union_item body: (_) @type.inside) @type.around
(trait_item body: (_) @type.inside) @type.around
(impl_item body: (_) @type.inside) @type.around
(mod_item body: (_) @type.inside) @type.around
(parameters (_) @parameter.around)
(closure_parameters (_) @parameter.around)
(arguments (_) @parameter.around)
(type_parameters (_) @parameter.around)
(type_arguments (_) @parameter.around)
(field_declaration_list (_) @parameter.around)
(line_comment) @comment.around
(block_comment) @comment.around
]],
	luau = [[
(function_declaration body: (_) @function.inside) @function.around
(function_definition body: (_) @function.inside) @function.around
(type_definition) @type.around
(table_constructor) @type.around
(parameters (_) @parameter.around)
(arguments (_) @parameter.around)
(table_constructor (field) @parameter.around)
(comment) @comment.around
]],
	json = [[
(object) @type.around
(array) @type.around
(object (pair) @parameter.around)
(array (_) @parameter.around)
]],
	toml = [[
(table) @type.around
(table_array_element) @type.around
(pair) @parameter.around
(array (_) @parameter.around)
(comment) @comment.around
]],
	markdown = [[
(section) @type.around
(list_item) @parameter.around
(fenced_code_block (code_fence_content) @function.inside) @function.around
]],
}

return queries
