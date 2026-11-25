import Editor.Config.Elaborate
import Editor.Ffi.Events
import Editor.Headless.Journal.Fake
import Editor.Headless.Queue
import Editor.Headless.Stepped
import Editor.SyntaxTree.Fake
import Editor.Test.Linked.Services

/-!
# The linked test kit: Stepping

What a host stepped over the fakes is run with, wherever it runs: the
fakes a driver steps on its own thread (`SteppedFakes`: the job services'
fakes, the memory queue the host drains, and the journal's and the syntax
service's fakes once a maker has added them), one piece of their work
(`SteppedFakes.stepWork`, the stepped host's `Headless.Stepped.Work`), what
of them still holds work (`unquiet`), and the loop's end that steps them
until each job it cancelled has ended (`endCancelled`); the guard that a
stepped run leaves the library's editor queue as it found it
(`leavingLibraryQueue`); and the elaborator that shares one base between
every host of a process (`sharing`).

The kit's stage (`Editor.Test.Linked.Host`, `Stage.Fakes`, `Stage.stepped`)
is built on it, and so is the headless fixture harness
(`Editor.Test.Fixture.Stepped`), which links a set's real packages and so
imports neither the stage nor the kit's stand-ins for those packages.

It is apart from `Editor.Test.Linked.Services`, which `contract-test`
links: `sharing` names the real elaborator, and a test executable that
reaches it must link the config base (`.agents/rules/structure.md`,
"Core imports").

Published for a package's linked tests, as the rest of the linked test kit
is (`docs/design/packages.md`, "What a package may import").
-/

namespace Editor.Test.Linked

open Editor

/-- The fakes of a host stepped on its driver's thread, which the driver
steps: the job services (`SteppedServices`: the fake scheduler, the fake
pump, the file and process fakes), the memory queue the host drains, and
the session journal's and the syntax service's fakes once a maker has
added them, which are refs so the loop's end, made before them, steps them
too. -/
structure SteppedFakes where
  /-- The job services, all fakes. -/
  services : SteppedServices
  /-- The memory queue the stepped host drains. -/
  memory : Headless.Queue.Memory Ffi.Event
  /-- The session journal's recording fake, once a maker has added it. -/
  journal : IO.Ref (Option Headless.RecordingJournal)
  /-- The syntax service's fake, once a maker has added it. -/
  syntaxService : IO.Ref (Option FakeSyntaxService)

namespace SteppedFakes

/-- Runs one piece of the fakes' work on the caller's thread, in a fixed
order: a piece of a job's code, else a due completion, else a delivery of
the syntax fake, else an order of the journal fake; `false` when none can
run. It drains no queue: what a piece posts is the host's to take. -/
def stepWork (fakes : SteppedFakes) : IO Bool := do
  if ← fakes.services.step then
    return true
  if let some service← fakes.syntaxService.get then
    if ← service.step then
      return true
  if let some journal← fakes.journal.get then
    if ← journal.step then
      return true
  return false

/-- One piece of the fakes' work, as a stepped host's waits step it
(`Headless.Stepped.Work`). -/
def work (fakes : SteppedFakes) : Headless.Stepped.Work :=
  { step := fakes.stepWork }

/-- What of the fakes still holds work, by name: empty when they are
quiescent, every one stepped to its end. -/
def unquiet (fakes : SteppedFakes) : IO (Array String) := do
  let mut held := #[]
  unless ← fakes.services.scheduler.quiescent do
    held :=
      held.push
        s!"the fake scheduler holds {← fakes.services.scheduler.size} pieces of a job's code"
  unless ← fakes.services.pump.quiescent do
    held := held.push s!"the fake pump holds {← fakes.services.pump.size} due completions"
  if let some service← fakes.syntaxService.get then
    unless ← service.quiescent do
      held := held.push "the syntax fake holds an undelivered parse"
  if let some journal← fakes.journal.get then
    unless ← journal.quiescent do
      held := held.push s!"the journal fake holds {← journal.unworked} unworked orders"
  return held

/-- The loop's end over the fakes (`Headless.Collaborators.endCancelled`):
steps them on the end's thread, the driver's, until each job the end
cancelled has ended, and throws, naming it, when nothing can run first. -/
def endCancelled (fakes : SteppedFakes) (cancelled : Array (Task Unit)) : IO Unit := do
  for index in [0:cancelled.size] do
    let some job := cancelled[index]? | continue
    repeat
      if ← IO.hasFinished job then
        break
      unless ← fakes.stepWork do
        throw <|
            IO.userError
              s!"the loop's end cancelled {cancelled.size} jobs, and the job {index + 1} of them had not ended when nothing of the stepped host's fakes could run"

end SteppedFakes

/-- The number of events the library's editor queue holds, before and after
`body`: a stepped host's check must leave none there, where the next real
host would take them. Throws, naming them, when the queue grew, and takes
every event the queue held off it, so no later host takes them. -/
def leavingLibraryQueue {α : Type} (body : IO α) : IO α := do
  let before ← Ffi.queued .editor
  let result ← body
  let after ← Ffi.queued .editor
  if after > before then
    -- Taken off the queue, so the failure says what they were and no later
    -- host takes them; `takeQueued` never parks.
    let mut held := #[]
    for _ in [0:after.toNat] do
      let some event ← Ffi.takeQueued .editor | break
      held :=
        held.push
          s!"{repr event.source.kind} {event.source.id} {repr event.kind} {event.code} {event.text.quote}"
    throw <|
        IO.userError
          s!"a stepped host's check posted to the library's editor queue: it held {before} events and then {after}: {held}"
  return result

/-- `real` with one base shared by every caller, kept in `latest`: whatever
base a caller hands in, `base` grows the one in `latest` to hold the
modules asked for, keeps it and returns it. A module of the toolchain is
then read once in the process, whichever check first imports it: a second
read of a module file about doubles its memory. A base holds at least what
was asked for, which is all the port says of it. -/
def sharing (latest : IO.Ref (Option Config.Elaborate.Base))
    (real : Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle) :
    Config.Elaborator Config.Elaborate.Base Config.Elaborate.Handle :=
  { real with
    base := fun _ modules => do
      let base ← real.base (← latest.get) modules
      latest.set (some base)
      return base }

end Editor.Test.Linked
