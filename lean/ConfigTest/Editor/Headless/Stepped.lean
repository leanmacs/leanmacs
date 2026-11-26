import ConfigTest.Check
import ConfigTest.Editor.Headless
import ConfigTest.Support.Configs
import ConfigTest.Support.Gate
import Editor.Config.Session
import Editor.Event
import Editor.Event.Queue
import Editor.Ffi.Events
import Editor.Headless
import Editor.Headless.Stepped
import Editor.Job.Fake
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Shipped

/-!
# Config tests: `Editor/Headless/Stepped.lean`

The tests of a host stepped on the check's own thread
(`Headless.withStepped`): `steppedChecks`; and of the script runner over a
stepped host whose waits step the fakes (`Headless.Stepped.runFrom` over a
stepped stage, `Stage.stepped`): `steppedRunChecks`. Each runs the host over a stage
(`Stage.new`), with the real elaborator, the fake clock and the recorder,
and controls time through a port: the elaborator held at a `Gate`, let go
from the wait's own call before it blocks (`waitBlocked`), never on time.
The root module `ConfigTest` runs them; its module doc says what they show.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- A config of one root file whose `setup` registers nothing. -/
def emptyRoot : List (String × String) :=
  [(Config.rootModule, "def setup : SetupM Unit := pure ()\n")]

/-- `collaborators` with a display whose every request throws: the first
scene the loop publishes makes its turn throw. -/
def brokenDisplay {β σ : Type} (collaborators : Headless.Collaborators β σ TestScheme.scheme) :
    Headless.Collaborators β σ TestScheme.scheme :=
  { collaborators with
    display := fun _ =>
      Headless.Host.Display.over fun _ => throw (IO.userError "the display broke") }

/-- `collaborators` with a recorder display that is kept in `kept` once the
loop has made it, so a check counts the scenes it was published. -/
def keptDisplay {β σ : Type} (collaborators : Headless.Collaborators β σ TestScheme.scheme)
    (kept : IO.Ref (Option Headless.Host.Display)) : Headless.Collaborators β σ TestScheme.scheme :=
  { collaborators with
    display := fun snapshots => do
      let display ← Headless.Host.Display.recorder Headless.cells snapshots
      kept.set (some display)
      return display }

/-- How many scenes the display kept in `kept` has been published. -/
def scenesOf (kept : IO.Ref (Option Headless.Host.Display)) : IO Nat := do
  match ← kept.get with
  | some display =>
    display.published
  | none =>
    return 0

/-- A check of `steppedChecks`, a declaration of its own: the stepped
counterpart of the real host's pause check, which a stepped host's own
activity count shows, read on the check's thread. -/
def steppedPauseHoldsUnitCheck (context : Context) : Check :=
  { name :=
      "a pause of completion at point armed on the fake clock, on a stepped host, holds no unit, and its event holds one from the clock's move until a step has handled it"
    run :=
      IO.FS.withTempDir fun directory => do
        let (stage, collaborators) ←
          shippedStaged TestScheme.scheme context directory [("init.lean", pausedAtPointText)] none
              "/" none id (context.packages.push Test.editingPackage) (stepped := true)
        Headless.withStepped collaborators stage.memory (guard := hangGuard) (grace :=
            some hangGuard) fun stepped => do
            let session := Session.ofStage (Driven.ofStepped stepped) directory stage
            session.ask [.reload]
            session.typed "a b"
            let armed ← stepped.activitySeen
            let waiting ← stage.clock.waiting
            stage.clock.advance 240
            -- The pause's event is queued on the stepped host's queue, and
            -- no step has taken it yet.
            let queued ← stepped.activitySeen
            session.ask []
            let after ← stepped.activitySeen
            saw (armed.running == 0 && waiting == 1 && queued.running == 1 && after.running == 0)
                s!"armed={repr armed} waiting={waiting} queued={repr queued} after={repr after}" }

