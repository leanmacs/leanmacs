/-!
# Bindings: the word codec

Lean's side of `crates/editor-ffi/src/words.rs`; it binds no extern. The
convention it follows is in the module docs of `Editor/Ffi.lean` ("Plain
data").

The encoders and decoders of words that more than one family uses, under
`Editor.Ffi.Words` so they are not among the names `Editor.Ffi` gives a
caller; only the binding modules open it. The selection codec
(`Words.pushShaped`, `Words.selectionAt?`) is in `Editor/Ffi/Transaction.lean`,
beside `Selection`.
-/

namespace Editor.Ffi.Words

/-- `words` with `word` added: its eight bytes, least significant first. -/
def pushWord (words : ByteArray) (word : UInt64) : ByteArray :=
  (List.range 8).foldl (fun words byte => words.push (word >>> (8 * byte).toUInt64).toUInt8) words

/-- The words `bytes` holds, eight bytes each, least significant first.
`none` unless its size is whole words. -/
def wordsOf? (bytes : ByteArray) : Option (Array UInt64) :=
  if bytes.size % 8 != 0 then none
  else
    some <|
      (Array.range (bytes.size / 8)).map fun index =>
        (List.range 8).foldr
          (fun byte word => (word <<< 8) ||| (bytes.get! (8 * index + byte)).toUInt64) 0

/-- An answer in words, as the glue builds it in one call: the object field
first and the `UInt64` field after it, so the order here is the layout the
glue writes. -/
structure RawWords where
  /-- The words, copied from the library's buffer. -/
  words : ByteArray
  /-- 0 answered, and otherwise the refusal of the call that filled it: for
  the log's, 1 the revision is unknown and 2 it is forgotten; for a marker's
  and for extents, the status `markRefusal` reads; for an inverse's, 1 the
  revision is unknown, 2 no inverse is kept and 3 the text is not in the
  state. -/
  status : UInt64

/-- A list of strings as words: their count, then the byte length of each.
The strings themselves cross beside the words, as one string of all of them
end to end. -/
def lengthWords (strings : Array String) : ByteArray :=
  strings.foldl (fun words string => pushWord words string.utf8ByteSize.toUInt64)
    (pushWord ByteArray.empty strings.size.toUInt64)

end Editor.Ffi.Words
