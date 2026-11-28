; What a Markdown text parsed once finds its layers with, for a rendered
; view, written for this repository (GPL-3.0-or-later): the block grammar
; crate's own injections query (tree-sitter-md 0.5.4,
; `tree-sitter-markdown/queries/injections.scm`, MIT), which the adapter
; puts before this file's text unchanged (`rendered_injections`,
; src/lib.rs), and the one pattern below.
;
; The crate's injections hand each `(inline)` node to the inline grammar,
; but a pipe table's cell has no `(inline)` child, so its code spans,
; emphasis and links would be left as source. Here each cell is an inline
; layer too, and renders like a paragraph's text. A document's own session
; keeps the crate's query alone.

((pipe_table_cell) @injection.content
  (#set! injection.language "markdown_inline"))
