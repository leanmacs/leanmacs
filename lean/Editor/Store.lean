import Editor.Command

/-!
# Stores

State of a type that config defines cannot simply be kept across a reload:
the new config may have changed the type, so a value the old config built
cannot be handed to the new one. Config keeps such state in a *store*: a
named cell whose type has an encoding to a plain tree (`Value`) and a
version.

The editor holds the cell as a tree, never as a value of config's type, so a
reload leaves it where it is. A command over a store is a function from the
store's value to its new value, `α → EditorM α`. To run one, the editor hands
the cell's tree to the command's step (`Store.step`: decode, run, encode, all
of it config's code) and writes the result back if the command succeeded.

When a new config is installed, each store it declares meets the cell of
that name (`Editor/Config/Stores.lean`):

- no cell: one is made from `initial`;
- a cell at the store's version: kept, if `decode` accepts its tree;
- a cell at another version: replaced by `migrate` of its tree;
- a cell `decode` does not accept, or one `migrate` returns `none` for: reset
  to `initial`, and the reload's report says so.

A cell the new config no longer declares is removed.

A store is declared, and commands over it registered, from `setup`
(`Editor/Setup.lean`):

```lean
def counter : Store Nat :=
  { name := "counter", version := 1, initial := 0, encode := .nat,
    decode := fun
      | .nat n => some n
      | _ => none }

def setup : SetupM Unit := do
  counter.declare
  counter.command "bump" fun n => pure (n + 1)
```

A command works on one store. There is no request of the editor's port that
reads or writes a cell: that would make the port a sum of the text port and a
store port, which is for the phase that grows the editor API to choose. The
cell, the encoding, the version and the install rule would not change.

The store never reaches the Rust library, so it has no model and no contract
check: its one implementation is the pure core, which the model tests and the
real editor both run.
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

/-- A store of values of type `α`, as config writes it: the cell's name, and
how a value becomes a tree and comes back. -/
structure Store (α : Type) where
  /-- The cell's name. -/
  name : String
  /-- The version of the encoding. Raise it when `encode` changes shape. -/
  version : Nat
  /-- The value of a cell that is new, or that was reset. -/
  initial : α
  /-- A value as a tree. -/
  encode : α → Value
  /-- The value a tree of this version stands for; `none` if it is none. -/
  decode : Value → Option α
  /-- The tree of this version for a tree written at the older version given;
  `none` drops the value, and the cell is reset to `initial`. The default
  drops. -/
  migrate : Nat → Value → Option Value := fun _ _ => none

/-- A store as the editor holds it: what `Store α` says, with no type of
config's in it. -/
structure StoreDeclaration where
  /-- The cell's name. -/
  name : String
  /-- The version of the encoding. -/
  version : Nat
  /-- The tree of a cell that is new, or that was reset. -/
  initial : Value
  /-- Whether the store's `decode` accepts the tree. -/
  accepts : Value → Bool
  /-- The store's `migrate`. -/
  migrate : Nat → Value → Option Value

/-- What the editor holds of `store`. -/
def Store.declaration {α : Type} (store : Store α) : StoreDeclaration :=
  { name := store.name, version := store.version, initial := store.encode store.initial,
    accepts := fun tree => (store.decode tree).isSome, migrate := store.migrate }

/-- A command over `store` as a step from the cell's tree to its new tree:
decodes `tree`, runs `run` on the value, and encodes what it returns.

The editor only hands a step a tree the store accepts (the install rule keeps
no other), so a tree `decode` refuses does not arise; were it to, the step
starts from `initial`. -/
def Store.step {α : Type} (store : Store α) (run : α → EditorM α) (tree : Value) : EditorM Value :=
  do
  let value := (store.decode tree).getD store.initial
  return store.encode (← run value)

end Editor
