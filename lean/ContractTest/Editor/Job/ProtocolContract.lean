import ContractTest.Check
import Editor.Job.Fake
import Editor.Job.ProtocolContract
import Editor.Job.Runner
import Editor.Test.Linked.Services

/-!
# Contract tests: `Editor/Job/ProtocolContract.lean`

The runner's protocol contract over the library's real services, on real
threads: `protocolContractChecks`. Jobs sleep on the library's timer
service, load a real file through its file service, and one is cancelled in
a long sleep; the pump and the pool's threads take whatever interleaving
they take, and the trace the fake recorder keeps must replay on the model
all the same. The property does not depend on scheduling: every wait is on
an event, the recorder's or a job's, bounded only by a hang guard. The root
module `ContractTest` runs it over the services it starts. It starts no
host loop.
-/

namespace ContractTest

open Editor
open Editor.Job

/-- The checks of the runner's protocol over the library's services. -/
def protocolContractChecks (services : Job.Services) : List Check :=
  [{  name :=
        "the runner over the library's timer and file services, on real threads, records a trace that is a run of the protocol, whatever interleaving its threads take"
      run :=
        Editor.Test.Linked.withFiles services fun directory => do
          let path := directory / "a.txt"
          IO.FS.writeFile path "a"
          let recorder ← FakeRecorder.new
          let services := { services with recorder := recorder.recorder }
          let spawn (work : Work) := Job.spawn services work (pure ())
          let mut handles := #[]
          for _ in [0:3] do
            handles := handles.push (← spawn (ProtocolContract.sleeper 1))
          for _ in [0:2] do
            handles := handles.push (← spawn (ProtocolContract.loader path))
          let long ← spawn (ProtocolContract.sleeper 60000)
          let quick ← spawn ProtocolContract.idler
          -- The long sleep is cancelled once it is in its wait, a real
          -- timer's, which keeps the job's unit: its serve.
          discard <|
              ProtocolContract.awaitStep "the long sleep's serve"
                (← recorder.reached (· == .serve long.job.number))
          long.cancel
          ProtocolContract.finishedAll (handles ++ #[long, quick])
          let trace ← recorder.trace
          let state ← ProtocolContract.replayed trace
          unless
            state.jobs.length == 7 && state.count == 0 &&
              trace.contains (.cancel long.job.number) do
            throw (IO.userError s!"saw trace={repr trace}")
          return true }]

end ContractTest
