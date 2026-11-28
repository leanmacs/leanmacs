; Markdown's inline highlights, this repository's: the inline grammar crate's
; query (tree-sitter-md 0.5.4, `tree-sitter-markdown-inline/queries/highlights.scm`,
; from nvim-treesitter, MIT) copied and changed, because the crate's captures
; a link's title as `@text.literal`, the name it gives a code span, so a
; link's title would be drawn as code (`text.code-span`). Lean maps these
; names to the `text.` faces (`Highlight.defaultFaces`,
; lean/Editor/Highlight.lean):
;
; - `@text.literal`: a code span, and nothing else.
; - `@text.reference`: a link's title, beside its text, label and an image's
;   description, drawn as a link.
;
; The other captures are the crate's.

(code_span) @text.literal

[
  (emphasis_delimiter)
  (code_span_delimiter)
] @punctuation.delimiter

(emphasis) @text.emphasis

(strong_emphasis) @text.strong

[
  (link_destination)
  (uri_autolink)
] @text.uri

[
  (link_label)
  (link_text)
  (link_title)
  (image_description)
] @text.reference

[
  (backslash_escape)
  (hard_line_break)
] @string.escape

(image
  [
    "!"
    "["
    "]"
    "("
    ")"
  ] @punctuation.delimiter)

(inline_link
  [
    "["
    "]"
    "("
    ")"
  ] @punctuation.delimiter)

(shortcut_link
  [
    "["
    "]"
  ] @punctuation.delimiter)

; NOTE: extension not enabled by default
; (wiki_link ["[" "|" "]"] @punctuation.delimiter)
