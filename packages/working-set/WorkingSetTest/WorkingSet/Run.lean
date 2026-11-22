import Editor.Test.Driver
import Editor.Test.Editing
import Editor.Test.Excerpt
import WorkingSet.Compiled
import WorkingSetTest.Check
import WorkingSetTest.Support.WorkingSet

/-!
# Model tests: `WorkingSet/Run.lean`

The model tests of `WorkingSet/Run.lean`: `workingSetRunChecks`, on the
loop's driver over the editor's models and the job model, with the kit's
editing keys on the test scheme (`WorkingSetTest/Support/WorkingSet.lean`).
The test driver's root, `WorkingSetTest/Model.lean`, runs them; its module
doc says what each shows.
-/

namespace WorkingSetTest

open Editor
open Editor.Test
open WorkingSetTest.Support

namespace WorkingSetRunTest

/-- A driver of the checks with the working sets' commands, mode and jobs,
and `a.txt` open in its window. -/
def withA : Option TestDriver :=
  (driverWith WorkingSet.package.registered.commands WorkingSet.package.registered.modes
        WorkingSet.package.registered.jobs).map
    (opened · "a.txt")

/-- The name of the buffer of the set `name` of the workspace of the
checks. -/
def setBuffer (name : String) : String :=
  WorkingSet.bufferName name "r@main"

/-- The name of the buffer the view 0 of `driver` shows. -/
def shown (driver : TestDriver) : Option String := do
  let state := driver.loop.state
  let window ← state.window? ⟨0⟩
  return (← state.buffer? window.buffer).name

/-- The headers of the entries of the buffer called `name` that are not
empty. -/
def headersOf (driver : TestDriver) (name : String) : Array String :=
  (((excerptBufferNamed driver name).bind (·.excerpts)).map fun excerpts =>
        (excerpts.entries.map (·.header)).filter (!·.isEmpty)).getD
    #[]

/-- `driver` once `command` is invoked with `arguments` and everything it
starts is settled. -/
def ran (driver : TestDriver) (command : String) (arguments : List Argument := []) : TestDriver :=
  drained (invoked driver command arguments)

/-- `driver` once its window's rows 2 and 3 of `a.txt` are selected
linewise and added to `demo`, the selection still there. -/
def addedDemo (driver : TestDriver) : TestDriver :=
  ran (keysFed driver s!"<ArrowDown> {selectRows 2}") WorkingSet.addName [.str "demo"]

/-- `driver` once `b.txt` and `c.txt`, each holding a match of `needle`, are
open and the kit's stand-in for a project search's results is shown: an
excerpt buffer of the two files' texts, `b.txt`'s first
(`Editor.Test.excerptFiles`), its cursor at its start, as a search of
`needle` shows its results. -/
def searched (driver : TestDriver) : TestDriver :=
  ran (opened (opened driver "b.txt") "c.txt") excerptFilesName [.str "b.txt", .str "c.txt"]

end WorkingSetRunTest

