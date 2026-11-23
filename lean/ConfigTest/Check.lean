import ConfigFixture
import Editor
import Editor.Config.Elaborate
import Editor.Config.Session
import Editor.Job.Runner
import Editor.Test.Linked.Host
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

/-- What every check is given: what a host harness is handed
(`Editor.Test.Linked.HostContext`), and the config tests' own. -/
structure Context extends Editor.Test.Linked.HostContext where
  /-- What `ConfigFixture.bump` returned to compiled code before the base was
  imported. -/
  bumped : Nat
  /-- The directory of the syntax fixtures (`tests/syntax`), whose Rust
  fixtures the indent checks read. -/
  syntaxFixtures : System.FilePath
  /-- The directory of the default config `mise run install` ships
  (`config/default`), which `defaultConfigChecks` read. -/
  defaultConfig : System.FilePath

/-- A check's context as a host harness takes it. -/
instance : Coe Context Editor.Test.Linked.HostContext :=
  ⟨Context.toHostContext⟩

/-- How a check ends that says what it saw when it fails: `true` when `holds`,
and otherwise it throws `observed`, which `failures` reports after the
check's name, as `(saw <observed>)`. -/
def saw (holds : Bool) (observed : String) : IO Bool := do
  unless holds do
    throw (IO.userError s!"saw {observed}")
  return true

/-- `stream`, with each line written to it put after `config-test: during
"<name>": `, and written through at once: nothing is kept, so a run that is
killed has said what it said. A write is taken to start a line, as
`IO.eprintln`'s does. -/
def naming (name : String) (stream : IO.FS.Stream) : IO.FS.Stream :=
  let named (text : String) : String :=
    let label := s!"config-test: during {name.quote}: "
    let lines := text.splitOn "\n"
    -- The piece after the last newline is a line only if it holds something.
    let labelled :=
      lines.mapIdx fun index line =>
        if index + 1 == lines.length && line.isEmpty then line else label ++ line
    "\n".intercalate labelled
  { stream with
    putStr := fun text => stream.putStr (named text)
    write := fun bytes =>
      match String.fromUTF8? bytes with
      | some text => stream.putStr (named text)
      | none => stream.write bytes }

/-- Runs `checks` and returns the names of those that failed. A check that
throws has failed, and its error is reported with its name.

While a check runs, what its thread says on stderr goes through `naming`:
a hang line a host or a wait says there (`hung`, `waitHung`) names the
check it was said in, the moment it is said. -/
def failures (checks : List Check) : IO (List String) :=
  checks.filterMapM fun check => do
    let before ← IO.setStderr (naming check.name (← IO.getStderr))
    try
      return if ← check.run then none else some check.name
    catch error =>
      return some s!"{check.name} ({error})"
    finally
      discard <| IO.setStderr before

/-- One line of the timings (`inventory`): how long `what` took on the
clock, in milliseconds, a tab, and `what`. -/
def timingLine (milliseconds : Nat) (what : String) : String :=
  s!"{milliseconds}\t{what}"

/-- Runs `checks` as `failures` does, and also names, sorted, the checks
during which `realLoops` moved: those that started a real editor loop
thread. As each check ends it hands `timed` the check's line of the
timings (`timingLine`): how far `clock`, which reads milliseconds, moved
while the check ran. No result reads the clock. -/
def inventory (realLoops : IO.Ref Nat) (checks : List Check) (clock : IO Nat := pure 0)
    (timed : String → IO Unit := fun _ => pure ()) : IO (List String × List String) := do
  let mut failed := []
  let mut real := #[]
  for check in checks do
    let before ← realLoops.get
    let started ← clock
    failed := failed ++ (← failures [check])
    timed (timingLine ((← clock) - started) check.name)
    if (← realLoops.get) != before then
      real := real.push check.name
  return (failed, (real.qsort (· < ·)).toList)

/-- What follows the four directories on the checks' command line: the file
of `--real-threads` and the file of `--timings`, each at most once, in
either order; `none` for anything else. -/
def options : List String → Option (Option System.FilePath × Option System.FilePath)
  | [] => some (none, none)
  | "--real-threads" :: file :: rest =>
    match options rest with
    | some (none, timings) => some (some file, timings)
    | _ => none
  | "--timings" :: file :: rest =>
    match options rest with
    | some (realThreads, none) => some (realThreads, some file)
    | _ => none
  | _ => none

