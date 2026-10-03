(function_expression body: (_) @function.inside) @function.around
(attrset_expression) @type.around
(rec_attrset_expression) @type.around
(let_expression) @type.around
(formals (formal) @parameter.around)
(binding_set (binding) @parameter.around)
(list_expression (_) @parameter.around)
(comment) @comment.around
(binding_set (binding) @entry.around)
