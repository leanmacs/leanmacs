import Editor.Restore.Value
import ModelTest.Check
import ShellApi

/-!
# Model tests: `Editor/Restore/Value.lean`

The model tests of `Editor/Restore/Value.lean`: `restoreValueChecks`, pure.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

namespace RestoreValueTest

/-- Whether `value` written as JSON, rendered, parsed and read back is
`value`. -/
def roundTrips (value : Value) : Bool :=
  match Json.parse (Json.render value.toJson).toUTF8 with
  | .ok json => Value.ofJson? json == some value && Value.ofJson? value.toJson == some value
  | .error _ => false

/-- A string holding bytes that are not UTF-8, as the store keeps them: each
as its escape (`File.decodeBytes`). -/
def survivors : String :=
  File.decodeBytes ⟨#[0x61, 0xff, 0xfe, 0x62]⟩

end RestoreValueTest

open RestoreValueTest in
/-- The checks of a plain tree as the session index writes it
(`Editor/Restore/Value.lean`). -/
def restoreValueChecks : List Check :=
  [{  name := "every kind of tree round-trips through its JSON, rendered and parsed"
      run :=
        pure <|
          [Value.null, .bool true, .bool false, .nat 0, .nat 7, .int 3, .int (-3), .str "",
                .str "plain", .list [], .record []].all
            roundTrips },
    { name := "a natural number and an integer of the same size are told apart"
      run :=
        pure
          (Value.ofJson? (Value.int 4).toJson == some (.int 4) &&
            (Value.int 4).toJson != (Value.nat 4).toJson) },
    { name := "negative integers and big naturals round-trip"
      run :=
        pure <|
          roundTrips (.int (-123456789012345678901234567890)) &&
            roundTrips (.nat 340282366920938463463374607431768211456) },
    { name := "nested lists and records round-trip"
      run :=
        pure <|
          roundTrips
            (.list
              [.record [("a", .list [.nat 1, .list [.null]]), ("b", .record [("c", .str "d")])],
                .list [.list []]]) },
    { name := "a record keeps its fields' order, out of order by name, and a name given twice twice"
      run :=
        pure <|
          let fields : List (String × Value) := [("z", .nat 1), ("a", .nat 2), ("z", .nat 3)]
          roundTrips (.record fields) &&
            Value.ofJson? (Value.record fields).toJson == some (.record fields) },
    { name := "a string holding a NUL round-trips, through the bytes the store writes it as"
      run :=
        pure <|
          roundTrips (.str "a\x00b") && roundTrips (.str "\x00") &&
            roundTrips (.str s!"é\x00{survivors}") },
    { name :=
        "bytes that are not UTF-8, kept as their escapes, and multi-byte characters round-trip"
      run := pure (roundTrips (.str survivors) && roundTrips (.str "é漢🙂 x")) },
    { name :=
        "JSON that is no tree is read as none: an array, an unknown object, a negative number, a byte past 255"
      run :=
        pure <|
          [Json.Value.array #[], .object #[("other", .null)], .number "-1", .number "1.5",
                .object #[("bytes", .array #[.number "256"])],
                .object #[("record", .array #[.array #[.null, .null]])]].all
            (Value.ofJson? · == none) },
    { name :=
        "the shell's store that is kept across a restart round-trips, initial and populated: shell-history"
      run :=
        pure <|
          roundTrips (Shell.historyStore.encode Shell.historyStore.initial) &&
            roundTrips (Shell.historyStore.encode #[":!make", "ls -la", "echo é\x00"]) }]

end ModelTest
