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
(`Editor/Headless/CommandLine.lean`): four paths anywhere, the `.olean`
directory among them a search path that the recorded directories follow
outside a bundle; two in a bundle; `--render` and `--generate` before them;
and what is refused. -/
def headlessCommandLineChecks : List Check :=
  let installed := "/Applications/Leanmacs.app/Contents/MacOS/editor"
  let outside := "/opt/leanmacs/bin/editor"
  let recorded := ["/w/lean/.lake/build/lib/lean", "/w/packages/themes/.lake/build/lib/lean"]
  let read (appPath : String) (arguments : List String) (recorded : List String := []) :
    Option Headless.Arguments := (Headless.read appPath arguments recorded).toOption
  let refusal (appPath : String) (arguments : List String) : Option String :=
    match Headless.read appPath arguments with
    | .error reason => some reason
    | .ok _ => none
  -- Refused with the empty reason: the usage line alone says why.
  let refused (appPath : String) (arguments : List String) : Bool :=
    refusal appPath arguments == some ""
  let explicit (render : Bool) : Headless.Arguments :=
    { render, generate := false, sysroot := "/s", oleans := ["/o"], config := "/c", script := "/t" }
  let bundled (render : Bool) : Headless.Arguments :=
    { render, generate := false
      sysroot := "/Applications/Leanmacs.app/Contents/Resources/lean/toolchain"
      oleans := ["/Applications/Leanmacs.app/Contents/Resources/lean/editor"], config := "/c"
      script := "/t" }
  [{  name :=
        "four paths are the toolchain, the .olean directory, the config directory and the script, wherever the executable is"
      run :=
        pure
          (read outside ["/s", "/o", "/c", "/t"] == some (explicit false) &&
            read installed ["/s", "/o", "/c", "/t"] == some (explicit false)) },
    { name :=
        "the .olean directory of four paths is a search path: the directories a colon joins, in order; outside a bundle the directories the build recorded for the executable follow them, and in a bundle nothing is added"
      run :=
        pure
          (read outside ["/s", "/o:/p", "/c", "/t"] ==
              some { explicit false with oleans := ["/o", "/p"] } &&
            read outside ["/s", "/o", "/c", "/t"] recorded ==
              some { explicit false with oleans := "/o" :: recorded } &&
            read installed ["/s", "/o:/p", "/c", "/t"] recorded ==
              some { explicit false with oleans := ["/o", "/p"] } &&
            read installed ["/c", "/t"] recorded == some (bundled false)) },
    { name :=
        "two paths are the config directory and the script, and an executable in a bundle imports from the bundle's two directories"
      run := pure (read installed ["/c", "/t"] == some (bundled false)) },
    { name :=
        "two paths outside a bundle are refused, because there is no toolchain, and say so, whatever the build recorded for the executable"
      run :=
        pure
          (refusal outside ["/c", "/t"] == some Headless.noToolchain &&
            refusal outside ["--render", "/c", "/t"] == some Headless.noToolchain &&
            (Headless.read outside ["/c", "/t"] recorded).toOption.isNone) },
    { name :=
        "the refusal of two paths outside a bundle says that <olean dir> is a search path, directories joined with a colon, which must cover the core and every package of the editor's set unless the build recorded them beside the executable, <executable>.oleans"
      run :=
        let says (part : String) : Bool := (Headless.noToolchain.splitOn part).length > 1
        pure
          (says "<sysroot> <olean dir>" && says "joined with `:`" &&
            says "the core's and every package's" &&
            says "<executable>.oleans") },
    { name := "--render is read before two paths and before four"
      run :=
        pure
          (read installed ["--render", "/c", "/t"] == some (bundled true) &&
            read outside ["--render", "/s", "/o", "/c", "/t"] == some (explicit true)) },
    { name :=
        "--generate is read before two paths and before four, alone, after --render and before it; without it nothing is generated"
      run :=
        pure
          (read installed ["--generate", "/c", "/t"] ==
              some { bundled false with generate := true } &&
            read outside ["--generate", "/s", "/o", "/c", "/t"] ==
              some { explicit false with generate := true } &&
            read outside ["--render", "--generate", "/s", "/o", "/c", "/t"] ==
              some { explicit true with generate := true } &&
            read installed ["--generate", "--render", "/c", "/t"] ==
              some { bundled true with generate := true } &&
            (read outside ["/s", "/o", "/c", "/t"]).map (·.generate) == some false) },
    { name :=
        "--state <dir> names the state directory, among the other options in any order; without it there is none, and with no directory after it, or twice, it is refused"
      run :=
        pure
          (read outside ["--state", "/st", "/s", "/o", "/c", "/t"] ==
              some { explicit false with state := some "/st" } &&
            read installed ["--render", "--state", "/st", "--generate", "/c", "/t"] ==
              some
                { bundled true with
                  generate := true, state := some "/st" } &&
            (read outside ["/s", "/o", "/c", "/t"]).map (·.state) == some none &&
            refused installed ["--state"] &&
            refused installed ["--state", "/a", "--state", "/b", "/c", "/t"] &&
            refused installed ["--state", "--render", "/c", "/t"]) },
    { name :=
        "--resume <k> is the count of restarts passed, read and refused as --state is, and not a number refused too; without it it is 0"
      run :=
        pure
          ((read installed ["--resume", "2", "--state", "/st", "/c", "/t"]).map (·.resume) ==
              some 2 &&
            (read installed ["/c", "/t"]).map (·.resume) == some 0 &&
            refused installed ["--resume"] &&
            refused installed ["--resume", "x", "/c", "/t"] &&
            refused installed ["--resume", "1", "--resume", "2", "/c", "/t"] &&
            refused installed ["--resume", "--render", "/c", "/t"]) },
    { name :=
        "the command line a restart hands on is this run's with --resume one more than its own, and no other --resume"
      run :=
        pure
          (Headless.handedOn ["--state", "/st", "/c", "/t"] 0 ==
              ["--resume", "1", "--state", "/st", "/c", "/t"] &&
            Headless.handedOn ["--resume", "1", "--state", "/st", "/c", "/t"] 1 ==
              ["--resume", "2", "--state", "/st", "/c", "/t"]) },
    { name := "an option given twice is refused with no reason beyond the usage line"
      run :=
        pure
          (refused installed ["--generate", "--generate", "/c", "/t"] &&
            refused installed ["--render", "--render", "/c", "/t"]) },
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
