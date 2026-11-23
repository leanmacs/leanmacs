import Editor.Restore

/-!
# The session journal's port

How a host hands the session journal's orders (`Loop.Stepped.journal`,
`Editor/Restore.lean`) to its file service, and reads back what failed: the
port `Journal`, which a host reaches through `Collaborators.journal`
(`Editor/Headless.lean`). It imports the reconciler's orders and nothing
else: no `Lean` and no `Ffi`, so the port, its fake and its contract link
into `model-test`, which links no Rust library.

Three things are written over it:

- the real adapter, `Journal.real` (`Editor/Headless/Journal/Real.lean`),
  each order an unobserved request of the library's file service and its
  drain a flush of that service;
- the recording fake, `RecordingJournal`
  (`Editor/Headless/Journal/Fake.lean`), which records each order with the
  thread that handed it and works it on a model of files only when a check
  steps it;
- the contract both keep (`Editor/Headless/Journal/Contract.lean`), run over
  the fake by `model-test` (`ModelTest.journalContractChecks`) and over the
  real adapter by `contract-test` (`ContractTest.journalContractChecks`).

## Where an addition goes

- A new capability of the port is a field of `Journal` here, with a default
  that does nothing, for a host with no file service.
- What every adapter must do with it is a property of the contract, run by
  both runners; what only the fake shows (that it answers on the check's
  step) is a fake-only check beside the model-test runner.
- What the host does with the port is pinned by the host's checks over the
  fake (`ConfigTest.journalOrderChecks`), never here.
-/

namespace Editor.Headless

/-- How a host hands the session journal's orders to its file service
(`Loop.Stepped.journal`, `Editor/Restore.lean`), and reads back what failed.
The default does nothing, for a host with no file service. -/
structure Journal where
  /-- Hands one order to the file service, unobserved: nothing waits on it. -/
  perform : Restore.Order → IO Unit := fun _ => pure ()
  /-- Takes what failed of the orders handed so far, each a path and why,
  oldest first, once. -/
  failures : IO (Array (String × String)) := pure #[]
  /-- Flushes the file service: a task that ends `true` once every order
  handed before it has been worked, and `false` if the service refused the
  flush. The default has nothing to wait for. -/
  drained : IO (Task Bool) := pure (.pure true)

end Editor.Headless
