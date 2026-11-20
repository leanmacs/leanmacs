import Editor.Value

/-!
# A store as the editor holds it, and its codec across a restart

What the editor holds of a store (`Editor/Store.lean`) with no type of
config's in it: its declaration (`StoreDeclaration`), the rule that meets a
declaration with a tree written at some version (`StoreDeclaration.meet`),
the codec a store is kept across a restart with (`StoreCodec`), and a cell
as the session index keeps it (`KeptCell`, `Editor/Restore/Document.lean`).

It is a leaf module, importing only the plain trees, so that the loop's
view of the registry (`Loop.Registered`, `Editor/Command/Dispatch.lean`),
the questions to the registry (`Editor/Command/Registry.lean`) and what the
session's reconciler keeps (`Editor/Restore/Kept.lean`) can all name it.

## The install rule

`StoreDeclaration.meet` is the one rule a declaration meets a tree by,
whoever holds the tree: a reload's cells (`Config.Cells.meet`,
`Editor/Config/Stores.lean`), and a restore's kept values
(`Editor/Restore/Workspaces.lean`, `Editor/Restore/Run.lean`,
`Config.State.restoreCells`).

- no tree: the declaration's initial tree;
- a tree at the declared version: kept, if the store accepts it;
- a tree at another version: the store's migration of it, if it accepts
  that;
- otherwise the initial tree, with why the value was lost.

## Kept across a restart

A store is kept across a restart only when its owner's `setup` registers a
codec for it (`Store.keptAcrossRestart`, `Editor/Setup.lean`): whether a
value means anything in the next process is the store's to say, and a
store that holds a buffer number or a run in flight does not. The codec's
`keep` is what of a value outlives the process; it answers `none` for a tree
the store does not accept.

Pinned by `ModelTest.storeCodecDeclarationChecks`.
-/

namespace Editor

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

/-- What a declaration met a tree with: the tree the cell now holds, its
version (always the declaration's), and why the old value was lost, when
it was. -/
structure StoreDeclaration.Met where
  /-- The tree. -/
  value : Value
  /-- The version it is at: the declaration's. -/
  version : Nat
  /-- Why the value met was lost and the initial tree taken, if it was. -/
  lost : Option String := none
  deriving BEq, Repr

/-- What `declaration` makes of `old`, a tree and the version it was written
at, or of none ("The install rule", in the module docs). -/
def StoreDeclaration.meet (declaration : StoreDeclaration) (old : Option (Nat × Value)) :
    StoreDeclaration.Met :=
  let fresh (value : Value) : StoreDeclaration.Met := { value, version := declaration.version }
  let reset (reason : String) : StoreDeclaration.Met :=
    { fresh declaration.initial with lost := some reason }
  match old with
  | none => fresh declaration.initial
  | some (version, value) =>
    if version == declaration.version then
      if declaration.accepts value then fresh value
      else
        reset "the new config cannot decode the stored value, which was reset to the initial value"
    else
      match declaration.migrate version value with
      | some migrated =>
        if declaration.accepts migrated then fresh migrated
        else
          reset
            s!"the new config cannot decode the value it migrated from version {version}, which was reset to the initial value"
      | none =>
        reset
          s!"the stored value, written at version {version}, was not migrated to version {declaration.version} and was reset to the initial value"

/-- How a store is kept across a restart ("Kept across a restart", in the
module docs): its declaration, and what of a value outlives the process. -/
structure StoreCodec where
  /-- The store's declaration: its name, version, initial tree and rules. -/
  declaration : StoreDeclaration
  /-- What of a tree outlives the process; `none` for a tree the store does
  not accept. -/
  keep : Value → Option Value

/-- The name of the store a codec is for. -/
def StoreCodec.name (codec : StoreCodec) : String :=
  codec.declaration.name

/-- A cell as the session index keeps it: whose store it is, the store's
name, the version its tree was written at, and the tree. -/
structure KeptCell where
  /-- The owner's name: a package's, or `config`. -/
  owner : String
  /-- The store's name. -/
  name : String
  /-- The version of the encoding `value` was written at. -/
  version : Nat
  /-- The tree. -/
  value : Value
  deriving BEq, Repr

end Editor
