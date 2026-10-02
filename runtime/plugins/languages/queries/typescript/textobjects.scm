(function_declaration body: (_) @function.inside) @function.around
(function_expression body: (_) @function.inside) @function.around
(arrow_function body: (_) @function.inside) @function.around
(method_definition body: (_) @function.inside) @function.around
(generator_function_declaration body: (_) @function.inside) @function.around
(class_declaration body: (_) @type.inside) @type.around
(class body: (_) @type.inside) @type.around
(formal_parameters (_) @parameter.around)
(arguments (_) @parameter.around)
(comment) @comment.around
(interface_declaration body: (_) @type.inside) @type.around
(type_alias_declaration) @type.around
(enum_declaration body: (_) @type.inside) @type.around
(type_arguments (_) @parameter.around)
(type_parameters (_) @parameter.around)
