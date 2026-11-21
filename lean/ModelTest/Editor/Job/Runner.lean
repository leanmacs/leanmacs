import Editor.Command
import Editor.File
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Fuzzy
import Editor.Fuzzy.Model
import Editor.Invocation
import Editor.Job
import Editor.Job.Activity
import Editor.Job.Contract
import Editor.Job.Fake
import Editor.Job.Jobs
import Editor.Job.Pool
import Editor.Job.Runner
import Editor.Job.Table
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.Test.Jobs
import Editor.Test.Models
import Editor.Text
import Editor.Text.Model
import ModelTest.Check

/-!
# Model tests: `Editor/Job/Runner.lean`

The model tests of `Editor/Job/Runner.lean`: `waitChecks`, `runnerChecks`,
`fileRunnerChecks`, `fileWatchRunnerChecks`, `grepRunnerChecks` and
`activityRunnerChecks`. `fileWatchRunnerChecks` are the runner's watch waits
on the fake of the watch service, and `activityRunnerChecks` the runner's
activity accounting over a count of each check's own. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- How `wait` ended; `none` while it is in flight. -/
def ended (wait : IO.Promise Job.Completion) : BaseIO (Option Job.Completion) := do
  if ← wait.isResolved then
    return wait.result?.get
  else
    return none

/-- Registers a wait in `rig`'s table and starts it at the clock for
`deadline`, as the runner does. `log` gets the wait's id when it ends,
on the thread that ended it, so the order of a log is the order the waits
ended in. -/
def _root_.Editor.Test.Rig.wait (rig : Rig) (deadline : Nat) (log : IO.Ref (Array UInt64)) :
    BaseIO (UInt64 × IO.Promise Job.Completion) := do
  let (id, wait) ← rig.services.completions.register
  BaseIO.chainTask wait.result? (fun _ => log.modify (·.push id)) (sync := true)
  rig.services.timers.start id deadline
  return (id, wait)

