import Editor.Buffers.Compiled
import Editor.Files.Compiled
import ModelTest.Check
import ModelTest.Support.Driver
import ModelTest.Support.Evil
import ModelTest.Support.Jumps

/-!
# Model tests: `Editor/Evil/Marks.lean`

The model tests of `Editor/Evil/Marks.lean`: `evilMarkChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The rows of the mark checks, as `evilRows` reads them: the keys, the text
before with the cursor as a bar, and the text after, or what the echo area
says. -/
def markRows : List (String × String × String) :=
  [ -- ` goes to the exact position, ' to the line's first non-blank.
    ("m a G ` a", "ab\n  c|d\ne", "ab\n  c|d\ne"), ("m a G ' a", "ab\n  c|d\ne", "ab\n  |cd\ne"),
    -- Setting a mark is no jump; going to one is.
    ("m a j C-o", "|a\nb", "a\n|b"), ("m a G ` a C-o", "a|b\nc\nd", "ab\nc\n|d"),
    -- Under an operator ` is exclusive and ' takes whole lines.
    ("m a w w d ` a", "|ab cd ef", "|ef"), ("m a j d ' a", "a|b\ncd\nef", "|ef"),
    -- A mark follows a line inserted above it.
    ("m a g g O x <Escape> ` a", "ab\nc|d", "x\nab\nc|d"),
    -- A mark not set, a character that names none, and m with one.
    ("` b", "a|b", Evil.markNotSet), ("' b", "a|b", Evil.markNotSet),
    ("` 1", "a|b", Evil.unknownMark), ("m 1", "a|b", Evil.badMarkName),
    ("` `", "a|b", Evil.markNotSet),
    -- '' and `` go back and forth; m ' sets the previous-context mark and
    -- records a jump.
    ("G ` `", "a|b\nc\nd", "a|b\nc\nd"), ("G ` ` ` `", "a|b\nc\nd", "ab\nc\n|d"),
    ("G ' '", "  a|b\nc\nd", "  |ab\nc\nd"), ("m ' j ` `", "a|b\nc\nd", "a|b\nc\nd"),
    ("m ' j C-o", "a|b\nc", "a|b\nc")]

