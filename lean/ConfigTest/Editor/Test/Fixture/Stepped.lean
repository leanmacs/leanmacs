import ConfigTest.Check
import Editor.Ffi.Events
import Editor.InputScheme.Test
import Editor.Test.Fixture.Stepped
import Editor.Test.Linked.Host

/-!
# Config tests: `Editor/Test/Fixture/Stepped.lean`

The tests of the headless fixture harness's stepped runs (`runRoots`,
`compare`): `fixtureRunChecks`. Each writes its fixtures into a temporary
directory the check owns, which is the harness's repository, and runs them
over config-test's elaborator, with the test scheme and the packages the
harness stands for (`HostContext.packages`): a script that runs a command
no package registers, whose one line is known. The root module
`ConfigTest` runs them; its module doc says what they show.
-/

namespace ConfigTest

open Editor
open Editor.Test.Fixture
open Editor.Test.Linked

/-- A script whose output is one known line, whatever the packages are. -/
def nothingScript : String :=
  "run nothing-at-all\n"

/-- What `nothingScript` prints. -/
def nothingExpected : String :=
  "run nothing-at-all: no such command\n"

/-- The harness over `repository`, with config-test's elaborator and the
context's packages, the test scheme, `setups` and the real-thread set
`entries`, its report kept in `said`. -/
def fixtureHarness (context : Context) (repository : System.FilePath) (said : IO.Ref (Array String))
    (setups : Array (String × Setup) := #[]) (entries : Array RealThread.Entry := #[]) :
    IO (Harness TestScheme.scheme) := do
  return {
      packages := context.packages, base := #[`Editor], sysroot := context.sysroot
      oleans := context.oleanDirs.map (·.toString), repository := repository.toString
      latest := ← IO.mkRef none, files := ← Config.Elaborate.ModuleFiles.temporary
      elaborator := some context.elaborator, setups, entries
      say := fun line => said.modify (·.push line) }

/-- Writes `files`, each a path under `repository` and its text, making the
directories they are in, and the config directory `tests/config` with a
root that registers nothing. -/
def writeFixtures (repository : System.FilePath) (files : List (String × String)) : IO Unit := do
  writeConfig (repository / "tests" / "config")
      [("init.lean", "def setup : SetupM Unit := pure ()\n")]
  for (path, text) in files do
    let file := repository / path
    if let some parent := file.parent then
      IO.FS.createDirAll parent
    IO.FS.writeFile file text

/-- Runs the harness over the root `tests` of fixtures written from `files`
(`writeFixtures`) in a temporary directory: its exit status and its report. -/
def runFixtures (context : Context) (files : List (String × String))
    (setups : Array (String × Setup) := #[]) (entries : Array RealThread.Entry := #[]) :
    IO (UInt32 × Array String) :=
  IO.FS.withTempDir fun repository => do
    writeFixtures repository files
    let said ← IO.mkRef #[]
    let harness ← fixtureHarness context repository said setups entries
    let status ← runRoots harness (realTree repository.toString) #["tests"]
    return (status, ← said.get)

/-- A runner entry of the script `script`. -/
def runnerEntry (script : String) : RealThread.Entry :=
  { script, covers := "the runner", site := "a check", subject := .runner, stepped := true }

/-- The checks of the harness's stepped runs. -/
def fixtureRunChecks (context : Context) : List Check :=
  [{  name :=
        "a fixture whose stepped output is its expected file passes, said with its count line, and the run leaves the fakes quiescent and the library's editor queue as it was"
      run := do
        let before ← Ffi.queued .editor
        let (status, said) ←
          runFixtures context
              [("tests/a/script", nothingScript), ("tests/a/expected", nothingExpected)]
        let after ← Ffi.queued .editor
        saw
            (status == 0 && before == after &&
              said ==
                #["fixture-test: tests/a/script: stepped, as expected",
                  "fixture-test: ran 1 fixtures stepped under tests, 0 left to the CLI"])
            s!"status={status} said={said} queued {before} then {after}" },
    { name :=
        "a fixture whose expected file is wrong fails, naming the first line that differs, and the run goes on"
      run := do
        let (status, said) ←
          runFixtures context
              [("tests/a/script", nothingScript), ("tests/a/expected", "run nothing-at-all: ok\n"),
                ("tests/b/script", nothingScript), ("tests/b/expected", nothingExpected)]
        saw
            (status == 1 &&
              said.contains
                "fixture-test: tests/a/script: its output is not its expected file: line 1 differs: expected \"run nothing-at-all: ok\", got \"run nothing-at-all: no such command\"" &&
              said.contains "fixture-test: tests/b/script: stepped, as expected")
            s!"status={status} said={said}" },
    { name :=
        "a fixture with no expected file is held by its setup's after-checks: a seeded file equal to its checked-in one passes, and one checked against another file fails, naming it"
      run := do
        let seeded (checked : String) : Array (String × Setup) :=
          #[("tests/c/script",
              .oneFile "tests/c/seed.txt" "seed.txt" #[.fileEquals "/fixture/seed.txt" checked])]
        let files :=
          [("tests/c/script", nothingScript), ("tests/c/seed.txt", "kept\n"),
            ("tests/c/other.txt", "other\n")]
        let (held, heldSaid) ← runFixtures context files (seeded "tests/c/seed.txt")
        let (changed, changedSaid) ← runFixtures context files (seeded "tests/c/other.txt")
        saw
            (held == 0 && heldSaid.contains "fixture-test: tests/c/script: stepped, as expected" &&
              changed == 1 &&
              changedSaid.contains
                "fixture-test: tests/c/script: the model's /fixture/seed.txt is not tests/c/other.txt")
            s!"held={held} {heldSaid} changed={changed} {changedSaid}" },
    { name := "a script with a placeholder no setup says what it stands for is refused, naming it"
      run := do
        let (status, said) ←
          runFixtures context
              [("tests/a/script", "run @FILE@\n"), ("tests/a/expected", nothingExpected)]
        saw
            (status == 1 &&
              said.any fun line =>
                line.startsWith
                  "fixture-test: tests/a/script: refused: tests/a/script holds @FILE@")
            s!"status={status} said={said}" },
    { name :=
        "an abort in a fixture outside the real-thread set is refused before it runs, and the run goes on, so the harness's process is never ended"
      run := do
        let (status, said) ←
          runFixtures context
              [("tests/a/script", "abort\n"), ("tests/a/expected", ""),
                ("tests/b/script", nothingScript), ("tests/b/expected", nothingExpected)]
        saw
            (status == 1 &&
              said.any
                (·.startsWith
                  "fixture-test: tests/a/script: refused: tests/a/script aborts or waits for a restart") &&
              said.contains "fixture-test: tests/b/script: stepped, as expected")
            s!"status={status} said={said}" },
    { name :=
        "a fixture whose entry leaves it to the CLI is skipped, its line naming its site and what it covers; and an entry under the root that names no fixture fails the run as stale"
      run := do
        let left : RealThread.Entry :=
          { script := "tests/a/script", covers := "a real effect", site := "a gate step"
            subject := .realEffect "a real effect", stepped := false }
        let stale : RealThread.Entry := { left with script := "tests/gone/script" }
        let files :=
          [("tests/a/script", "abort\n"), ("tests/a/expected", ""),
            ("tests/b/script", nothingScript), ("tests/b/expected", nothingExpected)]
        let (status, said) ← runFixtures context files (entries := #[left])
        let (staleStatus, staleSaid) ← runFixtures context files (entries := #[left, stale])
        saw
            (status == 0 &&
              said.contains
                "fixture-test: tests/a/script: left to the CLI (a gate step): a real effect" &&
              said.contains "fixture-test: ran 1 fixtures stepped under tests, 1 left to the CLI" &&
              staleStatus == 1 &&
              staleSaid.contains
                "fixture-test: the real-thread set names tests/gone/script, which is no fixture under tests: a stale entry")
            s!"status={status} said={said} stale={staleStatus} {staleSaid}" },
    { name := "a root that holds no fixture fails the run: nothing ran stepped there"
      run := do
        let (status, said) ← runFixtures context [("tests/notes.txt", "no fixture\n")]
        saw
            (status == 1 &&
              said ==
                #["fixture-test: tests holds no headless fixture, so nothing ran stepped there"])
            s!"status={status} said={said}" },
    { name :=
        "compare passes a runner entry whose CLI output is its stepped output and its expected file, and fails one whose CLI output differs, saying the lines each side alone has"
      run :=
        IO.FS.withTempDir fun repository => do
          writeFixtures repository
              [("tests/a/script", nothingScript), ("tests/a/expected", nothingExpected),
                ("same", nothingExpected), ("other", "run nothing-at-all: ok\nmore\n")]
          let said ← IO.mkRef #[]
          let harness ←
            fixtureHarness context repository said (entries := #[runnerEntry "tests/a/script"])
          let tree := realTree repository.toString
          let same ← compare harness tree "tests/a/script" (repository / "same").toString
          let other ← compare harness tree "tests/a/script" (repository / "other").toString
          let said ← said.get
          saw
              (same == 0 && other == 1 &&
                said.contains
                  "fixture-compare: tests/a/script: the CLI over a real loop thread and the stepped run printed the same, and it is expected" &&
                said.contains
                  "fixture-test: tests/a/script: the CLI over a real loop thread (<) and the stepped run (>) printed otherwise: < 1: run nothing-at-all: ok; < 2: more; > 1: run nothing-at-all: no such command")
              s!"same={same} other={other} said={said}" }]

end ConfigTest
