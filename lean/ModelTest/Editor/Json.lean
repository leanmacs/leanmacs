import Editor.Compile.Contribution
import Editor.Compile.Shipped
import Editor.Json
import ModelTest.Check
import ModelTest.Support.Compile

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
        "a JSON value written and read again is the value: quotes, backslashes, control characters, characters that are not ASCII and an escape of a byte, in strings and names, nested in arrays and objects"
      run :=
        let table : List Json.Value :=
          [.null, .bool true, .bool false, .number "-2.5e+3", .string "",
            .string "say \"hi\" \\ there",
            .string "tab\tline\nreturn\rbell\x07escape\x1bend\x08\x0c", .string "é漢🙂",
            .string (String.singleton (Char.ofNat 0x10DCFF)), .array #[],
            .object
              #[("a\"b", .array #[.number "1", .object #[("\n", .null)]]), ("é", .string "x")]]
        pure
          (table.all fun value => (Json.parse (Json.render value).toUTF8).toOption == some value) },
    { name :=
        "a JSON value is written compactly, members in order, with JSON's short escapes and \\u00XX for another control character"
      run :=
        pure
          (Json.render
              (.object
                #[("version", .number "1"), ("s", .string "a\"\\\n\x01é"),
                  ("list", .array #[.bool true, .null])]) ==
            "{\"version\":1,\"s\":\"a\\\"\\\\\\n\\u0001é\",\"list\":[true,null]}") },
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
            | .ok _ => false)) },
    { name :=
        "mise's task list gives one command per task, mise run and the task's name, in the task's dir, in the order listed: build and test in /m, lint in /m/sub; an empty list gives none"
      run :=
        pure
          ((Compile.miseTasks miseListing.toUTF8).toOption.map
                (·.map fun command =>
                  (command.name, command.line, command.directory.map (·.toString))) ==
              some
                #[("build", "mise run build", some "/m"), ("test", "mise run test", some "/m"),
                  ("lint", "mise run lint", some "/m/sub")] &&
            (Compile.miseTasks "[]".toUTF8).toOption.map (·.size) == some 0) },
    { name :=
        "a task's name that is not a bare shell word is quoted: my task gives mise run 'my task', it's gives mise run 'it'\\''s; a name listed twice keeps its first, and a task with an empty dir has none"
      run :=
        let listing :=
          "[{\"name\": \"my task\", \"dir\": \"\"}, {\"name\": \"it's\"}, {\"name\": \"my task\", \"dir\": \"/x\"}, {\"name\": \"a:b/c@d%e+f=g,h_i-j.k\"}]"
        pure
          ((Compile.miseTasks listing.toUTF8).toOption.map
                (·.map fun command =>
                  (command.name, command.line, command.directory.map (·.toString))) ==
              some
                #[("my task", "mise run 'my task'", none), ("it's", "mise run 'it'\\''s'", none),
                  ("a:b/c@d%e+f=g,h_i-j.k", "mise run a:b/c@d%e+f=g,h_i-j.k", none)] &&
            Compile.shellWord "" == "''" &&
            Compile.shellWord "a$b" == "'a$b'") },
    { name :=
        "mise's task list is refused when it is not an array, a task is not an object, a task has no name or an empty one, or it is no JSON, saying why"
      run :=
        let refused (text : String) : Option String :=
          match Compile.miseTasks text.toUTF8 with
          | .error why => some why
          | .ok _ => none
        pure
          (refused "{}" == some "it is not an array" &&
            refused "[{\"name\": \"a\"}, 3]" == some "task 2 is not an object" &&
            refused "[{\"name\": \"a\"}, {\"dir\": \"/m\"}]" == some "task 2 has no name" &&
            refused "[{\"name\": \"\"}]" == some "task 1 has no name" &&
            refused "[{\"name\": 1}]" == some "task 1 has no name" &&
            refused "[" == some "a value is missing") }]

end ModelTest
