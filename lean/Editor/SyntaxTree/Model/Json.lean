import Editor.SyntaxTree

/-!
# The syntax tree model's JSON grammar

A pure parser for JSON that builds the tree the library's JSON grammar
(`tree-sitter-json` 0.24.8, `crates/editor-syntax-treesitter`) builds, for
the subset the model implements: objects, arrays, strings without escapes,
numbers, `true`, `false` and `null`, with blanks (a space, a tab, a carriage
return, a line feed) between them. No escape and no comment.

The tree, with each kind and field confirmed against the grammar's
`src/grammar.json` and `src/node-types.json`:

- `document`, the root, over every value of the text. It starts where its
  first value starts, or at the end of a text with none, and stops at the
  end of the text: the library's root leaves out the blanks that lead the
  text.
- `object`: `{`, its pairs with `,` between them, and `}`.
- `pair`: a `string` at the field `key`, `:`, and a value at the field
  `value`.
- `array`: `[`, its values with `,` between them, and `]`.
- `string`: `"`, a `string_content` over what is between the quotes when
  there is anything, and `"`.
- `number`: an optional `-`, `0` or a digit other than `0` followed by
  digits, an optional `.` and digits, and an optional `e` or `E` with an
  optional `-` and digits; one token, with no children.
- `true`, `false`, `null`: named, with no children.

The punctuation, `{ } [ ] , : "`, is anonymous. A text outside the subset
parses to a `document` over one `ERROR` node, from its first character that
is not a blank to its end. That answer is the model's own, and no property
of the contract rests on it.
-/

namespace Editor.SyntaxTreeModel

/-- A node of a tree, as the model builds it. -/
inductive Node where
  /-- A node of `kind`, named or not, at `field` of its parent if any, over
  the bytes from `start` to `stop`, with its children in order. -/
  |
  mk (kind : String) (named : Bool) (field : Option String) (start stop : Nat)
    (children : Array Node)
  deriving Inhabited

namespace Node

/-- The node's kind. -/
def kind : Node → String
  | .mk kind .. => kind

/-- Whether it is named. -/
def named : Node → Bool
  | .mk _ named .. => named

/-- The field of its parent it is at. -/
def field : Node → Option String
  | .mk _ _ field .. => field

/-- The offset it starts at. -/
def start : Node → Nat
  | .mk _ _ _ start .. => start

/-- The offset it stops at, not included. -/
def stop : Node → Nat
  | .mk _ _ _ _ stop _ => stop

/-- Its children, in order. -/
def children : Node → Array Node
  | .mk _ _ _ _ _ children => children

/-- The node at `field`. -/
def atField (node : Node) (field : String) : Node :=
  .mk node.kind node.named (some field) node.start node.stop node.children

end Node

/-- One node of a tree read in pre-order: what the library's `nodes()`
answers, for the checks that compare a tree node by node. -/
structure Flat where
  /-- Its kind. -/
  kind : String
  /-- Whether it is named. -/
  named : Bool
  /-- The field of its parent it is at. -/
  field : Option String
  /-- How deep it is: 0 for the root. -/
  depth : Nat
  /-- The offset it starts at. -/
  start : Nat
  /-- The offset it stops at. -/
  stop : Nat
  deriving DecidableEq, Repr

/-- `node` and its descendants in pre-order, from `depth`. -/
partial def Node.flatten (node : Node) (depth : Nat := 0) : Array Flat :=
  node.children.foldl (fun flat child => flat ++ child.flatten (depth + 1))
    #[{ kind := node.kind, named := node.named, field := node.field, depth, start := node.start,
        stop := node.stop }]

/-- `node` and its descendants in pre-order. -/
partial def Node.preorder (node : Node) : Array Node :=
  node.children.foldl (fun all child => all ++ child.preorder) #[node]

namespace Json

/-- Where the parser is: the characters left, and the byte offset of the
first of them. -/
structure Cursor where
  /-- The characters not yet read. -/
  rest : List Char
  /-- The byte offset of the first of them. -/
  offset : Nat

/-- A parser of the subset: it fails, with nothing, outside it. -/
abbrev Parser :=
  StateT Cursor (Except Unit)

/-- The next character, if any. -/
def peek : Parser (Option Char) :=
  return (← get).rest.head?

/-- The byte offset of the next character. -/
def here : Parser Nat :=
  return (← get).offset

/-- Moves past the next character. -/
def bump : Parser Unit :=
  modify fun cursor =>
    match cursor.rest with
    | [] => cursor
    | char :: rest => { rest, offset := cursor.offset + char.utf8Size }

/-- Fails: the text is outside the subset. -/
def fail {α : Type} : Parser α :=
  throw ()

/-- Whether `char` is a blank between values. -/
def isBlank (char : Char) : Bool :=
  char == ' ' || char == '\t' || char == '\n' || char == '\r'

