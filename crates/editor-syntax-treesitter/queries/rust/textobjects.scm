; Rust's text objects, written for this repository (GPL-3.0-or-later): the
; Rust grammar crate ships no `textobjects.scm`. The rule that reads these
; captures is Lean's `TreeObjects.choose` (lean/Editor/Evil/TreeObjects.lean),
; and it reads only these five names:
;
; - `@function.outer`, `@class.outer`: the node a function or a class
;   object covers (`a f`, `a c`);
; - `@function.inner`, `@class.inner`: within such a node, what the inner
;   object covers (`i f`, `i c`), the longest one;
; - `@parameter.inner`: an argument (`i a`; `a a` adds its separator).
;
; The names follow nvim-treesitter-textobjects', so a config author can read
; them; the rule is ours, not nvim's.

(function_item body: (_) @function.inner) @function.outer
(function_signature_item) @function.outer
(closure_expression body: (_) @function.inner) @function.outer

(struct_item body: (_) @class.inner) @class.outer
(struct_item) @class.outer
(enum_item body: (_) @class.inner) @class.outer
(union_item body: (_) @class.inner) @class.outer
(trait_item body: (_) @class.inner) @class.outer
(impl_item body: (_) @class.inner) @class.outer
(mod_item body: (_) @class.inner) @class.outer

(parameters (_) @parameter.inner)
(closure_parameters (_) @parameter.inner)
(type_parameters (_) @parameter.inner)
(arguments (_) @parameter.inner)
(type_arguments (_) @parameter.inner)
(tuple_expression (_) @parameter.inner)
(tuple_pattern (_) @parameter.inner)
(array_expression (_) @parameter.inner)
