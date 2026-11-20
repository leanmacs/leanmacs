import ContractTest.Check
import Editor.Completion.Filtering
import Editor.Ffi.Processes
import Editor.Job
import Editor.Job.Runner
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Services
import Editor.Test.Linked.Trees

/-!
# Contract tests: `Editor/Completion/Filtering.lean`

The tests of `Editor/Completion/Filtering.lean`: `filteringChecks`, a source
a command filters over the real process service, with the fixture that
stands for fzf (`tests/completion/filter`). The root module `ContractTest`
runs them; its module doc says what each shows.
-/

namespace ContractTest

open Editor
open Editor.Test.Linked

/-- The text the metacharacter check types: shell metacharacters and quotes,
which a shell would run. -/
def typedMetacharacters : String :=
  "a; $(touch pwned) | 'b' \"c\""

/-- The filtering of the checks in `base`: `/bin/cat` of the file `list`
there as the lister, and the fixture filter under `fixtures` given
`arguments` before the text. -/
def fixtureFiltering (fixtures base : System.FilePath) (arguments : Array String := #["--filter"]) :
    Completion.Filtering :=
  { lister := { program := "/bin/cat", arguments := #["list"], directory := base }
    filter := { program := (fixtures / "filter").toString, arguments, directory := base } }

/-- Whether what `filtering.found text` answers over `services`, run as a
job, the error on the left and the records on the right, is as `expected`
says, and every child it ran was reaped. -/
def foundThrough (services : Job.Services) (filtering : Completion.Filtering) (text : String)
    (expected : String ⊕ Array String → Bool) : IO Bool := do
  let before ← Ffi.processesPending
  let outcome ←
    runOnTimers services do
        match ← filtering.found text with
        | .ok records =>
          return expected (.inr records)
        | .error message =>
          return expected (.inl message)
  let reaped ← Editor.Test.Linked.childrenReapedTo services before
  return outcome == .finished true && reaped

/-- What a source a command filters shows over the real process service,
with the fixture under `fixtures` (`tests/completion`) standing for fzf.
Each check works in a temporary directory of its own, which it removes, and
none sets a variable of the test process or changes its working
directory. -/
def filteringChecks (services : Job.Services) (fixtures : System.FilePath) : List Check :=
  [{  name :=
        "over the real process service, a text with shell metacharacters and quotes reaches the fixture filter as one literal argument: it answers the one record that holds it, as it does with NUL-separated records, and no command in it ran"
      run :=
        withBase fun base => do
          writeMaking (base / "list") s!"plain\nx{typedMetacharacters}y\nother\n"
          writeMaking (base / "list0") s!"plain\x00x{typedMetacharacters}y\x00other\x00"
          let one : String ⊕ Array String → Bool := (· == .inr #[s!"x{typedMetacharacters}y"])
          let lines ← foundThrough services (fixtureFiltering fixtures base) typedMetacharacters one
          let nul : Completion.Filtering :=
            { fixtureFiltering fixtures base
                #["--read0", "--print0",
                  "--filter"] with
              lister := { program := "/bin/cat", arguments := #["list0"], directory := base }
              separator := .nul }
          let nuls ← foundThrough services nul typedMetacharacters one
          let ran ← (base / "pwned").pathExists
          return lines && nuls && !ran },
    { name :=
        "over the real process service, the fixture filter fails a text split into two arguments, so the check above would have seen a split"
      run :=
        withBase fun base => do
          writeMaking (base / "list") "a b\n"
          let split := fixtureFiltering fixtures base #["--filter", "a"]
          foundThrough services split "b"
              (· ==
                .inl
                  s!"{fixtures / "filter"}: exited with status 2: filter: unknown argument: --filter") },
    { name :=
        "over the real process service, the empty text with a small byte limit over 10,000 records answers the whole records of the filter's head, a prefix of the list, with no time-out, and the filter is ended and reaped"
      run :=
        withBase fun base => do
          let records := (Array.range 10000).map (s!"record-{·}")
          writeMaking (base / "list") (String.join (records.toList.map (· ++ "\n")))
          let filtering := { fixtureFiltering fixtures base with filterBytes := 1000 }
          foundThrough services filtering "" fun
              | .inr found =>
                found.size > 0 && found.size < records.size && found == records.extract 0 found.size
              | .inl _ => false },
    { name := "over the real process service, a filter that is not there fails, naming the program"
      run :=
        withBase fun base => do
          writeMaking (base / "list") "a\n"
          let missing :=
            { fixtureFiltering fixtures base with
              filter := { program := "/nonexistent/editor-filter", directory := base } }
          foundThrough services missing "a" fun
              | .inl message => message.startsWith "/nonexistent/editor-filter: "
              | .inr _ => false },
    { name :=
        "over the real process service, the fixture filter's exit 1 on a text that matches nothing answers no records, which is no failure; with no status declared as no matches it fails, naming the program"
      run :=
        withBase fun base => do
          writeMaking (base / "list") "a\nb\n"
          let nothing ← foundThrough services (fixtureFiltering fixtures base) "q" (· == .inr #[])
          let strict := { fixtureFiltering fixtures base with noMatches := [] }
          let failed ←
            foundThrough services strict "q"
                (· == .inl s!"{fixtures / "filter"}: exited with status 1")
          return nothing && failed }]

end ContractTest