/-- Moves past blanks. -/
partial def blanks : Parser Unit := do
  if (← peek).any isBlank then
    bump
    blanks

/-- Moves past the characters that `keep`, however many. -/
partial def skipWhile (keep : Char → Bool) : Parser Unit := do
  if (← peek).any keep then
    bump
    skipWhile keep

/-- The one-byte punctuation `text`, as an anonymous node. -/
def token (text : String) : Parser Node := do
  let start ← here
  unless (← peek) == text.toList.head? do
    fail
  bump
  return .mk text false none start (start + 1) #[]

/-- A word, `true`, `false` or `null`, as the named node of that kind. -/
def word (text : String) : Parser Node := do
  let start ← here
  for char in text.toList do
    unless (← peek) == some char do
      fail
    bump
  return .mk text true none start (← here) #[]

/-- A string with no escape. -/
def string : Parser Node := do
  let start ← here
  let opening ← token "\""
  let contentStart ← here
  skipWhile fun char => char != '"' && char != '\\' && char != '\n'
  let contentStop ← here
  let closing ← token "\""
  let content : Array Node :=
    if contentStop > contentStart then
      #[.mk "string_content" true none contentStart contentStop #[]]
    else #[]
  return .mk "string" true none start closing.stop (#[opening] ++ content ++ #[closing])

/-- Whether `char` is an ASCII digit. -/
def isDigit (char : Char) : Bool :=
  '0' ≤ char && char ≤ '9'

/-- A number, as one token. -/
def number : Parser Node := do
  let start ← here
  if (← peek) == some '-' then
    bump
  match ← peek with
  | some '0' =>
    bump
  | some char =>
    unless isDigit char do
      fail
    skipWhile isDigit
  | none =>
    fail
  if (← peek) == some '.' then
    bump
    skipWhile isDigit
  if (← peek) == some 'e' || (← peek) == some 'E' then
    bump
    if (← peek) == some '-' then
      bump
    unless (← peek).any isDigit do
      fail
    skipWhile isDigit
  return .mk "number" true none start (← here) #[]

mutual
/-- A value. -/
partial def value : Parser Node := do
  match ← peek with
  | some '{' =>
    object
  | some '[' =>
    array
  | some '"' =>
    string
  | some 't' =>
    word "true"
  | some 'f' =>
    word "false"
  | some 'n' =>
    word "null"
  | some char =>
    if char == '-' || isDigit char then
      number
    else
      fail
  | none =>
    fail
/-- A pair of an object. -/
partial def pair : Parser Node := do
  let key ← string
  blanks
  let colon ← token ":"
  blanks
  let value ← value
  return .mk "pair" true none key.start value.stop
      #[key.atField "key", colon, value.atField "value"]
/-- The items of a list from its opening token to its closing one, each read
by `item`, with `,` between them. -/
partial def items (opening closing : String) (item : Parser Node) : Parser (Array Node) := do
  let first ← token opening
  blanks
  if (← peek) == closing.toList.head? then
    return #[first, ← token closing]
  let mut nodes := #[first, ← item]
  repeat
    blanks
    if (← peek) != some ',' then
      break
    nodes := nodes.push (← token ",")
    blanks
    nodes := nodes.push (← item)
  return nodes.push (← token closing)
/-- An object. -/
partial def object : Parser Node := do
  let start ← here
  let children ← items "{" "}" pair
  return .mk "object" true none start (← here) children
/-- An array. -/
partial def array : Parser Node := do
  let start ← here
  let children ← items "[" "]" value
  return .mk "array" true none start (← here) children
end

/-- Every value of the text, with blanks before, between and after them. -/
partial def values : Parser (Array Node) := do
  blanks
  if (← peek).isNone then
    return #[]
  let first ← value
  return #[first] ++ (← values)

end Json

/-- The tree of `text` in the JSON grammar: a `document` over its values, or
over one `ERROR` node for a text outside the subset. -/
def Json.parse (text : String) : Node :=
  let length := text.utf8ByteSize
  match Json.values.run' { rest := text.toList, offset := 0 } with
  | .ok values => .mk "document" true none ((values[0]?.map (·.start)).getD length) length values
  | .error () =>
    let blanks := (text.toList.takeWhile Json.isBlank).foldl (· + ·.utf8Size) 0
    .mk "document" true none blanks length #[.mk "ERROR" true none blanks length #[]]

/-- The named kinds of the JSON grammar, `ERROR` among them. -/
def Json.namedKinds : List String :=
  ["document", "object", "pair", "array", "string", "string_content", "escape_sequence", "number",
    "true", "false", "null", "comment", "ERROR"]

/-- The anonymous kinds of the JSON grammar. -/
def Json.anonymousKinds : List String :=
  ["{", "}", "[", "]", ",", ":", "\""]

/-- The fields of the JSON grammar. -/
def Json.fields : List String :=
  ["key", "value"]

end Editor.SyntaxTreeModel
