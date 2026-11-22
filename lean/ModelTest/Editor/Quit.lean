import Editor.FileJobs
import Editor.Quit
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Opener
import ModelTest.Check

/-!
# Model tests: `Editor/Quit.lean`

The model tests of `Editor/Quit.lean`: `quitChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A driver of the quit rule's checks: the file `note.txt` open in view 0
by the kit's opener (`C-o n`), and `C-l q` bound to a command registered
under the core's name (`Quit.name`) that runs the rule
(`Quit.closeRequested`); `none` if making the state was refused. -/
def quitRuleDriver : Option TestDriver :=
  let keys :=
    dispatchKeys [("C-o n", opens (inFiles "note.txt")), ("C-l q", invoke Quit.name)]
      [(FileJobs.openFileCommand, fun call => do
          Opener.openCommand call
          return none),
        (Quit.name, fun _ => do
          Quit.closeRequested
          return none)]
  (Loop.Driver.over keys Opener.jobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver =>
    ((fedTo { driver with jobs := { files := commandFiles } } (presses "C-o n")).1.finish 1).1

/-- The checks of the quit rule (`Editor/Quit.lean`). -/
def quitChecks : List Check :=
  [{  name :=
        "the quit rule asks the editor to quit, and says a refusal under the core's name: with nothing unsaved the editor leaves, and with a file's buffer that has unsaved changes it goes on and the echo area says quit: note.txt has unsaved changes"
      run :=
        pure <|
          match quitRuleDriver with
          | none => false
          | some driver =>
            let (left, _) := fedTo driver (presses "C-l q")
            let (refused, _) := fedTo driver ([.commit "x"] ++ presses "C-l q")
            Quit.name == "quit" && left.stopped && !refused.stopped &&
              echoOf refused == some (Quit.notQuitting (.unsaved "note.txt")) &&
              echoOf refused == some "quit: note.txt has unsaved changes" }]

end ModelTest
