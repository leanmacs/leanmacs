import ContractTest.Check
import Editor.Api
import Editor.Ffi.Files
import Editor.Files.Compiled
import Editor.InputScheme.Test
import Editor.Loop
import Editor.Restore.Compiled
import Editor.Test.Linked.Rig
import Editor.Text.Model

/-!
# Contract tests: `Editor/Restore/Run.lean`

The tests of session restore over the real bindings: `restoreRunChecks`,
with the library's text store and file service in a temporary directory,
through a restart: typing is journalled by the file service, unobserved,
and a second loop restores it; and two tabs, the first split, come back.

A restore check's directory is removed only once its journal has drained
(`withJournalledDirectory`, over the checks' `Journal` port): the second
loop hands the stale index's remove to the file service as its last order,
unobserved, and nothing else waits for it, so without the drain that remove
can land while the directory is being removed, which then fails. The first
check pins the drain with a journal that holds its orders (`HeldJournal`).
-/

namespace ContractTest

open Editor
open Editor.Test.Linked

/-- The jobs of the restore checks: the file commands' and the restore
package's, as a host registers them. -/
def restoreJobs : Array Config.JobRegistration :=
  Files.package.registered.jobs ++ Restore.package.registered.jobs

/-- The commands of the checks beside those: `start-restore` starts the job
`restore` with its argument, as a host's first request does; `type-text`
inserts its argument at the window's cursors; `split-and-tab` splits the
window and opens a second tab on its buffer, named `two`. -/
def restoreExtras : Array Config.Registration :=
  #[{ name := "start-restore"
      action :=
        .call fun call => do
          let .str state :: _ := call.arguments | return
          discard <| startJob Restore.restoreJob [.str state] },
    { name := "type-text"
      action :=
        .call fun call => do
          let .str text :: _ := call.arguments | return
          discard <| call.target.window.id.insertAtSelections text },
    { name := "split-and-tab"
      action :=
        .call fun call => do
          discard <| call.target.window.id.split
          discard <| call.target.window.id.newTab
          discard <| changeTab (.rename 1 (some "two")) }]

/-- The keys of the checks: none bound; the commands by name; the jobs
registered. -/
def restoreKeys : Loop.Keys TestScheme.scheme :=
  { command? := fun name =>
      ((Files.package.registered.commands ++ Restore.package.registered.commands ++
                restoreExtras).find?
            (·.name == name)).bind
        fun registration =>
        match registration.action with
        | .call run =>
          some fun call => do
            run call
            return none
        | _ => none
    registered := { jobs := fun name => restoreJobs.any (·.name == name) } }

