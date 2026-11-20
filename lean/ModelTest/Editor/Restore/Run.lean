import ModelTest.Check
import ModelTest.Editor.Restore
import ModelTest.Support.Restore

/-!
# Model tests: `Editor/Restore/Run.lean`

The model tests of `Editor/Restore/Run.lean`: `restoreChecks`, on the loop's
driver over the editor's models and the job model, from the journals and
indexes a first loop wrote, or that a check wrote by hand. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Restore
open WorkingSetTest
open RestoreTest
open JournalReconcileTest

namespace RestoreRunTest

/-- A mode only config registers, in the checks. -/
def configMode : Mode :=
  { name := "config-mode" }

/-- A command that sets the major mode of its window's buffer to the mode its
first argument names, and adds the minor mode its second names. -/
def modesCommandForTest : Config.Registration :=
  { name := "test-modes"
    action :=
      .call fun call => do
        let .str major :: .str minor :: _ := call.arguments | return
        discard <| call.target.window.id.setMajorMode major
        discard <| call.target.window.buffer.addMinorMode minor }

/-- `driver` with the checks' commands: the reconcile checks' and
`test-modes`. -/
def withCommands (driver : EvilDriver) : EvilDriver :=
  { driver with
    keys :=
      { driver.keys with
        command? := fun name =>
          match
            [noteCommand, ownedCommand, placeCommand, modesCommandForTest].find?
              (·.name == name) with
          | some { action := .call run, .. } =>
            some fun call => do
              run call;
              return none
          | _ => driver.keys.command? name } }

