import Editor.Bound
import Editor.Job.Fake
import Editor.Job.Runner
import ModelTest.Check

/-!
# Model tests: `Editor/Job/Fake.lean`

What the fakes of the job runner's services promise of themselves, beside
the contracts they keep (`ModelTest.fileFailures` and the other stepped
runs, `flushContractChecks`, `handleContractChecks`, `pumpContractChecks`):
`jobFakeChecks`. The root module `ModelTest` runs them; its module doc says
what each shows.
-/

namespace ModelTest

open Editor
open Editor.Job

/-- The guard of the stepped runner's end once a completion has been handed
to it between an empty step and its wait; only a hang reaches it. -/
def handedAfterEmptyStepGuard : HangGuard :=
  .on "the completion handed after an empty step, stepped, and its wait ended" 10000

/-- `FakePump.runToEnd` over a pump whose empty steps are held: a thread of
the check's own hands the completion its run waits for while the runner is
held just after a step that found nothing due, before it waits for the next
hand, so the hand lands in that window every time. The run must still step
it and end; a runner that reads the count of hands after its empty step
waits for a hand after this one, which never comes. -/
def handedAfterEmptyStepCheck : Check :=
  { name :=
      "the stepped runner steps a completion handed off its thread between a step that found nothing due and its wait for the next hand"
    run := do
      let completions ← Completions.new
      let pump ← FakePump.new completions
      let clock ← FakeClock.new completions
      let (id, wait) ← completions.register
      let hold ← pump.holdEmptySteps
      let arrived ← pump.emptyStepsArrivedAt 1
      let hander ←
        IO.asTask (prio := .dedicated) do
            try
              discard <| awaitOrHang handedAfterEmptyStepGuard arrived.result?
              pump.hand id
            finally
              hold.resolve ()
      try
        pump.runToEnd wait.result? handedAfterEmptyStepGuard (some clock)
      finally
        hold.resolve ()
        discard <| IO.wait hander
      return (← IO.hasFinished wait.result?) && (← pump.quiescent) }

/-- An order of a fake file service's log, as a check compares it. -/
def filesOrder : FakeFiles.Order → String
  | .start id _ => s!"start {id}"
  | .flush id => s!"flush {id}"
  | .withdraw id => s!"withdraw {id}"
  | .release snapshot => s!"release {snapshot.number}"
  | .diff id => s!"diff {id}"
  | .grep id => s!"grep {id}"
  | .grepCancel id => s!"grepCancel {id}"

/-- An order of a fake process service's log, as a check compares it. -/
def processesOrder : FakeProcesses.Order → String
  | .start id _ => s!"start {id}"
  | .flush id => s!"flush {id}"
  | .withdraw id => s!"withdraw {id}"
  | .kill id => s!"kill {id}"

/-- An order of a fake watch service's log, as a check compares it. -/
def watchesOrder : FakeFileWatches.Order → String
  | .start id _ => s!"start {id}"
  | .flush id => s!"flush {id}"
  | .withdraw id => s!"withdraw {id}"

/-- Throws, naming what `log` held, unless its orders are `expected`, in
order, each handed on `thread`. -/
def expectLog {α : Type} (what : String) (describe : α → String) (log : Array (α × UInt64))
    (expected : Array String) (thread : UInt64) : IO Bool := do
  let orders := log.map (describe ·.1)
  let threads := log.map (·.2)
  unless orders == expected && threads.all (· == thread) do
    throw <|
        IO.userError
          s!"{what} logged {orders} on {threads}, where {expected} on the check's thread {thread} was due"
  return true

/-- The search a check starts over `/r`. -/
def loggedGrep : GrepRequest :=
  .start "/r" "x" #[] { files := 1, found := 1 } 1

/-- The fake file service logs, in the order it was handed them and with the
thread that handed each, every start, flush, withdrawal of a pending file,
diff or search wait, release and cancel of a held search, and no cancel of
a wait it does not hold. -/
def filesLogCheck : Check :=
  { name :=
      "the fake file service logs each start, flush, release and withdrawal of a pending file, diff or search wait, and each cancel of a held search, in the order it was handed them, with the thread that handed each, and no cancel of a wait it does not hold"
    run := do
      let completions ← Completions.new
      let pump ← FakePump.new completions
      let files ← FakeFiles.new completions (({} : FileModel).withDirectory "/r") (.onStep pump)
      let thread ← IO.getTID
      let (load, _) ← completions.register
      files.files.start load (.stamp "/r/x")
      let (flushed, _) ← completions.register
      files.files.flush flushed
      files.files.cancel load
      files.files.release ⟨3⟩
      let (diff, _) ← completions.register
      files.diffs.start diff (.lines (.held ⟨1⟩) (.held ⟨2⟩) 10)
      files.diffs.cancel diff
      let (search, _) ← completions.register
      files.greps.start search loggedGrep
      pump.stepAll
      discard <| files.greps.take search loggedGrep
      files.greps.cancel search
      let (unread, _) ← completions.register
      files.greps.start unread loggedGrep
      files.greps.cancel unread
      files.files.cancel 999
      files.diffs.cancel 999
      files.greps.cancel 999
      pump.stepAll
      expectLog "the fake file service" filesOrder (← files.log)
          #[s!"start {load}", s!"flush {flushed}", s!"withdraw {load}", "release 3",
            s!"diff {diff}", s!"withdraw {diff}", s!"grep {search}", s!"grepCancel {search}",
            s!"grep {unread}", s!"withdraw {unread}"]
          thread }

