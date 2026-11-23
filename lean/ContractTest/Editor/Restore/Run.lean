import ContractTest.Check
import ContractTest.Support.FileHold
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
through a restart: typing is journalled by the file service, each order a
file request with a task of its reply (`Job.Services.fileWorked`), which the
checks drop, and a second loop restores it; and two tabs, the first split,
come back. The host's own journal hands its orders unobserved instead, for
its editor-thread cost (`Headless.Journal.real`, `docs/design/concurrency.md`,
"The session journal"); a check pays no such cost, so these hand theirs
through handles and read their own tasks, never a count of the service's.

A restore check's directory is removed only once its journal has drained
(`withJournalledDirectory`, over the checks' `Journal` port): the second
loop hands the stale index's remove to the file service as its last order,
and nothing else waits for it, so without the drain that remove can land
while the directory is being removed, which then fails with ENOENT. The
first two checks run one contract of the port (`drainsBeforeRemoval`) on the
journal that holds its orders (`HeldJournal`) and on the real one
(`Journal.real`), whose drain, a flush of the file service, is what keeps
the race out; the real case holds the file service's worker with its
in-process hold (`FileHold`) and releases it right after the drain asks for
its flush, so a drain that does not flush never releases it and finds the
remove unworked every time. That flush is the check's own signal, not an
inference: the worker is held, the drain asks its own flush, and what the
case reads as left is how many of the orders' tasks it handed have not
ended. The third pins the drain when the body throws; the fourth that a
journal that does not drain fails the check.

The typing and two-tabs restores wait on their own orders: `runRestoring`
keeps each order's task, and the wait before the second loop and the
directory's drain are `ownDrained`, a wait on those tasks, never on the
process-wide service. And the stale-index remove's order is forced
(`tabsHeldAtStaleRemove`): as the second loop hands it, the worker is held,
so it is queued behind the hold; the teardown's drain then runs, and what
it saw is read before the directory goes. On the flush and on the orders'
own tasks the remove has been worked when the drain returns; on the old
wait for the service's pending count, reconstructed (`pendingDrained`,
row W85 of `docs/dev-practices/inferred-waits.md`), the wait runs out with
the file still there and its remove unended, the order in which the
directory's removal met ENOENT under load
(`restore-contract-tabs-enoent-under-load`).
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

/-- What a restore check hands the journal's orders to, and how it waits
until every order handed is worked. -/
structure Journal where
  /-- Hands one order to be worked, without waiting for it, and returns the
  task of what it came to: `none` once worked, or its path and why it
  failed. A caller that does not need it drops it. -/
  perform : Restore.Order → IO (Task (Option (String × String)))
  /-- Waits until every order handed to `perform` has been worked; `false`
  if that does not happen within `patience`. -/
  drained : IO Bool

/-- Flushes the library's file service through `services`, runs `asked` once
the flush is asked, and says whether the flush was completed: the service
works requests in order, so every order handed to it before has been worked
by then. The wait is bounded by `patience` only as a guard against a hang. -/
def filesDrained (services : Job.Services) (asked : IO Unit := pure ()) : IO Bool := do
  let flushed ← services.flushed .files
  asked
  return (← Job.awaitWithin patience flushed) == some .completed

/-- The checks' journal over the library's file service: each order a file
request with a task of its reply (`Job.Services.fileWorked`), each task kept
in `handed`, oldest first; its drain is a flush of the service
(`filesDrained`), as the host's journal's is (`Headless.Journal.real`, whose
module reaches the elaborator, which this executable does not link), and
`asked` runs once the flush is asked. -/
def Journal.real (rig : ProjectRig) (handed : IO.Ref (Array (Task (Option (String × String)))))
    (asked : IO Unit := pure ()) : Journal :=
  { perform := fun order => do
      let worked ← rig.services.fileWorked order.request
      let task := worked.map (sync := true) order.failed
      handed.modify (·.push task)
      return task
    drained := filesDrained rig.services asked }

