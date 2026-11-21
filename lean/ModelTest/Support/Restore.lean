import BuffersApiTest.Fake
import Editor.Ex.Compiled
import Editor.Restore.Compiled
import Editor.TabCommands.Compiled
import Editor.Test.Hosted
import Editor.Test.Workspace
import Editor.WindowCommands.Compiled
import FilesApiTest.Fake
import ModelTest.Support.Evil
import VcApiTest.Fake

/-!
# Model tests: support: Restore

The session restore checks' world and driver: evil's keys over the
editor's models, the files of the checks under `/r` on the job model's disk,
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

/-- Evil's keys with `commands` after the base ones, and `modes`, as a host's
registry holds them, and the extension points `hooks` register. -/
def keysWith (commands : Array Config.Registration) (modes : Array Mode) :
    Loop.Keys Vim.Default.scheme :=
  let handed := evilHanded (baseCommands ++ commands)
  let registry := ({} : Config.Registry).replaceModes .compiled modes
  { handed with
    maps := fun state view =>
      registry.activeMaps Vim.Default.scheme state view ++ handed.maps state view
    registered :=
      { handed.registered with
        entering := fun name => (modes.find? (·.name == name)).map ([·])
        extensions := (hostedRegistry hooks).extensionsAt } }

/-- `more`, then the jobs every driver of the checks has, the files fake's:
a job of `more` comes before one of theirs of its name. -/
def jobsWith (more : Array Config.JobRegistration) (name : String) :
    Option (List Argument → Work) :=
  ((more ++ FilesApiTest.fake.registered.jobs).find? (·.name == name)).map
    (·.workWith (VcApiTest.backendValues #[]))

/-- A driver of the checks: evil's keys over an empty scratch buffer, with
`commands`, `modes` and `jobs` handed in, whose jobs meet the files of the
checks (`disk`); `none` if making the state was refused. -/
def driverWith (commands : Array Config.Registration := #[]) (modes : Array Mode := #[])
    (jobs : Array Config.JobRegistration := #[]) : Option EvilDriver :=
  (evilDriver "|" (keysWith commands modes)).map fun driver =>
    { driver with
      registered := jobsWith jobs, jobs := { files := disk {} } }

/-- `driver` once `command` is invoked with `arguments`. -/
def invoked (driver : EvilDriver) (command : String) (arguments : List Argument := []) :
    EvilDriver :=
  (driver.stepped (driver.loop.invoke driver.handed { command, arguments })).1

/-- `driver` once every post is delivered and every job finished, oldest
first, with those they start. -/
def drained (driver : EvilDriver) : EvilDriver :=
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
def opened (driver : EvilDriver) (name : String) : EvilDriver :=
  drained (invoked driver FilesApi.openFileName [.str (root / name).toString])

/-- `driver` once the buffer called `name` is closed and everything that
starts is settled. -/
def closed (driver : EvilDriver) (name : String) : EvilDriver :=
  drained (invoked driver BuffersApi.closeName [.str name])

/-- `driver` with the file `/r/<name>` holding `text` on disk, as another
program would leave it. -/
def onDisk (driver : EvilDriver) (name text : String) : EvilDriver :=
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
    (jobs : Array Config.JobRegistration := #[]) : Option EvilDriver :=
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
def begun (driver : EvilDriver) : EvilDriver :=
  drained (driver.started #[{ name := restoreJob, arguments := [.str stateDirectory.toString] }])

/-- A restored driver of the checks: `restoreDriver` with its restore run. -/
def restoredDriver (files : Option FileModel := none) (limit : Nat := Restore.bound)
    (modes : Array Mode := #[]) (generation : Nat := 0)
    (jobs : Array Config.JobRegistration := #[]) : Option EvilDriver :=
  (restoreDriver files (limit := limit) (modes := modes) (generation := generation) (jobs :=
        jobs)).map
    begun

/-- The bytes of the file at `path` in `driver`'s world. -/
def bytesAt (driver : EvilDriver) (path : System.FilePath) : Option ByteArray :=
  (driver.jobs.files.file? path).map (·.bytes)

/-- The paths of the files under `/state/session/journals/`, sorted. -/
def journalFiles (driver : EvilDriver) : Array String :=
  ((driver.jobs.files.files.map (·.path.toString)).filter
        (·.startsWith (journalsDirectory stateDirectory).toString)).qsort
    (· < ·)

/-- What the log of the journal of `buffer`'s generation `generation` of
the run `run` reads as. -/
def logOf (driver : EvilDriver) (run buffer generation : Nat) : Option Journal.Decoded := do
  let bytes ← bytesAt driver (logPath stateDirectory run buffer generation)
  return Journal.decode (File.decodeBytes bytes)

/-- The text the journal of `buffer`'s generation `generation` of the run
`run` restores: its base with its log replayed. -/
def journalText (driver : EvilDriver) (run buffer generation : Nat) : Option String := do
  let base ← bytesAt driver (basePath stateDirectory run buffer generation)
  let log ← logOf driver run buffer generation
  let program : TextM String := do
    let text ← createText (File.decodeBytes base)
    discard <| Journal.replay text log.records
    text.read
  (program.runModel {}).1.toOption

/-- The index of the run `run` in `driver`'s world, read. -/
def indexOf (driver : EvilDriver) (run : Nat) : Option Document := do
  let bytes ← bytesAt driver (indexPath stateDirectory run)
  (Document.read (indexName run) (File.decodeBytes bytes)).document

/-- The text of the buffer called `name`. -/
def textNamed (driver : EvilDriver) (name : String) : Option String := do
  let id ← driver.loop.state.findBuffer name
  let buffer ← driver.loop.state.buffer? id
  ((buffer.text.read).runModel driver.model.texts).1.toOption

/-- The buffer called `name`. -/
def bufferNamed (driver : EvilDriver) (name : String) : Option Buffer := do
  driver.loop.state.buffer? (← driver.loop.state.findBuffer name)

/-- A fresh driver over the world `driver` left, as after an abort and a
start: a new state over the same files, restored, with `jobs` registered
as `restoreDriver` registers them. -/
def restarted (driver : EvilDriver) (modes : Array Mode := #[]) (generation : Nat := 0)
    (change : FileModel → FileModel := id) (jobs : Array Config.JobRegistration := #[]) :
    Option EvilDriver :=
  restoredDriver (some (change driver.jobs.files)) (modes := modes) (generation := generation)
    (jobs := jobs)

/-- How many jobs called `name` are started and not delivered. -/
def pendingNamed (driver : EvilDriver) (name : String) : Nat :=
  (driver.pending.filter (·.name == name)).size

end RestoreTest

end ModelTest
