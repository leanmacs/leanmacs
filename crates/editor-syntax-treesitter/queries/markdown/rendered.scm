; Markdown's rendered query, written for this repository
; (GPL-3.0-or-later): which nodes of the block grammar (tree-sitter-md
; 0.5.4) a rendered view reads, its blocks, its spans and the markup it
; leaves out. The renderer that reads these captures is Lean's
; (lean/Editor/Markdown/Parsed.lean, which names each of them, and the
; modules beside it). Every capture below is one of its names:
;
; - `@block`: a top-level block, a child of a section that is not a
;   section (the grammar puts every block of a document in a section). A list, a block quote and a table are each one.
; - A block of each kind, wherever it is a child of a section, a list item
;   or a block quote: `@paragraph`, `@code` (a fenced
;   block), `@code.indented`, `@table`, `@list`, `@quote`, `@break`,
;   `@html`, `@definition`, and `@heading.1` ... `@heading.6` on a heading
;   by its marker or underline. A setext heading's paragraph is its
;   content, not a paragraph.
; - `@heading.content`: a heading's inline text.
; - `@inline`: a paragraph's or a heading's inline text, which the
;   inline grammar's layer renders.
; - Fenced code: `@code.language` (the info string's language) and
;   `@code.content` (its rows).
; - Tables: `@table.header`, `@table.delimiter`, `@table.row`,
;   `@table.cell`.
; - Lists: `@list.item`, `@list.bullet` (the minus, plus and star markers),
;   `@list.number` (the dot and parenthesis markers), `@task` (both task
;   markers).
; - `@hide`: markup left out: a heading's markers and underline, a fence's
;   delimiters and info string, a block quote's markers and the
;   continuation of a block inside a list or a quote.

(section
  [(paragraph) (atx_heading) (setext_heading) (fenced_code_block) (indented_code_block)
    (pipe_table) (list) (block_quote) (thematic_break) (html_block)
    (link_reference_definition)] @block)

; A block of each kind, by its parent: a section, a list item or a block
; quote.
(section
  [(paragraph) @paragraph (fenced_code_block) @code (indented_code_block) @code.indented
    (pipe_table) @table (list) @list (block_quote) @quote (thematic_break) @break
    (html_block) @html (link_reference_definition) @definition])
(list_item
  [(paragraph) @paragraph (fenced_code_block) @code (indented_code_block) @code.indented
    (pipe_table) @table (list) @list (block_quote) @quote (thematic_break) @break
    (html_block) @html (link_reference_definition) @definition])
(block_quote
  [(paragraph) @paragraph (fenced_code_block) @code (indented_code_block) @code.indented
    (pipe_table) @table (list) @list (block_quote) @quote (thematic_break) @break
    (html_block) @html (link_reference_definition) @definition])

; Headings, by level.
(atx_heading (atx_h1_marker)) @heading.1
(atx_heading (atx_h2_marker)) @heading.2
(atx_heading (atx_h3_marker)) @heading.3
(atx_heading (atx_h4_marker)) @heading.4
(atx_heading (atx_h5_marker)) @heading.5
(atx_heading (atx_h6_marker)) @heading.6
(setext_heading (setext_h1_underline)) @heading.1
(setext_heading (setext_h2_underline)) @heading.2

(atx_heading heading_content: (inline) @heading.content)
(setext_heading heading_content: (paragraph (inline) @heading.content))

(atx_heading
  [(atx_h1_marker) (atx_h2_marker) (atx_h3_marker) (atx_h4_marker) (atx_h5_marker)
    (atx_h6_marker)] @hide)
(setext_heading [(setext_h1_underline) (setext_h2_underline)] @hide)

; Inline text.
(paragraph (inline) @inline)

; Fenced and indented code.
(fenced_code_block (info_string (language) @code.language))
(fenced_code_block (code_fence_content) @code.content)
(fenced_code_block [(fenced_code_block_delimiter) (info_string)] @hide)
(code_fence_content (block_continuation) @hide)

; Tables.
(pipe_table (pipe_table_header) @table.header)
(pipe_table (pipe_table_delimiter_row) @table.delimiter)
(pipe_table (pipe_table_row) @table.row)
(pipe_table_header (pipe_table_cell) @table.cell)
(pipe_table_row (pipe_table_cell) @table.cell)

; Lists.
(list (list_item) @list.item)
(list_item [(list_marker_minus) (list_marker_plus) (list_marker_star)] @list.bullet)
(list_item [(list_marker_dot) (list_marker_parenthesis)] @list.number)
(list_item [(task_list_marker_checked) (task_list_marker_unchecked)] @task)

; Quotes and continuations.
(block_quote (block_quote_marker) @hide)
(list_item (block_continuation) @hide)
(block_quote (block_continuation) @hide)
