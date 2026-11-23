import Editor.Bound
import Editor.Headless.Journal
import Editor.Job.Runner

/-!
# The contract of the session journal's port

What every adapter of the journal's port (`Editor/Headless/Journal.lean`)
keeps, as a list of properties over a `JournalRig`: the rig gives the
journal, a directory that is there, how to read and put a file's bytes,
how to publish a text for a save to name, how to step the journal's work,
and how to hold that work until the rig lets it go. The same list runs two
ways:

- over the recording fake (`RecordingJournal`,
  `Editor/Headless/Journal/Fake.lean`), by `model-test`
  (`ModelTest.journalContractChecks`), on the model of files, held simply
  by not stepping it;
- over the real journal (`Journal.real`,
  `Editor/Headless/Journal/Real.lean`), by `contract-test`
  (`ContractTest.journalContractChecks`), on real files in a temporary
  directory, held by the file service's in-process hold.

**A deadline here is a hang guard, never a result**: a drain's task is
awaited with `Job.awaitWithin` under `patience`, and one not ended within
it is reported as a hang. That a drain has *not* ended while the work is
held is read once, with `IO.hasFinished`, while the rig holds it: nothing
can work the order then, so a drain that ends before its orders are worked
is seen every time.

This module imports the port and the runner's waits only: no `Lean` and no
`Ffi`, so the fake's run links into `model-test`, which links no Rust
library. The list is plain data.

## Where an addition goes

A new promise of the port is a `Property` here, added to `properties`; both
runners run it, so the fake cannot promise what the real journal does not
keep.
-/

namespace Editor.Headless.JournalContract

open Editor.Job

/-- The guard of a drain's end, which must come; only a hang reaches it, and
the property then fails as a hang. -/
def patience : HangGuard :=
  .on "the journal's drain" 10000

/-- A journal as the contract runs it. -/
structure JournalRig where
  /-- Which adapter, as a failure names it. -/
  name : String
  /-- The journal. -/
  journal : Journal
  /-- A directory that is there, which the properties write in, each under
  names of its own. -/
  directory : System.FilePath
  /-- The bytes of the file at a path, or `none` when no file is there. -/
  read : System.FilePath → IO (Option ByteArray)
  /-- Puts a file with these bytes at a path, outside the journal. -/
  put : System.FilePath → ByteArray → IO Unit
  /-- Publishes a text for a save to name, and gives its id. -/
  snapshotOf : String → IO SnapshotId
  /-- Works what the journal was handed: the fake's `stepAll`; nothing for
  the real journal, whose service works by itself. -/
  step : IO Unit
  /-- Holds the journal's work from now on, so nothing handed to it is
  worked until the rig lets it go, and gives back how to let it go. -/
  held : IO (IO Unit)

/-- One property of the port: whether it holds on a rig, or why not,
thrown. -/
structure Property where
  /-- What must hold, as a sentence. -/
  name : String
  /-- Observes it on a rig. -/
  holds : JournalRig → IO Bool

/-- What a drain's task came to, or a hang thrown when it has not ended
within `patience`. -/
def awaitDrain (task : Task Bool) : IO Bool := do
  let some ended ←
    awaitWithin patience
        task | throw <| IO.userError s!"a hang: the journal's drain had not ended within {patience.ms} ms"
  return ended

/-- Asks a drain, steps, and awaits it: `true` when it ended `true`. -/
def JournalRig.drain (rig : JournalRig) : IO Bool := do
  let task ← rig.journal.drained
  rig.step
  awaitDrain task

/-- What a file's bytes are, said for a failure. -/
def shown (bytes : Option ByteArray) : String :=
  match bytes with
  | none => "none"
  | some bytes => (String.fromUTF8? bytes).getD s!"{bytes.size} bytes"

/-- The bytes `text` is as a file. -/
def bytes (text : String) : ByteArray :=
  text.toUTF8

/-- J1: every order handed before a drain is worked by its end, in the
order handed. -/
def inOrder : Property where
  name :=
    "every order handed before a drain has been worked, in the order handed, once the drain ends true: a save, two appends after each other, a remove of a file there, a save then a remove, a remove then a save"
  holds rig := do
    let base := rig.directory / "b"
    let log := rig.directory / "l"
    let stale := rig.directory / "stale"
    let x := rig.directory / "x"
    let y := rig.directory / "y"
    rig.put stale (bytes "stale")
    let snapshot ← rig.snapshotOf "base"
    let orders : Array Restore.Order :=
      #[{ request := .save (.snapshot snapshot) base .whatever },
        { request := .append log (bytes "header;") }, { request := .append log (bytes "record;") },
        { request := .remove stale }, { request := .save (.snapshot snapshot) x .whatever },
        { request := .remove x }, { request := .remove y },
        { request := .save (.snapshot snapshot) y .whatever }]
    for order in orders do
      rig.journal.perform order
    let ended ← rig.drain
    let seen := (← rig.read base, ← rig.read log, ← rig.read stale, ← rig.read x, ← rig.read y)
    let expected :=
      (some (bytes "base"), some (bytes "header;record;"), none, none, some (bytes "base"))
    unless ended && seen == expected do
      throw <|
          IO.userError
            s!"{rig.name}: the drain ended {ended}; the base, the log, the stale file, x and y were {shown seen.1}, {shown seen.2.1}, {shown seen.2.2.1}, {shown seen.2.2.2.1}, {shown seen.2.2.2.2}"
    return true

/-- J2: a drain asked while the work is held has not ended; let go, it ends
true with the order worked. -/
def heldDrain : Property where
  name :=
    "a drain asked while the journal's work is held has not ended while it is held; let go, it ends true and the order handed before it has been worked"
  holds rig := do
    let gone := rig.directory / "held"
    rig.put gone (bytes "held")
    let release ← rig.held
    rig.journal.perform { request := .remove gone }
    let task ← rig.journal.drained
    let early ← IO.hasFinished task
    release
    rig.step
    let ended ← awaitDrain task
    let there := (← rig.read gone).isSome
    unless !early && ended && !there do
      throw <|
          IO.userError
            s!"{rig.name}: while held the drain had {if early then "ended" else "not ended"}; let go it ended {ended}, and the file was {if there then "there" else "gone"}"
    return true

/-- J3: a drain with nothing handed ends true. -/
def emptyDrain : Property where
  name := "a drain with nothing handed since the last ends true"
  holds rig := do
    discard <| rig.drain
    let ended ← rig.drain
    unless ended do
      throw <| IO.userError s!"{rig.name}: an empty drain ended false"
    return true

/-- J4: an order that fails is said by `failures` once, with its path. -/
def failureOnce : Property where
  name :=
    "an order that fails is said by the journal's failures once the drain after it ends, with its path, oldest first, and a second take says nothing"
  holds rig := do
    discard <| rig.drain
    discard <| rig.journal.failures
    let first := rig.directory / "none" / "first"
    let second := rig.directory / "none" / "second"
    rig.journal.perform { request := .append first (bytes "x") }
    rig.journal.perform { request := .append (rig.directory / "fine") (bytes "y") }
    rig.journal.perform { request := .append second (bytes "z") }
    let ended ← rig.drain
    let said := (← rig.journal.failures).map (·.1)
    let again ← rig.journal.failures
    unless ended && said == #[first.toString, second.toString] && again.isEmpty do
      throw <|
          IO.userError
            s!"{rig.name}: the drain ended {ended}; the failures said {said}, and then {again.map (·.1)}"
    return true

/-- The properties, in the order they run. -/
def properties : List Property :=
  [inOrder, heldDrain, emptyDrain, failureOnce]

end Editor.Headless.JournalContract
