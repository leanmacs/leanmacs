import Editor.InputScheme

/-!
# The Vim scheme

Vim's grammar as one input scheme: keys in, an invocation out. It is the
grammar only. What a motion or an operator does to a text is not here
(`docs/design/keymaps-and-modes.md`, "The Vim scheme"): a motion is a
vocabulary entry (`Editor/Vocabulary.lean`), and the commands this
scheme's invocations name are evil's (`Editor/Evil.lean`), written on the
editor API. Nor are any keys: the grammar is a function of a registry of Vim
states, and the states and bindings that ship are data in
`Editor/InputScheme/Vim/Default.lean`.

## Edits

A key sequence parses to an `Edit`, and an edit compiles to an invocation
(`Edit.compile`):

| Edit | Invocation |
|---|---|
| `move m c a` | `moveCommand`, with `[.str m, .nat c]`, or `[.str m, .str a, .nat c]` when the motion has an argument |
| `operate o over c r` | `operateCommand`, with `[.str o.name, .str kind, .str name, .nat c, .str r]`. Kind and name are `motion` and the motion, `text-object` and the object, `lines` and `""`, `selection` and `""`. A motion's argument, when it has one, is a string right after its name: `[.str o.name, .str "motion", .str m, .str a, .nat c, .str r]` |
| `run cmd c r` | `cmd.name`, with `[.nat c, .str r]` |
| `select obj c` | `selectObjectCommand` (`select-object`), with `[.str obj, .nat c]` |
| A motion that asks | `askCommand` (`minibuffer-ask`), with `[.str label]`; the edit is compiled when the answer comes ("Motions that ask") |
| `replay change inserted` | `repeatCommand`, with `[.bool session, .str text, .str command]` and then the change's own arguments: whether the change began an insert session, the text typed in it, and the command the change compiles to |

- **Every part of speech is named by its vocabulary name**, a `String`, so
  no vocabulary entry need exist for the grammar to parse.
- **An absent count is `.nat 0`** and an absent register `.str ""`: an
  invocation's arguments have no optional kind, and a typed count is never
  0. In an edit they stay optional, since no count is not a count of 1.
- **A motion's argument, when it has one, is the string right after the
  motion's name**, in a move and over a motion, so the register stays the
  last argument of an operator's layout, which dot repeat reads
  (`Editor/Evil/Repeat.lean`).
- **An operator and a command carry what the grammar cannot look up**:
  whether an edit with it changes text (`Edit.changes`) and which Vim state
  the view is in afterwards (`Edit.enters`).

## The grammar

`parse` is one key: the state it leaves and what the key parsed to. `step`
is `parse` with the edit compiled, and `scheme` packages it as an
`InputScheme` over a registry of Vim states. The rules:

