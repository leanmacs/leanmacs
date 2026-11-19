import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Compile
import Editor.Compile.Compiled
import Editor.Compile.Contribution
import Editor.Compile.Errors
import Editor.Compile.Listing
import Editor.Config.Owner
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.Ex.Compiled
import Editor.Ex.Line
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Keymap
import Editor.Loop
import Editor.Loop.Driver
import Editor.Minibuffer
import Editor.Mode
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.Scene
import Editor.Setup
import Editor.State
import Editor.Text
import Editor.Value
import Editor.Workspace
import Editor.Workspace.Modes
import ModelTest.Support.Driver
import ModelTest.Support.Files
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Shell

/-!
# Model tests: support: Compile

The compile commands' world: their jobs, keys, bindings and driver, the error
formats they read, and the compile hook's setup. Shared by several test modules
under `ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor

/-- The jobs of the compile checks: the shell checks', the compile's run job
and its listing job. -/
def compileJobs (name : String) : Option (List Argument → Work) :=
  if name == Compile.runJob then some Compile.runWork
  else if name == Compile.listJob then some Compile.listWork else shellJobs name

/-- Steps that write each of `lines` with a line feed on standard output,
pausing 100 ms between writes, so each is delivered, and posted, alone. -/
def linesSteps (lines : List String) : Array Process.Step :=
  (lines.toArray.map fun line => Process.Step.write .out (line ++ "\n").toUTF8).foldl
    (fun steps write => if steps.isEmpty then #[write] else steps ++ #[.pause 100, write]) #[]

/-- The place of the workspace `/r`. -/
def placeR : Compile.Place :=
  .workspace (.local "/r")

/-- The bindings of the compile checks: the shell checks', and `C-k c`
(`compile`), `C-k m` (`compile` with `make`), `C-k r` (`recompile`), `C-k k`
(`kill-compilation`), `C-k t` (`insert-x`, which inserts `x` at the window's
cursors), `C-k 0` (`to-start`, which puts the window's cursor at offset 0),
`C-k o` (`focus-compilation`, which focuses the first view that shows a
compilation buffer), `C-k s` (`squat`, which makes a buffer
`*compilation: r@main (clone)*` the compile did not make), `C-k z` (a stale
`compilation-output` of `/r`'s first run), `C-k q`, which cancels the open
prompt, `C-o q`, which opens `/clone/r/src/a.lean`, and `C-k h` (`compile`
with `check`, asking nothing, so a new compilation buffer is in view 1,
below view 0). For stepping: `C-k n` (`next-error`), `C-k p`
(`previous-error`), `C-k e` (`compile-goto-error`), and `C-k g` and `C-k j`
(`to-point`, which puts the window's cursor at row 4, column 3, and at row
2, column 0), and `C-k b` (`zero-base`, which has every location `/r` keeps
count its columns from 0, as those of a format whose `columnBase` is 0
do). -/
def compileBindings : List (String × Invocation) :=
  shellBindings ++
    [("C-k c", invoke Compile.compileName),
      ("C-k m", { command := Compile.compileName, arguments := [.str "make"] }),
      ("C-k r", invoke "recompile"), ("C-k k", invoke Compile.killName),
      ("C-k t", invoke "insert-x"), ("C-k 0", invoke "to-start"),
      ("C-k o", invoke "focus-compilation"), ("C-k s", invoke "squat-clone"),
      ("C-k z",
        { command := Compile.outputName
          arguments := placeR.arguments ++ [.nat 1, .str "stale"] }),
      ("C-k q", invoke Minibuffer.cancelName), ("C-o q", opens "/clone/r/src/a.lean"),
      ("C-k h", { command := Compile.compileName, arguments := [.str "check"] }),
      ("C-k n", invoke Compile.nextName), ("C-k p", invoke Compile.previousName),
      ("C-k e", invoke Compile.gotoName),
      ("C-k g", { command := "to-point", arguments := [.nat 4, .nat 3] }),
      ("C-k j", { command := "to-point", arguments := [.nat 2, .nat 0] }),
      ("C-k b", invoke "zero-base")]

/-- The commands of the compile checks (`compileBindings`). -/
def compileCommands : List (String × Dispatched) :=
  let insertX : Dispatched := fun call => do
    call.target.insertAtSelections "x"
    return none
  let toStart : Dispatched := fun call => do
    discard <| call.target.window.id.select { ranges := #[⟨0, 0⟩] }
    return none
  let focusCompilation : Dispatched := fun _ => do
    let state ← editorState
    let shows (window : Window) : Bool :=
      (state.buffer? window.buffer).any (·.name.startsWith "*compilation")
    if let some window := state.windows.find? shows then
      discard <| window.id.focus
    return none
  let squat : Dispatched := fun _ => do
    discard <| createBuffer "*compilation: r@main (clone)*"
    return none
  let toPoint : Dispatched := fun call => do
    if let .nat row :: .nat column :: _ := call.arguments then
      let offset ← call.target.buffer.text.offsetOf ⟨row, column⟩
      discard <| call.target.window.id.select { ranges := #[⟨offset, offset⟩] }
    return none
  let zeroBase : Dispatched := fun _ => do
    let record := Compile.recordOf (← editorState) placeR
    Compile.setRecord placeR
        { record with locations := record.locations.map ({ · with columnBase := 0 }) }
    return none
  shellCommands ++ dispatchedOf Compile.package.registered.commands ++
    [("insert-x", insertX), ("to-start", toStart), ("focus-compilation", focusCompilation),
      ("squat-clone", squat), ("to-point", toPoint), ("zero-base", zeroBase)]

/-- The keys of the compile checks over `bindings`, with the compile mode
and the ex names that ship registered: the active keymaps of a registry
holding the compile mode's modes, so the mode's roles are on their keys in
a compilation buffer as a host's registry puts them, then the keymap of
`bindings`. -/
def compileKeysOf (bindings : List (String × Invocation)) : Loop.Keys TestScheme.scheme :=
  let keys := dispatchKeys bindings compileCommands
  let registry := ({} : Config.Registry).replaceModes .compiled Compile.package.registered.modes
  { keys with
    maps := fun state view =>
      registry.activeMaps TestScheme.scheme state view ++ keys.maps state view
    registered :=
      { keys.registered with
        entering := fun name => (Compile.package.registered.modes.find? (·.name == name)).map ([·])
        ex := fun name => Ex.package.registered.ex.find? (·.name == name)
        exNames := Ex.package.registered.ex.map (·.name) } }

/-- `driver` once every post is delivered and every pending job finished,
oldest first, a post before a job's end; bounded. -/
def drained (driver : TestDriver) : TestDriver :=
  (List.range 64).foldl
    (fun driver _ =>
      match driver.posting[0]? with
      | some job => (driver.posted job.id).1
      | none =>
        match driver.pending[0]? with
        | some job => (driver.finish job.id).1
        | none => driver)
    driver

/-- `driver` once `keys` are pressedOn, with nothing settled. -/
def pressedOn (driver : TestDriver) (keys : String) : TestDriver :=
  (fedTo driver (presses keys)).1

/-- The format `t-lead` of the lead checks: a location line `  at
<file>:<line>`, maybe followed by ` note`, its severity, after a lead line
`<error|warning>: <message>` that gives its severity and message. -/
def leadFormat : Compile.Format :=
  { name := "t-lead"
    pattern :=
      [Compile.step
          [{ atom := .blanks }, { atom := .literal "at " },
            { atom := .noneOf [':', ' '], into := some .file }, { atom := .literal ":" },
            { atom := .digits, into := some .line }],
        Compile.optionalStep
          [{ atom := .literal " " }, { atom := .oneOf ["note"], into := some .severity }]]
    lead :=
      some
        [Compile.step
            [{ atom := .oneOf ["error", "warning"], into := some .severity },
              { atom := .literal ": " }, { atom := .rest, into := some .message }]] }

/-- The error format `name` of the hook checks: `at <file> line <line>`, which
the general format does not read. -/
def atFormat (name : String) : Compile.Format :=
  { name
    pattern :=
      [Compile.step
          [{ atom := .literal "at " }, { atom := .noneOf [' '], into := some .file },
            { atom := .literal " line " }, { atom := .digits, into := some .line }],
        Compile.step [{ atom := .rest }]] }

/-- `a-mode`'s formats in the hook checks. -/
def aFormats : Array Compile.Format :=
  #[atFormat "a-at"]

/-- `b-mode`'s formats in the hook checks: its own `at` format, then the
general one under another name. -/
def bFormats : Array Compile.Format :=
  #[atFormat "b-at", { Compile.Format.general with name := "b-general" }]

/-- `a-mode`'s commands in the hook checks, as `hookSetup` registers them by
default. -/
def aCommands : Array Compile.NamedCommand :=
  #[{ name := "build", line := "a-build" }, { name := "test", line := "a-test" }]

/-- The project commands of the hook checks: `lint` of `cargo-mode` for
`github.com/o/r`, as `cargo clippy`, with the setting `profile` `dev`. -/
def lintProject : SetupM Unit :=
  projectCommands (.remote "github.com/o/r") "cargo-mode" [("lint", "cargo clippy")]
    [("profile", .str "dev")]

/-- The config of the hook checks, in this order: `b-mode` on `b.toml`,
`a-mode` on `a.toml` with `aCommands` as its commands unless it is given
others, `marker-mode` on `marker.toml` and `cargo-mode` on `Cargo.toml`;
then `project`, by default `lintProject`. -/
def hookSetup (aCommands : Array Compile.NamedCommand := aCommands)
    (project : SetupM Unit := lintProject) : SetupM Unit := do
  compileContribution
      { mode := "b-mode", markers := #["b.toml"]
        commands :=
          #[{ name := "build", line := "b-build" }, { name := "check", line := "b-check" }]
        formats := bFormats }
  compileContribution
      { mode := "a-mode", markers := #["a.toml"], commands := aCommands, formats := aFormats }
  compileContribution
      { mode := "marker-mode", markers := #["marker.toml"]
        commands := #[{ name := "build", line := "m-build" }] }
  compileContribution
      { mode := "cargo-mode", markers := #["Cargo.toml"]
        commands :=
          #[{ name := "build", line := "cargo build" }, { name := "test", line := "cargo test" }] }
  project

/-- The registry of the hook checks: `setup`'s contributions and project
commands installed for config, over `compiled` for the owner `compiled`. -/
def hookRegistry (setup : SetupM Unit := hookSetup) (compiled : Array Compile.Contribution := #[]) :
    Config.Registry :=
  let base := ({} : Config.Registry).replaceContributions .compiled compiled
  match Config.Registrations.ofSetup setup with
  | .ok registrations =>
    { base.replaceContributions .config registrations.contributions with
      projectCommands := registrations.projectCommands }
  | .error _ => base

/-- The bindings of the hook checks: the compile checks', `C-k i`
(`compile-command`), and `C-o m`, `C-o u`, `C-o l`, `C-o 2`, `C-o h`, `C-o
g`, `C-o k`, `C-o 3` and `C-o 4`, which open the files of `hookFiles` in
that order. Test-scheme chords only. -/
def hookBindings : List (String × Invocation) :=
  compileBindings ++
    [("C-k i", invoke Compile.commandName), ("C-o m", opens "/r/a/b/c/x.txt"),
      ("C-o u", opens "/up/repo/src/u.txt"), ("C-o l", opens "/loose/deep/l.txt"),
      ("C-o 2", opens "/loose2/l.txt"), ("C-o h", opens "/r/hook/one/two/three/four/f.txt"),
      ("C-o g", opens "/r/hook/one/two/three/four/g.txt"), ("C-o k", opens "/r/crate/src/main.rs"),
      ("C-o 3", opens "/w/crate/src/main.rs"), ("C-o 4", opens "/o/src/main.rs")]

/-- The on-modes of the buffer the view 0 of `driver` shows. -/
def shownOnModes (driver : TestDriver) : Option (Array Workspace.OnMode) := do
  return Workspace.onModesOf driver.loop.state (← showing driver).id

/-- The minor modes of the buffer the view 0 of `driver` shows. -/
def shownMinors (driver : TestDriver) : Option (Array String) :=
  (showing driver).map (·.buffer.minors)

/-- `driver` once `keys` are pressed and every job they start, and every job
those jobs' commands start, is finished, oldest first; with the names of the
jobs finished, in order. -/
def settledNames (driver : TestDriver) (keys : String) : TestDriver × Array String :=
  (List.range 8).foldl
    (fun (driver, names) _ =>
      match driver.pending[0]? with
      | some job => ((driver.finish job.id).1, names.push job.name)
      | none => (driver, names))
    ((fedTo driver (presses keys)).1, #[])

/-- What `mise tasks ls --json` prints in `/m` in the project checks: three
tasks with the real listing's shape, `build` and `test` in `/m` and `lint`
in `/m/sub`, each with fields of every JSON kind besides its name and
directory. -/
def miseListing : String :=
  "[\n  {\n    \"name\": \"build\",\n    \"aliases\": [],\n    \"description\": \"\",\n    \"source\": \"/m/mise.toml\",\n    \"depends\": [],\n    \"dir\": \"/m\",\n    \"hide\": false,\n    \"raw\": false,\n    \"sources\": [],\n    \"outputs\": [],\n    \"shell\": null,\n    \"quiet\": false,\n    \"silent\": false,\n    \"tools\": {},\n    \"run\": [\"lake build\"],\n    \"file\": null\n  },\n  {\"name\": \"test\", \"dir\": \"/m\", \"depends\": [\"build\"], \"hide\": false, \"timeout\": 1.5e2, \"env\": {\"A\": \"1\"}, \"run\": [\"lake test\"]},\n  {\"name\": \"lint\", \"dir\": \"/m/sub\", \"depends\": [], \"hide\": false, \"usage\": {\"spec\": {\"args\": [[1, -2.5], true]}}}\n]\n"

/-- The bindings of the listing checks: the hook checks', and `C-p 1`,
`C-p 2`, `C-p 3` and `C-p 4`, which open `/t/a.txt`, `/t/b.txt`,
`/t2/a.txt` and `/u/a.txt`. -/
def listingBindings : List (String × Invocation) :=
  hookBindings ++
    [("C-p 1", opens "/t/a.txt"), ("C-p 2", opens "/t/b.txt"), ("C-p 3", opens "/t2/a.txt"),
      ("C-p 4", opens "/u/a.txt")]

/-- How many times `driver` has started `command`. -/
def startedCount (driver : TestDriver) (command : Process.Command) : Nat :=
  (driver.jobs.processes.started.filter (· == command)).size

end ModelTest
