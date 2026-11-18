import Editor.Executable
import ModelTest.Check

/-!
# Model tests: `Editor/Executable.lean`

The model tests of `Editor/Executable.lean`: `executableModeChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the executable's top-level dispatch
(`Editor/Executable.lean`): which mode a command line selects. -/
def executableModeChecks : List Check :=
  [{  name := "no arguments select the window mode, with an empty command line"
      run := pure (Executable.mode [] == .window []) },
    { name := "demo selects the demonstration"
      run := pure (Executable.mode ["demo"] == .demo) },
    { name :=
        "any command line but demo, headless and window-check is the window mode's, a file or an option alike"
      run :=
        pure
          (Executable.mode ["notes.txt"] == .window ["notes.txt"] &&
            Executable.mode ["--no-ime"] == .window ["--no-ime"] &&
            Executable.mode ["demo", "x"] == .window ["demo", "x"] &&
            Executable.mode ["headless", "/c", "/t"] == .headless ["/c", "/t"] &&
            Executable.mode ["window-check", "--no-ime"] == .windowCheck ["--no-ime"]) },
    { name := "--version alone selects the version, and with anything else is the window mode's"
      run :=
        pure
          (Executable.mode ["--version"] == .version &&
            Executable.mode ["--version", "x"] == .window ["--version", "x"] &&
            Executable.mode ["x", "--version"] == .window ["x", "--version"]) }]

end ModelTest
