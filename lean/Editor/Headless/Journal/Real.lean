import Editor.Ffi.Files
import Editor.Headless.Journal
import Editor.Job.Runner
import Editor.RealHost
import Editor.Text.Real

/-!
# The session journal over the library's file service

The real adapter of the journal's port (`Editor/Headless/Journal.lean`):
`Journal.real`, which the executable's hosts are handed
(`Collaborators.journal`, `Editor/Headless.lean`). Each order is an
unobserved request of the library's file service, so the editor thread
hands it and waits on nothing; what failed is taken from the service's
failures (`Ffi.filesFailure`); and the drain is a flush of the service
through the job services (`Job.Services.flushed`), the journal's own
signal.

It is pinned by the port's contract run over it in `contract-test`
(`ContractTest.journalContractChecks`), with the file service's worker held
in process and its drain waited on.
-/

namespace Editor.Headless

/-- The mark of `Journal.real`: it runs a real background service (`Editor/RealHost.lean`). -/
def Journal.real.realHost : RealHost :=
  .service

/-- The journal over the library's file service: each order an unobserved
request (`Ffi.filesAppendUnobserved`, `Ffi.filesRemoveUnobserved`,
`Ffi.filesSaveUnobserved` of the snapshot `published` holds), its failures
taken with `Ffi.filesFailure`, and its drain a flush of the file service
through `services` (`Job.Services.flushed`), whose table's pump must run. -/
def Journal.real (published : SnapshotReader) (services : Job.Services) : Journal where
  perform order := do
    match order.request with
    | .append path bytes =>
      discard <| Ffi.filesAppendUnobserved path.toString bytes
    | .remove path =>
      discard <| Ffi.filesRemoveUnobserved path.toString
    | .save (.snapshot id) path _ =>
      if let some snapshot← published.find? id then
        discard <| Ffi.filesSaveUnobserved snapshot path.toString
    | _ =>
      pure ()
  failures := do
    let mut taken := #[]
    repeat
      let some failure ← Ffi.filesFailure | break
      taken := taken.push failure
    return taken
  drained := do
    let flushed ← services.flushed .files
    return flushed.map (sync := true) (· == .completed)

end Editor.Headless
