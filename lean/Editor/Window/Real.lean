import Editor.Clipboard.Real
import Editor.Headless
import Editor.Window

/-!
# The editor on a file, in a window

`editor <file>`: the headless host's editor loop (`Editor/Headless.lean`)
handed real collaborators, with the window on the process's main thread.
There is one editor loop; this module only wires it to a window:

| Collaborator | The headless mode | The window mode |
|---|---|---|
| Display | the recorder, in cells of 8 by 16 | the real binding over a display on the system's fonts, bound to the window (`Ffi.Display.newSystem`, `Ffi.Display.present`) |
| Clipboard | the host's own | the system's (`Clipboard.Real.system`), or `Clipboard.unavailable` when it cannot be opened, which the echo area says once |
| Driver | the script | none: the open command with the file, what the echo area has to say, and a reload when config is loaded at start, are posted before the first event, and the window's events are the input |

- **The main thread.** `main` calls `Ffi.windowRun`, which blocks until the
  window has closed. The host's thread is a dedicated task, as the keyboard
  check's loop is. When the loop ends, because `:q` let the editor leave or
  the window asked to close, a task that waits on the host's thread waits a
  little for the render loop to draw what was published last, and then asks
  the window to close (`Ffi.windowClose`). Then `main` quits the queues and
  exits.
- **The command line** is read by the pure core (`Editor/Window.lean`).
  `main` reads at the edge what it needs of the world: the working
  directory, `XDG_CONFIG_HOME` and `HOME`, the executable's path, and
  whether the default config directory exists.
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
`window-host`, and `window-host-undrawn` on the scripted platform whose
renderer cannot be made): nothing in the gate opens a window, reads the
machine's fonts or touches the desktop's clipboard.

It is imported by `Main` and `FfiTest` only: it links the Rust library.
-/

namespace Editor.Window

/-- How long the window mode waits, once its loop has ended, for the render
loop to draw what was published last before it closes the window, in
milliseconds. -/
def drawPatience : Nat :=
  1000

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

/-- Runs the editor on `options.file` in a window of `platform`, drawn from
`display` and with `clipboard` as its clipboard, and returns once the window
has closed: the host is started, the file is opened, each of `said` is said
in the echo area and config is reloaded when `plan` says so, all before the
first event; the window is run; and it is closed when the host's loop ends.
The exit status: 0 when the window ran with something drawing in it; 1 when
it could not be opened, when nothing could draw in it (`nothingDrew`, said
on stderr, and in the echo area while the loop still runs), or when the loop
ended with an error. -/
def host (platform : Ffi.Platform) (options : Options) (plan : ConfigPlan) (display : Ffi.Display)
    (clipboard : ClipboardHandler) (said : Array String) : IO UInt32 := do
  let shipped ←
    Headless.shipped (options.sysroot.getD "") options.oleans (options.config.getD "") IO.eprintln
  let collaborators :=
    { shipped with
      display := fun snapshots => do
        Headless.Host.Display.real (← RealDisplay.over display snapshots Theme.builtin)
      clipboard := pure clipboard }
  display.present
  let host ← Headless.start collaborators
  host.send (.open options.file)
  for text in said do
    host.send (.say text)
  if let .load _ := plan then
    host.send .reload
  -- The loop ends by itself, on `:q` or a close request: the window is then
  -- closed, once what was published last is drawn.
  let closer ←
    IO.asTask (prio := .dedicated) do
        discard <| IO.wait host.thread
        discard <|
            Headless.within drawPatience do
              return (← Ffi.renderResting) != some false
        Ffi.windowClose platform
  let opened ← Ffi.inputClock
  let ran ←
    Ffi.windowRun platform options.composition (options.presentMode.map PresentMode.library)
        options.frameLatency
  let closed ← Ffi.inputClock
  -- Nothing drew in the window: a loop still running says why in the echo
  -- area before it ends.
  if let .ok { nothingDrew := some reason } := ran then
    unless ← IO.hasFinished host.thread do
      host.send (.say (nothingDrew reason))
  -- The window has closed, or never opened: a loop still running is ended.
  let ended ←
    try
      host.halt Headless.settlePatience
    catch error =>
      IO.eprintln s!"editor: the editor loop ended with an error: {error}"
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

/-- `editor <file>`, with the command line's `arguments`: reads the world at
the edge, opens the system's display and clipboard, and runs `host` on the
real window. A command line it does not take is the reason and the usage on
stderr, and status 2. It shuts the library's process service down, which
kills and reaps every child it started, quits the queues and exits
explicitly, as the headless mode does. -/
def main (arguments : List String) : IO UInt32 := do
  let environment : Environment :=
    { workingDirectory := (← IO.currentDir).toString, xdgConfigHome := ← IO.getEnv "XDG_CONFIG_HOME"
      home := ← IO.getEnv "HOME", appPath := (← IO.appPath).toString }
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
  let status ← host .winit options plan (← Ffi.Display.newSystem) clipboard said
  -- Every child the library started is killed and reaped before the queues
  -- are quit, and every watch is ended.
  Ffi.processesShutdown
  Ffi.watchesShutdown
  Ffi.quit
  IO.Process.exit status.toUInt8

end Editor.Window
