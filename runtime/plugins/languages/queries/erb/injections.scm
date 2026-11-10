; From tree-sitter-embedded-template (MIT). HTML around the template's
; Ruby code.

((content) @injection.content
 (#set! injection.language "html")
 (#set! injection.combined))

((code) @injection.content
 (#set! injection.language "ruby")
 (#set! injection.combined))
