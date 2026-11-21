import BuffersApiTest.Fake
import Editor.Ex.Compiled
import Editor.Jumps
import Editor.Jumps.Go
import Editor.Restore.Compiled
import Editor.TabCommands.Compiled
import Editor.Test.Editing
import Editor.Test.Hosted
import Editor.Test.Minibuffer
import Editor.Test.Workspace
import Editor.WindowCommands.Compiled
import FilesApiTest.Fake
import ModelTest.Support.Switching

/-!
# Model tests: support: Restore

The session restore checks' world and driver: `switching`, the scheme
written for the core's checks (`ModelTest/Support/Switching.lean`), with
the kit's editing keys and the keys of `keysWith`, over the editor's
models, the files of the checks under `/r` on the job model's disk,
the commands and jobs of `files-api`'s fake and `buffers-api`'s, with the
`restore` package's commands, mode and jobs, the ex commands, the window
commands and the tab commands, and the state directory `/state`. A file
opens and saves through `files-api`'s fake and is given the workspace `/r`
by the kit's stand-in for the workspace's attach (`attachPackage`), so the
support names no module of the files feature, the buffers', the
workspace's or the working sets', and the core's checks of the journal's
reconciler (`Editor/Restore.lean`, `Editor/Restore/Restart.lean`) and of
session restore's own run (`Editor/Restore/Run.lean`), which reaches the
files through `files-api` too, run on it.
Shared by the test modules of `Editor/Restore.lean`,
`Editor/Restore/Restart.lean` and `Editor/Restore/Run.lean`; it holds no
checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Restore
open Editor.Test

namespace RestoreTest

/-- The workspace of the checks. -/
def root : System.FilePath :=
  "/r"

/-- Six lines of `a.txt`. -/
def aText : String :=
  "alpha one\nbravo two\ncharlie three\ndelta four\necho five\nfoxtrot six\n"

/-- Four lines of `b.txt`. -/
def bText : String :=
  "one\ntwo\nthe needle here\nfour\n"

/-- Two lines of `c.txt`. -/
def cText : String :=
  "a needle\nsecond\n"

/-- The files of the checks on the job model's disk, under `/r`. -/
def disk (files : FileModel) : FileModel :=
  [("/r/a.txt", aText), ("/r/b.txt", bText), ("/r/c.txt", cText)].foldl
    (fun (files : FileModel) (path, text) => files.withFile path text.toUTF8)
    (files.withDirectory root)

/-- The workspace every file of the checks is given: the repository `/r`,
as git's answer for it, with its `origin`. -/
def found : Workspace.Found :=
  Workspace.Found.ofGit { toplevel := root, commonDir := root / ".git", branch := .detached }
    (some "git@github.com:o/r.git")

