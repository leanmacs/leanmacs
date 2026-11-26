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
  [{  name := "run, compared and compare are read after the toolchain, the .olean directories and the repository"
      run :=
        let head := ["/sys", "/a:/b", "--repo", ".."]
        let invocation (command : Command) : Invocation :=
          { sysroot := "/sys", oleans := "/a:/b", repository := "..", command }
        return (read (head ++ ["run", "x", "y"])).toOption == some (invocation (.run #["x", "y"])) &&
            (read (head ++ ["compared"])).toOption == some (invocation .compared) &&
            (read (head ++ ["compare", "s", "f"])).toOption == some (invocation (.compare "s" "f")) },
    { name :=
        "a command line with nothing is the usage alone, and one with no root to run, an unknown command, no command, or no --repo says why"
      run :=
        let head := ["/sys", "/a", "--repo", ".."]
        let says (arguments : List String) : Bool :=
          match read arguments with
          | .error reason => !reason.isEmpty
          | .ok _ => false
        return (match read [] with | .error "" => true | _ => false) && says (head ++ ["run"]) && says (head ++ ["bogus"]) && says head &&
            says ["/sys", "/a", "run", "x"] && says (head ++ ["compare", "s"]) &&
            (usage.splitOn "compared").length == 2 },
    { name :=
        "real-thread, with no toolchain, directories or repository, lists the real-thread set, all of it or the entries whose site begins with --site's prefix, and nothing else is the listing"
      run :=
        return readListing ["real-thread"] == some none &&
            readListing ["real-thread", "--site", "ffi-test"] == some (some "ffi-test") &&
            readListing ["real-thread", "--site"] == none &&
            readListing ["real-thread", "ffi-test"] == none &&
            readListing ["/sys", "/a", "--repo", "..", "real-thread"] == none &&
            readListing [] == none && (usage.splitOn "real-thread [--site <prefix>]").length == 2 }]

end ModelTest
