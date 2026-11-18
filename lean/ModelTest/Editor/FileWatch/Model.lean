import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Invocation
import Editor.Job
import Editor.Job.Contract
import Editor.Job.Model
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.Text.Model
import ModelTest.Check
import ModelTest.Support.Jobs

/-!
# Model tests: `Editor/FileWatch/Model.lean`

The model tests of `Editor/FileWatch/Model.lean`: `fileWatchModelChecks`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- What the watch model answers a start of `target` coalesced as
`coalescing`, made at `now`. -/
def watchStart (model : FileWatchModel) (target : FileWatch.Target)
    (coalescing : FileWatch.Coalescing) (now : Nat := 0) :
    Except FileWatchError FileWatch.Id × FileWatchModel × Nat :=
  model.handle now none (.start target coalescing)

/-- What the watch model answers a `next` of `watch` made at `now` by a job
cancelled at `cancelAt`. -/
def watchNext (model : FileWatchModel) (watch : Nat) (now : Nat := 0)
    (cancelAt : Option Nat := none) :
    Except FileWatchError (Array FileWatch.Change) × FileWatchModel × Nat :=
  model.handle now cancelAt (.next ⟨watch⟩)

/-- The change of `path` with `kinds`. -/
def changeOf (path : System.FilePath) (kinds : List FileWatch.Kind) : FileWatch.Change :=
  { path, kinds := kinds.foldl FileWatch.Kinds.add {} }

