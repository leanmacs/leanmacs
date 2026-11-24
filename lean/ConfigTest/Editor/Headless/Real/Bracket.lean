import ConfigTest.Editor.Headless
import ConfigTest.Editor.Test.Linked.Host
import ConfigTest.Support.Real
import Editor.RealHost

/-!
# Config tests: the loop's bracket, over a real loop thread

A module of the wiring set (`AGENTS.md`, "Deterministic concurrency in
tests"; `docs/dev-practices/real-thread-checks.md`), beside the mirror of
`Editor/Headless.lean`, whose stepped checks it must not hold: the real loop,
`Headless.withHost` and `Hosting.real` live in `Editor/Headless.lean` with
everything the stepped checks test.

**The real adapter.** The editor loop's own thread and its join
(`Headless.withHost`, `withHostEnding`): its guard, its grace, `abandoned`,
`endWaits`, `loopStarted`, and the refusal of a stepper's queue. **Why a
real thread.** The thread and its join are the subject: a stepped host has
no thread to join.

`bracketChecks`, each with what pins the ordering it touches:
- a loop held inside an event is waited for past the bracket's guard:
  `steppedChecks`' stepped end with a reload held past its guard;
- the bracket joins on throw, and throws the loop's error, and a settle on
  an ended loop says ended: `steppedChecks`' later waits once a step
  stopped the loop, and the stepped bracket on return and on throw;
- `withHostEnding` hands back the end, and `loopStarted` is called on the
  loop's thread: wiring only;
- the bracket waits for its reload past `endWaits`: the stepped wait that
  reaches its guard and lets the reload go through `endWaits`,
  `ConfigTest.protocolContractChecks`' "a stepped host's loop's end waits
  for the jobs cancelled before it", theorem `loopEnd_settles_cancelled`;
- held past guard and grace, the loop goes to `abandoned`: the stepped
  end's grace check;
- a real host refuses a stepper's queue: `ModelTest/Editor/Headless/Queue.lean`
  pins the flag;
- a stepped stage refuses a stage over the library's services, and a real
  host a stepped stage: wiring only, two refusals and no ordering.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.ConfigTest.Editor.Headless.Real.Bracket : Editor.WiringSet :=
  .wiring "the editor loop thread and its join (Headless.withHost, withHostEnding)" "the thread and its join are the subject, and a stepped host has no thread to join"

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- The checks of `Headless.withHost`, the bracket a host lives in
(`Editor/Headless.lean`), on the real queue and the real text binding: it
returns only once the host's loop has ended, whether its body returned or
threw, and a loop slow to end is waited for past the bracket's guard, which
says a hang once and does not end the wait. The slow end is forced by
holding the editor thread inside an event (`holdingUntil`), let go only by
the bracket's own report of the hang: no sleep, and the order is the same
every run. -/
def bracketChecks (context : Context) : List Check :=
  [{  name :=
        "a host's bracket returns only once its loop has ended: a loop held inside an event when the bracket asks it to stop is waited for past the bracket's guard, which says a hang once"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let kept ← IO.mkRef (none : Option (Task (Except IO.Error Unit)))
        let said ← IO.mkRef (#[] : Array String)
        let entered ← IO.Promise.new
        let finished ←
          holdingUntil fun hold letGo => do
              Headless.withHost (heldAtCommands stage hold entered) (guard := heldAtOnce) (hung :=
                  fun line => do
                  said.modify (·.push line)
                  letGo) fun host => do
                  kept.set (some host.thread)
                  host.send .show
                  discard <| Job.awaitWithin hangGuard entered.result?
              match ← kept.get with
              | some thread =>
                IO.hasFinished thread
              | none =>
                pure false
        -- Let go by now: a loop the bracket left is waited for here, so
        -- nothing the check started outlives it.
        if let some thread← kept.get then
          discard <| IO.wait thread
        let said ← said.get
        let output ← stage.output.get
        saw (finished && said.size == 1 && output.any (·.startsWith "commands:"))
            s!"finished={finished} said={said} output={output}" },
    { name :=
        "a host's bracket stops and waits for its loop when its body throws, and the body's error is the one thrown"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let kept ← IO.mkRef (none : Option (Task (Except IO.Error Unit)))
        let said ← IO.mkRef (#[] : Array String)
        let entered ← IO.Promise.new
        let (thrown, finished) ←
          holdingUntil fun hold letGo => do
              let thrown ←
                try
                  Headless.withHost (heldAtCommands stage hold entered) (guard := heldAtOnce)
                      (hung := fun line => do
                      said.modify (·.push line)
                      letGo) fun host => do
                      kept.set (some host.thread)
                      host.send .show
                      discard <| Job.awaitWithin hangGuard entered.result?
                      throw (IO.userError "the body broke")
                  pure none
                catch error =>
                  pure (some (toString error))
              let finished ←
                match ← kept.get with
                | some thread =>
                  IO.hasFinished thread
                | none =>
                  pure false
              return (thrown, finished)
        if let some thread← kept.get then
          discard <| IO.wait thread
        let said ← said.get
        saw (thrown == some "the body broke" && finished && said.size == 1)
            s!"thrown={thrown} finished={finished} said={said}" },
    { name := "a host's bracket throws the error its loop ended with when its body returned"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let broken :=
          { stage.collaborators with display := fun _ => throw (IO.userError "no display here") }
        let thrown ←
          try
            Headless.withHost broken fun _ => pure ()
            pure none
          catch error =>
            pure (some (toString error))
        saw (thrown == some "no display here") s!"thrown={thrown}" },
    { name :=
        "a host's bracket that hands back its loop's end gives the error its loop ended with, and throws nothing, when its body returned"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let broken :=
          { stage.collaborators with display := fun _ => throw (IO.userError "no display here") }
        let (answered, ended) ← Headless.withHostEnding broken fun _ => pure 7
        let error :=
          match ended with
          | .error error => some (toString error)
          | .ok () => none
        saw (answered == 7 && error == some "no display here")
            s!"answered={answered} error={error}" },
    { name :=
        "a check's settle on a host whose loop ended before the requests settled says the loop ended, with the error it ended with, and not a hang"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let broken :=
          { stage.collaborators with display := fun _ => throw (IO.userError "no display here") }
        let thrown (action : IO Unit) : IO (Option String) := do
          try
            action
            return none
          catch error =>
            return some (toString error)
        let ((asked, settledSaid), _) ←
          Headless.withHostEnding broken fun host => do
              let session : Session := (RealSession.ofStage host "/" stage)
              let asked ← thrown (session.ask [.show])
              let settledSaid ← thrown (discard <| settled host)
              return (asked, settledSaid)
        let ended (said : Option String) : Bool :=
          said.any fun text =>
            !text.startsWith "a hang" && (text.splitOn "ended").length > 1 &&
              (text.splitOn "no display here").length == 2
        saw (ended asked && ended settledSaid) s!"asked={asked} settled={settledSaid}" },
    { name :=
        "a host's bracket returns only once its reload job has ended: a reload held at the gate inside elaboration when the body returns is waited for by the loop's end, which says so once (`endWaits`), and the gate is let go only then"
      run := do
        let gate ← Gate.new
        let waited ← IO.mkRef (#[] : Array String)
        let stage ← Stage.new context (gate.around context.elaborator) (memorySource slowModules)
        let hung ← IO.mkRef (#[] : Array String)
        try
          -- The loop's end waits for an elaboration it has just let go,
          -- which takes as long as the machine takes: its guard is the
          -- checks' hang guard, and a hang said fails the check.
          let held ←
            Headless.withHost
                { stage.collaborators with
                  endWaits := fun what => do
                    waited.modify (·.push what)
                    gate.open }
                (guard := hangGuard) (hung := fun line => hung.modify (·.push line)) fun host => do
                host.send .reload
                -- The reload is inside the elaboration of the held file when
                -- the body returns.
                return (← Job.awaitWithin hangGuard gate.arrived.result?).isSome
          let inProgress ← gate.inProgress.get
          let waited ← waited.get
          let hung ← hung.get
          saw (held && waited == #["reload"] && inProgress == 0 && hung.isEmpty)
              s!"held={held} waited={waited} inProgress={inProgress} hung={hung}"
        finally
          gate.open },
    { name :=
        "a check's bracket whose loop is held past its guard and its grace fails as a hang, saying the loop's hang once, and hands the loop it left to `abandoned`"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory jobsConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          -- Held in the withdrawal as the loop ends, and let go only by the
          -- check, once the bracket has given up: a grace of 0 runs out on
          -- a held loop every time.
          let withdrew ← IO.mkRef false
          let order ← IO.mkRef #[]
          let said ← IO.mkRef (#[] : Array String)
          let left ← IO.mkRef (none : Option (Task (Except IO.Error Unit)))
          let thrown ←
            holdingUntil fun hold letGo => do
                let thrown ←
                  try
                    withdrawingHeld stage hold withdrew order fun collaborators =>
                        Headless.withHost collaborators (guard := heldAtOnce) (grace :=
                          some heldAtOnce) (hung := fun line => said.modify (·.push line))
                          (abandoned := fun task => left.set (some task)) fun host => do
                          host.send .reload
                          unless ← settled host do
                            throw (IO.userError "the reload did not settle")
                          host.send (.spawn "count")
                          unless ← settled host do
                            throw (IO.userError "the spawn did not settle")
                    pure none
                  catch error =>
                    pure (some (toString error))
                letGo
                return thrown
          let abandoned := (← left.get).isSome
          if let some task← left.get then
            discard <| IO.wait task
          let said ← said.get
          saw
              (thrown.any
                  (fun text =>
                    text.startsWith "a hang:" && (text.splitOn "giving up").length == 2) &&
                said.size == 1 &&
                abandoned)
              s!"thrown={thrown} said={said} abandoned={abandoned}" },
    { name :=
        "a real host refuses, at once, collaborators whose queue a stepper drains, and starts no loop"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let stepper :=
          { stage.collaborators with queue := stage.memory.queue Headless.Posted.toFfi }
        let before ← context.realLoops.get
        let refused ←
          try
            Headless.withHost stepper (guard := hangGuard) (grace := some hangGuard) fun _ =>
                pure ()
            pure none
          catch error =>
            pure (some (toString error))
        let after ← context.realLoops.get
        saw
            (refused ==
                some
                  "a real host's queue must be the library's: its collaborators' queue is pulled by a stepper" &&
              after == before)
            s!"refused={refused} real loops {before} then {after}" },
    { name :=
        "a stage's real host calls its loopStarted once, on its loop's own thread, not the check's, and a check's own run of the loop's handler never calls it"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let threads ← IO.mkRef (#[] : Array UInt64)
        let counted :=
          { stage.collaborators with
            loopStarted := do
              stage.collaborators.loopStarted
              threads.modify (·.push (← IO.getTID)) }
        Headless.withHost counted (guard := hangGuard) (grace := some hangGuard) fun host => do
            host.send .show
            discard <| host.await hangGuard
        let started ← threads.get
        let mine ← IO.getTID
        let before ← context.realLoops.get
        let ran ← withRunning context id fun _ _ _ => return true
        let after ← context.realLoops.get
        saw (started.size == 1 && started.all (· != mine) && ran && after == before)
            s!"started on {started}, the check on {mine}, real loops {before} then {after}" },
      { name :=
          "a stepped stage refuses a stage over the library's services, and a real host refuses a stepped stage"
        run := do
          let real ← Stage.overFiles context (memorySource [])
          let refusedReal ←
            try
              discard <| real.stepped
              pure false
            catch _ =>
              pure true
          let stage ← steppedStage context
          let refusedHost ←
            try
              discard <| onRealStage stage fun _ _ => pure true
              pure false
            catch _ =>
              pure true
          saw (refusedReal && refusedHost)
              s!"Stage.stepped refused overFiles {refusedReal}; onRealStage refused a stepped stage {refusedHost}" }]

end ConfigTest