/-- The checks of a host stepped on the check's own thread. -/
def steppedChecks (context : Context) : List Check :=
  [{  name :=
        "a stepped host over collaborators that carry the library's queue still steps a reload to settled: the bracket installs its own queue"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource emptyRoot)
        let library := stage.collaborators.queue.pulledBy == .library
        let wait ←
          Headless.withStepped stage.collaborators stage.memory (guard := hangGuard) (grace :=
              some hangGuard) fun stepped => do
              stepped.send .reload
              stepped.await hangGuard
        let output ← stage.output.get
        saw (library && wait == .settled && output.any (·.startsWith "reload 1: installed"))
            s!"library={library} wait={repr wait} output={output}" },
    { name := "a check on a stepped stage that posts to the library's editor queue fails, saying so"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let before ← Ffi.queued .editor
        let failed ←
          try
            discard <|
                onStage stage fun _ _ => do
                  discard <| Event.post (.commit "astray")
                  return true
            pure none
          catch error =>
            pure (some (toString error))
        -- The guard says what was posted, and has taken it back off the
        -- queue, so no later host takes it.
        let after ← Ffi.queued .editor
        let named :=
          failed.any fun error =>
            error.startsWith "a stepped host's check posted to the library's editor queue" &&
              (error.splitOn "\"astray\"").length == 2
        saw (named && after <= before) s!"failed={failed} before={before} after={after}" },
    { name :=
        "a stepped host handles a run request and a commit on the check's own thread: every line it emits is the check's thread's, and no loop thread starts"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let before ← context.realLoops.get
        let (wait, lines) ←
          Headless.withStepped stage.collaborators (← Headless.Queue.Memory.new) (guard :=
              hangGuard) (grace := some hangGuard) fun stepped => do
              stepped.send (.run "nothing")
              stepped.input (.commit "é")
              stepped.send .scene
              return (← stepped.await hangGuard, (← stage.output.get).size)
        let mine ← IO.getTID
        let threads ← stage.threads.get
        let after ← context.realLoops.get
        saw (wait == .settled && lines > 1 && threads.all (· == mine) && after == before)
            s!"wait {repr wait}, {lines} lines on {threads}, the check on {mine}, real loops {before} then {after}" },
    { name :=
        "a stepped settle after a reload held at a gate answers settled only after the install, the gate let go from its block on running work, never on time"
      run := do
        let gate ← Gate.new Config.rootModule
        let stage ← Stage.new context (gate.around context.elaborator) (memorySource emptyRoot)
        let order ← IO.mkRef (#[] : Array String)
        let wait ←
          Headless.withStepped stage.collaborators (← Headless.Queue.Memory.new) (guard :=
              hangGuard) (grace := some hangGuard) fun stepped => do
              stepped.send .reload
              stepped.await hangGuard (waitBlocked := fun what => do
                  order.modify
                      (·.push s!"blocked on {what}, installed: {(← stage.output.get).size}")
                  gate.open)
        let output ← stage.output.get
        let order ← order.get
        -- Each block, the first of which lets the gate go, comes before the
        -- install: the elaboration may still run at a later round.
        saw
            (wait == .settled && !order.isEmpty &&
              order.all (· == "blocked on running work, installed: 0") &&
              output.any (·.startsWith "reload 1: installed"))
            s!"wait {repr wait}, {order}, output {output}" },
    { name :=
        "a stepped join with a job asleep on the fake clock answers working at idle and says no hang, and an advance's wait with nothing due within its move answers working, a stall, while one with the job's wait due settles"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource []) nappingCompiled
        let hung ← IO.mkRef (#[] : Array String)
        let (joined, short, due, waiting) ←
          Headless.withStepped stage.collaborators (← Headless.Queue.Memory.new) (guard :=
              hangGuard) (grace := some hangGuard) fun stepped => do
              stepped.send (.run "rest")
              let joined ←
                stepped.join hangGuard (waitHung := fun line => hung.modify (·.push line))
              let advance (milliseconds : Nat) :=
                stepped.waitWhile hangGuard (.advance stage.clock milliseconds) (waitHung :=
                  fun line => hung.modify (·.push line))
              return (joined, ← advance 5, ← advance 10, ← stage.clock.waiting)
        let hung ← hung.get
        saw
            (joined == .working && short == .working && due == .settled && waiting == 1 &&
              hung.isEmpty)
            s!"join {repr joined}, advance 5 {repr short}, advance 10 {repr due}, {waiting} waiting, hung {hung}" },
    { name :=
        "a stepped wait handles an event pushed after its round's drain found the queue empty, in a round that posts no marker, with the activity count unchanged: it wakes on that push, handles it while a reload is held, and only its next block lets the reload go"
      run := do
        let gate ← Gate.new Config.rootModule
        let stage ← Stage.new context (gate.around context.elaborator) (memorySource emptyRoot)
        let pushed ← IO.mkRef false
        let blocks ← IO.mkRef (#[] : Array Bool)
        let wait ←
          Headless.withStepped stage.collaborators (← Headless.Queue.Memory.new) (guard :=
              hangGuard) (grace := some hangGuard) fun stepped => do
              stepped.send .reload
              -- A settle with no marker: no round of it pushes anything of
              -- its own. Its busy runs after the round's drain has found
              -- the queue empty, the reload started and held at the gate:
              -- the first one pushes a request, under no unit, so the
              -- count does not move again and only the push can wake the
              -- block. Had the wait armed its next-push task only after
              -- that, the block would last to the guard.
              let kind : Headless.Wait.Kind :=
                { Headless.Wait.Kind.settle with
                  marker := false
                  busy := fun progress => do
                    unless ← pushed.get do
                      pushed.set true
                      stepped.send .show
                    Headless.Wait.Kind.settle.busy progress }
              stepped.waitWhile hangGuard kind (waitBlocked := fun _ => do
                  let shown := (← stage.output.get).any (·.startsWith "commands:")
                  let block ← blocks.modifyGet fun blocks => (blocks.size, blocks.push shown)
                  if block > 0 then
                    gate.open)
        let output ← stage.output.get
        let shown := output.findIdx? (·.startsWith "commands:")
        let installed := output.findIdx? (·.startsWith "reload 1: installed")
        let blocks ← blocks.get
        -- The first block came before the push was handled, and the second
        -- after it, with the gate still shut: the push woke the first.
        saw
            (wait == .settled && blocks.size ≥ 2 && blocks[0]! == false && blocks[1]! == true &&
              (match shown, installed with
              | some shown, some installed => shown < installed
              | _, _ => false))
            s!"wait {repr wait}, blocks {blocks}, output {output}" },
    steppedPauseHoldsUnitCheck context,
    { name :=
        "a stepped wait that reaches its guard, a reload held for good, says the hang once and answers the hang, and the bracket's end lets the reload go through endWaits and waits for it"
      run := do
        let gate ← Gate.new Config.rootModule
        let stage ← Stage.new context (gate.around context.elaborator) (memorySource emptyRoot)
        let hung ← IO.mkRef (#[] : Array String)
        let ends ← IO.mkRef (#[] : Array String)
        let collaborators :=
          { stage.collaborators with
            endWaits := fun what => do
              ends.modify (·.push what)
              gate.open }
        let wait ←
          Headless.withStepped collaborators (← Headless.Queue.Memory.new) (guard := hangGuard)
              (grace := some hangGuard) fun stepped => do
              stepped.send .reload
              stepped.await heldAtOnce (waitHung := fun line => hung.modify (·.push line))
        let hung ← hung.get
        let ends ← ends.get
        saw
            (wait == .reloading && hung == #[s!"editor: {heldAtOnce.hang}: the settle"] &&
              ends == #["reload"] &&
              (← gate.inProgress.get) == 0)
            s!"wait {repr wait}, hung {hung}, ends {ends}" },
    { name :=
        "a stepped host's end with a reload held past its guard, endWaits letting nothing go, says the hang once through hung and, with grace, gives up as a hang, the reload's task handed to abandoned; with no grace it waits on once the hang is said"
      run := do
        -- The end's guard and grace are 0, and the reload is held at a gate
        -- only the check opens, so it cannot end within either: no timing.
        let ending (grace : Option HangGuard) : IO (Option String × Array String × Bool × Nat) := do
          let gate ← Gate.new Config.rootModule
          let stage ← Stage.new context (gate.around context.elaborator) (memorySource emptyRoot)
          let said ← IO.mkRef (#[] : Array String)
          let left ← IO.mkRef (none : Option (Task (Except IO.Error Unit)))
          let thrown ←
            try
              Headless.withStepped stage.collaborators (← Headless.Queue.Memory.new) (guard :=
                  heldAtOnce) (grace := grace) (hung := fun line => do
                  said.modify (·.push line)
                  -- With no grace the end waits on: the hang said, the
                  -- check lets the reload go.
                  if grace.isNone then
                    gate.open)
                  (abandoned := fun task => left.set (some task)) fun stepped => do
                  stepped.send .reload
                  -- Handled, the reload started and held: nothing waited for.
                  discard <| stepped.waitWhile hangGuard .handled
              pure none
            catch error =>
              pure (some (toString error))
          -- Let go, and waited for, so nothing of the reload outlives the
          -- check.
          gate.open
          let abandoned := (← left.get).isSome
          if let some task← left.get then
            discard <| IO.wait task
          return (thrown, ← said.get, abandoned, ← gate.inProgress.get)
        let (thrown, said, abandoned, left) ← ending (some heldAtOnce)
        let (waited, saidWaiting, abandonedWaiting, leftWaiting) ← ending none
        saw
            (thrown.any
                (fun text =>
                  text.startsWith "a hang: the stepped host's end" &&
                    (text.splitOn "giving up").length == 2) &&
              said == #[Headless.hangLine 0] &&
              abandoned &&
              left == 0 &&
              waited.isNone &&
              saidWaiting == #[Headless.hangLine 0] &&
              !abandonedWaiting &&
              leftWaiting == 0)
            s!"with grace: thrown {thrown}, said {said}, abandoned {abandoned}, {left} elaborating; with none: thrown {waited}, said {saidWaiting}, abandoned {abandonedWaiting}, {leftWaiting} elaborating" },
    { name :=
        "a stepped host's bracket, on return and on throw, cancels its jobs, waits for a held reload after endWaits, and closes its queue: a post after it is refused, and the reload's late wake-up gave its unit back"
      run := do
        let ending (throws : Bool) : IO (Option String × Bool × Nat × Nat × Array String) := do
          let gate ← Gate.new Config.rootModule
          let stage ←
            Stage.new context (gate.around context.elaborator) (memorySource emptyRoot)
                nappingCompiled
          let ends ← IO.mkRef (#[] : Array String)
          let collaborators :=
            { stage.collaborators with
              endWaits := fun what => do
                ends.modify (·.push what)
                gate.open }
          let kept ← IO.mkRef none
          let thrown ←
            try
              Headless.withStepped collaborators (← Headless.Queue.Memory.new) (guard := hangGuard)
                  (grace := some hangGuard) fun stepped => do
                  kept.set (some stepped)
                  stepped.send (.run "rest")
                  discard <| stepped.join hangGuard
                  stepped.send .reload
                  -- Handled, with the reload held: nothing waited for.
                  discard <| stepped.waitWhile hangGuard .handled
                  if throws then
                    throw (IO.userError "the body broke")
              pure none
            catch error =>
              pure (some (toString error))
          let some stepped ← kept.get | return (thrown, false, 1, 1, #[])
          let refused := !(← stepped.queue.post { source := stepped.requests, code := 2 })
          return (thrown, refused, (← stepped.activitySeen).running, ← stage.clock.waiting,
              ← ends.get)
        let returned ← ending false
        let threw ← ending true
        saw
            (returned == (none, true, 0, 0, #["reload"]) &&
              threw == (some "the body broke", true, 0, 0, #["reload"]))
            s!"returned {returned}, threw {threw}" },
    { name :=
        "a stepped host's later waits answer ended once a step stopped its loop, and once a turn threw, and the bracket then throws the turn's error"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let stopped ←
          Headless.withStepped stage.collaborators (← Headless.Queue.Memory.new) (guard :=
              hangGuard) (grace := some hangGuard) fun stepped => do
              stepped.post .stop
              let first ← stepped.await hangGuard
              stepped.send .show
              return (first, ← stepped.join hangGuard)
        let broken ← Stage.new context context.elaborator (memorySource [])
        let waits ← IO.mkRef (#[] : Array Headless.Wait)
        let thrown ←
          try
            Headless.withStepped (brokenDisplay broken.collaborators) (← Headless.Queue.Memory.new)
                (guard := hangGuard) (grace := some hangGuard) fun stepped => do
                -- The commit makes the frame, and its step publishes a scene.
                stepped.input (.commit "x")
                waits.modify (·.push (← stepped.await hangGuard))
                waits.modify (·.push (← stepped.join hangGuard))
            pure none
          catch error =>
            pure (some (toString error))
        let waits ← waits.get
        saw
            (stopped == (.ended, .ended) && waits == #[.ended, .ended] &&
              thrown == some "the display broke")
            s!"stopped {repr stopped}, waits {repr waits}, thrown {thrown}" }]

/-- Runs `script` on `stage`, made stepped (`Stage.stepped`), with the
script runner over the stepped host (`Headless.Stepped.runFrom`), whose
waits step the stage's fakes (`SteppedFakes.work`), with the hang guard and
`onAbort`: what the run came to, and the hangs it said. It fails the check
if the library's editor queue grew (`leavingLibraryQueue`). -/
def runOnFakes {β σ : Type} (stage : Stage β σ) (script : Array Headless.Line)
    (onAbort : IO Unit := Headless.Stepped.refuseAbort)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO (Headless.Ran × Array String) := do
  let said ← IO.mkRef (#[] : Array String)
  let ran ←
    leavingLibraryQueue <|
        Headless.Stepped.runFrom stage.collaborators stage.memory (stage.fakes.map (·.work)) script
          hangGuard (grace := some hangGuard) (waitHung := fun line => said.modify (·.push line))
          (waitBlocked := waitBlocked) (onAbort := onAbort)
  return (ran, ← said.get)

/-- A command `quit` that asks the editor to quit (`Editor.quit`). -/
def quittingCompiled : Compiled :=
  { commands := #[{ name := Quit.name, action := .plain (discard quit) }] }

/-- A stepped stage for a host over the config directory `directory`
holding `files`, with the packages `files` (its fake) and `restore`, over
the fake files holding the state directory `stateDirectory` and `model`,
its session journal the recording fake: what a check of the runner's
`journalled`, `indexed` and `restarted` over the fakes runs on, with the
fake. A restart's probe of `/A.app/Contents/MacOS/editor` passes, its
process fake scripted with that reply. -/
def restartingStage (context : Context) (directory : System.FilePath)
    (files : List (String × String)) (model : FileModel := {}) :
    IO (Stage Config.Elaborate.Base Config.Elaborate.Handle × Headless.RecordingJournal) := do
  writeConfig directory files
  let running : System.FilePath := "/A.app/Contents/MacOS/editor"
  let stage ←
    Stage.new context context.elaborator (Config.Directory.source directory)
        { packages := #[FilesApiTest.fake, Test.Restore.package] }
  let stage ←
    stage.stepped (stateFiles stateDirectory model)
        {
          scripts :=
            #[{ command := Restore.probeCommand running
                reply :=
                  .ok { exit := .code 0, stdout := "probe: ok\n".toUTF8, stderr := .empty } }] }
  let (stage, fake) ← stage.recordingJournal stateDirectory
  return ({ stage with
        collaborators :=
          { stage.collaborators with
            launch := { running := some running, shipped := some running } } },
      fake)

/-- The checks of the script runner over a host stepped on the check's own
thread whose waits step the stage's fakes (`Headless.Stepped.runFrom`,
`Editor/Headless/Stepped.lean`, "A wait over the fakes"): each wait is
answered at the rest of the fakes, never by the activity count, and each
outcome a real host's wait answers at idle is answered at once. The
runner's checks that needed no loop thread were moved here from
`jobChecks` and `scriptChecks`, their names kept (host-tests-on-fakes
phase 6): the runner is the `Headless.Driven` port's, so its directives,
guards and failures are the same over either host. -/
def steppedRunChecks (context : Context) : List Check :=
  [{  name :=
        "spawn, advance and join over the fakes end with the job's result on the check's own thread, with no activity count to read: the waits are judged at the fakes' rest"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource []) { jobs := #[countJob] }
        let stage ← stage.stepped
        -- A host that keeps no count: a wait that read it would never find
        -- the host idle, and would block until its guard.
        let stage :=
          { stage with collaborators := { stage.collaborators with tracksIdle := false } }
        let ((failure, _), said) ←
          runOnFakes stage #[⟨1, .request (.spawn "count")⟩, ⟨2, .advance 10⟩, ⟨3, .join⟩]
        let mine ← IO.getTID
        let output ← stage.output.get
        let threads ← stage.threads.get
        saw
            (failure.isNone && said.isEmpty && output.contains "job 1 count: ok" &&
              threads.all (· == mine))
            s!"failure={repr failure} said={said} output={output} threads={threads} mine={mine}" },
    { name :=
        "a join over the fakes on a job asleep on a clock no advance moves fails at once as working, naming its line, with no hang said"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource []) { jobs := #[countJob] }
        let stage ← stage.stepped
        let ((failure, _), said) ← runOnFakes stage #[⟨1, .request (.spawn "count")⟩, ⟨2, .join⟩]
        saw (failure == some (.working (some 2)) && said.isEmpty)
            s!"failure={repr failure} said={said}" },
    { name := "an advance over the fakes with nothing due stalls at once, naming its line"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let stage ← stage.stepped
        let ((failure, _), said) ← runOnFakes stage #[⟨1, .advance 10⟩]
        saw (failure == some (.stalled 1 10) && said.isEmpty)
            s!"failure={repr failure} said={said}" },
    { name :=
        "a settle over the fakes after a reload held at a gate blocks only on the reload's wake-up, the first block letting the gate go, and settles once the reload is installed"
      run := do
        let gate ← Gate.new Config.rootModule
        let stage ← Stage.new context (gate.around context.elaborator) (memorySource emptyRoot)
        let stage ← stage.stepped
        let blocked ← IO.mkRef (#[] : Array String)
        let ((failure, _), said) ←
          runOnFakes stage #[⟨1, .request .reload⟩, ⟨2, .settle⟩] (waitBlocked := fun what => do
              blocked.modify (·.push what)
              gate.open)
        let blocked ← blocked.get
        let output ← stage.output.get
        saw
            (failure.isNone && said.isEmpty && !blocked.isEmpty &&
              blocked.all (· == "running work") &&
              output.any (·.startsWith "reload 1: installed"))
            s!"failure={repr failure} said={said} blocked={blocked} output={output}" },
    { name :=
        "installed over the fakes settles and goes on once the last reload installed its config; after a rejected reload, or before any reload has finished, it fails at once as not installed, naming its line, with no hang said, and the script stops there"
      run := do
        let ran (files : List (String × String)) (script : Array Headless.Line) :
          IO (Option Headless.Failure × Array String × Array String) := do
          let stage ← Stage.new context context.elaborator (memorySource files)
          let stage ← stage.stepped
          let ((failure, _), said) ← runOnFakes stage script
          return (failure, said, ← stage.output.get)
        let broken := [(Config.rootModule, "def broken : Nat := \"not a number\"\n")]
        let (installed, installedSaid, installedOutput) ←
          ran emptyRoot #[⟨1, .request .reload⟩, ⟨2, .installed⟩, ⟨3, .request .show⟩]
        let (rejected, rejectedSaid, rejectedOutput) ←
          ran broken #[⟨1, .request .reload⟩, ⟨2, .installed⟩, ⟨3, .request .show⟩]
        let (unloaded, unloadedSaid, _) ← ran emptyRoot #[⟨1, .installed⟩]
        saw
            (installed.isNone && installedSaid.isEmpty &&
              installedOutput.any (·.startsWith "reload 1: installed") &&
              installedOutput.any (·.startsWith "commands:") &&
              rejected == some (.notInstalled 2) &&
              rejectedSaid.isEmpty &&
              rejectedOutput.contains "reload 1: rejected" &&
              !rejectedOutput.any (·.startsWith "commands:") &&
              unloaded == some (.notInstalled 1) &&
              unloadedSaid.isEmpty &&
              (((Headless.Failure.notInstalled 2).describe 200).splitOn "line 2").length == 2)
            s!"installed={repr installed} {installedSaid} {installedOutput}; rejected={repr rejected} {rejectedSaid} {rejectedOutput}; unloaded={repr unloaded} {unloadedSaid}" },
    { name :=
        "journalled over the fakes, after typing into a file, has every order of the journal fake worked by the next line, its drain resolved on the check's own thread"
      run :=
        IO.FS.withTempDir fun directory => do
          let notes := stateDirectory / "notes.txt"
          let (stage, journal) ←
            restartingStage context directory greetConfig
                (({} : FileModel).withFile notes "notes".toUTF8)
          let ((failure, _), said) ←
            runOnFakes stage
                #[⟨1, .settle⟩, ⟨2, .request (.open notes.toString)⟩, ⟨3, .settle⟩,
                  ⟨4, .commit "typed "⟩, ⟨5, .journalled⟩]
          let unworked ← journal.unworked
          let orders ← journal.orders
          let mine ← IO.getTID
          let threads := (← journal.state.get).answerThreads
          saw
              (failure.isNone && said.isEmpty && unworked == 0 && !orders.isEmpty &&
                threads.all (· == mine))
              s!"failure={repr failure} said={said} unworked={unworked} orders={orders.size} threads={threads} mine={mine}" },
    { name :=
        "indexed over the fakes moves the clock past the index's write delay, and the index is in the file fake's model"
      run :=
        IO.FS.withTempDir fun directory => do
          let notes := stateDirectory / "notes.txt"
          let (stage, _) ←
            restartingStage context directory greetConfig
                (({} : FileModel).withFile notes "notes".toUTF8)
          let ((failure, _), said) ←
            runOnFakes stage
                #[⟨1, .settle⟩, ⟨2, .request (.open notes.toString)⟩, ⟨3, .settle⟩,
                  ⟨4, .commit "typed "⟩, ⟨5, .indexed⟩]
          let now ← stage.clock.now
          let index ←
            match stage.fakes with
            | some fakes =>
              (lastIndex · stateDirectory) <$> fakes.services.files.model
            | none =>
              pure none
          saw (failure.isNone && said.isEmpty && now ≥ Restore.writeDelay && index.isSome)
              s!"failure={repr failure} said={said} now={now} index={index}" },
    { name :=
        "restarted over the fakes returns the plan of the restart the turn ended the loop with; with no restart asked it fails at once as not restarted, with no hang said"
      run :=
        IO.FS.withTempDir fun directory => do
          let (stage, _) ← restartingStage context directory greetConfig
          let ((failure, plan), said) ←
            runOnFakes stage
                #[⟨1, .settle⟩, ⟨2, .request (.run restartName)⟩, ⟨3, .restarted⟩,
                  ⟨4, .request .show⟩]
          let output ← stage.output.get
          let (stillStage, _) ← restartingStage context directory greetConfig
          let ((still, none), stillSaid) ←
            runOnFakes stillStage #[⟨1, .settle⟩, ⟨2, .restarted⟩] | return false
          saw
              (failure.isNone && plan.isSome && said.isEmpty &&
                !output.any (·.startsWith "commands:") &&
                still == some (.notRestarted 2) &&
                stillSaid.isEmpty)
              s!"failure={repr failure} plan={plan.isSome} said={said} output={output} still={repr still} stillSaid={stillSaid}" },
    { name := "abort over the fakes calls the run's onAbort, and the script stops there"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let stage ← stage.stepped
        let aborted ← IO.mkRef 0
        let ((failure, _), said) ←
          runOnFakes stage #[⟨1, .abort⟩, ⟨2, .request .show⟩] (onAbort := aborted.modify (· + 1))
        let output ← stage.output.get
        saw
            (failure.isNone && said.isEmpty && (← aborted.get) == 1 &&
              !output.any (·.startsWith "commands:"))
            s!"failure={repr failure} said={said} aborted={← aborted.get} output={output}" },
    { name :=
        "a script over the fakes whose command quits the editor stops there: the scene after it is not run"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource []) quittingCompiled
        let stage ← stage.stepped
        let ((failure, _), said) ←
          runOnFakes stage #[⟨1, .request (.run Quit.name)⟩, ⟨2, .settle⟩, ⟨3, .request .scene⟩]
        let output ← stage.output.get
        saw (failure.isNone && said.isEmpty && !output.any (·.startsWith "scene "))
            s!"failure={repr failure} said={said} output={output}" },
    { name :=
        "an advance over the fakes on a host with no fake clock fails at once with its sentence, naming its line, with no hang said"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let stage ← stage.stepped
        let stage := { stage with collaborators := { stage.collaborators with clock := none } }
        let ((failure, _), said) ← runOnFakes stage #[⟨1, .settle⟩, ⟨2, .advance 1⟩]
        saw
            (failure == some (.noClock 2) &&
              (Headless.Failure.noClock 2).describe 200 ==
                s!"the advance on line 2: {Headless.advanceNeedsClock}" &&
              said.isEmpty)
            s!"failure={repr failure} said={said}" },
    { name :=
        "a stepped run disposes of its collaborators once its loop has ended, on success and on failure: dispose is called once, after every line the script had the host print"
      run := do
        let disposing (script : Array Headless.Line) :
          IO (Option Headless.Failure × Array String × Array Nat) := do
          let stage ← Stage.new context context.elaborator (memorySource []) { jobs := #[countJob] }
          let stage ← stage.stepped
          let (failure, _) ←
            Headless.runOnAndDispose
                (Headless.Stepped.hosting stage.memory (stage.fakes.map (·.work)) hangGuard
                  (grace := some hangGuard))
                stage.collaborators script hangGuard (onAbort := Headless.Stepped.refuseAbort)
          return (failure, ← stage.output.get, ← stage.disposed.get)
        let (ran, ranOutput, ranDisposed) ←
          disposing #[⟨1, .request (.spawn "count")⟩, ⟨2, .advance 10⟩, ⟨3, .join⟩]
        let (failed, failedOutput, failedDisposed) ←
          disposing #[⟨1, .request (.spawn "count")⟩, ⟨2, .join⟩]
        saw
            (ran.isNone && ranOutput.contains "job 1 count: ok" &&
              ranDisposed == #[ranOutput.size] &&
              failed == some (.working (some 2)) &&
              failedDisposed == #[failedOutput.size])
            s!"ran={repr ran} {ranOutput} disposed={ranDisposed}; failed={repr failed} {failedOutput} disposed={failedDisposed}" },
    { name :=
        "an indexed that cannot finish, a background job asleep on the fake clock no advance moves, fails at idle, it does not hang: the failure names the indexed's line as the editor idle with a job still running, and nothing is said as a hang"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory napConfig
          let stage ←
            (← Stage.new context context.elaborator (Config.Directory.source directory)).stepped
          -- The clock is never moved, so `nap` never ends: the indexed finds
          -- the host idle with it asleep, and `run` ends its loop. The guard
          -- is a hang guard only, and nothing reaches it.
          let said ← IO.mkRef (#[] : Array String)
          let failure ←
            Headless.Stepped.run stage.collaborators stage.memory (stage.fakes.map (·.work))
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .request (.run "start-nap")⟩,
                  ⟨4, .indexed none⟩, ⟨5, .request .show⟩]
                hangGuard (grace := some hangGuard) (waitHung := fun line =>
                said.modify (·.push line))
          let described := failure.map (Headless.Failure.describe hangGuard.ms)
          let withdrawn ← stage.clock.withdrawn
          let said ← said.get
          saw
              (failure == some (.working (some 4)) &&
                (described.map
                    (·.startsWith
                      "the join or indexed on line 4 of the script found the editor idle with a job still running")) ==
                  some true &&
                withdrawn.size == 1 &&
                said.isEmpty)
              s!"failure={repr failure} described={described} withdrawn={withdrawn} said={said}" },
    { name :=
        "on a stage host, spawn count, advance by its sleep and join end with the job's line, ok; an advance with nothing due stalls at idle, with its line and its milliseconds, saying no hang, and an advance on a host with no fake clock fails with its sentence"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory jobsConfig
          let stage ←
            (← Stage.new context context.elaborator (Config.Directory.source directory)).stepped
          let joined ←
            Headless.Stepped.run stage.collaborators stage.memory (stage.fakes.map (·.work))
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .request (.spawn "count")⟩,
                  ⟨4, .advance 10⟩, ⟨5, .join⟩]
                hangGuard (grace := some hangGuard)
          let output ← stage.output.get
          -- Nothing is due, so the advance finds the host idle and stalls;
          -- its guard is a hang guard only, and nothing reaches it.
          let said ← IO.mkRef (#[] : Array String)
          let stalled ←
            (← Stage.new context context.elaborator (Config.Directory.source directory)).stepped
          let ranOut ←
            Headless.Stepped.run stalled.collaborators stalled.memory (stalled.fakes.map (·.work))
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .advance 5⟩] hangGuard (grace :=
                some hangGuard) (waitHung := fun line => said.modify (·.push line))
          let stalledOutput ← stalled.output.get
          let real ←
            (← Stage.new context context.elaborator (Config.Directory.source directory)).stepped
          let refused ←
            Headless.Stepped.run { real.collaborators with clock := none } real.memory
                (real.fakes.map (·.work)) #[⟨1, .settle⟩, ⟨2, .advance 1⟩] hangGuard (grace :=
                some hangGuard) (waitHung := fun line => said.modify (·.push line))
          let said ← said.get
          saw
              (joined.isNone && output.contains "job 1 count: ok" &&
                ranOut == some (.stalled 3 5) &&
                (Headless.Failure.stalled 3 5).describe 200 ==
                  "the advance on line 3 found the editor idle with no wait due within 5 ms on the clock" &&
                refused == some (.noClock 2) &&
                (Headless.Failure.noClock 2).describe 200 ==
                  s!"the advance on line 2: {Headless.advanceNeedsClock}" &&
                said.isEmpty)
              s!"joined={repr joined} output={output} ranOut={repr ranOut} stalledOutput={stalledOutput} refused={repr refused} said={said}" },
    { name :=
        "an idle answers only once the render loop is at rest: with a frame in flight as it begins, it waits for the frame's end, on the loop's rest and never for a time, and counts from that rest, so a loop then left alone has drawn and been handed nothing"
      run := do
        -- A render loop held mid-frame: it rests only once the frame ends,
        -- and the frame ends only once the idle has asked for the rest, so
        -- an idle that answered on a window of time, or before the rest,
        -- would answer with the frame still in flight.
        let stage ← (← Stage.new context context.elaborator (memorySource [])).stepped
        let order ← IO.mkRef (#[] : Array String)
        let asked ← IO.Promise.new
        let ended ← IO.Promise.new
        let entries ← IO.mkRef (#[] : Array Ffi.JournalEntry)
        let submitted ← IO.mkRef (0 : UInt64)
        let counters : IO Ffi.RenderCounters := do
          return {
              draws := (← entries.get).size.toUInt64, drawsFailed := 0
              framesSubmitted := ← submitted.get, framesReplaced := 0, rowsRebuilt := 0
              rowsReused := 0, glyphsRasterised := 0, glyphsReused := 0, glyphsEvicted := 0
              glyphsSkipped := 0, atlasBytes := 0, journalDropped := 0 }
        let render : Headless.Render :=
          { resting := return some (← ended.isResolved)
            awaitRest := fun bound => do
              order.modify (·.push "rest asked")
              asked.resolve ()
              return some (← Job.awaitWithin bound ended.result?).isSome
            journal := fun after => return some ((← entries.get).filter (·.serial > after))
            counters := some <$> counters }
        -- The frame in flight ends once the rest is asked, from a task of
        -- its own, joined below.
        let frame ←
          IO.asTask (prio := .dedicated) do
              let some () ← Job.awaitWithin hangGuard asked.result? | return ()
              entries.modify
                  (·.push
                    { serial := 1, inputNs := 0, drawNs := 0, presentNs := 0, rowsRebuilt := 0
                      rowsReused := 0 })
              submitted.modify (· + 1)
              order.modify (·.push "frame ended")
              ended.resolve ()
        let collaborators :=
          { stage.collaborators with
            render := some render
            emit := fun line => do
              if line.startsWith "idle" then
                order.modify (·.push line)
              stage.collaborators.emit line }
        let failure ←
          Headless.Stepped.run collaborators stage.memory (stage.fakes.map (·.work)) #[⟨1, .idle⟩]
              hangGuard (grace := some hangGuard)
        -- Whatever the run did, the frame's task ends before the check does.
        ended.resolve ()
        asked.resolve ()
        discard <| IO.wait frame
        let order ← order.get
        saw
            (failure.isNone &&
              order ==
                #["rest asked", "frame ended", "rest asked",
                  "idle: 0 frames drawn, 0 frames submitted"])
            s!"failure={repr failure} order={order}" },
    { name :=
        "a real config that defines a segment and lists the mode line installs: the reload prints a line for the segment nobody registered, the echo area says it, and each status line is the listing's, in its order and on its sides"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory
              [("init.lean",
                  "def setup : SetupM Unit := do\n  defineSegment \"greeting\" fun _ =>\n    #[{ text := \"hi\", face := ⟨\"mode-line.secondary\"⟩, padding := 4 }]\n  modeLine [\"buffer\", \"nope\"] [\"greeting\", \"line-column\"]\n")]
          let stage ←
            (← Stage.new context context.elaborator (Config.Directory.source directory)).stepped
          let failure ←
            Headless.Stepped.run stage.collaborators stage.memory (stage.fakes.map (·.work))
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .commit "ab"⟩, ⟨4, .request .scene⟩]
                hangGuard (grace := some hangGuard)
          let output ← stage.output.get
          return failure == none &&
              output.filter (fun line => !line.startsWith "scene " && !line.startsWith "view ") ==
                #["reload 1: installed, 1 files, 0 commands",
                  "segment: no segment is registered as `nope`",
                  "status 0 in mode-line.active: mode-line.buffer \"scratch\" +4 | mode-line.secondary \"hi\" +4, mode-line.secondary \"1:3\" +4"] &&
              output.any fun line =>
                line.startsWith "scene " &&
                  (line.splitOn
                        s!"echo {"reload: no segment is registered as `nope`".quote}").length ==
                    2 },
    { name :=
        "a settle with its own milliseconds waits that long, not the run's patience, and its failure says how long it waited"
      run := do
        let gate ← Gate.new
        IO.FS.withTempDir fun directory => do
            writeConfig directory slowConfig
            let stage ←
              (←
                    Stage.new context (gate.around context.elaborator)
                        (Config.Directory.source directory)).stepped
            let said ← IO.mkRef (#[] : Array String)
            try
              -- A pin of a bound of the headless mode: the reload is held
              -- open for good. The run's guard is a minute, so a failure now
              -- is the settle's own fifth of a second, said as a hang once.
              -- The loop's end waits for the elaboration it lets go, under
              -- the checks' hang guard.
              let hung ← IO.mkRef (#[] : Array String)
              let failure ←
                Headless.Stepped.run { stage.collaborators with endWaits := fun _ => gate.open }
                    stage.memory (stage.fakes.map (·.work))
                    #[⟨3, .request .reload⟩, ⟨7, .settleWithin 200⟩, ⟨8, .request .show⟩]
                    (.on "the run's other waits" 60000) (guard := hangGuard) (hung := fun line =>
                    hung.modify (·.push line)) (waitHung := fun line => said.modify (·.push line))
              let said ← said.get
              let hung ← hung.get
              saw
                  (failure == some (.waited 200 (.reloading (some 7))) && said.size == 1 &&
                    -- The hang names the settle's own guard, not the run's.
                    said.all (·.contains (HangGuard.on "the settle" 200).hang) &&
                    hung.isEmpty)
                  s!"failure={repr failure} said={said} hung={hung}"
            finally
              gate.open },
    { name := "a join with its own seconds has them as its guard, and its failure names them"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory jobsConfig
          let stage ←
            (← Stage.new context context.elaborator (Config.Directory.source directory)).stepped
          -- The clock is never moved, so the job never ends: the join finds
          -- the host idle, and its failure names the join's own second, the
          -- guard it had.
          let failure ←
            Headless.Stepped.run stage.collaborators stage.memory (stage.fakes.map (·.work))
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .request (.spawn "count")⟩,
                  ⟨5, .join (some 1)⟩, ⟨6, .request .show⟩]
                hangGuard (grace := some hangGuard)
          let output ← stage.output.get
          saw (failure == some (.waited 1000 (.working (some 5))))
              s!"failure={repr failure} output={output}" },
    { name :=
        "a restarted with its own seconds waits that long for a hand-over, not the run's patience, and its failure says how long it waited"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory jobsConfig
          let stage ←
            (← Stage.new context context.elaborator (Config.Directory.source directory)).stepped
          -- No restart is asked for, so none comes: its own patience of
          -- none at all is the guard its failure names, where the run's would
          -- be long.
          let said ← IO.mkRef (#[] : Array String)
          let failure ←
            Headless.Stepped.run stage.collaborators stage.memory (stage.fakes.map (·.work))
                #[⟨1, .restarted (some 0)⟩] hangGuard (grace := some hangGuard) (waitHung :=
                fun line => said.modify (·.push line))
          let said ← said.get
          saw
              -- Over the fakes the restarted is answered at once, so no
              -- hang is said; the failure still names its own guard.
              (failure == some (.waited 0 (.notRestarted 1)) && said.isEmpty)
              s!"failure={repr failure} said={said}" },
    { name :=
        "a script that ends while a reload cannot finish fails at its end, with a reload still running and no line"
      run := do
        let gate ← Gate.new
        IO.FS.withTempDir fun directory => do
            writeConfig directory slowConfig
            let stage ←
              (←
                    Stage.new context (gate.around context.elaborator)
                        (Config.Directory.source directory)).stepped
            let said ← IO.mkRef (#[] : Array String)
            try
              -- A pin of a bound of the headless mode: the reload is held for
              -- good, so only the guard ends the wait at the script's end,
              -- and it says the hang once. The loop's end waits for the
              -- elaboration it lets go, under the checks' hang guard.
              let hung ← IO.mkRef (#[] : Array String)
              let failure ←
                Headless.Stepped.run { stage.collaborators with endWaits := fun _ => gate.open }
                    stage.memory (stage.fakes.map (·.work)) #[⟨1, .request .reload⟩] heldShort
                    (guard := hangGuard) (hung := fun line => hung.modify (·.push line))
                    (waitHung := fun line => said.modify (·.push line))
              let said ← said.get
              let hung ← hung.get
              saw (failure == some (.reloading none) && said.size == 1 && hung.isEmpty)
                  s!"failure={repr failure} said={said} hung={hung}"
            finally
              gate.open },
    { name :=
        "a script that resizes the frame and asks for the scene prints the scene in a frame of that size, with its one view in the whole of it above the bottom row, one 16-pixel cell of the recorder; a second resize is the next scene's size"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory greetConfig
          let stage ←
            (← Stage.new context context.elaborator (Config.Directory.source directory)).stepped
          let failure ←
            Headless.Stepped.run stage.collaborators stage.memory (stage.fakes.map (·.work))
                #[⟨1, .resize 640 480⟩, ⟨2, .request .scene⟩, ⟨3, .resize 320 200⟩,
                  ⟨4, .request .scene⟩]
                hangGuard (grace := some hangGuard)
          return failure == none &&
              (← stage.output.get) ==
                #["scene 640x480, focused 0, echo \"\", echo padding 8, preedit -, theme \"default\"",
                  "view 0 0,0 640x464: \"\", scroll 0, selections 0..0, padding 8 8", statusOf,
                  "scene 320x200, focused 0, echo \"\", echo padding 8, preedit -, theme \"default\"",
                  "view 0 0,0 320x184: \"\", scroll 0, selections 0..0, padding 8 8", statusOf] },
    { name :=
        "a script that commits text and asks for the scene prints the scene: its frame, and a view whose snapshot holds the text, read from the library, with the cursor after it"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory greetConfig
          let stage ←
            (← Stage.new context context.elaborator (Config.Directory.source directory)).stepped
          let failure ←
            Headless.Stepped.run stage.collaborators stage.memory (stage.fakes.map (·.work))
                #[⟨1, .request .scene⟩, ⟨2, .commit "héllo"⟩, ⟨3, .request .scene⟩,
                  ⟨4, .commit " world"⟩, ⟨5, .request .scene⟩]
                hangGuard (grace := some hangGuard)
          return failure == none &&
              (← stage.output.get) ==
                #["scene: none",
                  "scene 0x0, focused 0, echo \"\", echo padding 8, preedit -, theme \"default\"",
                  "view 0 0,0 0x0: \"héllo\", scroll 0, selections 6..6, padding 8 8",
                  statusOf (modified := true) (cursor := ⟨0, 5⟩),
                  "scene 0x0, focused 0, echo \"\", echo padding 8, preedit -, theme \"default\"",
                  "view 0 0,0 0x0: \"héllo world\", scroll 0, selections 12..12, padding 8 8",
                  statusOf (modified := true) (cursor := ⟨0, 11⟩)] },
    { name :=
        "the scene prints each view's status line after the view's line, with the fields the loop gives the view: the buffer's name alone before anything is typed, and the modified field after it once text is committed"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory greetConfig
          let stage ←
            (← Stage.new context context.elaborator (Config.Directory.source directory)).stepped
          let failure ←
            Headless.Stepped.run stage.collaborators stage.memory (stage.fakes.map (·.work))
                #[⟨1, .key { logical := .named ⟨"F5"⟩ }⟩, ⟨2, .request .scene⟩, ⟨3, .commit "a"⟩,
                  ⟨4, .request .scene⟩]
                hangGuard (grace := some hangGuard)
          return failure == none && statusOf != statusOf (modified := true) &&
              (← stage.output.get) ==
                #["key arrived: <F5> - -",
                  "scene 0x0, focused 0, echo \"\", echo padding 8, preedit -, theme \"default\"",
                  "view 0 0,0 0x0: \"\", scroll 0, selections 0..0, padding 8 8", statusOf,
                  "scene 0x0, focused 0, echo \"\", echo padding 8, preedit -, theme \"default\"",
                  "view 0 0,0 0x0: \"a\", scroll 0, selections 1..1, padding 8 8",
                  statusOf (modified := true) (cursor := ⟨0, 1⟩)] }]

end ConfigTest