- **A key is walked through the active keymaps, over the Vim state's**
  (`Keymap.walkOver (maps view) record.keymaps`, with `record` the
  record of the Vim state the key's view is in). **While an operator
  waits, a state's pending keymaps are walked in place of its own**
  (`StateRecord.pending`, Vim's Operator-pending mode), when it has any:
  so a key a state binds to a command alone, such as normal state's `i`,
  can begin a text object after an operator. A state with none walks its
  own keymaps while an operator waits, as before. The active keymaps are the
  specific ones, so a binding of theirs replaces a default, and it holds in
  every Vim state, except a mode's where typing is text ("Mode keys"
  below). The specific keymaps decide a sequence they bind or begin, so an
  active prefix shadows a state's binding of the same keys: a config's
  `C-w l` makes `C-w` a prefix in insert state, over the state's own
  `C-w`. Only a sequence they leave unbound is looked up in the state's,
  so prefixes still merge across the two lists, and a part of speech bound
  in an active keymap is the same to the grammar as one bound in a state's
  keymap. The two tiers are `State.tiers`.
- **The keys that can follow are listed from the same tiers as the walk**
  (`State.continuations`, the scheme's `continuations`, over
  `State.tiers`): after an operator they come from the state's pending
  keymaps, as the walk's do. Only a keymap prefix lists anything: a count,
  the register prefix or an operator alone lists nothing, and neither does
  a key that waits to name a character or a register.
- **A motion alone is a move**, and **a command is run**. A key bound to a
  command name alone (`scheme.command`, as a binding from config is) is
  bound to `Bound.command` of that name, which changes no text and enters
  no state, unless the run table of the view's Vim state has an entry for
  the name ("Vim states" below).
- **An operator waits for its target** (`State.operator`). The wait has
  no keymap of its own: the motion that moves when typed alone is the
  operator's target when typed after it, so a motion bound once, in any
  keymap, works with every operator, unless a state's pending keymaps
  leave it out.
- **A text object after an operator is its target.** With no operator
  waiting, in a state where operators act on the selection, it completes
  `Edit.select` with the count typed, which sets the selection to the
  object, enters the state the record names for it
  (`StateRecord.objectEnters`), and is never the last change; elsewhere
  it resets.
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
  any key, so it can be bound to a motion. Digits are not bound at the
  start of a sequence: the rule for `0` needs the count typed so far,
  which a keymap does not see. After a prefix a digit is looked up like
  any key, so `C-w 1` to `C-w 9` are the tab keys (`Vim.Default.tabKeys`),
  and there is no count after `C-w`.

## Motions that take a character

`f`, `t`, `F` and `T` are bound to `Bound.charMotion`: the motion waits for
the key after it, which names the character it finds.

- **The key is kept as typed** (`State.awaitsChar`), so it is pending
  alone, and it folds the count being typed into the multiplier, as an
  operator does: `2f` then `x` is a count of 2, and so is `d2fx`.
- **The next key is read before counts and keymaps**, as the key after the
  register prefix is: a key that prints names the character, a digit
  included, so `f1` finds a `1`; `TAB` names a tab (`Key.character?`).
  It completes `Edit.move name count (some char)`, or, with an operator
  waiting, the operator over `.motion name (some char)`.
- **Any other key resets the edit begun**: `f` then `<Escape>` does
  nothing and leaves nothing pending, as in Vim.

## Motions that ask

`/` and `?` are bound to `Bound.promptMotion`: the motion's argument is a
text typed in the minibuffer, so the edit cannot complete at the key.

- **At the key** the edit that waits is recorded (`State.asking`, an
  `Asking`: the view, the motion, the operator waiting, the count and the
  register), the edit begun is reset so that the minibuffer's keys parse
  afresh, and the key yields `askCommand` with the prompt's label
  (`Parsed.ask`). Nothing becomes the last change and no state is
  entered.
- **The answer** (`State.answered`, the scheme's `InputScheme.answered`)
  completes the waiting edit with the answer as the motion's argument, for
  the view it is for, by `State.finish`, as a key completes one: an
  operator's edit is the last change and enters the operator's state. A
  second answer, and one with nothing waiting, yields nothing.
- **The edit waits while keys are typed in the minibuffer's view**, which
  the scheme is told when the prompt opens (`State.openMinibuffer` sets
  `Asking.minibuffer`), and when that view closes: the accept command
  closes it a step before the answer comes. A key for any other view drops
  it, as after the prompt was cancelled. A reset keeps it.

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
  the entry. So does the view being closed (`State.closeView`, which the
  scheme reports as `InputScheme.closeView`): the entry of a view that is
  gone is dropped, and nothing else of the state changes.
- **A state is entered by an edit that names it** (`Edit.enters`): a
  command bound in a keymap, or an operator. The view that enters is the
  one the completing key is for.
- **A record's run table** (`StateRecord.runs`, a command name and an edit
  for each entry) says that in the state a command of that name is
  completed as that edit. It holds for a key bound to the command name
  alone in any keymap (`Bound.command`, which the registry's bindings are,
  so config's binding of the key to another name wins: the name reached is
  looked up), with no operator waiting, and for a menu item that names the
  command with no arguments (`State.invoked`, which the scheme reports as
  `InputScheme.invoked`). So a command name can end a selection or enter
  a state, which a command alone cannot: Copy in a visual state is `"+y`.
  - The entry's edit is used as written: a count or a register typed
    before the key is dropped. A register the entry names is in its own
    arguments, last.
  - It is completed as an operator key is (`State.complete`): over the
    selection in a state where operators act on it, the view enters the
    state the operator names, or the initial state; any other edit enters
    the state it names. The last change and its typed text follow
    `State.finish`'s rules, as for a key.
  - A name with no entry runs the command of that name, as before.
- **The minibuffer's view enters the state the registry names for it**
  (`States.minibuffer`, a name or none), when the scheme is told the view
  is the minibuffer's (`State.openMinibuffer`, which the scheme reports as
  `InputScheme.openMinibuffer`). It is entered as an edit's state is, so
  the entry is dropped when the view is closed. With none named the view
  stays in the initial state. Nothing matches on the state's name: which
  state it is, and what it binds, is the registry's.
- **A name the registry does not have is the initial state**, when it is
  read and when it is entered, so a registry that loses a state strands no
  view.
- **The edit begun is one for the scheme**, not one a view: there is one
  keyboard. A key for another view goes on with it, and is looked up in the
  keymaps of its own view and that view's state.
- **A record says the shape of the view's selection** (`StateRecord.shape`,
  inclusive unless the record says otherwise). The grammar does not read
  it: the command that enters the state reshapes the selection by it
  (`docs/design/keymaps-and-modes.md`, "Vim states").
- **The scheme reports the record of a view's state** (`State.report`,
  which the scheme reports as `InputScheme.report`), since nothing outside
  the scheme can read one:

  | Field of the report | From the record |
  |---|---|
  | `cursor` | Its cursor shape, in the face `cursor.` followed by its name (`cursorFace`) |
  | `status` | One field: its name in capitals (`NORMAL`), in the face `mode-line.state.` followed by its name (`stateFace`), which the mode line's `state` segment draws as its badge (`Editor/ModeLine.lean`) |
  | `shape` | Its `shape` |
  | `selecting` | `operatesOnSelection`: where operators act on the selection, a motion extends it |
  | `session`, `takesText` | `insertsText`: where typing is text, the view is in an insert session and a committed text is inserted |

  A key that yields nothing changes no view's state, so it changes no
  report, which the scheme contract asks.

## The last change

`State.lastChange` is the last edit that changed text, as a value: what dot
repeat replays. An edit replaces it when it changes text (`Edit.changes`):
one with an operator that does, or one that runs a command that does, and
never a move. A reset keeps it, and so does entering a state. Typed text is
not an edit and does not replace it. It is one for the scheme, not one a
view. Replaying it is not here.

**The text typed in the insert session the last change began is kept with
it** (`State.inserted`, and `State.recording`, the view it is being kept
for), since typed text is no edit and a replay of the change needs it:

