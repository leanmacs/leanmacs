import Editor.Clipboard.Model
import Editor.Command.Call
import Editor.Command.Model
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Config.Packages
import Editor.Event
import Editor.File
import Editor.InputScheme
import Editor.Invocation
import Editor.Job
import Editor.Keymap
import Editor.Loop.Driver
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Text
import Editor.Vocabulary
import Editor.Watch.Model
import Evil
import Evil.Compiled
import Evil.Motions
import Evil.Operators
import Evil.Registers
import Evil.Repeat
import Evil.TreeObjects
import Evil.Vim
import Evil.Vim.Default
import EvilTest.Check
import EvilTest.Support.Evil

/-!
# Model tests: `Evil/Repeat.lean`

The model tests of `Evil/Repeat.lean`: `evilRepeatChecks`, and
`atPointRepeatChecks`, what a repeat replays after completion at point, on
the kit's at-point package (`Editor/Test/AtPoint.lean`). The root module
`EvilTest.Model` runs them; its module doc says what each shows.
-/

namespace EvilTest

open Editor
open Editor.Test

/-- The oracle table's rows for `.`: the keys, the text before with the
cursor as a bar, and the text after. A count before `.` replaces the
change's; a change with an insert session is replayed with the text typed
in it, and leaves the cursor where `<Escape>` would; a yank is not the last
change. -/
def repeatRows : List (String × String × String) :=
  [("d w .", "|a b c d e f", "|c d e f"), ("d w 3 .", "|a b c d e f g", "|e f g"),
    ("d w 3 . .", "|a b c d e f g h i", "|h i"), ("d 2 w 3 .", "|a b c d e f g", "|f g"),
    ("2 d d .", "|a\nb\nc\nd\ne", "|e"), ("x .", "|abcd", "|cd"), ("x 3 .", "|abcdefgh", "|efgh"),
    ("c w X Y <Escape> w .", "|foo bar baz", "XY X|Y baz"),
    ("c w X Y <Escape> w w .", "|foo bar baz", "XY bar X|Y"),
    ("c w X Y <Escape> w 2 .", "|foo bar baz qux", "XY X|Y qux"),
    ("c w <Escape> w .", "|foo bar baz", "|  baz"),
    ("c c X <Escape> j .", "|ab\ncd\nef", "X\n|X\nef"), ("o X <Escape> .", "|ab", "ab\nX\n|X"),
    ("O X <Escape> .", "|ab", "|X\nX\nab"), ("i X <Escape> .", "a|b", "a|XXb"),
    ("a X <Escape> .", "a|b", "abX|X"), ("A X <Escape> j .", "|ab\ncd", "abX\ncd|X"),
    ("I X <Escape> j .", "  a|b\n  cdef", "  Xab\n  |Xcdef"),
    ("I X <Escape> j $ .", "  a|b\n  cdef", "  Xab\n  |Xcdef"),
    ("y w P .", "|ab cd", "abab|  ab cd"), ("y y p .", "|ab", "ab\nab\n|ab"),
    ("d w y w .", "|a b c d", "|c d")]

/-- The oracle table's rows for `.` after an insert session that used insert
state's editing keys, Vim 9.1's results: `<Backspace>`, `RET` and `TAB` are
replayed as typed, a `<Backspace>` past where the insert began included;
after an arrow key that moved and a text typed after it the change is `i`
with that text (`ins-special-special`); an arrow key with nothing typed
after it, and one that did not move, leave the change as it was. -/
def insertKeysRepeatRows : List (String × String × String) :=
  [("i x <Backspace> y <Escape> .", "a|b", "a|yyb"),
    ("i a b SPC c d C-w <Escape> .", "|x", "abab|  x"),
    ("a <Backspace> X <Escape> .", "ab|cd", "ab|Xd"),
    ("i x RET y <Escape> .", "a|b", "ax\nx\n|yyb"), ("i x TAB y <Escape> .", "a|b", "ax\tx\t|yyb"),
    ("i x <ArrowLeft> y <Escape> .", "a|b", "a|yyxb"),
    ("i x <ArrowRight> y <Escape> .", "a|bc", "axb|yyc"),
    ("i x <ArrowUp> y <Escape> .", "ab\na|b", "ab|yy\naxb"),
    ("i x <ArrowDown> y <Escape> .", "a|b\nab", "axb\nab|yy"),
    ("A x <ArrowLeft> y <Escape> 0 .", "a|b", "|yabyx"),
    ("c w X <ArrowLeft> <Escape> w .", "|foo bar", "X |X"),
    ("A x <ArrowRight> y <Escape> 0 .", "a|b", "abxyx|y")]

