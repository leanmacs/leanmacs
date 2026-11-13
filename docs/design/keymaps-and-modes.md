# Keymaps and modes

How a key becomes a command, how Vim-style editing is built on that, how
modes contribute keys and behaviour, and how all of it is tested.

Status: partly built. The core's keymaps, input schemes and invocations
are built, in Lean with no port, with the test scheme and the contract
every scheme runs:

| Built | Where |
|---|---|
| Keymaps, a key's chord, the walk and its proof | `lean/Editor/Keymap.lean` |
| Key strings | `lean/Editor/Key/Notation.lean` |
| Invocations | `lean/Editor/Invocation.lean` |
| The scheme interface | `lean/Editor/InputScheme.lean` |
| The test scheme | `lean/Editor/InputScheme/Test.lean` |
| The scheme contract | `lean/Editor/InputScheme/Contract.lean` |

Nothing calls a scheme yet: the command loop drops keys, and running an
invocation is not built. The Vim scheme's grammar is decided and not built
("The Vim scheme"). The rest of this document (the vocabulary, modes,
registering from config) is a proposal from a design discussion, and
nothing is measured. The one settled input is the priority:
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
```

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
  alt and super is held. The name of that invocation is the test scheme's
  own; what the shipped self-insert is is not decided here.

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
- The command registry and `run`.
- The role table and leader convention described under Modes.

## The Vim scheme

Status: decided, not built. This section says what the scheme's grammar is
and where each thing it remembers is held, so that the code is written to
it. It is the grammar only: keys in, an invocation out, in pure Lean on the
scheme interface. What a motion or an operator does to a text is not here.

Keys are bound to parts of speech, not to opaque commands. The scheme's
`State` holds the count so far, the operator waiting for a motion, and the
prefix walked so far. It parses a key sequence into an `Edit` and compiles
that to an `Invocation`.

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
  no prefix are left.

An edit compiles to an invocation, and the layout is the scheme's one rule
for it:

| Edit | Invocation |
|---|---|
| `move m c` | `move`, with `[.str m, .nat c]` |
| `operate o over c r` | `operate`, with `[.str o.name, .str kind, .str name, .nat c, .str r]`. Kind and name are `motion` and the motion, `text-object` and the object, `lines` and `""`, `selection` and `""` |
| `run cmd c r` | `cmd.name`, with `[.nat c, .str r]` |

The commands `move` and `operate` are registered with the vocabulary, not
here.

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
  total, and registering a record replaces one of the same name, the
  initial one included.
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
- **A name the registry no longer has is read as the initial state**, so a
  registry that loses a state strands no view.
- The scene's cursor shape and status field will read the view's state
  through the scheme's state. That wiring is not built.

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
  insert included. A binding meant for one state belongs in that state's
  keymaps. Limiting a mode's key to some states is not built (open
  questions).

## Other schemes

| Scheme | `Binding` | `State` |
|---|---|---|
| Vim | `Bound` | Count, pending operator, prefix |
| Emacs-style | `Command` | Prefix, universal argument |
| Selection-first (Kakoune, Helix) | `Command` | Count, prefix |
| CUA | `Command` | None |

Only the Vim scheme ships. A trivial second scheme, the test scheme, is
published for tests to keep the interface honest (see "The test scheme"
and Testing).

## Modes

A mode is a value in a registry keyed by name. It is not a type class,
because instances resolve at elaboration time and the active mode is chosen
at runtime. It is not a closed inductive, because config must be able to
add modes.

```lean
structure Mode where
  name    : Name
  parent  : Option Name             -- derived modes
  roles   : List (Role × Command)
  locals  : Keymap Command          -- suffixes under the scheme's leader
  onEnter : ViewId → EditorM Unit
  owner   : Owner                   -- replaced as a unit on reload
```

No `Key` for a top-level binding and no scheme's `Binding` type appears in
`Mode`. A mode cannot name the binding type of a scheme it has never heard
of, and it does not need to.

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
def activeMaps : EditorState → ViewId → List (Keymap β)
-- minor modes, then the major mode, then global
```

### Per-mode state

Each mode wants state of its own type. Compiled modes use ordinary typed
fields. Modes defined in config use the store from
[lean-runtime.md](lean-runtime.md): a named cell with an encoding and a
version, which survives a reload that changes the type.

## Extending from config

- Config registers modes, commands, vocabulary and bindings from `setup`,
  tagged with their owner, as [lean-runtime.md](lean-runtime.md) describes
  for bindings and subscriptions. A reload replaces everything an owner
  registered.
- A binding's keys are written as a key string, which `Key.parse` reads:
  an ordinary function, built, that gives the keys or a refusal that names
  the stroke it could not read. Registering a binding from `setup` is not
  built.
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
rest of the model tests are, and not the `#guard`s sketched below: those
remain the proposal for a scheme's own grammar and for config.

### Keys in, invocation out

```lean
#guard parseKeys vim "d2w" == [.operate `delete (.motion `word) 2]
#guard parseKeys vim "dz"  == []      -- an unbound key resets pending state
```

`#guard` evaluates a `Bool` at elaboration time and fails the build if it
is false. `by decide` would give a kernel-checked proof, but kernel
reduction is too slow for strings and maps.

### Keys against the model

The cursor is written into the fixture:

```lean
#guard runKeys vim "foo |bar baz" "dw" == "foo |baz"
```

This runs on the pure model with no Rust build. The model's contract check
is what makes the result hold for the real binding.

### Who tests what

| Author | Tests | Against |
|---|---|---|
| Scheme | Its grammar, plus the scheme contract check | The model |
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
    properties that do not hold. There are five: some input has two keys or
    more, so the others are not vacuous; a strict prefix of a complete
    input emits nothing; after a strict prefix the scheme reports its keys
    as pending; the last key emits, and nothing is then pending; an unbound
    key after a strict prefix emits nothing, leaves nothing pending, and
    the input typed next yields what it yields from the initial state. It
    is pure and compares no states. "Every role has a key" joins it with
    roles.
  - The model tests run it on the test scheme, and on schemes written
    there that each break one property and are reported.
  - For modes: `Mode.check : Mode → List Problem` reports unregistered
    roles, duplicate suffixes, and hand-tuned keys that shadow a scheme
    binding.

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
- **The role set.** Which roles exist at the start, and the rule for adding
  one.
- **Which scheme is active where.** One per editor or one per view; how a
  terminal view or the minibuffer takes keys.
- **The wanted column and the selection's shape** in the Vim scheme. How
  counts, registers and the visual selection appear in the scheme's state
  and in an edit, and where the current Vim state is held, are decided
  ("The Vim scheme"), and how a selection is represented is settled
  ([text-and-display.md](text-and-display.md)). What is open is where the
  column a vertical motion wants is kept, and how entering and leaving a
  visual state changes the selection's shape.
- **A mode's key in some Vim states only.** An active keymap's binding
  holds in every Vim state. Whether a mode's role key can be limited to
  some states goes with the Vim role table.
- **The Vim state of a view that is closed.** The scheme's state keeps an
  entry for each view that is not in the initial state, and the scheme
  interface gives no notice that a view is gone.
- **A command that fails after its key entered a state.** The scheme enters
  the state when the key is parsed, before the invocation runs.
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
