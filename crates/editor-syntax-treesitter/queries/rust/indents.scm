; Rust's indents, written for this repository (GPL-3.0-or-later): the Rust
; grammar crate ships no `indents.scm`. The rule that reads these captures is
; Lean's (lean/Editor/Indent.lean): `Indent.rule` for a row's level, and
; `Indent.openingCounts` for the level of a line opened at a position. They
; read only these five names:
;
; - `@indent.begin`: a node that indents the rows after its first, through
;   the row of its last byte. Nodes that begin on one row count once.
; - `@indent.branch`: a row whose first non-blank is where such a node
;   starts is one level out: a closing bracket.
; - `@indent.ignore`: the rows after the first of such a node keep the
;   indent they have: a multi-line string or block comment.
; - `@indent.open`: an opening bracket the tree did not close, which counts
;   its row for every row after it: code being typed, with no closing
;   bracket yet.
; - `@indent.incomplete`: a node the parser could not complete. No rule
;   reads it: a question of the captures is asked again from its start, so
;   the bare brackets it holds are seen.
;
; The first three names follow nvim-treesitter's, so a config author can
; read them; the last two are ours, and every rule is ours, not nvim's.

[
  (block) (declaration_list) (field_declaration_list) (ordered_field_declaration_list)
  (enum_variant_list) (field_initializer_list) (match_block) (use_list)
  (parameters) (arguments) (type_parameters) (type_arguments) (closure_parameters)
  (tuple_expression) (tuple_pattern) (tuple_type) (array_expression) (token_tree)
  (where_clause) (let_declaration) (assignment_expression) (compound_assignment_expr)
  (field_expression) (binary_expression) (match_arm) (struct_pattern)
] @indent.begin

[ "}" ")" "]" ] @indent.branch

; A `>` is a branch only as a generic list's closing angle bracket, never as
; a comparison that leads a row (`    > b`), which keeps its continuation's
; level.
(type_arguments ">" @indent.branch)
(type_parameters ">" @indent.branch)

[ (string_literal) (raw_string_literal) (block_comment) ] @indent.ignore

; An opening bracket the tree did not close: a bare one directly in an ERROR,
; or one whose partner is MISSING. A row after it is one level in.
(ERROR [ "{" "(" "[" ] @indent.open)
(_ "{" @indent.open (MISSING "}"))
(_ "(" @indent.open (MISSING ")"))
(_ "[" @indent.open (MISSING "]"))

; A node the parser could not complete. A question of the captures is asked
; again from its start, so the bare brackets it holds are seen. No rule reads
; it.
(ERROR) @indent.incomplete
(_ (MISSING)) @indent.incomplete
