import Echo.Job
import Echo.Model
import Editor.Job.Model

/-!
# Model tests: `Echo/Job.lean`

Echo's service as a running job reaches it, on the job port's pure model
with echo's model of package services (`Echo.Model.packages`): a `say`
answers its text and its checksum, read back as `Echo.Reply`; an `attach`
is refused by the model, which has no children; and a service the model
does not know is `noSuchService`. The test driver's root,
`EchoTest/Model.lean`, runs them.
-/

namespace EchoTest

open Editor

/-- How `job` ends on the job model with echo's model of package
services. -/
def onEchoModel {α : Type} (job : JobM α) : Job.Outcome α :=
  (job.runModel { packages := Echo.Model.packages }).1

/-- The checks of echo's service on the job model, each with what must hold
as a sentence. -/
def echoJobChecks : List (String × Bool) :=
  [("a job's say of echo's service answers its text and the text's checksum, read back typed",
      match onEchoModel (Echo.Job.say "héllo") with
      | .finished (.ok reply) => reply == Echo.Reply.to "héllo"
      | _ => false),
    ("a job's attach on echo's model is refused: the model has no children",
      onEchoModel (Echo.Job.attach ⟨3⟩) matches .finished (.error (.refused _))),
    ("a job's request of a service the model does not know is noSuchService",
      onEchoModel (PackageService.ask { Echo.sayRequest "x" with service := "elsewhere" }) matches
        .finished (.error (.noSuchService "elsewhere")))]

end EchoTest
