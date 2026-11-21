import BuffersApiTest.Fake
import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.Diff.Script
import Editor.Event
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Loop
import Editor.Loop.Driver
import Editor.Process
import Editor.Process.Model
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Hosted
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Shell
import Editor.Test.Workspace
import Editor.Text
import Editor.Text.Model
import Editor.VersionControl.Compiled
import Editor.VersionControl.Git
import Editor.VersionControl.Git.Model
import Editor.VersionControl.Gutter
import Editor.Workspace
import FilesApiTest.Fake
import ModelTest.Check
import ModelTest.Support.Git
import ModelTest.Support.VersionControl
import VcApi
import VcApiTest.Contract
import VcApiTest.Fake

/-!
# Model tests: `Editor/VersionControl/Gutter.lean`

The model tests of `Editor/VersionControl/Gutter.lean`: `gutterChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The jobs of the gutter checks: the status buffer checks', and the
version-control gutter's. -/
def gutterJobs (name : String) : Option (List Argument → Work) :=
  ((VersionControl.gutterPackage.registered.jobs.find? (·.name == name)).map (·.work)) <|>
    statusJobs name

/-- The keys of the gutter checks: the workspace driver checks', with
`C-g x`, which makes the window's text `new\na\nB\nc\n`, `C-g z`, which
puts `z\n` at its start, `C-g k`, which closes the window's buffer, and
`C-g h`, which hands the window's buffer's head fetch a reply of an epoch
that is not its latest, first content and then a failure; and the gutter's
command, which its watch job posts. -/
def gutterKeys : Loop.Keys TestScheme.scheme :=
  dispatchKeys
    (workspaceBindings ++
      [("C-g x", invoke "gutter-edit"), ("C-g z", invoke "gutter-top"),
        ("C-g k", invoke BuffersApi.closeName), ("C-g h", invoke "gutter-stale-head")])
    (workspaceCommandsWith FilesApiTest.openSaveCommands ++
      dispatchedOf VersionControl.gutterPackage.registered.commands ++
      BuffersApiTest.commands ++
      [("gutter-edit", fun call => do
          let text := call.target.buffer.text
          text.replaceRange 0 (← text.byteLength) "new\na\nB\nc\n"
          return none),
        ("gutter-top", fun call => do
          call.target.buffer.text.insert 0 "z\n"
          return none),
        ("gutter-stale-head", fun call => do
          let state ← editorState
          if let some entry := state.tracked.find? (·.buffer == call.target.window.buffer) then
            let order : Gutter.HeadOrder :=
              { buffer := entry.buffer, epoch := entry.epoch + 1, root := entry.root
                git := entry.git, path := entry.path }
            VersionControl.headFetched order (.ok (some "stale\n"))
            VersionControl.headFetched order (.error (.unparsable "stale"))
          return none)])

/-- A driver of the gutter checks: the workspace driver's world, with the
gutter's keys and jobs, whose git in `/r` meets `repository`, saying `HEAD`
has no `src/b.lean`, whose watches may be made in `/r/.git`, and with each
file of `repository`'s working tree on disk under `/r`; its git the program
`git`, which the loop is told is config's (`Loop.Registered.git`), and
the finder meeting `world`; `none` if making the state was refused. -/
def gutterDriverOf (repository : VersionControl.Model.Repository) (git : String := "git")
    (world : Workspace.World := workspaceWorld) : Option TestDriver :=
  (workspaceDriver gutterJobs gutterKeys git world).map fun driver =>
    let scripts :=
      (repository.jobModel git "/r" (missing := #[("HEAD", "src/b.lean")])).processes.scripts
    let keys :=
      withExtensionsOf driver.keys
        #[worldAttachPackage world, FilesApiTest.fake, BuffersApiTest.fake]
    { driver with
      keys := { keys with registered := { keys.registered with git } }
      jobs :=
        { driver.jobs with
          files :=
            repository.worktree.foldl
              (fun (files : FileModel) (path, content) =>
                files.withFile (("/r" : System.FilePath) / path) content.toUTF8)
              driver.jobs.files
          processes :=
            { driver.jobs.processes with scripts := scripts ++ driver.jobs.processes.scripts }
          fileWatches := { driver.jobs.fileWatches with directories := #["/r/.git"] } } }

/-- `driver` with its git in `/r` meeting `repository` from now on, as after
a change made outside the editor. -/
def meeting (driver : TestDriver) (repository : VersionControl.Model.Repository) : TestDriver :=
  let scripts :=
    (repository.jobModel "git" "/r" (missing := #[("HEAD", "src/b.lean")])).processes.scripts
  { driver with
    jobs :=
      { driver.jobs with
        processes :=
          { driver.jobs.processes with scripts := scripts ++ driver.jobs.processes.scripts } } }

/-- `HEAD`'s content of `src/a.lean` in the gutter checks. -/
def gutterHead : String :=
  "a\nb\nc\nd\n"

/-- The repository of the gutter checks: `src/a.lean` the same in `HEAD`,
the index and the working tree. -/
def gutterRepository : VersionControl.Model.Repository :=
  VersionControlContract.clean #[("src/a.lean", gutterHead)]

/-- `driver` with the post its watch job holds delivered, if it holds one. -/
def postDelivered (driver : TestDriver) : TestDriver :=
  match driver.posting[0]? with
  | some job => (driver.posted job.id).1
  | none => driver

/-- The tracked entry of the buffer view 0 shows in `driver`. -/
def trackedShown (driver : TestDriver) : Option Tracked := do
  let id := (← showing driver).id
  driver.loop.state.tracked.find? (·.buffer == id)

/-- What the snapshot `snapshot` holds in `driver`'s text model. -/
def snapshotText (driver : TestDriver) (snapshot : SnapshotId) : Option String :=
  ((snapshot.read).runModel driver.model.texts).1.toOption

/-- The checks of the version-control gutter
(`Editor/VersionControl/Gutter.lean`), on the loop's driver over the
editor's models, the job model, the model of a repository in `/r` and the
model of watches, whose waiting jobs it holds parked. -/
def gutterChecks : List Check :=
  let headRun := gitRun #["rev-parse", "--verify", "--quiet", "HEAD:src/a.lean"]
  let staged : VersionControl.Model.Repository :=
    { committed := #[("src/a.lean", gutterHead)]
      index := #[("src/a.lean", .file "a\nB\nc\nd\n")]
      worktree := #[("src/a.lean", "a\nB\nc\nd\n")] }
  -- How many head fetches `driver` has run.
  let heads (driver : TestDriver) : Nat := ((gitStarted driver).filter (· == headRun)).size
  -- `driver` once `staged` is committed outside the editor, as a commit
  -- touches the git directory.
  let committing (driver : TestDriver) : TestDriver :=
    (meeting driver staged.commit).touch
      #[("/r/.git/index", .written), ("/r/.git/refs/heads/main", .written)]
  -- The epoch, staleness and fetching of the tracked entry view 0 shows.
  let fetchOf (driver : TestDriver) : Option (Nat × Bool × Bool) :=
    (trackedShown driver).map fun entry => (entry.epoch, entry.stale, entry.fetching)
  -- The command the watch job runs to ask what to watch.
  let watchRun := VersionControl.Git.command "git" "/r" VersionControl.Git.watchedArguments
  -- How many watches of `/r` `driver` has started.
  let watchReads (driver : TestDriver) : Nat :=
    (driver.jobs.processes.started.filter (· == watchRun)).size
  -- The marks of `new\na\nB\nc\n` against the committed `a\nB\nc\nd\n`.
  let againstCommit : Array GutterMark :=
    #[{ start := 0, stop := 4, text := "+", face := ⟨"diff.added"⟩ },
      { start := 10, stop := 10, text := "-", face := ⟨"diff.removed"⟩ }]
  [{  name :=
        "criterion 4: a tracked file's buffer takes its content at HEAD as its old text: its fetch runs rev-parse HEAD:src/a.lean then cat-file blob, and its tracked entry holds a snapshot of HEAD's content"
      run :=
        pure <|
          match gutterDriverOf gutterRepository with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let started := gitStarted opened
            (started.idxOf? headRun).isSome &&
              started.contains
                (gitRun #["cat-file", "blob", VersionControl.Model.blobId gutterHead]) &&
              ((trackedShown opened).bind (·.head)).bind (snapshotText opened) == some gutterHead &&
              ((showing opened).bind (·.buffer.gutter)).isSome &&
              (gutterView opened).map (·.padding.gutter) == some Buffer.Gutter.width &&
              (gutterView opened).map (·.marks) == some #[] &&
              opened.openWatches == 1 },
    { name := "a file HEAD lacks has no gutter, and its view no gutter column"
      run :=
        pure <|
          match gutterDriverOf gutterRepository with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o b"
            ((trackedShown opened).map (·.head)) == some none &&
              ((showing opened).bind (·.buffer.gutter)).isNone &&
              (gutterView opened).map (·.padding.gutter) == some 0 },
    { name :=
        "the gutter runs the git program the workspace settings name: with /opt/git registered, its head fetch and its watch of the repository run /opt/git, as the finder does, and never git"
      run :=
        pure <|
          match gutterDriverOf gutterRepository "/opt/git" with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let started := opened.jobs.processes.started
            started.contains
                (VersionControl.Git.command "/opt/git" "/r"
                  (VersionControl.Git.revisionArguments "HEAD" "src/a.lean")) &&
              started.contains
                (VersionControl.Git.command "/opt/git" "/r" VersionControl.Git.watchedArguments) &&
              !started.any (·.program == "git") &&
              (trackedShown opened).map (·.git) == some "/opt/git" &&
              ((trackedShown opened).bind (·.head)).bind (snapshotText opened) == some gutterHead &&
              opened.openWatches == 1 },
    { name :=
        "the marks of hunks: lines added are + in diff.added over them, lines changed ~ in diff.changed, and lines removed an empty - in diff.removed at the start of the line after them"
      run :=
        pure <|
          VersionControl.marksOf
              #[{ oldStart := 0, oldStop := 0, newStart := 0, newStop := 4 },
                { oldStart := 2, oldStop := 4, newStart := 6, newStop := 8 },
                { oldStart := 6, oldStop := 8, newStart := 10, newStop := 10 }] ==
            #[{ start := 0, stop := 4, text := "+", face := ⟨"diff.added"⟩ },
              { start := 6, stop := 8, text := "~", face := ⟨"diff.changed"⟩ },
              { start := 10, stop := 10, text := "-", face := ⟨"diff.removed"⟩ }] },
    { name :=
        "criterion 5: after an edit that adds a line, changes one and removes one, the view's gutter marks are + over the added line in diff.added, ~ over the changed one in diff.changed, and - at the end where the removed one was in diff.removed"
      run :=
        pure <|
          match gutterDriverOf gutterRepository with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let edited := settledAfter opened "C-g x"
            (gutterView edited).map (·.marks) ==
              some
                #[{ start := 0, stop := 4, text := "+", face := ⟨"diff.added"⟩ },
                  { start := 6, stop := 8, text := "~", face := ⟨"diff.changed"⟩ },
                  { start := 10, stop := 10, text := "-", face := ⟨"diff.removed"⟩ }] },
    { name :=
        "between an edit and its diff the marks are carried through the edit, and a second edit starts no second diff until the first lands, which starts the next"
      run :=
        pure <|
          match gutterDriverOf gutterRepository with
          | none => false
          | some driver =>
            let edited := settledAfter (settledAfter driver "C-o a") "C-g x"
            let (once, _) := fedTo edited (presses "C-g z")
            let (twice, steps) := fedTo once (presses "C-g z")
            let landed := finishNamed twice VersionControl.diffJob
            (gutterView once).map (·.marks) ==
                some
                  #[{ start := 2, stop := 6, text := "+", face := ⟨"diff.added"⟩ },
                    { start := 8, stop := 10, text := "~", face := ⟨"diff.changed"⟩ },
                    { start := 12, stop := 12, text := "-", face := ⟨"diff.removed"⟩ }] &&
              (once.pending.filter (·.name == VersionControl.diffJob)).size == 1 &&
              !(startNames steps).contains VersionControl.diffJob &&
              (landed.pending.filter (·.name == VersionControl.diffJob)).size == 1 },
    { name :=
        "criterion 6: a tracked file's gutter marks change after a commit made outside the editor: with its change staged, the buffer has a changed mark; the commit's touch of the index and the branch's ref makes the watch post vc-gutter-moved, which fetches HEAD again, whose content is now the buffer's, and whose diff leaves the gutter with no mark"
      run :=
        pure <|
          match gutterDriverOf staged with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let committed :=
              (meeting opened staged.commit).touch
                #[("/r/.git/index", .written), ("/r/.git/refs/heads/main", .written)]
            let moved := postDelivered committed
            let fetched := finishNamed moved VersionControl.headJob
            let diffed := finishNamed fetched VersionControl.diffJob
            opened.openWatches == 1 &&
              (gutterView opened).map (·.marks) ==
                some #[{ start := 2, stop := 4, text := "~", face := ⟨"diff.changed"⟩ }] &&
              committed.posting.size == 1 &&
              (pendingOf moved VersionControl.headJob).isSome &&
              ((trackedShown diffed).bind (·.head)).bind (snapshotText diffed) ==
                some "a\nB\nc\nd\n" &&
              ((showing diffed).bind (·.buffer.gutter)).isSome &&
              (gutterView diffed).map (·.marks) == some #[] &&
              diffed.openWatches == 1 },
    { name :=
        "HEAD moving while the first head fetch is in flight fetches again only once that fetch's content is held: the buffer is stale and no second fetch starts; the first reply is held, then exactly one more fetch starts, under the next epoch, with no diff against the head it replaces; its content then replaces the head and its diff leaves no mark"
      run :=
        pure <|
          match gutterDriverOf staged with
          | none => false
          | some driver =>
            let opening := settledBut (fedTo driver (presses "C-o a")).1 VersionControl.headJob
            let moved := postDelivered (committing opening)
            let first := finishNamed moved VersionControl.headJob
            let second := finishNamed first VersionControl.headJob
            let diffed := finishNamed second VersionControl.diffJob
            heads opening == 1 && fetchOf opening == some (0, false, true) && heads moved == 1 &&
              (moved.pending.filter (·.name == VersionControl.headJob)).size == 1 &&
              fetchOf moved == some (0, true, true) &&
              heads first == 2 &&
              fetchOf first == some (1, false, true) &&
              ((trackedShown first).bind (·.head)).bind (snapshotText first) == some gutterHead &&
              (pendingOf first VersionControl.diffJob).isNone &&
              heads diffed == 2 &&
              fetchOf diffed == some (1, false, false) &&
              ((trackedShown diffed).bind (·.head)).bind (snapshotText diffed) ==
                some "a\nB\nc\nd\n" &&
              (gutterView diffed).map (·.marks) == some #[] },
    { name :=
        "a diff in flight when HEAD moves is of the old epoch: the new head is held while it runs, its old head released, and when it lands it sets no mark and records no revision, and a fresh diff against the new head starts, whose marks land"
      run :=
        pure <|
          match gutterDriverOf staged with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let (edited, _) := fedTo opened (presses "C-g x")
            let moved := postDelivered (committing edited)
            let fetched := finishNamed moved VersionControl.headJob
            let old := finishNamed fetched VersionControl.diffJob
            let fresh := finishNamed old VersionControl.diffJob
            match (trackedShown opened).bind (·.head) with
            | none => false
            | some head =>
              (pendingOf edited VersionControl.diffJob).isSome &&
                fetchOf moved == some (1, false, true) &&
                (pendingOf moved VersionControl.diffJob).isSome &&
                ((trackedShown fetched).bind (·.head)).bind (snapshotText fetched) ==
                  some "a\nB\nc\nd\n" &&
                (snapshotText fetched head).isNone &&
                (gutterView old).map (·.marks) == (gutterView fetched).map (·.marks) &&
                (trackedShown old).map (·.diffed) == some none &&
                (old.pending.filter (·.name == VersionControl.diffJob)).size == 1 &&
                (gutterView fresh).map (·.marks) == some againstCommit },
    { name :=
        "an edit made while HEAD is fetched again starts no diff against the head being replaced: the diff starts once the new head is held, and its marks are against the new head"
      run :=
        pure <|
          match gutterDriverOf staged with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let moved := postDelivered (committing opened)
            let (edited, steps) := fedTo moved (presses "C-g x")
            let fetched := finishNamed edited VersionControl.headJob
            let diffed := finishNamed fetched VersionControl.diffJob
            fetchOf moved == some (1, false, true) &&
              !(startNames steps).contains VersionControl.diffJob &&
              (pendingOf edited VersionControl.diffJob).isNone &&
              (pendingOf fetched VersionControl.diffJob).isSome &&
              (gutterView diffed).map (·.marks) == some againstCommit &&
              (pendingOf (settledOn diffed []) VersionControl.diffJob).isNone },
    { name :=
        "a head fetch's reply of an epoch that is not the latest is ignored: its content replaces no head and its failure takes no gutter away"
      run :=
        pure <|
          match gutterDriverOf gutterRepository with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let stale := settledAfter opened "C-g h"
            (trackedShown opened).isSome && trackedShown stale == trackedShown opened &&
              ((trackedShown stale).bind (·.head)).bind (snapshotText stale) == some gutterHead &&
              ((showing stale).bind (·.buffer.gutter)) ==
                ((showing opened).bind (·.buffer.gutter)) &&
              ((showing stale).bind (·.buffer.gutter)).isSome },
    { name :=
        "the state told of the gutter changes only what its epoch's: a head or a diff of another epoch changes nothing but the diff in flight, and one of the latest holds the head or records the revision"
      run :=
        pure <|
          let entry : Tracked :=
            { buffer := ⟨0⟩, root := "/r", path := "src/a.lean", git := "git", head := some ⟨3⟩
              fetching := false, diffing := some (4, ⟨7⟩), diffed := some 2, epoch := 1 }
          let state := { EditorState.none with tracked := #[entry] }
          (state.changeGutter (.held ⟨0⟩ 0 (some ⟨9⟩))).tracked == #[entry] &&
            (state.changeGutter (.diffed ⟨0⟩ 0 4)).tracked == #[{ entry with diffing := none }] &&
            (state.changeGutter (.held ⟨0⟩ 1 (some ⟨9⟩))).tracked ==
              #[{ entry with
                  head := some ⟨9⟩, diffed := none }] &&
            (state.changeGutter (.diffed ⟨0⟩ 1 4)).tracked ==
              #[{ entry with
                  diffing := none, diffed := some 4 }] &&
            (state.changeGutter (.held ⟨1⟩ 1 (some ⟨9⟩))).tracked == #[entry] },
    { name :=
        "a watch the watch service refuses is started once and recorded refused, and no later publish starts another while the buffer is tracked; the gutter still marks edits"
      run :=
        pure <|
          match gutterDriverOf gutterRepository with
          | none => false
          | some driver =>
            let refusing :=
              { driver with
                jobs :=
                  { driver.jobs with
                    fileWatches := { driver.jobs.fileWatches with directories := #[] } } }
            let opened := settledAfter refusing "C-o a"
            let edited := settledAfter (settledAfter opened "C-g x") "C-g z"
            watchReads opened == 1 && watchReads edited == 1 &&
              opened.loop.state.refWatches == #[{ root := "/r", refused := true }] &&
              edited.loop.state.refWatches == #[{ root := "/r", refused := true }] &&
              opened.openWatches == 0 &&
              edited.openWatches == 0 &&
              ((gutterView edited).map (·.marks)).any (!·.isEmpty) },
    { name :=
        "a watch whose git directory git will not say is refused, recorded, and not started again while the buffer is tracked"
      run :=
        pure <|
          match gutterDriverOf gutterRepository with
          | none => false
          | some driver =>
            let refusing :=
              withScript driver
                { command := watchRun
                  reply :=
                    .ok {
                        exit := .code 128, stdout := .empty
                        stderr := "fatal: not a git repository\n".toUTF8 } }
            let opened := settledAfter refusing "C-o a"
            let edited := settledAfter opened "C-g x"
            watchReads opened == 1 && watchReads edited == 1 &&
              edited.loop.state.refWatches == #[{ root := "/r", refused := true }] &&
              edited.openWatches == 0 },
    { name :=
        "a head fetch whose git exits with an error takes the gutter away: once HEAD moves and the fetch fails, the buffer has no gutter, its view no gutter column, and its old head is released"
      run :=
        pure <|
          match gutterDriverOf gutterRepository with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            match (trackedShown opened).bind (·.head) with
            | none => false
            | some head =>
              let failing :=
                withScript opened
                  { command := headRun
                    reply :=
                      .ok {
                          exit := .code 128, stdout := .empty
                          stderr := "fatal: bad object HEAD\n".toUTF8 } }
              let fetched :=
                settledOn (postDelivered (failing.touch #[("/r/.git/index", .written)])) []
              ((showing opened).bind (·.buffer.gutter)).isSome && heads fetched == 2 &&
                ((showing fetched).bind (·.buffer.gutter)).isNone &&
                (gutterView fetched).map (·.padding.gutter) == some 0 &&
                (trackedShown fetched).map (·.head) == some none &&
                (snapshotText fetched head).isNone },
    { name :=
        "a buffer whose repository has HEAD detached is still tracked: a detached HEAD is a branch of the workspace's, and HEAD has the file"
      run :=
        pure <|
          let detached :=
            { workspaceWorld with
              repositories :=
                workspaceWorld.repositories.map fun repository =>
                  if repository.toplevel == ("/r" : System.FilePath) then
                    { repository with branch := none }
                  else repository }
          match gutterDriverOf gutterRepository (world := detached) with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            (shownWorkspace opened).any (·.1.branch == some .detached) &&
              ((trackedShown opened).bind (·.head)).bind (snapshotText opened) == some gutterHead },
    { name := "a change to an object or a lock file alone in the git directory posts nothing"
      run :=
        pure <|
          match gutterDriverOf gutterRepository with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let touched :=
              opened.touch
                #[("/r/.git/objects/ab/cdef", .created), ("/r/.git/index.lock", .created)]
            touched.posting.isEmpty && touched.openWatches == 1 }]

end ModelTest
