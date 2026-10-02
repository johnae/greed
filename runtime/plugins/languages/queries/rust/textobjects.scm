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
