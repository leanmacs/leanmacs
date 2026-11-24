import ConfigTest.Editor.Headless
import ConfigTest.Support.Real
import Editor.RealHost

/-!
# Config tests: the CLI's runner, over a real loop thread

A module of the wiring set (`AGENTS.md`, "Deterministic concurrency in
tests"; `docs/dev-practices/real-thread-checks.md`), beside the mirror of
`Editor/Headless.lean` (`Headless/Real/Bracket.lean` says why).

**The real adapter.** The headless CLI's driver over a real loop
(`Headless.run`, `runAndDispose`, `Hosting.real`): the reload's wake-up over
the library's queue, and dispose after the join. **Why a real thread.** The
runner's logic is the `Headless.Driven` port's and is pinned stepped
(`steppedRunChecks`); what is left is its real hosting.

`realRunnerChecks`, each with what pins the ordering it touches:
- a host made by a stage and handed straight to `Headless.run` still gets
  its reload's wake-up: wiring only;
- the headless mode's run disposes once its loop has ended: dispose after
  join; the stepped run's dispose, on success and on failure, is
  `steppedRunChecks`';
- a run that reaches its script's end disposes only after its loop has
  ended, when the loop is slow to end (W5):
  `ContractTest/Editor/Job/ProtocolContract.lean`, theorem
  `cancel_finds_running_or_recorded`.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.ConfigTest.Editor.Headless.Real.Runner : Editor.WiringSet :=
  .wiring "the headless CLI's runner over a real loop (Headless.run, runAndDispose, Hosting.real)" "the runner's logic is pinned stepped, and its hosting on a real loop thread, with dispose after the join, is what the CLI runs"

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- The checks of the CLI's runner over a real loop thread (this module's doc says what pins each). -/
def realRunnerChecks (context : Context) : List Check :=
  [{  name :=
        "a host made by a stage and handed straight to Headless.run still gets its reload's wake-up: reload, settle and show end with no failure, the reload installed and its command shown"
      run := do
        let stage ←
          Stage.new context context.elaborator (memorySource [("init", helloText ++ setupText)])
        let failure ←
          Headless.run stage.collaborators
              #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .request .show⟩] hangGuard (grace :=
              some hangGuard)
        let output ← stage.output.get
        saw
            (failure.isNone && output.any (·.startsWith "reload 1: installed") &&
              output.contains "commands: greet")
            s!"failure={repr failure} output={output}" },
    { name :=
        "the headless mode's run disposes of its collaborators once its loop has ended: dispose is called once, after every line the script had the host print"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory jobsConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          let (failure, _) ←
            Headless.runAndDispose stage.collaborators
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .request (.spawn "count")⟩,
                  ⟨4, .advance 10⟩, ⟨5, .join⟩]
                hangGuard (grace := some hangGuard)
          let output ← stage.output.get
          return failure.isNone && output.contains "job 1 count: ok" &&
              (← stage.disposed.get) == #[output.size] },
    { name :=
        "a run that reaches its script's end disposes only after its loop has ended, when the loop is slow to end"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory jobsConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          -- The script leaves its job in its wait, and the loop withdraws
          -- that wait as it ends, on its own thread: held there until the
          -- run's bracket says that its loop has not ended at once. A held
          -- line could not show this: the wait at the script's end waits
          -- for the editor thread's answer, so a line held before it is
          -- printed before the stop.
          let withdrew ← IO.mkRef false
          let order ← IO.mkRef #[]
          let (failure, left) ←
            holdingUntil fun hold letGo =>
                withdrawingHeld stage hold withdrew order fun collaborators => do
                  let (failure, _) ←
                    Headless.runAndDispose collaborators jobScript hangGuard (grace :=
                        some hangGuard) (guard := heldAtOnce) (hung := fun _ => letGo)
                  -- The loop has ended: nothing of the cancelled job is
                  -- still to come, its wake-up is on the editor queue, since
                  -- the loop's end waited for it (`withdrawingHeld`, which
                  -- holds the post until then and lets it go only after
                  -- this). What the queue holds is taken off it, since no
                  -- loop pulls it and no later host is to take it;
                  -- `takeQueued` never parks.
                  let mut left := #[]
                  for _ in [0:(← Ffi.queued .editor).toNat] do
                    let some event ← Ffi.takeQueued .editor | break
                    left := left.push (event.source.id, event.code)
                  return (failure, left)
          let woke := left.contains (stage.collaborators.jobs, 1)
          let withdrawn ← stage.clock.withdrawn
          let disposed ← stage.disposed.get
          let output ← stage.output.get
          let order ← order.get
          saw
              (failure.isNone && withdrawn.size == 1 && order == #[true] &&
                disposed == #[output.size] &&
                output == #["reload 1: installed, 2 files, 1 commands", "spawn count: job 1"] &&
                woke)
              s!"failure={repr failure} withdrawn={withdrawn} withdrew before dispose={order} disposed={disposed} output={output} the job's wake-up on the queue={woke} of {left}" }]

end ConfigTest
