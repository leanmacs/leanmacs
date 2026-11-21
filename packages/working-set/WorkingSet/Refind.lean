import Editor.Fuzzy
import WorkingSet

/-!
# Finding a stored range again

Where a stored range (`WorkingSet.Stored`) is in its file's text now, after
the file may have changed: `WorkingSet.refind`, a program over the fuzzy
port (`FuzzyM`), so the model tests run it against the fuzzy model and a
command against the library. It reads the text whole and the stored form;
the expected start is the stored start point turned into a byte offset,
clamped (`Point.offsetIn`).

## The ladder

1. **Exact**: the text's bytes at the expected start are the quote. Placed,
   `exact`.
2. **Offset**: every exact occurrence of the quote, scored as rdm scores
   them: the characters the text before it shares with the stored context
   before, from the end, plus those the text after it shares with the
   context after, from the start. The highest score wins, then the
   occurrence nearest the expected start, then the earliest. Placed,
   `moved`.
3. **Fuzzy**, when the quote does not occur:
   - a quote under `fuzzyMinimum` characters is not looked for: drifted;
   - otherwise the fuzzy port is asked `locate` with at most
     `bytes / fuzzyRatio` errors, over the window from `fuzzyWindow` bytes
     before the expected start to `fuzzyWindow` bytes after its end, cut to
     character boundaries;
   - a quote over `fuzzyWhole` bytes is located by its first and its last
     `fuzzyEnds` bytes, cut to character boundaries, each near where it is
     expected, with errors in the same ratio. It is placed when both are
     found, the last starts after the first ends, and the span from the
     first's start to the last's end is between half and twice the
     quote's length;
   - a span found is placed, `changed`.
4. **Drifted**: none of these. The stored form is not moved.

Pinned by `WorkingSetTest.workingSetRefindChecks`.
-/

namespace Editor.WorkingSet

/-- Where a stored range was found again, and how. -/
inductive Placement where
  /-- Where it was stored, unchanged: its byte span. -/
  | exact (start stop : Nat)
  /-- Elsewhere, unchanged: its byte span. -/
  | moved (start stop : Nat)
  /-- Found with errors: its byte span. -/
  | changed (start stop : Nat)
  /-- Not found. -/
  | drifted
  deriving DecidableEq, Repr, Inhabited

/-- The byte span a placement found, if it found one. -/
def Placement.span? : Placement → Option (Nat × Nat)
  | .exact start stop | .moved start stop | .changed start stop => some (start, stop)
  | .drifted => none

/-- Whether `needle` is the bytes of `bytes` from `start`. -/
def bytesAt (bytes needle : ByteArray) (start : Nat) : Bool :=
  start + needle.size ≤ bytes.size &&
    (List.range needle.size).all fun index => bytes.get! (start + index) == needle.get! index

/-- The byte offsets of `bytes` where `needle`, not empty, occurs. -/
def occurrences (bytes needle : ByteArray) : Array Nat :=
  Id.run do
    let mut found := #[]
    if needle.size == 0 || needle.size > bytes.size then
      return found
    let first := needle.get! 0
    for start in [0:bytes.size - needle.size + 1] do
      if bytes.get! start == first && bytesAt bytes needle start then
        found := found.push start
    return found

/-- How many of the characters of `a` and `b` are the same, from the
start. -/
def sharedLead (a b : List Char) : Nat :=
  match a, b with
  | x :: a, y :: b => if x == y then 1 + sharedLead a b else 0
  | _, _ => 0

/-- The score of an occurrence of a quote from `start` to `stop` of `bytes`
against the stored context: the characters shared before it, from the end,
and after it, from the start. -/
def contextScore (bytes : ByteArray) (start stop : Nat) (stored : Stored) : Nat :=
  let lead :=
    Id.run do
      let mut from_ := start - min start (4 * contextChars)
      while from_ < start && !starts bytes from_ do
        from_ := from_ + 1
      return from_
  let tail :=
    Id.run do
      let mut upTo := min bytes.size (stop + 4 * contextChars)
      while upTo > stop && upTo < bytes.size && !starts bytes upTo do
        upTo := upTo - 1
      return upTo
  sharedLead (slice bytes lead start).toList.reverse stored.before.toList.reverse +
    sharedLead (slice bytes stop tail).toList stored.after.toList

/-- `index` moved forward to a character boundary of `bytes`. -/
def boundaryAfter (bytes : ByteArray) (index : Nat) : Nat :=
  Id.run do
    let mut at_ := min index bytes.size
    while at_ < bytes.size && !starts bytes at_ do
      at_ := at_ + 1
    return at_

/-- `index` moved back to a character boundary of `bytes`. -/
def boundaryBefore (bytes : ByteArray) (index : Nat) : Nat :=
  Id.run do
    let mut at_ := min index bytes.size
    while at_ > 0 && at_ < bytes.size && !starts bytes at_ do
      at_ := at_ - 1
    return at_

/-- The distance between two offsets. -/
def apart (a b : Nat) : Nat :=
  if a ≤ b then b - a else a - b

/-- The best exact occurrence of the stored quote in `bytes`, by the offset
step's order, expected at `expected`. -/
def bestOccurrence (bytes quote : ByteArray) (expected : Nat) (stored : Stored) : Option Nat :=
  (occurrences bytes quote).foldl (init := none) fun best start =>
    let score := contextScore bytes start (start + quote.size) stored
    match best with
    | none => some start
    | some other =>
      let otherScore := contextScore bytes other (other + quote.size) stored
      if
          score > otherScore ||
            (score == otherScore && apart start expected < apart other expected) then
        some start
      else some other

/-- Where `text` places `stored` now: the ladder of the module docs. -/
def refind (text : String) (stored : Stored) : FuzzyM Placement := do
  let bytes := text.toUTF8
  let quote := stored.quote.toUTF8
  let expected := stored.start.offsetIn bytes
  if bytesAt bytes quote expected then
    return .exact expected (expected + quote.size)
  if let some start := bestOccurrence bytes quote expected stored then
    return .moved start (start + quote.size)
  if stored.quote.length < fuzzyMinimum then
    return .drifted
  let windowStart := boundaryAfter bytes (expected - min expected fuzzyWindow)
  let windowStop := boundaryBefore bytes (expected + quote.size + fuzzyWindow)
  let window := slice bytes windowStart windowStop
  let near := expected - min expected windowStart
  if quote.size ≤ fuzzyWhole then
    match ← Fuzzy.locate stored.quote window near (quote.size / fuzzyRatio) with
    | some (start, stop) =>
      return .changed (windowStart + start) (windowStart + stop)
    | none =>
      return .drifted
  let headStop := boundaryBefore quote fuzzyEnds
  let tailStart := boundaryAfter quote (quote.size - fuzzyEnds)
  let head := slice quote 0 headStop
  let tail := slice quote tailStart quote.size
  let some (headFrom, headTo) ←
    Fuzzy.locate head window near (headStop / fuzzyRatio) | return .drifted
  let some (tailFrom, tailTo) ←
    Fuzzy.locate tail window (near + tailStart)
        ((quote.size - tailStart) / fuzzyRatio) | return .drifted
  let length := tailTo - min tailTo headFrom
  if tailFrom ≥ headTo && 2 * length ≥ quote.size && length ≤ 2 * quote.size then
    return .changed (windowStart + headFrom) (windowStart + tailTo)
  return .drifted

end Editor.WorkingSet
