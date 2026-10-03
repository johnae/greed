(function_declaration body: (_) @function.inside) @function.around
(method_declaration body: (_) @function.inside) @function.around
(func_literal body: (_) @function.inside) @function.around
(type_declaration) @type.around
(parameter_list (_) @parameter.around)
(argument_list (_) @parameter.around)
(comment) @comment.around
((function_declaration name: (identifier) @_name (#match? @_name "^(Test|Benchmark|Example|Fuzz)") body: (_) @test.inside) @test.around)
(keyed_element) @entry.around
