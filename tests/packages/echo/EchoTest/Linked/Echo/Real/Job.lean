import Echo.Job
import Echo.Real
import EchoTest.Check
import Editor.Job.Contract
import Editor.Job.Fake
import Editor.Job.Protocol
import Editor.Job.Runner
import Editor.RealHost
import Editor.Test.Jobs
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Services

/-!
# Linked tests: echo's service, reached by a running job

The crate's service as the job runner's package service
(`Echo.Real.service`), over the linked test kit's real services and the
completion pump running over their table (`Editor.Test.Linked.Services`):
a runner given the package services the program's edge builds from echo's
packages (`Editor.Headless.packageServices Echo.packages`, which
`Headless.shipped` gives its runner and the linked test's root hands in
here, as only the root may import the headless host) and the fake recorder
runs jobs that ask it through the job port, each request completed by the
crate on the library's completion queue, which only the crate posts on for
it. So a package that stops bringing its service (`Package.services`), or
an edge that stops handing the packages' services on, fails every check
here.

- **A job's `say`** (AC1, over the real crate, through the edge's package
  services): `Echo.Job.say "hello"` finishes with the text and the checksum
  the crate computed, which is the pure one
  (`Echo.checksum`).
- **The package properties** (`JobContract.packageProperties`) hold of the
  crate: a request's reply, an unknown service, two requests in flight, a
  job cancelled in its wait on an attach whose child only a cancel ends,
  and a flush behind a request.
- **The trace** every job here recorded replays on the protocol's model
  breaking no invariant, and holds the package waits as `service` waits
  (AC2, on real threads).

