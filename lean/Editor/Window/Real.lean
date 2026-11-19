import Editor.Clipboard.Real
import Editor.Headless
import Editor.Window

/-!
# The editor on a file, in a window

`editor [<file>]`: the headless host's editor loop (`Editor/Headless.lean`)
handed real collaborators, with the window on the process's main thread.
With no file the loop shows its one empty buffer, `scratch`. The files
Finder or the Dock opens the app with are no file of the command line: the
window reports them as an `openFiles` event once it has opened, and the
loop runs `open-file` with them, like every window event the host hands it.
There is one editor loop; this module only wires it to a window:

| Collaborator | The headless mode | The window mode |
|---|---|---|
| Display | the recorder, in cells of 8 by 16 | the real binding over a display on the system's fonts, bound to the window (`Ffi.Display.newSystem`, `Ffi.Display.present`) |
| Clipboard | the host's own | the system's (`Clipboard.Real.system`), or `Clipboard.unavailable` when it cannot be opened, which the echo area says once |
| Syntax tree | the real binding over the library's syntax service (`Editor/SyntaxTree/Real.lean`), made once over the table of snapshots the loop's text binding publishes | the same |
| Driver | the script | none: the open command with the file, when one was given, what the echo area has to say, and a reload when config is loaded at start, are posted before the first event (`Options.starts`), and the window's events are the input |

- **The main thread.** `main` calls `Ffi.windowRun`, which blocks until the
  window has closed. When config is loaded at start it first waits for the
  start-up reload to finish, installed or refused, for at most
  `configPatience` (3 s), and opens the window with the title bar that
  config chose (`titleBar`, `Editor/Setup.lean`; `titleBarAtOpen`):
  the platform cannot change the title bar under an open window. A reload
  that chooses another takes effect at the next start. With no config
  loaded, or when the wait runs out, the window opens themed. The host's thread is a dedicated task, as the keyboard
  check's loop is. When the loop ends, because `:q` let the editor leave or
  the window asked to close, or the system's quit was let go ahead, a task
  that waits on the host's thread (`closeOnceEnded`) says on stderr why
  when the loop ended with an error, waits a little for the render loop to
  draw what was published last, shuts down (`shutdown`: the library's
  children killed and reaped, its watches ended, the queues quit), and then
  asks the window to close (`Ffi.windowClose`). Then `main` exits.
- **The system's quit, let go ahead.** The window port's rule
  (`Platform::close`, in `editor-platform`): a close with the system's quit
  pending lets the quit go ahead and may end the process inside the run,
  which then never returns, as AppKit's terminate does on macOS. So all
  that must come before the end comes before the close: the loop's error
  said, and the shutdown. What follows the run is then not reached: the
  exit status is 0, and `--report` and the "nothing could draw" line are
  not printed.
- **The system's quit, refused over a failure.** A loop that ended with an
  error has the closer ask the window to keep running just before the
  close, which by the same rule refuses a quit pending, so the run returns
  and `main` exits with status 1, and a logout is not carried out over a
  crash.
- **The command line** is read by the pure core (`Editor/Window.lean`).
  `main` reads at the edge what it needs of the world: the working
  directory, `XDG_CONFIG_HOME` and `HOME`, the executable's path, which
  the module directories are resolved from (`Editor/ModuleLookup.lean`),
  and whether the default config directory exists.
- **What is printed.** The host's output and its log go to stderr: the
  reload's report among them, whose first error the echo area says too.
- **Failures.** A window that cannot be opened is
  `editor: the window could not be opened: <reason>` on stderr and status
  1. A window that ran with nothing drawing in it, because its renderer
  could not be made (no adapter, no device, no surface) or its render
  thread did not end well, is known once the window has closed
  (`Ffi.WindowRan.nothingDrew`): it is
  `editor: nothing could draw in the window: <reason>` on stderr, said in
  the echo area too when the loop still runs, and status 1.
- **`--report`** prints, to stderr once the window has closed
  (`reportLines`): what the surface offered, what the run asked for and
  what it was configured with (`Ffi.windowPresentation`), the counters,
  each journal entry's present time since the window was asked to open
  with its `present − input`, their median, 99th percentile (nearest rank)
  and largest, and the longest stretch with no frame (`Report.lines`,
  pinned in `model-test`). It reads them through the latest render
  session's handle, which outlives the window.
- **`--present-mode` and `--frame-latency`** ask for another presentation
  for this run, to measure it (`docs/dev-practices/on-demand-checks.md`):
  the renderer gives the mode asked when the surface offers it, and the
  latency held to the range offered.

