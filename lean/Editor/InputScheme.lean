import Editor.Invocation
import Editor.Keymap
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
prints.

## What every scheme must do

`Editor/InputScheme/Contract.lean` is the contract check every scheme runs:
a strict prefix of a complete input yields nothing and is reported as
pending, and a key that continues nothing resets the pending keys. The
record carries no equality on `State`: a scheme's state may hold what a
reset must keep, so the contract speaks of `pending` and of what the scheme
then yields.

The scheme that ships is not here: it is the Vim scheme
(`Editor/InputScheme/Vim.lean`). `Editor/InputScheme/Test.lean` is the test
scheme, published for other modules' tests.

## Where an addition goes

| Addition | Where |
|---|---|
| A new scheme | A value of `InputScheme` in a module of its own, which runs the contract check |
| Something every scheme must report to the core | A field of `InputScheme`, and a property of the contract |
| Something one scheme remembers between keys | That scheme's `State`; nothing here |
| A fact about a key that more than one scheme reads | A function of `Key` here, as `Key.printed?` is |

Pinned by `ModelTest.schemeChecks`, on the test scheme.
-/

namespace Editor

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

/-- The text `key` prints, if it is printable: its logical key is a
character, and none of control, alt and super is held. It is the key's own,
so every scheme that yields a self-insert reads it here. -/
def Key.printed? (key : Key) : Option String :=
  match key.logical with
  | .character text =>
    if key.modifiers.control || key.modifiers.alt || key.modifiers.superKey then none else some text
  | _ => none

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
