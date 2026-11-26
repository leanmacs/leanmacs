import Echo.Checksum
import Echo.Job
import Echo.Model
import Echo.Packages
import EchoTest.Check
import Editor.Job.Fake
import Editor.Process.Model
import Editor.Test.Linked.Host

/-!
# Linked tests: `Echo/Packages.lean`

The package `echo` through the headless host stepped on the check's thread
(`Editor.Test.Linked.Stage.stepped`), its service the fake of a package's
service over echo's pure model (`Job.FakePackageService`,
`Echo.Model.packages`), its children the stage's process fake, so every
job's code, completion and hand-off runs on a step of the check's own:

- **`echo-say` reaches the service from a running job** (AC1, stepped): the
  command starts the job, the fake records its request on the check's
  thread, and once the session is stepped to rest the echo area says
  `echo: hello` and the text's CRC-32.
- **Cancelling a job that handed its child to the crate** (AC3), in two
  forced orders. (a) The consumer is held: the child is handed over and
  nothing has ended, read once at rest; `echo-attach-cancel` then withdraws
  the job's wait at the service before the runner ends the child, and the
  consumer's last event is `cancelled`, after the line `one`. (b) The child
  exits by itself and its completion is handed to the pump but not
  stepped; the cancel comes first, so the completion is dropped, the fake
  keeps no reply and the late kill of a child already forgotten does
  nothing. In both the job ends cancelled, so its command never says what
  the crate read, and the fakes hold nothing at the end.

