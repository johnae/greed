(function_definition body: (_) @function.inside) @function.around
(lambda body: (_) @function.inside) @function.around
(class_definition body: (_) @type.inside) @type.around
(parameters (_) @parameter.around)
(lambda_parameters (_) @parameter.around)
(argument_list (_) @parameter.around)
(comment) @comment.around
((function_definition name: (identifier) @_name (#match? @_name "^test") body: (_) @test.inside) @test.around)
(pair) @entry.around
