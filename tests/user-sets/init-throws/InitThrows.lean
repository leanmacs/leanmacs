import Editor.Api
import Editor.Package

/-!
# The fixture package `init-throws`

A package whose `initialize` throws: a set that requires it builds and
links, and the new editor fails its probe before anything is published
(tools/user-sets-check.sh, H).
-/

namespace InitThrows

/-- Never set: the `initialize` throws. -/
initialize initThrown : String ← throw (IO.userError "init-throws: initialize failed")

/-- The package `init-throws`. -/
def package : Editor.Package :=
  { name := "init-throws", setup := Editor.command "init-throws" (Editor.message initThrown) }

end InitThrows
