import ConfigFixture
import Editor
import Editor.Config.Elaborate
import Editor.Config.Session
import Editor.Job.Real
import Editor.Job.Runner
import ExtensionFixture

/-!
# Config tests: the check

The type of one check of the config session, `Check`; the `Context` every check
is given; `failures`, which runs a list of them; `saw`, with which a check
says what it saw when it fails; their checks, `checkChecks`; `run`, which
imports the base once and runs the list it is given; and `usage`, the command
line `main` does not understand. Every test module that writes a check imports
this one (the root module `ConfigTest` describes the layout).

It imports the config base, `Editor`, and the fixtures `ConfigFixture` and
`ExtensionFixture`, which the base the checks share holds too, for the
link alone: the checks
elaborate config on that base with the real elaborator
(`Editor/Config/Elaborate.lean`, "The base"), whose import of the base at
runtime needs every module of it linked into this executable. The adapter
does not import the base itself, so the module that builds the base here
does, and `tools/core-imports-check.sh` checks it.
-/

namespace ConfigTest

open Editor

/-- One behaviour, and how to observe it. -/
structure Check where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the behaviour; `true` when it holds. -/
  run : IO Bool

/-- What every check is given. -/
structure Context where
  /-- The real elaborator, whose `base` hands back, and grows, the one base
  the checks share (`sharing`): `Editor`, `ConfigFixture` and
  `ExtensionFixture` to start with. -/
  elaborator : Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle
  /-- What `ConfigFixture.bump` returned to compiled code before the base was
  imported. -/
  bumped : Nat
  /-- The next source id no host of this process has posted under. -/
  ids : IO.Ref UInt64
  /-- The table of waits the hosts over the library's file service share,
  once the first of them has asked for it (`Context.fileWaits`); none until
  then. -/
  waits : IO.Ref (Option Job.Completions)
  /-- The Lean toolchain's directory, as the executable was handed it. -/
  sysroot : String
  /-- The directories of the `.olean` files the base was imported from, as
  the executable was handed them (`oleanDirs`). -/
  oleanDirs : List System.FilePath
  /-- The directory of the syntax fixtures (`tests/syntax`), whose Rust
  fixtures the indent checks read. -/
  syntaxFixtures : System.FilePath
  /-- The directory of the default config `mise run install` ships
  (`config/default`), which `defaultConfigChecks` read. -/
  defaultConfig : System.FilePath
  /-- How many real editor loop threads the checks' hosts have started: a
  stage's host bumps it on its loop's own thread
  (`Headless.Collaborators.loopStarted`), so `inventory` names the checks
  that ran one. -/
  realLoops : IO.Ref Nat

/-- The table of waits every host over the library's file service is staged
over, with the process's one completion pump running over it. It is made,
and the pump started on a dedicated task, the first time it is asked for,
and handed back as it is afterwards: a second pump would take the first
one's completions, so the checks of files share one table and one pump.
The executable exits explicitly, which a pump parked in its pull needs. -/
def Context.fileWaits (context : Context) : IO Job.Completions := do
  if let some completions← context.waits.get then
    return completions
  let completions ← Job.Completions.new
  discard <| IO.asTask (prio := .dedicated) (Job.pump completions)
  context.waits.set (some completions)
  return completions

/-- How a check ends that says what it saw when it fails: `true` when `holds`,
and otherwise it throws `observed`, which `failures` reports after the
check's name, as `(saw <observed>)`. -/
def saw (holds : Bool) (observed : String) : IO Bool := do
  unless holds do
    throw (IO.userError s!"saw {observed}")
  return true

/-- Runs `checks` and returns the names of those that failed. A check that
throws has failed, and its error is reported with its name. -/
def failures (checks : List Check) : IO (List String) :=
  checks.filterMapM fun check => do
    try
      return if ← check.run then none else some check.name
    catch error =>
      return some s!"{check.name} ({error})"

/-- Runs `checks` as `failures` does, and also names, sorted, the checks
during which `realLoops` moved: those that started a real editor loop
thread. -/
def inventory (realLoops : IO.Ref Nat) (checks : List Check) : IO (List String × List String) := do
  let mut failed := []
  let mut real := #[]
  for check in checks do
    let before ← realLoops.get
    failed := failed ++ (← failures [check])
    if (← realLoops.get) != before then
      real := real.push check.name
  return (failed, (real.qsort (· < ·)).toList)

