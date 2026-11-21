import Editor.Gutter.Track
import Editor.State
import Editor.Test.Models
import Editor.Test.States
import Editor.Text
import ModelTest.Check

/-!
# Model tests: `Editor/Gutter/Track.lean`

`gutterTrackChecks`: the version-control gutter's reconciler, the core's,
run as the pure function it is on states built here, with the gutter's job
names registered and no version-control job: which buffers it tracks, the
jobs it starts and cancels, and the watch it keeps for each repository's
root. The root module `ModelTest` runs them; its module doc says what each
shows. What the jobs' commands do is version control's
(`VersionControlTest.gutterChecks`).
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The gutter's three job names, registered: the stand-in of a host that
registered version control's gutter package, whose works the reconciler
never runs. -/
def gutterRegistered (name : String) : Bool :=
  [Gutter.headJob, Gutter.diffJob, Gutter.refsJob].contains name

/-- The workspace at `/r`, with `branch` checked out, as the finder would
answer it. -/
def trackFound (branch : Option Workspace.Branch) : Workspace.Found :=
  { root := "/r", branch, project := { identity := .root "/r", name := "r" } }

/-- The initial state with the buffer `a.lean`, the buffer 1, over the text
`a`, holding the file `path` unless `file` is false, in the workspace at
`/r` with `branch` checked out. -/
def trackState (branch : Option Workspace.Branch := some (.named "main"))
    (path : System.FilePath := "/r/src/a.lean") (file : Bool := true) : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let text ← createText "a\n"
  let history ← UndoTree.over text
  let (.ok id, state) := state.addBuffer "a.lean" text history | return state
  let state := if file then (state.attachFile id path noteStamp .lf).2 else state
  let state := state.recordWorkspace "/r/src" 0 (some (trackFound branch))
  return (state.setValue id Workspace.bufferLocal (Location.local "/r").encode).2

/-- The buffer `trackState` adds. -/
def trackedBuffer : BufferId :=
  ⟨1⟩

/-- What the reconciler of the host that registered `registered` makes of
the state `start` makes, run on the text model, with the text model it
leaves; `none` when the text port refused a request. -/
def reconciledFrom (start : TextM EditorState) (registered : String → Bool := gutterRegistered) :
    Option ((EditorState × Array JobStart × Array String) × TextModel) :=
  let (result, model) :=
    (do
          Gutter.reconcile registered "git" (← start) : TextM _).runModel
      editorModel.texts
  result.toOption.map (·, model)

/-- The head fetch the reconciler starts for the tracked buffer, at `epoch`. -/
def headStart (epoch : Nat := 0) : JobStart :=
  { name := Gutter.headJob, key := some (Gutter.headKey trackedBuffer)
    arguments :=
      Gutter.HeadOrder.arguments
        { buffer := trackedBuffer, epoch, root := "/r", git := "git", path := "src/a.lean" } }

/-- The watch the reconciler starts for the repository at `/r`. -/
def refsStart : JobStart :=
  { name := Gutter.refsJob, key := some (Gutter.refsKey "/r")
    arguments := Gutter.refsArguments "/r" "git" }

/-- `start` reconciled once, then given a head snapshot of a text holding
`a`, held for its tracked buffer with no fetch in flight, as the head
fetch's command leaves it; and that snapshot. -/
def headHeld (start : TextM EditorState := trackState) : TextM (EditorState × SnapshotId) := do
  let (state, _, _) ← Gutter.reconcile gutterRegistered "git" (← start)
  let head ← createText "a\n"
  let snapshot ← head.snapshot
  head.release
  return ({ state with
        tracked :=
          state.tracked.map fun entry =>
            { entry with
              head := some snapshot, fetching := false } },
      snapshot)

