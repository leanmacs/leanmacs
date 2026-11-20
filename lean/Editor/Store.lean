import Editor.Command
import Editor.Store.Codec
import Editor.Value

/-!
# Stores

State of a type that config defines cannot simply be kept across a reload:
the new config may have changed the type, so a value the old config built
cannot be handed to the new one. Config keeps such state in a *store*: a
named cell whose type has an encoding to a plain tree (`Value`,
`Editor/Value.lean`) and a version.

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
reads or writes a cell. The port is a composite of sub-ports
(`Editor/Command.lean`), and a store sub-port could be one of them, but
stores do not use it: a command over a store is handed the value. Adding
one would not change the cell, the encoding, the version or the install
rule.

The store never reaches the Rust library, so it has no model and no contract
check: its one implementation is the pure core, which the model tests and the
real editor both run.
-/

namespace Editor

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

/-- The codec `store` is kept across a restart with
(`Editor/Store/Codec.lean`, "Kept across a restart"): its declaration, and
a `keep` that decodes a tree, applies `keep` to the value and encodes what
it gives; `none` for a tree `decode` refuses. -/
def Store.codec {α : Type} (store : Store α) (keep : α → α := id) : StoreCodec :=
  { declaration := store.declaration
    keep := fun tree => (store.decode tree).map fun value => store.encode (keep value) }

end Editor
