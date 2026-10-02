(function_declaration body: (_) @function.inside) @function.around
(method_declaration body: (_) @function.inside) @function.around
(func_literal body: (_) @function.inside) @function.around
(type_declaration) @type.around
(parameter_list (_) @parameter.around)
(argument_list (_) @parameter.around)
(comment) @comment.around