The orders were seen to bite by hand: (a) fails when `Job.Handle.conclude`
no longer ends the job's children, and (b) when `Job.Handle.drop` no longer
withdraws a wait at the package services (`docs/design/concurrency.md`, "A
long-lived job owns a handed-over child"). The same service over the real
crate is the wiring set's (`EchoTest/Linked/Echo/Real/Job.lean`).
-/

namespace EchoTest.Linked

open Editor
open Editor.Test.Linked

/-- The fake consumer's end as the crate's read says it: the lines, then
how the child ended, joined by line feeds, in one pull. -/
def attachedOf (handed : Job.FakeProcesses.Handed) : Echo.Attached :=
  let ended :=
    match handed.ended with
    | .exited (.code code) => s!"<exited {code}>"
    | .exited (.signal signal) => s!"<signalled {signal}>"
    | .cancelled => "<cancelled>"
  { text := "\n".intercalate (handed.lines.push ended).toList, pulls := 1 }

/-- The fake of echo's service: echo's pure model, and an `attach` answered
by a hand-off of its child to the fake consumer. -/
def echoSpec : Job.FakePackageService.Spec :=
  { name := Echo.serviceName, model := Echo.Model.packages
    handOff :=
      some { child := Echo.attachedChild, reply := fun handed => .mk (attachedOf handed) } }

/-- The child `echo-attach` opens, as the stage's process fake runs it:
`one`, then a pause no step ends, as a session's child lives until it is
ended. -/
def pausingAttach : Process.StreamScript :=
  { command := Echo.attachCommand, steps := #[.write .out "one\n".toUTF8, .pause 1000000000] }

/-- The child `echo-attach` opens, exiting by itself after `one`. -/
def exitingAttach : Process.StreamScript :=
  { command := Echo.attachCommand, steps := #[.write .out "one\n".toUTF8] }

/-- Runs `check` against a host stepped on the check's thread over a stepped
stage of `context`'s elaborator with no config, handed the package `echo`,
whose service is the fake of `echoSpec` and whose children are the process
fake running `child`. `check` is handed the session, the package fake and
the process fake. -/
def withEchoHost (context : HostContext) (child : Process.StreamScript)
    (check : Session → Job.FakePackageService → Job.FakeProcesses → IO Bool) : IO Bool := do
  let stage ← Stage.new context context.elaborator (memorySource []) { packages := #[Echo.package] }
  let stage ← stage.stepped (processes := { streams := #[child] }) (packages := #[echoSpec])
  let some fakes := stage.fakes | return false
  let some package := fakes.services.packages[0]? | return false
  onStage stage fun drive stage =>
      check (Session.ofStage drive "/" stage) package fakes.services.processes

/-- An order of the package fake's log, as a check compares it. -/
def packageOrder : Job.FakePackageService.Order → String
  | .start _ request => s!"start {request.operation}"
  | .take _ => "take"
  | .withdraw _ => "withdraw"
  | .flush _ => "flush"
  | .ended _ read => s!"ended {"\n".intercalate read.lines.toList} {repr read.ended}"

/-- An order of the process fake's log, as a check compares it. -/
def processOrder : Job.FakeProcesses.Order → String
  | .start _ request =>
    match request with
    | .start .. => "start child"
    | _ => "start"
  | .flush _ => "flush"
  | .withdraw _ => "withdraw"
  | .kill _ => "kill"
  | .handOff _ => "handOff"

/-- Whether `text` holds `part`. -/
def holds (text part : String) : Bool :=
  (text.splitOn part).length > 1

/-- The checks of the package `echo` through the stepped host. -/
def echoPackageChecks (context : HostContext) : List Check :=
  [{  name :=
        "AC1, stepped: echo-say starts a job whose request reaches echo's service fake on the check's thread, and the echo area says the text and its checksum"
      run :=
        withEchoHost context pausingAttach fun session package _ => do
          let thread ← IO.getTID
          session.ask [.reload]
          session.ask [.run Echo.sayName]
          session.step
          let echo ← session.echo
          let log ← package.log
          saw
              (holds echo s!"echo: hello {Echo.checksum "hello"}" &&
                (log.map (packageOrder ·.1)) == #["start say", "take"] &&
                log.all (·.2 == thread) &&
                (← package.quiescent))
              s!"echo {echo}, log {log.map (packageOrder ·.1)} on {log.map (·.2)}, the check's thread {thread}" },
    { name :=
        "AC3 (a): cancelling echo-attach while the crate's consumer is held withdraws the job's wait at the service, then ends the child, whose consumer's last event is cancelled after one; the job's command never runs"
      run :=
        withEchoHost context pausingAttach fun session package processes => do
          session.ask [.reload]
          session.ask [.run Echo.attachName]
          session.step
          -- At rest: the child is handed over, and nothing has ended.
          let handed ← processes.handed
          let atRest := (← package.log).map (packageOrder ·.1)
          session.ask [.run Echo.attachCancelName]
          session.step
          let log := (← package.log).map (packageOrder ·.1)
          let children := (← processes.log).map (processOrder ·.1)
          let echo ← session.echo
          saw
              (handed.size == 1 && atRest == #["start attach"] &&
                log ==
                  #["start attach", "withdraw",
                    s!"ended one {repr Job.FakeProcesses.Ending.cancelled}"] &&
                children == #["start child", "handOff", "kill"] &&
                !holds echo s!"{Echo.attachName}: " &&
                (← package.quiescent) &&
                (← processes.handed).isEmpty)
              s!"handed {handed}, at rest {atRest}, log {log}, children {children}, echo {echo}" },
    { name :=
        "AC3 (b): a child that exits by itself has its consumer's completion handed to the pump; a cancel before the pump's step drops it, the fake keeps no reply, and the late kill of the forgotten child does nothing"
      run :=
        withEchoHost context exitingAttach fun session package processes => do
          session.ask [.reload]
          package.holdCompletions
          session.ask [.run Echo.attachName]
          session.step
          -- The consumer has read the child's end, and its completion is
          -- handed to the pump, not stepped.
          package.letGo
          session.ask [.run Echo.attachCancelName]
          session.step
          let log := (← package.log).map (packageOrder ·.1)
          let children := (← processes.log).map (processOrder ·.1)
          let echo ← session.echo
          saw
              (log ==
                  #["start attach",
                    s!"ended one {repr (Job.FakeProcesses.Ending.exited (.code 0))}", "withdraw"] &&
                children == #["start child", "handOff"] &&
                !holds echo s!"{Echo.attachName}: " &&
                (← package.quiescent))
              s!"log {log}, children {children}, echo {echo}" }]

end EchoTest.Linked