/-- How many of `handed`'s tasks have not ended, each read once. -/
def unended (handed : IO.Ref (Array (Task (Option (String × String))))) : IO Nat := do
  let tasks ← handed.get
  return (← tasks.filterM fun task => return !(← IO.hasFinished task)).size

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

/-- The `Journal` port over `held`. An order's task ends at once, saying
nothing: no check reads it, and what this journal holds is `held`. -/
def HeldJournal.journal (held : HeldJournal) : Journal :=
  { perform := fun order => do
      held.held.modify (·.push order)
      return .pure none
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
        discard <| journal.perform { request := .remove stale }
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

/-- Waits for every task of `handed` to end, each the reply of one order the
checks' journal handed (`Journal.real`): the orders' own handles, so this
waits on the check's own work and nothing else of the process's file
service. `false` if one has not ended within `patience`, which only a hang
reaches. -/
def ownDrained (handed : IO.Ref (Array (Task (Option (String × String))))) : IO Bool := do
  for task in ← handed.get do
    unless (← Job.awaitWithin patience task).isSome do
      return false
  return true

/-- The loop of a host started fresh over `rig`, with `state` as its state
directory, once each of `invocations` has run and settled, the journal's
orders handed to the library's file service through the checks' journal
(`wrap` of it), each order's task kept in `handed`, oldest first, for the
check to wait on (`ownDrained`). -/
def runRestoring (rig : ProjectRig) (state : System.FilePath) (invocations : List Invocation)
    (handed : IO.Ref (Array (Task (Option (String × String))))) (wrap : Journal → Journal := id) :
    IO (Option (Loop TestScheme.scheme × RealTexts)) := do
  let begin : EditorM (Loop TestScheme.scheme) := do
    let loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
    return { loop with state := loop.state.hostedBy "/" none (some state) }
  let (started, texts) ← begin.runReal (RealTexts.over rig.published) rig.display
  let .ok loop := started | return none
  let journal := wrap (Journal.real rig handed)
  runSettledFrom rig loop texts invocations restoreKeys restoreJobs (journal := fun order =>
      discard <| journal.perform order)

/-- Two tabs, the first split, typed into and restored in `directory`: a
first loop over the state directory, a wait on its orders' own tasks, then
a second loop over the same state directory, whose journal is `wrap` of the
checks' journal; every order's task kept in `handed`. Whether the second
loop has both tabs, the split, the second tab's name, and every window on
the file's buffer. -/
def twoTabsRestored (services : Job.Services) (directory : System.FilePath)
    (handed : IO.Ref (Array (Task (Option (String × String))))) (wrap : Journal → Journal := id) :
    IO Bool := do
  let state := directory / "state"
  let a := directory / "a.txt"
  IO.FS.writeFile a "first line\nsecond line\n"
  let rig ← ProjectRig.over services
  let some (split, _) ←
    runRestoring rig state
        [{ command := "start-restore", arguments := [.str state.toString] }, openFile a,
          { command := "type-text", arguments := [.str "typed "] }, { command := "split-and-tab" }]
        handed | return false
  unless ← ownDrained handed do
    return false
  let fresh ← ProjectRig.over services
  let some (restored, _) ←
    runRestoring fresh state [{ command := "start-restore", arguments := [.str state.toString] }]
        handed wrap | return false
  let frame := restored.state.frame
  let shows (state : EditorState) : Array String :=
    state.windows.filterMap fun window => (state.buffer? window.buffer).map (·.name)
  return split.state.frame.tabs.size == 2 && frame.tabs.size == 2 && frame.windows.size == 2 &&
      frame.tabsAfter.map (·.name) == #[some "two"] &&
      shows restored.state == #["a.txt", "a.txt", "a.txt"] &&
      restored.state.wellFormed

/-- How `tabsHeldAtStaleRemove`'s teardown waits for the journal before the
directory goes. -/
inductive TabsDrain where
  /-- A flush of the file service (`filesDrained`), the hold let go once
  the flush is asked. -/
  | flush
  /-- Every order's own task (`ownDrained`), the hold let go as the wait
  begins. -/
  | ownTasks
  /-- The old wait, reconstructed for this check alone: the service's
  pending count read until it is 0 (`pendingDrained`). Nothing in it asks
  for work, so it never lets the hold go. -/
  | pendingCount
  deriving Repr

/-- What `tabsHeldAtStaleRemove` saw. -/
structure TabsSeen where
  /-- Whether the hold was taken as the stale index's remove was handed:
  false means the order was never met, and the check would be vacuous. -/
  held : Bool
  /-- What the drain returned. -/
  drained : Bool
  /-- Whether the stale index was there when the drain returned. -/
  there : Bool
  /-- Whether the stale index's remove's task had ended then. -/
  removeEnded : Bool
  deriving DecidableEq, Repr

-- inferred-waits W85: stays (the reconstruction's subject is the count)
set_option linter.inferredWait false in
/-- The old drain of the restore checks, reconstructed for
`tabsHeldAtStaleRemove` alone: the file service's pending count read once a
round until it reads 0, which treated its bound as a result. With the
worker held it never reads 0, so it runs out its bound and says `false`,
the remove still queued. -/
def pendingDrained : IO Bool := do
  let deadline ← (HangGuard.held "the file worker, held until a flush is asked" 200).deadline
  repeat
    if (← Ffi.filesPending) == 0 then
      return true
    if ← deadline.expired then
      return false
    RealTime.sleep (.under "the old drain's poll, reconstructed" 1)
  return false

/-- Two tabs restored (`twoTabsRestored`) with the second loop's last order,
the remove of the first run's index (`Kept.staleIndexes`), held: as the
checks' journal is handed it, the file service's worker is held first
(`FileHold`), so the remove is queued behind the hold. Then the directory's
teardown waits as `drain` says, and what it saw is read before the
directory goes: whether the stale index was there and whether its remove's
task had ended. After that read the hold is let go and the service flushed,
so the directory is removed with nothing in flight whatever `drain` did:
the order the restore checks' ENOENT came from is forced every time, and
never raced. -/
def tabsHeldAtStaleRemove (services : Job.Services) (drain : TabsDrain) : IO TabsSeen := do
  let handed ← IO.mkRef #[]
  let hold ← IO.mkRef (none : Option FileHold)
  let removed ← IO.mkRef (none : Option (Task (Option (String × String))))
  let used ← IO.mkRef (none : Option System.FilePath)
  let seen ← IO.mkRef (none : Option (Bool × Bool × Bool))
  let scenario ← IO.mkRef false
  let release := do
    if let some held← hold.get then
      held.release
  let drained : IO Bool := do
    let ended ←
      match drain with
      | .flush =>
        filesDrained services (asked := release)
      | .ownTasks =>
        do
          release
          ownDrained handed
      | .pendingCount =>
        pendingDrained
    if let some directory← used.get then
      let there ← (Restore.indexPath (directory / "state") 1).pathExists
      let removeEnded ←
        match ← removed.get with
        | some task =>
          IO.hasFinished task
        | none =>
          pure false
      seen.set (some (ended, there, removeEnded))
    release
    discard <| filesDrained services
    return ended
  let wrap (journal : Journal) : Journal :=
    { journal with
      perform := fun order => do
        if let some directory← used.get then
          if order.request == .remove (Restore.indexPath (directory / "state") 1) then
            hold.set (some (← FileHold.hold services.completions))
            let task ← journal.perform order
            removed.set (some task)
            return task
        journal.perform order }
  discard <|
      withJournalledDirectory drained fun directory => do
        used.set (some directory)
        let restored ← twoTabsRestored services directory handed wrap
        scenario.set restored
        return restored
  let some directory ← used.get | throw <| IO.userError "the scenario never ran"
  let restored ← scenario.get
  let gone := !(← directory.pathExists)
  unless restored && gone do
    throw <|
        IO.userError
          s!"the two tabs were {if restored then "" else "not "}restored, and the directory was {if gone then "gone" else "there"} after"
  let some (drained, there, removeEnded) ← seen.get | throw <| IO.userError "the drain never ran"
  return { held := (← hold.get).isSome, drained, there, removeEnded }

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
        "a restore check's state directory is removed only once every order its journal handed out has been worked, on the real journal over the library's file service: with the service's worker held until the drain has asked for its flush, the stale index's remove is worked before the directory goes, and no order's task is left unended"
      run := do
        let rig ← ProjectRig.over services
        let held ← IO.mkRef (none : Option FileHold)
        let release := do
          if let some hold← held.get then
            hold.release
        let hold (_ : System.FilePath) := do
          held.set (some (← FileHold.hold services.completions))
        let handed ← IO.mkRef #[]
        drainsBeforeRemoval (Journal.real rig handed release) hold (unended handed)
            (do
              release
              discard <| filesDrained services) },
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
                  discard <| journal.journal.perform { request := .remove stale }
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
        let stuck : Journal := { perform := fun _ => pure (.pure none), drained := return false }
        let held ← withJournalledDirectory stuck.drained fun _ => return true
        if held then
          throw <| IO.userError "the scaffold returned true though its journal did not drain"
        return true },
    { name :=
        "typing in a file's buffer is journalled by the library's file service, the base and the log on disk replaying to the text; a second loop over the same state directory, with no shutdown between, restores the buffer modified, at its file"
      run := do
        let handed ← IO.mkRef #[]
        withJournalledDirectory (ownDrained handed) fun directory => do
            let state := directory / "state"
            let a := directory / "a.txt"
            IO.FS.writeFile a "first line\nsecond line\n"
            let rig ← ProjectRig.over services
            let some (typed, texts) ←
              runRestoring rig state
                  [{ command := "start-restore", arguments := [.str state.toString] }, openFile a,
                    { command := "type-text", arguments := [.str "typed "] },
                    { command := "type-text", arguments := [.str "more "] }]
                  handed | return false
            -- The journal's writes are done once each order's own task has
            -- ended.
            unless ← ownDrained handed do
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
                  [{ command := "start-restore", arguments := [.str state.toString] }]
                  handed | return false
            let again ← bufferText fresh freshTexts restored "a.txt"
            let buffer := (restored.state.findFile a).bind restored.state.buffer?
            return edited == some "typed more first line\nsecond line\n" && fromDisk == edited &&
                decoded.records.size == 1 &&
                again == edited &&
                (buffer.map Buffer.isModified) == some true &&
                restored.state.restore.run == some 2 },
    { name :=
        "two tabs, the first split, are restored on the real text binding and file service: a second loop over the same state directory has both tabs, the split, the second tab's name, and every window on the file's buffer"
      run := do
        let handed ← IO.mkRef #[]
        withJournalledDirectory (ownDrained handed) fun directory =>
            twoTabsRestored services directory handed },
    { name :=
        "two tabs restored, the second loop's stale-index remove held behind the file service's worker, on the flush the restore checks drained with: the hold is taken, and when the drain returns the stale index is gone and its remove's task has ended; the directory is gone after"
      run := do
        let seen ← tabsHeldAtStaleRemove services .flush
        unless seen == { held := true, drained := true, there := false, removeEnded := true } do
          throw <| IO.userError s!"saw {repr seen}"
        return true },
    { name :=
        "two tabs restored, the second loop's stale-index remove held behind the file service's worker, on the orders' own tasks: the hold is taken, and when the drain returns the stale index is gone and its remove's task has ended; the directory is gone after"
      run := do
        let seen ← tabsHeldAtStaleRemove services .ownTasks
        unless seen == { held := true, drained := true, there := false, removeEnded := true } do
          throw <| IO.userError s!"saw {repr seen}"
        return true },
    { name :=
        "two tabs restored, the second loop's stale-index remove held behind the file service's worker, on the old wait for the service's pending count, reconstructed: the hold is taken, and the wait runs out with the stale index still there and its remove's task unended, the order the directory's removal met with ENOENT"
      run := do
        let seen ← tabsHeldAtStaleRemove services .pendingCount
        unless seen == { held := true, drained := false, there := true, removeEnded := false } do
          throw <| IO.userError s!"saw {repr seen}"
        return true }]

end ContractTest
