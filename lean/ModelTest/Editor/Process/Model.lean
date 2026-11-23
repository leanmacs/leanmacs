import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Invocation
import Editor.Job
import Editor.Job.Contract
import Editor.Job.Fake
import Editor.Job.Model
import Editor.Job.Runner
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.Test.Jobs
import Editor.Text.Model
import ModelTest.Check

/-!
# Model tests: `Editor/Process/Model.lean`

The model tests of `Editor/Process/Model.lean`: `processChecks`. `processChecks`
also run the job runner's process waits on the fake of the process service; they
are here because they start with the model's refusals and record. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A command that sleeps for ten minutes in `processRoot`, as the process
checks script it. -/
def sleeper : Process.Command :=
  JobContract.sh processRoot "/bin/sleep 600"

/-- The script of `sleeper`, which takes `takes` milliseconds. -/
def sleeperScript (takes : Nat) : Process.Script :=
  { command := sleeper, reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty },
    takes }

/-- What the process model answers a run of `command` under `limit` made at
`now` by a job cancelled at `cancelAt`, with the reply's type spelled out. -/
def modelRun (model : ProcessModel) (now : Nat) (cancelAt : Option Nat) (command : Process.Command)
    (limit : Nat) : Except ProcessError Process.Ran × ProcessModel × Nat :=
  model.handle now cancelAt (.run command limit)

