# Keymaps and modes

How a key becomes a command, how Vim-style editing is built on that, how
modes contribute keys and behaviour, and how all of it is tested.

Status: partly built. The core's keymaps, input schemes and invocations
are built, in Lean with no port, with the test scheme and the contract
every scheme runs, and so are the Vim scheme's grammar, with its default
states and bindings, modes, and evil's states, motions, operators,
registers, undo and dot repeat, on the editor API:

| Built | Where |
|---|---|
| Keymaps, a key's chord, the walk and its proof | `lean/Editor/Keymap.lean` |
| Key strings | `lean/Editor/Key/Notation.lean` |
| Invocations | `lean/Editor/Invocation.lean` |
| The scheme interface, and what a key prints | `lean/Editor/InputScheme.lean` |
| The test scheme | `lean/Editor/InputScheme/Test.lean` |
| The scheme contract | `lean/Editor/InputScheme/Contract.lean` |
| The Vim scheme's grammar: parts of speech, edits, counts, registers, Vim states, the last change | `lean/Editor/InputScheme/Vim.lean` |
| The Vim scheme's default states and bindings, and the scheme that ships | `lean/Editor/InputScheme/Vim/Default.lean` |
| The loop's one scheme, the keys it steps, running an invocation, rollback and the interrupt | `lean/Editor/Loop.lean` ("The loop runs one scheme" below) |
| What a command is run with: its target, arguments and keys | `lean/Editor/Command/Call.lean` |
| Compiled and config commands and key bindings, by owner, and the keymap of the bindings | `lean/Editor/Config/Registry.lean`, `lean/Editor/Setup.lean` (`bindKey`) |
| The registered roles | `lean/Editor/Role.lean` |
| Each scheme's role table, leader, hand-tuned keys and own keymaps, and what a mode's key is bound to | `lean/Editor/InputScheme.lean`; the test scheme's and the Vim scheme's tables in `lean/Editor/InputScheme/Test.lean` and `lean/Editor/InputScheme/Vim/Default.lean` |
| The mode record, the keymaps a mode makes for a scheme, `Mode.check` | `lean/Editor/Mode.lean` |
| Modes by owner, a mode's lineage, the active keymaps of a view, setting a major mode through a view and its on-enter action | `lean/Editor/Config/Registry.lean` |
| Defining a mode from `setup`, and its refusals | `lean/Editor/Setup.lean` (`defineMode`), `lean/Editor/Config/Registry.lean` (`Registrations.problem?`) |
| A buffer's major and minor modes, and the state operations that set them | `lean/Editor/State.lean` |
| The language entry, the shipped table, the rule that chooses a path's language, and the `code` mode | `lean/Editor/Language.lean`; a buffer's language in `lean/Editor/State.lean`, chosen when a file opens in `lean/Editor/Files.lean` |
| The notice a scheme is told when the minibuffer's view opens, and the contract's property that a key that prints is text there | `lean/Editor/InputScheme.lean` (`openMinibuffer`), `lean/Editor/InputScheme/Contract.lean` (`minibufferTakesText`), `lean/Editor/Loop.lean` (`Loop.toldViews`) |
| The minibuffer's mode and its six commands (accept, cancel, the next and the previous candidate, delete backward, and delete to the input's start), and their registrations | `lean/Editor/Minibuffer.lean`, `lean/Editor/Minibuffer/Compiled.lean` |
| The frame's commands (`toggle-fullscreen`, `minimise-window`) and their compiled bindings `C-s-f` and `s-m` | `lean/Editor/FrameCommands.lean`, `lean/Editor/FrameCommands/Compiled.lean` |
| The Vim state of the minibuffer's view, and its default keys | `lean/Editor/InputScheme/Vim.lean` (`States.minibuffer`, `State.openMinibuffer`), `lean/Editor/InputScheme/Vim/Default.lean` (`minibufferCommands`) |
| What a scheme reports of a view, and the contract's property that a key that yields nothing leaves it as it was | `lean/Editor/InputScheme.lean` (`InputScheme.Report`, `report`), `lean/Editor/InputScheme/Contract.lean` (`quietKeyKeepsReport`) |
| A Vim state's selection shape, and the Vim scheme's report of a view's state | `lean/Editor/InputScheme/Vim.lean` (`StateRecord.shape`, `State.report`), `lean/Editor/InputScheme/Vim/Default.lean` |
| What the loop does with a report: the scene's cursor and status field, the report a command is told, the first window's shape, insert sessions, and where a committed text is inserted | `lean/Editor/Loop.lean`, `lean/Editor/Command/Call.lean` (`Call.report`) |
| A window's wanted column | `lean/Editor/State.lean` (`Window.wanted`), `lean/Editor/Api.lean` (`ViewId.setWanted`) |
| The vocabulary's motion record, with how an operator takes a motion, and its operator record | `lean/Editor/Vocabulary.lean` |
| Evil: where a cursor rests, the move command, entering a state, the keys that begin an insert, the two that open a line, typed text | `lean/Editor/Evil.lean` |
| Evil's twenty-seven motions and their table | `lean/Editor/Evil/Motions.lean` |
| Evil's three operators and their table, what an operator takes, the operate command, and `x` | `lean/Editor/Evil/Operators.lean` |
| Evil's registers: the unnamed one and the clipboard's, storing, fetching, and `p` and `P` | `lean/Editor/Evil/Registers.lean` |
| Evil's undo and redo | `lean/Editor/Evil/Undo.lean` |
| Evil's dot repeat: the repeat command | `lean/Editor/Evil/Repeat.lean` |
| Evil's scroll commands: by half a view, by a view, and to the cursor's row | `lean/Editor/Evil/Scroll.lean`, over the policy in `lean/Editor/Scroll.lean` |
| What is proved of evil on the text model: `x` then `u` restores the text | `lean/Editor/Evil/Theorems.lean`, with `lean/Editor/UndoTree/Theorems.lean` |
| The clipboard port, its model, its contract, and the clipboard of a host with no window | `lean/Editor/Clipboard.lean`, `lean/Editor/Clipboard/Model.lean`, `lean/Editor/Clipboard/Contract.lean`, `lean/Editor/Clipboard/InProcess.lean` |
| Evil's commands as compiled code registers them | `lean/Editor/Evil/Compiled.lean` |
| An ex line as data: its name and argument, and an ex binding | `lean/Editor/Ex/Line.lean` |
| Ex bindings by owner, and binding one from `setup` | `lean/Editor/Config/Registry.lean` (`replaceEx`, `ex?`), `lean/Editor/Setup.lean` (`exCommand`) |
| The ex command, and the commands `quit`, `save-and-quit` and `reload-config` | `lean/Editor/Ex.lean` |
| The ex line's commands and the ex names that ship, as compiled code registers them | `lean/Editor/Ex/Compiled.lean` |

The command loop steps every key press through its one scheme and runs the
invocation it yields, as a command looked up by name in the registry. The
Vim scheme ships, and so does every command a default key names,
compiled into the executable: the motions, the operators `d c y` over a
motion, over lines and over a visual selection, `x p P o O`, `u` and
`C-r`, `.`, `i a I A`, `v V`, `<Escape>`, `:`, typed text, and the scroll
keys `C-d C-u C-f C-b` and `z t`, `z z`, `z b`. So with no
config the editor moves, edits, undoes, repeats and scrolls, and `:` opens
the ex command line ("The ex command line"). No default key names a command
that is not registered ("Default bindings"). The system clipboard is
reached through a port defined here, with a model and a contract; the
adapter to a window system's clipboard is the display pipeline's, and a
host with no window keeps a clipboard of its own ("Registers"). One
mode ships, the minibuffer's ("The minibuffer"); the others are built and
tested with the modes their tests define. Of the vocabulary, motions,
operators and the text objects that need no syntax tree are built.
Nothing is measured. The one settled input is the
priority:
Vim-style editing is the scheme that ships and is polished; other schemes
must stay possible without being paid for now.

## Summary

- Key handling is pure core logic, not a port. Only running the chosen
  command touches the editor API.
- The core owns a generic keymap and an **input scheme** interface. Vim's
  grammar (counts, operators, motions) lives in one scheme, not in the core.
- The core also owns the **vocabulary**: motions, operators and text objects
  as registered data, usable by any scheme.
- A mode is a record in a registry. It declares keys in scheme-neutral
  terms (roles and leader suffixes), so a mode works under any scheme
  without per-scheme bindings.
- Hand-tuned keys for one scheme are an opt-in extra, written for Vim only
  in the standard library.

## The pipeline

```
Key ──► step ──► Invocation ──► run : Invocation → EditorM Unit
(data)  (pure)   (data)         (the only part that needs the editor API)
```

- **`Key`** arrives from the Rust event queue as plain data.
- **`step`** is a pure function of the active keymaps, the view the key is
  for, the scheme's state and the key.
- **`Invocation`** is a command name plus plain arguments. It holds no
  closures, so it can be compared, stored and replayed. A registry maps
  command names to `EditorM` actions. As built, the name is a `String`, as
  the registry names a command, and an argument is one of a flat set of
  kinds (`Argument`: a natural number, an integer, a string, a truth
  value), so `Invocation` derives decidable equality. A store's `Value` is
  a nested inductive, for which Lean derives none (the table under
  Keymaps). Whoever runs invocations may widen `Argument`.
- **`run`** looks the command up and runs it against the editor API
  ([lean-runtime.md](lean-runtime.md)), real or model.

Keymaps therefore need no fake. A port is how the core reaches the outside
world, and key lookup never does.

## The core

### Keymaps

A keymap is parametric in what a key is bound to. The core knows only how
to walk prefixes. A keymap is a flat list of bound key sequences, one entry
a sequence and what it is bound to:

```lean
structure Keymap (β : Type) where
  bindings : List (List Key × β)
```

A sequence is a prefix when some binding begins with it and is longer; no
entry stands for a prefix by itself.

Why a flat list, and not a tree of submaps:

- **The list is its own specification.** What is proved of the walk is
  stated over the bindings, not over the internals of a hash table.
- **Equality and `Repr` are derivable**, and no function over a keymap is a
  nested recursion.
- **`Std.Data.HashMap` stays out of the modules config is elaborated on**
  (the root `Editor`).

A lookup is linear in the bindings. Nothing is measured. The list is reached
only through the keymap's own operations, so a hashed map can replace it
behind them if a measurement asks for one.

What the pinned toolchain (`leanprover/lean4:v4.35.0`) makes of the
alternatives, checked with scratch files that are not in the repository (a
declaration being rejected cannot be a `lake test` check). Look again when
the toolchain is bumped:

| Declaration | Lean 4.35.0 |
|---|---|
| `inductive Entry (β) \| bound (b : β) \| submap (m : Std.HashMap String (Entry β))` | Rejected by the kernel: `(kernel) application type mismatch  Std.DHashMap.Raw.WF inner  argument has type  _nested.Std.DHashMap.Raw_3`. A `Std.HashMap` carries a proof that its table is well formed, and a nested occurrence cannot go through it |
| The same through `List (String × Entry β)` | Accepted, and a structurally recursive lookup over it (a `mutual` pair, over the entry and over the list) compiles and runs |
| `deriving DecidableEq` on that nested inductive | Refused: "None of the deriving handlers for class `DecidableEq` applied to `Entry`" |

So a tree of submaps is possible through `List` and not through
`Std.HashMap`, and it would cost derived equality and structural proofs.

#### A key as a binding names it

A key from a window carries its physical code and whether the platform
repeated it, and a shifted letter arrives as the character `A` with shift
held. A binding written `A` or `C-x` must match all of those. `Key.chord`
is the key as a binding names it: no physical key, not repeated, and no
shift when the logical key is a character, which already says it. Shift
stays on a named key, so `S-<Tab>` is a key of its own. `Keymap.bind`
stores chords, the walk takes the chord of the key it is given, and the
keymap's constructor is private, so a keymap holds nothing else. There is
no second key type: a keymap is keyed by `Key`.

#### Lookup through a list of keymaps

The active keymaps are a list in precedence order. For a key sequence
(`Keymap.resolve`):

1. the first keymap that binds exactly that sequence gives its binding;
2. otherwise, if a binding in any keymap begins with the sequence, the
   sequence is pending;
3. otherwise it is unbound.

- **A bound sequence is never also a prefix.** There is no timeout, so a
  longer binding under a bound sequence, in the same keymap or another, is
  not reached. Nothing reports such a binding yet.
- **Pending prefixes merge across keymaps.** A prefix in one keymap and a
  longer binding in another are both walked.
- **An unbound key is dropped with the prefix before it.** It does not
  start a new sequence.

`Keymap.walk` is one key of this: the keys pending and a key in, the keys
still pending and the binding reached out. That an unbound key resets the
pending prefix is proved (`Keymap.walk_unbound`): when no binding of any
keymap in the list begins with the pending keys followed by the key, the
walk leaves nothing pending and gives nothing.

### Input schemes

A scheme is a state machine over keys, packaged with its own state and
binding types:

```lean
structure InputScheme where
  State   : Type
  Binding : Type
  init    : State
  step    : (ViewId → List (Keymap Binding)) → ViewId → State → Key
              → State × Option Invocation
  pending : State → List Key
  command : String → Binding
  -- what a scheme says for modes ("Roles" and "Hand-tuned keys" under Modes)
  roles       : List (Role × List Key)          := []
  leader      : List Key                        := []
  modeCommand : String → Binding                := command
  defaults    : List (Keymap Binding)           := []
  tuned       : List (String × List Key × Binding) := []
  -- what a scheme says of one view ("What a scheme reports of a view")
  report      : State → ViewId → InputScheme.Report := fun _ _ => {}
  -- notices, each the state once something happened
  closeView      : ViewId → State → State := fun _ s => s
  openMinibuffer : ViewId → State → State := fun _ s => s
  committed      : ViewId → String → State → State := fun _ _ s => s
  -- the answer to a prompt the scheme asked for, and what it completes
  answered : ViewId → String → State → State × Option Invocation := fun _ _ s => (s, none)
```

