import Editor.Api
import Editor.Package

/-!
# The fixture package `broken-elab`

A package that does not elaborate: `answer` is a string where a number is
wanted, so a set that requires it fails to build with the elaborator's
`Type mismatch`, and the editor that asked keeps running
(tools/user-sets-test.sh, B).
-/

namespace BrokenElab

/-- A number that is not one. -/
def answer : Nat := "forty-two"

/-- The package `broken-elab`. -/
def package : Editor.Package :=
  { name := "broken-elab", setup := Editor.command "broken-elab" (Editor.message s!"{answer}") }

end BrokenElab
