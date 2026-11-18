import Editor.Ffi.Snapshot
import Editor.Ffi.Text

/-!
# Bindings: pairs

The bindings of `crates/editor-ffi/src/pair.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Plain data").

The externs are exported from `snapshot.rs`; the logic is `pair.rs`'s.
-/

namespace Editor.Ffi

/-- A kind of bracket of the library (`crates/editor-text`, `Bracket`). -/
inductive Bracket where
  /-- `(` and `)`. -/
  | round
  /-- `[` and `]`. -/
  | square
  /-- `{` and `}`. -/
  | curly
  deriving DecidableEq, Repr

/-- A kind of quote of the library (`crates/editor-text`, `Quote`). -/
inductive Quote where
  /-- `"`. -/
  | double
  /-- `'`. -/
  | single
  /-- `` ` ``. -/
  | back
  deriving DecidableEq, Repr

/-- A bracket as it crosses: its tag. The table of tags is in the module docs
of `crates/editor-ffi/src/pair.rs`, which checks the tag. -/
private def Bracket.tag : Bracket → UInt8
  | .round => 0
  | .square => 1
  | .curly => 2

/-- A quote as it crosses: its tag, from the same table. -/
private def Quote.tag : Quote → UInt8
  | .double => 0
  | .single => 1
  | .back => 2

/-- `Snapshot.unmatched` as it crosses: the bracket as a tag, four flags and
the offset in, and `none` for a refusal, `some none` for no such bracket and
`some (some at)` for the bracket found. -/
@[extern "editor_glue_snapshot_unmatched"]
private opaque Snapshot.unmatchedRaw (snapshot : @& Snapshot) (tag : UInt8)
    (opening forward escaped skipQuoted : Bool) (offset : USize) : IO (Option (Option UInt64))

/-- `Snapshot.quoted` as it crosses: the quote as a tag and the offset in, and
`none` for a refusal, `some none` for no string and `some (some range)` for
the string found. -/
@[extern "editor_glue_snapshot_quoted"]
private opaque Snapshot.quotedRaw (snapshot : @& Snapshot) (tag : UInt8) (offset : USize) :
    IO (Option (Option ByteRange))

/-- The bracket of the kind `bracket` that the walk from the byte offset
`offset` of the snapshot leaves unbalanced: an opening one when `opening`,
strictly after the offset when `forward` and before it otherwise, counting
only the brackets whose escapedness is `escaped`, and passing over those Vim
guesses are quoted when `skipQuoted`. The rule is the library's
(`crates/editor-text`; `Editor/Text.lean`, "Pairs"). `none` unless the offset
is a position of the text; `some none` when there is no such bracket. -/
def Snapshot.unmatched (snapshot : Snapshot) (bracket : Bracket)
    (opening forward escaped skipQuoted : Bool) (offset : USize) : IO (Option (Option UInt64)) :=
  snapshot.unmatchedRaw bracket.tag opening forward escaped skipQuoted offset

/-- The quoted string of `quote` round the byte offset `offset` of the
snapshot, in its row, from its opening quote's start to its closing quote's
end, by the library's rule. `none` unless the offset is a position of the
text; `some none` when a quote is missing. -/
def Snapshot.quoted (snapshot : Snapshot) (quote : Quote) (offset : USize) :
    IO (Option (Option ByteRange)) :=
  snapshot.quotedRaw quote.tag offset

end Editor.Ffi
