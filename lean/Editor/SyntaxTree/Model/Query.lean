import Editor.SyntaxTree.Model.Json

/-!
# The syntax tree model's queries

The subset of the library's query language the model implements, over the
JSON grammar's tables (`Editor/SyntaxTree/Model/Json.lean`):

- **Patterns.** `(kind child*)` for a named node of a kind, `(_ child*)` for
  any named node, `_` for any node, named or not, and `"literal"` for an
  anonymous node of that text. A query is one or more top-level patterns,
  numbered in the order they come in its source.
- **Children.** A child pattern, `field: pattern` or `pattern`, matches a
  child of the node; the child patterns of a node match an ordered
  subsequence of its children, any others skipped, and one with a field
  only a child at that field. Every way the children can be matched is a
  match: the library's own way when no two sibling patterns could match the
  same child, which is how the contract's cases are written.
- **Captures.** `@name` after a pattern, at the top or as a child, captures
  the node it matched. A name is numbered where it first appears in the
  source, across every pattern.
- **Comments.** `;` to the end of the line.

Refused, with the offset of the byte where it was found:

- **`unsupported`**: what the library would accept and the model does not
  implement: a quantifier (`*`, `+`, `?`), an alternation (`[`), an anchor
  (`.`), a negated field (`!`), a predicate (`(#…)`) and a grouping of
  sibling patterns (`((…) (…))`).
- **`nodeType`**: a kind or a literal the grammar does not have.
- **`field`**: a field the grammar does not have.
- **`syntax`**: anything else that is not a query.

**What a query answers** (`Query.captures`) is every match's captures, at
every node of the tree, in pre-order; then those in the range, each once, in
the core's order (`SyntaxTree.sorted`, `SyntaxTree.overlaps`), as the Rust
core's `captures_in` answers.
-/

namespace Editor.SyntaxTreeModel

/-- What node a pattern matches. -/
inductive Kind where
  /-- A named node of this kind. -/
  | named (kind : String)
  /-- Any named node: `(_)`. -/
  | anyNamed
  /-- Any node, named or not: `_`. -/
  | any
  /-- An anonymous node of this text. -/
  | literal (text : String)
  deriving DecidableEq, Repr

/-- A pattern: the field it must be at, if it is a child pattern with one,
what node it matches, its child patterns, and the captures it makes. -/
inductive Pattern where
  /-- The pattern. -/
  | mk (field : Option String) (kind : Kind) (children : List Pattern) (captures : List Nat)

instance : Inhabited Pattern :=
  ⟨.mk none .any [] []⟩

/-- A compiled query: its top-level patterns, in order, and its capture
names, by index. -/
structure Query where
  /-- The patterns. -/
  patterns : Array Pattern
  /-- The capture names. -/
  names : Array String

namespace QueryParse

/-- Where the parser is: the characters left, the byte offset of the first
of them, and the capture names so far. -/
structure Cursor where
  /-- The characters not yet read. -/
  rest : List Char
  /-- The byte offset of the first of them. -/
  offset : Nat
  /-- The capture names so far, by index. -/
  names : Array String

/-- A parser of a query's source, refused with a kind and an offset. -/
abbrev Parser :=
  StateT Cursor (Except (QueryErrorKind × Nat))

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
    | char :: rest =>
      { cursor with
        rest, offset := cursor.offset + char.utf8Size }

/-- Refuses the query for `kind`, at the next character. -/
def refuse {α : Type} (kind : QueryErrorKind) : Parser α := do
  throw (kind, ← here)

/-- Moves past blanks and comments. -/
partial def skip : Parser Unit := do
  match ← peek with
  | some ';' =>
    repeat
      match ← peek with
      | some '\n' | none =>
        break
      | some _ =>
        bump
    skip
  | some char =>
    if char.isWhitespace then
      bump
      skip
  | none =>
    pure ()

/-- Whether `char` may be in a kind's or a field's name. -/
def isNameChar (char : Char) : Bool :=
  char.isAlphanum || char == '_'

/-- Whether `char` may be in a capture's name. -/
def isCaptureChar (char : Char) : Bool :=
  isNameChar char || char == '.' || char == '-'

/-- The characters that `keep`, however many, as a string. -/
partial def takeWhile (keep : Char → Bool) (taken : String := "") : Parser String := do
  match ← peek with
  | some char =>
    if keep char then
      bump
      takeWhile keep (taken.push char)
    else
      return taken
  | none =>
    return taken

/-- The index of the capture `name`, numbered now if it is new. -/
def captureIndex (name : String) : Parser Nat := do
  let cursor ← get
  match cursor.names.findIdx? (· == name) with
  | some index =>
    return index
  | none =>
    set { cursor with names := cursor.names.push name }
    return cursor.names.size

/-- Refuses a quantifier after a pattern as unsupported. -/
def noQuantifier : Parser Unit := do
  if (← peek).any fun char => char == '*' || char == '+' || char == '?' then
    refuse .unsupported

/-- The captures after a pattern, however many. -/
partial def captures (taken : List Nat := []) : Parser (List Nat) := do
  skip
  noQuantifier
  if (← peek) != some '@' then
    return taken
  bump
  let name ← takeWhile isCaptureChar
  if name.isEmpty then
    refuse .syntax
  captures (taken ++ [← captureIndex name])

