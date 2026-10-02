(function_definition body: (_) @function.inside) @function.around
(lambda body: (_) @function.inside) @function.around
(class_definition body: (_) @type.inside) @type.around
(parameters (_) @parameter.around)
(lambda_parameters (_) @parameter.around)
(argument_list (_) @parameter.around)
(comment) @comment.around
