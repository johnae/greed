; From tree-sitter-toml (MIT), with Kern's capture names.

; Properties
;-----------

; Table names are types, keys in a pair are members.
(table (bare_key) @type)
(table (dotted_key (bare_key) @type))
(table_array_element (bare_key) @type)
(table_array_element (dotted_key (bare_key) @type))

(pair (bare_key) @variable.other.member)
(pair (dotted_key (bare_key) @variable.other.member))

(quoted_key) @string

; Literals
;---------

(boolean) @constant.builtin.boolean

(comment) @comment

(string) @string

[
  (integer)
  (float)
] @constant.numeric

[
  (offset_date_time)
  (local_date_time)
  (local_date)
  (local_time)
] @string.special

; Punctuation
;------------

[
  "."
  ","
] @punctuation.delimiter

"=" @operator

[
  "["
  "]"
  "[["
  "]]"
  "{"
  "}"
] @punctuation.bracket
