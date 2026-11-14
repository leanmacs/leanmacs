/-!
# Roles

A role is a standard action that a mode fills with a command of its own and
that each input scheme puts on a key once: next and previous item, activate,
quit, refresh, toggle and mark (`docs/design/keymaps-and-modes.md`,
"Roles"). A mode names the roles it fills (`Editor/Mode.lean`) and never a
key, so it works under any scheme; a scheme's role table
(`InputScheme.roles`, `Editor/InputScheme.lean`) says which keys each role
is on.

## The role set

`Role.registered` is the set the core curates. A role is a name, not a
constructor of a closed type, so that a mode can name one that is not
registered and `Mode.check` can report it.

## The rule for adding a role

A role is a standard action that recurs, with one meaning, in modes that
have nothing else in common. An action of one mode, or of one family of
related modes, is a leader suffix (or lives on a parent mode). Config
cannot add a role.

## Where an addition goes

| Addition | Where |
|---|---|
| A new role | A constant here and an entry of `registered`, and a row in the role table of every scheme in the repository (the Vim scheme's, `Editor/InputScheme/Vim/Default.lean`, and the test scheme's, `Editor/InputScheme/Test.lean`), in one commit: the scheme contract fails a scheme without the row |
| Renaming or removing a role | Here, the schemes' tables, and every mode that fills it |

Pinned by `ModelTest.modeRecordChecks`.
-/

namespace Editor

/-- A role: a standard action a mode fills and a scheme puts on a key, by
its name. -/
structure Role where
  /-- The role's name. -/
  name : String
  deriving DecidableEq, Repr

namespace Role

/-- Go to the next item of a list. -/
def nextItem : Role :=
  { name := "next-item" }

/-- Go to the previous item of a list. -/
def previousItem : Role :=
  { name := "previous-item" }

/-- Act on the item at point: open it, follow it, run it. -/
def activate : Role :=
  { name := "activate" }

/-- Leave the buffer. -/
def quit : Role :=
  { name := "quit" }

/-- Make the buffer again from what it shows. -/
def refresh : Role :=
  { name := "refresh" }

/-- Fold or unfold, show or hide, the item at point. -/
def toggle : Role :=
  { name := "toggle" }

/-- Mark the item at point for a later action. -/
def mark : Role :=
  { name := "mark" }

/-- The roles the core registers, in order. -/
def registered : List Role :=
  [nextItem, previousItem, activate, quit, refresh, toggle, mark]

end Role

end Editor