/-- The checks of `failures`, `saw` and `inventory`: what a failing check
saw is printed after its name, and the inventory names the checks during
which a loop thread started. -/
def checkChecks (_ : Unit) : List Check :=
  [{  name :=
        "a check that ends with saw of what does not hold fails with what it saw after its name, and saw of what holds holds"
      run := do
        let failed ← failures [{ name := "it holds", run := saw false "x" }]
        return failed == ["it holds (saw x)"] && (← saw true "x") },
    { name :=
        "what a check says on its thread's stderr is written through at once, each line after the check's name, and a check that says nothing leaves nothing"
      run := do
        let caught ← IO.mkRef ({} : IO.FS.Stream.Buffer)
        let between ← IO.mkRef ""
        let said := do
          return String.fromUTF8! (← caught.get).data
        let before ← IO.setStderr (IO.FS.Stream.ofBuffer caught)
        let failed ←
          try
            failures
                [{  name := "it speaks"
                    run := do
                      IO.eprintln "editor: a hang: one"
                      -- Written through, not kept until the check ends.
                      between.set (← said)
                      IO.eprintln "two"
                      return true },
                  { name := "it is silent", run := pure true }]
          finally
            discard <| IO.setStderr before
        let said ← said
        let between ← between.get
        saw
            (failed.isEmpty &&
              between == "config-test: during \"it speaks\": editor: a hang: one\n" &&
              said == between ++ "config-test: during \"it speaks\": two\n")
            s!"failed={failed} between={between.quote} said={said.quote}" },
    { name :=
        "several lines said in one write each come after the check's name with nothing after the last newline, bytes written are named as text is and bytes that are no text pass as they are, and once a check has thrown the thread's stderr is the one it was"
      run := do
        let caught ← IO.mkRef ({} : IO.FS.Stream.Buffer)
        let before ← IO.setStderr (IO.FS.Stream.ofBuffer caught)
        let failed ←
          try
            let failed ←
              failures
                  [{  name := "two"
                      run := do
                        (← IO.getStderr).putStr "a\nb\n"
                        return true },
                    { name := "bytes"
                      run := do
                        (← IO.getStderr).write "c\n".toUTF8
                        return true },
                    { name := "raw"
                      run := do
                        (← IO.getStderr).write ⟨#[0xff, 0x0a]⟩
                        return true },
                    { name := "throws"
                      run := do
                        IO.eprintln "d"
                        throw (IO.userError "x") }]
            -- Said on the buffer itself again: no check is running.
            IO.eprintln "after"
            pure failed
          finally
            discard <| IO.setStderr before
        -- What was said: the text up to the bytes that are none, those
        -- bytes, and the text after them.
        let said := (← caught.get).data.toList
        let text (bytes : List UInt8) : String :=
          (String.fromUTF8? ⟨bytes.toArray⟩).getD "not UTF-8"
        let first := text (said.takeWhile (· != 0xff))
        let raw := (said.dropWhile (· != 0xff)).take 2
        let last := text ((said.dropWhile (· != 0xff)).drop 2)
        saw
            (failed == ["throws (x)"] &&
              first ==
                "config-test: during \"two\": a\nconfig-test: during \"two\": b\nconfig-test: during \"bytes\": c\n" &&
              raw == [0xff, 0x0a] &&
              last == "config-test: during \"throws\": d\nafter\n")
            s!"failed={failed} first={first.quote} raw={raw} last={last.quote}" },
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
            s!"failed {failed}, real {real}" },
    { name :=
        "the inventory hands over, as each check ends, how far its clock moved during the check and the check's name, a failing check's too"
      run := do
        -- A scripted clock: each reading is the next of these.
        let readings ← IO.mkRef [10, 25, 25, 100]
        let clock : IO Nat := readings.modifyGet fun left => (left.headD 0, left.tail)
        let lines ← IO.mkRef (#[] : Array String)
        let seen ← IO.mkRef (#[] : Array Nat)
        let first : Check :=
          { name := "a"
            run := do
              seen.modify (·.push (← lines.get).size)
              return true }
        let second : Check :=
          { name := "b"
            run := do
              seen.modify (·.push (← lines.get).size)
              return false }
        let (failed, _) ←
          inventory (← IO.mkRef 0) [first, second] clock fun line => lines.modify (·.push line)
        let lines ← lines.get
        let seen ← seen.get
        saw (failed == ["b"] && lines == #["15\ta", "75\tb"] && seen == #[0, 1])
            s!"failed={failed} lines={lines} seen={seen}" },
    { name :=
        "the checks' command line takes --real-threads and --timings after its directories, each once and in either order, and nothing else"
      run := do
        let real : Option System.FilePath := some "r"
        let timings : Option System.FilePath := some "t"
        let both := some (real, timings)
        saw
            (options [] == some (none, none) &&
              options ["--real-threads", "r"] == some (real, none) &&
              options ["--timings", "t"] == some (none, timings) &&
              options ["--real-threads", "r", "--timings", "t"] == both &&
              options ["--timings", "t", "--real-threads", "r"] == both &&
              options ["--timings", "t", "--timings", "u"] == none &&
              options ["--timings"] == none &&
              options ["--other", "x"] == none)
            "an option was not read as said" }]

/-- The directories a directory argument of the executable names: one, or
several joined with `:`, as the editor reads its own
(`ModuleLookup.searchPath`). -/
def oleanDirs (argument : String) : List System.FilePath :=
  (ModuleLookup.searchPath argument).map System.FilePath.mk

/-- Makes the base once and runs every check: names on stderr the ones that
failed, and returns the exit status, 0 when all hold and 1 otherwise.

`sysroot` is the Lean toolchain's directory and `oleanDir` the directory
holding the package's `.olean` files, or several joined with `:`
(`oleanDirs`). With `realThreads`, it writes there the names of the checks
that ran a real editor loop thread (`inventory`), sorted, one per line.
With `timings`, it writes there, as each ends, the wall time of the base's
import and of each check (`timingLine`), a line each, flushed as written, so
a run that is killed keeps the lines of what had ended: what a guard is
sized from (`Editor.Test.Linked.hangGuard`). -/
def run (checks : Context → List Check) (sysroot oleanDir : String)
    (syntaxFixtures defaultConfig : System.FilePath) (packages : Array Package)
    (realThreads : Option System.FilePath := none) (timings : Option System.FilePath := none) :
    IO UInt8 := do
  let timed ←
    match timings with
    | some file =>
      do
        let handle ← IO.FS.Handle.mk file .write
        pure fun (line : String) => do
            handle.putStrLn line
            handle.flush
    | none =>
      pure fun _ => pure ()
  -- real time under test: a check's wall time, written for sizing guards; no result reads it.
  let clock : IO Nat := IO.monoMsNow
  -- Compiled code writes to the fixture's cell before the base is imported.
  let bumped ← ConfigFixture.bump
  -- The module data of the config files the checks elaborate is written in
  -- a temporary directory of this run, removed when it ends.
  IO.FS.withTempDir fun scratch => do
      let files ← Config.Elaborate.ModuleFiles.over (pure scratch)
      let elaborator :=
        Editor.Test.Linked.sharing (← IO.mkRef none)
          (Config.Elaborate.elaborator
            { sysroot, oleanDirs := oleanDirs oleanDir,
              imports := #[`Editor, `ConfigFixture, `ExtensionFixture] }
            files)
      -- The one import of the base, made before any check runs.
      let started ← clock
      discard <| elaborator.base none #[]
      timed (timingLine ((← clock) - started) "the base's import, before any check")
      let realLoops ← IO.mkRef 0
      let context : Context :=
        { elaborator, bumped, ids := ← IO.mkRef 100, waits := ← IO.mkRef none, sysroot
          oleanDirs := oleanDirs oleanDir, packages, realLoops, syntaxFixtures, defaultConfig }
      let checks := checks context
      let (failed, real) ← inventory realLoops checks clock timed
      if let some file := realThreads then
        IO.FS.writeFile file (String.join (real.map (· ++ "\n")))
      for name in failed do
        IO.eprintln s!"FAILED: {name}"
      unless failed.isEmpty do
        return 1
      IO.println s!"config-test: {checks.length} checks passed"
      return 0

/-- The checks of `run`'s timings: a run of two checks of its own, on the
context's toolchain and `.olean` directories, with its timings in a file of
a temporary directory. -/
def runChecks (context : Context) : List Check :=
  [{  name :=
        "a run with timings makes the file and writes into it, as each ends, the base's import and each check, a line each of milliseconds, a tab and the name, there to read before the next check runs"
      run :=
        IO.FS.withTempDir fun directory => do
          let file := directory / "timings"
          -- What the file held as each of the run's checks began.
          let seen ← IO.mkRef (#[] : Array String)
          let looks (name : String) : Check :=
            { name
              run := do
                seen.modify (·.push (← IO.FS.readFile file))
                return true }
          -- The run's own line on stdout is caught: it is not this run's.
          let caught ← IO.mkRef ({} : IO.FS.Stream.Buffer)
          let before ← IO.setStdout (IO.FS.Stream.ofBuffer caught)
          let status ←
            try
              run (fun _ => [looks "first", looks "second"]) context.sysroot
                  (":".intercalate (context.oleanDirs.map toString)) context.syntaxFixtures
                  context.defaultConfig context.packages none (some file)
            finally
              discard <| IO.setStdout before
          -- Each line as its name, when what is before the tab is a number.
          let names (text : String) : Array String :=
            ((text.splitOn "\n").filter (· != "")).toArray.map fun line =>
              match line.splitOn "\t" with
              | [milliseconds, name] => if milliseconds.toNat?.isSome then name else s!"? {line}"
              | _ => s!"? {line}"
          let base := "the base's import, before any check"
          let seen := (← seen.get).map names
          let written := names (← IO.FS.readFile file)
          saw
              (status == 0 && seen == #[#[base], #[base, "first"]] &&
                written == #[base, "first", "second"])
              s!"status={status} seen={seen} written={written}" }]

/-- Reports a command line `main` does not understand; the exit status is 2. -/
def usage : IO UInt32 := do
  IO.eprintln
      "usage: config-test <sysroot> <olean dir> <syntax fixtures> <default config> [--real-threads <file>] [--timings <file>] | config-test lsp <sysroot> <config dir> <line> <column> | config-test bench-start <sysroot> <olean dir> <module>... | config-test bench-modules <sysroot> <olean dir> <module>... | config-test bench-reload <sysroot> <olean dir> | config-test bench-reload-directory <sysroot> <olean dir> | config-test bench-soak <sysroot> <olean dir> <count> | config-test bench-soak-modules <sysroot> <olean dir> <count> | config-test bench-jobs <sysroot> <olean dir> <samples> | config-test bench-prompt <sysroot> <olean dir> <samples>"
  return 2

end ConfigTest
