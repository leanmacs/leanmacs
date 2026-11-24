import ConfigTest.Editor.Headless
import ConfigTest.Editor.Loop
import Editor.RealHost

/-!
# Config tests: `Editor/Headless/Queue/Real.lean`, the library's editor queue

A module of the wiring set (`AGENTS.md`, "Deterministic concurrency in
tests"; `docs/dev-practices/real-thread-checks.md`): the test module that
mirrors the real adapter's module, `Queue.library`.

**The real adapter.** The library's editor queue: a Rust poster
(`Ffi.feedScript`), and the library's interrupt flag raised while a command
runs. **Why a real thread.** A stepped host never pulls the library's queue
and tells the library no interrupt key.

`realQueueChecks`, cut to the flag and the stop; the echo and the text's
rollback are `ModelTest.dispatchInterruptChecks`' (a key's command and a
finished job's delivered command) and `Command/Dispatch.lean`'s:
- the editor answers 100 events from a Rust thread while a reload is held:
  `steppedChecks`' stepped wait that handles a push while a reload is held;
- a finished job's command, and the driver's run of a command, are
  guarded: wiring of the flag;
- the interrupt key arriving while a command loops, and while none runs:
  wiring of the flag.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.ConfigTest.Editor.Headless.Queue.Real : Editor.WiringSet :=
  .wiring "the library's editor queue (Queue.library) and its interrupt flag"
    "a stepped host never pulls the library's queue and tells the library no interrupt key"

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- `withRealHost` over a stage whose services record to a fake recorder
(`Job.FakeRecorder`, `recording`), handed to `check` beside the session:
for a real-host check that waits on its own job's protocol transitions. -/
private def withRecordedRealHost (context : Context) (files : List (String × String))
    (check : RealSession → Job.FakeRecorder → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeConfig directory files
    let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
    let recorder ← Job.FakeRecorder.new
    let stage := { stage with collaborators := recording stage.collaborators recorder }
    onRealStage stage fun host stage => check (RealSession.ofStage host directory stage) recorder

/-- A check of `hostLoopChecks`, a declaration of its own. -/
def finishedJobCommandGuardedCheck (context : Context) : Check :=
  { name :=
      "a finished job's command is guarded as a key's is: the interrupt key that arrives as it is delivered stops the command that loops over requests, the output says the job was interrupted, and the flag is down once the loop has taken the key"
    run :=
      -- Stays on a real host (row W8 of docs/dev-practices/inferred-waits.md,
      -- A4): the library's queue and its interrupt flag are the subject. Its
      -- waits are its own: the spinner's park on its sleep, recorded (the
      -- recorder), and the arrival of the clock read it holds itself.
      withRecordedRealHost context [("init.lean", startingText)] fun session recorder => do
        session.ask [.reload]
        unless ← Event.post (.commit "ab") do
          return false
        session.ask [.spawn "spinner"]
        -- hang guard: the spinner's park on its sleep, recorded; only a
        -- hang reaches the bound.
        let parked ← recorder.reached (· matches .park _)
        unless (← Job.awaitWithin hangGuard parked).isSome do
          return false
        -- The loop reads the clock just before a command it runs: held
        -- there, the editor thread is inside the delivery, and the
        -- job's command has not started.
        let arrivals ← session.clock.held
        let hold ← session.clock.holdReads
        session.clock.advance 10
        -- hang guard: the loop's read of the clock arrived at the check's
        -- own hold, installed once the job had parked; only a hang reaches
        -- the bound.
        let reached ← session.clock.arrivedAt (.held (arrivals + 1))
        unless (← Job.awaitWithin hangGuard reached.result?).isSome do
          hold.resolve ()
          return false
        session.host.press Watch.interruptKey
        hold.resolve ()
        unless ← session.host.settle hangGuard do
          return false
        -- The echo and the text before the delivery are the model's
        -- (`ModelTest.dispatchInterruptChecks`, a finished job's command).
        return (← session.output.get).contains "job 1 spinner: interrupted" &&
            !(← Ffi.interruptRaised) }

/-- The checks of the library's editor queue under a real loop thread (this module's doc says what pins each). -/
def realQueueChecks (context : Context) : List Check :=
  [{
      name :=
        "the editor answers events while a slow file elaborates: 100 events from a Rust thread and a command of the old config",
      run := do
        let gate ← Gate.new
        withRealHostOver context greetConfig gate.around id fun session => do
            session.ask [.reload]
            session.write "Config/Slow.lean" slowText
            session.write "init.lean" overSlow
            session.host.send .reload
            try
              -- The reload job is now inside the elaboration of `Config/Slow.lean`,
              -- and stays there until the gate opens.
              unless (← Job.awaitWithin hangGuard gate.arrived.result?).isSome do
                return false
              let some fed ← Ffi.feedScript .editor 77 100 hangGuard | return false
              -- The feed's thread has pushed its last event once it is joined:
              -- all 100 are on the editor queue, and the run is sent after
              -- them, so a wait that only asks the editor thread to answer
              -- (`handled`, which waits for no reload) answers once all of
              -- them are handled. With the job on the editor thread it never
              -- answers while the file is held: the wait reaches its guard and
              -- the check fails as a hang.
              let joined := (← Job.awaitWithin hangGuard fed) matches some (.ok true)
              session.host.send (.run "greet")
              let handled ← session.handled
              let lines ← session.output.get
              let answered := handled && lines.size == 102 && lines.contains "run greet: ok"
              -- The file is still being elaborated: all of that was answered
              -- while it was held.
              let held := (← gate.inProgress.get) == 1
              gate.open
              session.ask []
              -- The reload's install once let go, and the editor's handling
              -- of each event, are the stepped checks': a stepped host
              -- answers events while a reload is held (`steppedChecks`).
              return answered && held && joined &&
                  (lines.filter (·.startsWith "event ")) == eventLines 77 100
            finally
              gate.open },
    finishedJobCommandGuardedCheck context,
    { name :=
        "the driver's run of a command is guarded: with the interrupt key arrived the command that loops over requests is stopped, the output says it was interrupted, and the flag is down once the loop has taken the key"
      run :=
        -- Wiring only: the flag the library raises stops the command, and
        -- the loop lowers it. The echo and the rollback are the model's
        -- (`ModelTest.dispatchInterruptChecks`).
        withRealHost context []
          (fun session => do
            -- The loop has started, so the library knows the interrupt key:
            -- the press raises the flag as it arrives, whether the loop has
            -- begun the command by then or not.
            session.ask []
            session.host.send (.run "spin")
            session.host.press Watch.interruptKey
            unless ← session.host.settle hangGuard do
              return false
            return ((← session.output.get).filter (·.startsWith "run ")) ==
                  #["run spin: interrupted"] &&
                !(← Ffi.interruptRaised))
          dispatchCompiled },
    { name :=
        "the interrupt key arrives while a command loops over requests: the command stops, the scene's echo says so, the flag is down once the loop has taken the key, and the next key runs its command"
      run :=
        -- Wiring only: the library raises its flag as the key arrives on its
        -- queue, and the loop reads and lowers it. The rollback of the
        -- command's edit is the model's (`ModelTest.dispatchInterruptChecks`,
        -- `ModelTest/Editor/Loop.lean`, and `Command/Dispatch.lean`'s).
        withRealHost context []
          (fun session => do
            session.type "C-c l"
            -- The loop has taken the key that runs the command: it is in the
            -- command, or about to be.
            unless ← session.outputReaches (·.contains "key arrived: l - -") do
              return false
            session.host.press Watch.interruptKey
            unless ← session.host.settle hangGuard do
              return false
            let interrupted ← session.scene
            let lowered ← Ffi.interruptRaised
            session.typed "C-c s"
            let after ← session.scene
            return interrupted.1 == "spin: interrupted".quote && !lowered &&
                after == ("".quote, #[viewLine "!" 1]))
          dispatchCompiled },
    { name :=
        "the interrupt key arrives while no command is running: the flag is down once the loop has taken it, and the next key's command runs to its end"
      run :=
        withRealHost context []
          (fun session => do
            session.host.press Watch.interruptKey
            session.ask []
            let lowered ← Ffi.interruptRaised
            session.typed "C-c s"
            return !lowered && (← session.scene) == ("".quote, #[viewLine "!" 1]))
          dispatchCompiled }]

end ConfigTest
