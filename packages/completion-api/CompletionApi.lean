/-!
# The interface package `completion-api`

The interface package of the completion styles and displays that ship
(`docs/design/extension-points.md`, "Three layers"): the contract between
the default package `completion`, which implements it, and whatever
reaches one of its styles by name. A name another package reaches is part
of the contract a replacement must keep, so it is declared here, in the
interface package, and a reacher names the constant, never the text
("Reaches by name"). The one reached name is the path style's: the core's
`files` package gives the file prompt's category the style `path`
(`useStyleFor Completion.Paths.category "path"`, the core's
`lean/Editor/Files/Compiled.lean`), and the core cannot import a package,
so it names the name as text. It registers no behaviour.

Its test library publishes a fake (`CompletionApiTest.fake`) and the
contract check every implementation runs (`CompletionApiTest.contractChecks`).
-/

namespace CompletionApi

/-- The name the path style is registered under: the style that matches a
path by its last component, which the file prompt's category is given. -/
def pathStyleName : String :=
  "path"

/-- Every name this interface declares: the names an implementation must
register a style under, which the contract check holds it to. -/
def names : Array String :=
  #[pathStyleName]

end CompletionApi
