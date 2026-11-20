import Editor.Api
import Editor.Package

/-!
# The fixture package `init-throws`

A package whose `initialize` throws in an editor: a set that requires it
builds and links, and the new editor fails its probe before anything is
published
(tools/user-sets-check.sh, H).
-/

namespace InitThrows

/-- Never set in an editor: the `initialize` throws there. Lean runs it
when it compiles a module that imports this one, too, so it throws only
in a process whose executable is called `editor`, and the package builds
and links. -/
initialize initThrown : String ← do
  if (← IO.appPath).fileName == some "editor" then
    throw (IO.userError "init-throws: initialize failed")
  pure "initialize ran"

/-- The package `init-throws`. -/
def package : Editor.Package :=
  { name := "init-throws", setup := Editor.command "init-throws" (Editor.message initThrown) }

end InitThrows
