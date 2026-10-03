; Bash, with Greed's capture names. The first pattern to match some text
; wins, so the specific ones come first.

(comment) @comment

(function_definition name: (word) @function)
(command_name (word) @function)

(command
  argument: (word) @variable.parameter
  (#match? @variable.parameter "^--?[A-Za-z]"))

[
  "if"
  "then"
  "elif"
  "else"
  "fi"
  "case"
  "esac"
] @keyword.control.conditional

[
  "for"
  "while"
  "until"
  "do"
  "done"
  "select"
] @keyword.control.repeat

"in" @keyword.operator
"function" @keyword.function

[
  "declare"
  "export"
  "local"
  "readonly"
  "typeset"
  "unset"
] @keyword.storage

(special_variable_name) @variable.builtin
(variable_name) @variable

[
  (string)
  (raw_string)
  (ansi_c_string)
  (translated_string)
  (heredoc_body)
  (heredoc_start)
  (heredoc_end)
] @string

(regex) @string.regexp
(number) @constant.numeric
(file_descriptor) @constant.numeric

(expansion
  [
    "${"
    "}"
  ] @punctuation.special)
(simple_expansion "$" @punctuation.special)
(command_substitution
  [
    "$("
    ")"
  ] @punctuation.special)

[
  ">"
  ">>"
  "<"
  "<<"
  "&>"
  "&&"
  "||"
  "|"
  "&"
  "="
  "+="
  "=="
  "!="
  "=~"
] @operator
(test_operator) @operator

[
  "("
  ")"
  "["
  "]"
  "[["
  "]]"
  "{"
  "}"
  "(("
  "))"
] @punctuation.bracket

[
  ";"
  ";;"
] @punctuation.delimiter
