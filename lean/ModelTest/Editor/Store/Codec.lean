import Editor.Store.Codec
import ModelTest.Check

/-!
# Model tests: `Editor/Store/Codec.lean`

The model tests of `Editor/Store/Codec.lean`: `storeCodecDeclarationChecks`,
pure. The root module `ModelTest` runs them; its module doc says what each
shows.
-/

namespace ModelTest

open Editor

namespace StoreCodecTest

/-- A declaration of the store `name` at `version`, which starts at the
number 0 and accepts any number. It migrates a number written at version 1
by adding 100 to it, and, wrongly, anything written at version 5 to a
string, which it does not accept. -/
def counted (name : String) (version : Nat) : StoreDeclaration :=
  { name, version, initial := .nat 0,
    accepts := fun
      | .nat _ => true
      | _ => false,
    migrate := fun
      | 1, .nat n => some (.nat (n + 100))
      | 5, _ => some (.str "not a number")
      | _, _ => none }

/-- What `counted "counter" version` met `old` with: the value, the version,
and whether a value was lost. -/
def met (version : Nat) (old : Option (Nat × Value)) : Value × Nat × Bool :=
  let met := (counted "counter" version).meet old
  (met.value, met.version, met.lost.isSome)

end StoreCodecTest

open StoreCodecTest in
/-- The checks of the install rule a declaration meets a tree by
(`StoreDeclaration.meet`, `Editor/Store/Codec.lean`), one for each case. -/
def storeCodecDeclarationChecks : List Check :=
  [{  name :=
        "a declaration that meets no tree gives its initial tree, at its version, losing nothing"
      run := pure (met 1 none == (.nat 0, 1, false)) },
    { name := "a tree at the declared version the store accepts is kept"
      run := pure (met 1 (some (1, .nat 7)) == (.nat 7, 1, false)) },
    { name :=
        "a tree at the declared version the store refuses is reset to the initial tree, and why is said"
      run :=
        pure <|
          met 1 (some (1, .str "seven")) == (.nat 0, 1, true) &&
            ((counted "counter" 1).meet (some (1, .str "seven"))).lost ==
              some
                "the new config cannot decode the stored value, which was reset to the initial value" },
    { name :=
        "a tree at another version becomes the store's migration of it, at the declared version"
      run := pure (met 2 (some (1, .nat 7)) == (.nat 107, 2, false)) },
    { name :=
        "a tree migrated to one the store refuses is reset to the initial tree, and why is said"
      run :=
        pure <|
          met 2 (some (5, .nat 7)) == (.nat 0, 2, true) &&
            ((counted "counter" 2).meet (some (5, .nat 7))).lost ==
              some
                "the new config cannot decode the value it migrated from version 5, which was reset to the initial value" },
    { name := "a tree the store does not migrate is reset to the initial tree, and why is said"
      run :=
        pure <|
          met 2 (some (3, .nat 7)) == (.nat 0, 2, true) &&
            ((counted "counter" 2).meet (some (3, .nat 7))).lost ==
              some
                "the stored value, written at version 3, was not migrated to version 2 and was reset to the initial value" }]

end ModelTest
