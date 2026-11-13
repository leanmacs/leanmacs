import Editor.InputScheme

/-!
# The Vim scheme

Vim's grammar as one input scheme: keys in, an invocation out. It is the
grammar only. What a motion or an operator does to a text is the
vocabulary's, and is not here (`docs/design/keymaps-and-modes.md`, "The Vim
scheme"). Nor are any keys: the grammar is a function of a registry of Vim
states, and the states and bindings that ship are data in
`Editor/InputScheme/Vim/Default.lean`.

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
  (`Keymap.walk` over `maps view ++ record.keymaps`, with `record` the
  record of the Vim state the key's view is in). The active keymaps are the
  specific ones, so a binding of theirs replaces a default, and it holds in
  every Vim state. It is one walk, so prefixes merge across the two lists,
  and a part of speech bound in an active keymap is the same to the grammar
  as one bound in a state's keymap.
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
- **A different operator, a command, or the register prefix, while an
  operator waits resets.**
- **An unbound key resets the edit begun**: nothing is yielded, and no
  count, no register, no operator and no prefix are left. A reset keeps
  which Vim state each view is in and the last change, so where no view
  entered a state and no edit changed text the state is then the scheme's
  initial state.
- **`pending` is every key of the edit begun** (`State.typed`), as chords.
- **Typed text is a self-insert** (`selfInsert`, the invocation
  `self-insert` with the text as its argument). It is yielded for a key
  that is unbound and prints (`Key.printed?`), typed with no edit begun,
  for a view whose Vim state inserts text (`StateRecord.insertsText`). It
  leaves the state as it was. Text typed is not an `Edit`. An unbound key
  after a prefix is dropped with the prefix there too, and is not text.

## Counts

- **Two fields hold the count.** `State.digits` is the count being typed,
  and `State.multiplier` the product of the counts already completed. An
  operator key folds the digits into the multiplier. The count of the edit
  (`State.count`) is their product, with an absent one left out, so a count
  in any position multiplies: `2d3w` is 6.
- **No count is not a count of 1.** An edit's count is optional, and
  compiles to 0 when absent. Only the doubled operator fills it in.
- **A digit is a key whose chord is one digit character with no modifier.**
  It is read as a count when no keymap prefix is being walked and the
  view's Vim state does not insert text: a digit is text exactly where
  typing is text, so one field of the record says both. `0` is a
  digit only while a count is being typed; otherwise it is looked up like
  any key, so it can be bound to a motion. Digits are not bound in a
  keymap: the rule for `0` needs the count typed so far, which a keymap
  does not see.

## Registers

- **The register prefix is bound in a keymap** (`Bound.register`), beside
  the four parts of speech. The key after it names the register by the
  text it prints (`Key.printed?`), a digit included, and a key that prints
  nothing resets.
- **The state holds the register named** (`State.register`) and whether the
  prefix was the last key (`State.awaitsRegister`). The prefix folds the
  count being typed into the multiplier, as an operator does, so counts on
  either side of it multiply.
- **An edit with an operator and one that runs a command carry the
  register.** A move carries none: a register named before a motion is
  dropped when the motion completes.
- **The prefix is refused, and resets, after an operator and when a
  register is already named.**
- **After the prefix every key that prints goes on with the edit.** So the
  key this scheme gives the scheme contract as unbound is a named key.
- Which registers exist and what they hold is editor state, and not here.

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
- **Which state a view is in is in the scheme's state**, one entry a view
  (`State.current`): `step` is pure and is the only thing that sees the key
  that enters a state, so the next key is looked up in the new state's
  keymaps with no editor API. A view with no entry is in the initial state
  (`State.record`, `State.stateOf`), and entering the initial state removes
  the entry.
- **A state is entered by an edit that names it** (`Edit.enters`): a
  command bound in a keymap, or an operator. The view that enters is the
  one the completing key is for.
- **A name the registry does not have is the initial state**, when it is
  read and when it is entered, so a registry that loses a state strands no
  view.
- **The edit begun is one for the scheme**, not one a view: there is one
  keyboard. A key for another view goes on with it, and is looked up in the
  keymaps of its own view and that view's state.

## The last change

`State.lastChange` is the last edit that changed text, as a value: what dot
repeat replays. An edit replaces it when it changes text (`Edit.changes`):
one with an operator that does, or one that runs a command that does, and
never a move. A reset keeps it, and so does entering a state. Typed text is
not an edit and does not replace it. It is one for the scheme, not one a
view. Replaying it is not here.

## The visual selection

The selection is not in the scheme's state: it is the view's selection in
the text store, and the scheme holds only which Vim state the view is in.

- **A state's record says whether operators act on the selection**
  (`StateRecord.operatesOnSelection`). In such a state an operator key
  completes an edit at once, over `Over.selection`, with the count and the
  register typed before it, and waits for no motion.
- **An edit over the selection ends it**: the view enters the state the
  operator names, or the initial state when it names none.
- **A motion in such a state is the same move as anywhere.** That it
  extends the selection is the command's, when the edit runs.

## Where an addition goes

| Addition | Where |
|---|---|
| A new target of an operator | A variant of `Over`, and its row in `Edit.compile` |
| A new fact about an operator or a command that the grammar needs | A field of `Operator` or of `Command` |
| A new fact about a Vim state | A field of `StateRecord` |
| A new part of speech | A variant of `Bound`, and its case in `State.reached` |
| Something the scheme remembers between keys | A field of `State`, with what a reset does to it (`State.reset`) |
| A new default key or default Vim state | A row of a table in `Editor/InputScheme/Vim/Default.lean`; nothing here |

Pinned by `ModelTest.vimEditChecks`, `ModelTest.vimRegistryChecks`,
`ModelTest.vimGrammarChecks` and `ModelTest.vimStateChecks`. The scheme
runs the scheme contract
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
  /-- The register prefix: the key after it names the register of the edit
  being typed. It is no part of speech. -/
  | register
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
  /-- The name of the Vim state of each view that is not in the initial
  state. A view with no entry is in the initial state. -/
  current : List (ViewId × String) := []
  /-- The chords of every key of the edit begun, in order; none when no
  edit is begun. -/
  typed : List Key := []
  /-- The product of the counts already completed, if one was. -/
  multiplier : Option Nat := none
  /-- The count being typed, if a digit was. -/
  digits : Option Nat := none
  /-- The register named for the edit being typed, if one was. -/
  register : Option String := none
  /-- Whether the register prefix was the last key, so that the next key
  names the register. -/
  awaitsRegister : Bool := false
  /-- The operator waiting for its target, if one was typed. -/
  operator : Option Operator := none
  /-- The keymap prefix walked so far, within the edit begun. -/
  walked : List Key := []
  /-- The last edit that changed text, if one did: what dot repeat
  replays. -/
  lastChange : Option Edit := none
  deriving DecidableEq, Repr

/-- The record of the Vim state `view` is in: the registry's record of the
name held for the view, and the initial record when none is held or the
registry has no state of that name. -/
def State.record (states : States) (state : State) (view : ViewId) : StateRecord :=
  match state.current.find? (·.1 == view) with
  | some entry => states.get entry.2
  | none => states.initial

/-- The name of the Vim state `view` is in. -/
def State.stateOf (states : States) (state : State) (view : ViewId) : String :=
  (state.record states view).name

/-- The product of two counts, with an absent one left out; none when both
are absent. -/
private def times : Option Nat → Option Nat → Option Nat
  | some first, some second => some (first * second)
  | some first, none => some first
  | none, second => second

/-- The count of the edit begun: the product of the counts completed and
the count being typed, with an absent one left out; none when no digit was
typed. -/
def State.count (state : State) : Option Nat :=
  times state.multiplier state.digits

/-- The digit `key` types, if its chord is one digit character with no
modifier held. -/
private def digit? (key : Key) : Option Nat :=
  match key.chord.logical, key.chord.modifiers == {} with
  | .character text, true =>
    match text.toList with
    | [char] => if char.isDigit then some (char.toNat - '0'.toNat) else none
    | _ => none
  | _, _ => none

/-- The digit `key` adds to the count being typed, if it is read as a count
and not looked up: no keymap prefix is being walked, and it is not a `0`
with no count being typed. -/
private def State.countDigit? (state : State) (key : Key) : Option Nat :=
  if state.walked.isEmpty then (digit? key).filter fun digit => digit != 0 || state.digits.isSome
  else none

/-- What one key parses to. -/
inductive Parsed where
  /-- Nothing yet, or nothing at all: the key went on with an edit, or
  reset one. -/
  | nothing
  /-- The key completed this edit. -/
  | edit (edit : Edit)
  /-- The key is typed text: this is what it prints. -/
  | text (text : String)
  deriving DecidableEq, Repr

/-- The state with the edit begun dropped. A reset keeps which Vim state
each view is in and the last change, and nothing else. -/
private def State.reset (state : State) : State :=
  { current := state.current, lastChange := state.lastChange }

/-- The state with `view` in the Vim state `name`. The initial state has no
entry, and a name the registry does not have is the initial state's, so
entering either removes the view's entry. -/
private def State.enter (states : States) (state : State) (view : ViewId) (name : String) : State :=
  let others := state.current.filter (·.1 != view)
  let entered := (states.get name).name
  { state with
    current := if entered == states.initial.name then others else others ++ [(view, entered)] }

/-- The edit begun, completed as `edit` by a key for `view`: the edit begun
is dropped, the edit is the last change if it changes text, and the view
enters the Vim state `enters`, if it is one: the state the edit names,
unless the caller says another. -/
private def State.finish (states : States) (view : ViewId) (state : State) (edit : Edit)
    (enters : Option String := edit.enters) : State × Parsed :=
  let next := state.reset
  let next := if edit.changes then { next with lastChange := some edit } else next
  match enters with
  | some name => (next.enter states view name, .edit edit)
  | none => (next, .edit edit)

/-- What the grammar makes of a binding that a key for `view` reached, with
`typed` the keys of the edit begun, that key included. -/
private def State.reached (states : States) (view : ViewId) (state : State) (typed : List Key) :
    Bound → State × Parsed
  | .motion name =>
    match state.operator with
    | some operator =>
      state.finish states view (.operate operator (.motion name) state.count state.register)
    | none => state.finish states view (.move name state.count)
  | .textObject name =>
    match state.operator with
    | some operator =>
      state.finish states view (.operate operator (.textObject name) state.count state.register)
    | none => (state.reset, .nothing)
  | .operator operator =>
    match state.operator with
    | some waiting =>
      if waiting.name == operator.name then
        state.finish states view
          (.operate waiting .lines (some (state.count.getD 1)) state.register)
      else (state.reset, .nothing)
    | none =>
      if (state.record states view).operatesOnSelection then
        -- The edit ends the selection, so the view leaves the state: for
        -- the one the operator names, or else the initial state.
        state.finish states view (.operate operator .selection state.count state.register)
          (some (operator.enters.getD states.initial.name))
      else
        ({ state with
            typed, multiplier := state.count, digits := none, operator := some operator,
            walked := [] },
          .nothing)
  | .command command =>
    match state.operator with
    | some _ => (state.reset, .nothing)
    | none => state.finish states view (.run command state.count state.register)
  | .register =>
    if state.operator.isSome || state.register.isSome then (state.reset, .nothing)
    else
      ({ state with
          typed, multiplier := state.count, digits := none, awaitsRegister := true, walked := [] },
        .nothing)

/-- One key of the grammar, a key for `view`: the state it leaves, and what
it parsed to (the rules in the module docs). A digit of a count is taken
first, where typing is not text; any other key is walked through the
active keymaps of `view` and then the keymaps of the view's Vim state. An
unbound key is text when the view's state inserts text, the key prints and
no edit is begun, and otherwise resets. -/
def parse (states : States) (maps : ViewId → List (Keymap Bound)) (view : ViewId) (state : State)
    (key : Key) : State × Parsed :=
  let record := state.record states view
  let typed := state.typed ++ [key.chord]
  if state.awaitsRegister then
    match key.printed? with
    | some name =>
      ({ state with
          typed, register := some name, awaitsRegister := false },
        .nothing)
    | none => (state.reset, .nothing)
  else
    match if record.insertsText then none else state.countDigit? key with
    | some digit =>
      ({ state with
          typed, digits := some (state.digits.getD 0 * 10 + digit) },
        .nothing)
    | none =>
      match Keymap.walk (maps view ++ record.keymaps) state.walked key with
      | (_, some binding) => state.reached states view typed binding
      | (walked, none) =>
        if !walked.isEmpty then
          ({ state with
              typed, walked },
            .nothing)
        else
          if record.insertsText && state.typed.isEmpty then
            (state, (key.printed?.map Parsed.text).getD .nothing)
          else (state.reset, .nothing)

/-- The invocation typed text yields: the command `self-insert`, with the
text a key printed as its argument. -/
def selfInsert (text : String) : Invocation :=
  { command := "self-insert", arguments := [.str text] }

/-- One key of the Vim scheme: `parse`, with the edit it completed compiled
to its invocation. -/
def step (states : States) (maps : ViewId → List (Keymap Bound)) (view : ViewId) (state : State)
    (key : Key) : State × Option Invocation :=
  match parse states maps view state key with
  | (next, .nothing) => (next, none)
  | (next, .edit edit) => (next, some edit.compile)
  | (next, .text text) => (next, some (selfInsert text))

/-- The Vim scheme over the registry `states`. Its bindings are parts of
speech, and it reports every key of the edit begun as pending. -/
def scheme (states : States) : InputScheme :=
  { State, Binding := Bound, init := {}, step := step states, pending := (·.typed) }

end Editor.Vim
