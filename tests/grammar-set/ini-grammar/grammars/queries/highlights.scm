; The INI grammar's highlights as the test package ini-grammar ships them: a
; copy of the fixture grammar's own query
; (crates/editor-syntax-fixture-ini/grammar/queries/highlights.scm), kept as a
; regular file so a staged or bundled copy never holds a link that dangles.

(section_name) @type

(key) @property

(value) @string

(comment) @comment

[
  "["
  "]"
] @punctuation.bracket

"=" @operator
