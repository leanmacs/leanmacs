import Editor.Invocation
import Editor.Key.Notation
import Editor.Keymap
import Editor.Role
import Editor.Scene

/-!
# Input schemes

An input scheme is how keys become invocations: a state machine over keys,
packaged with its own state type and its own binding type (`InputScheme`).
The core runs a scheme without knowing either type. A scheme owns its
grammar, such as counts and operators in a Vim-style scheme; the core owns
the keymap walk (`Editor/Keymap.lean`) and what an invocation is
(`Editor/Invocation.lean`). It is pure: a step reaches nothing outside its
arguments, so a scheme is tested under `lake test` with no model
(`docs/design/keymaps-and-modes.md`, "Input schemes").

## What a step is given

- **The active keymaps, as a function of the view**, and **the view the key
  is for**. There is no ambient current view: the caller says which view,
  and the scheme asks for that view's keymaps, in precedence order.
- **The scheme's state**, explicit and of the scheme's own type, so a step
  is an ordinary function that a proof can unfold.
- **The key**, as it arrived. A scheme looks it up by its chord
  (`Key.chord`), which `Keymap.walk` does for it.

A step returns the next state and the invocation the key completed, if it
completed one. A scheme also reports the keys of a sequence begun and not
yet completed (`pending`), for the scene's pending text.

Which keys print text is the same for every scheme (`Key.printed?`): a
scheme that yields a self-insert for an unbound key asks it what the key
prints. Which keys are modifiers by themselves is too (`Key.isModifier`):
whoever steps a scheme does not step one, so a scheme never sees the press
of Shift that comes before a shifted key.

A scheme also says what a key bound to a command name is (`command`): the
binding, of its own type, that runs the command of that name. So whoever
holds key sequences bound to command names, as the registry does for config
(`Editor/Config/Registry.lean`), makes a keymap for any scheme without
naming its binding type.

A scheme is told when a view is closed (`closeView`): the state without
what it kept for that view. It defaults to the state as it was, for a
scheme that keeps nothing by view. Whoever runs the scheme tells it once
for each view that is gone (the command loop, `Editor/Loop.lean`). A view's
id is never used again (`Editor/State.lean`), so what a scheme kept for a
closed view could never come to mean another view: the notice is so that it
does not keep it for ever.

A scheme is told when a view is opened as the minibuffer's
(`openMinibuffer`): the state with what the scheme keeps for a view that
typed text goes into. It defaults to the state as it was. Whoever runs the
scheme tells it once, when a prompt opens (the command loop), and the
notice of a closed view is what forgets it: closing the prompt closes the
view. It is a notice for the minibuffer alone and not a general one with a
kind of view: there is one kind of view a scheme must treat apart today.
The notice resets nothing the scheme keeps of a sequence begun.

A scheme is told when a committed text was inserted in a view
(`committed`): the state once that text was typed there. A committed text
is typed text that no key printed, what an input method composed, so it
never passes through `step`, and a scheme that keeps what is typed, as the
Vim scheme keeps the text of the last change's insert session, would miss
it. It defaults to the state as it was. Whoever runs the scheme tells it
once for each commit it inserted, and not for one it dropped (the command
loop).

A scheme can ask a question and be answered (`answered`). A key whose edit
needs a text the user types in the minibuffer, as Vim's `/` needs its
pattern, yields an invocation that opens a prompt whose continuation is
the reserved name `InputScheme.answerName`; no command can be registered
under it. When the prompt is accepted, the loop hands the answer to the
scheme instead of running a command of that name (`Loop.answer`,
`Editor/Loop.lean`): `answered` is the state once the answer came for the
view, and the invocation the answer completes, which the loop runs as it
runs a key's. A scheme that asks nothing answers the state as it was and
nothing, the default, and the scheme contract holds every scheme to that
while it is asking nothing.

A scheme is told when a menu item names an invocation for a view
(`invoked`): the state, and the invocation to run in its place. A menu
item is chosen with no key, so `step` never sees it, and a scheme whose
keys can make a command name run as something else in a state, as the Vim
scheme's run tables do (`Editor/InputScheme/Vim.lean`, "Vim states"),
does the same for the item. It defaults to both as they were. Whoever runs
the scheme tells it once for each menu item chosen (the command loop), and
runs what comes back with the report of the state that comes back. An
invocation of a name the scheme does not know comes back as it was, with
the view's report as it was, which the scheme contract asks.

