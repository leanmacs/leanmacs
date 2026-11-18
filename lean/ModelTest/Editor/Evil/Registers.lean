import Editor.Clipboard.Model
import Editor.Command.Model
import Editor.Config.Registry
import Editor.Evil.Motions
import Editor.Evil.Operators
import Editor.Evil.Registers
import Editor.InputScheme
import Editor.InputScheme.Vim
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Job
import Editor.Keymap
import Editor.Loop
import Editor.Loop.Driver
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.Vocabulary
import ModelTest.Check
import ModelTest.Support.Evil
import ModelTest.Support.Loop
import ModelTest.Support.Models
import ModelTest.Support.OperatorRows

/-!
# Model tests: `Editor/Evil/Registers.lean`

The model tests of `Editor/Evil/Registers.lean`: `evilRegisterChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- What a step of the replace checks is handed: evil's commands, with
`<F5>` bound in an active keymap to the operator `replace`, which no
default key binds, so that a visual state's selection is replaced by key. -/
def replaceHanded : Loop.Keys Vim.Default.scheme :=
  { evilHanded with
    maps := fun _ _ => [Vim.Default.keymap [("<F5>", .operator { name := Evil.replace.name })]] }

/-- A driver of the replace checks over the text and cursor `fixture` says,
with the unnamed register holding `evilSentinel`, on the editor's models
with the clipboard model `clipboard`. -/
def replaceDriver (fixture : String) (clipboard : ClipboardModel := {}) : Option EvilDriver :=
  let (contents, head) := barred fixture
  (Loop.Driver.over replaceHanded (fun _ => none)
      (do
        return (← evilState contents head).setRegister Evil.unnamed evilSentinel)
      { editorModel with clipboard }).toOption

/-- The keys `typed` pressed on `replaceDriver`: what they left, and the
text the clipboard model then holds. -/
def evilReplaced (fixture typed : String) (clipboard : ClipboardModel := {}) :
    Option (EvilEdited × Option String) :=
  (replaceDriver fixture clipboard).map fun driver =>
    let after := evilFed driver typed
    (evilLeft after, after.model.clipboard.held)

/-- The checks of evil's registers and of the commands that read and set
them without an operator's key (`Editor/Evil/Registers.lean`,
`Editor/Evil/Operators.lean`), by key, as `evilOperatorChecks` are. -/
def evilRegisterChecks : List Check :=
  [{  name :=
        "x deletes the cell under the cursor into the unnamed register and leaves the cursor on the cell that follows, or on the line's last cell when it deleted the last one; with a count it deletes that many cells and no further than the line's end; on an empty line it does nothing"
      run :=
        operatorRows
          [.rests "a|bc" "x" "a|c" (charwise "b"), .rests "ab|c" "x" "a|b" (charwise "c"),
            .rests "ab|c\ndef" "x" "a|b\ndef" (charwise "c"),
            .rests "a|bcde" "3 x" "a|e" (charwise "bcd"),
            .rests "a|bcde" "9 x" "|a" (charwise "bcde"),
            .rests "ab\n|\ncd" "x" "ab\n|\ncd" asItWas] },
    { name :=
        "x is d l: from the same text and cursor the two leave the same text, cursor and register, with no count and with one, and each is one step of the history"
      run :=
        pure <|
          ["a|bc", "ab|c", "ab|c\ndef", "ab\n|\ncd", "|", "a|é😀b\r\nc"].all
              (fun fixture =>
                (evilEdited fixture "x").isSome &&
                  evilEdited fixture "x" == evilEdited fixture "d l" &&
                  evilEdited fixture "3 x" == evilEdited fixture "d 3 l") &&
            ((evilDriver "a|bc").map fun driver => evilHistory (evilFed driver "x")) ==
              some (some (2, false)) },
    { name :=
        "a yank or a deletion that names the clipboard register writes the clipboard and sets the unnamed register too: \" + y w leaves the clipboard model holding the word, \" + d d the line with its line break, and \" + x the cell"
      run :=
        pure <|
          evilClipped "foo |bar baz" "\" + y w" ==
              some (⟨"foo |bar baz", charwise "bar ", false, ""⟩, some "bar ") &&
            evilClipped "ab\n|cd\nef" "\" + d d" ==
              some (⟨"ab\n|ef", linewise "cd\n", false, ""⟩, some "cd\n") &&
            evilClipped "a|bc" "\" + x" == some (⟨"a|c", charwise "b", false, ""⟩, some "b") },
    { name :=
        "naming the unnamed register is naming none: \" \" y w and y w leave the same, and the clipboard model holds what it held"
      run :=
        pure <|
          evilClipped "foo |bar baz" "\" \" y w" { held := some "before" } ==
              some (⟨"foo |bar baz", charwise "bar ", false, ""⟩, some "before") &&
            evilClipped "foo |bar baz" "y w" { held := some "before" } ==
              some (⟨"foo |bar baz", charwise "bar ", false, ""⟩, some "before") },
    { name :=
        "a register evil has none of gives the command up, with the sentence its function makes: nothing is yanked or deleted, a change begins no insert, and nothing is written to the clipboard"
      run :=
        pure <|
          !(Evil.noRegister "a").isEmpty &&
            evilGaveUp (evilEdited "foo |bar baz" "\" a y w") "foo |bar baz"
              (Evil.noRegister "a") &&
            evilGaveUp (evilEdited "foo |bar baz" "\" a c w") "foo |bar baz"
              (Evil.noRegister "a") &&
            evilGaveUp (evilEdited "foo |bar baz" "\" a d d") "foo |bar baz"
              (Evil.noRegister "a") &&
            evilGaveUp (evilEdited "foo |bar baz" "\" a x") "foo |bar baz" (Evil.noRegister "a") &&
            (evilClipped "foo |bar baz" "\" a y w").map (·.2) == some none },
    { name :=
        "with a clipboard that is not available, a yank that names it says so in the echo area, with the sentence its function makes, and the unnamed register holds the word"
      run :=
        pure <|
          !Evil.clipboardUnavailable.isEmpty &&
            evilClipped "foo |bar baz" "\" + y w" { available := false } ==
              some (⟨"foo |bar baz", charwise "bar ", false, Evil.clipboardUnavailable⟩, none) },
    { name :=
        "a yank that names the clipboard and takes no cell empties the unnamed register and writes nothing: the clipboard model holds what it held"
      run :=
        pure <|
          evilClipped "|abc" "\" + y h" { held := some "before" } ==
            some (⟨"|abc", charwise "", false, ""⟩, some "before") },
    { name :=
        "p and P put a character-wise register after and before the cursor's cell, count times, and leave the cursor on the last cell put, or on the first when the text holds a line break; on an empty line p puts at the cursor"
      run :=
        operatorRows
          [.rests "foo |bar baz" "y w p" "foo bbar| ar baz" (charwise "bar "),
            .rests "foo |bar baz" "y w P" "foo bar| bar baz" (charwise "bar "),
            .rests "|ab cd" "y w 2 p" "aab ab| b cd" (charwise "ab "),
            .rests "|ab cd\n\nef" "y w j p" "ab cd\nab| \nef" (charwise "ab "),
            .rests "|ab" "x p" "b|a" (charwise "a"),
            .rests "a|bc\ndef\nghi" "v j y p" "ab|bc\ndec\ndef\nghi" (charwise "bc\nde"),
            .rests "a|bc\ndef\nghi" "v j y P" "a|bc\ndebc\ndef\nghi" (charwise "bc\nde")] },
    { name :=
        "p and P put a line-wise register below and above the cursor's line, count times, and leave the cursor on the first non-blank of the first line put; below a last line with no line break the line break goes before the lines and their last one is left out"
      run :=
        operatorRows
          [.rests "ab\nc|d\nef" "y y p" "ab\ncd\n|cd\nef" (linewise "cd\n"),
            .rests "ab\nc|d\nef" "y y P" "ab\n|cd\ncd\nef" (linewise "cd\n"),
            .rests "ab\nc|d\nef" "y y 2 p" "ab\ncd\n|cd\ncd\nef" (linewise "cd\n"),
            .rests "ab\n  c|d\nef" "y y j p" "ab\n  cd\nef\n  |cd" (linewise "  cd\n"),
            .rests "ab\nc|d" "y y p" "ab\ncd\n|cd" (linewise "cd\n"),
            .rests "a|b\n" "y y p" "ab\n|ab\n" (linewise "ab\n"),
            .rests "|ab\ncd" "d d p" "cd\n|ab" (linewise "ab\n"),
            .rests "ab\n|cd" "d d P" "|cd\nab" (linewise "cd\n"),
            .rests "a|b" "y y 2 p" "ab\n|ab\nab" (linewise "ab\n")] },
    { name :=
        "a put from the clipboard register inserts what the clipboard model holds, character-wise for a text with no final line feed and line-wise for one that ends in one, and leaves the unnamed register as it was"
      run :=
        pure <|
          evilClipped "a|b" "\" + p" { held := some "XY" } ==
              some (⟨"abX|Y", asItWas, false, ""⟩, some "XY") &&
            evilClipped "a|b" "\" + P" { held := some "XY" } ==
              some (⟨"aX|Yb", asItWas, false, ""⟩, some "XY") &&
            evilClipped "a|b" "\" + p" { held := some "cd\n" } ==
              some (⟨"ab\n|cd", asItWas, false, ""⟩, some "cd\n") &&
            evilClipped "a|b\n" "\" + P" { held := some "  cd\n" } ==
              some (⟨"  |cd\nab\n", asItWas, false, ""⟩, some "  cd\n") },
    { name :=
        "a put with nothing to put gives up, with the sentence its function makes, and changes nothing: an unnamed register nothing was set in, one that holds the empty text, a clipboard that holds no text, and one that is not available; and a register evil has none of"
      run :=
        pure <|
          let unset :=
            (evilDriver "a|b").map fun driver =>
              let put := evilFed driver "p"
              (evilShown put, put.loop.state.echo.endsWith Evil.nothingToPut, evilHistory put)
          let emptied :=
            (evilEdited "|ab" "y h p").map fun left =>
              (left.shown, left.echo.endsWith Evil.nothingToPut)
          !Evil.nothingToPut.isEmpty && unset == some ("a|b", true, some (1, false)) &&
            emptied == some ("|ab", true) &&
            evilGaveUp ((evilClipped "a|b" "\" + p").map (·.1)) "a|b" Evil.nothingToPut &&
            evilGaveUp ((evilClipped "a|b" "\" + P" { available := false }).map (·.1)) "a|b"
              Evil.clipboardUnavailable &&
            evilGaveUp (evilEdited "a|b" "\" a p") "a|b" (Evil.noRegister "a") },
    { name :=
        "a put is one step of the history: after y w p the buffer's tree has one node more and nothing pending, and one undo request gives the text from before the put"
      run :=
        pure <|
          match evilDriver "|ab cd" with
          | none => false
          | some driver =>
            let put := evilFed driver "y w p"
            evilHistory put == some (2, false) && evilText put == some "aab b cd" &&
              evilText (evilUndone put) == some "ab cd" },
    { name :=
        "the name a command names the clipboard by when it will write it itself: a yank under that name sets the unnamed register and keeps the same text under the name, and writes nothing to the clipboard; a put under it puts what the clipboard holds; and it is no name a key types, being longer than one character"
      run :=
        pure <|
          let ran (fixture : String) (invocation : Invocation) (clipboard : ClipboardModel) :
            Option (EvilEdited × Option String × Option Register) :=
            (evilRegistered fixture { editorModel with clipboard }).map fun driver =>
              let after := (driver.stepped (driver.loop.invoke driver.handed invocation)).1
              (evilLeft after, after.model.clipboard.held,
                after.loop.state.register? Evil.clipboardLater)
          Evil.clipboardLater.length > 1 &&
            ran "foo |bar baz"
                { command := Vim.operateCommand
                  arguments :=
                    [.str Evil.yank.name, .str "motion", .str Evil.wordForward.name, .nat 0,
                      .str Evil.clipboardLater] }
                { held := some "before" } ==
              some (⟨"foo |bar baz", charwise "bar ", false, ""⟩, some "before", charwise "bar ") &&
            ran "a|b" { command := "put-after", arguments := [.nat 0, .str Evil.clipboardLater] }
                { held := some "XY" } ==
              some (⟨"abX|Y", asItWas, false, ""⟩, some "XY", none) },
    { name :=
        "in a buffer whose lines end in a carriage return and line feed, a line-wise put keeps that line break: y y p on a middle line puts the line below it, y y P above it, and below a last line with no line break the buffer's line break goes before the lines and their last one is left out whole, with a count too"
      run :=
        pure <|
          let put (contents : String) (head : Nat) (typed : String) :
            Option (String × Option Register) :=
            (evilCrlfDriver contents head).map fun driver =>
              let after := evilFed driver typed
              (evilShown after, after.loop.state.register? Evil.unnamed)
          put "ab\r\ncd" 5 "y y p" == some ("ab\r\ncd\r\n|cd", linewise "cd\r\n") &&
            put "ab\r\ncd\r\nef" 5 "y y p" == some ("ab\r\ncd\r\n|cd\r\nef", linewise "cd\r\n") &&
            put "ab\r\ncd" 5 "y y P" == some ("ab\r\n|cd\r\ncd", linewise "cd\r\n") &&
            put "ab\r\ncd" 5 "y y 2 p" == some ("ab\r\ncd\r\n|cd\r\ncd", linewise "cd\r\n") &&
            put "ab\r\n  cd" 6 "y y p" == some ("ab\r\n  cd\r\n  |cd", linewise "  cd\r\n") },
    { name :=
        "in such a buffer a put from the clipboard register of a text that ends in a carriage return and line feed is line-wise: below a middle line and above a line the text goes in as it is, and below a last line with no line break the buffer's line break goes first and the text's own is left out whole; a text that ends in a line feed alone is put below the last line after the buffer's line break"
      run :=
        pure <|
          let put (contents : String) (head : Nat) (typed held : String) : Option String :=
            (evilCrlfDriver contents head
                  { editorModel with clipboard := { held := some held } }).map
              fun driver => evilShown (evilFed driver typed)
          put "ab\r\ncd" 5 "\" + p" "xy\r\n" == some "ab\r\ncd\r\n|xy" &&
            put "ab\r\ncd" 0 "\" + p" "xy\r\n" == some "ab\r\n|xy\r\ncd" &&
            put "ab\r\ncd" 5 "\" + P" "xy\r\n" == some "ab\r\n|xy\r\ncd" &&
            put "ab\r\ncd" 5 "\" + p" "xy\n" == some "ab\r\ncd\r\n|xy" },
    { name :=
        "the operator replace over a character-wise selection puts the clipboard's text in place of it, the cursor on the last cell put, or on the first when the text holds a line break, which goes in as it is; the unnamed register holds the replaced text and the clipboard model what it held; the view is in normal state"
      run :=
        pure <|
          evilReplaced "a|bcd" "v l \" + <F5>" { held := some "XY" } ==
              some (⟨"aX|Yd", charwise "bc", false, ""⟩, some "XY") &&
            evilReplaced "a|bcd" "v l \" + <F5>" { held := some "XY\n" } ==
              some (⟨"a|XY\nd", charwise "bc", false, ""⟩, some "XY\n") &&
            ((replaceDriver "a|bcd" { held := some "XY" }).map fun driver =>
                (evilSeen (evilFed driver "v l \" + <F5>")).bind (·.status[0]?)) ==
              some (evilLooks "").2[0]? },
    { name :=
        "the operator replace over a line-wise selection puts the clipboard's text in place of the lines, a character-wise text with the buffer's line ending added, and the cursor on the first non-blank of the first line put; below a last line with no line break the text's last line break is left out; the unnamed register holds the lines, line-wise"
      run :=
        pure <|
          evilReplaced "ab\nc|d\nef" "V \" + <F5>" { held := some "XY" } ==
              some (⟨"ab\n|XY\nef", linewise "cd\n", false, ""⟩, some "XY") &&
            evilReplaced "ab\nc|d\nef" "V \" + <F5>" { held := some "  XY\n" } ==
              some (⟨"ab\n  |XY\nef", linewise "cd\n", false, ""⟩, some "  XY\n") &&
            evilReplaced "ab\nc|d" "V \" + <F5>" { held := some "XY\n" } ==
              some (⟨"ab\n|XY", linewise "cd\n", false, ""⟩, some "XY\n") &&
            evilReplaced "a|b\ncd\nef" "V j \" + <F5>" { held := some "XY" } ==
              some (⟨"|XY\nef", linewise "ab\ncd\n", false, ""⟩, some "XY") },
    { name :=
        "the operator replace with a clipboard model holding no text gives up with nothingToPut, and with one not available with clipboardUnavailable, and the buffer is as it was"
      run :=
        pure <|
          evilGaveUp ((evilReplaced "a|bcd" "v l \" + <F5>").map (·.1)) "ab|cd" Evil.nothingToPut &&
            evilGaveUp ((evilReplaced "a|bcd" "v l \" + <F5>" { available := false }).map (·.1))
              "ab|cd" Evil.clipboardUnavailable &&
            evilGaveUp ((evilReplaced "ab\nc|d\nef" "V \" + <F5>").map (·.1)) "ab\nc|d\nef"
              Evil.nothingToPut },
    { name :=
        "the operator replace is one step of the history: one undo request gives the text from before it"
      run :=
        pure <|
          match replaceDriver "a|bcd" { held := some "XY" } with
          | none => false
          | some driver =>
            let replaced := evilFed driver "v l \" + <F5>"
            evilText replaced == some "aXYd" && evilHistory replaced == some (2, false) &&
              evilText (evilUndone replaced) == some "abcd" }]

end ModelTest