/-- The fake file service resolves an arrival once that many requests are
started: at once when they already are, else in the start that makes the
count. -/
def filesStartsArrivedCheck : Check :=
  { name :=
      "the fake file service resolves a starts arrival in the start that makes the count, and at once when that many have already started"
    run := do
      let completions ← Completions.new
      let files ← FakeFiles.new completions
      let one ← files.startsArrivedAt 1
      let two ← files.startsArrivedAt 2
      let early := (← IO.hasFinished one.result?, ← IO.hasFinished two.result?)
      files.files.start 1 (.stamp "/a")
      let afterOne := (← IO.hasFinished one.result?, ← IO.hasFinished two.result?)
      let already ← IO.hasFinished (← files.startsArrivedAt 1).result?
      files.files.start 2 (.stamp "/b")
      let afterTwo ← IO.hasFinished two.result?
      unless early == (false, false) && afterOne == (true, false) && already && afterTwo do
        throw <|
            IO.userError
              s!"before a start the arrivals of one and two were {early}, after one {afterOne}, a new one of one {already}, after two {afterTwo}"
      return true }

/-- The command a check's process service runs and streams. -/
def loggedCommand : Process.Command :=
  { program := "/bin/logged", directory := "/" }

/-- The fake process service logs, in the order it was handed them and with
the thread that handed each, every start, flush, withdrawal of a pending
wait and kill of a streaming child, and no cancel of an id it does not
hold; and it records the thread of each start. -/
def processesLogCheck : Check :=
  { name :=
      "the fake process service logs each start, flush, withdrawal of a pending wait and kill of a streaming child, in the order it was handed them, with the thread that handed each, and no cancel of an id it does not hold"
    run := do
      let completions ← Completions.new
      let pump ← FakePump.new completions
      let processes ←
        FakeProcesses.new completions
            { streams := #[{ command := loggedCommand, steps := #[.awaitClosed] }] } (answer :=
            .onStep pump)
      let thread ← IO.getTID
      let (run, _) ← completions.register
      processes.processes.start run (.run loggedCommand 10)
      let (flushed, _) ← completions.register
      processes.processes.flush flushed
      processes.processes.cancel run
      let (child, _) ← completions.register
      processes.processes.start child (.start loggedCommand { bound := 16 })
      pump.stepAll
      discard <| processes.processes.take child (.start loggedCommand { bound := 16 })
      processes.processes.cancel child
      processes.processes.cancel 999
      pump.stepAll
      let starts ← processes.startThreads
      unless starts == #[thread, thread] do
        throw <|
            IO.userError s!"the starts were recorded on {starts}, not the check's thread {thread}"
      expectLog "the fake process service" processesOrder (← processes.log)
          #[s!"start {run}", s!"flush {flushed}", s!"withdraw {run}", s!"start {child}",
            s!"kill {child}"]
          thread }

/-- The fake watch service logs, in the order it was handed them and with the
thread that handed each, every start, flush, withdrawal of a pending wait
and end of a watch, and no cancel of an id it does not hold. -/
def watchesLogCheck : Check :=
  { name :=
      "the fake watch service logs each start, flush, withdrawal of a pending wait and end of a watch, in the order it was handed them, with the thread that handed each, and no cancel of an id it does not hold"
    run := do
      let completions ← Completions.new
      let pump ← FakePump.new completions
      let watches ← FakeFileWatches.new completions { directories := #["/w"] } (.onStep pump)
      let thread ← IO.getTID
      let started : FileWatchRequest := .start (.directory "/w" false) { window := 0, bound := 4 }
      let (watch, _) ← completions.register
      watches.fileWatches.start watch started
      let (flushed, _) ← completions.register
      watches.fileWatches.flush flushed
      pump.stepAll
      discard <| watches.fileWatches.take watch started
      let (next, _) ← completions.register
      watches.fileWatches.start next (.next ⟨watch.toNat⟩)
      watches.fileWatches.cancel next
      watches.fileWatches.cancel watch
      watches.fileWatches.cancel 999
      pump.stepAll
      expectLog "the fake watch service" watchesOrder (← watches.log)
          #[s!"start {watch}", s!"flush {flushed}", s!"start {next}", s!"withdraw {next}",
            s!"withdraw {watch}"]
          thread }

/-- The checks of the job services' fakes' own promises. -/
def jobFakeChecks : List Check :=
  [handedAfterEmptyStepCheck, filesLogCheck, filesStartsArrivedCheck, processesLogCheck,
    watchesLogCheck]

end ModelTest
