/-!
# A jump list, as plain data

A window's jump list (`docs/design/keymaps-and-modes.md`, "The jump list and
marks") as a pure value over entries of any type: the rules of Vim 9.1's
`mark.c` that `:help jumplist` documents, with no text and no editor state.
The editor state keeps one in each window over places held by markers
(`Editor/State.lean`, `Jumps`), and `Editor/Jumps.lean` reads the lines of
those places and runs these rules on them.

- **Record** (`record`, Vim's `setpcmark`): the entry is appended at the
  end, the oldest is dropped when the list grows past `limit` (Vim's
  `JUMPLISTSIZE`, 100), and the index is set one past the end. Nothing is
  removed at record time.
- **Filter-map** (`filterMap`, `filterMapIdx`): each entry is changed, or
  dropped. The index is carried along with the entry it pointed at, or to
  the next entry kept when that one is dropped, and an index one past the
  end stays one past the end. It is the one place that carries the index:
  the clean-up is one, and so is the editor's detaching and attaching of a
  closed buffer's places (`Jumps.filterMap`).
- **Clean up** (`cleanup`, Vim's `cleanup_jumplist` under the default
  `jumpoptions`): an entry is dropped when a later entry has the same key,
  so the latest of a key is kept, the index carried by `filterMapIdx`.
  The key is the caller's:
  the editor's is the entry's buffer, or file, and line, read when the
  clean-up runs, so that entries edits brought onto one line are one.
- **Step by `n`** (`plan`, the arithmetic of Vim's `movemark`, `C-o` being
  −count and `C-i` +count, on a list already cleaned up): an empty list
  fails, and so does a step that lands outside the list. When the index is
  one past the end, the first step after a jump, the position the step is
  taken from is recorded first, and the step is taken from the entry
  before that new one: the plan says so (`Plan.recordFirst`) with the index
  it lands on in the list as it is once recorded. `apply` takes a plan with
  the entry recorded, and `step` is the two together for a caller that has
  the entry at hand.

Pinned by `ModelTest.jumpListChecks`, which include `:help jumplist`'s
worked example step by step.
-/

namespace Editor

/-- A jump list: the entries, oldest first, and the index of the entry a
step is taken from; one past the end (`entries.size`) when no step was
taken since the last record. -/
structure JumpList (α : Type) where
  /-- The entries, oldest first. -/
  entries : Array α := #[]
  /-- Where a step is taken from: an index of `entries`, or one past the
  end. -/
  index : Nat := 0
  deriving DecidableEq, Repr

namespace JumpList

/-- The most entries a list keeps: Vim's `JUMPLISTSIZE`. -/
def limit : Nat :=
  100

/-- The list with `entry` recorded (Vim's `setpcmark`): appended at the end,
the oldest dropped when there are more than `limit`, and the index one past
the end. -/
def record {α : Type} (list : JumpList α) (entry : α) : JumpList α :=
  let entries := list.entries.push entry
  let entries :=
    if entries.size > limit then entries.extract (entries.size - limit) entries.size else entries
  { entries, index := entries.size }

/-- The list with each entry changed by `change`, told the entry's index, and
dropped where it answers `none`. The index goes with the entry it was at, or
to the next entry kept when that one is dropped, and one past the end stays
one past the end. -/
def filterMapIdx {α β : Type} (change : Nat → α → Option β) (list : JumpList α) : JumpList β :=
  let entries := list.entries
  let (kept, index) :=
    (List.range entries.size).foldl
      (fun (kept, index) from_ =>
        -- The index of the entry being looked at moves to where the next
        -- entry kept goes.
        let index := if list.index == from_ then kept.size else index
        match entries[from_]?.bind (change from_) with
        | some entry => (kept.push entry, index)
        | none => (kept, index))
      ((#[] : Array β), list.index)
  { entries := kept, index := if list.index ≥ entries.size then kept.size else index }

/-- The list with each entry changed by `change`, and dropped where it
answers `none`; the index as `filterMapIdx` carries it. -/
def filterMap {α β : Type} (change : α → Option β) (list : JumpList α) : JumpList β :=
  list.filterMapIdx fun _ => change

/-- The list cleaned up (Vim's `cleanup_jumplist`): each entry that a later
entry has the same key as is dropped. The index goes with the entry it was
at, or to the next entry kept when that one is dropped, and one past the end
stays one past the end (`filterMapIdx`). -/
def cleanup {α β : Type} [BEq β] (key : α → β) (list : JumpList α) : JumpList α :=
  let entries := list.entries
  list.filterMapIdx fun from_ entry =>
    let later := (entries.extract (from_ + 1) entries.size).any (key · == key entry)
    if later then none else some entry

/-- What a step of a list decides ("Step by `n`", in the module docs). -/
structure Plan where
  /-- Whether the position the step is taken from is to be recorded first
  (`record`): the index was one past the end. -/
  recordFirst : Bool
  /-- The index the step lands on, in the list as it is once the position
  is recorded when `recordFirst`. -/
  index : Nat
  deriving DecidableEq, Repr

/-- Where a step by `n` of `list`, already cleaned up, lands (Vim's
`movemark`): `none` for an empty list and for a step outside the list. -/
def plan {α : Type} (list : JumpList α) (n : Int) : Option Plan :=
  let size := list.entries.size
  let landing : Int := list.index + n
  if size == 0 || landing < 0 || landing ≥ size then none
  else
    if list.index ≥ size then
      -- The first step after a jump: the position is recorded, and the step
      -- is taken from the entry before it.
      let recorded := min (size + 1) limit
      let landing : Int := recorded - 1 + n
      if landing < 0 then none else some { recordFirst := true, index := landing.toNat }
    else some { recordFirst := false, index := landing.toNat }

/-- `list` with the step `plan` taken: `entry` recorded first when the plan
says so, and the index where it lands. -/
def apply {α : Type} (list : JumpList α) (plan : Plan) (entry : α) : JumpList α :=
  let list := if plan.recordFirst then list.record entry else list
  { list with index := plan.index }

/-- A step by `n` of `list`, already cleaned up, taken from `here`: the list
after it and the entry it lands on; `none` where `plan` fails, the list
then left as it was. -/
def step {α : Type} (list : JumpList α) (n : Int) (here : α) : Option (JumpList α × α) := do
  let plan ← list.plan n
  let next := list.apply plan here
  let entry ← next.entries[plan.index]?
  return (next, entry)

end JumpList

end Editor
