import Editor.InputScheme

/-!
# The Vim scheme

Vim's grammar as one input scheme: keys in, an invocation out. It is the
grammar only. What a motion or an operator does to a text is the
vocabulary's, and is not here (`docs/design/keymaps-and-modes.md`, "The Vim
scheme").

## Edits

A key sequence parses to an `Edit`, and an edit compiles to an invocation
(`Edit.compile`):

| Edit | Invocation |
|---|---|
| `move m c` | `moveCommand`, with `[.str m, .nat c]` |
| `operate o over c r` | `operateCommand`, with `[.str o.name, .str kind, .str name, .nat c, .str r]`. Kind and name are `motion` and the motion, `text-object` and the object, `lines` and `""`, `selection` and `""` |
| `run cmd c r` | `cmd.name`, with `[.nat c, .str r]` |

- **Every part of speech is named by its vocabulary name**, a `String`, so
  no vocabulary entry need exist for the grammar to parse.
- **An absent count is `.nat 0`** and an absent register `.str ""`: an
  invocation's arguments have no optional kind, and a typed count is never
  0. In an edit they stay optional, since no count is not a count of 1.
- **An operator and a command carry what the grammar cannot look up**:
  whether an edit with it changes text (`Edit.changes`) and which Vim state
  the view is in afterwards (`Edit.enters`).

## Where an addition goes

| Addition | Where |
|---|---|
| A new target of an operator | A variant of `Over`, and its row in `Edit.compile` |
| A new fact about an operator or a command that the grammar needs | A field of `Operator` or of `Command` |

Pinned by `ModelTest.vimEditChecks`.
-/

namespace Editor.Vim

/-- An operator, as a key is bound to it: its name, and what the grammar
must know of it. -/
structure Operator where
  /-- Its vocabulary name. -/
  name : String
  /-- Whether an edit with it changes text. -/
  changes : Bool := true
  /-- The Vim state the view is in after an edit with it, if it names one. -/
  enters : Option String := none
  deriving DecidableEq, Repr

/-- A command, as a key is bound to it: its name, and what the grammar must
know of it. -/
structure Command where
  /-- The command's name, as the registry names it. -/
  name : String
  /-- Whether running it changes text. -/
  changes : Bool := false
  /-- The Vim state the view is in after it runs, if it names one. -/
  enters : Option String := none
  deriving DecidableEq, Repr

/-- What an operator acts on. -/
inductive Over where
  /-- What the motion of this vocabulary name covers. -/
  | motion (name : String)
  /-- The text object of this vocabulary name. -/
  | textObject (name : String)
  /-- Whole lines: the operator's key typed twice. -/
  | lines
  /-- The view's selection, in a visual state. -/
  | selection
  deriving DecidableEq, Repr

/-- What a key sequence parses to. A count is absent when no digit was
typed, and a register when none was named. -/
inductive Edit where
  /-- Move by a motion. -/
  | move (motion : String) (count : Option Nat)
  /-- Apply an operator to a target. -/
  | operate (operator : Operator) (over : Over) (count : Option Nat) (register : Option String)
  /-- Run a command. -/
  | run (command : Command) (count : Option Nat) (register : Option String)
  deriving DecidableEq, Repr

/-- The name of the command a move compiles to. -/
def moveCommand : String :=
  "move"

/-- The name of the command an edit with an operator compiles to. -/
def operateCommand : String :=
  "operate"

namespace Edit

/-- Whether the edit changes text: its operator's or its command's word for
it, and never a move. -/
def changes : Edit → Bool
  | .move .. => false
  | .operate operator .. => operator.changes
  | .run command .. => command.changes

/-- The Vim state the view is in after the edit, if its operator or its
command names one. -/
def enters : Edit → Option String
  | .move .. => none
  | .operate operator .. => operator.enters
  | .run command .. => command.enters

/-- The invocation the edit compiles to (the table in the module docs). -/
def compile : Edit → Invocation
  | .move motion count =>
    { command := moveCommand, arguments := [.str motion, .nat (count.getD 0)] }
  | .operate operator over count register =>
    let (kind, name) :=
      match over with
      | .motion name => ("motion", name)
      | .textObject name => ("text-object", name)
      | .lines => ("lines", "")
      | .selection => ("selection", "")
    { command := operateCommand
      arguments :=
        [.str operator.name, .str kind, .str name, .nat (count.getD 0), .str (register.getD "")] }
  | .run command count register =>
    { command := command.name, arguments := [.nat (count.getD 0), .str (register.getD "")] }

end Edit

end Editor.Vim
