; Markdown's block highlights, this repository's: the block grammar crate's
; query (tree-sitter-md 0.5.4, `tree-sitter-markdown/queries/highlights.scm`,
; from nvim-treesitter, MIT) copied and changed, because the crate's captures
; every heading as `@text.title`, with no level, and gives a code block the
; name an inline code span has, `@text.literal`. Lean maps these names to the
; `text.` faces (`Highlight.defaultFaces`, lean/Editor/Highlight.lean):
;
; - `@text.heading.1` ... `@text.heading.6`: a heading's text, by its level;
;   a setext heading underlined with `=` is level 1 and with `-` level 2.
; - `@text.code-block`: a fenced or indented code block.
; - `@text.list-marker`: a list item's marker.
; - `@text.quote`: a block quote.
; - `@text.table-header`: a pipe table's header row.
;
; The other captures are the crate's. The inline grammar keeps the crate's
; query, whose `@text.literal` is a code span.

(atx_heading (atx_h1_marker) heading_content: (inline) @text.heading.1)
(atx_heading (atx_h2_marker) heading_content: (inline) @text.heading.2)
(atx_heading (atx_h3_marker) heading_content: (inline) @text.heading.3)
(atx_heading (atx_h4_marker) heading_content: (inline) @text.heading.4)
(atx_heading (atx_h5_marker) heading_content: (inline) @text.heading.5)
(atx_heading (atx_h6_marker) heading_content: (inline) @text.heading.6)

(setext_heading heading_content: (paragraph) @text.heading.1 (setext_h1_underline))
(setext_heading heading_content: (paragraph) @text.heading.2 (setext_h2_underline))

[
  (atx_h1_marker)
  (atx_h2_marker)
  (atx_h3_marker)
  (atx_h4_marker)
  (atx_h5_marker)
  (atx_h6_marker)
  (setext_h1_underline)
  (setext_h2_underline)
] @punctuation.special

(link_title) @text.literal

[
  (indented_code_block)
  (fenced_code_block)
] @text.code-block

(fenced_code_block_delimiter) @punctuation.delimiter

(code_fence_content) @none

(link_destination) @text.uri

(link_label) @text.reference

[
  (list_marker_plus)
  (list_marker_minus)
  (list_marker_star)
  (list_marker_dot)
  (list_marker_parenthesis)
] @text.list-marker

(thematic_break) @punctuation.special

(block_quote) @text.quote

[
  (block_continuation)
  (block_quote_marker)
] @punctuation.special

(pipe_table_header) @text.table-header

(backslash_escape) @string.escape
