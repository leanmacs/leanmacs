import Editor.Test.Models
import Editor.Text
import Editor.Text.Word
import ModelTest.Check

/-!
# Model tests: `Editor/Text/Word.lean`

The model tests of `Editor/Text/Word.lean`: `wordChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The cells of the line of `head` in a text holding `content`, on the text
model; `none` if the model refused. -/
def wordCellsOf (content : String) (head : Nat) : Option (Array (Nat × String)) :=
  onTextModel do
    let text ← createText content
    Text.Word.cells text head

/-- The word under the cursor at `head` in the line `content`, the line
alone in its text (`Text.Word.underCursor` over `Text.Word.cells`). -/
def wordUnder (content : String) (head : Nat) : Option (Option (Nat × String)) :=
  (wordCellsOf content head).map (Text.Word.underCursor · head)

/-- The checks of the word under the cursor (`Editor/Text/Word.lean`). -/
def wordChecks : List Check :=
  [{  name :=
        "a line's cells are its characters up to where its content ends, each with the byte offset it starts at, and no line break, LF or CRLF; a head at any cell of the line names that line"
      run :=
        pure <|
          wordCellsOf "ab\néx y\nz" 5 == some #[(3, "é"), (5, "x"), (6, " "), (7, "y")] &&
            wordCellsOf "ab\néx y\nz" 3 == wordCellsOf "ab\néx y\nz" 7 &&
            wordCellsOf "ab\r\ncd" 0 == some #[(0, "a"), (1, "b")] &&
            wordCellsOf "" 0 == some #[] },
    { name :=
        "a blank cell is a space or a tab, and a word cell holds word characters only: letters, digits, _ and any character from U+0080"
      run :=
        pure <|
          Text.Word.isBlank " " && Text.Word.isBlank "\t" && !Text.Word.isBlank "a" &&
            !Text.Word.isBlank "" &&
            Text.Word.isWord "a" &&
            Text.Word.isWord "_" &&
            Text.Word.isWord "9" &&
            Text.Word.isWord "é" &&
            !Text.Word.isWord "." &&
            !Text.Word.isWord " " &&
            !Text.Word.isWord "" },
    { name :=
        "the word under the cursor is the keyword the cursor is on, from its first cell; else the first keyword after the cursor in the line; else the run of punctuation under or after it; else none"
      run :=
        pure <|
          wordUnder "foo bar" 5 == some (some (4, "bar")) &&
            wordUnder "foo bar" 3 == some (some (4, "bar")) &&
            wordUnder "  x_1 y" 0 == some (some (2, "x_1")) &&
            wordUnder "a ->> " 1 == some (some (2, "->>")) &&
            wordUnder "a ->> " 3 == some (some (2, "->>")) &&
            wordUnder "ab   " 2 == some none &&
            wordUnder "" 0 == some none },
    { name :=
        "the whole-word pattern of a word writes each of \\ / . * $ ^ ~ [ with a backslash before it, with \\< before a word that starts with a word character and \\> after one that ends with one"
      run :=
        pure <|
          Text.Word.wholePattern "foo" == "\\<foo\\>" &&
            Text.Word.wholePattern "a.b" == "\\<a\\.b\\>" &&
            Text.Word.wholePattern "->>" == "->>" &&
            Text.Word.wholePattern "$x" == "\\$x\\>" &&
            Text.Word.wholePattern "\\/*^~[" == "\\\\\\/\\*\\^\\~\\[" },
    { name := "with no word under the cursor the text is Vim's E348"
      run := pure (Text.Word.noneUnderCursor == "E348: No string under cursor") }]

end ModelTest
