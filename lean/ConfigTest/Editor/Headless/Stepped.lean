import ConfigTest.Check
import ConfigTest.Support.Configs
import ConfigTest.Support.Gate
import ConfigTest.Support.Hosts
import Editor.Config.Session
import Editor.Event
import Editor.Event.Queue
import Editor.Ffi.Events
import Editor.Headless
import Editor.Headless.Stepped
import Editor.Job.Fake

/-!
# Config tests: `Editor/Headless/Stepped.lean`

The tests of a host stepped on the check's own thread
(`Headless.withStepped`): `steppedChecks`. Each runs the host over a stage
(`Stage.new`), with the real elaborator, the fake clock and the recorder,
and controls time through a port: the elaborator held at a `Gate`, let go
from the wait's own call before it blocks (`waitBlocked`), never on time.
The root module `ConfigTest` runs them; its module doc says what they show.
-/

namespace ConfigTest

open Editor

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

/-- The window event the library's editor queue holds next among those of
a window, pulling past any other: a check that posted one by mistake takes
it back, so no later host takes it. `none` once the queues are quit. -/
partial def windowPulled : IO (Option Ffi.Event) := do
  let event ← Ffi.nextEvent .editor
  if event.kind == .quit then
    return none
  if event.source.kind == .window then
    return some event
  windowPulled

/-- The checks of a host stepped on the check's own thread. -/
def steppedChecks (context : Context) : List Check :=
  [{  name :=
        "a stepped host over collaborators that carry the library's queue still steps a reload to settled: the bracket installs its own queue"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource emptyRoot)
        let library := stage.collaborators.queue.pulledBy == .library
        let wait ←
          Headless.withStepped stage.collaborators stage.memory (guard := patience) (grace :=
              some hangGuard) fun stepped => do
              stepped.send .reload
              stepped.await hangGuard
        let output ← stage.output.get
        saw (library && wait == .settled && output.any (·.startsWith "reload 1: installed"))
            s!"library={library} wait={repr wait} output={output}" },
    { name := "a check on a stepped stage that posts to the library's editor queue fails, saying so"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let failed ←
          try
            discard <|
                onStage stage fun _ _ => do
                  discard <| Event.post (.commit "astray")
                  return true
            pure none
          catch error =>
            pure (some (toString error))
        -- Taken back, so no later host takes it.
        let pulled ← windowPulled
        saw
            (failed.any
                (·.startsWith "a stepped host's check posted to the library's editor queue") &&
              pulled.any (·.text == "astray"))
            s!"failed={failed} pulled={repr pulled}" },
    { name :=
        "a stepped host handles a run request and a commit on the check's own thread: every line it emits is the check's thread's, and no loop thread starts"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let before ← context.realLoops.get
        let (wait, lines) ←
          Headless.withStepped stage.collaborators (← Headless.Queue.Memory.new) (guard := patience)
              (grace := some hangGuard) fun stepped => do
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
          Headless.withStepped stage.collaborators (← Headless.Queue.Memory.new) (guard := patience)
              (grace := some hangGuard) fun stepped => do
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
          Headless.withStepped stage.collaborators (← Headless.Queue.Memory.new) (guard := patience)
              (grace := some hangGuard) fun stepped => do
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
          Headless.withStepped stage.collaborators (← Headless.Queue.Memory.new) (guard := patience)
              (grace := some hangGuard) fun stepped => do
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
              Headless.withStepped (keptDisplay collaborators kept) memory (guard := patience)
                (grace := some hangGuard) fun stepped => do
                stepped.send (.run "rest")
                discard <| stepped.await hangGuard
                let settled ← scenesOf kept
                discard <| stepped.join hangGuard
                return [settled, ← scenesOf kept]
        let keptReal ← IO.mkRef none
        let real ←
          counts fun collaborators =>
              Headless.withHost (keptDisplay collaborators keptReal) (guard := patience) (grace :=
                some hangGuard) fun host => do
                host.send (.run "rest")
                discard <| host.await hangGuard
                let settled ← scenesOf keptReal
                discard <| host.join hangGuard
                return [settled, ← scenesOf keptReal]
        saw (stepped == real && stepped.length == 2) s!"stepped {stepped}, real {real}" },
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
          Headless.withStepped collaborators (← Headless.Queue.Memory.new) (guard := patience)
              (grace := some hangGuard) fun stepped => do
              stepped.send .reload
              stepped.await 0 (waitHung := fun line => hung.modify (·.push line))
        let hung ← hung.get
        let ends ← ends.get
        saw
            (wait == .reloading && hung.size == 1 && ends == #["reload"] &&
              (← gate.inProgress.get) == 0)
            s!"wait {repr wait}, hung {hung}, ends {ends}" },
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
              Headless.withStepped collaborators (← Headless.Queue.Memory.new) (guard := patience)
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
          Headless.withStepped stage.collaborators (← Headless.Queue.Memory.new) (guard := patience)
              (grace := some hangGuard) fun stepped => do
              stepped.post .stop
              let first ← stepped.await hangGuard
              stepped.send .show
              return (first, ← stepped.join hangGuard)
        let broken ← Stage.new context context.elaborator (memorySource [])
        let waits ← IO.mkRef (#[] : Array Headless.Wait)
        let thrown ←
          try
            Headless.withStepped (brokenDisplay broken.collaborators) (← Headless.Queue.Memory.new)
                (guard := patience) (grace := some hangGuard) fun stepped => do
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

end ConfigTest
