import Editor.Display
import Editor.Display.Real
import Editor.Event
import Editor.Event.Queue
import Editor.Face
import Editor.Ffi.Display
import Editor.Ffi.Events
import Editor.Ffi.Window
import Editor.Headless
import Editor.Menu
import Editor.Text.Real
import Editor.Window.Real
import Editor.WindowCheck
import Editor.WindowCheck.Real
import FfiTest.Check
import FfiTest.Support.Queues
import FfiTest.Support.Windows

/-!
# FFI tests: `Editor/Ffi/Window.lean`

The tests of `Editor/Ffi/Window.lean`: `windowChecks`. The root module `FfiTest`
runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- What a run of the scripted window that was asked things showed: the next
event after the sample, and what the window says it was asked. -/
structure AskedRun where
  /-- The run, as `runScripted` gives it. -/
  ran : WindowRun
  /-- The first event pulled after the sample's and the requests. -/
  after : Option Editor.Ffi.Event
  /-- What the scripted window says it was asked in this run. -/
  asked : Option (Array Editor.Ffi.WindowAsked)

/-- Runs the scripted window as `runScripted` does, but once its sample has
been pulled runs `ask`, which asks the window things, pulls the `changes`
events the requests make the window report (one for each change of
fullscreen), and reads what the window was asked, before closing it. -/
def runScriptedWhile (ask : IO Unit) (changes : Nat := 1) : IO AskedRun := do
  let run ← IO.asTask (prio := .dedicated) (Editor.Ffi.windowRun .scripted true)
  let mut events := #[]
  for _ in [0:(windowSample true).length] do
    let some event ← pull .editor | break
    events := events.push event
  ask
  let after ← pull .editor
  for _ in [1:changes] do
    discard <| pull .editor
  let asked ← Editor.Ffi.windowAsked .scripted
  Editor.Ffi.windowClose .scripted
  let result ← (← Editor.Job.awaitWithin patience run).mapM IO.ofExcept
  return { ran := { events := events.toList, stamped := true, waited := true, result }, after,
           asked }

/-- Runs the scripted window as `runScriptedWhile` does, asking it
`requests` in order through the library, which change fullscreen once. -/
def runScriptedAsking (requests : List Editor.Ffi.WindowRequest) : IO AskedRun :=
  runScriptedWhile do
    for request in requests do
      Editor.Ffi.windowRequest .scripted request

/-- The requests in `asked`, without the titles, the menu bars and the
backgrounds: each is the presenter's, sent when the window opens if a scene
bound to it named one, or a frame was presented. -/
def requestsOf (asked : Array Editor.Ffi.WindowAsked) : Array Editor.Ffi.WindowRequest :=
  asked.filterMap fun
    | .request request => some request
    | .title _ | .menu _ | .background .. | .close => none

/-- What the window mode's closer (`Editor.Window.closeOnceEnded`) did once a
loop that ended with `ended` had: whether it said the loop ended well, the
lines it said, the requests the scripted window was asked, and how many
times the shutdown ran. -/
structure Closed where
  /-- What the closer returned. -/
  well : Bool
  /-- The lines it said. -/
  said : Array String
  /-- What the scripted window was asked in its run, without titles. -/
  asked : Array Editor.Ffi.WindowRequest
  /-- How many times the shutdown ran. -/
  shutdowns : Nat

