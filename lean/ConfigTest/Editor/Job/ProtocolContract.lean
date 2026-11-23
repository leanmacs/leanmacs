import ConfigTest.Check
import ConfigTest.Support.Configs
import Editor.Headless
import Editor.Headless.Stepped
import Editor.Job.Fake
import Editor.Job.ProtocolContract
import Editor.Test.Linked.Host

/-!
# Config tests: `Editor/Job/ProtocolContract.lean`

The runner's protocol contract on a host stepped on the check's own thread
(`Headless.withStepped`): `protocolContractChecks`. The stage's services
record to the fake recorder (`Job.FakeRecorder`); a check sends the host
`spawn` requests, drains them on its own thread, moves the stage's fake
clock, and waits only on the recorder's events, never on a driver's wait.
The bracket's end cancels what is left and waits for it
(`Collaborators.endCancelled`, which `Stage.new` sets), then records the
loop's end. The root module `ConfigTest` runs them; its module doc says
what they show.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- `collaborators` with `recorder` as what the runner records to. -/
def recording {β σ : Type} (collaborators : Headless.Collaborators β σ TestScheme.scheme)
    (recorder : Job.FakeRecorder) : Headless.Collaborators β σ TestScheme.scheme :=
  { collaborators with services := { collaborators.services with recorder := recorder.recorder } }

/-- Whether `transition` is a park of a job other than `job`. -/
def parksOther (job : Nat) : Job.Protocol.Transition → Bool
  | .park other => other != job
  | _ => false

/-- The park subject of a stepped host's real runner: the stage's count is
this subject's own (`tracksIdle := false`), wrapped to note each `done`'s
thread, and the recorder holds the nap's thread at its first transition
after its unit's `done`, which is its park (`ProtocolContract.ParkHold`).
While it is held the body returns, so the loop's end cancels the job; the
stage's clock, wrapped, notes each wait it is told to withdraw, and the
wrapped `endCancelled` reads what was withdrawn as the cancel returned, then
lets the hold go before it hands over to the stage's wait for the job. A
`finally` lets it go too. A held call, never a sleep. -/
def steppedPark (context : Context) : ProtocolContract.ParkSubject where
  name := "the stepped host"
  run := do
    let stage ← Stage.new context context.elaborator (memorySource []) nappingCompiled
    let recorder ← Job.FakeRecorder.new
    let hold ← ProtocolContract.ParkHold.over (← Job.Activity.counting) recorder.recorder
    let told ← IO.mkRef (#[] : Array UInt64)
    let withdrawn ← IO.mkRef (#[] : Array UInt64)
    let held ← IO.mkRef (none : Option Job.Protocol.Transition)
    let staged := stage.collaborators
    let timers := staged.services.timers
    try
      Headless.withStepped
          { staged with
            tracksIdle := false
            services :=
              { staged.services with
                activity := hold.activity, recorder := hold.recorder
                timers :=
                  { timers with
                    cancel := fun id => do
                      timers.cancel id
                      told.modify (·.push id) } }
            endCancelled := fun cancelled => do
              withdrawn.set (← told.get)
              hold.release.resolve ()
              staged.endCancelled cancelled }
          stage.memory (guard := hangGuard) (grace := some hangGuard) fun stepped => do
          stepped.send (.spawn "nap")
          stepped.drain
          held.set
              (←
                ProtocolContract.awaitStep "the nap's step after it gave its unit back"
                    hold.arrived.result?)
    finally
      hold.release.resolve ()
    let held ← held.get
    return {
        asked := ProtocolContract.askedIn (← recorder.trace) ((held.bind (·.job?)).getD 0)
        unitBack := held.isSome && (← hold.unitBack.get)
        withdrawn := (← withdrawn.get).map (·.toNat) }

/-- The checks of the runner's protocol contract on a stepped host. -/
def protocolContractChecks (context : Context) : List Check :=
  [{  name :=
        "a stepped host's jobs record a trace that is a run of the protocol: a nap woken by the clock, one the loop's end cancels, and the loop's end once the jobs it cancelled are done"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource []) nappingCompiled
        let recorder ← Job.FakeRecorder.new
        Headless.withStepped (recording stage.collaborators recorder) stage.memory (guard :=
            hangGuard) (grace := some hangGuard) fun stepped => do
            stepped.send (.spawn "nap")
            stepped.drain
            let first ←
              ProtocolContract.awaitStep "the first nap's park"
                  (← recorder.reached (· matches .park _))
            let number := (first.job?).getD 0
            stage.clock.advance 10
            discard <|
                ProtocolContract.awaitStep "the first nap's done"
                  (← recorder.reached (· == .done number))
            stepped.send (.spawn "nap")
            stepped.drain
            discard <|
                ProtocolContract.awaitStep "the second nap's park"
                  (← recorder.reached (parksOther number))
        let trace ← recorder.trace
        let state ← ProtocolContract.replayed trace
        saw (trace.back? == some .loopEnd && state.jobs.length == 2 && state.count == 0)
            s!"trace={repr trace}" },
    { name :=
        "a stepped host's nap held just after it gave its unit back for its sleep is in a wait the loop's end withdraws"
      run := do
        let observed ← (steppedPark context).run
        saw (ProtocolContract.parkHolds observed) s!"{repr observed}" }]

end ConfigTest
