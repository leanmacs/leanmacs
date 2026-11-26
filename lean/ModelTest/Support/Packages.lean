import Editor.Job.Contract
import Editor.Job.Fake
import Editor.Job.Runner
import Editor.PackageService
import Editor.Test.Jobs

/-!
# Model tests: support: Packages

A package's service as the model tests run it: a reply type of a
package's own (`CountReply`), the model of a service that counts
(`countModel`), and the stepped runner over its fake (`PackageStepped`): the
fake scheduler, the fake pump and the fake package service answering
through it, over one table of waits, with the fake recorder. Its two users
are the model tests of the runner (`ModelTest/Editor/Job/Runner.lean`,
`packageServiceChecks`) and those of the protocol contract
(`ModelTest/Editor/Job/ProtocolContract.lean`), whose package runs replay
on the protocol's model.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A package's reply type: a count. Every package reply is a named type
of the package's that derives `TypeName`. -/
structure CountReply where
  /-- The count. -/
  value : Nat
  deriving TypeName, DecidableEq, Repr

/-- The name of the service that counts. -/
def countService : String :=
  "count"

/-- The request that asks the service that counts for the count after `n`. -/
def countAfter (n : Nat) : PackageRequest :=
  { service := countService, operation := "next", arguments := [.nat n] }

/-- The model of the service that counts: `next` of `n` answers `n + 1`,
any other request of it is refused, and it knows no other service. -/
def countModel : PackageModel := fun request =>
  if request.service == countService then
    match request.operation, request.arguments with
    | "next", [.nat n] => some (.ok (.mk (CountReply.mk (n + 1))))
    | _, _ => some (.error (.refused "the count takes next of a number"))
  else none

/-- The fake's spec of the service that counts. -/
def countSpec : Job.FakePackageService.Spec :=
  { name := countService, model := countModel }

/-- Whether `reply` is the count `n`. -/
def countIs (n : Nat) (reply : Dynamic) : Bool :=
  (reply.get? CountReply).any (·.value == n)

/-- The guard of a stepped package run's next completion or its job's end;
only a hang reaches it. -/
def packageGuard : HangGuard :=
  .on "a due completion or the job's end" 10000

/-- A runner over the fakes of a package check, stepped on the check's
thread: the fake scheduler, the fake pump, the fake clock and the fake
package service answering through the pump, over one table of waits, with
the fake recorder. -/
structure PackageStepped where
  /-- The table of waits. -/
  completions : Job.Completions
  /-- The fake clock, which no package check moves. -/
  clock : Job.FakeClock
  /-- The fake pump the package fake answers through. -/
  pump : Job.FakePump
  /-- The fake scheduler the jobs' code runs on. -/
  jobs : Job.FakeScheduler
  /-- The package service's fake. -/
  fake : Job.FakePackageService
  /-- The recorder the runner's transitions are recorded to. -/
  recorder : Job.FakeRecorder
  /-- The services, the fake's service among them. -/
  services : Job.Services

