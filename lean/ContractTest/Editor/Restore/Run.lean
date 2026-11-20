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
and a second loop restores it.
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
inserts its argument at the window's cursors. -/
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
          discard <| call.target.window.id.insertAtSelections text }]

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
  runSettledFrom rig loop texts invocations restoreKeys restoreJobs (journal := performOrder rig)

/-- The checks of session restore over the real bindings, in a directory of
their own, temporary. -/
def restoreRunChecks (services : Job.Services) : List Check :=
  [{  name :=
        "typing in a file's buffer is journalled by the library's file service, the base and the log on disk replaying to the text; a second loop over the same state directory, with no shutdown between, restores the buffer modified, at its file"
      run :=
        IO.FS.withTempDir fun directory => do
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
              restored.state.restore.run == some 2 }]

end ContractTest
