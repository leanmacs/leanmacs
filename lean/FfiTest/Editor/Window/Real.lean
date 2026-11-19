import Editor.Clipboard.InProcess
import Editor.Compile.Contribution
import Editor.Config.Owner
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.DisplayRules
import Editor.Ffi.Display
import Editor.Ffi.Render
import Editor.Ffi.Window
import Editor.FrameCommands.Compiled
import Editor.Menu
import Editor.Menu.Compiled
import Editor.PackageSet
import Editor.Process.Environment
import Editor.Window
import Editor.Window.Real
import Editor.Workspace

/-!
# FFI tests: `Editor/Window/Real.lean`

The tests of `Editor/Window/Real.lean`: the `window-host`, `window-host-config`
and `window-host-undrawn` scenarios (`windowHostScenario`,
`windowHostConfigScenario`, `windowHostUndrawnScenario`), of `Window.host`. The
root module `FfiTest` runs them, and each scenario's own doc says what it shows.
-/

namespace FfiTest

/-- The window mode's wiring (`Editor.Window.host`) on the library's
scripted platform, on the absolute path `file`, or with no file, on the
editor's one empty buffer, when it is `none`: a cells display bound to the
presenter, a clipboard of its own, no config, and the report asked for. The
sample window opens, reports its fixed input and asks to close, which ends
the host's loop, runs the window mode's shutdown and closes the window, and
the report is printed to stderr. 0 when the window ran, the shutdown ran
once and while the window still ran, the latest render session's counters, read once
`windowRun` has returned (the presenter's last handle), show a frame drawn,
no surface said what it offered, the window was opened with the themed
title bar and asked for the dark appearance of the built-in paper and for
nothing else, and, with no file, the last title the scripted window was
asked to show is `scratch`; 1 otherwise, saying why on stderr. The process starts no other render session, so the counters are this
run's. -/
def windowHostScenario (file : Option String) : IO UInt8 := do
  let options : Editor.Window.Options :=
    { file, config := none, configGiven := false, sysroot := none, oleans := ""
      composition := true, report := true }
  -- The window mode's shutdown, which first asks the window to minimise: a
  -- scripted window records that only while it runs, and runs until it is
  -- closed, so the record shows the shutdown ran before the close. It asks
  -- a moment later, by which a window closed first has ended its run.
  let shutdowns ← IO.mkRef 0
  let shutdown := do
    shutdowns.modify (· + 1)
    IO.sleep 100
    Editor.Ffi.windowRequest .scripted .minimise
    Editor.Window.shutdown
  let status ←
    Editor.Window.host Editor.PackageSet.shipped .scripted options (.skip none)
        (← Editor.Ffi.Display.newCells 8 16) (← Editor.Clipboard.InProcess.new).handle #[] shutdown
        .headless
  unless status == 0 do
    IO.eprintln s!"ffi-test window-host: the window mode ended with status {status}"
    return 1
  unless (← shutdowns.get) == 1 do
    IO.eprintln s!"ffi-test window-host: the shutdown ran {← shutdowns.get} times, not once"
    return 1
  unless ((← Editor.Ffi.windowAsked .scripted).getD #[]).contains (.request .minimise) do
    IO.eprintln "ffi-test window-host: the shutdown did not run before the window was closed"
    return 1
  let some counters ← Editor.Ffi.renderCounters |
    IO.eprintln "ffi-test window-host: no render session was started"
    return 1
  unless counters.draws > 0 do
    IO.eprintln "ffi-test window-host: no frame was drawn in the window"
    return 1
  -- The scripted platform draws with the recording renderer, which has no
  -- surface to say anything of.
  unless (← Editor.Ffi.windowPresentation) == none do
    IO.eprintln "ffi-test window-host: a scripted window said what a surface offered"
    return 1
  -- With no config the window opens with the themed title bar, and once it
  -- has opened it is asked for the appearance of the built-in theme's
  -- paper, which is dark; the shutdown's minimise comes last.
  unless (← Editor.Ffi.windowOpenedWith .scripted) == some (true, .themed) do
    IO.eprintln "ffi-test window-host: the window was not opened with the themed title bar"
    return 1
  let requests :=
    ((← Editor.Ffi.windowAsked .scripted).getD #[]).filterMap fun
      | .request request => some request
      | .title _ | .menu _ => none
  unless requests == #[.darkAppearance, .minimise] do
    IO.eprintln
        s!"ffi-test window-host: the window was asked {repr requests}, not the dark appearance and then the shutdown's minimise"
    return 1
  -- With no file the selected buffer is the one empty buffer, whose name is
  -- the window's title. With a file, its load may not finish before the
  -- sample asks to close, so the title is not looked at.
  if file.isNone then
    let titles :=
      ((← Editor.Ffi.windowAsked .scripted).getD #[]).filterMap fun
        | .title text => some text
        | .request _ | .menu _ => none
    unless titles.back? == some "scratch" do
      IO.eprintln
          s!"ffi-test window-host: the window was last asked for the title {titles.back?}, not scratch"
      return 1
    -- The menu bar crossed whole, from Lean through the scene to the
    -- scripted window's record and back: the standard one, with the keys
    -- the packages' bindings give it, asked once, since it never changed.
    let menus :=
      ((← Editor.Ffi.windowAsked .scripted).getD #[]).filterMap fun
        | .menu menu => some menu
        | .request _ | .title _ => none
    let compiled :=
      ({} : Editor.Config.Registry).replaceBindings .compiled
        (Editor.FrameCommands.package.registered.bindings ++
          Editor.Menu.package.registered.bindings)
    let expected := compiled.menuOf Editor.Menu.standard
    unless menus == #[expected] do
      IO.eprintln
          s!"ffi-test window-host: the window was asked for {menus.size} menu bars, not the standard one once: {repr menus}"
      return 1
  IO.println "ffi-test window-host: the window ran and closed, and frames were drawn in it"
  return 0

/-- The window mode's wiring (`Editor.Window.host`) on the library's
scripted platform, with no file and config loaded at start from
`configDir` with the toolchain `sysroot` and the `.olean` files in
`oleanDir`: the fixture `tests/window/title-bar/config`, whose `setup`
keeps the standard title bar. The host waits for the start-up reload with
no bound, so the result does not race the clock (the task's time limit
ends a run that hangs). 0 when the window mode ended with status 0 and the
scripted window was opened with the standard title bar; 1 otherwise,
saying why on stderr. -/
def windowHostConfigScenario (sysroot oleanDir configDir : String) : IO UInt8 := do
  let options : Editor.Window.Options :=
    { file := none, config := some configDir, configGiven := true, sysroot := some sysroot
      oleans := oleanDir, composition := true }
  let status ←
    Editor.Window.host Editor.PackageSet.shipped .scripted options (.load configDir)
        (← Editor.Ffi.Display.newCells 8 16) (← Editor.Clipboard.InProcess.new).handle #[]
        Editor.Window.shutdown .headless (patience := none)
  unless status == 0 do
    IO.eprintln s!"ffi-test window-host-config: the window mode ended with status {status}"
    return 1
  let opened ← Editor.Ffi.windowOpenedWith .scripted
  unless opened == some (true, .standard) do
    IO.eprintln
        s!"ffi-test window-host-config: the window was opened with {repr opened}, not the standard title bar"
    return 1
  IO.println
      "ffi-test window-host-config: the window opened with the title bar the start-up config chose"
  return 0

/-- The window mode's wiring (`Editor.Window.host`) on the library's
scripted platform whose renderer cannot be made, on the absolute path
`file`, as `windowHostScenario` sets it up but with no report. The sample
window opens, reports its fixed input and asks to close, as it does there,
and nothing draws in it. 0 when the window mode ended with status 1 and no
render session was started; 1 otherwise, saying why on stderr. What the
window mode prints of the failure is on stderr, for the gate to read. -/
def windowHostUndrawnScenario (file : String) : IO UInt8 := do
  let options : Editor.Window.Options :=
    { file := some file, config := none, configGiven := false, sysroot := none, oleans := ""
      composition := true }
  let status ←
    Editor.Window.host Editor.PackageSet.shipped .scriptedUndrawn options (.skip none)
        (← Editor.Ffi.Display.newCells 8 16) (← Editor.Clipboard.InProcess.new).handle #[]
        Editor.Window.shutdown .headless
  unless status == 1 do
    IO.eprintln s!"ffi-test window-host-undrawn: the window mode ended with status {status}, not 1"
    return 1
  if (← Editor.Ffi.renderCounters).isSome then
    IO.eprintln "ffi-test window-host-undrawn: a render session was started"
    return 1
  IO.println
      "ffi-test window-host-undrawn: the window ran with nothing drawing in it, and the window mode said so"
  return 0

end FfiTest
