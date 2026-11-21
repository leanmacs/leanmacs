import Editor.ProjectSearch.Run
import Editor.WorkingSet.Compiled
import ModelTest.Check
import ModelTest.Support.Evil
import ModelTest.Support.Excerpt
import ModelTest.Support.WorkingSet

/-!
# Model tests: `Editor/WorkingSet/Run.lean`

The model tests of `Editor/WorkingSet/Run.lean`: `workingSetRunChecks`, on the
loop's driver over the editor's models and the job model, with evil's keys. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open WorkingSetTest

namespace WorkingSetRunTest

/-- A driver of the checks with the working sets' commands, mode and jobs,
and `a.txt` open in its window. -/
def withA : Option EvilDriver :=
  (driverWith WorkingSet.package.registered.commands WorkingSet.package.registered.modes
        WorkingSet.package.registered.jobs).map
    (opened · "a.txt")

/-- The name of the buffer of the set `name` of the workspace of the
checks. -/
def setBuffer (name : String) : String :=
  WorkingSet.bufferName name "r@main"

/-- The name of the buffer the view 0 of `driver` shows. -/
def shown (driver : EvilDriver) : Option String := do
  let state := driver.loop.state
  let window ← state.window? ⟨0⟩
  return (← state.buffer? window.buffer).name

/-- The headers of the entries of the buffer called `name` that are not
empty. -/
def headersOf (driver : EvilDriver) (name : String) : Array String :=
  (((excerptBufferNamed driver name).bind (·.excerpts)).map fun excerpts =>
        (excerpts.entries.map (·.header)).filter (!·.isEmpty)).getD
    #[]

/-- `driver` once `command` is invoked with `arguments` and everything it
starts is settled. -/
def ran (driver : EvilDriver) (command : String) (arguments : List Argument := []) : EvilDriver :=
  drained (invoked driver command arguments)

/-- `driver` once its window's rows 2 and 3 of `a.txt` are selected
linewise and added to `demo`, the selection still there. -/
def addedDemo (driver : EvilDriver) : EvilDriver :=
  ran (evilFed driver "j V j") WorkingSet.addName [.str "demo"]

/-- `driver` once a search of `needle` has run and settled, its results
shown. -/
def searched (driver : EvilDriver) : EvilDriver :=
  ran driver ProjectSearch.name [.str "needle"]

end WorkingSetRunTest

open WorkingSetRunTest in
/-- The checks of `working-set-add` and `working-set-open`
(`Editor/WorkingSet/Run.lean`), on the loop's driver over the models: the
first acceptance criterion of navigation-and-windows phase 5. -/
def workingSetRunChecks : List Check :=
  [{  name :=
        "criterion 1 (a): V over rows 2 and 3 of a.txt, working-set-add demo and working-set-open demo show the set's buffer in the window, its text the two rows under the header a.txt:2"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let added := addedDemo driver
            let shownSet := ran (evilFed added "<Escape>") WorkingSet.openName [.str "demo"]
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
            let shownSet :=
              ran (evilFed (addedDemo driver) "<Escape>") WorkingSet.openName [.str "demo"]
            let typedIn := evilFed shownSet "i x <Escape>"
            let visited := evilFed typedIn "RET"
            let back := evilFed visited "C-o"
            excerptRead typedIn "a.txt" ==
                some "alpha one\nxbravo two\ncharlie three\ndelta four\necho five\nfoxtrot six\n" &&
              shown visited == some "a.txt" &&
              evilShown visited ==
                "alpha one\n|xbravo two\ncharlie three\ndelta four\necho five\nfoxtrot six\n" &&
              shown back == some (setBuffer "demo") },
    { name :=
        "criterion 1 (b): a row of project search's results added to pins records b.txt's range and line, not the results', and working-set-open pins shows that row of b.txt under b.txt:3"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let results := searched driver
            let pinned := ran (evilFed results "j j") WorkingSet.addName [.str "pins"]
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
            let refused := ran (evilFed results "V G") WorkingSet.addName [.str "pins"]
            refused.loop.state.echo == WorkingSet.spansTwoFiles &&
              (rangesOf refused "pins").isEmpty },
    { name := "criterion 1 (d): a cursor's add takes its whole row, with its line break"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let added := ran (evilFed driver "3 j") WorkingSet.addName [.str "solo"]
            (rangesOf added "solo").map (fun range => (range.stored.quote, range.stored.start)) ==
              #[("delta four\n", ⟨4, 1⟩)] },
    { name := "criterion 1 (e): adding the same range twice says already in demo and adds nothing"
      run :=
        pure <|
          match withA with
          | none => false
          | some driver =>
            let twice := addedDemo (evilFed (addedDemo driver) "<Escape> g g")
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
              evilFed (ran (evilFed first "<Escape> g g j j V j") WorkingSet.addName [.str "demo"])
                "<Escape>"
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
              ran (evilFed (addedDemo driver) "<Escape> 4 G") WorkingSet.addName [.str "other"]
            let asked := ran (evilFed other "g g") WorkingSet.addName
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
            let shownSet :=
              ran (evilFed (addedDemo driver) "<Escape>") WorkingSet.openName [.str "demo"]
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
            let first := evilFed (addedDemo driver) "<Escape>"
            let second :=
              evilFed (ran (evilFed first "g g j j V j") WorkingSet.addName [.str "demo"])
                "<Escape>"
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
            let added := ran (evilFed driver "2 j") WorkingSet.addName [.str "demo"]
            let gone := closed added "a.txt"
            let cut :=
              onDisk gone "a.txt" "alpha one\nbravo two\ndelta four\necho five\nfoxtrot six\n"
            let shownSet := ran (opened cut "b.txt") WorkingSet.openName [.str "demo"]
            let typedBack :=
              evilFed (opened shownSet "a.txt") s!"2 G o {typed "charlie three"} <Escape>"
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
            let added := ran (evilFed driver "2 j") WorkingSet.addName [.str "demo"]
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
            let none_ :=
              ran (evilFed (addedDemo driver) "<Escape>") WorkingSet.openName [.str "nope"]
            none_.loop.state.echo == WorkingSet.noSuchSet "nope" "r@main" &&
              (none_.loop.state.findBuffer (setBuffer "nope")).isNone }]

end ModelTest
