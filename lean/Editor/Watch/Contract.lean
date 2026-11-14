import Editor.Watch

/-!
# The contract of the watch port

What every implementation of the watch port (`Editor/Watch.lean`) answers,
as one list of properties. The model (`Editor/Watch/Model.lean`) is held to
it by `model-test`, and the real binding (`Editor/Watch/Real.lean`) by
`contract-test`, so the model cannot drift from the library's flag. This
module imports only the port, so the contract never depends on either.

## How a runner runs a property

A property says how many interrupt keys have arrived before it runs
(`Property.arrived`), and its `holds` is a program over the watch port. A
runner makes that many arrive, with nothing taken off the queue, and then
runs `holds`:

- the model starts with `arrived` at that count;
- the real binding posts that many presses of the interrupt key through the
  library's window input, runs `holds` against its handler, and afterwards
  takes the events off the queue and lowers the flag for any `holds` left
  up.

A program cannot make a key arrive, so every arrival of a property comes
before its first request.
-/

namespace Editor.WatchContract

/-- One property of the watch port. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- How many interrupt keys have arrived, and not been taken off the
  queue, before `holds` runs. -/
  arrived : Nat
  /-- Observes the property; `true` when it holds. -/
  holds : WatchM Bool

/-- The properties of the watch port. -/
def properties : List Property :=
  [{ name := "with no interrupt key arrived, the flag is down", arrived := 0,
     holds := do
       return !(← Watch.interrupted) },
    { name :=
        "with one interrupt key arrived the flag is up, and asking does not lower it: it is up when asked again"
      arrived := 1
      holds := do
        let first ← Watch.interrupted
        let second ← Watch.interrupted
        return first && second },
    { name := "one lower after one interrupt key arrived brings the flag down"
      arrived := 1
      holds := do
        Watch.lower
        return !(← Watch.interrupted) },
    { name :=
        "with two interrupt keys arrived the flag stays up through one lower, and comes down at the second"
      arrived := 2
      holds := do
        Watch.lower
        let between ← Watch.interrupted
        Watch.lower
        return between && !(← Watch.interrupted) },
    { name := "a lower with no interrupt key arrived leaves the flag down"
      arrived := 0
      holds := do
        Watch.lower
        return !(← Watch.interrupted) },
    { name := "a second lower after the one interrupt key that arrived leaves the flag down"
      arrived := 1
      holds := do
        Watch.lower
        Watch.lower
        return !(← Watch.interrupted) },
    { name := "two readings of the clock do not go back, whatever is asked between them"
      arrived := 1
      holds := do
        let first ← Watch.now
        discard Watch.interrupted
        Watch.lower
        return first ≤ (← Watch.now) }]

/-- The names of `properties` that do not hold. `run` runs one property
against an implementation in which the property's interrupt keys have
arrived, as the module docs say. -/
def failures (run : Property → IO Bool) (properties : List Property) : IO (List String) :=
  properties.filterMapM fun property => do
    return if ← run property then none else some property.name

end Editor.WatchContract
