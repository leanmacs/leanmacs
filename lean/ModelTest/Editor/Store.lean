import Editor.Store
import ModelTest.Check

/-!
# Model tests: `Editor/Store.lean`

The model tests of `Editor/Store.lean`: `storeCodecChecks`, pure. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

namespace StoreTest

/-- A store of a count and a note, whose note `keep` drops. -/
structure Noted where
  /-- The count. -/
  count : Nat
  /-- The note. -/
  note : Option String
  deriving BEq

/-- The store of a `Noted`, as a record of its count and its note. -/
def noted : Store Noted :=
  { name := "noted", version := 3, initial := { count := 0, note := none }
    encode := fun value =>
      .record [("count", .nat value.count), ("note", (value.note.map .str).getD .null)]
    decode := fun
      | .record [("count", .nat count), ("note", .str note)] => some { count, note := some note }
      | .record [("count", .nat count), ("note", .null)] => some { count, note := none }
      | _ => none }

end StoreTest

open StoreTest in
/-- The checks of a store's codec across a restart (`Store.codec`,
`Editor/Store.lean`). -/
def storeCodecChecks : List Check :=
  [{  name :=
        "a store's codec keeps what `keep` keeps of a value, through decode and encode, with the store's declaration"
      run :=
        pure <|
          let codec := noted.codec fun value => { value with note := none }
          let tree := noted.encode { count := 4, note := some "buffer 7" }
          codec.keep tree == some (noted.encode { count := 4, note := none }) &&
            codec.name == "noted" &&
            codec.declaration.version == 3 &&
            (noted.codec).keep tree == some tree },
    { name := "a store's codec answers none for a tree its decode refuses"
      run := pure ((noted.codec).keep (.str "not a record") == none) }]

end ModelTest
