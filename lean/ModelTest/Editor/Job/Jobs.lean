import Editor.Command
import Editor.Invocation
import Editor.Job
import Editor.Job.Fake
import Editor.Job.Jobs
import Editor.Job.Runner
import Editor.Job.Table
import Editor.Program
import Editor.Test.Jobs
import ModelTest.Check

/-!
# Model tests: `Editor/Job/Jobs.lean`

The model tests of `Editor/Job/Jobs.lean`: `ownerChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- What `finish` gave, as a check compares it: the job's id and name, and
how it ended. -/
def taken (result : Option (Job.Entry Job.Handle × Job.Outcome (EditorM Unit))) :
    Option (Nat × String × Job.Outcome (Array String)) :=
  result.map fun (entry, outcome) => (entry.id, entry.name, texts outcome)

-- inferred-waits W31: stays (the rig's count and fake clock are the check's own, and the stepped driver moves the clock at its idle)
set_option linter.inferredWait false in
/-- A check of `ownerChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def jobWhoseOwnerRemovedCheck : Check :=
  {
    name :=
      "a job whose owner is removed is cancelled, and its result can no longer be taken; another owner's job runs on, and its result is taken once",
    run := do
      let rig ← Rig.new
      let woken ← IO.mkRef #[]
      let finished (id : Nat) : BaseIO Unit := woken.modify (·.push id)
      let sleeps : Work :=
        reporting fun _ => do
          sleep 1000
          return true
      let jobs : Job.Jobs := { services := rig.services }
      let (annas, jobs) ← jobs.start anna "sleeps" sleeps finished
      let (bens, jobs) ← jobs.start ben "sleeps" sleeps finished
      try
        discard <| rig.idle
        unless (← rig.clock.waiting) == 2 do
          return false
        -- A job that is still running has no result to take, and stays.
        let (early, jobs) ← jobs.finish bens
        let (removed, jobs) ← jobs.removeOwner anna
        -- The clock stays at 0, so only removing the owner can have ended
        -- Anna's job. Once it has ended, at idle its `finished` has run.
        awaitEnded (removed.map (·.handle))
        discard <| rig.idle
        let ended := (← woken.get) == #[annas]
        let outcomes ← removed.mapM fun entry => return (← entry.handle.outcome?).map texts
        let withdrawn := (← rig.clock.withdrawn).size == 1 && (← rig.clock.waiting) == 1
        let unmoved := (← rig.clock.now) == 0
        -- The handler cannot run: there is no result to take.
        let (gone, jobs) ← jobs.finish annas
        rig.clock.advance 1000
        discard <| rig.idle
        let bensEnded := (← woken.get) == #[annas, bens]
        let (result, jobs) ← jobs.finish bens
        let (again, jobs) ← jobs.finish bens
        return early.isNone && ended && removed.map (·.id) == #[annas] &&
            outcomes == #[some .cancelled] &&
            withdrawn &&
            unmoved &&
            gone.isNone &&
            bensEnded &&
            taken result == some (bens, "sleeps", .finished #["true"]) &&
            again.isNone &&
            jobs.running == 0
      finally
        for entry in jobs.table.entries do
          entry.handle.cancel }

/-- The checks of the shell over the job table and the runner
(`Editor/Job/Jobs.lean`), on a fake clock. -/
def ownerChecks : List Check :=
  [jobWhoseOwnerRemovedCheck]

end ModelTest
