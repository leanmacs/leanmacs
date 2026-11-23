import Editor.Bound
import Editor.Ffi.Events
import Editor.Ffi.Words
import Editor.Menu

/-!
# Bindings: the window

The bindings of `crates/editor-ffi/src/window.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("The window").

`windowPresentation` is here too: `editor_glue_window_presentation` is
`window.rs`'s.
-/

namespace Editor.Ffi

open Words

/-- Which of the library's platforms runs the window. -/
inductive Platform where
  /-- The library's scripted platform, a fake for tests: it opens nothing,
  needs no display, and reports one fixed script. -/
  | scripted
  /-- The real window, over winit. It needs a display. -/
  | winit
  /-- The library's scripted platform that cannot open a window, a fake for
  tests: every run fails at once, with one fixed reason. -/
  | scriptedFailing
  /-- The library's scripted platform whose window nothing can draw in, a
  fake for tests: it opens and reports as `scripted` does, but its renderer
  cannot be made, with one fixed reason, as a machine with no usable GPU
  gives. -/
  | scriptedUndrawn
  deriving DecidableEq, Repr

/-- A way a frame reaches the display, by wgpu's names
(`crates/editor-render-wgpu/src/present.rs`): what a run may ask for in
place of the renderer's decision, to measure it. -/
inductive PresentMode where
  /-- Frames wait for the display's refresh: no tearing. -/
  | fifo
  /-- As `fifo`, but a late frame is shown at once, tearing. -/
  | fifoRelaxed
  /-- A frame is shown the moment it is presented, tearing. -/
  | immediate
  /-- The newest frame replaces one waiting, at the refresh. -/
  | mailbox
  deriving DecidableEq, Repr

/-- The tag a present mode crosses as; 0 is none asked. -/
def PresentMode.tag : Option PresentMode → UInt8
  | none => 0
  | some .fifo => 1
  | some .fifoRelaxed => 2
  | some .immediate => 3
  | some .mailbox => 4

/-- What a run of the window answers, as the glue builds it: a reason, then
how the run ended (0 it ran and something drew in it, with no reason; 1 no
window ran; 2 it ran and nothing drew in it). Object fields first, so the
order here is the layout the glue writes. -/
private structure RawWindowRun where
  /-- Why no window ran, or why nothing drew in it; empty when it ran and
  something drew. -/
  reason : String
  /-- How the run ended. -/
  status : UInt64

/-- The title bar a window opens with (`editor_ffi_window_run`'s tags 0 and
1, in this order). -/
inductive TitleBar where
  /-- The drawable area extends under a title bar that draws no background
  of its own, so what is drawn there shows through: the window says how far
  down it covers the drawable area on every resize. A platform with no such
  title bar opens a standard one. -/
  | themed
  /-- The system's own title bar, above the drawable area. -/
  | standard
  deriving DecidableEq, Repr, Inhabited

/-- `windowRun` as it crosses. The title bar is its tag, the present mode
its tag and the frame latency a number, each 0 for none asked. -/
@[extern "editor_glue_window_run"]
private opaque windowRunRaw (platform : Platform) (composition : Bool) (titleBar : TitleBar)
    (presentMode : UInt8) (frameLatency : UInt32) : IO RawWindowRun

/-- How a window that opened ran, once it has closed. -/
structure WindowRan where
  /-- Why nothing drew in the window, when nothing did: its renderer could
  not be made (no adapter, no device, no surface), or the render thread did
  not end well. The window ran all the same, and what it reported
  arrived. -/
  nothingDrew : Option String := none
  deriving DecidableEq, Repr

/-- Runs the window on `platform`, with an input method allowed to compose
or not and the title bar `titleBar`, and returns once the window has
closed: `.ok` when it ran, saying
why nothing drew in it when nothing did, and `.error` with the reason when
no window could be opened.

The library's main-thread service runs the window's loop, and this blocks
until the loop has ended, so call it from Lean's main thread or a dedicated
task, never from the thread pool. While it runs, the main-thread service
answers nothing else: `mainThreadProbe` would wait for the window to close.

What the window reports arrives on the editor queue, from the window source,
each event stamped with the reading of `inputClock` when the window reported
it. The window does not close by itself: when the user asks, a
`closeRequested` event arrives, and the window stays open until
`windowClose`.

While the window is open, what a display bound to the presenter publishes
(`Display.present`) is drawn in it, at the scale the window says. A run may
ask for a present mode and a frame latency in place of the renderer's
decision, to measure them; `none` is the decision. -/
def windowRun (platform : Platform) (composition : Bool) (presentMode : Option PresentMode := none)
    (frameLatency : Option Nat := none) (titleBar : TitleBar := .themed) :
    IO (Except String WindowRan) := do
  let latency := (frameLatency.getD 0).toUInt32
  let raw ← windowRunRaw platform composition titleBar (PresentMode.tag presentMode) latency
  return match raw.status with
    | 0 => .ok {}
    | 2 => .ok { nothingDrew := some raw.reason }
    | _ => .error raw.reason

/-- Asks the window `platform` is running to close, so that `windowRun`
ends. Any thread may call it, and it does nothing when that platform runs
no window.

With the system's quit pending (`EventKind.quitRequested`) the close lets
the quit go ahead, and the platform may end the process inside `windowRun`,
which then never returns (the window port's rule, `Platform::close` in
`editor-platform`; AppKit's terminate on macOS). So whatever must happen
before the program ends happens before this is called. A
`WindowRequest.keepRunning` asked just before it refuses the quit instead,
and `windowRun` returns. -/
@[extern "editor_glue_window_close"]
opaque windowClose (platform : Platform) : IO Unit

/-- `windowAwaitParked` as it crosses: its guard in milliseconds. -/
@[extern "editor_glue_window_await_parked"]
private opaque windowAwaitParkedRaw (platform : Platform) (boundMs : UInt64) : IO Bool

/-- Waits until the scripted window of `platform` is parked, its run waiting
for its close with nothing to report and no close asked, and says whether
it was: false at once for the real platform and for a scripted one that
cannot open, and once `guard` has run out first. With no run yet it waits
for the run to start and park, so a test can start `windowRun` on a task and
then wait. A readout for tests: it returns on the park, never by a window of
time. Only a run that never parks reaches the guard. -/
def windowAwaitParked (platform : Platform) (guard : HangGuard) : IO Bool :=
  windowAwaitParkedRaw platform guard.ms.toUInt64

/-- What Lean asks of the window (`editor_ffi_window_request`, its tags 0, 1,
2, 4, 6 and 7: `WindowRequest.tag`). The title is not one: it is a field of
the scene, and the tag 3 is the title's in what a scripted window was
asked, as 5 is a menu bar's. -/
inductive WindowRequest where
  /-- Put the window in the system's fullscreen; one in it stays there. -/
  | enterFullscreen
  /-- Take the window out of the system's fullscreen; one out of it stays
  out. -/
  | leaveFullscreen
  /-- Minimise the window. -/
  | minimise
  /-- The editor refused, or withdrew, the quit the system asked
  (`EventKind.quitRequested`). It changes nothing the window shows, and a
  platform with no quit pending does nothing with it. Asked just before
  `windowClose`, it refuses a quit pending as the window closes, so that
  `windowRun` returns. -/
  | keepRunning
  /-- Draw the window's title and buttons in the system's light
  appearance, for a light paper. -/
  | lightAppearance
  /-- Draw the window's title and buttons in the system's dark appearance,
  for a dark paper. -/
  | darkAppearance
  deriving DecidableEq, Repr

/-- The library's number for `request`: 0, 1, 2, 4, 6 and 7. It is not the
constructor's index, which for `keepRunning` would be the title's 3, and
for the appearances 4 and 5, keep running's and a menu bar's. -/
def WindowRequest.tag : WindowRequest → UInt8
  | .enterFullscreen => 0
  | .leaveFullscreen => 1
  | .minimise => 2
  | .keepRunning => 4
  | .lightAppearance => 6
  | .darkAppearance => 7

/-- `windowRequest` as it crosses: the request's tag. -/
@[extern "editor_glue_window_request"]
private opaque windowRequestRaw (platform : Platform) (tag : UInt8) : IO Unit

/-- Asks the window `platform` is running to do what `request` says. Any
thread may call it, it never blocks, and it does nothing when that platform
runs no window. It goes through the window's own loop, not the main-thread
service. Whether the window is then in fullscreen comes back on the editor
queue, as a resize. -/
def windowRequest (platform : Platform) (request : WindowRequest) : IO Unit :=
  windowRequestRaw platform request.tag

/-- One thing a scripted window was asked: a request, a title or a menu bar
the presenter sent it from a scene, or a background it sent from a frame's
ground. -/
inductive WindowAsked where
  /-- A request Lean made. -/
  | request (request : WindowRequest)
  /-- A title. -/
  | title (text : String)
  /-- A menu bar. -/
  | menu (menu : Menu)
  /-- A background the presenter sent it from a frame's ground: the
  theme's paper, as its sRGB red, green and blue. -/
  | background (red green blue : UInt8)
  /-- The close (`windowClose`), in its place among the requests. -/
  | close
  deriving DecidableEq, Repr

/-- The word of `modifiers` as the library reads it ("The window", in the
module docs): shift 1, control 2, alt 4, the system key 8. The one encoding
on the Lean side, for an event posted (`EventWords`), a menu's key
equivalent in a scene (`RealDisplay.encodeMenu`) and what a window was
asked (`askedOf`). -/
def modifierBits (modifiers : Modifiers) : UInt64 :=
  (if modifiers.shift then 1 else 0) ||| (if modifiers.control then 2 else 0) |||
    (if modifiers.alt then 4 else 0) |||
    (if modifiers.superKey then 8 else 0)

/-- The modifiers the word `bits` holds (`modifierBits`); `none` when it has
a bit past the system key's. -/
def modifiersOfBits? (bits : UInt64) : Option Modifiers :=
  if bits &&& ~~~15 != 0 then none
  else
    some
      { shift := bits &&& 1 != 0, control := bits &&& 2 != 0, alt := bits &&& 4 != 0,
        superKey := bits &&& 8 != 0 }

/-- Reads the words of what a window was asked, from an index on: each
reader gives what it read and the index after it, or `none` when the
words spell nothing. -/
private abbrev AskedReader :=
  StateT Nat Option

/-- The next word. -/
private def AskedReader.word (words : Array UInt64) : AskedReader UInt64 := fun at_ =>
  words[at_]?.map (·, at_ + 1)

/-- A count of things, each at least one word, that the words left can
hold. -/
private def AskedReader.count (words : Array UInt64) : AskedReader Nat := do
  let count := (← AskedReader.word words).toNat
  if count ≤ words.size - (← get) then
    pure count
  else
    failure

/-- The character the scalar value `scalar` numbers, if it is one. -/
private def AskedReader.char? (scalar : UInt64) : Option Char :=
  if scalar < 0x110000 && Nat.isValidChar scalar.toNat then some (Char.ofNat scalar.toNat) else none

/-- A text: the count of its scalar values, and each of them. -/
private def AskedReader.text (words : Array UInt64) : AskedReader String := do
  let count ← AskedReader.count words
  let chars ←
    (List.range count).mapM fun _ => do
        let some char := AskedReader.char? (← AskedReader.word words) | failure
        pure char
  return String.ofList chars

/-- A menu bar in the layout of `editor-ffi`'s `menu.rs`: its menus, each
with its title, its role and its items. -/
private def AskedReader.menu (words : Array UInt64) : AskedReader Menu := do
  let word := AskedReader.word words
  let menus ←
    (List.range (← AskedReader.count words)).mapM fun _ => do
        let title ← AskedReader.text words
        let role ←
          match ← word with
          | 0 =>
            pure none
          | 1 =>
            pure (some MenuRole.app)
          | 2 =>
            pure (some MenuRole.window)
          | _ =>
            failure
        let items ←
          (List.range (← AskedReader.count words)).mapM fun _ => do
              match ← word with
              | 0 =>
                pure MenuItem.separator
              | kind@(1 : UInt64) | kind@2 =>
                do
                  let title ← AskedReader.text words
                  let (present, scalar, bits) := (← word, ← word, ← word)
                  let key ←
                    match present with
                    | 0 =>
                      pure none
                    | 1 =>
                      do
                        let some character := AskedReader.char? scalar | failure
                        let some modifiers := modifiersOfBits? bits | failure
                        pure (some { character, modifiers })
                    | _ =>
                      failure
                  let action ←
                    if kind == 1 then
                      MenuAction.command <$> AskedReader.text words
                    else
                      match ← word with
                      | 0 =>
                        pure (.system .about)
                      | 1 =>
                        pure (.system .services)
                      | 2 =>
                        pure (.system .hide)
                      | 3 =>
                        pure (.system .hideOthers)
                      | 4 =>
                        pure (.system .showAll)
                      | 5 =>
                        pure (.system .quit)
                      | _ =>
                        failure
                  pure (MenuItem.item title key action)
              | _ =>
                failure
        pure { title, role, items := items.toArray }
  return { menus := menus.toArray }

/-- `windowAsked` as it crosses. -/
@[extern "editor_glue_window_asked"]
private opaque windowAskedRaw (platform : Platform) : IO RawWords

/-- What the words of `windowAsked` spell from the index `at_` on, each
thing asked in order: a request's tag, the tag 3, a count and the scalar
values of a title's characters, the tag 5 and a menu bar's layout
(`AskedReader.menu`), the tag 8 and a background's red, green and blue,
a word each, or the tag 9 for the close. `none` when they spell nothing, a
byte's word above 255 among them. It is public so that its test module can
read words of its own. -/
partial def askedOf (words : Array UInt64) (at_ : Nat := 0) (asked : Array WindowAsked := #[]) :
    Option (Array WindowAsked) :=
  if at_ >= words.size then some asked
  else
    match words[at_]! with
    | 0 => askedOf words (at_ + 1) (asked.push (.request .enterFullscreen))
    | 1 => askedOf words (at_ + 1) (asked.push (.request .leaveFullscreen))
    | 2 => askedOf words (at_ + 1) (asked.push (.request .minimise))
    | 4 => askedOf words (at_ + 1) (asked.push (.request .keepRunning))
    | 6 => askedOf words (at_ + 1) (asked.push (.request .lightAppearance))
    | 7 => askedOf words (at_ + 1) (asked.push (.request .darkAppearance))
    | 9 => askedOf words (at_ + 1) (asked.push .close)
    | 3 => do
      let count := (← words[at_ + 1]?).toNat
      let scalars ← (List.range count).mapM fun index => words[at_ + 2 + index]?
      let chars ←
        scalars.mapM fun scalar =>
            if scalar < 0x110000 && (Nat.isValidChar scalar.toNat) then
              some (Char.ofNat scalar.toNat)
            else none
      askedOf words (at_ + 2 + count) (asked.push (.title (String.ofList chars)))
    | 5 => do
      let (menu, next) ← (AskedReader.menu words).run (at_ + 1)
      askedOf words next (asked.push (.menu menu))
    | 8 => do
      let byte (offset : Nat) : Option UInt8 := do
        let word ← words[at_ + offset]?
        if word ≤ 255 then
          some word.toUInt8
        else
          none
      let (red, green, blue) := (← byte 1, ← byte 2, ← byte 3)
      askedOf words (at_ + 4) (asked.push (.background red green blue))
    | _ => none

/-- What the scripted window of `platform` was asked in its latest run, in
order: the requests while it ran, and the titles, the menu bars and the
backgrounds the presenter sent it.
`none` for the real platform, which records nothing. A readout for tests. -/
def windowAsked (platform : Platform) : IO (Option (Array WindowAsked)) := do
  let raw ← windowAskedRaw platform
  if raw.status != 0 then
    return none
  let problem := IO.userError "the library's record of requests is not its words"
  let some words := wordsOf? raw.words | throw problem
  let some asked := askedOf words | throw problem
  return some asked

/-- `windowOpenedWith` as it crosses. -/
@[extern "editor_glue_window_opened_with"]
private opaque windowOpenedWithRaw (platform : Platform) : IO RawWords

/-- What the scripted window of `platform` was opened with in its latest
run: whether an input method could compose, and its title bar. `none` for
the real platform, which records nothing, and before any run. A readout for
tests. -/
def windowOpenedWith (platform : Platform) : IO (Option (Bool × TitleBar)) := do
  let raw ← windowOpenedWithRaw platform
  if raw.status != 0 then
    return none
  let problem := IO.userError "the library's record of a run is not its words"
  let some words := wordsOf? raw.words | throw problem
  match words with
  | #[] =>
    return none
  | #[composition, titleBar] =>
    let titleBar ←
      match titleBar with
      | 0 =>
        pure TitleBar.themed
      | 1 =>
        pure .standard
      | _ =>
        throw problem
    return some (composition == 1, titleBar)
  | _ =>
    throw problem

/-- `postInput` as it crosses: the words as bytes. -/
@[extern "editor_glue_window_post_input"]
private opaque postInputRaw (kind : EventKind) (code : UInt64) (text : @& String)
    (words : @& ByteArray) : IO Bool

/-- Posts to the editor queue the event the process's window would push if it
reported the input that an event of `kind` with `code`, `text` and `words`
stands for (the layouts in "The window", in the module docs): the library
reads the words into its window input and pushes the event it makes of it,
from the window source, stamped on the input clock. It is the path a real
window's input takes, for tests and for the headless driver.

`false`, queueing nothing, when `kind` is not a window's, the code is out of
range, the words do not read as an input of that kind, or the queues have
been quit. -/
def postInput (kind : EventKind) (code : UInt64) (text : @& String) (words : Array UInt64) :
    IO Bool :=
  postInputRaw kind code text (words.foldl pushWord ByteArray.empty)

/-- The time on the library's input clock, in nanoseconds since the clock
began: the clock a window's events are stamped on. It never goes back, and
it is never 0. The time from an event's stamp to this reading is how long the
event took to reach whoever reads it. -/
@[extern "editor_glue_input_clock"]
opaque inputClock : IO UInt64

/-- What a window's surface offered, what its run asked for and what it was
configured with, as the wgpu renderer says it. -/
structure WindowPresentation where
  /-- The present modes the surface offered, in its order. -/
  modes : Array PresentMode
  /-- The present mode and the frame latency the run asked for, each `none`
  when it did not ask for it: only what was asked. -/
  asked : Option PresentMode × Option Nat
  /-- The present mode and frame latency the surface was configured with. -/
  configured : PresentMode × Nat
  deriving DecidableEq, Repr

/-- `windowPresentation` as it crosses. -/
@[extern "editor_glue_window_presentation"]
private opaque windowPresentationRaw : IO RawWords

/-- The present mode a tag of the library's names: the inverse of
`PresentMode.tag`. -/
private def PresentMode.ofTag? : UInt64 → Option PresentMode
  | 1 => some .fifo
  | 2 => some .fifoRelaxed
  | 3 => some .immediate
  | 4 => some .mailbox
  | _ => none

/-- What the surface of the latest window drawn with the wgpu renderer
offered, what its run asked for and what it was configured with, read after
it has closed too; `none` when no window has drawn with it, as on the
scripted platforms. -/
def windowPresentation : IO (Option WindowPresentation) := do
  let raw ← windowPresentationRaw
  if raw.status != 0 then
    return none
  let problem := IO.userError "the library's presentation is not its words"
  let some words := wordsOf? raw.words | throw problem
  let count := (words[0]?.getD 0).toNat
  let mode (index : Nat) : IO PresentMode := do
    let some mode := PresentMode.ofTag? (words[index]?.getD 0) | throw problem
    return mode
  unless words.size == 1 + count + 4 do
    throw problem
  let modes ← (Array.range count).mapM fun index => mode (1 + index)
  let at_ := 1 + count
  -- What was asked: a mode's tag and a latency, each 0 for none asked.
  let askedMode ←
    if words[at_]! == 0 then
      pure none
    else
      some <$> mode at_
  let askedLatency := (some words[at_ + 1]!.toNat).filter (· != 0)
  return some
      { modes, asked := (askedMode, askedLatency)
        configured := (← mode (at_ + 2), words[at_ + 3]!.toNat) }

end Editor.Ffi
