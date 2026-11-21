import CompletionApi
import Editor.Completion.Style
import Editor.Package

/-!
# The fake of `completion-api`

A package that registers a completion style under every name the
interface declares, each the style interface's pure model
(`Completion.Style.keeping`), which keeps every candidate in its order. A consumer's tests use it in place of any implementation, so they
import no implementation package.
-/

namespace CompletionApiTest

/-- The fake: a package named `completion-fake` that registers, under each
of `CompletionApi.names`, the model style that keeps every candidate. -/
def fake : Editor.Package :=
  { name := "completion-fake"
    setup :=
      for name in CompletionApi.names do
        Editor.defineStyle (Editor.Completion.Style.keeping name fun _ _ => true) }

end CompletionApiTest
