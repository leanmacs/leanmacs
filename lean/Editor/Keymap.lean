import Editor.Event

/-!
# Keymaps

A keymap binds key sequences, and is parametric in what a sequence is bound
to (`Keymap β`): the core knows only how to walk prefixes, and an input
scheme (`Editor/InputScheme.lean`) says what a binding is. It is plain data
and pure functions over the key type (`Editor/Event.lean`), with no port, so
it is tested under `lake test` with no model and no fake
(`docs/design/keymaps-and-modes.md`).

## The representation

A keymap is a flat list of bound sequences, one entry a sequence and what it
is bound to (`Keymap.bindings`). A sequence is a prefix when some binding
begins with it and is longer; no entry stands for a prefix by itself. The
list is its own specification: what is proved of a keymap is stated over
`bindings`. A lookup is linear in the bindings. The list is made only by
`Keymap.bind`, whose constructor is private, and read through
`Keymap.find?` and `Keymap.continues`, so another map can replace it behind
them.

## The chord

A key from a window carries where it is on the keyboard and whether the
platform repeated it, and a shifted letter arrives as the character `A` with
shift held. A binding names none of that. `Key.chord` is the key as a
binding names it: no physical key, not repeated, and no shift on a
character, since the character already says it. Shift stays on a named key,
so shift with `Tab` is a key of its own. `Keymap.bind` stores chords, and a
caller looks a key up by its chord, so a keymap never holds anything else.

## Where an addition goes

| Addition | Where |
|---|---|
| A new attribute of a key that a binding does not name | Dropped in `Key.chord` |
| A new way to ask what a sequence is bound to | A function over `Keymap.find?` and `Keymap.continues`, not over `bindings` |
| What a key is bound to | The input scheme's `Binding`; nothing here |

Each is pinned by `ModelTest.keymapChecks`.
-/

namespace Editor

/-- A key as a binding names it: `key` with no physical key, not repeated,
and without shift when it is a character, which already says whether it is
shifted. Shift stays on any other key. -/
def Key.chord (key : Key) : Key :=
  { logical := key.logical
    modifiers :=
      match key.logical with
      | .character _ => { key.modifiers with shift := false }
      | _ => key.modifiers }

/-- A chord is its own chord. -/
theorem Key.chord_chord (key : Key) : key.chord.chord = key.chord := by
  cases key with
  | mk logical physical modifiers repeated => cases logical <;> rfl

/-- Bound key sequences, each with what it is bound to. Made with
`Keymap.empty`, `Keymap.bind` and `Keymap.ofList` only, so every key in it
is a chord and no sequence is bound twice. -/
structure Keymap (β : Type) where private mk ::
  /-- The bound sequences, in the order each was last bound: none is empty,
  and no two are equal. -/
  bindings : List (List Key × β)
  deriving Repr

namespace Keymap

variable {β : Type}

/-- The keymap that binds nothing. -/
def empty : Keymap β :=
  ⟨[]⟩

/-- `keymap` with the chords of `keys` bound to `binding`, in place of what
that sequence was bound to if it was bound. The empty sequence binds
nothing: the keymap is returned as it was. -/
def bind (keymap : Keymap β) (keys : List Key) (binding : β) : Keymap β :=
  let chords := keys.map Key.chord
  if chords.isEmpty then keymap else ⟨keymap.bindings.filter (·.1 != chords) ++ [(chords, binding)]⟩

/-- The keymap that binds each sequence of `bindings`; a later entry
replaces an earlier one of the same sequence. -/
def ofList (bindings : List (List Key × β)) : Keymap β :=
  bindings.foldl (fun keymap (keys, binding) => keymap.bind keys binding) empty

/-- What exactly `keys` is bound to. The keys are compared as they are: look
a key from a window up by its chord. -/
def find? (keymap : Keymap β) (keys : List Key) : Option β :=
  (keymap.bindings.find? (·.1 == keys)).map (·.2)

/-- Whether a binding begins with `keys`: is `keys`, or is longer. -/
def continues (keymap : Keymap β) (keys : List Key) : Bool :=
  keymap.bindings.any (keys.isPrefixOf ·.1)

end Keymap

end Editor
