import Editor.Ffi.Document
import Editor.Ffi.Snapshot

/-!
# FFI tests: support: Texts

Texts and snapshots: rows of text, a snapshot of them, a moved offset, the
largest word, and equality of two results. Shared by several test modules; it
holds no checks of its own.
-/

namespace FfiTest

/-- Text of three rows. "é" and "ö" are two bytes and one UTF-16 unit each,
and "😀" is four bytes and two units. The first row ends in a carriage return
and a line feed, at the bytes 6 and 7; the second starts at 8; the third
starts at 15 with "😀", and its "x" is at 19. The text is 20 bytes long. -/
def rows : String :=
  "héllo\r\nwörld\n😀x"

/-- A snapshot of a document made here holding `text`. The document is
dropped on the way out, so the snapshot is all that is left of it. -/
def snapshotOf (text : String) : IO Editor.Ffi.Snapshot := do
  let document ← Editor.Ffi.Document.new text
  document.snapshot

/-- Text of four rows, 30 bytes long, for the motions. Row 0 is `foo.bar`,
two spaces and `x`, and ends in a carriage return and a line feed at the
bytes 10 and 11; row 1 is empty, a carriage return and a line feed at 12 and
13; row 2 starts at 14 with a tab, then `s`, `e`, a combining acute (two
bytes, at 17), "😀" (four, at 19), `!`, a space and `y`, and ends in a line
feed at 26; row 3 is `end`, from 27. -/
def moved : String :=
  "foo.bar  x\r\n\r\n\tsé😀! y\nend"

/-- The largest number a word holds, which no text accepts as a length or an
offset, and which a motion by rows reads as a count or a column past any
text's. -/
def largestWord : UInt64 :=
  0xFFFF_FFFF_FFFF_FFFF

/-- Two results are equal when they are the same answer or the same
refusal. -/
instance {ε α : Type} [BEq ε] [BEq α] : BEq (Except ε α) where
  beq
    | .ok one, .ok other => one == other
    | .error one, .error other => one == other
    | _, _ => false

end FfiTest
