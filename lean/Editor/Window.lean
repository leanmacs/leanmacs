import Editor.ModuleLookup

/-!
# The window mode's command line

`editor [--config <dir>] [--state <dir>] [--sysroot <dir>] [--oleans <dir>] [--no-ime] [<file>]`
opens a window (`Editor/Window/Real.lean`), on `<file>` when one is given.
This module is the pure part of that: what the command line asks for, given
what the edge read of the world (`Environment`), whether config is loaded
at start (`Options.configPlan`), and what is posted to the editor loop
before the first event (`Options.starts`). It reads nothing itself, so
`model-test` pins it (`ModelTest.windowOptionChecks`, and
`ModelTest.windowStartChecks` for what the loop then holds).

- **The file** is resolved against the working directory: the file port
  takes absolute paths only. At most one file is taken; with none the
  editor starts on its one empty buffer, which is how Finder starts the
  app. A Finder start posts no open: the files Finder opens the app with
  arrive from the window, as an `openFiles` event after it has opened,
  and the loop opens them (`Editor/Loop.lean`, "What each event does").
- **`--sysroot`** is the Lean toolchain's directory. When not given it is
  the bundle's, `Contents/Resources/lean/toolchain`, for an executable in a
  bundle (`Editor/ModuleLookup.lean`). Outside one there is no default: Lean
  cannot run `lean --print-prefix` (that would spawn a process), so with
  none given no config is loaded, and the echo area says so (`noToolchain`).
- **`--oleans`** is the directory of the editor's `.olean` files. When not
  given it is the bundle's, `Contents/Resources/lean/editor`, for an
  executable in a bundle, and `<directory of the executable>/../lib/lean`
  outside one, where Lake puts them in the build tree.
- **`--config`** is the config directory. When not given it is `leanmacs`
  under `$XDG_CONFIG_HOME`, or under `$HOME/.config` when that is unset or
  empty. A default directory that does not exist loads nothing and says
  nothing; a given one is reloaded whether it exists or not, so that a
  directory that does not exist is a rejected reload, said in the echo area.
- **`--state`** is the state directory, where what is kept across a
  restart lives (the working sets, `Editor/WorkingSet/Disk.lean`). When not
  given it is `leanmacs` under `$XDG_STATE_HOME`, or under
  `$HOME/.local/state` when that is unset or empty; none when neither is
  set, and then nothing is kept across a restart. The host hands it to the
  loop's first state (`EditorState.stateDirectory`, through
  `EditorState.hostedBy`). Nothing is made at start: a directory that is
  not there is made when something is first written in it.
- **`--no-ime`** runs the window with no input method composing.

Two files, an option it does not know, and an option with no value are
refused, with the usage (`usage`).
-/

namespace Editor.Window

/-- What the edge of the program read of the world for the command line:
the working directory, the two variables a config directory is found by,
and where the executable is (`IO.appPath`). -/
structure Environment where
  /-- The working directory, absolute. -/
  workingDirectory : String
  /-- `$XDG_CONFIG_HOME`, if it is set. -/
  xdgConfigHome : Option String
  /-- `$XDG_STATE_HOME`, if it is set. -/
  xdgStateHome : Option String := none
  /-- `$HOME`, if it is set. -/
  home : Option String
  /-- The executable's path. -/
  appPath : String
  deriving DecidableEq, Repr

/-- A way a frame reaches the display, by wgpu's names, that one run may ask
for in place of the renderer's decision, to measure it. -/
inductive PresentMode where
  /-- `fifo`. -/
  | fifo
  /-- `fifo-relaxed`. -/
  | fifoRelaxed
  /-- `immediate`. -/
  | immediate
  /-- `mailbox`. -/
  | mailbox
  deriving DecidableEq, Repr

/-- The title bar the window opens with. Config chooses it (`titleBar`,
`Editor/Setup.lean`); the window mode reads the choice when it opens the
window (`titleBarAtOpen`), since the platform cannot change it under an
open window. -/
inductive TitleBar where
  /-- The window's content extends under a title bar that draws no
  background of its own, so the paper shows there, and the title and the
  buttons are drawn in the appearance that contrasts with it. The views
  along the frame's top edge start their text below the title bar
  (`EditorState.topInset`). On a platform with no such title bar the
  window has its standard one. The default. -/
  | themed
  /-- The system's own title bar, in the system's colours, above the
  content. -/
  | standard
  deriving DecidableEq, Repr, Inhabited

