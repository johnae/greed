(function_declaration body: (_) @function.inside) @function.around
(function_definition body: (_) @function.inside) @function.around
(type_definition) @type.around
(table_constructor) @type.around
(parameters (_) @parameter.around)
(arguments (_) @parameter.around)
(table_constructor (field) @parameter.around)
(comment) @comment.around
