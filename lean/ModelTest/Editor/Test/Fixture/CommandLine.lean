import Editor.Test.Fixture.CommandLine
import ModelTest.Check

/-!
# Model tests: `Editor/Test/Fixture/CommandLine.lean`

The model tests of the fixture harness's command line:
`fixtureCommandLineChecks`. The root module `ModelTest` runs them; its
module doc says what they show.
-/

namespace ModelTest

open Editor.Test.Fixture

/-- The checks of the harness's command line, each pure. -/
def fixtureCommandLineChecks : List Check :=
  [{  name := "run is read after the toolchain, the .olean directories and the repository"
      run :=
        let head := ["/sys", "/a:/b", "--repo", ".."]
        let invocation (command : Command) : Invocation :=
          { sysroot := "/sys", oleans := "/a:/b", repository := "..", command }
        return (read (head ++ ["run", "x", "y"])).toOption == some (invocation (.run #["x", "y"])) },
    { name :=
        "a command line with nothing is the usage alone, and one with no root to run, an unknown command, no command, or no --repo says why"
      run :=
        let head := ["/sys", "/a", "--repo", ".."]
        let says (arguments : List String) : Bool :=
          match read arguments with
          | .error reason => !reason.isEmpty
          | .ok _ => false
        return (match read [] with | .error "" => true | _ => false) && says (head ++ ["run"]) && says (head ++ ["bogus"]) && says head &&
            says ["/sys", "/a", "run", "x"] && says (head ++ ["compared"]) &&
            (usage.splitOn "run <root>...").length == 2 }]

end ModelTest
