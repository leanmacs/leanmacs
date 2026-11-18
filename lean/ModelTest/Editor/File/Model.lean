import Editor.File
import Editor.File.Model
import Editor.Text
import Editor.Text.Model
import ModelTest.Check

/-!
# Model tests: `Editor/File/Model.lean`

The model tests of `Editor/File/Model.lean`: `fileModelChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The escape of `byte`: the character the text model keeps a byte that is
not valid UTF-8 as. It is four bytes of text. -/
def escapeOf (byte : Nat) : Char :=
  Char.ofNat (0x10DC00 + byte)

/-- The escapes of `bytes`, in order. -/
def escapesOf (bytes : List Nat) : String :=
  bytes.foldl (fun text byte => text.push (escapeOf byte)) ""

/-- Byte strings and the text the library keeps each as, written out by
hand: what `FileModel.decode` must make of the bytes, and what
`FileModel.encode` must make the bytes of again. -/
def decodings : List (String × ByteArray × String) :=
  [("Latin-1", ⟨#[0x63, 0x61, 0x66, 0xE9]⟩, "caf".push (escapeOf 0xE9)),
    ("bytes that are never valid", ⟨#[0x61, 0xFF, 0x62, 0xFE]⟩,
      (("a".push (escapeOf 0xFF)).push 'b').push (escapeOf 0xFE)),
    ("a sequence cut short at the end", ⟨#[0x61, 0xE2, 0x82]⟩, "a" ++ escapesOf [0xE2, 0x82]),
    ("a sequence cut short in the middle", ⟨#[0xF0, 0x9F, 0x98, 0x78]⟩,
      (escapesOf [0xF0, 0x9F, 0x98]).push 'x'),
    ("two overlong forms", ⟨#[0xC0, 0xAF, 0xE0, 0x80, 0xAF]⟩,
      escapesOf [0xC0, 0xAF, 0xE0, 0x80, 0xAF]),
    ("an encoded surrogate", ⟨#[0xED, 0xA0, 0x80]⟩, escapesOf [0xED, 0xA0, 0x80]),
    ("a continuation byte alone", ⟨#[0x61, 0x80, 0x62]⟩, ("a".push (escapeOf 0x80)).push 'b'),
    ("the lowest reserved code point, validly encoded", ⟨#[0xF4, 0x8D, 0xB2, 0x80]⟩,
      escapesOf [0xF4, 0x8D, 0xB2, 0x80]),
    ("the highest reserved code point, validly encoded", ⟨#[0xF4, 0x8D, 0xB3, 0xBF]⟩,
      escapesOf [0xF4, 0x8D, 0xB3, 0xBF]),
    ("the code points on either side of the reserved range",
      ⟨#[0xF4, 0x8D, 0xB1, 0xBF, 0xF4, 0x8D, 0xB4, 0x80]⟩,
      ("".push (Char.ofNat 0x10DC7F)).push (Char.ofNat 0x10DD00)),
    ("a code point above the maximum", ⟨#[0xF4, 0x90, 0x80, 0x80]⟩,
      escapesOf [0xF4, 0x90, 0x80, 0x80]),
    ("a lead byte F5", ⟨#[0xF5, 0x80, 0x80, 0x80]⟩, escapesOf [0xF5, 0x80, 0x80, 0x80]),
    ("two- and four-byte characters with a carriage return and a line feed",
      ⟨#[0xC3, 0xA9, 0xF0, 0x9F, 0x98, 0x80, 0x0D, 0x0A]⟩, "é😀\r\n")]

/-- Whether `reply` is the refusal `error`. -/
def refusedAs {α : Type} (reply : Except FileError α) (error : FileError) : Bool :=
  match reply with
  | .error refusal => refusal == error
  | .ok _ => false

/-- The directory the model's files are in, in the checks below. -/
def modelRoot : System.FilePath :=
  "/model"

/-- A file's bytes: "h", a carriage return and a line feed, "😀", two bytes
that are not UTF-8 and a line feed alone. Ten bytes. -/
def mixedBytes : ByteArray :=
  ⟨#[0x68, 0x0D, 0x0A, 0xF0, 0x9F, 0x98, 0x80, 0xE9, 0xFF, 0x0A]⟩

/-- The text `mixedBytes` loads as, written out by hand. Sixteen bytes. -/
def mixedText : String :=
  ("h\r\n😀" ++ escapesOf [0xE9, 0xFF]).push '\n'

/-- A file of `size` bytes, each "a" but for a NUL byte at `nul`. -/
def withNul (size nul : Nat) : ByteArray :=
  ⟨(Array.replicate size (0x61 : UInt8)).setIfInBounds nul 0⟩

/-- A model with the directory `modelRoot` and, in it, `mixed.txt` holding
`mixedBytes`. The editor has published two snapshots, the second released;
the first holds a text that the job's first load will not. -/
def modelWithFile : FileModel :=
  let model :=
    (({} : FileModel).withDirectory modelRoot).withFile (modelRoot / "mixed.txt") mixedBytes
  { model with
    snapshots := #[some { contents := "pub é".push (escapeOf 0xFF), revision := 4 }, none] }

/-- The checks of the pure model of the files a job reaches
(`Editor/File/Model.lean`) and of the file data (`Editor/File.lean`). They
touch no file. -/
def fileModelChecks : List Check :=
  [{  name :=
        "the file model's stamp of a file is the stamp it was written with, and a write changes it; of nothing it is none"
      run :=
        let (before, model) := modelWithFile.handle (.stamp (modelRoot / "mixed.txt"))
        let (written, _) := model.written (modelRoot / "mixed.txt") mixedBytes
        let (after, _) :=
          (model.withFile (modelRoot / "mixed.txt") mixedBytes).handle
            (.stamp (modelRoot / "mixed.txt"))
        let (nothing, _) := modelWithFile.handle (.stamp (modelRoot / "missing.txt"))
        let stampOf : Except FileError (Option File.Stamp) → Option (Option File.Stamp)
          | .ok stamp => some stamp
          | .error _ => none
        pure
          (stampOf before == some ((modelWithFile.file? (modelRoot / "mixed.txt")).map (·.stamp)) &&
            stampOf after == some (some written) &&
            stampOf before != stampOf after &&
            stampOf nothing == some none) },
    {
      name :=
        "the store's escape rule decodes bytes to the text the library keeps them as, and encodes that text to the bytes again, and the file model uses it: thirteen byte strings, each against a text written out by hand",
      run :=
        pure
          (decodings.all fun (_, bytes, text) =>
            File.decodeBytes bytes == text && File.encodeText text == bytes &&
              FileModel.decode bytes == text &&
              FileModel.encode text == bytes) },
    { name :=
        "the file model's load answers a snapshot under the next id, holding the file's text, with the file's length in bytes as the stamp's size and its line endings"
      run := do
        let (first, model) := modelWithFile.load (modelRoot / "mixed.txt") 10
        let (second, after) := model.load (modelRoot / "mixed.txt") 1000
        let .ok first := first | return false
        let .ok second := second | return false
        return first.snapshot == ⟨0⟩ && second.snapshot == ⟨1⟩ && first.stamp.size == 10 &&
            first.endings == ⟨1, 1⟩ &&
            second.stamp == first.stamp &&
            after.held ==
              #[some { contents := mixedText, revision := 0 },
                some { contents := mixedText, revision := 0 }] &&
            after.files == modelWithFile.files &&
            after.snapshots == modelWithFile.snapshots },
    { name :=
        "the file model counts line endings on the bytes: a line feed alone, one after a carriage return, both, and a carriage return alone as neither"
      run :=
        pure
          (FileModel.lineEndings "a\nb\n".toUTF8 == ⟨2, 0⟩ &&
            FileModel.lineEndings "a\r\nb\r\n".toUTF8 == ⟨0, 2⟩ &&
            FileModel.lineEndings "\na\r\nb\nc\rd\r".toUTF8 == ⟨2, 1⟩ &&
            FileModel.lineEndings "abc".toUTF8 == ⟨0, 0⟩ &&
            FileModel.lineEndings ByteArray.empty == ⟨0, 0⟩) },
    { name :=
        "the file model refuses a load in the library's order, and a refused load changes nothing: a path that is not absolute, nothing there, a directory, a file over the limit, and a NUL byte among the first 8,000 bytes"
      run := do
        let model :=
          ((modelWithFile.withFile (modelRoot / "early") (withNul 8001 7999)).withFile
                (modelRoot / "late") (withNul 8001 8000)).withFile
            (modelRoot / "both") (withNul 20 3)
        let refusals :=
          [(model.load "missing.txt" 1000, FileError.relativePath),
            (model.load (modelRoot / "missing.txt") 1000, .notFound),
            (model.load (modelRoot / "none" / "mixed.txt") 1000, .notFound),
            (model.load modelRoot 1000, .notAFile),
            (model.load (modelRoot / "mixed.txt") 9, .tooLarge 10 9),
            (model.load (modelRoot / "early") 9000, .binary 7999),
            -- Over the limit and binary: the limit is looked at first.
            (model.load (modelRoot / "both") 19, .tooLarge 20 19),
            (model.load (modelRoot / "both") 20, .binary 3)]
        let (late, _) := model.load (modelRoot / "late") 9000
        return refusals.all
              (fun ((reply, after), refusal) => refusedAs reply refusal && after == model) &&
            late.toOption.isSome },
    { name :=
        "the file model refuses a save in the library's order, and a refused save changes nothing: a source that names nothing, a path that is not absolute, a directory, a file that is not what is expected, and a directory that is not there"
      run := do
        let (loaded, model) := modelWithFile.load (modelRoot / "mixed.txt") 1000
        let .ok loaded := loaded | return false
        let held := File.Source.held loaded.snapshot
        let stale : File.Stamp := { loaded.stamp with seconds := loaded.stamp.seconds + 1 }
        let refusals :=
          [(model.save (.held ⟨1⟩) "relative.txt" .whatever, FileError.noSuchSnapshot),
            (model.save (.snapshot ⟨1⟩) "relative.txt" .whatever, .noSuchSnapshot),
            (model.save (.snapshot ⟨2⟩) (modelRoot / "new.txt") .whatever, .noSuchSnapshot),
            (model.save held "relative.txt" .whatever, .relativePath),
            (model.save held modelRoot .whatever, .notAFile),
            (model.save held (modelRoot / "mixed.txt") .absent, .changed (some loaded.stamp)),
            (model.save held (modelRoot / "mixed.txt") (.unchanged stale),
              .changed (some loaded.stamp)),
            (model.save held (modelRoot / "new.txt") (.unchanged loaded.stamp), .changed none),
            -- The expectation is looked at before the directory.
            (model.save held (modelRoot / "none" / "new.txt") (.unchanged loaded.stamp),
              .changed none),
            (model.save held (modelRoot / "none" / "new.txt") .absent, .notFound),
            (model.save held (modelRoot / "none" / "new.txt") .whatever, .notFound)]
        return refusals.all fun ((reply, after), refusal) =>
            refusedAs reply refusal && after == model },
    { name :=
        "the file model's save writes the file and answers its stamp, which the next save accepts and which every write changes: over the file that is expected, where no file is expected, and over whatever is there"
      run := do
        let (loaded, model) := modelWithFile.load (modelRoot / "mixed.txt") 1000
        let .ok loaded := loaded | return false
        let held := File.Source.held loaded.snapshot
        let (over, model) := model.save held (modelRoot / "mixed.txt") (.unchanged loaded.stamp)
        let .ok over := over | return false
        let (again, model) := model.save held (modelRoot / "mixed.txt") (.unchanged over)
        let .ok again := again | return false
        let (stale, model) := model.save held (modelRoot / "mixed.txt") (.unchanged over)
        let (fresh, model) := model.save held (modelRoot / "new.txt") .absent
        let .ok fresh := fresh | return false
        let (whatever, model) := model.save held (modelRoot / "new.txt") .whatever
        let .ok whatever := whatever | return false
        return over != loaded.stamp && again != over && refusedAs stale (.changed (some again)) &&
            whatever != fresh &&
            [over, again, fresh, whatever].all (·.size == 10) &&
            model.contents ==
              #[(modelRoot / "mixed.txt", mixedBytes), (modelRoot / "new.txt", mixedBytes)] },
    { name :=
        "a save from what a load made and a save from what the editor published each write the bytes of that snapshot, though the two ids have one number, and neither changes what was published; a released snapshot of the job's is no source"
      run := do
        let (loaded, model) := modelWithFile.load (modelRoot / "mixed.txt") 1000
        let .ok loaded := loaded | return false
        let (held, model) := model.save (.held loaded.snapshot) (modelRoot / "held.txt") .absent
        let (published, model) := model.save (.snapshot ⟨0⟩) (modelRoot / "published.txt") .absent
        let (gone, after) :=
          (model.released loaded.snapshot).save (.held loaded.snapshot) (modelRoot / "gone.txt")
            .absent
        return loaded.snapshot.number == 0 && held.toOption.isSome && published.toOption.isSome &&
            (model.file? (modelRoot / "held.txt")).map (·.bytes) == some mixedBytes &&
            (model.file? (modelRoot / "published.txt")).map (·.bytes) ==
              some ⟨#[0x70, 0x75, 0x62, 0x20, 0xC3, 0xA9, 0xFF]⟩ &&
            model.snapshots == modelWithFile.snapshots &&
            refusedAs gone .noSuchSnapshot &&
            (after.file? (modelRoot / "gone.txt")).isNone &&
            ((after.load (modelRoot / "mixed.txt") 1000).1.toOption.map (·.snapshot)) == some ⟨1⟩ },
    { name :=
        "the dominant line ending is CRLF when there are more of those, LF otherwise when there is any line break, and none for a file with no line break"
      run :=
        pure
          ((File.LineEndings.mk 3 0).dominant == some .lf &&
            (File.LineEndings.mk 0 2).dominant == some .crlf &&
            (File.LineEndings.mk 2 3).dominant == some .crlf &&
            (File.LineEndings.mk 3 2).dominant == some .lf &&
            (File.LineEndings.mk 2 2).dominant == some .lf &&
            (File.LineEndings.mk 0 0).dominant == none) },
    { name :=
        "the text of a line ending is a line feed for LF, and a carriage return and a line feed for CRLF"
      run := pure (File.LineEnding.lf.text == "\n" && File.LineEnding.crlf.text == "\r\n") },
    { name :=
        "each file error describes its own thing: no two say the same, a binary file's says its offset, a file too large its size and its limit, a changed file whether one is there, and a failure its detail"
      run := do
        let errors : List FileError :=
          [.relativePath, .notFound, .notAFile, .denied, .binary 7999, .tooLarge 4321 1234,
            .changed none, .changed (some { seconds := 5, nanoseconds := 6, size := 8765 }),
            .noSuchSnapshot, .noTemporaryName, .failed "the disk is on fire"]
        let said := errors.map FileError.describe
        let says (error : FileError) (part : String) : Bool :=
          (error.describe.splitOn part).length > 1
        return said.eraseDups.length == errors.length && said.all (· != "") &&
            says (.binary 7999) "7999" &&
            says (.tooLarge 4321 1234) "4321" &&
            says (.tooLarge 4321 1234) "1234" &&
            says (.changed (some { seconds := 5, nanoseconds := 6, size := 8765 })) "8765" &&
            says (.failed "the disk is on fire") "the disk is on fire" &&
            says .relativePath "absolute" &&
            says .notFound "nothing" &&
            says .notAFile "not a file" &&
            says .noSuchSnapshot "snapshot" }]

end ModelTest
