import ContractTest.Check
import Editor.Api
import Editor.Ffi.Files
import Editor.InputScheme.Test
import Editor.Loop
import Editor.Test.Linked.Rig
import Editor.Test.Restore
import Editor.Text.Model
import FilesApiTest.Fake

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
two checks run one contract of the port (`drainsBeforeRemoval`) on the
journal that holds its orders (`HeldJournal`) and on the real one
(`Journal.real`), whose drain is what keeps the race out; the real case holds
the file service's worker on a gate until the drain first reads the service's
pending count, so a drain that does not wait finds the remove unworked every
time. The third pins the drain when the body throws; the fourth that a
journal that does not drain fails the check.
-/

namespace ContractTest

open Editor
open Editor.Test.Linked

/-- The jobs of the restore checks: `files-api`'s fake's and the restore
package's, as a host registers them. -/
def restoreJobs : Array Config.JobRegistration :=
  FilesApiTest.fake.registered.jobs ++ Test.Restore.package.registered.jobs

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
      ((FilesApiTest.fake.registered.commands ++ Test.Restore.package.registered.commands ++
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

/-- Whether the library's file service holds no request within `patience`,
reading how many it holds with `pending` (the service's own count, unless a
check gates it): it works requests in order, so every order handed to it has
been worked. -/
def filesDrained (pending : IO UInt64 := Ffi.filesPending) : IO Bool :=
  eventually (return (← pending) == 0)

/-- The checks' journal over the library's file service, as a host's; its
drain reads the service's pending count with `pending`. -/
def Journal.real (rig : ProjectRig) (pending : IO UInt64 := Ffi.filesPending) : Journal :=
  { perform := performOrder rig
    drained := filesDrained pending }

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

/-- The contract of the `Journal` port, which `HeldJournal.journal` and
`Journal.real` both keep: run under `withJournalledDirectory`, a remove the
body hands out for a file that exists is worked by the time `drained`
returns, before the directory goes, and the journal then holds nothing. The
scaffold returns true, nothing throws, and the directory is gone after.

`hold` runs in the directory before the remove is handed out (the real case
holds the file service's worker with it); `left` counts what the journal
still holds, read as `drained` returns; `settle` runs after that read, before
the directory goes, so a failing journal still leaves nothing in flight.
Throws, saying what it saw, when the property fails. -/
def drainsBeforeRemoval (journal : Journal) (hold : System.FilePath → IO Unit) (left : IO Nat)
    (settle : IO Unit) : IO Bool := do
  let used ← IO.mkRef (none : Option System.FilePath)
  let seen ← IO.mkRef (none : Option (Bool × Nat))
  let drained := do
    let emptied ← journal.drained
    if let some directory← used.get then
      seen.set (some (← (directory / "session-1.json").pathExists, ← left))
    settle
    return emptied
  let held ←
    withJournalledDirectory drained fun directory => do
        let stale := directory / "session-1.json"
        IO.FS.writeFile stale "{}"
        hold directory
        journal.perform { request := .remove stale }
        used.set (some directory)
        return true
  let some directory ← used.get | return false
  let gone := !(← directory.pathExists)
  let some (there, count) ← seen.get | return false
  unless held && !there && count == 0 && gone do
    throw <|
        IO.userError
          s!"the scaffold returned {held}; when the drain returned the stale file was {if there then "there" else "gone"} and {count} orders were left; the directory was {if gone then "gone" else "there"} after"
  return true

/-- A gate that holds the library's file service's worker: `hold` makes a
named pipe in a directory and hands the service an append to it, which
blocks the worker opening the pipe until `release` opens it to read. The
service works in order, so nothing handed to it after `hold` is worked
before `release`. `release` is idempotent. -/
structure WorkerGate where
  /-- Makes the pipe in the directory and blocks the worker on it. -/
  hold : System.FilePath → IO Unit
  /-- Lets the worker go, once; nothing when the gate is not held. -/
  release : IO Unit

/-- A worker gate, not yet held. -/
def WorkerGate.new : IO WorkerGate := do
  let pipe ← IO.mkRef (none : Option System.FilePath)
  return {
      hold := fun directory => do
        let path := directory / "gate"
        let made ← IO.Process.output { cmd := "mkfifo", args := #[path.toString] }
        unless made.exitCode == 0 do
          throw <| IO.userError s!"mkfifo exited {made.exitCode}: {made.stderr}"
        unless ← Ffi.filesAppendUnobserved path.toString "gate".toUTF8 do
          throw <| IO.userError "the file service has no thread"
        pipe.set (some path)
      release := do
        if let some path← pipe.swap none then
          let handle ← IO.FS.Handle.mk path .read
          discard handle.readBinToEnd }

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
        "a restore check's state directory is removed only once every order its journal handed out has been worked, on the journal that holds its orders: a stale index's remove still held when the body ends is worked before the directory goes, and nothing is left held"
      run := do
        let journal ← HeldJournal.new
        drainsBeforeRemoval journal.journal (fun _ => pure ()) (return (← journal.held.get).size)
            (pure ()) },
    { name :=
        "a restore check's state directory is removed only once every order its journal handed out has been worked, on the real journal over the library's file service: with the service's worker held until the drain first reads the pending count, the stale index's remove is worked before the directory goes, and nothing is left pending"
      run := do
        let rig ← ProjectRig.over services
        let gate ← WorkerGate.new
        let pending := do
          gate.release
          Ffi.filesPending
        drainsBeforeRemoval (Journal.real rig pending) gate.hold (return (← Ffi.filesPending).toNat)
            (do
              gate.release
              discard <| filesDrained) },
    { name :=
        "a restore check's journal is drained even when its body throws: the scaffold rethrows the body's error, and a remove the body handed out before throwing is worked"
      run := do
        let journal ← HeldJournal.new
        let used ← IO.mkRef (none : Option System.FilePath)
        let outcome ←
          try
            discard <|
                withJournalledDirectory journal.journal.drained fun directory => do
                  let stale := directory / "session-1.json"
                  IO.FS.writeFile stale "{}"
                  journal.journal.perform { request := .remove stale }
                  used.set (some directory)
                  throw <| IO.userError "the body failed"
            pure "returned"
          catch error =>
            pure s!"threw {error}"
        let some directory ← used.get | return false
        let events ← journal.events.get
        let expected := #[s!"worked remove {directory / "session-1.json"}"]
        unless outcome == "threw the body failed" && events == expected do
          throw <| IO.userError s!"the scaffold {outcome} and worked {events}"
        return true },
    { name :=
        "a restore check whose journal does not drain fails: the scaffold returns false though its body held"
      run := do
        let stuck : Journal := { perform := fun _ => pure (), drained := return false }
        let held ← withJournalledDirectory stuck.drained fun _ => return true
        if held then
          throw <| IO.userError "the scaffold returned true though its journal did not drain"
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
