import Editor.Evil.Objects
import Editor.SyntaxTree

/-!
# Text objects from a syntax tree

Six text objects whose ranges come from the syntax tree of a buffer's text,
entries of evil's vocabulary (`Editor/Vocabulary.lean`, "Text objects") in
`Evil.objects`: the function round the cursor, or inside its braces; the
class (a struct, enum, union, trait, impl or mod in Rust), or inside it; and
the argument, with its separator or alone. The ranges are the captures of
the text objects query the text keeps (`Mode.SyntaxTree.textObjects`,
`Editor/Highlight.lean`), asked of the library as plain rows
(`SyntaxTree.capturesOf`); which node an object is, is the rule here
(`TreeObjects.choose`), not the library's.

| Object | Name | Captures read |
|---|---|---|
| the function, or inside it | `a-function`, `inner-function` | `function.outer`, `function.inner` |
| the class, or inside it | `a-class`, `inner-class` | `class.outer`, `class.inner` |
| the argument with its separator, or alone | `an-argument`, `inner-argument` | `parameter.inner` |

The names follow nvim-treesitter-textobjects', so a config author can read
them; the rule is ours.

## The rule (`TreeObjects.choose`)

Over rows of a capture's name, start and stop:

1. **The object nodes** are the rows named `function.outer`, `class.outer`
   or `parameter.inner`, for a function, a class and an argument; each
   range once.
2. **The enclosing ones** are those with `start ≤ low` and `high < stop`,
   smallest first, where `low` and `high` are the selection's ends: both the
   head under an operator, or with a one-cell selection.
3. **A wider selection is extended**: in a visual state whose selection is
   wider than one cell, a node no bigger than the selection is passed over
   for the next one out, as the block objects do.
4. **The count** takes the `count`-th node (1 when none was typed); too few
   is no object. With no node round the cursor there is no object: a search
   forward is an open question.
5. **`inner-function` and `inner-class`** take the longest `function.inner`
   or `class.inner` row within the chosen node; with none (a unit struct, a
   function signature with no body) there is no object.

## What the text adds (`span`)

- **Inside brackets.** An inner range that starts with an opening bracket
  and ends with its partner (`{}`, `()` or `[]`) is Vim's inner block
  between them (`Evil.innerBetween`, the code `i{` runs): from the line
  after an opening bracket that ends its line, and up to the start of the
  closing bracket's line when only blanks are before it there, so an
  operator takes whole lines. Any other inner range is taken as it is,
  exclusive: a closure whose body is an expression.
- **Outer objects** are the node's range, exclusive: `d a f` is charwise.
  Taking whole lines when the function fills them is an open question.
- **`an-argument`**: when a comma follows the argument, blanks allowed
  before it, from the argument's start through that comma and the blanks
  after it, line breaks included, up to the next non-blank; otherwise, when
  a comma comes before it, blanks and line breaks allowed between, from that
  comma through the argument; otherwise the argument alone. The separator is
  a comma, which is every grammar's here.

A refusal of the syntax tree port is no object: a text not parsed with a
grammar (`notAttached`), one that keeps no text objects query (`noQuery`),
or one whose last edit's tree is not delivered yet (`notParsed`). Under an
operator the operate command then gives up with `noObjectHere`, and in a
visual state the selection is left as it was, as for any object that is not
there. Dot repeat replays an operator over an object by its name, so a
repeat asks the tree again.

