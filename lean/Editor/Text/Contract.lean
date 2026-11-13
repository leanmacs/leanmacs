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

/-- Changes over `rows` in which "é" becomes "e", "w" becomes "W" and "😀"
goes: they make "hello\r\nWörld\nx", 15 bytes long. -/
def severalChanges : Array Change :=
  #[.retain 1, .delete 2, .insert "e", .retain 5, .insert "W", .delete 1, .retain 6, .delete 4,
    .retain 1]

/-- Whether applying `transaction` to `text` is refused with `error`. -/
def applyRefusedWith (error : TextError) (text : TextId) (transaction : Transaction) :
    EditorM Bool :=
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
def changedFourTimes : EditorM (TextId × Nat × Nat) := do
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

/-- The properties every implementation of the text port has. -/
def properties : List Property :=
  editProperties ++ revisionProperties ++ snapshotProperties ++ positionProperties ++
    releaseProperties ++
    transactionProperties ++
    logProperties ++
    forgetProperties

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
