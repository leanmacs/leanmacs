/-!
# Invocations

What a key sequence becomes: an `Invocation`, a command's name with plain
arguments. It is data and holds no closure, so two can be compared, an
invocation can be stored, and one can be run again
(`docs/design/keymaps-and-modes.md`, "The pipeline"). An input scheme
(`Editor/InputScheme.lean`) yields invocations; looking the command up and
running it is the command loop's, and is not here.

A command is named by a `String`, as the registry names it
(`Editor/Config/Registry.lean`).

An argument is one of a small flat set of kinds (`Argument`), not a store's
`Value` (`Editor/Store.lean`): that type is a nested inductive, for which
Lean derives no decidable equality, and an invocation must have one.

## Where an addition goes

| Addition | Where |
|---|---|
| A new kind of argument | A variant of `Argument`, of a type with decidable equality |
| What an invocation does | The command registered under its name; nothing here |

Pinned by `ModelTest.invocationChecks`.
-/

namespace Editor

/-- A plain argument of an invocation. -/
inductive Argument where
  /-- A natural number, such as a count. -/
  | nat (value : Nat)
  /-- An integer. -/
  | int (value : Int)
  /-- A string, such as the text to insert. -/
  | str (value : String)
  /-- A truth value. -/
  | bool (value : Bool)
  deriving DecidableEq, Repr

/-- A command's name and the arguments to run it with. -/
structure Invocation where
  /-- The command's name, as the registry names it. -/
  command : String
  /-- Its arguments, in order. -/
  arguments : List Argument := []
  deriving DecidableEq, Repr

end Editor