/-- A model with `watchRoot` and its subdirectory `sub` there. -/
def watchModel : FileWatchModel :=
  { directories := #[watchRoot, watchRoot / "sub"] }

/-- The checks of the watch model (`Editor/FileWatch/Model.lean`), exactly:
the kinds of a change as an exact set, the window moving the clock, the
bound, the routing of each kind of target, the order of the refusals, and a
watch ended with its job. -/
def fileWatchModelChecks : List Check :=
  [{  name :=
        "the watch model delivers one change a path with exactly the kinds recorded there, in the order of each path's first change"
      run := do
        let (_, model, _) := watchStart watchModel (.directory watchRoot false) atOnce
        let model :=
          model.touch
            #[(watchRoot / "b", .written), (watchRoot / "a", .created), (watchRoot / "b", .removed),
              (watchRoot / "a", .written)]
            0
        let (reply, _, _) := watchNext model 1
        return reply ==
            .ok
              #[changeOf (watchRoot / "b") [.written, .removed],
                changeOf (watchRoot / "a") [.created, .written]] },
    { name :=
        "the watch model answers a next at the window from the first change, moving the clock there, or now if that is later"
      run := do
        let window : FileWatch.Coalescing := { window := 300, bound := 10 }
        let (_, model, _) := watchStart watchModel (.file (watchRoot / "f")) window
        let model :=
          (model.touch #[(watchRoot / "f", .written)] 100).touch #[(watchRoot / "f", .written)] 350
        let (early, _, earlyNow) := watchNext model 1 150
        let (late, _, lateNow) := watchNext model 1 500
        let written := Except.ok #[changeOf (watchRoot / "f") [.written]]
        return early == written && earlyNow == 400 && late == written && lateNow == 500 },
    { name :=
        "the watch model collapses a delivery past its bound to missed of the watch's own path, keeps it collapsed until it is taken, then records anew"
      run := do
        let bound : FileWatch.Coalescing := { window := 0, bound := 2 }
        let (_, model, _) := watchStart watchModel (.directory watchRoot false) bound
        let model :=
          model.touch
            #[(watchRoot / "a", .written), (watchRoot / "b", .written), (watchRoot / "c", .written),
              (watchRoot / "a", .removed)]
            0
        let (collapsed, model, _) := watchNext model 1
        let (after, _, _) := watchNext (model.touch #[(watchRoot / "d", .created)] 0) 1
        return collapsed == .ok #[changeOf watchRoot [.missed]] &&
            after == .ok #[changeOf (watchRoot / "d") [.created]] },
    { name :=
        "the watch model's file watch keeps its file and drops its siblings; an entries watch keeps what is directly inside, and a recursive one what is deeper too"
      run := do
        let (_, model, _) := watchStart watchModel (.file (watchRoot / "f")) atOnce
        let (_, model, _) := watchStart model (.directory watchRoot false) atOnce
        let (_, model, _) := watchStart model (.directory watchRoot true) atOnce
        let model :=
          model.touch
            #[(watchRoot / "g", .written), (watchRoot / "sub" / "x", .written),
              (watchRoot / "f", .written), ("/elsewhere/f", .written)]
            0
        let (file, model, _) := watchNext model 1
        let (entries, model, _) := watchNext model 2
        let (tree, _, _) := watchNext model 3
        return file == .ok #[changeOf (watchRoot / "f") [.written]] &&
            entries ==
              .ok #[changeOf (watchRoot / "g") [.written], changeOf (watchRoot / "f") [.written]] &&
            tree ==
              .ok
                #[changeOf (watchRoot / "g") [.written],
                  changeOf (watchRoot / "sub" / "x") [.written],
                  changeOf (watchRoot / "f") [.written]] },
    { name :=
        "the watch model refuses a relative path or a parent component as not absolute, then a bound of 0 as failed, then a missing directory as not found, and starts none of them"
      run := do
        let zero : FileWatch.Coalescing := { window := 0, bound := 0 }
        let isNotAbsolute : Except FileWatchError FileWatch.Id → Bool
          | .error (.notAbsolute _) => true
          | _ => false
        let isFailed : Except FileWatchError FileWatch.Id → Bool
          | .error (.failed _) => true
          | _ => false
        let isNotFound : Except FileWatchError FileWatch.Id → Bool
          | .error (.notFound _) => true
          | _ => false
        let (relative, a, _) := watchStart watchModel (.file "watched/f") zero
        let (parent, b, _) := watchStart watchModel (.directory "/watched/../watched" false) atOnce
        let (bound, c, _) := watchStart watchModel (.file "/nowhere/f") zero
        let (missing, d, _) := watchStart watchModel (.directory "/nowhere" true) atOnce
        let (fileMissing, e, _) := watchStart watchModel (.file "/nowhere/f") atOnce
        -- The library refuses a file with no directory as not found too.
        let (noDirectory, f, _) := watchStart watchModel (.file "/") atOnce
        return isNotAbsolute relative && isNotAbsolute parent && isFailed bound &&
            isNotFound missing &&
            isNotFound fileMissing &&
            isNotFound noDirectory &&
            [a, b, c, d, e, f].all (·.watches.isEmpty) },
    { name :=
        "the watch model's next with nothing recorded fails, or is the cancel at its instant, and a next of a watch it does not have is noSuchWatch"
      run := do
        let (_, model, _) := watchStart watchModel (.file (watchRoot / "f")) atOnce
        let (nothing, _, nothingNow) := watchNext model 1 5
        let (atCancel, _, cancelledNow) := watchNext model 1 5 (some 40)
        let (unknown, _, _) := watchNext model 9
        let isFailed : Except FileWatchError (Array FileWatch.Change) → Bool
          | .error (.failed _) => true
          | _ => false
        return isFailed nothing && nothingNow == 5 && isFailed atCancel && cancelledNow == 40 &&
            unknown == .error .noSuchWatch },
    { name :=
        "in the job model a command a job runs changes what its watch sees, the delivery comes at the window, and the watch ends with its job, finished, failed or cancelled"
      run := do
        let command := JobContract.sh watchRoot "printf x >> f"
        let model : JobModel :=
          { processes :=
              {
                scripts :=
                  #[{ command
                      reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty }
                      takes := 2 }] }
            fileWatches :=
              { watchModel with effects := #[(command, #[(watchRoot / "f", .written)])] } }
        let job (ending : Nat) : JobM Bool := do
          let .ok watch ←
            FileWatch.start (.file (watchRoot / "f")) { window := 10, bound := 4 } | return false
          discard <| Process.run command 100
          let .ok changes ← FileWatch.next watch | return false
          let reached ← now
          match ending with
          | 0 =>
            return changes == #[changeOf (watchRoot / "f") [.written]] && reached == 12
          | 1 =>
            throw "failed"
          | _ =>
            discard <| FileWatch.next watch
            return true
        let (finished, afterFinished) := (job 0).runModel model
        let (failed, afterFailed) := (job 1).runModel model
        let (whenCancelled, afterCancelled) := (job 2).runModel { model with cancelAt := some 50 }
        let endedOne (after : JobModel) :=
          after.fileWatches.ended == #[1] && after.fileWatches.watches.isEmpty
        return finished == .finished true && failed == .failed "failed" &&
            whenCancelled == .cancelled &&
            [afterFinished, afterFailed, afterCancelled].all endedOne }]

end ModelTest
