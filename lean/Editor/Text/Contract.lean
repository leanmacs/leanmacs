import Editor.Text

/-!
# The contract of the text port

What every implementation of the text port (`Editor/Text.lean`) does, as one
list of properties. A property is a command that returns whether it held, so
the same list runs against the pure model (`model-test`, under `lake test`)
and against the real binding (`contract-test`, linked with the Rust library).
That is what keeps the model from drifting from the library.

This module imports only the port. The list is plain data, programs that have
not run, so it is a constant: nothing in it calls the library when the module
is initialised.

Offsets are byte offsets. "é" and "ö" are two bytes each, so in `"héllo"` the
offsets 0, 1, 3, 4, 5 and 6 are character boundaries and 2 is inside "é".

A model and a library that each converted positions wrongly in the same way
would pass a round trip. So the conversions are also pinned against a table
written out by hand (`positions`), and the count of positions against the
count of characters.
-/

namespace Editor.TextContract

/-- One property of the text port: a command that observes it. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the property, from an empty store; `true` when it holds. A
  command that fails has not held. -/
  holds : EditorM Bool

/-- Runs `command` and returns whether it was refused with `error`. -/
def refusedWith (error : TextError) (command : EditorM Unit) : EditorM Bool :=
  try
    command
    return false
  catch refusal =>
    return refusal == error

/-- The point of `offset` in `source`, with its column in `unit`; `none` when
it is refused as not a position. Any other refusal fails the command. -/
def pointOf? (source : TextSource) (unit : ColumnUnit) (offset : Nat) : EditorM (Option Point) :=
  try
    return some (← source.ask (.pointOf unit offset))
  catch refusal =>
    if refusal == .badPosition then
      return none
    throw refusal

/-- The offset of `point` in `source`, with its column in `unit`; `none` when
it is refused as not a position. Any other refusal fails the command. -/
def offsetOf? (source : TextSource) (unit : ColumnUnit) (point : Point) : EditorM (Option Nat) :=
  try
    return some (← source.ask (.offsetOf unit point))
  catch refusal =>
    if refusal == .badPosition then
      return none
    throw refusal

/-- Text of three rows, 20 bytes long.

| Row | Bytes | Holds |
|---|---|---|
| 0 | 0 to 7 | `héllo`, a carriage return at 6, then the line feed at 7 |
| 1 | 8 to 14 | `wörld`, then the line feed at 14 |
| 2 | 15 to 20 | `😀x` |
-/
def rows : String :=
  "héllo\r\nwörld\n😀x"

/-- Where one position of a text is. -/
structure Place where
  /-- The position's byte offset. -/
  offset : Nat
  /-- Its row. -/
  row : Nat
  /-- Its column in bytes. -/
  bytes : Nat
  /-- Its column in UTF-16 code units. -/
  units : Nat

/-- Every position of `rows`, written out by hand. The offsets from 0 to 20
that are missing are inside a character: 2, 10, 16, 17 and 18. -/
def positions : List Place :=
  [⟨0, 0, 0, 0⟩, ⟨1, 0, 1, 1⟩, ⟨3, 0, 3, 2⟩, ⟨4, 0, 4, 3⟩, ⟨5, 0, 5, 4⟩, ⟨6, 0, 6, 5⟩, ⟨7, 0, 7, 6⟩,
    ⟨8, 1, 0, 0⟩, ⟨9, 1, 1, 1⟩, ⟨11, 1, 3, 2⟩, ⟨12, 1, 4, 3⟩, ⟨13, 1, 5, 4⟩, ⟨14, 1, 6, 5⟩,
    ⟨15, 2, 0, 0⟩, ⟨19, 2, 4, 2⟩, ⟨20, 2, 5, 3⟩]

/-- "a", the character the library keeps the raw byte `0xFF` of a file as
(U+10DCFF), and "b". That character is four bytes of UTF-8, so "b" is at the
byte offset 5, and it is two UTF-16 code units. -/
def escaped : String :=
  ("a".push (Char.ofNat 0x10DCFF)).push 'b'