open WorkingSetRunTest in
/-- The checks of `working-set-add` and `working-set-open`
(`WorkingSet/Run.lean`), on the loop's driver over the models: the
first acceptance criterion of navigation-and-windows phase 5. -/
def workingSetRunChecks : List Check :=
  [{  name :=
        "criterion 1 (a): a selection of rows 2 and 3 of a.txt, working-set-add demo and working-set-open demo show the set's buffer in the window, its text the two rows under the header a.txt:2"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let added := addedDemo driver
            let shownSet := ran (keysFed added letGo) WorkingSet.openName [.str "demo"]
            added.loop.state.echo == s!"demo: added a.txt:2; {WorkingSet.memoryOnlySentence}" &&
              shown shownSet == some (setBuffer "demo") &&
              excerptRead shownSet (setBuffer "demo") == some "bravo two\ncharlie three\n" &&
              headersOf shownSet (setBuffer "demo") == #["a.txt:2"] &&
              shownSet.loop.state.echo == "demo: 1 ranges, 0 drifted" &&
              ((excerptBufferNamed shownSet (setBuffer "demo")).bind (·.major)) ==
                some WorkingSet.modeName },
    { name :=
        "criterion 1 (a): an x typed in the set's buffer is typed in a.txt's, RET shows a.txt at that row and C-o returns to the set"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let shownSet := ran (keysFed (addedDemo driver) letGo) WorkingSet.openName [.str "demo"]
            let typedIn := keysFed shownSet "x <ArrowLeft>"
            let visited := keysFed typedIn "RET"
            let back := keysFed visited "C-o"
            excerptRead typedIn "a.txt" ==
                some "alpha one\nxbravo two\ncharlie three\ndelta four\necho five\nfoxtrot six\n" &&
              shown visited == some "a.txt" &&
              shownOf visited ==
                "alpha one\n|xbravo two\ncharlie three\ndelta four\necho five\nfoxtrot six\n" &&
              shown back == some (setBuffer "demo") },
    { name :=
        "criterion 1 (b): a row of a search's results (the kit's stand-in, an excerpt buffer of b.txt and c.txt) added to pins records b.txt's range and line, not the results', and working-set-open pins shows that row of b.txt under b.txt:3"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let results := searched driver
            let pinned := ran (keysFed results (down 2)) WorkingSet.addName [.str "pins"]
            let shownSet := ran pinned WorkingSet.openName [.str "pins"]
            (rangesOf pinned "pins").map (fun range => (range.stored.path, range.stored.start)) ==
                #[("b.txt", ⟨3, 1⟩)] &&
              (rangesOf pinned "pins").map (·.stored.quote) == #["the needle here\n"] &&
              excerptRead shownSet (setBuffer "pins") == some "the needle here\n" &&
              headersOf shownSet (setBuffer "pins") == #["b.txt:3"] },
    { name :=
        "criterion 1 (c): a visual selection across two files' excerpts of the results is refused, saying so, and nothing is added"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let results := searched driver
            let refused := ran (keysFed results (selectRows 8)) WorkingSet.addName [.str "pins"]
            refused.loop.state.echo == WorkingSet.spansTwoFiles &&
              (rangesOf refused "pins").isEmpty },
    { name := "criterion 1 (d): a cursor's add takes its whole row, with its line break"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let added := ran (keysFed driver (down 3)) WorkingSet.addName [.str "solo"]
            (rangesOf added "solo").map (fun range => (range.stored.quote, range.stored.start)) ==
              #[("delta four\n", ⟨4, 1⟩)] },
    { name := "criterion 1 (e): adding the same range twice says already in demo and adds nothing"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let twice := addedDemo (keysFed (addedDemo driver) s!"{letGo} C-<Home>")
            twice.loop.state.echo == "already in demo" && (rangesOf twice "demo").size == 1 },
    { name :=
        "criterion 1 (f): two ranges on overlapping rows of one file are one excerpt, headed by the first row's line"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let first := addedDemo driver
            let second :=
              keysFed
                (ran (keysFed first s!"{letGo} C-<Home> {down 2} {selectRows 2}") WorkingSet.addName
                  [.str "demo"])
                letGo
            let shownSet := ran second WorkingSet.openName [.str "demo"]
            (rangesOf second "demo").size == 2 &&
              excerptRead shownSet (setBuffer "demo") ==
                some "bravo two\ncharlie three\ndelta four\n" &&
              headersOf shownSet (setBuffer "demo") == #["a.txt:2"] },
    { name :=
        "working-set-add with no name asks with the prompt of the file's workspace, its sets the last used first, and the answer adds what was selected"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let other :=
              ran (keysFed (addedDemo driver) s!"{letGo} {toLine 4}") WorkingSet.addName
                [.str "other"]
            let asked := ran (keysFed other "C-<Home>") WorkingSet.addName
            let index := ((asked.loop.state.findFile "/r/a.txt").map (·.index)).getD 0
            let answered :=
              ran asked WorkingSet.addName [.str "demo", .bool true, .nat index, .nat 0, .nat 10]
            asked.loop.state.prompt.map (·.label) == some (WorkingSet.addPrompt "r@main") &&
              WorkingSet.namesOf (kept other) == #["other", "demo"] &&
              (rangesOf answered "demo").map (·.stored.quote) ==
                #["bravo two\ncharlie three\n", "alpha one\n"] },
    { name :=
        "working-set-remove drops the range under the cursor from the set and its excerpt from the buffer, and the set left empty is still listed"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let shownSet := ran (keysFed (addedDemo driver) letGo) WorkingSet.openName [.str "demo"]
            let removed := ran shownSet WorkingSet.removeName
            (rangesOf removed "demo").isEmpty &&
              excerptRead removed (setBuffer "demo") == some "" &&
              WorkingSet.namesOf (kept removed) == #["demo"] &&
              removed.loop.state.echo == "demo: removed a.txt:2" },
    { name :=
        "working-set-note asks with the range's note, and the answer is the stored note and its excerpt's header; two ranges in one excerpt each keep their own"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let first := keysFed (addedDemo driver) letGo
            let second :=
              keysFed
                (ran (keysFed first s!"C-<Home> {down 2} {selectRows 2}") WorkingSet.addName
                  [.str "demo"])
                letGo
            let shownSet := ran second WorkingSet.openName [.str "demo"]
            let asked := ran shownSet WorkingSet.noteName
            let one := ran shownSet WorkingSet.noteName [.str "one", .bool true, .nat 0]
            let two := ran one WorkingSet.noteName [.str "two", .bool true, .nat 1]
            asked.loop.state.prompt.map (·.label) == some "Note: " &&
              (rangesOf two "demo").map (·.stored.note) == #["one", "two"] &&
              headersOf two (setBuffer "demo") == #["a.txt:2 · one · two"] &&
              excerptRead two (setBuffer "demo") == some "bravo two\ncharlie three\ndelta four\n" },
    { name :=
        "working-set-refresh after a drifted range's text is put back in its file's buffer finds it again: placed, under its line"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let added := ran (keysFed driver (down 2)) WorkingSet.addName [.str "demo"]
            let gone := closed added "a.txt"
            let cut :=
              onDisk gone "a.txt" "alpha one\nbravo two\ndelta four\necho five\nfoxtrot six\n"
            let shownSet := ran (opened cut "b.txt") WorkingSet.openName [.str "demo"]
            let typedBack :=
              keysFed (opened shownSet "a.txt") s!"{toLine 2} <End> RET {typed "charlie three"}"
            let back := ran typedBack BuffersApi.switchName [.str (setBuffer "demo")]
            let refreshed := ran back WorkingSet.refreshName
            (rangesOf shownSet "demo").map (·.hold) == #[.drifted] &&
              shown back == some (setBuffer "demo") &&
              headersOf refreshed (setBuffer "demo") == #["a.txt:3"] &&
              excerptRead refreshed (setBuffer "demo") == some "charlie three\n" &&
              refreshed.loop.state.echo == "demo: 1 ranges, 0 drifted" },
    { name :=
        "with no files implementation registered, working-set-open of a set whose file is open nowhere leaves the file unloaded, and its range drifted as for a refused load"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let added := ran (keysFed driver (down 2)) WorkingSet.addName [.str "demo"]
            let gone := opened (closed added "a.txt") "b.txt"
            let bare := { gone with keys := Test.withoutExtension FilesApi.Files gone.keys }
            let shownSet := ran bare WorkingSet.openName [.str "demo"]
            (rangesOf gone "demo").map (·.hold) == #[.detached] &&
              (shownSet.loop.state.findBuffer "a.txt").isNone &&
              (rangesOf shownSet "demo").map (·.hold) == #[.drifted] &&
              shownSet.loop.state.echo == "demo: 1 ranges, 1 drifted" },
    { name := "working-set-open of a name the workspace has no set of says so, and opens nothing"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let none_ := ran (keysFed (addedDemo driver) letGo) WorkingSet.openName [.str "nope"]
            none_.loop.state.echo == WorkingSet.noSuchSet "nope" "r@main" &&
              (none_.loop.state.findBuffer (setBuffer "nope")).isNone }]

end WorkingSetTest