/-- How long the window mode waits for the config it loads at start before
it opens the window, in milliseconds: the window is opened with the title
bar that config chose, so it waits for the start-up reload to finish,
installed or refused, and for no longer than this. -/
def configPatience : Nat :=
  3000

/-- The title bar the window opens with, given whether the start-up reload
had finished when the wait for it ended (`settled`) and the title bar the
installed config chose, if one did (`installed`): the config's when the
reload finished, and themed when it did not, or when no config chose one.
With no config loaded at start there is no wait, and no config chose one. -/
def titleBarAtOpen (settled : Bool) (installed : Option TitleBar) : TitleBar :=
  if settled then installed.getD .themed else .themed

/-- The present mode a command line names, by wgpu's names. -/
def PresentMode.named? : String → Option PresentMode
  | "fifo" => some .fifo
  | "fifo-relaxed" => some .fifoRelaxed
  | "immediate" => some .immediate
  | "mailbox" => some .mailbox
  | _ => none

/-- A present mode's name, as the command line and the report say it. -/
def PresentMode.name : PresentMode → String
  | .fifo => "fifo"
  | .fifoRelaxed => "fifo-relaxed"
  | .immediate => "immediate"
  | .mailbox => "mailbox"

/-- What the window mode's command line asks for. -/
structure Options where
  /-- The file to open, absolute; none when no file was given, and the
  editor starts on its one empty buffer. -/
  file : Option String
  /-- The config directory: given, or the default; none when there is no
  default, because neither variable it is found by is set. -/
  config : Option String
  /-- Whether the config directory was given with `--config`. -/
  configGiven : Bool
  /-- The state directory: given with `--state`, or the default; none when
  there is no default, because neither variable it is found by is set. -/
  state : Option String := none
  /-- The Lean toolchain's directory, if one was given. -/
  sysroot : Option String
  /-- The directory of the editor's `.olean` files. -/
  oleans : String
  /-- Whether an input method may compose: `false` with `--no-ime`. -/
  composition : Bool
  /-- Whether the window mode prints its report to stderr once the window
  has closed (`--report`). -/
  report : Bool := false
  /-- The present mode this run asks for (`--present-mode`); none for the
  renderer's decision. -/
  presentMode : Option PresentMode := none
  /-- The frame latency this run asks for (`--frame-latency`); none for the
  renderer's decision. -/
  frameLatency : Option Nat := none
  deriving DecidableEq, Repr

/-- The window mode's command line, as the usage says it. -/
def usage : String :=
  "[--config <dir>] [--state <dir>] [--sysroot <dir>] [--oleans <dir>] [--no-ime] [--report] [--present-mode fifo|fifo-relaxed|immediate|mailbox] [--frame-latency <n>] [<file>]"

/-- What the window mode says, on stderr after `editor: ` and in the echo
area, when nothing could draw in the window, for `reason`. -/
def nothingDrew (reason : String) : String :=
  s!"nothing could draw in the window: {reason}"

/-- What the echo area says when no config is loaded because no toolchain
was given. -/
def noToolchain : String :=
  "config: not loaded: no Lean toolchain given (--sysroot)"

/-- The default config directory: `leanmacs` under `$XDG_CONFIG_HOME`, or
under `$HOME/.config` when that is unset or empty; none when neither is
set. -/
def defaultConfig (environment : Environment) : Option String :=
  match environment.xdgConfigHome.filter (!·.isEmpty), environment.home with
  | some xdg, _ => some (System.FilePath.mk xdg / "leanmacs").toString
  | none, some home => some (System.FilePath.mk home / ".config" / "leanmacs").toString
  | none, none => none

/-- The default state directory: `leanmacs` under `$XDG_STATE_HOME`, or
under `$HOME/.local/state` when that is unset or empty; none when neither is
set. -/
def defaultState (environment : Environment) : Option String :=
  match environment.xdgStateHome.filter (!·.isEmpty), environment.home with
  | some xdg, _ => some (System.FilePath.mk xdg / "leanmacs").toString
  | none, some home => some (System.FilePath.mk home / ".local" / "state" / "leanmacs").toString
  | none, none => none