/-- The checks of the table of waits and of the fake clock
(`Editor/Job/Runner.lean`, `Editor/Job/Fake.lean`), with no job. -/
def waitChecks : List Check :=
  [{
      name :=
        "the table of waits gives each wait an id of its own, from 1, and finish ends exactly that wait and forgets it",
      run := do
        let table ← Job.Completions.new
        let (first, firstWait) ← table.register
        let (second, secondWait) ← table.register
        table.finish first .completed
        return first == 1 && second == 2 && (← ended firstWait) == some .completed &&
            (← ended secondWait) == none &&
            (← table.waiting) == 1 },
    { name :=
        "a wait ends once: a second finish, and a finish for an id that is not waiting, change nothing, and no id is used again"
      run := do
        let table ← Job.Completions.new
        let (id, wait) ← table.register
        table.finish id .cancelled
        table.finish id .completed
        table.finish 99 .completed
        let (next, _) ← table.register
        return (← ended wait) == some .cancelled && next == id + 1 && (← table.waiting) == 1 },
    { name :=
        "a wait registered with an action ends by running it once, with how it ended, on the thread that finishes it: a second finish of its id runs nothing"
      run := do
        let table ← Job.Completions.new
        let log ← IO.mkRef (#[] : Array (UInt64 × Job.Completion))
        let id ← table.registerWith fun id completion => log.modify (·.push (id, completion))
        let before ← log.get
        let waitingBefore ← table.waiting
        table.finish id .cancelled
        -- Read as soon as `finish` returns: the action ran inside it.
        let after ← log.get
        table.finish id .completed
        return before.isEmpty && waitingBefore == 1 && after == #[(id, .cancelled)] &&
            (← log.get) == #[(id, .cancelled)] &&
            (← table.waiting) == 0 },
    { name := "a wait's action runs though nothing holds what it resolves"
      run := do
        let table ← Job.Completions.new
        let ran ← IO.mkRef (none : Option Job.Completion)
        -- No promise and no task is kept here: only the table holds the
        -- action.
        let id ← table.registerWith fun _ completion => ran.set (some completion)
        table.finish id .completed
        return (← ran.get) == some .completed },
    { name :=
        "the fake clock's arrival promise is resolved by an arrival made before it was asked for, at once, and by one made after, in the step that makes it: waits started, waits waiting, and calls arrived at a hold"
      run := do
        let rig ← Rig.new
        let log ← IO.mkRef #[]
        discard <| rig.wait 10 log
        -- Already reached when asked for: resolved at once.
        let startedOne ← rig.clock.arrivedAt (.started 1)
        let waitingOne ← rig.clock.arrivedAt (.waiting 1)
        -- Not yet reached: resolved by the start that reaches it, inside it.
        let startedTwo ← rig.clock.arrivedAt (.started 2)
        let waitingNone ← rig.clock.arrivedAt (.waiting 0)
        let beforeSecond := (← startedTwo.isResolved, ← waitingNone.isResolved)
        discard <| rig.wait 20 log
        let afterSecond ← startedTwo.isResolved
        rig.clock.advance 20
        let afterAdvance ← waitingNone.isResolved
        -- A start that arrives at a hold resolves the promise of `held`: one
        -- asked for before it arrives, and one asked for after, at once.
        let hold ← rig.clock.holdStarts
        let heldOne ← rig.clock.arrivedAt (.held 1)
        let (id, _) ← rig.services.completions.register
        let starting ← IO.asTask (prio := .dedicated) (rig.services.timers.start id 30)
        let some _ ← Job.awaitWithin patience heldOne.result? |
          hold.resolve ();
          return false
        let heldLater ← rig.clock.arrivedAt (.held 1)
        let resolvedLater ← heldLater.isResolved
        hold.resolve ()
        discard <| IO.wait starting
        return (← startedOne.isResolved) && (← waitingOne.isResolved) &&
            beforeSecond == (false, false) &&
            afterSecond &&
            afterAdvance &&
            resolvedLater },
    { name :=
        "the fake files' take arrival promise is resolved by a take that arrived at the hold before it was asked for, and by one that arrives after"
      run := do
        let completions ← Job.Completions.new
        let files ← Job.FakeFiles.new completions
        let hold ← files.holdTakes
        let first ← files.takesArrivedAt 1
        let taking ← IO.asTask (prio := .dedicated) files.parkTake
        let some _ ← Job.awaitWithin patience first.result? |
          hold.resolve ();
          return false
        let again ← files.takesArrivedAt 1
        let resolvedAgain ← again.isResolved
        let second ← files.takesArrivedAt 2
        let unresolved ← second.isResolved
        hold.resolve ()
        discard <| IO.wait taking
        files.parkTake
        return resolvedAgain && !unresolved && (← second.isResolved) },
    { name :=
        "the fake clock completes the waits that are due when it is advanced, earliest deadline first, and leaves the others waiting"
      run := do
        let rig ← Rig.new
        let log ← IO.mkRef #[]
        let (late, _) ← rig.wait 30 log
        let (early, _) ← rig.wait 10 log
        let (middle, _) ← rig.wait 20 log
        let (last, lastWait) ← rig.wait 40 log
        let before ← log.get
        rig.clock.advance 30
        let due ← log.get
        let waiting ← rig.clock.waiting
        let lastEnded ← ended lastWait
        rig.clock.advance 10
        return before.isEmpty && due == #[early, middle, late] && waiting == 1 &&
            lastEnded == none &&
            (← log.get) == #[early, middle, late, last] &&
            (← rig.clock.now) == 40 },
    { name := "the fake clock completes a wait started at or after its deadline at once"
      run := do
        let rig ← Rig.new
        let log ← IO.mkRef #[]
        rig.clock.advance 30
        let (now, nowWait) ← rig.wait 30 log
        let (past, pastWait) ← rig.wait 7 log
        return (← log.get) == #[now, past] && (← ended nowWait) == some .completed &&
            (← ended pastWait) == some .completed &&
            (← rig.clock.waiting) == 0 &&
            (← rig.clock.started) == #[(now, 30), (past, 7)] },
    { name :=
        "the fake clock records each wait started with the thread that started it, and each wait withdrawn, and never completes a withdrawn wait"
      run := do
        let rig ← Rig.new
        let log ← IO.mkRef #[]
        let (kept, _) ← rig.wait 10 log
        let (dropped, droppedWait) ← rig.wait 10 log
        rig.services.timers.cancel dropped
        -- Withdrawing a wait that is not waiting is not recorded.
        rig.services.timers.cancel 99
        rig.clock.advance 10
        return (← log.get) == #[kept] && (← ended droppedWait) == none &&
            (← rig.clock.started) == #[(kept, 10), (dropped, 10)] &&
            (← rig.clock.withdrawn) == #[dropped] &&
            (← rig.clock.startThreads) == #[← IO.getTID, ← IO.getTID] }]

/-- `value`, once `gate` has been resolved: pure work a check can hold a
thread in. It is never inlined, so the read of the gate stays where the call
is. -/
@[noinline]
def onceOpen (gate : IO.Promise Unit) (value : Nat) : Nat :=
  if gate.result?.get.isSome then value else value + 1

/-- The checks of the job runner (`Editor/Job/Runner.lean`), each on a fake
clock of its own. A check holds what it controls (the clock, a promise) and
polls only as the bound after which it fails. -/
def runnerChecks : List Check :=
  [{
      name :=
        "a job that runs to its end is finished with its command, a job that throws is failed with its message, and the runner says so once for each",
      run := do
        let rig ← Rig.new
        let ends ←
          rig.spawn
              (reporting fun _ => do
                sleep 2
                return 42)
        let throws ←
          rig.spawn fun _ => do
              sleep 2
              throw "no thanks"
        unless ← eventually (return (← rig.clock.waiting) == 2) do
          return false
        rig.clock.advance 2
        return (← ends.endedAs (.finished #["42"])) && (← throws.endedAs (.failed "no thanks")) },
    { name :=
        "a fuzzy request on the runner is answered at once by the fuzzy service it was given, registering no wait and moving no clock; a service that throws is answered to the job as an error, `fuzzy: ` and its message, which the job can catch and go on from, and which, uncaught, fails the job; a runner given no fuzzy service answers `fuzzy: this runner has no fuzzy service`"
      run := do
        let rig ← Rig.new
        let given := { rig with services := { rig.services with fuzzy := FuzzyModel.handler } }
        let broken :=
          { rig with
            services := { rig.services with fuzzy := fun _ => throw (IO.userError "broken") } }
        let candidates := #["wq", "edit", "w"]
        let ranked : Unit → JobM (Array Nat) := fun _ => Job.embedFuzzy (Fuzzy.rank "w" candidates)
        let caught : Unit → JobM String := fun _ => do
          try
            discard <| ranked ()
            return "answered"
          catch message =>
            return message
        let answered ← given.spawn (reporting ranked)
        let refused ← broken.spawn (reporting caught)
        let failed ← broken.spawn (reporting ranked)
        let absent ← rig.spawn (reporting caught)
        return (← answered.endedAs (.finished #[toString (FuzzyModel.rank "w" candidates)])) &&
            (← refused.endedAs (.finished #["fuzzy: broken"])) &&
            (← failed.endedAs (.failed "fuzzy: broken")) &&
            (← absent.endedAs (.finished #["fuzzy: this runner has no fuzzy service"])) &&
            (← rig.clock.started).isEmpty &&
            (← rig.clock.now) == 0 &&
            (← rig.services.completions.register).1 == 1 },
    { name :=
        "100,000 now requests in one job are answered on one thread, and none of them registers a wait"
      run := do
        let rig ← Rig.new
        let reads ←
          rig.spawn
              (reporting fun _ => do
                let mut last := 0
                for _ in [0:100000] do
                  last ← now
                return last)
        let ended ← reads.endedAs (.finished #["0"])
        -- A request that needs no wait is a direct call on the job's thread:
        -- a runner that hopped to a task for each would read the clock from
        -- many threads.
        return ended && (← rig.clock.reads) == 100000 && (← rig.clock.readThreads).size == 1 &&
            (← rig.clock.started).isEmpty &&
            (← rig.services.completions.register).1 == 1 },
    { name :=
        "jobs blocked in waits do not delay a new pool task, and their waits hold no thread: more jobs than the pool has threads all reach their wait from fewer threads than there are jobs"
      run := do
        let rig ← Rig.new
        -- More jobs than the pool has threads, whatever its size is here.
        let count := max 64 ((← Job.Pool.expected) + 1)
        let mut jobs := #[]
        for _ in [0:count] do
          jobs :=
            jobs.push
              (←
                rig.spawn
                    (reporting fun _ => do
                      sleep 1000
                      return true))
        try
          -- A runner that parked a thread in a system call for each wait
          -- would let only a pool's worth of jobs get this far.
          unless ← eventually (return (← rig.clock.waiting) == count) do
            return false
          let ran ← IO.Promise.new
          discard <| BaseIO.asTask (ran.resolve ())
          let notDelayed ← eventually ran.isResolved
          -- The clock has not moved, so every job is still in its wait.
          let allWaiting := (← rig.clock.waiting) == count && (← rig.clock.now) == 0
          let noneEnded ← jobs.allM fun job => return !(← job.handle.ended)
          -- A runner that parked each job in `IO.wait` would have had Lean add
          -- a thread for every one of them: as many threads as jobs.
          let threads := distinct (← rig.clock.startThreads)
          rig.clock.advance 1000
          let allFinished ← jobs.allM (·.endedAs (.finished #["true"]))
          return notDelayed && allWaiting && noneEnded && threads < count && allFinished
        finally
          rig.clock.advance 1000 },
    { name :=
        "jobs in file waits do not delay a new pool task, and their waits hold no thread: more jobs than the pool has threads are all in a load at once, started from fewer threads than there are jobs"
      run := do
        let (rig, files) ←
          Rig.withFiles
              ((({} : FileModel).withDirectory fileRoot).withFile (fileRoot / "a.txt")
                JobContract.rawFile)
        files.holdCompletions
        let count := max 64 ((← Job.Pool.expected) + 1)
        let mut jobs := #[]
        for _ in [0:count] do
          jobs :=
            jobs.push
              (←
                rig.spawn
                    (reporting fun _ => do
                      return (← JobContract.loaded (fileRoot / "a.txt")).stamp.size))
        try
          unless ← eventually (return (← files.waiting) == count) do
            return false
          let ran ← IO.Promise.new
          discard <| BaseIO.asTask (ran.resolve ())
          let notDelayed ← eventually ran.isResolved
          let allWaiting := (← files.waiting) == count
          let noneEnded ← jobs.allM fun job => return !(← job.handle.ended)
          let threads := distinct (← files.startThreads)
          files.letGo
          let allFinished ← jobs.allM (·.endedAs (.finished #["17"]))
          return notDelayed && allWaiting && noneEnded && threads < count && allFinished
        finally
          files.letGo },
    { name :=
        "a job's leading pure work does not run on the spawning thread: spawn returns while that work is still held"
      run := do
        let rig ← Rig.new
        let gate : IO.Promise Unit ← IO.Promise.new
        try
          -- The job's leading pure work reads the gate, so whichever thread
          -- applies the job stays in it until the check resolves the gate.
          let work : Work := fun _ =>
            if gate.result?.get.isSome then pure (makes "ran") else pure (makes "dropped")
          -- On a thread of its own: a spawn that applied the job on its
          -- caller's thread would not return while the gate is held, and
          -- the wait for it would run out.
          let spawning ← BaseIO.asTask (prio := .dedicated) (rig.spawn work)
          let returned ← eventually (IO.hasFinished spawning)
          let held := !(← gate.isResolved)
          gate.resolve ()
          unless returned do
            return false
          return held && (← spawning.get.endedAs (.finished #["ran"]))
        finally
          gate.resolve () },
    { name :=
        "cancelling a sleeping job ends it promptly: it is cancelled, its wait is withdrawn at the clock and gone from the table, and the runner says so once, with the clock never moved"
      run := do
        let rig ← Rig.new
        let sleeper ←
          rig.spawn
              (reporting fun _ => do
                sleep 1000
                return true)
        try
          unless ← eventually (return (← rig.clock.waiting) == 1) do
            return false
          let started ← rig.clock.started
          sleeper.handle.cancel
          -- The clock stays at 0, so only the cancel can have ended the job.
          let cancelled ← sleeper.endedAs .cancelled
          return cancelled && started.size == 1 && (← rig.clock.withdrawn) == started.map (·.1) &&
              (← rig.clock.waiting) == 0 &&
              (← rig.services.completions.waiting) == 0 &&
              (← rig.clock.now) == 0
        finally
          sleeper.handle.cancel },
    { name :=
        "a cancelled job cannot be resumed by a try/catch: a job that catches every error around each of five sleeps, cancelled in the first, makes no further request"
      run := do
        let rig ← Rig.new
        let job ←
          rig.spawn fun _ => do
              stubborn
              return makes "resumed"
        try
          unless ← eventually (return (← rig.clock.waiting) == 1) do
            return false
          job.handle.cancel
          -- A job that went on would start its second sleep.
          discard <|
              eventually do
                return (← job.handle.ended) || (← rig.clock.started).size > 1
          -- Past all five sleeps: a job that had gone on runs to its end.
          rig.clock.advance 100
          return (← job.endedAs .cancelled) && (← rig.clock.started).size == 1 &&
              (← rig.clock.reads) == 1
        finally
          job.handle.cancel },
    { name :=
        "a job cancelled before it starts makes no request: cancelled while its leading work is held, it reads no clock and starts no wait"
      run := do
        let rig ← Rig.new
        let gate : IO.Promise Unit ← IO.Promise.new
        let job ←
          rig.spawn fun _ =>
              if gate.result?.get.isSome then do
                sleep 1000
                return makes "ran"
              else pure (makes "dropped")
        -- A job with no request at all: cancelled, it does not finish.
        let short ←
          rig.spawn fun _ =>
              if gate.result?.get.isSome then pure (makes "ran") else pure (makes "dropped")
        try
          job.handle.cancel
          short.handle.cancel
          gate.resolve ()
          -- A job that went on would read the clock for its sleep.
          discard <|
              eventually do
                return (← job.handle.ended) || (← rig.clock.reads) > 0
          return (← job.endedAs .cancelled) && (← short.endedAs .cancelled) &&
              (← rig.clock.reads) == 0 &&
              (← rig.clock.started).isEmpty
        finally
          gate.resolve ()
          job.handle.cancel },
    { name :=
        "cancellation is looked for again when a reply arrives: a job cancelled while a reading of the clock is in flight is not continued with the reading"
      run := do
        let rig ← Rig.new
        let gate : IO.Promise Unit ← IO.Promise.new
        let reading ← rig.clock.holdReads
        let job ←
          rig.spawn
              (reporting fun _ => do
                let instant ← now
                -- What follows the reply starts with pure work the check
                -- holds: a runner that applied it would be held in it.
                waitUntil (onceOpen gate instant + 10)
                return true)
        try
          unless ← eventually (return (← rig.clock.held) == 1) do
            return false
          job.handle.cancel
          reading.resolve ()
          -- The gate is still shut, so the job can only have ended if what
          -- follows the reply was never applied.
          let cancelled ← job.endedAs .cancelled
          return cancelled && !(← gate.isResolved) && (← rig.clock.started).isEmpty
        finally
          reading.resolve ()
          gate.resolve ()
          job.handle.cancel },
    { name :=
        "a wait entered just as the job is cancelled is withdrawn at once: cancelled while the clock is being asked for the wait, the job ends with the clock never moved"
      run := do
        let rig ← Rig.new
        let starting ← rig.clock.holdStarts
        let job ←
          rig.spawn
              (reporting fun _ => do
                sleep 1000
                return true)
        try
          -- The job has registered its wait and is asking the clock for it:
          -- the cancel finds no wait to withdraw yet.
          unless ← eventually (return (← rig.clock.held) == 1) do
            return false
          job.handle.cancel
          starting.resolve ()
          let cancelled ← job.endedAs .cancelled
          let started ← rig.clock.started
          return cancelled && started.size == 1 && (← rig.clock.withdrawn) == started.map (·.1) &&
              (← rig.services.completions.waiting) == 0 &&
              (← rig.clock.now) == 0
        finally
          starting.resolve ()
          job.handle.cancel },
    { name :=
        "cancellation is looked for again when a wait has ended: a job cancelled as its wait completes is not continued"
      run := do
        let rig ← Rig.new
        let gate : IO.Promise Unit ← IO.Promise.new
        let starting ← rig.clock.holdStarts
        let job ←
          rig.spawn
              (reporting fun _ => do
                let instant ← now
                -- Due already: the clock completes it as soon as it is asked.
                waitUntil instant
                waitUntil (onceOpen gate instant + 10)
                return true)
        try
          unless ← eventually (return (← rig.clock.held) == 1) do
            return false
          -- Cancelled before the clock knows the wait, which then completes
          -- at once: the completion wins, and the job's token is set.
          job.handle.cancel
          starting.resolve ()
          let cancelled ← job.endedAs .cancelled
          return cancelled && !(← gate.isResolved) && (← rig.clock.started).size == 1 &&
              (← rig.clock.withdrawn).isEmpty
        finally
          starting.resolve ()
          gate.resolve ()
          job.handle.cancel },
    { name :=
        "cancelling a job that has ended, and cancelling a job twice, change nothing: the outcome stays, the runner said so once, and the wait was withdrawn once"
      run := do
        let rig ← Rig.new
        let short ←
          rig.spawn
              (reporting fun _ => do
                sleep 5
                return 7)
        let sleeper ←
          rig.spawn
              (reporting fun _ => do
                sleep 1000
                return true)
        try
          unless ← eventually (return (← rig.clock.waiting) == 2) do
            return false
          rig.clock.advance 5
          unless ← short.endedAs (.finished #["7"]) do
            return false
          short.handle.cancel
          sleeper.handle.cancel
          sleeper.handle.cancel
          return (← sleeper.endedAs .cancelled) && (← short.endedAs (.finished #["7"])) &&
              (← rig.clock.withdrawn).size == 1 &&
              (← rig.services.completions.waiting) == 0
        finally
          short.handle.cancel
          sleeper.handle.cancel },
    { name :=
        "over shared environments, a job's record of a failure reaches the report once, a second job finds the first one's entry, and no environment request registers a wait"
      run := do
        let rig ← Rig.new
        let state ← IO.mkRef ({} : Process.Environments)
        let said ← IO.mkRef #[]
        let rig :=
          { rig with
            services :=
              { rig.services with
                environments :=
                  Job.sharedEnvironments state fun text => said.modify (·.push text) } }
        let failure := Process.Failure.exited 1 "untrusted"
        let entry : Process.Entry := { stamps := #[none], found := .failed failure }
        let first ←
          rig.spawn
              (reporting fun _ => do
                Process.askEnvironment (.record "/p/d" entry)
                Process.askEnvironment (.record "/p/d" entry)
                return true)
        let firstEnded ← first.endedAs (.finished #["true"])
        let second ←
          rig.spawn
              (reporting fun _ => do
                let found : Option Process.Entry ← Process.askEnvironment (.cached "/p/d")
                return found == some entry)
        let secondEnded ← second.endedAs (.finished #["true"])
        return firstEnded && secondEnded &&
            (← said.get) == #[Process.failureMessage "/p/d" failure] &&
            (← rig.services.completions.waiting) == 0 &&
            (← rig.clock.started).isEmpty },
    { name :=
        "a runner given no environments answers the policy as inherited: auto in the headless mode"
      run := do
        let rig ← Rig.new
        let job ←
          rig.spawn
              (reporting fun _ => do
                let policy : Process.Policy ← Process.askEnvironment .policy
                return policy ==
                    { setting := .auto, host := .headless, resolved := none, limit := 5000 })
        job.endedAs (.finished #["true"]) },
    { name :=
        "a job cancelled in a wait after one post makes no second post: its host is handed the first alone, and it ends cancelled"
      run := do
        let rig ← Rig.new
        let posts ← IO.mkRef #[]
        let work :=
          Work.of
            (fun _ => do
              post (JobContract.posting "first")
              sleep 1000
              post (JobContract.posting "second"))
            fun _ => pure ()
        let handle ←
          Job.spawn rig.services work (pure ()) fun invocation => posts.modify (·.push invocation)
        unless ← eventually (return (← rig.clock.waiting) == 1) do
          return false
        let before ← posts.get
        handle.cancel
        let ended ← eventually handle.ended
        rig.clock.advance 1000
        return before == #[JobContract.posting "first"] && ended &&
            (← posts.get) == #[JobContract.posting "first"] &&
            (← handle.outcome?).map texts == some .cancelled }]

/-- A model with the directory `fileRoot` and, in it, `a.txt` holding
`JobContract.rawFile`, seventeen bytes, and `b.txt` holding
`JobContract.otherFile`, twelve. -/
def twoFiles : FileModel :=
  ((({} : FileModel).withDirectory fileRoot).withFile (fileRoot / "a.txt")
        JobContract.rawFile).withFile
    (fileRoot / "b.txt") JobContract.otherFile

/-- What the editor has published, in the checks below: one snapshot, of a
text with a two-byte character and an escape. Saved, it is the seven bytes
`pubBytes`. -/
def pubContent : TextContent :=
  { contents := "pub é".push (Char.ofNat 0x10DCFF), revision := 2 }

/-- The bytes `pubContent` is saved as, written out by hand. -/
def pubBytes : ByteArray :=
  ⟨#[0x70, 0x75, 0x62, 0x20, 0xC3, 0xA9, 0xFF]⟩

/-- Whether `reply` is a refusal as failed, whatever its detail. -/
def isFailed {α : Type} (reply : Except FileError α) : Bool :=
  match reply with
  | .error (.failed _) => true
  | _ => false

/-- The bytes of the file `name` of `fileRoot` in the fake's model, if it is
there. -/
def fileOf (files : Job.FakeFiles) (name : String) : BaseIO (Option ByteArray) :=
  return ((← files.model).file? (fileRoot / name)).map (·.bytes)

/-- The checks of the job runner's file waits (`Editor/Job/Runner.lean`),
each on a fake of the file service of its own (`Job.FakeFiles`,
`Editor/Job/Fake.lean`), over a model of two files. A check holds what it
controls (the service's completions, its takes, a clock) and polls only as
the bound after which it fails. -/
def fileRunnerChecks : List Check :=
  [{  name :=
        "a file request handed through the services whose wait is withdrawn ends with the withdrawn reply, and nothing is taken for it"
      run := do
        let (rig, files) ← Rig.withFiles twoFiles
        files.holdCompletions
        let request : FileRequest := .append (fileRoot / "a.txt") "w".toUTF8
        let task ← rig.services.fileWorked request
        -- The id of the request's wait, as the fake recorded its start.
        let some (id, _) := (← files.started).back? | return false
        let early ← IO.hasFinished task
        rig.services.completions.finish id .cancelled
        let some reply ← Job.awaitWithin 10000 task | return false
        files.letGo
        let withdrawn :=
          match (reply : Except FileError Unit),
            (Job.Files.withdrawnReply request : Except FileError Unit) with
          | .error (.failed said), .error (.failed expected) => said == expected
          | _, _ => false
        -- The fake's take was never asked: the request is still its pending.
        return !early && withdrawn && (← files.waiting) == 1 },
    {
      name :=
        "cancelling a job in a file wait withdraws the wait and ends the job cancelled, and its save never happens: no file is written, then or when the service lets go",
      run := do
        let (rig, files) ← Rig.withFiles twoFiles
        files.publish #[some pubContent]
        files.holdCompletions
        let saver ←
          rig.spawn
              (reporting fun _ => do
                return (← JobContract.saved (.snapshot ⟨0⟩) (fileRoot / "new.txt") .absent).size)
        try
          unless ← eventually (return (← files.waiting) == 1) do
            return false
          let started := (← files.started).map (·.1)
          saver.handle.cancel
          let cancelled ← saver.endedAs .cancelled
          let withdrawn := (← files.withdrawn) == started && (← files.waiting) == 0
          let forgotten := (← rig.services.completions.waiting) == 0
          files.letGo
          return cancelled && started.size == 1 && withdrawn && forgotten &&
              (← fileOf files "new.txt").isNone
        finally
          saver.handle.cancel
          files.letGo },
    { name :=
        "a job cancelled as its load completes is not continued, and what it loaded is released: cancelled while the reply is being fetched, it ends cancelled, and the snapshot the load made is given up"
      run := do
        let (rig, files) ← Rig.withFiles twoFiles
        let hold ← files.holdTakes
        let loader ←
          rig.spawn
              (reporting fun _ => do
                let file ← JobContract.loaded (fileRoot / "a.txt")
                -- Never reached: the job is cancelled before the reply is
                -- handed to it.
                return (←
                      JobContract.saved (.held file.snapshot) (fileRoot / "new.txt") .absent).size)
        try
          unless ← eventually (return (← files.takesHeld) == 1) do
            return false
          loader.handle.cancel
          hold.resolve ()
          let cancelled ← loader.endedAs .cancelled
          return cancelled && (← files.released) == #[⟨0⟩] && (← files.model).held == #[none] &&
              (← loader.handle.holding).isEmpty &&
              (← files.started).size == 1 &&
              (← fileOf files "new.txt").isNone
        finally
          hold.resolve ()
          loader.handle.cancel },
    { name :=
        "what a job loaded is the runner's to release: a job that fails after a load has its snapshot released with no call from here, and one that finishes keeps it until it is settled, once"
      run := do
        let (rig, files) ← Rig.withFiles twoFiles
        let fails ←
          rig.spawn fun _ => do
              discard <| JobContract.loaded (fileRoot / "a.txt")
              throw "no thanks"
        let failed ← fails.endedAs (.failed "no thanks")
        let afterFailure ← files.released
        let finishes ←
          rig.spawn
              (reporting fun _ => do
                discard <| JobContract.loaded (fileRoot / "a.txt")
                return (← JobContract.loaded (fileRoot / "b.txt")).stamp.size)
        let finished ← finishes.endedAs (.finished #["12"])
        let kept ← files.released
        let holding ← finishes.handle.holding
        finishes.handle.settle
        let settled ← files.released
        finishes.handle.settle
        return failed && afterFailure == #[⟨0⟩] && finished && kept == #[⟨0⟩] &&
            holding == #[⟨1⟩, ⟨2⟩] &&
            settled == #[⟨0⟩, ⟨1⟩, ⟨2⟩] &&
            (← files.released) == settled &&
            (← finishes.handle.holding).isEmpty &&
            (← files.model).held == #[none, none, none] },
    { name :=
        "removing an owner releases what its finished job loaded though the job's command never ran, and so does cancelling every job"
      run := do
        let (rig, files) ← Rig.withFiles twoFiles
        let woken ← IO.mkRef #[]
        let finished (id : Nat) : BaseIO Unit := woken.modify (·.push id)
        let loads : Work :=
          reporting fun _ => do
            return (← JobContract.loaded (fileRoot / "a.txt")).stamp.size
        let jobs : Job.Jobs := { services := rig.services }
        let (annas, jobs) ← jobs.start anna "loads" loads finished
        unless ← eventually (return (← woken.get) == #[annas]) do
          return false
        let before ← files.released
        let (removed, jobs) ← jobs.removeOwner anna
        let afterRemoval ← files.released
        let (bens, jobs) ← jobs.start ben "loads" loads finished
        unless ← eventually (return (← woken.get) == #[annas, bens]) do
          return false
        jobs.cancelAll
        return before.isEmpty && removed.map (·.id) == #[annas] && afterRemoval == #[⟨0⟩] &&
            (← files.released) == #[⟨0⟩, ⟨1⟩] &&
            (← files.model).held == #[none, none] },
    { name :=
        "a job cannot save what another job holds: with one job parked after its load, a second that saves that job's snapshot is refused as naming none, and the service is asked to start nothing for it"
      run := do
        let (rig, files) ← Rig.withFiles twoFiles
        let holder ←
          rig.spawn
              (reporting fun _ => do
                discard <| JobContract.loaded (fileRoot / "a.txt")
                sleep 1000
                return true)
        try
          unless ← eventually (return (← rig.clock.waiting) == 1) do
            return false
          let #[theirs] ← holder.handle.holding | return false
          let thief ←
            rig.spawn
                (reporting fun _ =>
                  JobContract.saveRefusedAs .noSuchSnapshot (.held theirs) (fileRoot / "new.txt")
                    .absent)
          let refused ← thief.endedAs (.finished #["true"])
          return refused && (← files.started).size == 1 && (← fileOf files "new.txt").isNone &&
              (← holder.handle.holding) == #[theirs]
        finally
          holder.handle.cancel },
    { name :=
        "a save of a snapshot the editor published finds it by its id when the save is made: one published before the job began, one published after, and none for one taken away since"
      run := do
        let (rig, files) ← Rig.withFiles twoFiles
        files.publish #[some pubContent]
        let saver ←
          rig.spawn
              (reporting fun _ => do
                let early ← JobContract.saved (.snapshot ⟨0⟩) (fileRoot / "early.txt") .absent
                sleep 10
                let late ← JobContract.saved (.snapshot ⟨1⟩) (fileRoot / "late.txt") .absent
                sleep 10
                let gone ←
                  JobContract.saveRefusedAs .noSuchSnapshot (.snapshot ⟨0⟩) (fileRoot / "gone.txt")
                      .absent
                return early.size == 7 && late.size == 4 && gone)
        try
          unless ← eventually (return (← rig.clock.waiting) == 1) do
            return false
          files.publish #[some pubContent, some { contents := "lé\n" }]
          rig.clock.advance 10
          unless ← eventually (return (← rig.clock.waiting) == 1) do
            return false
          files.publish #[none, some { contents := "lé\n" }]
          rig.clock.advance 10
          let held ← saver.endedAs (.finished #["true"])
          return held && (← fileOf files "early.txt") == some pubBytes &&
              (← fileOf files "late.txt") == some ⟨#[0x6C, 0xC3, 0xA9, 0x0A]⟩ &&
              (← fileOf files "gone.txt").isNone
        finally
          saver.handle.cancel },
    { name :=
        "on a runner that was given no file service a load and a save are refused as failed, and the job goes on to finish"
      run := do
        let rig ← Rig.new
        let asks ←
          rig.spawn
              (reporting fun _ => do
                let load ← File.load (fileRoot / "a.txt") 1000
                let save ← File.save (.snapshot ⟨0⟩) (fileRoot / "b.txt") .whatever
                return isFailed load && isFailed save && (← now) == 0)
        return (← asks.endedAs (.finished #["true"])) &&
            (← rig.services.completions.waiting) == 0 }]

/-- A watch model with `watchRoot` there, for the runner's watch checks. -/
def rootWatches : FileWatchModel :=
  { directories := #[watchRoot] }

/-- A job that watches `watchRoot / "f"` and then sleeps for `ms`. -/
def watchesThenSleeps (ms : Nat) : JobM Bool := do
  let .ok _ ← FileWatch.start (.file (watchRoot / "f")) atOnce | return false
  sleep ms
  return true

/-- The checks of the runner's watch waits, on the fake of the watch
service: a watch is named for its job, it ends with its job however the job
ends, a cancelled job's pending read is withdrawn, and removing an owner
ends its jobs' watches. -/
def fileWatchRunnerChecks : List Check :=
  [{  name := "a watch is named for its job: another job's next of it is noSuchWatch, asked of no service"
      run := do
        let (rig, _, watches) ← Rig.withWatches {} rootWatches
        let holder ← rig.spawn (reporting fun _ => watchesThenSleeps 1000)
        unless ← eventually (return (← watches.watching) == 1) do
          return false
        let id := ((← watches.started)[0]?.map (·.1)).getD 0
        let other ←
          rig.spawn
              (reporting fun _ => do
                let .error .noSuchWatch ← FileWatch.next ⟨id.toNat⟩ | return false
                return true)
        let refused ← other.endedAs (.finished #["true"])
        holder.handle.cancel
        let asked :=
          (← watches.started).any fun (_, request) =>
            match request with
            | .next _ => true
            | _ => false
        return refused && !asked },
    { name := "a watch ends with its job, finished, failed or cancelled, through the watch service's cancel"
      run := do
        let (rig, _, watches) ← Rig.withWatches {} rootWatches
        let finished ← rig.spawn (reporting fun _ => watchesThenSleeps 0)
        let failed ←
          rig.spawn
              (reporting fun _ => (do
                discard <| watchesThenSleeps 0
                throw "failed" : JobM Bool))
        let cancelled ← rig.spawn (reporting fun _ => watchesThenSleeps 1000000)
        let ended ←
          (return (← finished.endedAs (.finished #["true"])) && (← failed.endedAs (.failed "failed")))
        unless ← eventually (return (← watches.watching) == 1) do
          return false
        cancelled.handle.cancel
        let cancelledEnded ← cancelled.endedAs .cancelled
        let ids := (← watches.started).map (·.1)
        return ended && cancelledEnded && (← watches.watching) == 0 &&
            (← watches.ended).qsort (· < ·) == (ids.map (·.toNat)).qsort (· < ·) &&
            ids.all (← watches.withdrawn).contains },
    { name := "a cancelled job's pending next is withdrawn from the watch service, and its watch ended"
      run := do
        let (rig, _, watches) ← Rig.withWatches {} rootWatches
        let spawned ←
          rig.spawn
              (reporting fun _ => do
                let .ok watch ← FileWatch.start (.file (watchRoot / "f")) atOnce | return false
                discard <| FileWatch.next watch
                return true)
        unless ← eventually (return (← watches.started).size == 2) do
          return false
        let started ← watches.started
        spawned.handle.cancel
        let ended ← spawned.endedAs .cancelled
        let withdrawn ← watches.withdrawn
        return ended && started.all (withdrawn.contains ·.1) && (← watches.watching) == 0 &&
            (← watches.waiting) == 0 },
    { name := "Jobs.removeOwner ends the watches of the owner's jobs, and leaves another owner's"
      run := do
        let (rig, _, watches) ← Rig.withWatches {} rootWatches
        let sleeps : Work := reporting fun _ => watchesThenSleeps 1000000
        let jobs : Job.Jobs := { services := rig.services }
        let (_, jobs) ← jobs.start anna "watches" sleeps fun _ => pure ()
        let (_, jobs) ← jobs.start ben "watches" sleeps fun _ => pure ()
        unless ← eventually (return (← watches.watching) == 2) do
          return false
        let (_, jobs) ← jobs.removeOwner anna
        let annasEnded ← eventually (return (← watches.watching) == 1)
        let one := (← watches.ended).size == 1
        jobs.cancelAll
        let allEnded ← eventually (return (← watches.watching) == 0)
        return annasEnded && one && allEnded }]

/-- The checks of the runner's grep port on the fake file service, whose
model answers a search: a search is named for its job, and it does not
outlive the job. -/
def grepRunnerChecks : List Check :=
  [{  name :=
        "a cancelled job's search is cancelled through the grep service, and another job's next of it is noSuchSearch"
      run := do
        let (rig, files) ←
          Rig.withFiles
              ((({} : FileModel).withDirectory fileRoot).withFile (fileRoot / "a") "x".toUTF8)
        let spawned ←
          rig.spawn
              (reporting fun _ => do
                let .ok _ ← Grep.start fileRoot "x" #[] { files := 9, found := 9 } 9 | return false
                sleep 1000000
                return true)
        unless ← eventually (return (← files.searching) == 1) do
          return false
        let id := ((← files.grepsStarted)[0]?.map (·.1)).getD 0
        let other ←
          rig.spawn
              (reporting fun _ => do
                let .error .noSuchSearch ← Grep.next ⟨id.toNat⟩ | return false
                return true)
        let refused ← other.endedAs (.finished #["true"])
        spawned.handle.cancel
        let cancelled ← spawned.endedAs .cancelled
        return refused && cancelled && (← files.searching) == 0 &&
            (← files.grepsCancelled) == #[id] }]

/-- `true` when `holds`, and otherwise what the check saw, thrown, so its
failure says it. -/
def saw (holds : Bool) (observed : String) : IO Bool := do
  unless holds do
    throw <| IO.userError s!"saw {observed}"
  return true

/-- `rig`, its services keeping a count of their activity
(`Job.Activity.counting`), and that count. -/
def _root_.Editor.Test.Rig.counted (rig : Rig) : BaseIO (Rig × Job.Activity) := do
  let activity ← Job.Activity.counting
  return ({ rig with services := { rig.services with activity } }, activity)

/-- `activity`, noting in `log`, at each `begin` and each `done`, the count
it left and the thread that called it. A check reads the log of one job,
whose steps follow one another, so each entry is the count that step left. -/
def recorded (activity : Job.Activity) (log : IO.Ref (Array (Nat × UInt64))) : Job.Activity :=
  { activity with
    begin := do
      activity.begin
      let seen ← activity.seen
      log.modify (·.push (seen.running, ← IO.getTID))
    done := do
      activity.done
      let seen ← activity.seen
      log.modify (·.push (seen.running, ← IO.getTID)) }

/-- The count `activity` reads at its next change after `seen`, waited for on
the change itself (`changedSince`). The bound is a hang guard, never a
result: past it this throws a hang. -/
def changedAfter (activity : Job.Activity) (seen : Job.Activity.Seen) : IO Job.Activity.Seen := do
  let some () ←
    Job.awaitWithin patience
        (←
          activity.changedSince
              seen.epoch) | throw <| IO.userError s!"a hang: the count had not changed from {repr seen} within {patience} ms"
  activity.seen

/-- Waits, on the count's own changes, until `activity`'s epoch has reached
`epoch`: the steps a check knows will come, counted from a fresh count, so
it never waits for a change that already happened. The bound is a hang
guard, never a result: past it this throws a hang. -/
def untilEpoch (activity : Job.Activity) (epoch : Nat) : IO Unit := do
  repeat
    let seen ← activity.seen
    if seen.epoch >= epoch then
      return
    discard <| changedAfter activity seen
  throw <| IO.userError "unreachable"

/-- The checks of the runner's activity accounting (`Editor/Job/Runner.lean`,
"Activity"), each on a fake clock of its own and a count of its own: a job
holds a unit while it can run, a wait only a test ends (the fake clock's)
holds none, and a wait on a service that ends it by itself holds the job's.
A check waits on the count's own changes (`changedAfter`), and holds the
port (`holdReads`, held completions) to look while a step is in flight. -/
def activityRunnerChecks : List Check :=
  [{  name :=
        "a job on the fake clock holds a unit from its spawn until its sleep is in the clock, then none; once the clock is moved past it holds one again until it has ended, and none once its finished has run"
      run := do
        let (rig, counted) ← (← Rig.new).counted
        let log ← IO.mkRef #[]
        let activity := recorded counted log
        let rig := { rig with services := { rig.services with activity } }
        let spawned ←
          rig.spawn
              (reporting fun _ => do
                sleep 10
                return 1)
        -- The spawn's step, then the park's: the sleep is in the clock.
        untilEpoch activity 2
        let waiting ← rig.clock.waiting
        rig.clock.advance 10
        -- The wake's step, on this thread, then the end's.
        untilEpoch activity 4
        let finishes ← spawned.finishes.get
        let outcome ← spawned.outcome
        let counts := (← log.get).map (·.1)
        saw
            (counts == #[1, 0, 1, 0] && waiting == 1 && finishes == 1 &&
              outcome == some (.finished #["1"]) &&
              (← activity.refused) == 0)
            s!"counts={counts} waiting={waiting} finishes={finishes}" },
    { name :=
        "a job whose sleep the clock ends is runnable from the wait's end: its unit is taken on the thread that moves the clock, before the job runs, and held while its next request is in flight, until its next sleep is in the clock"
      run := do
        let (rig, counted) ← (← Rig.new).counted
        let log ← IO.mkRef #[]
        let activity := recorded counted log
        let rig := { rig with services := { rig.services with activity } }
        let spawned ←
          rig.spawn
              (reporting fun _ => do
                sleep 10
                sleep 10
                return 2)
        untilEpoch activity 2
        let parked ← activity.seen
        -- The second sleep's reading of the clock is held: the job is
        -- runnable, inside a request, until the check lets it go.
        let hold ← rig.clock.holdReads
        log.set #[]
        rig.clock.advance 10
        let woken ← log.get
        let held ← activity.seen
        hold.resolve ()
        let again ← changedAfter activity held
        let waiting ← rig.clock.waiting
        rig.clock.advance 10
        let ended ← spawned.endedAs (.finished #["2"])
        let here ← IO.getTID
        saw
            (parked.running == 0 && woken == #[(1, here)] && held.running == 1 &&
              again.running == 0 &&
              waiting == 1 &&
              ended &&
              (← activity.refused) == 0)
            s!"parked={repr parked} woken={woken} here={here} held={repr held} again={repr again} waiting={waiting} ended={ended}" },
    { name :=
        "a sleep already due is ended inside its start: the count goes from 1 to 2 and back to 1 as the job enters it, and never reads 0 before the job has ended"
      run := do
        let (rig, counted) ← (← Rig.new).counted
        let log ← IO.mkRef #[]
        let activity := recorded counted log
        let rig := { rig with services := { rig.services with activity } }
        let spawned ←
          rig.spawn
              (reporting fun _ => do
                sleep 0
                return 0)
        let ended ← spawned.endedAs (.finished #["0"])
        let counts := (← log.get).map (·.1)
        saw (ended && counts == #[1, 2, 1, 0] && (← activity.refused) == 0) s!"counts={counts}" },
    { name :=
        "cancelling a job parked on the fake clock gives back exactly one unit: the count is 0 once it has concluded, and no done ever arrived with nothing held"
      run := do
        let (rig, counted) ← (← Rig.new).counted
        let log ← IO.mkRef #[]
        let activity := recorded counted log
        let rig := { rig with services := { rig.services with activity } }
        let spawned ←
          rig.spawn
              (reporting fun _ => do
                sleep 10
                return 0)
        untilEpoch activity 2
        spawned.handle.cancel
        let cancelled ← spawned.endedAs .cancelled
        let counts := (← log.get).map (·.1)
        saw
            (cancelled && counts == #[1, 0, 1, 0] && (← activity.seen).running == 0 &&
              (← activity.refused) == 0)
            s!"cancelled={cancelled} counts={counts} refused={← activity.refused}" },
    { name :=
        "a job's load on a file service that ends it by itself holds the job's unit while the service holds it, and none once it has been let go and the job has ended"
      run := do
        let (rig, files) ← Rig.withFiles twoFiles
        let (rig, activity) ← rig.counted
        let started ← IO.Promise.new
        let rig :=
          { rig with
            services :=
              { rig.services with
                files :=
                  { files.files with
                    start := fun id request => do
                      files.start id request
                      started.resolve () } } }
        files.holdCompletions
        let spawned ←
          rig.spawn
              (reporting fun _ => do
                let loaded ← File.load (fileRoot / "a.txt") 100
                return loaded.isOk)
        try
          let some _ ←
            Job.awaitWithin patience
                started.result? | throw <| IO.userError s!"a hang: the load had not started within {patience} ms"
          let held ← activity.seen
          let inFlight ← files.waiting
          files.letGo
          let ended ← changedAfter activity held
          let finished ← spawned.endedAs (.finished #["true"])
          saw
              (held.running == 1 && inFlight == 1 && ended.running == 0 && finished &&
                (← activity.refused) == 0)
              s!"held={repr held} inFlight={inFlight} ended={repr ended} finished={finished}"
        finally
          spawned.handle.cancel
          files.letGo },
    { name :=
        "a job in a next of a fake watch holds no unit: it holds one from its spawn until its next is parked, none while parked, and once the test's change answers it one again until it has ended, then none, with no done refused"
      run := do
        let (rig, _, watches) ← Rig.withWatches {} rootWatches
        let (rig, counted) ← rig.counted
        let log ← IO.mkRef #[]
        let activity := recorded counted log
        let rig := { rig with services := { rig.services with activity } }
        let spawned ←
          rig.spawn
              (reporting fun _ => do
                let .ok watch ← FileWatch.start (.file (watchRoot / "f")) atOnce | return false
                let .ok _ ← FileWatch.next watch | return false
                return true)
        -- The spawn's step, then the park in the next: the start was answered
        -- inside its own request, the job keeping its unit.
        untilEpoch activity 2
        let parked ← activity.seen
        watches.change (watchRoot / "f") #[.written]
        -- The change's step, on this thread, then the end's.
        untilEpoch activity 4
        let ended ← spawned.endedAs (.finished #["true"])
        let counts := (← log.get).map (·.1)
        saw (parked.running == 0 && counts == #[1, 0, 1, 0] && ended && (← activity.refused) == 0)
            s!"parked={repr parked} counts={counts} ended={ended}" }]

end ModelTest
