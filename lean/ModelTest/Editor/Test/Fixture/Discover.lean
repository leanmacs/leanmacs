import Editor.Test.Fixture.Discover
import ModelTest.Check

/-!
# Model tests: `Editor/Test/Fixture/Discover.lean`

The model tests of the fixture harness's discovery, over a tree written by
hand (`handTree`), the port's fake: `fixtureDiscoverChecks`; and of the path
helpers it shares (`Editor/Test/Fixture/Fixture.lean`). The root module
`ModelTest` runs them; its module doc says what they show.
-/

namespace ModelTest

open Editor.Test.Fixture

/-- A tree written by hand: its files and its directories, every path from
the repository's root. A directory's entries are the last parts of the
paths directly under it. -/
def handTree (files directories : List String) : Tree Id where
  entries directory :=
    ((files ++ directories).filterMap fun path =>
        let parts := path.splitOn "/"
        if "/".intercalate parts.dropLast == directory then parts.getLast? else none).toArray
  isFile path := files.contains path
  isDirectory path := directories.contains path

/-- The tree of a root `t` holding the scripts at its root and in a
directory under it, the expected files and config directories beside them,
a directory holding no script and a file that is no script. -/
def discoveryTree : Tree Id :=
  handTree
    ["t/script", "t/expected", "t/keys-script", "t/keys-expected", "t/a/script", "t/a/expected",
      "t/b/run-script", "t/b/run-config/init.lean", "t/b/note.txt", "t/empty/notes.txt",
      "t/deep/inner/script"]
    ["t", "t/config", "t/a", "t/a/config", "t/b", "t/b/run-config", "t/empty", "t/deep",
      "t/deep/inner"]

/-- The checks of discovery and of its path helpers, each over a tree
written by hand. -/
def fixtureDiscoverChecks : List Check :=
  [{  name :=
        "discovery finds script and <x>-script at the root and in a directory directly under it, in the order of their paths, and nothing deeper or that is no script"
      run := do
        let found := Id.run (discover discoveryTree "t")
        return (found.toOption.map (·.map (·.script))) ==
            some #["t/a/script", "t/b/run-script", "t/keys-script", "t/script"] },
    { name :=
        "a fixture's expected file is expected or <x>-expected beside it, when it is there, and its config the first of <x>-config, config beside it and the root's config"
      run := do
        let found := Id.run (discover discoveryTree "t/")
        return found.toOption ==
            some
              #[{ script := "t/a/script", config := "t/a/config", expected := some "t/a/expected" },
                { script := "t/b/run-script", config := "t/b/run-config", expected := none },
                { script := "t/keys-script", config := "t/config", expected := some "t/keys-expected" },
                { script := "t/script", config := "t/config", expected := some "t/expected" }] },
    { name := "a fixture with no config directory anywhere it is looked for is refused, naming its script"
      run := do
        let found := Id.run (discover (handTree ["u/script"] ["u"]) "u")
        return match found with
          | .error reason => reason.startsWith "u/script: no config directory"
          | .ok _ => false },
    { name := "a root that holds nothing discovers no fixture"
      run := return (Id.run (discover (handTree [] ["v"]) "v")).toOption == some #[] },
    { name :=
        "a script's name gives its parts' stem: none for script, x for x-script, and no script for -script or any other name"
      run :=
        return scriptPrefix? "script" == some "" && scriptPrefix? "keys-script" == some "keys" &&
            scriptPrefix? "-script" == none && scriptPrefix? "scripts" == none &&
            partName "" "expected" == "expected" && partName "keys" "config" == "keys-config" },
    { name :=
        "a path is named from the repository's root when it is under it, a trailing slash dropped, and is under a root that is it or a directory above it"
      run :=
        return underRepository "/r/" "/r/tests/headless/" == "tests/headless" &&
            underRepository "/r" "/rx/tests" == "/rx/tests" &&
            underRepository "/r" "tests" == "tests" && isUnder "tests/headless" "tests/headless/x/script" &&
            isUnder "tests/headless/" "tests/headless" && !isUnder "tests/head" "tests/headless/script" }]

end ModelTest
