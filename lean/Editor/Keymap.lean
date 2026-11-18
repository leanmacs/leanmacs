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
`Keymap.bind`, whose constructor is private, narrowed only by
`Keymap.filter`, which removes bindings and adds none, and read through
`Keymap.find?` and `Keymap.continues`, so another map can replace it behind
them.

A keymap also holds descriptions, for the key hints (`Keymap.descriptions`):
a label of a bound sequence, at most one a sequence, each of a sequence
`bindings` binds. A description belongs to the binding it describes, so
`Keymap.bind` sets it with the binding (`desc`) and drops it when the
sequence is bound again without one, and `Keymap.filter` drops it with the
binding. It is not keyed by the keys alone: one sequence can be bound
differently in two keymaps, and the description read is always that of the
binding the walk reaches. A prefix has no entry, so it has no description;
its name is the caller's (`names`, below).

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

`Keymap.walkOver` walks two tiers, specific keymaps over defaults
(`Keymap.resolveOver`): the specific tier decides a sequence it binds or
begins, so a specific prefix shadows a default binding of the same keys,
and only a sequence it leaves unbound is resolved in the defaults, so
prefixes still merge. The reset is proved for it too
(`Keymap.walkOver_unbound`). The Vim scheme walks its active keymaps over a
state's this way.

## What can follow a prefix

