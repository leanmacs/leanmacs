import Editor.WindowCommands
import EvilTest.Check
import EvilTest.Support.Evil

/-!
# Model tests: `Evil/Jumps.lean`

The model tests of `Evil/Jumps.lean`: `evilJumpChecks`. The root module
`EvilTest.Model` runs them; its module doc says what each shows.
-/

namespace EvilTest

open Editor
open Editor.Test

/-- The text of the jump list checks scaled from `:help jumplist`: eight
lines, each its own number, the cursor on line 1. -/
def eightLines : String :=
  "|1\n2\n3\n4\n5\n6\n7\n8"

/-- `eightLines` with the cursor at the start of the line `line`, from 1. -/
def onLine (line : Nat) : String :=
  "\n".intercalate
    ((List.range 8).map fun index =>
      if index + 1 == line then s!"|{index + 1}" else s!"{index + 1}")

/-- The rows of the jump checks, as `evilRows` reads them: the keys, the text
before with the cursor as a bar, and the text after. -/
def jumpRows : List (String × String × String) :=
  [ -- G and back to the exact column, and forward again; forward at the end
    -- does nothing.
    ("G C-o", "abc\nd|ef\nghi", "abc\nd|ef\nghi"),
    ("G C-o C-i", "abc\nd|ef\nghi", "abc\ndef\n|ghi"),
    ("G C-o C-i C-i", "abc\nd|ef\nghi", "abc\ndef\n|ghi"),
    ("G C-o TAB", "abc\nd|ef\nghi", "abc\ndef\n|ghi"),
    -- Each jump motion records.
    ("g g C-o", "abc\nd|ef", "abc\nd|ef"), ("/ x RET C-o", "a|b\nx", "a|b\nx"),
    ("? a RET C-o", "a\nb|c", "a\nb|c"), ("/ x RET n C-o", "|ab\nx\nx", "ab\n|x\nx"),
    ("/ x RET n N C-o", "|ab\nx\nx", "ab\nx\n|x"), ("* C-o", "|ab\nx\nab", "|ab\nx\nab"),
    ("# C-o", "ab\nx\n|ab", "ab\nx\n|ab"), ("% C-o", "|(\n)", "|(\n)"),
    -- A motion that is no jump records nothing.
    ("j j C-o", "|a\nb\nc", "a\nb\n|c"), ("w f c C-o", "|a b c", "a b |c"),
    -- A count steps that many.
    ("3 G 5 G 6 G 2 C-o", eightLines, onLine 3),
    -- :help jumplist's example, scaled to eight lines.
    ("3 G 5 G 6 G", eightLines, onLine 6), ("3 G 5 G 6 G C-o", eightLines, onLine 5),
    ("3 G 5 G 6 G C-o G", eightLines, onLine 8), ("3 G 5 G 6 G C-o G C-o", eightLines, onLine 5),
    ("3 G 5 G 6 G C-o G C-o C-o", eightLines, onLine 6),
    ("3 G 5 G 6 G C-o G C-o C-o C-o", eightLines, onLine 3),
    ("3 G 5 G 6 G C-o G C-o C-o C-o C-o", eightLines, onLine 1),
    ("3 G 5 G 6 G C-o G C-o C-o C-o C-o C-o", eightLines, onLine 1),
    ("3 G 5 G 6 G C-o G C-o C-o C-o C-o C-o C-i", eightLines, onLine 3),
    ("3 G 5 G 6 G C-o G C-o C-o C-o C-o C-o C-i C-i", eightLines, onLine 6),
    ("3 G 5 G 6 G C-o G C-o C-o C-o C-o C-o C-i C-i C-i", eightLines, onLine 5),
    ("3 G 5 G 6 G C-o G C-o C-o C-o C-o C-o C-i C-i C-i C-i", eightLines, onLine 8),
    ("3 G 5 G 6 G C-o G C-o C-o C-o C-o C-o C-i C-i C-i C-i C-i", eightLines, onLine 8),
    -- An entry follows a line inserted above it, and one opened right at it.
    ("g g O x <Escape> C-o", "r0\nr1\nr2\nr|3\nr4", "x\nr0\nr1\nr2\nr|3\nr4"),
    ("G k O x <Escape> C-o", "r0\n|r1\nr2", "r0\nx\n|r1\nr2"),
    -- A jump under an operator records.
    ("/ x RET y n C-o", "|ab\nx\nx", "ab\n|x\nx")]

/-- The jump list of the view `view` of `driver`, as the offsets its entries'
markers are at, and its index; `none` when an entry is no held place. -/
def evilJumpOffsets (driver : EvilDriver) (view : ViewId := ⟨0⟩) : Option (List Nat × Nat) := do
  let window ← driver.loop.state.window? view
  let offsets ←
    window.jumps.list.entries.toList.mapM fun place =>
        match place with
        | .held _ marker => ((Marks.offsetOf marker).runModel driver.model.texts).1.toOption
        | .file .. => none
  return (offsets, window.jumps.list.index)

/-- What `evilHanded` hands a step, with the core's split
(`WindowCommands.split`) registered here under its name, as the window
commands' package registers it, so that `C-w s` splits. -/
def jumpWindowsHanded : Loop.Keys Vim.Default.scheme :=
  evilHanded (commands :=
    [(WindowCommands.splitName, fun call => do
        WindowCommands.split call
        return none)])

/-- The checks of `C-o`, `C-i` and the jump motions under the Vim scheme that
ships, on the text model. -/
def evilJumpChecks : List Check :=
  [{  name :=
        "C-o and C-i go back and forth through the jumps the jump motions record, to the exact column, as :help jumplist's example scaled to eight lines, and an entry follows the lines inserted above it"
      run := evilRows jumpRows },
    { name := "a search that fails records no jump, and a motion that is no jump records none"
      run :=
        return ((evilDriver "a|b\nc").map fun driver => evilJumpOffsets (evilFed driver "/ z RET")) ==
              some (some ([], 0)) &&
            ((evilDriver "|a\nb\nc").map fun driver => evilJumpOffsets (evilFed driver "j w")) ==
              some (some ([], 0)) },
    { name := "the jumps G records are entries of the list, and C-o records the cursor's place first"
      run :=
        return ((evilDriver "a\n|b\nc").map fun driver => evilJumpOffsets (evilFed driver "G")) ==
              some (some ([2], 1)) &&
            ((evilDriver "a\n|b\nc").map fun driver => evilJumpOffsets (evilFed driver "G C-o")) ==
              some (some ([2, 4], 0)) },
    { name :=
        "a split copies the jump list to the new window, and each window then moves through its own"
      run :=
        return ((evilDriver "|1\n2\n3\n4\n5" jumpWindowsHanded).map fun driver =>
              let split := evilFed driver "3 G 5 G C-w s"
              let moved := evilFed split "C-o"
              let focused := moved.loop.state.frame.focused
              let other := if focused == ⟨0⟩ then (⟨1⟩ : ViewId) else ⟨0⟩
              (evilJumpOffsets split ⟨0⟩ == evilJumpOffsets split ⟨1⟩ &&
                  evilJumpOffsets split ⟨0⟩ == some ([0, 4], 2),
                evilJumpOffsets moved focused, evilJumpOffsets moved other,
                evilShown moved focused)) ==
            some (true, some ([0, 4, 8], 1), some ([0, 4], 2), "1\n2\n|3\n4\n5") }]

end EvilTest
