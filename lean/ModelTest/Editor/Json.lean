import Editor.Json
import ModelTest.Check

/-!
# Model tests: `Editor/Json.lean`

The model tests of `Editor/Json.lean`: `jsonChecks`. The root module `ModelTest`
runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the JSON reader (`Editor/Json.lean`): pure. -/
def jsonChecks : List Check :=
  let parsed (text : String) : Option Json.Value := (Json.parse text.toUTF8).toOption
  let refusal (text : String) : Option String :=
    match Json.parse text.toUTF8 with
    | .error why => some why
    | .ok _ => none
  [{  name :=
        "the JSON reader reads nested arrays and objects in order, escapes, numbers as their text, true, false and null, with whitespace around them"
      run :=
        pure
          (parsed
                " {\"a\": [1, -2.50, 3e+2, {\"b\": null}], \"s\": \"x\\\"y\\u00e9\\n\", \"t\": true, \"f\": false, \"a\": []} " ==
              some
                (.object
                  #[("a",
                      .array
                        #[.number "1", .number "-2.50", .number "3e+2", .object #[("b", .null)]]),
                    ("s", .string "x\"yé\n"), ("t", .bool true), ("f", .bool false),
                    ("a", .array #[])]) &&
            (parsed "{\"a\": 1, \"a\": 2}").bind (·.field? "a") == some (.number "1") &&
            parsed "[]" == some (.array #[]) &&
            parsed "\"é\"" == some (.string "é")) },
    { name :=
        "the JSON reader refuses trailing text, an unclosed array, an unclosed object, a bare word, a number with no digits, an empty document and what is not UTF-8, saying why"
      run :=
        pure
          (refusal "[1] x" == some "there is more after the value" &&
            refusal "[1, 2" == some "an array is not closed" &&
            refusal "{\"a\": 1" == some "an object is not closed" &&
            refusal "nope" == some "nope is not a JSON value" &&
            refusal "-" == some "a number has no digits" &&
            refusal "  " == some "a value is missing" &&
            (match Json.parse (ByteArray.mk #[0xff]) with
            | .error why => why == "it is not UTF-8"
            | .ok _ => false)) }]

end ModelTest
