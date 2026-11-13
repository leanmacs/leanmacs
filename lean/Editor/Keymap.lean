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

## The walk

Keys are looked up through a list of keymaps in precedence order
(`Keymap.resolve`): the first keymap that binds the sequence gives its
binding; otherwise the sequence is pending if a binding in any of them
begins with it, and unbound if none does. There is no timeout, so a bound
sequence is never also a prefix. `Keymap.walk` is one key of that: it
returns the keys still pending and the binding reached, if one was. An
unbound key is dropped with the prefix before it; it does not start a new
sequence.

That an unbound key resets the pending prefix is proved, not only checked
(`Keymap.walk_unbound`): its hypothesis is about the bindings, that none
begins with the keys so far, and the kernel checks it on every build.

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
| A new outcome of a lookup, such as a timeout | A variant of `Lookup`, and its case in `Keymap.walk` |
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

/-- What a list of keymaps makes of a key sequence. -/
inductive Lookup (β : Type) where
  /-- No keymap binds the sequence, and no binding begins with it. -/
  | unbound
  /-- No keymap binds the sequence, and a binding of one begins with it: more
  keys are awaited. -/
  | pending
  /-- A keymap binds the sequence, to `binding`. -/
  | bound (binding : β)
  deriving DecidableEq, Repr

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

/-- What `maps`, in precedence order, make of `keys`: the binding of the
first keymap that binds exactly `keys`; otherwise pending, if a binding of
any of them begins with `keys`; otherwise unbound.

So a sequence that is bound is never also a prefix: a longer binding under
it, in the same keymap or another, is not reached, since nothing waits to
see whether more keys come. Prefixes merge across the keymaps. -/
def resolve (maps : List (Keymap β)) (keys : List Key) : Lookup β :=
  match maps.findSome? (·.find? keys) with
  | some binding => .bound binding
  | none => if maps.any (·.continues keys) then .pending else .unbound

/-- One step of the walk through `maps`, in precedence order: the keys
`pending` so far, followed by the chord of `key`, are resolved. A bound
sequence gives its binding and leaves nothing pending; a prefix becomes
the pending keys and gives nothing; an unbound sequence is dropped whole,
`key` with it, leaving nothing pending and giving nothing. -/
def walk (maps : List (Keymap β)) (pending : List Key) (key : Key) : List Key × Option β :=
  let keys := pending ++ [key.chord]
  match resolve maps keys with
  | .bound binding => ([], some binding)
  | .pending => (keys, none)
  | .unbound => ([], none)

/-- An unbound key resets the walk: when no binding of any keymap in `maps`
begins with the pending keys followed by the chord of `key`, or is that
sequence, the walk leaves nothing pending and gives nothing. -/
theorem walk_unbound (maps : List (Keymap β)) (pending : List Key) (key : Key)
    (unbound : ∀ keymap ∈ maps, ∀ entry ∈ keymap.bindings, ¬(pending ++ [key.chord]) <+: entry.1) :
    walk maps pending key = ([], none) := by
  have notBound : maps.findSome? (·.find? (pending ++ [key.chord])) = none := by
    rw [List.findSome?_eq_none_iff]
    intro keymap member
    simp only [find?, Option.map_eq_none_iff, List.find?_eq_none]
    intro entry present equal
    have same : entry.1 = pending ++ [key.chord] := by simpa using equal
    exact unbound keymap member entry present (same ▸ List.prefix_refl _)
  have notPending : maps.any (·.continues (pending ++ [key.chord])) = false := by
    rw [List.any_eq_false]
    intro keymap member
    simp only [continues, List.any_eq_true, not_exists, not_and, List.isPrefixOf_iff_prefix]
    exact unbound keymap member
  simp [walk, resolve, notBound, notPending]

end Keymap

end Editor
