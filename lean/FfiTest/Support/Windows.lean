import Editor.Ffi.Events
import Editor.Ffi.Window
import FfiTest.Support.Queues

/-!
# FFI tests: support: Windows

The scripted window: an unidentified key, a sample of what the window was asked,
and a scripted run of it. Shared by several test modules; it holds no checks of
its own.
-/

namespace FfiTest

/-- The words of a key the scripted platform could not identify, with no
modifier held. -/
def unidentifiedKey : Array UInt64 :=
  #[0, 0, 0, 0, 0]

/-- What the library's scripted platform reports of its window, as the kind,
the code, the text and the words of each event: that it opened, with the
platform's name; the focus gained; `a` pressed, the character `a` on the key
`KeyA` (75, 101, 121, 65) with shift and control (bits 1 and 2); `a`
released, unidentified; the dead key `´` (180) pressed; `é` pressed,
unidentified; then, when composition is allowed, a composition enabled, its
preedit and its commit; the secondary button (2) pressed at (12.5, 40) with
alt (bit 4); the window resized to 800 by 600 at scale 2; and a request to
close. A float is its bits. -/
def windowSample (composition : Bool) :
    List (Editor.Ffi.EventKind × UInt64 × String × Array UInt64) :=
  [(.windowOpened, 0, "scripted", #[]), (.windowFocus, 1, "", #[]),
      (.key, 1, "a", #[1, 1, 97, 1, 4, 75, 101, 121, 65, 3]), (.key, 0, "", unidentifiedKey),
      (.key, 5, "", #[3, 1, 180, 0, 0, 0]), (.key, 1, "é", unidentifiedKey)] ++
    (if composition then
      [(.composition, 0, "", #[]), (.composition, 1, "´", #[]), (.composition, 2, "é", #[])]
    else []) ++
    [(.pointer, 0, "", #[(12.5 : Float).toBits, (40.0 : Float).toBits, 2, 0, 4, 0, 0, 0]),
      (.resize, 0, "", #[800, 600, (2.0 : Float).toBits, 0, 0]), (.closeRequested, 0, "", #[])]

/-- What one run of the scripted platform's window showed. -/
structure WindowRun where
  /-- The events pulled from the editor queue while the window ran, in order. -/
  events : List Editor.Ffi.Event
  /-- Whether every event had a stamp that was set, was not before the stamp
  of the event before it, and was not after the input clock's reading once
  the event was pulled. -/
  stamped : Bool
  /-- Whether `windowRun` was still running once every event had been pulled
  and before the window was closed. -/
  waited : Bool
  /-- What `windowRun` returned after the close; `none` if it did not return
  in time. -/
  result : Option (Except String Editor.Ffi.WindowRan)

/-- Runs the window of `platform`, a scripted one that opens, on a dedicated
task, pulls as many events from the editor queue as its sample has, closes
the window and waits for the run. It always closes the window, so a check
that fails leaves no run behind to hold the main-thread service. -/
def runScripted (composition : Bool) (platform : Editor.Ffi.Platform := .scripted)
    (titleBar : Editor.Ffi.TitleBar := .themed) : IO WindowRun := do
  let run ←
    IO.asTask (prio := .dedicated)
        (Editor.Ffi.windowRun platform composition (titleBar := titleBar))
  let mut events := #[]
  let mut stamped := true
  let mut last : UInt64 := 0
  for _ in [0:(windowSample composition).length] do
    let some event ← pull .editor | break
    let pulledAt ← Editor.Ffi.inputClock
    stamped := stamped && event.stamp > 0 && last <= event.stamp && event.stamp <= pulledAt
    last := event.stamp
    events := events.push event
  IO.sleep 20
  let waited := !(← IO.hasFinished run)
  Editor.Ffi.windowClose platform
  let result ←
    if ← eventually (IO.hasFinished run) then
      some <$> IO.ofExcept run.get
    else
      pure none
  return { events := events.toList, stamped, waited, result }

end FfiTest
