; From tree-sitter-luau (MIT), with Greed's capture names.

; Preproc
(hash_bang_line) @keyword.directive

; Keywords
"return" @keyword.control.return

[
  "local"
  "type"
  "export"
] @keyword

(do_statement
  [
    "do"
    "end"
  ] @keyword)

(while_statement
  [
    "while"
    "do"
    "end"
  ] @keyword.control.repeat)

(repeat_statement
  [
    "repeat"
    "until"
  ] @keyword.control.repeat)

[
  (break_statement)
  (continue_statement)
] @keyword.control.repeat

(if_statement
  [
    "if"
    "elseif"
    "else"
    "then"
    "end"
  ] @keyword.control.conditional)

(if_expression
  [
    "if"
    "then"
  ] @keyword.control.conditional)

(elseif_statement
  [
    "elseif"
    "then"
    "end"
  ] @keyword.control.conditional)

(elseif_clause
  [
    "elseif"
    "then"
  ] @keyword.control.conditional)

(else_statement
  [
    "else"
    "end"
  ] @keyword.control.conditional)

(else_clause
  "else" @keyword.control.conditional)

(for_statement
  [
    "for"
    "do"
    "end"
  ] @keyword.control.repeat)

(function_declaration
  [
    "function"
    "end"
  ] @keyword.function)

(function_definition
  [
    "function"
    "end"
  ] @keyword.function)

; Operators
[
  "and"
  "not"
  "or"
  "in"
  "typeof"
] @keyword.operator

[
  "+"
  "-"
  "*"
  "/"
  "%"
  "^"
  "#"
  "=="
  "~="
  "<="
  ">="
  "<"
  ">"
  "="
  "&"
  "|"
  "?"
  "//"
  ".."
  "+="
  "-="
  "*="
  "/="
  "%="
  "^="
  "..="
  "//="
] @operator

; Types: built-in ones, and names that start with a capital. (Matching
; identifiers inside `(type ...)` catches every identifier with this grammar.)
(builtin_type) @type.builtin

((identifier) @type
  (#match? @type "^[A-Z]"))

; Typedefs
(type_definition
  "type"
  .
  (type) @type
  "=")

; Constants
((identifier) @constant
  (#match? @constant "^[A-Z][A-Z_0-9]+$"))

; Builtins
((identifier) @constant.builtin
  (#eq? @constant.builtin "_VERSION"))

((identifier) @variable.builtin
  (#eq? @variable.builtin "self"))

"..." @variable.builtin

((identifier) @namespace
  (#any-of? @namespace "_G" "debug" "io" "jit" "math" "os" "package" "string" "table" "utf8"))

((identifier) @keyword.control
  (#eq? @keyword.control "coroutine"))

; Tables
(field
  name: (identifier) @variable.other.member)

(dot_index_expression
  field: (identifier) @variable.other.member)

(object_type
  (identifier) @variable.other.member)

(table_constructor
  [
    "{"
    "}"
  ] @constructor)

; Functions
(parameter
  .
  (identifier) @variable.parameter)

(function_type
  (identifier) @variable.parameter)

(function_call
  name: (identifier) @function)

(function_declaration
  name: (identifier) @function)

(function_call
  name:
    (dot_index_expression
      field: (identifier) @function))

(function_declaration
  name:
    (dot_index_expression
      field: (identifier) @function))

(method_index_expression
  method: (identifier) @function.method)

(function_call
  (identifier) @function.builtin
  ; format-ignore
  (#any-of? @function.builtin
    ; built-in functions in Lua 5.1
    "assert" "collectgarbage" "dofile" "error" "getfenv" "getmetatable" "ipairs"
    "load" "loadfile" "loadstring" "module" "next" "pairs" "pcall" "print"
    "rawequal" "rawget" "rawlen" "rawset" "require" "select" "setfenv" "setmetatable"
    "tonumber" "tostring" "type" "unpack" "xpcall" "typeof"
    "__add" "__band" "__bnot" "__bor" "__bxor" "__call" "__concat" "__div" "__eq" "__gc"
    "__idiv" "__index" "__le" "__len" "__lt" "__metatable" "__mod" "__mul" "__name" "__newindex"
    "__pairs" "__pow" "__shl" "__shr" "__sub" "__tostring" "__unm"))

; Literals
(number) @constant.numeric

(string) @string

(nil) @constant.builtin

(vararg_expression) @variable.builtin

[
  (false)
  (true)
] @constant.builtin.boolean

; Punctuations
[
  ";"
  ":"
  "::"
  ","
  "."
  "->"
] @punctuation.delimiter

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

(variable_list
  attribute:
    (attribute
      ([
        "<"
        ">"
      ] @punctuation.bracket
        (identifier) @attribute)))

(generic_type
  [
    "<"
    ">"
  ] @punctuation.bracket)

(generic_type_list
  [
    "<"
    ">"
  ] @punctuation.bracket)

; Comments
(comment) @comment

((comment) @comment.line.documentation
  (#match? @comment.line.documentation "^[-][-][-]"))

((comment) @comment.line.documentation
  (#match? @comment.line.documentation "^[-][-](\\s?)@"))

; string.match("123", "%d+")
(function_call
  (dot_index_expression
    field: (identifier) @_method
    (#any-of? @_method "find" "format" "match" "gmatch" "gsub"))
  arguments:
    (arguments
      .
      (_)
      .
      (string
        content: _ @string.regexp)))

; ("123"):match("%d+")
(function_call
  (method_index_expression
    method: (identifier) @_method
    (#any-of? @_method "find" "format" "match" "gmatch" "gsub"))
  arguments:
    (arguments
      .
      (string
        content: _ @string.regexp)))

; Any other name. Last, since the first pattern to match some text wins.
(identifier) @variable