`host` is the wiring with the platform, the display and the clipboard
handed in, so that `ffi-test` runs it on the library's scripted platform
with a cells display and a clipboard of its own (`FfiTest`, the scenarios
`window-host`, with a file and with none, `window-host-config`, which
loads a config that keeps the standard title bar and waits for it with no
bound, and `window-host-undrawn` on the scripted platform whose
renderer cannot be made): nothing in the gate opens a window, reads the
machine's fonts or touches the desktop's clipboard.

It is imported by `Editor.Main` and `FfiTest` only: it links the Rust
library.
-/

namespace Editor.Window

/-- How long the window mode waits, once its loop has ended, for the render
loop to draw what was published last before it closes the window, in
milliseconds. -/
def drawPatience : Nat :=
  1000

/-- The library's name of a title bar. -/
def TitleBar.library : TitleBar → Ffi.TitleBar
  | .themed => .themed
  | .standard => .standard

/-- Waits for the start-up reload `host` was sent to finish, installed or
refused, for at most `patience` milliseconds, or with no bound for none;
whether it finished. A loop that has ended has nothing more to finish. -/
def awaitConfig (host : Headless.Host) : Option Nat → IO Bool
  | some patience => return (← host.await patience) == .settled
  | none => do
    repeat
      match ← host.await drawPatience with
      | .settled =>
        return true
      | .ended =>
        return false
      | _ =>
        pure ()
    return false

/-- The library's name of a present mode the command line asked for. -/
def PresentMode.library : PresentMode → Ffi.PresentMode
  | .fifo => .fifo
  | .fifoRelaxed => .fifoRelaxed
  | .immediate => .immediate
  | .mailbox => .mailbox

/-- A present mode of the library's, by wgpu's name. -/
def modeName : Ffi.PresentMode → String
  | .fifo => "fifo"
  | .fifoRelaxed => "fifo-relaxed"
  | .immediate => "immediate"
  | .mailbox => "mailbox"

/-- A present mode and a frame latency, as the report says them. -/
def presentationText (presentation : Ffi.PresentMode × Nat) : String :=
  s!"{modeName presentation.1} at a frame latency of {presentation.2}"

/-- What a run asked for, as the report says it: only the halves it asked
for, and `nothing` when it asked for neither. -/
def askedText : Option Ffi.PresentMode × Option Nat → String
  | (none, none) => "nothing"
  | (some mode, none) => modeName mode
  | (none, some latency) => s!"a frame latency of {latency}"
  | (some mode, some latency) => presentationText (mode, latency)