- **`answered` is how a scheme is answered.** A key whose edit needs a text
  typed in the minibuffer (Vim's `/`) yields `minibuffer-ask`, which opens
  a prompt whose continuation is the reserved name
  `InputScheme.answerName`. When it is accepted, `Loop.invoke` hands the
  answer to the scheme instead of looking a command up (`Loop.answer`),
  and runs what the scheme yields as it runs a key's invocation, keeping
  or restoring the scheme's state at rest. A scheme that asks nothing
  yields nothing, which the scheme contract holds every scheme to
  (`unaskedAnswerYieldsNothing`); the test scheme keeps the default.

- **`command` is what a key bound to a command name is bound to** under the
  scheme. Config and compiled code bind a key sequence to a command's name
  and never name a scheme's `Binding`; the scheme turns the name into its
  binding (the test scheme's is the invocation of that name with no
  arguments, the Vim scheme's a named command). Completing a sequence bound
  to it yields an invocation of that command.
- **`step` is given the view the key is for**, beside the keymaps as a
  function of the view. A function of the view with no view to apply it to
  would need an ambient focus.
- **`pending` reports the keys of a sequence begun and not completed**, for
  the scene's pending text.
- **The record carries no equality on `State`.** A scheme's state may hold
  what a reset must keep, such as the Vim scheme's last edit for
  dot-repeat. So the scheme contract speaks of a reset through `pending`
  and through what the scheme yields next, not through states. Lean's
  instance search does not find a decidable equality through the
  type-valued field either: a test compares states at the scheme's own
  concrete type.
- The core runs a scheme without knowing its `State`. This is an
  existential package: a record with type-valued fields.
- The state is explicit, not hidden in a closure. A self-referential
  `Key → (Machine × Output)` type is inductive in Lean and has no values
  without `partial`. An explicit `State` also keeps `step` open to proof.
- The active keymaps are a function of the view, passed in. There is no
  ambient "current buffer" (see the principles in
  [overview.md](overview.md)).

#### What a scheme reports of a view

Status: decided 2026-11-14 and built, by the command loop's phase 11
(`lean/Editor/InputScheme.lean`; pinned by `ModelTest.schemeChecks`, and
what the loop does with a report by `loopChecks`, `dispatchReportChecks`,
`dispatchUndoChecks` and `commitChecks`, each with a scheme written in the
test whose report a key switches).

A command cannot learn which Vim state its view is in: the state is in the
scheme's state, which the loop holds at a type it does not know. The scene
cannot either. So the scheme interface has one function for it, and the
loop hands its answer to the command it runs and to the scene:

```lean
report : State → ViewId → InputScheme.Report   -- defaults to the default report
```

| Field of `InputScheme.Report` | Default | Read by |
|---|---|---|
| `cursor : Cursor` | A bar in the face `cursor` | The scene: how the view's cursors are drawn |
| `status : Array StatusField` | None | The mode line's `state` segment, which draws these fields as its badge on the selected window |
| `shape : Shape` | `exclusive` | The first window's selection, and a command that places one |
| `selecting : Bool` | `false` | A command: a motion moves the head and keeps the anchor |
| `session : Bool` | `false` | The loop: the view is in an insert session ("Insert sessions") |
| `takesText : Bool` | `true` | The loop: a committed text is inserted in the view |

- **The defaults are what the loop does with no report**, so a scheme that
  says nothing of a view, as the test scheme does, changes nothing.
- **A command is told the report of its view** (a field of `Call`), in the
  scheme's state after the key: the key that enters a state is the key
  whose command reshapes the selection, and that command must see the
  state it is entering. When the command fails the scheme goes back to its
  state at rest and the editor state to the one before the command, so the
  two cannot disagree.
- **A command no key ran** (one run by its name, a prompt's continuation)
  is told the report in the state the scheme is in.
- **So a command enters no state: a key does.** A scheme's state is
  changed only by its `step`, and under the Vim scheme by a key bound to
  an edit that names a state ("Vim states"). The commands such a key runs
  (`normal`, `visual`, `visual-line`, and the four that begin an insert)
  reshape the selection for the state they are told of, and change
  nothing of the scheme. Run by name, or by a key bound to the name
  alone, which enters no state, each is told of the state the view is
  already in: the view stays in it, the selection is reshaped for it, and
  nothing is said in the echo area (`docs/dev-practices/headless-mode.md`
  has what `run insert` does).
  - **Set aside: a message from the command.** The command is not told
    the name it was run under, one function is registered under three
    names, and no fact of the report says which state a name stands for.
    A message would need evil to match on a state's name or to keep a
    second copy of each record's facts, and "Vim states" has neither.
    That no key ran the command does not decide it either: a key bound
    to the name alone enters no state, and a command of config's run by
    name may call `Evil.enter` with a report of its own.
  - **A state's run table, and a menu item.** A record of the Vim scheme
    may say that in its state a command name is completed as another
    edit (`StateRecord.runs`), which can end a selection or enter a
    state: Copy in a visual state is `"+y`, and Select All enters
    `visual-line`. It holds for a key bound to the name alone, in any
    keymap, and for a menu item that names it: the loop tells the scheme
    of a menu item (`InputScheme.invoked`) and runs what it hands back,
    with the report of the state it hands back, so on macOS, where AppKit
    runs the item for `s-c` before the key reaches the window, the menu
    and the key agree. So a key or a menu item enters a state, and still
    no command does. A name with no entry runs as named, and config's
    binding of the chord to another name wins, since the table looks at
    the name reached.
- **The first window's selection has the reported shape**: the loop starts
  its state with the scheme's report of the first view
  (`Loop.start`, `EditorState.initial`). A window made later takes its
  shape from a window that exists (a split copies the selection, and a
  window shown another buffer keeps its selection's shape), and the
  minibuffer's cursor is exclusive. A view whose shape and state disagree,
  as a split made from a view in another state is, is put right by the
  next evil command, which always places the selection with the reported
  shape.
- **A committed text is inserted only where the report says the view takes
  text** ("Insert sessions").
- **The contract has a property for it** (`quietKeyKeepsReport`): a key
  that yields nothing leaves the report of its view as it was, after a
  strict prefix of a complete input and after the unbound key that resets
  it. The loop decides after every key whether a buffer's undo group stays
  open, and a key that ran no command must not open or end a session. It
  forbids a scheme that changes a view's cursor while an operator is
  pending, which Vim itself does (the open questions).
- **Set aside: the Vim state mirrored in the editor state's window.** It
  would be one fact in two places, kept in step by every command and by
  the rollback.
- **Set aside: the state's facts as arguments of the invocation.** The
  layout of a move's arguments is the grammar's, and a command run by name
  has no such arguments.

#### The test scheme

The simplest scheme there is, published for other modules' tests
(`TestScheme.scheme`) and not shipped:

- A binding is an `Invocation`: completing a sequence yields exactly what
  it is bound to. No `Command` type exists yet, and a command is named by
  its invocation.
- Its state is the pending keys and nothing else, so after a reset its
  state equals its initial state.
- An unbound key with nothing pending yields a self-insert invocation
  (`TestScheme.selfInsert`, with the character as its argument) when the
  key is printable: its logical key is a character, and none of control,
  alt and super is held. Which keys print is one rule for every scheme
  (`Key.printed?`, beside the scheme interface). The name of that
  invocation is the test scheme's own. The shipped self-insert is the Vim
  scheme's (`Vim.selfInsert`, under "Edits" below): it is yielded only in a
  Vim state that inserts text.

### The loop runs one scheme

Status: built (`lean/Editor/Loop.lean`, whose module docs have the detail;
pinned on the models by `ModelTest.dispatchChecks` and through the headless
host by `ConfigTest.dispatchChecks`). The headless host takes the scheme as
a parameter; the executable runs `Vim.Default.scheme` and the tests the test
scheme.

- **One scheme for the editor.** The loop is given its scheme when it
  starts, and the scheme is fixed for the loop's life. The loop holds the
  scheme's state. One view differs from another by its active keymaps,
  which are already a function of the view in `step`, and by what the
  scheme keeps for each view (the Vim scheme's `current`).
- **A scheme is told when a view is closed.** The scheme interface has a
  notice, `closeView`: the scheme's state without what it kept for that
  view. It defaults to changing nothing. After a command that ran to its
  end, the loop tells both states of the scheme it keeps of each view the
  command closed, and the Vim scheme drops the view's entry from `current`
  (pinned by `ModelTest.schemeChecks`, `vimStateChecks` and
  `dispatchChecks`). A view's id is never used again
  (`lean/Editor/State.lean`), so an entry left behind could never have
  come to mean another view; the notice is so that the state does not
  grow with every view that was ever opened. A command that did not run to
  its end closed nothing, and the scheme is told nothing.
- **Why not one a view.** There is one keyboard, and a sequence begun in
  one view is one pending input ("Vim states": the pending edit is one for
  the scheme). A scheme for each view would need a table of states of
  different types and a rule for a prefix that is pending when the focus
  moves. No second scheme ships.
- **A terminal view** takes keys through its keymaps, which modes supply.
- **The minibuffer takes keys as the focused window**, through its
  buffer's mode, under the same scheme: there is no second path for keys.
  A scheme is told when the minibuffer's view opens, by a second notice
  beside `closeView`, `openMinibuffer`, and takes typed text there ("The
  minibuffer", under Modes).
- **The scheme is a parameter of the loop, not a field.** `InputScheme`
  has type-valued fields, so it is in `Type 1`, and a value that flows
  through `EditorM` or `IO` must be in `Type`. So the loop's type is
  `Loop scheme`, and its field for the scheme's state is of type
  `scheme.State`.
- **Which keys are stepped.** A key event is stepped when it is a press (a
  repeat is a press) and its key is not a modifier by itself. A release is
  not stepped. A modifier key by itself is not stepped either: a window
  reports the Shift press before `G`, and stepped it would be an unbound
  key that resets the `d` of `dG`. Which keys those are is one rule for
  every scheme (`Key.isModifier`, beside `Key.printed?`): a named key
  whose W3C `key` value is `Shift`, `Control`, `Alt`, `AltGraph`, `Meta`,
  `Super`, `Hyper`, `CapsLock`, `NumLock`, `ScrollLock`, `Fn`, `FnLock`,
  `Symbol` or `SymbolLock`.
- **The key is for the focused view**, the frame's. The event's text is not
  read: a scheme asks `Key.printed?`.
- **A command that fails after its key entered a state.** The loop keeps
  two states of the scheme: the one after the last key, and the last one in
  which nothing was pending. When the invocation a key yields does not run
  to its end (no such command, a refusal, an interrupt, a command that
  gives up or breaks off), the scheme goes
  back to the second: it is as it was before the first key of the
  sequence. When the invocation runs to its end, or a key yields nothing
  and leaves nothing pending, the second becomes the first.
  - For the Vim scheme this needs no change to the scheme or its
    interface. A failed `cw` leaves the view in the Vim state it was in, a
    failed edit is not the last change, and no prefix is left pending.
  - Keeping the state the key left would leave a view in insert state with
    nothing changed, and make a failed edit what dot repeat replays. Going
    back to the state before the key alone would leave the failed
    sequence's prefix pending.
  - Consequence: a key whose command is not registered echoes
    `<name>: no such command` and the view stays in the state it was in;
    and an operator whose motion fails (`cj` on the last line) gives up,
    or breaks off where the motion moved first (`c3b` that reaches an
    empty first line), so the view is not left in insert state and the
    cancelled edit is not the last change ("Operators as built").
- **What a command is run with** (`Call`): the focused window and its
  buffer, the invocation's arguments unchanged, the keys that yielded
  it, which are what the scheme reported as pending before the last key,
  then that key's chord, and what the scheme reports of the focused view
  (`Call.report`, "What a scheme reports of a view"), in its state after
  the key. The count is one of the arguments, where the
  scheme laid it out ("Counts"); `Invocation` has no count field, so a
  command has one answer for its count.
- **The scene shows what the scheme reports of each view**: the view's
  cursor is the report's, and its status line is the report's fields and
  then its buffer's ([text-and-display.md](text-and-display.md),
  "Publishing").
- **The scene shows the pending keys**, as a key string
  (`Key.notations`): empty once a sequence completes and after an unbound
  key.
- **A failure is said in the echo area** and the editor keeps running:
  `<name>: no such command`, `<name>: refused: <error>`,
  `<name>: interrupted`, or `<name>: <reason>` for a command that gave up
  or broke off with a reason. The echo is cleared when an invocation runs,
  and not by a key that yields nothing. What the command did is rolled
  back, but for a command that broke off, whose doings stay
  ([concurrency.md](concurrency.md), "Foreground: commands").

### Vocabulary

Status: motions, operators and text objects are built
(`lean/Editor/Vocabulary.lean`; the objects that ship are in "Text objects
as built").

Motions, operators and text objects are data in the core, separate from
any keymap. The grammar belongs to a scheme; the vocabulary belongs to
everyone. The delete operator and the word motion are the same two values
whether a scheme composes them as `dw`, as select-then-delete, or as one
`kill-word` command.

A motion, as built:

```lean
structure Vocabulary.From where
  head   : Nat                          -- where the cursor is
  count  : Option Nat := none           -- none is not a count of 1
  wanted : Option WantedColumn := none  -- the kept column, when it still holds

structure Vocabulary.To where
  head    : Nat                          -- the raw target
  wanted  : Option WantedColumn := none  -- the column to keep with the new head
  unmoved : Option WantedColumn := wanted -- the one to keep if the cursor rests where it was
  failed  : Bool := false                -- the motion could not be made

inductive Vocabulary.Reach | exclusive | inclusive | lines

structure Vocabulary.Taken where         -- where a motion leads an operator
  head   : Nat
  reach  : Vocabulary.Reach
  failed : Bool := false

structure Vocabulary.Motion where
  name   : String
  target : TextId → Vocabulary.From → EditorM Vocabulary.To
  reach  : Vocabulary.Reach := .exclusive
  taken  : Bool → TextId → Vocabulary.From → EditorM Vocabulary.Taken  -- `target` with `reach`, by default
```

- **It is not the record this section first sketched** (a `Motion` with a
  line-wise flag and `target : Nat → Cursor → EditorM Cursor`). The name
  `Motion` is the text port's, for its motion primitives; there is no
  position type called `Cursor`, which is the scene's cursor shape and
  face; and a count of none must differ from 1, for `gg` and `G`.
- **A motion answers a raw target**: the position it leads to, not clamped
  to where a cursor may rest. Resting is a rule of the state, applied by
  the command ("Where a cursor rests"), and an operator needs the raw
  target: `dw` on the last word wants the text's end.
- **A motion asks the text, and the display where a column is the
  display's, and changes nothing.** Its target is a command (`EditorM`),
  since the command loop's phase 16: `j` and `k` ask the display for their
  column ("The wanted column"). Until then the type was `TextM`, and a
  motion could not edit the editor state or publish; that is now the
  entry's rule and not the type's. The fourteen entries that ask only the
  text are written over the text port and lift unchanged. Pinned by a
  motion written in a check that asks the display and is run by the move
  command (`evilMotionChecks`).
  - **Set aside: the motion stays `TextM` and the move command asks the
    display.** The motion would answer a line and a flag, and `To`,
    `Taken`, the move command and the operator command would each carry a
    protocol that only `j` and `k` use.
- **The wanted column goes in and comes out as data**: a motion is not
  handed the window. The command hands it the kept column when that still
  holds, and keeps what it hands back ("The wanted column").
- **`unmoved` is a field of its own** because a motion cannot tell that
  it did not move: `l` at a line's last character answers the line break,
  which normal state's resting rule brings back. Only the command knows
  where the cursor came to rest.
- **The table is compiled** (`Evil.motions`, twenty-seven entries under the
  names the default tables bind; "Motions as built"). The move command is
  a function of the table it looks names up in (`Evil.move motions`), so
  the caller supplies the vocabulary. A name with no entry says
  `<name>: no such motion` in the echo area and moves nothing. A call
  that names no motion, which is the command run by its name or called
  with a first argument that is not a string, says
  `move: no motion named (expects a motion's name, then an optional count)`,
  so a malformed call is not taken for a misspelt name.
- **Config can name the table and its entries**: the root module imports
  `lean/Editor/Evil/Motions.lean`, which names no registry. So a command
  of config's runs the move command over the vocabulary that ships, or
  over that vocabulary with motions of its own added
  (`Evil.move (Evil.motions.push mine)`), without registering anything
  (`ConfigTest.evilChecks`).
- **Not built: registering a motion from `setup`.** Nothing needs it yet.
  When it is built, the registry holds motions by owner and hands the move
  command the table as it is when the command is looked up, which is how a
  command over a store is made today.
- **A motion says how an operator takes it.** `reach` is one of three:
  up to its target (`exclusive`), through the cell at its target
  (`inclusive`), or the whole lines of both ends (`lines`). `taken` is
  where the motion leads when an operator waits for it, told whether the
  operator puts an insert in place of what it takes: it is `target` with
  `reach` unless the motion says another, which three do (the two word
  motions forward, and `^`). `failed` says the motion could not be made,
  as Vim fails one with nowhere to go; the move command does not read it,
  and an operator that waits for it is given up ("Operators as built").
  Two values could not say Vim's three kinds, and `w` under an operator is
  another walk than `w` alone, which is why this is not the line-wise flag
  first sketched.

An operator, as built:

```lean
inductive Vocabulary.Stretch             -- what an operator acts on
  | cells (extent : Extent) (reach : Vocabulary.Reach)
  | lines (first last : Nat)

structure Vocabulary.Operand where
  stretch  : Vocabulary.Stretch
  head     : Nat          -- the head it was called at
  rest     : Nat          -- where a yank leaves the cursor, before it is rested
  register : String       -- the register the call named
  before   : Selection    -- the selection from before the command

structure Vocabulary.Operator where
  name            : String
  replaces        : Bool := false   -- it puts an insert in place of what it takes
  linesOverBlanks : Bool := false   -- Vi's rule for a deletion over lines holds for it
  act             : Call → Vocabulary.Operand → EditorM Unit
```

- **One command composes an operator with what it acts on**:
  `Evil.operate operators motions`, a function of the two tables it looks
  names up in, as the move command is of one. The Vim scheme's grammar
  already compiles an operator over a motion, over lines and over a visual
  selection to an invocation of `operate` ("Edits"), so the scheme's side
  needed nothing. The command works the stretch out, by Vim's rules, and
  hands it to the operator ("Operators as built").
- **The two flags keep the command from matching on an operator's name.**
  `replaces` is how `cw` differs from `dw`: the motion is told it.
  `linesOverBlanks` is Vi's rule for `d`.
- **The table is compiled** (`Evil.operators`: `delete`, `change`, `yank`).
  Config can name it and call `Evil.operate` with tables of its own, as it
  calls `Evil.move` (`ConfigTest.evilChecks`). Registering an operator
  from `setup` is not built, for the reason a motion's is not.
- **An operator's `act` is a command's body**, so the vocabulary imports
  the editor's port and the call. It still names no scheme and no key.
- **Set aside: one command for each operator.** The grammar yields one
  name, and the three share everything but what they do with a stretch.

### What stays in the core

- Keyboard macros, because they replay keys and work under any scheme.
- The command registry and `run`. Built: commands are registered by name
  and by owner (`Config.Registry`), by compiled code for the owner
  `compiled` when the host starts and by config's `setup` for the owner
  `config`. The latest entry of a name is the one an invocation runs
  (`Config.State.command?`), and a reload appends config's after the
  compiled ones, so config's command of a compiled command's name runs in
  its place until a reload drops it, and the compiled one runs again.
- Key bindings, by owner in the same registry (`Registry.bindings`): a key
  sequence and a command name. A reload replaces config's and never the
  compiled ones, so compiled bindings run when config fails to load.
- Vocabulary. Motions and operators each have a type and a compiled table
  (`Evil.motions`, `Evil.operators`, "Vocabulary" above). A registry of
  them by owner (entries replaced as a set, the latest wins), and text
  objects, are not built.
- The role set and the leader convention described under Modes, with each
  scheme's role table and leader as fields of the scheme.

## The Vim scheme

Status: the grammar is built (`lean/Editor/InputScheme/Vim.lean`, namespace
`Editor.Vim`), with the default states and bindings
(`lean/Editor/InputScheme/Vim/Default.lean`). It is the grammar only: keys
in, an invocation out, in pure Lean on the scheme interface, checked with
no editor API. What its invocations run is evil (`lean/Editor/Evil.lean`,
namespace `Editor.Evil`): Vim's states, motions and commands written on
the editor API, which name no key. Of evil, the motions, the four states
and the keys that enter and leave them, and typed text are built (the
sections from "The wanted column" to "Motions as built" below); what an
operator does to a text is not.

Keys are bound to parts of speech, not to opaque commands. The scheme's
`State` holds the count so far, the operator waiting for a motion, and the
prefix walked so far. One key is `Vim.parse`: the state it leaves, and what
the key parsed to, which is nothing, an `Edit`, or typed text. `Vim.step`
compiles that to an `Invocation`, and `Vim.scheme states` packages it as an
`InputScheme` over a registry of Vim states.

- **Operator-pending needs no separate keymap.** `w` is bound once, as a
  motion. Alone it moves; after `d` it supplies the range. A motion added
  later, by a mode or by config, works with every operator.
- **Dot-repeat is replaying data.** The last `Edit` that changes text is a
  value in the scheme's `State`.
- **Vim states** (normal, insert, visual) are records in a registry, like
  modes, so a state defined in config is not a special case.
- **A state's selection is a shape and ends.** The text store keeps a
  selection as ranges of two offsets with one shape, and says what a shape
  covers: insert state is an exclusive range with equal ends, normal state
  an inclusive one, and the three visual states inclusive, line and block.
  The table, and the cases at a line's last character, an empty line and
  the end of the buffer, are in
  [text-and-display.md](text-and-display.md) ("What a selection covers, and
  how evil maps onto it"). The scheme's own rules are not there: keeping
  the normal-state cursor off the line break ("Where a cursor rests"),
  `curswant` ("The wanted column") and the motions ("Motions as built"),
  which are below, and what an operator does with an extent, which is not
  built.

Keymaps are not indexed by Vim state in their types. That would need a
closed set of states, which conflicts with states being open.

### What a key is bound to

```lean
structure Operator where
  name    : String                  -- its vocabulary name
  changes : Bool := true            -- an edit with it changes text
  enters  : Option String := none   -- the Vim state the view is in after it

structure Command where
  name     : String                  -- the command's name, as the registry names it
  changes  : Bool := false
  enters   : Option String := none
  typed    : Option String := none   -- what it adds to the last change's typed text
  restarts : Option String := none   -- the command the last change restarts as after it

inductive Bound where
  | motion     (name : String)
  | charMotion (name : String)      -- a motion that takes the character the next key names
  | promptMotion (name label : String) -- a motion that takes a text typed in the minibuffer
  | operator   (operator : Operator)
  | textObject (name : String)
  | command    (command : Command)
  | register
  | repeat                          -- the repeat key: it yields the last change, to replay
  | mode       (bound : Bound)      -- a binding a mode contributes
```

- **Every part of speech is named by its vocabulary name**, a `String`, so
  the grammar needs no vocabulary entry to exist. An earlier sketch bound a
  key to a `Motion` value; a name replaces it, and the vocabulary is looked
  up when the invocation runs.
- **An operator and a command carry the two facts the grammar needs and
  cannot look up**: whether an edit with it changes text, and which Vim
  state the view is in afterwards. They are data on the binding, not a
  table of names in the scheme. So a state is entered by a command bound in
  a keymap, and `c` enters insert state the same way.
- **A motion needs only its name.** How an operator takes it is the
  vocabulary's, read when the edit runs.
- **`promptMotion`** is a motion that takes a text typed in the
  minibuffer: `/` and `?` ("Motions that ask", under the last change).
- **`charMotion`** is a motion that takes the character the next key names
  as its argument: `f`, `t`, `F` and `T`. The key is kept as typed, so it is
  pending alone, and it folds the count being typed as an operator does.
  The next key is read before counts and keymaps, as the key after the
  register prefix is: a key that prints names the character, a digit
  included, and `TAB` names a tab. It completes the move, or the operator
  waiting over the motion, with that argument. Any other key resets the
  edit begun, as `f<Escape>` does in Vim.
- **`register`** is the key that begins a register's name (`"`). See
  Registers.
- **`repeat`** is the repeat key (`.`). It is a part of speech and not a
  command's key, because the scheme cannot match on a command's name and a
  command cannot read the scheme: the key yields the last change, with the
  text typed in its insert session, for the command to replay ("The last
  change").

### Edits

```lean
inductive Over where
  | motion (name : String) (argument : Option String := none)
  | textObject (name : String) | lines | selection

inductive Edit where
  | move    (motion : String) (count : Option Nat) (argument : Option String := none)
  | operate (operator : Operator) (over : Over) (count : Option Nat) (register : Option String)
  | run     (command : Command) (count : Option Nat) (register : Option String)
  | replay  (change : Edit) (inserted : Option String)   -- the last change, and its typed text, editing keys' marks in it
```

The rules of the grammar:

- A motion alone is a `move`. After an operator it is the operator's
  target.
- A text object after an operator is its target. With no operator waiting,
  in a state where operators act on the selection, it is `Edit.select`,
  which sets the selection to the object and enters the state the record
  names for an object (`StateRecord.objectEnters`); elsewhere it is
  dropped, and the input is reset.
- The operator that is waiting, typed again, acts on lines (`Over.lines`):
  `dd`.
- A different operator, a command or the register prefix while an operator
  waits resets the input.
- An unbound key resets the input: no count, no operator, no register and
  no prefix are left. A reset keeps which Vim state each view is in and the
  last change.

An edit compiles to an invocation (`Edit.compile`), and the layout is the
scheme's one rule for it:

| Edit | Invocation |
|---|---|
| `move m c a` | `move`, with `[.str m, .nat c]`, or `[.str m, .str a, .nat c]` when the motion has an argument |
| `operate o over c r` | `operate`, with `[.str o.name, .str kind, .str name, .nat c, .str r]`. Kind and name are `motion` and the motion, `text-object` and the object, `lines` and `""`, `selection` and `""`. A motion's argument, when it has one, is a string right after its name: `[.str o.name, .str "motion", .str m, .str a, .nat c, .str r]` |
| `run cmd c r` | `cmd.name`, with `[.nat c, .str r]` |
| `replay change inserted` | `repeat`, with `[.bool session, .str text, .str command]` and then the change's own arguments: whether the change began an insert session, the text typed in it, and the command the change compiles to |

**A motion's argument, when it has one, is the string right after the
motion's name.** So the register stays the last argument of the `operate`
layout, which is the one thing dot repeat reads of a layout ("The last
change"), and a move and an operation over a motion carry the argument in
the same place. The move and operate commands read both layouts: a string
after the name is the argument, and a number the count.

The three command names are constants of the scheme (`Vim.moveCommand`,
`Vim.operateCommand`, `Vim.repeatCommand`), and so is the name typed text
runs (`Vim.selfInsertCommand`). The commands are registered with evil, not
here (`lean/Editor/Evil/Compiled.lean`), and all four are built.

- **`pending` is every key of the edit begun**, as chords: counts, the
  register prefix and the operator included, so `d 2` after `d2`. The
  scheme contract requires a strict prefix to be reported key for key, and
  it is what Vim shows.
- **Typed text is a self-insert, and not an edit.** `Vim.selfInsert text`
  is the invocation `self-insert` with `[.str text]`. It is yielded for a
  key that is unbound and prints, typed with no edit begun, for a view
  whose Vim state inserts text; it leaves the scheme's state as it was. In
  any other state such a key yields nothing. An unbound key after a prefix
  is dropped with the prefix, in an inserting state too. The one thing of
  the state it changes is the text kept for the last change, when it is
  typed in the session that change began ("The last change").
- **The command it runs is built** (`Evil.selfInsert`, registered under
  `self-insert`): it inserts its first argument, a string, at the head of
  each range of its target's selection, as one transaction that carries
  the selection before and after. What is typed in one insert session is
  one step of the history, which is the loop's rule and not the command's
  ("Insert sessions").

### Counts

- **In the scheme's state**: two fields. `digits` is the count being typed;
  `multiplier` is the product of the counts already completed. A key that
  is not a digit and goes on with the edit (an operator, the register
  prefix) folds `digits` into `multiplier`. The count of the edit is their
  product, with an absent one left out, and none when no digit was typed.
  So `2d3w` is 6, and a count in any position multiplies, with no slot for
  each position.
- **In an edit**: `count : Option Nat`. None is not 1: `G` and `gg` read a
  count as a line number, so `G` and `1G` differ.
- **In the invocation**: `.nat n`, with `.nat 0` for no count. A typed
  count is never 0, since a count cannot begin with `0`. `Argument` has no
  optional kind; whoever runs invocations may widen it.
- **The doubled operator** counts lines, so its edit always has a count:
  `dd` is 1, `3dd` is 3, `2d3d` is 6.
- **What a digit is**: a key whose chord is one digit character with no
  modifier, read as a count when no keymap prefix is being walked and the
  view's Vim state does not insert text. `0` is a digit only while a count
  is being typed; otherwise it is looked up like any key, so `0` can be
  bound to a motion. Digits are not bound in a keymap: the rule for `0`
  needs the count typed so far, which a keymap does not see.

### Registers

- **In the scheme's state**: `register`, the register named for the edit
  being typed, and `awaitsRegister`, set by the key bound to the register
  prefix until the next key names the register.
- **In an edit**: `register : Option String` on `operate` and `run`. A move
  carries none: a register typed before a motion is dropped when the motion
  completes.
- **In the invocation**: `.str name`, with `.str ""` when none was named,
  which is the unnamed register.
- **In a keymap**: `Bound.register`, a fifth thing a key can be bound to
  beside the four parts of speech. The key after it names the register by
  the text it prints; a key that prints nothing resets the input. The
  prefix is refused, and resets, after an operator and when a register is
  already named.
- Which registers exist and what they hold is not the scheme's: it is
  editor state, and built (`lean/Editor/State.lean`,
  `lean/Editor/Evil/Registers.lean`):
  - **A register is a text and whether it is line-wise** (`Register`),
    kept by name in the editor state (`EditorState.registers`), set by one
    state request (`setRegister`). So a command that sets one and then
    does not run to its end is rolled back to the register it had. The
    table is by name so that a named register is one more name and no new
    request.
  - **The names evil knows**: the empty name, which is a call that named
    none, and `"`, which are the unnamed register; `+`, the system
    clipboard; and the name a command names the clipboard by when it
    writes it itself (below). Any other name gives the command up
    (`Evil.noRegister`), before anything is taken: named registers are
    not built.
  - **Every yank and every deletion sets the unnamed register**, whatever
    register was named, as Vim's does.
  - **The clipboard is a port** (`lean/Editor/Clipboard.lean`): two
    requests, read and write, each refused as a value (`unavailable`), a
    pure model, and a contract every implementation runs. It is a sub-port
    of the editor's port ([lean-runtime.md](lean-runtime.md), "The editor's
    port is a composite"). The adapter to a window system's clipboard is
    the display pipeline's. A host with no window keeps a clipboard of its
    own, a cell of the process that answers with the model's rule
    (`lean/Editor/Clipboard/InProcess.lean`), as it has a display
    recorder.
  - **A write of the clipboard is not rolled back, so evil writes last.**
    The clipboard is outside the editor. A command that names it edits,
    places its cursor, and then stores, and the write is its last
    request: the guard stops a command before a request and never after
    its last, so a command that wrote the clipboard ran to its end
    ([concurrency.md](concurrency.md), "Foreground: commands"). A write
    that is refused is said in the echo area, and the text is in the
    unnamed register. A yank that took no cell writes nothing.
  - **A command that goes on after a store has the write kept for it.**
    Dot repeat's replay of a change that began an insert session
    (`"+cw`, text, escape, then `.`) inserts the typed text and leaves
    the insert after the change, so the change's store is not the
    replay's last request: an interrupt or a refusal after it would roll
    the text back with the clipboard already written. The replay runs
    such a change under another name for the clipboard
    (`Evil.clipboardLater`, which no key types): a store under it sets
    the unnamed register, keeps the same register under that name in the
    editor state, and asks the clipboard nothing. Once the insert is
    left, the replay writes what was kept (`Evil.writeKept`), as its
    last request. What is kept is editor state, so it is rolled back
    with the command; it is kept apart from the unnamed register so that
    a change that stored nothing writes nothing, and one that stored the
    text the unnamed register already held writes it. Pinned by
    `evilRepeatChecks`, with an interrupt placed before each request of
    a replay in turn.
  - **A text read from the clipboard is line-wise when it ends in a line
    feed**: the clipboard holds a text and no flag.
  - **`p` and `P`** put the register the call names ("Operators as
    built").
- Consequence for the scheme contract: after the register prefix every
  printable key goes on with the input, so the key the Vim scheme gives the
  contract as unbound is a named key.

### The visual selection

- **Not in the scheme's state.** The selection is the view's selection
  marker in the text store, with the shape of the view's Vim state (the
  bullet above). The scheme's state holds only which Vim state each view
  is in.
- **In an edit**: the target `Over.selection`. A state's record says
  whether operators act on the selection (`operatesOnSelection`). In such a
  state an operator key completes an edit at once, `operate o .selection
  count register`, and waits for no motion.
- An edit over the selection ends it: the view enters the state the
  operator names (`c` names insert), or the registry's initial state when
  it names none.
- A motion in a visual state is the same `move` edit as in normal state.
  That it extends the selection is the command's, when the edit runs: the
  move command keeps the range's anchor where the scheme reports the view
  as selecting, and moves the head alone.
- A text object in a visual state is the edit `select o count`
  (`Edit.select`), which compiles to `select-object` and is never the last
  change. The command sets the selection to the object, charwise, and the
  view enters the state the record names for an object
  (`StateRecord.objectEnters`): `visual-line` names `visual`, so `V i w`
  is in `v` ("Text objects as built").

**How entering and leaving a visual state changes the selection.**
Decided 2026-11-14 and built, by the command loop's phase 11
(`Evil.enter`, `lean/Editor/Evil.lean`; pinned by
`ModelTest.evilStateChecks`). It is the entering rule of "Vim states",
read for the three keys:

- **`v` in normal state changes nothing but the view's state.** The
  selection is already one inclusive range with equal ends, on the cell
  under the cursor. The next motion moves its head and keeps its anchor,
  because the state is one whose operators act on the selection.
- **`V` gives the same two ends the line shape.** The ends are not moved
  to the lines' starts and ends: what a line-shaped range covers is the
  text store's answer, so the columns survive leaving the state, and
  `V` then `v` selects from the first column the cursor was in.
- **`v` in `visual-line` and `V` in `visual` change the shape and keep
  both ends.**
- **`<Escape>`, and the state's own key typed again, collapse the
  selection onto its head**, as one inclusive range with equal ends, which
  is then put where normal state lets a cursor rest ("Where a cursor
  rests").
- **The scene shows it with no further rule**: a view's selection in the
  scene is its window's selection marker, which carries its ranges and its
  shape, and what the ranges cover is the text store's answer. After `v`
  and a motion it is one inclusive range from the starting cell to the
  target cell; after `V` and a motion one line-shaped range that covers
  every line from the starting line to the target line.

### Vim states

```lean
structure StateRecord where
  name                : String
  keymaps             : List (Keymap Bound) := []
  cursor              : CursorShape := .block
  insertsText         : Bool := false   -- an unbound printable key is text, and a digit is not a count
  operatesOnSelection : Bool := false   -- an operator acts on the selection at once
  shape               : Shape := .inclusive  -- the shape of the view's selection

structure States where
  initial    : StateRecord
  others     : List StateRecord := []
  minibuffer : Option String := none      -- the state the minibuffer's view is put in
```

- **The registry always has an initial record**, so looking a state up is
  total (`States.get`), and registering a record replaces one of the same
  name, the initial one included (`States.register`).
- **What the grammar must know of a state is data on its record**, never a
  match on its name, so a state that a test or config registers is not a
  special case. A digit is text exactly where typing is text, so one field
  says both.
- **The scheme is a function of the registry**: `Vim.scheme states` is an
  `InputScheme`. The registry is a value; a reload that changes it builds
  the scheme again, and the scheme's state type does not change.
  Registering a state from `setup` is not built.

**A state's record says the shape of its selection, and entering a state
reshapes the selection by that record.** Decided 2026-11-14 and built, by
the command loop's phase 11 (`StateRecord.shape` and `State.report`,
`lean/Editor/InputScheme/Vim.lean`; `Evil.enter`, `lean/Editor/Evil.lean`;
pinned by `vimRegistryChecks`, `vimStateChecks` and `vimDefaultChecks` for
the record and the report, and by `evilStateChecks` and `evilInsertChecks`
for the rule).

- **The record has `shape : Shape := .inclusive`.** The defaults:
  `normal` and `visual` inclusive, `visual-line` line, `insert` and
  `minibuffer` exclusive, which is the table
  [text-and-display.md](text-and-display.md) has ("What a selection covers,
  and how evil maps onto it").
- **The entering rule is one for every state**, run by the command the
  entering key names:
  1. The selection takes the record's shape.
  2. Its two ends are kept when the state is one whose operators act on
     the selection (`operatesOnSelection`: the visual states). Otherwise it
     is collapsed onto its head.
  3. When the selection was exclusive and the new shape is not (an insert
     session ends), the head first steps back one cell, and stays where it
     is at the start of its line. This is Vim's escape.
  4. The head is then put where the state lets it rest ("Where a cursor
     rests").
  The anchor, where it is kept, is put where the state lets a cursor rest
  too. Once the selection is collapsed the window keeps no wanted column,
  as Vim's escape resets it ("The wanted column").
- **No command matches a state's name.** The commands that enter `normal`,
  `visual` and `visual-line` are one function (`Evil.enter`), which reads
  the record's facts from the scheme's report of the view ("What a scheme
  reports of a view"). A state that config registers with the block shape
  would be entered by the same function. The four commands that begin an
  insert are that function with the head moved first (`Evil.enterAt`,
  "Insert state").
- **No second field for "a motion extends the selection".** A state whose
  operators act on the selection is a state in which the selection is the
  user's to grow. One field says both, as `insertsText` says both "typing
  is text" and "a digit is not a count".
- **The scheme reports the record**, because nothing outside the scheme
  can read one: the record's cursor shape in the face `cursor.` followed
  by the state's name (`cursor.normal`, `cursor.insert`, `cursor.visual`,
  `cursor.visual-line`, `cursor.minibuffer`), one status field with the
  state's name in capitals in the face `mode-line.state.` followed by the
  state's name (`NORMAL` in `mode-line.state.normal`, `Vim.stateFace`),
  the record's shape, `selecting` from `operatesOnSelection`, and
  `session` and `takesText` both from `insertsText`. The mode line's
  `state` segment draws that field as its badge
  ([text-and-display.md](text-and-display.md), "The scene", as built;
  `lean/Editor/ModeLine.lean`), on the selected window only. So the
  scene's cursor shape and the badge change when the state changes, and
  a view's status line under the Vim scheme on the scratch buffer reads
  `mode-line.state.normal "NORMAL" +8, mode-line.buffer "scratch" +4 |
  mode-line.secondary "1:1" +4, mode-line.secondary "All" +4`.
- **If a state ever needs `selecting`, `session` and `takesText` apart**
  from the two fields they are read off, each becomes a field of the
  record, and the report does not change.

**Where the current Vim state is held**: in the scheme's state, one entry a
view. `current : List (ViewId × String)` is the name of the Vim state of
each view that is not in the registry's initial state. A view with no entry
is in the initial state, and entering the initial state removes the entry,
so the state after a reset in a fresh view equals the scheme's initial
state.

- **In the scheme's state and not in the editor state's window**: `step` is
  pure, and it is the only thing that sees the key that enters a state.
  Held in the editor state, the next key could not be looked up in the new
  state's keymaps without the editor API, and the grammar is tested without
  it.
- **By view and not one for the scheme**: the selection is the window's,
  and its shape must agree with the Vim state, so two windows cannot share
  one. `step` is already given the view.
- **The pending edit and the last change are one for the scheme**, not one
  a view: there is one keyboard. A key for another view goes on with the
  pending edit, and is looked up in the keymaps of its own view and that
  view's state.
- **A name the registry does not have is the initial state**, when it is
  read and when a command enters it, so a registry that loses a state
  strands no view.
- **The minibuffer's view enters the state the registry names for it**
  (`States.minibuffer`), when the scheme is told the view is the
  minibuffer's, and its entry is dropped when the view is closed ("The
  minibuffer", under Modes). With none named the view stays in the initial
  state, where a key that prints is no text, which the scheme contract
  reports.
- **A record has no equality.** It holds keymaps, and a keymap derives
  none, so neither `StateRecord` nor `States` does. The scheme's `State`
  holds names and edits only and has a decidable equality. A check compares
  two records by their fields.
- The scene's cursor shape and status field read the view's state through
  the scheme's report of the view (`Vim.State.report`), which the loop
  asks for when it makes a scene.

### Which keymaps a key is looked up in

For a key for a view whose Vim state has the record `record`, the walk runs
over `maps view ++ record.keymaps`: the active keymaps passed to `step`
first, in their own order, then the state's. **While an operator waits it
runs over `maps view ++ record.pending`** when the record has pending
keymaps (`StateRecord.pending`, Vim's Operator-pending mode), and over the
state's own otherwise. Normal state's pending keymaps are its own without
`normalCommands` and with `objects` first, so `i` and `a`, which begin an
insert alone, begin a text object after an operator; every other command
key resets there as an unbound key does, which is what it did as a
command.

- **The active keymaps are the specific ones** (the view's modes, the
  user's config) and the state's are the scheme's defaults. A specific
  binding must be able to replace a default, as a mode's role key such as
  `j` in a list buffer has to.
- **It is one walk** (`Keymap.walk`), so prefixes merge across both lists,
  and a part of speech bound in an active keymap is the same to the grammar
  as one bound in a state's keymap. That is what makes a motion bound after
  the scheme was built work after every operator with no further binding.
- **Consequence**: an active keymap's binding holds in every Vim state,
  insert included, except a mode's (below). A binding meant for one state
  belongs in that state's keymaps.
- **A mode's keys hold only where typing is not text** (built). Without
  that, a buffer whose mode fills a role on `j`, or has a suffix under `\`,
  could not have `j` or `\` typed in insert state. Every key a mode binds
  (a role, a suffix) is bound to what the scheme says a mode's key is bound
  to (`InputScheme.modeCommand`, which is `command` unless a scheme says
  otherwise). The Vim scheme's is `Bound.mode (.command { name })`: a
  constructor, "a binding a mode contributes", which the grammar reaches as
  what it wraps, so a mode's motion moves and is an operator's target.
  `Vim.parse`
  leaves the `.mode` bindings out of the active keymaps for a view whose
  state's record has `insertsText`, the field that already says "typing is
  text" (and "a digit is not a count"), through `Keymap.filter`, which keeps
  the bindings a predicate keeps. The scheme wraps its hand-tuned keys in
  `.mode`, so they follow the same rule. A binding from config's `bindKey`
  is not a mode's and still holds in every state.

### Motions that ask

Status: built, by the daily-driver floor's phase 3
(`lean/Editor/InputScheme/Vim.lean`, "Motions that ask"; pinned by
`vimGrammarChecks` and `evilSearchChecks`).

`/` and `?` are `Bound.promptMotion`: their argument is a pattern typed in
the minibuffer, and a prompt is answered later, so the edit cannot complete
at the key.

1. **At the key** the grammar records the edit that waits
   (`State.asking`: the view, the motion, the operator waiting, the count
   and the register typed), resets the edit begun so the minibuffer's keys
   parse afresh, and yields `minibuffer-ask` with the label (`/` or `?`).
   Nothing is the last change and no state is entered.
2. **`minibuffer-ask`** opens a prompt with that label whose continuation is
   the reserved name `InputScheme.answerName`.
3. **On accept** the loop hands the answer to the scheme
   (`InputScheme.answered`), which completes the waiting edit with the
   answer as the motion's argument, by the rule a key completes one by
   (`State.finish`, for the asking view). So `c/foo RET` enters insert
   state, `.` after `d/foo RET` replays `d/foo` with `foo` (Vim's redo
   buffer holds `d/foo\r`), and a count and a register typed before `/`
   are kept.
4. **Cancel.** `<Escape>` in the minibuffer closes it with no answer. The
   edit waiting is dropped at the next key for a view other than the
   minibuffer's, which the scheme is told when the prompt opens
   (`openMinibuffer`). It is not dropped when the minibuffer's view closes:
   the accept command closes it one step before the answer arrives. A
   reset keeps it. So `d/<Escape>` changes nothing and is no change, as in
   Vim.

In the minibuffer `/` is typed text, as any key that prints is there.

### The last change

`lastChange : Option Edit` in the scheme's state is the last edit that
changed text, as a value: what dot repeat replays.

- An edit replaces it when it changes text: an `operate` whose operator
  has `changes`, a `run` whose command has it, and never a move. So `d2w`
  is the last change, and `w` and `yw` after it leave it as it was.
- A reset keeps it, and so does entering a state. Typed text is not an
  edit and does not replace it.
- It is one for the scheme, not one a view.

**The text typed in the insert session the last change began is kept with
it** (`State.inserted`, and `State.recording`, the view it is being kept
for). Typed text is no edit, so the change alone would not hold it.

- An edit that changes text and enters a state where typing is text sets
  `inserted` to the empty text and `recording` to the key's view. Any
  other edit that changes text sets both to none.
- Text typed in the recording view is added. Text typed in another view,
  the minibuffer's included, is not.
- **A command that changes no text adds what its binding says**
  (`Command.typed`), run in the recording view: insert state's
  `<Backspace>`, `RET` and `TAB` add the backspace character, a line feed
  and a tab, so the replay runs them again ("Insert state").
- **A command can restart the last change** (`Command.restarts`, insert
  state's arrow keys): run in the recording view, it leaves a restart
  waiting (`State.restart`), the command it names as a change that enters
  the view's Vim state, with no count. The next text added in the recording
  view makes that the last change, with that text alone kept for it. Ending
  the recording drops the restart, so with nothing typed after the key the
  last change is as it was. This is Vim's `stop_arrow`, which starts the
  redo again as `i` at the first key after an arrow key.
- **A committed text is typed text here too.** No key printed it, so the
  scheme's `step` never sees it: the scheme interface has a notice,
  `committed`, which the loop makes of both states of the scheme it keeps
  when it inserts a commit, and the Vim scheme adds the text for the
  recording view. Without it `.` after `cw` and a text an input method
  composed would replay the change with that text missing.
- An edit that enters a state for the recording view, and that view being
  closed, end the recording; what was kept stays. A reset keeps both.
- A command that does not run to its end is not the last change and its
  typed text is not kept, with no rule added: the loop puts the scheme
  back in its state at rest.

**The repeat key yields the last change to replay** (`Bound.repeat`,
`Edit.replay`).

- With no last change, and while an operator waits, the key resets and
  yields nothing.
- Otherwise it yields `Edit.replay change inserted`, which compiles to the
  invocation `repeat` ("Edits"). The scheme hands the change to the
  command in the invocation, since a command cannot read the scheme.
- **A count typed before `.` replaces the change's count**, in what is
  yielded and in the last change, so the repeats after it carry it; with
  none typed the change's own count is used. This is Vim's rule: `dw3.`
  deletes three words and a further `.` three more, and `d2w3.` deletes
  three, not six.
- A replay changes no text and enters no state for the grammar: it does
  not become the last change, and the view stays in the state it is in.
- **Set aside: keeping the last change in the editor state**, set by each
  changing command. `step` is where a typed key is seen, and every command
  anyone writes would have to record itself.
- **Set aside: the repeat key yielding the change's own invocation.** A
  change with an insert session is three things (the change, the text,
  the escape) and a key yields one invocation.

**The repeat command replays the change as one command**
(`Evil.repeat`, `lean/Editor/Evil/Repeat.lean`).

- **The change's command is the one the registry holds for its name**,
  as the change's own keys ran it. The repeat command has the loop run
  the command of that name inside itself (`runCommand`,
  [concurrency.md](concurrency.md), "Prompts"), and the loop looks the
  name up as it looks up a key's invocation. The repeat command holds no
  table of commands.
  - So config's command of a name evil registers is what `.` replays: a
    config that registers `operate` again over a vocabulary with an
    operator of its own, or its own `delete-char`, gets that command from
    `.` as from the keys. A command of config's that a scheme's table
    binds as changing text is replayed too.
  - Which commands are changes is the scheme's data (`changes` of a
    `Vim.Command` and of a `Vim.Operator`), and nothing in evil restates
    it.
  - **Set aside: a table of changes in evil**, each name with the function
    registered under it. It was a second place where a name was given a
    command, and it did not know of config's command of the same name: `.`
    ran the shipped function where the key had run config's.
  - **Set aside: a request answered the command.** A command is a program
    over the editor's port, and a reply of that port cannot hold one.
- **A change with no insert session** is run with the repeat's call, with
  the change's arguments in place of the call's.
- **A change with an insert session** is three things in one command: the
  change, told of an exclusive selection that no motion extends, which is
  all a command that begins an insert reads of insert state's report; the
  typed text, replayed at the bar as it was typed (a backspace character
  deletes the cell before the bar, a line feed breaks the line with the
  buffer's line ending, and the rest is inserted); and `Evil.enter`
  with the call's own report, which is normal state's and steps the head
  back as `<Escape>` does.
- **It is one command in normal state**, so it is one step of the history
  and is rolled back whole.
- **A change that breaks off breaks the replay off.** A replayed operator
  whose motion fails after it moved leaves the cursor where the motion got
  to and ends the command there, with no typed text inserted, as Vim's `.`
  does ("Operators as built").
- **What is not repeated gives the command up**, with nothing changed: no
  change, which is the command run by its name; a name no command is
  registered under; the repeat command's own name; a change whose command
  asks for a store to be written, which a command run inside another
  cannot; and a change over a visual selection, which Vim repeats over
  the same amount of text from the cursor.
- A count before `.` on a change that begins an insert with a key
  (`i a I A o O`) replaces a count those commands ignore.
- **A yank is not repeated**: its operator changes no text, so it never is
  the last change.

### The wanted column

Status: decided 2026-11-14 and built, by the command loop's phase 11
(`Window.wanted` and `EditorState.setWanted`, `lean/Editor/State.lean`;
`ViewId.setWanted`, `lean/Editor/Api.lean`; read and kept by `Evil.move`,
`lean/Editor/Evil.lean`; pinned by `stateChecks`, `stateRequestChecks` and
`apiStateChecks` for the state, and by `evilMotionChecks` for the keys).
Its unit, a display column asked of the display, was decided 2026-11-14
and built by the command loop's phase 16 (`WantedColumn.goal`,
`lean/Editor/State.lean`; `Evil.down`, `Evil.up`, `Evil.unwrapped`,
`lean/Editor/Evil/Motions.lean`; pinned by `displayColumnRows` in
`evilMotionChecks`, by three properties of the display contract, and on
the executable by `tests/headless/column`).

The wanted column is the column a view's `j` and `k` aim for, which
survives crossing a shorter line (Vim's `curswant`).

**It is kept on the view's window, in the editor state, with the position
it was kept at.**

- **The field**: `Window.wanted : Option Window.Wanted`, none by default,
  with `Window.Wanted { column : WantedColumn, head : Nat }`. A
  `WantedColumn` is `goal x`, a display column as the display gave it
  ("Where the display column comes from", below), or `lineEnd`, which is
  what `$` leaves so that `j` and `k` then stay at line ends.
- **`head` is the offset the cursor was left at when the column was
  kept.** A vertical motion uses the kept column only when the cursor is
  still at that offset. Anything else that moves the cursor (a horizontal
  motion, an edit, an undo, a command of config's) makes the kept column
  stale with nobody clearing it. That is the reason for the field: a rule
  that every cursor-moving operation clears the column would bind every
  command anyone writes.
- **One state request sets it**, refused for a view with no window, and
  the editor API has the operation over it. Showing another buffer in the
  window clears it, because offsets of one text mean nothing in another,
  and a window a split makes has none.
- **A command reads it from the editor state, when it needs it**, and not
  from the window its call hands it, which is the window as it was when
  the command was called. The move command sets the column, so a command
  of config's that calls it twice with one call would otherwise hand the
  second move the column from before the first. Read from the state, two
  moves in one command are two keys: down and then down across a shorter
  line lands in the column it started in (pinned by `evilMotionChecks`,
  with a command written in the check).
- **It is rolled back with the command**, because it is editor state.
- **Who keeps what** ("Motions as built" has the motions' side):
  - `j` and `k` aim for the kept column, or for the cursor's own column
    when none holds, and keep it. So `j` then `k` across a shorter line
    returns to the column it started in.
  - `$` keeps the line's end, also when it does not move.
  - `h` and `l` keep none when the cursor moves, and what was kept when it
    does not. Vim leaves `curswant` alone when `h` or `l` fails: after `j`
    onto a shorter line, a failed `h` and another `j` return to the first
    column.
  - Every other motion keeps none, also when the cursor does not move
    (`0` at column 0 resets it, as in Vim).
  - Entering a state that collapses the selection keeps none: `<Escape>`
    from insert state and from a visual state, and the keys that begin an
    insert, as Vim's do. Entering a visual state leaves it.
- **It is a display column, as Vim's is.** From `b` in `a⇥b`, `j` onto
  `0123456789` lands on `8`; from `b` in `世b`, on `2`; and where the
  column falls inside a tab or a wide character on the line it goes to,
  the cursor lands on that character. Phase 11 counted cells, which put
  the first on `2`, and pinned that as a departure; phase 16 removed it.
- **Set aside: in the scheme's state.** `step` is pure and never sees what
  a command did, so the scheme cannot know the column.
- **Set aside: in the selection marker.** The store's selection has no
  such field. Adding one is a change to the Rust library and to every
  marker.
- **Set aside: a buffer-local value.** Two windows on one buffer have two
  cursors.
- **What it costs.** An edit made through another window that shifts the
  cursor's offset makes the kept column stale, where Vim would keep it.
  The next `j` then aims for the cursor's own column.

**Where the display column comes from.** The line `j` and `k` go to is the
text port's, by buffer lines, as phase 11 built it. The column on that line
is the display's, asked with the move query the display interface already
has (`Display.linesFrom`), of the text laid out unwrapped. Tab stops and
character widths are layout's, and Lean keeps no copy of layout.

- **Two questions, both a move of no lines** (`Evil.inLine`):
  - the cursor's own x: the query with no goal, from the cursor, whose
    reply passes back the x it would aim for;
  - the position at an x of the line gone to: the query from that line's
    start, which the text port answers, with the x as its goal.
- **The unit of the kept column is that x** (`WantedColumn.goal`): what the
  display passed back, which is pixels from the start of the line laid out
  unwrapped. Lean stores it and hands it back, and does no arithmetic on
  it. The display interface gained no request.
- **Unwrapped, and not at the view's width.** The query's width is
  `Evil.unwrapped`, 2^64: wider than any machine word holds, which the
  display takes for wider than any view. Vim's `curswant` is a column of
  the buffer line whatever the window's width. At the view's width an x is
  counted from the visual row's start, which is wrong on a wrapped line,
  and in a frame of 0 by 0, the headless host's until a script resizes,
  every x is 0. Asked unwrapped, nothing of the view's rectangle is read,
  so `j` and `k` are the same in a view that is not laid out.
- **The line is the text port's, and not `lines := ±n` in one query.**
  Real layout cuts a row longer than 4096 bytes into segments that are
  visual lines at any width, so a move by display lines could stay in the
  row. With the line from the text port the line is always right; on such
  a row only the column degrades, since an x is counted in the segment.
- **What the display model answers**
  ([text-and-display.md](text-and-display.md), "The scene", as built): a
  tab reaches to the next multiple of 8 cells from its line's start, and a
  wide character is two cells, by the model's own list of East Asian
  blocks. An emoji is one cell there. Over real layout a character is as
  wide as its glyph.
- **What the display is held to** (`lean/Editor/Display/Contract.lean`),
  on the model, the recorder and the real binding: a move of no lines that
  is given a goal goes to that x of its row; a width no machine word holds
  wraps no line; and a tab reaches to the next multiple of eight cells.
- **What it costs.** Each `j` or `k` that asks takes a snapshot of the
  text round its questions and releases it, with the helper
  `Target.onArea` is built on (`TextId.withSnapshot`,
  `lean/Editor/Command.lean`):

  | | Display requests | Text requests more than phase 11 |
  |---|---|---|
  | The line's end kept (`$` before) | 0 | 0 |
  | A goal kept, which is every `j` or `k` after the first | 1 | 2: the snapshot and its release |
  | No column kept | 2 | 2 |
  | Cannot move, a goal kept | 0 | 0 |
  | Cannot move, none kept | 1 | 2 |

  A count asks no more: the text port goes to the line in one request, so
  `2j` aims for the same x as `jj`. An operator (`dj`, `yk`) hands the
  motion no kept column, so it asks twice. Over real layout the text is
  asked about at a second width, and layout keeps one width for a text:
  unmeasured ([text-and-display.md](text-and-display.md), open questions).
- **Visual states** go through the same motion: the head of `vj` aims for
  the display column. Block-wise columns are not built. `gj` and `gk`, by
  visual lines, are not built either.
- **Set aside: a new display query by buffer line.** It states the
  question most directly, and the real binding would have to answer it.
  The existing query answers it.
- **Set aside: the text port, with a tab stop passed in.** It needs a
  table of widths and a tab stop in the text store and in Lean, and gives
  layout two places that answer one question.
- **Departures from Vim that remain**:
  - **A cursor on a tab counts at the tab's first column.** Vim counts it
    at the tab's last: `j` from the tab of `a⇥b` onto `0123456789` lands
    on `7` in Vim and on `1` here. The x the display answers for a
    position is where its character starts, and the column of a
    character's last cell cannot be had without Lean subtracting from an
    x. Pinned by one check of `evilMotionChecks`, named as a departure.
  - **An emoji is one cell on the display model**, and two columns in
    Vim.
  - **Over real layout**, not seen on the model: a tab after a wide
    character stops at a multiple of 8 characters, not of 8 display
    columns, and on a row longer than 4096 bytes the column is counted in
    the segment.
  - Whether a cell is a grapheme cluster stays open
    ([text-and-display.md](text-and-display.md)).

### Where a cursor rests

Status: decided 2026-11-14 and built, by the command loop's phase 11
(`Evil.Rest`, `Evil.restOf` and `Evil.rested`, `lean/Editor/Evil.lean`;
pinned by `evilRestChecks` from every position of a few small texts, and
by the sweep of `evilMotionChecks`, which runs every motion of the table
from every resting position of the sample texts, with no count and with
counts of 1, 2 and 99, and holds the cursor to a cell that is not the line
break of a line with content).

A motion answers a position, its raw target, which the text port never
clamps. Where the head of a selection may stay after a command is a rule
of the view's state, applied to the raw target. The rule is evil's and is
in Lean.

| The state's report | Rule | Where the head may rest |
|---|---|---|
| Exclusive shape (insert, the minibuffer) | `anywhere` | Any position, the text's end included |
| Not exclusive, not selecting (normal) | `offLineBreak` | A cell of its line that is not the line break, or the line break of an empty line |
| Not exclusive, selecting (the visual states) | `onCell` | Any cell, a line break included |

For the two rules that are not `anywhere`, in order:

1. An empty text answers 0.
2. An offset at or past the text's length goes to the start of the last
   cell. This keeps the head out of the empty last row of a text that ends
   in a line feed, and never past the last cell.
3. An offset past its row's content (between a carriage return and its
   line feed) goes to where the content ends.
4. For `offLineBreak`, an offset on the line break of a row that has
   content goes back one cell.

- **A line break is a cell in a visual state**, because Vim's cursor may
  be one past the line there: `v$` puts the head on it, and so do `l` at
  the last character and `j` onto a shorter line.
- **The empty last row is not a line for a cursor outside insert state.**
  A text that ends in a line feed has an empty last row with no cell;
  Vim has no such line, since its lines are ended by line breaks and not
  separated by them. `G` goes to the last row that has a cell, `j` stops
  there, and a `w` or an `e` that runs off the text rests on the last
  character, as Vim does on a file.
  - **What differs from Vim**: in insert state the bar can be in the empty
    last row, for example after a line break is inserted at the very end
    of a text. On escape the cursor rests on the last character of the row
    above, where Vim would show a new empty line. It is pinned at the
    resting rule, from the text's length.
  - **Where operators and `o` meet it** (a recorded departure, pinned by
    two checks named as one): when a last line with no final line feed is
    emptied by cells being deleted or changed (`d$` or `dw` on its only
    word, `cc` and escape), and when `o` on such a line is left with
    escape, the text is what Vim writes, and Vim's cursor is on the
    emptied or new line. Here that line is the empty last row, and the
    cursor rests on the line above. It does not show on a text that ends
    in a line feed.
- **A departure**: on a last row with no line feed, a visual-state head
  stops on the last character, where Vim's goes one past. There is no
  cell there for an inclusive range to cover. One evil check pins it,
  named as a departure.
- **Set aside: clamping inside each motion.** An operator needs the raw
  target: `dw` on the last word wants the text's end.

### Insert sessions

Status: decided 2026-11-14 and built, by the command loop's phase 11
(`Loop.sessions`, `Loop.publish` and `EditorState.recordHistories`,
`lean/Editor/Loop.lean`; pinned by `dispatchUndoChecks` with a scheme
written in the test whose keys begin and end a session, and under the Vim
scheme by `evilInsertChecks`).

An insert session is the time a view is in a state where typing is text.
What is edited in its buffer during one session is one step of the
history.

**The loop leaves a buffer's undo group open while a view of it is in a
session.** It closes the group of every other buffer after every event,
as it did for every buffer before: a buffer is held while a window whose
view the scheme reports as in a session (`InputScheme.Report.session`)
shows it, in the scheme's state after the key.

- **A session's boundary is the state change itself.** Escape enters
  normal state; the scene published after its command finds no view of
  the buffer in a session, and the group is closed: one node for
  everything typed. Nothing is set by the command that begins an insert,
  and nothing is cleared by the one that ends it.
- **An arrow key in insert state starts a new undo step, as in Vim 9.1**
  (`:help ins-special-special`: "the changes (inserted or deleted
  characters) before and after these keys can be undone separately"). The
  command closes the buffer's group after a move that moved
  (`BufferId.closeGroup`, which `lean/Editor/Api.lean`'s "Undo" names as
  how a command sets a boundary inside a session itself), so what was
  edited before the key and after it are undone separately. A move that
  fails, left at a line's start or up on the first line, does not break
  the step, as Vim beeps without one. Backspace, Enter and Tab join the
  session's step ("Insert state").
- **An insert that begins with an edit is one step with no further
  rule**: `o` and `O` (a line break, then typed text) and `c` (a deletion,
  then typed text), because the view is in insert state when the scene
  after the command is published. That is Vim's rule, and nothing was
  built for it: one `u` takes the deletion and the typed text back
  together. A `c` over no cell makes no edit, so `cw` at the text's end
  and escape make no step; a `c` that gives up begins no session, since
  the scheme goes back to its state at rest.
- **A command that fails inside a session** is rolled back to the point of
  the open group it began at ([concurrency.md](concurrency.md),
  "Rollback"). The session's earlier text stays pending, and is one step
  with what follows.
- **Anything else that edits the buffer during a session** (a job's
  command, a committed text) joins the session's step.
- **A buffer is modified while its group is open**, so the status line
  shows it during the session.
- **The minibuffer's buffer** is in a session for as long as its prompt is
  open. Its history is given up with it.
- **A view left in insert state holds its buffer's group open**, and
  everything edited there meanwhile is one step. That is Vim's behaviour.
  A save taken inside a session marks a point inside the group, which the
  undo tree's rule for the saved state covers.
- **An undo of a session hands back an exclusive selection**: the one from
  before its first edit, which is insert state's bar, when that edit was
  typed text. Whoever places it gives it the shape of the view's state
  ("Undo and redo").
- **Set aside: commands close their own groups and the loop closes none.**
  Every command anyone writes would have to remember.
- **Set aside: a flag on the buffer that the inserting command sets and
  escape clears.** Every command that begins an insert would have to set
  it, and a command that fails between the two leaves it wrong unless it
  is rolled back with care. The scheme's state already says it.

**A committed text is typed text: it is inserted only where the scheme's
report says the view takes text** (`InputScheme.Report.takesText`,
`Loop.handle`; pinned by `commitChecks` and `evilInsertChecks`).

- Under the Vim scheme that is insert state and the minibuffer; under a
  scheme that says nothing, every view. Elsewhere the committed text is
  dropped, and the preedit is cleared either way.
- **Why.** Normal state's selection is inclusive, and a commit replaces
  what the selection covers: an input method's text in normal state would
  replace the character under the cursor and leave the cursor where the
  resting rule forbids.
- It was not in the phase's description; the alternative is to leave the
  commit as it was (the open questions).
- **The scheme is told of a commit that was inserted**
  (`InputScheme.committed`), in both states of it the loop keeps, and not
  of one that is dropped: it is typed text that no key printed ("The last
  change").

### Insert state

Status: built, by the command loop's phase 11 (`lean/Editor/Evil.lean`;
pinned by `evilInsertChecks`).

Four commands place the bar, one inserts typed text, and seven named keys
edit or move inside the session.

| Key | Command | Where the insert begins |
|---|---|---|
| `i` | `insert` | Before the cursor's cell: the head stays |
| `a` | `append` | After the cursor's cell: one cell on, and not past where the line's content ends, so on an empty line the head stays |
| `I` | `insert-line-start` | At the line's first character that is not a blank, which on a line of blanks only is where the content ends |
| `A` | `append-line-end` | Where the line's content ends, before its line break |

- **Each moves the head and then enters the state** by the entering rule
  ("Vim states"), which collapses the selection to an exclusive bar.
- **Typed text** is `self-insert` ("Edits").
- **`<Escape>` is the entering rule too**: leaving an exclusive selection,
  the head steps back one cell on its line.
- **The minibuffer's typing is served by the same command, with no code of
  its own** ("The minibuffer").
- **`o` and `O` open a line** (`open-below`, `open-above`;
  `Evil.openBelow`, `Evil.openAbove`). `o` inserts the buffer's line
  ending where the cursor's line's content ends, and the new line is after
  it; `O` inserts it at the start of the cursor's line, and the new line
  is before it. Each leaves one range of the shape its call's report says
  on the new line: a bar there, in insert state, when a key that enters
  insert state runs it, and the cursor resting there when it is run by its
  name. The line ending is read from the buffer (`Buffer.lineEnding`), and
  the edit carries the selection from before the command ("Undo and
  redo"). The new line starts at its indent level ("Indenting a new
  line"): `o` inserts the line ending and then the indent, `O` the indent
  and then the line ending, and the bar goes after the indent.
- **Not built: a count before `i a I A o O`.** Vim repeats the inserted
  text. The six commands ignore their count and their register.

The editing keys are named keys, which print nothing (`Key.printed?`), so
each is a row of `insertCommands` (`Evil.deleteBackward`, `Evil.newline`,
`Evil.insertTab`, `Evil.insertMove`; Daily-driver floor phase 1). Each
follows Vim 9.1 with its default options:

| Key | Command | Behaviour, as Vim 9.1 documents it |
|---|---|---|
| `<Backspace>` | `insert-delete-backward` | Deletes the character before the bar; a carriage return and line feed, or a character of several bytes, goes whole. At a line's start it joins the line to the one above, and it deletes past where the insert began: `i_<BS>` under `backspace=indent,eol,start`, Vim 9.1's default. At the text's start it deletes nothing |
| `RET` | `insert-newline` | Breaks the line at the bar with the buffer's own line ending, as `o` and `O` read it, and starts the new row at its indent level ("Indenting a new line", below): the blanks either side of the bar are replaced, so the row left keeps no trailing blanks and the rest starts at its level, and the bar goes after the indent. With no syntax tree or no indents query it inserts the line ending alone, as before indenting; a text not parsed yet gets the row's own indent. With several ranges it breaks the line at each (`Target.insertLineBreak`), with no indent |
| `TAB` | `insert-tab` | Inserts a tab character: Vim's defaults `noexpandtab` and `softtabstop=0` |
| `<ArrowLeft>` | `insert-left` | One cell back, no further than the line's start (`whichwrap=b,s`: no wrap) |
| `<ArrowRight>` | `insert-right` | One cell on, no further than where the line's content ends |
| `<ArrowUp>` | `insert-up` | A line up, at the wanted column, clamped to a shorter line and kept through it; nothing on the first line |
| `<ArrowDown>` | `insert-down` | A line down, the same; nothing on the last line |

- **Built: `<Backspace>`, `RET`, `TAB`, `<ArrowLeft>`, `<ArrowRight>`,
  `<ArrowUp>` and `<ArrowDown>` in insert state.**
- **An arrow key that moves starts a new undo step** ("Insert sessions");
  the other three join the session's step.
- **Each is bound as a command that changes no text for the grammar**, so
  it is not the last change and keeps the recording of the session's typed
  text ("The last change").
- **Dot repeat replays them as Vim 9.1's does** ("The last change", "Dot
  repeat as built"). `<Backspace>`, `RET` and `TAB` are kept in the
  session's typed text, in the order typed (`Command.typed`: the backspace
  character, a line feed and a tab), and `.` runs them again, so it makes
  the session's result: after `i x <BS> y <Esc>` it inserts `y`, a
  `<Backspace>` past where the insert began deletes there too, and `RET`
  is replayed by `RET`'s command (`Evil.newline`), so it breaks the line
  and indents the new row as typing it does. The typed text holds no
  indent, only the line feed, which is Vim's `.` under `autoindent`; a
  line break after typed text inside one replay gets its row's own
  indent, the text not being parsed yet. An arrow key that moved
  restarts the last change as `i` once something is typed after it, with
  the text typed from there on (`Command.restarts`), as
  `ins-special-special` says: "only the last change can be redone and
  always behaves like an 'i' command". Vim restarts at the first key typed
  after the arrow key, not at the arrow key, so with nothing typed after it
  the change is as it was. An arrow key that did not move gives its command
  up (`cannotMove`, said in the echo area where Vim beeps), so the loop puts
  the scheme back in its state from before the key and nothing restarts,
  as Vim's beep restarts nothing.
- **Not built: the other keys of Vim's insert state**: `C-w`, `C-u`,
  `C-o`, `C-r`, `<Home>` and `<End>` do nothing there (the open
  questions).

#### Indenting a new line

Status: built, by language-modes phase 3 (`lean/Editor/Evil.lean`,
`Evil.openingIndent`; `lean/Editor/Indent.lean`, "The opening rule"; pinned
by `indentOpeningChecks`, `indentEditChecks`, `evilIndentChecks`,
`ConfigTest.indentChecks` and `ContractTest`'s opening table).

`RET`, `o` and `O` ask the level of the new row of the text the user sees,
before the line break (`TextId.openingLevel`), at the offset the line opens
at: the bar for `RET`, where the cursor's line's content ends for `o`, and
the line's start for `O`. That text's tree is the one delivered last: keys
come further apart than an incremental reparse, which is milliseconds, and
the editor thread never waits for a parse. A position in the text before
the break answers the new row's level, so nothing is asked of a revision
that has no tree, and the syntax tree port gains nothing.

| What the opening level is | The new line's whitespace |
|---|---|
| A level | That many of the buffer's indent unit |
| None: inside a multi-line string or block comment | Nothing added |
| Refused `notParsed`: keys faster than a reparse, or a replay | The opening row's own leading whitespace (Vim's `autoindent`) |
| Refused otherwise: no language, a mode with no tree, a language with no indents query | Nothing added: the edit is the one before this phase, byte for byte |

- **`RET` truncates the blanks at the split**: with something added, the
  blanks just before the bar on its row and just after it go, replaced by
  the line ending and the indent (`Indent.breakAt`), as Vim's `open_line`
  does under `autoindent`. The row left keeps no trailing blanks (`RET RET`
  leaves an empty row), and the rest of the line starts at the indent. A
  closing bracket that moves to the new row leads it a level out.
- **One undo step with the session**: `o`/`O` with their indent, and `RET`
  with its, are part of the insert session's one step.
- **Several ranges**: `RET` breaks the line at each with no indent, as
  before; evil makes no multi-range insert today.
- **A recorded departure**: Vim removes an indent left untouched when the
  insert is left (`<Escape>` after `o` with nothing typed). Here the blanks
  stay until `=`, or a `RET` on that row, which replaces them.
- **No electric closing bracket**: typing `}` as a row's first character
  does not re-indent the row, where Vim's `indentkeys` has `0}`; a later
  `=` does.

### Motions as built

Status: built, by the command loop's phase 11
(`lean/Editor/Evil/Motions.lean`; pinned by `evilMotionChecks`).

Twenty-eight motions are vocabulary entries. Fifteen are composed from the
text port's motion primitives ([text-and-display.md](text-and-display.md),
"Motion primitives"), the six character finds walk the line's content
in Lean, the six searches ask the text port's `search`, and `%` its
`unmatched`. What a count means, and what a motion does when it cannot go the
whole way, is Vim's:

| Key | Motion | Composed from | Count |
|---|---|---|---|
| `h`, `l` | `left`, `right` | `previousCell`, `nextCell`, stopped at the line's start and at where its content ends | Repeats. Goes as far as the line allows |
| `j`, `k` | `down`, `up` | `rowsDown`, `rowsUp` to the line's start, then the display's position at the wanted column of that line ("The wanted column") | Rows. Stops at the last line and at the first |
| `w`, `b`, `e`, `W`, `B`, `E` | `word-forward`, `word-backward`, `word-end` and the three `bigword` names | `nextWordStart`, `previousWordStart`, `nextWordEnd` of a word or a WORD | Repeats. Stops when the position no longer changes |
| `0` | `line-start` | `lineStart` | None is ever given: a `0` after a digit is part of the count. A count is ignored |
| `^` | `line-first-non-blank` | `lineFirstNonBlank` | Ignored, as Vim documents |
| `$` | `line-end` | `rowsDown (count - 1)`, then `lineEnd` | The end of the line `count - 1` lines below. With fewer lines below it goes to the last line's end. On the last line with a count above 1 it does not move, which is Vim's failed motion |
| `g g`, `G` | `first-line`, `last-line` | `offsetOf` of the row's start, then `lineFirstNonBlank` | The line number, from 1, stopped at the last line. With none: the first line, and the last |
| `f`, `F` | `find-forward`, `find-backward` | The line's content (`slice` from `lineStart` to `lineEnd`), walked from the cursor | The `count`th occurrence of the character after the cursor (before it, for `F`). With fewer in the line it does not move, and fails |
| `t`, `T` | `till-forward`, `till-backward` | The same, then one cell back towards the cursor | As `f` and `F`. With the character right beside the cursor it does not move, and does not fail (Vim's `searchc`) |
| `;`, `,` | `find-again`, `find-again-reverse` | The last find (`EditorState.lastFind`), as it was, and for `,` in the other direction | As the find it runs. With no last find it fails where it is |
| `/{pat}RET`, `?{pat}RET` | `search-forward`, `search-backward` | The text port's `search` ([text-and-display.md](text-and-display.md); the rule is in `lean/Editor/Text.lean`, "Search") | The `count`th match, each step from the last. Every step must find one, and one that wraps still counts |
| `n`, `N` | `search-next`, `search-previous` | The same, of the last search (`EditorState.lastSearch`), in its direction and in the other | As above |
| `*`, `#` | `word-search-forward`, `word-search-backward` | The same, of the word under the cursor as a whole word, searched from the word's start | As above |
| `%` | `matching-bracket` | The first of `( [ { } ] )` on the line at or after the cursor, then the text port's `unmatched` walk to its partner, counting only brackets of its escapedness (`lean/Editor/Text.lean`, "Pairs") | With a count, Vim's `N%`: the first non-blank of the line `(N * lines + 99) / 100`, taken as whole lines. A count above 100 fails |

**`%`** (`:help %`): with no bracket on the line at or after the cursor,
and with no partner, it fails where it is and says nothing, as Vim only
beeps; an operator over it gives up. It is inclusive. A bracket after an
odd number of backslashes is escaped and matches only an escaped one,
which is Vim's rule without `cpo-M`. A bracket Vim guesses is quoted is
passed over, as under Vim's default `cpoptions` (without `cpo-%`): the
guess is made a line at a time, and reads the line's double quotes only
when there is an even number of them (`lean/Editor/Text.lean`, "Pairs").
One departure from Vim's default `cpoptions`, recorded and pinned by a row
that shows the editor's behaviour: `/* */` and `#if`, `#else`, `#endif`
are not matched, being a syntax tree's or a plugin's.

**The searches** (`:help /`, `:help n`, `:help star`), under Vim's default
options (`cpoptions` with `c`, `wrapscan`, `magic`, `noignorecase`):

- **The user types Vim's syntax**, a subset of it under `magic`, not the
  regex library's ([rust-library.md](rust-library.md), "Search, as
  built"), so `foo(` and `a|b` are literal, as in Vim.
- **Each step starts at the head, and a match that starts there is passed
  over**, so `/abab` in `|abababab` goes to `abab|abab`.
- **A search that wraps says so**: `search hit BOTTOM, continuing at TOP`
  forward, `search hit TOP, continuing at BOTTOM` back, as Vim warns. With
  no match it fails where it is and says `E486: Pattern not found: {pat}`;
  `n` and `N` with no last search say `E35: No previous regular
  expression`; `*` and `#` with no word in the line say `E348: No string
  under cursor`. A motion says these through `Vocabulary.To.said`, and the
  move command says them; under an operator a failure gives the command
  up with it, as `operate: E486: Pattern not found: x`.
- **An empty pattern is the last search's pattern**, in the new
  direction (`:help last-pattern`). With no last search it is E35.
- **The last search is remembered as data** (`Vocabulary.To.search`,
  `EditorState.lastSearch`), pattern and direction, also when the search
  fails, as Vim keeps the pattern. `N` does not change the direction, and
  `n` after `#` goes back. A search under an operator that fails gives the
  command up, which rolls it back, a recorded departure as for the finds.
- **`*` and `#`** search for the first of: the keyword under the cursor,
  the first keyword after it in the line, the run of punctuation under the
  cursor, the first such run after it. A keyword is a run of word
  characters, the text's class (as for `w`), not Vim's `iskeyword` table,
  a recorded departure beyond ASCII. The pattern is the word with
  `\ / . * $ ^ ~ [` escaped, with `\<` before it when it starts with a
  word character and `\>` after it when it ends with one, as Vim's
  `nv_ident` builds it. The search starts from the word's start, as Vim
  moves the cursor there first, so `*` passes over the word under the
  cursor; an operator still takes from the cursor, as Vim's `oap->start`
  is set when the operator key is typed.
- **Under an operator every search is exclusive**, so the two rules for an
  exclusive motion that ends in column 1 apply: `d*` from a line's start to
  the next line's start deletes the line, line-wise.
- **Not built**: search offsets (`/foo/e`), search history, `incsearch`,
  the jump list, `ignorecase` and `smartcase`.

**The character finds** (`:help f`, `:help t`, `:help ;`):

- **They never leave the line.** A character on the next line is not
  found.
- **The character is the motion's argument** (`Vocabulary.From.argument`),
  the text the next key printed (`Bound.charMotion`, "What a key is bound
  to"). Run with none, by its name, by config or by a sweep, a find fails
  where it is.
- **The find is remembered as data.** `f`, `t`, `F` and `T` hand back the
  find they made (`Vocabulary.To.find`), also when they fail, and the move
  and operate commands keep it (`setLastFind`), as Vim keeps the character
  even when the motion fails. It is global, as Vim's is. `;` and `,` hand
  back none, so `,` does not change the direction kept: `f x , ;` goes
  back and then forward again.
- **A till repeated with a count of 1 passes over the character beside the
  cursor**: Vim's default `cpoptions` has no `;`, so `t x ;` right before
  an `x` goes on to the next `x` (`searchc` sets `stop = FALSE`). With a
  count, as `2;`, the first step does stop at it.
- **Under an operator** `f` and `t` are inclusive and `F` and `T`
  exclusive; `;` and `,` take the reach of the motion they run, so `d,`
  after `t` is exclusive. `dtx` in `|ax` deletes the `a`.
- **A recorded departure**: a find under an operator that fails gives the
  command up, which rolls back what it kept, so `dfz` on a line with no
  `z` leaves the last find as it was, where Vim keeps `z`.

- **The last line** (`Evil.lastLine`) is the last row a cursor may rest
  in outside insert state. It is the row before the empty last row of a
  text that ends in a line feed, and the last row otherwise. So it is row
  0 for the empty text and for a text that is one line feed.
- **A count is bounded by the text**: each motion that repeats stops when
  the position stops changing, and each turn is a request the interrupt
  flag guards, so `99999 w` on a large text can be interrupted.
- `gg` and `G` go to the first non-blank, which is Vim's default
  (`startofline`).
- **The move command** (`Evil.move`, registered under `move`): reads the
  primary range of its target's selection; hands the motion the window's
  wanted column when the range's head is where it was kept; asks the
  motion; rests the raw target by the rule of the call's report ("Where a
  cursor rests"); places one range with the report's shape, whose anchor
  is the old anchor when the report is selecting and the new head
  otherwise; and has the window keep the column the motion handed back,
  with the new head. Placing a marker is no edit, so a motion is no step
  of the history.
- **Several cursors are not built.** No command makes a second range. Each
  evil command reads the primary range and places one range.

**The oracle is Vim's documented behaviour, written out case by case; no
test runs Vim.**

- **The reference** is Vim 9.1's `motion.txt` (left-right motions, up-down
  motions, word motions) and `insert.txt` (`i a I A`), with the options a
  Vim started with no configuration has: `whichwrap=b,s` (so `h` and `l`
  stay on the line), `startofline`, `selection=inclusive`, `virtualedit`
  empty, `iskeyword=@,48-57,_,192-255`.
- **Each expected position is a string written by hand in the check**,
  with the cursor as `|`. For each motion the checks cover what applies to
  it: no count, a count of 1, a count inside the text, and a count past
  what the text has; the last character of a line, and the first; an empty
  line, as the start and as the target; a line of blanks only; the first
  line and the last line; the end of the buffer, with and without a final
  line feed; an empty text, and a text that is one line feed; for the word
  motions a run of punctuation beside a word (`foo.bar`, `foo(bar)`), a run
  of blanks, a line break between words, and leading blanks on the next
  line; a carriage return and line feed as the line break; and for `j`
  and `k` characters of two bytes before the cursor, where the cursor's
  column in cells is not its column in bytes.
- **A key string separates strokes with spaces** ("Key strings"), so a
  count and a two-key motion are written `2 w`, `9 9 G` and `g g`.

The table the checks are written from. `⏎` is a line feed, `␍⏎` a
carriage return and line feed, `⇥` a tab, and `|` the cursor. Each row
was run through Vim 9.1 (patches 1-1752) by hand, outside the suite, and
Vim agreed, except the rows with a carriage return, which Vim reads as
another file format and which follow from the cell. The checks have more
rows of the same kinds than are listed here.

| Keys | Before | After |
|---|---|---|
| `l` | `a\|bc` | `ab\|c` |
| `l` | `ab\|c`, and `ab\|c⏎def` | unchanged |
| `1 l`, `2 l`, `3 l` | `a\|bc`, `\|abcd`, `\|abcd` | `ab\|c`, `ab\|cd`, `abc\|d` |
| `5 l` | `\|abc` | `ab\|c` |
| `h` | `ab\|c` | `a\|bc` |
| `h` | `\|abc`, and `abc⏎\|def` | unchanged |
| `1 h`, `2 h` | `ab\|c`, `abc\|d` | `a\|bc`, `a\|bcd` |
| `2 h` | `abc⏎de\|fg` | `abc⏎\|defg` |
| `5 h` | `abc⏎de\|f` | `abc⏎\|def` |
| `l` | `\|⏎abc` | unchanged |
| `w` | `foo \|bar baz` | `foo bar \|baz` |
| `w` | `foo \|bar`, and `foo \|bar⏎` | `foo ba\|r` (the last character) |
| `w`, `3 w`, `9 w` | `\|foo.bar  x` | `foo\|.bar  x`, `foo.bar  \|x`, `foo.bar  \|x` |
| `1 w`, `2 w` | `foo \|bar baz`, `\|foo bar baz` | `foo bar \|baz` |
| `9 w` | `\|ab cd ef` | `ab cd e\|f` |
| `w`, `3 w` | `\|foo(bar)` | `foo\|(bar)`, `foo(bar\|)` |
| `w` | `\|foo⏎⏎bar` | `foo⏎\|⏎bar` (stops on the empty line) |
| `w` | `\|foo⏎   ⏎bar` | `foo⏎   ⏎\|bar` (passes a line of blanks) |
| `2 w` | `\|ab cd⏎  ef` | `ab cd⏎  \|ef` |
| `w` | `a⏎\|⏎` | unchanged |
| `e` | `\|foo bar`, `fo\|o bar`, `foo ba\|r` | `fo\|o bar`, `foo ba\|r`, unchanged |
| `e` | `fo\|o⏎⏎bar` | `foo⏎⏎ba\|r` (passes the empty line) |
| `e` | `fo\|o  ` (two trailing blanks) | `foo \| ` (the last blank) |
| `1 e`, `3 e`, `9 e` | `\|a b c d e` | `a \|b c d e`, `a b c \|d e`, `a b c d \|e` |
| `2 e`, `9 e` | `\|ab cd ef` | `ab c\|d ef`, `ab cd e\|f` |
| `e` | `\|foo(bar)`, `fo\|o(bar)`, `foo\|(bar)` | `fo\|o(bar)`, `foo\|(bar)`, `foo(ba\|r)` |
| `b` | `foo b\|ar`, `foo \|bar`, `\|foo bar` | `foo \|bar`, `\|foo bar`, unchanged |
| `b` | `foo⏎⏎\|bar` | `foo⏎\|⏎bar` |
| `1 b` | `foo b\|ar` | `foo \|bar` |
| `2 b`, `9 b` | `foo.bar  \|x` | `foo\|.bar  x`, `\|foo.bar  x` |
| `b`, `3 b` | `foo(bar\|)` | `foo(\|bar)`, `\|foo(bar)` |
| `W` | `\|foo.bar  x` | `foo.bar  \|x` |
| `W`, `1 W`, `2 W`, `3 W`, `9 W` | `\|a.b c.d e.f gh` | `a.b \|c.d e.f gh` twice, `a.b c.d \|e.f gh`, `a.b c.d e.f \|gh`, `a.b c.d e.f g\|h` |
| `2 W` | `\|a.b c.d⏎  e.f gh` | `a.b c.d⏎  \|e.f gh` |
| `W` | `\|foo⏎⏎bar` | `foo⏎\|⏎bar` |
| `B` | `foo.bar  \|x` | `\|foo.bar  x` |
| `B`, `1 B`, `2 B`, `9 B` | `a.b c.d e.f \|gh` | `a.b c.d \|e.f gh` twice, `a.b \|c.d e.f gh`, `\|a.b c.d e.f gh` |
| `2 B` | `a.b c.d e.f g\|h` | `a.b c.d \|e.f gh` |
| `B` | `foo⏎⏎\|bar` | `foo⏎\|⏎bar` |
| `E` | `\|foo.bar  x` | `foo.ba\|r  x` |
| `E`, `1 E`, `2 E`, `9 E` | `\|a.b c.d e.f gh` | `a.\|b c.d e.f gh` twice, `a.b c.\|d e.f gh`, `a.b c.d e.f g\|h` |
| `9 E` | `\|a.b c.d e.f gh⏎` | `a.b c.d e.f g\|h⏎` |
| `E` | `fo\|o⏎⏎bar` | `foo⏎⏎ba\|r` |
| `0` | `  a\|bc` | `\|  abc` |
| `1 0 l` | `\|abcdefghijklmno` | `abcdefghij\|klmno` (the `0` is part of the count) |
| `^`, `3 ^` | `  ab\|c` | `  \|abc` |
| `^` | `\| ⇥ ` (blanks only), and `\| ⇥ ⏎x` | on the last blank |
| `$` | `\|abc⏎def` | `ab\|c⏎def` |
| `1 $`, `2 $`, `3 $` | `\|abc⏎def⏎ghi` | `ab\|c⏎def⏎ghi`, `abc⏎de\|f⏎ghi`, `abc⏎def⏎gh\|i` |
| `2 $` | `\|abc⏎def` | `abc⏎de\|f` |
| `5 $` | `\|abc⏎def⏎` | `abc⏎de\|f⏎` |
| `2 $` | `abc⏎\|def` (the last line), and `abc⏎de\|f⏎` | unchanged |
| `$` | `\|⏎abc` | unchanged |
| `2 $` | `\|abc⏎⏎ghi` | `abc⏎\|⏎ghi` |
| `j` | `abc\|d⏎x⏎abcd` | `abcd⏎\|x⏎abcd` |
| `1 j`, `2 j`, `3 j` | `a\|b⏎cd⏎ef⏎gh⏎ij` | `ab⏎c\|d⏎ef⏎gh⏎ij`, `ab⏎cd⏎e\|f⏎gh⏎ij`, `ab⏎cd⏎ef⏎g\|h⏎ij` |
| `2 j` | `a\|b⏎cd⏎ef⏎gh⏎ij⏎` | `ab⏎cd⏎e\|f⏎gh⏎ij⏎` |
| `1 k`, `2 k` | `ab⏎cd⏎ef⏎g\|h⏎ij` | `ab⏎cd⏎e\|f⏎gh⏎ij`, `ab⏎c\|d⏎ef⏎gh⏎ij` |
| `3 k` | `ab⏎cd⏎ef⏎gh⏎i\|j` | `ab⏎c\|d⏎ef⏎gh⏎ij` |
| `j`, `2 j` | `hé\|llo⏎world`, `é\|bc⏎def⏎ghi` | `héllo⏎wo\|rld`, `ébc⏎def⏎g\|hi` (a character of two bytes before the cursor is one column) |
| `k` | `abcdef⏎éö\|x` | `ab\|cdef⏎éöx` |
| `j k`, `j j` | `hé\|llo⏎x⏎héllo`, `hé\|llo⏎x⏎world` | `hé\|llo⏎x⏎héllo`, `héllo⏎x⏎wo\|rld` (the kept column is not in bytes either) |
| `j`, `k` | `a⇥\|b⏎0123456789`, `0123456789⏎a⇥\|b` | `a⇥b⏎01234567\|89`, `01234567\|89⏎a⇥b` (the display column after a tab, with a tab stop of 8) |
| `j`, `k` | `世\|b⏎0123456789`, `0123456789⏎世\|b` | `世b⏎01\|23456789`, `01\|23456789⏎世b` (a wide character is two columns) |
| `j` | `0123\|456789⏎a⇥b`, `01\|23456789⏎a世b` | `0123456789⏎a\|⇥b`, `0123456789⏎a\|世b` (a column inside a tab or a wide character lands on it) |
| `j j k k` | `a⇥\|b⏎xy⏎0123456789`, `a世\|b⏎x⏎0123456789` | each as it started |
| `j j` | `abc\|d⏎x⏎abcd` | `abcd⏎x⏎abc\|d` |
| `j k` | the same | `abc\|d⏎x⏎abcd` (the acceptance criterion) |
| `j j` | `abc\|d⏎⏎abcd` | `abcd⏎⏎abc\|d` (across an empty line) |
| `5 j`, and `5 k` from the last line | `abc\|d⏎x⏎abcd` | the last line, and the first, in the same column |
| `j` on the last line, `k` on the first | | unchanged |
| `j` | `ab\|cd⏎xyz⏎` | `abcd⏎xy\|z⏎`, and a second `j` does not move |
| `2 j 2 j`, `j 3 j` | `ab\|cd⏎x⏎abcd⏎y⏎abcd` | `abcd⏎x⏎abcd⏎y⏎ab\|cd` |
| `j 2 j` | the same | `abcd⏎x⏎abcd⏎\|y⏎abcd` |
| `k 2 k`, `k 3 k` | `abcd⏎x⏎abcd⏎y⏎ab\|cd` | `abcd⏎\|x⏎abcd⏎y⏎abcd`, `ab\|cd⏎x⏎abcd⏎y⏎abcd` |
| `j h j`, `j l j` | `abc\|d⏎x⏎abcd` | `abcd⏎x⏎abc\|d` (a failed `h` or `l` keeps the column) |
| `k j` | the same | `abcd⏎\|x⏎abcd` (a failed `k` keeps it too) |
| `j h j` | `abc\|d⏎xy⏎abcd` | `abcd⏎xy⏎\|abcd` (an `h` that moves keeps none) |
| `j 0 j` | `abc\|d⏎⏎abcd` | `abcd⏎⏎\|abcd` |
| `j ^ k`, `j e k` | `abc\|d⏎x⏎abcd` | `\|abcd⏎x⏎abcd`, `abcd⏎\|x⏎abcd` |
| `j w j` | `abc\|d⏎x⏎abcd⏎abcd` | `abcd⏎x⏎abcd⏎\|abcd` |
| `$ j j`, then `k` | `\|abc⏎de⏎abcdef` | `abc⏎de⏎abcde\|f`, then `abc⏎d\|e⏎abcdef` |
| `2 $ k` | `abc⏎\|def` | `ab\|c⏎def` (a `$` that does not move keeps the line's end) |
| `G` | `a\|bcd⏎  xyz⏎` | `abcd⏎  \|xyz⏎` |
| `g g` | `abcd⏎  x\|yz` | `\|abcd⏎  xyz` |
| `1 G`, `2 G`, `3 g g`, `9 9 G` | `a⏎b⏎  c\|c⏎d` | on `a`, on `b`, on the first `c`, on `d` |
| `2 G` | `ab⏎⏎\|cd`, and `ab⏎   ⏎\|cd` | on the empty line, and on the last blank |
| `j G k k` | `abc\|d⏎x⏎abcd` | `\|abcd⏎x⏎abcd` (`G` keeps no column) |
| `j v j`, `j v <Escape> j`, `j i <Escape> j` | `abc\|d⏎x⏎abcd` | `abcd⏎x⏎abc\|d`, then `abcd⏎x⏎\|abcd` twice |
| every motion | the empty text, and the text of one line feed | unchanged, at 0 |
| `h`, `l`, `0`, `^`, `$` | `ab⏎\|⏎cd` (an empty line) | unchanged |
| `j`, `w`, `W`, `G`; `k`, `b`, `B`, `g g`; `e`, `E`, `2 $` | the same | `ab⏎⏎\|cd`; `\|ab⏎⏎cd`; `ab⏎⏎c\|d` |
| `l`, `j`, `w`, `e`, `W`, `E`, `$`, each also with a count of 3 | `ab⏎c\|d`, and `ab⏎c\|d⏎` (the last character) | unchanged |
| `h`, `b`, `B`, `0`, `^`, `G`; `k`; `g g` | the same | `ab⏎\|cd`; `a\|b⏎cd`; `\|ab⏎cd` |
| `k` | `ab␍⏎\|cd` | `\|ab␍⏎cd` |
| `$`, `l` | `a\|b␍⏎cd` | unchanged, on `b` |
| `w`, `b` | `foo \|bar␍⏎baz`, `foo␍⏎\|bar` | `foo bar␍⏎\|baz`, `\|foo␍⏎bar` |
| `i X <Escape>` | `ab\|c` | `ab\|Xc` |
| `i <Escape>` | `a\|bc`, `\|abc` | `\|abc`, unchanged |
| `a X <Escape>` | `a\|bc`, `ab\|c⏎def`, `\|⏎abc` | `ab\|Xc`, `abc\|X⏎def`, `\|X⏎abc` |
| `I X <Escape>` | `  ab\|c`, `\| ⇥ ` | `  \|Xabc`, ` ⇥ \|X` |
| `A X <Escape>` | `a\|bc` | `abc\|X` |
| `v $`, `v l`, `v j` (the head) | `a\|bc⏎def`, `ab\|c⏎def`, `abc\|d⏎x⏎abcd` | on the line break |

**Departures from Vim**, each recorded where it is decided and pinned by
its owner:

- **Word characters outside ASCII.** An em dash, an emoji and CJK text are
  word characters here and classes of their own in Vim: `w` from the start
  of `foo—bar baz` goes to `baz` here and to the dash in Vim. Recorded in
  [text-and-display.md](text-and-display.md), open question "Character
  classes for words outside ASCII". The rule is the text port's, so it is
  pinned there and nowhere else: by the library's own tests and by the
  text contract's word table, on the model and the library. Evil's checks
  use ASCII text for the word motions, and one text with `é` and `ö`, on
  which the two agree. They do not restate the rule: a fix to the table
  must break no evil check.
- **A cursor on a tab aims for the tab's first display column** ("The
  wanted column"). Vim's aims for its last.
- **A visual-state head on a last row with no line feed**, and **the empty
  last row after an insert** ("Where a cursor rests").
- **A count before `i a I A` is ignored** ("Insert state"). Vim repeats
  the insert.

### Text objects as built

Status: built, by daily-driver-floor phase 4
(`lean/Editor/Evil/Objects.lean`, over the text port's two pair questions,
`lean/Editor/Text.lean`, "Pairs"; pinned by `evilObjectChecks`).

Sixteen text objects are vocabulary entries (`Vocabulary.TextObject`): a
name and a function from where it is asked (`Within`: the head, the count
and, in a visual state, the anchor) to what it covers (`Span`: a start, a
stop and a reach, Vim's own end and inclusiveness), or none. Each is a
literal port of Vim 9.1's `textobject.c`:

| Keys | Objects | Composed from | Count | Rule |
|---|---|---|---|---|
| `iw`, `iW` | `inner-word`, `inner-bigword` | Vim's cursor steps (`inc`, `dec`, `incl`, `decl`) and word walks (`fwd_word`, `end_word`, `bck_word`, `bckend_word`, `back_in_line`) over the text port, a cell's class by the text's word class | Each further count adds one word or one run of blanks | The word or the run of blanks under the cursor (`current_word`) |
| `aw`, `aW` | `a-word`, `a-bigword` | The same | Each further count adds a word and its blanks | The word and the blanks after it, or before it when none are after and they are no indent; on blanks, the blanks and the word after |
| `i"`, `i'`, `` i` `` | `inner-double-quote`, `inner-single-quote`, `inner-backquote` | The text port's `quoted` | 2 or more takes the quotes and no blanks | The quoted string round the cursor in its line, without its quotes (`current_quote`) |
| `a"`, `a'`, `` a` `` | `a-double-quote`, `a-single-quote`, `a-backquote` | `quoted`, and the line's cells for the blanks | Ignored | With its quotes and the blanks after it, or before it, indent included, when none are after |
| `i(` `i)` `ib`, `i[` `i]`, `i{` `i}` `iB` | `inner-paren`, `inner-bracket`, `inner-brace` | The text port's `unmatched`: back to the `count`th unmatched opening bracket, or, with none round the cursor, forward to the `count`th next one, and forward to its partner | The `count`th pair out | Between the brackets; from the line after an opening bracket that ends its line; when the closing bracket is at or before its line's first non-blank, up to the start of the line after the last that has content, so an operator takes whole lines (`current_block`) |
| `a(` `a)` `ab`, `a[` `a]`, `a{` `a}` `aB` | `a-paren`, `a-bracket`, `a-brace` | The same | The same | The pair with both brackets |

- **Under an operator** an object is taken as a motion's target is, from
  the span's start with the span's reach (`Editor/Evil/Operators.lean`, "A
  text object under an operator"): Vim's exclusive-linewise rule and Vi's
  rule for a deletion over lines apply, as Vim applies them, so `d i {`
  over lines is line-wise and `d a w` of a word alone on its line takes the
  line. An object that covers no cell first moves the cursor to its start,
  as `d i (` on `f|()` leaves `f(|)`. An object that is not there gives
  the command up, nothing taken.
- **In a visual state** (`v`, `V`) an object's keys are `Edit.select`,
  which runs `select-object`: the selection becomes one charwise range,
  from the span's start to its head, and `V` enters `v`, as Vim's objects
  make a line-wise selection characterwise. A selection of one cell is the
  object under the cursor. A wider one is extended from its head: a word
  object by one more, backward when the head is before the anchor; a block
  object from the selection's low end, and by the next pair out when the
  block found is no bigger. An object that is not there leaves the
  selection and says nothing, as Vim beeps; after `V` the command gives up
  so the view stays in `visual-line`.
- **Blocks search forward** with no pair round the cursor, for every kind,
  and across lines: Vim 9.1's `:help ib` ("If the cursor is not inside a
  () block, then find the next `(`"), which the installed Vim 9.1.1752
  does for `[` and `{` too. An escaped bracket is passed over (`cpo`
  without `M`), and an empty inner block is none in a visual state.
- **Quoted brackets are passed over on the way to a block's closing
  bracket** and not on the way back to its opening one, as Vim 9.1's
  `current_block` walks back with `cpo` set to `%` and forward with the
  default `cpo`: in `(a "b|)" c)`, `d i (` takes `a "b)" c`. A visual
  selection extended to the next pair out walks both ways with the
  default `cpo`, as Vim's does.
- **Dot repeat** replays an operator over an object by name, from where
  the cursor is then, with a count typed before `.` in place of the
  change's.
- **Recorded departures**, each pinned by a row that shows the editor's
  behaviour:
  - A quote object over a visual selection wider than one cell is not
    built (Vim's "another string is included"): there is none, and the
    selection is as it was.
  - Word classes beyond ASCII are the text's word class as it stands.
  - `i<` `a<`, `it` `at`, `is` `as` and `ip` `ap` are not built.

#### The syntax tree's objects

Status: built, by the syntax-tree-sitter roadmap's phase 3
(`lean/Editor/Evil/TreeObjects.lean`; pinned by `treeObjectRuleChecks`,
`evilObjectChecks`, `ContractTest`'s rows over `tests/syntax/rust/objects.rs`
and `ConfigTest`'s `v a f`, and `v i f` from a `fn` line, through a host of
the Vim scheme).

Six more entries of `Evil.objects` (which is `Evil.vimObjects`, the sixteen
above, and these) take their ranges from the syntax tree of a buffer's
text: the captures of the text objects query its major mode keeps
(`Mode.SyntaxTree.textObjects`, or the grammar's shipped one), asked of the
library as plain rows (`SyntaxTree.capturesOf`), the rule Lean's:

| Keys | Objects | Captures read | Rule |
|---|---|---|---|
| `af`, `if` | `a-function`, `inner-function` | `function.outer`, `function.inner` | The function round the cursor; inside, its body |
| `ac`, `ic` | `a-class`, `inner-class` | `class.outer`, `class.inner` | The class round the cursor (a struct, enum, union, trait, impl or mod in Rust); inside, its body |
| `aa`, `ia` | `an-argument`, `inner-argument` | `parameter.inner` | The argument round the cursor, with its separator; alone |

- **The rule** (`TreeObjects.choose`): the nodes of the object's outer
  capture, each range once; those enclosing the selection (`start ≤ low`,
  `high < stop`), smallest first; in a visual state with a selection wider
  than one cell, a node no bigger than the selection passed over for the
  next one out, as block objects do; the `count`th (1 with none typed),
  too few being no object; and for `if` and `ic` the longest inner row
  within the chosen node, asked again over the node's own range so that a
  cursor on a `fn`, a `struct` or a closure's parameters, outside the
  inside, still has it, none being no object (a unit struct, a signature
  with no body).
- **Inside brackets**: an inner range that starts with an opening bracket
  and ends with its partner is Vim's inner block between them
  (`Evil.innerBetween`, which `i{` runs too, factored out of
  `currentBlock`); any other inner range is taken as it is, exclusive (a
  closure whose body is an expression).
- **Outer objects** are the node's range, exclusive. `d af` of a function
  that fills its lines takes them whole, by `d`'s own rule over lines (a
  charwise span from a line's indent to the end of a later line); `c` and
  `y` take it charwise.
- **The separator** of `aa`: a comma after the argument (blanks before it
  allowed) is taken with the blanks after it, line breaks included, up to
  the next non-blank; otherwise a comma before it, blanks and line breaks
  between allowed; otherwise the argument alone.
- **No object** where the syntax tree port refuses: a text with no syntax
  tree, one whose mode keeps no text objects query, and one whose last
  edit's tree is not yet delivered ("A structural question before its
  reparse", `docs/design/README.md`). Under an operator the command gives
  up (`noObjectHere`); in a visual state the selection stays.
- **Open points**: a node found forward when none encloses the cursor, as
  `ib` finds the next pair; `d af` taking whole lines when the function
  fills them under `c` and `y` too; text objects inside injected layers
  (`vaf` in a Markdown fence finds nothing); and a macro or `.` that runs an
  object right after an edit, before its reparse is delivered.

### Operators as built

Status: built, by the command loop's phase 13
(`lean/Editor/Evil/Operators.lean`, `lean/Editor/Evil/Registers.lean`,
`lean/Editor/Evil/Motions.lean`; pinned by `evilOperatorChecks`,
`evilSelectionChecks`, `evilRegisterChecks` and `evilOpenChecks`). `=`
is built by language-modes phase 3 (pinned by `evilIndentChecks` and
`ConfigTest.indentChecks`).

**The oracle is Vim's documented behaviour, written out case by case; no
test runs Vim.** The reference is Vim 9.1's `motion.txt`, `change.txt`,
`insert.txt` and `repeat.txt`, with the options a Vim started with no
configuration has (`cpoptions=aABceFsz`, `selection=inclusive`,
`startofline`, `noautoindent`). Each expected result is written by hand in
a check: the keys, the text before with the cursor, the text after with
the cursor, the unnamed register and whether it is line-wise. The unnamed
register holds a sentinel before the keys, so a register left as it was
is seen. Every row was run through Vim 9.1 by hand, outside the suite,
when the phase was planned.

- **The operator × motion table** is five situations of 88 cases, each of
  the 22 motions that take no argument under each of `d`, `c`, `y` and
  `=`: no
  count; a count of 2; the cursor on an empty line; and the cursor on the
  buffer's last character, on a text that ends in a line feed and on one
  that does not, because the empty last row makes those two cases here.
  Each situation is one text and one cursor, and every motion is run from
  it with each operator (`ModelTest.operatorTable`). A check that reads
  the default tables holds it complete: the pairs of keys each situation's
  rows have are exactly the product of the operators' keys and the
  motions'. The situations' buffer has no language, so every `=` row is
  the indent operator giving up (`Evil.cannotIndent`); what `=` does over
  a motion with indent levels is `evilIndentChecks`'s, and the find,
  search and text-object tables each have `=` rows over a JSON text the
  model's tree indents.
- **A sweep beside it** (`ModelTest.operatorSweep`) presses every operator
  key with every motion key, with no count and with a count of 2, from
  every resting position of a few texts: nothing is refused, the cursor
  rests where normal state lets one after `d` and `y`, `y` leaves the
  text, and `u` restores a text that changed, and the cursor. It reads
  the tables, so it covers a key added later.

**What an operator takes** (`Evil.stretch`). `p` is the head and `t` where
the motion's `taken` leads. The rules, in order, each from Vim's
documentation:

| # | Rule | Source |
|---|---|---|
| R1 | A motion that failed cancels the operator, and the cursor is left where the motion got to | Vim cancels the operator; its documents do not say it in one place |
| R2 | Reach `lines`: the stretch is the lines of `p` and `t`, and those between | `motion.txt`, `linewise` |
| R3 | Otherwise it is cells from the lower of `p` and `t` to the higher. Reach `inclusive` takes the cell at the higher end too, unless that end is where its line's content ends | `motion.txt`, `inclusive`, `exclusive` |
| R4 | The stretch stops no later than where the last line's content ends | The empty last row is no line here; Vim cannot address the last line's line feed |
| R5 | Reach `exclusive`, the stretch stops at a line's start, and it starts on an earlier line: when it starts at or before its line's first non-blank, it is the lines from its first to the line before its stop. Otherwise it stops where the line before ends | `motion.txt`, the two exceptions under `exclusive`, and `exclusive-linewise` |
| R6 | For an operator with `linesOverBlanks` (`d`): cells that start at or before their line's first non-blank, stop on a later line, and have only blanks between their stop and that line's end are that many whole lines | `change.txt` under `d` (`cpo-z`, in the default `cpoptions`) |
| R7 | Otherwise the stretch is those cells, with the motion's reach | |

What each motion says of itself:

| Motion | Reach | `taken`, where it is not `target` | Fails |
|---|---|---|---|
| `left`, `right` | exclusive | | Never. `right`'s raw target is the line break at a line's last cell, so `dl` there takes that cell |
| `down`, `up` | lines | | On the last line, and on the first. A count past the text stops at the last line and does not fail |
| `word-forward`, `bigword-forward` | exclusive | The last step stops where its line's content ends, and from an empty line it goes to the next line's start. For an operator that replaces, on a cell that is neither a blank (a space or a tab) nor a line break: the end of the word under the cursor, counted as the first, then `count - 1` word ends on, with reach `inclusive` | Never |
| `word-backward`, `bigword-backward` | exclusive | | When a step is asked of it at offset 0: when it starts there, and when it has come to rest on an empty first line with steps left over, which is a failure after the motion moved |
| `word-end`, `bigword-end` | inclusive | | Never |
| `line-start` | exclusive | | Never |
| `line-first-non-blank` | exclusive | On a line of blanks only, the line's last blank | Never |
| `line-end` | inclusive | | With a count above 1 on the last line |
| `first-line`, `last-line` | lines | | Never |

- **`cw` is `ce` with one difference**: on a word's last character `cw`
  changes that character, where `ce` goes on to the next word's end. On a
  blank `cw` is `dw`; on an empty line it changes the line. Whether the
  cursor is on a word's last cell is asked of the motions: it is when the
  next word's start is not after the next word's end.
- **`dw` on the last word of a line** takes the word and the blanks after
  it, and not the line break. **`dw` on an empty line deletes the line**:
  the last step goes to the next line's start, and R5 makes it that line.
- **The doubled operator** is the lines from the head's to `count - 1`
  lines below, stopped at the last line.
- **On the last line with a count above 1 the doubled operator gives up**
  (`Evil.noLineBelow`), as Vim cancels it: `2dd`, `2cc`, `2yy`, `d2d` and
  a `dd` replayed there with a count take nothing, leave the register,
  begin no insert and are not the last change.
  - Vim's doubled operator goes down `count - 1` lines first, and going
    down fails on the last line. That is the rule of `j` under an operator
    with a count one less, and `d2$` gives up there for the same reason.
  - It holds in a text of one line and in the empty text, whose one line
    is the last. A count of 1 never fails.
  - Run through Vim 9.1 by hand, outside the suite, when the rule was
    built (`evilOperatorChecks`, `evilRepeatChecks`).
- **A selection** is what it covers: a selection of the line shape is the
  lines of its two ends; any other is what the text port says its range
  covers (`TextId.extents`), with R4 applied and R5 and R6 not, as Vim
  applies neither in Visual mode. A count is ignored.
- **Rows are asked in cells**, and line starts, line ends and cells of the
  motion primitives, so a carriage return and line feed is one line break
  throughout.
- **Set aside: clamping inside the motion.** The move command needs the
  raw target unchanged, and R4 to R6 need both ends.

**What `d`, `c` and `y` do with a stretch** (the three operators' `act`):

| | Cells that are not empty | No cell | Lines |
|---|---|---|---|
| **`d`** | The register is the cells' text. They are deleted. The cursor goes to their start, rested | Nothing is done, and the register is as it was | The register is the lines, line-wise. They are deleted. The cursor goes to the first non-blank of the line now where the first was, or of the last line when there is none |
| **`y`** | The register is the cells' text. The cursor goes to their start, rested | The register is the empty text. The cursor stays | The register is the lines, line-wise. The cursor goes to the operand's `rest`, rested |
| **`c`** | The register is the cells' text. They are deleted. The selection is a bar at their start | Nothing is deleted. The register is as it was, unless the reach is `inclusive`, when it is the empty text. The selection is a bar at the head | The register is the lines, line-wise. The text from the first line's start to where the last line's content ends is deleted, so one line break stays. The selection is a bar at that line's start |

**What `=` does** (`Evil.indent`, the operator `indent`; pinned by
`evilIndentChecks` on the models and `ConfigTest.indentChecks` over the
library's Rust grammar):

- **It acts on whole rows**, as Vim's `=` does: lines from `==` (with a
  count), a linewise motion (`=j`, `=G`, `gg=G`) or `V`; and for cells,
  from a charwise motion, a text object (`=af`) or `v`, the rows of the
  first cell through the last, or the first cell's row for an empty
  stretch.
- **Each row's leading whitespace becomes its level in the buffer's indent
  unit** (`TextId.reindentEdits`, `Indent.reindent`, `lean/Editor/Indent.lean`):
  a blank row's becomes nothing, as Vim's `=` and rustfmt leave one; a row
  whose level is none, inside a multi-line string or block comment, keeps
  its own; a row already right is not touched. The unit is the buffer's
  language's (`Target.indentUnit`, through `indentUnitOf`, "Languages and
  the code mode").
- **One edit, one undo step.** Every row's edit is one transaction that
  carries the selection from before the command
  (`Target.replaceEachCarrying`), so one `u` gives back the text and the
  cursor. With no edit there is no transaction, and only the cursor moves.
- **The cursor** goes to the first non-blank of the first row, rested, as
  Vim's `op_reindent` leaves it. The window keeps no wanted column.
- **No register** is read or written; a register named before `=` is
  taken and ignored, as in Vim.
- **`.` replays it** over the same rows from the cursor, its count
  replaced by one typed before `.`; over a visual selection it is not
  repeated (`notRepeated overSelection`), as for any operator.
- **With no levels to read it gives up** (`Evil.cannotIndent`), having
  changed nothing, and is not the last change: a buffer with no syntax
  tree (`indent: this buffer has no syntax tree`), a tree that keeps no
  indents query (`indent: its language has no indents query`, JSON,
  Markdown, TOML and Lean today), or a text whose last edit's tree is not delivered yet
  (`indent: the syntax tree is not parsed yet`).
- **A recorded departure**: Vim's own `=` reads `indentexpr` or `cindent`;
  ours reads the language's indents query, so its levels are the query's.

- **The empty-stretch column is Vim's**, quirks included: `yh` at a line's
  start empties the register, `dh` leaves it, and `c$` on an empty line
  empties it where `ch` and `cl` do not.
- **In an empty text `d` and `c` do nothing to the text or the register**
  (`c` still begins an insert), and `yy` there yanks one line break,
  line-wise.
- **`rest`** is the lower of the head and the motion's target for a motion
  (so `yk` and `ygg` move the cursor up and `yj` and `yG` leave it), the
  head for the doubled operator, and for a selection the stretch's start
  for cells; for lines, the start of the anchor's line when the head is
  not before the anchor, and the head otherwise.
- **A line-wise register's text** is the lines from the first line's start
  through the last line's line break, and the buffer's line ending is
  added when the last line has none.
- **The window keeps no wanted column after an operator.**
- **`c` begins an insert only when a key that enters insert state runs
  it.** It leaves one range of the shape its call's report says. Run by
  its name in normal state it deletes and the cursor rests there.

**The text's last line.** A text that ends in a line feed has an empty
last row, which is no line ("Where a cursor rests"). Three consequences,
each with one rule:

- **Cells never take the last line's line feed** (R4). Without it `de` on
  the last word of `ab⏎` would leave `a` with no final line feed.
- **A line-wise deletion leaves the text ending the way it ended.** The
  lines go from the first line's start through the last line's line
  break. When the last of them is the text's last line and has no line
  break, the line break before the first goes instead, so `dd` on the
  last line of `a⏎b` leaves `a`, and on `a⏎b⏎` leaves `a⏎`. Deleting
  every line leaves the empty text.
- **A put below the last line of a text with no final line feed** puts the
  buffer's line ending and then the register's lines without their last
  line break, so `yyp` on `ab` leaves `ab⏎ab`. The line break left out is
  the whole one, a carriage return and line feed included, and the one put
  first is the buffer's: both are pinned on a buffer whose lines end in a
  carriage return and line feed, for the unnamed register and for a text
  read from the clipboard.

**A motion that fails cancels the operator** (`Evil.cannotMove`). Vim
cancels the operator: nothing is deleted or yanked, the register is as it
was, `c` begins no insert, the edit is not what `.` repeats, and the
cursor is where the motion got to. Here, either way, the scheme goes back
to its state at rest, so the view is not in insert state and the last
change is what it was ([concurrency.md](concurrency.md), "Foreground:
commands"):

- **Where the motion did not move, the command gives up** and the loop
  rolls it back: `dj` on the last line, `dk` on the first, `d2$` on the
  last line, `db` at the text's start.
- **Where the motion moved before it failed, the command places the
  cursor and breaks off**, which rolls nothing back. A counted `b` or `B`
  that comes to rest on an empty first line with steps left over fails
  there, and Vim leaves the cursor on that line: `d3b` on the `c` of
  `⏎ab cd` leaves the cursor on the empty first line and the text and the
  register as they were. The cursor is one range of the shape the
  selection had before the command, rested as normal state rests one, and
  the window keeps no wanted column. They are the only motions that ship
  that fail after moving. A replayed change breaks its replay off the
  same way ("The last change").
- **What does not fail**, as in Vim: `dh` at a line's start, `dl` on an
  empty line, `d0` and `d^` where the cursor is, and `dw` and `de` at the
  text's end take no cell or the last cell. With a count they cannot go
  the whole way of, `w W e E` take what there is, `h` and `l` the cells
  the line has, `j` and `k` stop at the last line and at the first, and
  `$` at the last line's end.
- **How it was verified.** The rows of `b B` that fail after moving, of
  each other motion with a count past what the text has, and of `.` after
  a cancelled operator were run through Vim 9.1 by hand, outside the
  suite, when the review of the phase was answered; the editor's results
  for the same rows are pinned by `evilOperatorChecks` and
  `evilRepeatChecks`.

**`x`, `p`, `P`.**

- **`x` is `dl`** (`Evil.deleteChar`): the operate command's own path,
  with the operator `delete` over the motion `right`, the call's count and
  register. It has no rule of its own.
- **`p` and `P` put a register** (`Evil.put`): the unnamed one, or the
  clipboard's text ("Registers"). Char-wise, `P` inserts at the head and
  `p` after the cursor's cell, or at the head on an empty line; the
  cursor goes to the last cell put when the text holds no line break, and
  to the first cell put when it holds one. Line-wise, `P` inserts the
  lines at the start of the cursor's line and `p` at the start of the
  next; the cursor goes to the first non-blank of the first line put.
  The text is put `count` times. A register that holds nothing, a
  clipboard that holds no text and one that is refused each give the
  command up. A put in place of a visual selection is the operator
  `replace`, which the Edit menu's Paste runs there: it fetches the
  register first, puts its text in place of the selection, and sets the
  unnamed register to the replaced text without `store`, so that text
  never reaches the clipboard. The visual tables do not bind `p` and `P`
  to it. A line-wise text put in place of a character-wise selection goes
  in as it is, where Vim would split the line.

**Departures from Vim that the checks name**, beside those of "Motions as
built":

- **A cursor cannot rest in the empty last row** ("Where a cursor rests"):
  after cells of a last line with no final line feed are emptied, and
  after `o` and escape there.
- **A count before `o` and `O` is ignored**, as one before `i a I A` is.
- **What `u` does to the cursor** ("Undo and redo").
- **A change over a visual selection is not repeated** ("The last
  change").

### Undo and redo

Status: built, by the command loop's phase 13
(`lean/Editor/Evil/Undo.lean`, `Target.replaceCarrying` in
`lean/Editor/Api.lean`; pinned by `evilUndoChecks`, and the API's
operation by a case of `lean/Editor/Api/Cases.lean`).

- **Every edit of evil's carries the selection from before the command.**
  One primitive, `Target.replaceCarrying extent s before after`: one
  transaction by the user that replaces one extent and carries both
  selections. `before` is the selection as it was when the command was
  called, read once from the window's marker, and not a bar the command
  has since placed. `after` is where the command leaves the cursor,
  before it is rested, in the shape of the call's report; a transaction
  carries it, so it is worked out before the edit.
- **`u`** (`Evil.undo`) undoes up to `count` steps of the buffer's
  history and stops at the first that finds nothing. It then places one
  range of the report's shape on the head of the selection the last step
  handed back, rested by the report's rule. So it restores the text and
  the cursor from before the change.
- **`C-r`** (`Evil.redo`) redoes the same way, and places what is handed
  back by the entering rule ("Vim states"): a selection handed back in
  the exclusive shape, which is the bar an insert session ended with,
  steps back one cell on its line before it rests, as escape does. So
  `C-r` after an undone `cw`, text and escape leaves the cursor where
  escape left it.
- **Why an undo does not step back.** The selection before a step that
  began in insert state is the bar the insert began at, and the cell
  after that bar is the one the cursor was on.
- **One step is what the loop closed**: a command in normal state, and a
  whole insert session ("Insert sessions"). With no step to take the
  command says so in the echo area and changes nothing.
- **A step whose edits carried no selection** hands none back, and the
  cursor rests where the window's marker is.
- **The window keeps no wanted column** after either.
- **This is the phase's rule and not Vim's.** Vim leaves the cursor at the
  start of the changed text (`ddu` from the middle of a line leaves it in
  column 0). The checks of `u` are not compared with Vim.
- **Proved on the text model**: `x` then `u` restores the text
  ("Theorems").

### Scrolling as built

Status: built, by the command loop's phase 15
(`lean/Editor/Evil/Scroll.lean`, over the policy in
`lean/Editor/Scroll.lean` and `Target.anchor`, `Target.scrollTo` and
`Target.onArea` in `lean/Editor/Api.lean`; pinned by `viewChecks` and
`scrollChecks`, by three cases of `lean/Editor/Api/Cases.lean`, and by the
headless fixture `tests/headless/view`). How a view follows its cursor
between commands is the loop's
([text-and-display.md](text-and-display.md), "Views as built").

Everything here is tested on the display model, which lays text out in
cells of one size, and, since the display pipeline's last phase, once over
real layout: the milestone fixture (`tests/headless/milestone`) runs `C-f`
over the library's layout in cells and checks that the rows the loop asked
for are the rows of the frame drawn (`agree`). A view is asked about with
its height less its bottom row, as tall as the display answers
(`EditorState.bottomRow`).

- **`C-d` and `C-u`** (`Evil.scroll .half`) move the view's scroll anchor
  and its cursor by the same number of visual rows.
  - **How many**: the count, when one was typed; otherwise half the rows
    the view fits, and at least one.
  - **The anchor going down** moves that many rows, and no further than
    where the text's last row is the last row shown; it never moves up.
    **Going up** it stops at the text's first row.
  - **The cursor** moves that many rows and keeps its x
    (`Display.linesFrom` with no goal), stops at the text's first and last
    row, and is rested by the rule of the view's state ("Where a cursor
    rests"), as a motion's target is. In a visual state the selection's
    other end stays, so the key extends the selection. The window then
    keeps no wanted column.
  - **In a text that ends in a line feed** the display lays out an empty
    row after the last line. A cursor the move leaves there, in a state
    where no cursor rests there, goes one row back up at the same x. So
    the cursor ends on the last line in its column, and the empty row is
    the last row shown.
  - **At the text's end** `C-d` moves the anchor until the text's last row
    is the last row shown, then the cursor alone, until it is on the last
    line. There it changes nothing and says nothing. `C-u` at the start is
    the same, upwards.
- **`C-f` and `C-b`** (`Evil.scroll .page`) are the same command with the
  rows the view fits, times the count when one was typed.
- **`z t`, `z z` and `z b`** (`Evil.scrollLineTo`) place the anchor so that
  the cursor's row is the first row shown, the middle one or the last, and
  change nothing else: not the text, the selection or the wanted column.
  - **The middle** is the middle row of those the view fits, the upper of
    two when it fits an even number.
  - **In a view that shows its whole text `z z` shows it from its first
    row**, wherever the cursor is: no row that fits is scrolled out of
    sight. `z b` does the same there, and `z t` shows from the cursor's
    row.
  - They ignore their count and their register.
  - **At the text's start** the anchor stops at the first row, so a cursor
    near the start cannot be put in the middle or at the bottom. **At its
    end** `z t` and `z z` show past the text's end.
  - They work from the rows the view fits, not the rows it shows, so `G`,
    `z t`, `z b` comes back to the view `G` left.
- **After each the cursor is among the rows shown**: where the anchor and
  the cursor did not move the same rows, the loop's follow holds it at the
  next scene.
- **None reads the scroll margin.** The follow at the next scene applies
  it, so `z t` with a margin of two leaves two rows above the cursor's
  row.
- **A view that shows no row is left alone**: the seven change nothing and
  say nothing. That is every headless run that does not resize its frame.
- **They are commands and not motions**, so an operator's key before one
  is dropped: `d C-d` deletes nothing. They change no text, so none is the
  last change and `.` does not replay one.
- **A command that does not run to its end leaves the anchor and the
  selection as they were**: the loop keeps and restores both markers. One
  that is interrupted leaves the snapshot it took of its text
  (`Target.onArea`).

Where this departs from Vim. The Vim column is its documentation
(`scroll.txt`, `'scroll'`, `'scrolloff'`, `'startofline'`) as remembered:
it was not read again for this, and no check runs Vim.

| | Vim | Here |
|---|---|---|
| The unit of `C-d`, `C-u`, `C-f`, `C-b` | Lines of the buffer | Visual rows, so a wrapped line is scrolled through row by row |
| A count before `C-d` | Sets the `scroll` option, which later `C-d` and `C-u` use | Is the rows of this one command |
| The column after `C-d` | The first non-blank, under `startofline`, which Vim sets and Neovim does not | Kept, as Neovim's default |
| `C-d` on the last line, `C-u` on the first | Beeps | Nothing |
| A text shorter than its view | Moves the cursor half the window's height | Half the text's rows: how many rows fit a view that is not full is not asked |
| A text that ends in a line feed | No row after the last line | The empty row the display lays out after it is the last row shown |
| `C-f` and `C-b` | Keep two lines of the page before in view and put the cursor on the new page's first line | The anchor moves a whole view and the cursor keeps its row of the view |
| A count before `z t`, `z z`, `z b` | A line number | Ignored |
| After a far jump | Centres the cursor's line | The least movement: the cursor is at the edge it came in by |

Not built: `C-e` and `C-y`; `z<CR>`, `z.` and `z-`; `H`, `M` and `L`; `gj`
and `gk`; the mouse wheel; smooth scrolling; `scrolljump` and `sidescroll`.

### Default bindings

`Vim.Default` holds the scheme's default keys as data: tables of key string
and `Bound`, the keymaps made from them, the five state records, and
`Vim.Default.scheme`, the scheme that ships. The root module imports it, so
config sees `Vim.Bound`. The grammar's module names no key.

The names in the tables are the vocabulary names and command names that
the motions, operators and commands are registered under. A name is
changed in its row and in its registration together. No grammar check names
a default, so renaming one breaks none.

Which names have something behind them:

| Names | State |
|---|---|
| The twenty-eight motions of `motions` | Built: entries of `Evil.motions`, run by the command `move`. One check presses every key of the table and holds that none says `no such motion`, without restating either table |
| `insert`, `append`, `insert-line-start`, `append-line-end`; `visual`, `visual-line`; `normal` | Built and registered (`Evil.commands`) |
| `self-insert`, which no table names: typed text | Built and registered |
| `minibuffer-accept`, `minibuffer-cancel`, `minibuffer-next`, `minibuffer-previous`, `minibuffer-delete-backward`, `minibuffer-delete-to-start` | Built and registered (`Minibuffer.commands`) |
| `insert-delete-backward`, `insert-newline`, `insert-tab`, `insert-left`, `insert-right`, `insert-up`, `insert-down` | Built and registered (`Evil.commands`; "Insert state") |
| The operators (`delete`, `change`, `yank`, `indent`, bound to `d`, `c`, `y` and `=`) | Built: entries of `Evil.operators`, run by the command `operate`, which is registered (`Evil.commands`) |
| The twenty-two text objects of `objects` | Built: entries of `Evil.objects`, Vim's sixteen and the syntax tree's six, run by the command `operate` after an operator and by `select-object` in a visual state, both registered (`Evil.commands`; "Text objects as built") |
| `open-below`, `open-above`, `delete-char`, `put-after`, `put-before`, `undo`, `redo` | Built and registered (`Evil.commands`) |
| `repeat`, which no table names: the repeat key's invocation | Built and registered |
| The register prefix's registers | The unnamed register and the clipboard's (`+`) are built; any other name gives the command up |
| `ex` | Built and registered (`Ex.commands`): `:` opens the ex command line ("The ex command line"). The key hands the command a count and a register, which it does not read |
| `keyboard-quit` | Built and registered (`Shell.commands`): `C-g` in normal state cancels the `:!` or filter running in the focused buffer's workspace, and says `<line>: interrupted`, or `Quit` with nothing running ("The ex command line"). `C-g` is also the interrupt key, which lowers the flag before the key is stepped ([concurrency.md](concurrency.md), "Interrupt") |
| `scroll-down`, `scroll-up`, `scroll-page-down`, `scroll-page-up`; `scroll-line-to-top`, `scroll-line-to-center`, `scroll-line-to-bottom` | Built and registered (`Evil.commands`; "Scrolling as built"). The names are evil's own for these commands, without its prefix |
| `clipboard-cut`, `clipboard-copy`, `clipboard-paste`, `select-all`, which the run tables name and the Edit menu's items and `s-x`, `s-c`, `s-v`, `s-a` run | Built and registered (`Evil.commands`, `lean/Editor/Evil/Clipboard.lean`); the operator `replace`, which `visualRuns` names, is an entry of `Evil.operators` that no key binds |

| Table | Keys |
|---|---|
| `motions` | `h` left, `j` down, `k` up, `l` right, `w` word-forward, `b` word-backward, `e` word-end, `W` bigword-forward, `B` bigword-backward, `E` bigword-end, `0` line-start, `^` line-first-non-blank, `$` line-end, `g g` first-line, `G` last-line; `f` find-forward, `F` find-backward, `t` till-forward, `T` till-backward, each a motion that takes the character the next key names (`Bound.charMotion`); `;` find-again, `,` find-again-reverse; `n` search-next, `N` search-previous, `*` word-search-forward, `#` word-search-backward, `%` matching-bracket |
| `objects` | `i w` inner-word, `a w` a-word, `i W` inner-bigword, `a W` a-bigword, `i "` `a "`, `i '` `a '`, `` i ` `` `` a ` `` the quote objects, `i (` `i )` `i b` inner-paren, `a (` `a )` `a b` a-paren, `i [` `i ]` inner-bracket, `a [` `a ]` a-bracket, `i {` `i }` `i B` inner-brace, `a {` `a }` `a B` a-brace, `a f` a-function, `i f` inner-function, `a c` a-class, `i c` inner-class, `a a` an-argument, `i a` inner-argument: in normal state's pending keymaps, read only while an operator waits, and in both visual states' keymaps |
| `operators` | `d` delete, `c` change (enters insert), `y` yank (changes no text) |
| `normalCommands` | `i` insert, `a` append, `I` insert-line-start, `A` append-line-end, `o` open-below, `O` open-above (each enters insert and changes text); `x` delete-char, `p` put-after, `P` put-before (each changes text); `u` undo, `C-r` redo, `:` ex, `C-g` keyboard-quit; `.` the repeat key, a part of speech of its own (`Bound.repeat`); `v` visual, `V` visual-line (each enters that state); `"` the register prefix |
| `insertCommands` | `<Escape>` normal (enters normal); `<Backspace>` insert-delete-backward, `RET` insert-newline, `TAB` insert-tab, `<ArrowLeft>` insert-left, `<ArrowRight>` insert-right, `<ArrowUp>` insert-up, `<ArrowDown>` insert-down (each enters no state, and none is a change dot repeat replays) |
| `visualCommands` | `<Escape>` and `v` normal, `V` visual-line, `"` |
| `visualLineCommands` | `<Escape>` and `V` normal, `v` visual, `"` |
| `minibufferCommands` | `RET` minibuffer-accept, `<Escape>` minibuffer-cancel, `TAB` and `C-n` minibuffer-next, `S-TAB` and `C-p` minibuffer-previous, `<Backspace>` minibuffer-delete-backward, which deletes the character before the bar and, on an empty minibuffer, cancels the prompt as Vim's `<BS>` does, `C-u` minibuffer-delete-to-start, which deletes from the bar to the input's start (each enters no state, and none is a change dot repeat replays); `<ArrowLeft>` the motion left, `<ArrowRight>` the motion right |
| `scrollCommands` | `C-d` scroll-down, `C-u` scroll-up, `C-f` scroll-page-down, `C-b` scroll-page-up, `z t` scroll-line-to-top, `z z` scroll-line-to-center, `z b` scroll-line-to-bottom (each changes no text and enters no state) |

The run tables (`StateRecord.runs`), which say what a command name is
completed as in a state, for a key bound to the name and a menu item that
names it ("So a command enters no state: a key does"):

| Table | Runs |
|---|---|
| `normalRuns` | `clipboard-paste` as `"+P`; `select-all` as itself, entering `visual-line` |
| `insertRuns` | `select-all` as in normal state |
| `visualRuns`, of both visual states | `clipboard-copy` as `"+y`, `clipboard-cut` as `"+d`, `clipboard-paste` as the operator `replace` from `+`, each over the selection, and `select-all` as in normal state |

| State | Keymaps, in precedence order | Cursor | Selection | The grammar reads |
|---|---|---|---|---|
| `normal`, the initial state | `normalCommands`, `scrollCommands`, `operators`, `motions` | Block | Inclusive | |
| `insert` | `insertCommands` | Bar | Exclusive | Typing is text |
| `visual` | `visualCommands`, `scrollCommands`, `operators`, `motions` | Block | Inclusive | Operators act on the selection |
| `visual-line` | `visualLineCommands`, `scrollCommands`, `operators`, `motions` | Block | Line | Operators act on the selection |
| `minibuffer`, the state of the minibuffer's view | `minibufferCommands` | Bar | Exclusive | Typing is text |

**The scroll keys are in normal state and the two visual states**, and not
in `insert` or `minibuffer`: there `C-d` and `C-u` are Vim's editing keys,
and `z` is text. `C-u` is built in `minibuffer`, where it deletes to the
input's start; `C-d` is built in neither, nor `C-u` in `insert`. `z` begins three sequences and is
bound to nothing itself, so in those three states it is a prefix: a `z`
followed by a key that completes none of them runs nothing. None of the
four control keys is the interrupt key, `C-g`, which normal state binds
to `keyboard-quit`.

No key enters `minibuffer`: the registry names it as the state of the
minibuffer's view (`states.minibuffer`), and the scheme puts a view in it
when it is told the view is the minibuffer's ("The minibuffer", under
Modes, which says why it is a state of its own and why its two keys are in
its table).

A key string in a table that `Key.parse` refuses binds nothing, which a
check catches: each table's keymap has as many bindings as the table has
rows.

`Vim.Default` also holds the role table (`roles`), the leader (`leader`,
`\`) and the hand-tuned keys (`tuned`, empty), as key strings (the table
under "Roles"). A role whose string is refused is on no key, which the
scheme contract reports.

## Other schemes

| Scheme | `Binding` | `State` |
|---|---|---|
| Vim | `Vim.Bound`: a part of speech, or the register prefix | Each view's Vim state, the keys typed, the count, the register, the pending operator, the prefix, the last change |
| Emacs-style | `Command` | Prefix, universal argument |
| Selection-first (Kakoune, Helix) | `Command` | Count, prefix |
| CUA | `Command` | None |

Only the Vim scheme ships. A trivial second scheme, the test scheme, is
published for tests to keep the interface honest (see "The test scheme"
and Testing).

## Modes

Status: built (`lean/Editor/Role.lean`, `lean/Editor/Mode.lean`, the
registry's modes in `lean/Editor/Config/Registry.lean`, a buffer's modes in
`lean/Editor/State.lean`; the module docs have the detail). Three modes
ship: the minibuffer's ("The minibuffer"), `compilation` ("The compile
mode, as built") and `code` ("Languages and the code mode").

A mode is a value in a registry keyed by name. It is not a type class,
because instances resolve at elaboration time and the active mode is chosen
at runtime. It is not a closed inductive, because config must be able to
add modes.

```lean
structure Mode where
  name       : String
  parent     : Option String := none                -- derived modes
  roles      : List (Role × String) := []           -- role, command name
  locals     : List (String × String) := []         -- suffix as a key string, command name
  syntaxTree : Option Mode.SyntaxTree := none       -- how its text is parsed and drawn
  syntaxTreeOfLanguage : Bool := false              -- or as its buffer's language says
  onEnter    : ViewId → EditorM Unit := fun _ => pure ()

structure Mode.SyntaxTree where
  grammar     : String                               -- the library's grammar: rust, json, markdown, toml, lean
  highlights  : Option String := none                -- query source; none: the grammar's shipped one
  captures    : List (String × Option FaceName) := [] -- config's capture faces, over the shipped default
  injections  : Option String := none                -- injections query source; none: the shipped one
  textObjects : Option String := none                -- text objects query source; none: the shipped one
  indents     : Option String := none                -- indents query source; none: the shipped one
```

- **`syntaxTree` says how the mode's text is parsed and drawn**: a grammar
  of the library's syntax service, the highlights query's source (none for
  the one the grammar ships), config's mapping of capture names to faces
  over the shipped default (`lean/Editor/Highlight.lean`), and the sources
  of the injections, text objects and indents queries, each none for the
  grammar's shipped one; an empty source captures nothing, which turns that
  part off. It is not
  called `syntax`, which is a keyword of Lean's. A derived mode with none
  takes the nearest of its lineage (`Mode.syntaxTreeOf`). Config writes it
  in `defineMode`; there is no other registry API.
- **`syntaxTreeOfLanguage` takes the tree of the buffer's language** in
  place of one of the mode's own: the `code` mode's ("Languages and the
  code mode"). In a lineage the nearest mode that has its own tree, or
  takes the language's and the buffer has one, says.

No `Key` for a top-level binding and no scheme's `Binding` type appears in
`Mode`. A mode cannot name the binding type of a scheme it has never heard
of, and it does not need to.

- **Commands are named by `String`**, as everywhere in the registry: a
  role's command and a suffix's are looked up when the key runs.
- **A suffix is a key string**, as every binding table in the repository
  is (`bindKey`, `Vim.Default`), so a suffix written twice is visible (a
  `Keymap` would merge it), and suffixes are compared as parsed chords
  (`TAB` and `<Tab>` are one suffix). A string can fail to parse, so
  `Mode.check` reports an unreadable suffix too.
- **The owner is on the registry entry** (`Config.ModeEntry { owner, mode
  }`), as for commands, jobs and key bindings, not on the record: `setup`
  cannot choose its owner, and a reload replaces an owner's modes
  (`Registry.replaceModes`).
- **`setup` refuses** a mode name defined twice, and a mode with a problem
  that needs no scheme (an unregistered role, a suffix used twice, an
  unreadable suffix), with a message naming the mode and the problem: the
  same rule as a key sequence bound twice. Shadowing needs a scheme, which
  the registry does not know, so only `Mode.check` reports it.

### How a mode declares keys

| What the mode needs | How it is declared | Cost per scheme |
|---|---|---|
| Text editing in its buffers | Vocabulary only: motions and text objects. The scheme's grammar does the rest | None |
| Standard actions: next and previous item, activate, quit, refresh, toggle, mark | The mode fills named **roles**. Each scheme maps roles to keys once | One table per scheme |
| Mode-specific commands | The mode picks a mnemonic suffix. The scheme supplies the prefix (`<localleader>` in Vim) | None |
| Hand-tuned top-level keys | Written against one scheme's binding type, in that scheme's own table | Per mode and per scheme, opt-in |

- **Roles** are registered names, an open set curated by the core.
- **Hand-tuned keys** live in the scheme, not in the mode record. The
  standard library writes them for Vim only.

### Roles

Built (`Role.registered`; the tables are `TestScheme.roles` and
`Vim.Default.roles`, with the leaders beside them).

**The starting set** is seven roles, the ones the table above names:
`next-item`, `previous-item`, `activate`, `quit`, `refresh`, `toggle` and
`mark`. They are the actions list-like special buffers share (what
evil-collection rebinds most), and no other action has two unrelated users
yet.

**The rule for adding a role.** A role is a standard action that recurs,
with one meaning, in modes that have nothing else in common. An action of
one mode, or of one family of related modes, is a leader suffix (or lives
on a parent mode). Roles are curated by the core: config cannot add one,
and a mode that names a role that is not registered is reported by
`Mode.check` and refused by `setup`. Adding a role is one core commit: its
name in `Role.registered`, and a row in the role table of every scheme in
the repository (the Vim scheme's and the test scheme's). The scheme
contract fails a scheme without the row. Renaming or removing a role
changes every mode that fills it.

- **A role is a name** (`structure Role where name : String`), with a
  constant for each registered role and `Role.registered`. The set is open
  to the core, and a mode may name a role that is not registered, which
  `Mode.check` must be able to report; a closed inductive could not
  represent that mistake.
- **Each scheme's role table and leader are fields of `InputScheme`**
  (`roles : List (Role × List Key)`, `leader : List Key`), so the scheme
  contract and a mode's keymaps read them without knowing the scheme.

| Role | Test scheme | Vim scheme |
|---|---|---|
| `next-item` | `C-n` | `j` |
| `previous-item` | `C-p` | `k` |
| `activate` | `RET` | `RET` |
| `quit` | `C-q` | `q` |
| `refresh` | `<F5>` | `g r` |
| `toggle` | `TAB` | `TAB` |
| `mark` | `C-SPC` | `m` |
| **leader** | `C-c` | `\` |

- **The test scheme's keys print nothing**, so none is ever a self-insert,
  and `C-c` is Emacs's prefix for a mode's keys.
- **The Vim scheme's are evil-collection's usual keys for list buffers.**
  `j` and `k` replace the motions only in buffers whose modes fill those
  roles, which is the design's intent; `g r` merges with the `g g` prefix;
  `\` is Vim's own default `maplocalleader`, and begins no binding of any
  default state, so a suffix under it reaches nothing of the scheme's.
- **The scheme contract has three properties for modes**: every registered role has
  a key (`everyRoleHasKey`); the leader is not empty, no two roles share a
  key sequence, and no role's keys begin with the leader or are a prefix of
  it (`leaderAndRolesApart`), since a role key that collided with a leader
  suffix would make one of them unreachable, which no check of one mode can
  see; and the key bound to what the scheme says a mode's key is bound to
  (`modeCommand`) of a name yields an invocation of that name and leaves
  nothing pending (`modeCommandRuns`), as `namedCommandRuns` does for
  `command`.

**A mode's keymaps** (`Mode.keymaps scheme mode`). A mode makes, for a
scheme, a keymap of its hand-tuned keys (below), then one of its roles and
suffixes: each role it fills bound at the scheme's key for the role, and
each suffix bound at the scheme's leader followed by the suffix, each to
`scheme.modeCommand` of the command's name. A role the scheme's table
lacks, and an unreadable suffix, bind nothing.

### Hand-tuned keys

Built (`InputScheme.tuned`, `InputScheme.defaults`, `Mode.check`). A
hand-tuned key is an entry of a scheme's own table
(`InputScheme.tuned`: a mode's name, a key sequence, and a binding of the
scheme's type), beside the scheme's own keymaps (`InputScheme.defaults`;
the Vim scheme's are every state's keymaps). A mode's tuned entries are a
keymap consulted with the mode, ahead of its roles and suffixes, so one
wins over a role on the same key.

- **A tuned key shadows a scheme binding** when the scheme's own keymaps
  bind exactly the same sequence (`Keymap.resolve scheme.defaults keys` is
  bound). `Mode.check` reports it. A tuned key that is a strict prefix of a
  default stays under the open question "Unreachable bindings".
- **The Vim scheme's table is empty** (`Vim.Default.tuned`): the one mode
  that ships, the minibuffer's, has its keys in the Vim state of its view.
  The Vim scheme wraps each tuned binding in `Bound.mode`.

### A buffer's modes

Built (`EditorState.setMajorMode`, `addMinorMode`, `removeMinorMode`; the
requests over them, `lean/Editor/State/Request.lean`; and the operations a
command calls, `ViewId.setMajorMode`, `BufferId.addMinorMode` and
`BufferId.removeMinorMode`, `lean/Editor/Api.lean`). A buffer has one major
mode, or none (`Buffer.major : Option String`), and minor modes
(`Buffer.minors`, the one added last first). They are names: a buffer can
hold a name no registered mode has (a reload may drop it), which
contributes nothing.

- **Pure state operations** set the major mode and add or remove a minor
  mode, shaped like `removeWindow`. Setting the major mode says whether the
  mode became the major mode; it did not when the buffer already had it.
  Adding a minor mode already there, and removing one not there, change
  nothing.
- **A command sets a mode by a request.** The request names the mode: it
  is plain data, and cannot hold the mode or its `onEnter`, which is a
  program over the port the request belongs to. So the loop that runs the
  command answers it with what it is told of the registry
  (`Loop.Registered`, made by the host from the registry as it is at that
  step; `lean/Editor/Command/Dispatch.lean`).
- **`onEnter` runs when a mode becomes a buffer's major mode**, with the
  view it was set through, once, inside the command that asked. Setting the
  major mode the buffer already has changes nothing and runs nothing. For a
  derived mode the actions of its lineage run root first, each once, as
  Emacs's derived modes run their parent's body first. Setting a name no
  registered mode has is refused (`noSuchMode`), after a view with no
  window (`noSuchWindow`), each with nothing changed and nothing run; the
  pure operation takes any name and refuses only a buffer there is none of
  (`noSuchBuffer`).
- **An on-enter action is part of the command.** Its program is put before
  the rest of the command's, so its requests are guarded against the
  interrupt and rolled back with the command, and its own state requests
  are answered from the state the command had reached, in which the mode
  is already the buffer's. An action that is refused refuses the command.
  Phase 7 ran the actions from a registry operation that was handed the
  state and handed it back; that operation is gone, because an action's
  own state requests would have been answered from a state it could not
  see.
- **A major mode with a syntax tree is highlighted.** When the mode that
  became the major mode, or the nearest of its lineage, has a syntax tree,
  the loop runs `Highlight.enter` before the on-enter actions, inside the
  command: with a snapshot of the buffer's text it attaches the text with
  the grammar, compiles the query (the mode's own or the grammar's shipped
  highlights), and has the library draw the text with each capture in the
  face `Highlight.faceOf` gives (the capture's own entry, else its first
  component's, else none; config's mapping over the shipped
  `syntax.<capture>` default), then releases the query, which the library's
  highlighter keeps. A refusal of the syntax tree port is said in the echo
  area, ``highlights: `<mode>`: <refusal>``, and stops those steps: the
  mode is set and the command is not refused, so a query of config's that
  does not compile keeps no buffer out of its mode. The text is detached
  first, so it is drawn plain, as the echo area says: a refused attach
  replaces nothing, and an attach with the grammar the text already has
  keeps its highlighter, so without it the mode before would still be
  drawn. After highlights
  that succeeded, four more steps, each from the mode's own source or the
  grammar's shipped query, a grammar that ships none of a kind skipping its
  step: the text's injections (compiled, `inject`ed, released); a language
  for each grammar the library has (its highlights, the mode's own for its
  grammar, in the faces of the mode's mapping, so config's capture faces
  reach embedded code, and its injections; names are grammar names, an
  alias names nothing); and the text objects and indents queries, each kept
  as its kind (`keep`). A refusal in one of these stops that step alone and
  is said under the mode's name, ``injections: `<mode>`: …``,
  ``text objects: `<mode>`: …`` or ``indents: `<mode>`: …``; the
  highlights stay and the text is not detached. When a mode with no
  syntax tree replaces one with a syntax tree, the text is detached, which
  drops its highlights; when neither has one, the port is asked nothing.
  What the port did is not undone on rollback, as the clipboard is not.
- **The buffer's language is read too.** Both lineages, the old and the
  new, are read with the tree of the buffer's language
  (`Mode.syntaxTreeOf lineage language`, the entry looked up by the
  buffer's `language` in the loop's table), which a mode that takes the
  language's gives. Opening a file chooses its language and sets `code`
  ("Languages and the code mode").
- **Adding a minor mode runs no action** yet (left open).

Pinned by `ModelTest.modeEnterChecks`, through the loop,
`ModelTest.apiStateChecks`, and, for a syntax tree,
`ModelTest.highlightFaceChecks` and `ModelTest.highlightEnterChecks`, and
`ConfigTest`'s check that a job's command setting such a mode reaches the
host's syntax tree.

### Languages and the code mode

Status: built by `language-modes` phase 2 (`lean/Editor/Language.lean`;
the module docs have the detail). A buffer's language is chosen from its
file name, and one generic major mode, `code`, parses and draws its text
as the language says. There is no mode per language.

```lean
inductive Language.Pattern where
  | name (fileName : String)        -- the exact base name: Cargo.lock
  | extension (extension : String)  -- rs for *.rs

structure Language where
  name       : String                -- how a buffer records it, and how config overrides it
  patterns   : List Language.Pattern
  syntaxTree : Mode.SyntaxTree       -- a grammar and the overrides a mode takes
  indentUnit : Language.IndentUnit := .spaces 4  -- spaces n, or tab
```

`Language.IndentUnit` is a module of its own,
`lean/Editor/Language/IndentUnit.lean`, which imports nothing, so the state
requests can name it (`Language → Mode → Command → State.Request` would
otherwise be a cycle).

- **The shipped table** (`Language.shipped`) is `rust` (`*.rs`, four
  spaces), `json` (`*.json`, two), `markdown` (`*.md`, two), `toml`
  (`*.toml` and `Cargo.lock`, two) and `lean` (`*.lean`, `lakefile.lean`
  included, two), each parsed with the grammar of its name and its shipped
  queries. Each is a named definition, so config writes
  `{ Language.rust with … }`. `toml` draws its booleans, a capture the face
  vocabulary has no face for, as constants; a TOML file with another name
  (`uv.lock`) is one line of config. `lean` draws its booleans as
  constants, its characters as strings and its namespaces as modules, three
  captures the vocabulary has no face for.
- **The rule is pure and the core's** (`Language.forPath`). The table is in
  precedence order: config's entries, in the order config defined them,
  then the shipped ones config did not replace by name
  (`Language.over`; the registry's `languageTable`). The first entry with
  an exact base-name pattern of the path's base name wins; else the first
  with an extension pattern the base name ends in after a dot, with
  something before it; else none. So a base name beats an extension, and
  config's entry beats a shipped one of equal pattern. Patterns are typed
  and case-sensitive; one that is empty or holds `/` is refused by
  `setup`.
- **`code`** (`Language.codeMode`) has no tree of its own and
  `syntaxTreeOfLanguage` set, so highlighting, injections, text objects
  and indents come from the buffer's language. It fills no role and has no
  local command; a user's minor mode for a language is an ordinary minor
  mode.
- **A buffer records its language by name** (`Buffer.language`,
  `BufferId.setLanguage`), as it records its major mode: the entry is
  looked up in the loop's table when a mode is entered, so a reload's
  entry of that name is the one used next. An already-highlighted buffer
  is not highlighted again by a reload.
- **Opening a file** (`Files.takeIn`): once the new buffer is shown, the
  path's language is asked (`languageOf`, answered from the loop's table).
  For one, the buffer records it and is set to `code`, so the mode's entry
  attaches and highlights the text inside the open's command. For none,
  nothing is recorded and no mode is set, as before languages. A path a
  buffer already holds is shown and nothing is chosen again.
- **A config mode with its own tree wins when the user sets it**: it never
  looks at the language. One derived from `code` with no tree takes the
  language's.
- **A grammar loaded at run time** (deferred) would be a registration that
  makes a name known to the syntax service; entries name grammars and need
  no new field.
- **The indent unit is read by `=` and by the commands that open a
  line** (`Target.indentUnit`): the unit of the buffer's language's entry,
  which a command asks the loop for by name (`indentUnitOf`, answered from
  the loop's table, config's entry first), or four spaces
  (`Language.IndentUnit.default`) for a buffer with no language or one the
  table has no entry of, which covers a mode with its own tree and an
  indents query.
- Not built: setting a language on a buffer with no file by command;
  comment tokens; a formatter; indents queries for JSON, Markdown, TOML
  and Lean, whose buffers' `=` says there is none.

Pinned by `ModelTest.languageMatchChecks` (the rule and the table, pure),
`ModelTest.modeRecordChecks` (`code`'s tree), `ModelTest.languageOpenChecks`
(opening on the models, over the model's one grammar, `json`), and
`ConfigTest.languageChecks` (Rust, JSON, Markdown, TOML and Lean, a
`.toml` file and `Cargo.lock`, a `.lean` file and `lakefile.lean`, and
config's override of Rust's query, through the host and the real syntax
binding), and `ContractTest`'s checks that a TOML text is drawn by the real
display with its keys, string and brackets in their faces' colours, and a
Lean text with its keyword, string and comment in theirs.

### Why this shape

Emacs modes are written against Emacs keys, so Vim bindings are retrofitted
mode by mode; `evil-collection` is that retrofit, maintained by hand. Here
no mode is written against any scheme's keys, so there is nothing to
retrofit. Most of what the retrofit does (`j`, `k`, `RET` and `q` in
list-like buffers) is the roles row, which is one table.

Costs accepted:

- **Roles are a lowest common denominator.** A mode whose actions do not
  fit is pushed to leader keys, which are slower to type, or to hand-tuned
  keys.
- **Schemes other than Vim are second-class in special buffers.** They work
  through the first three rows and are less tailored until someone tunes
  them.
- **Authors must think in roles, not keys.** The types encourage this and
  cannot force it, since hand-tuned keys exist.

### Active keymaps

One pure function resolves what is active for a view, in precedence order:

```lean
def Config.Registry.activeMaps (registry : Registry) (scheme : InputScheme)
    (state : EditorState) (view : ViewId) : List (Keymap scheme.Binding)
-- minor modes, then the major mode, then global
```

As built. The global keymap is every owner's key bindings
(`Config.Registry.keymap`), oldest entry first, so of two owners that bind
one sequence the later wins. Under the Vim scheme the state's keymaps are
walked after the active ones ("Which keymaps a key is looked up in").

- **A mode's lineage** is the mode, then its parent, and so on, stopping at
  a name with no registered mode or one already in the lineage (so a cycle
  ends), bounded by the registry's size.
- **The keymaps of a mode** are, for each mode of its lineage, nearest
  first: its tuned keymap, then its role-and-suffix keymap. So a derived
  mode's own role wins, and a role it does not fill falls to its parent;
  the same for suffixes.
- **`activeMaps`** is each minor mode's keymaps, the minor added last
  first, then the major mode's, then the global keymap (every owner's key
  bindings). A view with no window has the global keymap alone.
- **The loop computes them from its own state.** The active keymaps depend
  on the buffers' modes, which only the loop's state holds, so the loop's
  `Keys.maps` is a function of the editor state and the view, which the
  loop applies to its own state (`Loop.key`), and the host supplies the
  registry's `activeMaps` for each event (`Headless.Running.keys`): a
  reload's modes and bindings hold from the next key.

### Per-mode state

Each mode wants state of its own type. Compiled modes use ordinary typed
fields. Modes defined in config use the store from
[lean-runtime.md](lean-runtime.md): a named cell with an encoding and a
version, which survives a reload that changes the type.

As built, with nothing new for it:

- **A compiled mode's state is a typed field** where the editor state's
  "Where a new field goes" table puts it (a field of `Buffer` for state of
  one buffer's mode, of `EditorState` for one per editor). The one mode
  that ships, the minibuffer's, keeps none of its own: the open prompt is
  a field of `EditorState`.
- **A config mode uses the store as built**: a `Store α` declared in the
  same `setup`, whose commands (`Store.command`) fill its roles and
  suffixes. Per-buffer state of a config mode is a buffer-local value
  (`BufferId.setValue`, `BufferId.value?`: a plain tree under a name, which
  a reload leaves where it is), or is kept inside its store's value.
  `ConfigTest.modeChecks` runs a config mode's role on a store command.
- **An `onEnter` is a plain `EditorM` program** and cannot write a store.
  It can set a buffer-local value, since that is a request of the editor's
  port.

### The minibuffer

**Where it is drawn** (since the display pipeline's last phase). The
minibuffer's place is the bottom leaf of the split tree, and always takes
the frame's bottom row, as tall as the display's `message` height: with no
prompt open the scene's echo is drawn there, and while a prompt is open
the place takes the input row above it too (`text + message`), the
minibuffer's view fills both, and the prompt replaces the message in the
bottom row. Opening a prompt clears the echo, as Vim does, so once the
prompt closes the row is empty until a command says something.

Status: decided 2026-11-14 and built, by the command loop's phase 10
(`lean/Editor/Minibuffer.lean` and `lean/Editor/Minibuffer/Compiled.lean`
for the mode and its commands; `lean/Editor/InputScheme.lean`,
`lean/Editor/InputScheme/Contract.lean` and `lean/Editor/Loop.lean` for
the notice; `lean/Editor/InputScheme/Vim.lean` and
`lean/Editor/InputScheme/Vim/Default.lean` for the Vim state; the module
docs have the detail). How a command waits for a prompt's answer, and what
accept and cancel do, is in [concurrency.md](concurrency.md), "Prompts".

While a prompt is open the minibuffer is a buffer shown in a window of its
own, and that window has the focus.

- **There is no second path for keys.** The loop steps every key for the
  focused view, and while a prompt is open that is the minibuffer's view.
  The active keymaps of that view are its buffer's modes' and then the
  global keymap ("Active keymaps"), as for any view.
- **"Its own keymap" is a compiled major mode**, `minibuffer`
  (`Minibuffer.mode`), which fills four roles: `activate` with the command
  `minibuffer-accept`, `quit` with `minibuffer-cancel`, and `next-item`
  and `previous-item` with the two commands that move through a prompt's
  candidates ("A prompt's candidates", below). So any scheme
  has an accept key and a cancel key from its role table, with no binding
  written for the scheme, which is what roles are for. Under the test
  scheme they are the keys of those two roles. With no prompt open each
  command says so in the echo area and does nothing else.
- **The buffer is made with the mode**: opening the prompt sets the name
  (`Prompt.mode`, `lean/Editor/State.lean`). No on-enter action runs, and
  the mode has none. A host that was not handed the mode has a minibuffer
  whose mode contributes nothing; the executable is handed the commands
  and the mode (`Minibuffer.commands`, `Minibuffer.modes`), registered for
  the owner `compiled`, so they hold when config fails to load and a
  reload does not replace them.
- **A prompt does not capture the keyboard.** A command may focus another
  window while the prompt is open; keys then go there, and the prompt
  waits. A binding of the global keymap holds in the minibuffer's view as
  in any view.

**A scheme is told when the minibuffer's view opens, and every scheme
takes text there.**

- **A second notice**, beside `closeView`: `openMinibuffer`, the scheme's
  state with what the scheme keeps for a view that is the minibuffer's. It
  defaults to changing nothing.
- **The loop tells it** after a command that ran to its end left a prompt
  open that was not open before it, for both states of the scheme it keeps
  (the one after the last key and the one at rest), after it has told them
  of the views the command closed. A command that did not run to its end
  opened nothing, and the scheme is told nothing.
- **What the scheme kept is forgotten by the notice that exists**: closing
  the prompt closes the view, and the loop tells `closeView`.
- **The scheme contract has a property for it**, `minibufferTakesText`:
  after the scheme is told a view is the minibuffer's, a key that prints
  and that nothing binds, typed for that view, yields an invocation and
  leaves nothing pending. The contract's subject supplies that key
  (`Subject.printable`). The contract says nothing of which invocation:
  the name of a self-insert is the scheme's own. The test scheme keeps it
  with no notice of its own, since it yields a self-insert in every view.
- **A notice for the minibuffer alone**, and not a general one with a kind
  of view: there is one kind of view a scheme must treat apart today. A
  terminal view can widen it when it exists.
- **The edit begun is not reset by the notice.** A prompt opened by a
  key's command opens with nothing pending. One opened from the background
  while a sequence is pending finds the scheme mid-sequence, and the next
  key goes on with it, as a key for another view does today.

**Under the Vim scheme the minibuffer's view is in a Vim state of its
own.**

- **The registry names the state** (`Vim.States.minibuffer`, a name or
  none). Told that a view is the minibuffer's, the Vim scheme enters that
  state for the view, as an edit that names a state enters it, so a name
  the registry does not have is the initial state. With none the view
  stays in the initial state. Nothing matches on a state's name.
- **The default registry has a fifth state, `minibuffer`**: typing is
  text (so a digit is text too), the cursor is a bar, and its one keymap
  (`Vim.Default.minibufferCommands`) binds `RET` to `minibuffer-accept`
  and `<Escape>` to `minibuffer-cancel`, four keys to the commands
  that move through a prompt's candidates, and the editing keys: `<Backspace>`
  to `minibuffer-delete-backward`, `<ArrowLeft>` and `<ArrowRight>` to the
  motions `left` and `right` (Vim's `c_<Left>` and `c_<Right>`), which stop
  at the input's start and its end, and `C-u` to
  `minibuffer-delete-to-start` (Vim's `c_CTRL-U`), which deletes from the
  bar to the input's start, keeps what is after it, and never cancels the
  prompt. This is Vim's own command-line mode. The one editing key of
  Vim's command line not built is `C-w`.
- **Why a state of its own and not `insert`.** In `insert`, `<Escape>`
  enters normal state and `RET` is bound to nothing, so answering would
  take `<Escape>` and then a key of normal state.
- **Why the accept and cancel keys are in the state's table.** The view's
  state inserts text, so the mode's role keys do not hold there ("Which
  keymaps a key is looked up in"), and the Vim key for `quit` is `q`,
  which must be text. A binding meant for one state belongs in that
  state's keymaps. The mode still fills the roles, for any scheme whose
  role keys hold where it types.
- **How the per-view state is made and forgotten.** It is an entry of
  `current`, made by the notice and dropped by `closeView` when the prompt
  closes. The asking view's Vim state is its own entry and does not
  change.
- **The interrupt key is not bound there**, as it is not in Vim's command
  line.

**The minibuffer's typing is insert state's command, with no code of its
own.** The minibuffer's view is in the Vim state `minibuffer`, where
typing is text, so a key that prints yields `self-insert`; the loop runs
it with the focused window as its target, which is the minibuffer's
window. So a key types into a prompt, and `RET` answers with what was
typed. A committed text is inserted there too, since the view takes text.
The minibuffer's buffer is in an insert session for as long as its prompt
is open, so its history has one step for the whole prompt, and is given
up with it.

Pinned by `ModelTest.evilInsertChecks` (a key typed into a prompt, under
the Vim scheme), `ModelTest.promptChecks` (the mode and its commands, on the
models and the test scheme, with the accept key and the cancel key read
from its role table), `dispatchMinibufferNoticeChecks` (the notice in the
loop), `schemeContractChecks` and `vimContractChecks` (the property),
`vimStateChecks` and `vimDefaultChecks` (the Vim state, on the registry
written for the checks and on the defaults), `ConfigTest.promptChecks`
(through the headless host, with the test scheme), and the fixture
`tests/headless/prompt`, which is where a key is typed into the minibuffer
and `<Enter>` and `<Escape>` are pressed, under the Vim scheme the
executable runs.

**A prompt's candidates** (built by the command loop's phase 14). A prompt
may be asked with candidates, strings the answer may be chosen from
([concurrency.md](concurrency.md), "Prompts", has where they come from and
what accepting gives).

- **The scene lists them in the minibuffer's status line.** After the
  prompt's label comes one field for each candidate the typed text
  matches, every one, in the fuzzy matcher's order, in the face
  `minibuffer.candidate`; the chosen one is in `minibuffer.chosen`
  ([text-and-display.md](text-and-display.md), "Views as built"). A
  candidate that is the typed text is first. With nothing listed the line
  is the label alone.
- **Two commands move a choice through the list**, `minibuffer-next` and
  `minibuffer-previous` (`lean/Editor/Minibuffer.lean`).
  - From nothing chosen, next chooses the first and previous the last;
    next from the last and previous from the first choose nothing. So the
    typed text is one stop of the round, as in Vim's wild menu.
  - The minibuffer's text is not changed by a choice. Accepting takes the
    chosen candidate, and the typed text when nothing is chosen.
  - A change of the text forgets the choice: the next scene lists again.
  - With nothing listed each changes nothing, and with no prompt open
    each says so, as accept and cancel do.
- **The mode fills the roles `next-item` and `previous-item` with them**,
  so any scheme whose role keys hold in the minibuffer has the two keys
  from its role table, as it has the accept key and the cancel key. Under
  the test scheme they are the keys of those roles.
- **Under the Vim scheme the keys are in the minibuffer state's table**,
  for the reason the accept and cancel keys are: the state inserts text,
  and the Vim keys of the two roles are `j` and `k`, which must be text.
  `Vim.Default.minibufferCommands` binds `TAB` and `C-n` to
  `minibuffer-next` and `S-TAB` and `C-p` to `minibuffer-previous`, Vim's
  own keys in its command line. A window system may report Shift and Tab
  under another name than `S-TAB`; that has not been checked on a window,
  and `C-p` is bound beside it.
- **Set aside**: putting the chosen candidate's text into the minibuffer;
  a limit on how many candidates the scene lists, or a window of them
  round the choice, which a long list wants; a popup or a view of their
  own for them; and highlighting the characters that matched.

Pinned by `ModelTest.candidateChecks` (the listing, the scene's fields and
the two commands, on the models and the test scheme, with the keys read
from its role table), `vimDefaultChecks` (the four keys of the Vim state),
and the fixture `tests/headless/candidates`, which is where `<Tab>` and
`<Enter>` are pressed under the Vim scheme the executable runs, with the
library's matcher.

### The compile mode, as built

Status: built by `shell-and-compile` phase 3 (`lean/Editor/Compile.lean`,
`lean/Editor/Compile/Compiled.lean`; the module docs have the detail).
Emacs's `M-x compile`, one per workspace: a build or test command runs as
`/bin/sh -c <line>` and its output arrives in the workspace's compilation
buffer while editing goes on.

- **The scope.** Each command acts on the focused buffer's workspace; a
  buffer with no workspace uses its file's directory, or the editor's
  working directory, as a workspace of its own; a compilation buffer, its
  own scope ([projects.md](projects.md), "A buffer's workspace"). A
  location that cannot run commands refuses `compile` and `recompile`
  before anything is asked or started, and says why.
- **The commands.** `compile` takes the line, or asks for it, `Compile
  command: `, with the scope's last line as the prompt's text and the
  project's compile history as its candidates. `recompile` reruns the
  scope's last line in the directory it ran in, with no prompt.
  `kill-compilation` cancels the scope's run, which kills the child with
  its process group. Starting a run while the scope's own runs asks,
  `Kill the compilation running in <label>? (y or n) `: `y` or `yes`
  kills the old one and empties the buffer, anything else leaves both. The
  ex line ships `compile` (taking the line), `recompile` and
  `kill-compilation`; no key binds them yet.
- **The buffer** is `*compilation: <label>*`, with the root's parent
  directory in parentheses when that name is taken by another workspace
  of the same label, then the first free name of that. It is found by the
  number its scope keeps, never by its name. Its first line is the header,
  `<label> in <directory>: <line>`; its last, once the run ends,
  `Compilation <how> after <s>.<tenths> s`, with Emacs's words for how:
  `finished`, `exited abnormally with code <n>`, `killed by signal <n>`,
  `killed`, or `stopped: <why>` and `could not start: <why>`. The echo area
  says the same with the label. When no view shows the buffer, the asking
  view is split and the new view below shows it, the focus staying.
- **Streaming.** The run is a job keyed by its scope. It reads the child a
  delivery at a time and posts each batch of lines to the editor as it
  comes (`post`, [concurrency.md](concurrency.md), "Getting results
  back"), pausing 50 ms after each, so a fast child is drawn at most twenty
  times a second. Within a delivery, standard output's lines come before
  standard error's: the true interleaving of the two needs them merged in
  the process service, which is not built. A killed or replaced run's late
  output is dropped.
- **Following.** A view whose cursor is on the buffer's last line, or the
  empty row after it, follows: its cursor goes to the start of the new
  last line, and the view scrolls with it. A view whose cursor was moved
  up stays where it is. A restart puts every view's cursor on the header.
- **Read-only.** The buffer is read-only to editing commands
  (`Buffer.readOnly`): an edit gives the command up, `<command>: <name> is
  read-only`, undo included, and a committed text is dropped and said. The
  compile mode writes it inside `BufferId.writing`, Emacs's
  `inhibit-read-only`. The mode line has no read-only mark yet.
- **The mode** `compilation` fills the role `refresh` with `recompile`.
- **Not built here**: errors and `next-error` (phase 4), the hook a minor
  mode gives a project (phase 5), a time limit (a build may run for many
  minutes; `kill-compilation` ends it, and `C-g` does not, as in Emacs).

Pinned by `ModelTest.compileChecks` and `readOnlyChecks` on the models, and
by `ContractTest.compileChecks` over the real process service, with the
fixture `tests/compile/three-lines`.

## The ex command line

Status: decided 2026-11-14 and built, by the command loop's phase 12
(`lean/Editor/Ex/Line.lean` for a line and a binding as data,
`lean/Editor/Ex.lean` for the commands, `lean/Editor/Ex/Compiled.lean` for
their registrations and the names that ship; the module docs have the
detail). How quitting and reloading reach the host is in
[concurrency.md](concurrency.md), "Quit" and "Reload".

The ex line is a prompt whose answer is run as a named ex command. The
command `ex` opens it, and the Vim scheme's default table binds `:` to
that name, so the key opens the line.

**A line is a range, then its first word and the rest, or `!` and a shell
command** (`:!` built by the shell-and-compile roadmap's phase 2,
`lean/Editor/Shell.lean`).

- **Parsing** (`Ex.parse`). Leading and trailing ASCII white space is
  dropped. **A range may come first**: `%`, the whole buffer; or one
  address, or two with a comma between, where an address is `.` (the
  cursor's line), `$` (the last line) or a line number. An address left
  out beside the comma is the cursor's line, as in Vim (`,5` is `.,5`).
  White space may follow it. **A line whose first character after the
  range is `!` is the bang form**: the name `!`, and the rest, trimmed, its
  argument. Otherwise the *ex name* is everything up to the first white
  space, and the argument is the rest, with the white space before it
  dropped, kept whole: the spaces inside it are part of it. A line that is
  empty or all white space runs nothing and says nothing, as Vim's does.
- **The argument is one string, handed on unchanged**: `e /tmp/my
  notes.txt` opens that path. Nothing is escaped or expanded.
- **Only a leading `!` starts the bang form**, so `w!` and `e!` are still
  names of their own. Vim's rule for a name, a run of letters and then the
  rest (`e#`, `w>>file`), is not built: a name config registers may hold
  a hyphen or a digit after its first character.
- **A name must read back as itself.** `exCommand` refuses a name the ex
  line would not read as that name with no range, no bang and no argument
  (`Ex.reachable`): one that is empty, holds white space, or starts with
  `!`, `%`, `.`, `$`, `,` or a digit.
- **A range before a name** is refused, `<name>: takes no range`: no name
  that ships takes one. A range alone, which in Vim goes to that line,
  says that is not built.
- **Resolving a range** (`Range.resolve`) is the ex command's, against the
  view the line was asked from: `.` is the primary cursor's line and `$`
  the last. A buffer's lines are its rows, but for the empty row after a
  last line feed (`b\nc\na\n` is three lines; the empty text is one).
  Line 0, a range that runs backwards and a line past the end are refused,
  the last as `line 7 is past the end of the buffer (3 lines)`.
- **Set aside: a leading colon or a count.** Neither is dropped: `:w`
  typed on the ex line is the unknown name `:w`.

**`:!cmd` runs a shell command in the focused buffer's workspace**
(`lean/Editor/Shell.lean`; [projects.md](projects.md)).

- **What runs**: `/bin/sh -c cmd`, as a job (`shell-run`), so the editor
  stays responsive; not `$SHELL`, so a user's interactive set-up cannot
  change what runs. The environment is the directory's, as every child's
  is.
- **Where**: the workspace's root; with no workspace, the directory of the
  buffer's file; with neither, the editor's working directory, which the
  host set from its own. A workspace whose location cannot run commands
  runs nothing and says so: `!: <label> is <location>, where commands
  cannot run`.
- **For how long**: 30 seconds, or config's `shellTimeLimit`. A run past
  it is killed, its process group with it, and the echo area says
  `<line>: the run did not end within <n> ms and was killed`.
- **What is shown**: one line of output or none, with nothing on standard
  error, goes to the echo area, with ` [exit <n>]` after it when the
  status is not 0; no output says `<line>: no output`. Anything longer, or
  anything on standard error, replaces the text of the workspace's output
  buffer, `*shell output: <workspace label>*`, with standard output, then
  standard error, then a last line `[exit <n>]`, and it is shown in the
  view the line was asked from. A second run in that workspace replaces
  its text, as one edit `u` takes back; another workspace has a buffer of
  its own. A buffer outside any workspace uses one editor-wide `*shell
  output*`. A refusal, a program not there or output past 16 MiB among
  them, is said as `<line>: ` and its sentence.
- **One run a workspace**: each runs under its workspace's job key, so a
  second `:!` there while one runs cancels the first, and one elsewhere is
  left alone. **`C-g` cancels it** (`keyboard-quit`, "Default bindings"):
  its child is killed, and the echo area says `<line>: interrupted`.
- **History**: each line run is kept in the project's history, newest
  first, each once, at most 100, so every worktree of a codebase offers the
  same lines; a buffer outside any workspace keeps one editor-wide history.
  The ex prompt's candidates are the history, then the bound ex names, so
  typing `!` lists the earlier lines and the minibuffer's keys choose one.

**`:{range}!cmd` filters the range's lines through the command**, in the
same directory, under the same time limit and job key as `:!`:

- **The child is fed the range's lines**, through the last one's line
  feed, with one line feed added when the buffer's last line has none, and
  then end of file.
- **Its output replaces them as one edit** that one `u` takes back, and
  the echo area says `<n> lines filtered`. When the range had no last line
  feed, one at the end of the output is dropped.
- **A status other than 0, or anything on standard error, changes
  nothing** and says `<line>: exit <n>: <first line of standard error>`.
- **A buffer edited while the child ran is left as it is**: the result is
  dropped, `<line>: dropped: the buffer changed while it ran`. The text's
  revision is the test: Vim, which blocks while the child runs, cannot be
  edited meanwhile.

Where `:!` differs from Vim: `:!!` and `%` in the command are not
expanded; output does not take over the screen, it goes to the echo area or
a buffer; and the time limit is the editor's.

**The ex line's editing keys are the minibuffer's.** It is a prompt, so it
is typed in the minibuffer's view, in the Vim state `minibuffer`, and
`<Backspace>`, `<ArrowLeft>`, `<ArrowRight>` and `C-u` edit it as they edit
any prompt ("The minibuffer"; pinned on both by `evilInsertChecks`).

**The ex line's candidates are the `:!` history of the asking buffer, then
the ex names that are bound** (built by the command loop's phase 14; "A
prompt's candidates", under "The minibuffer"; the history by the
shell-and-compile roadmap's phase 2).

- `ex` asks for its line with the asking buffer's `:!` lines, newest first
  (`Shell.history`), then the bound ex names as the prompt's
  candidates: each name once, in the order they were first bound. A
  command asks for them (`exNames`), and the loop answers from the
  registry as it is when the line is asked for.
- So while a name is typed the scene lists the names it matches, a key of
  the minibuffer chooses one, and accepting runs the chosen name. With the
  names that ship, `e` lists `e`, then `e!` and then `reload`.
- **The typed line is the pattern, whole.** A line with an argument
  matches no name, so nothing is listed, and accepting runs the line as
  typed. A name is completed; an argument is not.
- **Nothing is chosen unless a key chooses it**, so a typed name and the
  accept key run what was typed, as before: `r` and the accept key is the
  unknown name `r`, not `reload`.
- **`open-file` has no candidates.** File names depend on the directory
  typed so far and need the file system: a job, and a list that changes
  with the text, neither of which is built
  ([concurrency.md](concurrency.md), "Prompts").

**An ex name is a binding to a command's name, held in the registry by
owner.**

- **A binding** (`Ex.Binding`) is the ex name, the name of the command it
  runs, and what the name takes after it (`Ex.Takes`): nothing, or text.
- **The registry has a table of them by owner** (`Registry.ex`), replaced
  as a set (`replaceEx`), and a lookup finds the latest entry of a name
  (`ex?`). So config's `w` runs in place of the compiled one until a
  reload drops it, as for a command. A reload replaces config's ex
  bindings and never the compiled ones. An ex binding is not a command,
  and a reload's report does not count it.
- **The invocation a line runs** (`Binding.invocation?`): with no
  argument, the command with no arguments; with an argument and a name
  that takes text, the command with the argument as its first argument, a
  string, which is where a prompt's answer goes; with an argument and a
  name that takes nothing, none, and the line is refused before anything
  runs.
- **Why a binding and not a second kind of program.** Every way a command
  comes to run names it: a key binding, a role, a prompt's continuation. A
  table of ex programs would be a second set of names for `show`, for the
  reload's report and for "registered twice", and a command an ex name
  runs could not be bound to a key. With a binding, the command a line
  runs is run by the loop like any command: one rollback, one scene, and
  its errors in the echo area under its own name.
- **Why a binding says what it takes.** Without it `w notes.txt` would run
  `save-buffer`, which ignores a string, and save the current file in
  silence. With it the ex line refuses the argument, for every command,
  and no command changes. It is data on the binding, so a later phase
  adds a kind of argument (a file, for completion) with no new mechanism.
- **Set aside: ex names as commands under a prefix** (`:w` registered as
  a command). It needs no table, and puts a second namespace inside the
  first: `show` would list them, and every lookup would build a string.

**The ex line is one command that asks and then runs the answer; the
command an ex name runs is a step of its own.**

- **`ex` asks for its line when it is given none**, as `open-file` asks
  for its path. With a string as its first argument it runs that line.
  With anything else first, or nothing, it asks with a prompt labelled
  `:`, whose continuation is `ex` itself. A key bound to it under the Vim
  scheme hands it a count and a register, so it asks. Where the prompt is
  refused, because one is open, it says so.
- **Running a line**: parse it; hand a bang line to `shell-command`, which
  runs after `ex` as a step of its own; ask which binding the name has; say
  `<name>: not an ex command` for none; say `<name>: takes no argument`
  for an argument the binding does not take; otherwise ask for the
  invocation to be run after this command.
- **A command asks two things of the loop for that**, each a state
  request ([lean-runtime.md](lean-runtime.md), "The editor API"). Which
  binding an ex name has (`exBinding`) is answered by the loop from the
  registry as it is at that step: a command is a program over the
  editor's port and cannot hold the registry. And that an invocation be
  run after it (`invoke`): the bound command is to be a step of its own,
  with its own write and its failure under its own name
  ([concurrency.md](concurrency.md), "Prompts").
- **So one accepted ex line is three steps**: the accept command, `ex`
  with the line, and the bound command, each with a scene. A name bound to
  a command nobody registered says `<command>: no such command`, by the
  loop's rule.
- **An ex command's error goes to the echo area as a command's does**,
  with no rule of its own: a refusal of the bound command is the loop's to
  say, under that command's name, and an unknown ex name is a message of
  `ex`, which ran to its end. The editor goes on.
- **Set aside: running the bound command inside `ex`.** It would be looked
  up before the step's write to a store was written back, and its failure
  would be said under `ex`'s name.

**The names that ship.**

| Ex name | Command | Takes | What it does |
|---|---|---|---|
| `w` | `save-buffer` | Nothing | Saves the buffer of the window the line was asked from |
| `w!` | `save-buffer`, with `true` first | Nothing | Saves it whatever the file on disk now is: "write mine over theirs" |
| `e` | `edit-file` | Text | Opens the path the rest of the line is. With no argument, reloads the window's file (`reload-buffer`), refused while the buffer has unsaved changes; on a buffer with no file it asks for a path, by `open-file`'s own rule |
| `e!` | `edit-file`, with `true` first | Text | As `e`, but with no argument the reload discards unsaved changes as one step `u` undoes: "take theirs" |
| `q` | `quit` | Nothing | Quits the editor |
| `wq` | `save-and-quit` | Nothing | Starts the save, and quits once it has ended |
| `reload` | `reload-config` | Nothing | Reloads the config |
| `b` | `switch-buffer` | Text | Shows the buffer the rest of the line names, exactly or by fuzzy match. With no argument, asks with the open buffers as candidates, by `switch-buffer`'s own rule |
| `ls` | `list-buffers` | Nothing | Shows the buffer list, a text view of the open buffers, most recently used first, with `+` for unsaved changes |
| `bd` | `close-buffer` | Text | Closes the buffer the rest of the line names, or the window's own: refused for a buffer of a file with unsaved changes and for a buffer with a save in flight, and every window that showed it shows the most recently used buffer left |
| `compile` | `compile` | Text | Runs the rest of the line as `/bin/sh -c` in the buffer's workspace, into its compilation buffer ("The compile mode, as built"); with no argument, asks for the line |
| `recompile` | `recompile` | Nothing | Reruns the workspace's last compiled line |
| `kill-compilation` | `kill-compilation` | Nothing | Kills the workspace's compilation in flight |

Where they differ from Vim:

- **`q` does not refuse for a modified buffer with no file.** Such a
  buffer cannot be saved, and `:w !cmd` is not built, so the rule would
  leave no way to quit once anything was typed in the scratch buffer. It refuses
  while a buffer that holds a file has unsaved changes.
- **`q` quits the editor, not the current window.** No shipped command
  splits a window.
- **`e` with no argument reloads as one edit.** Vim reads the current
  file again and loses the undo history; here the file's text comes in as
  one edit made from a line diff, so the cursor and the marks stay where
  the diff kept the text, and `u` takes the reload back. On a buffer with
  no file it asks for a path.
- **`e!` and `w!` are names of their own**, bound with a fixed argument;
  only a leading `!` is parsed, as the shell's.
- **`w` takes no file name.** Saving under another name is not built.
- **`reload` is no Vim command**, nor are `compile`, `recompile` and
  `kill-compilation`, which are Emacs's.
- **`b <pattern>` takes the best fuzzy match.** Vim refuses a pattern that
  matches more than one buffer.
- **`bd` never refuses a modified buffer with no file**, by `q`'s rule: it
  cannot be saved.
- **`bd` refuses a buffer with a save in flight**, until the save is
  delivered: the save may yet be refused, and the buffer then holds the
  only copy of the edits. `q` waits for such a save instead.
- **The buffer left after the last `bd` is `scratch`**, empty and with no
  file, the name the initial buffer has. Vim calls it `[No Name]`.
- **A buffer's cursor is not given back.** A window shown a buffer again,
  by `b` or after a `bd`, has its cursor at the buffer's start; Vim gives
  back where the cursor last was in that buffer.

Pinned by `ModelTest.exLineChecks` (the parser, ranges and the binding),
`shellChecks` (`:!` on the models, in the workspaces of a main checkout,
a linked worktree and a directory in none), `ContractTest.shellChecks`
(over the real process service), `compileChecks` (`:compile` and the
compile mode on the models) and `ConfigTest.shippedChecks` (the names
bound),
`registryChecks`, `setupChecks` and `reloadChecks` (ex bindings by owner,
from `setup`, and across an install), `exChecks` (the ex line and the
first five names, and `bufferCommandChecks` the last three, on the loop's driver over the editor's models and the model of
files, with the test scheme), `ConfigTest.exChecks` and
`ConfigTest.exScriptChecks` (through the headless host, with the real
elaborator and the library's file service), the fixture
`tests/headless/ex`, and the two process checks of the `ffi-test` task,
which run the executable on a real file.

## Extending from config

- Config registers modes, commands, vocabulary and bindings from `setup`,
  tagged with their owner, as [lean-runtime.md](lean-runtime.md) describes
  for bindings and subscriptions. A reload replaces everything an owner
  registered.
- A binding's keys are written as a key string, which `Key.parse` reads:
  an ordinary function, built, that gives the keys or a refusal that names
  the stroke it could not read.
- Built: `setup` binds a key sequence to a command name with
  `bindKey "C-x C-s" "save"` (`lean/Editor/Setup.lean`). It is refused with
  the parser's message for a string that is not keys, and with its own for
  one that names none; a `setup` that binds one sequence twice is rejected,
  as one that registers a command name twice is. A binding to a name that
  is not registered is accepted: the name is looked up when the key runs.
  It is `bindKey` and not `bind`, which would shadow the monad's `bind` for
  config, which opens `Editor`.
- Built: `setup` defines a mode with `defineMode { name := "listing", roles
  := [(Role.nextItem, "listing-next")], locals := [("x", "listing-run")] }`.
  A `setup` that defines a mode name twice, or a mode with a problem
  (`Mode.problems`), is rejected with a message that names the mode and the
  problem. A reload replaces config's modes and never the compiled ones.
- Built: `setup` registers a command that is given what it was called with,
  `commandWith "greet" fun call => …` (`lean/Editor/Setup.lean`), beside
  `command`, which is told nothing of its call, as `jobWith` is beside
  `job`. The call holds the window the command acts on, the invocation's
  arguments and its keys (`lean/Editor/Command/Call.lean`), so a command
  of config's reads a count, and can be the command a prompt names, which
  receives the answer as its first argument. Both kinds are commands under
  one set of names: a name registered twice is refused whichever the two
  are.
- Built: `setup` binds an ex name to a command's name with
  `exCommand "greet" "greet-named" (takes := .text)`
  (`lean/Editor/Setup.lean`; "The ex command line"). By default the name
  takes nothing. The command's name is looked up when the line is run, as
  a key binding's is. A name the ex line would not read back as itself is
  refused (one that is empty, holds white space, or starts with `!`, `%`,
  `.`, `$`, `,` or a digit), and a
  `setup` that binds one ex name twice is rejected. A reload replaces
  config's ex bindings and never the compiled ones.
- Built: `setup` defines a language with `defineLanguage`
  (`lean/Editor/Setup.lean`; "Languages and the code mode"). One of a
  shipped language's name replaces it whole; config's entries are matched
  before the shipped ones. A `setup` that defines a language name twice,
  or a pattern that is empty or holds `/`, is rejected. A reload's
  languages hold from the next file opened.
- A key-string macro (`kbd "C-x C-s"`) could parse at elaboration time, so
  a mistyped key is an error in config before it runs. It is not built. See
  the open questions for its cost.

### Key strings

Strokes are separated by spaces. A stroke is modifier prefixes, then a key:

| Written | Is |
|---|---|
| `C-`, `M-`, `s-`, `S-` before a key | Control, alt, super and shift held |
| One character: `x`, `A`, `-`, `<` | The key of that character |
| `<Name>`: `<Escape>`, `<ArrowLeft>` | The named key of that W3C `key` value, as the event's key names it |
| `RET`, `ESC`, `TAB` | `<Enter>`, `<Escape>`, `<Tab>` |
| `SPC` | The space character, the W3C `key` value of the space bar |

- A prefix is one only while something follows its `-`: `-` is the minus
  key, and `C--` is control with it.
- `S-` before a character is refused. A shifted character is written as
  itself, and a chord carries no shift on a character, so the prefix would
  be dropped without a word.
- What `Key.parse` gives is in chord form. `Key.notation` and
  `Key.notations` write chords back, for the scene's pending text: the
  inverse of `Key.parse` on chords of one character or a named key. A dead
  key and an unidentified one are written `<Dead>` and `<Unidentified>`,
  which do not read back as them.

## Testing

Tests follow the pipeline. Most need no fake.

What is built is checked by the model tests (`lean/ModelTest.lean`, under
`lake test`, with no Rust library): `keymapChecks`, `keyNotationChecks`,
`invocationChecks`, `schemeChecks` on the test scheme, and
`schemeContractChecks`. They are checks that the test driver runs, each
with a name it prints when it fails and each written to fail first, as the
rest of the model tests are, and not `#guard`s.

The Vim scheme is checked the same way, by six lists:

| List | Checks |
|---|---|
| `vimEditChecks` | What an edit compiles to, the layout of each kind of invocation, and what an edit says of itself |
| `vimRegistryChecks` | The registry of Vim states: looking a state up, and registering one |
| `vimGrammarChecks` | Which keymaps a key is looked up in; moves, operators and their targets, the doubled operator, counts, registers, resets, and the pending keys |
| `vimStateChecks` | Which Vim state a view is in and how one is entered; what the scheme reports of a view in a state; typed text; an operator over the selection; the last change; the state the minibuffer's view is put in when the scheme is told of it, and what the notice keeps |
| `vimDefaultChecks` | The default states and bindings, through what each default key parses to and what the scheme reports after it, the minibuffer's state among them; that each editing key of insert state runs a command of its own and keeps the view in insert state and the last change; that `<Backspace>`, `RET` and `TAB` are kept in the session's recording and that an arrow key restarts the last change as `i` once something is typed after it; the minibuffer state's `<ArrowLeft>`, `<ArrowRight>` and `C-u`; and that every command name of the insert and minibuffer tables is registered |
| `vimContractChecks` | The scheme contract holds of the Vim scheme, over the checks' registry and over the default states, and is reported for a registry that names no state for the minibuffer |

- **The grammar's checks run on a registry and keymaps written in the
  test** (`vimStates`), and name no default binding. The defaults have
  their own list, which observes them through `Vim.parse` and restates no
  table.
- **The contract's unbound key is a named key** (`<F12>`): after the
  register prefix every key that prints names a register. Given a key that
  prints, the contract reports that the scheme does not reset, and a check
  holds it to that.
- **A state record is compared by its fields**: it holds keymaps and has no
  equality. The scheme's state is compared whole, at its own type.
- **The Vim checks' contract runs on a role table and leader written in the
  test** (`vimModeKeys`), so no grammar check names a default.

Evil is checked on the editor's models, by four lists. This is where Vim
keys are pressed against a text:

| List | Checks |
|---|---|
| `evilRestChecks` | Where a cursor rests under each rule, from every position of a few small texts, on the text model; the rule a report gives |
| `evilMotionChecks` | Each motion's key, with and without a count, in a text with the cursor written into it ("Keys against the model"); the wanted column, by keys and by a command that calls the move command twice; the display column `j` and `k` aim for, by rows of Vim's results with a tab and with wide characters (`displayColumnRows`), in a frame of 0 by 0, and by what `down` asks of the ports; a motion written in a check that asks the display; a sweep of every motion of the table from every resting position; that every default motion key has an entry |
| `evilStateChecks` | `v`, `V` and `<Escape>`: the selection the scene shows, its shape and what it covers; the scene's cursor and status field in each state; and, by `Evil.enter` called with a report written by hand, a state that keeps both ends entered from an exclusive selection, which no default key does: where the anchor rests, and that the head steps back |
| `evilInsertChecks` | `i a I A`, typed text and `<Escape>`; that a session is one step of the history, by an undo request; `<Backspace>`, `RET` (in a buffer of each line ending), `TAB` and the four arrow keys in insert state, by rows of Vim's results, and that an arrow key that moves starts a new step and one that fails does not; a key typed into a prompt; `<Backspace>`, `<ArrowLeft>`, `<ArrowRight>` and `C-u` in a prompt, each in the minibuffer and on the ex line; a committed text in normal state and in a session |

- **The first runs on the text model alone; the other three on the loop's
  driver over the editor's models** (`Loop.Driver`), under the Vim scheme
  that ships with the commands compiled code registers for evil.
- **What the loop does with a scheme's report is checked apart, with no
  Vim key**: `loopChecks` (the scene), `dispatchReportChecks` (what a
  command is told), `dispatchUndoChecks` (insert sessions) and
  `commitChecks` (a committed text) run a scheme written in the test,
  whose report a key's invocation switches, and commands written in the
  test.
- **No evil command adds a request to a port**, so there is no new model
  and no new contract. That the motion primitives agree between the model
  and the library is the text contract's.
- **The wiring is one fixture on the executable**, against the real
  library (`tests/headless/evil-script`): with no config, `i`, typed
  text, `<Escape>` and `0`.

Scrolling is checked by two lists, three cases and one fixture (built by
the command loop's phase 15):

| List | Checks |
|---|---|
| `scrollChecks` | On the display model alone, with a view's anchor and cursor as offsets: the follow policy (which anchors are kept, how far one moves, a wrapped line's last row, the margin, swept from every row and every position, and what it costs in requests), and the anchors a scroll by rows and a scroll to the cursor's row place |
| `viewChecks` | On the loop's driver over the editor's models, under the Vim scheme that ships with evil's commands, in frames a few rows tall: a view follows its cursor after a motion, a resize and an edit through another window; the margin after every motion of the vocabulary; `C-d`, `C-u`, `C-f` and `C-b`, by key, at the text's two ends, with a count, in a visual state and stopped by the interrupt; and `z t`, `z z` and `z b` |

- **A check asks the model and restates no layout.** What a view shows is
  read by asking the display model for the rows of the scene's view from
  its anchor, and the cursor's row the same way. The texts are lines
  shorter than their view, and the one text the display contract's own
  cases wrap.
- **The keys through the grammar** are in `vimDefaultChecks`: each scroll
  key runs a command of its own that changes no text and enters no state,
  in normal state and the two visual states; an operator's key before one
  is dropped; `z` is a prefix there, and text where typing is text.
- **No request was added to a port.** The three operations of the API
  that reach the library, and the loop's follow, have cases in
  `lean/Editor/Api/Cases.lean`, played on the models and on the real text
  binding with the recorder as the display.
- **The wiring on the executable** is the fixture `tests/headless/view`,
  a process check of the `ffi-test` task on a file of 120 lines in a
  temporary directory: with no config, in a frame the script sizes,
  `100j` is followed, and `C-u`, `C-f`, `z t`, `z b` and a resize each
  print the scroll anchor and the selection worked out by hand in the
  script's comments ([the gate](../dev-practices/the-gate.md)).

Modes are checked on the test scheme, by four lists in the model tests and
one in `config-test`. Each check reads the role's keys and the leader from
the test scheme (`InputScheme.roleKey`, `InputScheme.leader`), so none
names a scheme's key:

| List | Checks |
|---|---|
| `modeRecordChecks` | The registered roles; the keymaps a mode makes for a scheme (a role at the scheme's key, a suffix under the leader, a role the scheme has no key for, hand-tuned keys ahead of both); what `Mode.check` reports, each problem and none |
| `modeRegistryChecks` | A mode's lineage, a cycle and a missing parent; the order of the active keymaps; a mode name no mode is registered under; a view with no window |
| `modeDispatchChecks` | On the editor's models, through the loop: a major mode's role runs its command in a view of its buffer and the global binding elsewhere; a minor mode's wins; a derived mode falls to its parent; the leader then a suffix |
| `modeEnterChecks` | On the editor's models: the on-enter action runs once, with the view, when the mode becomes the major mode; a derived mode's lineage root first; a refusal runs nothing |
| `highlightFaceChecks`, `highlightEnterChecks` | The capture-to-face rule, pure; and, on the editor's models through the loop, a mode with a syntax tree attaching and highlighting its text in the faces the rule gives, its own query, a refusal in the echo area with the mode set and the text detached, a mode before drawn no more, a parent's syntax tree, and the text detached when a mode with none replaces it; then its injections and a language for the model's grammar, its text objects and indents queries kept, and a refusal of one of those steps said and stopping it alone |
| `languageMatchChecks`, `languageOpenChecks` | The language rule, pure: by extension, an exact base name over an extension, config's entry over a shipped one and the earlier over the later, no match, `Language.over` and the registry's table, and the shipped table; and, on the loop's driver over the editor's models, a `.json` and a `.rs` file opened into `code` with their language and highlighted, a file of no language opened as before, one already open asking nothing more, a config mode with its own tree winning, and config's entry of a language's name used |
| `ConfigTest.languageChecks` | Through the headless host, the real elaborator and the real syntax binding: a `.rs`, a `.json` and a `.md` file opened into `code` and highlighted with their grammar's shipped query, a file of no language asking the syntax tree port nothing, and config's `rust` with its own highlights query used in place of the shipped one |
| `treeObjectRuleChecks` | The syntax tree's text-object rule (`Evil.TreeObjects.choose`), pure, over hand-built rows: the smallest node first, a count, a node no bigger than a wider selection passed over, the inside as the longest inner row within, no inside, and no node round the cursor |
| `indentRuleChecks`, `indentLevelChecks` | The indent rule (`Indent.rule`), pure, over hand-built rows; and the indent primitive (`TextId.indentLevels`) on the editor's models, under a test mode of the model's JSON grammar with an indents query of its own, refused for a text with no syntax tree or no indents query |
| `indentOpeningChecks`, `indentEditChecks` | The opening rule (`Indent.openingCounts`, `Indent.levelOf`) and the widening (`Indent.widenedStart`), pure, over hand-built nodes; and levels as edits, pure: a level's whitespace in spaces or tabs, the re-indent's edits (a row already right left, a blank row emptied, a kept row untouched), what a new line gets for each answer, and `RET`'s edit (`Indent.breakAt`) |
| `evilIndentChecks` | `=` and the indented new lines by key, in a JSON language whose model tree answers the indents query (`indentDriver`): `gg=G` over a mangled text, `=af`, counts, `=j`, `V j =`, one undo step, `.` over another range and with a new count, not over a selection, a config entry's tab unit; `RET` after an opening bracket and before a closing one, between blanks and twice, `o` and `O`, and `.` replaying them; and with no language or no indents query, `=` giving up with its sentence and `RET`, `o` and `O` as before |
| `ConfigTest.indentChecks` | Through a headless host of the Vim scheme that ships and the library's Rust grammar: `gg=G` on the Rust indent fixture mangled in code gives the fixture back, its string and comment rows kept; `=af` on one of two functions, then `u` and `.`; `A RET` after an unclosed brace at the text's end and two deep, `o` then `if a {` and `RET`, `o` and `O` in a method; and a plain and a JSON buffer as before. The host waits for a text's tree before a question of its captures, so keys that edit and then ask are deterministic. `ContractTest` holds the opening rule's table over the real grammar through `TextId.openingLevel` |
| `ConfigTest.modeChecks` | Through the headless host and the real elaborator: a config mode's role runs its store command, and once a reload drops the mode the role's key runs the global binding; a compiled mode's role runs its command before any reload and after a reload of a config that defines no mode |

Beside them, `stateChecks` pin the three state operations, `registryChecks`
and `reloadChecks` modes by owner and their install, `setupChecks`
`defineMode`, `defineLanguage` and their refusals, `keymapChecks` `Keymap.filter`, and
`vimStateChecks` that a mode's key, a hand-tuned one among them, is typed
text in insert state, that a mode's binding is reached as what it wraps,
and that `Mode.check` under the Vim scheme reads every state's keymaps.

The mode that ships, the minibuffer's, is checked the same way: by
`promptChecks`, on the loop's driver over the editor's models, with the
registry's active keymaps and the accept key and the cancel key read from
the test scheme's role table; and by `ConfigTest.promptChecks`, through
the headless host. The keys the Vim scheme has for it are pinned by the
Vim scheme's own lists, above, and pressed in the executable's fixture
(`tests/headless/prompt`).

A prompt's candidates are checked by `candidateChecks`, on the loop's
driver over the editor's models and the test scheme: the listing the loop
makes before each scene, the fields the scene has for it, and the two
commands that move through it, with their keys read from the test
scheme's role table through the minibuffer's mode. Each listing a check
expects is what the fuzzy model answers for the same pattern
(`FuzzyModel.rank`): no check writes an order out, since after the
candidates that are the pattern the model's order and the library's are
not held to agree. On the executable, with the library's matcher, they
are checked by the fixture `tests/headless/candidates`, whose one ordered
pair is one the rule for an exact match fixes. The ex line's candidates
are in `exChecks` and in the fixture `tests/headless/ex`.

The ex command line is checked by one pure list, one list on the models
and two through the host:

| List | Checks |
|---|---|
| `exLineChecks` | Pure: what a line parses to, and the invocation a binding makes of an argument, by what it takes |
| `exChecks` | On the loop's driver over the editor's models and the model of files, with the test scheme: the ex command opens a prompt and runs the accepted line's command as a step of its own; a name nobody bound, an argument a name does not take, an empty line, a bound command that is not registered or is refused, a cancelled line; and the five names that ship, with `w` then `q` and `wq` while the save is in flight |
| `ConfigTest.exChecks` | Through the headless host and the real elaborator, with the test scheme: the ex line `reload` reloads the config, an ex name config binds runs config's command until a reload drops the binding, config's binding of a shipped name runs in its place, and a name nobody bound is said in the scene's echo |
| `ConfigTest.exScriptChecks` | Through `Headless.run` over the library's file service, on a file in a temporary directory: `e`, an edit, `w` and `q`, and the same with `wq`, leave the file with the buffer's text and end the script with no failure |

- **The lists on the models name no Vim key**: the ex command and the
  accept and cancel commands are on keys of the test scheme, and a line is
  a committed text. The ex line's own rules are checked with ex bindings
  written in the test, and the names that ship with `Ex.bindings`.
- **Each message is read from the function that makes it** (`Ex.unknown`,
  `Ex.noArgument`, `Ex.notQuitting`, and the file commands' in `Files`).
- **The loop's part, stop and the withdrawn quit and the reload handed
  back, is checked apart**, by `dispatchQuitChecks`, with commands written
  in the test that name no ex name
  ([concurrency.md](concurrency.md), "Quit").
- **No new port and no new model.** The two requests that name the
  registry are answered by the dispatcher, which is one function on the
  models and against the library. The API's `quit` asks the text port for
  revisions, so it has a case in `lean/Editor/Api/Cases.lean`, played on
  the model and on the real binding.
- **The wiring on the executable** is the fixture `tests/headless/ex`,
  with no config, which opens two of its lines with the `:` key, and two process checks of the `ffi-test` task, on a real
  file in a temporary directory ([the gate](../dev-practices/the-gate.md)).

### Keys in, invocation out

The grammar's checks are of this kind: a key string in, and what each key
yielded out.

```lean
(vimFed "d 2 w").2 ==
  [none, none,
    some { command := "operate"
           arguments := [.str "delete", .str "motion", .str "word", .nat 2, .str ""] }]
(vimFed "d z").2 == [none, none]      -- an unbound key resets the edit begun
```

They replace the `#guard`s this section sketched for the grammar. `#guard`
evaluates a `Bool` at elaboration time and fails the build if it is false;
it remains the proposal for config (below). `by decide` would give a
kernel-checked proof, but kernel reduction is too slow for strings and
maps.

### Keys against the model

Built, for motions, the keys of insert state, the operators, the
registers, undo and dot repeat (`ModelTest.evilMotionChecks`,
`evilInsertChecks`, `evilOperatorChecks`, `evilSelectionChecks`,
`evilRegisterChecks`, `evilOpenChecks`, `evilUndoChecks`,
`evilRepeatChecks`). The cursor is written into the fixture as a bar, and
a check is a row: keys, the text before, the text after.

```lean
evilKeys "foo |bar baz" "w" == "foo bar |baz"
evilKeys "abc|d\nx\nabcd" "j k" == "abc|d\nx\nabcd"
evilKeys "ab|c" "i X <Escape>" == "ab|Xc"
```

- `evilKeys fixture keys` makes a state whose buffer holds the fixture
  without its bar, with one cursor at the bar of the shape the default
  scheme reports; presses the keys through the loop's driver, under the
  Vim scheme that ships with evil's commands; and answers the text with a
  bar at the cursor, or what the echo area says when a command said
  something.
- **Each expected string is written by hand** from Vim's documented
  behaviour ("Motions as built" has the table). No test runs Vim.
- A row whose key string names no keys is reported: it would press
  nothing, which a row that expects the text unchanged would not show.
- They are checks the test driver runs, as the grammar's are, and not
  `#guard`s.

- **An operator's row says more** (`OperatorRow`, `operatorRows`): the
  unnamed register after and whether it is line-wise, or that it is as it
  was, which a sentinel set before the keys shows; whether the view is
  left in insert state, read from the scene's status field; and whether
  the command gave up or broke off. The operator × motion table, its completeness
  check and the sweep are in "Operators as built".
- **The clipboard register is checked on the clipboard model**
  (`evilClipped`), which a check sets and takes away; the clipboard port's
  contract runs on the model there and on the in-process clipboard in
  `contract-test`.
- **Dot repeat's rows** (`repeatRows`) and **undo's** (`undoRows`) are
  keys and texts too. The checks of `u` are the phase's rule and are not
  compared with Vim. Beside its rows, dot repeat is checked where a
  replay does not run to its end: a replayed change whose motion fails
  where it is (`d j`, then `.` on the last line) gives the replay up
  with nothing changed, one whose motion fails after moving breaks it
  off, and one stopped by the interrupt is rolled back with the
  clipboard as it was.

This runs on the pure models with no Rust build. The text contract is
what makes the motion primitives hold for the real binding, and the API's
case for `replaceCarrying`, played on the models and the binding, does so
for the one edit evil makes. One process check runs a whole evil session
on a real file in the headless executable (`tests/headless/session/`,
[../dev-practices/the-gate.md](../dev-practices/the-gate.md)).

### Who tests what

| Author | Tests | Against |
|---|---|---|
| Scheme | Its grammar, plus the scheme contract check | Nothing, for the grammar: a scheme is pure. The models, for keys against a text |
| Mode | Its vocabulary; that each role and leader suffix runs the right command | The fake scheme the core publishes |
| Mode, hand-tuned keys | Those bindings | The real scheme they were written for |
| User config | Their own bindings | Whatever they bound against |

- **A mode's tests do not name a scheme's keys.** Typing `j` to test "next
  item" pins a rule the Vim scheme owns (`AGENTS.md`, crate coupling). The
  mode asserts on the role, using the fake scheme with a fixed role table.
- **The core publishes two contract checks.**
  - For schemes, built (`SchemeContract`,
    `lean/Editor/InputScheme/Contract.lean`). A scheme's author gives it
    the scheme, keymaps, a view, inputs the author says are complete, a key
    that goes on with none of them and a key that prints and that nothing
    binds, and it answers the names of the properties that do not hold.
    There are eleven: some input has two keys or
    more, so the others are not vacuous; a strict prefix of a complete
    input emits nothing; after a strict prefix the scheme reports its keys
    as pending; the last key emits, and nothing is then pending; an unbound
    key after a strict prefix emits nothing, leaves nothing pending, and
    the input typed next yields what it yields from the initial state; the
    unbound key, bound in a keymap of its own to `scheme.command` of a
    name, yields from the initial state an invocation of that name and
    leaves nothing pending (`namedCommandRuns`); every registered role has
    a key (`everyRoleHasKey`); the leader is not empty, and the roles are
    on distinct keys apart from it (`leaderAndRolesApart`); the unbound
    key bound to `scheme.modeCommand` of a name runs as `namedCommandRuns`
    asks (`modeCommandRuns`); once the scheme is told that the view is
    the minibuffer's, the key that prints, typed for it, yields an
    invocation and leaves nothing pending (`minibufferTakesText`); and a
    key that yields nothing leaves the scheme's report of its view as it
    was, after a strict prefix and after the unbound key that resets it
    (`quietKeyKeepsReport`). It is pure and compares no states.
  - The model tests run it on the test scheme, on schemes written there
    that each break one property and are reported (a scheme whose role
    table lacks a role, one that never yields a self-insert, and two whose
    report changes at a key that yields nothing, among them), and on both
    Vim schemes.
  - For modes, built: `Mode.check mode scheme : List Mode.Problem` reports
    unregistered roles, duplicate suffixes, unreadable suffixes, and
    hand-tuned keys that shadow a scheme binding.

### Config

A reload fails as a whole if any chunk fails to elaborate, and `#guard` is
part of elaboration. So keymap tests written in config run on every reload,
and a failing one keeps the old config.

### Theorems

Stated where they earn their keep: an unbound key always resets pending
state; `x` then `u` restores the buffer. The first is proved for the keymap
walk, which needs no model (`Keymap.walk_unbound`, checked by the kernel on
every build). The second is proved on the text model
(`Evil.deleteChar_undo`, `lean/Editor/Evil/Theorems.lean`):

- **What it says.** For every model in which a text holds some content,
  every extent, and every undo tree over that text that knew its revision
  and had nothing pending: if the model accepts the deletion `x` makes
  (`TextId.replaceCarrying extent ""`), then the deletion followed by one
  undo (`UndoTree.sync`, then `UndoTree.undo` with the user's origin)
  succeeds, the text holds exactly what it held, two revisions on, and
  the selection handed back is the one from before the deletion.
- **What it is about.** The three programs over the text port that `x` and
  `u` come to. The commands' other requests place a marker and set a
  register, which change no text; the dispatcher is `partial`, and no
  theorem is about it.
- **Its premises.** That the model accepts the deletion; that the tree is
  the text's, knows its revision, has no open group and is at one of its
  nodes, which is how the loop leaves every buffer's tree after an event
  in normal state; and that the text is in step (`TextModel.InStep`): the
  model's log holds the text at every earlier revision, and its record of
  kept inverses has one slot a revision. A text made in the empty store
  is in step and an accepted edit keeps it so (`TextModel.inStep_made`,
  `TextModel.inStep_changed`); for the other requests a model check holds
  it (`ModelTest.textModelStepChecks`).
- **Its lemmas**: `TextModel.apply_accepted` and
  `TextModel.apply_applyInverse` (`lean/Editor/Text/Model.lean`), and
  `UndoTree.undo_pending` and `UndoTree.apply_undo`
  (`lean/Editor/UndoTree/Theorems.lean`).
- **Not proved**: that every request keeps a text in step, and anything
  about the real binding, which the text contract's inverse properties
  and the API's case hold to the model.
- No `sorry`, and no axiom beyond the three
  `replaceRange_insert_delete` depends on.

## Open questions

- **How `EditorM` is represented** (rdm `workspace-and-ports`). Bindings
  store `EditorM` actions, so this decides whether a keymap is one concrete
  type. Type classes would make it `Keymap m`, against the constraint that
  config is evaluated at one concrete type. A record of functions passed by
  reader, or a free-monad program, keeps it concrete.
- **The interrupt key in the minibuffer.** It does not close a prompt: it
  is stepped like any key, and neither scheme binds it there ("The
  minibuffer"). Binding it to `minibuffer-cancel` in the minibuffer under
  each scheme is the alternative, and under the Vim scheme whether `C-c`
  should cancel as well as `<Escape>`.
- **How many candidates the scene lists.** Every one the text matches, in
  the minibuffer's status line ("A prompt's candidates"). The lists that
  ship are five names. A list of thousands would put thousands of fields
  in the scene at each key: a limit, or a window of about ten round the
  choice, is the better design for it, and a view of their own for the
  candidates once the display pipeline has popups.
- **Case in fuzzy matching.** Case is kept, so `Re` does not match
  `reload`, and a decomposed character does not match its composed form
  ([rust-library.md](rust-library.md), "Fuzzy matching, as built").
  Folding ASCII case, in the Rust core and the Lean model in one commit,
  is the alternative.
- **Whether the choice should wrap** from the last candidate to the first.
  As built it passes through "nothing chosen", which is the typed text.
- **Whether accepting with nothing chosen should take the first match.**
  As built it takes the typed text, so no prompt that shipped before
  candidates changed.
- **`S-TAB` on a real window.** Whether Shift and Tab arrive from every
  window system as the key `S-TAB` names has not been checked.
- **The empty last row is not a line for a cursor** ("Where a cursor
  rests"). This follows Vim on files. The alternative is Emacs's: the end
  of a text that ends in a line feed is a place a normal-state cursor may
  rest, which removes the consequence after an insert and makes `G` on a
  file land one row below Vim's.
- **Carried structural captures.** A new line's level is asked of the
  text before the break, whose tree is delivered, so the syntax tree port
  gains nothing ("Indenting a new line"). A replay or a macro that types
  and breaks lines in one command asks of a revision with no tree, and
  gets the row's own indent. Carrying the delivered tree's indents captures
  through the patch to a newer revision, as highlights are carried, would
  answer it; it is a Rust, FFI, model and contract addition, and sits
  beside "a job's wait for a parse".
- **An electric closing bracket.** `}` typed as a row's first character
  does not re-indent the row (Vim's `indentkeys` `0}`); `=` does.
- **Insert state's other editing keys** ("Insert state"). `<Backspace>`,
  `RET`, `TAB` and the arrow keys are built; `C-w`, `C-u`, `C-o`, `C-r`,
  `<Home>` and `<End>` are not. Dot repeat replays the built keys as Vim
  does.
- **A count before `i a I A o O` is ignored.** Vim repeats the insert.
  Dot repeat is built and replays a session's text, so the repeat is now
  a matter of running that replay `count - 1` times when the session
  ends; it is not built.
- **The empty last row and operators** ("Where a cursor rests", "Operators
  as built"). A cursor cannot rest on a last line that an operator or `o`
  and escape emptied, when the text has no final line feed. Letting a
  normal-state cursor rest in the empty last row of such a text would
  remove the departure, and is phase 11's rule to change.
- **What `u` does to the cursor** ("Undo and redo"). The phase asks for
  the cursor from before the change; Vim leaves it at the start of the
  changed text. A step whose first edit was typed text hands back the bar
  the insert began at, which for `a` is the cell after the cursor's.
- **A text read from the clipboard is line-wise when it ends in a line
  feed** ("Registers"). The clipboard holds a text and no flag; whoever
  binds a system's clipboard may be able to carry one.
- **A change over a visual selection is not repeated** ("The last
  change"). Vim repeats it over the same amount of text from the cursor.
- **A change whose command writes a store is not repeated** ("The last
  change"): a command run inside another has nothing written back
  ([concurrency.md](concurrency.md), "Prompts"). No command that ships is
  one; a config that binds a store's command as changing text would need
  the replay to carry the write.
- **`p` and `P` in a visual state and named registers** are not built.
  Text objects are ("Text objects as built").
- **A put that ends in a cell of more than one character** carries the
  start of its last character as the cursor after, and places the cursor
  on the cell's start, so a redo of it lands inside the cell.
- **A committed text is dropped where the view takes no text** ("Insert
  sessions"). The alternative is to leave the commit as it was, which
  lets an input method's text replace the character under a normal-state
  cursor.
- **The column of a cursor on a tab** ("The wanted column"). It is the
  tab's first display column, and Vim's is its last. Vim's needs the x of
  a character's last cell, which the display interface does not answer.
- **The status line's order and the face names**: the state's badge
  first, in the face `mode-line.state.` followed by the state's name, as
  the segmented mode line's default order puts it (theming phase 5,
  `lean/Editor/ModeLine.lean`); the cursor faces `cursor.` followed by
  the state's name.
- **A view follows by the least movement** ("Scrolling as built";
  [text-and-display.md](text-and-display.md), "Views as built"). Vim
  centres the cursor's line after a far jump. Centring is another target
  of the same policy (`Scroll.follow`), when wanted; it needs to know how
  far off the cursor is, which is a third question of layout or a count of
  moves.
- **The scroll margin is editor state set by a command.** It could be a
  setting config declares in `setup`, which is its home once there are
  settings: today config cannot set it when it loads. It is one number
  for every view, where Vim's `scrolloff` is global or a window's.
- **`C-d`, `C-u`, `C-f` and `C-b` keep the cursor's column**, Neovim's
  default, where Vim's goes to the first non-blank, as `G` and `g g` do
  here.
- **`C-f` and `C-b` move a whole view with no overlap**, and the cursor
  keeps its row of the view. Vim keeps two lines of the page before and
  puts the cursor on the new page's first line.
- **A text that fills its view exactly is scrolled as one shorter than
  its view.** How many rows a view has room for is not asked of the
  display, and the two cannot be told apart by the rows it answers
  ([text-and-display.md](text-and-display.md), "Views as built", "How
  many rows a view has room for is missing"). So `z z` never moves the
  anchor of a view that shows its whole text from the text's first row,
  where Vim, in a view the text fills, scrolls for a cursor below the
  middle; and a scroll margin larger than half such a view shows the
  text from its first row. In a view taller than its text `C-d` and
  `C-u` move the cursor half the text's rows, not half the view's.
- **A count before `C-d` is not remembered.** Vim's sets the `scroll`
  option for later `C-d` and `C-u`; remembering it is one more number of
  editor state.
- **A follow that is refused says nothing**
  ([text-and-display.md](text-and-display.md), "Publishing"). The
  alternative puts a second line in the echo area for a marker a command
  gave up, in place of what that command was told.
- **Scrolling has not run over real layout.** With rows of several
  heights, "half the rows the view fits" is not half the view, and with a
  status row the last row the query answers is behind it
  ([text-and-display.md](text-and-display.md), "Open questions", "The
  height of a view's text area").
- **The headless `scene` prints neither the cursor's shape nor the
  selection's shape.** The state's name is in the status line it prints;
  the shapes are checked on the models, where a scene is data. Adding
  them changes every scene fixture.
- **A command run by its name enters no Vim state** ("What a scheme
  reports of a view"): `run insert` leaves the view in the state it was
  in and says nothing. Entering a state by a command's name would need
  the scheme to be told of it, as it is told that a view is the
  minibuffer's. Nothing built needs it: what runs a command by name is
  the headless `run`, a prompt's continuation and a key that config
  binds to a name.
- **The vocabulary is a compiled table.** Registering a motion or an
  operator from `setup`, by owner, is not built ("Vocabulary").
- **A motion is a command that changes nothing by rule, not by type**
  ("Vocabulary"). Its target is `EditorM`, so that `j` and `k` can ask the
  display; a narrower type, one that admits the text port and the
  display's queries and nothing else, is not built.
- **One cursor.** The evil commands read the primary range and place one
  range.
- **`gg` and `G` go to the first non-blank**, Vim's default; Neovim's
  default keeps the column.
- **A scheme may not change its report at a key that yields nothing**
  (`quietKeyKeepsReport`). That forbids a scheme that changes a view's
  cursor while an operator is pending, which Vim itself does.
- **The minibuffer's buffer has one undo step for its whole prompt**
  ("Insert sessions").
- **A stale wanted column after an edit through another window** ("The
  wanted column"), and **a split made from a view in a visual or insert
  state**, whose copied selection has another shape than its new view's
  state until the next evil command places it. No built command splits.
- **Requests per key.** A motion makes several requests of the text port:
  the selection, the motion, three or four for the resting rule, the
  placement, and one state request. Nothing is measured. If typing or a
  held `j` is slow, the resting rule can become one question of the port,
  which is a change to the Rust library.
- **Text objects on `i` and `a`** are settled: while an operator waits,
  normal state walks its pending keymaps, which hold the objects and not
  its commands ("Which keymaps a key is looked up in").
- **The `kbd` macro.** Macros need the `Lean` package at elaboration time,
  and importing it at runtime is what the memory figures in
  [lean-runtime.md](lean-runtime.md) argue against. Not measured, and not
  built: `Key.parse` is a function that runs when it is called.
- **Characters the layout composes with Alt.** On macOS, Option with a
  letter arrives as another character (`ø`) with alt held, so a binding
  written `M-o` does not match it. A chord keeps the character the
  platform reported.
- **Binding by physical key.** A chord drops the physical key, so a binding
  cannot say "the key where `h` is on a QWERTY keyboard, whatever the
  layout".
- **Unreachable bindings.** A binding under a bound sequence is never
  reached, and nothing reports it.
- **Not verified:** that `#guard` in interpreted config is fast enough to
  run on every reload; how well the Plausible property-testing library
  works on the pinned toolchain.
