import Editor.Command
import Editor.Command.Model
import Editor.Highlight
import Editor.Indent
import Editor.Language.IndentUnit
import Editor.Mode
import Editor.Program
import Editor.Scene
import Editor.SyntaxTree
import Editor.Test.Models
import Editor.Text
import ModelTest.Check
import ModelTest.Support.Modes

/-!
# Model tests: `Editor/Indent.lean`

The model tests of `Editor/Indent.lean`: `indentRuleChecks`,
`indentOpeningChecks`, `indentEditChecks` and `indentLevelChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A node of the indents query, for the indent rule's checks: its capture's
name, where it starts, and its first and last rows. -/
def indentNode (name : String) (start firstRow lastRow : Nat) : Indent.Captured :=
  { name, start, firstRow, lastRow }

/-- The rows from 0 through `last`, each with its first non-blank at the
offset `firstNonBlanks` gives it, or 1000 past it. -/
def indentLines (firstNonBlanks : List Nat) : Array Indent.Line :=
  (firstNonBlanks.zipIdx.map fun (offset, row) => { row, firstNonBlank := offset }).toArray

/-- The checks of the indent rule (`Indent.rule`, `Editor/Indent.lean`),
pure, over hand-built rows. -/
def indentRuleChecks : List Check :=
  [{  name := "begins on one row count once, and each begin counts on the rows after its first"
      run :=
        pure
          (Indent.rule
              #[indentNode "indent.begin" 0 0 3, indentNode "indent.begin" 4 0 3,
                indentNode "indent.begin" 10 1 2]
              (indentLines [0, 10, 20, 30]) ==
            #[some 0, some 1, some 2, some 1]) },
    { name := "a branch takes a level away only where it starts a row's first non-blank"
      run :=
        pure
          (Indent.rule
              #[indentNode "indent.begin" 0 0 2, indentNode "indent.branch" 20 2 2,
                indentNode "indent.branch" 15 1 1]
              (indentLines [0, 12, 20]) ==
            #[some 0, some 1, some 0]) },
    { name := "the level is never below 0"
      run :=
        pure (Indent.rule #[indentNode "indent.branch" 0 0 0] (indentLines [0]) == #[some 0]) },
    { name :=
        "the rows of an ignored node after its first keep their indent, and so its first does not"
      run :=
        pure
          (Indent.rule #[indentNode "indent.begin" 0 0 3, indentNode "indent.ignore" 10 1 2]
              (indentLines [0, 10, 20, 30]) ==
            #[some 0, some 1, none, some 1]) },
    { name := "a node whose last byte is on the row before reaches no further"
      run :=
        pure
          (Indent.rule #[indentNode "indent.begin" 0 0 1] (indentLines [0, 5, 9]) ==
            #[some 0, some 1, some 0]) },
    { name := "a blank row gets the level a line typed there would have"
      run :=
        pure
          (Indent.rule #[indentNode "indent.begin" 0 0 2] (indentLines [0, 2, 3]) ==
            #[some 0, some 1, some 1]) },
    { name := "names the rule does not read are ignored"
      run :=
        pure
          (Indent.rule
              #[indentNode "indent.align" 0 0 2, indentNode "function.outer" 0 0 2,
                indentNode "indent.begin" 0 0 2]
              (indentLines [0, 2, 3]) ==
            #[some 0, some 1, some 1]) },
    { name :=
        "an opening bracket the tree did not close counts its row for every row after it, not for its own, and with a begin on the same row it counts once"
      run :=
        -- Each is held by an error from the text's start through its last row.
        let error := indentNode "indent.incomplete" 0 0 2
        pure
          (Indent.rule #[indentNode "indent.open" 10 0 0, error] (indentLines [0, 12, 20]) ==
              #[some 0, some 1, some 1] &&
            Indent.rule #[indentNode "indent.open" 10 1 1, error] (indentLines [0, 12, 20]) ==
              #[some 0, some 0, some 1] &&
            Indent.rule #[indentNode "indent.open" 10 0 0, indentNode "indent.begin" 0 0 1, error]
                (indentLines [0, 12, 20]) ==
              #[some 0, some 1, some 1] &&
            Indent.rule #[indentNode "indent.open" 10 0 0, indentNode "indent.open" 30 1 1, error]
                (indentLines [0, 12, 40]) ==
              #[some 0, some 1, some 2]) },
    { name :=
        "an opening bracket counts only on the rows an incomplete node that starts at or before it reaches: a call's `(` whose partner is missing mid-function leaves the rows after its node, the function's `}` and the next function, at their levels"
      run :=
        -- fn a() {        row 0
        --     foo(1;      row 1: `(` at 16, where `arguments` starts
        -- }               row 2
        --                 row 3
        -- fn b() {        row 4
        --     x           row 5
        -- }               row 6
        let captured :=
          #[indentNode "indent.begin" 7 0 2, indentNode "indent.branch" 21 2 2,
            indentNode "indent.open" 16 1 1, indentNode "indent.incomplete" 16 1 1,
            indentNode "indent.begin" 31 4 6, indentNode "indent.branch" 39 6 6]
        pure
          (Indent.rule captured (indentLines [0, 13, 21, 23, 24, 37, 39]) ==
              #[some 0, some 1, some 0, some 0, some 0, some 1, some 0] &&
            -- An incomplete node that ends before the bracket's row, or
            -- starts after the bracket, does not hold it.
            Indent.rule #[indentNode "indent.open" 10 1 1, indentNode "indent.incomplete" 0 0 0]
                (indentLines [0, 5, 20]) ==
              #[some 0, some 0, some 0] &&
            Indent.rule #[indentNode "indent.open" 10 1 1, indentNode "indent.incomplete" 12 1 3]
                (indentLines [0, 5, 20, 30]) ==
              #[some 0, some 0, some 0, some 0] &&
            -- An error that holds the bracket counts it on the rows it
            -- reaches only.
            Indent.rule #[indentNode "indent.open" 10 0 0, indentNode "indent.incomplete" 0 0 2]
                (indentLines [0, 12, 20, 30]) ==
              #[some 0, some 1, some 1, some 0]) },
    { name := "an incomplete node alone adds no level: the rows it holds keep the level they had"
      run :=
        pure
          (Indent.rule #[indentNode "indent.incomplete" 0 0 2] (indentLines [0, 2, 3]) ==
            #[some 0, some 0, some 0]) }]

/-- A node of the indents query, for the opening rule's checks: its
capture's name and the offsets it starts and stops at. -/
def openingNode (name : String) (start stop : Nat) : Indent.Node :=
  { name, start, stop }

/-- The checks of the opening rule (`Indent.openingCounts`,
`Indent.levelOf`) and of the widening (`Indent.widenedStart`), pure, over
hand-built nodes. -/
def indentOpeningChecks : List Check :=
  [{  name :=
        "a begin node that holds the position counts, and one that ends at it or starts at it does not"
      run :=
        pure
          (Indent.openingCounts #[openingNode "indent.begin" 3 20] { offset := 10 } ==
              some (#[3], false) &&
            Indent.openingCounts #[openingNode "indent.begin" 3 10] { offset := 10 } ==
              some (#[], false) &&
            Indent.openingCounts #[openingNode "indent.begin" 10 20] { offset := 10 } ==
              some (#[], false)) },
    { name := "an opening bracket the tree did not close counts when it starts before the position"
      run :=
        pure
          (Indent.openingCounts #[openingNode "indent.open" 3 4] { offset := 10 } ==
              some (#[3], false) &&
            Indent.openingCounts #[openingNode "indent.open" 10 11] { offset := 10 } ==
              some (#[], false) &&
            Indent.openingCounts #[openingNode "indent.open" 12 13] { offset := 10 } ==
              some (#[], false)) },
    { name :=
        "a branch at the first non-blank that moves to the new row says so, and none for an empty new row"
      run :=
        let nodes := #[openingNode "indent.begin" 0 20, openingNode "indent.branch" 12 13]
        pure
          (Indent.openingCounts nodes { offset := 10, firstNonBlank := some 12 } ==
              some (#[0], true) &&
            Indent.openingCounts nodes { offset := 10, firstNonBlank := some 11 } ==
              some (#[0], false) &&
            Indent.openingCounts nodes { offset := 10 } == some (#[0], false)) },
    { name := "a position inside an ignored node adds nothing, and one at its ends does"
      run :=
        let ignored := openingNode "indent.ignore" 5 15
        pure
          (Indent.openingCounts #[openingNode "indent.begin" 0 20, ignored] { offset := 10 } ==
              none &&
            Indent.openingCounts #[ignored] { offset := 5 } == some (#[], false) &&
            Indent.openingCounts #[ignored] { offset := 15 } == some (#[], false)) },
    { name := "names the opening rule does not read are ignored"
      run :=
        pure
          (Indent.openingCounts
              #[openingNode "indent.incomplete" 0 20, openingNode "function.outer" 0 20]
              { offset := 10 } ==
            some (#[], false)) },
    { name :=
        "the level is the number of distinct rows counted, less one for a branch, and never below 0"
      run :=
        pure
          (Indent.levelOf #[0, 0, 2] false == 2 && Indent.levelOf #[0, 0, 2] true == 1 &&
            Indent.levelOf #[] true == 0 &&
            Indent.levelOf #[] false == 0) },
    { name :=
        "the widened start is the earliest start of an incomplete node, or the asked start when that is earlier"
      run :=
        pure
          (Indent.widenedStart
                #[openingNode "indent.incomplete" 4 30, openingNode "indent.incomplete" 2 30,
                  openingNode "indent.begin" 0 30]
                10 ==
              2 &&
            Indent.widenedStart #[openingNode "indent.incomplete" 12 30] 10 == 10 &&
            Indent.widenedStart #[] 10 == 10) }]

/-- A row of a text, as the re-indent reads it, starting at `start` with
the whitespace `leading` before what it holds, `content` bytes of it after
that, and the level `level`. -/
def reindentRow (start : Nat) (leading : String) (content : Nat) (level : Option Nat) :
    Indent.Row :=
  { start, firstNonBlank := start + leading.utf8ByteSize
    content := start + leading.utf8ByteSize + content, leading, level }

/-- The checks of the indent decisions as edits (`Indent.whitespace`,
`Indent.reindent`, `Indent.newLine`, `Indent.breakAt`), pure. -/
def indentEditChecks : List Check :=
  [{  name := "a level is that many units: spaces times the count, or tabs, and level 0 is nothing"
      run :=
        pure
          (Indent.whitespace (.spaces 4) 2 == "        " && Indent.whitespace .tab 2 == "\t\t" &&
            Indent.whitespace (.spaces 2) 0 == "" &&
            Indent.whitespace .tab 0 == "") },
    { name :=
        "the re-indent replaces each row's leading whitespace with its level, from its start to its first non-blank, and leaves a row already right"
      run :=
        pure
          (Indent.reindent (.spaces 2)
              #[reindentRow 0 "" 3 (some 0), reindentRow 4 "" 3 (some 1),
                reindentRow 8 "      " 3 (some 1), reindentRow 18 "\t" 1 (some 2)] ==
            #[(⟨4, 4⟩, "  "), (⟨8, 14⟩, "  "), (⟨18, 19⟩, "    ")]) },
    { name := "a blank row gets no whitespace, whatever its level"
      run :=
        pure
          (Indent.reindent (.spaces 4)
              #[reindentRow 0 "   " 0 (some 2), reindentRow 4 "" 0 (some 1)] ==
            #[(⟨0, 3⟩, "")]) },
    { name := "a row with no level keeps its whitespace, a blank one too"
      run :=
        pure
          (Indent.reindent (.spaces 4)
              #[reindentRow 0 "   " 4 none, reindentRow 8 "     " 0 none] ==
            #[]) },
    { name := "a tab unit indents with tabs"
      run :=
        pure
          (Indent.reindent .tab
              #[reindentRow 0 "    " 1 (some 1), reindentRow 6 "\t\t" 1 (some 2)] ==
            #[(⟨0, 4⟩, "\t")]) },
    { name :=
        "a new line gets its level as whitespace, nothing inside a string or comment, the row's own indent when the text is not parsed yet, and nothing when the text has no tree or no indents query"
      run :=
        pure
          (Indent.newLine (.spaces 4) (.ok (some 2)) "  " == some "        " &&
            Indent.newLine (.spaces 4) (.ok none) "  " == none &&
            Indent.newLine (.spaces 4) (.error .notParsed) "  " == some "  " &&
            Indent.newLine (.spaces 4) (.error .notAttached) "  " == none &&
            Indent.newLine (.spaces 4) (.error .noQuery) "  " == none) },
    { name :=
        "a line break with no indent is the line ending at the bar; with one it replaces the blanks either side of the bar with the line ending and the indent"
      run :=
        pure
          (Indent.breakAt "\n" none 10 2 3 == (⟨10, 10⟩, "\n") &&
            Indent.breakAt "\r\n" (some "  ") 10 2 3 == (⟨8, 13⟩, "\r\n  ") &&
            Indent.breakAt "\n" (some "") 10 0 0 == (⟨10, 10⟩, "\n")) }]

/-- The indent levels of rows `first` through `last` of a text of `text`, set
to a test mode with `syntaxTree` when given, on the editor's models: the
levels on the right, a refusal on the left; `none` when the command was
refused. -/
def indentLevelsOf (text : String) (syntaxTree : Option Mode.SyntaxTree) (first last : Nat) :
    Option (Sum SyntaxTreeError (Array (Option Nat))) :=
  let program : EditorM (Except SyntaxTreeError (Array (Option Nat))) := do
    let id ← createText text
    if let some syntaxTree := syntaxTree then
      Highlight.enter "test" id syntaxTree
    id.indentLevels first last
  match program.runModel editorModel with
  | (.ok (.ok levels), _) => some (.inr levels)
  | (.ok (.error refusal), _) => some (.inl refusal)
  | (.error _, _) => none

/-- An indents source of the model's JSON grammar whose array is a node the
parser could not complete and whose opening bracket one the tree did not
close: what the widening reads. -/
def widenedIndents : String :=
  "(array) @indent.incomplete\n\"[\" @indent.open"

/-- The opening level of a line opened at `offset` of a text of `text`, with
what follows it on its row moved to the new row when `rest`, set to a test
mode with `syntaxTree` when given, on the editor's models: the level on the
right, a refusal on the left; `none` when the command was refused. -/
def openingLevelOf (text : String) (syntaxTree : Option Mode.SyntaxTree) (offset : Nat)
    (rest : Bool) : Option (Sum SyntaxTreeError (Option Nat)) :=
  let program : EditorM (Except SyntaxTreeError (Option Nat)) := do
    let id ← createText text
    if let some syntaxTree := syntaxTree then
      Highlight.enter "test" id syntaxTree
    id.openingLevel offset rest
  match program.runModel editorModel with
  | (.ok (.ok level), _) => some (.inr level)
  | (.ok (.error refusal), _) => some (.inl refusal)
  | (.error _, _) => none

/-- The re-indent's edits of rows `first` through `last` of a text of
`text` in `unit`, set to a test mode with `syntaxTree` when given, on the
editor's models: the edits on the right, a refusal on the left; `none` when
the command was refused. -/
def reindentEditsOf (text : String) (syntaxTree : Option Mode.SyntaxTree) (first last : Nat)
    (unit : Language.IndentUnit) : Option (Sum SyntaxTreeError (Array (Extent × String))) :=
  let program : EditorM (Except SyntaxTreeError (Array (Extent × String))) := do
    let id ← createText text
    if let some syntaxTree := syntaxTree then
      Highlight.enter "test" id syntaxTree
    id.reindentEdits first last unit
  match program.runModel editorModel with
  | (.ok (.ok edits), _) => some (.inr edits)
  | (.ok (.error refusal), _) => some (.inl refusal)
  | (.error _, _) => none

/-- The checks of the indent primitive (`TextId.indentLevels`,
`Editor/Indent.lean`), on the editor's models through the syntax tree
model. -/
def indentLevelChecks : List Check :=
  let pretty := "{\n  \"a\": [\n    1,\n    {\n      \"b\": null\n    }\n  ],\n\n  \"c\": {}\n}\n"
  let spaces (line : String) : Nat := (line.toList.takeWhile (· == ' ')).length
  [{  name :=
        "a two-space pretty-printed JSON text, under a test mode's indents query, gets each row's leading spaces divided by two, a blank row the level of what holds it"
      run :=
        pure <|
          let lines := pretty.splitOn "\n"
          let expected :=
            (lines.take (lines.length - 1)).toArray.map fun line =>
              if line.isEmpty then some 1 else some (spaces line / 2)
          indentLevelsOf pretty (some { grammar := "json", indents := some jsonIndents }) 0 9 ==
            some (.inr expected) },
    { name := "rows past the text's last are left out, and a first row past the last answers none"
      run :=
        pure <|
          let mode := some { grammar := "json", indents := some jsonIndents }
          indentLevelsOf "[\n  1\n]" mode 1 7 == some (.inr #[some 1, some 0]) &&
            indentLevelsOf "[\n  1\n]" mode 3 4 == some (.inr #[]) },
    { name := "a text with no syntax tree is refused as not attached"
      run := pure (indentLevelsOf "[1]" none 0 0 == some (.inl .notAttached)) },
    { name := "a text whose grammar ships no indents query is refused as keeping none"
      run := pure (indentLevelsOf "[1]" (some { grammar := "json" }) 0 0 == some (.inl .noQuery)) },
    { name := "a mode with an empty indents source answers 0 for every row"
      run :=
        pure
          (indentLevelsOf pretty (some { grammar := "json", indents := some "" }) 0 3 ==
            some (.inr #[some 0, some 0, some 0, some 0])) },
    { name :=
        "a row inside a node captured incomplete is asked from that node's start, so an opening bracket it holds far above counts"
      run :=
        pure <|
          let mode := some { grammar := "json", indents := some widenedIndents }
          indentLevelsOf "[\n1,\n2,\n3\n]" mode 3 3 == some (.inr #[some 1]) &&
            indentLevelsOf "[\n1,\n2,\n3\n]" mode 0 1 == some (.inr #[some 0, some 1]) },
    { name :=
        "the opening level is the level of a line opened at a position: one in after an opening bracket, at the body's level after an item, one out with a closing bracket moved to the new row, and none asked of a text with no tree or no indents query"
      run :=
        pure <|
          let mode := some { grammar := "json", indents := some jsonIndents }
          let text := "{\n  \"a\": [\n  ]\n}"
          let afterBracket := 10
          openingLevelOf text mode afterBracket true == some (.inr (some 2)) &&
            openingLevelOf text mode 9 true == some (.inr (some 1)) &&
            openingLevelOf text mode 11 true == some (.inr (some 1)) &&
            openingLevelOf text mode 11 false == some (.inr (some 2)) &&
            openingLevelOf text mode (text.utf8ByteSize) true == some (.inr (some 0)) &&
            openingLevelOf text none afterBracket true == some (.inl .notAttached) &&
            openingLevelOf text (some { grammar := "json" }) afterBracket true ==
              some (.inl .noQuery) },
    { name :=
        "the opening level is asked from the start of a node captured incomplete, so an opening bracket it holds far above counts"
      run :=
        pure
          (openingLevelOf "[\n1,\n2,\n3\n]"
              (some { grammar := "json", indents := some widenedIndents }) 7 false ==
            some (.inr (some 1))) },
    { name :=
        "the re-indent's edits of rows read from the text: each row's leading whitespace from its start to its first non-blank becomes its level in the unit, a row already right and a blank row already empty have none; refused as the primitive is"
      run :=
        pure <|
          let mode := some { grammar := "json", indents := some jsonIndents }
          reindentEditsOf "[\n1,\n      2\n\n   \n]" mode 0 5 (.spaces 2) ==
              some (.inr #[(⟨2, 2⟩, "  "), (⟨5, 11⟩, "  "), (⟨14, 17⟩, "")]) &&
            reindentEditsOf "[\n1\n]" mode 1 1 .tab == some (.inr #[(⟨2, 2⟩, "\t")]) &&
            reindentEditsOf "[1]" none 0 0 (.spaces 2) == some (.inl .notAttached) }]

end ModelTest