/-- The checks of evil's dot repeat (`Evil/Repeat.lean`), by key, on
the loop's driver over the editor's models, under the Vim scheme that ships
with evil's commands. -/
def evilRepeatChecks : List Check :=
  [{  name :=
        ". after an operator over a text object replays it where the cursor is then: c i w with typed text, d a w, d i ( on another pair, d a w with a count that replaces the change's, d 2 i w, and c i \" with typed text in another string, as Vim 9.1.1752 does them"
      run :=
        evilRows
          [("c i w x y <Escape> w .", "|foo bar baz", "xy x|y baz"),
            ("d a w .", "|a b c d", "|c d"), ("d i ( $ .", "f(|a) g(b)", "f() g(|)"),
            ("d a w 3 .", "|a b c d e f", "|e f"), ("d 2 i w .", "|a b c d e", "|c d e"),
            ("c i \" z <Escape> f c .", "\"|ab\" \"cd\"", "\"z\" \"|z\"")] },
    { name :=
        ". after an operator over a find replays it with the same character: d f c deletes to the next c again, d t c up to the next c, d ; repeats the last find as it is at the replay, and c f c with typed text makes the same change"
      run :=
        evilRows
          [("d f c .", "|abcabcabc", "|abc"), ("d t c .", "|abcabcab", "|cab"),
            ("f a d ; .", "|xabxabxab", "x|b"), ("c f c z <Escape> .", "|abcabcab", "|zab")] },
    { name :=
        ". after an operator over a search replays it with the search as it is at the replay: d n deletes to the next match of the last search again, and d * to the next occurrence of the word under the cursor"
      run :=
        evilRows
          [("* 0 d n .", "|foo x foo x foo x", "|foo x"), ("d * .", "|a x a x a x", "|a x"),
            ("d / f o o RET .", "|a foo b foo c foo", "|foo c foo"),
            ("c / x RET y <Escape> l .", "|abxcdxef", "y|yxef")] },
    { name :=
        ". replays the last change: after d w it deletes the next word, and after c w, typed text and <Escape> it makes the same change with the same text at the cursor; a count before it replaces the change's and is kept; x, the doubled operator, o, O, i, a, I, A, p and P are replayed, and a yank is not the last change"
      run := evilRows repeatRows },
    { name :=
        ". after a session that used <Backspace>, C-w, RET or TAB replays them as typed, a <Backspace> past where the insert began included, and RET with the buffer's line ending; after an arrow key that moved and a text typed after it, . is i with that text, as in Vim 9.1; after an arrow key with nothing typed after it, or one that did not move, . replays the change as it was"
      run := do
        let rows ← evilRows insertKeysRepeatRows
        let crlf :=
          let start : TextM EditorState := do
            let state ← evilState "abc" 2
            return { state with
                buffers := state.buffers.map (·.map ({ · with lineEnding := .crlf })) }
          match (Loop.Driver.over evilHanded (fun _ => none) start editorModel).toOption with
          | none => false
          | some driver => evilShown (evilFed driver "i RET <Escape> .") == "ab\r\n\r\n|c"
        return rows && crlf },
    { name :=
        "a replayed change that itself gives up gives the replay up and changes nothing: after d j, G and . on the last line, where j fails, the text, the cursor, the register and the history are as they were, the view is in normal state, and the echo area says why under the repeat command's name; after c j, a text, <Escape> and G, . likewise, with no text inserted and the view left in normal state; and the change is still the last change, which . replays from the first line"
      run :=
        pure <|
          let said := s!"{Vim.repeatCommand}: {Evil.cannotMove Evil.down.name}"
          let steps (typed : String) : Option (Option (Nat × Bool)) :=
            (evilDriver "|ab\ncd\nef\ngh").map fun driver => evilHistory (evilFed driver typed)
          let status (typed : String) : Option (Array StatusField) :=
            (evilScene "|ab\ncd\nef\ngh" typed).map (·.status)
          evilEdited "|ab\ncd\nef\ngh" "d j G" ==
              some ⟨"ef\n|gh", linewise "ab\ncd\n", false, ""⟩ &&
            evilEdited "|ab\ncd\nef\ngh" "d j G ." ==
              some ⟨"ef\n|gh", linewise "ab\ncd\n", false, said⟩ &&
            steps "d j G ." == steps "d j G" &&
            status "d j G ." == status "d j G" &&
            evilEdited "|ab\ncd\nef\ngh" "c j X <Escape> G" ==
              some ⟨"X\nef\n|gh", linewise "ab\ncd\n", false, ""⟩ &&
            evilEdited "|ab\ncd\nef\ngh" "c j X <Escape> G ." ==
              some ⟨"X\nef\n|gh", linewise "ab\ncd\n", false, said⟩ &&
            steps "c j X <Escape> G ." == steps "c j X <Escape> G" &&
            steps "c j X <Escape> G" == some (some (2, false)) &&
            status "c j X <Escape> G ." == status "c j X <Escape> G" &&
            evilEdited "|ab\ncd\nef\ngh" "c j X <Escape> G . g g ." ==
              some ⟨"|X\ngh", linewise "X\nef\n", false, ""⟩ },
    { name :=
        "a replayed change with an insert session is one step of the history and leaves the view in normal state: after c w X Y <Escape> w . the tree has one node more and nothing pending, and one u takes the whole replay back, with the cursor where it was"
      run :=
        pure <|
          match evilDriver "|foo bar baz" with
          | none => false
          | some driver =>
            let changed := evilFed driver "c w X Y <Escape> w"
            let replayed := evilFed changed "."
            evilHistory changed == some (2, false) && evilHistory replayed == some (3, false) &&
              evilShown replayed == "XY X|Y baz" &&
              (evilSeen replayed).map (·.status) == some ((evilLooks "").2.push evilMark) &&
              evilShown (evilFed replayed "u") == "XY |bar baz" },
    { name :=
        ". with no change to repeat says nothing and changes nothing, and the repeat command run by its name, which is handed no change, gives up with the sentence its function makes"
      run :=
        pure <|
          let named :=
            (evilRegistered "a|bc").map fun driver =>
              evilLeft
                (driver.stepped
                    (driver.loop.invoke driver.handed { command := Vim.repeatCommand })).1
          evilEdited "a|bc" "." == some ⟨"a|bc", asItWas, false, ""⟩ &&
            evilEdited "a|bc" "y l ." == some ⟨"a|bc", charwise "b", false, ""⟩ &&
            evilGaveUp named "a|bc" Evil.nothingToRepeat },
    { name :=
        "what is not repeated gives the command up and changes nothing: a change over a visual selection, and a change whose command the registry has none of"
      run :=
        pure <|
          let unknown :=
            (evilRegistered "a|bc").map fun driver =>
              evilLeft
                (driver.stepped
                    (driver.loop.invoke driver.handed
                      { command := Vim.repeatCommand
                        arguments :=
                          [.bool false, .str "", .str "frobnicate", .nat 0, .str ""] })).1
          let selected :=
            (evilDriver "foo |bar baz qux").map fun driver =>
              let deleted := evilFed driver "v e d w"
              let repeated := evilFed deleted "."
              (evilShown deleted, evilShown repeated,
                repeated.loop.state.echo.endsWith (Evil.notRepeated Evil.overSelection),
                evilHistory deleted == evilHistory repeated)
          !(Evil.notRepeated "frobnicate").isEmpty &&
            evilGaveUp unknown "a|bc" (Evil.notRepeated "frobnicate") &&
            selected == some ("foo  |baz qux", "foo  |baz qux", true, true) },
    { name :=
        "a text committed in the session a change began is replayed with it: after c w, a committed text, <Escape> and w, . changes the next word to that text"
      run :=
        pure <|
          match evilDriver "|foo bar baz" with
          | none => false
          | some driver =>
            let changing := evilFed driver "c w"
            let committed := (changing.feed { event := .commit "かな", stamp := 0 }).1
            evilShown (evilFed committed "X <Escape> w .") == "かなX かな|X baz" },
    { name :=
        "an operator that a motion's failure cancelled is not the last change, whether or not the motion moved first, as in Vim: after x, a d 3 b that leaves the cursor on the empty first line, and w, . replays the x; and after x and a d j that fails on the last line, . replays the x"
      run :=
        pure <|
          evilEdited "\nab |cd ef" "x d 3 b w ." == some ⟨"\n|b d ef", charwise "a", false, ""⟩ &&
            evilEdited "\nab |cd ef" "x c 3 B w ." == some ⟨"\n|b d ef", charwise "a", false, ""⟩ &&
            evilEdited "ab\n|cde" "x d j ." == some ⟨"ab\n|e", charwise "d", false, ""⟩ },
    { name :=
        "a doubled operator that its count cancelled on the last line is not the last change, as in Vim: after x and then 2 d d, 2 c c, 2 y y or d 2 d on the last line, . replays the x"
      run :=
        pure <|
          evilEdited "ab\ncd\n|efg" "x 2 d d ." == some ⟨"ab\ncd\n|g", charwise "f", false, ""⟩ &&
            evilEdited "ab\ncd\n|efg" "x 2 c c ." == some ⟨"ab\ncd\n|g", charwise "f", false, ""⟩ &&
            evilEdited "ab\ncd\n|efg" "x 2 y y ." == some ⟨"ab\ncd\n|g", charwise "f", false, ""⟩ &&
            evilEdited "ab\ncd\n|efg\n" "x 2 d d ." ==
              some ⟨"ab\ncd\n|g\n", charwise "f", false, ""⟩ &&
            evilEdited "|abc" "x d 2 d ." == some ⟨"|c", charwise "b", false, ""⟩ },
    { name :=
        "a replayed doubled operator that comes to the last line with a count above 1 gives the replay up, as Vim cancels it: 2 d d and . on the one line left, 2 d d . . when the second replay is on the last line, d d, G and 2 ., and 2 c c, a text, <Escape>, j and . each leave the text, the cursor, the register and the history as they were and the view in normal state, with no text inserted, and the echo area says why under the repeat command's name; and the change is still the last change, which . replays from the first line, with the count it had and not the count of the replay that gave up"
      run :=
        pure <|
          let steps (fixture typed : String) : Option (Option (Nat × Bool)) :=
            (evilDriver fixture).map fun driver => evilHistory (evilFed driver typed)
          -- Whether the replay `replay`, typed after `typed`, gave up: what
          -- `typed` left is `shown` and `register`, and the replay left that
          -- and the history, and said why under the repeat command's name.
          let gaveUp (fixture typed replay shown : String) (register : Option Register) : Bool :=
            let after := typed ++ " " ++ replay
            match evilEdited fixture after with
            | some left =>
              evilEdited fixture typed == some ⟨shown, register, false, ""⟩ &&
                left.shown == shown &&
                left.register == register &&
                !left.insert &&
                left.echo == s!"{Vim.repeatCommand}: {Evil.noLineBelow}" &&
                steps fixture after == steps fixture typed
            | none => false
          gaveUp "|ab\ncd\nef" "2 d d" "." "|ef" (linewise "ab\ncd\n") &&
            gaveUp "|ab\ncd\nef\ngh\nij" "2 d d ." "." "|ij" (linewise "ef\ngh\n") &&
            gaveUp "ab\ncd\nef\n|gh" "d d G" "2 ." "ab\ncd\n|ef" (linewise "gh\n") &&
            gaveUp "|ab\ncd\nef" "2 c c X <Escape> j" "." "X\n|ef" (linewise "ab\ncd\n") &&
            evilEdited "|ab\ncd\nef\ngh\nij\nkl" "2 d d G . g g ." ==
              some ⟨"|ij\nkl", linewise "ef\ngh\n", false, ""⟩ &&
            evilEdited "|ab\ncd\nef\ngh" "2 c c X <Escape> G . g g ." ==
              some ⟨"|X\ngh", linewise "X\nef\n", false, ""⟩ &&
            -- The count of a replay that gave up is not kept.
            evilEdited "|ab\ncd\nef\ngh\nij" "d d G 2 . g g ." ==
              some ⟨"|ef\ngh\nij", linewise "cd\n", false, ""⟩ },
    { name :=
        "a replayed change whose motion fails after it moved breaks the replay off, as Vim does: the cursor is where the motion got to, in normal state, nothing is deleted or inserted, the register is the one the change left, the history has no step for it, and the change is still the last change"
      run :=
        pure <|
          let said := s!"{Vim.repeatCommand}: {Evil.cannotMove Evil.wordBackward.name}"
          let steps (fixture typed : String) : Option (Option (Nat × Bool)) :=
            (evilDriver fixture).map fun driver => evilHistory (evilFed driver typed)
          evilEdited "\nab cd |ef gh" "d 2 b ." ==
              some ⟨"|\nef gh", charwise "ab cd ", false, said⟩ &&
            evilEdited "\nab cd |ef gh" "c 2 b X <Escape> ." ==
              some ⟨"|\nXef gh", charwise "ab cd ", false, said⟩ &&
            steps "\nab cd |ef gh" "d 2 b ." == steps "\nab cd |ef gh" "d 2 b" &&
            steps "\nab cd |ef gh" "c 2 b X <Escape> ." ==
              steps "\nab cd |ef gh" "c 2 b X <Escape>" &&
            evilEdited "\nab cd ef |gh" "d 2 b $ . ." ==
              some ⟨"|\nh", charwise "ab g", false, said⟩ &&
            evilEdited "\nab cd |ef gh ij" "d 2 b . G $ ." ==
              some ⟨"\nef |j", charwise "gh i", false, ""⟩ },
    { name :=
        ". replays a change with the command the registry holds for its name, which is the one the change's own keys ran: with operate registered again over the operators that ship and one more, and a key bound to that operator, the key and w erase a word and . erases the next; with a command registered in place of delete-char that deletes two cells, x deletes two and . two more; and with one in place of append that inserts before the cursor, a, a text and <Escape> insert before it and . does again"
      run :=
        pure <|
          let erase : Vocabulary.Operator := { Evil.delete with name := "erase" }
          let more : Array Config.Registration :=
            #[{ name := Vim.operateCommand
                action :=
                  .call (Evil.operate (Evil.operators.push erase) Evil.motions Evil.objects) },
              { name := "delete-char"
                action :=
                  .call fun call => Evil.deleteChar { call with arguments := [.nat 2, .str ""] } },
              { name := "append", action := .call Evil.insert }]
          let handed : Loop.Keys Vim.Default.scheme :=
            { evilHanded more with
              maps := fun _ _ =>
                [Keymap.ofList [(keys "Z", Vim.Bound.operator { name := erase.name })]] }
          let typed (fixture keys : String) : Option (String × String) :=
            (evilDriver fixture handed).map fun driver =>
              let after := evilFed driver keys
              (evilShown after, after.loop.state.echo)
          typed "|a b c d" "Z w" == some ("|b c d", "") &&
            typed "|a b c d" "Z w ." == some ("|c d", "") &&
            typed "|abcdef" "x" == some ("|cdef", "") &&
            typed "|abcdef" "x ." == some ("|ef", "") &&
            typed "a|b" "a X <Escape>" == some ("a|Xb", "") &&
            typed "a|b" "a X <Escape> ." == some ("a|XXb", "") },
    { name :=
        "the repeat command handed its own name as the change gives up, with the sentence its function makes: a replay is no change"
      run :=
        pure <|
          let named :=
            (evilRegistered "a|bc").map fun driver =>
              evilLeft
                (driver.stepped
                    (driver.loop.invoke driver.handed
                      { command := Vim.repeatCommand
                        arguments :=
                          [.bool false, .str "", .str Vim.repeatCommand, .bool false, .str "",
                            .str "delete-char", .nat 0, .str ""] })).1
          evilGaveUp named "a|bc" (Evil.notRepeated Vim.repeatCommand) },
    { name :=
        "every command a default key of the Vim scheme is bound to as changing text is one evil registers, and so is the command an operator's keys run: . finds each in the registry"
      run :=
        pure <|
          let changing :=
            (Vim.Default.normalCommands ++ Vim.Default.insertCommands ++
                  Vim.Default.visualCommands ++
                  Vim.Default.visualLineCommands).filterMap
              fun (_, bound) =>
              match bound with
              | .command command => if command.changes then some command.name else none
              | _ => none
          !changing.isEmpty &&
            (Vim.operateCommand :: changing).all fun name =>
              Evil.package.registered.commands.any (·.name == name) },
    { name :=
        "a replayed change that names the clipboard register and began an insert session writes the clipboard as the replay's last request: run to its end it leaves the clipboard model holding the word it changed, and stopped by the interrupt before any one of its requests it is rolled back with the clipboard model holding what it held before"
      run :=
        pure <|
          match evilRegistered "|foo bar baz" with
          | none => false
          | some driver =>
            let changed := evilFed driver "\" + c w X <Escape> w"
            -- The replay with an interrupt key that arrives once it has made
            -- `asks` of its requests, or with none.
            let replayed (asks : Option Nat) : EvilEdited × Option String :=
              let after :=
                evilFed
                  { changed with
                    model :=
                      { changed.model with
                        watch := { changed.model.watch with arrivesAfter := asks } } }
                  "."
              (evilLeft after, after.model.clipboard.held)
            let before : EvilEdited × Option String :=
              (⟨"X |bar baz", charwise "foo", false, ""⟩, some "foo")
            let whole : EvilEdited × Option String :=
              (⟨"X |X baz", charwise "bar", false, ""⟩, some "bar")
            let stopped : EvilEdited × Option String :=
              ({ before.1 with echo := s!"{Vim.repeatCommand}: interrupted" }, some "foo")
            let runs := (List.range 80).map fun asks => replayed (some asks)
            (evilLeft changed, changed.model.clipboard.held) == before && replayed none == whole &&
              runs.all (fun run => run == stopped || run == whole) &&
              (runs.filter (· == stopped)).length > 8 &&
              runs.getLast? == some whole },
    { name :=
        "the clipboard a replayed change writes is the text the replay took, whatever the unnamed register held: where the clipboard model was set to another text since the change, and the word the replay changes is the one the unnamed register already holds, the replay writes that word; a replayed change that takes no cell writes nothing; and with a clipboard that is not available the replay runs to its end and says so in the echo area"
      run :=
        pure <|
          let replayed (fixture typed : String) (clipboard : ClipboardModel) :
            Option (EvilEdited × Option String) :=
            (evilRegistered fixture).map fun driver =>
              let changed := evilFed driver typed
              let after := evilFed { changed with model := { changed.model with clipboard } } "."
              (evilLeft after, after.model.clipboard.held)
          replayed "|foo foo baz" "\" + c w X <Escape> w" { held := some "other" } ==
              some (⟨"X |X baz", charwise "foo", false, ""⟩, some "foo") &&
            replayed "|ab\ncd" "\" + c h X <Escape> j" { held := some "other" } ==
              some (⟨"Xab\n|Xcd", asItWas, false, ""⟩, some "other") &&
            replayed "|foo bar baz" "\" + c w X <Escape> w" { available := false } ==
              some (⟨"X |X baz", charwise "bar", false, Evil.clipboardUnavailable⟩, none) &&
            replayed "|a b c d" "\" + d w" {} ==
              some (⟨"|c d", charwise "b ", false, ""⟩, some "b ") }]

