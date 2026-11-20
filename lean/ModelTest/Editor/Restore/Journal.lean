import Editor.Restore.Journal
import Editor.Text.Model
import ModelTest.Check

/-!
# Model tests: `Editor/Restore/Journal.lean`

The model tests of `Editor/Restore/Journal.lean`: `journalFormatChecks`,
pure and over the text model. The root module `ModelTest` runs them; its
module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Restore

namespace JournalFormatTest

/-- A header of a buffer holding a file. -/
def header : Journal.Header :=
  { name := "a.txt", path := some "/r/a.txt", stamp := some { seconds := -3, nanoseconds := 7, size := 12 }
    lineEnding := .crlf, revision := 4 }

/-- Records whose inserted texts hold a byte that is not UTF-8 (its escape),
a NUL, a CRLF, characters of two, three and four bytes, and an empty insert
and an empty delete. -/
def records : Array (Array Journal.Edit) :=
  #[#[{ start := 0, stop := 0, inserted := s!"a{File.escape 0xFF}b" }],
    #[{ start := 1, stop := 3, inserted := "x\x00y\x00" }, { start := 5, stop := 5, inserted := "" }],
    #[{ start := 2, stop := 2, inserted := "line\r\nnext é 中 😀" }],
    #[{ start := 0, stop := 4, inserted := "" }]]

/-- The bytes of a log of `header` and `records`, as the appends wrote it. -/
def logBytes : ByteArray :=
  records.foldl (fun bytes edits => bytes ++ (Journal.Record.edits edits).bytes)
    (Journal.Record.header header).bytes

/-- What a load of `bytes` gives a reader: the store's text of them. -/
def loadedText (bytes : ByteArray) : String :=
  File.decodeBytes bytes

/-- The text `edit` makes of `original` on the text model, and what reading
the edits since revision 0 as a record and replaying them over `original`
anew makes: the two must be one. -/
def replayed (original : String) (edit : TextId → TextM Unit) : Option (String × String) :=
  let program : TextM (String × String) := do
    let text ← createText original
    edit text
    let patch ← text.changesSince 0
    let edits ← Journal.editsOf patch text.slice
    let line := (Journal.Record.edits edits).bytes
    let decoded := Journal.decode (loadedText line)
    let fresh ← createText original
    discard <| Journal.replay fresh decoded.records
    return (← text.read, ← fresh.read)
  (program.runModel {}).1.toOption

end JournalFormatTest

open JournalFormatTest in
/-- The checks of a journal's log (`Editor/Restore/Journal.lean`). -/
def journalFormatChecks : List Check :=
  [{  name :=
        "a log written as appends and loaded reads back its header and its records whole: a byte that is not UTF-8, a NUL, a CRLF, characters of every width, an empty insert and an empty delete"
      run :=
        pure <|
          let decoded := Journal.decode (loadedText logBytes)
          decoded.header == some header && decoded.records == records && decoded.torn == 0 &&
            decoded.stopped.isNone &&
            -- The log holds no NUL byte, so a load takes it as text.
            !logBytes.toList.contains 0 },
    { name := "a header with no file reads back with none"
      run :=
        pure <|
          let bare : Journal.Header := { name := "scratch" }
          (Journal.decode (loadedText (Journal.Record.header bare).bytes)).header == some bare },
    { name :=
        "a torn last line is dropped and its bytes said; the records before it are read"
      run :=
        pure <|
          let whole := (Journal.Record.edits #[{ start := 0, stop := 0, inserted := "tail" }]).bytes
          let torn := whole.extract 0 (whole.size - 5)
          let decoded := Journal.decode (loadedText (logBytes ++ torn))
          decoded.records == records && decoded.torn == torn.size && decoded.stopped.isNone },
    { name :=
        "a line of a kind this editor does not know stops the reading before it, with why; what came before is read"
      run :=
        pure <|
          let unknown := File.encodeText "{\"kind\":\"marks\",\"marks\":[]}\n"
          let after := (Journal.Record.edits #[{ start := 0, stop := 0, inserted := "z" }]).bytes
          let decoded := Journal.decode (loadedText (logBytes ++ unknown ++ after))
          decoded.records == records &&
            decoded.stopped == some "line 6 is of the kind marks, which this editor does not know" },
    { name :=
        "a line of a newer format stops the reading before it, with why"
      run :=
        pure <|
          let newer := File.encodeText "{\"format\":2,\"kind\":\"edits\",\"edits\":[]}\n"
          let decoded := Journal.decode (loadedText (logBytes ++ newer))
          decoded.records == records &&
            decoded.stopped == some "line 6 is of format 2, newer than this editor's 1" },
    { name := "a log whose first line is not a header has none, and its records are read"
      run :=
        pure <|
          let edits := (Journal.Record.edits #[{ start := 0, stop := 0, inserted := "q" }]).bytes
          let decoded := Journal.decode (loadedText edits)
          decoded.header.isNone && decoded.records.size == 1 && decoded.stopped.isNone },
    { name :=
        "edits read from a text's log as one record and replayed over the text they started from make the text they were read from: inserts, deletes, a replace and a NUL, over characters of every width"
      run :=
        pure <|
          let cases : List (String × (TextId → TextM Unit)) :=
            [("hello world\n",
                fun text => do
                  text.insert 5 ","
                  text.delete 0 1
                  text.insert 0 "J"
                  text.insert 12 "\x00end"),
              ("é 中 😀\r\nline\n",
                fun text => do
                  text.delete 0 2
                  text.insert 0 "e"
                  text.insert 2 "x"),
              ("", fun text => text.insert 0 "typed into nothing")]
          cases.all fun (original, edit) =>
            match replayed original edit with
            | some (edited, again) => edited == again && edited != original
            | none => false },
    { name := "a record the text refuses ends the replay there, and what came before stays"
      run :=
        pure <|
          let program : TextM (Nat × String) := do
            let text ← createText "abc"
            let played ←
              Journal.replay text
                #[#[{ start := 0, stop := 1, inserted := "X" }],
                  #[{ start := 2, stop := 9, inserted := "" }],
                  #[{ start := 0, stop := 0, inserted := "never" }]]
            return (played, ← text.read)
          (program.runModel {}).1.toOption == some (1, "Xbc") }]

end ModelTest
