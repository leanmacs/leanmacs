import ContractTest.Check
import ContractTest.Support.Syntax
import Editor.Markdown.Cases
import Editor.SyntaxTree

/-!
# Contract tests: `Editor/Markdown/Cases.lean`

The tests of `Editor/Markdown/Cases.lean`: `markdownCaseChecks`, the real
syntax tree binding held to answer each Markdown fixture under
`tests/markdown/` exactly its canned layers. The root module
`ContractTest` runs them; its module doc says what each shows.

The fixture list is read here with `include_str`, at build time, so nothing
is read from the working directory; it has one user in this executable, so
it stays in this module (AGENTS.md). Lake rebuilds this module when a
fixture changes.
-/

namespace ContractTest

open Editor
open Editor.Markdown

/-- Each Markdown fixture's name, text and layers file, as checked in. -/
def markdownFixtureFiles : List (String × String × String) :=
  [("prose", include_str "../../../../tests/markdown/prose.md",
      include_str "../../../../tests/markdown/prose.layers.json"),
    ("headings", include_str "../../../../tests/markdown/headings.md",
      include_str "../../../../tests/markdown/headings.layers.json"),
    ("code", include_str "../../../../tests/markdown/code.md",
      include_str "../../../../tests/markdown/code.layers.json"),
    ("table", include_str "../../../../tests/markdown/table.md",
      include_str "../../../../tests/markdown/table.layers.json"),
    ("links", include_str "../../../../tests/markdown/links.md",
      include_str "../../../../tests/markdown/links.layers.json"),
    ("folds", include_str "../../../../tests/markdown/folds.md",
      include_str "../../../../tests/markdown/folds.layers.json"),
    ("lists", include_str "../../../../tests/markdown/lists.md",
      include_str "../../../../tests/markdown/lists.layers.json"),
    ("stream", include_str "../../../../tests/markdown/stream.md",
      include_str "../../../../tests/markdown/stream.layers.json"),
    ("stream-head", include_str "../../../../tests/markdown/stream-head.md",
      include_str "../../../../tests/markdown/stream-head.layers.json"),
    ("stream-tail-1", include_str "../../../../tests/markdown/stream-tail-1.md",
      include_str "../../../../tests/markdown/stream-tail-1.layers.json"),
    ("stream-tail-2", include_str "../../../../tests/markdown/stream-tail-2.md",
      include_str "../../../../tests/markdown/stream-tail-2.layers.json"),
    ("stream-tail-3", include_str "../../../../tests/markdown/stream-tail-3.md",
      include_str "../../../../tests/markdown/stream-tail-3.layers.json")]

/-- One check a fixture: the real binding answers its text parsed once
exactly its canned layers. When it does not, the library's answer is
printed as a layers file, for a person to read before checking it in
(`tests/markdown/README.md`). -/
def markdownCaseChecks : List Check :=
  markdownFixtureFiles.map fun (name, source, layersFile) =>
    { name := s!"the library answers tests/markdown/{name}.md parsed once exactly its canned layers"
      run := do
        let .ok layers := Cases.decode layersFile
          | throw (IO.userError s!"tests/markdown/{name}.layers.json is not a layers file")
        let (_, _, _, handler) ← syntaxTreeOver #[]
        match ← (Markdown.parse Cases.grammars source).runWith handler with
        | .ok answered =>
          if answered == layers then
            return true
          IO.println
              s!"contract-test: the library's layers of tests/markdown/{name}.md:\n{Cases.encode answered}contract-test: end of {name}"
          return false
        | .error refusal =>
          throw
              (IO.userError s!"the library refused tests/markdown/{name}.md: {refusal.describe}") }

end ContractTest