/-- The rows of the checks of marks across line deletions and undo, as
`evilRows` reads them. -/
def markUndoRows : List (String × String × String) :=
  [ -- A lowercase mark whose line is deleted is erased, on the last line
    -- too. A global mark stays, on the line that takes the deleted one's
    -- place.
    ("m a d d ` a", "ab\nc|d\nef", Evil.markNotSet), ("m a d d ` a", "ab\nc|d", Evil.markNotSet),
    ("m A d d g g ' A", "ab\nc|d\nef", "ab\n|ef"),
    ("j m A g g 3 d d ' A", "|ab\ncd\nef\ngh", "|gh"),
    ("m a j d k ` a", "ab\nc|d\nef\ngh", Evil.markNotSet),
    -- A deletion of part of its line keeps it, the column where the
    -- deletion left it; a deletion of another line keeps it.
    ("m a 0 d w G ` a", "ab\nc|d ef\ngh", "ab\n|ef\ngh"),
    ("m a 0 d $ G ` a", "ab\nc|d\nef", "ab\n|\nef"), ("m a k d d ` a", "ab\nc|d\nef", "c|d\nef"),
    -- A linewise change keeps its first line, and so does a charwise
    -- delete from a line's start into a later line; a linewise delete
    -- erases the marks of every line it deletes.
    ("m a 3 c c <Escape> j ` a", "|ab\ncd\nef\ngh", "|\ngh"),
    ("m a v j d j ` a", "|ab\ncd\nef\ngh", "|d\nef\ngh"),
    ("m a j j l m b g g d ` b j ` a", "|ab\ncd\nef\ngh", "|f\ngh"),
    ("m a j m b j m c g g 3 d d ` a", "|ab\ncd\nef\ngh", Evil.markNotSet),
    ("m a j m b j m c g g 3 d d ` b", "|ab\ncd\nef\ngh", Evil.markNotSet),
    ("m a j m b j m c g g 3 d d ` c", "|ab\ncd\nef\ngh", Evil.markNotSet),
    -- The linewise delete erases the marks of the lines it deletes, the
    -- only line of a text too, which an undo puts back; the linewise change
    -- those of its lines after the first. A change of the only line, and a
    -- redo of its delete, keep its mark, as Vim's do.
    ("m a d d ` a", "a|b", Evil.markNotSet), ("m a d d u ` a", "a|b", "a|b"),
    ("m a d d u C-r ` a", "a|b", "|"), ("m a c c <Escape> ` a", "a|b", "|"),
    ("j j m a g g 3 c c <Escape> ` a", "|ab\ncd\nef\ngh", Evil.markNotSet),
    -- Undo puts a lowercase mark back on its line and column; redo erases
    -- it again, and undo puts it back again.
    ("m a d d u G ` a", "ab\nc|d\nef", "ab\nc|d\nef"),
    ("m a d d u C-r ` a", "ab\nc|d\nef", Evil.markNotSet),
    ("m a d d u C-r u G ` a", "ab\nc|d\nef", "ab\nc|d\nef"),
    -- Undo puts back the column the mark had before the step, not where
    -- the text it put back left the mark's marker.
    ("m a 0 d w u G ` a", "ab\nc|d ef\ngh", "ab\nc|d ef\ngh"),
    -- Inside an open group the boundary stays the one from before it: the
    -- step an insert session makes keeps the marks as they were before the
    -- session, those its linewise change erased and those its typing moved.
    ("j m b g g 3 c c <Escape> u ` b", "|ab\ncd\nef\ngh", "ab\n|cd\nef\ngh"),
    ("m a i x y <Escape> u G ` a", "ab\nc|def\ngh", "ab\nc|def\ngh")]

/-- The jobs of the mark checks, by name: those compiled code registers for
files. -/
def markJobs (name : String) : Option (List Argument → Work) :=
  (Files.jobs.find? (·.name == name)).map (·.work)

/-- The driver of the mark checks that cross buffers: under the Vim scheme
that ships, with the commands compiled code registers for files and
buffers, over the files of the jump checks (`jumpFiles`), from one buffer,
`scratch`, holding three lines, the cursor at the start of the second. -/
def markDriver : Option EvilDriver :=
  (Loop.Driver.over (evilHanded (Files.commands ++ Buffers.commands)) markJobs
        (evilState "s0\ns1\n  s2\n" 3) editorModel).toOption.map
    fun driver => { driver with jobs := { files := jumpFiles } }

/-- `driver` with every load it started finished. -/
def markLoaded (driver : EvilDriver) : EvilDriver :=
  (List.range 2).foldl
    (fun driver _ =>
      match driver.pending.find? (·.name == Files.loadJob) with
      | some job => (driver.finish job.id).1
      | none => driver)
    driver

/-- `driver` fed the keys `keys`, each followed by every load it started
being finished. -/
def markFed (driver : EvilDriver) (keys : String) : EvilDriver :=
  (presses keys).foldl (fun driver event => markLoaded (driver.feed { event, stamp := 0 }).1) driver

/-- `driver` once it ran `invocation`, as a command no key ran, and every
load it started was finished. -/
def markRan (driver : EvilDriver) (invocation : Invocation) : EvilDriver :=
  markLoaded (driver.stepped (driver.loop.invoke driver.handed invocation)).1

/-- The invocation that opens `jumps.txt`. -/
def openJumps : Invocation :=
  { command := Files.openName, arguments := [.str jumpsPath.toString] }

/-- The invocation that shows the buffer `scratch`. -/
def toScratch : Invocation :=
  { command := Buffers.switchName, arguments := [.str EditorState.scratchName] }

/-- The name of the buffer view 0 of `driver` shows, and what it shows, as a
fixture writes it. -/
def markSeen (driver : EvilDriver) : Option String × String :=
  ((driver.loop.state.target? ⟨0⟩).map (·.buffer.name), evilShown driver)

