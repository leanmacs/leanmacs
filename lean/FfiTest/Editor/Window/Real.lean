import ConfigFixture
import Editor
import Editor.Clipboard.InProcess
import Editor.Config.Directory
import Editor.Config.LakePackage
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Session
import Editor.Ffi.Display
import Editor.Ffi.Render
import Editor.Ffi.Window
import Editor.InputScheme.Test
import Editor.Menu
import Editor.Process.Environment
import Editor.RealHost
import Editor.Test.AtPoint
import Editor.Test.Editing
import Editor.Test.Minibuffer
import Editor.Test.Restore
import Editor.Test.Shipped
import Editor.Window
import Editor.Window.Real
import FfiTest.Check
import FfiTest.Support.Queues
import FilesApiTest.Fake

/-!
# FFI tests: `Editor/Window/Real.lean`

The tests of `Editor/Window/Real.lean`: the `window-host`, `window-host-config`,
`window-host-base`, `window-host-generate`, `window-host-direct`,
`window-host-undrawn` and `window-host-restart` scenarios
(`windowHostScenario`, `windowHostConfigScenario`,
`windowHostBaseScenario`, `windowHostGenerateScenario`,
`windowHostDirectScenario`, `windowHostUndrawnScenario`,
`windowHostRestartScenario`), of `Window.host`, and `windowRealChecks`, of
the end with no deadline the restart scenario gives the journal's drain
(`journalDrained`). The root module `FfiTest` runs them, and each
scenario's own doc says what it shows.