/-- The checks of the gutter's reconciler (`Editor/Gutter/Track.lean`). -/
def gutterTrackChecks : List Check :=
  [{  name :=
        "a buffer of a file under its workspace's root, the workspace a repository with a branch, is tracked: one head fetch keyed by the buffer, with its order, and one watch of the root; reconciled again it starts and cancels nothing"
      run :=
        pure <|
          match reconciledFrom trackState with
          | none => false
          | some ((state, starts, cancels), _) =>
            starts == #[headStart, refsStart] && cancels.isEmpty &&
              state.tracked.map
                  (fun entry => (entry.buffer, entry.root, entry.path, entry.fetching)) ==
                #[(trackedBuffer, ("/r" : System.FilePath), "src/a.lean", true)] &&
              state.refWatches.map (·.root) == #[("/r" : System.FilePath)] &&
              match reconciledFrom (pure state) with
              | some ((again, starts, cancels), _) =>
                starts.isEmpty && cancels.isEmpty && again.tracked == state.tracked
              | none => false },
    { name :=
        "where the host registered any of the gutter's three jobs but not all, a tracked file's buffer is not tracked: no fetch, no watch"
      run :=
        pure <|
          [Gutter.headJob, Gutter.diffJob, Gutter.refsJob].all fun missing =>
            match
              reconciledFrom trackState (fun name => gutterRegistered name && name != missing) with
            | some ((state, starts, cancels), _) =>
              starts.isEmpty && cancels.isEmpty && state.tracked.isEmpty && state.refWatches.isEmpty
            | none => false },
    { name :=
        "a buffer whose workspace has no branch, so is no repository, a buffer with no file, and a file outside its workspace's root are not tracked; a detached HEAD is a branch, and is tracked"
      run :=
        pure <|
          let untracked (start : TextM EditorState) : Bool :=
            match reconciledFrom start with
            | some ((state, starts, _), _) => starts.isEmpty && state.tracked.isEmpty
            | none => false
          untracked (trackState (branch := none)) && untracked (trackState (file := false)) &&
            untracked (trackState (path := "/x/a.txt")) &&
            match reconciledFrom (trackState (branch := some .detached)) with
            | some ((state, starts, _), _) =>
              starts == #[headStart, refsStart] && state.tracked.size == 1
            | none => false },
    { name :=
        "a buffer whose head is held and whose text's revision is not diffed gets one diff, keyed by the buffer, over the head and a snapshot of its text at that revision; one diffed at its revision gets none"
      run :=
        pure <|
          let diffing :=
            (do
                  let (state, head) ← headHeld
                  let (state, starts, cancels) ← Gutter.reconcile gutterRegistered "git" state
                  return (state, starts, cancels, head) : TextM _).runModel
              editorModel.texts
          match diffing.1 with
          | .error _ => false
          | .ok (state, starts, cancels, head) =>
            let diffed :=
              { state with
                tracked :=
                  state.tracked.map fun entry =>
                    { entry with
                      diffing := none, diffed := entry.diffing.map (·.1) } }
            cancels.isEmpty &&
              (match starts.toList, (state.tracked[0]?.bind (·.diffing)) with
              | [start], some (revision, taken) =>
                start ==
                  { name := Gutter.diffJob, key := some (Gutter.diffKey trackedBuffer)
                    arguments :=
                      Gutter.DiffOrder.arguments
                        { buffer := trackedBuffer, epoch := 0, head, taken, revision } }
              | _, _ => false) &&
              match (Gutter.reconcile gutterRegistered "git" diffed).runModel diffing.2 with
              | (.ok (_, starts, _), _) => starts.isEmpty
              | _ => false },
    { name :=
        "a buffer no longer wanted, here closed, has its fetch and its diff cancelled, its snapshot of HEAD released and its gutter taken away, and, the last buffer of its repository, its watch cancelled"
      run :=
        pure <|
          let closed :=
            (do
                  let (state, head) ← headHeld
                  let (_, state) := state.removeBuffer trackedBuffer
                  let (state, starts, cancels) ← Gutter.reconcile gutterRegistered "git" state
                  return (state, starts, cancels, head) : TextM _).runModel
              editorModel.texts
          match closed with
          | (.ok (state, starts, cancels, head), model) =>
            starts.isEmpty &&
              cancels ==
                #[Gutter.headKey trackedBuffer, Gutter.diffKey trackedBuffer,
                  Gutter.refsKey "/r"] &&
              state.tracked.isEmpty &&
              state.refWatches.isEmpty &&
              ((head.read : TextM String).runModel model).1.toOption.isNone
          | _ => false },
    { name :=
        "a tracked file's root and path come from its workspace's root: the path relative to it, and none for a path outside it"
      run :=
        pure <|
          Gutter.relativeTo "/r" "/r/src/a.lean" == some "src/a.lean" &&
            Gutter.relativeTo "/r/" "/r/src/a.lean" == some "src/a.lean" &&
            Gutter.relativeTo "/r" "/rs/a.lean" == none }]

end ModelTest
