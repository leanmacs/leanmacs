import Editor.Mode.SyntaxTree
import Editor.SyntaxTree

/-!
# A Markdown text parsed once

What a rendered view of Markdown asks of the syntax tree port: the layers
of a Markdown text parsed once (`SyntaxTree.parseOnce`), with the block
grammar `markdown` as the host.

- **The languages** (`languagesOf`) are made from the trees a rendered view
  is handed (`RegistryRequest.languageTrees`), each with the queries read
  from its grammar's declared files, since the library ships none:
  `markdown` and `markdown_inline` answered with their `rendered` queries,
  whose captures are the renderer's vocabulary
  (`Editor/Markdown/Parsed.lean`); `markdown`'s injections are its
  `injections` and then its `renderedInjections` (which make each table
  cell an inline layer too), joined by a line, and `markdown_inline`'s its
  `injections`; then each other grammar, once, with its `highlights` and
  `injections`, so a fence in that grammar's language is a layer drawn in
  its captures' faces. A tree with no query of the kind it needs is left
  out, and the port refuses a parse whose host has none (`noQuery`).
- **The parse** (`parse`) is that one request. It takes trees, plain data
  (`Editor/Mode/SyntaxTree.lean`), not languages, so this module imports
  only the port and that.

## Where an addition goes

| Addition | Where |
|---|---|
| Another kind of query a layer is answered with | A field of `Mode.SyntaxTree`, its query file (`Language.Grammar.queryFiles`), `languagesOf`, and the renderer that reads it |

Pinned by `ModelTest.markdownParseChecks` (`languagesOf`),
`ModelTest.markdownCaseChecks` (the model answers each fixture's canned
layers) and `ContractTest.markdownCaseChecks` (the library answers each
fixture exactly its canned layers, through the test grammars' trees, whose
queries are the `languages` package's).
-/

namespace Editor.Markdown

/-- The languages a Markdown text is parsed once with, from `trees` (the
module docs): `markdown` with its `rendered` query and its `injections` and
`renderedInjections` joined by a line, `markdown_inline` with its
`rendered` query and its `injections`, then each other grammar of `trees`,
once each, in order, with its `highlights` and `injections`. The first
tree of a grammar is used, and a tree with no query of the kind it needs is
left out. -/
def languagesOf (trees : List Mode.SyntaxTree) : Array SyntaxTree.OnceLanguage :=
  let first (grammar : String) : Option Mode.SyntaxTree := trees.find? (·.grammar == grammar)
  let joined : Option String → Option String → Option String
    | some a, some b => some s!"{a}\n{b}"
    | a, b => a <|> b
  let markdown :=
    (first "markdown").bind fun tree =>
      tree.rendered.map fun query =>
        { grammar := "markdown", query,
          injections := joined tree.injections tree.renderedInjections }
  let inline :=
    (first "markdown_inline").bind fun tree =>
      tree.rendered.map fun query =>
        { grammar := "markdown_inline", query, injections := tree.injections }
  let (others, _) :=
    trees.foldl
      (fun ((kept : Array SyntaxTree.OnceLanguage), (seen : Array String)) tree =>
        if
            tree.grammar == "markdown" || tree.grammar == "markdown_inline" ||
              seen.contains tree.grammar then
          (kept, seen)
        else
          let seen := seen.push tree.grammar
          match tree.highlights with
          | some query =>
            (kept.push { grammar := tree.grammar, query, injections := tree.injections }, seen)
          | none => (kept, seen))
      (#[], #[])
  markdown.toArray ++ inline.toArray ++ others

/-- The layers of `source`, a Markdown text, parsed once with the block
grammar and the languages of `trees` (`languagesOf`): the host first, then
its inline and code layers, by depth and start. -/
def parse (trees : List Mode.SyntaxTree) (source : String) : SyntaxTreeM (Array SyntaxTree.Layer) :=
  SyntaxTree.parseOnce source "markdown" (languagesOf trees)

end Editor.Markdown