It imports the config base, `Editor`, for the link alone: the window host
elaborates config on that base (`Editor/Config/Elaborate.lean`, "The
base"), whose import of the base at runtime needs every module of it linked
into this executable. The adapter does not import the base itself, so this
module, which runs the host, does, and `tools/core-imports-check.sh` checks
it. It imports `ConfigFixture` for the link too: `window-host-base` hands
the window mode a base that holds that module, which `Editor` does not
import, as an editor's generated root hands it the entry modules of its
set's packages.

A module of the wiring set, declared in place (`AGENTS.md`, "Deterministic
concurrency in tests"; `docs/dev-practices/real-thread-checks.md`): its
scenarios run `Editor.Window.host` on the scripted platform, the window
mode's wiring; shutdown before close and exec after close are their
subject. The model halves are `ModelTest/Editor/Window.lean`'s and
`ModelTest/Editor/Restart/Handover.lean`'s.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.FfiTest.Editor.Window.Real : Editor.WiringSet :=
  .wiring "the window mode's host on the scripted platform (Editor.Window.host)"
    "the window mode's wiring, its restart's exec and its real timers are the edge, which only a real loop and platform show"

namespace FfiTest

/-- Waits for the journal's drain `drained`, a flush of the file service, with
no deadline, and says whether it drained: a drain not ended `guard`
milliseconds after this was asked is said through `hung` as a hang, once,
and still waited for. A scenario whose state directory is a temporary one
of its own waits so before the window mode's shutdown, whose own wait is
bounded by `Headless.drainPatience` and gives up, so that its directory is
removed only once every journal order has been written.
Only a hang reaches `guard`, the drain's flush completed, which is then
said once and still waited on. -/
def journalDrained (drained : Task Bool) (guard : Editor.HangGuard := Editor.Headless.drainPatience)
    (hung : String → IO Unit := IO.eprintln) : IO Bool := do
  if (← Editor.Job.awaitWithin guard drained).isNone then
    hung
        s!"ffi-test: a hang: the journal had not drained {guard.ms} ms after it was asked; waiting for it"
  IO.wait drained

/-- The checks of `journalDrained`, on a drain the check ends: with a guard of
0, the drain is ended only from the hang report, so a wait that gave up at
its guard is seen every run, with no sleep. -/
def windowRealChecks (_ : Unit) : List Check :=
  [{  name :=
        "a scenario's wait for the journal's drain has no deadline: a drain not ended at its guard is said as a hang once and still waited for, and the wait returns only once the drain has ended"
      run := do
        let drain ← IO.Promise.new
        let said ← IO.mkRef (#[] : Array String)
        let drained := drain.result?.map (sync := true) (·.getD false)
        let answered ←
          journalDrained drained (guard := .held "the drain the check ends from the hang report" 0)
              (hung := fun line => do
              said.modify (·.push line)
              drain.resolve true)
        let ended ← IO.hasFinished drained
        -- A wait that gave up left the drain pending: end it.
        drain.resolve false
        let said ← said.get
        unless answered && ended && said.size == 1 do
          IO.eprintln s!"ffi-test: saw answered={answered} ended={ended} said={said}"
          return false
        return true }]

/-- Whether the scripted window's record `asked` holds the shutdown's
minimise before the close: the window records the close in its place among
the requests, and records a request only while it runs, so a shutdown run
after the close, or not at all, leaves no minimise before it. -/
def shutBeforeClose (asked : Array Editor.Ffi.WindowAsked) : Bool :=
  match asked.findIdx? (· == .request .minimise), asked.findIdx? (· == .close) with
  | some minimised, some closed => minimised < closed
  | _, _ => false

/-- The title of the menu the window checks write. -/
def windowMenuTitle : String :=
  "Window Test"

/-- The command the window checks' menu item names; nothing registers it. -/
def windowMenuCommand : String :=
  "window-test-greet"

/-- A package written for the window checks: a menu of one command item,
and the chord `s-g` bound to the item's command, so the menu bar the host
publishes holds a menu and a key equivalent that are no feature's. -/
def windowMenuPackage : Editor.Package :=
  { name := "window-menu"
    setup := do
      Editor.bindKeys
          [Editor.Key.chord { logical := .character "g", modifiers := { superKey := true } }]
          windowMenuCommand
      Editor.defineMenu
          { title := windowMenuTitle,
            items := #[.item "Greet" none (.command windowMenuCommand)] } }

/-- The packages the window host is handed in these scenarios, as the
default editor's root hands them: the
kit's stand-in for the default package `restore`
(`Editor.Test.Restore.package`, `Editor/Test/Restore.lean`), through whose
`restart` the restart check hands over, then the menu the checks write
(`windowMenuPackage`), then `files-api`'s fake (`FilesApiTest.fake`), which opens the file in place of
the default package `files`, then the kit's stand-ins for the default packages whose data the core keeps
(`Editor.Test.Shipped`, `Editor/Test/Shipped.lean`), then the kit's
implementation of the default package `at-point`'s commands
(`Editor.Test.AtPoint`, `Editor/Test/AtPoint.lean`), which a scheme's keys
of completion at point run, and its implementation of the default package
`minibuffer`'s commands and mode (`Editor.Test.Minibuffer`,
`Editor/Test/Minibuffer.lean`), which answer a prompt, and the kit's
editing commands and keys (`Editor.Test.editingPackage`,
`Editor/Test/Editing.lean`), with which a printable key of the test scheme
the hosts run types. -/
def shippedPackages : Array Editor.Package :=
  #[Editor.Test.Restore.package, windowMenuPackage, FilesApiTest.fake] ++
    Editor.Test.Shipped.packages ++
    #[Editor.Test.AtPoint.package, Editor.Test.Minibuffer.package, Editor.Test.editingPackage]

/-- The mark of `windowHostScenario`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def windowHostScenario.realHost : Editor.RealHost :=
  .loop

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
    { file, config := none, configGiven := false, sysroot := none, oleans := []
      composition := true, report := true }
  -- The window mode's shutdown, which first asks the window to minimise: a
  -- scripted window records that only while it runs, and records its close
  -- in its place among the requests, so the record's order shows the
  -- shutdown ran before the close (`shutBeforeClose`), with no wait.
  let shutdowns ← IO.mkRef 0
  let shutdown drained := do
    shutdowns.modify (· + 1)
    Editor.Ffi.windowRequest .scripted .minimise
    Editor.Window.shutdown drained
  let status ←
    Editor.Window.host Editor.TestScheme.scheme shippedPackages #[`Editor] .scripted options
        (.skip none) (← Editor.Ffi.Display.newCells 8 16) (← Editor.Clipboard.InProcess.new).handle
        #[] shutdown .headless
  unless status == 0 do
    IO.eprintln s!"ffi-test window-host: the window mode ended with status {status}"
    return 1
  unless (← shutdowns.get) == 1 do
    IO.eprintln s!"ffi-test window-host: the shutdown ran {← shutdowns.get} times, not once"
    return 1
  unless shutBeforeClose ((← Editor.Ffi.windowAsked .scripted).getD #[]) do
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
      | .title _ | .menu _ | .background .. | .close => none
  unless requests == #[.darkAppearance, .minimise] do
    IO.eprintln
        s!"ffi-test window-host: the window was asked {repr requests}, not the dark appearance and then the shutdown's minimise"
    return 1
  -- The paper crossed whole, from Lean's theme through layout's frame and
  -- the presenter to the scripted window's record and back: the last
  -- background asked is the built-in theme's paper, `#2e3440`, the
  -- `default` face's background that `Editor/Appearance.lean` classifies.
  let backgrounds :=
    ((← Editor.Ffi.windowAsked .scripted).getD #[]).filterMap fun
      | .background red green blue => some (red, green, blue)
      | .request _ | .title _ | .menu _ | .close => none
  let byte (color : Editor.Color) (shift : UInt32) : UInt8 := (color.word >>> shift).toUInt8
  let paper : Option (UInt8 × UInt8 × UInt8) :=
    (Editor.Theme.builtin.paper).map fun color => (byte color 24, byte color 16, byte color 8)
  unless paper == some (0x2e, 0x34, 0x40) && backgrounds.back? == paper do
    IO.eprintln
        s!"ffi-test window-host: the window was last asked for the background {repr backgrounds.back?}, not the built-in theme's paper {repr paper}"
    return 1
  -- With no file the selected buffer is the one empty buffer, whose name is
  -- the window's title. With a file, its load may not finish before the
  -- sample asks to close, so the title is not looked at.
  if file.isNone then
    let titles :=
      ((← Editor.Ffi.windowAsked .scripted).getD #[]).filterMap fun
        | .title text => some text
        | .request _ | .menu _ | .background .. | .close => none
    unless titles.back? == some "scratch" do
      IO.eprintln
          s!"ffi-test window-host: the window was last asked for the title {titles.back?}, not scratch"
      return 1
    -- The menu bar crossed whole, from Lean through the scene to the
    -- scripted window's record and back: the one the host's packages
    -- register, with the keys their bindings give it, the menu written
    -- here (`windowMenuPackage`) with its chord among it, asked once,
    -- since it never changed.
    let menus :=
      ((← Editor.Ffi.windowAsked .scripted).getD #[]).filterMap fun
        | .menu menu => some menu
        | .request _ | .title _ | .background .. | .close => none
    let (state, _) : Editor.Config.State Unit Unit × Array String :=
      Editor.Config.State.ofPackages shippedPackages
    let expected := state.registry.menuBar?
    let written :=
      expected.any fun menu =>
        menu.menus.any fun submenu =>
          submenu.title == windowMenuTitle &&
            submenu.items ==
              #[.item "Greet" (some { character := 'g', modifiers := { superKey := true } })
                  (.command windowMenuCommand)]
    unless written && menus.map some == #[expected] do
      IO.eprintln
          s!"ffi-test window-host: the window was asked for {menus.size} menu bars, not the host's packages' one once, the test's menu with its chord among it: {repr menus}"
      return 1
  IO.println "ffi-test window-host: the window ran and closed, and frames were drawn in it"
  return 0

/-- The mark of `windowHostConfigScenario`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def windowHostConfigScenario.realHost : Editor.RealHost :=
  .loop

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
      oleans := [oleanDir], composition := true }
  let status ←
    Editor.Window.host Editor.TestScheme.scheme shippedPackages #[`Editor] .scripted options
        (.load configDir) (← Editor.Ffi.Display.newCells 8 16)
        -- hang guard: none of its own; the start-up reload's end, which the window
        -- mode's `awaitConfig` waits for over `Host.waitWhile`'s untracked branch
        -- (follow-up window-mode-waits-poll-progress); only a hang reaches the
        -- task's time limit, and the scenario then fails as a hang.
        (← Editor.Clipboard.InProcess.new).handle #[] Editor.Window.shutdown .headless (patience :=
        none)
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

/-- The mark of `windowHostBaseScenario`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def windowHostBaseScenario.realHost : Editor.RealHost :=
  .loop

/-- The window mode's wiring (`Editor.Window.host`) handed a config base
that is not `Editor` alone, as the editor's `main` hands it its package
set's (`Editor/Main.lean`, "The base"): `Editor` and `ConfigFixture`, a
module linked into this executable that `Editor` does not import. Config is
loaded at start from `configDir`, the fixture `tests/window/base/config`,
which names a declaration of that module and keeps the standard title bar.
So the config elaborates only if the window mode handed the elaborator the
base it was handed: on `Editor` alone the start-up reload is rejected with
an unknown identifier, and the window opens with the themed title bar. The
host waits for the start-up reload with no bound. 0 when the window mode
ended with status 0 and the scripted window was opened with the standard
title bar; 1 otherwise, saying why on stderr. -/
def windowHostBaseScenario (sysroot oleanDir configDir : String) : IO UInt8 := do
  let options : Editor.Window.Options :=
    { file := none, config := some configDir, configGiven := true, sysroot := some sysroot
      oleans := [oleanDir], composition := true }
  let status ←
    Editor.Window.host Editor.TestScheme.scheme shippedPackages #[`Editor, `ConfigFixture] .scripted
        options (.load configDir) (← Editor.Ffi.Display.newCells 8 16)
        -- hang guard: none of its own; the start-up reload's end, which the window
        -- mode's `awaitConfig` waits for over `Host.waitWhile`'s untracked branch
        -- (follow-up window-mode-waits-poll-progress); only a hang reaches the
        -- task's time limit, and the scenario then fails as a hang.
        (← Editor.Clipboard.InProcess.new).handle #[] Editor.Window.shutdown .headless (patience :=
        none)
  unless status == 0 do
    IO.eprintln s!"ffi-test window-host-base: the window mode ended with status {status}"
    return 1
  let opened ← Editor.Ffi.windowOpenedWith .scripted
  unless opened == some (true, .standard) do
    IO.eprintln
        s!"ffi-test window-host-base: the window was opened with {repr opened}, not the standard title bar: the config, which names a declaration of a base module outside Editor, was not installed, so the window mode did not elaborate it on the base it was handed"
    return 1
  IO.println
      "ffi-test window-host-base: config that names a module of the base outside Editor loaded: the window mode elaborated it on the base it was handed"
  return 0

/-- The mark of `windowHostGenerateScenario`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def windowHostGenerateScenario.realHost : Editor.RealHost :=
  .loop

/-- The window mode's wiring (`Editor.Window.host`) handed a generator, as
the editor's `main` hands it one: config is loaded at start from
`configDir`, a directory of the caller's own that holds a root and neither
generated file, with a generator that creates files in that directory, for
a made-up pin and a made-up package set. The start-up reload must create
the directory's `lean-toolchain`, holding the pin, and its `lakefile.toml`,
requiring the set, and load the config, which keeps the standard title
bar. So the window host hands the session the generator it was handed: a
host that dropped it would leave the directory as it was. 0 when the window
mode ended with status 0, the window was opened with the standard title
bar and both files hold what they must; 1 otherwise, saying why on
stderr. It writes in `configDir` alone. -/
def windowHostGenerateScenario (sysroot oleanDir configDir : String) : IO UInt8 := do
  let options : Editor.Window.Options :=
    { file := none, config := some configDir, configGiven := true, sysroot := some sysroot
      oleans := [oleanDir], composition := true }
  let pin := "leanprover/lean4:made-up\n"
  let set : Editor.Config.LakePackage.Set :=
    { name := "made-up-set", directory := "/made/up", core := "/made/core" }
  let generator : Editor.Config.Generator :=
    { create := Editor.Config.Directory.create configDir, pin, set := some set }
  let status ←
    Editor.Window.host Editor.TestScheme.scheme shippedPackages #[`Editor] .scripted options
        (.load configDir) (← Editor.Ffi.Display.newCells 8 16)
        -- hang guard: none of its own; the start-up reload's end, which the window
        -- mode's `awaitConfig` waits for over `Host.waitWhile`'s untracked branch
        -- (follow-up window-mode-waits-poll-progress); only a hang reaches the
        -- task's time limit, and the scenario then fails as a hang.
        (← Editor.Clipboard.InProcess.new).handle #[] Editor.Window.shutdown .headless (patience :=
        none) (generator := some generator)
  unless status == 0 do
    IO.eprintln s!"ffi-test window-host-generate: the window mode ended with status {status}"
    return 1
  let opened ← Editor.Ffi.windowOpenedWith .scripted
  unless opened == some (true, .standard) do
    IO.eprintln
        s!"ffi-test window-host-generate: the window was opened with {repr opened}, not the standard title bar: the config was not loaded"
    return 1
  let held (name : String) : IO (Option String) := Editor.Config.Directory.read configDir name
  unless (← held Editor.Config.LakePackage.toolchainName) == some pin do
    IO.eprintln "ffi-test window-host-generate: no lean-toolchain holding the pin was created"
    return 1
  unless
    (← held Editor.Config.LakePackage.lakefileName) ==
      some (Editor.Config.LakePackage.lakefile set) do
    IO.eprintln "ffi-test window-host-generate: no lakefile.toml requiring the set was created"
    return 1
  IO.println
      "ffi-test window-host-generate: the window mode created the config directory's lakefile and toolchain file, and loaded the config"
  return 0

/-- The mark of `windowHostDirectScenario`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def windowHostDirectScenario.realHost : Editor.RealHost :=
  .loop

/-- The window mode as the editor at `editorPath` starts it when run
directly with `--sysroot <sysroot> --config <configDir>` and no `--oleans`:
the command line is read by `Window.parse`, given that executable's path,
so the directories of the editor's `.olean` files are the default for it,
which the edge reads from the record the build wrote beside that
executable (`Window.environmentAt`), and the host runs on the library's
scripted platform as in `windowHostConfigScenario`, on the same fixture
config. 0 when the command
line was taken, the window mode ended with status 0 and the scripted window
was opened with the standard title bar, which only the loaded config
chooses: the default directory held the modules config is elaborated on. 1
otherwise, saying why on stderr. -/
def windowHostDirectScenario (editorPath sysroot configDir : String) : IO UInt8 := do
  let environment ← Editor.Window.environmentAt editorPath
  let options ←
    match Editor.Window.parse environment ["--sysroot", sysroot, "--config", configDir] with
    | .ok options =>
      pure options
    | .error message =>
      IO.eprintln s!"ffi-test window-host-direct: the command line was refused: {message}"
      return 1
  let plan := options.configPlan false
  let status ←
    Editor.Window.host Editor.TestScheme.scheme shippedPackages #[`Editor] .scripted options plan
        (← Editor.Ffi.Display.newCells 8 16) (← Editor.Clipboard.InProcess.new).handle #[]
        -- hang guard: none of its own; the start-up reload's end, which the window
        -- mode's `awaitConfig` waits for over `Host.waitWhile`'s untracked branch
        -- (follow-up window-mode-waits-poll-progress); only a hang reaches the
        -- task's time limit, and the scenario then fails as a hang.
        Editor.Window.shutdown .headless (patience := none)
  unless status == 0 do
    IO.eprintln s!"ffi-test window-host-direct: the window mode ended with status {status}"
    return 1
  let opened ← Editor.Ffi.windowOpenedWith .scripted
  unless opened == some (true, .standard) do
    IO.eprintln
        s!"ffi-test window-host-direct: the window was opened with {repr opened}, not the standard title bar: the config was not loaded from the default module directory, {repr options.oleans}"
    return 1
  IO.println
      "ffi-test window-host-direct: config loaded from the module directory the editor finds by default"
  return 0

/-- The mark of `windowHostUndrawnScenario`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def windowHostUndrawnScenario.realHost : Editor.RealHost :=
  .loop

/-- The window mode's wiring (`Editor.Window.host`) on the library's
scripted platform whose renderer cannot be made, on the absolute path
`file`, as `windowHostScenario` sets it up but with no report. The sample
window opens, reports its fixed input and asks to close, as it does there,
and nothing draws in it. 0 when the window mode ended with status 1 and no
render session was started; 1 otherwise, saying why on stderr. What the
window mode prints of the failure is on stderr, for the gate to read. -/
def windowHostUndrawnScenario (file : String) : IO UInt8 := do
  let options : Editor.Window.Options :=
    { file := some file, config := none, configGiven := false, sysroot := none, oleans := []
      composition := true }
  let status ←
    Editor.Window.host Editor.TestScheme.scheme shippedPackages #[`Editor] .scriptedUndrawn options
        (.skip none) (← Editor.Ffi.Display.newCells 8 16) (← Editor.Clipboard.InProcess.new).handle
        #[] Editor.Window.shutdown .headless
  unless status == 1 do
    IO.eprintln s!"ffi-test window-host-undrawn: the window mode ended with status {status}, not 1"
    return 1
  if (← Editor.Ffi.renderCounters).isSome then
    IO.eprintln "ffi-test window-host-undrawn: a render session was started"
    return 1
  IO.println
      "ffi-test window-host-undrawn: the window ran with nothing drawing in it, and the window mode said so"
  return 0

/-- The mark of `windowHostRestartScenario`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def windowHostRestartScenario.realHost : Editor.RealHost :=
  .loop

/-- The window mode's wiring (`Editor.Window.host`) on the scripted
platform, ending in a restart: with a state directory and a launcher in a
temporary directory, `restart` is run as soon as the restore has finished
(`afterRestore`), into a probe script that prints `probe: ok`. Config is
loaded at start from `configDir`, as `windowHostConfigScenario` loads it,
so the window opens only once the loop has ended or the reload has
finished, and the scripted window's input and close request come after the
hand-over began: dropped, and refused, while it is in flight.

The host is handed a recording exec (`replace`) that fails, answering
`recorded`, and a `say` that records what the host says. The host must call
that exec exactly once, with `<launcher> --handover
<state>/session/handover`, and only once the shutdown has run once, while
the window ran, and the window has closed: when it is called, the shutdown
count is 1, and a request it sends the scripted window is not recorded,
since a window that is not running records none (`Ffi.windowAsked`). Its
failure must then be said, `editor: the restart could not start
<launcher>: recorded; the session is kept and the next start restores it`,
and the host must answer status 1. The record on disk is
`Restart.Handover.encode` of the plan: the index under the state
directory, the probe as the shipped and the only candidate, and the
options as given. 0 when all of that holds; 1 otherwise, saying why on
stderr. -/
def windowHostRestartScenario (sysroot oleanDir configDir : String) : IO UInt8 := do
  -- The directory goes only once the journal has drained: this scenario's
  -- shutdown waits for the drain, a flush of the file service behind every
  -- order the journal handed out, with no deadline (`journalDrained`)
  -- before the window mode's shutdown quits the queues, and `Window.host`
  -- returns only after the closer ran it.
  let dir ← IO.FS.createTempDir
  try
    let probe := dir / "probe"
    IO.FS.writeFile probe "#!/bin/sh\necho 'probe: ok'\n"
    IO.setAccessRights probe { user := { read := true, write := true, execution := true } }
    let state := dir / "state"
    let launcher : System.FilePath := dir / "leanmacs"
    let options : Editor.Window.Options :=
      { file := none, config := some configDir, configGiven := true, sysroot := some sysroot
        oleans := [oleanDir], composition := true, state := some state.toString
        launch := { launchedBy := some launcher, running := some probe, shipped := some probe } }
    let shutdowns ← IO.mkRef 0
    let shutdown drained := do
      shutdowns.modify (· + 1)
      -- The loop ends with the hand-over, which can come before the window
      -- has opened (config is loaded at start, so the window opens only once
      -- the reload has ended or the loop has): a request or a close sent
      -- then reaches no window, and the run would wait for good. So the
      -- shutdown first waits for the window's run to park for its close, on
      -- the park itself. Its minimise is then recorded before the close only
      -- when the shutdown runs first (`shutBeforeClose`).
      discard <| Editor.Ffi.windowAwaitParked .scripted patience
      Editor.Ffi.windowRequest .scripted .minimise
      -- The journal writes into `state`, under the directory removed below:
      -- its drain is waited for with no deadline (`journalDrained`), and the
      -- window mode's shutdown, whose own wait is bounded, finds it done.
      let drain ← drained
      discard <| journalDrained drain
      Editor.Window.shutdown (pure drain)
    -- What the exec was called with, and the shutdown count when it was.
    let replaced ← IO.mkRef (#[] : Array (Editor.Restart.Invocation × Nat))
    let replace (invocation : Editor.Restart.Invocation) : IO String := do
      let count ← shutdowns.get
      replaced.modify (·.push (invocation, count))
      -- Recorded only while the window runs.
      Editor.Ffi.windowRequest .scripted .enterFullscreen
      return "recorded"
    let said ← IO.mkRef (#[] : Array String)
    let status ←
      Editor.Window.host Editor.TestScheme.scheme shippedPackages #[`Editor] .scripted options
          (.load configDir) (← Editor.Ffi.Display.newCells 8 16)
          -- hang guard: none of its own; the start-up reload's end, which the window
          -- mode's `awaitConfig` waits for over `Host.waitWhile`'s untracked branch
          -- (follow-up window-mode-waits-poll-progress); only a hang reaches the
          -- task's time limit, and the scenario then fails as a hang.
          (← Editor.Clipboard.InProcess.new).handle #[] shutdown .headless (patience := none)
          (afterRestore := #[.run Editor.restartName]) (replace := replace) (say := fun line =>
          said.modify (·.push line))
    let record := state / "session" / "handover"
    let exec : Editor.Restart.Invocation :=
      { program := launcher, arguments := #["--handover", record.toString] }
    unless (← replaced.get) == #[(exec, 1)] do
      IO.eprintln
          s!"ffi-test window-host-restart: the exec was called {repr (← replaced.get)}, each with the shutdown count then, not once with {repr exec} after one shutdown"
      return 1
    let asked := (← Editor.Ffi.windowAsked .scripted).getD #[]
    unless shutBeforeClose asked do
      IO.eprintln
          "ffi-test window-host-restart: the shutdown did not run before the window was closed"
      return 1
    if asked.contains (.request .enterFullscreen) then
      IO.eprintln "ffi-test window-host-restart: the exec was called before the window closed"
      return 1
    let failed :=
      s!"editor: the restart could not start {launcher}: recorded; the session is kept and the next start restores it"
    unless status == 1 && (← said.get).contains failed do
      IO.eprintln
          s!"ffi-test window-host-restart: the failed exec ended with status {status}, having said {repr (← said.get)}"
      return 1
    let text ← IO.FS.readFile record
    let session :=
      ((text.splitOn "\n").findSome? fun line =>
            (line.dropPrefix? "session ").map (·.toString)).getD
        ""
    let expected : Editor.Restart.Handover :=
      { session, shipped := probe, candidates := #[probe], arguments := options.restartArguments }
    unless
      text == expected.encode && (System.FilePath.mk session).parent == some (state / "session") do
      IO.eprintln s!"ffi-test window-host-restart: the record on disk is not the plan's: {text}"
      return 1
    IO.println
        "ffi-test window-host-restart: the host exec'd the restart once, through the exec it was handed, after the shutdown and the window's close, and said the failed exec with status 1, its record written"
    return 0
  finally
    IO.FS.removeDirAll dir

/-- Says how `command`, a scenario of `windowScenarios`, is run, and gives
the exit status 2. -/
private def scenarioUsage (command arguments : String) : IO UInt8 := do
  IO.eprintln s!"usage: ffi-test {command} {arguments}"
  return 2

/-- The mark of `windowScenarios`: running one of them runs a real editor
loop thread (`Editor/RealHost.lean`). -/
def windowScenarios.realHost : Editor.RealHost :=
  .loop

/-- The window scenarios, each a subcommand of `ffi-test` that parses its
own arguments (`Editor.Scenario`): how the root's `main` reaches them, as
the build's `linter.wiringSet` requires, and what `ffi-test
wiring-scenarios` lists for the gate's once-check and the stress loop
(`tools/wiring-runs.sh`). -/
def windowScenarios : List Editor.Scenario :=
  [{  command := "window-host"
      run := fun
        | [file] => windowHostScenario (some file)
        | [] => windowHostScenario none
        | _ => scenarioUsage "window-host" "[<file>]" },
    { command := "window-host-config"
      run := fun
        | [sysroot, oleanDir, configDir] => windowHostConfigScenario sysroot oleanDir configDir
        | _ => scenarioUsage "window-host-config" "<sysroot> <olean dir> <config dir>" },
    { command := "window-host-restart"
      run := fun
        | [sysroot, oleanDir, configDir] => windowHostRestartScenario sysroot oleanDir configDir
        | _ => scenarioUsage "window-host-restart" "<sysroot> <olean dir> <config dir>" },
    { command := "window-host-base"
      run := fun
        | [sysroot, oleanDir, configDir] => windowHostBaseScenario sysroot oleanDir configDir
        | _ => scenarioUsage "window-host-base" "<sysroot> <olean dir> <config dir>" },
    { command := "window-host-generate"
      run := fun
        | [sysroot, oleanDir, configDir] => windowHostGenerateScenario sysroot oleanDir configDir
        | _ => scenarioUsage "window-host-generate" "<sysroot> <olean dir> <config dir>" },
    { command := "window-host-direct"
      run := fun
        | [editorPath, sysroot, configDir] => windowHostDirectScenario editorPath sysroot configDir
        | _ => scenarioUsage "window-host-direct" "<editor> <sysroot> <config dir>" },
    { command := "window-host-undrawn"
      run := fun
        | [file] => windowHostUndrawnScenario file
        | _ => scenarioUsage "window-host-undrawn" "<file>" }]

end FfiTest
