import Editor.Config.Session

/-!
# Config tests: support: Gate

How a check controls elaboration (`Gate`): a decorator of the elaborator
port that holds one config file open until the check lets it go. Shared by
several test modules; it holds no checks of its own.
-/

namespace ConfigTest

open Editor

/-- How a check controls elaboration: a decorator of the elaborator port that
holds one config file, `Config/Slow.lean` unless the check names another,
open until the check lets it go, and counts the files being elaborated.
Nothing here sleeps to let something else happen. -/
structure Gate where
  /-- The module of the config file the gate holds: `Config.Slow` unless
  the check names another. -/
  module : String := "Config.Slow"
  /-- Resolved by the check to let the held file go, for good. -/
  release : IO.Promise Unit
  /-- Whether an elaboration of the held file has arrived and waited. -/
  holding : IO.Ref Bool
  /-- How many files are being elaborated now. -/
  inProgress : IO.Ref Nat
  /-- The most files that were being elaborated at once. -/
  most : IO.Ref Nat

namespace Gate

/-- A gate that is shut, holding the config file of `module`. -/
def new (module : String := "Config.Slow") : IO Gate :=
  return { module, release := ← IO.Promise.new, holding := ← IO.mkRef false,
           inProgress := ← IO.mkRef 0, most := ← IO.mkRef 0 }

/-- Runs `elaborate`, the elaboration of `file`, behind the gate. -/
def through {σ : Type} (gate : Gate) (file : Config.SourceFile)
    (elaborate : IO (Config.FileResult σ)) : IO (Config.FileResult σ) := do
  let now ← gate.inProgress.modifyGet fun count => (count + 1, count + 1)
  gate.most.modify (max · now)
  try
    if file.module == gate.module then
      gate.holding.set true
      discard <| IO.wait gate.release.result?
    elaborate
  finally
    gate.inProgress.modify (· - 1)

/-- `elaborator` behind the gate: every elaboration of a file, the root's
too. -/
def around {β σ : Type} (gate : Gate) (elaborator : Config.Elaborator β σ) :
    Config.Elaborator β σ :=
  { elaborator with
    file := fun base handles file => gate.through file (elaborator.file base handles file),
    root := fun base handles file => gate.through file (elaborator.root base handles file) }

/-- Lets the held file go, now and from now on. -/
def «open» (gate : Gate) : IO Unit :=
  gate.release.resolve ()

end Gate

end ConfigTest