/-- What a kind's name in parens matches: `_` any named node, a named kind
of the grammar that kind; anything else is refused at `spot`. -/
def kindOf (name : String) (spot : Nat) : Parser Kind :=
  if name == "_" then pure .anyNamed
  else if Json.namedKinds.contains name then pure (.named name) else throw (.nodeType, spot)

mutual
/-- One pattern, at `field` if it is a child pattern with one, with its
captures. -/
partial def pattern (field : Option String) : Parser Pattern := do
  skip
  match ← peek with
  | some '(' =>
    bump
    skip
    match ← peek with
    | some '#' =>
      refuse .unsupported
    | some '(' =>
      -- A grouping of sibling patterns: refused, unless what is in it is
      -- no query at all, which is a refusal of its own.
      let spot ← here
      discard (pattern none)
      throw (.unsupported, spot)
    | _ =>
      pure ()
    let spot ← here
    let name ← takeWhile isNameChar
    if name.isEmpty then
      refuse .syntax
    let kind ← kindOf name spot
    let children ← childPatterns
    return .mk field kind children (← captures)
  | some '"' =>
    bump
    let spot ← here
    let text ← takeWhile (· != '"')
    if (← peek) != some '"' then
      refuse .syntax
    bump
    unless Json.anonymousKinds.contains text do
      throw (.nodeType, spot)
    return .mk field (.literal text) [] (← captures)
  | some '_' =>
    bump
    if (← peek).any isNameChar then
      refuse .syntax
    return .mk field .any [] (← captures)
  | some '[' =>
    refuse .unsupported
  | _ =>
    refuse .syntax
/-- The child patterns of a pattern in parens, up to and past its `)`. -/
partial def childPatterns (taken : List Pattern := []) : Parser (List Pattern) := do
  skip
  match ← peek with
  | some ')' =>
    bump
    return taken
  | some '!' | some '.' =>
    refuse .unsupported
  | some char =>
    if isNameChar char && char != '_' then
      -- A field: its name, then `:`.
      let spot ← here
      let name ← takeWhile isNameChar
      skip
      if (← peek) != some ':' then
        refuse .syntax
      bump
      unless Json.fields.contains name do
        throw (.field, spot)
      childPatterns (taken ++ [← pattern (some name)])
    else
      childPatterns (taken ++ [← pattern none])
  | none =>
    refuse .syntax
end

/-- Every top-level pattern of the source. -/
partial def patterns (taken : Array Pattern := #[]) : Parser (Array Pattern) := do
  skip
  if (← peek).isNone then
    return taken
  patterns (taken.push (← pattern none))

end QueryParse

/-- The query `source` spells in the model's subset, or why not: a kind and
the byte offset where it was found. -/
def Query.compile (source : String) : Except (QueryErrorKind × Nat) Query :=
  match QueryParse.patterns.run { rest := source.toList, offset := 0, names := #[] } with
  | .ok (patterns, cursor) => .ok { patterns, names := cursor.names }
  | .error refusal => .error refusal

namespace Pattern

/-- The field it must be at. -/
def field : Pattern → Option String
  | .mk field .. => field

/-- Whether `kind` matches `node`. -/
def kindMatches : Kind → Node → Bool
  | .named kind, node => node.named && node.kind == kind
  | .anyNamed, node => node.named
  | .any, _ => true
  | .literal text, node => !node.named && node.kind == text

mutual
/-- Every way `pattern` matches `node`, each as the captures it makes: a
capture's index and the node it captured. -/
partial def matchesAt (pattern : Pattern) (node : Node) : List (List (Nat × Node)) :=
  match pattern with
  | .mk _ kind children captures =>
    if kindMatches kind node then
      (align children node.children.toList).map fun found => captures.map (·, node) ++ found
    else []
/-- Every way `patterns` match an ordered subsequence of `nodes`, each child
pattern with a field only a node at that field. -/
partial def align (patterns : List Pattern) (nodes : List Node) : List (List (Nat × Node)) :=
  match patterns, nodes with
  | [], _ => [[]]
  | _ :: _, [] => []
  | first :: others, node :: later =>
    let here :=
      if first.field.all (node.field == some ·) then
        (matchesAt first node).flatMap fun found => (align others later).map (found ++ ·)
      else []
    here ++ align patterns later
end

end Pattern

/-- What `query` answers of `tree` in the range from `first` to `last`:
every match's captures at every node, those in the range, each once, in the
core's order. -/
def Query.captures (query : Query) (tree : Node) (first last : Nat) : Array SyntaxTree.Capture :=
  let all :=
    tree.preorder.foldl
      (fun found node =>
        (query.patterns.zipIdx).foldl
          (fun found (pattern, index) =>
            (pattern.matchesAt node).foldl
              (fun found captured =>
                captured.foldl
                  (fun found (capture, node) =>
                    found.push
                      { pattern := index, capture, start := node.start, stop := node.stop })
                  found)
              found)
          found)
      #[]
  SyntaxTree.sorted
    (all.filter fun capture => SyntaxTree.overlaps capture.start capture.stop first last)

end Editor.SyntaxTreeModel
