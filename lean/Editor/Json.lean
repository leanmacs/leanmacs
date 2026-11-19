import Editor.Process.Environment

/-!
# JSON documents, read whole and written

What a tool prints as JSON, read into a tree (`Json.Value`), for the
compile mode's computed commands (`mise tasks ls --json`,
`Editor/Compile/Shipped.lean`); and a tree written as a document
(`Json.render`), for the working sets a workspace keeps on disk
(`Editor/WorkingSet.lean`). Pure. It is read here, and not with
`Lean.Data.Json`, which lives in `Lean`, outside config's closure, as
`Editor/Process/Environment.lean` records for `mise env --json`, whose
string reader (`Process.string`, `Process.skipSpace`) it shares.

## The rules

- **The document** (`Json.parse`) is UTF-8 holding one value, with JSON's
  whitespace around it and nothing after it.
- **A value** is `null`, `true`, `false`, a number, a string, an array or an
  object. A number is kept as its text (`number`), checked against JSON's
  grammar and never converted. A string has JSON's escapes, and refuses a
  control character or a NUL. An object keeps its members in order, a name
  given twice twice (`Value.field?` answers the first).
- **Refusals** say why, as a clause: `it is not UTF-8`, `there is more after
  the value`, `an array is not closed`, `an object is not closed`, `a value
  is missing`, `<word> is not a JSON value`, and the string reader's own.
- **Depth** is bounded by fuel (`fuel`), as `Process.members` is, which a
  document cannot run out of: it is more than twice its characters.
- **Writing** (`Json.render`) is compact: no whitespace between tokens. A
  string is written with JSON's short escapes for `"`, `\`, a backspace, a
  form feed, a line feed, a carriage return and a tab, `\u00XX` for every
  other control character, and every other character as itself, in UTF-8.
  A number is written as its text. So `parse (render v)` is `v` for every
  value whose strings hold no NUL and whose numbers are JSON's: the reader
  refuses a NUL even escaped.

Pinned by `ModelTest.jsonChecks`.
-/

namespace Editor.Json

/-- A JSON value. -/
inductive Value where
  /-- `null`. -/
  | null
  /-- `true` or `false`. -/
  | bool (value : Bool)
  /-- A number, as its text. -/
  | number (text : String)
  /-- A string. -/
  | string (value : String)
  /-- An array, in order. -/
  | array (items : Array Value)
  /-- An object's members, in order. -/
  | object (members : Array (String × Value))
  deriving BEq, Repr, Inhabited

/-- The value of the first member named `name` of an object; none for no
such member, or a value that is no object. -/
def Value.field? (value : Value) (name : String) : Option Value :=
  match value with
  | .object members => (members.find? (·.1 == name)).map (·.2)
  | _ => none

/-- The digits at the start of `input`, and what follows them. -/
def digits (input : List Char) : List Char × List Char :=
  (input.takeWhile Char.isDigit, input.dropWhile Char.isDigit)

/-- A number at the start of `input` (JSON's grammar: an optional minus,
an integer part with no leading zero, an optional fraction and an optional
exponent): its text and what follows it. -/
def number (input : List Char) : Except String (String × List Char) := do
  let (sign, rest) :=
    match input with
    | '-' :: rest => (['-'], rest)
    | _ => ([], input)
  let (whole, rest) ←
    match rest with
    | '0' :: rest =>
      pure (['0'], rest)
    | _ =>
      let (whole, rest) := digits rest
      if whole.isEmpty then
        throw "a number has no digits"
      else
        pure (whole, rest)
  let (fraction, rest) ←
    match rest with
    | '.' :: rest =>
      let (part, rest) := digits rest
      if part.isEmpty then
        throw "a number's fraction has no digits"
      else
        pure ('.' :: part, rest)
    | _ =>
      pure ([], rest)
  let (exponent, rest) ←
    match rest with
    | e :: rest =>
      if e == 'e' || e == 'E' then
        let (signs, rest) :=
          match rest with
          | '+' :: rest => (['+'], rest)
          | '-' :: rest => (['-'], rest)
          | _ => ([], rest)
        let (part, rest) := digits rest
        if part.isEmpty then
          throw "a number's exponent has no digits"
        else
          pure (e :: signs ++ part, rest)
      else
        pure ([], e :: rest)
    | [] =>
      pure ([], [])
  return (String.ofList (sign ++ whole ++ fraction ++ exponent), rest)

/-- The word at the start of `input`: its letters, for a refusal. -/
def word (input : List Char) : String :=
  match input.takeWhile Char.isAlpha with
  | [] => String.ofList (input.take 1)
  | letters => String.ofList letters

