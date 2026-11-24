import ConfigTest.Check
import ConfigTest.Editor.Headless
import Editor.Job.Contract
import Editor.RealHost
import Editor.Test.Linked.Host

/-!
# Config tests: `Editor/Job/Real.lean`, the library's diff and grep services

A module of the wiring set (`AGENTS.md`, "Deterministic concurrency in
tests"; `docs/dev-practices/real-thread-checks.md`): the test module that
mirrors the real adapters' module, `Editor/Job/Real.lean`.

**The real adapters.** The library's diff service (`Job.realDiffs`) and its
grep service (`Job.realGreps`), as `Headless.shipped` wires them, reached
by a host's job. **Why.** They are the diff and grep services' end-to-end
checks (AC4): the fakes stand in for them in every other host check, and
their behaviour is their contracts' (`ContractTest`'s diff and grep
checks). Each host is stepped on the check's thread over a stage on the
library's services (`Stage.overFiles`), waits on its own job's end line,
and lives inside `context.withFiles`, which flushes the services it used
before its directory goes. Each asserts the wiring alone: the service is
reached and answers.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.ConfigTest.Editor.Job.Real : Editor.WiringSet :=
  .wiring
    "the library's diff and grep services (Job.realDiffs, Job.realGreps), reached by a host's job"
    "they are those services' end-to-end checks, which the fakes stand in for in every other host check"

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- A job `diff` that loads `old` and `new` from `directory` and asks the
diff service for their line diff, its command saying how many edits the
script holds. -/
def diffJob (directory : System.FilePath) : Config.JobRegistration :=
  { name := "diff"
    work := fun _ =>
      Work.of
        (fun _ => do
          let old ← JobContract.loaded (directory / "old")
          let new ← JobContract.loaded (directory / "new")
          match ← Diff.lines (.held old.snapshot) (.held new.snapshot) 100 with
          | .ok script =>
            return script.size
          | .error error =>
            throw s!"the diff was refused: {error.describe}")
        fun edits => message s!"diff: {edits} edits" }

/-- A job `grep` that searches `directory` for `needle` and takes every
delivery until the search ends, its command saying how many files matched. -/
def grepJob (directory : System.FilePath) : Config.JobRegistration :=
  { name := "grep"
    work := fun _ =>
      Work.of
        (fun _ => do
          let .ok search ←
            Grep.start directory "needle" #[] { files := 10, found := 10 }
                10 | throw "the search was refused"
          let mut found := 0
          repeat
            let .ok delivery ← Grep.next search | throw "a delivery was refused"
            found := found + delivery.found.size
            if delivery.ended.isSome then
              break
          return found)
        fun files => message s!"grep: {files} files" }

/-- Runs `check` against a host stepped on the check's thread over a stage
on the library's file, diff and grep services (`Stage.overFiles`), handed
`compiled`, inside the directory `directory`. -/
def withServiceHost (context : Context) (compiled : Compiled) (check : Session → IO Bool) :
    IO Bool := do
  let stage ← Stage.overFiles context (memorySource []) compiled
  onStage stage fun drive stage => check (Session.ofStage drive "/" stage)

/-- The end-to-end checks of the library's diff and grep services. -/
def jobServiceChecks (context : Context) : List Check :=
  [{  name :=
        "a host's job's line diff of two files is answered by the library's diff service: the job ends ok, its command saying the script's edits"
      run :=
        context.withFiles (targets := [.files, .diffs]) fun directory => do
          IO.FS.writeFile (directory / "old") "a\nb\nc\n"
          IO.FS.writeFile (directory / "new") "a\nx\nc\n"
          withServiceHost context { jobs := #[diffJob directory] } fun session => do
              session.ask [.spawn "diff"]
              unless ← session.outputReaches (·.contains "job 1 diff: ok") do
                return false
              let (echo, _) ← session.scene
              -- How many edits the script holds is the diff's rules',
              -- `ContractTest`'s diff checks': here only that it answered.
              saw ((echo.splitOn "diff: ").length == 2 && echo != "diff: 0 edits".quote)
                  s!"echo {echo}" },
    { name :=
        "a host's job's search of a directory is answered by the library's grep service: the job ends ok, its command saying the files that matched"
      run :=
        context.withFiles (targets := [.files, .greps]) fun directory => do
          IO.FS.writeFile (directory / "one.txt") "a needle here\n"
          IO.FS.writeFile (directory / "two.txt") "no match\n"
          withServiceHost context { jobs := #[grepJob directory] } fun session => do
              session.ask [.spawn "grep"]
              unless ← session.outputReaches (·.contains "job 1 grep: ok") do
                return false
              let (echo, _) ← session.scene
              saw (echo == "grep: 1 files".quote) s!"echo {echo}" }]

end ConfigTest