`Keymap.continuations` lists the keys that can follow a pending prefix in a
list of keymaps, and what the walk makes of each (`Keymap.Continuation`): a
binding, with the description of the keymap that binds it, or a further
prefix, with its name and how many bindings under it the walk can reach.
`Keymap.continuationsOver` does the same over two tiers. Both are one
function over the walk's own lookup, `resolve` or `resolveOver`, so each
listed key is what the walk computes for it. The keys come in the order
first seen: the keymaps in precedence order (the specific tier's first),
each keymap's bindings in order. A prefix is named by a function of its
keys that the caller gives (`names`): a prefix has no entry in a keymap, so
its name is a table of its own, outside this module. Its count leaves out a
binding the walk cannot reach from it: one under a shorter bound sequence,
or one a specific tier hides. Nothing pending lists every first key; a
scheme that shows hints only while a prefix is pending says so itself.

The list agrees with the walk both ways, and it is proved: each listed key,
walked after the pending keys, gives what the list says
(`Keymap.walk_listed`, `Keymap.walkOver_listed`), and a key the list leaves
out resets the walk (`Keymap.walk_unlisted`, `Keymap.walkOver_unlisted`).

## What the walk reaches

`Keymap.reachableOver` lists every sequence the walk over two tiers can
complete from rest (`Keymap.Reached`): one `resolveOver` binds, each of
whose strict non-empty prefixes is pending. Each is listed once, the
specific tier's first, with the deciding tier's description. A default
binding a specific prefix or binding shadows is left out, as is a binding
under a shorter bound sequence, so a listed sequence is one a person can
type. That each listed sequence resolves so is proved
(`Keymap.reachableOver_resolves`); that a scheme's walk agrees once the keys
are chords is the scheme contract's (`keyBindingsWalk`).

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
| A reverse question: which sequences are bound to what a predicate keeps (`Keymap.keysFor`) | A function over `bindings` that reads and adds nothing, so the order each was last bound is kept |
| A new way to make a keymap from another, such as keeping the bindings a predicate keeps (`Keymap.filter`) | A function here that only removes or rebinds through `Keymap.bind`, so the invariants hold |
| A label of a bound sequence | `Keymap.descriptions`, set by `Keymap.bind` and kept by `Keymap.filter` |
| What can follow a prefix (`Keymap.continuations`) | A function over `bindings` and `descriptions` that adds nothing, over the walk's own `resolve` or `resolveOver`, with its agreement with the walk proved |
| Every sequence the walk can complete from rest (`Keymap.reachableOver`) | A function over the walk's own `resolveOver`, with what it says of the lookup proved |
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
`Keymap.empty`, `Keymap.bind`, `Keymap.ofList`, `Keymap.ofDescribed` and `Keymap.filter`
only, so every key in it is a chord, no sequence is bound twice, and only a bound sequence is
described. -/
structure Keymap (β : Type) where private mk ::
  /-- The bound sequences, in the order each was last bound: none is empty,
  and no two are equal. -/
  bindings : List (List Key × β)
  /-- The descriptions of bound sequences, for the key hints: each sequence
  here is bound in `bindings`, and none has two. -/
  descriptions : List (List Key × String)
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
  ⟨[], []⟩

/-- `keymap` with the chords of `keys` bound to `binding`, in place of what
that sequence was bound to if it was bound, and described by `desc` when it
is given. A description belongs to the binding, so binding a sequence again
without one drops the one it had. The empty sequence binds nothing: the
keymap is returned as it was. -/
def bind (keymap : Keymap β) (keys : List Key) (binding : β) (desc : Option String := none) :
    Keymap β :=
  let chords := keys.map Key.chord
  if chords.isEmpty then keymap
  else
    ⟨keymap.bindings.filter (·.1 != chords) ++ [(chords, binding)],
      keymap.descriptions.filter (·.1 != chords) ++ (desc.map (chords, ·)).toList⟩

/-- The keymap that binds each sequence of `bindings`; a later entry
replaces an earlier one of the same sequence. -/
def ofList (bindings : List (List Key × β)) : Keymap β :=
  bindings.foldl (fun keymap (keys, binding) => keymap.bind keys binding) empty

/-- The keymap that binds each sequence of `bindings`, described by its
row's description when it has one; a later row replaces an earlier one of
the same sequence, description and all. -/
def ofDescribed (bindings : List (List Key × β × Option String)) : Keymap β :=
  bindings.foldl (fun keymap (keys, binding, desc) => keymap.bind keys binding desc) empty

/-- `keymap` with only the bindings whose binding `keep` keeps, in their
order, and the descriptions of those. Nothing is added, so every key is
still a chord and no sequence is bound twice. -/
def filter (keymap : Keymap β) (keep : β → Bool) : Keymap β :=
  let kept := keymap.bindings.filter (keep ·.2)
  ⟨kept, keymap.descriptions.filter fun (keys, _) => kept.any (·.1 == keys)⟩

/-- What exactly `keys` is bound to. The keys are compared as they are: look
a key from a window up by its chord. -/
def find? (keymap : Keymap β) (keys : List Key) : Option β :=
  (keymap.bindings.find? (·.1 == keys)).map (·.2)

/-- The description of the binding of exactly `keys`, if it has one. -/
def describe? (keymap : Keymap β) (keys : List Key) : Option String :=
  (keymap.descriptions.find? (·.1 == keys)).map (·.2)

/-- The sequences bound to what `keep` keeps, in the order each was last
bound. A sequence bound again to something `keep` does not keep is not
among them: the keymap holds its latest binding only. -/
def keysFor (keymap : Keymap β) (keep : β → Bool) : List (List Key) :=
  keymap.bindings.filterMap fun (keys, binding) => if keep binding then some keys else none

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

/-- A sequence no binding of any keymap in `maps` begins with, or is, is
unbound. -/
theorem resolve_unbound (maps : List (Keymap β)) (keys : List Key)
    (unbound : ∀ keymap ∈ maps, ∀ entry ∈ keymap.bindings, ¬keys <+: entry.1) :
    resolve maps keys = .unbound := by
  have notBound : maps.findSome? (·.find? keys) = none := by
    rw [List.findSome?_eq_none_iff]
    intro keymap member
    simp only [find?, Option.map_eq_none_iff, List.find?_eq_none]
    intro entry present equal
    have same : entry.1 = keys := by simpa using equal
    exact unbound keymap member entry present (same ▸ List.prefix_refl _)
  have notPending : maps.any (·.continues keys) = false := by
    rw [List.any_eq_false]
    intro keymap member
    simp only [continues, List.any_eq_true, not_exists, not_and, List.isPrefixOf_iff_prefix]
    exact unbound keymap member
  simp [resolve, notBound, notPending]

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

/-- What two tiers of keymaps make of `keys`: the `specific` keymaps decide
whenever one of them binds `keys` or a longer sequence that begins with it,
and only a sequence they leave unbound is resolved in the `defaults`. So a
specific prefix shadows a default binding of the same keys, a specific
binding replaces a default one, and prefixes still merge across the tiers:
a sequence pending in the specific keymaps and unbound there once more keys
come is looked up in the defaults with those keys. -/
def resolveOver (specific defaults : List (Keymap β)) (keys : List Key) : Lookup β :=
  match resolve specific keys with
  | .unbound => resolve defaults keys
  | decided => decided

/-- One step of the walk through two tiers of keymaps, `specific` over
`defaults` (`resolveOver`): the keys `pending` so far, followed by the chord
of `key`, are resolved, with the outcomes of `walk`. -/
def walkOver (specific defaults : List (Keymap β)) (pending : List Key) (key : Key) :
    List Key × Option β :=
  let keys := pending ++ [key.chord]
  match resolveOver specific defaults keys with
  | .bound binding => ([], some binding)
  | .pending => (keys, none)
  | .unbound => ([], none)

/-- An unbound key resets the walk: when no binding of any keymap in `maps`
begins with the pending keys followed by the chord of `key`, or is that
sequence, the walk leaves nothing pending and gives nothing. -/
theorem walk_unbound (maps : List (Keymap β)) (pending : List Key) (key : Key)
    (unbound : ∀ keymap ∈ maps, ∀ entry ∈ keymap.bindings, ¬(pending ++ [key.chord]) <+: entry.1) :
    walk maps pending key = ([], none) := by simp [walk, resolve_unbound maps _ unbound]

/-- An unbound key resets the walk over two tiers too: when no binding of
any keymap in `specific` or in `defaults` begins with the pending keys
followed by the chord of `key`, or is that sequence, the walk leaves nothing
pending and gives nothing. -/
theorem walkOver_unbound (specific defaults : List (Keymap β)) (pending : List Key) (key : Key)
    (unbound :
      ∀ keymap ∈ specific ++ defaults,
        ∀ entry ∈ keymap.bindings, ¬(pending ++ [key.chord]) <+: entry.1) :
    walkOver specific defaults pending key = ([], none) := by
  have inSpecific :=
    resolve_unbound specific (pending ++ [key.chord]) fun keymap member =>
      unbound keymap (List.mem_append_left _ member)
  have inDefaults :=
    resolve_unbound defaults (pending ++ [key.chord]) fun keymap member =>
      unbound keymap (List.mem_append_right _ member)
  simp [walkOver, resolveOver, inSpecific, inDefaults]

/-- What a key typed after a pending prefix leads to. -/
inductive Next (β : Type) where
  /-- The sequence is bound, to `binding`, described by `desc` if the
  keymap that binds it describes it. -/
  | bound (binding : β) (desc : Option String)
  /-- The sequence is a prefix, named `name` if it is named, with `count`
  bindings under it that the walk can reach. -/
  | prefix (name : Option String) (count : Nat)
  deriving DecidableEq, Repr

/-- A key that can follow a pending prefix, and what it leads to. -/
structure Continuation (β : Type) where
  /-- The key, as a chord. -/
  key : Key
  /-- What the pending keys followed by `key` are. -/
  next : Next β
  deriving DecidableEq, Repr

/-- What the walk gives for `c`'s key after `pending`, as the continuation
says: nothing pending and the binding, or the keys so far pending and
nothing. -/
def Continuation.walked (c : Continuation β) (pending : List Key) : List Key × Option β :=
  match c.next with
  | .bound binding _ => ([], some binding)
  | .prefix .. => (pending ++ [c.key.chord], none)

/-- One step of a walk, from what a lookup made of the keys so far: the
outcomes of `walk` and `walkOver`. -/
private def outcome (lookup : Lookup β) (keys : List Key) : List Key × Option β :=
  match lookup with
  | .bound binding => ([], some binding)
  | .pending => (keys, none)
  | .unbound => ([], none)

private theorem walk_eq (maps : List (Keymap β)) (pending : List Key) (key : Key) :
    walk maps pending key =
      outcome (resolve maps (pending ++ [key.chord])) (pending ++ [key.chord]) := by
  simp only [walk, outcome]

private theorem walkOver_eq (specific defaults : List (Keymap β)) (pending : List Key) (key : Key) :
    walkOver specific defaults pending key =
      outcome (resolveOver specific defaults (pending ++ [key.chord]))
        (pending ++ [key.chord]) := by
  simp only [walkOver, outcome]

/-- The bound sequences of `maps`, in precedence order, then each keymap's
order. -/
private def sequencesOf (maps : List (Keymap β)) : List (List Key) :=
  maps.flatMap (·.bindings.map (·.1))

/-- The keys that come next after `pending` in some sequence of
`sequences`, each once, in the order first seen. -/
private def nextKeys (sequences : List (List Key)) (pending : List Key) : List Key :=
  (sequences.filterMap fun sequence =>
      if pending.isPrefixOf sequence then sequence[pending.length]? else none).eraseDups

/-- Whether the walk can complete `sequence` from `keys`: `sequence` is
longer and begins with `keys`, `lookup` binds it, and every sequence
strictly between the two is pending. -/
private def reaches (lookup : List Key → Lookup β) (keys sequence : List Key) : Bool :=
  keys.length < sequence.length && keys.isPrefixOf sequence &&
    (match lookup sequence with
    | .bound _ => true
    | _ => false) &&
    (List.range (sequence.length - keys.length - 1)).all fun index =>
      match lookup (sequence.take (keys.length + 1 + index)) with
      | .pending => true
      | _ => false

/-- How many distinct sequences of `sequences` the walk can complete from
`keys` (`reaches`). One hidden under a shorter bound sequence, or behind a
tier that decides otherwise, is not counted. -/
private def beneath (lookup : List Key → Lookup β) (sequences : List (List Key)) (keys : List Key) :
    Nat :=
  (sequences.filter (reaches lookup keys)).eraseDups.length

/-- The keys that can follow `pending`, given the walk's own lookup: for each
key that comes next in some sequence, what `lookup` makes of the keys so far
followed by it, a binding with its description or a prefix with its name
and count. -/
private def continuationsBy (lookup : List Key → Lookup β) (describe : List Key → Option String)
    (sequences : List (List Key)) (names : List Key → Option String) (pending : List Key) :
    List (Continuation β) :=
  (nextKeys sequences pending).filterMap fun key =>
    let keys := pending ++ [key.chord]
    match lookup keys with
    | .bound binding => some ⟨key, .bound binding (describe keys)⟩
    | .pending => some ⟨key, .prefix (names keys) (beneath lookup sequences keys)⟩
    | .unbound => none

/-- The description of `keys` in the first keymap of `maps` that binds them:
the one whose binding `resolve` gives. -/
private def describeIn (maps : List (Keymap β)) (keys : List Key) : Option String :=
  (maps.find? fun keymap => (keymap.find? keys).isSome).bind (·.describe? keys)

/-- The description of `keys` over two tiers, `specific` over `defaults`:
the deciding tier's, the one whose binding `resolveOver` gives. -/
private def describeOver (specific defaults : List (Keymap β)) (keys : List Key) : Option String :=
  match resolve specific keys with
  | .bound _ => describeIn specific keys
  | _ => describeIn defaults keys

/-- The keys that can follow `pending` in `maps`, in precedence order, and
what `walk` makes of each: the keys in the order first seen, through the
keymaps in precedence order and each keymap's bindings in order. A prefix is
named by `names`, given its keys. Nothing pending lists every first key. -/
def continuations (maps : List (Keymap β)) (pending : List Key)
    (names : List Key → Option String := fun _ => none) : List (Continuation β) :=
  continuationsBy (resolve maps) (describeIn maps) (sequencesOf maps) names pending

/-- The keys that can follow `pending` over two tiers, `specific` over
`defaults`, and what `walkOver` makes of each: as `continuations`, the
specific tier's keys first. A binding's description is the deciding
tier's. -/
def continuationsOver (specific defaults : List (Keymap β)) (pending : List Key)
    (names : List Key → Option String := fun _ => none) : List (Continuation β) :=
  continuationsBy (resolveOver specific defaults) (describeOver specific defaults)
    (sequencesOf (specific ++ defaults)) names pending

/-- A sequence the walk can complete from rest, what it is bound to, and its
description. -/
structure Reached (β : Type) where
  /-- The sequence, as chords. -/
  keys : List Key
  /-- What the walk gives at its last key. -/
  binding : β
  /-- The deciding tier's description of it, if it has one. -/
  desc : Option String
  deriving DecidableEq, Repr

/-- Every sequence the walk over `specific` and `defaults` can complete from
rest: `resolveOver` binds it, and every strict non-empty prefix of it is
pending. Each is listed once, in the order first seen through the specific
tier's keymaps and then the defaults', with the deciding tier's
description. A default binding that a specific prefix or binding shadows is
not listed, nor is a binding under a shorter bound sequence. -/
def reachableOver (specific defaults : List (Keymap β)) : List (Reached β) :=
  (sequencesOf (specific ++ defaults)).eraseDups.filterMap fun keys =>
    match resolveOver specific defaults keys with
    | .bound binding =>
      if reaches (resolveOver specific defaults) [] keys then
        some ⟨keys, binding, describeOver specific defaults keys⟩
      else none
    | _ => none

/-- Every sequence `reachableOver` lists is what the walk's lookup binds, and
every strict non-empty prefix of it is pending: the walk over the two tiers
completes it from rest. -/
theorem reachableOver_resolves {specific defaults : List (Keymap β)} {r : Reached β}
    (listed : r ∈ reachableOver specific defaults) :
    resolveOver specific defaults r.keys = .bound r.binding ∧
      ∀ n,
        0 < n → n < r.keys.length → resolveOver specific defaults (r.keys.take n) = .pending := by
  simp only [reachableOver, List.mem_filterMap] at listed
  obtain ⟨keys, _, found⟩ := listed
  split at found
  · next binding bound =>
      split at found
      · next reached =>
          cases found
          refine ⟨bound, fun n positive short => ?_⟩
          simp only [reaches, Bool.and_eq_true, List.all_eq_true, List.mem_range] at reached
          have pending :=
            reached.2 (n - 1)
              (by
                simp at short ⊢; omega)
          have index : 0 + 1 + (n - 1) = n := by omega
          rw [List.length_nil, index] at pending
          split at pending
          · next isPending => exact isPending
          · cases pending
      · cases found
  · cases found

/-- A listed continuation is what the lookup makes of its key. -/
private theorem continuationsBy_walked {lookup : List Key → Lookup β}
    {describe : List Key → Option String} {sequences : List (List Key)}
    {names : List Key → Option String} {pending : List Key} {c : Continuation β}
    (listed : c ∈ continuationsBy lookup describe sequences names pending) :
    outcome (lookup (pending ++ [c.key.chord])) (pending ++ [c.key.chord]) = c.walked pending := by
  simp only [continuationsBy, List.mem_filterMap] at listed
  obtain ⟨key, _, found⟩ := listed
  split at found
  · next binding bound =>
      cases found
      simp [outcome, Continuation.walked, bound]
  · next pending' =>
      cases found
      simp [outcome, Continuation.walked, pending']
  · cases found

/-- A key that begins a sequence after `pending`, and that the lookup does
not leave unbound, is listed. -/
private theorem continuationsBy_complete {lookup : List Key → Lookup β}
    {describe : List Key → Option String} {sequences : List (List Key)}
    {names : List Key → Option String} {pending : List Key} {key : Key} {sequence : List Key}
    (present : sequence ∈ sequences) (begins : pending ++ [key.chord] <+: sequence)
    (decided : lookup (pending ++ [key.chord]) ≠ .unbound) :
    ∃ c ∈ continuationsBy lookup describe sequences names pending, c.key = key.chord := by
  have next : key.chord ∈ nextKeys sequences pending := by
    obtain ⟨rest, equal⟩ := begins
    rw [nextKeys, List.mem_eraseDups, List.mem_filterMap]
    refine ⟨sequence, present, ?_⟩
    simp [← equal]
  simp only [continuationsBy, List.mem_filterMap]
  cases found : lookup (pending ++ [key.chord]) with
  | unbound => exact absurd found decided
  | pending =>
    exact
      ⟨⟨key.chord,
          .prefix (names (pending ++ [key.chord]))
            (beneath lookup sequences (pending ++ [key.chord]))⟩,
        ⟨key.chord, next, by simp [Key.chord_chord, found]⟩, rfl⟩
  | bound binding =>
    exact
      ⟨⟨key.chord, .bound binding (describe (pending ++ [key.chord]))⟩,
        ⟨key.chord, next, by simp [Key.chord_chord, found]⟩, rfl⟩

private theorem mem_sequencesOf {maps : List (Keymap β)} {keymap : Keymap β} {entry : List Key × β}
    (member : keymap ∈ maps) (present : entry ∈ keymap.bindings) : entry.1 ∈ sequencesOf maps := by
  simp only [sequencesOf, List.mem_flatMap, List.mem_map]
  exact ⟨keymap, member, entry, present, rfl⟩

/-- A sequence some binding of a keymap in `maps` begins with, or is, is not
unbound. -/
theorem resolve_ne_unbound {maps : List (Keymap β)} {keys : List Key} {keymap : Keymap β}
    {entry : List Key × β} (member : keymap ∈ maps) (present : entry ∈ keymap.bindings)
    (begins : keys <+: entry.1) : resolve maps keys ≠ .unbound := by
  have continued : maps.any (·.continues keys) = true := by
    rw [List.any_eq_true]
    refine ⟨keymap, member, ?_⟩
    simp only [continues, List.any_eq_true, List.isPrefixOf_iff_prefix]
    exact ⟨entry, present, begins⟩
  unfold resolve
  split <;> simp [continued]

/-- A sequence some binding of a keymap in either tier begins with, or is,
is not unbound over the two tiers. -/
theorem resolveOver_ne_unbound {specific defaults : List (Keymap β)} {keys : List Key}
    {keymap : Keymap β} {entry : List Key × β} (member : keymap ∈ specific ++ defaults)
    (present : entry ∈ keymap.bindings) (begins : keys <+: entry.1) :
    resolveOver specific defaults keys ≠ .unbound := by
  unfold resolveOver
  split
  · next unbound =>
      rcases List.mem_append.mp member with inSpecific | inDefaults
      · exact absurd unbound (resolve_ne_unbound inSpecific present begins)
      · exact resolve_ne_unbound inDefaults present begins
  · next decided notUnbound => exact notUnbound

/-- Every key `continuations` lists, walked after the pending keys, gives
what the list says it leads to. -/
theorem walk_listed {maps : List (Keymap β)} {pending : List Key} {names : List Key → Option String}
    {c : Continuation β} (listed : c ∈ continuations maps pending names) :
    walk maps pending c.key = c.walked pending :=
  (walk_eq maps pending c.key).trans (continuationsBy_walked listed)

/-- A key `continuations` does not list, walked after the pending keys,
leaves nothing pending and gives nothing. -/
theorem walk_unlisted {maps : List (Keymap β)} {pending : List Key}
    {names : List Key → Option String} {key : Key}
    (unlisted : ∀ c ∈ continuations maps pending names, c.key ≠ key.chord) :
    walk maps pending key = ([], none) :=
  walk_unbound maps pending key fun _ member _ present begins =>
    let ⟨c, listed, same⟩ :=
      continuationsBy_complete (describe := describeIn maps) (names := names)
        (mem_sequencesOf member present) begins (resolve_ne_unbound member present begins)
    unlisted c listed same

/-- Every key `continuationsOver` lists, walked over the two tiers after the
pending keys, gives what the list says it leads to. -/
theorem walkOver_listed {specific defaults : List (Keymap β)} {pending : List Key}
    {names : List Key → Option String} {c : Continuation β}
    (listed : c ∈ continuationsOver specific defaults pending names) :
    walkOver specific defaults pending c.key = c.walked pending :=
  (walkOver_eq specific defaults pending c.key).trans (continuationsBy_walked listed)

/-- A key `continuationsOver` does not list, walked over the two tiers after
the pending keys, leaves nothing pending and gives nothing. -/
theorem walkOver_unlisted {specific defaults : List (Keymap β)} {pending : List Key}
    {names : List Key → Option String} {key : Key}
    (unlisted : ∀ c ∈ continuationsOver specific defaults pending names, c.key ≠ key.chord) :
    walkOver specific defaults pending key = ([], none) :=
  walkOver_unbound specific defaults pending key fun _ member _ present begins =>
    let ⟨c, listed, same⟩ :=
      continuationsBy_complete (names := names) (mem_sequencesOf member present) begins
        (resolveOver_ne_unbound member present begins)
    unlisted c listed same

end Keymap

end Editor
