import Editor.Config.Diagnostic
import Editor.Config.Registry

/-!
# The cells of the stores

A store's value (`Editor/Store.lean`) lives in a *cell*: an owner, a name, a
version and a plain tree. The cells are editor state, held on the editor
thread. A cell holds no type of config's, so a reload leaves it where it is,
and `install` is the rule that meets the stores a new config declares with
the cells there are.

A command over a store does not write its cell: it hands back a `Write`,
the cell's new tree, and whoever ran it writes that back. `Write` is here,
beside the cells, so that the command loop (`Editor/Loop.lean`) can hand one
on without importing the reload reducer.
-/

namespace Editor.Config

/-- The cell of one store. -/
structure Cell where
  /-- Who declared the store. -/
  owner : Owner
  /-- The store's name. An owner's stores have different names. -/
  name : String
  /-- The version of the encoding `value` was written at. -/
  version : Nat
  /-- The store's value, as a tree. -/
  value : Value
  deriving BEq, Repr

/-- The cells of every store. -/
structure Cells where
  /-- The cells. -/
  cells : Array Cell := #[]

namespace Cells

/-- The cell of `owner`'s store called `name`. -/
def find? (cells : Cells) (owner : Owner) (name : String) : Option Cell :=
  cells.cells.find? fun cell => cell.owner == owner && cell.name == name

/-- `cells` with `value` as the value of `owner`'s store called `name`.
Nothing changes if there is no such cell. -/
def set (cells : Cells) (owner : Owner) (name : String) (value : Value) : Cells :=
  {
    cells :=
      cells.cells.map fun cell =>
        if cell.owner == owner && cell.name == name then { cell with value } else cell }

/-- The diagnostic that the value of the store called `name` was lost. A lost
value does not reject a reload, so it is a warning. -/
def lost (name reason : String) : Diagnostic :=
  { source := s!"store {name}", severity := .warning, message := reason }

/-- The cell a new config's `declaration` gets, given the cell there was for
it, and a diagnostic if that cell's value was lost: the install rule
(`StoreDeclaration.meet`, `Editor/Store/Codec.lean`), with the owner and the
name filled in. -/
def meet (owner : Owner) (declaration : StoreDeclaration) (old : Option Cell) :
    Cell × Option Diagnostic :=
  let met := declaration.meet (old.map fun cell => (cell.version, cell.value))
  ({ owner, name := declaration.name, version := met.version, value := met.value },
    met.lost.map (lost declaration.name))

/-- What the reload's report says of the store called `name`, kept by the
session and parked until config installed, when the config that installed
registers no codec for it. -/
def unclaimed (name : String) : Diagnostic :=
  lost name "the session kept a value, but config registers no codec for it now; dropped"

/-- The cells once `owner` has declared exactly `declarations`, and a
diagnostic for each value that was lost on the way.

Each declared store meets the cell `owner` had under its name (`meet`): with
none, a cell is made from the initial value; a cell at the declared version
is kept if the store accepts its tree; a cell at another version becomes the
store's migration of it; and a cell the store does not accept, or does not
migrate, is reset to the initial value. A cell of `owner` that is no longer
declared is removed. Other owners' cells are left alone, and come first.

`parked` are the cells a session restore kept for the owner, parked until
it installs (`State.parked`, `Editor/Config/Reload.lean`): a declaration
with no cell meets the parked cell of its name, as a cell there was, when
`codecs`, the codecs the same `setup` registered, keep its store across a
restart. Every other parked cell is dropped, and said (`unclaimed`). -/
def install (cells : Cells) (owner : Owner) (declarations : Array StoreDeclaration)
    (parked : Array KeptCell := #[]) (codecs : Array StoreCodec := #[]) :
    Cells × Array Diagnostic :=
  let others := cells.cells.filter (·.owner != owner)
  let dropped :=
    (cells.cells.filter fun cell =>
          cell.owner == owner && !declarations.any (·.name == cell.name)).map
      fun cell =>
      lost cell.name "the new config no longer declares the store, and its value was dropped"
  let claimable (name : String) : Option KeptCell :=
    if codecs.any (·.name == name) then parked.find? (·.name == name) else none
  let previous (name : String) : Option Cell :=
    (cells.find? owner name) <|>
      (claimable name).map fun kept => { owner, name, version := kept.version, value := kept.value }
  let claimed (kept : KeptCell) : Bool :=
    (cells.find? owner kept.name).isNone && declarations.any (·.name == kept.name) &&
      (claimable kept.name).isSome
  let unclaimedCells := (parked.filter (!claimed ·)).map (unclaimed ·.name)
  let met := declarations.map fun declaration => meet owner declaration (previous declaration.name)
  ({ cells := others ++ met.map (·.1) }, dropped ++ met.filterMap (·.2) ++ unclaimedCells)

end Cells

/-- What a command asks the editor to write when it has run: the new tree of
a store's cell. Whoever ran the command writes it back
(`Config.State.written`, `Editor/Config/Reload.lean`). -/
structure Write where
  /-- Whose store it is. -/
  owner : Owner
  /-- The store's name. -/
  store : String
  /-- The cell's new tree. -/
  value : Value

end Editor.Config
