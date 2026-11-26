import Editor.Executable
import Editor.InputScheme

/-!
# The executable's scheme refusal

A mode that runs an input scheme (`Executable.Mode.needsScheme`: the
headless mode, the window mode and the probe) is refused when the
executable's package set supplies no scheme (`SchemePackage.chosen?` of
them is none). `schemeRefusal?` decides it, as a pure function: the line
the executable says on stderr, `editor: ` and `SchemePackage.noneInstalled`,
or none when the mode runs. `Editor.Main.run` asks it before the mode reads
the rest of its command line, so that a usage error does not hide it, and
returns status 1 on a refusal.

It imports only the executable's modes and the input scheme's interface, so
`model-test` tests it (`ModelTest.executableRefusalChecks`) without
reaching the hosts that `Editor.Main` imports.
-/

namespace Editor.Executable

/-- The line an executable whose package set supplies `schemes` says on
stderr when it refuses `mode`, which runs an input scheme and finds none;
none when the mode runs. -/
def schemeRefusal? (mode : Mode) (schemes : Array SchemePackage) : Option String :=
  if mode.needsScheme && (SchemePackage.chosen? schemes).isNone then
    some s!"editor: {SchemePackage.noneInstalled}"
  else none

end Editor.Executable
