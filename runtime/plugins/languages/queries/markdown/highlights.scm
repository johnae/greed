; Markdown's blocks. The text inside them (emphasis, links, code spans) is
; markdown_inline, injected into each block.

(atx_heading (atx_h1_marker) @markup.heading.marker (inline) @markup.heading.1)
(atx_heading (atx_h2_marker) @markup.heading.marker (inline) @markup.heading.2)
(atx_heading (atx_h3_marker) @markup.heading.marker (inline) @markup.heading.3)
(atx_heading (atx_h4_marker) @markup.heading.marker (inline) @markup.heading.4)
(atx_heading (atx_h5_marker) @markup.heading.marker (inline) @markup.heading.5)
(atx_heading (atx_h6_marker) @markup.heading.marker (inline) @markup.heading.6)
(setext_heading (paragraph) @markup.heading.1 (setext_h1_underline) @markup.heading.marker)
(setext_heading (paragraph) @markup.heading.2 (setext_h2_underline) @markup.heading.marker)

[
  (list_marker_plus)
  (list_marker_minus)
  (list_marker_star)
] @markup.list.unnumbered

[
  (list_marker_dot)
  (list_marker_parenthesis)
] @markup.list.numbered

(task_list_marker_checked) @markup.list.checked
(task_list_marker_unchecked) @markup.list.unchecked

(block_quote) @markup.quote
[
  (block_quote_marker)
  (block_continuation)
] @punctuation.special

[
  (fenced_code_block)
  (indented_code_block)
] @markup.raw.block
(fenced_code_block_delimiter) @punctuation.delimiter
(info_string (language) @label)

(thematic_break) @punctuation.special

(link_destination) @markup.link.url
(link_label) @markup.link.label
(link_title) @string

(backslash_escape) @constant.character.escape