## What a scheme reports of a view

A scheme says what it knows of a view in a state (`report`, an
`InputScheme.Report`), because nothing else can: its state is of its own
type, which the core does not know
(`docs/design/keymaps-and-modes.md`, "What a scheme reports of a view").

| Field | Default | Who reads it |
|---|---|---|
| `cursor` | A bar in the face `cursor` | The scene: how the view's cursors are drawn |
| `status` | None | The mode line's `state` segment, which draws these fields as its badge (`Editor/ModeLine.lean`) |
| `shape` | `exclusive` | Whoever places the view's selection: the shape it has |
| `selecting` | `false` | A command: a motion moves the head and keeps the anchor |
| `session` | `false` | Whoever sets the boundaries of the history: the view is in an insert session |
| `takesText` | `true` | Whoever handles a committed text: it is inserted in the view |

The defaults are what a scheme that says nothing of a view reports, so a
scheme with no states of its own, as the test scheme is, leaves the field
out. The report is data: a new fact every scheme can say of a view is a
field of it, with a default.

## What a scheme reports for modes

A mode names roles and suffixes, never keys (`Editor/Role.lean`,
`docs/design/keymaps-and-modes.md`, "Modes"). Each scheme says once where
they go: its role table (`roles`, read through `roleKey`), the keys each
registered role is on, its leader (`leader`), the prefix of config's
bindings written `<leader>`, and its localleader (`localLeader`), the
prefix a mode's suffixes are bound under and config's bindings written
`<localleader>`. The localleader is written over the leader, as strokes
(`Key.Stroke`), so it may begin with `<leader>`: the Vim scheme's is
`<leader> m`. Config may set either in place of the scheme's; `leaders`
resolves the two in force, as chords. All three default to empty, which
the scheme contract reports for a scheme that is run: every registered
role has a key, and the leader, the localleader and the roles are apart.

