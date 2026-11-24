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
`spawn`, `run` and `reload` requests, drains them on its own thread, moves
the stage's fake clock, and waits only on the recorder's events and the
queue's pushes, never on a driver's wait. The bracket's end cancels what is
left and waits for every job cancelled and not yet done, those cancelled
before it by a keyed cancel or an owner's removal included
(`Collaborators.endCancelled`, which `Stage.new` sets), then records the
loop's end. The stages are `Stage.new` alone, never a stepped stage
(`Stage.stepped`): the subject is the runner's protocol on real job
threads, on Lean's pool, held at the recorder's events, so their jobs stay
off the fake scheduler. The root module `ConfigTest` runs them; its module
doc says what they show.

The park check (`steppedPark`) is one function over the park's order
(`ParkOrder`), run twice: in the runner's own order (`runnerOrder`), where
the property holds, and in the order before the runner-park fix
(`preFixOrder`), where it must fail, held at the job's `ask` with its unit
given back and no wait recorded for the cancel to withdraw. The pre-fix
order is a wrapper of the count and the recorder the stepped host's runner
is given, written here, its one user: the runner is not touched and takes
no seam for it. Its park is still one section, which alone writes the
token and moves the job's unit as the model says, and every access to its
table is still one `Completions.critical`; the wrapper only moves the
count's unit around that section, as the old runner did around its token
write. The editor's wiring imports no test module and gives the runner its
own count and `Recorder.none`, which tells no transition for an order to
act on, and the proofs, which are of the model, see none of it.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- Whether `transition` is a park of a job other than `job`. -/
def parksOther (job : Nat) : Job.Protocol.Transition → Bool
  | .park other => other != job
  | _ => false

/-- What compiled code hands the host of the check of jobs cancelled before
the loop's end: `nappingCompiled`'s job `nap`, and the commands
`rest-keyed`, which starts it under the key `nap`, and `halt`, which
cancels the job of that key. -/
def keyedNapping : Compiled :=
  { nappingCompiled with
    commands :=
      nappingCompiled.commands ++
        #[{ name := "rest-keyed", action := .plain (discard <| startJob "nap" [] (some "nap")) },
          { name := "halt", action := .plain (cancelJob "nap") }] }

/-- A config whose `setup` registers the job `doze`, config's own, which
sleeps 10 ms on the job clock: a reload that installs cancels it. -/
def dozingText : String :=
  "def setup : SetupM Unit := do\n  job \"doze\" (fun _ => sleep 10) fun _ => pure ()\n"

/-- Drains `stepped`'s queue until `done` holds of `stage`'s output: each
round arms the queue's next-push task before it drains, so a post that
comes after the drain found the queue empty ends the wait
(`Queue.Memory.arrived`). It waits on that push, an event; `what` names it,
and only a hang reaches `ProtocolContract.patience`. -/
def drainUntil {β σ : Type} (stage : Stage β σ) (stepped : Headless.Stepped) (what : String)
    (done : Array String → Bool) : IO Unit := do
  repeat
    let arrived ← stepped.memory.arrived
    stepped.drain
    if done (← stage.output.get) then
      return
    discard <| ProtocolContract.awaitStep what arrived

/-- An order of a job's park, as the two collaborators the park moves and
tells see it: the count (`Job.Activity`) and the recorder (`Job.Recorder`)
a stepped host's runner is given. `over` wraps the ones the check's hold
sees (`ProtocolContract.ParkHold`), so the hold sees the job's unit given
back and the transitions told in the order the park makes them. -/
structure ParkOrder where
  /-- Which order, as a check names it. -/
  name : String
  /-- The count and the recorder the runner is given, over the hold's. -/
  over : Job.Activity → Job.Recorder → BaseIO (Job.Activity × Job.Recorder)

/-- The runner's own order: the count and the recorder as they are, so the
park gives the job's unit back in the section that records its wait. -/
def runnerOrder : ParkOrder where
  name := "the stepped host"
  over activity recorder := pure (activity, recorder)

