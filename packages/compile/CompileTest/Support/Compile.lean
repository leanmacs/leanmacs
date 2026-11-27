import Compile
import Compile.Compiled
import CompileApi
import CompileApi.Format
import CompileApi.Listing
import CompileApiTest.Listing
import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Config.Packages
import Editor.DisplayRules
import Editor.Ex.Line
import Editor.Extension
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Keymap
import Editor.Loop.Driver
import Editor.Mode
import Editor.Process
import Editor.Process.Model
import Editor.Program
import Editor.Scene
import Editor.Setup
import Editor.State
import Editor.Test.Driver
import Editor.Test.Ex
import Editor.Test.Files
import Editor.Test.Hosted
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Minibuffer
import Editor.Test.Models
import Editor.Test.Shell
import Editor.Test.Workspace
import Editor.Text
import Editor.Value
import Editor.Workspace
import FilesApi
import FilesApiTest.Fake
import MinibufferApi

/-!
# Model tests: support: Compile

The compile commands' world: their jobs, keys, bindings and driver, the error
formats they read, the compile hook's setup, and the driver of the compile
mode's checks of a listing, over the listing checks' world
(`packages/compile-api/CompileApiTest/Listing.lean`, the core's test kit). It names no feature but
the compile mode: files are opened by `files-api`'s fake
(`FilesApiTest.fake`), a file's workspace and its modes on markers are the
core kit's stand-ins' (`compileFound`, `hookMarkers`, `compileWorkspace`),
and the ex line is the kit's (`Editor.Test.exLinePackage`). Shared by several
test modules under `CompileTest/`; it holds no checks of its own.
-/

namespace CompileTest

open Editor
open Editor.Test

/-- The workspace a directory of the compile checks is in, standing in for
the workspace finder's answer over their repositories: those of the open
driver checks (`openFound`: `/r` on `main`, and `/w`, its linked worktree on
`feature`, both of the origin `openOrigin`), a second clone of that origin
at `/clone/r`, a repository `/up/repo` with no origin, and `/o` of the
origin `git@github.com:o/other.git`, each a main checkout on `main`
(`Workspace.Found.ofGit`, the core's, as the finder's git adapter answers);
none elsewhere (`/x`, `/loose`, `/loose2`). -/
def compileFound (directory : System.FilePath) : Option Workspace.Found :=
  (openFound directory).orElse fun _ =>
    ([("/clone/r", some openOrigin), ("/up/repo", none),
            ("/o", some "git@github.com:o/other.git")] :
          List (System.FilePath × Option String)).findSome?
      fun (root, origin) =>
      if Workspace.holds root directory then
        some
          (Workspace.Found.ofGit
            { toplevel := root, commonDir := root / ".git", branch := .named "main" } origin)
      else none

/-- The marker files there are in the hook checks: of `marker-mode` at `/r/a`,
above the workspace `/up/repo`, above `/loose/deep` and beside
`/loose2/l.txt`; of `b-mode` at `/r/hook` and `a-mode` at `/r/hook/one/two`;
and of `cargo-mode` in `/r/crate`, `/w/crate` and `/o`. -/
def hookMarkers : Array System.FilePath :=
  #["/r/a/marker.toml", "/up/marker.toml", "/loose/marker.toml", "/loose2/marker.toml",
    "/r/hook/b.toml", "/r/hook/one/two/a.toml", "/r/crate/Cargo.toml", "/w/crate/Cargo.toml",
    "/o/Cargo.toml"]

/-- The stand-ins for the workspace package of the compile checks, in the
order a host registers the workspace's hooks at `FilesApi.Opened`: a file's
workspace by `compileFound` (the core kit's `attachByPackage`), then its modes
on markers by the hook checks' markers (`markersByPackage`, the core's
marker rules over `hookMarkers`). -/
def compileWorkspace : Array Package :=
  #[attachByPackage compileFound, markersByPackage compileFound hookMarkers]

/-- The jobs of the compile checks: `files-api`'s fake's, the compile's run
job and its listing job. -/
def compileJobs (name : String) : Option (List Argument → Work) :=
  if name == Compile.runJob then some Compile.runWork
  else if name == Compile.listJob then some Compile.listWork else FilesApiTest.jobs name