/-- Hands `order` to the library's file service, unobserved, as a host's
journal does (`Headless.Journal.real`, which the host's checks run): the
hosts' module reaches the elaborator, which this executable does not link. -/
def performOrder (rig : ProjectRig) (order : Restore.Order) : IO Unit := do
  match order.request with
  | .append path bytes =>
    discard <| Ffi.filesAppendUnobserved path.toString bytes
  | .remove path =>
    discard <| Ffi.filesRemoveUnobserved path.toString
  | .save (.snapshot id) path _ =>
    if let some snapshot← rig.published.reader.find? id then
      discard <| Ffi.filesSaveUnobserved snapshot path.toString
  | _ =>
    pure ()

/-- What a restore check hands the journal's orders to, and how it waits
until every order handed is worked. -/
structure Journal where
  /-- Hands one order to be worked, without waiting for it. -/
  perform : Restore.Order → IO Unit
  /-- Waits until every order handed to `perform` has been worked; `false`
  if that does not happen within `patience`. -/
  drained : IO Bool

/-- Whether the library's file service holds no request within `patience`:
it works requests in order, so every order handed to it has been worked. -/
def filesDrained : IO Bool :=
  eventually (return (← Ffi.filesPending) == 0)

/-- The checks' journal over the library's file service, as a host's. -/
def Journal.real (rig : ProjectRig) : Journal :=
  { perform := performOrder rig
    drained := filesDrained }

/-- A journal that holds every order handed to it until `drained`, which
works them in order on the real filesystem, logging `worked <kind> <path>`
for each: an order in flight for as long as a check wants. -/
structure HeldJournal where
  /-- The orders handed and not yet worked. -/
  held : IO.Ref (Array Restore.Order)
  /-- What `drained` worked, in order. -/
  events : IO.Ref (Array String)

/-- A held journal holding nothing, having worked nothing. -/
def HeldJournal.new : IO HeldJournal :=
  return { held := ← IO.mkRef #[], events := ← IO.mkRef #[] }

/-- The `Journal` port over `held`. -/
def HeldJournal.journal (held : HeldJournal) : Journal :=
  { perform := fun order => held.held.modify (·.push order)
    drained := do
      for order in ← held.held.swap #[] do
        match order.request with
        | .remove path =>
          IO.FS.removeFile path
          held.events.modify (·.push s!"worked remove {path}")
        | .append path bytes =>
          let handle ← IO.FS.Handle.mk path .append
          handle.write bytes
          held.events.modify (·.push s!"worked append {path}")
        | _ =>
          pure ()
      return true }

/-- Runs `body` in a fresh temporary directory, then waits for the journal
to drain (`drained`) before the directory is removed, even when `body`
throws, so no order the body handed out lands during the removal. `true`
only when `body` held and the journal drained. -/
def withJournalledDirectory (drained : IO Bool) (body : System.FilePath → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    let emptied ← IO.mkRef false
    let held ←
      tryFinally (body directory)
          (do
            emptied.set (← drained))
    return held && (← emptied.get)

/-- The loop of a host started fresh over `rig`, with `state` as its state
directory, once each of `invocations` has run and settled, the journal's
orders handed to the library's file service. -/
def runRestoring (rig : ProjectRig) (state : System.FilePath) (invocations : List Invocation) :
    IO (Option (Loop TestScheme.scheme × RealTexts)) := do
  let begin : EditorM (Loop TestScheme.scheme) := do
    let loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
    return { loop with state := loop.state.hostedBy "/" none (some state) }
  let (started, texts) ← begin.runReal (RealTexts.over rig.published) rig.display
  let .ok loop := started | return none
  runSettledFrom rig loop texts invocations restoreKeys restoreJobs (journal :=
      (Journal.real rig).perform)

/-- The checks of session restore over the real bindings, in a directory of
their own, temporary. -/
def restoreRunChecks (services : Job.Services) : List Check :=
  [{  name :=
        "a restore check's state directory is removed only once every order its journal handed out has been worked: a stale index's remove still held when the body ends is worked before the directory goes, and the directory is gone after"
      run := do
        let journal ← HeldJournal.new
        let used ← IO.mkRef (none : Option System.FilePath)
        let held ←
          withJournalledDirectory journal.journal.drained fun directory => do
              let session := directory / "state" / "session"
              IO.FS.createDirAll session
              IO.FS.writeFile (session / "session-1.json") "{}"
              IO.FS.writeFile (session / "session-2.json") "{}"
              journal.journal.perform { request := .remove (session / "session-1.json") }
              used.set (some directory)
              return true
        let some directory ← used.get | return false
        let events ← journal.events.get
        let left ← journal.held.get
        let gone := !(← directory.pathExists)
        let expected := #[s!"worked remove {directory / "state" / "session" / "session-1.json"}"]
        unless held && events == expected && gone && left.isEmpty do
          throw <|
              IO.userError
                s!"the scaffold returned {held}, worked {events}, left the directory {if gone then "gone" else "there"} and {left.size} orders held"
        return true },
    { name :=
        "typing in a file's buffer is journalled by the library's file service, the base and the log on disk replaying to the text; a second loop over the same state directory, with no shutdown between, restores the buffer modified, at its file"
      run :=
        withJournalledDirectory filesDrained fun directory => do
          let state := directory / "state"
          let a := directory / "a.txt"
          IO.FS.writeFile a "first line\nsecond line\n"
          let rig ← ProjectRig.over services
          let some (typed, texts) ←
            runRestoring rig state
                [{ command := "start-restore", arguments := [.str state.toString] }, openFile a,
                  { command := "type-text", arguments := [.str "typed "] },
                  { command := "type-text", arguments := [.str "more "] }] | return false
          -- The journal's writes are unobserved: they are done once the
          -- service holds no request.
          unless ← eventually (return (← Ffi.filesPending) == 0) do
            return false
          let edited ← bufferText rig texts typed "a.txt"
          let some index := typed.state.findFile a | return false
          let some live :=
            typed.state.restore.journals.find? (·.buffer == index.index) | return false
          let base ← IO.FS.readBinFile (Restore.basePath state 1 index.index live.generation)
          let log ← IO.FS.readBinFile (Restore.logPath state 1 index.index live.generation)
          let decoded := Restore.Journal.decode (File.decodeBytes log)
          let replayed : TextM String := do
            let text ← createText (File.decodeBytes base)
            discard <| Restore.Journal.replay text decoded.records
            text.read
          let fromDisk := (replayed.runModel {}).1.toOption
          let fresh ← ProjectRig.over services
          let some (restored, freshTexts) ←
            runRestoring fresh state
                [{ command := "start-restore", arguments := [.str state.toString] }] | return false
          let again ← bufferText fresh freshTexts restored "a.txt"
          let buffer := (restored.state.findFile a).bind restored.state.buffer?
          return edited == some "typed more first line\nsecond line\n" && fromDisk == edited &&
              decoded.records.size == 1 &&
              again == edited &&
              (buffer.map Buffer.isModified) == some true &&
              restored.state.restore.run == some 2 },
    { name :=
        "two tabs, the first split, are restored on the real text binding and file service: a second loop over the same state directory has both tabs, the split, the second tab's name, and every window on the file's buffer"
      run :=
        withJournalledDirectory filesDrained fun directory => do
          let state := directory / "state"
          let a := directory / "a.txt"
          IO.FS.writeFile a "first line\nsecond line\n"
          let rig ← ProjectRig.over services
          let some (split, _) ←
            runRestoring rig state
                [{ command := "start-restore", arguments := [.str state.toString] }, openFile a,
                  { command := "type-text", arguments := [.str "typed "] },
                  { command := "split-and-tab" }] | return false
          unless ← eventually (return (← Ffi.filesPending) == 0) do
            return false
          let fresh ← ProjectRig.over services
          let some (restored, _) ←
            runRestoring fresh state
                [{ command := "start-restore", arguments := [.str state.toString] }] | return false
          let frame := restored.state.frame
          let shows (state : EditorState) : Array String :=
            state.windows.filterMap fun window => (state.buffer? window.buffer).map (·.name)
          return split.state.frame.tabs.size == 2 && frame.tabs.size == 2 &&
              frame.windows.size == 2 &&
              frame.tabsAfter.map (·.name) == #[some "two"] &&
              shows restored.state == #["a.txt", "a.txt", "a.txt"] &&
              restored.state.wellFormed }]

end ContractTest
