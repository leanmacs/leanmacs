import Editor.Test.Minibuffer
import MinibufferApiTest.Contract
import MinibufferApiTest.Fake

/-!
# Model tests: `MinibufferApi.lean`

The tests of the interface package's names, its fake and its contract
check. The test driver's root, `MinibufferApiTest/Model.lean`, runs them.

The checks catch an omission as well as a rename: the names are pinned
whole against the core's test kit's (`Editor.Test.Minibuffer.names`),
which the core's Vim-table tests hold the minibuffer table to, so a name
left out of either, or spelt otherwise in either, fails here; and a
package that registers every name but one, or one misspelt, or no mode of
the declared name, fails the contract.
-/

namespace MinibufferApiTest

open Editor

/-- Whether every check of the contract over `package` holds. -/
def keeps (package : Package) : Bool :=
  (contractChecks package).all (·.2)

/-- Whether the contract over `package` has a check that names `name` and
does not hold. -/
def failsOn (package : Package) (name : String) : Bool :=
  (contractChecks package).any fun (sentence, held) =>
    !held && (sentence.splitOn s!"`{name}`").length > 1

/-- A package named `name` that registers a command, saying nothing, under
each of `names`, then, when `mode` is given, a mode of that name with no
roles. -/
def registering (name : String) (names : Array String)
    (mode : Option String := some MinibufferApi.modeName) : Package :=
  { name
    setup := do
      for command in names do
        Editor.command command (pure ())
      if let some mode := mode then
        defineMode { name := mode } }

/-- The checks of `minibuffer-api`, each with what must hold as a
sentence. -/
def minibufferApiChecks : List (String × Bool) :=
  [("the command names the interface declares are the nine the core's test kit registers, in its order: the seven the Vim scheme's minibuffer table binds, the one it yields to ask and the one a source's job posts a batch as, so a name left out of either list fails",
      MinibufferApi.names == Editor.Test.Minibuffer.names &&
        MinibufferApi.names ==
          #["minibuffer-accept", "minibuffer-cancel", "minibuffer-next", "minibuffer-previous",
            "minibuffer-insert", "minibuffer-delete-backward", "minibuffer-delete-to-start",
            "minibuffer-ask", "minibuffer-candidates"]),
    ("the name of the command a source's job posts a batch as and the name of the minibuffer's mode are the core's own constants",
      MinibufferApi.candidatesName == Completion.candidatesCommand &&
        MinibufferApi.modeName == Prompt.mode),
    ("the fake keeps the contract: every check of it holds", keeps fake),
    ("the contract holds of the core's test kit's implementation, Editor.Test.Minibuffer.package, the same value as the fake",
      keeps Editor.Test.Minibuffer.package),
    ("a package that registers nothing fails the contract, with the check for each command name and for the mode's name false",
      let missing := registering "missing" #[] (mode := none)
      MinibufferApi.names.all (failsOn missing) && failsOn missing MinibufferApi.modeName),
    ("a package that registers every name but minibuffer-cancel fails the contract, with the check for `minibuffer-cancel` false and the others true",
      let lacking :=
        registering "lacking" (MinibufferApi.names.filter (· != MinibufferApi.cancelName))
      !keeps lacking && failsOn lacking MinibufferApi.cancelName &&
        (MinibufferApi.names.filter (· != MinibufferApi.cancelName)).all
          (fun name => !failsOn lacking name) &&
        !failsOn lacking MinibufferApi.modeName),
    ("a package that registers every name but one misspelt fails the contract",
      !keeps
          (registering "misspelt"
            (MinibufferApi.names.map fun name =>
              if name == MinibufferApi.askName then "minibuffer-asks" else name))),
    ("a package that registers every command name and no mode of the declared name fails the contract, with the check for the mode's name false and every command's true",
      let modeless := registering "modeless" MinibufferApi.names (mode := some "prompt")
      !keeps modeless && failsOn modeless MinibufferApi.modeName &&
        MinibufferApi.names.all fun name => !failsOn modeless name)]

end MinibufferApiTest
