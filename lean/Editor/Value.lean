/-!
# Plain trees

A `Value` is a plain tree: what a store's cell holds (`Editor/Store.lean`)
and what a buffer keeps under a name (`Buffer.locals`,
`Editor/State.lean`). It names no type of config's, so it means the same
before and after a reload.

It is a module of its own, which imports nothing, because the editor state
holds values and the editor's port asks about the editor state
(`Editor/Command.lean`): a store's commands are programs over that port, so
the stores cannot be where the state finds the type.
-/

namespace Editor

/-- A plain tree: what a store's cell holds. It names no type of config's, so
it means the same before and after a reload. -/
inductive Value where
  /-- Nothing. -/
  | null
  /-- A boolean. -/
  | bool (value : Bool)
  /-- A natural number. -/
  | nat (value : Nat)
  /-- An integer. -/
  | int (value : Int)
  /-- A string. -/
  | str (value : String)
  /-- A list of trees. -/
  | list (items : List Value)
  /-- Named fields, in order. -/
  | record (fields : List (String × Value))
  deriving BEq, Repr, Inhabited

end Editor
