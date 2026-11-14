import Editor.State

/-!
# The vocabulary

The parts of speech of editing, as data that any input scheme can use
(`docs/design/keymaps-and-modes.md`, "Vocabulary"). The grammar belongs to
a scheme; the vocabulary belongs to everyone: the word motion is the same
value whether a scheme composes it as `dw`, as select-then-delete, or as
one command. This module names no scheme and no key. An input scheme names
an entry by its name, a `String`, and the entry is looked up when the
invocation runs.

One part of speech is here: the motion.

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
- **A motion asks the text port and changes nothing**: its type is `TextM`,
  so it cannot edit the editor state or publish. A motion by display lines
  needs the display port and is not here; when one is built the type
  widens, and these entries lift unchanged.
- **The wanted column goes in and comes out as data** (`From.wanted`,
  `To.wanted`, a `WantedColumn` of the editor state, `Editor/State.lean`,
  "The wanted column"). A motion cannot read the window, so its caller
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

What is not on the record yet: a motion's type for an operator (exclusive,
inclusive or line-wise), which only operators read.

## Where an addition goes

| Addition | Where |
|---|---|
| A new motion | An entry, a `Motion` value, in the table its command looks names up in (`Editor/Evil/Motions.lean`) |
| Something every motion is told of where it starts | A field of `From` |
| Something every motion says of where it leads | A field of `To`, with a default |
| A new part of speech (an operator, a text object) | A record here, beside `Motion` |

Pinned through the motions that are entries, by `ModelTest.evilMotionChecks`.
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
  deriving DecidableEq, Repr

/-- A motion: its name, by which an input scheme's binding names it, and
where it leads from a position of a text. -/
structure Motion where
  /-- The motion's vocabulary name. -/
  name : String
  /-- Where the motion leads in `text` from where the cursor is. It asks the
  text and changes nothing. -/
  target : TextId → From → TextM To

end Editor.Vocabulary
