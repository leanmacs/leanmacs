import Editor.Command.Model
import Editor.File.Cases
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
import Editor.Test.Jobs
import Editor.Test.Models
import Editor.Text
import Editor.Text.Model

/-!
# Model tests: `Editor/File/Cases.lean`

The model tests of `Editor/File/Cases.lean`: `caseFailures`. `caseFailures` play
the cases across the text port and the job port on both models. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- What a job's model holds, as what a run of the job's command is handed:
each snapshot the job's loads made that was not released, under the job's
name for it. -/
def heldBy (model : FileModel) : Array (JobSnapshotId × TextContent) :=
  (Array.range model.held.size).filterMap fun index =>
    (model.held[index]?).join.map fun content => (⟨index⟩, content)

/-- Plays `case` on the text model and the job model, handing the snapshots
across as the runtime does, and says what went wrong; `none` when the case
held.

The values that cross are handed as values. The commands run against the
editor's models. The job's model starts with the text model's snapshots as
the published ones. The job's command runs with what the job's model held as
what arrived in its text model. The job is then settled, so the last command
runs against a text model that was handed nothing. Neither side writes what
the other owns. -/
def playOnModels (case : FileCases.Case) : Option String :=
  match case.first.runModel editorModel with
  | (.error refusal, _) => some s!"its first command failed with {repr refusal}"
  | (.ok start, model) =>
    let files := { fileModelOf case.files with snapshots := model.texts.snapshots }
    match (case.job fileRoot start).runModel { files } with
    | (.failed message, _) => some s!"its job failed with `{message}`"
    | (.cancelled, _) => some "its job was cancelled"
    | (.finished value, job) =>
      let handed := { model with texts := { model.texts with arrived := heldBy job.files } }
      match (case.handler start value).runModel handed with
      | (.error refusal, _) => some s!"the job's command failed with {repr refusal}"
      | (.ok (), model) =>
        match
          (case.last start).runModel
            { model with texts := { model.texts with arrived := #[] } } with
        | (.error refusal, _) => some s!"its last command failed with {repr refusal}"
        | (.ok false, _) => some "its last command says it did not hold"
        | (.ok true, _) =>
          let after := JobContract.byName (filesIn job.files)
          if after == JobContract.byName case.after then none
          else some s!"the files afterwards are {after.map (·.1)}, of {after.map (·.2.size)} bytes"

/-- The names of the cases across the text port and the job port that do not
hold of the two models, each with what went wrong. -/
def caseFailures : IO (List String) :=
  return FileCases.cases.filterMap fun case =>
      (playOnModels case).map fun reason => s!"the text model and the job model: {case.name} ({reason})"

end ModelTest