/-- The at-point source `line` of the repeat checks of completion at point:
the region from the start of the cursor's line to the cursor, read from the
text, completed from the source `say`. -/
def repeatLineAtPoint : Completion.AtPoint :=
  { name := "line"
    ask := fun spot => do
      let .ok target ← spot.view.target | return none
      let start ← target.buffer.text.motion .lineStart spot.offset
      return some { start, stop := spot.offset, sources := [.source "say"] } }

/-- What a step of the repeat checks of completion at point is handed:
`evilHanded`, which registers the kit's at-point package
(`Editor/Test/AtPoint.lean`), told that a buffer's chain is the at-point
source `line` (`repeatLineAtPoint`) and that the source `say` holds
`say hello` and `say hi`. -/
def repeatAtPointHanded : Loop.Keys Vim.Default.scheme :=
  let handed := evilHanded
  let say : Completion.Source := .ofTexts "say" "say" #["say hello", "say hi"]
  { handed with
    registered :=
      { handed.registered with
        atPoint := fun name =>
          if name == repeatLineAtPoint.name then some repeatLineAtPoint else none
        atPointNames := fun _ _ => #[repeatLineAtPoint.name]
        sources := fun name => if name == say.name then some say else none
        categorySources := fun category => if category == say.category then #[say.name] else #[] } }

/-- The checks of what a repeat replays after completion at point
(`EditorState.retyped`, `Loop.ranInto`): what a command typed in place of
typed text reaches the last change's recording, only when the command ran to
its end; and `.` after an insert that accepted a preview inserts what that
insert left. -/
def atPointRepeatChecks : List Check :=
  let retyping : Config.Registration :=
    { name := "retyping", action := .call fun call => retype call.target.window.id "zz" }
  let refusing : Config.Registration :=
    { name := "refusing"
      action :=
        .call fun call => do
          retype call.target.window.id "yy"
          throw .badRange }
  [{  name :=
        "what a command says it typed reaches the insert session's recording once it has run to its end, and a command that is refused tells the scheme nothing"
      run :=
        pure <|
          match evilDriver "ab|c" (evilHanded #[retyping, refusing]) with
          | none => false
          | some driver =>
            let inserting := evilFed driver "i x"
            let told :=
              (inserting.stepped
                  (inserting.loop.invoke inserting.handed { command := "retyping" })).1
            let refused := (told.stepped (told.loop.invoke told.handed { command := "refusing" })).1
            told.loop.input.inserted == some "xzz" && told.loop.atRest.inserted == some "xzz" &&
              refused.loop.input.inserted == some "xzz" &&
              told.loop.state.retyped.isEmpty },
    { name :=
        "after a C-n C-n RET <Escape>, a move and . insert at the new bar what the insert left, the previewed text included"
      run :=
        pure <|
          match evilDriver "say he\nsay h|e" repeatAtPointHanded with
          | none => false
          | some driver =>
            let done := evilFed driver "a C-n C-n RET <Escape>"
            let repeated := evilFed done "k ."
            evilText done == some "say he\nsay hello" &&
              evilText repeated == some "say hello\nsay hello" }]

end EvilTest