-- inferred-waits W32: stays (the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle)
set_option linter.inferredWait false in
/-- A check of `processChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def cancellingJobProcessWaitCheck : Check :=
  { name :=
      "cancelling a job in a process wait withdraws the wait from the process service with the wait's id, the job ends cancelled, and it makes no further request"
    run := do
      let (rig, processes) ← Rig.withProcesses { scripts := #[sleeperScript 0] }
      processes.holdCompletions
      -- A held run keeps its job's unit: the check waits for its start to
      -- reach the fake.
      let (start, runStarted) ← startGate processes.processes.start 1
      let rig :=
        { rig with
          services := { rig.services with processes := { processes.processes with start } } }
      let spawned ←
        rig.spawn
            (reporting fun _ => do
              discard <| Process.run sleeper 10
              discard <| Process.run sleeper 10
              return true)
      try
        discard <| awaitEvent "the run's start" runStarted.result?
        unless (← processes.waiting) == 1 do
          return false
        let id := ((← processes.started)[0]?.map (·.1)).getD 0
        spawned.handle.cancel
        let cancelled ← spawned.endedAs .cancelled
        processes.letGo
        return cancelled && (← processes.withdrawn) == #[id] && (← processes.started).size == 1 &&
            (← processes.taken).isEmpty &&
            (← processes.waiting) == 0
      finally
        processes.letGo }

-- inferred-waits W32: stays (the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle)
set_option linter.inferredWait false in
/-- A check of `processChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def runnerGivenProcessServiceCheck : Check :=
  { name :=
      "a runner given no process service refuses a run as failed, as a value, and the job goes on"
    run := do
      let rig ← Rig.new
      let spawned ←
        rig.spawn
            (reporting fun _ => do
              let .error (.failed _) ← Process.run sleeper 10 | return false
              return true)
      spawned.endedAs (.finished #["true"]) }

-- inferred-waits W32: stays (the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle)
set_option linter.inferredWait false in
/-- A check of `processChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def readDeliversLineChildCheck : Check :=
  { name :=
      "one read delivers every line a child wrote before it waits on its input, on the model and on the fake, where the read is one start and one take: one completion"
    run := do
      let script : Process.StreamScript :=
        { command := sleeper, steps := #[.write .out (JobContract.counted 1000), .awaitClosed] }
      let expected := (List.range 1000).toArray.map fun n => s!"{n}".toUTF8
      let job : JobM Bool := do
        let child ← JobContract.started sleeper (JobContract.lines 1000000 true)
        let delivery ← JobContract.delivered child
        return JobContract.linesOf #[delivery] .out == expected && delivery.ended.isNone
      let (onModel, _) := job.runModel { processes := { streams := #[script] } }
      let (rig, processes) ← Rig.withProcesses { streams := #[script] }
      let onFake ← runOnFake job (some rig)
      let reads :=
        (← processes.started).filterMap fun (id, request) =>
          match request with
          | .read _ => some id
          | _ => none
      return onModel == .finished true && onFake == .finished true && reads.size == 1 &&
          ((← processes.taken).filter reads.contains).size == 1 }

-- inferred-waits W32: stays (the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle)
set_option linter.inferredWait false in
/-- A check of `processChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def childLastDeliveryRunnerCheck : Check :=
  { name :=
      "after a child's last delivery the runner forgets it: a later read, write or close is noSuchProcess, answered without a request to the process service"
    run := do
      let script : Process.StreamScript :=
        { command := sleeper, steps := #[.write .out "a\n".toUTF8] }
      let (rig, processes) ← Rig.withProcesses { streams := #[script] }
      let noSuchProcess {α : Type} : Except ProcessError α → Bool
        | .error .noSuchProcess => true
        | _ => false
      let spawned ←
        rig.spawn
            (reporting fun _ => do
              let child ← JobContract.started sleeper (JobContract.lines 64)
              let all ← JobContract.toTheEnd child
              let read ← Process.read child
              let write ← Process.write child "late".toUTF8
              let close ← Process.closeInput child
              return JobContract.linesOf all .out == JobContract.linesFrom ["a"] &&
                  JobContract.endOf all == some (.exited (.code 0)) &&
                  noSuchProcess read &&
                  noSuchProcess write &&
                  noSuchProcess close)
      let finished ← spawned.endedAs (.finished #["true"])
      let kinds :=
        (← processes.started).map fun (_, request) =>
          match request with
          | .start _ _ => "start"
          | .read _ => "read"
          | .write _ _ => "write"
          | .closeInput _ => "closeInput"
          | .run _ _ => "run"
          | .runWithin .. => "runWithin"
          | .runInput .. => "runInput"
          | .runHead .. => "runHead"
      return finished && kinds == #["start", "read"] && (← processes.withdrawn).isEmpty }

-- inferred-waits W32: stays (the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle)
set_option linter.inferredWait false in
/-- A check of `processChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def jobEndsStreamingChildCheck : Check :=
  { name :=
      "a job that ends with a streaming child running, finished, failed or cancelled, cancels the child: the fake withdraws its id, and the model, the fake's and the job model's, records it killed"
    run := do
      let script : Process.StreamScript := { command := sleeper, steps := #[.awaitClosed] }
      let starts : JobM Unit := discard <| JobContract.started sleeper (JobContract.lines 64 true)
      let jobs : List (JobM Bool × Bool) :=
        [((do
              starts;
              return true),
            false),
          ((do
              starts;
              throw "it fails"),
            false),
          ((do
              starts;
              sleep 1000;
              return true),
            true)]
      let results ←
        jobs.mapM fun (job, cancel) => do
            let (rig, processes) ← Rig.withProcesses { streams := #[script] }
            let spawned ← rig.spawn (reporting fun _ => job)
            if cancel then
              discard <| rig.idle
              unless (← rig.clock.waiting) == 1 do
                return false
              spawned.handle.cancel
            discard <| awaitEvent "the job's end" spawned.handle.outcome.result?
            let child := ((← processes.started)[0]?.map (·.1)).getD 0
            let model ← processes.model
            return (← processes.withdrawn) == #[child] && model.killed == #[sleeper] &&
                model.children.isEmpty
      let (_, model) :=
        (do
              starts;
              return true : JobM Bool).runModel
          { processes := { streams := #[script] } }
      return results.all id && model.processes.killed == #[sleeper] &&
          model.processes.children.isEmpty }

-- inferred-waits W32: stays (the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle)
set_option linter.inferredWait false in
/-- A check of `processChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def cancellingJobPendingReadCheck : Check :=
  { name := "cancelling a job in a pending read withdraws the read's wait and then its child"
    run := do
      let script : Process.StreamScript := { command := sleeper, steps := #[.awaitClosed] }
      let (rig, processes) ← Rig.withProcesses { streams := #[script] }
      -- The child's start, then the read's: a held read keeps its job's
      -- unit, so the check waits for the second start to reach the fake.
      let (start, readStarted) ← startGate processes.processes.start 2
      let rig :=
        { rig with
          services := { rig.services with processes := { processes.processes with start } } }
      let spawned ←
        rig.spawn
            (reporting fun _ => do
              let child ← JobContract.started sleeper (JobContract.lines 64 true)
              sleep 10
              discard <| Process.read child
              return true)
      discard <| rig.idle
      unless (← rig.clock.waiting) == 1 do
        return false
      processes.holdCompletions
      rig.clock.advance 10
      try
        discard <| awaitEvent "the read's start" readStarted.result?
        unless (← processes.waiting) == 1 do
          return false
        let started ← processes.started
        let child := (started[0]?.map (·.1)).getD 0
        let read := (started[1]?.map (·.1)).getD 0
        spawned.handle.cancel
        let cancelled ← spawned.endedAs .cancelled
        return cancelled && (← processes.withdrawn) == #[read, child] &&
            (← processes.model).killed == #[sleeper]
      finally
        processes.letGo }

/-- The checks of processes a job runs: the model's order of refusals and its
record of what was killed, and the runner's process waits on the fake of the
process service, where cancelling a job withdraws its wait, which is how the
library comes to kill the job's child. -/
def processChecks : List Check :=
  [{  name :=
        "the process model refuses a relative directory, then a relative program, then an unscripted command as not found, and starts none of them"
      run := do
        let model : ProcessModel := { scripts := #[sleeperScript 0] }
        let ask (command : Process.Command) := modelRun model 0 none command 10
        let (directory, afterDirectory, _) := ask { program := "bin/sh", directory := "relative" }
        let (program, afterProgram, _) := ask { program := "bin/sh", directory := processRoot }
        let (unscripted, afterUnscripted, _) :=
          ask { program := "/bin/sh", directory := processRoot }
        let isNotFound :=
          match unscripted with
          | .error (.notFound _) => true
          | _ => false
        return directory == .error .relativeDirectory && program == .error .relativeProgram &&
            isNotFound &&
            [afterDirectory, afterProgram, afterUnscripted].all (·.started.isEmpty) },
    { name :=
        "the process model records a scripted run as started, moves the clock by its time, and answers too large past the limit, standard output first"
      run := do
        let ran : Process.Ran :=
          { exit := .code 0, stdout := "123456".toUTF8, stderr := "123456".toUTF8 }
        let model : ProcessModel :=
          { scripts := #[{ command := sleeper, reply := .ok ran, takes := 7 }] }
        let (atBound, after, now) := modelRun model 3 none sleeper 6
        let (over, _, _) := modelRun model 3 none sleeper 5
        let quiet : ProcessModel :=
          {
            scripts :=
              #[{ command := sleeper, reply := .ok { ran with stdout := .empty }, takes := 7 }] }
        let (err, _, _) := modelRun quiet 3 none sleeper 5
        return atBound == .ok ran && after.started == #[sleeper] && now == 10 &&
            over == .error (.outputTooLarge .out 5) &&
            err == .error (.outputTooLarge .err 5) &&
            after.killed.isEmpty },
    { name :=
        "a job model cancelled inside a scripted run is cancelled at that instant, and the process model records the command as killed"
      run := do
        let job : JobM Bool := do
          discard <| Process.run sleeper 10
          return true
        let (outcome, model) :=
          job.runModel { cancelAt := some 50, processes := { scripts := #[sleeperScript 100] } }
        let (finished, untouched) :=
          job.runModel { cancelAt := some 500, processes := { scripts := #[sleeperScript 100] } }
        return outcome == .cancelled && model.now == 50 && model.processes.killed == #[sleeper] &&
            finished == .finished true &&
            untouched.processes.killed.isEmpty },
    cancellingJobProcessWaitCheck, runnerGivenProcessServiceCheck, readDeliversLineChildCheck,
    { name :=
        "the process model holds a child at the bound in the middle of its write, with exactly the bound undelivered, and a read lets it go on"
      run := do
        let script : Process.StreamScript :=
          { command := sleeper, steps := #[.write .out (ByteArray.mk (Array.replicate 25 120))] }
        let model : ProcessModel := { streams := #[script] }
        let streaming : Process.Streaming := { stdout := .bytes, stderr := .bytes, bound := 10 }
        let heldAt (model : ProcessModel) :=
          model.children[0]?.map fun child => (child.stdout.size, child.writing.map (·.2.2))
        let (_, started, _) := model.handle 0 none (.start sleeper streaming)
        let (_, afterRead, _) := started.handle 0 none (.read ⟨1⟩)
        let (_, afterSecond, _) := afterRead.handle 0 none (.read ⟨1⟩)
        return heldAt started == some (10, some 10) && heldAt afterRead == some (10, some 20) &&
            heldAt afterSecond == some (5, none) },
    -- Seen to bite once by hand, on 2026-11-15: over the model as it was,
    -- which judged a partial line that fills the bound too long whatever
    -- the child did next, the first read ends the child and the check fails.
    { name :=
        "the process model ends a child as lineTooLong only when it has more of the line to write: a partial line exactly the bound long, the child waiting on its input, is not too long, and is delivered whole once the input ends"
      run := do
        let script : Process.StreamScript :=
          { command := sleeper, steps := #[.write .out "abcd".toUTF8, .awaitClosed] }
        let model : ProcessModel := { streams := #[script] }
        let (_, started, _) := model.handle 0 none (.start sleeper (JobContract.lines 4 true))
        let (waiting, afterWaiting, _) := started.handle 0 none (.read ⟨1⟩)
        let (_, closed, _) := afterWaiting.handle 0 none (.closeInput ⟨1⟩)
        let (last, afterLast, _) := closed.handle 0 none (.read ⟨1⟩)
        let notTooLong :=
          match waiting with
          | .ok delivery => delivery.ended.isNone
          | .error _ => true
        let whole :=
          match last with
          | .ok delivery =>
            delivery.stdout == .lines #["abcd".toUTF8] && delivery.ended == some (.exited (.code 0))
          | .error _ => false
        return notTooLong && afterWaiting.killed.isEmpty && whole && afterLast.killed.isEmpty &&
            afterLast.children.isEmpty },
    { name :=
        "on the job model a child that pauses holds its second line: the first read gives the first line at once, with no end, and the next moves the clock to the pause's end and gives the second with the end"
      run := do
        let script := JobContract.pausingStream processRoot
        let job : JobM (Process.Delivery × Nat × Array Process.Delivery × Nat) := do
          let child ← JobContract.started script.command (JobContract.lines 64)
          let first ← JobContract.delivered child
          let between ← now
          let rest ← JobContract.toTheEnd child
          return (first, between, rest, ← now)
        match job.runModel { processes := { streams := #[script] } } with
        | (.finished (first, between, rest, after), _) =>
          return first.stdout == .lines #["one".toUTF8] && first.ended.isNone && between == 0 &&
              JobContract.linesOf rest .out == #["two".toUTF8] &&
              JobContract.endOf rest == some (.exited (.code 0)) &&
              after == 500
        | _ =>
          return false },
    { name :=
        "on the job model a job cancelled while its child pauses is cancelled at that instant, and its child is recorded as killed"
      run := do
        let script := JobContract.pausingStream processRoot
        let job : JobM Unit := do
          let child ← JobContract.started script.command (JobContract.lines 64)
          discard <| JobContract.delivered child
          discard <| JobContract.delivered child
        let (outcome, after) :=
          job.runModel { processes := { streams := #[script] }, cancelAt := some 200 }
        return outcome == .cancelled && after.now == 200 &&
            after.processes.killed == #[script.command] },
    -- Seen to bite once by hand, on 2026-11-15: with the filter of
    -- `Handle.children` after a last delivery taken out of `answer`, the
    -- later read, write and close reach the fake, and the check fails.
    childLastDeliveryRunnerCheck,
    -- Seen to bite once by hand, on 2026-11-15: with `Handle.endChildren`
    -- taken out of `Handle.conclude`, this check and the next fail.
    jobEndsStreamingChildCheck, cancellingJobPendingReadCheck]

end ModelTest
