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

## The grammar

`parse` is one key: the state it leaves and what the key parsed to. `step`
is `parse` with the edit compiled, and `scheme` packages it as an
`InputScheme` over a registry of Vim states. The rules:

- **A key is walked through the active keymaps, then the Vim state's**
  (`Keymap.walk` over `maps view ++ states.initial.keymaps`: every view is
  in the initial state, since nothing enters another yet). The active keymaps
  are the specific ones, so a binding of theirs replaces a default. It is
  one walk, so prefixes merge across the two lists, and a part of speech
  bound in an active keymap is the same to the grammar as one bound in a
  state's keymap.
- **A motion alone is a move**, and **a command is run**.
- **An operator waits for its target** (`State.operator`). There is no
  keymap for the wait: the motion that moves when typed alone is the
  operator's target when typed after it, so a motion bound once, in any
  keymap, works with every operator.
- **A text object after an operator is its target.** With no operator
  waiting it resets.
- **The operator that is waiting, typed again, acts on lines**
  (`Over.lines`), and that edit always has a count, 1 when none was typed:
  the doubled operator counts lines. It is the same operator when it has
  the same name.
- **A different operator, or a command, while an operator waits resets.**
- **An unbound key resets the edit begun**: nothing is yielded, no operator
  waits, no prefix is walked, and the state is the initial state.
- **`pending` is every key of the edit begun** (`State.typed`), as chords.

## Vim states

A Vim state (normal, insert, a visual state) is a record in a registry
(`StateRecord`, `States`), an open set.

- **The registry always has an initial record**, so looking a state up is
  total (`States.get`): a name it does not have is read as the initial
  state. `States.register` replaces the record of the same name, the
  initial one included.
- **What the grammar must know of a state is a field of its record**, never
  a match on its name, so a state that a test or config registers is not a
  special case.
- **A record has no equality.** It holds keymaps, and `Keymap` derives
  none. Compare two records by their fields.

## Where an addition goes

| Addition | Where |
|---|---|
| A new target of an operator | A variant of `Over`, and its row in `Edit.compile` |
| A new fact about an operator or a command that the grammar needs | A field of `Operator` or of `Command` |
| A new fact about a Vim state | A field of `StateRecord` |
| A new part of speech | A variant of `Bound`, and its case in `parse` |
| Something the scheme remembers between keys | A field of `State`, with what a reset does to it |

Pinned by `ModelTest.vimEditChecks`, `ModelTest.vimRegistryChecks` and
`ModelTest.vimGrammarChecks`. The scheme runs the scheme contract
(`Editor/InputScheme/Contract.lean`) in `ModelTest.vimContractChecks`.
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

/-- What a key sequence is bound to in the Vim scheme's keymaps: a part of
speech, named by its vocabulary name. -/
inductive Bound where
  /-- The motion of this vocabulary name. -/
  | motion (name : String)
  /-- An operator. -/
  | operator (operator : Operator)
  /-- The text object of this vocabulary name. -/
  | textObject (name : String)
  /-- A command. -/
  | command (command : Command)
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

/-- A Vim state, such as normal or insert: its name, its keymaps, and what
the grammar and the scene must know of it. No keymap equality is derived,
so a record has none: compare two by their fields. -/
structure StateRecord where
  /-- The state's name, by which a command enters it. -/
  name : String
  /-- The state's keymaps, in precedence order. -/
  keymaps : List (Keymap Bound) := []
  /-- The shape a cursor is drawn as in the state. -/
  cursor : CursorShape := .block
  /-- Whether typing is text in the state: an unbound printable key is
  text, and a digit is not a count. -/
  insertsText : Bool := false
  /-- Whether an operator acts on the view's selection at once, and waits
  for no motion. -/
  operatesOnSelection : Bool := false
  deriving Repr

/-- The registry of Vim states the scheme is built over: an open set, with
one state that a view is in before any key. -/
structure States where
  /-- The state a view is in before any key, and the one a name the
  registry does not have is read as. -/
  initial : StateRecord
  /-- Every other state, in the order each was last registered. -/
  others : List StateRecord := []
  deriving Repr

namespace States

/-- The record of the state `name`; the initial record when the registry
has no state of that name, so the lookup is total. -/
def get (states : States) (name : String) : StateRecord :=
  if name == states.initial.name then states.initial
  else (states.others.find? (·.name == name)).getD states.initial

/-- `states` with `record` registered, in place of the record of the same
name if there is one, the initial record included. -/
def register (states : States) (record : StateRecord) : States :=
  if record.name == states.initial.name then { states with initial := record }
  else { states with others := states.others.filter (·.name != record.name) ++ [record] }

end States

/-- What the Vim scheme remembers between keys. -/
structure State where
  /-- The chords of every key of the edit begun, in order; none when no
  edit is begun. -/
  typed : List Key := []
  /-- The operator waiting for its target, if one was typed. -/
  operator : Option Operator := none
  /-- The keymap prefix walked so far, within the edit begun. -/
  walked : List Key := []
  deriving DecidableEq, Repr

/-- What one key parses to. -/
inductive Parsed where
  /-- Nothing yet, or nothing at all: the key went on with an edit, or
  reset one. -/
  | nothing
  /-- The key completed this edit. -/
  | edit (edit : Edit)
  deriving DecidableEq, Repr

/-- One key of the grammar: the state it leaves, and what it parsed to (the
rules in the module docs). The key is walked through the active keymaps of
`view` and then the keymaps of the initial Vim state. -/
def parse (states : States) (maps : ViewId → List (Keymap Bound)) (view : ViewId) (state : State)
    (key : Key) : State × Parsed :=
  let typed := state.typed ++ [key.chord]
  match Keymap.walk (maps view ++ states.initial.keymaps) state.walked key with
  | (walked, none) =>
    if walked.isEmpty then ({}, .nothing)
    else
      ({ state with
          typed, walked },
        .nothing)
  | (_, some (.motion name)) =>
    match state.operator with
    | some operator => ({}, .edit (.operate operator (.motion name) none none))
    | none => ({}, .edit (.move name none))
  | (_, some (.textObject name)) =>
    match state.operator with
    | some operator => ({}, .edit (.operate operator (.textObject name) none none))
    | none => ({}, .nothing)
  | (_, some (.operator operator)) =>
    match state.operator with
    | some waiting =>
      if waiting.name == operator.name then ({}, .edit (.operate waiting .lines (some 1) none))
      else ({}, .nothing)
    | none => ({ typed, operator := some operator }, .nothing)
  | (_, some (.command command)) =>
    match state.operator with
    | some _ => ({}, .nothing)
    | none => ({}, .edit (.run command none none))

/-- One key of the Vim scheme: `parse`, with the edit it completed compiled
to its invocation. -/
def step (states : States) (maps : ViewId → List (Keymap Bound)) (view : ViewId) (state : State)
    (key : Key) : State × Option Invocation :=
  match parse states maps view state key with
  | (next, .nothing) => (next, none)
  | (next, .edit edit) => (next, some edit.compile)

/-- The Vim scheme over the registry `states`. Its bindings are parts of
speech, and it reports every key of the edit begun as pending. -/
def scheme (states : States) : InputScheme :=
  { State, Binding := Bound, init := {}, step := step states, pending := (·.typed) }

end Editor.Vim
