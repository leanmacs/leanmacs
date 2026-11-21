import Editor.Test.Hosted
import FilesApi
import ModelTest.Check
import ModelTest.Editor.Restore
import ModelTest.Support.Restore

/-!
# Model tests: `Editor/Restore/Run.lean`

The model tests of `Editor/Restore/Run.lean`: `restoreChecks`, on the loop's
driver over the editor's models and the job model, from the journals and
indexes a first loop wrote, or that a check wrote by hand. The root module
`ModelTest` runs them; its module doc says what each shows.

Session restore's run adopts a restored file through `files-api`
(`FilesApi.files?`) and runs its `Opened` hook for a journaled buffer that
holds a file, so its drivers answer both from the restore support's
extension points (`files-api`'s fake and the kit's stand-in for the
workspace's attach), and name no module of a feature.
-/

namespace ModelTest

open Editor
open Editor.Test
open Editor.Restore
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

/-- A command that names the tab in view after its first argument. -/
def renameCommandForTest : Config.Registration :=
  { name := "test-rename"
    action :=
      .call fun call => do
        let .str name :: _ := call.arguments | return
        discard <| changeTab (.rename (← editorState).frame.tabIndex (some name)) }

/-- A command that has the workspace of its window's buffer keep the number
of its second argument under the name of its first, and the unscoped store
too. -/
def cellCommandForTest : Config.Registration :=
  { name := "test-cell"
    action :=
      .call fun call => do
        let .str name :: .nat value :: _ := call.arguments | return
        if let some (workspace, _) := (← editorState).workspaceOf? call.target.window.buffer then
          discard <| Workspace.setValue workspace.location name (.nat value)
        Workspace.setUnscopedValue name (.nat value) }

/-- `driver` with the checks' commands: the reconcile checks' and
`test-modes`. -/
def withCommands (driver : RestoreDriver) : RestoreDriver :=
  { driver with
    keys :=
      { driver.keys with
        command? := fun name =>
          match
            [noteCommand, ownedCommand, placeCommand, modesCommandForTest, renameCommandForTest,
                  cellCommandForTest].find?
              (·.name == name) with
          | some { action := .call run, .. } =>
            some fun call => do
              run call;
              return none
          | _ => driver.keys.command? name } }

/-- The first loop: restored over `files`, with `modes`, and the checks'
commands. -/
def first (files : Option FileModel := none) (modes : Array Mode := #[]) : Option RestoreDriver :=
  (restoredDriver files (modes := modes)).map withCommands

/-- A second loop over the world `driver` left, `change` made to its files
first, restored, with the checks' commands. -/
def second (driver : RestoreDriver) (change : FileModel → FileModel := id)
    (modes : Array Mode := #[]) (generation : Nat := 0) : Option RestoreDriver :=
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
def reportOf (driver : RestoreDriver) : String :=
  (textNamed driver reportName).getD ""

/-- The text the focused window shows, with `|` at its cursor. -/
def focusedShown (driver : RestoreDriver) : String :=
  shownOf driver driver.loop.state.frame.focused

/-- The frame `driver`'s state records (`Frame.Record.of`), on its models. -/
def frameOf (driver : RestoreDriver) : Option Frame.Record :=
  ((Frame.Record.of driver.loop.state).runModel driver.model.texts).1.toOption

/-- `record` with its views given ids in its order, the tab in view's focused
one 0 and the others from 1000: two records of one frame are equal so,
whatever ids each run gave. -/
def canonical (record : Frame.Record) : Frame.Record :=
  (record.renumber 0 1000).1

/-- Each view of `driver`'s frame, in its record's order, with its buffer's
name and its place: the anchor and the head of its selection and its top
row. -/
def viewsOf (driver : RestoreDriver) : Option (Array (String × Option (Spot × Spot × Nat))) := do
  let record ← frameOf driver
  let state := driver.loop.state
  record.views.mapM fun view => do
      let window ← state.window? ⟨view⟩
      let buffer ← state.buffer? window.buffer
      let place := ((placeOf state buffer.text window).runModel driver.model.texts).1.toOption.join
      return (buffer.name, place.map fun place => (place.anchor, place.head, place.top))

/-- `driver` handed a layout of manual splits inside a left edge, as config
would hand it. -/
def edged (driver : RestoreDriver) : RestoreDriver :=
  { driver with keys := { driver.keys with layout := some (.edge .left 25 Layout.manual) } }

/-- A first loop's frame of two tabs: `a.txt` edited, with jumps recorded by
`C-<End>` and `C-<Home>` (`jumped`); in the first tab four windows under manual splits at a left
edge, one widened, one docked at the edge and one floating; a second tab
named `notes`, split and zoomed; the first tab in view. -/
def framed : Option RestoreDriver :=
  (first
        (some
          ((world fun files => files.withFile "/r/a.txt" "one\ntwo\nthree\nfour\n".toUTF8).getD
            {}))).map
    fun begun =>
    let edited := keysFed (opened (edged begun) "a.txt") "C-<End> C-<Home> <ArrowDown> <Delete>"
    let tiled :=
      [WindowCommands.splitName, WindowCommands.splitVerticallyName, WindowCommands.splitName,
            WindowCommands.widerName, WindowCommands.edgeLeftName, WindowCommands.nextName,
            WindowCommands.floatName].foldl
        (fun driver name => ran driver name) edited
    let tabbed := ran (ran tiled TabCommands.newName) "test-rename" [.str "notes"]
    let zoomed := ran (ran tabbed WindowCommands.splitName) WindowCommands.zoomName
    drained (ran zoomed TabCommands.previousName)

/-- A second loop over the world `driver` left, with `change` made to its
driver before its restore runs, and the checks' commands. -/
def secondWith (driver : RestoreDriver) (change : RestoreDriver → RestoreDriver)
    (files : FileModel → FileModel := id) : Option RestoreDriver :=
  (restoreDriver (some (files driver.jobs.files))).map fun fresh =>
    begun (withCommands (change fresh))

/-- A store of a count at version 2, which migrates a version-1 count by
doubling it. -/
def counted : Store Nat :=
  { name := "counted", version := 2, initial := 0, encode := .nat
    decode := fun
      | .nat n => some n
      | _ => none
    migrate := fun version tree =>
      match version, tree with
      | 1, .nat n => some (.nat (2 * n))
      | _, _ => none }

/-- `driver` told of the codecs of `names` among `tally` and `later`, counts
both, of the package `pkg`, and of `counted`, of the package `counter`. -/
def withCodecs (names : List String) (driver : RestoreDriver) : RestoreDriver :=
  let count (name : String) : Store Nat :=
    { counted with
      name, version := 1, migrate := fun _ _ => none }
  let codec? (name : String) : Option (String × StoreCodec) :=
    if !names.contains name then none
    else
      if name == "counted" then some ("counter", counted.codec)
      else some ("pkg", (count name).codec)
  { driver with keys := { driver.keys with registered := { driver.keys.registered with codec? } } }

/-- A cell of a store kept by the session. -/
def keptCell (owner name : String) (version : Nat) (value : Value) : KeptCell :=
  { owner, name, version, value }

/-- The jump list of `driver`'s focused window: each entry, then its index,
then the previous-context mark, each place named by where it is now,
`<buffer>:<row>:<column>` for one held in a buffer and
`file <path>:<row>:<column>` for one in a file, the column in characters. -/
def jumpsShown (driver : RestoreDriver) : Option (Array String × Nat × Option String) := do
  let state := driver.loop.state
  let window ← state.window? state.frame.focused
  let shown (place : Editor.Place) : TextM String :=
    match place with
    | .file path row column => pure s!"file {path}:{row}:{column}"
    | .held buffer marker => do
      let name := ((state.buffer? buffer).map (·.name)).getD "no buffer"
      let (row, column) ← Marks.pointAt marker.text (← Marks.offsetOf marker)
      return s!"{name}:{row}:{column}"
  let program : TextM (Array String × Option String) := do
    return (← window.jumps.list.entries.mapM shown, ← window.jumps.previous.mapM shown)
  let (entries, previous) ← (program.runModel driver.model.texts).1.toOption
  return (entries, window.jumps.list.index, previous)

/-- What `driver`'s focused window shows once `keys` are typed and what
they start is settled. -/
def shownAfter (driver : RestoreDriver) (keys : String) : String :=
  focusedShown (drained (keysFed driver keys))

/-- `document` with every jump of the kept buffer `key` written as a place
in the file `path`, as an index holds the place of a file no buffer kept
when it was written. -/
def filedJumps (document : Document) (key : Nat) (path : String) : Document :=
  let filed : Jump → Jump
    | .kept at_ row column => if at_ == key then .file path row column else .kept at_ row column
    | jump => jump
  { document with
    buffers :=
      document.buffers.map fun buffer =>
        { buffer with
          views :=
            buffer.views.map fun place =>
              { place with
                jumps :=
                  place.jumps.map fun jumps =>
                    { jumps with
                      entries := jumps.entries.map filed,
                      previous := jumps.previous.map filed } } } }

/-- A first loop whose scratch buffer has `one`, `two` and `three` typed
in, so it is journalled, with jumps in it recorded by `C-<Home>` and `C-<End>` (`jumped`). -/
def typedScratch : Option RestoreDriver :=
  (first).map fun begun =>
    drained (keysFed begun "C-b o n e RET t w o RET t h r e e C-e <ArrowLeft> C-<Home> C-<End>")

/-- A first loop with jumps in `b.txt`, by `C-<End>` and `C-<Home>`, then `a.txt`
opened and edited, and `b.txt` closed, so the jumps in it are places in
its file. -/
def closedFile : Option RestoreDriver :=
  (first
        (some
          ((world fun files =>
                (files.withFile "/r/a.txt" "one\ntwo\nthree\nfour\n".toUTF8).withFile "/r/b.txt"
                  "alpha\nbeta\ngamma\n".toUTF8).getD
            {}))).map
    fun begun =>
    let inB := keysFed (opened begun "b.txt") "C-<End> C-<Home>"
    drained (closed (keysFed (opened inB "a.txt") "C-<End> <Delete>") "b.txt")

/-- A loop after a first one that opened `a.txt` and ended uncleanly,
over its world with `change` made to it, launched with `launch`, its
restore naming `named`, restored. -/
def restartedOver (named : Option System.FilePath) (launch : Restart.Launch := {})
    (change : FileModel → FileModel := id) : Option RestoreDriver := do
  let before ← first
  let opened := drained (RestoreTest.opened before "a.txt")
  let driver ← restoreDriver (some (change opened.jobs.files))
  let launched :=
    { driver with loop := { driver.loop with state := { driver.loop.state with launch } } }
  let arguments := [Argument.str stateDirectory.toString] ++ (named.map (.str ·.toString)).toList
  return withCommands (drained (launched.started #[{ name := restoreJob, arguments }]))

/-- `files` with an index of the run 5 that lists no buffer, not ended. -/
def withEmptyIndex (files : FileModel) : FileModel :=
  withIndex files (indexName 5) ({ run := 5 } : Document).render

end RestoreRunTest

open RestoreRunTest in
/-- The checks of restoring a session (`Editor/Restore/Run.lean`). -/
def restoreChecks : List Check :=
  [{  name :=
        "a restart's named index is restored even when an index of a higher run is there, and the run then says it took a handed session in"
      run :=
        pure <|
          let named := restartedOver (some (indexPath stateDirectory 1)) (change := withEmptyIndex)
          let chosen := restartedOver none (change := withEmptyIndex)
          (named.map fun d => (bufferNamed d "a.txt").isSome) == some true &&
            (chosen.map fun d => (bufferNamed d "a.txt").isSome) == some false &&
            (named.map (·.loop.state.restore.restarted)) == some true &&
            (chosen.map (·.loop.state.restore.restarted)) == some false },
    { name :=
        "a named index that is not there is said, and the index the version rule chooses is restored"
      run :=
        pure <|
          match restartedOver (some (indexPath stateDirectory 42)) with
          | none => false
          | some driver =>
            (bufferNamed driver "a.txt").isSome &&
              (reportOf driver).contains
                "session-42.json was named by the restart but it is not there; restoring as after an unclean end" },
    { name :=
        "a named index that does not parse is said, left as it is, and the index the version rule chooses is restored"
      run :=
        pure <|
          let garbage := "{ not an index"
          let change (files : FileModel) : FileModel := withIndex files (indexName 0) garbage
          match restartedOver (some (indexPath stateDirectory 0)) (change := change) with
          | none => false
          | some driver =>
            (bufferNamed driver "a.txt").isSome &&
              (reportOf driver).contains
                "session-0.json was named by the restart but it does not parse; restoring as after an unclean end" &&
              bytesAt driver (indexPath stateDirectory 0) == some garbage.toUTF8 },
    { name :=
        "a restart's summary says the window was closed and reopened, and, after a fallback, which executables ended before the one that restored it"
      run :=
        pure <|
          let named := some (indexPath stateDirectory 1)
          let plain := restartedOver named { running := some "/A/editor" }
          let fell :=
            restartedOver named { running := some "/A/editor", failed := #["/u/9/editor"] }
          (plain.map (·.loop.state.echo)) ==
              some
                "restore: restarted, so the window was closed and reopened; 1 buffers, 0 with unsaved text" &&
            (fell.map (·.loop.state.echo)) ==
              some
                "restore: restarted, so the window was closed and reopened; /u/9/editor ended before restoring the session, so /A/editor restored it; 1 buffers, 0 with unsaved text" },
    { name :=
        "a record a launcher gave up on, handover.failed, is said in the report with its candidates and removed"
      run :=
        pure <|
          let failed :=
            "leanmacs-handover 1\nsession /state/session/session-1.json\nshipped /A/editor\ncandidate /u/9/editor\ncandidate /A/editor\nfailed /u/9/editor\nfailed /A/editor\n"
          let change (files : FileModel) : FileModel :=
            files.withFile (failedRecordPath stateDirectory) failed.toUTF8
          match restartedOver none (change := change) with
          | none => false
          | some driver =>
            (reportOf driver).contains
                "a restart could not start any of /u/9/editor, /A/editor; the session was restored as after an unclean end" &&
              bytesAt driver (failedRecordPath stateDirectory) == none },
    { name :=
        "(a) windows and layouts, (b) tabs: two tabs with manual splits at an edge, a resize, a docked window, a float, a named and zoomed hidden tab come back as they were, up to the views' ids; the start window keeps id 0 and is focused; each view's buffer, selection and scroll match; tab-next shows the hidden tab as it was"
      run :=
        pure <|
          match framed with
          | none => false
          | some before =>
            match second before with
            | none => false
            | some again =>
              let hidden := ran again TabCommands.nextName
              (frameOf before).map canonical == (frameOf again).map canonical &&
                (frameOf before).isSome &&
                viewsOf before == viewsOf again &&
                again.loop.state.wellFormed &&
                again.loop.state.frame.focused == ⟨0⟩ &&
                again.loop.state.frame.tabs.size == 2 &&
                again.loop.state.frame.docked.size == 1 &&
                again.loop.state.frame.floats.size == 1 &&
                hidden.loop.state.frame.name == some "notes" &&
                hidden.loop.state.frame.layout == .monocle &&
                hidden.loop.state.frame.zoomedFrom.isSome &&
                again.loop.state.echo == "restore: 1 buffers, 1 with unsaved text" },
    { name :=
        "(c) the jump list: the restored window's C-o goes where the first loop's went, and the list's entries, its index and the previous-context mark come back; an entry of a buffer that is not kept is dropped"
      run :=
        pure <|
          match framed with
          | none => false
          | some before =>
            match second before with
            | none => false
            | some again =>
              let jumpsOf (driver : RestoreDriver) : Option (Nat × Nat × Bool) :=
                (driver.loop.state.window? driver.loop.state.frame.focused).map
                  fun (window : Window) =>
                  (window.jumps.list.entries.size, window.jumps.list.index,
                    window.jumps.previous.isSome)
              -- The first loop's first entry is in the scratch buffer, which
              -- is not kept: it is dropped, and the index with it.
              focusedShown (keysFed before "C-o") == focusedShown (keysFed again "C-o") &&
                jumpsOf before == some (3, 3, true) &&
                jumpsOf again == some (2, 2, true) &&
                focusedShown (keysFed before "C-o") != focusedShown before },
    { name :=
        "(c) the jump list with its index in the middle, an entry before it dropped: the index moves back past the dropped entry, and the restored window's C-o and C-i go where the first loop's went"
      run :=
        pure <|
          match framed with
          | none => false
          | some before =>
            -- C-o once leaves the index in the middle of the list, after
            -- the scratch buffer's entry, which is not kept.
            let mid := drained (keysFed before "C-o")
            match second mid with
            | none => false
            | some again =>
              jumpsShown mid ==
                  some
                    (#["scratch:0:0", "a.txt:0:0", "a.txt:3:0", "a.txt:1:0"], 2,
                      some "a.txt:1:0") &&
                jumpsShown again ==
                  some (#["a.txt:0:0", "a.txt:3:0", "a.txt:1:0"], 1, some "a.txt:1:0") &&
                shownAfter mid "C-o" == shownAfter again "C-o" &&
                shownAfter mid "C-i" == shownAfter again "C-i" &&
                shownAfter again "C-o" != shownAfter again "C-i" },
    { name :=
        "(c) a jump entry in a kept buffer with no file is held in the restored buffer by a new marker, and the restored window's C-o goes where the first loop's went"
      run :=
        pure <|
          match typedScratch with
          | none => false
          | some before =>
            match second before with
            | none => false
            | some again =>
              let window := again.loop.state.window? again.loop.state.frame.focused
              let scratch := again.loop.state.findBuffer EditorState.scratchName
              jumpsShown before == some (#["scratch:2:4", "scratch:0:0"], 2, some "scratch:0:0") &&
                jumpsShown again == jumpsShown before &&
                (window.map fun window =>
                    window.jumps.list.entries.all fun
                      | .held buffer _ => some buffer == scratch
                      | .file .. => false) ==
                  some true &&
                shownAfter before "C-o" == shownAfter again "C-o" &&
                shownAfter again "C-o" != focusedShown again },
    { name :=
        "(c) a jump entry in a file no buffer keeps is restored as a place in that file, and the restored window's C-o reaches it, opening the file where the first loop's did"
      run :=
        pure <|
          match closedFile with
          | none => false
          | some before =>
            match second before with
            | none => false
            | some again =>
              let back (driver : RestoreDriver) : RestoreDriver :=
                drained (keysFed (drained (keysFed driver "C-o")) "C-o")
              jumpsShown before ==
                  some
                    (#["scratch:0:0", "file /r/b.txt:0:0", "file /r/b.txt:2:0", "file /r/b.txt:0:0",
                        "a.txt:0:0"],
                      5, some "a.txt:0:0") &&
                jumpsShown again ==
                  some
                    (#["file /r/b.txt:0:0", "file /r/b.txt:2:0", "file /r/b.txt:0:0", "a.txt:0:0"],
                      4, some "a.txt:0:0") &&
                focusedShown (back before) == focusedShown (back again) &&
                focusedShown (back again) == "|alpha\nbeta\ngamma\n" },
    { name :=
        "(c) a jump entry recorded in the file of a buffer the restore puts back is held in that buffer once it is restored (Jumps.attach)"
      run :=
        pure <|
          match framed with
          | none => false
          | some before =>
            let filed (files : FileModel) : FileModel :=
              match indexOf before 1 with
              | some document =>
                match document.buffers.find? (·.name == "a.txt") with
                | some kept =>
                  withIndex files (indexName 1) (filedJumps document kept.key "/r/a.txt").render
                | none => files
              | none => files
            match second before filed, second before with
            | some attached, some again =>
              let a := attached.loop.state.findBuffer "a.txt"
              let window := attached.loop.state.window? attached.loop.state.frame.focused
              (indexOf before 1).any (fun document => document.buffers.any (·.name == "a.txt")) &&
                jumpsShown attached == some (#["a.txt:0:0", "a.txt:3:0"], 2, some "a.txt:3:0") &&
                jumpsShown attached == jumpsShown again &&
                (window.map fun window =>
                    window.jumps.list.entries.all fun
                      | .held buffer _ => some buffer == a
                      | .file .. => false) ==
                  some true &&
                shownAfter attached "C-o" == shownAfter again "C-o"
            | _, _ => false },
    { name :=
        "(d) undo: every restored buffer is marked as having no history before the restore, and an undo at its root finds no step and leaves its text"
      run :=
        pure <|
          match framed with
          | none => false
          | some before =>
            match second before with
            | none => false
            | some again =>
              (bufferNamed again "a.txt").map (·.historyRestored) == some true &&
                textNamed (keysFed again "C-z") "a.txt" == textNamed again "a.txt" &&
                (textNamed again "a.txt").isSome },
    { name :=
        "(h) a frame the restore refuses falls back to phase 1's placement and says so: a record check refuses, and a prompt open at the restore"
      run :=
        pure <|
          match framed with
          | none => false
          | some before =>
            let broken (files : FileModel) : FileModel :=
              match indexOf before 1 with
              | some document =>
                withIndex files (indexName 1)
                  ({ document with
                        frame := document.frame.map fun frame => { frame with selected := 9 } } :
                      Document).render
              | none => files
            let prompted :=
              (restoreDriver (some before.jobs.files)).bind fun fresh =>
                let started :=
                  (withCommands fresh).started
                    #[{ name := restoreJob, arguments := [.str stateDirectory.toString] }]
                match started.pending[0]? with
                | none => none
                | some job => some (drained (keysFed (started.finish job.id).1 "C-x"))
            match second before broken, prompted with
            | some refused, some asked =>
              refused.loop.state.frame.tabs.size == 1 &&
                refused.loop.state.frame.windows.size == 1 &&
                ((reportOf refused).splitOn
                      "the windows are not restored (the tab in view, 10, is past the 2 tabs)").length ==
                  2 &&
                refused.loop.state.restore.places.size > 0 &&
                ((reportOf asked).splitOn
                      s!"the windows are not restored ({LayoutRefusal.promptOpen.describe})").length ==
                  2 &&
                asked.loop.state.frame.tabs.size == 1
            | _, _ => false },
    { name :=
        "(i) a window whose buffer is not kept shows scratch after the restore, and the report says so"
      run :=
        pure <|
          match first with
          | none => false
          | some begun =>
            let noted :=
              drained
                (ran (ran (keysFed begun (typing "kept")) WindowCommands.splitName) "test-note")
            match second noted with
            | none => false
            | some again =>
              let shown :=
                again.loop.state.windows.filterMap fun window =>
                  (again.loop.state.buffer? window.buffer).map (·.name)
              shown == #[EditorState.scratchName, EditorState.scratchName] &&
                ((reportOf again).splitOn
                      "showed note, which is not kept: it shows scratch").length ==
                  2 &&
                again.loop.state.echo ==
                  s!"restore: 1 buffers, 1 with unsaved text; see {reportName}" },
    { name :=
        "(e) workspaces and (f) their stores: the table's workspace and project come back with a restored file buffer attached; a cell with a package's codec comes back, one with none is never written, and one whose codec is registered later is parked, written meanwhile, and claimed after an install"
      run :=
        pure <|
          match (first).map (withCodecs ["tally", "later"]) with
          | none => false
          | some begun =>
            let celled :=
              drained
                ([("tally", 7), ("private", 3), ("later", 5)].foldl
                  (fun driver (name, value) => ran driver "test-cell" [.str name, .nat value])
                  (keysFed (opened begun "a.txt") "<Delete>"))
            let written := (indexOf celled 1).bind (·.workspaces)
            let names := (written.map fun record => record.unscoped.map (·.name)).getD #[]
            match secondWith celled (withCodecs ["tally"]) with
            | none => false
            | some again =>
              let state := again.loop.state
              let location := (state.workspaces.workspaces[0]?).map (·.1.location)
              let valueOf (name : String) (driver : RestoreDriver) : Option Value :=
                location.bind (driver.loop.state.workspaces.workspaceValue? · name)
              let meanwhile :=
                ((indexOf again 2).bind (·.workspaces)).map fun record =>
                  record.unscoped.map (·.name)
              let installed :=
                drained
                  (ran
                    (withCodecs ["tally", "later"]
                      { again with
                        keys :=
                          { again.keys with
                            registered := { again.keys.registered with generation := 1 } } })
                    "test-place" [.nat 0, .nat 0, .nat 0, .nat 0, .nat 0, .nat 0])
              names == #["tally", "later"] &&
                state.workspaces.workspaces.size == celled.loop.state.workspaces.workspaces.size &&
                state.workspaces.projects.map (·.1) ==
                  celled.loop.state.workspaces.projects.map (·.1) &&
                (state.workspaces.workspaces.map (·.1.branch)) ==
                  celled.loop.state.workspaces.workspaces.map (·.1.branch) &&
                ((state.findBuffer "a.txt").bind (state.workspaceOf? ·)).isSome &&
                valueOf "tally" again == some (.nat 7) &&
                valueOf "private" again == none &&
                valueOf "later" again == none &&
                state.restore.parked.size == 2 &&
                meanwhile == some #["tally", "later"] &&
                valueOf "later" installed == some (.nat 5) &&
                installed.loop.state.workspaces.unscopedValue? "later" == some (.nat 5) &&
                installed.loop.state.restore.parked.isEmpty },
    { name :=
        "(g) a reported job running at the write is named in *restore* as stopped by the restart, the other jobs running are counted there, and the summary counts them all; a job the registry does not report is not handed by name, and the count is the host's"
      run :=
        pure <|
          match first with
          | none => false
          | some begun =>
            let running : RestoreDriver :=
              { begun with
                keys :=
                  { begun.keys with
                    running :=
                      #[{ owner := "shell", name := "shell-run", key := some "shell outside" }]
                    otherJobs := 2 } }
            let typed := drained (keysFed running (typing "kept"))
            let pendingJob (name : String) : Loop.Driver.Pending :=
              { id := 9, name, outcome := .cancelled, key := some name }
            let handed :=
              ({ begun with
                    pending := #[pendingJob "waited", pendingJob "watched"]
                    keys :=
                      { begun.keys with
                        otherJobs := 4
                        registered :=
                          { begun.keys.registered with reported := (· == "waited") } } } :
                  RestoreDriver).handed
            match second typed with
            | none => false
            | some again =>
              ((reportOf again).splitOn
                      "the job shell-run (shell outside) of shell was running: the restart stopped it").length ==
                  2 &&
                ((reportOf again).splitOn
                      "and 2 other jobs were running: the restart stopped them").length ==
                  2 &&
                again.loop.state.echo ==
                  s!"restore: 1 buffers, 1 with unsaved text; 3 jobs stopped; see {reportName}" &&
                handed.running.map (·.name) == #["waited"] &&
                handed.otherJobs == 4 },
    { name :=
        "other jobs running at the write with no reported one are counted in *restore* and in the summary"
      run :=
        pure <|
          match first with
          | none => false
          | some begun =>
            let running : RestoreDriver := { begun with keys := { begun.keys with otherJobs := 1 } }
            match second (drained (keysFed running (typing "kept"))) with
            | none => false
            | some again =>
              ((reportOf again).splitOn "1 jobs were running: the restart stopped them").length ==
                  2 &&
                again.loop.state.echo ==
                  s!"restore: 1 buffers, 1 with unsaved text; 1 jobs stopped; see {reportName}" },
    { name :=
        "(j) a package's declared store: an entry at its version is handed on as it is, one at an older version migrated, one decode refuses as the initial value with a report line; config's is handed on as it is, and an unknown owner's is not, and is said"
      run :=
        pure <|
          let entries :=
            #[keptCell "counter" "counted" 2 (.nat 4), keptCell "counter" "counted" 1 (.nat 4),
              keptCell "counter" "counted" 2 (.str "bad"), keptCell "config" "kept" 1 (.nat 9),
              keptCell "gone" "lost" 1 (.nat 1)]
          let text := ({ run := 5, stores := entries } : Document).render
          match world (fun files => withIndex files (indexName 5) text) with
          | none => false
          | some files =>
            match
              (restoreDriver (some files)).map fun fresh =>
                begun (withCommands (withCodecs ["counted"] fresh)) with
            | none => false
            | some again =>
              again.restoredCells ==
                  #[keptCell "counter" "counted" 2 (.nat 4),
                    keptCell "counter" "counted" 2 (.nat 8),
                    keptCell "counter" "counted" 2 (.nat 0), keptCell "config" "kept" 1 (.nat 9)] &&
                ((reportOf again).splitOn
                      "store counted of counter: the new config cannot decode").length ==
                  2 &&
                ((reportOf again).splitOn
                      "store lost of gone: gone keeps no such store now: it is dropped").length ==
                  2 },
    { name :=
        "a cursor after a multi-byte character comes back where it was: its column is recorded in bytes and put back in bytes"
      run :=
        pure <|
          match
            first
              (some ((world fun files => files.withFile "/r/e.txt" "é xy\n".toUTF8).getD {})) with
          | none => false
          | some begun =>
            let moved := drained (keysFed (opened begun "e.txt") "<ArrowRight> <ArrowRight>")
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
            let scratched := keysFed begun (typing "kept")
            let crlf := keysFed (opened scratched "c.txt") "<Delete>"
            let moded := ran crlf "test-modes" [.str configMode.name, .str "spell"]
            let edited :=
              drained (keysFed (opened moded "a.txt") "<ArrowDown> <ArrowRight> <Delete>")
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
        "a file changed on disk since is restored with its unsaved text and marked, which the restore's line says, and its save is refused as changed, the file left as it is"
      run :=
        pure <|
          match first with
          | none => false
          | some begun =>
            let edited := drained (opened (keysFed (opened begun "a.txt") "<Delete>") "b.txt")
            match
              second edited (fun files => files.withFile (root / "a.txt") "rewritten\n".toUTF8) with
            | none => false
            | some again =>
              let marked := (bufferNamed again "a.txt").bind (·.file.bind (·.changed))
              let shown := opened again "a.txt"
              let saved := ran shown FilesApi.saveName
              (marked.bind (·.found)) ==
                  ((again.jobs.files.file? (root / "a.txt")).map (·.stamp)) &&
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
            let both := drained (keysFed (opened (opened begun "b.txt") "a.txt") "<Delete>")
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
            let edited := drained (keysFed begun (typing "abc"))
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
        "the other windows come back with the frame, and the next index carries both places; from the same index with no frame, format 1's, the other window's place is kept, as phase 1 keeps it, and the next index carries both"
      run :=
        pure <|
          match first with
          | none => false
          | some begun =>
            let lines := keysFed begun "C-b o n e RET t w o RET t h r e e C-e <ArrowLeft>"
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
              let spots (buffer : Option Document.Buffer) : Array (Spot × Spot) :=
                ((buffer.map (·.views.map fun place => (place.anchor, place.head))).getD #[]).qsort
                  fun a b => a.1.row < b.1.row
              let unframed (files : FileModel) : FileModel :=
                match indexOf placed 1 with
                | some document =>
                  withIndex files (indexName 1)
                    { document with
                        format := 1, frame := none }.render
                | none => files
              match second placed, second placed unframed with
              | some again, some phaseOne =>
                let after :=
                  (indexOf again 2).bind (·.buffers.find? (·.name == EditorState.scratchName))
                let kept :=
                  (indexOf phaseOne 2).bind (·.buffers.find? (·.name == EditorState.scratchName))
                again.loop.state.frame.windows.size == 2 &&
                  again.loop.state.restore.places.isEmpty &&
                  spots before == spots after &&
                  (spots after).size == 2 &&
                  phaseOne.loop.state.frame.windows.size == 1 &&
                  phaseOne.loop.state.restore.places.size == 1 &&
                  spots before == spots kept
              | _, _ => false
            | _, _ => false },
    { name :=
        "a place kept from an earlier run is never taken for a window of a later run's frame: a format-1 restore keeps the other window's place under its old view id, a split gives a new window that id on another buffer, and the next restore puts every window back on its own buffer"
      run :=
        pure <|
          match first with
          | none => false
          | some begun =>
            -- Window 0 on b.txt, window 1 on a.txt, focused.
            let split := ran (keysFed (opened begun "b.txt") "<Delete>") WindowCommands.splitName
            let firstRun := drained (keysFed (opened split "a.txt") "<Delete>")
            let unframed (files : FileModel) : FileModel :=
              match indexOf firstRun 1 with
              | some document =>
                withIndex files (indexName 1)
                  { document with
                      format := 1, frame := none }.render
              | none => files
            match second firstRun unframed with
            | none => false
            | some phaseOne =>
              -- b.txt's place is kept under view 1; the split's window is 1,
              -- on a.txt.
              let resplit := drained (ran phaseOne WindowCommands.splitName)
              match second resplit with
              | none => false
              | some again =>
                let buffers (driver : RestoreDriver) : Option (Array String) :=
                  (viewsOf driver).map (·.map (·.1))
                phaseOne.loop.state.restore.places.size == 1 &&
                  buffers resplit == some #["a.txt", "a.txt"] &&
                  buffers again == buffers resplit },
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
              let settled := drained (keysFed again idle)
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
                (ran (keysFed (opened begun "a.txt") "<Delete>") "test-modes"
                  [.str configMode.name, .str "spell"])
            match second moded, restoredDriver (modes := #[configMode]) (generation := 1),
              restoredDriver (generation := 1) with
            | some again, some withMode, some without =>
              let deferred := (bufferNamed again "a.txt").bind (·.major)
              let installed :=
                keysFed
                  { again with keys := { withMode.keys with command? := again.keys.command? } } "l"
              let missing :=
                keysFed { again with keys := { without.keys with command? := again.keys.command? } }
                  "l"
              deferred.isNone && again.loop.state.restore.deferred.size == 1 &&
                (bufferNamed installed "a.txt").bind (·.major) == some configMode.name &&
                installed.loop.state.restore.deferred.isEmpty &&
                (bufferNamed missing "a.txt").bind (·.major) == none &&
                missing.loop.state.restore.deferred.isEmpty &&
                missing.loop.state.echo ==
                  s!"restore: no mode is registered as {configMode.name}: a.txt is restored without it"
            | _, _, _ => false },
    { name :=
        "a journaled buffer that holds a file runs every FilesApi.Opened value once, with the buffer and its path, as an open does: an Opened value the check registers sees the restored a.txt"
      run :=
        pure <|
          match first with
          | none => false
          | some begun =>
            let edited := drained (keysFed (opened begun "a.txt") "<Delete>")
            let probe : Package :=
              { name := "restore-opened-probe"
                setup :=
                  Extension.add
                    ({  name := "probe"
                        opened := fun id path =>
                          discard <| createText s!"restore-opened {id.index} {path}" } :
                      FilesApi.Opened) }
            let withProbe (driver : RestoreDriver) : RestoreDriver :=
              { driver with
                keys := Test.withExtensionsOf driver.keys (RestoreTest.hooks.push probe) }
            match secondWith edited withProbe with
            | none => false
            | some again =>
              match again.loop.state.findFile (root / "a.txt") with
              | none => false
              | some id =>
                (bufferNamed again "a.txt").map (·.isModified) == some true &&
                  again.model.texts.contents.filter (·.startsWith "restore-opened ") ==
                    #[s!"restore-opened {id.index} {root / "a.txt"}"] },
    { name :=
        "with no files implementation, an unmodified file of the index to reopen is reported and not restored, and a journaled one is restored all the same"
      run :=
        pure <|
          match first with
          | none => false
          | some begun =>
            let both := drained (keysFed (opened (opened begun "b.txt") "a.txt") "<Delete>")
            let bare (driver : RestoreDriver) : RestoreDriver :=
              { driver with keys := Test.withoutExtension FilesApi.Files driver.keys }
            match secondWith both bare with
            | none => false
            | some again =>
              (bufferNamed again "b.txt").isNone && (bufferNamed again "a.txt").isSome &&
                ((reportOf again).splitOn
                      s!"/r/b.txt: {FilesApi.noImplementation "restore"}: it is not restored").length ==
                  2 }]

end ModelTest