/-- The checks of `failures`, `saw` and `inventory`: what a failing check
saw is printed after its name, and the inventory names the checks during
which a loop thread started. -/
def checkChecks (_ : Unit) : List Check :=
  [{  name :=
        "a check that ends with saw of what does not hold fails with what it saw after its name, and saw of what holds holds"
      run := do
        let failed ← failures [{ name := "it holds", run := saw false "x" }]
        return failed == ["it holds (saw x)"] && (← saw true "x") },
    { name := "the inventory names, sorted, only the checks during which a loop thread started"
      run := do
        let loops ← IO.mkRef 0
        let started : Check :=
          { name := "b starts"
            run := do
              loops.modify (· + 1)
              return true }
        let quiet : Check := { name := "a starts none", run := pure true }
        let also : Check :=
          { name := "a also starts"
            run := do
              loops.modify (· + 2)
              return false }
        let (failed, real) ← inventory loops [started, quiet, also]
        saw (failed == ["a also starts"] && real == ["a also starts", "b starts"])
            s!"failed {failed}, real {real}" }]

/-- The directories a directory argument of the executable names: one, or
several joined with `:`, as the editor reads its own
(`ModuleLookup.searchPath`). -/
def oleanDirs (argument : String) : List System.FilePath :=
  (ModuleLookup.searchPath argument).map System.FilePath.mk

/-- `real` with one base shared by every caller, kept in `latest`: whatever
base a caller hands in, `base` grows the one in `latest` to hold the
modules asked for, keeps it and returns it. A module of the toolchain is
then read once in the process, whichever check first imports it: a second
read of a module file about doubles its memory. A base holds at least what
was asked for, which is all the port says of it. -/
def sharing (latest : IO.Ref (Option Config.Elaborate.Base))
    (real : Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle) :
    Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle :=
  { real with
    base := fun _ modules => do
      let base ← real.base (← latest.get) modules
      latest.set (some base)
      return base }

/-- Makes the base once and runs every check: names on stderr the ones that
failed, and returns the exit status, 0 when all hold and 1 otherwise.

`sysroot` is the Lean toolchain's directory and `oleanDir` the directory
holding the package's `.olean` files, or several joined with `:`
(`oleanDirs`). With `realThreads`, it writes there the names of the checks
that ran a real editor loop thread (`inventory`), sorted, one per line. -/
def run (checks : Context → List Check) (sysroot oleanDir : String)
    (syntaxFixtures defaultConfig : System.FilePath)
    (realThreads : Option System.FilePath := none) : IO UInt8 := do
  -- Compiled code writes to the fixture's cell before the base is imported.
  let bumped ← ConfigFixture.bump
  -- The module data of the config files the checks elaborate is written in
  -- a temporary directory of this run, removed when it ends.
  IO.FS.withTempDir fun scratch => do
      let files ← Config.Elaborate.ModuleFiles.over (pure scratch)
      let elaborator :=
        sharing (← IO.mkRef none)
          (Config.Elaborate.elaborator
            { sysroot, oleanDirs := oleanDirs oleanDir,
              imports := #[`Editor, `ConfigFixture, `ExtensionFixture] }
            files)
      -- The one import of the base, made before any check runs.
      discard <| elaborator.base none #[]
      let realLoops ← IO.mkRef 0
      let context : Context :=
        { elaborator, bumped, ids := ← IO.mkRef 100, waits := ← IO.mkRef none, sysroot
          oleanDirs := oleanDirs oleanDir, syntaxFixtures, defaultConfig, realLoops }
      let checks := checks context
      let (failed, real) ← inventory realLoops checks
      if let some file := realThreads then
        IO.FS.writeFile file (String.join (real.map (· ++ "\n")))
      for name in failed do
        IO.eprintln s!"FAILED: {name}"
      unless failed.isEmpty do
        return 1
      IO.println s!"config-test: {checks.length} checks passed"
      return 0

/-- Reports a command line `main` does not understand; the exit status is 2. -/
def usage : IO UInt32 := do
  IO.eprintln
      "usage: config-test <sysroot> <olean dir> <syntax fixtures> <default config> [--real-threads <file>] | config-test lsp <sysroot> <config dir> <line> <column> | config-test bench-start <sysroot> <olean dir> <module>... | config-test bench-modules <sysroot> <olean dir> <module>... | config-test bench-reload <sysroot> <olean dir> | config-test bench-reload-directory <sysroot> <olean dir> | config-test bench-soak <sysroot> <olean dir> <count> | config-test bench-soak-modules <sysroot> <olean dir> <count> | config-test bench-jobs <sysroot> <olean dir> <samples> | config-test bench-prompt <sysroot> <olean dir> <samples> | config-test bench-workspace-files <sysroot> <olean dir> <repository> <samples>"
  return 2

end ConfigTest