mutual
/-- A value at the start of `input`, after any whitespace, with `fuel`
  ("Depth", in the module docs): it and what follows it. -/
def value : Nat → List Char → Except String (Value × List Char)
  | 0, _ => .error "the document is nested too deeply"
  | fuel + 1, input =>
    match Process.skipSpace input with
    | [] => .error "a value is missing"
    | '"' :: rest => do
      let (text, rest) ← Process.string ('"' :: rest)
      return (.string text, rest)
    | '[' :: rest =>
      match Process.skipSpace rest with
      | ']' :: rest => .ok (.array #[], rest)
      | _ => items fuel #[] rest
    | '{' :: rest =>
      match Process.skipSpace rest with
      | '}' :: rest => .ok (.object #[], rest)
      | _ => members fuel #[] rest
    | 't' :: 'r' :: 'u' :: 'e' :: rest => .ok (.bool true, rest)
    | 'f' :: 'a' :: 'l' :: 's' :: 'e' :: rest => .ok (.bool false, rest)
    | 'n' :: 'u' :: 'l' :: 'l' :: rest => .ok (.null, rest)
    | input@(first :: _) =>
      if first == '-' || first.isDigit then do
        let (text, rest) ← number input
        return (.number text, rest)
      else .error s!"{word input} is not a JSON value"
/-- An array's items after `found`, from the next item on: the array and
  what follows its closing bracket. -/
def items : Nat → Array Value → List Char → Except String (Value × List Char)
  | 0, _, _ => .error "the document is nested too deeply"
  | fuel + 1, found, input => do
    let (item, rest) ← value fuel input
    match Process.skipSpace rest with
    | ',' :: rest =>
      items fuel (found.push item) rest
    | ']' :: rest =>
      return (.array (found.push item), rest)
    | _ =>
      throw "an array is not closed"
/-- An object's members after `found`, from the next member on: the
  object and what follows its closing brace. -/
def members : Nat → Array (String × Value) → List Char → Except String (Value × List Char)
  | 0, _, _ => .error "the document is nested too deeply"
  | fuel + 1, found, input => do
    let (name, rest) ← Process.string input
    let ':' :: rest := Process.skipSpace rest | throw s!"the name {name} has no colon"
    let (member, rest) ← value fuel rest
    match Process.skipSpace rest with
    | ',' :: rest =>
      members fuel (found.push (name, member)) rest
    | '}' :: rest =>
      return (.object (found.push (name, member)), rest)
    | _ =>
      throw "an object is not closed"
end

/-- The fuel a document of `input` is read with ("Depth", in the module
docs). -/
def fuel (input : List Char) : Nat :=
  2 * input.length + 2

/-- The value the JSON document `bytes` holds ("The rules", in the module
docs), or why it holds none. -/
def parse (bytes : ByteArray) : Except String Value := do
  let some text := String.fromUTF8? bytes | throw "it is not UTF-8"
  let input := text.toList
  let (found, rest) ← value (fuel input) input
  unless (Process.skipSpace rest).isEmpty do
    throw "there is more after the value"
  return found

/-- The two hexadecimal digits of `value`, below 256, in lower case. -/
def hex2 (value : Nat) : String :=
  let digit (n : Nat) : Char := if n < 10 then Char.ofNat (48 + n) else Char.ofNat (87 + n)
  String.ofList [digit (value / 16 % 16), digit (value % 16)]

/-- `text` as a JSON string, quotes included ("Writing", in the module
docs). -/
def quoted (text : String) : String :=
  let body :=
    text.foldl (init := "") fun out character =>
      match character with
      | '"' => out ++ "\\\""
      | '\\' => out ++ "\\\\"
      | '\x08' => out ++ "\\b"
      | '\x0c' => out ++ "\\f"
      | '\n' => out ++ "\\n"
      | '\r' => out ++ "\\r"
      | '\t' => out ++ "\\t"
      | character =>
        if character.toNat < 0x20 then out ++ "\\u00" ++ hex2 character.toNat
        else out.push character
  "\"" ++ body ++ "\""

/-- `value` as a compact JSON document ("Writing", in the module docs). -/
partial def render : Value → String
  | .null => "null"
  | .bool value => if value then "true" else "false"
  | .number text => text
  | .string text => quoted text
  | .array items => "[" ++ ",".intercalate (items.toList.map render) ++ "]"
  | .object members =>
    "{" ++
      ",".intercalate
        (members.toList.map fun (name, member) => quoted name ++ ":" ++ render member) ++
      "}"

end Editor.Json
