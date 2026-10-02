; From tree-sitter-json (MIT), with Kern's capture names.

(pair
  key: (_) @variable.other.member)

(string) @string

(number) @constant.numeric

[
  (null)
  (true)
  (false)
] @constant.builtin

(escape_sequence) @constant.character.escape

(comment) @comment