/-- The order of the park before the runner-park fix (784962e3), put
together around the real runner from the two collaborators its park moves
and tells: a job asking a wait that parks gives its unit back once its
`ask` has taken effect, before its `park` records the wait, as the old
`drive` (784962e3's parent) called `activity.done` before it set the
token's wait.

- **The unit given back early.** At the `ask` of a wait that parks, told
  applied on the job's thread, the job's unit is given back first, then the
  `applied` is passed on: the job's first step out of a section after its
  unit went back is that `ask`, where the hold comes, its wait not yet
  recorded.
- **The park's own give is absorbed.** The `park`'s section then gives the
  unit back as the model says (`Protocol.JobState.step`); the next `done` on
  that thread, inside that section, is not passed on, as the old runner's
  token write moved no unit.
- **A park that kept the unit takes one back.** A `park` of a job cancelled
  in between, or whose wait ended first, keeps the job's unit in the model;
  told it is recorded, inside its section, with the unit given early still
  out, the order takes one, as the old wait's end took one before it
  resolved. So the count is back at the runner's at the end of the park,
  and the job's `done` is never refused.

The runner is not touched: it still applies and records its park in one
section, and it alone writes the token, so the trace records an `ask` and
then a `park` as the model has them; only the count, which the host's idle
reads, sees the unit back before the wait is recorded. It needs a recorder
that records (`Recorder.on`); the check's fake does. -/
def preFixOrder : ParkOrder where
  name := "the stepped host in the park's order before the runner-park fix"
  over activity recorder := do
    -- The threads that gave their job's unit back early and whose park is
    -- not yet recorded, each with whether the park's own give has been
    -- absorbed.
    let early ← IO.mkRef (#[] : Array (UInt64 × Bool))
    return ({ activity with
          done := do
            let thread ← IO.getTID
            let absorbed ←
              early.modifyGet fun gave =>
                  match gave.findIdx? fun (held, absorbed) => held == thread && !absorbed with
                  | some index => (true, gave.modify index fun (held, _) => (held, true))
                  | none => (false, gave)
            unless absorbed do
              activity.done },
        { recorder with
          record := fun transition => do
            recorder.record transition
            if transition matches .park _ then
              let thread ← IO.getTID
              let absorbed? ←
                early.modifyGet fun gave =>
                    ((gave.find? (·.1 == thread)).map (·.2), gave.filter (·.1 != thread))
              if absorbed? == some false then
                activity.begin
          applied := fun transition => do
            if transition matches .ask _ _ .parks then
              activity.done
              let thread ← IO.getTID
              early.modify (·.push (thread, false))
            recorder.applied transition })

/-- The park subject of a stepped host's real runner, its park in `order`:
the stage's count is this subject's own (`tracksIdle := false`), wrapped to
note each `done`'s thread, and the recorder holds the nap's thread at its
first transition after its unit's `done` (`ProtocolContract.ParkHold`),
which in the runner's own order is its park; `order` wraps both. While it
is held the body returns, so the loop's end cancels the job; the stage's
clock, wrapped, notes each wait it is told to withdraw, and the wrapped
`endCancelled` reads what was withdrawn as the cancel returned, then lets
the hold go before it hands over to the stage's wait for the job. A
`finally` lets it go too. A held call, never a sleep. -/
def steppedPark (context : Context) (order : ParkOrder) : ProtocolContract.ParkSubject where
  name := order.name
  run := do
    let stage ← Stage.new context context.elaborator (memorySource []) nappingCompiled
    let recorder ← Job.FakeRecorder.new
    let hold ← ProtocolContract.ParkHold.over (← Job.Activity.counting) recorder.recorder
    let (activity, recording) ← order.over hold.activity hold.recorder
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
                activity, recorder := recording
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

/-- A check that `subject` holds the park property (`parkHolds`), or with
`holds` false, that it breaks it where its hold came and its job had asked
a wait: the cancel made there withdrew none of it. -/
def parkCheck (subject : ProtocolContract.ParkSubject) (holds : Bool := true) : Check :=
  { name :=
      if holds then
        s!"{subject.name}: a nap held just after it gave its unit back for its sleep is in a wait the loop's end withdraws"
      else
        s!"{subject.name}: a nap held just after it gave its unit back for its sleep is in no wait the loop's end withdraws"
    run := do
      let observed ← subject.run
      saw
          (if holds then ProtocolContract.parkHolds observed
          else observed.unitBack && observed.asked.isSome && !ProtocolContract.parkHolds observed)
          s!"{repr observed}" }

/-- The file the cancel-after-wake check's load asks for, in its fake file
service's model. -/
def protocolFile : System.FilePath :=
  "/protocol/a.txt"

/-- The streaming command the cancel-after-wake check's start asks for, which
its fake process service is scripted for: it writes nothing and exits. -/
def protocolCommand : Process.Command :=
  { program := "/bin/protocol", directory := "/protocol" }

/-- What compiled code hands the host of the cancel-after-wake checks: the
jobs `protocol-load`, which loads `protocolFile`, and `protocol-start`,
which starts `protocolCommand` as a streaming child
(`ProtocolContract.loader`, `starter`); the commands `load-keyed` and
`start-keyed`, which start each under the key `protocol`; and `halt`,
which cancels the job of that key. -/
def protocolCompiled : Compiled :=
  { commands :=
      #[{ name := "load-keyed"
          action := .plain (discard <| startJob "protocol-load" [] (some "protocol")) },
        { name := "start-keyed"
          action := .plain (discard <| startJob "protocol-start" [] (some "protocol")) },
        { name := "halt", action := .plain (cancelJob "protocol") }]
    jobs :=
      #[{ name := "protocol-load", work := fun _ => ProtocolContract.loader protocolFile },
        { name := "protocol-start", work := fun _ => ProtocolContract.starter protocolCommand }] }