- An edit that changes text and enters a state where typing is text sets
  `inserted` to the empty text and `recording` to the key's view. Any
  other edit that changes text sets both to none.
- Text typed in the recording view is added to `inserted`
  (`State.typedText`). Text typed in another view, the minibuffer's
  included, is not.
- A command that changes no text, run in the recording view, adds what its
  binding says it adds (`Command.typed`), as typed text is added: insert
  state's `<Backspace>`, `C-w`, `RET` and `TAB` add `backspaceTyped`,
  `wordDeleteTyped`, `lineBreakTyped` and a tab, which the repeat runs
  again.
- A command that restarts the last change (`Command.restarts`, insert
  state's arrow keys), run in the recording view, leaves a restart waiting
  (`State.restart`): the command it names, as a change that enters the Vim
  state the view is in, with no count and no register. The next text added
  in the recording view makes it the last change, with that text alone kept
  for it; ending the recording drops it. This is Vim 9.1's restart of the
  redo as `i` at the first key after an arrow key (`ins-special-special`).
- An edit that enters a state for the recording view, and that view being
  closed, end the recording. What was kept stays.
- A reset keeps both and the waiting restart, as it keeps the last change.
- A command that does not run to its end is not the last change and its
  typed text is not kept, with no rule here: the loop puts the scheme back
  in its state at rest (`Editor/Loop.lean`).

**The repeat key is a part of speech** (`Bound.repeat`), since the scheme
cannot match on a command's name and a command cannot read the scheme:

- With no last change, and while an operator waits, the key resets and
  yields nothing.
- Otherwise it yields `Edit.replay change inserted`: the last change, and
  the text kept for it. The scheme hands the change to the command in the
  invocation, since the command cannot ask for it.
- **A count typed before it replaces the change's count**
  (`Edit.withCount`) in what is yielded and in the last change, so the
  repeats after it carry it. With none typed the change's own count is
  used. This is Vim's rule.
- A replay changes no text and enters no state for the grammar: it does
  not become the last change, and the view stays in the state it is in.
  What it replays is the command's (`Editor/Evil/Repeat.lean`).

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
- **A text object in such a state sets the selection** (`Edit.select`):
  the command sets it to the object, and the view enters the state the
  record names for an object (`StateRecord.objectEnters`), when it names
  one, as `visual-line` names `visual`. A register named before it is
  dropped.

## Mode keys

The scheme is given a role table, a leader, a localleader and hand-tuned
keys beside its states (`ModeKeys`), and reports them to the core
(`InputScheme.roles`, `InputScheme.leader`, `InputScheme.localLeader`,
`InputScheme.tuned`, each tuned binding wrapped in `Bound.mode`), with every
state's keymaps as its own (`InputScheme.defaults`). The grammar reads
none of them: a mode's keys reach it as active keymaps. The tables that ship
are data in `Editor/InputScheme/Vim/Default.lean`.

A key a mode binds is bound to `Bound.mode` of what it runs
(`InputScheme.modeCommand`: `.mode (.command { name })`), and so is a
binding of config's under the leader or the localleader, which the registry
binds with `modeCommand` (`Editor/Config/Registry.lean`). The grammar
reaches a `.mode` binding as the binding it wraps, so a mode's motion is a
move like any other.

A key bound to hold only in some Vim states is bound to `Bound.within` of
those states' names and what it runs (`InputScheme.stateCommand`:
`.within states (.command { name })`, config's `bindKey … (states := …)`).
The grammar reaches it as the binding it wraps too.

**Where a binding of the active keymaps holds** is one predicate,
`Bound.holdsIn`, of the record of the view's Vim state, and `parse` leaves
the bindings that do not hold out of the active keymaps (`Keymap.filter`),
so the keys are walked on to the state's own keymaps:

- `.mode` holds only where typing is not text (`StateRecord.insertsText`,
  the field that already says a digit is not a count), so a key a mode
  binds, or one under the leader, is typed text where it is.
- `.within names` holds only in a state whose name is one of `names`.
- Every other binding, such as one from config's `bindKey` with no
  `states` and not under a leader, holds in every state.

## Where an addition goes

| Addition | Where |
|---|---|
| A new target of an operator | A variant of `Over`, and its row in `Edit.compile` |
| A new fact about an operator or a command that the grammar needs | A field of `Operator` or of `Command` |
| A new fact about a Vim state | A field of `StateRecord` |
| A key read only after an operator | A row of a keymap in the state's `StateRecord.pending`, with the keys of its own keymaps an operator still takes |
| A command name that runs as another edit in a state | An entry of that state's run table (`StateRecord.runs`) |
| A new fact about a Vim state that the loop, the scene or a command reads | A field of `StateRecord`, and how `State.report` reads it into the report |
| A new part of speech | A variant of `Bound`, and its case in `State.reached` |
| A new fact about where a binding holds | A variant of `Bound` that wraps the binding, its case in `State.reached`, and its case in `Bound.holdsIn` |
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
  /-- What running it in the insert session the last change began adds to
  the text kept for that change, as typed text is added, so that the repeat
  replays it: insert state's editing keys say so (`backspaceTyped`,
  `wordDeleteTyped`, `lineBreakTyped`, a tab). None for a command that adds nothing. Read only
  of a command that changes no text. -/
  typed : Option String := none
  /-- The name of the command the last change restarts as once something
  is added to its text after this command ran in the session it began, with
  the text from there on: an arrow key of insert state's, which restarts
  it as `i` (Vim 9.1's `ins-special-special`). Read only of a command that
  changes no text. -/
  restarts : Option String := none
  deriving DecidableEq, Repr

/-- What `<Backspace>` in an insert session adds to the text kept for the
last change (`Command.typed`): the backspace character, U+0008, which no
key prints. The repeat deletes the cell before the bar for it
(`Editor/Evil/Repeat.lean`). -/
def backspaceTyped : String :=
  "\x08"

/-- What `C-w` in an insert session adds to the text kept for the last
change (`Command.typed`): Vim's own `CTRL-W` character, U+0017, which no
key prints. The repeat deletes the word before the bar for it
(`Editor/Evil/Repeat.lean`). -/
def wordDeleteTyped : String :=
  "\x17"

/-- What `RET` in an insert session adds to the text kept for the last
change: a line feed. The repeat breaks the line there with the buffer's own
line ending. -/
def lineBreakTyped : String :=
  "\n"

/-- What a key sequence is bound to in the Vim scheme's keymaps: a part of
speech, named by its vocabulary name. -/
inductive Bound where
  /-- The motion of this vocabulary name. -/
  | motion (name : String)
  /-- The motion of this vocabulary name, which takes the character the next
  key names as its argument: `f`, `t`, `F` and `T`. -/
  | charMotion (name : String)
  /-- The motion of this vocabulary name, which takes as its argument a text
  typed in the minibuffer, asked for with a prompt labelled `label`: `/`
  and `?`. -/
  | promptMotion (name label : String)
  /-- An operator. -/
  | operator (operator : Operator)
  /-- The text object of this vocabulary name. -/
  | textObject (name : String)
  /-- A command. -/
  | command (command : Command)
  /-- The register prefix: the key after it names the register of the edit
  being typed. It is no part of speech. -/
  | register
  /-- The repeat key: it yields the last change, to replay. -/
  | repeat
  /-- A binding a mode contributes, or one of config's under the leader or
  the localleader: the grammar reaches it as `bound`, and it does not hold
  where typing is text. -/
  | mode (bound : Bound)
  /-- A binding that holds only in the Vim states of these names: the
  grammar reaches it as `bound`. -/
  | within (states : List String) (bound : Bound)
  deriving DecidableEq, Repr

/-- What an operator acts on. -/
inductive Over where
  /-- What the motion of this vocabulary name covers, given `argument` when
  it takes one. -/
  | motion (name : String) (argument : Option String := none)
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
  /-- Move by a motion, given `argument` when it takes one. -/
  | move (motion : String) (count : Option Nat) (argument : Option String := none)
  /-- Apply an operator to a target. -/
  | operate (operator : Operator) (over : Over) (count : Option Nat) (register : Option String)
  /-- Run a command. -/
  | run (command : Command) (count : Option Nat) (register : Option String)
  /-- Replay `change`, the last change, with `inserted`, the text typed in
  the insert session it began, or none when it began none. -/
  | replay (change : Edit) (inserted : Option String)
  /-- Set a visual selection to the text object of this vocabulary name. -/
  | select (object : String) (count : Option Nat)
  deriving DecidableEq, Repr

/-- The name of the command a replay compiles to. -/
def repeatCommand : String :=
  "repeat"

/-- The name of the command a move compiles to. -/
def moveCommand : String :=
  "move"

/-- The name of the command an edit with an operator compiles to. -/
def operateCommand : String :=
  "operate"

/-- The name of the command a text object in a visual state compiles to. -/
def selectObjectCommand : String :=
  "select-object"

namespace Edit

/-- Whether the edit changes text: its operator's or its command's word for
it, and never a move. -/
def changes : Edit → Bool
  | .move .. => false
  | .operate operator .. => operator.changes
  | .run command .. => command.changes
  | .replay .. => false
  | .select .. => false

/-- The Vim state the view is in after the edit, if its operator or its
command names one. -/
def enters : Edit → Option String
  | .move .. => none
  | .operate operator .. => operator.enters
  | .run command .. => command.enters
  | .replay .. => none
  | .select .. => none

/-- The edit with `count` as its count: a replay is left as it is. -/
def withCount (count : Nat) : Edit → Edit
  | .move motion _ argument => .move motion (some count) argument
  | .operate operator over _ register => .operate operator over (some count) register
  | .run command _ register => .run command (some count) register
  | .replay change inserted => .replay change inserted
  | .select object _ => .select object (some count)

/-- The invocation the edit compiles to (the table in the module docs). -/
def compile : Edit → Invocation
  | .move motion count argument =>
    { command := moveCommand
      arguments := [.str motion] ++ argument.toList.map .str ++ [.nat (count.getD 0)] }
  | .operate operator over count register =>
    let (kind, name, argument) :=
      match over with
      | .motion name argument => ("motion", name, argument)
      | .textObject name => ("text-object", name, none)
      | .lines => ("lines", "", none)
      | .selection => ("selection", "", none)
    { command := operateCommand
      arguments :=
        [.str operator.name, .str kind, .str name] ++ argument.toList.map .str ++
          [.nat (count.getD 0), .str (register.getD "")] }
  | .run command count register =>
    { command := command.name, arguments := [.nat (count.getD 0), .str (register.getD "")] }
  | .replay change inserted =>
    let compiled := change.compile
    { command := repeatCommand
      arguments :=
        [.bool inserted.isSome, .str (inserted.getD ""), .str compiled.command] ++
          compiled.arguments }
  | .select object count =>
    { command := selectObjectCommand, arguments := [.str object, .nat (count.getD 0)] }

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
  for no motion. A motion in such a state extends the selection. -/
  operatesOnSelection : Bool := false
  /-- The shape the view's selection has in the state. -/
  shape : Shape := .inclusive
  /-- The keymaps walked, after the active ones, in place of `keymaps` while
  an operator waits: Vim's Operator-pending mode. With none, `keymaps` are
  walked then too. -/
  pending : List (Keymap Bound) := []
  /-- The Vim state a view enters when a text object sets its selection in
  this state, if one: `visual-line` names `visual`, as an object makes a
  line-wise selection character-wise. -/
  objectEnters : Option String := none
  /-- The run table: in the state, a command of the first name, reached by
  a key bound to that name alone in any keymap or named by a menu item, is
  completed as the edit beside it ("Vim states", in the module docs). -/
  runs : List (String × Edit) := []
  deriving Repr

/-- Whether the binding holds in a view whose Vim state has the record
`record` ("Mode keys", in the module docs): a `.mode` binding only where
typing is not text, a `.within` binding only in a state it names, and any
other binding everywhere. -/
def Bound.holdsIn (record : StateRecord) : Bound → Bool
  | .mode _ => !record.insertsText
  | .within states _ => states.contains record.name
  | _ => true

/-- An edit that waits for the answer to a prompt ("Motions that ask", in
the module docs): the motion that takes the answer as its argument, and
what was typed before its key. -/
structure Asking where
  /-- The view the edit is for. -/
  view : ViewId
  /-- The motion's vocabulary name. -/
  motion : String
  /-- The operator that waits for the motion, if one was typed. -/
  operator : Option Operator := none
  /-- The count typed, if one was. -/
  count : Option Nat := none
  /-- The register named, if one was. -/
  register : Option String := none
  /-- The view of the minibuffer the prompt opened, once the scheme is told
  of it. -/
  minibuffer : Option ViewId := none
  deriving DecidableEq, Repr

/-- The name of the command a motion that asks yields, to open its prompt:
the minibuffer's (`Editor/Minibuffer.lean`, "Asking for the input
scheme"). -/
def askCommand : String :=
  "minibuffer-ask"

/-- The registry of Vim states the scheme is built over: an open set, with
one state that a view is in before any key. -/
structure States where
  /-- The state a view is in before any key, and the one a name the
  registry does not have is read as. -/
  initial : StateRecord
  /-- Every other state, in the order each was last registered. -/
  others : List StateRecord := []
  /-- The name of the state the minibuffer's view is put in when a prompt
  opens; with `none` it stays in the initial state. -/
  minibuffer : Option String := none
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
  /-- The motion that waits for the character the next key names, if a key
  bound to one was the last key (`Bound.charMotion`). -/
  awaitsChar : Option String := none
  /-- The operator waiting for its target, if one was typed. -/
  operator : Option Operator := none
  /-- The keymap prefix walked so far, within the edit begun. -/
  walked : List Key := []
  /-- The last edit that changed text, if one did: what dot repeat
  replays. -/
  lastChange : Option Edit := none
  /-- The text typed in the insert session the last change began; `none`
  when it began none. -/
  inserted : Option String := none
  /-- The view whose typed text is being added to `inserted`: the view of
  the last change, while it is in the session that change began. -/
  recording : Option ViewId := none
  /-- The change the last change is restarted as once something is added
  to its text: set by a command that restarts it (`Command.restarts`), and
  dropped when the recording ends. -/
  restart : Option Edit := none
  /-- The edit that waits for a prompt's answer, if a motion that asks was
  typed and the answer has not come ("Motions that ask", in the module
  docs). -/
  asking : Option Asking := none
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

/-- The face of the status field that names a view in the Vim state called
`name`, which the mode line draws as its badge: `mode-line.state.` and the
name. -/
def stateFace (name : String) : FaceName :=
  ⟨s!"mode-line.state.{name}"⟩

/-- The face a view's cursors take in the Vim state called `name`:
`cursor.` and the name. -/
def cursorFace (name : String) : FaceName :=
  ⟨s!"cursor.{name}"⟩

/-- What the scheme says of `view`, read off the record of the Vim state it
is in: the record's cursor shape in the face of its name, one status field,
the state's name in capitals in the badge face of its name (`stateFace`),
and the record's shape. A motion extends
the selection where operators act on it, and the view is in an insert
session and takes committed text where typing is text. -/
def State.report (states : States) (state : State) (view : ViewId) : InputScheme.Report :=
  let record := state.record states view
  { cursor := { shape := record.cursor, face := cursorFace record.name }
    status := #[{ text := record.name.toUpper, face := stateFace record.name }]
    shape := record.shape
    selecting := record.operatesOnSelection
    session := record.insertsText
    takesText := record.insertsText }

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

/-- The character `key` names as a find's argument: the text it prints, or a
tab for `TAB` with no modifier held. -/
def Key.character? (key : Key) : Option String :=
  match key.printed? with
  | some text => some text
  | none =>
    if key.chord.logical == .named .tab && key.chord.modifiers == {} then some "\t" else none

/-- What one key parses to. -/
inductive Parsed where
  /-- Nothing yet, or nothing at all: the key went on with an edit, or
  reset one. -/
  | nothing
  /-- The key completed this edit. -/
  | edit (edit : Edit)
  /-- The key is typed text: this is what it prints. -/
  | text (text : String)
  /-- The key asks for a text typed in the minibuffer, with a prompt
  labelled `label`: the edit waits for the answer (`State.asking`). -/
  | ask (label : String)
  deriving DecidableEq, Repr

/-- The state with the edit begun dropped. A reset keeps which Vim state
each view is in, the last change and the text typed in the session it
began, with the view that text is being kept for and the change it is
restarted as, and nothing else. -/
private def State.reset (state : State) : State :=
  { current := state.current, lastChange := state.lastChange, inserted := state.inserted
    recording := state.recording, restart := state.restart, asking := state.asking }

/-- The state with the typed text of `view` no longer kept, when `view` is
the view it is being kept for. The text kept so far stays, and no restart
waits. -/
private def State.endRecording (state : State) (view : ViewId) : State :=
  if state.recording == some view then
    { state with
      recording := none, restart := none }
  else state

/-- The state once `text` was typed in `view`: when `view` is the view it is
being kept for, the text is added to what is kept for the last change, or,
when a restart waits, the last change is the change it restarts as, with
the text alone kept for it; the state is as it was otherwise. -/
def State.typedText (state : State) (view : ViewId) (text : String) : State :=
  if state.recording == some view then
    match state.restart with
    | some change =>
      { state with
        lastChange := some change, inserted := some text, restart := none }
    | none => { state with inserted := state.inserted.map (· ++ text) }
  else state

/-- The state once `view` is closed: without the Vim state kept for it, and
with no more of its typed text kept for the last change. The edit begun,
the last change and the text kept for it are the scheme's, not the view's,
and stay. -/
def State.closeView (view : ViewId) (state : State) : State :=
  { state.endRecording view with current := state.current.filter (·.1 != view) }

/-- The state with `view` in the Vim state `name`. The initial state has no
entry, and a name the registry does not have is the initial state's, so
entering either removes the view's entry. -/
private def State.enter (states : States) (state : State) (view : ViewId) (name : String) : State :=
  let others := state.current.filter (·.1 != view)
  let entered := (states.get name).name
  { state with
    current := if entered == states.initial.name then others else others ++ [(view, entered)] }

/-- The state once `view` is opened as the minibuffer's: the view is in the
Vim state the registry names for the minibuffer (`States.minibuffer`),
entered as an edit that names a state enters it, so a name the registry
does not have is the initial state. With none named, the state is as it
was. The edit begun and the last change are the scheme's, not the view's,
and stay. -/
def State.openMinibuffer (states : States) (view : ViewId) (state : State) : State :=
  -- An edit that waits for a prompt's answer waits while keys are typed in
  -- the minibuffer's view.
  let state := { state with asking := state.asking.map ({ · with minibuffer := some view }) }
  match states.minibuffer with
  | some name => state.enter states view name
  | none => state

/-- The edit begun, completed as `edit` by a key for `view`: the edit begun
is dropped, the edit is the last change if it changes text, and the view
enters the Vim state `enters`, if it is one: the state the edit names,
unless the caller says another.

What is typed in the insert session the last change began is kept for it
("The last change", in the module docs): an edit that changes text and
enters a state where typing is text begins keeping, with the empty text,
for `view`; any other edit that changes text keeps none; and an edit that
changes no text and enters a state for the view being kept for ends the
keeping, with what was kept. -/
private def State.finish (states : States) (view : ViewId) (state : State) (edit : Edit)
    (enters : Option String := edit.enters) : State × Parsed :=
  let next := state.reset
  let begins := (enters.map fun name => (states.get name).insertsText) == some true
  let next :=
    if edit.changes then
      { next with
        lastChange := some edit, inserted := if begins then some "" else none
        recording := if begins then some view else none }
    else if enters.isSome then next.endRecording view else next
  match enters with
  | some name => (next.enter states view name, .edit edit)
  | none => (next, .edit edit)

/-- The state once `command`, which a key for `view` ran, completed its
edit: when it changes no text and `view` is the view whose typed text is
kept, what it adds (`Command.typed`) is added as typed text is, and a
command that restarts the last change (`Command.restarts`) leaves the
change it restarts as waiting: its command, which changes text and enters
the Vim state the view is in, with no count and no register. -/
private def State.ran (states : States) (view : ViewId) (command : Command) (state : State) :
    State :=
  if command.changes || state.recording != some view then state
  else
    let state := (command.typed.map (state.typedText view)).getD state
    match command.restarts with
    | some name =>
      let enters := some (state.stateOf states view)
      { state with restart := some (.run { name, changes := true, enters } none none) }
    | none => state

/-- The edit begun, completed as `edit` for `view` (`State.finish`): an edit
over the selection, in a state where operators act on it, ends the
selection, so the view enters the state its operator names, or the initial
state; any other edit enters the state it names. -/
private def State.complete (states : States) (view : ViewId) (state : State) (edit : Edit) :
    State × Parsed :=
  match edit with
  | .operate operator .selection .. =>
    if (state.record states view).operatesOnSelection then
      -- The edit ends the selection, so the view leaves the state: for the
      -- one the operator names, or else the initial state.
      state.finish states view edit (some (operator.enters.getD states.initial.name))
    else state.finish states view edit
  | _ => state.finish states view edit

/-- The edit the run table of the Vim state `view` is in completes a command
of the name `name` as, if it has an entry for the name. -/
private def State.runOf (states : States) (state : State) (view : ViewId) (name : String) :
    Option Edit :=
  ((state.record states view).runs.find? (·.1 == name)).map (·.2)

/-- What the grammar makes of a binding that a key for `view` reached, with
`typed` the keys of the edit begun, that key included. -/
private def State.reached (states : States) (view : ViewId) (state : State) (typed : List Key) :
    Bound → State × Parsed
  | .motion name =>
    match state.operator with
    | some operator =>
      state.finish states view (.operate operator (.motion name) state.count state.register)
    | none => state.finish states view (.move name state.count)
  | .promptMotion name label =>
    -- The edit cannot complete at the key: its argument is typed in the
    -- minibuffer, and the keys typed there must parse afresh.
    let asking : Asking :=
      { view, motion := name, operator := state.operator, count := state.count
        register := state.register }
    ({ state.reset with asking := some asking }, .ask label)
  | .charMotion name =>
    ({ state with
        typed, multiplier := state.count, digits := none, awaitsChar := some name, walked := [] },
      .nothing)
  | .textObject name =>
    match state.operator with
    | some operator =>
      state.finish states view (.operate operator (.textObject name) state.count state.register)
    | none =>
      let record := state.record states view
      if record.operatesOnSelection then
        state.finish states view (.select name state.count) record.objectEnters
      else (state.reset, .nothing)
  | .operator operator =>
    match state.operator with
    | some waiting =>
      if waiting.name == operator.name then
        state.finish states view
          (.operate waiting .lines (some (state.count.getD 1)) state.register)
      else (state.reset, .nothing)
    | none =>
      if (state.record states view).operatesOnSelection then
        state.complete states view (.operate operator .selection state.count state.register)
      else
        ({ state with
            typed, multiplier := state.count, digits := none, operator := some operator,
            walked := [] },
          .nothing)
  | .command command =>
    match state.operator with
    | some _ => (state.reset, .nothing)
    | none =>
      -- The state's run table: the entry's edit, as written, so a count or
      -- a register typed before the key is dropped.
      match state.runOf states view command.name with
      | some edit => state.complete states view edit
      | none =>
        let (next, parsed) := state.finish states view (.run command state.count state.register)
        (next.ran states view command, parsed)
  | .register =>
    if state.operator.isSome || state.register.isSome then (state.reset, .nothing)
    else
      ({ state with
          typed, multiplier := state.count, digits := none, awaitsRegister := true, walked := [] },
        .nothing)
  | .repeat =>
    match state.operator, state.lastChange with
    | none, some change =>
      -- A count typed before the key replaces the change's own, for this
      -- replay and for those after it.
      let change := (state.count.map change.withCount).getD change
      let (next, parsed) := state.finish states view (.replay change state.inserted)
      ({ next with lastChange := some change }, parsed)
    | _, _ => (state.reset, .nothing)
  | .mode bound => State.reached states view state typed bound
  | .within _ bound => State.reached states view state typed bound

/-- The two tiers a key for `view` is walked through ("The grammar", in the
module docs): the active keymaps of `view`, each with only the bindings
that hold in the record of the view's Vim state, over that state's own
keymaps, or its pending keymaps while an operator waits when it has any.
`parse` walks them and `State.continuations` lists from them, so the two
cannot drift apart. -/
def State.tiers (states : States) (maps : ViewId → List (Keymap Bound)) (view : ViewId)
    (state : State) : List (Keymap Bound) × List (Keymap Bound) :=
  let record := state.record states view
  let active := (maps view).map (·.filter (·.holdsIn record))
  let own :=
    if state.operator.isSome && !record.pending.isEmpty then record.pending else record.keymaps
  (active, own)

/-- The keys that can follow the keymap prefix walked so far for `view`, and
what the walk makes of each, from the same tiers `parse` walks
(`State.tiers`), with prefixes named by `names`. None when no keymap prefix
is walked, or while the next key names a character or a register: a count,
the register prefix or an operator alone is no keymap prefix. -/
def State.continuations (states : States) (maps : ViewId → List (Keymap Bound))
    (names : List Key → Option String) (view : ViewId) (state : State) :
    List (Keymap.Continuation Bound) :=
  if state.walked.isEmpty || state.awaitsChar.isSome || state.awaitsRegister then []
  else
    let (active, own) := state.tiers states maps view
    Keymap.continuationsOver active own state.walked names

/-- One key of the grammar, a key for `view`: the state it leaves, and what
it parsed to (the rules in the module docs). A digit of a count is taken
first, where typing is not text; any other key is walked through the
active keymaps of `view` and then the keymaps of the view's Vim state, its
pending keymaps while an operator waits when it has any. An
unbound key is text when the view's state inserts text, the key prints and
no edit is begun, and otherwise resets. -/
def parse (states : States) (maps : ViewId → List (Keymap Bound)) (view : ViewId) (state : State)
    (key : Key) : State × Parsed :=
  -- A key for a view other than the minibuffer's: the prompt was cancelled,
  -- and the edit that waited for its answer is dropped.
  let state :=
    if state.asking.any (·.minibuffer != some view) then { state with asking := none } else state
  let record := state.record states view
  let typed := state.typed ++ [key.chord]
  if let some name := state.awaitsChar then
    match Key.character? key with
    | some char =>
      match state.operator with
      | some operator =>
        state.finish states view
          (.operate operator (.motion name (some char)) state.count state.register)
      | none => state.finish states view (.move name state.count (some char))
    | none => (state.reset, .nothing)
  else
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
        let (active, own) := state.tiers states maps view
        match Keymap.walkOver active own state.walked key with
        | (_, some binding) => state.reached states view typed binding
        | (walked, none) =>
          if !walked.isEmpty then
            ({ state with
                typed, walked },
              .nothing)
          else
            if record.insertsText && state.typed.isEmpty then
              match key.printed? with
              | some text => (state.typedText view text, .text text)
              | none => (state, .nothing)
            else (state.reset, .nothing)

/-- The name of the command typed text runs. -/
def selfInsertCommand : String :=
  "self-insert"

/-- The invocation typed text yields: the command `selfInsertCommand`, with
the text a key printed as its argument. -/
def selfInsert (text : String) : Invocation :=
  { command := selfInsertCommand, arguments := [.str text] }

/-- One key of the Vim scheme: `parse`, with the edit it completed compiled
to its invocation. -/
def step (states : States) (maps : ViewId → List (Keymap Bound)) (view : ViewId) (state : State)
    (key : Key) : State × Option Invocation :=
  match parse states maps view state key with
  | (next, .nothing) => (next, none)
  | (next, .edit edit) => (next, some edit.compile)
  | (next, .text text) => (next, some (selfInsert text))
  | (next, .ask label) => (next, some { command := askCommand, arguments := [.str label] })

/-- The state once `answer` came to the prompt the scheme asked for, and the
invocation it completes ("Motions that ask", in the module docs): the edit
that waited, with the answer as its motion's argument, completed for the
view it is for as a key completes one (`State.finish`). With no edit
waiting the state is as it was and nothing is yielded. -/
def State.answered (states : States) (_ : ViewId) (answer : String) (state : State) :
    State × Option Invocation :=
  match state.asking with
  | none => (state, none)
  | some asking =>
    let state := { state with asking := none }
    let edit : Edit :=
      match asking.operator with
      | some operator =>
        .operate operator (.motion asking.motion (some answer)) asking.count asking.register
      | none => .move asking.motion asking.count (some answer)
    let (next, _) := state.finish states asking.view edit
    (next, some edit.compile)

/-- What a menu item's `invocation` for `view` is, from `state`: when it has
no arguments and the run table of the view's Vim state has an entry for its
command, that entry's edit, completed as a key bound to the name would
complete it, and compiled; otherwise the state and the invocation as they
were. -/
def State.invoked (states : States) (view : ViewId) (state : State) (invocation : Invocation) :
    State × Invocation :=
  match invocation.arguments, state.runOf states view invocation.command with
  | [], some edit => ((state.complete states view edit).1, edit.compile)
  | _, _ => (state, invocation)

/-- What the Vim scheme says of modes' keys: its role table, its leader and
localleader, each as chords or strokes. The grammar reads none of it. -/
structure ModeKeys where
  /-- The keys each role is on. -/
  roles : List (Role × List Key) := []
  /-- The prefix of config's bindings written `<leader>`. -/
  leader : List Key := []
  /-- The prefix a mode's suffixes are bound under, and config's bindings
  written `<localleader>`, written over the leader. -/
  localLeader : List Key.Stroke := []
  /-- The hand-tuned keys: a mode's name, a key sequence and what it is
  bound to. -/
  tuned : List (String × List Key × Bound) := []

/-- The Vim scheme over the registry `states`, with the role table, leader,
localleader and hand-tuned keys `modes`. Its bindings are parts of speech,
and it reports every key of the edit begun as pending. A key bound to a
command name is bound to the command of that name, which changes no text
and enters no state: the grammar cannot look either up. A key a mode binds,
and a hand-tuned key, is marked as a mode's (`Bound.mode`), and a key bound
for some states holds only in those (`Bound.within`). Its own keymaps are
every state's. A view that is closed has its Vim state forgotten, and a
view that is opened as the minibuffer's is put in the state the registry
names for it. A text it is told was committed in a view is typed text
there: it is added to what is kept for the last change when the view is
the one being kept for (`State.typedText`). What it reports of a view is
read off the record of the view's Vim state (`State.report`). A menu
item's invocation is run as the view's state's run table says
(`State.invoked`). What can follow a keymap prefix is listed from the tiers
the grammar walks (`State.continuations`). -/
def scheme (states : States) (modes : ModeKeys := {}) : InputScheme :=
  { State, Binding := Bound, init := {}, step := step states, pending := (·.typed)
    report := State.report states
    command := fun name => .command { name }
    roles := modes.roles
    leader := modes.leader
    localLeader := modes.localLeader
    modeCommand := fun name => .mode (.command { name })
    stateCommand := fun states name => .within states (.command { name })
    defaults :=
      states.initial.keymaps ++ states.initial.pending ++
        states.others.flatMap fun record => record.keymaps ++ record.pending
    tuned := modes.tuned.map fun (name, keys, bound) => (name, keys, .mode bound)
    closeView := State.closeView
    openMinibuffer := State.openMinibuffer states
    committed := fun view text state => state.typedText view text
    answered := State.answered states
    invoked := State.invoked states
    continuations := State.continuations states }

end Editor.Vim
