import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Evil.Undo
import Editor.InputScheme
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Loop.Driver
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Test.Excerpt
import Editor.Test.Loop
import Editor.Text
import ModelTest.Check
import ModelTest.Support.Evil
import ModelTest.Support.Vim

/-!
# Model tests: `Editor/Evil/Undo.lean`

The model tests of `Editor/Evil/Undo.lean`: `evilUndoChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- One change of each kind, for the checks of `u` and `C-r`: the text and
the cursor it is made from, its keys, and the text and the cursor from
before the change's command, which is the fixture unless keys before the
change's own moved the cursor. -/
def undoRows : List (String × String × String) :=
  [("|a b c", "d w", "|a b c"), ("ab\n|cd\nef", "d d", "ab\n|cd\nef"),
    ("ab\nc|d\nef\ngh", "d j", "ab\nc|d\nef\ngh"),
    ("foo |bar baz", "c w X <Escape>", "foo |bar baz"),
    ("ab\nc|d\nef", "c c X <Escape>", "ab\nc|d\nef"), ("foo |bar baz", "v e d", "foo ba|r baz"),
    ("abc\nd|ef\nghi\njk", "V j d", "abc\ndef\ng|hi\njk"), ("a|bc", "x", "a|bc"),
    ("a|bcde", "3 x", "a|bcde"), ("foo |bar baz", "y w p", "foo |bar baz"),
    ("ab\nc|d\nef", "y y p", "ab\nc|d\nef"), ("ab\nc|d\nef", "y y P", "ab\nc|d\nef"),
    ("foo |bar baz", "y w P", "foo |bar baz"), ("ab\nc|d\nef", "o X <Escape>", "ab\nc|d\nef"),
    ("ab\nc|d\nef", "O X <Escape>", "ab\nc|d\nef"),
    -- A session that typed nothing leaves its bar at a line's start, where
    -- `<Escape>` does not step back and a redo must not either.
    ("ab\nc|d\nef", "o <Escape>", "ab\nc|d\nef"), ("ab\nc|d\nef", "O <Escape>", "ab\nc|d\nef"),
    ("ab\nc|d\nef", "c c <Escape>", "ab\nc|d\nef"), ("ab\n|cd ef", "c w <Escape>", "ab\n|cd ef"),
    ("foo |bar baz", "v e c X <Escape>", "foo ba|r baz")]

/-- The checks of evil's undo and redo (`Editor/Evil/Undo.lean`), by key,
on the loop's driver over the editor's models, under the Vim scheme that
ships with evil's commands. What `u` leaves is the phase's rule and not
Vim's, which leaves the cursor at the start of the changed text. -/
def evilUndoChecks : List Check :=
  [{  name :=
        "u after a change restores the text and the cursor from before the change's command, and C-r reapplies it, leaving the text and the cursor the change left: for d over a motion, lines and a selection, c with typed text, x, p, P, o and O; for c over a selection; and for o, O, c c and c w at a line's start with nothing typed, whose session leaves its bar at a line's start, where C-r does not step back across the line break"
      run := do
        let wrong :=
          undoRows.filterMap fun (fixture, typed, before) =>
            match evilDriver fixture with
            | none => some s!"no driver for {repr fixture}"
            | some driver =>
              let changed := evilFed driver typed
              let undone := evilFed changed "u"
              let redone := evilFed undone "C-r"
              if
                  evilText changed != evilText driver && evilShown undone == before &&
                    undone.loop.state.echo.isEmpty &&
                    evilShown redone == evilShown changed &&
                    redone.loop.state.echo.isEmpty then
                none
              else
                some
                  s!"{typed} from {repr fixture} left {repr (evilShown changed)}, u {repr (evilShown undone)} saying {repr undone.loop.state.echo}, C-r {repr (evilShown redone)} saying {repr redone.loop.state.echo}"
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate wrong))
        return true },
    { name :=
        "u after an insert session that typed text restores the text and leaves the cursor on the cell the insert began before, and C-r leaves the cursor where <Escape> left it"
      run :=
        pure <|
          evilKeys "a|bc" "i X Y <Escape> u" == "a|bc" &&
            evilKeys "a|bc" "a X Y <Escape> u" == "ab|c" &&
            evilKeys "a|bc" "i X Y <Escape> u C-r" == evilKeys "a|bc" "i X Y <Escape>" &&
            evilKeys "a|bc" "i X Y <Escape>" == "aX|Ybc" },
    { name :=
        "a count before u or C-r takes that many steps: 2 u takes two back, a count past the history stops at the first step, and 2 C-r takes two forward"
      run :=
        pure <|
          evilKeys "|abcd" "x x x" == "|d" && evilKeys "|abcd" "x x x 2 u" == "|bcd" &&
            evilKeys "|abcd" "x x x 9 u" == "|abcd" &&
            evilKeys "|abcd" "x x x 9 u 2 C-r" == "|cd" &&
            evilKeys "|abcd" "x x x 9 u 9 C-r" == "|d" },
    { name :=
        "u with nothing to undo and C-r with nothing to redo say so in the echo area, each with the sentence its function makes, and change nothing"
      run :=
        pure <|
          match evilDriver "a|bc" with
          | none => false
          | some driver =>
            let undone := evilFed driver "u"
            let redone := evilFed driver "C-r"
            !Evil.nothingToUndo.isEmpty && !Evil.nothingToRedo.isEmpty &&
              undone.loop.state.echo == Evil.nothingToUndo &&
              evilShown undone == "a|bc" &&
              evilHistory undone == evilHistory driver &&
              redone.loop.state.echo == Evil.nothingToRedo &&
              evilShown redone == "a|bc" &&
              (evilFed (evilFed driver "x u") "u").loop.state.echo == Evil.nothingToUndo },
    { name :=
        "u at the root of a buffer a restore made says its history starts at the restore, after undoing what was done since, and changes nothing"
      run :=
        pure <|
          match evilDriver "a|bc" with
          | none => false
          | some driver =>
            let state := driver.loop.state
            let marked : EvilDriver :=
              { driver with loop := { driver.loop with state := (state.markRestored ⟨0⟩).2 } }
            let undone := evilFed marked "u"
            let again := evilFed (evilFed marked "x") "u u"
            undone.loop.state.echo == Evil.nothingBeforeRestore && evilShown undone == "a|bc" &&
              again.loop.state.echo == Evil.nothingBeforeRestore &&
              evilShown again == "a|bc" },
    { name :=
        "u after a visual deletion leaves one range with equal ends at the selection's head, in normal state's shape"
      run :=
        pure <|
          (evilSelected "foo |bar baz" "v e d u").map (fun (ranges, shape, _) => (ranges, shape)) ==
            some ([(6, 6)], (vimDefaultReport "").shape) },
    { name :=
        "a step whose edits carried no selection is undone with the cursor rested where the selection's marker is: a command written here inserts at a position, and u after it leaves the cursor on the cell it was on"
      run :=
        pure <|
          let stamp : Config.Registration :=
            { name := "stamp"
              action := .call fun _ => discard <| (⟨0⟩ : BufferId).insertAt 0 "XY" }
          match evilDriver "ab|c" (evilHanded #[stamp]) with
          | none => false
          | some driver =>
            let stamped :=
              (driver.stepped (driver.loop.invoke driver.handed { command := "stamp" })).1
            evilShown stamped == "XYab|c" && evilShown (evilFed stamped "u") == "ab|c" },
    { name :=
        "after u and after C-r the window keeps no wanted column: j keeps one, and the u and the C-r after it leave none"
      run :=
        pure <|
          match evilDriver "ab|cd\nxyz\nabcd" with
          | none => false
          | some driver =>
            let wanted (driver : EvilDriver) := (driver.loop.state.window? ⟨0⟩).bind (·.wanted)
            let moved := evilFed driver "x j"
            let undone := evilFed moved "u"
            let again := evilFed (evilFed undone "j") "C-r"
            (wanted moved).isSome && (wanted undone).isNone && (wanted again).isNone },
    { name :=
        "u in the excerpt buffer after the source was edited in its own buffer since is refused, saying so, and changes nothing"
      run :=
        pure <|
          match evilExcerptDriver with
          | none => false
          | some driver =>
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            let moved := excerptInvoked typed "edit-one"
            let undone := evilFed moved "u"
            excerptRead moved "one" == some "Zone\ntXwo\nthree\n" &&
              undone.loop.state.echo == Evil.sourceMovedSays "one" &&
              excerptRead undone "one" == some "Zone\ntXwo\nthree\n" &&
              excerptRead undone "ex" == some "tXwo\n\nalpha\n" },
    { name :=
        "C-r in the excerpt buffer after the source was edited in its own buffer since the undo is refused, saying so, and changes nothing"
      run :=
        pure <|
          match evilExcerptDriver with
          | none => false
          | some driver =>
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            let moved := excerptInvoked (evilFed typed "u") "edit-one"
            let redone := evilFed moved "C-r"
            excerptRead moved "one" == some "Zone\ntwo\nthree\n" &&
              redone.loop.state.echo == Evil.sourceMovedSays "one" &&
              excerptRead redone "one" == some "Zone\ntwo\nthree\n" &&
              excerptRead redone "ex" == some "two\n\nalpha\n" },
    { name :=
        "u in the excerpt buffer once a source buffer of its last step was removed says so, under the name the step recorded, and drops that step, so the next u undoes the older step over a live source"
      run :=
        pure <|
          match evilExcerptDriver with
          | none => false
          | some driver =>
            let older := evilFed (excerptFed (evilFed driver "j j i") [.commit "Q"]) "<Escape>"
            let newer := evilFed (excerptFed (evilFed older "k k i") [.commit "X"]) "<Escape>"
            let removed := excerptInvoked newer "remove-one"
            let refused := evilFed removed "u"
            let undone := evilFed refused "u"
            let emptied := evilFed undone "u"
            excerptRead older "two" == some "Qalpha\nbeta\n" &&
              excerptRead newer "one" == some "one\nXtwo\nthree\n" &&
              (excerptBufferNamed removed "one").isNone &&
              refused.loop.state.echo == Evil.sourceRemovedSays "one" &&
              excerptRead refused "two" == some "Qalpha\nbeta\n" &&
              undone.loop.state.echo.isEmpty &&
              excerptRead undone "two" == some "alpha\nbeta\n" &&
              emptied.loop.state.echo == Evil.nothingToUndo },
    { name :=
        "u in the excerpt buffer once one of the two sources of its last step was removed says so and drops that source from the step, so the next u undoes the step in the source left"
      run :=
        pure <|
          match evilExcerptDriver with
          | none => false
          | some driver =>
            let removed := excerptInvoked (excerptInvoked driver "edit-both") "remove-one"
            let refused := evilFed removed "u"
            let undone := evilFed refused "u"
            excerptRead removed "two" == some "Alpha\nbeta\n" &&
              refused.loop.state.echo == Evil.sourceRemovedSays "one" &&
              excerptRead refused "two" == some "Alpha\nbeta\n" &&
              undone.loop.state.echo.isEmpty &&
              excerptRead undone "two" == some "alpha\nbeta\n" },
    { name :=
        "C-r in the excerpt buffer once the source buffer of the step to redo was removed says so and drops the step, so the next C-r has nothing to redo"
      run :=
        pure <|
          match evilExcerptDriver with
          | none => false
          | some driver =>
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            let removed := excerptInvoked (evilFed typed "u") "remove-one"
            let refused := evilFed removed "C-r"
            let emptied := evilFed refused "C-r"
            refused.loop.state.echo == Evil.sourceRemovedSays "one" &&
              emptied.loop.state.echo == Evil.nothingToRedo },
    { name :=
        "a menu's undo undoes as u does: after x over abc, both leave abc and the same selection"
      run :=
        pure <|
          match evilDriver "|abc" with
          | none => false
          | some driver =>
            let cut := evilFed driver "x"
            let byKey := evilFed cut "u"
            let byMenu := (cut.feed { event := .menu "undo", stamp := 0 }).1
            evilShown cut != evilShown byKey && evilShown byMenu == evilShown byKey &&
              (evilShown byKey).replace "|" "" == "abc" &&
              evilSelection byMenu == evilSelection byKey }]

end ModelTest