/-- A stepped runner over a fake of `spec`, its hand-offs taken from the
process fake `processes` a check makes over the same table, when given. -/
def PackageStepped.new (spec : Job.FakePackageService.Spec)
    (processes : Option (Job.Completions → BaseIO Job.FakeProcesses) := none) :
    BaseIO PackageStepped := do
  let completions ← Job.Completions.new
  let clock ← Job.FakeClock.new completions
  let pump ← Job.FakePump.new completions
  let jobs ← Job.FakeScheduler.new
  let recorder ← Job.FakeRecorder.new
  let processes ←
    match processes with
    | some make =>
      some <$> make completions
    | none =>
      pure none
  let fake ← Job.FakePackageService.new completions spec processes (.onStep pump)
  return {
      completions, clock, pump, jobs, fake, recorder
      services :=
        { completions, timers := clock.timers, scheduler := jobs.scheduler
          recorder := recorder.recorder
          processes := ((processes.map (·.processes)).getD (Job.Processes.absent completions))
          packages := Job.PackageServices.of #[fake.service] } }

/-- Spawns `job` on the stepped runner, its value reported as a text. -/
def PackageStepped.spawn (stepped : PackageStepped) (job : JobM Bool) : BaseIO Job.Handle :=
  Job.spawn stepped.services (reporting fun _ => job) (pure ())

/-- How the job behind `handle` ended, its value read back; `cancelled`
while it runs. -/
def PackageStepped.outcome (handle : Job.Handle) : BaseIO (Job.Outcome Bool) := do
  match (← handle.outcome?).map texts with
  | some (.finished values) =>
    return .finished (values == #["true"])
  | some (.failed message) =>
    return .failed message
  | _ =>
    return .cancelled

/-- Steps the runner on the check's thread until the job behind `handle`
has ended (`FakePump.runToEnd`): how it ended. -/
def PackageStepped.toEnd (stepped : PackageStepped) (handle : Job.Handle) : IO (Job.Outcome Bool) :=
  do
  stepped.pump.runToEnd handle.outcome.result? packageGuard (some stepped.clock) (some stepped.jobs)
  PackageStepped.outcome handle

/-- Spawns `job` and steps it to its end: how it ended. -/
def PackageStepped.run (stepped : PackageStepped) (job : JobM Bool) : IO (Job.Outcome Bool) := do
  stepped.toEnd (← stepped.spawn job)

/-- Runs the scheduler's pieces of code that can run, on the check's
thread, and none of the pump's completions: the jobs go as far as their
waits. -/
def PackageStepped.toWaits (stepped : PackageStepped) : BaseIO Unit :=
  stepped.jobs.stepAll

/-- The stepped runner over a fresh fake of `spec` as a package property's
rig (`JobContract.PackageRig`): each property's runs on a runner of their
own; two jobs both spawned and run to their waits before the pump answers
either; a job held in its wait by the fake's held completions and cancelled
there; and a flush asked behind a request whose completion the fake holds,
let go and stepped. -/
def PackageStepped.rig (spec : Job.FakePackageService.Spec) (subject : JobContract.PackageSubject) :
    JobContract.PackageRig
    where
  name := s!"the runner over the fake of {spec.name}, stepped"
  subject
  run job := do
    (← PackageStepped.new spec).run job
  both :=
    some fun first second => do
      let stepped ← PackageStepped.new spec
      let one ← stepped.spawn first
      let two ← stepped.spawn second
      stepped.toWaits
      unless (← stepped.fake.waiting) == 2 do
        throw (IO.userError s!"{← stepped.fake.waiting} requests in flight, and not 2")
      let one ← stepped.toEnd one
      return (one, ← stepped.toEnd two)
  cancelled :=
    some do
      let stepped ← PackageStepped.new spec
      stepped.fake.holdCompletions
      let handle ← stepped.spawn (JobContract.askedAnswers subject.request subject.answers)
      stepped.toWaits
      handle.cancel
      let ended ← stepped.toEnd handle
      stepped.fake.letGo
      unless ← stepped.fake.quiescent do
        throw (IO.userError "the fake holds a request once its job was cancelled")
      return ended
  flushed :=
    some do
      let stepped ← PackageStepped.new spec
      stepped.fake.holdCompletions
      let (id, wait) ← stepped.completions.register
      unless ← stepped.fake.service.start id subject.request do
        throw (IO.userError "the fake refused the subject's request")
      let flushed ← stepped.services.flushed (.package spec.name)
      let early ← IO.hasFinished flushed
      stepped.fake.letGo
      stepped.pump.stepAll
      -- The request's reply is taken, so the fake keeps nothing.
      discard <| stepped.fake.service.take id subject.request
      let completed := (← IO.hasFinished flushed) && flushed.get == .completed
      return (!early && completed, ← wait.isResolved)

end ModelTest
