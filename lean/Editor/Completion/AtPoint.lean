import Editor.Completion

/-!
# At-point sources

What is asked when completion is wanted at a position of a buffer, as
Emacs's `completion-at-point` asks `completion-at-point-functions`: an
at-point source. It is an interface like a completion source
(`Editor/Completion.lean`), with a pure model (`AtPoint.fixed`), a fake for
tests (`AtPoint.refusing`, `Editor/Completion/Fake.lean`) and a contract
every at-point source is held to (`Editor/Completion/AtPointContract.lean`).

## An at-point source

- **A name**, which it is registered under and which a mode's list names
  it by (`Mode.atPoint`, `Editor/Mode.lean`).
- **A function from a spot to a region** (`Spot`, `Region`,
  `Editor/Completion/Candidate.lean`): asked with the view, the cursor's
  byte offset and why it is asked (`Occasion`), it answers nothing, or the
  region of the text to replace, which holds the offset, and the sources
  to complete it from. It is a program over the editor's port, which may
  read the state and a text, and has no `IO` and cannot wait. It reads and
  does not write: that is the contract.
- **When it asks by itself**, besides when a key asks: after one of its
  trigger characters is typed (`triggers`), and after typing pauses for
  its `pause` milliseconds. `asksOn` says whether it is asked on an
  occasion.

The sources it names are named, never given (`Named`): an at-point source
runs inside the asking command through a dispatcher request
(`ControlRequest.askAtPoint`, `Editor/Command/Dispatch.lean`), and a reply
cannot hold a program. `Named.ref` turns each into the reference a prompt
is asked with.

How the editor asks one, holds the session it opens and closes it is in
`docs/design/keymaps-and-modes.md`, "Completion at point", and
`Editor/Api.lean`, "Completion at point".

## Where an addition goes

| Addition | Where |
|---|---|
| Something more an at-point source is asked | A field of `Spot` (`Editor/Completion/Candidate.lean`), filled where `completeAtPoint` asks |
| Something more it answers | A field of `Region`, read where `completeAtPoint` opens the session |
| A new reason to ask | A constructor of `Occasion` and its case of `asksOn` |
| A shipped at-point source | A value in `AtPoint.shipped` (`Editor/Completion/Words.lean`), registered by the `at-point` package (`Editor/AtPoint/Compiled.lean`), and run by `ModelTest.atPointContractChecks` |
| A rule every at-point source keeps | A property of `Editor/Completion/AtPointContract.lean` |

Pinned by `ModelTest.atPointContractChecks` (the contract, on the model and
the shipped source), `atPointChecks` (asking through the dispatcher, the
first that answers), and `registryChecks` (a buffer's chain).
-/

namespace Editor.Completion

/-- What is asked for the region to complete at a position: a name, the
function that answers, and when it asks by itself. -/
structure AtPoint where
  /-- The name it is registered and listed under. -/
  name : String
  /-- The region it answers `spot` with, or none. It reads and does not
  write. -/
  ask : (spot : Spot) → EditorM (Option Region)
  /-- The characters whose typing has it asked by itself. -/
  triggers : List Char := []
  /-- How long typing pauses, in milliseconds, before it is asked by
  itself; none when a pause never asks it. -/
  pause : Option Nat := none

namespace AtPoint

/-- Whether `atPoint` is asked on `occasion`: always when a key asks, on a
trigger it declares, and on a pause of its own length. -/
def asksOn (atPoint : AtPoint) : Occasion → Bool
  | .key => true
  | .trigger char => atPoint.triggers.contains char
  | .pause ms => atPoint.pause == some ms

/-- The model of an at-point source: one called `name` that answers
`answer spot` for every spot, asking the port nothing. -/
def fixed (name : String) (answer : Spot → Option Region) : AtPoint :=
  { name, ask := fun spot => pure (answer spot) }

/-- An at-point source called `name` that never answers. -/
def silent (name : String) : AtPoint :=
  fixed name fun _ => none

/-- What the echo area says of an at-point source named in a mode's list or
config's uses that no at-point source is registered under. -/
def unknown (name : String) : String :=
  s!"no at-point completion source is registered under `{name}`"

end AtPoint

end Editor.Completion
