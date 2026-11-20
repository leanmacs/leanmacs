import ModelTest.Check
import ModelTest.Support.Restore

/-!
# Model tests: `Editor/Restore.lean`

The model tests of `Editor/Restore.lean`: `journalReconcileChecks`, on the
loop's driver over the editor's models and the job model, with the state
directory `/state`. Each reads what the journal's orders left in the file
model, decoded and replayed. The root module `ModelTest` runs them; its
module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Restore
open WorkingSetTest
open RestoreTest

namespace JournalReconcileTest

/-- The key strings that type `text` in insert state from normal state,
then leave it. -/
def typing (text : String) : String :=
  s!"i {typed text} <Escape>"

/-- `driver` once the test command `name` runs with `arguments`, and what
it starts is settled. -/
def ran (driver : EvilDriver) (name : String) (arguments : List Argument := []) : EvilDriver :=
  drained (invoked driver name arguments)

/-- The live journal of the buffer `index`. -/
def liveOf (driver : EvilDriver) (index : Nat) : Option Journal :=
  driver.loop.state.restore.journals.find? (·.buffer == index)

/-- The journal files of the buffer `index`'s generation `generation` of
run 1. -/
def filesOf (index generation : Nat) : Array String :=
  #[(basePath stateDirectory 1 index generation).toString,
    (logPath stateDirectory 1 index generation).toString]

/-- The index of the buffer called `name`. -/
def indexNamed (driver : EvilDriver) (name : String) : Nat :=
  ((driver.loop.state.findBuffer name).map (·.index)).getD 999

/-- `driver` with the text of the buffer called `name` edited behind the
loop's back by `edit`, and its log forgotten up to the revision that
leaves. -/
def forgotten (driver : EvilDriver) (name : String) (edit : TextId → TextM Unit) : EvilDriver :=
  match driver.loop.state.findBuffer name >>= driver.loop.state.buffer? with
  | none => driver
  | some buffer =>
    let program : TextM Unit := do
      edit buffer.text
      buffer.text.forget (← buffer.text.revision)
    { driver with model := { driver.model with texts := (program.runModel driver.model.texts).2 } }

/-- A command that makes the buffer `note`, with no file, and shows it in
its window. -/
def noteCommand : Config.Registration :=
  { name := "test-note"
    action :=
      .call fun call => do
        let .ok id ← createBuffer "note" | return
        discard <| call.target.window.id.show id }