Pinned by `ModelTest.treeObjectRuleChecks` (the rule, pure),
`ModelTest.evilObjectChecks` (by key, under the shipped Vim scheme, on a
test mode of the model's JSON grammar), and, real-only, by `ContractTest`'s
rows over the Rust fixture `tests/syntax/rust/objects.rs` and
`ConfigTest`'s `v a f` through the host's loop.
-/

namespace Editor.Evil.TreeObjects

/-- A capture of the text objects query, as the rule reads it: its name and
the range of its node. -/
structure Row where
  /-- The capture's name. -/
  name : String
  /-- The offset its node starts at. -/
  start : Nat
  /-- The offset its node stops at, not included. -/
  stop : Nat
  deriving DecidableEq, Repr

/-- Which object. -/
inductive Kind where
  /-- A function: `function.outer`, and inside it `function.inner`. -/
  | function
  /-- A class: `class.outer`, and inside it `class.inner`. -/
  | class
  /-- An argument: `parameter.inner`. -/
  | argument
  deriving DecidableEq, Repr

/-- The capture name of a node of the object `kind`. -/
def Kind.outer : Kind → String
  | .function => "function.outer"
  | .class => "class.outer"
  | .argument => "parameter.inner"

/-- The capture name of what is inside a node of the object `kind`, if it
has an inside. -/
def Kind.inner : Kind → Option String
  | .function => some "function.inner"
  | .class => some "class.inner"
  | .argument => none

/-- The capture names the rule reads. -/
def names : List String :=
  ["function.outer", "function.inner", "class.outer", "class.inner", "parameter.inner"]

/-- What the object `kind`, its inside when `inner`, covers, by the rule of
the module docs, from `rows`: asked of the selection from `low` through the
cell at `high`, `wider` when it is a visual selection wider than one cell,
taking the `count`-th node out. The range of its node, from its start up to
its stop; `none` when there is no object. -/
def choose (rows : Array Row) (kind : Kind) (inner : Bool) (low high : Nat) (wider : Bool)
    (count : Nat) : Option (Nat × Nat) := do
  let nodes :=
    (rows.filter (·.name == kind.outer)).foldl
      (fun kept row =>
        if kept.any (fun (start, stop) => start == row.start && stop == row.stop) then kept
        else kept.push (row.start, row.stop))
      #[]
  let enclosing :=
    (nodes.filter fun (start, stop) =>
          start ≤ low && high < stop && !(wider && stop - start ≤ high + 1 - low)).qsort
      fun (a, b) (c, d) => b - a < d - c
  let (start, stop) ← enclosing[count - 1]?
  if !inner then
    return (start, stop)
  let some name := kind.inner | return (start, stop)
  let within := rows.filter fun row => row.name == name && start ≤ row.start && row.stop ≤ stop
  let longest ←
    within.foldl
        (fun best row =>
          match best with
          | some (s, e) => if row.stop - row.start > e - s then some (row.start, row.stop) else best
          | none => some (row.start, row.stop))
        none
  return longest

/-- The bracket a pair of `{}`, `()` or `[]` closes with, for the opening
one `opening`. -/
def partner? (opening : String) : Option String :=
  match opening with
  | "{" => some "}"
  | "(" => some ")"
  | "[" => some "]"
  | _ => none

/-- Where the blanks from `p` end, line breaks included: the next non-blank,
or the text's end. -/
partial def pastBlanks (text : TextId) (p length : Nat) : TextM Nat := do
  if p ≥ length then
    return p
  let next ← text.motion .nextCell p
  if isBlankCell (← text.slice p next) || next == (← text.motion .lineStart next) && next > p then
    pastBlanks text next length
  else
    return p

/-- Where the blanks before `p` start, line breaks included: just after the
previous non-blank, or the text's start. -/
partial def beforeBlanks (text : TextId) (p : Nat) : TextM Nat := do
  if p == 0 then
    return p
  let previous ← text.motion .previousCell p
  let cell ← text.slice previous p
  if isBlankCell cell || cell == "\n" || cell == "\r\n" then
    beforeBlanks text previous
  else
    return p

/-- `an-argument`'s span over the argument from `start` up to `stop`, by
the separator rule of the module docs. -/
def withSeparator (text : TextId) (start stop : Nat) : TextM Vocabulary.Span := do
  let length ← text.byteLength
  let after ← pastBlanks text stop length
  if after < length then
    let next ← text.motion .nextCell after
    if (← text.slice after next) == "," then
      return { start, stop := ← pastBlanks text next length }
  let before ← beforeBlanks text start
  if before > 0 then
    let previous ← text.motion .previousCell before
    if (← text.slice previous before) == "," then
      return { start := previous, stop }
  return { start, stop }

/-- What the object `kind`, its inside when `inner`, covers in `text`,
asked from `within` (the module docs): `none` where there is no object,
the syntax tree port's refusals included. -/
def span (text : TextId) (kind : Kind) (inner : Bool) (within : Vocabulary.Within) :
    EditorM (Option Vocabulary.Span) :=
  text.withSnapshot fun snapshot => do
    let anchor := within.anchor.getD within.head
    let low := min anchor within.head
    let high := max anchor within.head
    let length ← text.byteLength
    let asked ←
      if high < length then
        text.motion .nextCell high
      else
        pure high
    let .ok kept ←
      SyntaxTree.lift (SyntaxTree.capturesOf snapshot .textObjects low asked) | return none
    let rows :=
      kept.captures.filterMap fun capture =>
        (kept.names[capture.capture]?).map fun name =>
          { name, start := capture.start, stop := capture.stop : Row }
    let wider := within.anchor.isSome && anchor != within.head
    let some (start, stop) := choose rows kind inner low high wider (within.count.getD 1)
      | return none
    if kind == .argument then
      if inner then
        return some { start, stop }
      return some (← withSeparator text start stop)
    if !inner || stop ≤ start then
      return some { start, stop }
    let closing ← text.motion .previousCell stop
    let first ← text.slice start (← text.motion .nextCell start)
    let final ← text.slice closing stop
    if start < closing && partner? first == some final then
      return some (← innerBetween text start closing within.anchor.isSome)
    return some { start, stop }

/-- The tree's text object called `name`: the object `kind`, its inside when
`inner`. -/
def object (name : String) (kind : Kind) (inner : Bool) : Vocabulary.TextObject :=
  { name, span := fun text within => span text kind inner within }

end TreeObjects

/-- The function round the cursor, evil-textobj-tree-sitter's `af`. -/
def aFunction : Vocabulary.TextObject :=
  TreeObjects.object "a-function" .function false

/-- Inside the function round the cursor: its body, inside its braces. -/
def innerFunction : Vocabulary.TextObject :=
  TreeObjects.object "inner-function" .function true

/-- The class round the cursor: a struct, enum, union, trait, impl or mod in
Rust. -/
def aClass : Vocabulary.TextObject :=
  TreeObjects.object "a-class" .class false

/-- Inside the class round the cursor: its body, inside its braces. -/
def innerClass : Vocabulary.TextObject :=
  TreeObjects.object "inner-class" .class true

/-- The argument round the cursor, with its separator. -/
def anArgument : Vocabulary.TextObject :=
  TreeObjects.object "an-argument" .argument false

/-- The argument round the cursor, alone. -/
def innerArgument : Vocabulary.TextObject :=
  TreeObjects.object "inner-argument" .argument true

/-- The table the operate and select commands look a text object's name up
in: Vim's own (`vimObjects`) and the syntax tree's, one entry for each name
the Vim scheme's default tables bind a key to. -/
def objects : Array Vocabulary.TextObject :=
  vimObjects ++ #[aFunction, innerFunction, aClass, innerClass, anArgument, innerArgument]

end Editor.Evil