/-- Runs the scripted window on a dedicated task, pulls its sample, and runs
the window mode's closer on a loop that ended with `ended`, with a shutdown
that counts its runs; `none` if the window's run did not return once the
closer had closed it, in which case it is closed again so that no run is
left behind. -/
def closedOnceEnded (ended : Except IO.Error Unit) : IO (Option Closed) := do
  let run ← IO.asTask (prio := .dedicated) (Editor.Ffi.windowRun .scripted true)
  for _ in [0:(windowSample true).length] do
    discard <| pull .editor
  let said ← IO.mkRef #[]
  let shutdowns ← IO.mkRef 0
  let well ←
    Editor.Window.closeOnceEnded .scripted (Task.pure ended) (shutdowns.modify (· + 1)) (say :=
        fun line => said.modify (·.push line))
  if (← Editor.Job.awaitWithin patience run).isNone then
    Editor.Ffi.windowClose .scripted
    return none
  let asked := requestsOf ((← Editor.Ffi.windowAsked .scripted).getD #[])
  return some { well, said := ← said.get, asked, shutdowns := ← shutdowns.get }

/-- Whether `events` are those of `windowSample composition`, in order, each
from the window source of the window number 1. -/
def isWindowSample (composition : Bool) (events : List Editor.Ffi.Event) : Bool :=
  events.all (·.source == { kind := .window, id := 1 }) &&
    events.map (fun event => (event.kind, event.code, event.text, event.words)) ==
      windowSample composition

/-- Runs the keyboard check (`Editor/WindowCheck.lean`) over the real
bindings, on `platform`, and returns the lines of its report and its exit
status; `none` if it did not end in time, in which case the window is closed
so that no run is left behind. The check blocks until the window has closed,
so it runs on a dedicated task. -/
def checkOn (platform : Editor.Ffi.Platform) (composition : Bool) :
    IO (Option (List String × UInt32)) := do
  let lines ← IO.mkRef #[]
  let window := Editor.WindowCheck.real platform fun line => lines.modify (·.push line)
  let task ← IO.asTask (prio := .dedicated) (Editor.WindowCheck.check window { composition })
  let some status ← Editor.Job.awaitWithin patience task |
    Editor.Ffi.windowClose platform
    return none
  let status ← IO.ofExcept status
  return some ((← lines.get).toList, status)

/-- The lines of the keyboard check's report on the scripted platform; `none`
if the check did not end in time. -/
def checkScripted (composition : Bool) : IO (Option (List String)) :=
  return (← checkOn .scripted composition).map (·.1)

/-- What `windowRun` returns on `platform`; `none` if it does not return in
time, in which case the window is closed so that no run is left behind. -/
def runUntilReturn (platform : Editor.Ffi.Platform) :
    IO (Option (Except String Editor.Ffi.WindowRan)) := do
  let run ← IO.asTask (prio := .dedicated) (Editor.Ffi.windowRun platform true)
  let some ran ← Editor.Job.awaitWithin patience run |
    Editor.Ffi.windowClose platform
    return none
  return some (← IO.ofExcept ran)

/-- Whether `result` is a run that returned and failed for exactly `reason`. -/
def failedFor (reason : String) : Option (Except String Editor.Ffi.WindowRan) → Bool
  | some (.error actual) => actual == reason
  | _ => false

/-- The checks of the window's bindings, on the library's scripted platforms:
nothing opens and no display is needed. A run blocks until the window is
closed, so each runs on a dedicated task, and the events are pulled on
dedicated tasks too. None of them quits the queues.

Three run the keyboard check's own loop over the bindings: what
`editor window-check` runs on the real window. One is on the scripted
platform whose renderer cannot be made: the glue's path for a window that
ran with nothing drawing in it, which the real platform takes on a machine
with no usable GPU. The last three are on the scripted platform that cannot
open a window: the glue's path for a failure, which the real platform takes
only on a machine with no display. -/
def windowChecks (_ : Unit) : List Check :=
  [{
      name :=
        "a window's inputs arrive on the editor queue in order, from the window source, with the kind, the code and the text of each, the first of them that the window opened, with the platform's name",
      run := return isWindowSample true (← runScripted true).events },
    { name := "run with composition not allowed, the same window reports no composition event"
      run := return isWindowSample false (← runScripted false).events },
    { name :=
        "each of a window's events is stamped on the input clock: with a stamp that is set, is not before the stamp of the event before it, and is not after the clock's reading once the event is pulled"
      run := do
        let ran ← runScripted true
        return ran.stamped && ran.events.length == (windowSample true).length },
    { name :=
        "running a window returns only after the window is closed, and says that it ran with something drawing in it"
      run := do
        let ran ← runScripted true
        return ran.waited && ran.result matches some (.ok { nothingDrew := none }) },
    { name :=
        "a window whose renderer cannot be made runs, reports its inputs and waits for its close all the same, and then says why nothing drew in it, whole"
      run := do
        let ran ← runScripted true .scriptedUndrawn
        let said :=
          match ran.result with
          | some (.ok { nothingDrew := some reason }) => reason == scriptedNoRenderer
          | _ => false
        return isWindowSample true ran.events && ran.waited && said },
    { name :=
        "an input posted as a window would report it arrives on the editor queue as the window's event, stamped, and words that do not read as an input are refused and queue nothing"
      run := do
        let words := #[1024, 768, (1.5 : Float).toBits, 16, 32]
        let short ← Editor.Ffi.postInput .resize 0 "" #[1024, 768]
        let notWindow ← Editor.Ffi.postInput .message 0 "" #[]
        let posted ← Editor.Ffi.postInput .resize 0 "" words
        let some event ← pull .editor | return false
        return !short && !notWindow && posted && event.source == { kind := .window, id := 1 } &&
            event.kind == .resize &&
            event.code == 0 &&
            event.words == words &&
            event.stamp > 0 },
    { name :=
        "the scripted window is opened with the composition and the title bar a run asks for, and the real platform records nothing"
      run := do
        let standard ← runScripted false (titleBar := .standard)
        let afterStandard ← Editor.Ffi.windowOpenedWith .scripted
        let themed ← runScripted true
        let afterThemed ← Editor.Ffi.windowOpenedWith .scripted
        return standard.result matches some (.ok _) && themed.result matches some (.ok _) &&
            afterStandard == some (false, .standard) &&
            afterThemed == some (true, .themed) &&
            (← Editor.Ffi.windowOpenedWith .winit) == none },
    { name :=
        "asked while the scripted window runs, a fullscreen request and a minimise request are what the window was asked, in that order, and entering fullscreen arrives on the editor queue as a resize in fullscreen at the size the window last said"
      run := do
        let ran ← runScriptedAsking [.enterFullscreen, .minimise]
        let resized :=
          match ran.after.map Editor.Event.ofFfi with
          | some (.ok { event := .resize size, .. }) =>
            size == { width := 800, height := 600, scale := 2.0, fullscreen := true }
          | _ => false
        return isWindowSample true ran.ran.events &&
            (ran.asked.map requestsOf) == some #[.enterFullscreen, .minimise] &&
            resized &&
            ran.ran.result matches some (.ok _) },
    { name :=
        "the light and the dark appearance asked while the scripted window runs are what the window was asked, in order among the other requests, and report nothing of their own"
      run := do
        let ran ← runScriptedAsking [.lightAppearance, .enterFullscreen, .darkAppearance]
        let resized :=
          match ran.after.map Editor.Event.ofFfi with
          | some (.ok { event := .resize size, .. }) => size.fullscreen
          | _ => false
        return isWindowSample true ran.ran.events &&
            (ran.asked.map requestsOf) ==
              some #[.lightAppearance, .enterFullscreen, .darkAppearance] &&
            resized &&
            ran.ran.result matches some (.ok _) },
    { name :=
        "asked while the scripted window runs, keeping running crosses as its own tag and is what the window was asked, before the fullscreen request after it"
      run := do
        -- Keeping running reports nothing; the enter after it gives the run
        -- the resize it waits for.
        let ran ← runScriptedAsking [.keepRunning, .enterFullscreen]
        return isWindowSample true ran.ran.events &&
            (ran.asked.map requestsOf) == some #[.keepRunning, .enterFullscreen] &&
            ran.ran.result matches some (.ok _) },
    { name :=
        "once the editor loop has ended with an error, the window mode's closer says so, runs the shutdown once and asks the window to keep running before it closes it, so that a system quit pending is refused and the run returns; once it has ended well, the closer says nothing and asks nothing"
      run := do
        let some failed ← closedOnceEnded (.error (IO.userError "the loop broke")) | return false
        let some fine ← closedOnceEnded (.ok ()) | return false
        return !failed.well &&
            failed.said == #["editor: the editor loop ended with an error: the loop broke"] &&
            failed.asked == #[.keepRunning] &&
            failed.shutdowns == 1 &&
            fine.well &&
            fine.said == #[] &&
            fine.asked == #[] &&
            fine.shutdowns == 1 },
    { name :=
        "a frame request asked of the real display binding made over the scripted platform, directly and through the window mode's host display, is what the scripted window was asked, in order"
      run := do
        let table ← Editor.Snapshots.new
        let display ← Editor.Ffi.Display.newCells 8 16
        let real ←
          Editor.RealDisplay.over display table.reader Editor.Theme.builtin (platform :=
              some .scripted)
        let hosted ← Editor.Window.hostDisplay display .scripted table.reader
        -- Entering and leaving fullscreen each change it: two resizes.
        let ran ←
          runScriptedWhile (changes := 2) do
              discard <| (Editor.Display.askFrame .enterFullscreen).runReal real
              hosted.handle (.frame .leaveFullscreen)
              hosted.handle (.frame .minimise)
              hosted.handle (.frame .keepRunning)
        return (ran.asked.map requestsOf) ==
              some #[.enterFullscreen, .leaveFullscreen, .minimise, .keepRunning] &&
            ran.ran.result matches some (.ok _) },
    { name :=
        "a request to a window that is not running is not recorded, and the real platform records nothing"
      run := do
        Editor.Ffi.windowRequest .scriptedFailing .enterFullscreen
        Editor.Ffi.windowRequest .scriptedFailing .minimise
        Editor.Ffi.windowRequest .scriptedFailing .keepRunning
        return (← Editor.Ffi.windowAsked .scriptedFailing) == some #[] &&
            (← Editor.Ffi.windowAsked .winit) == none },
    { name :=
        "a background in what a window was asked reads as its three bytes, and a byte's word above 255 or a background cut short reads as nothing"
      run :=
        pure <|
          Editor.Ffi.askedOf #[8, 0x2e, 0x34, 0x40, 2] ==
              some #[.background 0x2e 0x34 0x40, .request .minimise] &&
            Editor.Ffi.askedOf #[8, 0x2e, 0x134, 0x40] == none &&
            Editor.Ffi.askedOf #[8, 0x2e] == none },
    { name := "the input clock is never 0 and does not go back"
      run := do
        let first ← Editor.Ffi.inputClock
        return first > 0 && first <= (← Editor.Ffi.inputClock) },
    { name :=
        "the keyboard check over the bindings reports what the scripted window sent: that it opened, the focus, four key events of which three are presses and one is dead, the text they typed, a composition with one preedit and one commit, and that the window was closed"
      run := do
        let some lines ← checkScripted true | return false
        return lines.length == 8 &&
            lines[0]? ==
              some
                "window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes" &&
            lines[1]?.any (·.startsWith "window: opened by scripted ") &&
            lines[2]?.any (·.startsWith "focus: gained ") &&
            lines[3]? ==
              some
                "keys: 4 key events reached the Lean loop (3 presses, 0 of them repeats, 1 releases); text: \"aé\"" &&
            lines[4]?.any (·.endsWith "(4 samples)") &&
            lines[5]? == some "dead keys: 1 key events marked dead" &&
            lines[6]? ==
              some "composition: enabled; 1 preedit and 1 commit events; committed: \"é\"" &&
            lines[7]? == some "ended: the window was closed" },
    { name :=
        "run with composition not allowed, the keyboard check reports the same keys and no composition"
      run := do
        let some lines ← checkScripted false | return false
        return lines.length == 8 &&
            lines[0]? ==
              some
                "window-check: composition off, limit 120 s; the main-thread service is on the process's main thread: yes" &&
            lines[3]? ==
              some
                "keys: 4 key events reached the Lean loop (3 presses, 0 of them repeats, 1 releases); text: \"aé\"" &&
            lines[6]? ==
              some "composition: not enabled; 0 preedit and 0 commit events; committed: \"\"" &&
            lines[7]? == some "ended: the window was closed" },
    { name :=
        "running a window that cannot be opened returns the platform's reason, whole, and does so again on a second run"
      run := do
        let first ← runUntilReturn .scriptedFailing
        let second ← runUntilReturn .scriptedFailing
        return failedFor scriptedFailure first && failedFor scriptedFailure second },
    { name :=
        "a window that cannot be opened puts nothing on the editor queue, and closing it does nothing"
      run := do
        let ran ← runUntilReturn .scriptedFailing
        Editor.Ffi.windowClose .scriptedFailing
        -- The message is the first event of the queue: the run queued nothing.
        return failedFor scriptedFailure ran && (← roundTrips 11 1 "after the run that failed") },
    { name :=
        "the keyboard check over the bindings on a window that cannot be opened prints its eight lines, with the platform's reason in the second, and ends with status 1"
      run := do
        let some (lines, status) ← checkOn .scriptedFailing true | return false
        return lines.length == 8 &&
            lines[0]? ==
              some
                "window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes" &&
            lines[1]? == some s!"window: could not open: {scriptedFailure}" &&
            lines[7]? == some "ended: the window never opened" &&
            status == 1 },
    { name :=
        "the window mode's report says only the halves of a presentation the run asked for, and nothing when it asked for none"
      run :=
        pure
          (Editor.Window.askedText (none, none) == "nothing" &&
            Editor.Window.askedText (some .mailbox, none) == "mailbox" &&
            Editor.Window.askedText (none, some 2) == "a frame latency of 2" &&
            Editor.Window.askedText (some .immediate, some 3) ==
              "immediate at a frame latency of 3") }]

end FfiTest
