import Editor.Command
import Editor.Command.Call

/-!
# The vocabulary

The parts of speech of editing, as data that any input scheme can use
(`docs/design/keymaps-and-modes.md`, "Vocabulary"). The grammar belongs to
a scheme; the vocabulary belongs to everyone: the word motion is the same
value whether a scheme composes it as `dw`, as select-then-delete, or as
one command. This module names no scheme and no key. An input scheme names
an entry by its name, a `String`, and the entry is looked up when the
invocation runs.

Three parts of speech are here: the motion, the operator and the text
object.

## Motions

A motion (`Motion`) is a name and a function from where a cursor is
(`From`) to where it goes (`To`).

- **It answers the raw target**: the position the motion leads to, never
  clamped to where a cursor may rest. Resting is a rule of the caller's
  (`Editor/Evil.lean`, "Where a cursor rests"), and an operator needs the
  raw target: a deletion to the next word's start on the last word wants
  the text's end.
- **No count is not a count of 1** (`From.count`, optional): a motion to a
  line reads a count as the line's number, so a count of 1 and no count
  differ. A motion that repeats reads none as 1.
- **A motion asks the text, and the display where a column is the
  display's, and changes nothing.** That is the entry's rule and no longer
  the type's: a motion's target is a command (`EditorM`), so that a motion
  whose column is the display's can ask the display for it, and the type
  would let an entry edit the editor state or publish. No entry does. An
  entry that asks only the text is written over the text port and lifts.
- **The wanted column goes in and comes out as data** (`From.wanted`,
  `To.wanted`, a `WantedColumn` of the editor state, `Editor/State.lean`,
  "The wanted column"). A motion is not handed the window, so its caller
  hands it the column the view keeps, when that column still holds, and
  keeps for the view what the motion hands back, with the position the
  cursor comes to rest at. A vertical motion aims for the column it is
  handed and hands it back; a motion that hands back none makes the view
  keep none.
- **A motion that could not move may keep what was kept** (`To.unmoved`,
  which is `To.wanted` unless the motion says another): the column the
  view keeps when the cursor comes to rest where it started. It is a field
  of its own because a motion cannot tell that it did not move: its raw
  target may be a position the caller's resting rule brings back.

- **A motion says how an operator takes it** (`Motion.reach`, a `Reach`):
  up to its target (`exclusive`, which is the default), through the cell at
  its target (`inclusive`), or the whole lines of both ends (`lines`). Only
  an operator reads it.
- **Where a motion leads under an operator may be another place than where
  it leads a cursor** (`Motion.taken`, which answers a `Taken`): it is told
  whether the operator puts an insert in place of what it takes, and
  answers the position with the reach. By default it is `target` with the
  motion's `reach`, so a motion that leads an operator where it leads a
  cursor says nothing more.
- **A motion says when it could not be made** (`To.failed`, `Taken.failed`),
  as Vim fails a motion that has nowhere to go, or that has gone as far as
  it can with steps left over. An operator that waits for it is cancelled
  by its caller, which leaves the cursor at the position the motion
  answers (`Editor/Evil/Operators.lean`). The move command does not read
  it: the cursor goes to the target the motion answers.
- **A motion may take an argument** (`From.argument`): the character its
  key's next key named, for `f`, `t`, `F` and `T`. A motion that takes one
  and is given none fails where it is.
- **What is remembered between motions goes out as data too**: a find
  hands back the character find it made (`To.find`), and its caller keeps
  it as the last one (`EditorState.lastFind`), which `;` and `,` read from
  the editor state; a search hands back the search it made (`To.search`),
  kept as `EditorState.lastSearch`, which `n` and `N` read. A motion that
  has something for the echo area hands
  it back (`To.said`), and its caller says it. `Taken` carries both, and
  its default copies them from `To`.

## Operators