/-- Steps that write each of `lines` with a line feed on standard output,
pausing 100 ms between writes, so each is delivered, and posted, alone. -/
def linesSteps (lines : List String) : Array Process.Step :=
  (lines.toArray.map fun line => Process.Step.write .out (line ++ "\n").toUTF8).foldl
    (fun steps write => if steps.isEmpty then #[write] else steps ++ #[.pause 100, write]) #[]

/-- The place of the workspace `/r`. -/
def placeR : Compile.Place :=
  .workspace (.local "/r")

/-- The bindings of the compile checks that answer a prompt and work on
windows and buffers, by the shell checks' keys: `C-e e` opens the ex line
(`ExLine.name`, the kit's ex line's command), `C-e y` accepts the
prompt, `C-e k` gives the window's buffer the reachable workspace `kube`,
`C-e u` undoes, `C-e s` splits the window, `C-e c` closes it and `C-e x`
shows a buffer `elsewhere` in it and removes the one it showed. -/
def windowBindings : List (String × Invocation) :=
  [("C-e e", invoke ExLine.name), ("C-e y", invoke Editor.Test.Minibuffer.acceptName),
    ("C-e k", invoke "kube"), ("C-e u", invoke "undo"), ("C-e s", invoke "split"),
    ("C-e c", invoke "close"), ("C-e x", invoke "drop")]

/-- The commands of `windowBindings`, written over the core's API. -/
def windowCommands : List (String × Dispatched) :=
  [("kube", fun call => do
      let location := Location.reachable "kube" "pod" "/app"
      discard <| Workspace.register location openOrigin
      Workspace.setBufferWorkspace call.target.window.buffer location
      return none),
    ("undo", fun call => do
      discard <| call.target.window.buffer.undo
      return none),
    ("split", fun call => do
      if let .ok made← call.target.window.id.split then
        discard <| made.focus
      return none),
    ("close", fun call => do
      discard <| call.target.window.id.close
      return none),
    ("drop", fun call => do
      let window := call.target.window
      if let .ok elsewhere← createBuffer "elsewhere" then
        discard <| window.id.show elsewhere
        discard <| window.buffer.remove
      return none)]

/-- The bindings of the compile checks: the open driver checks' (`openBindings`),
`windowBindings`, and `C-k c`
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
  openBindings ++ windowBindings ++
    [("C-k c", invoke Compile.compileName),
      ("C-k m", { command := Compile.compileName, arguments := [.str "make"] }),
      ("C-k r", invoke "recompile"), ("C-k k", invoke Compile.killName),
      ("C-k t", invoke "insert-x"), ("C-k 0", invoke "to-start"),
      ("C-k o", invoke "focus-compilation"), ("C-k s", invoke "squat-clone"),
      ("C-k z",
        { command := Compile.outputName
          arguments := placeR.arguments ++ [.nat 1, .str "stale"] }),
      ("C-k q", invoke MinibufferApi.cancelName), ("C-o q", opens "/clone/r/src/a.lean"),
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
  openCommandsWith FilesApiTest.openSaveCommands ++
    dispatchedOf
      (exLinePackage.registered.commands ++ Editor.Test.Minibuffer.package.registered.commands ++
        Compile.package.registered.commands) ++
    windowCommands ++
    [("insert-x", insertX), ("to-start", toStart), ("focus-compilation", focusCompilation),
      ("squat-clone", squat), ("to-point", toPoint), ("zero-base", zeroBase)]

/-- The ex bindings of the compile checks: the kit's ex line's
(`Editor.Test.exLinePackage`, standing in for the `ex` package, whose module
a package's tests may not import), then the `compile` package's, which binds
its own names, as a host handed both registers them. -/
def compileExBindings : Array Ex.Binding :=
  exLinePackage.registered.ex ++ Compile.package.registered.ex

/-- The keys of the compile checks over `bindings`, with the compile mode
and the ex names of the kit's ex line and the `compile` package registered,
and the hooks at `FilesApi.Opened` of the stand-ins `workspace`
(`compileWorkspace` by default) and of `files-api`'s fake: the active
keymaps of a registry holding the compile mode's modes, so the mode's roles
are on their keys in a compilation buffer as a host's registry puts them,
then the keymap of `bindings`. -/
def compileKeysOf (bindings : List (String × Invocation))
    (workspace : Array Package := compileWorkspace) : Loop.Keys TestScheme.scheme :=
  let keys := dispatchKeys bindings compileCommands
  let registry := ({} : Config.Registry).replaceModes .compiled Compile.package.registered.modes
  { keys with
    maps := fun state view =>
      registry.activeMaps TestScheme.scheme state view ++ keys.maps state view
    registered :=
      { keys.registered with
        entering := fun name => (Compile.package.registered.modes.find? (·.name == name)).map ([·])
        ex := fun name => compileExBindings.find? (·.name == name)
        exNames := compileExBindings.map (·.name)
        -- `files-api`'s fake runs its hook `FilesApi.Opened` once a buffer
        -- holds a file: the stand-ins for the workspace's attach and its
        -- modes on markers are registered there. A location is visited
        -- through the fake's `FilesApi.Files` value.
        extensions := (hostedRegistry (workspace.push FilesApiTest.fake)).extensionsAt } }

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
commands installed for config, over `compiled` registered by a package, as
the compile package registers its shipped modes. -/
def hookRegistry (setup : SetupM Unit := hookSetup) (compiled : Array Compile.Contribution := #[]) :
    Config.Registry :=
  let shipping : Package :=
    { name := "test-shipping"
      setup :=
        for contribution in compiled do
          compileContribution contribution }
  hostedRegistry #[shipping] setup

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

/-- The minor modes of the buffer the view 0 of `driver` shows. -/
def shownMinors (driver : TestDriver) : Option (Array String) :=
  (showing driver).map (·.buffer.minors)

/-- What `mise tasks ls --json` prints in `/m` in the project checks: three
tasks with the real listing's shape, `build` and `test` in `/m` and `lint`
in `/m/sub`, each with fields of every JSON kind besides its name and
directory. -/
def miseListing : String :=
  "[\n  {\n    \"name\": \"build\",\n    \"aliases\": [],\n    \"description\": \"\",\n    \"source\": \"/m/mise.toml\",\n    \"depends\": [],\n    \"dir\": \"/m\",\n    \"hide\": false,\n    \"raw\": false,\n    \"sources\": [],\n    \"outputs\": [],\n    \"shell\": null,\n    \"quiet\": false,\n    \"silent\": false,\n    \"tools\": {},\n    \"run\": [\"lake build\"],\n    \"file\": null\n  },\n  {\"name\": \"test\", \"dir\": \"/m\", \"depends\": [\"build\"], \"hide\": false, \"timeout\": 1.5e2, \"env\": {\"A\": \"1\"}, \"run\": [\"lake test\"]},\n  {\"name\": \"lint\", \"dir\": \"/m/sub\", \"depends\": [], \"hide\": false, \"usage\": {\"spec\": {\"args\": [[1, -2.5], true]}}}\n]\n"

/-- The bindings of the compile mode's checks of a listing: the hook
checks', and the keys that open the listing checks' files
(`listingFiles`). -/
def compileListingBindings : List (String × Invocation) :=
  hookBindings ++ listingFiles.map fun (key, path) => (key, opens path)

/-- The streaming children of the compile mode's checks of a listing. -/
def compileListingStreams : Array Process.StreamScript :=
  #[{ command := shellCommand "/t" "t-build", steps := linesSteps ["ok"] },
    { command := shellCommand "/t/sub" "t-sub", steps := linesSteps ["ok"] },
    { command := shellCommand "/u" "u-only", steps := linesSteps ["ok"] }]

/-- A package, standing in for the workspace's, that registers `opened` at
`FilesApi.Opened` under the workspace's name: the kit's stand-ins for a
listing file's workspace and on-modes (`listingOpened`, `kubeOpened`). -/
def openedPackage (opened : BufferId → System.FilePath → EditorM Unit) : Package :=
  { name := "test-workspace"
    setup := Extension.add ({ name := "workspace", opened } : FilesApi.Opened) }

/-- A driver of the compile mode's checks of a listing over `registry`, by
default `t-mode` registered in config (`listingRegistry`), in which a file's
workspace and on-modes are the kit's stand-ins' `opened` (`listingOpened` by
default): the files and the listings' runs of the listing checks
(`listingRuns`), with the compile checks' keys and jobs and the children
`compileListingStreams`; `none` if making the state was refused. -/
def compileListingDriver (registry : Config.Registry := listingRegistry)
    (opened : BufferId → System.FilePath → EditorM Unit := listingOpened) : Option TestDriver :=
  let keys := compileKeysOf compileListingBindings #[openedPackage opened]
  let keys := toldHook keys registry
  (Loop.Driver.over keys compileJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := listingRuns compileListingStreams }

end CompileTest
