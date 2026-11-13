# Keymaps and modes

How a key becomes a command, how Vim-style editing is built on that, how
modes contribute keys and behaviour, and how all of it is tested.

Status: a proposal from a design discussion. Nothing here is built or
measured. The one settled input is the priority: Vim-style editing is the
scheme that ships and is polished; other schemes must stay possible without
being paid for now.

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
- **`step`** is a pure function of the active keymaps, the scheme's pending
  state and the key.
- **`Invocation`** is a command name plus plain arguments. It holds no
  closures, so it can be compared, stored and replayed. A registry maps
  command names to `EditorM` actions.
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

### Input schemes

A scheme is a state machine over keys, packaged with its own state and
binding types:

```lean
structure InputScheme where
  State   : Type
  Binding : Type
  init    : State
  step    : (ViewId → List (Keymap Binding)) → State → Key
              → State × Option Invocation
```

- The core runs a scheme without knowing its `State`. This is an
  existential package: a record with type-valued fields.
- The state is explicit, not hidden in a closure. A self-referential
  `Key → (Machine × Output)` type is inductive in Lean and has no values
  without `partial`. An explicit `State` also keeps `step` open to proof.
- The active keymaps are a function of the view, passed in. There is no
  ambient "current buffer" (see the principles in
  [overview.md](overview.md)).

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

Keys are bound to parts of speech, not to opaque commands:

```lean
inductive Bound where
  | motion     (m : Motion)
  | operator   (o : Operator)
  | textObject (t : TextObject)
  | command    (c : Command)
```

The scheme's `State` holds the count so far, the operator waiting for a
motion, and the prefix walked so far. It parses a key sequence into an
internal `Edit` and compiles that to an `Invocation`:

```lean
inductive Edit where
  | move    (m : Motion) (count : Nat)
  | operate (o : Operator) (over : Target) (count : Nat)
  | run     (c : Command)
```

- **Operator-pending needs no separate keymap.** `w` is bound once, as a
  motion. Alone it moves; after `d` it supplies the range. A motion added
  later, by a mode or by config, works with every operator.
- **Dot-repeat is replaying data.** The last `Edit` is a value in the
  scheme's `State`.
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

## Other schemes

| Scheme | `Binding` | `State` |
|---|---|---|
| Vim | `Bound` | Count, pending operator, prefix |
| Emacs-style | `Command` | Prefix, universal argument |
| Selection-first (Kakoune, Helix) | `Command` | Count, prefix |
| CUA | `Command` | None |

Only the Vim scheme ships. A trivial second scheme lives in the test suite
to keep the interface honest (see Testing).

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
- A key-string macro (`kbd "C-x C-s"`) could parse at elaboration time, so
  a mistyped key is an error in config before it runs. See the open
  questions for its cost.

## Testing

Tests follow the pipeline. Most need no fake.

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
  - For schemes: an unbound key resets, a strict prefix of a binding emits
    nothing, every role has a key.
  - For modes: `Mode.check : Mode → List Problem` reports unregistered
    roles, duplicate suffixes, and hand-tuned keys that shadow a scheme
    binding.

### Config

A reload fails as a whole if any chunk fails to elaborate, and `#guard` is
part of elaboration. So keymap tests written in config run on every reload,
and a failing one keeps the old config.

### Theorems

Stated against the model where they earn their keep: an unbound key always
resets pending state; `x` then `u` restores the buffer.

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
- **Counts, registers and visual selection** in the Vim scheme's `State`
  and `Edit`. How a selection is represented is settled
  ([text-and-display.md](text-and-display.md)); what is open is where the
  scheme keeps which state it is in and the column it wants, and how
  entering and leaving a visual state changes the selection's shape.
- **The `kbd` macro.** Macros need the `Lean` package at elaboration time,
  and importing it at runtime is what the memory figures in
  [lean-runtime.md](lean-runtime.md) argue against. Not measured.
- **Not verified:** that `#guard` in interpreted config is fast enough to
  run on every reload; how well the Plausible property-testing library
  works on the pinned toolchain.
