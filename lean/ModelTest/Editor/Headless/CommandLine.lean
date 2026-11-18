import Editor.Headless.CommandLine
import ModelTest.Check

/-!
# Model tests: `Editor/Headless/CommandLine.lean`

The model tests of `Editor/Headless/CommandLine.lean`:
`headlessCommandLineChecks`. The root module `ModelTest` runs them; its module
doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the headless mode's command line
(`Editor/Headless/CommandLine.lean`): four paths anywhere, two in a bundle,
and what is refused. -/
def headlessCommandLineChecks : List Check :=
  let installed := "/Applications/Leanmacs.app/Contents/MacOS/editor"
  let outside := "/opt/leanmacs/bin/editor"
  let read (appPath : String) (arguments : List String) : Option Headless.Arguments :=
    (Headless.read appPath arguments).toOption
  let refusal (appPath : String) (arguments : List String) : Option String :=
    match Headless.read appPath arguments with
    | .error reason => some reason
    | .ok _ => none
  -- Refused with the empty reason: the usage line alone says why.
  let refused (appPath : String) (arguments : List String) : Bool :=
    refusal appPath arguments == some ""
  let explicit (render : Bool) : Headless.Arguments :=
    { render, sysroot := "/s", oleans := "/o", config := "/c", script := "/t" }
  let bundled (render : Bool) : Headless.Arguments :=
    { render, sysroot := "/Applications/Leanmacs.app/Contents/Resources/lean/toolchain"
      oleans := "/Applications/Leanmacs.app/Contents/Resources/lean/editor", config := "/c"
      script := "/t" }
  [{  name :=
        "four paths are the toolchain, the .olean directory, the config directory and the script, wherever the executable is"
      run :=
        pure
          (read outside ["/s", "/o", "/c", "/t"] == some (explicit false) &&
            read installed ["/s", "/o", "/c", "/t"] == some (explicit false)) },
    { name :=
        "two paths are the config directory and the script, and an executable in a bundle imports from the bundle's two directories"
      run := pure (read installed ["/c", "/t"] == some (bundled false)) },
    { name := "two paths outside a bundle are refused, because there is no toolchain, and say so"
      run :=
        pure
          (refusal outside ["/c", "/t"] == some Headless.noToolchain &&
            refusal outside ["--render", "/c", "/t"] == some Headless.noToolchain) },
    { name := "--render is read before two paths and before four"
      run :=
        pure
          (read installed ["--render", "/c", "/t"] == some (bundled true) &&
            read outside ["--render", "/s", "/o", "/c", "/t"] == some (explicit true)) },
    { name :=
        "no path, one, three and five, and an option it does not know, are refused with no reason beyond the usage line, inside a bundle and outside one"
      run :=
        pure
          ([installed, outside].all fun appPath =>
            refused appPath [] && refused appPath ["/c"] && refused appPath ["/o", "/c", "/t"] &&
              refused appPath ["/x", "/s", "/o", "/c", "/t"] &&
              refused appPath ["--render", "/o", "/c", "/t"] &&
              refused appPath ["--bogus", "/c", "/t"] &&
              refused appPath ["--bogus", "/s", "/o", "/c"] &&
              refused appPath ["--render", "--bogus", "/c"]) }]

end ModelTest
