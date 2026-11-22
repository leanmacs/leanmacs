import ModelTest.Check
import ModelTest.Support.Restore

/-!
# Model tests: `Editor/Restore.lean`

The model tests of `Editor/Restore.lean`: `journalReconcileChecks`, on the
loop's driver over the editor's models and the job model, with the state
directory `/state`. Each reads what the journal's orders left in the file
model, decoded and replayed. And `orderFailureChecks`, pure: the path of a
journal order and what a reply to it says of it. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test
open Editor.Restore
open RestoreTest

namespace JournalReconcileTest

/-- The key strings that type `text` in one session the scheme reports
(`C-b`, the text, `C-e`) and then step the cursor back onto its last
character. -/
def typing (text : String) : String :=
  s!"C-b {typed text} C-e <ArrowLeft>"

/-- `driver` once the test command `name` runs with `arguments`, and what
it starts is settled. -/
def ran (driver : RestoreDriver) (name : String) (arguments : List Argument := []) :
    RestoreDriver :=
  drained (invoked driver name arguments)

/-- The live journal of the buffer `index`. -/
def liveOf (driver : RestoreDriver) (index : Nat) : Option Journal :=
  driver.loop.state.restore.journals.find? (·.buffer == index)

/-- The journal files of the buffer `index`'s generation `generation` of
run 1. -/
def filesOf (index generation : Nat) : Array String :=
  #[(basePath stateDirectory 1 index generation).toString,
    (logPath stateDirectory 1 index generation).toString]

/-- The index of the buffer called `name`. -/
def indexNamed (driver : RestoreDriver) (name : String) : Nat :=
  ((driver.loop.state.findBuffer name).map (·.index)).getD 999

/-- `driver` with the text of the buffer called `name` edited behind the
loop's back by `edit`, and its log forgotten up to the revision that
leaves. -/
def forgotten (driver : RestoreDriver) (name : String) (edit : TextId → TextM Unit) :
    RestoreDriver :=
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
    Option RestoreDriver :=
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
def withStores (revision : Nat) (cells : Array KeptCell) (driver : RestoreDriver) : RestoreDriver :=
  { driver with keys := { driver.keys with stores := { revision, cells := Thunk.pure cells } } }

/-- `driver` handed `running` as the reported jobs running, and
`otherJobs` as how many others are. -/
def withRunning (running : Array RunningJob) (driver : RestoreDriver) (otherJobs : Nat := 0) :
    RestoreDriver :=
  { driver with
    keys :=
      { driver.keys with
        running, otherJobs } }

/-- A config cell kept across a restart. -/
def keptOf (name : String) (value : Nat) : KeptCell :=
  { owner := "config", name, version := 1, value := .nat value }

/-- `driver` with `cells` parked with their scopes at the config generation
0, as a restore parks the table cells no codec met (`Kept.parked`). -/
def withParked (cells : Array (Document.Scope × KeptCell)) (driver : RestoreDriver) :
    RestoreDriver :=
  let state := driver.loop.state
  { driver with
    loop :=
      { driver.loop with
        state :=
          { state with
            restore :=
              { state.restore with
                parked := cells, parkedAt := 0 } } } }