/-- The number of entries of the jump list of view 0 of `driver`. -/
def jumpCount (driver : EvilDriver) : Option Nat :=
  (driver.loop.state.window? ⟨0⟩).map (·.jumps.list.entries.size)

/-- What a mark motion run by the move command in view 1 of a state of two
windows leaves in each, view 0 being focused: the head of each window's
cursor. View 0 shows `scratch`, whose mark `a` is at 1, and view 1 `other`,
whose mark `a` is at 4 and whose previous-context mark is at 3. -/
def markInOtherWindow (mark : String) : Option (Nat × Nat) :=
  let start : TextM EditorState := do
    let state ← evilState "ab\ncd" 0
    let text ← createText "xy\nzw"
    let scroll ← text.mark (.anchor { offset := 0, bias := .before })
    let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩], shape := .inclusive })
    let history ← UndoTree.over text
    let mine ← (⟨0⟩ : TextId).mark (.anchor { offset := 1, bias := .after })
    let theirs ← text.mark (.anchor { offset := 4, bias := .after })
    let previous ← text.mark (.anchor { offset := 3, bias := .after })
    return {
        state with
        buffers :=
          (state.buffers.modify 0 (·.map ({ · with marks := #[('a', mine)] }))).push
            (some { name := "other", text, history, marks := #[('a', theirs)] })
        windows :=
          state.windows.push
            { id := ⟨1⟩, buffer := ⟨1⟩, scroll, selection
              jumps := { previous := some (.held ⟨1⟩ previous) } }
        frame := { state.frame with windows := #[⟨0⟩, ⟨1⟩] } }
  let head (view : ViewId) : EditorM Nat := do
    let .ok selection ← view.selection | return 99
    return (selection.ranges[selection.primary]?.map (·.head)).getD 99
  let program : EditorM (Nat × Nat) := do
    let some target := (← editorState).target? ⟨1⟩ | return (99, 99)
    Evil.move Evil.motions { target, arguments := [.str Evil.markExact.name, .str mark, .nat 0] }
    return (← head ⟨0⟩, ← head ⟨1⟩)
  (dispatchedFrom program start).map (·.1)

/-- The checks of `m`, `` ` `` and `'` under the Vim scheme that ships, on
the text model, and across buffers on the file model. -/
def evilMarkChecks : List Check :=
  [{  name :=
        "m sets a mark and ` and ' go to it, exactly and at its line's first non-blank, as jumps, exclusive and line-wise under an operator; a mark follows a line inserted above it; a mark not set, a character that names none and m with one are said; '' and `` go back and forth, and m ' sets the previous-context mark"
      run := evilRows markRows },
    { name :=
        "a lowercase mark whose line is deleted is erased and a global mark stays, and one of a line deleted in part keeps the column the deletion left; undo puts a lowercase mark back where it was before the step, and redo erases it again; the step an insert session makes keeps the marks from before the session"
      run := evilRows markUndoRows },
    { name :=
        "recorded departure (task marks-counted-undo-redo-restore): a counted undo crosses more than one edge of the undo tree and puts back no lowercase mark, so m a, dd, x elsewhere and 2u leave ` a saying E20, where Vim puts the mark back; undoing one step at a time puts it back"
      run :=
        evilRows
          [("m a d d j x 2 u ` a", "ab\nc|d\nef\ngh", Evil.markNotSet),
            ("m a d d j x u u G ` a", "ab\nc|d\nef\ngh", "ab\nc|d\nef\ngh")] },
    { name :=
        "under an operator a mark that is not set gives the operator up, saying so, with the text as it was"
      run :=
        pure <|
          ((evilDriver "a|b\ncd").map fun driver =>
              let left := evilFed driver "d ` b"
              (evilShown left, left.loop.state.echo)) ==
            some ("a|b\ncd", s!"{Vim.operateCommand}: {Evil.markNotSet}") },
    { name :=
        "a mark motion run in a window that is not the focused one reads that window's buffer's marks and its previous-context mark, and moves that window's cursor"
      run := pure (markInOtherWindow "a" == some (0, 4) && markInOtherWindow "`" == some (0, 3)) },
    { name := "a buffer's marks are its own: m a in one buffer, then ` a in another says E20"
      run :=
        pure <|
          (markDriver.map fun driver =>
              let other := markRan (markFed driver "m a") openJumps
              let tried := markFed other "` a"
              (markSeen tried, tried.loop.state.echo)) ==
            some ((some "jumps.txt", "|zero\n  one\néx two\nthree\nfour\n"), Evil.markNotSet) },
    { name :=
        "m A in one buffer, then ` A in another shows the first at the mark, as a jump: C-o returns to the other buffer"
      run :=
        pure <|
          (markDriver.map fun driver =>
              let other := markFed (markRan (markFed driver "l m A") openJumps) "j"
              let gone := markFed other "` A"
              (markSeen gone, markSeen (markFed gone "C-o"))) ==
            some
              ((some "scratch", "s0\ns|1\n  s2\n"),
                (some "jumps.txt", "zero\n|  one\néx two\nthree\nfour\n")) },
    { name := "d ' A with the mark in another buffer gives the operator up with E20"
      run :=
        pure <|
          (markDriver.map fun driver =>
              let other := markRan (markFed driver "m A") openJumps
              let tried := markFed other "d ' A"
              (markSeen tried, tried.loop.state.echo)) ==
            some
              ((some "jumps.txt", "|zero\n  one\néx two\nthree\nfour\n"),
                s!"{Vim.operateCommand}: {Evil.markNotSet}") },
    { name :=
        "after its buffer is closed, ' A reopens the mark's file at the first non-blank of its row, through the load, recording exactly one jump, where ' A was typed, which C-o returns to"
      run :=
        pure <|
          (markDriver.map fun driver =>
              let marked := markFed (markRan driver openJumps) "j l l m A"
              let closed :=
                markRan (markRan marked toScratch)
                  { command := Buffers.closeName, arguments := [.str "jumps.txt"] }
              let before := jumpCount closed
              let back := markFed closed "' A"
              (markSeen back, before.map (· + 1) == jumpCount back,
                markSeen (markFed back "C-o"))) ==
            some
              ((some "jumps.txt", "zero\n  |one\néx two\nthree\nfour\n"), true,
                (some "scratch", "|s0\ns1\n  s2\n")) },
    { name :=
        "m A, then its buffer closed and its file opened again, attaches the mark to the new buffer's text: a line inserted above it carries it down, and ` A lands on the shifted row"
      run :=
        pure <|
          (markDriver.map fun driver =>
              let marked := markFed (markRan driver openJumps) "j l l m A"
              let closed :=
                markRan (markRan marked toScratch)
                  { command := Buffers.closeName, arguments := [.str "jumps.txt"] }
              let shifted := markFed (markRan closed openJumps) "g g O x <Escape>"
              let back := markFed shifted "G ` A"
              (match shifted.loop.state.globalMark? 'A' with
                | some (.held ..) => true
                | _ => false,
                markSeen back)) ==
            some (true, (some "jumps.txt", "x\nzero\n  |one\néx two\nthree\nfour\n")) },
    { name := "m A in a buffer with no file, then that buffer closed, drops the mark: ` A says E20"
      run :=
        pure <|
          (markDriver.map fun driver =>
              let other := markRan (markFed driver "m A") openJumps
              let closed :=
                markRan other
                  { command := Buffers.closeName, arguments := [.str EditorState.scratchName] }
              let tried := markFed closed "` A"
              (closed.loop.state.globalMark? 'A', markSeen tried, tried.loop.state.echo)) ==
            some
              (none, (some "jumps.txt", "|zero\n  one\néx two\nthree\nfour\n"), Evil.markNotSet) }]

end ModelTest