/-- The properties of making, editing and reading a text. -/
def editProperties : List Property :=
  [{
      name :=
        "a new text reads back what it was made with, multi-byte characters and an embedded NUL included",
      holds := do
        let text ← createText "héllo\x00wörld"
        let empty ← createText ""
        return (← text.read) == "héllo\x00wörld" && (← empty.read) == "" },
    { name := "an insert at a character boundary lands at that byte offset"
      holds := do
        let text ← createText "héllo"
        text.insert 3 "XY"
        let middle ← text.read
        text.insert 0 "<"
        let start ← text.read
        text.insert 9 ">"
        return middle == "héXYllo" && start == "<héXYllo" && (← text.read) == "<héXYllo>" },
    { name := "an insert inside a character is refused and changes nothing"
      holds := do
        let text ← createText "héllo"
        let refused ← refusedWith .badRange (text.insert 2 "x")
        return refused && (← text.read) == "héllo" },
    { name := "an insert past the end is refused, and so is one at an offset no machine word holds"
      holds := do
        let text ← createText "héllo"
        let pastEnd ← refusedWith .badRange (text.insert 7 "x")
        let huge ← refusedWith .badRange (text.insert (2 ^ 64 + 1) "x")
        return pastEnd && huge && (← text.read) == "héllo" },
    { name := "a delete removes exactly its byte range"
      holds := do
        let text ← createText "héllo wörld"
        text.delete 1 3
        let middle ← text.read
        text.delete 5 11
        return middle == "hllo wörld" && (← text.read) == "hllo " },
    { name :=
        "a delete whose range is backwards, splits a character or runs past the end is refused and changes nothing"
      holds := do
        let text ← createText "héllo"
        let backwards ← refusedWith .badRange (text.delete 3 1)
        let split ← refusedWith .badRange (text.delete 0 2)
        let pastEnd ← refusedWith .badRange (text.delete 3 7)
        return backwards && split && pastEnd && (← text.read) == "héllo" },
    -- In the next two, only one offset is beyond a machine word. Cut down to
    -- a 64-bit word, `2 ^ 64 + 1` is 1, a character boundary of "héllo", so
    -- an implementation that converted it without looking would delete.
    { name := "a delete whose stop no machine word holds is refused and changes nothing"
      holds := do
        let text ← createText "héllo"
        -- With the stop cut down to 1, this would delete "h".
        let refused ← refusedWith .badRange (text.delete 0 (2 ^ 64 + 1))
        return refused && (← text.read) == "héllo" },
    { name := "a delete whose start no machine word holds is refused and changes nothing"
      holds := do
        let text ← createText "héllo"
        -- With the start cut down to 1, this would delete "é".
        let refused ← refusedWith .badRange (text.delete (2 ^ 64 + 1) 3)
        return refused && (← text.read) == "héllo" },
    { name := "two texts are independent and have different ids"
      holds := do
        let first ← createText "a"
        let second ← createText "b"
        first.insert 1 "1"
        second.delete 0 1
        return first != second && (← first.read) == "a1" && (← second.read) == "" },
    { name := "an id that no create returned is refused"
      holds := do
        let never : TextId := ⟨99⟩
        let before ← refusedWith .noSuchText (discard never.read)
        let made ← createText "a"
        let read ← refusedWith .noSuchText (discard never.read)
        let insert ← refusedWith .noSuchText (never.insert 0 "x")
        let delete ← refusedWith .noSuchText (never.delete 0 0)
        return before && read && insert && delete && (← made.read) == "a" }]

/-- The properties of a text's revision. -/
def revisionProperties : List Property :=
  [{
      name :=
        "a new text is at revision 0, and each accepted edit adds one, an edit that changes nothing included",
      holds := do
        let text ← createText "héllo"
        let new ← text.revision
        text.insert 3 "XY"
        let inserted ← text.revision
        text.delete 0 1
        let deleted ← text.revision
        text.insert 0 ""
        let nothingInserted ← text.revision
        -- The text is now "éXYllo", and 2 is the boundary after "é".
        text.delete 2 2
        return new == 0 && inserted == 1 && deleted == 2 && nothingInserted == 3 &&
            (← text.revision) == 4 },
    { name := "a refused edit leaves the revision as it was"
      holds := do
        let text ← createText "héllo"
        text.insert 0 "x"
        -- In "xhéllo" the offset 3 is inside "é".
        let insert ← refusedWith .badRange (text.insert 3 "x")
        let delete ← refusedWith .badRange (text.delete 4 99)
        return insert && delete && (← text.revision) == 1 }]

