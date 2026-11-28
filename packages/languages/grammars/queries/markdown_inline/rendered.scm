; Markdown's inline rendered query, written for this repository
; (GPL-3.0-or-later): which nodes of the inline grammar (tree-sitter-md
; 0.5.4) a rendered view reads in a paragraph's, a heading's or a table
; cell's text, and the markup it leaves out. The renderer that reads these
; captures is Lean's (lean/Editor/Markdown/Parsed.lean, which names each of
; them, and lean/Editor/Markdown/Inline.lean). Every capture below is one of
; its names:
;
; - `@emphasis`, `@strong`, `@code-span`: drawn in their faces.
; - `@hide`: markup left out: the delimiters of an emphasis, a strong
;   emphasis and a code span, and the brackets and parentheses of a link
;   and an image. A strikethrough's delimiters are kept: it is shown as its
;   source.
; - `@link` (an inline link), `@link.text`, `@link.destination`,
;   `@link.title`: a link shows its text alone.
; - `@autolink` (`<http://...>`), `@autolink.email` (`<a@b.c>`).
; - `@image`, `@image.description`: an image shows its description, linked
;   to its source (its `@link.destination`).
; - `@escape`, `@hard-break`, `@html` (an inline tag), `@reference` (the
;   three kinds of reference link), `@strike`, `@entity`.

(emphasis) @emphasis
(emphasis (emphasis_delimiter) @hide)
(strong_emphasis) @strong
(strong_emphasis (emphasis_delimiter) @hide)
(code_span) @code-span
(code_span (code_span_delimiter) @hide)

(inline_link) @link
(inline_link (link_text) @link.text)
(inline_link (link_destination) @link.destination)
(inline_link (link_title) @link.title)
(inline_link ["[" "]" "(" ")"] @hide)

(uri_autolink) @autolink
(email_autolink) @autolink.email

(image) @image
(image (image_description) @image.description)
(image (link_destination) @link.destination)
(image (link_title) @link.title)
(image ["!" "[" "]" "(" ")"] @hide)

(backslash_escape) @escape
(hard_line_break) @hard-break
(html_tag) @html
[(full_reference_link) (collapsed_reference_link) (shortcut_link)] @reference
(strikethrough) @strike
[(entity_reference) (numeric_character_reference)] @entity
