(function_definition body: (_) @function.inside) @function.around
(struct_specifier body: (_) @type.inside) @type.around
(enum_specifier body: (_) @type.inside) @type.around
(union_specifier body: (_) @type.inside) @type.around
(parameter_list (_) @parameter.around)
(argument_list (_) @parameter.around)
(comment) @comment.around
