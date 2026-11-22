import ContractTest.Check
import ContractTest.Support.Displays
import ContractTest.Support.Files
import ContractTest.Support.Syntax
import Editor.Clipboard
import Editor.Command
import Editor.Display
import Editor.Display.Recorder
import Editor.Ffi.Document
import Editor.Ffi.Events
import Editor.Ffi.Files
import Editor.Ffi.Grep
import Editor.Ffi.Processes
import Editor.Ffi.Snapshot
import Editor.Ffi.Syntax
import Editor.Ffi.Timers
import Editor.Ffi.Watches
import Editor.File
import Editor.FileWatch
import Editor.Grep
import Editor.Highlight
import Editor.Invocation
import Editor.Job
import Editor.Job.Contract
import Editor.Job.Fake
import Editor.Job.Pool
import Editor.Job.Real
import Editor.Job.Runner
import Editor.Mode
import Editor.Process
import Editor.Program
import Editor.Scene
import Editor.SyntaxTree
import Editor.SyntaxTree.Real
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Services
import Editor.Text
import Editor.Text.Real
import Editor.Watch

/-!
# Contract tests: `Editor/Job/Real.lean`

The tests of `Editor/Job/Real.lean`: `fileWatchChecks`, `processChecks`,
`jobChecks`, `fileChecks` and `grepChecks`, what only the runner over the library's services
shows, and `warmPatience`. The root module `ContractTest` runs them; its module
doc says what each shows.
-/

namespace ContractTest

open Editor
open Editor.Test.Linked

/-- An hour, in milliseconds: how long a job sleeps when its wait must not
complete while a check runs. -/
def hour : Nat :=
  3600000

/-- The checks of the watch service's adapter that only the library can
show: a job's watch does not outlive it, and a path that is not UTF-8 is
delivered as missed of the watch's own path. -/
def fileWatchChecks (services : Job.Services) : List Check :=
  [{  name :=
        "a job's watch does not outlive it: once the job has ended the watch service holds nothing of it, and a write is delivered to no one"
      run := do
        Editor.Test.Linked.withFiles services (targets := [.fileWatches]) fun directory => do
            let before ← Ffi.watchesPending
            let job : JobM Bool := do
              let .ok _ ←
                FileWatch.start (.file (directory / "f")) JobContract.watchCoalescing | return false
              return true
            let outcome ← runOnTimers services job
            -- Every start of the watch has returned once a flush of the
            -- service is completed; the count is read once then.
            let ended :=
              (← Editor.Test.Linked.flushedAll services [.fileWatches]) &&
                (← Ffi.watchesPending) == before
            IO.FS.writeFile (directory / "f") "x"
            let stillEnded := (← Ffi.watchesPending) == before
            return outcome == .finished true && ended && stillEnded },
    { name :=
        "a change whose path is not UTF-8 is delivered as missed of the watch's own path, where the volume allows such a name"
      run := do
        Editor.Test.Linked.withFiles services (targets := [.fileWatches]) fun directory => do
            let job : JobM Bool := do
              let watch ← JobContract.watching (.directory directory false)
              let made ←
                Process.run (JobContract.sh directory "printf x > \"$(printf '\\377')\"") 1000
              match made with
              | .ok { exit := .code 0, .. } =>
                let told ← JobContract.readUntil watch (JobContract.toldIn · directory .missed)
                -- Lean cannot name the file to remove it: its name is not a
                -- string. So the shell that made it removes it.
                discard <| Process.run (JobContract.sh directory "rm -f \"$(printf '\\377')\"") 1000
                return told
              | made =>
                -- The volume refuses the name (APFS does): there is nothing
                -- to deliver. The job leaves a marker saying why, and the
                -- check says so on stderr.
                let why :=
                  match made with
                  | .ok ran => s!"{repr ran.exit}: {String.fromUTF8! ran.stderr}"
                  | .error error => error.describe
                discard <|
                    Process.run (JobContract.sh directory s!"printf '%s' '{why}' > refused") 1000
                return true
            let outcome ← runOnTimers services job
            if outcome == .finished true then
              if ← (directory / "refused").pathExists then
                IO.eprintln
                    s!"contract-test: the volume refuses a name that is not UTF-8, so the change of one was not checked here ({← IO.FS.readFile (directory / "refused")})"
            return outcome == .finished true }]

