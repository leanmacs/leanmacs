import Editor.InputScheme.Test
import Editor.Loop.Driver
import Editor.Process
import Editor.State
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Shell
import Editor.Test.Workspace
import Editor.VersionControl.Show
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.VersionControl
import VcApi
import VcApiTest.Contract
import VcApiTest.Fake

/-!
# Model tests: `Editor/VersionControl/Show.lean`

The model tests of `Editor/VersionControl/Show.lean`: `revisionBufferChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The repository of the revision buffer checks: `src/a.lean` holds `a` in
`HEAD` and the working tree, and `old` at the tag `v1`. -/
def showRepository : VersionControl.Model.Repository :=
  { VersionControlContract.clean #[("src/a.lean", "a")] with
    revisions := #[("v1", #[("src/a.lean", "old\n")])] }

/-- The driver of the revision buffer checks: the status buffer checks' over
`showRepository`, whose git says `HEAD` has no `nope.txt`, with `/r/src/a.lean`
open and settled in view 0. -/
def showDriver : Option TestDriver :=
  (statusDriverOf showRepository (missing := #[("HEAD", "nope.txt")])).map (settledAfter · "C-o a")

/-- The checks of `vc-show` (`Editor/VersionControl/Show.lean`), on the loop's
driver over the editor's models, the job model and the model of a
repository in `/r`. -/
def revisionBufferChecks : List Check :=
  let revisionAsked (command : Process.Command) : Bool :=
    command.arguments[0]? == some "rev-parse" && command.arguments.contains "--verify"
  [{  name :=
        "criterion 2: vc-show v1 src/a.lean opens a read-only buffer src/a.lean@v1 holding v1's content, with no file, in the workspace /r, focused"
      run :=
        pure <|
          match showDriver with
          | none => false
          | some driver =>
            let asking := (fedTo driver (presses "C-v w")).1
            let shown := settledAfter driver "C-v w"
            let state := shown.loop.state
            asking.pending.map (fun job => (job.name, job.key)) ==
                #[(VersionControl.showJob, some "vc-show local /r v1:src/a.lean")] &&
              match state.findBuffer "src/a.lean@v1" with
              | none => false
              | some id =>
                (state.buffer? id).map (·.readOnly) == some true &&
                  ((state.buffer? id).bind (·.file)).isNone &&
                  (state.workspaceOf? id).map (·.1.location) == some (.local "/r") &&
                  (showingFocused shown).map (·.id) == some id &&
                  namedText shown "src/a.lean@v1" == some "old\n" },
    { name := "vc-show with no text opens the focused buffer's file at HEAD"
      run :=
        pure <|
          match showDriver with
          | none => false
          | some driver =>
            let shown := settledAfter driver "C-v h"
            namedText shown "src/a.lean@HEAD" == some "a" &&
              (showingFocused shown).map (·.buffer.name) == some "src/a.lean@HEAD" },
    { name := "vc-show of a path the revision lacks says so, and makes no buffer"
      run :=
        pure <|
          match showDriver with
          | none => false
          | some driver =>
            let shown := settledAfter driver "C-v n"
            echoOf shown == some "vc-show: nope.txt is not in HEAD" &&
              (shown.loop.state.findBuffer "nope.txt@HEAD").isNone },
    { name := "vc-show of a revision that starts with - is refused before any job runs"
      run :=
        pure <|
          match showDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-v x")
            echoOf asked == some "vc-show: -x is not a revision" && asked.pending.isEmpty &&
              (gitStarted asked).all (!revisionAsked ·) },
    { name := "vc-show in a buffer with no workspace says so, and starts no job"
      run :=
        pure <|
          match statusDriverOf showRepository with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-v w")
            echoOf asked == some s!"vc-show: {EditorState.scratchName} has no workspace" &&
              asked.pending.isEmpty }]

end ModelTest
