import ConfigTest.Editor.Headless
import ConfigTest.Editor.Headless.Stepped
import Editor.RealHost

/-!
# Config tests: the driver's waits, across a real loop thread

A module of the wiring set (`AGENTS.md`, "Deterministic concurrency in
tests"; `docs/dev-practices/real-thread-checks.md`), beside the mirror of
`Editor/Headless.lean` (`Headless/Real/Bracket.lean` says why).

**The real adapter.** The driver's waits across the loop thread
(`Host.waitWhile`): the idle signal read from another thread, and an editor
thread that does not answer. **Why a real thread.** A stepped host takes
its turns on the waiting thread, so neither crossing exists there.

`realWaitChecks`, each with what pins the ordering it touches:
- the two "a join does not answer working while ..." checks force the
  interleaving with a held start and a held clock read:
  `ModelTest/Editor/Headless/Wait.lean` (a busy round blocks on the count's
  next change), `ModelTest/Editor/Job/Runner.lean`'s held park checks,
  theorem `count_zero_iff_none_holds`;
- an editor thread held inside an event when a join asks: cross-thread
  wiring only;
- a wait that runs out on an editor thread held inside an event: wiring
  only; the reloading half is `Wait.lean`'s "a busy rest blocked on a
  reload in flight whose guard has run out hangs";
- `steppedHostPublishesScenesCheck`, the parity of a stepped host's scenes
  with a real one's (W11): its subject is the comparison itself.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.ConfigTest.Editor.Headless.Real.Waits : Editor.WiringSet :=
  .wiring "the driver's waits across the editor loop thread (Host.waitWhile)" "a stepped host takes its turns on the waiting thread, so the idle read across threads and an unanswering editor thread exist only on a real one"

namespace ConfigTest

open Editor
open Editor.Test.Linked

-- inferred-waits W11: stays (A2: the join's later rounds publishing no scene, stepped against real, are the subject)
set_option linter.inferredWait false in
/-- A check of `steppedChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def steppedHostPublishesScenesCheck (context : Context) : Check :=
  { name :=
      "a stepped host publishes the scenes a real host does: a settle one, and a join's later rounds none"
    run := do
      let counts (drive : (Headless.Collaborators _ _ TestScheme.scheme) → IO (List Nat)) := do
        let stage ← Stage.new context context.elaborator (memorySource []) nappingCompiled
        drive stage.collaborators
      let kept ← IO.mkRef none
      let memory ← Headless.Queue.Memory.new
      let stepped ←
        counts fun collaborators =>
            Headless.withStepped (keptDisplay collaborators kept) memory (guard := hangGuard)
              (grace := some hangGuard) fun stepped => do
              stepped.send (.run "rest")
              discard <| stepped.await hangGuard
              let settled ← scenesOf kept
              discard <| stepped.join hangGuard
              return [settled, ← scenesOf kept]
      let keptReal ← IO.mkRef none
      let real ←
        counts fun collaborators =>
            Headless.withHost (keptDisplay collaborators keptReal) (guard := hangGuard) (grace :=
              some hangGuard) fun host => do
              host.send (.run "rest")
              discard <| host.await hangGuard
              let settled ← scenesOf keptReal
              discard <| host.join hangGuard
              return [settled, ← scenesOf keptReal]
      saw (stepped == real && stepped.length == 2) s!"stepped {stepped}, real {real}" }

/-- The checks of the driver's waits across a real loop thread (this module's doc says what pins each). -/
def realWaitChecks (context : Context) : List Check :=
  [{  name :=
        "a join does not answer working while a job is about to start its sleep: with the job's start held, the join blocks on it, and answers working once the job is in its sleep"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource []) { jobs := #[countJob] }
        let blocks ← IO.mkRef 0
        let said ← IO.mkRef (#[] : Array String)
        let seen ← IO.mkRef (none : Option (Headless.Wait × Nat))
        let settled ←
          onRealStage stage fun host stage => do
              -- Held before the spawn: when the join begins the job can run,
              -- inside the start of its sleep, and the editor queue is empty.
              let hold ← stage.clock.holdStarts
              try
                host.send (.spawn "count")
                let wait ←
                  host.join hangGuard (waitHung := fun line => said.modify (·.push line))
                      (waitBlocked := fun what => do
                      if what == "running work" then
                        blocks.modify (· + 1)
                        hold.resolve ())
                seen.set (some (wait, ← stage.clock.waiting))
                return true
              finally
                hold.resolve ()
        let seen ← seen.get
        let blocks ← blocks.get
        let said ← said.get
        saw (settled && seen == some (.working, 1) && blocks >= 1 && said.isEmpty)
            s!"seen={repr seen} blocks={blocks} said={said}" },
    { name :=
        "a join does not answer working while a job's result is on its way: with the job's reading of the clock held after its sleep, the join blocks on it, and answers settled once the job's line is printed"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource []) { jobs := #[readingJob] }
        let said ← IO.mkRef (#[] : Array String)
        let seen ← IO.mkRef (none : Option Headless.Wait)
        let settled ←
          onRealStage stage fun host stage => do
              host.send (.spawn "once")
              unless ← host.settle hangGuard do
                return false
              -- In its sleep: its reading is then held, and the clock moved
              -- past the sleep, so the job can run, inside the reading, and
              -- will post its result after the join's first marker.
              discard <| countReaches host 0
              let hold ← stage.clock.holdReads
              try
                stage.clock.advance 10
                let wait ←
                  host.join hangGuard (waitHung := fun line => said.modify (·.push line))
                      (waitBlocked := fun what => do
                      if what == "running work" then
                        hold.resolve ())
                seen.set (some wait)
                return true
              finally
                hold.resolve ()
        let output ← stage.output.get
        let seen ← seen.get
        let said ← said.get
        saw (settled && seen == some .settled && output.contains "job 1 once: ok" && said.isEmpty)
            s!"seen={repr seen} output={output} said={said}" },
    { name :=
        "an editor thread held inside an event when a join asks for its answer still makes the join answer working, at idle: the hold is let go when the join blocks on the answer, and nothing is said as a hang"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource []) { jobs := #[countJob] }
        -- The editor thread is held inside the spawn's line until the join
        -- has blocked on its answer (`meetingAnswer`): the join's marker
        -- waits behind the held event, whichever comes first. The loop's
        -- end lets it go too, as a backstop for a driver that never says
        -- it blocked.
        let said ← IO.mkRef (#[] : Array String)
        let failure ←
          meetingAnswer fun hold blocked letGo =>
              Headless.run (heldAtLine stage.collaborators (· == "spawn count: job 1") hold)
                #[⟨3, .request (.spawn "count")⟩, ⟨4, .join⟩] hangGuard (grace := some hangGuard)
                (hung := fun _ => letGo) (waitHung := fun line => said.modify (·.push line))
                (waitBlocked := blocked)
        let output ← stage.output.get
        let said ← said.get
        saw
            (failure == some (.working (some 4)) && said.isEmpty &&
              output == #["spawn count: job 1"])
            s!"failure={repr failure} said={said} output={output}" },
    { name :=
        "a wait that runs out on an editor thread held inside an event says the editor thread has not answered, as a hang once"
      run := do
        -- Wiring only: the editor thread's answer read across the loop
        -- thread. The reloading half, a wait on a reload that does not end,
        -- is `ModelTest/Editor/Headless/Wait.lean`'s ("a busy rest blocked on
        -- a reload in flight whose guard has run out hangs") and
        -- `steppedChecks`' (a stepped wait that reaches its guard).
        let said ← IO.mkRef (#[] : Array String)
        -- An editor thread held inside an event, by an output port that
        -- does not return until the check lets it: it never reaches the
        -- marker.
        let block ← IO.Promise.new
        let entered ← IO.Promise.new
        let stage ← Stage.new context context.elaborator (memorySource [])
        Headless.withHost (scheme := TestScheme.scheme) (guard := hangGuard)
            { stage.collaborators with
              emit := fun _ => do
                entered.resolve ()
                discard <| IO.wait block.result? }
            fun host => do
            -- Let go before the bracket ends the loop, whatever the body
            -- did: the bracket waits for the loop with no deadline.
            try
              host.send .show
              let inside := (← Job.awaitWithin hangGuard entered.result?).isSome
              -- The editor thread is held for good inside the show: only the
              -- answer's guard ends the wait, said as a hang once.
              let wait ← host.await heldShort (waitHung := fun line => said.modify (·.push line))
              let saidUnanswered ← said.get
              block.resolve ()
              let after ← host.await hangGuard
              saw
                  (inside && wait == .unanswered && saidUnanswered.size == 1 &&
                    (after == .settled || after == .ended))
                  s!"inside={inside} wait={repr wait} saidUnanswered={saidUnanswered} after={repr after}"
            finally
              block.resolve () },
  steppedHostPublishesScenesCheck context]

end ConfigTest