/-- `path` resolved against the working directory: kept when it is
absolute. -/
def resolve (environment : Environment) (path : String) : String :=
  let path := System.FilePath.mk path
  if path.isAbsolute then path.toString
  else (System.FilePath.mk environment.workingDirectory / path).toString

/-- The options read so far. -/
structure Read where
  /-- The file, as given. -/
  file : Option String := none
  /-- `--config`'s directory. -/
  config : Option String := none
  /-- `--state`'s directory. -/
  state : Option String := none
  /-- `--sysroot`'s directory. -/
  sysroot : Option String := none
  /-- `--oleans`'s directory. -/
  oleans : Option String := none
  /-- `false` once `--no-ime` is read. -/
  composition : Bool := true
  /-- `true` once `--report` is read. -/
  report : Bool := false
  /-- `--present-mode`'s mode. -/
  presentMode : Option PresentMode := none
  /-- `--frame-latency`'s number. -/
  frameLatency : Option Nat := none

/-- Reads `arguments` into `read`, or says what is wrong. -/
def readAll (read : Read) : List String → Except String Read
  | [] => .ok read
  | "--config" :: directory :: rest => readAll { read with config := some directory } rest
  | "--state" :: directory :: rest => readAll { read with state := some directory } rest
  | "--sysroot" :: directory :: rest => readAll { read with sysroot := some directory } rest
  | "--oleans" :: directory :: rest => readAll { read with oleans := some directory } rest
  | "--no-ime" :: rest => readAll { read with composition := false } rest
  | "--report" :: rest => readAll { read with report := true } rest
  | "--present-mode" :: mode :: rest =>
    match PresentMode.named? mode with
    | some mode => readAll { read with presentMode := some mode } rest
    | none => .error s!"{mode} is not a present mode: fifo, fifo-relaxed, immediate or mailbox"
  | "--frame-latency" :: count :: rest =>
    match count.toNat? with
    | some (latency + 1) => readAll { read with frameLatency := some (latency + 1) } rest
    | _ => .error s!"{count} is not a frame latency: a number from 1"
  | argument :: rest =>
    if argument.startsWith "-" then
      if ["--config", "--state", "--sysroot", "--oleans"].contains argument then
        .error s!"{argument} needs a directory after it"
      else
        if ["--present-mode", "--frame-latency"].contains argument then
          .error s!"{argument} needs a value after it"
        else .error s!"{argument} is not an option"
    else
      match read.file with
      | some _ => .error "only one file is opened"
      | none => readAll { read with file := some argument } rest

/-- What `arguments`, the command line, asks for, given `environment`; or
why it is refused, followed by a line of the usage. -/
def parse (environment : Environment) (arguments : List String) : Except String Options :=
  let refused (reason : String) : Except String Options :=
    .error s!"{reason}\nusage: editor {usage}"
  match readAll {} arguments with
  | .error reason => refused reason
  | .ok read =>
    let directories :=
      ModuleLookup.resolve environment.appPath { sysroot := read.sysroot, oleans := read.oleans }
    .ok {
        file := read.file.map (resolve environment)
        config := read.config <|> defaultConfig environment
        configGiven := read.config.isSome
        state := (read.state.map (resolve environment)) <|> defaultState environment
        sysroot := directories.sysroot
        oleans := directories.oleans
        composition := read.composition
        report := read.report
        presentMode := read.presentMode
        frameLatency := read.frameLatency }

/-- The state directory the host hands the loop's first state. -/
def Options.stateDirectory (options : Options) : Option System.FilePath :=
  options.state.map System.FilePath.mk

/-- Whether config is loaded at start, and what the echo area says if it
is not. -/
inductive ConfigPlan where
  /-- A reload of this directory is posted before the first event. -/
  | load (directory : String)
  /-- Nothing is loaded; the echo area says this, if anything. -/
  | skip (said : Option String)
  deriving DecidableEq, Repr

