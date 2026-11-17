; Rust's indents, written for this repository (GPL-3.0-or-later): the Rust
; grammar crate ships no `indents.scm`. The rule that reads these captures is
; Lean's `Indent.rule` (lean/Editor/Indent.lean), and it reads only these
; three names:
;
; - `@indent.begin`: a node that indents the rows after its first, through
;   the row of its last byte. Nodes that begin on one row count once.
; - `@indent.branch`: a row whose first non-blank is where such a node
;   starts is one level out: a closing bracket.
; - `@indent.ignore`: the rows after the first of such a node keep the
;   indent they have: a multi-line string or block comment.
;
; The names follow nvim-treesitter's, so a config author can read them; the
; rule is ours, not nvim's.

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
