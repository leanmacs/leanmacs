import Editor.Completion.AtPoint

/-!
# The contract of at-point sources

What every at-point source (`Editor/Completion/AtPoint.lean`) keeps, as one
list of properties. `model-test` runs it against the model
(`AtPoint.fixed`) and each shipped at-point source
(`ModelTest.atPointContractChecks`), and sees it fail on a broken one. This
module imports only the interface, so the contract never depends on a
source or on how one is run.

## What it asks

It asks over a table of texts (`texts`: empty, ASCII, one with a two-byte
character, two lines, a CRLF), at every position of each, the end
included, on every occasion (`occasions`: a key, a trigger and a pause):

- **An answer's region holds the offset**: `start ≤ offset ≤ stop ≤` the
  text's size, and both ends are positions of the text, never inside a
  character. The editor replaces that region; an answer outside it would
  make a session the cursor is already out of.
- **An at-point source reads and does not write.** Asking it leaves the
  editor state and the text's revision as they were. It is asked inside the
  asking command, at every key that asks.

## How it is run

The properties are handed a runner (`Runner`): what asks a source on a
fixture of one buffer holding a text, from one window, and says what it
answered and whether it left the state and the text as they were. The
runner is the caller's, so the fixture and the models stay out of this
module.
-/

namespace Editor.Completion.AtPointContract

/-- How the contract asks an at-point source: `run text spot atPoint` asks
`atPoint` at `spot.offset` of a buffer holding `text`, on `spot.occasion`,
and answers what it answered and whether the editor state and the text's
revision were left as they were; `none` when it was refused. The spot's view
is the runner's to fill. -/
abbrev Runner :=
  (text : String) →
    (offset : Nat) → (occasion : Occasion) → (atPoint : AtPoint) → Option (Option Region × Bool)

/-- One property of at-point sources. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Whether it holds of `atPoint`, asked through `run`. -/
  holds : (run : Runner) → (atPoint : AtPoint) → Bool

/-- The texts the properties ask over: empty, ASCII, one with a two-byte
character, two lines, and a line ended by CRLF. -/
def texts : List String :=
  ["", "alpha be", "café au", "one\ntwo", "ab\r\ncd"]

/-- The occasions the properties ask on: a key, a trigger of `.`, and a
pause of 240 ms, the one `words` declares. -/
def occasions : List Occasion :=
  [.key, .trigger '.', .pause 240]

/-- The positions of `text`: the byte offset of each character's start, and
its end. -/
def positions (text : String) : List Nat :=
  let (starts, size) :=
    text.foldl (fun (starts, walked) char => (walked :: starts, walked + char.utf8Size)) ([], 0)
  (size :: starts).reverse

/-- Whether `region`, answered at `offset` of `text`, holds the offset, with
both ends positions of the text. -/
def holdsOffset (text : String) (offset : Nat) (region : Region) : Bool :=
  let places := positions text
  region.start ≤ offset && offset ≤ region.stop && region.stop ≤ text.utf8ByteSize &&
    places.contains region.start &&
    places.contains region.stop

/-- Whether `check` holds of every answer `run` gives at every position of
every text, on every occasion; `false` when an ask is refused. -/
def everywhere (run : Runner) (atPoint : AtPoint)
    (check : String → Nat → Option Region → Bool → Bool) : Bool :=
  texts.all fun text =>
    (positions text).all fun offset =>
      occasions.all fun occasion =>
        match run text offset occasion atPoint with
        | some (answer, kept) => check text offset answer kept
        | none => false

/-- The properties every at-point source keeps. -/
def properties : List Property :=
  [{  name :=
        "an answer's region holds the offset: start ≤ offset ≤ stop ≤ the text's size, both ends positions of the text, at every position of every text, on every occasion"
      holds := fun run atPoint =>
        everywhere run atPoint fun text offset answer _ => answer.all (holdsOffset text offset) },
    { name :=
        "an at-point source reads and does not write: asked at every position of every text, on every occasion, it is not refused and leaves the editor state and the text's revision as they were"
      holds := fun run atPoint => everywhere run atPoint fun _ _ _ kept => kept }]

end Editor.Completion.AtPointContract