/-- The report `--report` prints to stderr once the window has closed, read
through the latest render session's handle, which outlives the window: the
presentation the surface offered and was configured with, the counters,
then each journal entry and the figures (`Report.lines`), for a window
asked to open at `opened` and closed at `closed`, on the input clock. -/
def reportLines (opened closed : Nat) : IO (Array String) := do
  let presentation :=
    match ← Ffi.windowPresentation with
    | some offered =>
      let modes := ", ".intercalate (offered.modes.map modeName).toList
      s!"presentation: offered {modes}; asked {askedText offered.asked}; configured {presentationText offered.configured}"
    | none => "presentation: none (no window drew with the wgpu renderer)"
  let counters :=
    match ← Ffi.renderCounters with
    | some c =>
      s!"counters: {c.draws} draws ({c.drawsFailed} failed), {c.framesSubmitted} frames submitted ({c.framesReplaced} replaced), rows {c.rowsRebuilt} rebuilt and {c.rowsReused} reused, glyphs {c.glyphsRasterised} rasterised, {c.glyphsReused} reused, {c.glyphsEvicted} evicted and {c.glyphsSkipped} skipped, atlas {c.atlasBytes} bytes, {c.journalDropped} journal entries dropped"
    | none => "counters: no render session"
  let entries :=
    ((← Ffi.renderJournal 0).getD #[]).map fun entry =>
      ({ inputNs := entry.inputNs.toNat, presentNs := entry.presentNs.toNat } : Report.Entry)
  return #[presentation, counters] ++ Report.lines opened closed entries

/-- The host's request for what the window mode posts before the first
event. -/
def Start.request : Start → Headless.Request
  | .open path => .open path
  | .say text => .say text
  | .reload => .reload

/-- The window mode's display over the snapshots `snapshots`: the host's
display over the real binding over `display`, in the built-in theme, which
sends the requests of the window to the window of `platform`. Pinned on the
scripted platform by `FfiTest.windowChecks`. -/
def hostDisplay (display : Ffi.Display) (platform : Ffi.Platform) (snapshots : SnapshotReader) :
    IO Headless.Host.Display := do
  Headless.Host.Display.real
      (← RealDisplay.over display snapshots Theme.builtin (platform := some platform))

/-- What the window mode does once its editor loop, `loop`, has ended, on
the window of `platform`; whether the loop ended well. By the window port's
rule a close with the system's quit pending may end the process inside the
window's run (`Platform::close`, in `editor-platform`), so everything that
must come before the end comes before the close, in this order:

- a loop that ended with an error is said, with `say` (stderr in the
  window mode): `editor: the editor loop ended with an error: <error>`;
- it waits up to `drawPatience` for the render loop to draw what was
  published last;
- it runs `shutdown`, saying so if it fails;
- after a loop that ended with an error, it asks the window to keep running
  (`Ffi.WindowRequest.keepRunning`), which refuses a system quit pending as
  the window closes, so that the run returns and a logout is not carried out
  over a crash;
- and it asks the window to close.

Pinned on the scripted platform by `FfiTest.windowChecks`. -/
def closeOnceEnded (platform : Ffi.Platform) (loop : Task (Except IO.Error Unit))
    (shutdown : IO Unit) (say : String → IO Unit := IO.eprintln) : IO Bool := do
  let ended ← IO.wait loop
  if let .error error := ended then
    say s!"editor: the editor loop ended with an error: {error}"
  discard <|
      Headless.within drawPatience do
        return (← Ffi.renderResting) != some false
  try
    shutdown
  catch error =>
    say s!"editor: the shutdown failed: {error}"
  if ended matches .error _ then
    Ffi.windowRequest platform .keepRunning
  Ffi.windowClose platform
  return ended matches .ok _

/-- Runs the editor in a window of `platform`, on `options.file` when one
was given, drawn from `display` and with `clipboard` as its clipboard, and
returns once the window has closed: the host is started with `packages` as
the packages it registers (`Headless.shipped`), and what
`options.starts` gives is posted before the first event (the file opened
when one was given, each of `said` said in the echo area, and config
reloaded when `plan` says so); when config is loaded, its reload is waited
for, for at most `patience` milliseconds (none for no bound, which a test
gives so that its result does not race the clock); the window is run, with
the title bar that config chose (`titleBarAtOpen`); and when the host's loop
ends, `closeOnceEnded` says why if it failed, removes the directory of the
config files' module data if one was made (`Headless.Collaborators.dispose`),
runs `shutdown` and closes the window. That comes before the close by the window port's rule: a close with
the system's quit pending may end the process inside the run, so nothing
after the run is reached then.
The exit status: 0 when the window ran with something drawing in it; 1 when
it could not be opened, when nothing could draw in it (`nothingDrew`, said
on stderr, and in the echo area while the loop still runs), or when the loop
ended with an error. The editor's working directory is `workingDirectory`
(`Headless.Collaborators.workingDirectory`): the process's, which `main`
read at the edge. Config is elaborated on `base`, which every caller
names: `main` hands on its package set's (`Editor/Main.lean`, "The base"),
and a test with no set `Editor` alone. `generator` is what creates the
config directory's lakefile and toolchain file when they are absent: `main`
hands its own, and with none, the default, nothing is written into the
config directory. -/
def host (packages : Array Package) (base : Array Lean.Name) (platform : Ffi.Platform)
    (options : Options) (plan : ConfigPlan) (display : Ffi.Display) (clipboard : ClipboardHandler)
    (said : Array String) (shutdown : IO Unit) (processes : Process.Host)
    (patience : Option Nat := some configPatience) (workingDirectory : System.FilePath := "/")
    (generator : Option Config.Generator := none) : IO UInt32 := do
  let shipped ←
    Headless.shipped packages base (options.sysroot.getD "") options.oleans (options.config.getD "")
        IO.eprintln processes
  let collaborators :=
    { shipped with
      display := hostDisplay display platform
      clipboard := pure clipboard
      generator, workingDirectory
      home := processes.home }
  display.present
  let host ← Headless.start collaborators
  for start in options.starts plan said do
    host.send start.request
  -- The loop ends by itself, once `:q` or a close request can leave (one
  -- refused for unsaved changes leaves the loop running): the window is then
  -- closed, once what was published last is drawn.
  -- With the shutdown goes the directory of the config files' module data, if
  -- one was made: the close that follows may end the process.
  let ending : IO Unit := do
    try
      shipped.dispose
    catch _ =>
      pure ()
    shutdown
  let closer ← IO.asTask (prio := .dedicated) (closeOnceEnded platform host.thread ending)
  -- The title bar is chosen as the window opens, so config loaded at start
  -- is waited for first (`awaitConfig`), for at most `patience`.
  let titleBar ←
    match plan with
    | .load _ =>
      do
        let settled ← awaitConfig host patience
        pure (titleBarAtOpen settled (← host.progress.get).titleBar)
    | .skip _ =>
      pure (titleBarAtOpen true none)
  let opened ← Ffi.inputClock
  let ran ←
    Ffi.windowRun platform options.composition (options.presentMode.map PresentMode.library)
        options.frameLatency (titleBar := titleBar.library)
  let closed ← Ffi.inputClock
  -- Nothing drew in the window: a loop still running says why in the echo
  -- area before it ends.
  if let .ok { nothingDrew := some reason } := ran then
    unless ← IO.hasFinished host.thread do
      -- The loop may end, and the shutdown quit the queues, in between.
      try
        host.send (.say (nothingDrew reason))
      catch _ =>
        pure ()
  -- The window has closed, or never opened: a loop still running is ended.
  -- A loop that ended with an error was said by the closer, which reads the
  -- same result.
  let ended ←
    try
      host.halt Headless.settlePatience
    catch _ =>
      pure false
  discard <| IO.wait closer
  match ran with
  | .ok ran =>
    if let some reason := ran.nothingDrew then
      IO.eprintln s!"editor: {nothingDrew reason}"
    if options.report then
      for line in ← reportLines opened.toNat closed.toNat do
        IO.eprintln line
    return if ended && ran.nothingDrew.isNone then 0 else 1
  | .error reason =>
    IO.eprintln s!"editor: the window could not be opened: {reason}"
    return 1

/-- The window mode's shutdown, which `host` runs once the loop has ended
and before it closes the window: every child the library started is killed
and reaped, every watch is ended, and then the queues are quit, as the
headless mode does. -/
def shutdown : IO Unit := do
  Ffi.processesShutdown
  Ffi.watchesShutdown
  Ffi.quit

/-- What the window mode is told of the world, read at the edge, for the
executable at `appPath`: the working directory, the two variables the
default config directory is found by, and the `.olean` directories the
build recorded beside that executable (`ModuleLookup.recorded`, with the
real file read: a record that is not there, or cannot be read, is none).
`main` reads it for the running executable, and `ffi-test
window-host-direct` for an editor it is pointed at. -/
def environmentAt (appPath : String) : IO Environment := do
  let readFile (path : System.FilePath) : IO (Option String) := do
    try
      return some (← IO.FS.readFile path)
    catch _ =>
      return none
  return {
      workingDirectory := (← IO.currentDir).toString
      xdgConfigHome := ← IO.getEnv "XDG_CONFIG_HOME", home := ← IO.getEnv "HOME", appPath
      recordedOleans := ← ModuleLookup.recorded appPath readFile }

/-- `editor [<file>]`, with the packages its host registers, the base
config is elaborated on, what the build says of the editor for the files
it generates in the config directory (`origin`) and the command line's
`arguments`: reads the world at
the edge, opens the system's display and clipboard, and runs `host` on the
real window, with `shutdown`. A command line it does not take is the reason
and the usage on stderr, and status 2. It exits explicitly, with the status
`host` gave. When the system's quit was let go ahead, the platform may have
ended the process with status 0 inside the run instead (the window port's
rule; AppKit's terminate on macOS), once `shutdown` had run. -/
def main (packages : Array Package) (base : Array Lean.Name) (origin : Config.LakePackage.Origin)
    (arguments : List String) : IO UInt32 := do
  let appPath := (← IO.appPath).toString
  let environment ← environmentAt appPath
  let options ←
    match parse environment arguments with
    | .ok options =>
      pure options
    | .error message =>
      IO.eprintln message
      return 2
  let defaultExists ←
    match options.config with
    | some directory =>
      if options.configGiven then
        pure false
      else
        System.FilePath.isDir directory
    | none =>
      pure false
  let plan := options.configPlan defaultExists
  let (clipboard, unavailable) ←
    match ← Clipboard.Real.system with
    | .ok real =>
      pure (real.handle, #[])
    | .error reason =>
      pure (Clipboard.unavailable, #[s!"clipboard: unavailable: {reason}"])
  let said :=
    (match plan with
      | .skip (some text) => #[text]
      | _ => #[]) ++
      unavailable
  -- `auto` takes mise under the home directory first, when `HOME` names one.
  let home := environment.home.filter (!·.isEmpty) |>.map System.FilePath.mk
  -- The window mode may write into the config directory it loads: a reload
  -- creates the lakefile and the toolchain file the directory lacks.
  let generator ←
    match options.config with
    | some directory =>
      some <$> Headless.generatorAt origin appPath directory
    | none =>
      pure none
  let status ←
    host packages base .winit options plan (← Ffi.Display.newSystem) clipboard said shutdown
        (.window home) (workingDirectory := environment.workingDirectory) (generator := generator)
  IO.Process.exit status.toUInt8

end Editor.Window