/-- The commands every driver of the checks has: `files-api`'s fake's (the
kit's opener, `FilesApiTest.fake`) and `buffers-api`'s fake's
(`BuffersApiTest.fake`). -/
def baseCommands : Array Config.Registration :=
  FilesApiTest.fake.registered.commands ++ BuffersApiTest.fake.registered.commands

/-- What the checks' extension points hold: the kit's stand-in for the
workspace's attach at `FilesApi.Opened` (`attachPackage found`), the fake's
`FilesApi.Files` value, and the buffers fake's, in that order, as a host
registers the workspace before the files' users. -/
def hooks : Array Package :=
  #[attachPackage found, FilesApiTest.fake, BuffersApiTest.fake]

/-- A driver of the session restore checks: a loop over `switching`. -/
abbrev RestoreDriver :=
  Loop.Driver switching

/-- The commands `jump-first` and `jump-last` of the checks: records a jump
in the call's window (`Jumps.record`), as a scheme's motion that is a jump
does, and puts the cursor at the start of the text, or, for `last`, at the
start of its last line that has text. -/
def jumped (last : Bool) (call : Call) : EditorM Unit := do
  let view := call.target.window.id
  Jumps.record view
  let text ← call.target.buffer.text.read
  let size := text.utf8ByteSize
  let offset :=
    if last then Editing.lineStart text (if text.endsWith "\n" then size - 1 else size) else 0
  Jumps.placeCursor view offset

/-- What a step of the checks is handed, under `switching`: a printable key
types, `C-b` begins a session the scheme reports, as a scheme's insert
state is, and `C-e` ends it; the kit's editing keys
(`Editor/Test/Editing.lean`), but `C-<Home>` and `C-<End>`, which run
`jump-first` and `jump-last` (`jumped`); `C-o` and `C-i`, which go back
and on one place in the window's jump list (`Jumps.move`); and `C-x`, which
runs the ex line's command. The commands are the kit's minibuffer's, the base ones and
`commands`, under their names, then the kit's editing commands and the
four written here; with `modes`, as a host's registry holds them, and the
extension points `hooks` register. -/
def keysWith (commands : Array Config.Registration) (modes : Array Mode) : Loop.Keys switching :=
  let ran (run : Call → EditorM Unit) : Dispatched := fun call => do
    run call
    return none
  let written : List (String × Dispatched) :=
    editingDispatched ++
      [("jump-first", ran (jumped false)), ("jump-last", ran (jumped true)),
        ("jump-back", ran fun call => discard <| Jumps.move call.target.window.id (-1)),
        ("jump-on", ran fun call => discard <| Jumps.move call.target.window.id 1)]
  let bindings : List (String × Invocation) :=
    editingBindings.filter (fun (text, _) => text != "C-<Home>" && text != "C-<End>") ++
      [("C-b", invoke "begin"), ("C-e", invoke "end"), ("C-<Home>", invoke "jump-first"),
        ("C-<End>", invoke "jump-last"), ("C-o", invoke "jump-back"), ("C-i", invoke "jump-on"),
        ("C-x", invoke Ex.name)]
  let registry := ({} : Config.Registry).replaceModes .compiled modes
  let own : Keymap switching.Binding :=
    Keymap.ofList (bindings.map fun (text, invocation) => (keys text, invocation))
  { maps := fun state view => registry.activeMaps switching state view ++ [own]
    command? := fun name =>
      match
        (Test.Minibuffer.package.registered.commands ++ baseCommands ++ commands).findRev?
          (·.name == name) with
      | some { action := .call run, .. } => some (ran run)
      | _ =>
        match written.find? (·.1 == name) with
        | some (_, command) => some command
        | none => if switchingTable.any (·.1 == name) then some fun _ => pure none else none
    registered :=
      { entering := fun name => (modes.find? (·.name == name)).map ([·])
        extensions := (hostedRegistry hooks).extensionsAt } }

/-- `more`, then the jobs every driver of the checks has, the files fake's:
a job of `more` comes before one of theirs of its name. A job is handed no
value at any extension point: the restore registers no job over one. -/
def jobsWith (more : Array Config.JobRegistration) (name : String) :
    Option (List Argument → Work) :=
  ((more ++ FilesApiTest.fake.registered.jobs).find? (·.name == name)).map (·.workWith fun _ => #[])

/-- A key of `keysWith` that changes nothing, for a check that only needs
the loop to take a step: `C-e`, which ends a session where none is open. -/
def idle : String :=
  "C-e"

/-- A driver of the checks: `keysWith` over an empty scratch buffer, with
`commands`, `modes` and `jobs` handed in, whose jobs meet the files of the
checks (`disk`); `none` if making the state was refused. -/
def driverWith (commands : Array Config.Registration := #[]) (modes : Array Mode := #[])
    (jobs : Array Config.JobRegistration := #[]) : Option RestoreDriver :=
  (Loop.Driver.over (keysWith commands modes) (fun _ => none) (barState "" 0)
        editorModel).toOption.map
    fun driver =>
    { driver with
      registered := jobsWith jobs, jobs := { files := disk {} } }

/-- `driver` once `command` is invoked with `arguments`. -/
def invoked (driver : RestoreDriver) (command : String) (arguments : List Argument := []) :
    RestoreDriver :=
  (driver.stepped (driver.loop.invoke driver.handed { command, arguments })).1

/-- `driver` once every post is delivered and every job finished, oldest
first, with those they start. -/
def drained (driver : RestoreDriver) : RestoreDriver :=
  (List.range 64).foldl
    (fun driver _ =>
      match driver.posting[0]? with
      | some job => (driver.posted job.id).1
      | none =>
        match driver.pending[0]? with
        | some job => (driver.finish job.id).1
        | none => driver)
    driver

/-- `driver` once the file `/r/<name>` is opened in the window and everything
that starts is settled. -/
def opened (driver : RestoreDriver) (name : String) : RestoreDriver :=
  drained (invoked driver FilesApi.openFileName [.str (root / name).toString])

/-- `driver` once the buffer called `name` is closed and everything that
starts is settled. -/
def closed (driver : RestoreDriver) (name : String) : RestoreDriver :=
  drained (invoked driver BuffersApi.closeName [.str name])

/-- `driver` with the file `/r/<name>` holding `text` on disk, as another
program would leave it. -/
def onDisk (driver : RestoreDriver) (name text : String) : RestoreDriver :=
  { driver with
    jobs := { driver.jobs with files := driver.jobs.files.withFile (root / name) text.toUTF8 } }

/-- The keys of each character of `text`, as a key string. -/
def typed (text : String) : String :=
  " ".intercalate
    (text.toList.map fun character => if character == ' ' then "SPC" else character.toString)

/-- The state directory of the checks. -/
def stateDirectory : System.FilePath :=
  "/state"

/-- A driver of the checks over `files`, its state directory `state`, each
step handed a log bound of `limit`, with `modes` registered beside the
restore package's, the config generation `generation` and `jobs` registered
after the restore package's; `none` if making the state was refused. -/
def restoreDriver (files : Option FileModel := none)
    (state : Option System.FilePath := some stateDirectory) (limit : Nat := Restore.bound)
    (modes : Array Mode := #[]) (generation : Nat := 0)
    (jobs : Array Config.JobRegistration := #[]) : Option RestoreDriver :=
  (driverWith
        (Restore.package.registered.commands ++ Ex.package.registered.commands ++
          WindowCommands.package.registered.commands ++
          TabCommands.package.registered.commands)
        (Restore.package.registered.modes ++ modes) (Restore.package.registered.jobs ++ jobs)).map
    fun driver =>
    { driver with
      keys :=
        { driver.keys with
          journalBound := limit
          registered := { driver.keys.registered with generation } }
      loop := { driver.loop with state := { driver.loop.state with stateDirectory := state } }
      jobs := { driver.jobs with files := files.getD driver.jobs.files } }

/-- `driver` once its restore has run, as a host starts it first: the job
`restore` with the state directory, and everything it starts settled. -/
def begun (driver : RestoreDriver) : RestoreDriver :=
  drained (driver.started #[{ name := restoreJob, arguments := [.str stateDirectory.toString] }])

/-- A restored driver of the checks: `restoreDriver` with its restore run. -/
def restoredDriver (files : Option FileModel := none) (limit : Nat := Restore.bound)
    (modes : Array Mode := #[]) (generation : Nat := 0)
    (jobs : Array Config.JobRegistration := #[]) : Option RestoreDriver :=
  (restoreDriver files (limit := limit) (modes := modes) (generation := generation) (jobs :=
        jobs)).map
    begun

/-- The bytes of the file at `path` in `driver`'s world. -/
def bytesAt (driver : RestoreDriver) (path : System.FilePath) : Option ByteArray :=
  (driver.jobs.files.file? path).map (·.bytes)

/-- The paths of the files under `/state/session/journals/`, sorted. -/
def journalFiles (driver : RestoreDriver) : Array String :=
  ((driver.jobs.files.files.map (·.path.toString)).filter
        (·.startsWith (journalsDirectory stateDirectory).toString)).qsort
    (· < ·)

/-- What the log of the journal of `buffer`'s generation `generation` of
the run `run` reads as. -/
def logOf (driver : RestoreDriver) (run buffer generation : Nat) : Option Journal.Decoded := do
  let bytes ← bytesAt driver (logPath stateDirectory run buffer generation)
  return Journal.decode (File.decodeBytes bytes)

/-- The text the journal of `buffer`'s generation `generation` of the run
`run` restores: its base with its log replayed. -/
def journalText (driver : RestoreDriver) (run buffer generation : Nat) : Option String := do
  let base ← bytesAt driver (basePath stateDirectory run buffer generation)
  let log ← logOf driver run buffer generation
  let program : TextM String := do
    let text ← createText (File.decodeBytes base)
    discard <| Journal.replay text log.records
    text.read
  (program.runModel {}).1.toOption

/-- The index of the run `run` in `driver`'s world, read. -/
def indexOf (driver : RestoreDriver) (run : Nat) : Option Document := do
  let bytes ← bytesAt driver (indexPath stateDirectory run)
  (Document.read (indexName run) (File.decodeBytes bytes)).document

/-- The text of the buffer called `name`. -/
def textNamed (driver : RestoreDriver) (name : String) : Option String := do
  let id ← driver.loop.state.findBuffer name
  let buffer ← driver.loop.state.buffer? id
  ((buffer.text.read).runModel driver.model.texts).1.toOption

/-- The buffer called `name`. -/
def bufferNamed (driver : RestoreDriver) (name : String) : Option Buffer := do
  driver.loop.state.buffer? (← driver.loop.state.findBuffer name)

/-- A fresh driver over the world `driver` left, as after an abort and a
start: a new state over the same files, restored, with `jobs` registered
as `restoreDriver` registers them. -/
def restarted (driver : RestoreDriver) (modes : Array Mode := #[]) (generation : Nat := 0)
    (change : FileModel → FileModel := id) (jobs : Array Config.JobRegistration := #[]) :
    Option RestoreDriver :=
  restoredDriver (some (change driver.jobs.files)) (modes := modes) (generation := generation)
    (jobs := jobs)

/-- How many jobs called `name` are started and not delivered. -/
def pendingNamed (driver : RestoreDriver) (name : String) : Nat :=
  (driver.pending.filter (·.name == name)).size

end RestoreTest

end ModelTest