/-- Whether `reply` is the refusal `expected`. -/
def refusedAs (expected : ProcessError) : Except ProcessError Process.Ran → Bool
  | .error refusal => refusal == expected
  | .ok _ => false

/-- Starts, straight through the library's bindings, a run under the id
`id` that sleeps for ten minutes in `directory`, so that the library's
process service refuses another run under that id. It is never completed: a
check cancels it before it ends. Whether the library took it. -/
def occupy (id : UInt64) (directory : System.FilePath) : IO Bool :=
  Ffi.processesRun id "/bin/sleep" #["600"] false #[] #[] directory.toString 10

/-- Runs `check` in a temporary directory of its own, removed whatever
happened once the process service has ended every child it ran there
(`Linked.withFiles`), on `services` with a real process service whose table of the runs
with a time limit armed is one the check holds, so it can read how many
there are. -/
def timedCheck (services : Job.Services)
    (check : System.FilePath → Job.Services → Job.TimedRuns → IO Bool) : IO Bool := do
  Editor.Test.Linked.withFiles services (targets := [.processes]) fun directory => do
      let timed ← Job.TimedRuns.new
      let services :=
        { services with
          processes :=
            Job.realProcesses services.completions (← Job.RefusedRuns.new) services.timers timed }
      check directory services timed

/-- What only the real process service can show: that cancelling a job
whose child is running kills the child, which the service then reaps; and
that a run the library does not take is refused at once by the adapter,
which keeps the refusal until it is taken or its wait is withdrawn
(`realProcesses`). The library refuses a run whose id is in use there, so
those checks first start a run under the id with `occupy`.

Each such check has its own table of refusals, and registers its ids in the
services' table of waits, so no id is one another wait in flight has. The
id the job's first wait gets is the one after the id the check registers:
no other wait is registered while a check runs. If it were not, the job's
run would be taken and the check would fail, not pass.

Seen to bite once by hand, on 2026-11-15, each with one line of
`realProcesses` taken out: without the completion of a run not taken, both
not-taken checks fail, the job waiting for ever; without keeping its
refusal, the first fails, the job getting no result instead; and without
the erasing in `cancel`, the second fails, the take finding the refusal.

