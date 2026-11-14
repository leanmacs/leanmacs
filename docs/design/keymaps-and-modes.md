# Keymaps and modes

How a key becomes a command, how Vim-style editing is built on that, how
modes contribute keys and behaviour, and how all of it is tested.

Status: partly built. The core's keymaps, input schemes and invocations
are built, in Lean with no port, with the test scheme and the contract
every scheme runs, and so are the Vim scheme's grammar, with its default
states and bindings, and modes:

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

The command loop steps every key press through its one scheme and runs the
invocation it yields, as a command looked up by name in the registry. The
Vim scheme ships, but no motion, operator or command its keys name is
registered yet, so under it a default key echoes `<name>: no such command`.
No mode ships either: modes are built and tested with the modes their tests
define. Of the rest of this document, the vocabulary is a proposal from a
design discussion, and nothing is measured. The one settled input is the
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
```

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
  **How the minibuffer takes keys** is still open, and goes with the
  minibuffer.
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
  to its end (no such command, a refusal, an interrupt), the scheme goes
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
  - Consequence: until the `insert` command is registered, `i` under the
    Vim scheme echoes `insert: no such command` and the view stays in
    normal state.
- **What a command is run with** (`Call`): the focused window and its
  buffer, the invocation's arguments unchanged, and the keys that yielded
  it, which are what the scheme reported as pending before the last key,
  then that key's chord. The count is one of the arguments, where the
  scheme laid it out ("Counts"); `Invocation` has no count field, so a
  command has one answer for its count.
- **The scene shows the pending keys**, as a key string
  (`Key.notations`): empty once a sequence completes and after an unbound
  key.
- **A failure is said in the echo area** and the editor keeps running:
  `<name>: no such command`, `<name>: refused: <error>` or
  `<name>: interrupted`. The echo is cleared when an invocation runs, and
  not by a key that yields nothing. What the command did is rolled back
  ([concurrency.md](concurrency.md), "Foreground: commands").

### Vocabulary

Motions, operators and text objects are registered in the core as data,
separately from any keymap:

```lean
structure Motion where
  name     : Name
  linewise : Bool
  target   : Nat → Cursor → EditorM Cursor   -- count, from, to
```

The grammar belongs to a scheme; the vocabulary belongs to everyone. The
delete operator and the word motion are the same two values whether a
scheme composes them as `dw`, as select-then-delete, or as one `kill-word`
command.

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
- Vocabulary, once it exists: motions, operators and text objects follow
  the same pattern (entries by owner, replaced as a set, the latest wins).
  No table of them is built until they have a type.
- The role set and the leader convention described under Modes, with each
  scheme's role table and leader as fields of the scheme.

## The Vim scheme

Status: the grammar is built (`lean/Editor/InputScheme/Vim.lean`, namespace
`Editor.Vim`), with the default states and bindings
(`lean/Editor/InputScheme/Vim/Default.lean`). It is the grammar only: keys
in, an invocation out, in pure Lean on the scheme interface, checked with
no editor API. What a motion or an operator does to a text is not built,
and no name the scheme yields is registered.

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
  the normal-state cursor off the line break, what an operator does with an
  extent, `curswant`, and the motions.

Keymaps are not indexed by Vim state in their types. That would need a
closed set of states, which conflicts with states being open.

### What a key is bound to

```lean
structure Operator where
  name    : String                  -- its vocabulary name
  changes : Bool := true            -- an edit with it changes text
  enters  : Option String := none   -- the Vim state the view is in after it

structure Command where
  name    : String                  -- the command's name, as the registry names it
  changes : Bool := false
  enters  : Option String := none

inductive Bound where
  | motion     (name : String)
  | operator   (operator : Operator)
  | textObject (name : String)
  | command    (command : Command)
  | register
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
- **A motion needs only its name.** Whether it is line-wise is the
  vocabulary's, read when the edit runs.
- **`register`** is the key that begins a register's name (`"`). See
  Registers.

### Edits

```lean
inductive Over where
  | motion (name : String) | textObject (name : String) | lines | selection

inductive Edit where
  | move    (motion : String) (count : Option Nat)
  | operate (operator : Operator) (over : Over) (count : Option Nat) (register : Option String)
  | run     (command : Command) (count : Option Nat) (register : Option String)
```

The rules of the grammar:

- A motion alone is a `move`. After an operator it is the operator's
  target.
- A text object after an operator is its target. With no operator waiting
  it is dropped, and the input is reset.
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
| `move m c` | `move`, with `[.str m, .nat c]` |
| `operate o over c r` | `operate`, with `[.str o.name, .str kind, .str name, .nat c, .str r]`. Kind and name are `motion` and the motion, `text-object` and the object, `lines` and `""`, `selection` and `""` |
| `run cmd c r` | `cmd.name`, with `[.nat c, .str r]` |

The two command names are constants of the scheme (`Vim.moveCommand`,
`Vim.operateCommand`). The commands are registered with the vocabulary, not
here.

- **`pending` is every key of the edit begun**, as chords: counts, the
  register prefix and the operator included, so `d 2` after `d2`. The
  scheme contract requires a strict prefix to be reported key for key, and
  it is what Vim shows.
