import Editor.Ffi.Snapshot
import Editor.Ffi.Text
import Editor.Ffi.Words

/-!
# Bindings: search

The bindings of `crates/editor-ffi/src/search.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Plain data").
-/

namespace Editor.Ffi

open Words

/-- What a search of a snapshot answers (`Snapshot.search`). -/
inductive SearchAnswer where
  /-- The match, and whether the search wrapped round the text to find it. -/
  | found (range : ByteRange) (wrapped : Bool)
  /-- The text has no match. -/
  | notFound
  /-- The pattern is none the syntax takes, for `reason`. -/
  | invalid (reason : String)
  /-- The offset is not a position of the text. -/
  | badPosition
  deriving DecidableEq, Repr

/-- What the matches in a range of a snapshot answer (`Snapshot.matches`). -/
inductive MatchesAnswer where
  /-- The matches, in order. -/
  | ranges (all : Array ByteRange)
  /-- The pattern is none the syntax takes, for `reason`. -/
  | invalid (reason : String)
  /-- The range is not two positions of the text in order. -/
  | badRange
  deriving DecidableEq, Repr

/-- `Snapshot.search` as it crosses: the pattern, the direction and the
offset in, and words out. The status is 0 answered, with the words a
presence (1 found, 0 not), the match's two offsets and whether it wrapped;
1 for an offset that is not a position, with no words; and 2 for a pattern
the syntax refuses, with the words the bytes of the sentence that says
why, in UTF-8, and not words. -/
@[extern "editor_glue_snapshot_search"]
private opaque Snapshot.searchRaw (snapshot : @& Snapshot) (pattern : @& String) (forward : Bool)
    (offset : USize) : IO RawWords

/-- `Snapshot.matches` as it crosses: the pattern and the range in, and
words out. The status is 0 answered, with the words the count of matches
and then the two offsets of each; 1 for a range that is not two positions in
order; and 2 for a pattern the syntax refuses, as for `searchRaw`. -/
@[extern "editor_glue_snapshot_matches"]
private opaque Snapshot.matchesRaw (snapshot : @& Snapshot) (pattern : @& String)
    (start stop : USize) : IO RawWords

/-- The sentence a status of 2 carries in its bytes. Bytes that are not
UTF-8 mean the library is wrong, which is an `IO` error. -/
private def reasonOf (bytes : ByteArray) : IO String :=
  match String.fromUTF8? bytes with
  | some reason => return reason
  | none => throw (IO.userError "the library's reason for refusing a pattern is not UTF-8")

/-- The match of `pattern` a search of the snapshot's text from `offset`
answers, forward when `forward` and back otherwise: the rule is the
library's (`crates/editor-search`; `Editor/Text.lean`, "Search"). The call
keeps nothing in the library: the pattern is compiled for it. A status or
words the library cannot have answered are an `IO` error. -/
def Snapshot.search (snapshot : Snapshot) (pattern : String) (forward : Bool) (offset : USize) :
    IO SearchAnswer := do
  let raw ← snapshot.searchRaw pattern forward offset
  match raw.status with
  | 0 =>
    match wordsOf? raw.words with
    | some #[0, 0, 0, 0] =>
      return .notFound
    | some #[1, start, stop, wrapped] =>
      return .found ⟨start, stop⟩ (wrapped != 0)
    | _ =>
      throw (IO.userError "the library's words do not spell a search's answer")
  | 1 =>
    return .badPosition
  | 2 =>
    return .invalid (← reasonOf raw.words)
  | _ =>
    throw (IO.userError "the library answered a search with a status it has none of")

/-- The matches of `pattern` in the snapshot's text that start from `start`
up to `stop`, in order, as `search` answers one. -/
def Snapshot.matches (snapshot : Snapshot) (pattern : String) (start stop : USize) :
    IO MatchesAnswer := do
  let raw ← snapshot.matchesRaw pattern start stop
  match raw.status with
  | 0 =>
    let ranges? : Option (Array ByteRange) := do
      let words ← wordsOf? raw.words
      let count ← words[0]?
      guard (words.size == 1 + 2 * count.toNat)
      return (Array.range count.toNat).map fun index =>
          ⟨words[1 + 2 * index]!, words[2 + 2 * index]!⟩
    match ranges? with
    | some all =>
      return .ranges all
    | none =>
      throw (IO.userError "the library's words do not spell the matches in a range")
  | 1 =>
    return .badRange
  | 2 =>
    return .invalid (← reasonOf raw.words)
  | _ =>
    throw (IO.userError "the library answered the matches in a range with a status it has none of")

end Editor.Ffi