A scheme also says what a key a mode binds is bound to (`modeCommand`),
which is `command` unless the scheme treats a mode's keys apart: the Vim
scheme marks them, so that they do not hold where typing is text. The
registry binds config's bindings under the leader or the localleader to it
too, so they do not hold there either. And a scheme says what a key bound
to hold only in some of its states is bound to (`stateCommand`, given the
states' names, `SchemeState`), which is `command` for a scheme with no
states of its own, so such a binding holds everywhere.

A scheme may tune keys for a mode by hand (`tuned`: a mode's name, a key
sequence and a binding of its own type), which the mode's keymaps consult
ahead of its roles and suffixes (`Editor/Mode.lean`), and reports its own
keymaps (`defaults`), against which `Mode.check` finds a tuned key that
shadows one of the scheme's. Both default to empty.

## What every scheme must do

`Editor/InputScheme/Contract.lean` is the contract check every scheme runs:
a strict prefix of a complete input yields nothing and is reported as
pending, a key that continues nothing resets the pending keys, and a key
bound to `command` of a name yields an invocation of that command. The
record carries no equality on `State`: a scheme's state may hold what a
reset must keep, so the contract speaks of `pending` and of what the scheme
then yields.

The scheme that ships is not here: it is the Vim scheme
(`Editor/InputScheme/Vim.lean`), over its default states and bindings
(`Editor/InputScheme/Vim/Default.lean`). `Editor/InputScheme/Test.lean` is
the test scheme, published for other modules' tests.

## Where an addition goes

| Addition | Where |
|---|---|
| A new scheme | A value of `InputScheme` in a module of its own, which runs the contract check |
| Something every scheme must report to the core | A field of `InputScheme`, and a property of the contract |
| What a scheme makes of an invocation no key yielded, such as a menu item's | `invoked`, which `invokedKeepsUnknown` in the contract holds to its default for a name the scheme does not know |
| Something a scheme says of one view, for the scene, the loop or a command | A field of `InputScheme.Report`, with the default a scheme that says nothing reports |
| Something one scheme remembers between keys | That scheme's `State`; nothing here |
| A fact about a key that more than one scheme reads | A function of `Key` here, as `Key.printed?` is |
| A new prefix config's bindings are written under | A field beside `leader` and `localLeader`, a placeholder in `Editor/Key/Notation.lean`, and its keys in `leaders` |
| A new kind of place a binding may hold in | A field beside `modeCommand` and `stateCommand`, with `command` as its default |

Pinned by `ModelTest.schemeChecks`, on the test scheme.
-/

namespace Editor

/-- What an input scheme says of one view ("What a scheme reports of a
view", in the module docs). The defaults are what a scheme that says
nothing of a view reports. -/
structure InputScheme.Report where
  /-- How the view's cursors are drawn. -/
  cursor : Cursor := { shape := .bar, face := ⟨"cursor"⟩ }
  /-- The scheme's fields of the view's status line, which the mode line's
  `state` segment draws as its badge (`Editor/ModeLine.lean`). -/
  status : Array StatusField := #[]
  /-- The shape the view's selection has. -/
  shape : Shape := .exclusive
  /-- Whether a motion in the view moves the selection's head and keeps its
  anchor. -/
  selecting : Bool := false
  /-- Whether the view is in an insert session: what is edited in its
  buffer meanwhile is one step of the history. -/
  session : Bool := false
  /-- Whether a committed text is inserted in the view. -/
  takesText : Bool := true
  deriving DecidableEq, Repr

/-- An input scheme: a state machine over keys, with its own state and
binding types. -/
structure InputScheme where
  /-- What the scheme remembers between keys. -/
  State : Type
  /-- What the scheme's keymaps bind a key sequence to. -/
  Binding : Type
  /-- The state before any key. -/
  init : State
  /-- One key: given the active keymaps of each view, in precedence order,
  the view the key is for, the state and the key, the next state and the
  invocation the key completed, if it completed one. -/
  step : (ViewId → List (Keymap Binding)) → ViewId → State → Key → State × Option Invocation
  /-- The keys of the sequence begun and not yet completed, in order; none
  when no sequence is begun. -/
  pending : State → List Key
  /-- The binding that runs the command of this name: what a key sequence
  bound to a command name is bound to under this scheme. Completing a
  sequence bound to it yields an invocation of that command. -/
  command : String → Binding
  /-- The role table: the keys, as chords, each role is on under this
  scheme (`Editor/Role.lean`). A mode that fills a role is bound there. -/
  roles : List (Role × List Key) := []
  /-- The leader, as chords: the prefix of config's bindings written with
  `<leader>`, when config sets no leader of its own. -/
  leader : List Key := []
  /-- The localleader, as strokes over the leader: the prefix a mode's
  suffixes are bound under, and config's bindings written with
  `<localleader>`, when config sets no localleader of its own. It may hold
  `.leader`, which stands for the leader in force. -/
  localLeader : List Key.Stroke := []
  /-- The binding a key a mode binds (a role, a suffix) is bound to, to run
  the command of this name: `command`, unless the scheme treats a mode's
  keys apart. Completing a sequence bound to it yields an invocation of
  that command. -/
  modeCommand : String → Binding := command
  /-- The binding a key bound to run the command of this name only in the
  scheme's states of these names is bound to (`bindKey`'s `states`):
  `command`, which holds everywhere, unless the scheme has states of its
  own. Completing a sequence bound to it yields an invocation of that
  command. -/
  stateCommand : List String → String → Binding := fun _ name => command name
  /-- The scheme's own keymaps, in precedence order (the Vim scheme's are
  every state's): what a mode's hand-tuned key is checked against for
  shadowing. -/
  defaults : List (Keymap Binding) := []
  /-- The state once the view is closed: without what the scheme kept for
  that view. A scheme that keeps nothing by view leaves it as it was. -/
  closeView : ViewId → State → State := fun _ state => state
  /-- The state once the view is opened as the minibuffer's: with what the
  scheme keeps for a view that typed text goes into. A scheme that treats
  no view apart leaves it as it was. -/
  openMinibuffer : ViewId → State → State := fun _ state => state
  /-- The state once this text, committed and not typed by a key, was
  inserted in the view. A scheme that keeps nothing of what is typed leaves
  it as it was. -/
  committed : ViewId → String → State → State := fun _ _ state => state
  /-- The state once `answer` came, for the view, to the question the
  scheme asked (`answerName`), and the invocation it completes, if it
  completes one. A scheme that asks nothing leaves the state as it was and
  yields nothing. -/
  answered : ViewId → String → State → State × Option Invocation := fun _ _ state => (state, none)
  /-- The state, and the invocation to run, once a menu item names this
  invocation for the view: an invocation no key yielded. A scheme that
  treats no such invocation apart leaves both as they were. -/
  invoked : ViewId → State → Invocation → State × Invocation := fun _ state invocation =>
    (state, invocation)
  /-- What the scheme says of a view in a state: how its cursor is drawn,
  its fields of the status line, the shape of its selection, and what the
  loop and a command act on. A scheme that says nothing of a view reports
  the default. -/
  report : State → ViewId → InputScheme.Report := fun _ _ => {}
  /-- The scheme's hand-tuned keys: each a mode's name, a key sequence as
  chords, and its binding, consulted with that mode ahead of its roles and
  suffixes. -/
  tuned : List (String × List Key × Binding) := []

/-- The reserved name of a prompt's continuation whose answer is the input
scheme's (`InputScheme.answered`): the loop hands the answer to the scheme
and runs no command of this name, so no command can be registered under
it. -/
def InputScheme.answerName : String :=
  "input-scheme-answer"

/-- The keys `role` is on in `scheme`'s role table, if it has a row. -/
def InputScheme.roleKey (scheme : InputScheme) (role : Role) : Option (List Key) :=
  (scheme.roles.find? (·.1 == role)).map (·.2)

/-- The leaders in force under `scheme`, as chords: `leader`, or the
scheme's when it is `none`, and `localLeader`, or the scheme's when it is
`none`, with that leader in place of its `<leader>`. -/
def InputScheme.leaders (scheme : InputScheme) (leader : Option (List Key) := none)
    (localLeader : Option (List Key.Stroke) := none) : Key.Leaders :=
  let leader := leader.getD scheme.leader
  { leader, localLeader := Key.expand { leader } (localLeader.getD scheme.localLeader) }

/-- A state of a scheme, by its name, as config names one for a binding
that holds only there (`bindKey`'s `states`). The scheme says which states
it has: the Vim scheme's are constants of `Editor/InputScheme/Vim/Default.lean`
(`SchemeState.insert`). -/
structure SchemeState where
  /-- The state's name, as the scheme registers it. -/
  name : String
  deriving DecidableEq, Repr

/-- The text `key` prints, if it is printable: its logical key is a
character, and none of control, alt and super is held. It is the key's own,
so every scheme that yields a self-insert reads it here. -/
def Key.printed? (key : Key) : Option String :=
  match key.logical with
  | .character text =>
    if key.modifiers.control || key.modifiers.alt || key.modifiers.superKey then none else some text
  | _ => none

/-- The W3C UI Events `key` values of the keys that are modifiers by
themselves. -/
def Key.modifierNames : List String :=
  ["Shift", "Control", "Alt", "AltGraph", "Meta", "Super", "Hyper", "CapsLock", "NumLock",
    "ScrollLock", "Fn", "FnLock", "Symbol", "SymbolLock"]

/-- Whether `key` is a modifier key by itself: a named key whose name is one
of `Key.modifierNames`, whatever modifiers are held with it. A window
reports the press of Shift before the `G` it shifts, and that press is no
key of a sequence: whoever steps a scheme does not step it, for any
scheme. -/
def Key.isModifier (key : Key) : Bool :=
  match key.logical with
  | .named named => Key.modifierNames.contains named.name
  | _ => false

/-- Steps `scheme` from `state` through `keys`, each a key for `view`: the
state it is left in, and what each key yielded, one entry a key, in order. -/
def InputScheme.feed (scheme : InputScheme) (maps : ViewId → List (Keymap scheme.Binding))
    (view : ViewId) (state : scheme.State) (keys : List Key) :
    scheme.State × List (Option Invocation) :=
  keys.foldl
    (fun (state, yields) key =>
      let (next, yielded) := scheme.step maps view state key
      (next, yields ++ [yielded]))
    (state, [])

end Editor
