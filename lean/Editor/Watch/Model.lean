import Editor.Watch

/-!
# The watch port's model

A pure model of the watch port (`Editor/Watch.lean`): the interrupt flag as
a count of the interrupt keys that have arrived and not been taken off the
queue, and a clock that reads where it was set. The contract
(`Editor/Watch/Contract.lean`) holds it to what the real binding does.

Two things are the model's own, for the tests of the loop:

- **An arrival a test places** (`arrivesAfter`). On the model nothing
  happens between two requests, so an interrupt key cannot arrive "while a
  command runs" unless the model makes it. With `arrivesAfter := some n`,
  the flag is asked `n` times and answers as it stands, and the time after
  that one more key has arrived before it answers. A command the loop
  dispatched asks before each of its requests but a state request
  (`Editor/Command/Dispatch.lean`, "The guard"), so with `some n` it makes
  exactly `n` of them.
- **A clock a command's requests move** (`pace`). The model does not move
  the clock itself: the editor's models (`EditorModel.handle`,
  `Editor/Command/Model.lean`) move it on by `pace` at each text request
  and each display request, so on the models a command takes as long as
  the requests it makes.

Pinned by `ModelTest.watchChecks`.
-/

namespace Editor

/-- The state of the watch port's model. -/
structure WatchModel where
  /-- How many interrupt keys have arrived and not been taken off the
  queue. The flag is up while it is not 0. -/
  arrived : Nat := 0
  /-- When one more interrupt key arrives: after the flag has been asked
  this many more times, just before it answers the time after. `none` when
  none is to arrive. -/
  arrivesAfter : Option Nat := none
  /-- The clock's reading, in milliseconds. -/
  clock : Nat := 0
  /-- How far the editor's models move the clock on at each text request and
  each display request, in milliseconds. -/
  pace : Nat := 0
  deriving DecidableEq, Repr

namespace WatchModel

/-- The model once the flag is about to be asked: the interrupt key a test
placed has arrived if this is the time it was placed at, and is one ask
nearer otherwise. -/
def asked (model : WatchModel) : WatchModel :=
  match model.arrivesAfter with
  | none => model
  | some 0 =>
    { model with
      arrived := model.arrived + 1, arrivesAfter := none }
  | some (count + 1) => { model with arrivesAfter := some count }

/-- The model with the clock moved on by its pace: what a text request or a
display request of a command costs on the editor's models. -/
def paced (model : WatchModel) : WatchModel :=
  { model with clock := model.clock + model.pace }

/-- Answers `request`, and the model after it. -/
def handle : (request : WatchRequest) → WatchModel → request.Reply × WatchModel
  | .interrupted, model =>
    let model := model.asked
    (decide (model.arrived > 0), model)
  | .lower, model => ((), { model with arrived := model.arrived - 1 })
  | .now, model => (model.clock, model)

end WatchModel

end Editor
