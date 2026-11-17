import Editor.Completion

/-!
# The contract of completion sources

What every completion source (`Editor/Completion.lean`) keeps, as one list
of properties. `model-test` runs it against the model (`Source.fixed`), the
fake that answers what it was asked (`Editor/Completion/Fake.lean`) and
each shipped source (`ModelTest.sourceContractChecks`). This module
imports only the interface, so the contract never depends on a source or
on how one is run.

## What it asks

- **A source reads and does not write.** Asked on a fixture, with the
  empty text and with a text typed, it is not refused, and it leaves the
  editor state and the texts the store holds as they were. A prompt asks
  its sources inside the asking command, before the minibuffer is made
  (`prompt`, `Editor/Api.lean`), and a later phase asks them again as the
  text changes: a source that wrote would change the editor each time it
  was asked.

## How it is run

The properties are handed a runner (`Runner`): what asks a source on a
fixture over the editor's models and says what it answered and whether it
left the state and the store as they were. The runner is the caller's,
so the fixture and the models stay out of this module.
-/

namespace Editor.Completion.Contract

/-- How the contract asks a source: `run text source` asks `source` with
`text`, from a view of a fixture, and answers what it answered and whether
the editor state and the texts the store holds were left as they were;
`none` when it was refused. -/
abbrev Runner :=
  (text : String) → (source : Source) → Option (Array Candidate × Bool)

/-- One property of completion sources. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Whether it holds of `source`, asked through `run`. -/
  holds : (run : Runner) → (source : Source) → Bool

/-- The properties every source keeps. -/
def properties : List Property :=
  [{  name :=
        "a source reads and does not write: asked with the empty text and with a text typed, it is not refused and leaves the editor state and the texts the store holds as they were"
      holds := fun run source => ["", "w"].all fun text => (run text source).any (·.2) }]

end Editor.Completion.Contract