/-- The first loop: restored over `files`, with `modes`, and the checks'
commands. -/
def first (files : Option FileModel := none) (modes : Array Mode := #[]) : Option EvilDriver :=
  (restoredDriver files (modes := modes)).map withCommands

/-- A second loop over the world `driver` left, `change` made to its files
first, restored, with the checks' commands. -/
def second (driver : EvilDriver) (change : FileModel → FileModel := id) (modes : Array Mode := #[])
    (generation : Nat := 0) : Option EvilDriver :=
  (restarted driver modes generation change).map withCommands

/-- `files` with the journal `<run>-<buffer>-<generation>` written by hand:
its base holding `base`, and its log `header`'s line, if any, `records`'
lines and `extra`. -/
def withJournal (files : FileModel) (run buffer generation : Nat) (header : Option Journal.Header)
    (base : String) (records : Array (Array Journal.Edit)) (extra : String := "") : FileModel :=
  let log :=
    records.foldl (fun bytes edits => bytes ++ (Journal.Record.edits edits).bytes)
        ((header.map fun header => (Journal.Record.header header).bytes).getD ByteArray.empty) ++
      File.encodeText extra
  let files := (files.makeDirectory (journalsDirectory stateDirectory)).2
  (files.withFile (basePath stateDirectory run buffer generation) (File.encodeText base)).withFile
    (logPath stateDirectory run buffer generation) log

/-- `files` with the index `name` holding `text`. -/
def withIndex (files : FileModel) (name text : String) : FileModel :=
  let files := (files.makeDirectory (journalsDirectory stateDirectory)).2
  files.withFile (sessionDirectory stateDirectory / name) text.toUTF8

/-- The checks' world, with `change` made to it. -/
def world (change : FileModel → FileModel := id) : Option FileModel :=
  (restoreDriver).map fun driver => change driver.jobs.files

/-- The journal files of the run `run`'s buffer `index`, generation
`generation`. -/
def filesOf' (run index generation : Nat) : Array String :=
  #[(basePath stateDirectory run index generation).toString,
    (logPath stateDirectory run index generation).toString]

/-- The text of the report's buffer. -/
def reportOf (driver : EvilDriver) : String :=
  (textNamed driver reportName).getD ""

/-- The text the focused window shows, with `|` at its cursor. -/
def focusedShown (driver : EvilDriver) : String :=
  evilShown driver driver.loop.state.frame.focused

end RestoreRunTest

open RestoreRunTest in
/-- The checks of restoring a session (`Editor/Restore/Run.lean`). -/
def restoreChecks : List Check :=
  [{  name :=
        "a cursor after a multi-byte character comes back where it was: its column is recorded in bytes and put back in bytes"
      run :=
        pure <|
          match
            first
              (some ((world fun files => files.withFile "/r/e.txt" "é xy\n".toUTF8).getD {})) with
          | none => false
          | some begun =>
            let moved := drained (evilFed (opened begun "e.txt") "l l")
            match second moved with
            | none => false
            | some again => focusedShown moved == "é |xy\n" && focusedShown again == "é |xy\n" },
    { name :=
        "after an abort, the buffers come back: a file's unsaved text, modified, at its file with its line ending and modes, the scratch buffer's text, and the focused buffer shown with its cursor"
      run :=
        pure <|
          match
            first
              (some
                ((world fun files => files.withFile "/r/c.txt" "one\r\ntwo\r\n".toUTF8).getD {}))
              #[configMode] with
          | none => false
          | some begun =>
            let scratched := evilFed begun (typing "kept")
            let crlf := evilFed (opened scratched "c.txt") "x"
            let moded := ran crlf "test-modes" [.str configMode.name, .str "spell"]
            let edited := drained (evilFed (opened moded "a.txt") "j l x")
            match second edited (modes := #[configMode]) with
            | none => false
            | some again =>
              let a := bufferNamed again "a.txt"
              let c := bufferNamed again "c.txt"
              textNamed again "a.txt" == textNamed edited "a.txt" &&
                textNamed again "c.txt" == some "ne\r\ntwo\r\n" &&
                textNamed again EditorState.scratchName == some "kept" &&
                (a.map (·.isModified)) == some true &&
                (c.map (·.lineEnding)) == some .crlf &&
                (a.bind (·.file.map (·.path))) == some (root / "a.txt") &&
                (c.map fun buffer => (buffer.major, buffer.minors)) ==
                  some (some configMode.name, #["spell"]) &&
                focusedShown again == focusedShown edited &&
                again.loop.state.echo == "restore: 3 buffers, 3 with unsaved text" },
    { name :=
        "a file changed on disk since is restored with its unsaved text and marked, which the restore's line says; the loop's check of it marks it told, its next edit lands, and its save is refused as changed, the file left as it is"
      run :=
        pure <|
          match first with
          | none => false
          | some begun =>
            let edited := drained (opened (evilFed (opened begun "a.txt") "x") "b.txt")
            match
              second edited (fun files => files.withFile (root / "a.txt") "rewritten\n".toUTF8) with
            | none => false
            | some again =>
              let marked := (bufferNamed again "a.txt").bind (·.file.bind (·.changed))
              let shown := opened again "a.txt"
              let typedIn := evilFed shown "x"
              let saved := ran typedIn Files.saveName
              (marked.bind (·.found)) ==
                  ((again.jobs.files.file? (root / "a.txt")).map (·.stamp)) &&
                ((bufferNamed shown "a.txt").bind (·.file.bind (·.changed.map (·.told)))) ==
                  some true &&
                textNamed typedIn "a.txt" != textNamed edited "a.txt" &&
                bytesAt saved (root / "a.txt") == some "rewritten\n".toUTF8 &&
                (saved.loop.state.echo.splitOn
                      "the file on disk is not the one that was expected").length ==
                  2 &&
                (again.loop.state.echo.splitOn "1 changed on disk").length == 2 },
    { name :=
        "an unmodified file of the index is reopened, and one gone from disk is said and not restored"
      run :=
        pure <|
          match first with
          | none => false
          | some begun =>
            let both := drained (evilFed (opened (opened begun "b.txt") "a.txt") "x")
            match second both,
              second both
                (fun files =>
                  { files with files := files.files.filter (·.path != root / "b.txt") }) with
            | some kept, some gone =>
              (bufferNamed kept "b.txt").map (·.isModified) == some false &&
                textNamed kept "b.txt" == some bText &&
                (bufferNamed gone "b.txt").isNone &&
                ((reportOf gone).splitOn "/r/b.txt: gone from disk: it is not restored").length ==
                  2 &&
                (gone.loop.state.echo.splitOn s!"see {reportName}").length == 2
            | _, _ => false },
    { name :=
        "journals of a run with no index are restored, a journal with no header as a buffer with no file, and two buffers of one name each get one"
      run :=
        pure <|
          let files :=
            world fun files =>
              withJournal
                (withJournal
                  (withJournal files 3 1 1 (some { name := "note" }) "abc"
                    #[#[{ start := 3, stop := 3, inserted := "d" }]])
                  4 2 1 (some { name := "note" }) "xyz" #[])
                5 7 1 none "base" #[#[{ start := 0, stop := 1, inserted := "B" }]]
          match files.bind fun files => (restoredDriver (some files)) with
          | none => false
          | some again =>
            let names := again.loop.state.buffers.filterMap (·.map (·.name))
            let notes := names.filter (·.startsWith "note")
            notes.size == 2 &&
              (notes.filterMap (textNamed again ·)).qsort (· < ·) == #["abcd", "xyz"] &&
              textNamed again (orphanName 5 7) == some "Base" &&
              (bufferNamed again (orphanName 5 7)).bind (·.file) == none },
    { name :=
        "after a restore, the new bases are asked for before the journals taken in are removed"
      run :=
        pure <|
          match first with
          | none => false
          | some begun =>
            let edited := drained (evilFed begun (typing "abc"))
            match restoreDriver (some edited.jobs.files) with
            | none => false
            | some fresh =>
              let started :=
                fresh.started #[{ name := restoreJob, arguments := [.str stateDirectory.toString] }]
              let read :=
                match started.pending[0]? with
                | some job => (started.finish job.id).1
                | none => started
              match read.pending.find? (·.name == filesJob) with
              | none => false
              | some job =>
                match read.finish job.id with
                | (finished, some stepped) =>
                  let orders := stepped.journal
                  let newBase :=
                    orders.findIdx? fun order =>
                      match order.request with
                      | .save _ path _ => path == basePath stateDirectory 2 0 1
                      | _ => false
                  let staleRemove :=
                    orders.findIdx? fun order =>
                      order.request == .remove (basePath stateDirectory 1 0 1)
                  (match newBase, staleRemove with
                    | some base, some remove => base < remove
                    | _, _ => false) &&
                    journalFiles finished == filesOf' 2 0 1
                | _ => false },
    { name :=
        "the other windows' places are kept: after a two-window index is restored, the next index this run writes carries both places"
      run :=
        pure <|
          match first with
          | none => false
          | some begun =>
            let lines := evilFed begun "i o n e RET t w o RET t h r e e <Escape>"
            let split := ran lines WindowCommands.splitName
            let views := split.loop.state.frame.windows
            match views[0]?, views[1]? with
            | some one, some other =>
              let placed :=
                drained
                  (ran
                    (ran split "test-place"
                      [.nat one.index, .nat 0, .nat 1, .nat 1, .nat 2, .nat 0])
                    "test-place" [.nat other.index, .nat 2, .nat 0, .nat 2, .nat 3, .nat 1])
              let before :=
                (indexOf placed 1).bind (·.buffers.find? (·.name == EditorState.scratchName))
              match second placed with
              | none => false
              | some again =>
                let after :=
                  (indexOf again 2).bind (·.buffers.find? (·.name == EditorState.scratchName))
                let spots (buffer : Option Document.Buffer) : Array (Spot × Spot) :=
                  ((buffer.map (·.views.map fun place => (place.anchor, place.head))).getD
                        #[]).qsort
                    fun a b => a.1.row < b.1.row
                again.loop.state.restore.places.size == 1 && spots before == spots after &&
                  (spots after).size == 2
            | _, _ => false },
    { name :=
        "the version rule end to end: an index of a newer format with unknown keys and a journal with a record of an unknown kind restore what is known, report the rest, and are left byte for byte"
      run :=
        pure <|
          let newer :=
            "{\"format\":99,\"run\":5,\"layouts\":[],\"focused\":0,\"buffers\":[{\"key\":1,\"name\":\"a.txt\",\"file\":{\"path\":\"/r/a.txt\",\"stamp\":{\"seconds\":1,\"nanoseconds\":0,\"size\":1}},\"lineEnding\":\"lf\",\"folds\":[],\"views\":[]}]}"
          let unknown := "{\"kind\":\"marks\",\"marks\":[]}\n"
          let files :=
            world fun files =>
              withIndex
                (withJournal files 5 2 1 (some { name := "note" }) "ab"
                  #[#[{ start := 2, stop := 2, inserted := "c" }]] unknown)
                "session-5.json" newer
          match files with
          | none => false
          | some files =>
            match restoredDriver (some files) with
            | none => false
            | some again =>
              let settled := drained (evilFed again "l")
              textNamed settled "note" == some "abc" && textNamed settled "a.txt" == some aText &&
                bytesAt settled (sessionDirectory stateDirectory / "session-5.json") ==
                  some newer.toUTF8 &&
                bytesAt settled (logPath stateDirectory 5 2 1) ==
                  bytesAt { again with jobs := { again.jobs with files } }
                    (logPath stateDirectory 5 2 1) &&
                ((reportOf settled).splitOn
                      "session-5.json: the key layouts is not known").length ==
                  2 &&
                ((reportOf settled).splitOn
                      "session-5.json: buffer 1: the key folds is not known").length ==
                  2 &&
                ((reportOf settled).splitOn "line 3 is of the kind marks").length == 2 },
    { name :=
        "a major mode only config registers is deferred at the restore and set once a config that registers it installs; one the config does not register is said and not set"
      run :=
        pure <|
          match first (modes := #[configMode]) with
          | none => false
          | some begun =>
            let moded :=
              drained
                (ran (evilFed (opened begun "a.txt") "x") "test-modes"
                  [.str configMode.name, .str "spell"])
            match second moded, restoredDriver (modes := #[configMode]) (generation := 1),
              restoredDriver (generation := 1) with
            | some again, some withMode, some without =>
              let deferred := (bufferNamed again "a.txt").bind (·.major)
              let installed :=
                evilFed
                  { again with keys := { withMode.keys with command? := again.keys.command? } } "l"
              let missing :=
                evilFed { again with keys := { without.keys with command? := again.keys.command? } }
                  "l"
              deferred.isNone && again.loop.state.restore.deferred.size == 1 &&
                (bufferNamed installed "a.txt").bind (·.major) == some configMode.name &&
                installed.loop.state.restore.deferred.isEmpty &&
                (bufferNamed missing "a.txt").bind (·.major) == none &&
                missing.loop.state.restore.deferred.isEmpty &&
                missing.loop.state.echo ==
                  s!"restore: no mode is registered as {configMode.name}: a.txt is restored without it"
            | _, _, _ => false }]

end ModelTest