/-- Whether config is loaded at start, given whether the default config
directory exists (`defaultExists`, which the edge reads): never with no
toolchain, which is said; from a directory given with `--config`, whether
it exists or not; and from the default one only when it exists. -/
def Options.configPlan (options : Options) (defaultExists : Bool) : ConfigPlan :=
  match options.sysroot, options.config with
  | none, _ => .skip (some noToolchain)
  | some _, none => .skip none
  | some _, some directory =>
    if options.configGiven || defaultExists then .load directory else .skip none

/-- What the window mode posts to the editor loop before the first event. -/
inductive Start where
  /-- Open the file at `path`, which is absolute. -/
  | «open» (path : String)
  /-- Say `text` in the echo area. -/
  | say (text : String)
  /-- Reload config. -/
  | reload
  deriving DecidableEq, Repr

/-- What the window mode posts before the first event, in order: the open
of the file, if one was given; then each of `said`; then a reload when
`plan` loads config. With no file nothing is opened, and the loop shows its
one empty buffer. -/
def Options.starts (options : Options) (plan : ConfigPlan) (said : Array String) : Array Start :=
  let opens :=
    match options.file with
    | some path => #[Start.open path]
    | none => #[]
  let reloads :=
    match plan with
    | .load _ => #[Start.reload]
    | .skip _ => #[]
  opens ++ said.map .say ++ reloads

namespace Report

/-- A frame the render loop presented, as the report reads it from the
journal: when the input it answers was stamped, and when it was presented,
in nanoseconds of the input clock. -/
structure Entry where
  /-- When the input it answers was stamped. -/
  inputNs : Nat
  /-- When the renderer returned, having presented it. -/
  presentNs : Nat
  deriving DecidableEq, Repr

/-- What the report says of a journal, in microseconds. -/
structure Summary where
  /-- How many frames were presented. -/
  frames : Nat
  /-- The median of their `present − input`, by nearest rank. -/
  median : Nat
  /-- The 99th percentile of their `present − input`, by nearest rank. -/
  p99 : Nat
  /-- The largest of their `present − input`. -/
  max : Nat
  /-- The longest stretch with no frame presented: from the open to the
  first, between two, or from the last to the close. -/
  longestGap : Nat
  deriving DecidableEq, Repr

/-- The nearest-rank `rank`th percentile of `sorted`, which is in ascending
order: the value at rank ⌈rank × n / 100⌉, from 1, of its n values; 0 for
none. -/
def nearestRank (sorted : Array Nat) (rank : Nat) : Nat :=
  sorted.getD (((rank * sorted.size + 99) / 100) - 1) 0

/-- The report's figures over `entries`, oldest first, for a window asked to
open at `opened` and closed at `closed`, both in nanoseconds of the input
clock: `present − input` of each entry, and the stretches between the open,
each entry's present and the close. -/
def summary (opened closed : Nat) (entries : Array Entry) : Summary :=
  let latencies := (entries.map fun entry => (entry.presentNs - entry.inputNs) / 1000).qsort (· < ·)
  let marks := #[opened] ++ entries.map (·.presentNs) ++ #[closed]
  let gaps :=
    (List.range (marks.size - 1)).map fun index => (marks[index + 1]! - marks[index]!) / 1000
  { frames := entries.size, median := nearestRank latencies 50, p99 := nearestRank latencies 99
    max := latencies.back?.getD 0, longestGap := gaps.foldl Nat.max 0 }

/-- The report's lines for `entries`, for a window asked to open at `opened`
and closed at `closed`: each entry's present time since the open, in
milliseconds, with its `present − input` in microseconds; then the figures
(`summary`). -/
def lines (opened closed : Nat) (entries : Array Entry) : Array String :=
  let summary := summary opened closed entries
  let each :=
    entries.map fun entry =>
      s!"frame at {(entry.presentNs - opened) / 1000000} ms: present - input {(entry.presentNs - entry.inputNs) / 1000} us"
  each ++
    #[s!"frames: {summary.frames}; present - input median {summary.median} us, p99 {summary.p99} us, max {summary.max} us",
      s!"longest stretch with no frame: {summary.longestGap / 1000} ms"]

end Report

end Editor.Window