Each wait is on the event itself (a job's outcome, the recorder's step, a
flush's end), the kit's patience a hang guard. The orderings are forced on
the stepped host with the service's fake (`EchoTest/Linked/Echo/Packages.lean`)
and in the crate's own tests.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.EchoTest.Linked.Echo.Real.Job : Editor.WiringSet :=
  .wiring "the echo crate's service, reached by a running job through the runner's package port"
    "only the crate posts on the library's completion queue"

namespace EchoTest.Linked

open Editor
open Editor.Test

/-- The runner over `services`, the linked kit's real services, given the
package services `packages`, the edge's for echo's packages, and recording
to `recorder`. -/
def jobRunner (services : Editor.Test.Linked.Services) (packages : Job.PackageServices)
    (recorder : Job.FakeRecorder) : Job.Services :=
  { services.jobs with
    packages, recorder := recorder.recorder }

/-- How the job behind `handle` ended, waited for on its outcome, the kit's
patience a hang guard; its value read back. -/
def endedOf (handle : Job.Handle) : IO (Job.Outcome Bool) := do
  discard <| Editor.Test.Linked.hangGuarded "the job's end" handle.finishedRan.result?
  match (← handle.outcome?).map texts with
  | some (.finished values) =>
    return .finished (values == #["true"])
  | some (.failed message) =>
    return .failed message
  | _ =>
    return .cancelled

/-- The subject of the package properties over the crate: a `say` of
`hello` and one of `héllo`, each answered its text and the crate's checksum. -/
def echoSubject : JobContract.PackageSubject :=
  { service := Echo.serviceName, request := Echo.sayRequest "hello"
    answers := fun reply => (reply.get? Echo.Reply) == some (Echo.Reply.to "hello")
    other := Echo.sayRequest "héllo"
    otherAnswers := fun reply => (reply.get? Echo.Reply) == some (Echo.Reply.to "héllo") }

/-- Opens `/bin/sh -c script` in `directory` as a streaming child through the
real process port, and gives its number once it is open. -/
private def opened (services : Editor.Test.Linked.Services) (directory : System.FilePath)
    (script : String) : IO (Option UInt64) := do
  let request :=
    ProcessRequest.start { program := "/bin/sh", arguments := #["-c", script], directory }
      { input := true, bound := 4 * 1024 * 1024 }
  let (child, wait) ← services.completions.register
  services.jobs.processes.start child request
  unless (← Job.awaitWithin Editor.Test.Linked.patience wait.result?) == some (some .completed) do
    return none
  match ← services.jobs.processes.take child request with
  | .ok _ =>
    return some child
  | .error _ =>
    return none

/-- The crate as a package property's rig, over `services` and the package
services `packages`: each run on a runner of its own recording to `recorder`; two jobs spawned before either is
awaited; a job held in its package wait on an attach of a child that only a
cancel ends, cancelled once it serves that wait, its child ended after; and
a flush asked behind a `say` started at the service. -/
def echoRig (services : Editor.Test.Linked.Services) (packages : Job.PackageServices)
    (recorder : Job.FakeRecorder) : JobContract.PackageRig
    where
  name := "the runner over the echo crate"
  subject := echoSubject
  run job := do
    endedOf (← Job.spawn (jobRunner services packages recorder) (reporting fun _ => job) (pure ()))
  both :=
    some fun first second => do
      let runner := jobRunner services packages recorder
      let one ← Job.spawn runner (reporting fun _ => first) (pure ())
      let two ← Job.spawn runner (reporting fun _ => second) (pure ())
      let one ← endedOf one
      return (one, ← endedOf two)
  cancelled :=
    some do
      Editor.Test.Linked.withFiles services.jobs (targets := [.processes]) fun directory => do
          let some child ←
            opened services directory "read x" | throw (IO.userError "the child was not opened")
          -- A recorder of this job's own, so its one service wait is the
          -- attach's.
          let held ← Job.FakeRecorder.new
          let handle ←
            Job.spawn (jobRunner services packages held)
                (reporting fun _ => do
                  discard <| Echo.Job.attach ⟨child.toNat⟩
                  return true)
                (pure ())
          discard <|
              Editor.Test.Linked.hangGuarded "the job's serve of its attach"
                (← held.reached (· matches .serve _))
          handle.cancel
          let ended ← endedOf handle
          -- The child is not the job's: it is ended here, and the crate's
          -- consumer, blocked in its pull, is answered cancelled.
          services.jobs.processes.cancel child
          return ended
  flushed :=
    some do
      let (id, wait) ← services.completions.register
      unless ← Echo.Real.service.start id echoSubject.request do
        throw (IO.userError "the crate did not take the say")
      let flushed ← (jobRunner services packages recorder).flushed (.package Echo.serviceName)
      let completed ← Job.awaitWithin Editor.Test.Linked.patience flushed
      let before ← wait.isResolved
      discard <| Echo.Real.service.take id echoSubject.request
      return (completed == some .completed, before)

/-- The checks of the crate's service reached by running jobs, over
`services`, whose pump is running, and the package services `packages`: the
edge's for echo's packages (`Editor.Headless.packageServices`), which the
linked test's root hands in. -/
def echoJobChecks (services : Editor.Test.Linked.Services) (packages : Job.PackageServices) :
    List Check :=
  [{  name :=
        "AC1, over the real crate, through the package services the edge builds from echo's packages: a running job's say of hello finishes with hello and the checksum the crate computed, which is the pure one"
      run := do
        let recorder ← Job.FakeRecorder.new
        let handle ←
          Job.spawn (jobRunner services packages recorder)
              (reporting fun _ => do
                let reply ← Echo.Job.say "hello"
                return reply.toOption.any (· == Echo.Reply.to "hello"))
              (pure ())
        let ended ← endedOf handle
        saw (ended == .finished true) s!"ended {repr ended}" },
    { name :=
        "the package properties hold of the runner over the echo crate, and every trace they recorded replays on the protocol's model with its package waits as service waits"
      run := do
        let recorder ← Job.FakeRecorder.new
        let failed ← JobContract.packageFailures [echoRig services packages recorder]
        unless failed.isEmpty do
          return ← saw false s!"{failed}"
        let trace ← recorder.trace
        match Job.Protocol.replay trace with
        | .ok state =>
          saw (state.violation?.isNone && trace.any (· matches .ask _ _ .service))
              s!"the replay broke {repr state.violation?}; the trace {repr trace}"
        | .error refusal =>
          saw false s!"{refusal.text}; the trace {repr trace}" }]

end EchoTest.Linked