/-- `driver` with the major mode `mode` of the buffer `buffer` deferred at
the config generation 0, as a restore defers a mode only config registers
(`Kept.deferred`). -/
def withDeferred (buffer : Nat) (mode : String) (driver : RestoreDriver) : RestoreDriver :=
  let state := driver.loop.state
  { driver with
    loop :=
      { driver.loop with
        state :=
          { state with
            restore :=
              { state.restore with deferred := #[{ buffer, mode, generation := some 0 }] } } } }

/-- `driver` told that config has installed `generation` times, with the
codecs `codec?`. -/
def installedWith (generation : Nat) (codec? : String → Option (String × StoreCodec))
    (driver : RestoreDriver) : RestoreDriver :=
  { driver with
    keys :=
      { driver.keys with
        registered :=
          { driver.keys.registered with
            generation, codec? } } }

/-- `driver` once the pending job called `name` is finished, the oldest of
that name. -/
def finishNamed (driver : RestoreDriver) (name : String) : RestoreDriver :=
  match driver.pending.find? (·.name == name) with
  | some job => (driver.finish job.id).1
  | none => driver

/-- A driver of the checks launched with the hand-over record of a restart
(`--handed-over`), the record on disk, with the restore started and
its two halves finished: restored, its own index not yet written. -/
def handedDriver : Option RestoreDriver :=
  (restoreDriver).map fun driver =>
    let record := recordPath stateDirectory
    let launched :=
      { driver with
        loop :=
          { driver.loop with
            state := { driver.loop.state with launch := { handedOver := some record } } }
        jobs := { driver.jobs with files := driver.jobs.files.withFile record "record".toUTF8 } }
    let started :=
      launched.started #[{ name := restoreJob, arguments := [.str stateDirectory.toString] }]
    finishNamed (finishNamed started restoreJob) filesJob

/-- The names of the unscoped cells the index of the run `run` lists. -/
def unscopedNames (driver : RestoreDriver) (run : Nat) : Option (Array String) :=
  ((indexOf driver run).bind (·.workspaces)).map (·.unscoped.map (·.name))

end JournalReconcileTest

open JournalReconcileTest in
/-- The checks of the journal's reconciler (`Editor/Restore.lean`). -/
def journalReconcileChecks : List Check :=
  [{  name :=
        "the hand-shake: a run handed a record removes it once the handed index is restored and its own index is written, never before, and once"
      run :=
        pure <|
          match handedDriver with
          | none => false
          | some restored =>
            let record := recordPath stateDirectory
            let shaken := drained restored
            -- Once only: a record written again later is the next restart's.
            let rewritten :=
              { shaken with
                jobs :=
                  { shaken.jobs with files := shaken.jobs.files.withFile record "next".toUTF8 } }
            let later := drained (keysFed rewritten (typing "x"))
            restored.loop.state.restore.restored && !restored.loop.state.restore.indexWritten &&
              bytesAt restored record == some "record".toUTF8 &&
              restored.loop.state.restore.handedOver == some record &&
              shaken.loop.state.restore.indexWritten &&
              bytesAt shaken record == none &&
              shaken.loop.state.restore.handedOver.isNone &&
              bytesAt later record == some "next".toUTF8 &&
              later.loop.state.restore.handedOver.isNone },
    { name :=
        "a run that ends cleanly before the hand-shake removes the record it was handed with its last orders"
      run :=
        pure <|
          match handedDriver with
          | none => false
          | some restored =>
            let quit := invoked restored Quit.name
            quit.stopped && bytesAt quit (recordPath stateDirectory) == none &&
              (indexOf quit 1).map (·.ended) == some true },
    { name :=
        "the index written after a split, a new tab and a jump carries the frame, both tabs and the jumps, decoded"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let lines := keysFed begun "C-b o n e RET t w o C-e <ArrowLeft> C-<Home>"
            let quiet := drained (ran (ran lines Test.Windows.splitName) Test.Windows.newTabName)
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
            let changed := keysFed (withStores 1 #[keptOf "kept" 2] written) idle
            let quiet := drained changed
            let unchanged := drained (keysFed (withStores 1 #[keptOf "other" 9] quiet) idle)
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
            let waiting := drained (keysFed parked idle)
            let dropped := keysFed (installedWith 1 (fun _ => none) waiting) idle
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
              later.2.isEmpty &&
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
            let met := keysFed (installedWith 1 codec? (drained (keysFed parked idle))) idle
            met.loop.state.workspaces.unscopedValue? "count" == some (.nat 4) &&
              met.loop.state.workspaces.unscopedValue? "late" == some (.nat 0) &&
              met.loop.state.restore.parked.isEmpty &&
              met.loop.state.echo ==
                "restore: store late: the new config cannot decode the stored value, which was reset to the initial value" },
    { name :=
        "an install that settles a deferred mode no config registers and drops a parked table cell no codec is registered for says both, in one sentence"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let parked :=
              withDeferred 0 "missing-mode"
                (withParked #[(.unscoped, keptOf "gone" 5)] (drained begun))
            let settled :=
              keysFed (installedWith 1 (fun _ => none) (drained (keysFed parked idle))) idle
            let name := ((settled.loop.state.buffer? ⟨0⟩).map (·.name)).getD ""
            settled.loop.state.restore.parked.isEmpty &&
              settled.loop.state.restore.deferred.isEmpty &&
              settled.loop.state.echo ==
                s!"restore: the session kept gone, but no codec is registered for it now; dropped; no mode is registered as missing-mode: {name} is restored without it" },
    { name :=
        "an install that settles a deferred mode no config registers and resets a parked table cell whose value its codec refuses says both, in one sentence"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let refusing : Store Nat :=
              { name := "late", version := 1, initial := 0, encode := .nat,
                decode := fun _ => none }
            let codec? (name : String) : Option (String × StoreCodec) :=
              if name == "late" then some ("config", refusing.codec) else none
            let parked :=
              withDeferred 0 "missing-mode"
                (withParked #[(.unscoped, keptOf "late" 5)] (drained begun))
            let settled := keysFed (installedWith 1 codec? (drained (keysFed parked idle))) idle
            let name := ((settled.loop.state.buffer? ⟨0⟩).map (·.name)).getD ""
            settled.loop.state.workspaces.unscopedValue? "late" == some (.nat 0) &&
              settled.loop.state.restore.deferred.isEmpty &&
              settled.loop.state.echo ==
                s!"restore: store late: the new config cannot decode the stored value, which was reset to the initial value; no mode is registered as missing-mode: {name} is restored without it" },
    { name := "a reported job's start and its end each change the jobs the index lists"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let job : RunningJob := { owner := "shell", name := "shell-run", key := some "k" }
            let started := drained (keysFed (withRunning #[job] (drained begun)) idle)
            let ended := drained (keysFed (withRunning #[] started) idle)
            (indexOf started 1).map (·.jobs) == some #[job] &&
              (indexOf ended 1).map (·.jobs) == some #[] },
    { name :=
        "the other jobs counted are every job running that is neither reported nor restarted by its owner, whoever registered it"
      run :=
        pure <|
          Restore.otherJobs (· == "waited") (fun name => name == "follow-file" || name == writeJob)
              #["mine", "waited", "save-file", "follow-file", "working-set-write", writeJob,
                "waited"] ==
            3 },
    { name :=
        "a change of how many other jobs run starts no write of the index; the next write another change starts lists the count, and so does the one after it ends"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let quiet := drained begun
            let started := keysFed (withRunning #[] quiet (otherJobs := 2)) idle
            let typed := drained (keysFed (drained started) (typing "a"))
            let ended := keysFed (withRunning #[] typed) idle
            let typedAgain := drained (keysFed (drained ended) (typing "b"))
            (indexOf quiet 1).map (·.otherJobs) == some 0 && pendingNamed started writeJob == 0 &&
              (indexOf (drained started) 1).map (·.otherJobs) == some 0 &&
              (indexOf typed 1).map (·.otherJobs) == some 2 &&
              pendingNamed ended writeJob == 0 &&
              (indexOf (drained ended) 1).map (·.otherJobs) == some 2 &&
              (indexOf typedAgain 1).map (·.otherJobs) == some 0 },
    { name :=
        "from an empty state directory the restore makes session/journals/, and typing gives a base at the first edit and then one record per event, which replay to the text"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let made := begun.jobs.files.directories.contains (journalsDirectory stateDirectory)
            let typedIn := keysFed begun (typing "abc")
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
            let typedIn := keysFed begun (typing "ab")
            let moved := keysFed typedIn "<ArrowLeft> <ArrowLeft> <ArrowRight>"
            (logOf typedIn 1 0 1).map (·.records.size) == some 1 &&
              (logOf moved 1 0 1).map (·.records.size) == some 1 },
    { name := "a save removes the journal of the file's buffer"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let edited := keysFed (opened begun "a.txt") "<Delete>"
            let index := indexNamed edited "a.txt"
            let saved := ran edited FilesApi.saveName
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
            let edited := keysFed (opened begun "a.txt") "<Delete>"
            let undone := keysFed edited "C-z"
            journalFiles edited != #[] && journalFiles undone == #[] },
    { name :=
        "past the bound a new generation is written, and the old one's files are removed after it; the live one replays to the text"
      run :=
        pure <|
          match driver (limit := 150) with
          | none => false
          | some begun =>
            let typedIn := keysFed begun (typing "abcdef")
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
            let typedIn := keysFed begun (typing "ab")
            let behind := forgotten typedIn EditorState.scratchName fun text => text.insert 0 "z"
            let after := keysFed behind (typing "c")
            (liveOf after 0).map (·.generation) == some 2 && journalFiles after == filesOf 0 2 &&
              journalText after 1 0 2 == textNamed after EditorState.scratchName },
    { name :=
        "a save while still modified gives a new generation whose header has the file's new stamp"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let edited := keysFed (opened begun "a.txt") "<Delete>"
            let index := indexNamed edited "a.txt"
            let saving := keysFed (invoked edited FilesApi.saveName) "<Delete>"
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
            let noted := keysFed (ran begun "test-note") (typing "n")
            let index := indexNamed noted "note"
            let closedNote := ran noted closeName [.str "note"]
            journalFiles noted == filesOf index 1 && journalFiles closedNote == #[] },
    { name := "read-only, excerpt and minibuffer buffers are never journalled"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let owned := ran begun "test-owned"
            let prompted := keysFed owned "C-x a b"
            journalFiles prompted == #[] && prompted.loop.state.prompt.isSome },
    { name := "with no state directory nothing is journalled"
      run :=
        pure <|
          match driver (state := none) with
          | none => false
          | some begun =>
            let typedIn := keysFed begun (typing "abc")
            journalFiles typedIn == #[] && (indexOf typedIn 1).isNone },
    { name := "a leave removes this run's journals and saves its index saying ended"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let typedIn := drained (keysFed begun (typing "abc"))
            let left := ran typedIn Quit.name
            journalFiles typedIn != #[] && left.stopped && journalFiles left == #[] &&
              (indexOf left 1).map (·.ended) == some true },
    { name := "the index write fires once for a burst of changes, and writes the state at its end"
      run :=
        pure <|
          match driver with
          | none => false
          | some begun =>
            let written := drained begun
            let burst := keysFed written (typing "abc")
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
            let lines :=
              keysFed begun "C-b o n e RET t w o RET t h r e e RET f o u r C-e <ArrowLeft>"
            let split := ran lines Test.Windows.splitName
            let views := split.loop.state.frame.windows
            match views[0]?, views[1]? with
            | some first, some second =>
              let placed :=
                ran
                  (ran split "test-place"
                    [.nat first.index, .nat 0, .nat 1, .nat 1, .nat 2, .nat 0])
                  "test-place" [.nat second.index, .nat 2, .nat 0, .nat 3, .nat 3, .nat 1]
              let third := ran placed Test.Windows.splitName
              let focused := third.loop.state.frame.focused
              let opened :=
                drained (invoked third FilesApi.openFileName [.str (root / "a.txt").toString])
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

namespace OrderFailureTest

/-- An append to the log `/state/a.log`. -/
def appendOrder : Order :=
  { request := .append "/state/a.log" "x".toUTF8 }

/-- A remove of the base `/state/b.base`. -/
def removeOrder : Order :=
  { request := .remove "/state/b.base" }

/-- A save of the snapshot 3 as `/state/c.base`, whatever is there, which
releases it. -/
def saveOrder : Order :=
  { request := .save (.snapshot ⟨3⟩) "/state/c.base" .whatever, release := some ⟨3⟩ }

end OrderFailureTest

open OrderFailureTest in
/-- The checks of a journal order's path and failure (`Restore.Order.path`,
`Restore.Order.failed`, `Editor/Restore.lean`), pure. -/
def orderFailureChecks : List Check :=
  [{  name := "an append order's path is its log's, and a refusal of it says that path and why"
      run :=
        pure <|
          appendOrder.path == "/state/a.log" &&
            appendOrder.failed (.error .notFound : Except FileError Unit) ==
              some ("/state/a.log", "nothing is at the path") &&
            appendOrder.failed (.ok () : Except FileError Unit) == none },
    { name := "a remove order's path is its file's, and a refusal of it says that path and why"
      run :=
        pure <|
          removeOrder.path == "/state/b.base" &&
            removeOrder.failed (.error .denied : Except FileError Unit) ==
              some ("/state/b.base", "the file system does not allow it") &&
            removeOrder.failed (.ok () : Except FileError Unit) == none },
    { name :=
        "a save order's path is the file it writes, and a refusal of it says that path and why"
      run :=
        pure <|
          saveOrder.path == "/state/c.base" &&
            saveOrder.failed (.error .noSuchSnapshot : Except FileError File.Stamp) ==
              some ("/state/c.base", "the save names no snapshot") &&
            saveOrder.failed
                (.ok { seconds := 1, nanoseconds := 2, size := 3 } : Except FileError File.Stamp) ==
              none },
    { name := "an order the reconciler never makes has no path"
      run := pure <| ({ request := .stamp "/state/d.log" } : Order).path == "" }]

end ModelTest
