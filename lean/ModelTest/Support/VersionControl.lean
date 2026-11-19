import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Config.Owner
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.File
import Editor.File.Model
import Editor.Files
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Keymap
import Editor.Loop
import Editor.Loop.Driver
import Editor.Mode
import Editor.ModeLine
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.ProjectMode
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.VersionControl
import Editor.VersionControl.Blame
import Editor.VersionControl.Commit
import Editor.VersionControl.Compiled
import Editor.VersionControl.Hunk
import Editor.VersionControl.Log
import Editor.VersionControl.Model
import Editor.VersionControl.Review
import Editor.VersionControl.Show
import Editor.VersionControl.Stage
import Editor.VersionControl.Status
import Editor.Workspace
import Editor.Workspace.Attach
import ModelTest.Support.Driver
import ModelTest.Support.Files
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Shell
import ModelTest.Support.Workspace

/-!
# Model tests: support: VersionControl

The loop's driver of the version-control checks: the jobs, bindings,
commands and keys of the status buffer checks and of the hunk and message
buffer checks, the drivers over a model repository in `/r` they are built
with, and the git commands a driver has started there. Shared by several
test modules under `ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor

/-- The jobs of the status buffer checks: the workspace driver checks', and
the status buffer's read and apply jobs. -/
def statusJobs (name : String) : Option (List Argument → Work) :=
  if name == VersionControl.readJob then some VersionControl.readWork
  else
    if name == VersionControl.applyJob then some VersionControl.applyWork
    else if name == VersionControl.showJob then some VersionControl.showWork else workspaceJobs name

/-- The bindings of the status buffer checks: the workspace driver checks',
and `C-v s` (`vc-status`), `C-v t` (`vc-status-toggle`), `C-v v`
(`vc-status-visit`), `C-v r` (`vc-status-refresh`), `C-v a`
(`vc-status-stage`), `C-v u` (`vc-status-unstage`), `C-v k`, which gives
the window's buffer a workspace registered as reachable through `kube`,
and `C-v 0` to `C-v 5`, which put the window's cursor at the start of that
row. -/
def statusBindings : List (String × Invocation) :=
  workspaceBindings ++
    [("C-v s", invoke VersionControl.statusName), ("C-v t", invoke VersionControl.toggleName),
      ("C-v v", invoke VersionControl.visitName), ("C-v r", invoke VersionControl.refreshName),
      ("C-v a", invoke VersionControl.stageName), ("C-v u", invoke VersionControl.unstageName),
      ("C-v k", invoke "kube")] ++
    (List.range 6).map
      (fun row => (s!"C-v {row}", { command := "to-row", arguments := [.nat row] })) ++
    [("C-v w", { command := VersionControl.showName, arguments := [.str "v1 src/a.lean"] }),
      ("C-v h", invoke VersionControl.showName),
      ("C-v n", { command := VersionControl.showName, arguments := [.str "HEAD nope.txt"] }),
      ("C-v x", { command := VersionControl.showName, arguments := [.str "-x src/a.lean"] })]

/-- The commands of the status buffer checks (`statusBindings`). -/
def statusCommands : List (String × Dispatched) :=
  workspaceCommands ++ dispatchedOf VersionControl.package.registered.commands ++
    [("to-row", fun call => do
        if let .nat row :: _ := call.arguments then
          let offset ← call.target.buffer.text.offsetOf ⟨row, 0⟩
          discard <| call.target.window.id.select { ranges := #[⟨offset, offset⟩] }
        return none),
      ("kube", fun call => do
        let location := Location.reachable "kube" "pod" "/app"
        discard <| Workspace.register location workspaceOrigin
        Workspace.setBufferWorkspace call.target.window.buffer location
        return none)]

/-- The keys of the status buffer checks (`statusBindings`), with the status
buffer's mode registered, as a host's registry holds it: the mode's roles
on their keys in a status buffer, and its name known to the loop that sets
it. -/
def statusKeys : Loop.Keys TestScheme.scheme :=
  let keys := dispatchKeys statusBindings statusCommands
  let registry :=
    ({} : Config.Registry).replaceModes .compiled VersionControl.package.registered.modes
  { keys with
    maps := fun state view =>
      registry.activeMaps TestScheme.scheme state view ++ keys.maps state view
    registered :=
      { keys.registered with
        entering := fun name =>
          (VersionControl.package.registered.modes.find? (·.name == name)).map ([·]) } }

/-- A driver of the status buffer checks: the workspace driver's world, with
the status buffer's keys and jobs (or `keys` and `registered`), whose git in `/r` meets `repository`
(`Repository.jobModel`) and answers `writes`, and with each file of
`repository`'s working tree on disk under `/r`; `none` if making the state
was refused. -/
def statusDriverOf (repository : VersionControl.Model.Repository)
    (writes : Array VersionControl.Request := #[]) (missing : Array (String × String) := #[])
    (registered : String → Option (List Argument → Work) := statusJobs)
    (keys : Loop.Keys TestScheme.scheme := statusKeys) : Option TestDriver :=
  (workspaceDriver registered keys).map fun driver =>
    let scripts := (repository.jobModel "git" "/r" writes missing).processes.scripts
    { driver with
      jobs :=
        { driver.jobs with
          files :=
            repository.worktree.foldl
              (fun (files : FileModel) (path, content) =>
                files.withFile (("/r" : System.FilePath) / path) content.toUTF8)
              driver.jobs.files
          processes :=
            { driver.jobs.processes with scripts := driver.jobs.processes.scripts ++ scripts } } }

/-- The name of the status buffer of `/r`. -/
def statusBufferName : String :=
  "*vc-status: r@main*"

/-- The git commands `driver`'s jobs have started in the root `/r`, oldest
first: the status buffer's, and none of the finder's, which runs in the
file's directory. -/
def gitStarted (driver : TestDriver) : Array Process.Command :=
  driver.jobs.processes.started.filter fun command =>
    command.program == "git" && command.directory == ("/r" : System.FilePath)

/-- The jobs of the hunk and message buffer checks: every job of the
version-control registrations (`VersionControl.package.registered.jobs`), and the workspace
driver checks', the file commands' among them. -/
def stagingJobs (name : String) : Option (List Argument → Work) :=
  ((VersionControl.package.registered.jobs.find? (·.name == name)).map (·.work)) <|>
    workspaceJobs name

/-- The bindings of the hunk and message buffer checks: the workspace driver
checks', and `C-v s` (`vc-status`), `C-v g` (`vc-stage-hunk`), `C-v G`
(`vc-unstage-hunk`), `C-v c` (`vc-commit`), `C-v y` (`vc-commit-accept`),
`C-v q` (`vc-commit-abort`), `C-v z`, which puts `0\n` at the start of the
window's text, `C-v m` and `C-v n`, which make the window's text the
messages `stagingMessage` and `edited\n`, `C-v d` and `C-v D`, which hand
the loop what a check of the window's file finds when another program has
changed it or removed it (`Files.checked`), and `C-r 0` to `C-r 9`, which
put the window's cursor at the start of that row, and `C-r t` of row 10. -/
def stagingBindings : List (String × Invocation) :=
  workspaceBindings ++
    [("C-v s", invoke VersionControl.statusName), ("C-v g", invoke VersionControl.stageHunkName),
      ("C-v G", invoke VersionControl.unstageHunkName), ("C-v c", invoke VersionControl.commitName),
      ("C-v y", invoke VersionControl.acceptName), ("C-v q", invoke VersionControl.abortName),
      ("C-v z", invoke "top-line"),
      ("C-v m",
        { command := "set-text",
          arguments := [.str "Subject line\n\n# kept, as git's own cleanup keeps it\n"] }),
      ("C-v n", { command := "set-text", arguments := [.str "edited\n"] }),
      ("C-v d", invoke "disk-changed"),
      ("C-v D", { command := "disk-changed", arguments := [.bool true] })] ++
    (List.range 10).map
      (fun row => (s!"C-r {row}", { command := "to-row", arguments := [.nat row] })) ++
    [("C-r t", { command := "to-row", arguments := [.nat 10] })]

/-- The commands of the hunk and message buffer checks (`stagingBindings`):
the status buffer checks', and `top-line`, `set-text` and
`disk-changed`. -/
def stagingCommands : List (String × Dispatched) :=
  statusCommands ++
    [("top-line", fun call => do
        call.target.buffer.text.insert 0 "0\n"
        return none),
      ("set-text", fun call => do
        if let .str text :: _ := call.arguments then
          let target := call.target.buffer.text
          target.replaceRange 0 (← target.byteLength) text
        return none),
      ("disk-changed", fun call => do
        let buffer := call.target.window.buffer
        if let some file := ((← editorState).buffer? buffer).bind (·.file) then
          Files.checked
              #[({ buffer, path := file.path, stamp := file.stamp },
                  if call.arguments == [.bool true] then .error .notFound
                  else .ok { file.stamp with size := file.stamp.size + 1 })]
        return none)]

/-- The keys of the hunk and message buffer checks (`stagingBindings`), with
the version-control modes known to the loop that sets them. -/
def stagingKeys : Loop.Keys TestScheme.scheme :=
  let keys := dispatchKeys stagingBindings stagingCommands
  { keys with
    registered :=
      { keys.registered with
        entering := fun name =>
          (VersionControl.package.registered.modes.find? (·.name == name)).map ([·]) } }

/-- The writes the hunk and message buffer checks expect git to be asked for
in `/r`: an apply, its reverse and a commit. -/
def stagingWrites : Array VersionControl.Request :=
  let none := VersionControl.LineHunk.make 0 0 "" "" "" ""
  #[.stageHunk "" none, .unstageHunk "" none, .commit ""]

/-- A driver of the hunk and message buffer checks over `repository`
(`statusDriverOf`), whose git says each revision and path of `missing` is
not there, by default that the index has no `src/b.lean`, and whose files
may be saved in `/r/src`. -/
def stagingDriverOf (repository : VersionControl.Model.Repository)
    (missing : Array (String × String) := #[("", "src/b.lean")]) : Option TestDriver :=
  (statusDriverOf repository stagingWrites missing stagingJobs stagingKeys).map fun driver =>
    { driver with
      jobs :=
        { driver.jobs with
          files :=
            { driver.jobs.files with
              directories := driver.jobs.files.directories.push "/r/src" } } }

/-- The bindings of the review buffer checks: the hunk checks', and, under
`C-t`: `r`, `m`, `n` and `d`, `vc-review` against `base`, against `main`,
with no name, and against `-x`; `k`, `v` and `f`, `vc-review-keep`,
`vc-review-revert` and `vc-review-refresh`; `u`, which undoes one step of
the window's buffer; `i`, which inserts `X` at the window's cursors; `x`,
which gives the window's buffer a review record
with no hunk; `z`, which does nothing, so its step only publishes; `e`,
which puts `0\n` at the start of the buffer of `/r/lean/Pkg/B.lean`; and `0`
to `9`, which put the cursor at the start of that excerpt of the window's
text. Under `C-y`: `s`, `vc-review-since`; `c`, `z`, `h` and `0`, which
write the workspace at `/r` a review store of one round against `base`
whose head is `C`, `Z`, `head` or empty; `m` and `b`, which open the
review of the commit `C` or `B` (`startCommitReview`); and `e`, which puts
`0\n` at the start of the buffer of `/r/y.txt`. Under `C-l`: `l`,
`f` and `d`, `vc-log` of `HEAD`, of `feature` and of `-x`; `v` and `r`,
`vc-log-visit` and `vc-log-refresh`; `a` and `s`, which open `/r/a.txt`
and `/r/s.txt`; `e`, `k` and `x`, `vc-blame` at `HEAD`, at `B` and at `-x`;
and `o`, `vc-blame-visit`. -/
def reviewBindings : List (String × Invocation) :=
  stagingBindings ++
    [("C-t r", { command := VersionControl.reviewName, arguments := [.str "base"] }),
      ("C-t m", { command := VersionControl.reviewName, arguments := [.str "main"] }),
      ("C-t n", invoke VersionControl.reviewName),
      ("C-t d", { command := VersionControl.reviewName, arguments := [.str "-x"] }),
      ("C-t k", invoke VersionControl.reviewKeepName),
      ("C-t v", invoke VersionControl.reviewRevertName),
      ("C-t f", invoke VersionControl.reviewRefreshName), ("C-t u", invoke "undo-here"),
      ("C-t i", invoke "insert-x"), ("C-t x", invoke "no-hunks"), ("C-t z", invoke "noop"),
      ("C-t e", { command := "edit-file", arguments := [.str "/r/lean/Pkg/B.lean"] })] ++
    (List.range 10).map
      (fun index => (s!"C-t {index}", { command := "to-excerpt", arguments := [.nat index] })) ++
    [("C-y s", invoke VersionControl.reviewSinceName),
      ("C-y c", { command := "seed-round", arguments := [.str "C"] }),
      ("C-y z", { command := "seed-round", arguments := [.str "Z"] }),
      ("C-y h", { command := "seed-round", arguments := [.str "head"] }),
      ("C-y 0", { command := "seed-round", arguments := [.str ""] }),
      ("C-y m", { command := "review-commit", arguments := [.str "C"] }),
      ("C-y b", { command := "review-commit", arguments := [.str "B"] }),
      ("C-y e", { command := "edit-file", arguments := [.str "/r/y.txt"] }),
      ("C-l l", invoke VersionControl.logName),
      ("C-l f", { command := VersionControl.logName, arguments := [.str "feature"] }),
      ("C-l d", { command := VersionControl.logName, arguments := [.str "-x"] }),
      ("C-l v", invoke VersionControl.logVisitName),
      ("C-l r", invoke VersionControl.logRefreshName), ("C-l a", opens "/r/a.txt"),
      ("C-l s", opens "/r/s.txt"), ("C-l e", invoke VersionControl.blameName),
      ("C-l k", { command := VersionControl.blameName, arguments := [.str "B"] }),
      ("C-l x", { command := VersionControl.blameName, arguments := [.str "-x"] }),
      ("C-l o", invoke VersionControl.blameVisitName)]

/-- The mode line of the review buffer checks: the default order resolved over
the shipped segments and version control's, as a host's registry holds them
(`Headless.keys`), so `review` is drawn. -/
def reviewModeLine : ModeLine :=
  (ModeLine.resolve ModeLine.Order.standard fun name =>
      (ModeLine.shipped ++ VersionControl.package.registered.segments).find? (·.name == name)).1

/-- The keys of the review buffer checks (`reviewBindings`), with the
version-control modes known to the loop that sets them, and the mode line
`reviewModeLine`. -/
def reviewKeys : Loop.Keys TestScheme.scheme :=
  let keys :=
    dispatchKeys reviewBindings
      (stagingCommands ++
        [("undo-here", fun call => do
            discard <| call.target.window.buffer.undo
            return none),
          ("insert-x", fun call => do
            call.target.insertAtSelections "X"
            return none),
          ("no-hunks", fun call => do
            discard <|
                call.target.window.buffer.setValue VersionControl.ReviewRecord.localName
                  ({ root := "/r", against := "base", base := "B" } :
                      VersionControl.ReviewRecord).encode
            return none),
          ("noop", fun _ => pure none),
          ("edit-file", fun call => do
            if let .str path :: _ := call.arguments then
              if let some id := (← editorState).findFile path then
                discard <| id.insertAt 0 "0\n"
            return none),
          ("to-excerpt", fun call => do
            if let .nat index :: _ := call.arguments then
              if let some excerpt := (← call.target.buffer.text.excerpts)[index]? then
                discard <|
                    call.target.window.id.select { ranges := #[⟨excerpt.start, excerpt.start⟩] }
            return none),
          ("seed-round", fun call => do
            if let .str head :: _ := call.arguments then
              discard <|
                  Workspace.set VersionControl.reviewStore (.local "/r")
                    { rounds := #[{ against := "base", base := "B", head, hunks := #[] }] }
            return none),
          ("review-commit", fun call => do
            if let .str id :: _ := call.arguments then
              if let some read← VersionControl.readOrder "review-commit" call then
                VersionControl.startCommitReview read.root read.git read.label read.view id
            return none)])
  { keys with
    registered :=
      { keys.registered with
        entering := fun name =>
          (VersionControl.package.registered.modes.find? (·.name == name)).map ([·]) }
    modeLine := reviewModeLine }

/-- The jobs of the review buffer checks: the hunk checks', with the review's,
the log's and the blame's reads over the version-control model of
`repository` (`Model.readHandler`). -/
def reviewJobs (repository : VersionControl.Model.Repository) (name : String) :
    Option (List Argument → Work) :=
  let model : String → System.FilePath → VersionControl.Handler := fun _ _ =>
    VersionControl.Model.readHandler repository
  if name == VersionControl.reviewReadJob then some (VersionControl.reviewReadWork model)
  else
    if name == VersionControl.logReadJob then some (VersionControl.logReadWork model)
    else
      if name == VersionControl.blameReadJob then some (VersionControl.blameReadWork model)
      else stagingJobs name

/-- A driver of the review buffer checks over `repository`
(`statusDriverOf`), its frame resized so that its one window is `rows` rows
of text tall, with the working tree's files in the file model at `/r`, and
the jobs `registered`, `reviewJobs repository` by default. -/
def reviewDriverOf (repository : VersionControl.Model.Repository) (rows : Nat := 6)
    (registered : String → Option (List Argument → Work) := reviewJobs repository) :
    Option TestDriver :=
  (statusDriverOf repository stagingWrites #[] registered reviewKeys).map fun driver =>
    let cells := driver.model.display.cells
    let height := (rows + 2) * cells.lineHeight
    (driver.feed
        { event := .resize { width := 40 * cells.advance, height, scale := 1.0 }
          stamp := 0 }).1

end ModelTest