- **Typed text is a self-insert, and not an edit.** `Vim.selfInsert text`
  is the invocation `self-insert` with `[.str text]`. It is yielded for a
  key that is unbound and prints, typed with no edit begun, for a view
  whose Vim state inserts text; it leaves the scheme's state as it was. In
  any other state such a key yields nothing. An unbound key after a prefix
  is dropped with the prefix, in an inserting state too. How typed text
  joins the last change is not built.

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
  editor state.
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
  That it extends the selection is the command's, when the edit runs.

### Vim states

```lean
structure StateRecord where
  name                : String
  keymaps             : List (Keymap Bound) := []
  cursor              : CursorShape := .block
  insertsText         : Bool := false   -- an unbound printable key is text, and a digit is not a count
  operatesOnSelection : Bool := false   -- an operator acts on the selection at once

structure States where
  initial : StateRecord
  others  : List StateRecord := []
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
- The selection shape a state gives a cursor is added to the record with
  the text store's shapes.

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
- **A record has no equality.** It holds keymaps, and a keymap derives
  none, so neither `StateRecord` nor `States` does. The scheme's `State`
  holds names and edits only and has a decidable equality. A check compares
  two records by their fields.
- The scene's cursor shape and status field will read the view's state
  through the scheme's state (`Vim.State.record`, `Vim.State.stateOf`).
  That wiring is not built.

### Which keymaps a key is looked up in

For a key for a view whose Vim state has the record `record`, the walk runs
over `maps view ++ record.keymaps`: the active keymaps passed to `step`
first, in their own order, then the state's.

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

### The last change

`lastChange : Option Edit` in the scheme's state is the last edit that
changed text, as a value: what dot repeat replays.

- An edit replaces it when it changes text: an `operate` whose operator
  has `changes`, a `run` whose command has it, and never a move. So `d2w`
  is the last change, and `w` and `yw` after it leave it as it was.
- A reset keeps it, and so does entering a state. Typed text is not an
  edit and does not replace it.
- It is one for the scheme, not one a view.
- Replaying it, and the text typed in an insert session as part of it, are
  not built.

### Default bindings

`Vim.Default` holds the scheme's default keys as data: tables of key string
and `Bound`, the keymaps made from them, the four state records, and
`Vim.Default.scheme`, the scheme that ships. The root module imports it, so
config sees `Vim.Bound`. The grammar's module names no key.

The names in the tables are the vocabulary names and command names that
the motions, operators and commands will be registered under. A name is
changed in its row and in its registration together. No grammar check names
a default, so renaming one breaks none.

| Table | Keys |
|---|---|
| `motions` | `h` left, `j` down, `k` up, `l` right, `w` word-forward, `b` word-backward, `e` word-end, `W` bigword-forward, `B` bigword-backward, `E` bigword-end, `0` line-start, `^` line-first-non-blank, `$` line-end, `g g` first-line, `G` last-line |
| `operators` | `d` delete, `c` change (enters insert), `y` yank (changes no text) |
| `normalCommands` | `i` insert, `a` append, `I` insert-line-start, `A` append-line-end, `o` open-below, `O` open-above (each enters insert and changes text); `x` delete-char, `p` put-after, `P` put-before (each changes text); `u` undo, `C-r` redo, `.` repeat, `:` ex; `v` visual, `V` visual-line (each enters that state); `"` the register prefix |
| `insertCommands` | `<Escape>` normal (enters normal) |
| `visualCommands` | `<Escape>` and `v` normal, `V` visual-line, `"` |
| `visualLineCommands` | `<Escape>` and `V` normal, `v` visual, `"` |

| State | Keymaps, in precedence order | Cursor | The grammar reads |
|---|---|---|---|
| `normal`, the initial state | `normalCommands`, `operators`, `motions` | Block | |
| `insert` | `insertCommands` | Bar | Typing is text |
| `visual` | `visualCommands`, `operators`, `motions` | Block | Operators act on the selection |
| `visual-line` | `visualLineCommands`, `operators`, `motions` | Block | Operators act on the selection |

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
`lean/Editor/State.lean`; the module docs have the detail). No mode ships.

A mode is a value in a registry keyed by name. It is not a type class,
because instances resolve at elaboration time and the active mode is chosen
at runtime. It is not a closed inductive, because config must be able to
add modes.

```lean
structure Mode where
  name    : String
  parent  : Option String := none                -- derived modes
  roles   : List (Role × String) := []           -- role, command name
  locals  : List (String × String) := []         -- suffix as a key string, command name
  onEnter : ViewId → EditorM Unit := fun _ => pure ()
```

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
- **The Vim scheme's table is empty** (`Vim.Default.tuned`): no mode
  ships. The Vim scheme wraps each tuned binding in `Bound.mode`.

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
- **Adding a minor mode runs no action** yet (left open).

Pinned by `ModelTest.modeEnterChecks`, through the loop, and
`ModelTest.apiStateChecks`.

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
  one buffer's mode, of `EditorState` for one per editor). No mode ships,
  so none is added.