/-- The properties of a snapshot. -/
def snapshotProperties : List Property :=
  [{
      name :=
        "a snapshot reads what its text held when it was taken, whatever is inserted into or deleted from the text afterwards",
      holds := do
        let text ← createText "héllo"
        let first ← text.snapshot
        text.insert 6 " wörld"
        let second ← text.snapshot
        text.delete 0 6
        text.insert 0 "😀"
        return (← first.read) == "héllo" && (← second.read) == "héllo wörld" &&
            (← text.read) == "😀 wörld" },
    { name :=
        "a snapshot keeps the revision its text had, and answers every query as the text did then"
      holds := do
        let text ← createText rows
        text.insert 0 "x"
        -- What the text answers now, at revision 1: it holds "x" and then
        -- `rows`, so every offset of `rows` is one further on.
        let revision ← text.revision
        let length ← text.byteLength
        let rowCount ← text.rowCount
        let contents ← text.read
        let point ← text.pointOf 20 .utf16
        let offset ← text.offsetOf ⟨1, 3⟩
        let snapshot ← text.snapshot
        -- Afterwards the text loses its first row and gains two empty ones.
        text.delete 0 9
        text.insert 0 "\n\n"
        let kept :=
          (← snapshot.revision) == revision && (← snapshot.byteLength) == length &&
            (← snapshot.rowCount) == rowCount &&
            (← snapshot.read) == contents &&
            (← snapshot.pointOf 20 .utf16) == point &&
            (← snapshot.offsetOf ⟨1, 3⟩) == offset
        return kept && revision == 1 && length == 21 && rowCount == 3 && point == ⟨2, 2⟩ &&
            offset == 12 &&
            (← text.revision) == 3 &&
            (← text.rowCount) == 4 },
    { name :=
        "two snapshots of one text have different ids, and with no edit between them they hold the same text at the same revision"
      holds := do
        let text ← createText "héllo"
        text.insert 0 "x"
        let first ← text.snapshot
        let second ← text.snapshot
        return first != second && (← first.read) == "xhéllo" && (← second.read) == "xhéllo" &&
            (← first.revision) == 1 &&
            (← second.revision) == 1 },
    { name := "a snapshot id that no request returned is refused"
      holds := do
        let never : SnapshotId := ⟨99⟩
        let before ← refusedWith .noSuchSnapshot (discard never.read)
        let text ← createText "a"
        let taken ← text.snapshot
        let read ← refusedWith .noSuchSnapshot (discard never.read)
        let ask ← refusedWith .noSuchSnapshot (discard never.rowCount)
        let release ← refusedWith .noSuchSnapshot never.release
        return before && read && ask && release && (← taken.read) == "a" }]

/-- The properties of rows, points and positions. -/
def positionProperties : List Property :=
  [{
      name :=
        "an empty text has one row, a text that ends in a line feed has an empty last row, and a carriage return alone starts no row",
      holds := do
        let empty ← createText ""
        let ended ← createText "a\n"
        let alone ← createText "a\rb"
        let paired ← createText "a\r\nb"
        return (← empty.rowCount) == 1 && (← empty.pointOf 0) == ⟨0, 0⟩ &&
            (← ended.rowCount) == 2 &&
            (← ended.pointOf 2) == ⟨1, 0⟩ &&
            (← alone.rowCount) == 1 &&
            (← alone.pointOf 3) == ⟨0, 3⟩ &&
            (← paired.rowCount) == 2 &&
            (← paired.pointOf 2) == ⟨0, 2⟩ &&
            (← paired.pointOf 3) == ⟨1, 0⟩ },
    { name :=
        "the point of every offset of a text is the one in a table written out by hand, in bytes and in UTF-16, and an offset inside a character or past the end is refused"
      holds := do
        let text ← createText rows
        let mut held := (← text.byteLength) == 20 && (← text.rowCount) == 3
        -- To one past the end, which is not a position either.
        for offset in [0:22] do
          let inBytes ← pointOf? (.text text) .bytes offset
          let inUnits ← pointOf? (.text text) .utf16 offset
          match positions.find? (·.offset == offset) with
          | some place =>
            held :=
              held && inBytes == some ⟨place.row, place.bytes⟩ &&
                inUnits == some ⟨place.row, place.units⟩
          | none =>
            held := held && inBytes == none && inUnits == none
        return held },
    { name :=
        "every position of a text converts to a point and back, in both units, and nothing else converts"
      holds := do
        let mut held := true
        for contents in [rows, "", "a\n", "a\r\nb", "\n\n", "héllo wörld", escaped] do
          let text ← createText contents
          let snapshot ← text.snapshot
          for source in [TextSource.text text, TextSource.snapshot snapshot] do
            for unit in [ColumnUnit.bytes, ColumnUnit.utf16] do
              let mut converted := 0
              for offset in [0:contents.utf8ByteSize + 2] do
                if let some point← pointOf? source unit offset then
                  converted := converted + 1
                  held := held && (← offsetOf? source unit point) == some offset
              -- A text has one position before each character and one at
              -- its end.
              held := held && converted == contents.length + 1
        return held },
    { name :=
        "a point past the end of its row, in a row the text does not have, inside a character or between the two UTF-16 units of one is refused"
      holds := do
        let text ← createText rows
        -- The first row is seven bytes and six units long. The column just
        -- past its last character is the position before its line feed; one
        -- more is not carried into the next row.
        let rowEnd := (← text.offsetOf ⟨0, 7⟩) == 7 && (← text.offsetOf ⟨0, 6⟩ .utf16) == 7
        let pastBytes ← refusedWith .badPosition (discard <| text.offsetOf ⟨0, 8⟩)
        let pastUnits ← refusedWith .badPosition (discard <| text.offsetOf ⟨0, 7⟩ .utf16)
        let noRowBytes ← refusedWith .badPosition (discard <| text.offsetOf ⟨3, 0⟩)
        let noRowUnits ← refusedWith .badPosition (discard <| text.offsetOf ⟨3, 0⟩ .utf16)
        let insideCharacter ← refusedWith .badPosition (discard <| text.offsetOf ⟨0, 2⟩)
        let betweenUnits ← refusedWith .badPosition (discard <| text.offsetOf ⟨2, 1⟩ .utf16)
        return rowEnd && pastBytes && pastUnits && noRowBytes && noRowUnits && insideCharacter &&
            betweenUnits },
    -- Cut down to a 64-bit word, `2 ^ 64 + 1` is 1: the position after "h",
    -- the second row, and the column after the first character. An
    -- implementation that converted without looking would answer.
    { name := "an offset, a row or a column that no machine word holds is refused"
      holds := do
        let text ← createText rows
        let huge := 2 ^ 64 + 1
        let mut held := true
        for unit in [ColumnUnit.bytes, ColumnUnit.utf16] do
          let offset ← refusedWith .badPosition (discard <| text.pointOf huge unit)
          let row ← refusedWith .badPosition (discard <| text.offsetOf ⟨huge, 0⟩ unit)
          let column ← refusedWith .badPosition (discard <| text.offsetOf ⟨0, huge⟩ unit)
          held := held && offset && row && column
        return held && (← text.pointOf 1) == ⟨0, 1⟩ && (← text.offsetOf ⟨1, 0⟩) == 8 },
    { name :=
        "the character a raw byte is kept as is one character: four bytes of the text and two UTF-16 units"
      holds := do
        let text ← createText escaped
        let inside ← refusedWith .badPosition (discard <| text.pointOf 3)
        let betweenUnits ← refusedWith .badPosition (discard <| text.offsetOf ⟨0, 2⟩ .utf16)
        return (← text.read) == escaped && (← text.byteLength) == 6 &&
            (← text.pointOf 5) == ⟨0, 5⟩ &&
            (← text.pointOf 5 .utf16) == ⟨0, 3⟩ &&
            (← text.offsetOf ⟨0, 3⟩ .utf16) == 5 &&
            inside &&
            betweenUnits }]

