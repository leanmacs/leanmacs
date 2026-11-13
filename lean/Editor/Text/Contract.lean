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
  holds : TextM Bool

/-- Runs `command` and returns whether it was refused with `error`. -/
def refusedWith (error : TextError) (command : TextM Unit) : TextM Bool :=
  try
    command
    return false
  catch refusal =>
    return refusal == error

/-- The point of `offset` in `source`, with its column in `unit`; `none` when
it is refused as not a position. Any other refusal fails the command. -/
def pointOf? (source : TextSource) (unit : ColumnUnit) (offset : Nat) : TextM (Option Point) :=
  try
    return some (← source.ask (.pointOf unit offset))
  catch refusal =>
    if refusal == .badPosition then
      return none
    throw refusal

/-- The offset of `point` in `source`, with its column in `unit`; `none` when
it is refused as not a position. Any other refusal fails the command. -/
def offsetOf? (source : TextSource) (unit : ColumnUnit) (point : Point) : TextM (Option Nat) :=
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

/-- Changes over `rows` in which "é" becomes "e", "w" becomes "W" and "😀"
goes: they make "hello\r\nWörld\nx", 15 bytes long. -/
def severalChanges : Array Change :=
  #[.retain 1, .delete 2, .insert "e", .retain 5, .insert "W", .delete 1, .retain 6, .delete 4,
    .retain 1]

/-- Whether applying `transaction` to `text` is refused with `error`. -/
def applyRefusedWith (error : TextError) (text : TextId) (transaction : Transaction) : TextM Bool :=
  refusedWith error (discard <| text.apply transaction)

