import CompletionApiTest.Contract
import CompletionApiTest.Fake

/-!
# Model tests: `CompletionApi.lean`

The tests of the interface package's names, its fake and its contract
check. The test driver's root, `CompletionApiTest/Model.lean`, runs them.

The checks catch an omission as well as a rename: the names are pinned
whole (`CompletionApi.names`), and an implementation that registers the
other styles but not `path` fails the contract.
-/

namespace CompletionApiTest

open Editor

/-- Whether every check of the contract over `package` holds. -/
def keeps (package : Package) : Bool :=
  (contractChecks package).all (·.2)

/-- Whether the contract over `package` has a check that names `name` and
does not hold. -/
def failsOn (package : Package) (name : String) : Bool :=
  (contractChecks package).any fun (sentence, held) =>
    !held && (sentence.splitOn s!"`{name}`").length > 1

/-- The checks of `completion-api`, each with what must hold as a
sentence. -/
def completionApiChecks : List (String × Bool) :=
  [("the name `path` is the one the interface declares, and the only one: the name the core's files package gives the file prompt's category",
      CompletionApi.pathStyleName == "path" &&
        CompletionApi.names == #[CompletionApi.pathStyleName]),
    ("the fake keeps the contract: every check of it holds", keeps fake),
    ("a package that registers nothing fails the contract, with the check for `path` false",
      failsOn { name := "missing", setup := pure () } "path"),
    ("an implementation that registers the styles fuzzy and orderless but none named path fails the contract, with the check for `path` false",
      let lacking : Package :=
        { name := "lacking"
          setup := do
            defineStyle (Completion.Style.keeping "fuzzy" fun _ _ => true)
            defineStyle (Completion.Style.keeping "orderless" fun _ _ => true) }
      !keeps lacking && failsOn lacking "path"),
    ("a package that registers the name misspelt fails the contract",
      !keeps
          { name := "misspelt",
            setup := defineStyle (Completion.Style.keeping "paths" fun _ _ => true) }),
    ("a package that registers a command named path, and no style, fails the contract",
      !keeps { name := "command", setup := Editor.command "path" (pure ()) })]

end CompletionApiTest