An operator (`Operator`) is a name and what it does with what it is handed
(`act`, a command's body: a function of the call and of an `Operand`).

- **What an operator acts on is worked out by its caller** and handed to it
  as a stretch (`Stretch`): cells, as one extent of the text with the reach
  they were taken by, or whole lines, as the rows of the first and the
  last. What a motion, a doubled key or a selection amounts to is the
  caller's rule (`Editor/Evil/Operators.lean`), so an operator is written
  once for all three.
- **An operand also carries** the head the operator was called at, where a
  cursor that is left alone is to rest (`rest`), the register the call
  named, and the selection from before the command (`before`), which an
  operator's edit carries so that an undo hands it back.
- **Two flags say how the caller works the stretch out**, so that no caller
  matches on an operator's name: `replaces`, for an operator that puts an
  insert in place of what it takes, which a motion's `taken` is told; and
  `linesOverBlanks`, for one that takes whole lines where its cells run
  from a line's indent to the blanks at the end of a later line.

An operator's `act` is a command's body, so this module imports the
editor's port (`Editor/Command.lean`) and the call
(`Editor/Command/Call.lean`); it still names no scheme and no key.

## Text objects

A text object (`TextObject`) is a name and a function from where it is asked
from (`Within`) to what it covers (`Span`), or `none` where there is no
object, as Vim fails a text object.

- **It is asked from the head**, with the count, and in a visual state with
  the selection's other end (`Within.anchor`), since a visual state extends
  a selection that is wider than one cell where an operator takes the
  object afresh. Under an operator the anchor is none.
- **What it covers is a start and a stop with a reach** (`Span`): under an
  operator, from `start` up to `stop` when the reach is `exclusive`, and
  through the cell at `stop` when it is `inclusive`, which is Vim's own
  pair of an object's end and whether it is inclusive. An operator takes a
  span as it takes a motion's target from `start`, so Vim's rules for an
  exclusive end at a line's start and for a deletion over lines apply to
  it, as Vim applies them (`Editor/Evil/Operators.lean`, "What an operator
  takes"). In a visual state `start` is the selection's new anchor and
  `stop` its new head, or the cell before `stop` when the reach is
  `exclusive`; the two may be in either order.
- **Its function is a command** (`EditorM`), as a motion's target is, so
  that an object that asks more than the text has the same shape: the
  syntax tree's objects ask the text's kept text objects query
  (`Editor/Evil/TreeObjects.lean`). It changes nothing: the entry's rule, which its type does
  not enforce.

## Where an addition goes

| Addition | Where |
|---|---|
| A new motion | An entry, a `Motion` value, in the table its command looks names up in (`Editor/Evil/Motions.lean`) |
| Something every motion is told of where it starts | A field of `From` |
| Something every motion says of where it leads | A field of `To`, with a default |
| How an operator takes a motion | The motion's `reach`, or its `taken` when the position differs too |
| A new operator | An entry, an `Operator` value, in the table its command looks names up in (`Editor/Evil/Operators.lean`) |
| Something every operator is told of what it acts on | A field of `Operand` |
| A new text object | An entry, a `TextObject` value, in the table its commands look names up in (`Editor/Evil/Objects.lean`) |
| Something every text object is told of where it is asked from | A field of `Within` |
| A new part of speech | A record here, beside `Motion`, `Operator` and `TextObject` |

Pinned through the motions that are entries, by
`ModelTest.evilMotionChecks`, through the operators that are, by
`ModelTest.evilOperatorChecks`, and through the text objects that are, by
`ModelTest.evilObjectChecks`.
-/

namespace Editor.Vocabulary

/-- Where a motion starts, and how it was asked for. -/
structure From where
  /-- The position the cursor is at. -/
  head : Nat
  /-- The count typed, if one was. None is not a count of 1. -/
  count : Option Nat := none
  /-- The wanted column the view keeps, when it still holds: when the cursor
  is where it was left when the column was kept. -/
  wanted : Option WantedColumn := none
  /-- The argument its key gave the motion, if it takes one: a character for
  `f`, a pattern for `/`. -/
  argument : Option String := none
  deriving DecidableEq, Repr

/-- Where a motion leads. -/
structure To where
  /-- The raw target: the position the motion leads to, not clamped to where
  a cursor may rest. -/
  head : Nat
  /-- The wanted column the view is to keep with the cursor where it comes
  to rest; `none` to keep none. -/
  wanted : Option WantedColumn := none
  /-- The wanted column the view is to keep when the cursor comes to rest
  where it started: `wanted`, unless the motion says another. A motion
  that could not move may keep what was kept, and cannot tell by itself
  that it could not: where a cursor rests is its caller's rule. -/
  unmoved : Option WantedColumn := wanted
  /-- Whether the motion could not be made, as Vim fails a motion: an
  operator that waits for it is cancelled. A cursor is moved to `head` all
  the same. -/
  failed : Bool := false
  /-- What the echo area is to say of the motion, if anything: a warning,
  or why it failed. Its caller says it. -/
  said : Option String := none
  /-- The character find the motion made, for its caller to keep as the
  last one (`EditorState.lastFind`), which `;` and `,` repeat; `none` to
  keep the one there was. -/
  find : Option Find := none
  /-- The search the motion made, for its caller to keep as the last one
  (`EditorState.lastSearch`), which `n` and `N` repeat; `none` to keep the
  one there was. -/
  search : Option Search := none
  deriving DecidableEq, Repr

/-- How an operator takes the cells between the head and a motion's
target. -/
inductive Reach where
  /-- From the lower of the two up to, not including, the higher. -/
  | exclusive
  /-- From the lower of the two through the cell at the higher. -/
  | inclusive
  /-- The whole lines of both, and those between. -/
  | lines
  deriving DecidableEq, Repr

/-- Where a motion leads when an operator waits for it. -/
structure Taken where
  /-- The position the motion leads to, not clamped. -/
  head : Nat
  /-- How the operator takes what lies between. -/
  reach : Reach
  /-- Whether the motion could not be made: the operator is cancelled, and
  the cursor is left at `head`. -/
  failed : Bool := false
  /-- What the echo area is to say, as `To.said`. -/
  said : Option String := none
  /-- The character find the motion made, as `To.find`. -/
  find : Option Find := none
  /-- The search the motion made, as `To.search`. -/
  search : Option Search := none
  deriving DecidableEq, Repr

/-- A motion: its name, by which an input scheme's binding names it, and
where it leads from a position of a text. -/
structure Motion where
  /-- The motion's vocabulary name. -/
  name : String
  /-- Where the motion leads in `text` from where the cursor is. It asks the
  text, and the display where a column is the display's, and changes
  nothing: the entry's rule, which its type does not enforce. -/
  target : TextId → From → EditorM To
  /-- How an operator takes the motion. -/
  reach : Reach := .exclusive
  /-- Where the motion leads in `text` when an operator waits for it, told
  whether the operator puts an insert in place of what it takes: `target`
  with `reach`, unless the motion says another. It changes nothing, as
  `target` changes nothing. -/
  taken : Bool → TextId → From → EditorM Taken := fun _ text origin => do
    let to ← target text origin
    return {
        head := to.head, reach, failed := to.failed, said := to.said, find := to.find
        search := to.search }

/-- What an operator acts on. -/
inductive Stretch where
  /-- The cells of `extent`, taken by `reach`: an extent that is empty is no
  cell. -/
  | cells (extent : Extent) (reach : Reach)
  /-- The whole lines from the row `first` through the row `last`. -/
  | lines (first last : Nat)
  deriving DecidableEq, Repr

/-- What an operator is handed. -/
structure Operand where
  /-- What it acts on. -/
  stretch : Stretch
  /-- The head of the selection it was called at. -/
  head : Nat
  /-- Where an operator that changes no text leaves the cursor, before it is
  rested. -/
  rest : Nat
  /-- The register the call named; the empty name when it named none. -/
  register : String
  /-- The selection from before the command, which the operator's edit
  carries. -/
  before : Selection
  deriving DecidableEq, Repr

/-- An operator: its name, by which an input scheme's binding names it, and
what it does with what it is handed. -/
structure Operator where
  /-- The operator's vocabulary name. -/
  name : String
  /-- Whether it puts an insert in place of what it takes, which a motion's
  `taken` is told. -/
  replaces : Bool := false
  /-- Whether cells that run from a line's indent to the blanks at the end
  of a later line are whole lines for it. -/
  linesOverBlanks : Bool := false
  /-- What it does, as a command's body: a function of its call and of what
  it acts on. -/
  act : Call → Operand → EditorM Unit

/-- Where a text object is asked from. -/
structure Within where
  /-- The position the cursor is at: the selection's head. -/
  head : Nat
  /-- The count typed, if one was. None is not a count of 1. -/
  count : Option Nat := none
  /-- The selection's other end, in a visual state; none under an
  operator. -/
  anchor : Option Nat := none
  deriving DecidableEq, Repr

/-- What a text object covers ("Text objects", in the module docs). -/
structure Span where
  /-- Where it starts; in a visual state, the selection's new anchor. -/
  start : Nat
  /-- Where it stops: the position after it when the reach is `exclusive`,
  and its last cell when it is `inclusive`; in a visual state, the
  selection's new head, or the cell before it when exclusive. -/
  stop : Nat
  /-- How `stop` is read: `exclusive` or `inclusive`. -/
  reach : Reach := .exclusive
  deriving DecidableEq, Repr

/-- A text object: its name, by which an input scheme's binding names it,
and what it covers in a text. -/
structure TextObject where
  /-- The object's vocabulary name. -/
  name : String
  /-- What the object covers in `text`, asked from `within`; `none` where
  there is no object. It changes nothing: the entry's rule, which its type
  does not enforce. -/
  span : TextId → Within → EditorM (Option Span)

end Editor.Vocabulary