The last three are the runs with a time limit, each on a table of the runs
whose alarm is armed that the check holds (`timedCheck`): taken within the
limit, cancelled before it, and timed out. Seen to bite once by hand, on
2026-11-16: without the disarming in the take, the first fails, its alarm
left in the table of waits; without the take and disarming in `cancel`, the
second fails; and with a timed-out run put back in the table at its take,
the third fails. -/
def processChecks (services : Job.Services) : List Check :=
  [{  name :=
        "a job whose child sleeps for ten minutes is cancelled: it ends cancelled, and the process service reaps the child, so nothing is pending that was not before"
      run := do
        Editor.Test.Linked.withFiles services (targets := [.processes]) fun directory => do
            let before ← Ffi.processesPending
            -- The job keeps its unit in a real wait, so no idle says it is
            -- in: the check waits for the run's start to have returned.
            let (start, runStarted) ← startsArrive services.processes.start 1
            let handle ←
              Job.spawn { services with processes := { services.processes with start } }
                  (reporting fun _ => do
                    discard <| Process.run (JobContract.sh directory "/bin/sleep 600") 10
                    return true)
                  (pure ())
            discard <| hangGuarded "the run's start" runStarted.result?
            -- The library counts the run from its start: read once.
            let started := (← Ffi.processesPending) == before + 1
            handle.cancel
            let cancelled ← endedAs handle .cancelled
            let reaped ← Editor.Test.Linked.childrenReapedTo services before
            return started && cancelled && reaped },
    { name :=
        "a run the library does not take, its id being in use there, is refused at once as failed, and the job goes on to a run that ends; the refusal is gone once taken"
      run := do
        Editor.Test.Linked.withFiles services (targets := [.processes]) fun directory => do
            let refused ← Job.RefusedRuns.new
            let services :=
              { services with
                processes :=
                  Job.realProcesses services.completions refused services.timers
                    (← Job.TimedRuns.new) }
            let (probe, _) ← services.completions.register
            services.completions.finish probe .completed
            let taken := probe + 1
            let before ← Ffi.processesPending
            try
              let occupied ← occupy taken directory
              let handle ←
                Job.spawn services
                    (reporting fun _ => do
                      let first ← Process.run (JobContract.sh directory "exit 0") 10
                      let second ← Process.run (JobContract.sh directory "exit 0") 10
                      return refusedAs Job.runNotTaken first &&
                          match second with
                          | .ok ran => ran.exit == .code 0
                          | .error _ => false)
                    (pure ())
              let ended ← endedAs handle (.finished #["true"])
              unless ended do
                handle.cancel
              -- Asked again, the refusal is not there: the library answers, and
              -- it has no result for its own run under the id, still sleeping.
              let again ←
                services.processes.take taken (.run (JobContract.sh directory "exit 0") 10)
              discard <| Ffi.processesCancel taken
              let reaped ← Editor.Test.Linked.childrenReapedTo services before
              return occupied && ended && refusedAs Job.runNoResult again && reaped
            finally
              discard <| Ffi.processesCancel taken },
    { name :=
        "a run the library does not take completes its wait at once, and withdrawing the wait erases the refusal kept for it"
      run := do
        Editor.Test.Linked.withFiles services (targets := [.processes]) fun directory => do
            let processes :=
              Job.realProcesses services.completions (← Job.RefusedRuns.new) services.timers
                (← Job.TimedRuns.new)
            let (id, wait) ← services.completions.register
            let before ← Ffi.processesPending
            let request := ProcessRequest.run (JobContract.sh directory "exit 0") 10
            try
              let occupied ← occupy id directory
              processes.start id request
              let completed ← wait.isResolved
              -- The withdrawal also cancels the library's run under the id.
              processes.cancel id
              let taken ← processes.take id request
              let reaped ← Editor.Test.Linked.childrenReapedTo services before
              return occupied && completed && refusedAs Job.runNoResult taken && reaped
            finally
              discard <| Ffi.processesCancel id
              services.completions.finish id .completed },
    { name :=
        "a run with a time limit that ends well inside it, once taken, leaves no run in the table of time limits and its alarm disarmed: the table of waits is as it was"
      run :=
        timedCheck services fun directory services timed => do
          let waiting ← services.completions.waiting
          let outcome ←
            runOnTimers services do
                return (← Process.runWithin (JobContract.sh directory "exit 0") 10 hour) matches
                    .ok { exit := .code 0, .. }
          -- The take disarms the alarm before the job ends; once a flush of
          -- the timers is completed nothing of the alarm is in flight, and
          -- the tables are read once.
          let disarmed :=
            (← Editor.Test.Linked.flushedAll services [.timers]) && (← timed.size) == 0 &&
              (← services.completions.waiting) == waiting
          return outcome == .finished true && disarmed },
    { name :=
        "a run with a time limit cancelled with its job before the limit leaves no run in the table of time limits and its alarm disarmed, and its child is reaped"
      run :=
        timedCheck services fun directory services timed => do
          let waiting ← services.completions.waiting
          let before ← Ffi.processesPending
          -- The job keeps its unit in a real wait: the check waits for the
          -- run's start, which starts the run and arms its alarm, to return.
          let (start, runStarted) ← startsArrive services.processes.start 1
          let handle ←
            Job.spawn { services with processes := { services.processes with start } }
                (reporting fun _ => do
                  discard <| Process.runWithin (JobContract.sh directory "/bin/sleep 600") 10 hour
                  return true)
                (pure ())
          discard <| hangGuarded "the run's start" runStarted.result?
          let armed := (← Ffi.processesPending) == before + 1 && (← timed.size) == 1
          handle.cancel
          let cancelled ← endedAs handle .cancelled
          -- The cancel disarms the alarm in the call; once a flush of the
          -- timers is completed nothing of it is in flight: read once.
          let disarmed :=
            (← Editor.Test.Linked.flushedAll services [.timers]) && (← timed.size) == 0 &&
              (← services.completions.waiting) == waiting
          let reaped ← Editor.Test.Linked.childrenReapedTo services before
          return armed && cancelled && disarmed && reaped },
    { name :=
        "a run with a time limit that outlives it answers timed out, and then leaves no run in the table of time limits and nothing in the table of waits, and its child is reaped"
      run :=
        timedCheck services fun directory services timed => do
          let waiting ← services.completions.waiting
          let before ← Ffi.processesPending
          let outcome ←
            runOnTimers services do
                return refusedAs (.timedOut 200)
                    (← Process.runWithin (JobContract.sh directory "/bin/sleep 600") 10 200)
          -- The alarm has fired and the take found the run timed out; once
          -- a flush of the timers is completed nothing of it is in flight.
          let disarmed :=
            (← Editor.Test.Linked.flushedAll services [.timers]) && (← timed.size) == 0 &&
              (← services.completions.waiting) == waiting
          let reaped ← Editor.Test.Linked.childrenReapedTo services before
          return outcome == .finished true && disarmed && reaped }]

/-- `count` jobs that each sleep for an hour. -/
def sleepers (services : Job.Services) (count : Nat) : IO (Array Job.Handle) := do
  let mut jobs := #[]
  for _ in [0:count] do
    jobs :=
      jobs.push
        (←
          Job.spawn services
              (reporting fun _ => do
                sleep hour
                return true)
              (pure ()))
  return jobs

/-- hang guard: each pool task's start, which `Pool.holdAll` waits for; only
a pool with fewer free threads than it is asked to hold reaches it, and the
check then fails as a hang. A task starts on a free thread in microseconds;
the guard is `Editor.Test.Linked.hangGuard`'s measured 120 000 ms. -/
def warmPatience : Nat :=
  120000

/-- The checks of the runner over the library's timer service
(`Editor/Job/Real.lean`): what only the real service can show. It is a
function, not a constant, because it calls bindings.

`pool` is the threads the pool was seen to have before the pump was started:
`Pool.holdAll` of the size Lean's runtime gives it (`Pool.expected`). -/
def jobChecks (services : Job.Services) (pool : Array UInt64) : List Check :=
  -- More jobs than the pool has threads, and at least 64.
  let many := max 64 (pool.size + 1)
  [{
      name :=
        "jobs in real waits do not delay a new pool task: more jobs than the pool has threads all have a timer in the library while a new pool task runs",
      run := do
        let before ← Ffi.timersPending
        let (start, timersStarted) ← startsArrive services.timers.start many
        let jobs ← sleepers { services with timers := { services.timers with start } } many
        try
          -- Each job's timer is in the library's schedule once its start has
          -- returned, so every job has reached its wait. A job keeps its unit
          -- in a real wait: no idle can say so.
          discard <| hangGuarded s!"the start of {many} timers" timersStarted.result?
          unless (← Ffi.timersPending) == before + many.toUInt64 do
            return false
          let ran ← IO.Promise.new
          discard <| BaseIO.asTask (ran.resolve ())
          -- hang guard: the new task's run; a pool all of whose threads the
          -- jobs held would never run it.
          let notDelayed := (← Job.awaitWithin patience ran.result?).isSome
          let allWaiting := (← Ffi.timersPending) == before + many.toUInt64
          let noneEnded ← jobs.allM fun job => return !(← job.ended)
          return notDelayed && allWaiting && noneEnded
        finally
          for job in jobs do
            job.cancel },
    { name :=
        "cancelling a job withdraws its timer: each job ends cancelled, and the library's schedule is back to what it held"
      run := do
        let before ← Ffi.timersPending
        let (start, timersStarted) ← startsArrive services.timers.start many
        let jobs ← sleepers { services with timers := { services.timers with start } } many
        try
          -- Every job is in its wait once its timer's start has returned.
          discard <| hangGuarded s!"the start of {many} timers" timersStarted.result?
          unless (← Ffi.timersPending) == before + many.toUInt64 do
            return false
          for job in jobs do
            job.cancel
          let allCancelled ← jobs.allM (endedAs · .cancelled)
          return allCancelled && (← Ffi.timersPending) == before &&
              (← services.completions.waiting) == 0
        finally
          for job in jobs do
            job.cancel },
    { name :=
        "a deadline no machine word holds is not cut down: a job that waits for it is still waiting when a job that sleeps for nothing has finished"
      run := do
        let before ← Ffi.timersPending
        -- Cut down to a 64-bit word, `2 ^ 64 + 1` is 1: a deadline in the
        -- past, which the service would complete at once.
        let (start, farStarted) ← startsArrive services.timers.start 1
        let far ←
          Job.spawn { services with timers := { services.timers with start } }
              (reporting fun _ => do
                waitUntil (2 ^ 64 + 1)
                return true)
              (pure ())
        try
          -- The far job is in its wait once its timer's start has returned.
          discard <| hangGuarded "the far timer's start" farStarted.result?
          unless (← Ffi.timersPending) == before + 1 do
            return false
          let short ←
            Job.spawn services
                (reporting fun _ => do
                  sleep 0
                  return true)
                (pure ())
          let shortFinished ← endedAs short (.finished #["true"])
          -- The timers complete in the order of their deadlines, so had the
          -- far one been due it would have left the schedule first.
          let stillWaiting := (← Ffi.timersPending) == before + 1 && !(← far.ended)
          far.cancel
          return shortFinished && stillWaiting && (← endedAs far .cancelled)
        finally
          far.cancel },
    { name :=
        "a wait the timer service refuses ends the job as cancelled: it does not wait for ever"
      run := do
        -- Ids are a counter, so the id the job's wait will get is known: a
        -- timer that already has it makes the service refuse the job's.
        let (reserved, _) ← services.completions.register
        let taken := reserved + 1
        try
          unless ← Ffi.timersStart taken ((← Ffi.timersNow) + hour.toUInt64) do
            return false
          let jobs ← sleepers services 1
          let ended ← jobs.allM (endedAs · .cancelled)
          return ended && (← services.completions.waiting) == 1
        finally
          discard <| Ffi.timersCancel taken
          services.completions.finish reserved .cancelled },
    { name :=
        "the pump is not one of the pool's tasks: with the pump parked in its pull, every thread the pool had before the pump was started is still free to be held, and no other"
      run := do
        -- Waited for on the pump's park itself; `patience` is a hang guard.
        unless ← Ffi.awaitWaiting .completion 1 patience.toUInt64 do
          return false
        -- A pump that was a pool task would be parked on one of these
        -- threads, and the last of the hold could never start.
        let some threads ← Job.Pool.holdAll pool.size warmPatience | return false
        return !pool.isEmpty && threads.size == pool.size && threads.all pool.contains }]

/-- A file's bytes, in the checks below: "héllo", a line feed, "😀" and the
byte `FF`, which is not UTF-8. Twelve bytes. -/
def noteBytes : ByteArray :=
  ⟨#[0x68, 0xC3, 0xA9, 0x6C, 0x6C, 0x6F, 0x0A, 0xF0, 0x9F, 0x98, 0x80, 0xFF]⟩

/-- The text `noteBytes` loads as, written out by hand. -/
def noteText : String :=
  "héllo\n😀".push (Char.ofNat 0x10DCFF)

/-- Runs `check` on a directory of its own holding `note.txt`, which holds
`noteBytes`, and removes the directory afterwards, whatever happened, once
the library's file service, flushed through `completions`, has worked what
was handed to it (`Linked.withFiles`). -/
def withNote (completions : Job.Completions) (check : System.FilePath → IO Bool) : IO Bool := do
  Editor.Test.Linked.withFiles (← Editor.Test.Linked.Services.over completions).jobs
      fun directory => do
      IO.FS.writeBinFile (directory / "note.txt") noteBytes
      check directory

/-- The checks of the runner over the library's file service and the real
text binding (`Editor/Job/Real.lean`, `Editor/Text/Real.lean`): what only the
two together can show. It is a function, not a constant, because it calls
bindings. Every file is in a temporary directory its check makes and
removes. -/
def fileChecks (completions : Job.Completions) : List Check :=
  [{
      name :=
        "a load writes nothing to the editor's table: with a job parked after its load the published table is as it was and the library holds one snapshot more; the job's command adopts it into the table; and once the command has released it and the job is settled the library holds what it held",
      run :=
        withNote completions fun directory => do
          let rig ← FileRig.new completions
          let size ← rig.published.size
          let live ← Ffi.Snapshot.live
          let handle ←
            Job.spawn rig.services
                (reporting fun _ => do
                  discard <| JobContract.loaded (directory / "note.txt")
                  sleep 1000
                  return true)
                (pure ())
          try
            -- At idle the load has been worked and the job is in its sleep
            -- on the fake clock.
            untilIdle rig.services.activity
            unless (← rig.clock.waiting) == 1 do
              return false
            let parked :=
              (← rig.published.size) == size && (← Ffi.Snapshot.live) == live + 1 &&
                (← rig.held.size) == 1
            rig.clock.advance 1000
            discard <| hangGuarded "the job's end" handle.outcome.result?
            let #[loaded] ← handle.holding | return false
            -- The job's command, on this thread, as the loop runs it.
            let command : EditorM (SnapshotId × String) := do
              let adopted ← loaded.adopt
              return (adopted, ← adopted.read)
            let display := (← recorderOf rig.published).handle
            let (.ok (adopted, read), texts) ←
              Job.finishWith rig.held handle command (.over rig.published) display | return false
            let adoptedHeld :=
              (← rig.published.size) == size + 1 && (← Ffi.Snapshot.live) == live + 1 &&
                (← rig.held.size) == 0 &&
                (← handle.holding).isEmpty
            let (released, _) ← adopted.release.runReal texts
            -- The free is waited for on the free itself; `patience` is a
            -- hang guard.
            return parked && read == noteText && adoptedHeld && released.isOk &&
                (← Ffi.Snapshot.awaitLive live patience.toUInt64) &&
                (← Ffi.Snapshot.live) == live
          finally
            handle.cancel },
    { name :=
        "a job's command run by Job.finishWith reaches the syntax tree it is handed: its text, highlighted as a mode with a syntax tree is entered, is attached in the library, and a query of it answers"
      run := do
        let rig ← FileRig.new completions
        let handle ← Job.spawn rig.services (reporting fun _ => pure 1) (pure ())
        discard <| hangGuarded "the job's end" handle.outcome.result?
        let real ← RealSyntaxTree.new rig.published.reader
        let syntaxTree := settlingAttach rig.published real.handle
        let command : EditorM SnapshotId := do
          let text ← createText "[1, 2]"
          Highlight.enter "json" text { grammar := "json" }
          text.snapshot
        let display := (← recorderOf rig.published).handle
        let (.ok snapshot, texts) ←
          Job.finishWith rig.held handle command (.over rig.published) display (syntaxTree :=
              syntaxTree) | return false
        let numbers : SyntaxTreeM Nat := do
          let query ← SyntaxTree.compile "json" "(number) @n"
          return (← SyntaxTree.captures snapshot query 0 6).size
        let some found ← rig.published.find? snapshot | return false
        unless ← Ffi.syntaxSettle found 5000 do
          return false
        let answered ← numbers.runWith syntaxTree
        -- The text's document is held until here: a document freed is
        -- detached.
        return answered matches .ok 2 && texts.documents.size == 1 },
    { name :=
        "a snapshot a job loaded that no command adopted is freed when the job is settled: the library holds what it held, and the editor's table never grew"
      run :=
        withNote completions fun directory => do
          let rig ← FileRig.new completions
          let live ← Ffi.Snapshot.live
          let handle ←
            Job.spawn rig.services
                (reporting fun _ => do
                  return (← JobContract.loaded (directory / "note.txt")).stamp.size)
                (pure ())
          let ended ← endedAs handle (.finished #["12"])
          let kept := (← Ffi.Snapshot.live) == live + 1 && (← rig.held.size) == 1
          let display := (← recorderOf rig.published).handle
          let (ran, _) ←
            Job.finishWith rig.held handle (pure () : EditorM Unit) (.over rig.published) display
          return ended && kept && ran.isOk && (← Ffi.Snapshot.awaitLive live patience.toUInt64) &&
              (← Ffi.Snapshot.live) == live &&
              (← rig.held.size) == 0 &&
              (← rig.published.size) == 0 },
    { name :=
        "cancelling a job whose load is in the file service behind other requests leaves the service and the runner with nothing of it, whether the cancel found the load waiting, being worked or done: the service's count is that of the requests ahead, and nothing is held"
      run :=
        withNote completions fun directory => do
          let rig ← FileRig.new completions
          let before ← Ffi.filesPending
          let live ← Ffi.Snapshot.live
          let snapshot ← (← Ffi.Document.new noteText).snapshot
          -- Five saves ahead of the job's load, started straight at the
          -- service under ids the table of waits gave out, so no job's wait
          -- has them. Each syncs its file, so the load is behind them.
          let mut ahead := #[]
          for index in [0:5] do
            let (id, _) ← completions.register
            unless
              ← Ffi.filesSave id snapshot (directory / s!"ahead-{index}.txt").toString .whatever do
              return false
            ahead := ahead.push id
          let (start, loadStarted) ← startsArrive rig.services.files.start 1
          let handle ←
            Job.spawn { rig.services with files := { rig.services.files with start } }
                (reporting fun _ => do
                  return (← JobContract.loaded (directory / "note.txt")).stamp.size)
                (pure ())
          try
            -- The job's request is at the service once its start has
            -- returned. On a file system that syncs slowly the load is still
            -- waiting then; on a fast one it may be done, and the job with
            -- it. The job keeps its unit in a real wait: no idle can say so.
            discard <| hangGuarded "the load's start" loadStarted.result?
            handle.cancel
            discard <| hangGuarded "the cancelled job's end" handle.outcome.result?
            handle.settle
            -- Once a flush of the service is completed the five ahead are
            -- done, their results kept and counted; the job's load is gone,
            -- whichever state the cancel found it in.
            let withdrawn :=
              (← Editor.Test.Linked.filesFlushed completions) && (← Ffi.filesPending) == before + 5
            -- The one snapshot left is the one made here, which is read last
            -- so that it is alive until then.
            return withdrawn && (← rig.held.size) == 0 &&
                (← Ffi.Snapshot.awaitLive (live + 1) patience.toUInt64) &&
                (← Ffi.Snapshot.live) == live + 1 &&
                (← snapshot.info).byteLength == 15
          finally
            handle.cancel
            for id in ahead do
              discard <| Ffi.filesCancel id
              completions.finish id .cancelled
            -- The cancels drop the kept results at once; a flush covers a
            -- request still in flight. The snapshots they held are freed on
            -- the library's threads: waited for on the frees, with
            -- `patience` as a hang guard.
            discard <| Editor.Test.Linked.filesFlushed completions
            discard <| Ffi.Snapshot.awaitLive (live + 1) patience.toUInt64 },
    { name :=
        "a job saves a snapshot a command took, found through the published table, and a snapshot the command has released since is refused as naming none, and writes no file"
      run :=
        withNote completions fun directory => do
          let rig ← FileRig.new completions
          let take : TextM SnapshotId := do
            let text ← createText noteText
            let taken ← text.snapshot
            -- The text moves on: the snapshot does not.
            text.insert 0 "x"
            return taken
          let (.ok taken, texts) ← take.runReal (.over rig.published) | return false
          let saver (name : String) (job : System.FilePath → JobM Bool) : IO Bool := do
            let handle ←
              Job.spawn rig.services (reporting fun _ => job (directory / name)) (pure ())
            endedAs handle (.finished #["true"])
          let saved ←
            saver "taken.txt" fun path => do
                return (← JobContract.saved (.snapshot taken) path .absent).size == 12
          let (released, _) ← taken.release.runReal texts
          let refused ←
            saver "released.txt" fun path =>
                JobContract.saveRefusedAs .noSuchSnapshot (.snapshot taken) path .absent
          return saved && released.isOk && refused &&
              (← IO.FS.readBinFile (directory / "taken.txt")) == noteBytes &&
              !(← (directory / "released.txt").pathExists) }]

/-- The checks of the runner over the library's grep service
(`realGreps`): what only the library can show. A job's search does not
outlive the job; and an overlay of a snapshot a command took, published in
the store's table, is searched in place of a file whose text on disk
differs. Every file is in a temporary directory its check makes and
removes once the grep and file services have worked what was handed to them
(`Linked.withFiles`, with the grep service's flush): no cancelled search
still walks it. -/
def grepChecks (completions : Job.Completions) : List Check :=
  [{  name :=
        "a job's search does not outlive the job: cancelled while its search is held, the grep service holds nothing more"
      run := do
        Editor.Test.Linked.withFiles (← Editor.Test.Linked.Services.over completions).jobs
            (targets := [.greps, .files]) fun directory => do
            IO.FS.writeFile (directory / "a") "needle\n"
            let rig ← FileRig.new completions
            let before ← Ffi.grepPending
            let handle ←
              Job.spawn rig.services
                  (reporting fun _ => do
                    let .ok _ ←
                      Grep.start directory "needle" #[] JobContract.wideLimits 64 | return false
                    sleep hour
                    return true)
                  (pure ())
            -- At idle the job is in its sleep on the fake clock, its search
            -- started and held.
            untilIdle rig.services.activity
            let held := (← Ffi.grepPending) > before
            handle.cancel
            let cancelled ← endedAs handle .cancelled
            -- A readout, final once the outcome is in: `Handle.conclude` ends
            -- the job's searches, a cancel the grep service does in the call,
            -- before it resolves the outcome.
            let freed := (← Ffi.grepPending) == before
            return held && cancelled && freed },
    { name :=
        "an overlay of a snapshot a command took is searched in place of a file whose text on disk differs, and answered as the buffer's"
      run := do
        Editor.Test.Linked.withFiles (← Editor.Test.Linked.Services.over completions).jobs
            (targets := [.greps, .files]) fun directory => do
            IO.FS.writeFile (directory / "a") "nothing\n"
            IO.FS.writeFile (directory / "b") "x needle\n"
            let rig ← FileRig.new completions
            let first ← Job.spawn rig.services (reporting fun _ => pure 1) (pure ())
            discard <| hangGuarded "the first job's end" first.outcome.result?
            let command : EditorM SnapshotId := do
              let text ← createText "y\nneedle needle"
              text.snapshot
            let display := (← recorderOf rig.published).handle
            let (.ok snapshot, _) ←
              Job.finishWith rig.held first command (.over rig.published) display | return false
            let handle ←
              Job.spawn rig.services
                  (reporting fun _ => do
                    let reply ←
                      JobContract.searchedAll directory "needle"
                          #[(directory / "a", .snapshot snapshot)]
                    return reply.toOption ==
                        some
                          (#[("a", .buffer, #[(1, 2, 8), (1, 9, 15)]), ("b", .disk, #[(0, 2, 8)])],
                            .complete 2 3))
                  (pure ())
            endedAs handle (.finished #["true"]) }]

end ContractTest
