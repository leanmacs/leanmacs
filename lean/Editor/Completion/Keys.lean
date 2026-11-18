import Editor.Completion
import Editor.Scene

/-!
# The key hints as a completion source

The keys that can follow a pending prefix (`Loop.keyHints`,
`InputScheme.continuations`), listed through the completion display config
chose for the category `key` once the key hint delay has passed
(`docs/design/keymaps-and-modes.md`, "The key hints").

## The `key` source

`source hints` is a source of the category `key` whose candidates are the
hints, one a key that can follow, in the scheme's order:

- **The text is the key**, as a key string names it (`SPC`, `C-s`, `f`).
- **The annotation** is the binding's description, or `+<name> (<count>)`
  for a named prefix and `+prefix (<count>)` for an unnamed one, the count
  being the bindings the walk can reach under it. A binding with no
  description has none.
- **The kind** is `binding` or `prefix`.

It has filtered already (`Source.filtered`), so no style matches it: the
loop asks it with an empty query (`Loop.keyHinted`), and the listing never
narrows on typed text. Typing walks the keymaps, as it does with no hints
shown, and the list follows the walk: a key is never consumed by the list.

It is made per publish from the input scheme's state, which no registered
source can see, so it is not registered (`Config.Registry`); a source of
config's in the category `key` is not asked.

## The delay

`Delay` is how long a prefix is pending before its hints are shown:
`.after ms`, in milliseconds, written as a number (`keyHintDelay 250`,
`keyHintDelay 0` for at once), or `.never`, which turns them off
(`keyHintDelay`, `Editor/Setup.lean`). A delay longer than `longest` is
refused (`keyHintDelayTooLong`). The editor's own is `Loop.keyHintDelay`.

## Where an addition goes

| Addition | Where |
|---|---|
| Another annotation of a hint | `annotation` |
| Something more a hint's candidate carries | `candidate`, from a field of `KeyHint` (`Editor/Scene.lean`) the scheme fills |
| A display for the hints | config's `defineDisplay` and `useDisplayFor "key"`, not code here |

Pinned by `ModelTest.keyHintSourceChecks` and, against the sources'
contract, `ModelTest.sourceContractChecks`.
-/

namespace Editor.Completion.Keys

/-- The category of the key hints' source and listing, `key`: the display
config chose for it draws them. It is the state's
(`KeyHintList.category`, `Editor/State.lean`), which shows the listing
and which this module's import of the port puts upstream of it. -/
def category : String :=
  KeyHintList.category

/-- The name of the key hints' source. -/
def sourceName : String :=
  "keys"

/-- What a hint's candidate is annotated with: a binding's description, or
`+<name> (<count>)` for a named prefix and `+prefix (<count>)` for an
unnamed one. -/
def annotation : KeyHint.Leads → Option String
  | .binding desc => desc
  | .prefix (some name) count => some s!"+{name} ({count})"
  | .prefix none count => some s!"+prefix ({count})"

/-- The candidate of `hint`: its key, annotated (`annotation`), of the kind
`binding` or `prefix`. -/
def candidate (hint : KeyHint) : Candidate :=
  { text := hint.key, annotation := annotation hint.leads
    kind :=
      some
        (match hint.leads with
        | .binding _ => "binding"
        | .prefix .. => "prefix") }

/-- The candidates of `hints`, in order. -/
def candidates (hints : Array KeyHint) : Array Candidate :=
  hints.map candidate

/-- The `key` source of `hints`: it answers their candidates, whatever it
is asked, and has filtered already, so no style matches them. -/
def source (hints : Array KeyHint) : Source :=
  { Source.fixed sourceName category (candidates hints) with filtered := true }

/-- How long a prefix is pending before its hints are shown: after some
milliseconds, `0` being at once, or never. -/
inductive Delay where
  /-- After `ms` milliseconds. -/
  | after (ms : Nat)
  /-- Never: the hints are off. -/
  | never
  deriving DecidableEq, Repr

/-- A number is a delay of that many milliseconds, so config writes
`keyHintDelay 250`. -/
instance : OfNat Delay n :=
  ⟨.after n⟩

/-- The longest delay config may set, in milliseconds: a minute. -/
def longest : Nat :=
  60000

/-- What a delay longer than `longest` is refused with. -/
def keyHintDelayTooLong (ms : Nat) : String :=
  s!"a key hint delay of {ms} ms is longer than a minute: write `keyHintDelay .never` to turn the hints off"

end Editor.Completion.Keys
