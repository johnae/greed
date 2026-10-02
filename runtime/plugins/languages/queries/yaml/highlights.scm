; From tree-sitter-yaml (MIT), with Kern's capture names.

(boolean_scalar) @constant.builtin.boolean

(null_scalar) @constant.builtin

[
  (integer_scalar)
  (float_scalar)
] @constant.numeric

(comment) @comment

[
  (anchor_name)
  (alias_name)
] @label

(tag) @type

[
  (yaml_directive)
  (tag_directive)
  (reserved_directive)
] @attribute

(block_mapping_pair
  key: (flow_node
    [
      (double_quote_scalar)
      (single_quote_scalar)
    ] @variable.other.member))

(block_mapping_pair
  key: (flow_node
    (plain_scalar
      (string_scalar) @variable.other.member)))

(flow_mapping
  (_
    key: (flow_node
      [
        (double_quote_scalar)
        (single_quote_scalar)
      ] @variable.other.member)))

(flow_mapping
  (_
    key: (flow_node
      (plain_scalar
        (string_scalar) @variable.other.member))))

[
  ","
  "-"
  ":"
  ">"
  "?"
  "|"
] @punctuation.delimiter

[
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

[
  "*"
  "&"
  "---"
  "..."
] @punctuation.special

; Strings that aren't keys. Last, since the first pattern to match some text
; wins.
[
  (double_quote_scalar)
  (single_quote_scalar)
  (block_scalar)
  (string_scalar)
] @string