/-- The properties of applying a transaction. -/
def transactionProperties : List Property :=
  [{
      name :=
        "a transaction's changes are applied in order, and applying returns the revision it produced: one more than before, however many changes it has and when it changes nothing",
      holds := do
        let text ← createText rows
        let several ← text.apply { changes := severalChanges }
        let afterSeveral ← text.read
        let nothing ← text.apply { changes := #[.retain 15] }
        let afterNothing ← text.read
        let replaced ← text.apply (.replacing 15 0 1 "J")
        let empty ← createText ""
        let noChange ← empty.apply { changes := #[] }
        return several == 1 && afterSeveral == "hello\r\nWörld\nx" && nothing == 2 &&
            afterNothing == afterSeveral &&
            replaced == 3 &&
            (← text.read) == "Jello\r\nWörld\nx" &&
            (← text.revision) == 3 &&
            noChange == 1 &&
            (← empty.revision) == 1 },
    { name :=
        "changes that stop short of the text, run past it, or change a range that starts or stops inside a character are refused, and the text and its revision are as they were"
      holds := do
        let text ← createText rows
        let short ← applyRefusedWith .badChange text { changes := #[.retain 19] }
        let noChanges ← applyRefusedWith .badChange text { changes := #[] }
        let shortAfterAChange ←
          applyRefusedWith .badChange text { changes := #[.insert "x", .delete 1, .retain 18] }
        let long ← applyRefusedWith .badChange text { changes := #[.retain 21] }
        let longDelete ← applyRefusedWith .badChange text { changes := #[.retain 19, .delete 2] }
        -- An insert inside "é", a delete that stops inside it, and one that
        -- stops inside "😀" after changes that fit.
        let startsInside ←
          applyRefusedWith .badChange text { changes := #[.retain 2, .insert "x", .retain 18] }
        let stopsInside ←
          applyRefusedWith .badChange text { changes := #[.retain 1, .delete 1, .retain 18] }
        let laterInside ←
          applyRefusedWith .badChange text
              { changes := #[.insert "H", .delete 1, .retain 14, .delete 2, .retain 3] }
        return short && noChanges && shortAfterAChange && long && longDelete && startsInside &&
            stopsInside &&
            laterInside &&
            (← text.read) == rows &&
            (← text.revision) == 0 &&
            -- The log is as it was: nothing changed, and nobody wrote a byte.
            (← text.changesSince 0) == ⟨0, 0, #[]⟩ &&
            (← text.trace 0 20) == #[⟨0, 20, .earlier 0⟩] },
    -- Cut down to a 64-bit word, `2 ^ 64 + 1` is 1, the length of the text:
    -- an implementation that converted without looking would accept each.
    { name := "a count in a change that no machine word holds is refused"
      holds := do
        let text ← createText "a"
        let huge := 2 ^ 64 + 1
        let retained ← applyRefusedWith .badChange text { changes := #[.retain huge] }
        let deleted ← applyRefusedWith .badChange text { changes := #[.delete huge] }
        let afterAnInsert ←
          applyRefusedWith .badChange text { changes := #[.insert "x", .retain huge] }
        return retained && deleted && afterAnInsert && (← text.read) == "a" &&
            (← text.revision) == 0 &&
            (← text.apply { changes := #[.retain 1] }) == 1 },
    { name :=
        "changes that do nothing are ignored, neighbours of one kind are one change, and a delete and an insert at one place are one replaced range in either order"
      holds := do
        let text ← createText "héllo"
        -- The two retains meet inside "é": together they keep the text.
        let emptyInsert ← text.apply { changes := #[.retain 2, .insert "", .retain 4] }
        let twoRetains ← text.apply { changes := #[.retain 1, .retain 1, .delete 0, .retain 4] }
        let kept ← text.read
        -- The two deletes meet inside "é": together they remove "hé".
        let deleteFirst ← text.apply { changes := #[.delete 2, .insert "HE", .delete 1, .retain 3] }
        let replaced ← text.read
        let other ← createText "abc"
        let insertsAround ←
          other.apply { changes := #[.insert "x", .delete 1, .insert "y", .retain 2] }
        return emptyInsert == 1 && twoRetains == 2 && kept == "héllo" && deleteFirst == 3 &&
            replaced == "HEllo" &&
            insertsAround == 1 &&
            (← other.read) == "xybc" },
    -- With "h" deleted from "héllo" the text is "éllo": 1 and 6 are positions
    -- of the text before only, and 2 is a position of the text after only.
    { name :=
        "a selection whose ends are positions of its own text is accepted, and one with an end inside a character, past the end, a position of the other text only, or that no machine word holds is refused"
      holds := do
        let text ← createText "héllo"
        let deleteH : Array Change := #[.delete 1, .retain 5]
        let inside ←
          applyRefusedWith .badSelection text
              { changes := #[.retain 6], before := some { ranges := #[⟨0, 2⟩] } }
        let pastEnd ←
          applyRefusedWith .badSelection text
              { changes := #[.retain 6], after := some { ranges := #[⟨7, 0⟩] } }
        let secondRange ←
          applyRefusedWith .badSelection text
              { changes := #[.retain 6], before := some { ranges := #[⟨0, 1⟩, ⟨3, 2⟩] } }
        let afterOnly ←
          applyRefusedWith .badSelection text
              { changes := deleteH, before := some { ranges := #[⟨2, 2⟩] } }
        let beforeOnly ←
          applyRefusedWith .badSelection text
              { changes := deleteH, after := some { ranges := #[⟨1, 1⟩] } }
        let oldEnd ←
          applyRefusedWith .badSelection text
              { changes := deleteH, after := some { ranges := #[⟨0, 6⟩] } }
        -- Cut down to a word these are 1 and 2: positions of their texts.
        let hugeBefore ←
          applyRefusedWith .badSelection text
              { changes := deleteH, before := some { ranges := #[⟨2 ^ 64 + 1, 0⟩] } }
        let hugeAfter ←
          applyRefusedWith .badSelection text
              { changes := deleteH, after := some { ranges := #[⟨0, 2 ^ 64 + 2⟩] } }
        let unchanged := (← text.read) == "héllo" && (← text.revision) == 0
        let accepted ←
          text.apply
              { changes := deleteH
                before := some { ranges := #[⟨1, 6⟩, ⟨0, 0⟩], primary := 1 }
                after := some { ranges := #[⟨2, 5⟩] } }
        return inside && pastEnd && secondRange && afterOnly && beforeOnly && oldEnd &&
            hugeBefore &&
            hugeAfter &&
            unchanged &&
            accepted == 1 &&
            (← text.read) == "éllo" },
    { name :=
        "a selection with no range, or whose primary names none, is refused as a selection even when the changes do not fit, and changes that do not fit are refused as that even when a selection's end is no position"
      holds := do
        let text ← createText "héllo"
        let noRange ←
          applyRefusedWith .badSelection text
              { changes := #[.retain 6], before := some { ranges := #[] } }
        let noPrimary ←
          applyRefusedWith .badSelection text
              { changes := #[.retain 6], after := some { ranges := #[⟨0, 0⟩], primary := 1 } }
        -- Cut down to a word, `2 ^ 64` is 0, which names the one range.
        let hugePrimary ←
          applyRefusedWith .badSelection text
              { changes := #[.retain 6], after := some { ranges := #[⟨0, 0⟩], primary := 2 ^ 64 } }
        let noRangeAndShort ←
          applyRefusedWith .badSelection text
              { changes := #[.retain 5], after := some { ranges := #[] } }
        let noPrimaryAndShort ←
          applyRefusedWith .badSelection text
              { changes := #[.retain 5], before := some { ranges := #[⟨0, 0⟩], primary := 1 } }
        let shortAndAstray ←
          applyRefusedWith .badChange text
              { changes := #[.retain 5]
                before := some { ranges := #[⟨2, 2⟩] }
                after := some { ranges := #[⟨99, 99⟩] } }
        return noRange && noPrimary && hugePrimary && noRangeAndShort && noPrimaryAndShort &&
            shortAndAstray &&
            (← text.read) == "héllo" &&
            (← text.revision) == 0 },
    { name :=
        "applying a transaction to an id no create returned, and to a released text, is refused with no such text, whatever else is wrong with it"
      holds := do
        let text ← createText "héllo"
        text.release
        let never ← applyRefusedWith .noSuchText ⟨7⟩ { changes := #[] }
        let released ← applyRefusedWith .noSuchText text { changes := #[.retain 6] }
        let releasedAndWrong ←
          applyRefusedWith .noSuchText text
              { changes := #[.retain 5], after := some { ranges := #[] } }
        -- The same of the requests about its log, whatever they ask.
        let mut log := true
        for id in [(⟨7⟩ : TextId), text] do
          let since ← refusedWith .noSuchText (discard <| id.changesSince 0)
          let ahead ← refusedWith .noSuchText (discard <| id.changesSince 9)
          let trace ← refusedWith .noSuchText (discard <| id.trace 0 0)
          let backwards ← refusedWith .noSuchText (discard <| id.trace 3 1)
          let forget ← refusedWith .noSuchText (id.forget 0)
          let forgetAhead ← refusedWith .noSuchText (id.forget 9)
          log := log && since && ahead && trace && backwards && forget && forgetAhead
        return never && released && releasedAndWrong && log },
    { name := "a snapshot taken before a transaction reads what it read"
      holds := do
        let text ← createText rows
        let before ← text.snapshot
        discard <| text.apply { changes := severalChanges }
        let after ← text.snapshot
        return (← before.read) == rows && (← before.revision) == 0 && (← before.byteLength) == 20 &&
            (← after.read) == "hello\r\nWörld\nx" &&
            (← after.revision) == 1 }]

/-- The span from `start` to `stop` whose points, with their columns in
bytes, are the two (row, column) pairs. -/
def span (start stop : Nat) (startPoint stopPoint : Nat × Nat) : Span where
  start := start
  stop := stop
  startPoint := ⟨startPoint.1, startPoint.2⟩
  stopPoint := ⟨stopPoint.1, stopPoint.2⟩

/-- Makes a text holding "héllo\nwörld" and changes it four times, to
"\nhXYllo\nwörld!": "A\n" is inserted at the start, by nobody; "é" is
replaced by "XY", by the origin 7; "!" is added at the end, by the origin 9;
and the "A" is deleted, by nobody. Returns the text and the revisions the
two transactions produced. -/
def changedFourTimes : TextM (TextId × Nat × Nat) := do
  let text ← createText "héllo\nwörld"
  text.insert 0 "A\n"
  let second ← text.apply { changes := #[.retain 3, .delete 2, .insert "XY", .retain 10] } ⟨7⟩
  let third ←
    text.apply { changes := #[.retain 15, .insert "!"], after := some { ranges := #[⟨16, 16⟩] } }
        ⟨9⟩
  text.delete 0 1
  return (text, second, third)

/-- What changed in the text of `changedFourTimes` since it was made, written
out by hand. The "A" that was inserted and then deleted is in no edit. -/
def editsSinceMade : Array Edit :=
  #[⟨span 0 0 (0, 0) (0, 0), span 0 1 (0, 0) (1, 0)⟩,
    ⟨span 1 3 (0, 1) (0, 3), span 2 4 (1, 1) (1, 3)⟩,
    ⟨span 13 13 (1, 6) (1, 6), span 14 15 (2, 6) (2, 7)⟩]

/-- What changed in the text of `changedFourTimes` since its second revision,
when it held "A\nhXYllo\nwörld", written out by hand. -/
def editsSinceSecond : Array Edit :=
  #[⟨span 0 1 (0, 0) (0, 1), span 0 0 (0, 0) (0, 0)⟩,
    ⟨span 15 15 (2, 6) (2, 6), span 14 15 (2, 6) (2, 7)⟩]

/-- The properties of a text's edit log: what changed since a revision, and
who wrote a range. -/
def logProperties : List Property :=
  [{
      name :=
        "what one transaction changed is its changed ranges, each with its offsets and its points in the text before and in the text after",
      holds := do
        let text ← createText rows
        discard <| text.apply { changes := #[.retain 20] }
        -- An insertion with a line feed in it, a deletion across a line
        -- feed, and a replacement inside a row: "héa\nbllöRLXd\n😀x".
        discard <|
            text.apply
              {
                changes :=
                  #[.retain 3, .insert "a\nb", .retain 2, .delete 4, .retain 2, .insert "RLX",
                    .delete 2, .retain 7] }
        return (← text.changesSince 1) ==
            ⟨1, 2,
              #[⟨span 3 3 (0, 3) (0, 3), span 3 6 (0, 3) (1, 1)⟩,
                ⟨span 5 9 (0, 5) (1, 1), span 8 8 (1, 3) (1, 3)⟩,
                ⟨span 11 13 (1, 3) (1, 5), span 10 13 (1, 5) (1, 8)⟩]⟩ },
    { name :=
        "an insert and a delete are recorded as the transaction with that one change is, by nobody"
      holds := do
        let edited ← createText "héllo"
        let applied ← createText "héllo"
        edited.insert 3 "XY"
        discard <| applied.apply (.replacing 6 3 3 "XY")
        let inserted : Patch := ⟨0, 1, #[⟨span 3 3 (0, 3) (0, 3), span 3 5 (0, 3) (0, 5)⟩]⟩
        let insertedAlike :=
          (← edited.changesSince 0) == inserted && (← applied.changesSince 0) == inserted
        edited.delete 0 1
        discard <| applied.apply (.replacing 8 0 1 "")
        let deleted : Patch := ⟨1, 2, #[⟨span 0 1 (0, 0) (0, 1), span 0 0 (0, 0) (0, 0)⟩]⟩
        let trace : Array Attribution :=
          #[⟨0, 2, .earlier 0⟩, ⟨2, 4, .entry 1 .unattributed⟩, ⟨4, 7, .earlier 0⟩]
        return insertedAlike && (← edited.changesSince 1) == deleted &&
            (← applied.changesSince 1) == deleted &&
            (← edited.trace 0 7) == trace &&
            (← applied.trace 0 7) == trace },
    { name :=
        "a subscriber that skips several transactions gets one patch that says which revisions it spans, and asked again from the revision it reached it gets an empty one"
      holds := do
        let (text, second, third) ← changedFourTimes
        let patch ← text.changesSince 0
        let later ← text.changesSince second
        let again ← text.changesSince patch.revision
        return second == 2 && third == 3 && (← text.read) == "\nhXYllo\nwörld!" &&
            patch == ⟨0, 4, editsSinceMade⟩ &&
            later == ⟨2, 4, editsSinceSecond⟩ &&
            again == ⟨4, 4, #[]⟩ },
    { name :=
        "text one transaction inserts and a later one deletes is in no edit of the patch that spans both, and two edits that come to touch are one"
      holds := do
        let cancelled ← createText "abcdef"
        discard <| cancelled.apply { changes := #[.retain 2, .insert "XYZ", .retain 4] }
        discard <| cancelled.apply { changes := #[.retain 2, .delete 3, .retain 4] }
        let touching ← createText "abcdef"
        discard <| touching.apply { changes := #[.retain 1, .insert "X", .retain 5] }
        discard <| touching.apply { changes := #[.retain 2, .delete 1, .retain 4] }
        return (← cancelled.read) == "abcdef" && (← cancelled.changesSince 0) == ⟨0, 2, #[]⟩ &&
            (← touching.read) == "aXcdef" &&
            (← touching.changesSince 0) ==
              ⟨0, 2, #[⟨span 1 2 (0, 1) (0, 2), span 1 2 (0, 1) (0, 2)⟩]⟩ },
    -- "é😀" is two characters and six bytes: "é" is the bytes 1 and 2 of
    -- "aé😀bc\nd", "😀" the bytes 3 to 6, and "c" the byte 8. A log that
    -- counted the insert in characters would have everything after it four
    -- bytes early.
    { name :=
        "inserted text of characters of several bytes is counted in bytes: it is as long in an edit and in a trace as its bytes are, and a later change after it is at its byte offsets and columns"
      holds := do
        let text ← createText "abc\nd"
        let first ← text.apply { changes := #[.retain 1, .insert "é😀", .retain 4] } ⟨7⟩
        -- After the insert, on its row, "c" goes; on the next, "!" is added.
        let second ← text.apply { changes := #[.retain 8, .delete 1, .retain 2, .insert "!"] } ⟨9⟩
        return first == 1 && second == 2 && (← text.read) == "aé😀b\nd!" &&
            (← text.changesSince 0) ==
              ⟨0, 2,
                #[⟨span 1 1 (0, 1) (0, 1), span 1 7 (0, 1) (0, 7)⟩,
                  ⟨span 2 3 (0, 2) (0, 3), span 8 8 (0, 8) (0, 8)⟩,
                  ⟨span 5 5 (1, 1) (1, 1), span 10 11 (1, 1) (1, 2)⟩]⟩ &&
            (← text.changesSince 1) ==
              ⟨1, 2,
                #[⟨span 8 9 (0, 8) (0, 9), span 8 8 (0, 8) (0, 8)⟩,
                  ⟨span 11 11 (1, 1) (1, 1), span 10 11 (1, 1) (1, 2)⟩]⟩ &&
            (← text.trace 0 11) ==
              #[⟨0, 1, .earlier 0⟩, ⟨1, 7, .entry 1 ⟨7⟩⟩, ⟨7, 10, .earlier 0⟩,
                ⟨10, 11, .entry 2 ⟨9⟩⟩] &&
            (← text.trace 3 8) == #[⟨3, 7, .entry 1 ⟨7⟩⟩, ⟨7, 8, .earlier 0⟩] },
    -- Cut down to a 64-bit word, `2 ^ 64` is 0, a revision the text reached.
    { name :=
        "what changed since a revision the text has not reached, and since one no machine word holds, is refused"
      holds := do
        let text ← createText "héllo"
        text.insert 0 "x"
        let ahead ← refusedWith .unknownRevision (discard <| text.changesSince 2)
        let huge ← refusedWith .unknownRevision (discard <| text.changesSince (2 ^ 64))
        return ahead && huge && (← text.changesSince 1) == ⟨1, 1, #[]⟩ },
    { name :=
        "a trace names, for each piece of the text, the revision and the origin of the transaction that wrote it, and the bytes the text was made with as earlier than its first revision"
      holds := do
        let (text, _, _) ← changedFourTimes
        return (← text.trace 0 15) ==
              #[⟨0, 1, .entry 1 .unattributed⟩, ⟨1, 2, .earlier 0⟩, ⟨2, 4, .entry 2 ⟨7⟩⟩,
                ⟨4, 14, .earlier 0⟩, ⟨14, 15, .entry 3 ⟨9⟩⟩] &&
            (← text.trace 3 9) == #[⟨3, 4, .entry 2 ⟨7⟩⟩, ⟨4, 9, .earlier 0⟩] },
    -- In "\nhXYllo\nwörld!" the "ö" is the bytes 9 and 10. Cut down to a
    -- word, `2 ^ 64` is 0 and `2 ^ 64 + 4` is 4: both positions.
    { name :=
        "a trace of an empty range is empty, and of a range that is backwards, inside a character, past the end, or that no machine word holds is refused"
      holds := do
        let (text, _, _) ← changedFourTimes
        let backwards ← refusedWith .badRange (discard <| text.trace 4 2)
        let stopsInside ← refusedWith .badRange (discard <| text.trace 0 10)
        let startsInside ← refusedWith .badRange (discard <| text.trace 10 15)
        let pastEnd ← refusedWith .badRange (discard <| text.trace 0 16)
        let hugeStart ← refusedWith .badRange (discard <| text.trace (2 ^ 64) 4)
        let hugeStop ← refusedWith .badRange (discard <| text.trace 0 (2 ^ 64 + 4))
        return (← text.trace 0 0) == #[] && (← text.trace 3 3) == #[] &&
            (← text.trace 15 15) == #[] &&
            backwards &&
            stopsInside &&
            startsInside &&
            pastEnd &&
            hugeStart &&
            hugeStop }]

/-- The properties of forgetting the start of a text's edit log. -/
def forgetProperties : List Property :=
  [{
      name :=
        "after forgetting up to a revision, what changed since an earlier one is refused, what changed since it answers as before, and a trace names the bytes written by then as earlier than it",
      holds := do
        let (text, _, _) ← changedFourTimes
        text.forget 2
        let sinceMade ← refusedWith .forgotten (discard <| text.changesSince 0)
        let sinceFirst ← refusedWith .forgotten (discard <| text.changesSince 1)
        return sinceMade && sinceFirst && (← text.changesSince 2) == ⟨2, 4, editsSinceSecond⟩ &&
            (← text.changesSince 4) == ⟨4, 4, #[]⟩ &&
            (← text.trace 0 15) == #[⟨0, 14, .earlier 2⟩, ⟨14, 15, .entry 3 ⟨9⟩⟩] },
    -- Cut down to a 64-bit word, `2 ^ 64` is 0, which changes nothing.
    { name :=
        "forgetting a revision the text has not reached is refused, forgetting at or below where the log starts changes nothing, and none of it touches the text or its revision"
      holds := do
        let (text, _, _) ← changedFourTimes
        let ahead ← refusedWith .unknownRevision (text.forget 5)
        let huge ← refusedWith .unknownRevision (text.forget (2 ^ 64))
        let whole := (← text.changesSince 0) == ⟨0, 4, editsSinceMade⟩
        text.forget 0
        let stillWhole := (← text.changesSince 0) == ⟨0, 4, editsSinceMade⟩
        text.forget 2
        text.forget 2
        text.forget 1
        text.forget 0
        let sinceFirst ← refusedWith .forgotten (discard <| text.changesSince 1)
        -- The log goes on from where it starts now.
        text.insert 0 "z"
        return ahead && huge && whole && stillWhole && sinceFirst &&
            (← text.changesSince 2).revision == 5 &&
            (← text.changesSince 4) ==
              ⟨4, 5, #[⟨span 0 0 (0, 0) (0, 0), span 0 1 (0, 0) (0, 1)⟩]⟩ &&
            (← text.read) == "z\nhXYllo\nwörld!" &&
            (← text.revision) == 5 }]

/-- An anchor marker at `offset` with the bias `bias`. -/
def anchorAt (offset : Nat) (bias : Bias) : Marker :=
  .anchor ⟨offset, bias⟩

/-- A selection marker of shape `shape` with `ranges`, each an anchor and a
head, whose primary is the one at `primary`. -/
def selected (shape : Shape) (ranges : Array (Nat × Nat)) (primary : Nat := 0) : Marker :=
  .selection { ranges := ranges.map fun (anchor, head) => ⟨anchor, head⟩, primary, shape }

/-- Whether marking `text` with `marker` is refused with `error`. -/
def markRefusedWith (error : TextError) (text : TextId) (marker : Marker) : TextM Bool :=
  refusedWith error (discard <| text.mark marker)

/-- Where two anchors at `offset` of a new text holding `initial`, one of
each bias, are after `edit`: the one that stays before, then the one that
goes after. -/
def movedBy (initial : String) (offset : Nat) (edit : TextId → TextM Unit) :
    TextM (Marker × Marker) := do
  let text ← createText initial
  let before ← text.mark (anchorAt offset .before)
  let after ← text.mark (anchorAt offset .after)
  edit text
  return (← text.marker before, ← text.marker after)

/-- An anchor of each bias, the first at `before` and the second at
`after`. -/
def anchorsAt (before after : Nat) : Marker × Marker :=
  (anchorAt before .before, anchorAt after .after)

/-- What the selection of shape `shape` with `ranges` and `primary` reads
back as, once a new text of twenty letters holds it. -/
def keptAs (shape : Shape) (ranges : Array (Nat × Nat)) (primary : Nat := 0) : TextM Marker := do
  let text ← createText "abcdefghijklmnopqrst"
  text.marker (← text.mark (selected shape ranges primary))

/-- What the selection of shape `shape` with `ranges` and `primary`, held by
a new text holding `initial`, reads back as after `changes` are applied. -/
def selectionAfter (initial : String) (shape : Shape) (ranges : Array (Nat × Nat)) (primary : Nat)
    (changes : Array Change) : TextM Marker := do
  let text ← createText initial
  let marker ← text.mark (selected shape ranges primary)
  discard <| text.apply { changes }
  text.marker marker

/-- The properties of a text's markers: anchors and selections that every
edit moves. Offsets are of `"héllo wörld"` unless a property says otherwise:
13 bytes, in which "é" is the bytes 1 and 2, the space is at 6 and "ö" is
the bytes 8 and 9. -/
def markerProperties : List Property :=
  [{
      name :=
        "an anchor marked at a position reads back, and one inside a character, past the end, or at an offset no machine word holds is refused",
      holds := do
        let text ← createText "héllo"
        let start ← text.mark (anchorAt 0 .before)
        let stop ← text.mark (anchorAt 6 .after)
        let inside ← markRefusedWith .badPosition text (anchorAt 2 .before)
        let pastEnd ← markRefusedWith .badPosition text (anchorAt 7 .after)
        -- Cut down to a 64-bit word, `2 ^ 64 + 1` is 1, a position.
        let huge ← markRefusedWith .badPosition text (anchorAt (2 ^ 64 + 1) .after)
        let later ← text.mark (anchorAt 3 .before)
        return start != stop && later != start && later != stop && inside && pastEnd && huge &&
            (← text.marker start) == anchorAt 0 .before &&
            (← text.marker stop) == anchorAt 6 .after &&
            (← text.marker later) == anchorAt 3 .before },
    { name :=
        "an anchor moves with an insert and a delete: with the text it is in, to one side of text inserted at it by its bias, and to where a range deleted round it was"
      holds := do
        let text := "héllo wörld"
        -- Two bytes before it; six bytes at it, of characters of two and of
        -- four bytes; and one byte at the end of the text.
        let insertedBefore ← movedBy text 3 (·.insert 1 "XY")
        let insertedAt ← movedBy text 3 (·.insert 3 "é😀")
        let insertedAtEnd ← movedBy text 13 (·.insert 13 "!")
        let insertedAfter ← movedBy text 3 (·.insert 4 "é😀")
        -- "éllo" is deleted: at its start, inside it, at its end and after
        -- it.
        let deletedAtStart ← movedBy text 1 (·.delete 1 6)
        let deletedRound ← movedBy text 4 (·.delete 1 6)
        let deletedAtEnd ← movedBy text 6 (·.delete 1 6)
        let deletedBefore ← movedBy text 10 (·.delete 1 6)
        return insertedBefore == anchorsAt 5 5 && insertedAt == anchorsAt 3 9 &&
            insertedAtEnd == anchorsAt 13 14 &&
            insertedAfter == anchorsAt 3 3 &&
            deletedAtStart == anchorsAt 1 1 &&
            deletedRound == anchorsAt 1 1 &&
            deletedAtEnd == anchorsAt 1 1 &&
            deletedBefore == anchorsAt 5 5 },
    { name :=
        "an anchor moves with a transaction: to the start or the end of what replaced a range round it by its bias, and past it from the range's end; and one that goes after and a later one that stays before swap"
      holds := do
        let text := "héllo wörld"
        -- "éllo" is replaced by "ÖK", three bytes, and "!" is added at the
        -- end.
        let replacing : TextId → TextM Unit :=
          (discard <|
            ·.apply { changes := #[.retain 1, .insert "ÖK", .delete 5, .retain 7, .insert "!"] })
        let atStart ← movedBy text 1 replacing
        let inside ← movedBy text 3 replacing
        let atEnd ← movedBy text 6 replacing
        let after ← movedBy text 10 replacing
        let atTextEnd ← movedBy text 13 replacing
        let before ← movedBy text 0 replacing
        -- On "abcd", "abc" is replaced by "XY".
        let swapping ← createText "abcd"
        let earlier ← swapping.mark (anchorAt 1 .after)
        let later ← swapping.mark (anchorAt 2 .before)
        discard <| swapping.apply { changes := #[.insert "XY", .delete 3, .retain 1] }
        return atStart == anchorsAt 1 4 && inside == anchorsAt 1 4 && atEnd == anchorsAt 4 4 &&
            after == anchorsAt 8 8 &&
            atTextEnd == anchorsAt 11 12 &&
            before == anchorsAt 0 0 &&
            (← swapping.marker earlier) == anchorAt 2 .after &&
            (← swapping.marker later) == anchorAt 0 .before },
    { name :=
        "a selection reads back sorted by start and then by end, with its shape and the primary followed to where it went"
      holds := do
        let sorted ← keptAs .exclusive #[(9, 7), (0, 1), (4, 3), (12, 20), (12, 15)]
        let block ← keptAs .block #[(9, 7), (0, 1), (4, 3)] 1
        return sorted == selected .exclusive #[(0, 1), (4, 3), (9, 7), (12, 20)] 2 &&
            block == selected .block #[(0, 1), (4, 3), (9, 7)] 0 },
    { name :=
        "exclusive ranges that overlap or start together are one and those that only touch stay two; ranges of the other shapes that share an end are one"
      holds := do
        let touching ← keptAs .exclusive #[(0, 2), (2, 5)]
        let overlapping ← keptAs .exclusive #[(2, 5), (0, 3)] 1
        let cursors ← keptAs .exclusive #[(2, 2), (2, 2)]
        let cursorAtStart ← keptAs .exclusive #[(2, 5), (2, 2)]
        let cursorAtEnd ← keptAs .exclusive #[(2, 5), (5, 5), (5, 8)]
        let chain ← keptAs .exclusive #[(4, 8), (0, 3), (2, 5), (8, 9)] 3
        let shared ← [Shape.inclusive, .line, .block].mapM (keptAs · #[(0, 2), (2, 5)])
        let cursorOnLast ← keptAs .inclusive #[(2, 5), (5, 5)]
        let neighbours ← keptAs .line #[(0, 2), (3, 5)]
        return touching == selected .exclusive #[(0, 2), (2, 5)] &&
            overlapping == selected .exclusive #[(0, 5)] &&
            cursors == selected .exclusive #[(2, 2)] &&
            cursorAtStart == selected .exclusive #[(2, 5)] &&
            cursorAtEnd == selected .exclusive #[(2, 5), (5, 8)] &&
            chain == selected .exclusive #[(0, 8), (8, 9)] 1 &&
            shared ==
              [selected .inclusive #[(0, 5)], selected .line #[(0, 5)],
                selected .block #[(0, 5)]] &&
            cursorOnLast == selected .inclusive #[(2, 5)] &&
            neighbours == selected .line #[(0, 2), (3, 5)] },
    { name :=
        "a merged range points the way the primary did when the primary is in it, and otherwise the way its first range did"
      holds := do
        let primaryBackward ← keptAs .exclusive #[(0, 3), (5, 2)] 1
        let primaryForward ← keptAs .exclusive #[(0, 3), (5, 2)] 0
        let primaryACursor ← keptAs .exclusive #[(5, 2), (2, 2)] 1
        let firstForward ← keptAs .exclusive #[(5, 2), (0, 3), (9, 9)] 2
        let firstBackward ← keptAs .inclusive #[(2, 5), (3, 0), (9, 9)] 2
        let firstGiven ← keptAs .line #[(4, 1), (1, 4), (9, 9)] 2
        return primaryBackward == selected .exclusive #[(5, 0)] &&
            primaryForward == selected .exclusive #[(0, 5)] &&
            primaryACursor == selected .exclusive #[(2, 5)] &&
            firstForward == selected .exclusive #[(0, 5), (9, 9)] 1 &&
            firstBackward == selected .inclusive #[(5, 0), (9, 9)] 1 &&
            firstGiven == selected .line #[(4, 1), (9, 9)] 1 },
    { name :=
        "a selection that is none, or has an end that is not a position, is refused; an end of a range that merged into another is no end of the selection, for a marker and for a transaction"
      holds := do
        let text ← createText "héllo"
        let noRange ← markRefusedWith .badSelection text (selected .line #[])
        let noPrimary ← markRefusedWith .badSelection text (selected .exclusive #[(0, 0)] 1)
        let inside ← markRefusedWith .badSelection text (selected .exclusive #[(0, 1), (3, 2)])
        let pastEnd ← markRefusedWith .badSelection text (selected .block #[(0, 7)])
        let huge ← markRefusedWith .badSelection text (selected .inclusive #[(2 ^ 64 + 1, 0)])
        -- 2 is inside "é", and the range it ends is inside the other.
        let merged ← text.mark (selected .exclusive #[(0, 6), (2, 1)])
        let carried ←
          text.apply
              { changes := #[.retain 6]
                before := some { ranges := #[⟨0, 6⟩, ⟨2, 1⟩] }
                after := some { ranges := #[⟨2, 1⟩, ⟨6, 0⟩], primary := 1, shape := .line } }
        return noRange && noPrimary && inside && pastEnd && huge && carried == 1 &&
            (← text.marker merged) == selected .exclusive #[(0, 6)] },
    { name :=
        "text inserted at either edge of a marked exclusive range stays outside it, text inserted at a cursor is before it, and an end on a character stays on it"
      holds := do
        let text := "héllo wörld"
        -- "XY" at 1 and "é😀" at 6, round "éllo".
        let atEdges : Array Change := #[.retain 1, .insert "XY", .retain 5, .insert "é😀", .retain 7]
        let forward ← selectionAfter text .exclusive #[(1, 6)] 0 atEdges
        let backward ← selectionAfter text .exclusive #[(6, 1)] 0 atEdges
        let cursor ← selectionAfter text .exclusive #[(6, 6)] 0 atEdges
        let onCharacters ← selectionAfter text .inclusive #[(1, 6)] 0 atEdges
        let lines ← selectionAfter text .line #[(6, 1)] 0 atEdges
        -- Inside the range, it grows.
        let grown ← selectionAfter text .exclusive #[(1, 6)] 0 #[.retain 3, .insert "😀", .retain 10]
        return forward == selected .exclusive #[(3, 8)] &&
            backward == selected .exclusive #[(8, 3)] &&
            cursor == selected .exclusive #[(14, 14)] &&
            onCharacters == selected .inclusive #[(3, 14)] &&
            lines == selected .line #[(14, 3)] &&
            grown == selected .exclusive #[(1, 10)] },
    { name :=
        "a marked range that is wholly replaced is a cursor after the replacement, and ranges a deletion brings together are one, with the primary still the primary"
      holds := do
        let text := "héllo wörld"
        -- "éllo" is replaced by "😀", four bytes.
        let replacing : Array Change := #[.retain 1, .insert "😀", .delete 5, .retain 7]
        let replaced ← selectionAfter text .exclusive #[(3, 5)] 0 replacing
        let replacedBackward ← selectionAfter text .exclusive #[(6, 1)] 0 replacing
        let replacedOnCharacters ← selectionAfter text .block #[(3, 5)] 0 replacing
        let deleted ← selectionAfter text .exclusive #[(3, 5)] 0 #[.retain 1, .delete 5, .retain 7]
        -- " w" goes: the cursors at 6 and at 8 meet.
        let meeting : Array Change := #[.retain 6, .delete 2, .retain 5]
        let met ← selectionAfter text .exclusive #[(6, 6), (8, 8), (0, 0)] 0 meeting
        let metOther ← selectionAfter text .exclusive #[(6, 6), (8, 8), (0, 0)] 2 meeting
        -- "llo w" goes: two ranges on characters come to share one, and the
        -- primary points backward.
        let joined ←
          selectionAfter text .inclusive #[(0, 3), (10, 7)] 1 #[.retain 3, .delete 5, .retain 5]
        return replaced == selected .exclusive #[(5, 5)] &&
            replacedBackward == selected .exclusive #[(5, 5)] &&
            replacedOnCharacters == selected .block #[(5, 5)] &&
            deleted == selected .exclusive #[(1, 1)] &&
            met == selected .exclusive #[(0, 0), (6, 6)] 1 &&
            metOther == selected .exclusive #[(0, 0), (6, 6)] 0 &&
            joined == selected .inclusive #[(5, 0)] },
    { name :=
        "place puts a marker somewhere else and can make it the other kind, and a refused place leaves it where it was"
      holds := do
        let text ← createText "héllo wörld"
        let marker ← text.mark (anchorAt 3 .after)
        let other ← text.mark (anchorAt 0 .before)
        text.place marker (anchorAt 6 .before)
        let moved ← text.marker marker
        text.place marker (selected .inclusive #[(13, 10), (4, 1)] 1)
        let asSelection ← text.marker marker
        let inside ← refusedWith .badPosition (text.place marker (anchorAt 2 .after))
        let astray ← refusedWith .badSelection (text.place marker (selected .line #[(0, 14)]))
        let kept ← text.marker marker
        text.place marker (anchorAt 13 .after)
        return moved == anchorAt 6 .before &&
            asSelection == selected .inclusive #[(4, 1), (13, 10)] 0 &&
            inside &&
            astray &&
            kept == asSelection &&
            (← text.marker marker) == anchorAt 13 .after &&
            (← text.marker other) == anchorAt 0 .before },
    { name :=
        "a marker that is given up is refused from then on, a later marker has another id, and an id the text never gave is refused, a selection that is none first"
      holds := do
        let text ← createText "héllo"
        let first ← text.mark (anchorAt 3 .after)
        let second ← text.mark (anchorAt 4 .after)
        text.unmark first
        let read ← refusedWith .noSuchMarker (discard <| text.marker first)
        let placed ← refusedWith .noSuchMarker (text.place first (anchorAt 0 .after))
        let again ← refusedWith .noSuchMarker (text.unmark first)
        let later ← text.mark (anchorAt 0 .before)
        let never : MarkerId := { later with index := later.index + 5 }
        let neverRead ← refusedWith .noSuchMarker (discard <| text.marker never)
        -- For an id that names nothing: a marker that is in the text, one
        -- that is not, and a selection that is none.
        let neverPlaced ← refusedWith .noSuchMarker (text.place never (anchorAt 0 .after))
        let neverMisplaced ← refusedWith .noSuchMarker (text.place never (anchorAt 2 .after))
        let neverNone ← refusedWith .badSelection (text.place never (selected .line #[]))
        let neverUnmarked ← refusedWith .noSuchMarker (text.unmark never)
        -- Cut down to a 64-bit word, `2 ^ 64 + second.index` is `second`.
        let huge : MarkerId := { second with index := 2 ^ 64 + second.index }
        let hugeRead ← refusedWith .noSuchMarker (discard <| text.marker huge)
        let hugePlaced ← refusedWith .noSuchMarker (text.place huge (anchorAt 0 .after))
        let hugeNone ← refusedWith .badSelection (text.place huge (selected .block #[(0, 0)] 1))
        let hugeUnmarked ← refusedWith .noSuchMarker (text.unmark huge)
        return read && placed && again && later != first && later != second && neverRead &&
            neverPlaced &&
            neverMisplaced &&
            neverNone &&
            neverUnmarked &&
            hugeRead &&
            hugePlaced &&
            hugeNone &&
            hugeUnmarked &&
            (← text.marker second) == anchorAt 4 .after &&
            (← text.marker later) == anchorAt 0 .before },
    { name :=
        "a refused edit moves no marker, and marking, placing and giving a marker up leave the revision and the log as they were"
      holds := do
        let text ← createText "héllo wörld"
        text.insert 0 "x"
        let since ← text.changesSince 0
        let anchor ← text.mark (anchorAt 4 .after)
        let range ← text.mark (selected .exclusive #[(2, 7)])
        let spare ← text.mark (anchorAt 0 .before)
        text.place spare (selected .line #[(0, 14)])
        text.unmark spare
        let unedited :=
          (← text.revision) == 1 && (← text.changesSince 0) == since &&
            (← text.changesSince 1) == ⟨1, 1, #[]⟩
        let inside ← refusedWith .badRange (text.insert 3 "x")
        let backwards ← refusedWith .badRange (text.delete 4 2)
        let short ← applyRefusedWith .badChange text { changes := #[.insert "XY", .retain 3] }
        let astray ←
          applyRefusedWith .badSelection text
              { changes := #[.insert "XY", .retain 14], after := some { ranges := #[⟨0, 99⟩] } }
        return unedited && inside && backwards && short && astray &&
            (← text.marker anchor) == anchorAt 4 .after &&
            (← text.marker range) == selected .exclusive #[(2, 7)] &&
            (← text.revision) == 1 },
    { name :=
        "a marker belongs to its text: another text refuses its id, and every marker request of a text no create returned, or one that was released, is refused"
      holds := do
        let text ← createText "héllo"
        let other ← createText "wörld"
        let marker ← text.mark (anchorAt 3 .after)
        -- The other text holds a marker of its own, the first it gave out
        -- as `marker` is the first of `text`: the id of one is not taken
        -- for the other's.
        let own ← other.mark (anchorAt 1 .before)
        let ofOther ← refusedWith .noSuchMarker (discard <| other.marker marker)
        let placedInOther ← refusedWith .noSuchMarker (other.place marker (anchorAt 0 .after))
        -- A selection that is none is still looked for before the id is.
        let noneInOther ← refusedWith .badSelection (other.place marker (selected .line #[]))
        let unmarkedInOther ← refusedWith .noSuchMarker (other.unmark marker)
        let ofText ← refusedWith .noSuchMarker (discard <| text.marker own)
        let ownKept := (← other.marker own) == anchorAt 1 .before
        -- Edits to the other text move nothing here.
        other.insert 0 "XY"
        let unmoved := (← text.marker marker) == anchorAt 3 .after
        let requests (text : TextId) : List (TextM Unit) :=
          [discard <| text.mark (anchorAt 0 .after), discard <| text.marker marker,
            text.place marker (anchorAt 0 .after), text.unmark marker,
            -- The text is looked for before a selection that is none is.
            text.place marker (selected .line #[])]
        let absent ← (requests ⟨7⟩).allM (refusedWith .noSuchText)
        text.release
        let released ← (requests text).allM (refusedWith .noSuchText)
        return ofOther && placedInOther && noneInOther && unmarkedInOther && ofText && ownKept &&
            unmoved &&
            absent &&
            released }]

/-- What the selection of shape `shape` with `ranges`, each an anchor and a
head, covers in a new text holding `initial`: each extent as its start and
its stop. -/
def covered (initial : String) (shape : Shape) (ranges : Array (Nat × Nat)) :
    TextM (Array (Nat × Nat)) := do
  let text ← createText initial
  let extents ← text.extents { ranges := ranges.map fun (anchor, head) => ⟨anchor, head⟩, shape }
  return extents.map fun extent => (extent.start, extent.stop)

/-- What the normal-state cursor on the character at `offset` covers in a new
text holding `initial`: an inclusive range with equal ends. -/
def cursorCovers (initial : String) (offset : Nat) : TextM (Array (Nat × Nat)) :=
  covered initial .inclusive #[(offset, offset)]

/-- Whether asking `text` what the selection of shape `shape` with `ranges`
and `primary` covers is refused with `badSelection`. -/
def extentsRefused (text : TextId) (shape : Shape) (ranges : Array (Nat × Nat))
    (primary : Nat := 0) : TextM Bool :=
  refusedWith .badSelection
    (discard <|
      text.extents { ranges := ranges.map fun (anchor, head) => ⟨anchor, head⟩, primary, shape })

/-- The properties of what a selection covers. -/
def extentProperties : List Property :=
  [{
      name :=
        "a cursor on the last character of a line covers it and not the line break, with a line feed and with a carriage return and a line feed",
      holds := do
        let lineFeed ← cursorCovers "ab\ncd" 1
        let both ← cursorCovers "ab\r\ncd" 1
        let lastLine ← cursorCovers "ab\ncd" 4
        return lineFeed == #[(1, 2)] && both == #[(1, 2)] && lastLine == #[(4, 5)] },
    { name :=
        "a cursor on an empty line covers its line break, and one on a line break covers all of it"
      holds := do
        let empty ← cursorCovers "a\n\nb" 2
        let emptyBoth ← cursorCovers "a\r\n\r\nb" 3
        let onLineFeed ← cursorCovers "ab\ncd" 2
        let onBoth ← cursorCovers "ab\r\ncd" 2
        return empty == #[(2, 3)] && emptyBoth == #[(3, 5)] && onLineFeed == #[(2, 3)] &&
            onBoth == #[(2, 4)] },
    { name :=
        "a cursor at the end of the text covers nothing: in an empty text, after the last character, and on the empty last row"
      holds := do
        let emptyText ← cursorCovers "" 0
        let afterLast ← cursorCovers "ab" 2
        let lastRow ← cursorCovers "ab\n" 3
        let lastRowBoth ← cursorCovers "ab\r\n" 4
        return emptyText == #[(0, 0)] && afterLast == #[(2, 2)] && lastRow == #[(3, 3)] &&
            lastRowBoth == #[(4, 4)] },
    { name := "a cursor on a character of several bytes covers all of them"
      holds := do
        let four ← cursorCovers "a😀b" 1
        let two ← cursorCovers "aéb" 1
        let escape ← cursorCovers escaped 1
        return four == #[(1, 5)] && two == #[(1, 3)] && escape == #[(1, 5)] },
    { name :=
        "an exclusive range covers from its lower end up to its higher, and an inclusive one through the character at its higher, whichever way each points"
      holds := do
        let exclusive ← covered rows .exclusive #[(1, 5)]
        let exclusiveBackward ← covered rows .exclusive #[(5, 1)]
        let bar ← covered rows .exclusive #[(3, 3)]
        let inclusive ← covered rows .inclusive #[(1, 5)]
        let inclusiveBackward ← covered rows .inclusive #[(5, 1)]
        -- Through "é", through the carriage return and its line feed,
        -- through the line feed alone, and through "😀".
        let throughTwo ← covered rows .inclusive #[(0, 1)]
        let throughBreak ← covered rows .inclusive #[(0, 6)]
        let throughLineFeed ← covered rows .inclusive #[(0, 7)]
        let throughFour ← covered rows .inclusive #[(15, 13)]
        return exclusive == #[(1, 5)] && exclusiveBackward == #[(1, 5)] && bar == #[(3, 3)] &&
            inclusive == #[(1, 6)] &&
            inclusiveBackward == #[(1, 6)] &&
            throughTwo == #[(0, 3)] &&
            throughBreak == #[(0, 8)] &&
            throughLineFeed == #[(0, 8)] &&
            throughFour == #[(13, 19)] },
    { name :=
        "a line-wise range covers its rows and the line feed of the last: one row, several, an empty row, a row that ends in a carriage return and a line feed, and a last row with no line feed"
      holds := do
        let one ← covered rows .line #[(9, 9)]
        let oneWide ← covered rows .line #[(8, 14)]
        let several ← covered rows .line #[(3, 11)]
        let severalBackward ← covered rows .line #[(11, 3)]
        let withBoth ← covered rows .line #[(0, 0)]
        let last ← covered rows .line #[(19, 19)]
        let all ← covered rows .line #[(20, 0)]
        let emptyRow ← covered "a\n\nb" .line #[(2, 2)]
        let emptyLastRow ← covered "ab\n" .line #[(3, 3)]
        let emptyText ← covered "" .line #[(0, 0)]
        return one == #[(8, 15)] && oneWide == #[(8, 15)] && several == #[(0, 15)] &&
            severalBackward == #[(0, 15)] &&
            withBoth == #[(0, 8)] &&
            last == #[(15, 20)] &&
            all == #[(0, 20)] &&
            emptyRow == #[(2, 3)] &&
            emptyLastRow == #[(3, 3)] &&
            emptyText == #[(0, 0)] },
    { name :=
        "a block covers the columns between its corners on each of its rows, counted in cells and cut off at each row's content"
      holds := do
        -- Columns 1 and 2 of three rows, the second too short for either.
        let block ← covered "abcd\nx\nabcd" .block #[(1, 9)]
        let backward ← covered "abcd\nx\nabcd" .block #[(9, 1)]
        let otherCorners ← covered "abcd\nx\nabcd" .block #[(2, 8)]
        -- Columns 1 to 3, and a second row with only columns 0 and 1.
        let cutOff ← covered "abcde\nxy\nabcde" .block #[(1, 12)]
        -- Rows that end in a carriage return and a line feed.
        let withBoth ← covered "abcd\r\nxy\r\nabcd" .block #[(1, 12)]
        -- "é" is two bytes and one column.
        let twoBytes ← covered "aéb\nabc" .block #[(1, 7)]
        -- A corner on a line break is past its row's content.
        let onBreak ← covered "ab\r\nabcd" .block #[(2, 4)]
        let emptyRow ← covered "ab\n\nab" .block #[(0, 5)]
        let oneCell ← covered "abcde" .block #[(2, 2)]
        let emptyText ← covered "" .block #[(0, 0)]
        return block == #[(1, 3), (6, 6), (8, 10)] && backward == block && otherCorners == block &&
            cutOff == #[(1, 4), (7, 8), (10, 13)] &&
            withBoth == #[(1, 3), (7, 8), (11, 13)] &&
            twoBytes == #[(1, 4), (6, 8)] &&
            onBreak == #[(0, 2), (4, 7)] &&
            emptyRow == #[(0, 2), (3, 3), (4, 6)] &&
            oneCell == #[(2, 3)] &&
            emptyText == #[(0, 0)] },
    { name :=
        "the extents of several ranges come back in order, those that overlap are one, and those that only touch stay two"
      holds := do
        let inOrder ← covered "abcdef" .inclusive #[(4, 4), (0, 1)]
        let touching ← covered "abcdef" .inclusive #[(0, 1), (2, 3)]
        let rowsApart ← covered "ab\ncd\nef" .line #[(7, 7), (0, 0)]
        -- Two line-wise ranges on one row.
        let oneRow ← covered "abcd\nef" .line #[(0, 0), (2, 3)]
        -- A second block inside the columns of the first, on its last row.
        let blocks ← covered "abcdef\nabcdef" .block #[(4, 8), (10, 10)]
        -- An empty extent that touches another: the empty last row.
        let emptyTouching ← covered "ab\n" .line #[(0, 0), (3, 3)]
        return inOrder == #[(0, 2), (4, 5)] && touching == #[(0, 2), (2, 4)] &&
            rowsApart == #[(0, 3), (6, 8)] &&
            oneRow == #[(0, 5)] &&
            blocks == #[(1, 5), (8, 12)] &&
            emptyTouching == #[(0, 3), (3, 3)] },
    { name :=
        "a selection that is none, or has an end that is not a position, covers nothing that can be said, in every shape; an end of a range that merged into another is no end of it"
      holds := do
        let text ← createText "héllo"
        let refused ←
          [Shape.exclusive, .inclusive, .line, .block].allM fun shape => do
              let noRange ← extentsRefused text shape #[]
              let noPrimary ← extentsRefused text shape #[(0, 0)] 1
              -- 2 is inside "é", and 7 is past the end.
              let inside ← extentsRefused text shape #[(0, 2)]
              let cursorInside ← extentsRefused text shape #[(2, 2)]
              let pastEnd ← extentsRefused text shape #[(0, 1), (4, 7)]
              let huge ← extentsRefused text shape #[(0, 2 ^ 64 + 1)]
              return noRange && noPrimary && inside && cursorInside && pastEnd && huge
        let absent ← refusedWith .noSuchText (discard <| (⟨7⟩ : TextId).extents { ranges := #[] })
        let merged ← covered "héllo" .exclusive #[(0, 6), (2, 1)]
        return refused && absent && merged == #[(0, 6)] },
    { name :=
        "a text and a snapshot of it answer alike, and a snapshot goes on answering for the text it holds"
      holds := do
        let text ← createText rows
        let before ← text.snapshot
        let selections : List Selection :=
          [{ ranges := #[⟨5, 1⟩, ⟨9, 9⟩], primary := 1 },
            { ranges := #[⟨6, 6⟩, ⟨15, 13⟩], shape := .inclusive },
            { ranges := #[⟨3, 11⟩], shape := .line }, { ranges := #[⟨1, 19⟩], shape := .block }]
        let alike ←
          selections.allM fun selection =>
              return (← text.extents selection) == (← before.extents selection)
        -- A row is added before the others.
        text.insert 0 "x\n"
        let line : Selection := { ranges := #[⟨0, 0⟩], shape := .line }
        let extent (start stop : Nat) : Extent := ⟨start, stop⟩
        return alike && (← before.extents line) == #[extent 0 8] &&
            (← text.extents line) == #[extent 0 2] &&
            (← before.extents { ranges := #[⟨1, 19⟩], shape := .block }) ==
              -- Column 1 of each row: "é", "ö" and "x".
              #[extent 1 3, extent 9 11, extent 19 20] }]

/-- Whether applying the inverse of the run from `first` to `last` to `text`
is refused with `error`. -/
def inverseRefusedWith (error : TextError) (text : TextId) (first last : Nat) : TextM Bool :=
  refusedWith error (discard <| text.applyInverse first last)

/-- Applies the inverse of the run from `first` to `last` to `text`, and
returns the revision it produced and what the text then reads. -/
def invertedTo (text : TextId) (first last : Nat) : TextM (Nat × String) := do
  let inverted ← text.applyInverse first last
  return (inverted.revision, ← text.read)

/-- Makes a text holding "héllo wörld" and changes it three times, by a
transaction, an insert and a delete, to "hello, rld😀": "é" becomes "e" and
"😀" is added at the end; "," is inserted after "hello"; and "wö" is
deleted. -/
def changedThreeWays : TextM TextId := do
  let text ← createText "héllo wörld"
  discard <| text.apply { changes := #[.retain 1, .delete 2, .insert "e", .retain 10, .insert "😀"] }
  text.insert 5 ","
  text.delete 7 10
  return text

/-- Makes a text holding "héllo" and adds "1" to "5" at its end, one edit
each: "héllo12345", at revision 5. -/
def editedFiveTimes : TextM TextId := do
  let text ← createText "héllo"
  text.insert 6 "1"
  text.insert 7 "2"
  text.insert 8 "3"
  text.insert 9 "4"
  text.insert 10 "5"
  return text

/-- The selection of shape `shape` with `ranges`, each an anchor and a head,
whose primary is the one at `primary`. -/
def selection (shape : Shape) (ranges : Array (Nat × Nat)) (primary : Nat := 0) : Selection :=
  { ranges := ranges.map fun (anchor, head) => ⟨anchor, head⟩, primary, shape }

/-- The properties of kept inverses: applying the inverse of a run of
revisions, and dropping the inverses a text keeps. -/
def inverseProperties : List Property :=
  [{
      name :=
        "the inverse of a run of revisions restores the text the run started from, as one new revision and one entry of the log, whichever way each edit of the run was made",
      holds := do
        let text ← changedThreeWays
        let made := (← text.read) == "hello, rld😀" && (← text.revision) == 3
        let inverted ← text.applyInverse 1 3
        -- The old spans are ranges of "hello, rld😀" and the new ones of
        -- "héllo wörld".
        return made && inverted == ⟨4, none⟩ && (← text.read) == "héllo wörld" &&
            (← text.revision) == 4 &&
            (← text.changesSince 3) ==
              ⟨3, 4,
                #[⟨span 1 2 (0, 1) (0, 2), span 1 3 (0, 1) (0, 3)⟩,
                  ⟨span 5 6 (0, 5) (0, 6), span 6 6 (0, 6) (0, 6)⟩,
                  ⟨span 7 7 (0, 7) (0, 7), span 7 10 (0, 7) (0, 10)⟩,
                  ⟨span 10 14 (0, 10) (0, 14), span 13 13 (0, 13) (0, 13)⟩]⟩ },
    { name :=
        "the inverse of an inverse restores the text again, and the two go back and forth, each at one more revision"
      holds := do
        let text ← changedThreeWays
        discard <| text.applyInverse 1 3
        let redone ← invertedTo text 4 4
        let undone ← invertedTo text 5 5
        let again ← invertedTo text 6 6
        return redone == (5, "hello, rld😀") && undone == (6, "héllo wörld") &&
            again == (7, "hello, rld😀") },
    -- "é😀llo wörld": "é" is the bytes 0 and 1 and "😀" the bytes 2 to 5.
    { name :=
        "an inverse is refused, and the text, its revision, its log and its markers unchanged, when the text is not in the state its run ended in"
      holds := do
        let text ← createText "héllo wörld"
        text.insert 3 "😀"
        text.delete 0 1
        let marker ← text.mark (anchorAt 2 .after)
        let newest ← text.changesSince 1
        -- The first edit's run did not end where the text is.
        let refused ← inverseRefusedWith .notInState text 1 1
        let unchanged :=
          (← text.read) == "é😀llo wörld" && (← text.revision) == 2 &&
            (← text.changesSince 1) == newest &&
            (← text.changesSince 2) == ⟨2, 2, #[]⟩ &&
            (← text.marker marker) == anchorAt 2 .after
        -- Once the second edit is taken back, its inverse is refused and the
        -- first's is accepted.
        let second ← invertedTo text 2 2
        let again ← inverseRefusedWith .notInState text 2 2
        let first ← invertedTo text 1 1
        return refused && unchanged && second == (3, "hé😀llo wörld") && again &&
            first == (4, "héllo wörld") },
    { name :=
        "a state is where a text is in its history, not what it holds: a text edited by hand back to what it read is not where it was, and one brought back by inverses is"
      holds := do
        let typed ← createText "héllo"
        typed.insert 0 "é"
        typed.delete 0 2
        let reads := (← typed.read) == "héllo"
        let refused ← inverseRefusedWith .notInState typed 1 1
        -- An edit, its inverse and the inverse of that leave the text where
        -- the edit left it, so the edit's own inverse is accepted again.
        let brought ← createText "héllo"
        brought.insert 0 "é"
        discard <| brought.applyInverse 1 1
        let back ← invertedTo brought 2 2
        let accepted ← invertedTo brought 1 1
        return reads && refused && (← typed.revision) == 2 && back == (3, "éhéllo") &&
            accepted == (4, "héllo") },
    { name :=
        "a branch is switched by inverses: after an edit is taken back and another made, the first is reached again by the inverse of the second and the inverse of the inverse, though the inverses each crossing no longer needs are dropped"
      holds := do
        let text ← createText "héllo"
        -- Edits A and B.
        text.insert 6 " A"
        text.insert 8 "B"
        -- Undo B, and drop what the crossing no longer needs.
        let undoB ← invertedTo text 2 2
        text.dropInverses 2 2
        -- B's own inverse is gone, and the text is not where B left it.
        let gone ← inverseRefusedWith .noInverse text 2 2
        -- Edit C, a new branch.
        text.insert 8 "C"
        let branched := (← text.read) == "héllo AC" && (← text.revision) == 4
        -- Back to B: undo C, then redo B by the inverse of its undo.
        let undoC ← invertedTo text 4 4
        text.dropInverses 4 4
        let redoB ← invertedTo text 3 3
        text.dropInverses 3 3
        -- And to C again, by the inverses the last two crossings left.
        let undoAgain ← invertedTo text 6 6
        let redoC ← invertedTo text 5 5
        return undoB == (3, "héllo A") && gone && branched && undoC == (5, "héllo A") &&
            redoB == (6, "héllo AB") &&
            undoAgain == (7, "héllo A") &&
            redoC == (8, "héllo AC") },
    -- "Xhéllo": "é" is the bytes 2 and 3. A model that found what an inverse
    -- changed from the bytes the text holds now, and not from those it held
    -- when the run ended, would say the restored "é" was changed again.
    { name :=
        "an inverse keeps what its run kept though the text has been away and back: text another inverse restored in between is not changed by it, and is still traced to the inverse that restored it"
      holds := do
        let text ← createText "héllo"
        text.insert 0 "X"
        text.delete 2 4
        let restored ← invertedTo text 2 2
        let inverted ← text.applyInverse 1 1 ⟨5⟩
        return restored == (3, "Xhéllo") && inverted == ⟨4, none⟩ && (← text.read) == "héllo" &&
            (← text.changesSince 3) ==
              ⟨3, 4, #[⟨span 0 1 (0, 0) (0, 1), span 0 0 (0, 0) (0, 0)⟩]⟩ &&
            (← text.trace 0 6) ==
              #[⟨0, 1, .earlier 0⟩, ⟨1, 3, .entry 3 .unattributed⟩, ⟨3, 6, .earlier 0⟩] },
    { name :=
        "a run may hold inverses: an edit, its inverse and the inverse of that are one run, and so are edits with the inverse of the last of them, or with that inverse left out"
      holds := do
        let replaced : Transaction :=
          { changes := #[.retain 1, .delete 2, .insert "E", .retain 10] }
        let text ← createText "héllo wörld"
        discard <| text.apply replaced
        discard <| text.applyInverse 1 1
        let redone ← invertedTo text 2 2
        let whole ← invertedTo text 1 3
        -- Three edits and the inverse of the third: the text is where the
        -- second left it.
        let thrice : TextM TextId := do
          let text ← createText "héllo wörld"
          discard <| text.apply replaced
          text.insert 12 "😀"
          text.delete 0 1
          discard <| text.applyInverse 3 3
          return text
        let short ← thrice
        let long ← thrice
        let there := (← short.read) == "hEllo wörld😀"
        return redone == (3, "hEllo wörld") && whole == (4, "héllo wörld") && there &&
            (← invertedTo short 1 2) == (5, "héllo wörld") &&
            (← invertedTo long 1 4) == (5, "héllo wörld") },
    -- "😀 héllo" is 11 bytes: "😀" is the bytes 0 to 3 and "é" the bytes 6
    -- and 7. With "X" inserted after "😀" it is "😀X héllo", and with "é"
    -- then deleted "😀X hllo".
    { name :=
        "applying an inverse hands back the selection before that its run's first transaction carried, in the store's form, of each shape; none when that transaction carried none; and the inverse of the inverse hands back the selection after that the run's last carried"
      holds := do
        let inserting : Transaction := { changes := #[.retain 4, .insert "X", .retain 7] }
        let deleting : Transaction := { changes := #[.retain 7, .delete 2, .retain 3] }
        let shapes : List Shape := [.exclusive, .inclusive, .line, .block]
        let handedBack ←
          shapes.allM fun shape => do
              let text ← createText "😀 héllo"
              -- Given out of order, and with two ranges that overlap.
              discard <|
                  text.apply
                    { inserting with
                      before := some (selection shape #[(8, 5), (0, 4), (6, 8)])
                      after := some (selection shape #[(5, 5)]) }
              discard <|
                  text.apply
                    { deleting with
                      before := some (selection shape #[(7, 9)])
                      after := some (selection shape #[(7, 7), (0, 4)]) }
              let before := selection shape #[(0, 4), (8, 5)] 1
              let after := selection shape #[(0, 4), (7, 7)] 1
              let undone ← text.applyInverse 1 2
              -- It is a selection of the text the inverse left.
              let placed ← text.mark (.selection before)
              let held := (← text.marker placed) == .selection before
              let redone ← text.applyInverse 3 3
              let marked ← text.mark (.selection after)
              return undone == ⟨3, some before⟩ && held && redone == ⟨4, some after⟩ &&
                  (← text.marker marked) == .selection after &&
                  (← text.read) == "😀X hllo"
        -- The first transaction carried none, though the second did.
        let text ← createText "😀 héllo"
        discard <| text.apply inserting
        discard <|
            text.apply
              { deleting with
                before := some (selection .exclusive #[(7, 9)])
                after := some (selection .inclusive #[(7, 7)]) }
        let undone ← text.applyInverse 1 2
        let redone ← text.applyInverse 3 3
        return handedBack && undone == ⟨3, none⟩ &&
            redone == ⟨4, some (selection .inclusive #[(7, 7)])⟩ },
    { name :=
        "an inverse is an edit to the log: its entry has the origin it was given, a trace names the bytes it restored with its revision and that origin, and what changed across an edit and its inverse is nothing for an insert and one range replaced by itself for a delete"
      holds := do
        -- The character of four bytes is deleted by one origin and restored
        -- by another's inverse.
        let text ← createText "a😀b"
        discard <| text.apply { changes := #[.retain 1, .delete 4, .retain 1] } ⟨3⟩
        let inverted ← text.applyInverse 1 1 ⟨7⟩
        let inserted ← createText "héllo"
        inserted.insert 3 "😀"
        discard <| inserted.applyInverse 1 1
        return inverted == ⟨2, none⟩ && (← text.read) == "a😀b" &&
            (← text.trace 0 6) == #[⟨0, 1, .earlier 0⟩, ⟨1, 5, .entry 2 ⟨7⟩⟩, ⟨5, 6, .earlier 0⟩] &&
            (← text.changesSince 1) ==
              ⟨1, 2, #[⟨span 1 1 (0, 1) (0, 1), span 1 5 (0, 1) (0, 5)⟩]⟩ &&
            (← text.changesSince 0) ==
              ⟨0, 2, #[⟨span 1 5 (0, 1) (0, 5), span 1 5 (0, 1) (0, 5)⟩]⟩ &&
            (← inserted.changesSince 0) == ⟨0, 2, #[]⟩ },
    { name :=
        "a marker follows an inverse as it follows any edit: an anchor inside text an edit deleted is before or after the restored text by its bias and not inside it, one outside is where it was, and through a run of two revisions an anchor is where the one change of the run's inverse puts it"
      holds := do
        let text ← createText "héllo wörld"
        let stays ← text.mark (anchorAt 8 .before)
        let goes ← text.mark (anchorAt 8 .after)
        let outside ← text.mark (anchorAt 3 .after)
        -- "wörld" is deleted, and put back at 7.
        text.delete 7 13
        let collapsed := (← text.marker stays, ← text.marker goes) == anchorsAt 7 7
        discard <| text.applyInverse 1 1
        let one :=
          (← text.marker stays, ← text.marker goes) == anchorsAt 7 13 &&
            (← text.marker outside) == anchorAt 3 .after
        -- "é" is deleted and "E" inserted where it was. The inverse of the
        -- two replaces "E" by "é" as one change: an anchor at the end of
        -- "E" is after "é", where through the two inverses in turn it would
        -- be before it.
        let run ← createText "héllo wörld"
        run.delete 1 3
        run.insert 1 "E"
        let before ← run.mark (anchorAt 1 .before)
        let after ← run.mark (anchorAt 1 .after)
        let past ← run.mark (anchorAt 2 .before)
        discard <| run.applyInverse 1 2
        return collapsed && one && (← run.read) == "héllo wörld" &&
            (← run.marker before, ← run.marker after) == anchorsAt 1 3 &&
            (← run.marker past) == anchorAt 3 .before },
    -- Cut down to a 64-bit word, `2 ^ 64 + 2` is 2, a revision the text
    -- reached, whose inverse the text is at the end of.
    { name :=
        "an inverse is refused, changing nothing, in this order: for a run that names a revision the text has not reached or that no machine word holds; for a run the text keeps no inverse for, because it starts at revision 0, is backwards or names a dropped revision; and then for a run the text is not at the end of"
      holds := do
        let text ← createText "héllo"
        text.insert 0 "x"
        text.insert 0 "y"
        let ahead ← inverseRefusedWith .unknownRevision text 1 3
        let bothAhead ← inverseRefusedWith .unknownRevision text 3 3
        let firstAhead ← inverseRefusedWith .unknownRevision text 3 2
        let huge ← inverseRefusedWith .unknownRevision text (2 ^ 64 + 2) (2 ^ 64 + 2)
        let hugeLast ← inverseRefusedWith .unknownRevision text 2 (2 ^ 64 + 2)
        let fromZero ← inverseRefusedWith .noInverse text 0 2
        let zero ← inverseRefusedWith .noInverse text 0 0
        let backwards ← inverseRefusedWith .noInverse text 2 1
        -- A revision not reached is looked for first, and a missing inverse
        -- before the state: the text is not where the first edit left it.
        let aheadFirst ← inverseRefusedWith .unknownRevision text 0 3
        let elsewhere ← inverseRefusedWith .notInState text 1 1
        text.dropInverses 1 1
        let dropped ← inverseRefusedWith .noInverse text 1 1
        let run ← inverseRefusedWith .noInverse text 1 2
        return ahead && bothAhead && firstAhead && huge && hugeLast && fromZero && zero &&
            backwards &&
            aheadFirst &&
            elsewhere &&
            dropped &&
            run &&
            (← text.read) == "yxhéllo" &&
            (← text.revision) == 2 &&
            (← text.changesSince 2) == ⟨2, 2, #[]⟩ },
    { name :=
        "a revision is a number of its own text: two texts at the same revisions each keep and apply their own inverses, and an id that names no text, or one that was released, is refused"
      holds := do
        let one ← createText "héllo"
        let other ← createText "wörld"
        one.insert 0 "a"
        one.insert 0 "b"
        other.insert 0 "c"
        other.insert 0 "d"
        let first ← invertedTo one 2 2
        let untouched := (← other.read) == "dcwörld" && (← other.revision) == 2
        let second ← invertedTo other 2 2
        let stranger : TextId := ⟨7⟩
        let noText ← inverseRefusedWith .noSuchText stranger 1 1
        let noDrop ← refusedWith .noSuchText (stranger.dropInverses 1 1)
        one.release
        let released ← inverseRefusedWith .noSuchText one 3 3
        let releasedDrop ← refusedWith .noSuchText (one.dropInverses 1 1)
        return first == (3, "ahéllo") && untouched && second == (3, "cwörld") && noText && noDrop &&
            released &&
            releasedDrop },
    -- Cut down to a 64-bit word, `2 ^ 64 + 5` is 5, the text's revision.
    { name :=
        "after the inverses of a run are dropped, every run that names one of them is refused and the others still apply; a drop changes neither the text nor its revision nor its log; dropping what is not kept changes nothing; and a drop past the text's revision, or to one no machine word holds, is refused"
      holds := do
        let text ← editedFiveTimes
        let since ← text.changesSince 0
        text.dropInverses 2 3
        let runs : List (Nat × Nat) :=
          [(1, 5), (2, 5), (3, 5), (2, 2), (3, 3), (2, 3), (1, 2), (3, 4)]
        let refused ← runs.allM fun (first, last) => inverseRefusedWith .noInverse text first last
        let unchanged :=
          (← text.read) == "héllo12345" && (← text.revision) == 5 &&
            (← text.changesSince 0) == since &&
            since == ⟨0, 5, #[⟨span 6 6 (0, 6) (0, 6), span 6 11 (0, 6) (0, 11)⟩]⟩
        -- What is not kept: dropped already, revision 0, a run whose first
        -- is after its last, and one whose first no word holds.
        text.dropInverses 2 3
        text.dropInverses 0 0
        text.dropInverses 5 4
        text.dropInverses (2 ^ 64 + 4) 5
        let ahead ← refusedWith .unknownRevision (text.dropInverses 1 6)
        let huge ← refusedWith .unknownRevision (text.dropInverses 4 (2 ^ 64 + 5))
        let fifth ← invertedTo text 5 5
        let fourth ← invertedTo text 4 4
        return refused && unchanged && ahead && huge && fifth == (6, "héllo1234") &&
            fourth == (7, "héllo123") },
    { name :=
        "forgetting the log and dropping inverses are independent: with the whole log forgotten an inverse is still accepted and is the one entry after where the log starts, and with every inverse dropped the log still answers"
      holds := do
        let forgotten ← editedFiveTimes
        forgotten.forget 5
        let inverted ← forgotten.applyInverse 1 5 ⟨9⟩
        let behind ← refusedWith .forgotten (discard <| forgotten.changesSince 4)
        let dropped ← editedFiveTimes
        dropped.dropInverses 1 5
        return inverted == ⟨6, none⟩ && (← forgotten.read) == "héllo" && behind &&
            (← forgotten.changesSince 5) ==
              ⟨5, 6, #[⟨span 6 11 (0, 6) (0, 11), span 6 6 (0, 6) (0, 6)⟩]⟩ &&
            (← forgotten.trace 0 6) == #[⟨0, 6, .earlier 5⟩] &&
            (← dropped.changesSince 0) ==
              ⟨0, 5, #[⟨span 6 6 (0, 6) (0, 6), span 6 11 (0, 6) (0, 11)⟩]⟩ &&
            (← dropped.trace 5 8) ==
              #[⟨5, 6, .earlier 0⟩, ⟨6, 7, .entry 1 .unattributed⟩,
                ⟨7, 8, .entry 2 .unattributed⟩] }]

/-- The properties of making a text from a text or from a snapshot
(`TextSource.copy`). The texts hold two- and four-byte characters and an
escape, and every expected value is written out by hand. -/
def copyProperties : List Property :=
  [{
      name :=
        "a copy of a text at revision 3 holds what the text holds, at revision 0, with an empty log: nothing has changed since 0, and its bytes are earlier than its log",
      holds := do
        -- "a", the escape of `0xFF`, "b", "é" and "😀": twelve bytes.
        let text ← createText (escaped ++ "é😀")
        text.insert 0 "y"
        text.insert 0 "x"
        text.delete 1 2
        let copy ← text.copy
        return copy != text && (← text.revision) == 3 &&
            (← copy.read) == ("xa".push (Char.ofNat 0x10DCFF)) ++ "bé😀" &&
            (← copy.revision) == 0 &&
            (← copy.byteLength) == 13 &&
            (← copy.rowCount) == 1 &&
            (← copy.changesSince 0) == ⟨0, 0, #[]⟩ &&
            (← copy.trace 0 13) == #[⟨0, 13, .earlier 0⟩] },
    { name :=
        "a copy is a text of its own: an edit to the copy and an edit to its source each leave the other, and the source's snapshot, as they were"
      holds := do
        let text ← createText "héllo\n😀"
        let snapshot ← text.snapshot
        let copy ← text.copy
        copy.insert 0 "C"
        text.insert 11 "T"
        return (← copy.read) == "Chéllo\n😀" && (← text.read) == "héllo\n😀T" &&
            (← snapshot.read) == "héllo\n😀" &&
            (← copy.revision) == 1 &&
            (← text.revision) == 1 &&
            (← snapshot.revision) == 0 },
    { name :=
        "a copy of a snapshot holds what the snapshot holds though its text has moved on, at revision 0 whatever the snapshot's, and outlives the release of both"
      holds := do
        let text ← createText escaped
        text.insert 0 "é"
        let snapshot ← text.snapshot
        text.insert 0 "😀"
        let copy ← snapshot.copy
        let made ← copy.revision
        text.release
        snapshot.release
        copy.insert 8 "!"
        return made == 0 &&
            (← copy.read) == (("éa".push (Char.ofNat 0x10DCFF)).push 'b').push '!' &&
            (← copy.revision) == 1 },
    { name :=
        "a copy has none of its source's markers and none of its kept inverses: it refuses a marker id of its source though it holds a marker under the same number, and the inverse of its source's revision 1"
      holds := do
        let text ← createText "héllo"
        let marker ← text.mark (anchorAt 1 .before)
        text.insert 0 "x"
        let copy ← text.copy
        let own ← copy.mark (anchorAt 4 .after)
        let foreign ← refusedWith .noSuchMarker (discard <| copy.marker marker)
        let inverse ← inverseRefusedWith .unknownRevision copy 1 1
        return own.index == marker.index && own.text == copy && foreign && inverse &&
            (← copy.marker own) == anchorAt 4 .after &&
            (← copy.read) == "xhéllo" &&
            (← text.marker marker) == anchorAt 2 .before &&
            (← invertedTo text 1 1) == (2, "héllo") },
    { name :=
        "a copy of an id that names nothing is refused and makes no text: a text and a snapshot never made, and a text and a snapshot that were released; the next text made has the id it would have had"
      holds := do
        let text ← createText "héllo"
        let snapshot ← text.snapshot
        let released ← createText "gone"
        released.release
        snapshot.release
        let never ← refusedWith .noSuchText (discard (TextId.mk 7).copy)
        let gone ← refusedWith .noSuchText (discard released.copy)
        let neverTaken ← refusedWith .noSuchSnapshot (discard (SnapshotId.mk 7).copy)
        let goneSnapshot ← refusedWith .noSuchSnapshot (discard snapshot.copy)
        let next ← createText "next"
        return never && gone && neverTaken && goneSnapshot && next.index == released.index + 1 &&
            (← next.read) == "next" }]

/-- The properties every implementation of the text port has. -/
def properties : List Property :=
  editProperties ++ revisionProperties ++ snapshotProperties ++ positionProperties ++
    releaseProperties ++
    transactionProperties ++
    logProperties ++
    forgetProperties ++
    markerProperties ++
    extentProperties ++
    inverseProperties ++
    copyProperties

/-- Runs each of `properties` with `run`, which must start every command from
an empty store, and returns the names of those that did not hold. A property
whose command failed is named with the error it failed with. -/
def failures (run : TextM Bool → IO (Except TextError Bool)) (properties : List Property) :
    IO (List String) :=
  properties.filterMapM fun property => do
    match ← run property.holds with
    | .ok true =>
      return none
    | .ok false =>
      return some property.name
    | .error error =>
      return some s!"{property.name} (the command failed with {repr error})"

/-- One property of taking a job's snapshot into the store
(`JobSnapshotId.adopt`): what the command's run is handed, and a command
that observes the property. Whoever runs the list hands each run its
snapshots: the model is handed the strings, and the real binding snapshots
the library made of the same strings. So the list needs no job. -/
structure AdoptProperty where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- What the run is handed: the snapshots a job held, each as the job's
  name for it and the text it holds. -/
  arrived : Array (JobSnapshotId × String)
  /-- Observes the property, from an empty store, in a run that was handed
  `arrived`; `true` when it holds. A command that fails has not held. -/
  holds : TextM Bool

/-- What a job's snapshot holds, in the properties below: "héllo", a
carriage return and a line feed, "😀", and the escape of the byte `0xFF`.
Sixteen bytes in two rows: the second starts at 8, and the escape at 12. -/
def loaded : String :=
  "héllo\r\n😀".push (Char.ofNat 0x10DCFF)

/-- The properties of taking a job's snapshot into the store. A
`JobSnapshotId` is handed under a number that a text and a snapshot of the
store also have, so an id of one kind read as another is seen. -/
def adoptProperties : List AdoptProperty :=
  [{  name :=
        "an adopted snapshot reads what the job's snapshot holds, with its length, its rows and its revision, under the store's next id: with a text and a snapshot of the same number already there, it is not that snapshot, which reads what it did",
      arrived := #[(⟨0⟩, loaded)]
      holds := do
        let text ← createText "other"
        let taken ← text.snapshot
        let adopted ← (JobSnapshotId.mk 0).adopt
        return adopted != taken && adopted.index == taken.index + 1 &&
            (← adopted.read) == "héllo\r\n😀".push (Char.ofNat 0x10DCFF) &&
            (← adopted.byteLength) == 16 &&
            (← adopted.rowCount) == 2 &&
            (← adopted.revision) == 0 &&
            (← taken.read) == "other" &&
            (← text.read) == "other" },
    { name :=
        "an adopted snapshot is a snapshot like any other: it answers a question, it is copied into a text that is then edited without changing it, and it is released, after which its id is refused"
      arrived := #[(⟨3⟩, loaded)]
      holds := do
        let adopted ← (JobSnapshotId.mk 3).adopt
        let point ← adopted.pointOf 12
        let copy ← adopted.copy
        copy.insert 0 "x"
        let unchanged ← adopted.read
        adopted.release
        let read ← refusedWith .noSuchSnapshot (discard adopted.read)
        let again ← refusedWith .noSuchSnapshot adopted.release
        return point == ⟨1, 4⟩ && (← copy.read) == "xhéllo\r\n😀".push (Char.ofNat 0x10DCFF) &&
            unchanged == loaded &&
            read &&
            again },
    { name :=
        "a job's snapshot becomes a text: the text holds it at revision 0, and the store keeps no snapshot of it, since what was adopted on the way is released"
      arrived := #[(⟨3⟩, loaded)]
      holds := do
        let other ← createText "other"
        let before ← other.snapshot
        let text ← (JobSnapshotId.mk 3).toText
        let after ← other.snapshot
        let between ← refusedWith .noSuchSnapshot (discard (SnapshotId.mk (before.index + 1)).read)
        return text != other && (← text.read) == loaded && (← text.revision) == 0 &&
            after.index == before.index + 2 &&
            between },
    { name :=
        "adopting does not use a job's id up, and each id names its own snapshot: one adopted twice gives two ids that both read it, releasing one leaves the other, and a second snapshot handed in the same run reads its own text"
      arrived := #[(⟨5⟩, "five é"), (⟨9⟩, loaded)]
      holds := do
        let first ← (JobSnapshotId.mk 9).adopt
        let second ← (JobSnapshotId.mk 9).adopt
        let other ← (JobSnapshotId.mk 5).adopt
        let firstRead ← first.read
        first.release
        let released ← refusedWith .noSuchSnapshot (discard first.read)
        return first != second && firstRead == loaded && released && (← second.read) == loaded &&
            (← other.read) == "five é" },
    { name :=
        "with nothing handed to the run, a job's id is refused and takes nothing in, though a text and a snapshot of the store have its number: the next snapshot taken has the id it would have had"
      arrived := #[]
      holds := do
        let text ← createText "héllo"
        let taken ← text.snapshot
        let refused ← refusedWith .noSuchSnapshot (discard (JobSnapshotId.mk 0).adopt)
        let next ← text.snapshot
        return refused && next.index == taken.index + 1 && (← next.read) == "héllo" },
    { name :=
        "an id the run was not handed is refused and takes nothing in, whatever else was handed: neither a neighbouring number nor the place of a snapshot among those handed names one"
      arrived := #[(⟨5⟩, "five"), (⟨9⟩, "nine")]
      holds := do
        let text ← createText "héllo"
        let taken ← text.snapshot
        let refused ←
          [0, 1, 4, 6, 8, 10].allM fun number =>
              refusedWith .noSuchSnapshot (discard (JobSnapshotId.mk number).adopt)
        let next ← text.snapshot
        return refused && next.index == taken.index + 1 }]

/-- Runs each of `properties` with `run`, which is given what the run is
handed and must start the command from an empty store, and returns the names
of those that did not hold. -/
def adoptFailures (run : Array (JobSnapshotId × String) → TextM Bool → IO (Except TextError Bool))
    (properties : List AdoptProperty) : IO (List String) :=
  properties.filterMapM fun property => do
    match ← run property.arrived property.holds with
    | .ok true =>
      return none
    | .ok false =>
      return some property.name
    | .error error =>
      return some s!"{property.name} (the command failed with {repr error})"

end Editor.TextContract