/-- Whether `trace`, a stepped host's, is the run of one job cancelled after
its service woke it and before it recorded the wait: start, ask of a
service wait, the wake, the cancel, the serve that drops the request, the
resume, the job's done, then the loop's end. -/
def cancelledAfterWake (trace : Array Job.Protocol.Transition) : Bool :=
  match trace.toList with
  |
  [.start job, .ask asker wait .service, .wake woken .completed, .cancel cancelled, .serve served,
      .resume resumed, .done done, .loopEnd] =>
    asker == job && woken == wait && cancelled == job && served == job && resumed == job &&
      done == job
  | _ => false

/-- The cancel-after-wake check on a stepped host (task
`stepped-host-cancel-after-wake-drop-check`): a job whose service completes
its wait inside its start (the stage's file and process fakes, answering at
once), started by `command` under the key `protocol`, is held by the
recorder at its wake (`hold`), on its job thread on Lean's pool, before it
records the wait; the keyed cancel (`halt`) goes through the host's table
of jobs there; let go, the job's serve drops the request at its service.
The stage stays on the pool, as `protocolContractChecks` do: a held job
thread is the shape the property needs. What `kept` reads of the fakes
must hold, and the trace must be that run and a run of the protocol. -/
def steppedCancelAfterWake (context : Context) (name command : String)
    (hold : Job.Protocol.Transition → Bool)
    (kept : Job.FakeFiles → Job.FakeProcesses → IO (Bool × String)) : Check :=
  { name
    run := do
      let stage ← Stage.new context context.elaborator (memorySource []) protocolCompiled
      let completions := stage.collaborators.services.completions
      let files ←
        Job.FakeFiles.new completions
            ((({} : FileModel).withDirectory "/protocol").withFile protocolFile "a\n".toUTF8)
      let processes ←
        Job.FakeProcesses.new completions { streams := #[{ command := protocolCommand }] }
      let recorder ← Job.FakeRecorder.new
      let staged := recording stage.collaborators recorder
      let staged :=
        { staged with
          services :=
            { staged.services with
              files := files.files, processes := processes.processes } }
      let (woken, letGo) ← recorder.holdAt hold
      try
        Headless.withStepped staged stage.memory (guard := hangGuard) (grace := some hangGuard)
            fun stepped => do
            stepped.send (.run command)
            stepped.drain
            discard <| ProtocolContract.awaitStep "the wait's wake inside its start" woken
            stepped.send (.run "halt")
            stepped.drain
            letGo
      finally
        letGo
      let trace ← recorder.trace
      let state ← ProtocolContract.replayed trace
      let (held, said) ← kept files processes
      saw (cancelledAfterWake trace && state.count == 0 && held)
          s!"trace={repr trace} {said} output={← stage.output.get}" }

/-- The two cases of the cancel-after-wake check: a file load and a
streaming start, each held at its wake. -/
def cancelAfterWakeChecks (context : Context) (hold : Job.Protocol.Transition → Bool) :
    List Check :=
  [steppedCancelAfterWake context
      "a stepped host's job whose load its file service completed before the job recorded it, cancelled by its key there, drops the load at the file service by its serve: nothing is pending there, the load is withdrawn, and the trace is a run of the protocol"
      "load-keyed" hold fun files _ => do
      let state ← files.state.get
      return (state.withdrawn.size == 1 && state.pending.isEmpty,
          s!"withdrawn={state.withdrawn} pending={state.pending.size}"),
    steppedCancelAfterWake context
      "a stepped host's job whose streaming start its process service completed before the job recorded it, cancelled by its key there, drops the start at the process service by its serve: the start is withdrawn, no child is left, nothing waits and nothing was taken, and the trace is a run of the protocol"
      "start-keyed" hold fun _ processes => do
      let withdrawn ← processes.withdrawn
      let model ← processes.model
      let waiting ← processes.waiting
      let taken ← processes.taken
      return (withdrawn.size == 1 && model.children.isEmpty && waiting == 0 && taken.isEmpty,
          s!"withdrawn={withdrawn} children={model.children.size} waiting={waiting} taken={taken}")]

/-- The checks of the runner's protocol contract on a stepped host. -/
def protocolContractChecks (context : Context) : List Check :=
  [{    name :=
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
          "a stepped host's loop's end waits for the jobs cancelled before it, by a keyed cancel and by an owner's removal, and records its end only once they are done: the trace is a run of the protocol"
        run := do
          let stage ←
            Stage.new context context.elaborator (memorySource [("init", dozingText)]) keyedNapping
          let recorder ← Job.FakeRecorder.new
          let staged := recording stage.collaborators recorder
          -- Each cancelled job is held at its resume, its wait withdrawn, until
          -- the loop's end hands over what it waits for; a `finally` lets them
          -- go too. A held call, never a sleep.
          let releases ← IO.mkRef (#[] : Array (BaseIO Unit))
          let letGo : BaseIO Unit := do
            for release in ← releases.get do
              release
          let handed ← IO.mkRef (none : Option Nat)
          let (keyed, dozing) ←
            try
              Headless.withStepped
                  { staged with
                    endCancelled := fun cancelled => do
                      handed.set (some cancelled.size)
                      -- A loop's end that hands over none of them records its
                      -- end with them still held.
                      unless cancelled.isEmpty do
                        letGo
                      staged.endCancelled cancelled }
                  stage.memory (guard := hangGuard) (grace := some hangGuard) fun stepped => do
                  stepped.send .reload
                  drainUntil stage stepped "the first reload's report"
                      (·.any (·.startsWith "reload 1: installed"))
                  -- The keyed nap, parked, then cancelled by its key.
                  stepped.send (.run "rest-keyed")
                  stepped.drain
                  let keyed :=
                    ((←
                            ProtocolContract.awaitStep "the keyed nap's park"
                                (← recorder.reached (· matches .park _))).job?).getD
                      0
                  let (keyedHeld, release) ← recorder.holdAt (· == .resume keyed)
                  releases.modify (·.push release)
                  stepped.send (.run "halt")
                  stepped.drain
                  discard <| ProtocolContract.awaitStep "the keyed nap's resume" keyedHeld
                  -- Config's doze, parked, then cancelled by the reload that
                  -- installs, which removes config's jobs.
                  stepped.send (.spawn "doze")
                  stepped.drain
                  let dozing :=
                    ((←
                            ProtocolContract.awaitStep "the doze's park"
                                (← recorder.reached (parksOther keyed))).job?).getD
                      0
                  let (dozeHeld, release) ← recorder.holdAt (· == .resume dozing)
                  releases.modify (·.push release)
                  stepped.send .reload
                  drainUntil stage stepped "the second reload's report"
                      (·.any (·.startsWith "reload 2: installed"))
                  discard <| ProtocolContract.awaitStep "the doze's resume" dozeHeld
                  return (keyed, dozing)
            finally
              letGo
          for job in [keyed, dozing] do
            discard <|
                ProtocolContract.awaitStep s!"job {job}'s done"
                  (← recorder.reached (· == .done job))
          let trace ← recorder.trace
          let state ← ProtocolContract.replayed trace
          let handed ← handed.get
          saw
              (trace.back? == some .loopEnd && handed == some 2 && trace.contains (.cancel keyed) &&
                trace.contains (.cancel dozing) &&
                state.jobs.length == 2 &&
                state.count == 0)
              s!"handed={handed} trace={repr trace}" },
      parkCheck (steppedPark context runnerOrder),
      parkCheck (steppedPark context preFixOrder) (holds := false)] ++
    cancelAfterWakeChecks context (· matches .wake _ .completed)

end ConfigTest
