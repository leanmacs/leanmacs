import Editor.SyntaxTree

/-!
# A Markdown text parsed once

What a rendered view of Markdown asks of the syntax tree port: the layers
of a Markdown text parsed once (`SyntaxTree.parseOnce`), with the block
grammar `markdown` as the host.

- **The kinds** (`kindsOf`): `markdown` and `markdown_inline` answered
  with their `rendered` queries, whose captures are the renderer's
  vocabulary (`Editor/Markdown/Parsed.lean`); then each other grammar
  named, once, with its `highlights`, so a fence in that grammar's
  language is a layer drawn in its captures' faces.
- **The parse** (`parse`) is that one request. It takes grammar names,
  not languages, so this module imports only the port.

## Where an addition goes

| Addition | Where |
|---|---|
| Another kind of query a layer is answered with | `kindsOf`, and the renderer that reads it |

Pinned by `ModelTest.markdownCaseChecks` (the model answers each fixture's
canned layers for these kinds) and `ContractTest.markdownCaseChecks` (the
library answers each fixture exactly its canned layers).
-/

namespace Editor.Markdown

/-- The pairs a Markdown text is parsed once with: `markdown` and
`markdown_inline` with `rendered`, then each other name of `grammars`, once
each, in order, with `highlights`. -/
def kindsOf (grammars : List String) : Array (String × QueryKind) :=
  let others :=
    grammars.foldl
      (fun kept name =>
        if name == "markdown" || name == "markdown_inline" || kept.contains name then kept
        else kept.push name)
      #[]
  #[("markdown", .rendered), ("markdown_inline", .rendered)] ++
    others.map fun name => (name, QueryKind.highlights)

/-- The layers of `source`, a Markdown text, parsed once with the block
grammar and the pairs of `grammars` (`kindsOf`): the host first, then its
inline and code layers, by depth and start. -/
def parse (grammars : List String) (source : String) : SyntaxTreeM (Array SyntaxTree.Layer) :=
  SyntaxTree.parseOnce source "markdown" (kindsOf grammars)

end Editor.Markdown