/-- A command that makes `owned`, a read-only buffer it writes into, and an
excerpt buffer of the scratch buffer's text. -/
def ownedCommand : Config.Registration :=
  { name := "test-owned"
    action :=
      .call fun _ => do
        let .ok id ← createBuffer "owned" | return
        discard <| id.setReadOnly true
        discard <| id.writing (id.insertAt 0 "generated")
        let state ← editorState
        let some scratch := state.buffer? ⟨0⟩ | return
        discard <| createExcerptBufferOf "excerpts" #[⟨scratch.text, 0, 0⟩] }

/-- A command that puts the window of its first argument at the place its
other arguments say (`Restore.placeIn`). -/
def placeCommand : Config.Registration :=
  { name := "test-place"
    action :=
      .call fun call => do
        let .nat view :: .nat ar :: .nat ac :: .nat hr :: .nat hc :: .nat top :: _ :=
          call.arguments | return
        let some window := (← editorState).window? ⟨view⟩ | return
        placeIn ⟨view⟩ window.buffer { view, anchor := ⟨ar, ac⟩, head := ⟨hr, hc⟩, top } }

/-- The checks' driver, restored, with the test commands. -/
def driver (state : Option System.FilePath := some stateDirectory) (limit : Nat := Restore.bound) :
    Option EvilDriver :=
  (restoreDriver (state := state) (limit := limit)).map fun driver =>
    begun
      { driver with
        keys :=
          { driver.keys with
            command? := fun name =>
              match [noteCommand, ownedCommand, placeCommand].find? (·.name == name) with
              | some { action := .call run, .. } =>
                some fun call => do
                  run call;
                  return none
              | _ => driver.keys.command? name } }

/-- `driver` handed the host's cells `cells` at the revision `revision`. -/
def withStores (revision : Nat) (cells : Array KeptCell) (driver : EvilDriver) : EvilDriver :=
  { driver with keys := { driver.keys with stores := { revision, cells := Thunk.pure cells } } }

/-- `driver` handed `running` as the reported jobs running, and
`otherJobs` as how many others are. -/
def withRunning (running : Array RunningJob) (driver : EvilDriver) (otherJobs : Nat := 0) :
    EvilDriver :=
  { driver with
    keys :=
      { driver.keys with
        running, otherJobs } }

/-- A config cell kept across a restart. -/
def keptOf (name : String) (value : Nat) : KeptCell :=
  { owner := "config", name, version := 1, value := .nat value }

/-- `driver` with `cells` parked with their scopes at the config generation
0, as a restore parks the table cells no codec met (`Kept.parked`). -/
def withParked (cells : Array (Document.Scope × KeptCell)) (driver : EvilDriver) : EvilDriver :=
  let state := driver.loop.state
  { driver with
    loop :=
      { driver.loop with
        state :=
          { state with
            restore :=
              { state.restore with
                parked := cells, parkedAt := 0 } } } }

/-- `driver` told that config has installed `generation` times, with the
codecs `codec?`. -/
def installedWith (generation : Nat) (codec? : String → Option (String × StoreCodec))
    (driver : EvilDriver) : EvilDriver :=
  { driver with
    keys :=
      { driver.keys with
        registered :=
          { driver.keys.registered with
            generation, codec? } } }

/-- The names of the unscoped cells the index of the run `run` lists. -/
def unscopedNames (driver : EvilDriver) (run : Nat) : Option (Array String) :=
  ((indexOf driver run).bind (·.workspaces)).map (·.unscoped.map (·.name))

end JournalReconcileTest

open JournalReconcileTest in
/-- The checks of the journal's reconciler (`Editor/Restore.lean`). -/
def journalReconcileChecks : List Check :=
  [{  name :=
        "the index written after a split, a new tab and a jump carries the frame, both tabs and the jumps, decoded"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let lines := evilFed begun "i o n e RET t w o <Escape> g g"
            let quiet := drained (ran (ran lines WindowCommands.splitName) TabCommands.newName)
            match indexOf quiet 1 with
            | none => false
            | some document =>
              (document.frame.map (·.tabs.size)) == some 2 &&
                (document.frame.map (·.tabs.map (·.windows.size))) == some #[2, 1] &&
                document.buffers.any fun buffer =>
                  buffer.views.any fun place => place.jumps.any (!·.entries.isEmpty) },
    { name :=
        "a change of the host's cells, a new revision, is mirrored and makes one debounced write, which lists them; an unchanged revision reads nothing"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let written := drained begun
            let changed := evilFed (withStores 1 #[keptOf "kept" 2] written) "l"
            let quiet := drained changed
            let unchanged := drained (evilFed (withStores 1 #[keptOf "other" 9] quiet) "l")
            pendingNamed changed writeJob == 1 &&
              (indexOf quiet 1).map (·.stores) == some #[keptOf "kept" 2] &&
              quiet.loop.state.restore.stores == #[keptOf "kept" 2] &&
              unchanged.loop.state.restore.stores == #[keptOf "kept" 2] &&
              (indexOf unchanged 1).map (·.stores) == some #[keptOf "kept" 2] },
    { name :=
        "a parked table cell an install registers no codec for is dropped once config installs past it: said once in the echo area, no longer parked, and no longer in the next index"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let parked := withParked #[(.unscoped, keptOf "gone" 5)] (drained begun)
            let waiting := drained (evilFed parked "l")
            let dropped := evilFed (installedWith 1 (fun _ => none) waiting) "l"
            let quiet := drained dropped
            -- A later mirror, a revision moved, says nothing again.
            let later :=
              mirrored quiet.loop.state
                ({ configGeneration := 1, stores := { revision := 7 } } : Context)
            unscopedNames waiting 1 == some #["gone"] &&
              waiting.loop.state.restore.parked.size == 1 &&
              dropped.loop.state.echo ==
                "restore: the session kept gone, but no codec is registered for it now; dropped" &&
              dropped.loop.state.restore.parked.isEmpty &&
              unscopedNames quiet 1 == some #[] &&
              later.2 == none &&
              later.1.restore.parked.isEmpty },
    { name :=
        "a parked table cell whose codec an install registers is met into its store, and one whose value that codec refuses is reset to its initial value and the loss said in the echo area"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let refusing : Store Nat :=
              { name := "late", version := 1, initial := 0, encode := .nat,
                decode := fun _ => none }
            let counting : Store Nat :=
              { refusing with
                name := "count"
                decode := fun
                  | .nat n => some n
                  | _ => none }
            let codec? (name : String) : Option (String × StoreCodec) :=
              if name == "late" then some ("config", refusing.codec)
              else if name == "count" then some ("config", counting.codec) else none
            let parked :=
              withParked #[(.unscoped, keptOf "count" 4), (.unscoped, keptOf "late" 5)]
                (drained begun)
            let met := evilFed (installedWith 1 codec? (drained (evilFed parked "l"))) "l"
            met.loop.state.workspaces.unscopedValue? "count" == some (.nat 4) &&
              met.loop.state.workspaces.unscopedValue? "late" == some (.nat 0) &&
              met.loop.state.restore.parked.isEmpty &&
              met.loop.state.echo ==
                "restore: store late: the new config cannot decode the stored value, which was reset to the initial value" },
    { name := "a reported job's start and its end each change the jobs the index lists"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let job : RunningJob := { owner := "shell", name := "shell-run", key := some "k" }
            let started := drained (evilFed (withRunning #[job] (drained begun)) "l")
            let ended := drained (evilFed (withRunning #[] started) "l")
            (indexOf started 1).map (·.jobs) == some #[job] &&
              (indexOf ended 1).map (·.jobs) == some #[] },
    { name :=
        "how many other jobs run, not reported, is a count the index lists, changed by their start and their end"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let started := drained (evilFed (withRunning #[] (drained begun) (otherJobs := 2)) "l")
            let ended := drained (evilFed (withRunning #[] started) "l")
            (indexOf started 1).map (·.otherJobs) == some 2 &&
              (indexOf ended 1).map (·.otherJobs) == some 0 },
    { name :=
        "from an empty state directory the restore makes session/journals/, and typing gives a base at the first edit and then one record per event, which replay to the text"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let made := begun.jobs.files.directories.contains (journalsDirectory stateDirectory)
            let typedIn := evilFed begun (typing "abc")
            made && begun.loop.state.restore.run == some 1 &&
              ((logOf typedIn 1 0 1).map fun log => (log.header.isSome, log.records.size)) ==
                some (true, 2) &&
              journalText typedIn 1 0 1 == some "abc" &&
              journalFiles typedIn == filesOf 0 1 &&
              typedIn.journalFailures.isEmpty },
    { name := "a buffer whose text did not move gets no record"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let typedIn := evilFed begun (typing "ab")
            let moved := evilFed typedIn "h h l"
            (logOf typedIn 1 0 1).map (·.records.size) == some 1 &&
              (logOf moved 1 0 1).map (·.records.size) == some 1 },
    { name := "a save removes the journal of the file's buffer"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let edited := evilFed (opened begun "a.txt") "x"
            let index := indexNamed edited "a.txt"
            let saved := ran edited Files.saveName
            journalFiles edited == filesOf index 1 &&
              journalText edited 1 index 1 == some (aText.drop 1).toString &&
              journalFiles saved == #[] &&
              (liveOf saved index).isNone },
    { name := "undo back to the saved state removes the journal"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let edited := evilFed (opened begun "a.txt") "x"
            let undone := evilFed edited "u"
            journalFiles edited != #[] && journalFiles undone == #[] },
    { name :=
        "past the bound a new generation is written, and the old one's files are removed after it; the live one replays to the text"
      run :=
        pure <|
          match driver (limit := 150) with
          | none => false
          | some begun =>
            let typedIn := evilFed begun (typing "abcdef")
            match liveOf typedIn 0 with
            | none => false
            | some live =>
              live.generation > 1 && journalFiles typedIn == filesOf 0 live.generation &&
                journalText typedIn 1 0 live.generation == some "abcdef" },
    { name :=
        "a log forgotten past the record's revision gives a new generation, its base the text now"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let typedIn := evilFed begun (typing "ab")
            let behind := forgotten typedIn EditorState.scratchName fun text => text.insert 0 "z"
            let after := evilFed behind (typing "c")
            (liveOf after 0).map (·.generation) == some 2 && journalFiles after == filesOf 0 2 &&
              journalText after 1 0 2 == textNamed after EditorState.scratchName },
    { name :=
        "a save while still modified gives a new generation whose header has the file's new stamp"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let edited := evilFed (opened begun "a.txt") "x"
            let index := indexNamed edited "a.txt"
            let saving := evilFed (invoked edited Files.saveName) "x"
            let saved := drained saving
            let stamp := (bufferNamed saved "a.txt").bind (·.file.map (·.stamp))
            match liveOf saved index with
            | none => false
            | some live =>
              live.generation == 2 && journalFiles saved == filesOf index 2 &&
                ((logOf saved 1 index 2).bind (·.header.bind (·.stamp))) == stamp &&
                stamp != ((logOf edited 1 index 1).bind (·.header.bind (·.stamp))) },
    { name := "closing a buffer removes its journal"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let noted := evilFed (ran begun "test-note") (typing "n")
            let index := indexNamed noted "note"
            let closedNote := ran noted Buffers.closeName [.str "note"]
            journalFiles noted == filesOf index 1 && journalFiles closedNote == #[] },
    { name := "read-only, excerpt and minibuffer buffers are never journalled"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let owned := ran begun "test-owned"
            let prompted := evilFed owned ": a b"
            journalFiles prompted == #[] && prompted.loop.state.prompt.isSome },
    { name := "with no state directory nothing is journalled"
      run :=
        pure <|
          match driver (state := none) with
          | none => false
          | some begun =>
            let typedIn := evilFed begun (typing "abc")
            journalFiles typedIn == #[] && (indexOf typedIn 1).isNone },
    { name := "a leave removes this run's journals and saves its index saying ended"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let typedIn := drained (evilFed begun (typing "abc"))
            let left := ran typedIn Ex.quitName
            journalFiles typedIn != #[] && left.stopped && journalFiles left == #[] &&
              (indexOf left 1).map (·.ended) == some true },
    { name := "the index write fires once for a burst of changes, and writes the state at its end"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let written := drained begun
            let burst := evilFed written (typing "abc")
            let quiet := drained burst
            pendingNamed burst writeJob == 1 &&
              ((indexOf quiet 1).map fun document =>
                  document.buffers.map fun buffer =>
                    (buffer.name, buffer.journal.map (·.generation))) ==
                some #[(EditorState.scratchName, some 1)] },
    { name :=
        "every window's place is recorded: two windows on one buffer, each with its selection and scroll top, a third on another buffer, and the focused view named"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let lines := evilFed begun "i o n e RET t w o RET t h r e e RET f o u r <Escape>"
            let split := ran lines WindowCommands.splitName
            let views := split.loop.state.frame.windows
            match views[0]?, views[1]? with
            | some first, some second =>
              let placed :=
                ran
                  (ran split "test-place"
                    [.nat first.index, .nat 0, .nat 1, .nat 1, .nat 2, .nat 0])
                  "test-place" [.nat second.index, .nat 2, .nat 0, .nat 3, .nat 3, .nat 1]
              let third := ran placed WindowCommands.splitName
              let focused := third.loop.state.frame.focused
              let opened := drained (invoked third Files.openName [.str (root / "a.txt").toString])
              let document := indexOf opened 1
              let scratch :=
                (document.bind (·.buffers.find? (·.name == EditorState.scratchName))).map (·.views)
              let file :=
                (document.bind (·.buffers.find? (·.name == "a.txt"))).map (·.views.map (·.view))
              (scratch.map fun places =>
                    places.map fun place => (place.view, place.anchor, place.head)) ==
                  some #[(first.index, ⟨0, 1⟩, ⟨1, 2⟩), (second.index, ⟨2, 0⟩, ⟨3, 3⟩)] &&
                (scratch.map (·.map (·.top))) == some #[0, 1] &&
                file == some #[focused.index] &&
                (document.bind (·.focused)) == some focused.index
            | _, _ => false }]

/-- The offset `Restore.offsetOf` puts `spot` at in a text holding
`content`, on the text model. -/
def offsetIn (content : String) (spot : Spot) : Option Nat :=
  let program : TextM Nat := do
    let text ← createText content
    Restore.offsetOf text spot
  (program.runModel {}).1.toOption

/-- The checks of where a recorded spot is put back (`Restore.offsetOf`,
`Editor/Restore.lean`), on the text model: a spot's column is in bytes. -/
def restoreOffsetChecks : List Check :=
  [{  name := "a spot's byte column after a multi-byte character is that byte of its row"
      run := pure (offsetIn "é xy\nab" ⟨0, 3⟩ == some 3 && offsetIn "ab\né xy" ⟨1, 3⟩ == some 6) },
    { name := "a column past the row's content is clamped to its end, before the line break"
      run := pure (offsetIn "é x\nab" ⟨0, 99⟩ == some 4) },
    { name := "a column inside a multi-byte character is moved back to its start"
      run := pure (offsetIn "aé\n" ⟨0, 2⟩ == some 1 && offsetIn "éa\n" ⟨0, 1⟩ == some 0) },
    { name := "a row past the last is the last row"
      run := pure (offsetIn "é x\nab" ⟨7, 1⟩ == some 6) }]

end ModelTest
