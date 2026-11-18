import Editor.Ffi.Words

/-!
# Bindings: fuzzy ranking

The bindings of `crates/editor-ffi/src/fuzzy.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Plain data").
-/

namespace Editor.Ffi

open Words

/-- The ranking `words` spell for `candidates` candidates: the count of
indices, then each. `none` unless the count is the count of indices there
and each is below `candidates`. -/
private def rankingOf? (candidates : Nat) (words : Array UInt64) : Option (Array Nat) := do
  let count := (← words[0]?).toNat
  guard (words.size == 1 + count)
  let indices := (words.extract 1 words.size).map (·.toNat)
  guard (indices.all (· < candidates))
  return indices

/-- `fuzzyRank` as it crosses: the pattern, the candidates as words and one
string, and the ranking as words with the status 0, or no words and the
status 1 when the library cannot read the candidates. -/
@[extern "editor_glue_fuzzy_rank"]
private opaque fuzzyRankRaw (pattern : @& String) (words : @& ByteArray) (strings : @& String) :
    IO RawWords

/-- The indices of the `candidates` that `pattern` matches, best first, each
once: the library's fuzzy matcher (`crates/editor-fuzzy`, over
`nucleo-matcher`). A candidate matches when the pattern's Unicode scalar
values all occur in it, in the pattern's order, adjacent or apart; a
candidate that is the pattern comes first, and the rest are in the order of
the matcher's scores.

The call keeps nothing in the library: the candidates are borrowed for it,
and each call copies their bytes once, into the one string that crosses.

It refuses nothing. A status other than 0, and an answer that is not a count
and that many indices of the candidates, mean the encoder here is wrong, so
each is an `IO` error. -/
def fuzzyRank (pattern : String) (candidates : Array String) : IO (Array Nat) := do
  let strings := candidates.foldl (· ++ ·) ""
  let raw ← fuzzyRankRaw pattern (lengthWords candidates) strings
  if raw.status != 0 then
    throw (IO.userError "the library could not read the candidates of a fuzzy ranking")
  match (wordsOf? raw.words).bind (rankingOf? candidates.size) with
  | some ranking =>
    return ranking
  | none =>
    throw (IO.userError "the library's words do not spell a fuzzy ranking")

end Editor.Ffi
