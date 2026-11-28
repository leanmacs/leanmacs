import Editor.Scene

/-!
# How a mode's text is parsed and drawn

`Mode.SyntaxTree`: a grammar of the library's syntax service and the
sources of its queries, with config's mapping of capture names to faces. It
is plain data in a module of its own, importing only the scene's types
(`FaceName`), so the registry's requests (`Editor/Command/Registry.lean`,
`RegistryRequest.languageTrees`) and a Markdown text's parse
(`Editor/Markdown/Parse.lean`) can name it without importing the editor's
port, which `Editor/Mode.lean` does, as `Editor/Language/IndentUnit.lean`
is for the indent unit.

A new query a mode's text is parsed with is a field here, its file in
`Language.Grammar.queryFiles` and its case in `Queries.set` and
`Queries.over` (`Editor/Language/Grammar.lean`).
-/

namespace Editor

/-- How a mode's text is parsed and drawn: a grammar of the library's
syntax service, the highlights query's source, config's mapping of capture
names to faces (`Editor/Highlight.lean`), and the sources of its
injections, text objects and indents queries. -/
structure Mode.SyntaxTree where
  /-- The grammar the text is parsed with: `rust`, `json`. -/
  grammar : String
  /-- The source of the highlights query: a language entry's own, or the
  one read from a declared grammar's directory (`Language.Grammar.treeOf`);
  `none` for none, so the text is drawn plain (`Highlight.noHighlights`):
  the library compiles in no grammar and ships no query. -/
  highlights : Option String := none
  /-- Config's mapping of capture names to faces, over the shipped default
  (`Highlight.defaultFaces`): a capture's full name, or a first component,
  and its face, `none` for one that draws nothing (`Highlight.faceOf`). -/
  captures : List (String × Option FaceName) := []
  /-- The source of the injections query, which finds text of another
  language in the mode's text; `none` for none, as is an empty source,
  which captures nothing: either turns injections off. -/
  injections : Option String := none
  /-- The source of the text objects query (`packages/evil/Evil/TreeObjects.lean`);
  `none` for none. -/
  textObjects : Option String := none
  /-- The source of the indents query (`Editor/Indent.lean`); `none` for
  none. -/
  indents : Option String := none
  /-- The source of the rendered query, which nodes a rendered view of a
  text parsed once reads (`Editor/Markdown/Parse.lean`); `none` for none. -/
  rendered : Option String := none
  /-- The source of the rendered injections, what a text parsed once for a
  rendered view finds its layers with after `injections`
  (`Markdown.languagesOf`); `none` for none. -/
  renderedInjections : Option String := none
  deriving DecidableEq, Repr

end Editor