/-- The properties of releasing a text or a snapshot. -/
def releaseProperties : List Property :=
  [{
      name :=
        "a released snapshot is refused, releasing it again is refused, and its text and its other snapshots are untouched",
      holds := do
        let text ← createText "héllo"
        let kept ← text.snapshot
        let released ← text.snapshot
        released.release
        let read ← refusedWith .noSuchSnapshot (discard released.read)
        let ask ← refusedWith .noSuchSnapshot (discard released.revision)
        let again ← refusedWith .noSuchSnapshot released.release
        -- An id is never used again: a snapshot taken now has a new one.
        let later ← text.snapshot
        return read && ask && again && (← kept.read) == "héllo" && (← text.read) == "héllo" &&
            later != released &&
            later != kept &&
            (← later.read) == "héllo" },
    { name :=
        "a released text is refused by every request, its snapshots still read, and a text made afterwards has a new id"
      holds := do
        let text ← createText "héllo"
        let other ← createText "other"
        let snapshot ← text.snapshot
        text.release
        let read ← refusedWith .noSuchText (discard text.read)
        let insert ← refusedWith .noSuchText (text.insert 0 "x")
        let delete ← refusedWith .noSuchText (text.delete 0 0)
        let take ← refusedWith .noSuchText (discard text.snapshot)
        let ask ← refusedWith .noSuchText (discard text.rowCount)
        let again ← refusedWith .noSuchText text.release
        let made ← createText "new"
        return read && insert && delete && take && ask && again && (← snapshot.read) == "héllo" &&
            (← snapshot.revision) == 0 &&
            (← other.read) == "other" &&
            made != text &&
            made != other &&
            (← made.read) == "new" }]

/-- The properties every implementation of the text port has. -/
def properties : List Property :=
  editProperties ++ revisionProperties ++ snapshotProperties ++ positionProperties ++
    releaseProperties

/-- Runs each of `properties` with `run`, which must start every command from
an empty store, and returns the names of those that did not hold. A property
whose command failed is named with the error it failed with. -/
def failures (run : EditorM Bool → IO (Except TextError Bool)) (properties : List Property) :
    IO (List String) :=
  properties.filterMapM fun property => do
    match ← run property.holds with
    | .ok true =>
      return none
    | .ok false =>
      return some property.name
    | .error error =>
      return some s!"{property.name} (the command failed with {repr error})"

end Editor.TextContract
