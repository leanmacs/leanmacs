import Editor.Config.Diagnostic
import Editor.Config.Owner
import Editor.Config.Stores
import Editor.Test.Config
import Editor.Value
import ModelTest.Check

/-!
# Model tests: `Editor/Config/Stores.lean`

The model tests of `Editor/Config/Stores.lean`: `storeChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A declaration of the store `name` at `version`, which starts at the
number 0 and accepts any number. It migrates a number written at version 1 by
adding 100 to it, and, wrongly, anything written at version 5 to a string,
which it does not accept. -/
def numbers (name : String) (version : Nat) : StoreDeclaration :=
  { name, version, initial := .nat 0,
    accepts := fun
      | .nat _ => true
      | _ => false,
    migrate := fun
      | 1, .nat n => some (.nat (n + 100))
      | 5, _ => some (.str "not a number")
      | _, _ => none }

/-- A cell of the config's. -/
def cell (name : String) (version : Nat) (value : Value) : Config.Cell :=
  { owner := .config, name, version, value }

/-- Installs `declarations` for the config over `cells`, and returns the
cells after it and the source and severity of each diagnostic. -/
def installed (cells : Array Config.Cell) (declarations : Array StoreDeclaration) :
    Array Config.Cell × Array (String × Config.Severity) :=
  let (after, diagnostics) := ({ cells } : Config.Cells).install .config declarations
  (after.cells, diagnostics.map fun diagnostic => (diagnostic.source, diagnostic.severity))

/-- The checks of the rule that meets a new config's stores with the cells
there are (`Editor/Config/Stores.lean`), one for each case. -/
def storeChecks : List Check :=
  [{ name := "installing a store with no cell makes one from its initial value",
     run := pure (installed #[] #[numbers "counter" 1] == (#[cell "counter" 1 (.nat 0)], #[])) },
    { name := "a cell at the declared version that the store accepts is kept"
      run :=
        pure
          (installed #[cell "counter" 1 (.nat 7)] #[numbers "counter" 1] ==
            (#[cell "counter" 1 (.nat 7)], #[])) },
    { name :=
        "a cell the store does not accept is reset to the initial value, and a diagnostic says so"
      run :=
        pure
          (installed #[cell "counter" 1 (.str "seven")] #[numbers "counter" 1] ==
            (#[cell "counter" 1 (.nat 0)], #[("store counter", .warning)])) },
    { name :=
        "a cell at another version becomes the store's migration of it, at the declared version"
      run :=
        pure
          (installed #[cell "counter" 1 (.nat 7)] #[numbers "counter" 2] ==
            (#[cell "counter" 2 (.nat 107)], #[])) },
    { name :=
        "a cell the store's migration drops is reset to the initial value, and a diagnostic says so"
      run :=
        pure
          (installed #[cell "counter" 3 (.nat 7)] #[numbers "counter" 2] ==
            (#[cell "counter" 2 (.nat 0)], #[("store counter", .warning)])) },
    { name :=
        "a cell migrated to a tree the store does not accept is reset to the initial value, and a diagnostic says so"
      run :=
        pure
          (installed #[cell "counter" 5 (.nat 7)] #[numbers "counter" 2] ==
            (#[cell "counter" 2 (.nat 0)], #[("store counter", .warning)])) },
    { name := "a cell of the owner that is no longer declared is removed, and a diagnostic says so"
      run :=
        pure
          (installed #[cell "old" 1 (.nat 7), cell "counter" 1 (.nat 1)] #[numbers "counter" 1] ==
            (#[cell "counter" 1 (.nat 1)], #[("store old", .warning)])) },
    { name := "another owner's cell is left alone, whatever its name"
      run :=
        let theirs : Config.Cell :=
          { owner := other, name := "counter", version := 9, value := .str "theirs" }
        pure
          (installed #[theirs] #[numbers "counter" 1] ==
              (#[theirs, cell "counter" 1 (.nat 0)], #[]) &&
            installed #[theirs] #[] == (#[theirs], #[])) },
    { name :=
        "an install with parked cells: a declaration with no cell and a codec meets its parked cell, and every other parked cell is dropped, said"
      run :=
        pure <|
          let parked : Array KeptCell :=
            #[{ owner := "config", name := "counter", version := 1, value := .nat 7 },
              { owner := "config", name := "other", version := 1, value := .nat 1 }]
          let codec : StoreCodec := { declaration := numbers "counter" 2, keep := some }
          let (after, said) :=
            ({} : Config.Cells).install .config #[numbers "counter" 2] parked #[codec]
          let (without, unsaid) := ({} : Config.Cells).install .config #[numbers "counter" 2] parked
          after.cells == #[cell "counter" 2 (.nat 107)] &&
            said.map (·.source) == #["store other"] &&
            without.cells == #[cell "counter" 2 (.nat 0)] &&
            unsaid.map (·.source) == #["store counter", "store other"] },
    { name :=
        "a cell meets a declaration as the install rule says, the owner and the name filled in: what `StoreDeclaration.meet` gives, its lost value a warning"
      run :=
        pure <|
          [none, some (cell "counter" 1 (.nat 7)), some (cell "counter" 1 (.str "seven")),
                some (cell "counter" 5 (.nat 7)), some (cell "counter" 3 (.nat 7))].all
            fun old =>
            let declaration := numbers "counter" 2
            let met := declaration.meet (old.map fun cell => (cell.version, cell.value))
            let (made, said) := Config.Cells.meet .config declaration old
            made == cell "counter" met.version met.value &&
              (said.map fun diagnostic => (diagnostic.message, diagnostic.severity)) ==
                met.lost.map (·, .warning) }]

end ModelTest
