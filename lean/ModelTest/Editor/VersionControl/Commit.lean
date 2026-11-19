import Editor.Config.Packages
import Editor.Event
import Editor.InputScheme.Test
import Editor.Job.Model
import Editor.Loop
import Editor.Loop.Driver
import Editor.Mode
import Editor.Process
import Editor.Process.Model
import Editor.Role
import Editor.State
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Keys
import Editor.Test.Shell
import Editor.Test.Workspace
import Editor.VersionControl
import Editor.VersionControl.Commit
import Editor.VersionControl.Compiled
import Editor.VersionControl.Git
import Editor.VersionControl.Model
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.Git
import ModelTest.Support.VersionControl

/-!
# Model tests: `Editor/VersionControl/Commit.lean`

The model tests of `Editor/VersionControl/Commit.lean`: `commitBufferChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The message `C-v m` types in the hunk and message buffer checks. -/
def stagingMessage : String :=
  "Subject line\n\n# kept, as git's own cleanup keeps it\n"

/-- The name of the message buffer of `/r`. -/
def messageBufferName : String :=
  "*vc-commit: r@main*"

/-- The name of the output buffer of `/r`. -/
def outputBufferName : String :=
  "*vc-commit-output: r@main*"

/-- The repository of the message buffer checks: `src/a.lean` with a staged
change, and `hook` as its pre-commit hook. -/
def committingRepository (hook : Option String := none) : VersionControl.Model.Repository :=
  { committed := #[("src/a.lean", "one\n")], index := #[("src/a.lean", .file "two\n")]
    worktree := #[("src/a.lean", "two\n")], hook }

/-- `driver` with `src/a.lean` open, and its message buffer open over it,
settled. -/
def messageOpen (driver : TestDriver) : TestDriver :=
  settledAfter (settledAfter driver "C-o a") "C-v c"

/-- The checks of the message buffer (`Editor/VersionControl/Commit.lean`),
on the loop's driver over the editor's models, the job model and the model
of a repository in `/r`. -/
def commitBufferChecks : List Check :=
  let buffers (driver : TestDriver) (lead : String) : Nat :=
    ((driver.loop.state.buffers.filterMap id).filter (·.name.startsWith lead)).size
  [{  name :=
        "vc-commit opens *vc-commit: r@main*: empty, editable, with no file, in the mode vc-commit, of the workspace /r, focused; asked again, it shows that buffer and makes no other"
      run :=
        pure <|
          match stagingDriverOf (committingRepository) with
          | none => false
          | some driver =>
            let opened := messageOpen driver
            let again := settledAfter (settledAfter opened "C-o a") "C-v c"
            let state := opened.loop.state
            match state.findBuffer messageBufferName with
            | none => false
            | some id =>
              (state.buffer? id).map (·.readOnly) == some false &&
                ((state.buffer? id).bind (·.file)).isNone &&
                (state.buffer? id).bind (·.major) == some VersionControl.commitModeName &&
                (state.workspaceOf? id).map (·.1.location) == some (.local "/r") &&
                (showingFocused opened).map (·.id) == some id &&
                namedText opened messageBufferName == some "" &&
                (showingFocused again).map (·.id) == some id &&
                buffers again "*vc-commit" == 1 },
    { name :=
        "criterion 2 on the models: vc-commit-accept feeds git commit --file=- exactly the buffer's text, closes the message buffer and says it committed, by the message's first line"
      run :=
        pure <|
          match stagingDriverOf (committingRepository) with
          | none => false
          | some driver =>
            let accepted := settledAfter (messageOpen driver) "C-v m C-v y"
            accepted.jobs.processes.fed == #[(gitCommitRun, stagingMessage.toUTF8)] &&
              (accepted.loop.state.findBuffer messageBufferName).isNone &&
              echoOf accepted == some "vc-commit: committed Subject line" &&
              (showingFocused accepted).map (·.buffer.name) == some "a.lean" },
    { name :=
        "criterion 3 on the models: a commit the hook refuses writes everything git printed into *vc-commit-output: r@main*, read-only, shown without the focus, and keeps the message buffer with its text"
      run :=
        pure <|
          match
            stagingDriverOf (committingRepository (some "no on its output\nno on its error\n")) with
          | none => false
          | some driver =>
            let refused := settledAfter (messageOpen driver) "C-v m C-v y"
            let state := refused.loop.state
            match state.findBuffer outputBufferName with
            | none => false
            | some output =>
              namedText refused outputBufferName == some "no on its output\nno on its error" &&
                (state.buffer? output).map (·.readOnly) == some true &&
                state.windows.any (·.buffer == output) &&
                (showingFocused refused).map (·.buffer.name) == some messageBufferName &&
                namedText refused messageBufferName == some stagingMessage &&
                echoOf refused ==
                  some
                    "vc-commit: exited with status 1: no on its output (output in *vc-commit-output: r@main*)" },
    { name := "a second refusal writes the same output buffer again, in place of its text"
      run :=
        pure <|
          match stagingDriverOf (committingRepository (some "no\n")) with
          | none => false
          | some driver =>
            let twice := settledAfter (settledAfter (messageOpen driver) "C-v m C-v y") "C-v y"
            buffers twice "*vc-commit-output" == 1 &&
              namedText twice outputBufferName == some "no" },
    { name :=
        "accepting while a commit runs says so and starts no second; a message edited while it ran is kept, and said so"
      run :=
        pure <|
          match stagingDriverOf (committingRepository) with
          | none => false
          | some driver =>
            let (asked, _) := fedTo (settledAfter (messageOpen driver) "C-v m") (presses "C-v y")
            let (again, _) := fedTo asked (presses "C-v y")
            let (edited, _) := fedTo again (presses "C-v n")
            let landed := finishNamed edited VersionControl.commitJob
            echoOf again == some "vc-commit-accept: a commit is running" &&
              (again.pending.filter (·.name == VersionControl.commitJob)).size == 1 &&
              namedText landed messageBufferName == some "edited\n" &&
              echoOf landed ==
                some
                  "vc-commit: committed Subject line; the message buffer was edited since, and is kept" },
    { name :=
        "vc-commit-abort while a commit runs says so and keeps the message buffer with its text; the commit then closes it"
      run :=
        pure <|
          match stagingDriverOf (committingRepository) with
          | none => false
          | some driver =>
            let (asked, _) := fedTo (settledAfter (messageOpen driver) "C-v m") (presses "C-v y")
            let (aborted, _) := fedTo asked (presses "C-v q")
            let landed := settledOn (finishNamed aborted VersionControl.commitJob) []
            echoOf aborted == some "vc-commit-abort: a commit is running" &&
              namedText aborted messageBufferName == some stagingMessage &&
              aborted.pending.map (·.name) == #[VersionControl.commitJob] &&
              (landed.loop.state.findBuffer messageBufferName).isNone &&
              echoOf landed == some "vc-commit: committed Subject line" },
    { name :=
        "a commit git could not run is said in the echo area alone: no output buffer is made, and the message buffer is kept with its text"
      run :=
        pure <|
          match stagingDriverOf (committingRepository) with
          | none => false
          | some driver =>
            let failing :=
              withScript driver { command := gitCommitRun, reply := .error (.notFound "git") }
            let refused := settledAfter (messageOpen failing) "C-v m C-v y"
            echoOf refused ==
                some
                  s!"vc-commit: {(VersionControl.Error.couldNotRun (.notFound "git")).describe}" &&
              buffers refused "*vc-commit-output" == 0 &&
              namedText refused messageBufferName == some stagingMessage },
    { name := "a commit made with the workspace's status buffer kept reads the status again into it"
      run :=
        pure <|
          match stagingDriverOf (committingRepository) with
          | none => false
          | some driver =>
            let shown := settledAfter (settledAfter driver "C-o a") "C-v s"
            let committed := settledAfter (messageOpen shown) "C-v m C-v y"
            let statusRead := gitRun VersionControl.Git.statusArguments
            echoOf committed == some "vc-commit: committed Subject line" &&
              (gitStarted committed).back? == some statusRead &&
              ((gitStarted committed).filter (· == statusRead)).size == 2 },
    { name :=
        "vc-commit-abort closes the message buffer, and the next vc-commit makes a new one; accept and abort outside a message buffer say it is not one; vc-commit with no workspace says so"
      run :=
        pure <|
          match stagingDriverOf (committingRepository) with
          | none => false
          | some driver =>
            let opened := messageOpen driver
            let aborted := settledAfter opened "C-v q"
            let reopened := settledAfter (settledAfter aborted "C-o a") "C-v c"
            let outside := settledAfter (settledAfter driver "C-o a") "C-v y"
            let outsideAbort := settledAfter (settledAfter driver "C-o a") "C-v q"
            let bare := settledAfter driver "C-v c"
            (aborted.loop.state.findBuffer messageBufferName).isNone &&
              (showingFocused aborted).map (·.buffer.name) == some "a.lean" &&
              (reopened.loop.state.findBuffer messageBufferName).isSome &&
              echoOf outside == some "vc-commit-accept: a.lean is not a commit message buffer" &&
              echoOf outsideAbort ==
                some "vc-commit-abort: a.lean is not a commit message buffer" &&
              echoOf bare == some s!"vc-commit: {EditorState.scratchName} has no workspace" },
    { name :=
        "the vc-commit mode has no role and the leader suffixes c, accept, and k, abort, and is registered with the status buffer's mode, the worktree list's, the review buffer's, the log buffer's and the blame buffer's"
      run :=
        pure <|
          VersionControl.commitMode.name == "vc-commit" && VersionControl.commitMode.roles == [] &&
            VersionControl.commitMode.locals ==
              [("c", VersionControl.acceptName), ("k", VersionControl.abortName)] &&
            VersionControl.commitMode.problems == [] &&
            VersionControl.package.registered.modes.map (·.name) ==
              #["vc-status", "vc-commit", "vc-worktrees", "vc-review", "vc-log", "vc-blame"] }]

end ModelTest
