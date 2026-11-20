import Editor.File
import Editor.Json
import Editor.Value

/-!
# A plain tree as the session index writes it

A store's value is a plain tree (`Value`, `Editor/Value.lean`). The session
index (`Editor/Restore/Document.lean`) writes the trees of the cells kept
across a restart as JSON, losslessly, so that a tree read back is the tree
written. Pure.

## The form

- `null`, `true` and `false` are themselves; a natural number is a JSON
  number.
- A string is a JSON string, unless it holds a NUL, which the JSON reader
  refuses even escaped (`Editor/Json.lean`): then it is `{"bytes":[…]}`,
  the bytes the store writes the text as (`File.encodeText`), read back by
  `File.decodeBytes`, as the journal's inserted text crosses
  (`Editor/Restore/Journal.lean`).
- An integer is `{"int":"-3"}`, its text, so it is never confused with a
  natural number.
- A list is `{"list":[…]}`.
- A record is `{"record":[[name, value], …]}`, its fields in order, a name
  given twice twice: a store's `decode` may match on its fields' order.

Pinned by `ModelTest.restoreValueChecks`.
-/

namespace Editor

mutual
/-- A plain tree as JSON ("The form", in the module docs). -/
def Value.toJson : Value → Json.Value
  | .null => .null
  | .bool value => .bool value
  | .nat value => .number (toString value)
  | .int value => .object #[("int", .string (toString value))]
  | .str value =>
    if value.contains '\x00' then
      .object
        #[("bytes",
            .array
              ((File.encodeText value).toList.toArray.map fun byte =>
                .number (toString byte.toNat)))]
    else .string value
  | .list items => .object #[("list", .array (Value.itemsJson items).toArray)]
  | .record fields => .object #[("record", .array (Value.fieldsJson fields).toArray)]
/-- The items of a list as JSON, in order. -/
def Value.itemsJson : List Value → List Json.Value
  | [] => []
  | item :: rest => item.toJson :: Value.itemsJson rest
/-- The fields of a record as JSON, each a name and its value, in order. -/
def Value.fieldsJson : List (String × Value) → List Json.Value
  | [] => []
  | (name, value) :: rest => .array #[.string name, value.toJson] :: Value.fieldsJson rest
end

/-- The tree JSON stands for ("The form", in the module docs); none for JSON
that is not one. It recurses through arrays, so it is `partial`: no theorem
is about it, and the round trip is pinned by checks. -/
partial def Value.ofJson? : Json.Value → Option Value
  | .null => some .null
  | .bool value => some (.bool value)
  | .number text => text.toNat?.map .nat
  | .string value => some (.str value)
  | .array _ => none
  | .object #[("int", .string text)] => text.toInt?.map .int
  | .object #[("bytes", .array bytes)] => do
    let bytes ←
      bytes.mapM fun
          | .number text => do
            let byte ← text.toNat?
            if byte < 256 then
              some byte.toUInt8
            else
              none
          | _ => none
    some (.str (File.decodeBytes ⟨bytes⟩))
  | .object #[("list", .array items)] => do
    some (.list (← items.toList.mapM Value.ofJson?))
  | .object #[("record", .array fields)] => do
    let fields ←
      fields.toList.mapM fun
          | .array #[.string name, value] => do
            some (name, ← Value.ofJson? value)
          | _ => none
    some (.record fields)
  | .object _ => none

end Editor