- **A config mode uses the store as built**: a `Store α` declared in the
  same `setup`, whose commands (`Store.command`) fill its roles and
  suffixes. Per-buffer state of a config mode is a buffer-local value
  (`BufferId.setValue`, `BufferId.value?`: a plain tree under a name, which
  a reload leaves where it is), or is kept inside its store's value.
  `ConfigTest.modeChecks` runs a config mode's role on a store command.
- **An `onEnter` is a plain `EditorM` program** and cannot write a store.
  It can set a buffer-local value, since that is a request of the editor's
  port.

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
| `vimStateChecks` | Which Vim state a view is in and how one is entered; typed text; an operator over the selection; the last change |
| `vimDefaultChecks` | The default states and bindings, through what each default key parses to |
| `vimContractChecks` | The scheme contract holds of the Vim scheme, over the checks' registry and over the default states |

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
| `ConfigTest.modeChecks` | Through the headless host and the real elaborator: a config mode's role runs its store command, and once a reload drops the mode the role's key runs the global binding; a compiled mode's role runs its command before any reload and after a reload of a config that defines no mode |

Beside them, `stateChecks` pin the three state operations, `registryChecks`
and `reloadChecks` modes by owner and their install, `setupChecks`
`defineMode` and its refusals, `keymapChecks` `Keymap.filter`, and
`vimStateChecks` that a mode's key, a hand-tuned one among them, is typed
text in insert state, that a mode's binding is reached as what it wraps,
and that `Mode.check` under the Vim scheme reads every state's keymaps.

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

Not built: it waits for the vocabulary. The cursor is written into the
fixture:

```lean
#guard runKeys vim "foo |bar baz" "dw" == "foo |baz"
```

This runs on the pure model with no Rust build. The model's contract check
is what makes the result hold for the real binding.

### Who tests what

| Author | Tests | Against |
|---|---|---|
| Scheme | Its grammar, plus the scheme contract check | Nothing, for the grammar: a scheme is pure. The model, for keys against a text, once the vocabulary exists |
| Mode | Its vocabulary; that each role and leader suffix runs the right command | The fake scheme the core publishes |
| Mode, hand-tuned keys | Those bindings | The real scheme they were written for |
| User config | Their own bindings | Whatever they bound against |

- **A mode's tests do not name a scheme's keys.** Typing `j` to test "next
  item" pins a rule the Vim scheme owns (`AGENTS.md`, crate coupling). The
  mode asserts on the role, using the fake scheme with a fixed role table.
- **The core publishes two contract checks.**
  - For schemes, built (`SchemeContract`,
    `lean/Editor/InputScheme/Contract.lean`). A scheme's author gives it
    the scheme, keymaps, a view, inputs the author says are complete and a
    key that goes on with none of them, and it answers the names of the
    properties that do not hold. There are nine: some input has two keys or
    more, so the others are not vacuous; a strict prefix of a complete
    input emits nothing; after a strict prefix the scheme reports its keys
    as pending; the last key emits, and nothing is then pending; an unbound
    key after a strict prefix emits nothing, leaves nothing pending, and
    the input typed next yields what it yields from the initial state; the
    unbound key, bound in a keymap of its own to `scheme.command` of a
    name, yields from the initial state an invocation of that name and
    leaves nothing pending (`namedCommandRuns`); every registered role has
    a key (`everyRoleHasKey`); the leader is not empty, and the roles are
    on distinct keys apart from it (`leaderAndRolesApart`); and the unbound
    key bound to `scheme.modeCommand` of a name runs as `namedCommandRuns`
    asks (`modeCommandRuns`). It is pure and compares no states.
  - The model tests run it on the test scheme, on schemes written there
    that each break one property and are reported (a scheme whose role
    table lacks a role among them), and on both Vim schemes.
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
every build); the second is a proposal.

## Open questions

- **How `EditorM` is represented** (rdm `workspace-and-ports`). Bindings
  store `EditorM` actions, so this decides whether a keymap is one concrete
  type. Type classes would make it `Keymap m`, against the constraint that
  config is evaluated at one concrete type. A record of functions passed by
  reader, or a free-monad program, keeps it concrete.
- **How the minibuffer takes keys.** Which scheme is active where is
  decided: one for the editor ("The loop runs one scheme"). What the
  minibuffer's keys are looked up in goes with the minibuffer.
- **The wanted column and the selection's shape** in the Vim scheme. How
  counts, registers and the visual selection appear in the scheme's state
  and in an edit, and where the current Vim state is held, are built ("The
  Vim scheme"), and how a selection is represented is settled
  ([text-and-display.md](text-and-display.md)). What is open is where the
  column a vertical motion wants is kept, and how entering and leaving a
  visual state changes the selection's shape. The shape a state gives a
  cursor is not yet on its record.
- **Text objects on `i` and `a`.** Vim's text objects begin with `i` or `a`
  (`diw`, `da(`). The default normal state binds both keys as commands, and
  a bound sequence is never also a prefix, so they cannot also begin a text
  object after an operator. The grammar accepts a text object after an
  operator; which keys the default ones are on is not decided.
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
