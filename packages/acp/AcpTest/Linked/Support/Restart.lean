import AcpTest.Linked.Support.Stage
import Editor.Restore
import Editor.Test.Restore

/-!
# Linked tests' support: a restart over the journal's fake

Two stepped hosts in turn over one file model, as `ConfigTest`'s
`withStateHost` runs them (`lean/ConfigTest/Editor/Headless.lean`), which a
package may not import, so written here: each host is `withConversation`'s
stage with the state directory `/state`, its session and journals
directories, the session journal the recording fake
(`Stage.recordingJournal`) and the core's stand-in of the `restore`
package (`Editor.Test.Restore.package`) among the extra packages; at its
end the file fake's model is written back, so the next host over it
starts from what this one left, as a restart does. `stepIndexed` steps a
host until it has written the session index.
-/

namespace AcpTest.Linked

open Editor
open Editor.Test
open Editor.Test.Linked
open AgentsApiTest

/-- The state directory of the hosts across a restart. -/
def restartState : System.FilePath :=
  "/state"

/-- `model` with the directories a session under `restartState` is kept
in. -/
def stateModel (model : FileModel) : FileModel :=
  ((model.withDirectory restartState).withDirectory
        (Restore.sessionDirectory restartState)).withDirectory
    (Restore.journalsDirectory restartState)

/-- Runs `check` against a host stepped on the check's thread, as
`withConversation`'s, whose fake files hold what `model` holds and the
state directory, whose session journal is the recording fake, and with the
restore package's stand-in; once it has ended, `model` holds what its fake
files held then (the module docs). -/
def withStateHost (context : HostContext) (packages : Array Package) (script : Fake.Script)
    (model : IO.Ref FileModel) (check : Session → Fake → Stage.Fakes → IO Bool) : IO Bool := do
  let fake ← Fake.new script
  let stage ←
    Stage.new context context.elaborator (memorySource [])
        { packages := stagePackages packages #[Editor.Test.Restore.package] }
  let stage ←
    stage.stepped (stateModel (← model.get)) { streams := #[agentChild] } (packageFakes :=
        #[fake.packageFake])
  let (stage, _) ← stage.recordingJournal restartState
  let some fakes := stage.fakes | return false
  let held ← onStage stage fun drive stage => check (Session.ofStage drive "/" stage) fake fakes
  model.set (← fakes.services.files.model)
  return held

/-- Steps the session until the host has written the session index: stepped
to rest, and while the host says the index is being written, the write's
delay moved past on the stage's clock and stepped again. Whether it is
written. -/
partial def stepIndexed (session : Session) : IO Bool := do
  session.step
  unless (← session.drive.progress).indexing do
    return true
  let some deadline ← session.clock.nextDeadline | return false
  session.clock.advance (deadline - (← session.clock.now))
  stepIndexed session

end AcpTest.Linked
