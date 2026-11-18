import Editor.Ex.Line
import Editor.Invocation
import Editor.Program
import Editor.Text
import ModelTest.Check
import ModelTest.Support.Models

/-!
# Model tests: `Editor/Ex/Line.lean`

The model tests of `Editor/Ex/Line.lean`: `exLineChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of an ex line (`Editor/Ex/Line.lean`): what a line typed on
the ex command line parses to, and the invocation an ex binding makes of a
line's argument. -/
def exLineChecks : List Check :=
  let parsed (line : String) : Option (String × Option String) :=
    (Ex.parse line).map fun parsed => (parsed.name, parsed.argument)
  [{  name := "an ex line of one word is that name, with no argument"
      run := pure (parsed "w" == some ("w", none)) },
    { name := "an ex line of a word and more is the word as its name and the rest as its argument"
      run := pure (parsed "e notes.txt" == some ("e", some "notes.txt")) },
    { name :=
        "white space round an ex line and after its name is dropped, and the argument is kept whole, the spaces inside it included"
      run := pure (parsed "  e   /tmp/my notes.txt  " == some ("e", some "/tmp/my notes.txt")) },
    { name := "a tab separates an ex name from its argument as a space does"
      run := pure (parsed "e\tnotes.txt" == some ("e", some "notes.txt")) },
    { name := "an ex name may hold a hyphen, and its argument a digit"
      run := pure (parsed "greet-all 2" == some ("greet-all", some "2")) },
    { name :=
        "an ex name is everything up to the first white space: a mark after letters is part of the name, and so is a leading colon"
      run := pure (parsed "w!" == some ("w!", none) && parsed ":w" == some (":w", none)) },
    { name := "the empty line and a line of white space are no ex line"
      run := pure (parsed "" == none && parsed "  \t " == none) },
    { name :=
        "an ex binding that takes nothing gives its command with no arguments for a line with no argument, and nothing for a line with one"
      run :=
        let binding : Ex.Binding := { name := "w", command := "write" }
        pure
          (binding.invocation? none == some { command := "write" } &&
            binding.invocation? (some "notes.txt") == none) },
    { name :=
        "an ex binding that takes text gives its command with the line's argument as its first argument, a string, and its command with no arguments for a line with none"
      run :=
        let binding : Ex.Binding := { name := "e", command := "edit", takes := .text }
        pure
          (binding.invocation? (some "my notes.txt") ==
              some { command := "edit", arguments := [.str "my notes.txt"] } &&
            binding.invocation? none == some { command := "edit" }) },
    { name :=
        "an ex binding's own arguments come before the line's, with an argument and without; one that takes nothing still refuses an argument"
      run :=
        let forced : Ex.Binding :=
          { name := "e!", command := "edit", takes := .text, arguments := [.bool true] }
        let write : Ex.Binding := { name := "w!", command := "write", arguments := [.bool true] }
        pure
          (forced.invocation? (some "a b") ==
              some { command := "edit", arguments := [.bool true, .str "a b"] } &&
            forced.invocation? none == some { command := "edit", arguments := [.bool true] } &&
            write.invocation? none == some { command := "write", arguments := [.bool true] } &&
            write.invocation? (some "x") == none &&
            (Ex.parse "e! /tmp/a").map (·.name) == some "e!") },
    { name :=
        "criterion 1: an ex line whose first non-blank after its range is `!` is the bang form, named `!`, with the rest as its argument: `!echo hi` has no range, `%!sort` the range 1,$, `.,$!sort` the range .,$ and `3,5!sort` the range 3,5; `w!` is still the name `w!`, with no range and no bang"
      run :=
        let shell (range : Option Ex.Range) (argument : String) : Option Ex.Line :=
          some { name := "!", argument := some argument, range, bang := true }
        pure
          (Ex.parse "!echo hi" == shell none "echo hi" &&
            Ex.parse "%!sort" == shell (some { start := .line 1, stop := .last }) "sort" &&
            Ex.parse ".,$!sort" == shell (some { start := .current, stop := .last }) "sort" &&
            Ex.parse "3,5!sort" == shell (some { start := .line 3, stop := .line 5 }) "sort" &&
            Ex.parse "w!" == some { name := "w!" }) },
    { name :=
        "a range of one address is that line to itself, an address left out beside the comma is the cursor's line, spaces may stand between the range, the `!` and the command, `!` alone is the bang form with no argument, line 0 and a range that runs backwards still parse, and a range before a name is kept with the name"
      run :=
        pure
          (Ex.parse "3!sort" ==
              some
                { name := "!", argument := some "sort",
                  range := some { start := .line 3, stop := .line 3 }
                  bang := true } &&
            Ex.parse "  % !  sort -r " ==
              some
                { name := "!", argument := some "sort -r"
                  range := some { start := .line 1, stop := .last }, bang := true } &&
            Ex.parse "!" == some { name := "!", bang := true } &&
            Ex.parse " ! " == some { name := "!", bang := true } &&
            (Ex.parse "0!x").bind (·.range) == some { start := .line 0, stop := .line 0 } &&
            (Ex.parse "5,3!x").bind (·.range) == some { start := .line 5, stop := .line 3 } &&
            Ex.parse "3,5w" ==
              some { name := "w", range := some { start := .line 3, stop := .line 5 } } &&
            (Ex.parse ",5!x").bind (·.range) == some { start := .current, stop := .line 5 } &&
            (Ex.parse "3,!x").bind (·.range) == some { start := .line 3, stop := .current } &&
            Ex.parse "12,$ e a b" ==
              some
                { name := "e", argument := some "a b"
                  range := some { start := .line 12, stop := .last } }) },
    { name :=
        "criterion 2: a range is resolved against the buffer's lines and the cursor's: over three lines `%` is 1 to 3 and `.` the cursor's line, and line 0, a range that runs backwards and a line past the end are refused, the last with a message naming the line and the count"
      run :=
        let over (range : Ex.Range) (current : Nat) : String ⊕ (Nat × Nat) :=
          match range.resolve current 3 with
          | .ok lines => .inr lines
          | .error why => .inl why
        pure
          (over { start := .line 1, stop := .line 7 } 1 == .inl (Ex.pastEnd 7 3) &&
            Ex.pastEnd 7 3 == "line 7 is past the end of the buffer (3 lines)" &&
            over { start := .line 1, stop := .last } 2 == .inr (1, 3) &&
            over { start := .current, stop := .current } 2 == .inr (2, 2) &&
            over { start := .current, stop := .last } 2 == .inr (2, 3) &&
            over { start := .line 0, stop := .line 0 } 1 == .inl Ex.lineZero &&
            over { start := .line 3, stop := .line 2 } 1 == .inl (Ex.backwards 3 2) &&
            over { start := .line 5, stop := .line 3 } 1 == .inl (Ex.pastEnd 5 3) &&
            over { start := .line 9, stop := .line 8 } 1 == .inl (Ex.pastEnd 9 3)) },
    { name :=
        "a text's lines are its rows, but for the empty row after a last line feed: three lines and a last line feed are three lines, the empty text is one, and a last line with no line feed counts; a snapshot of the text counts the same"
      run :=
        let counted (initial : String) : Option (Nat × Nat) :=
          onTextModel do
            let text ← createText initial
            return (← text.lineCount, ← (← text.snapshot).lineCount)
        pure
          ([("b\nc\na\n", 3), ("", 1), ("a", 1), ("a\nb", 2), ("\n", 1), ("a\n\n", 2)].all
            fun (initial, lines) => counted initial == some (lines, lines)) }]

end ModelTest
