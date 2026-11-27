import Echo.Real
import EchoTest.Check
import Editor.RealHost
import Editor.Restore.Restart
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Services

/-!
# Linked tests: the fixture set's editor loads echo's library when it starts

The editor the package-set build made from the fixture set
(`<set>/.lake/build/bin/editor`, built by `tools/package-set.sh build`
before any linked test runs) is run with `--probe`, through the linked test
kit's real process port, as the package-set build runs its probe. Echo's
`builtin_initialize` (`Echo.Real`) loads the library before the editor's
`main`, so the probe reaches `probe: ok` and exits 0 only once the library
loaded: a refused load ends it with status 1 and the refusal on standard
error. The check holds the run to the build's own judgement,
`Editor.Restore.probeFailure`.

The fixture set is the package's parent directory: the linked test runs in
the package's directory (`tools/package-set.sh`). The wait on the run's
completion is on the completion itself, the kit's patience a hang guard.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.EchoTest.Linked.Echo.Real.Probe : Editor.WiringSet :=
  .wiring "the fixture set's editor, run through the real process port"
    "only a real executable runs its module initialisers; no fake starts one"

namespace EchoTest.Linked

open Editor

/-- The probe of the fixture set's editor: runs it with `--probe` from `/`
through the real process port, and checks that it passed as the
package-set build judges a probe. -/
def echoProbeChecks (services : Editor.Test.Linked.Services) : List Check :=
  let processes := services.jobs.processes
  let completions := services.completions
  [{  name :=
        "an editor the package-set build made from the fixture set loads echo's library when it starts: its --probe passes as the build judges it"
      run := do
        let editor ← IO.FS.realPath (".." / ".lake" / "build" / "bin" / "editor")
        let request :=
          ProcessRequest.run
            { program := editor.toString, arguments := #["--probe"], directory := "/" } 65536
        let (id, wait) ← completions.register
        processes.start id request
        -- Waited for on the run's own completion; the kit's patience is a
        -- hang guard.
        let ended ← Job.awaitWithin Test.Linked.patience wait.result?
        unless ended == some (some .completed) do
          return ← saw false s!"the probe's run did not complete: {repr ended}"
        match ← processes.take id request with
        | .ok ran =>
          let failure := Editor.Restore.probeFailure ran
          saw (failure == none) s!"{failure.getD ""}"
        | .error error =>
          saw false error.describe }]

end EchoTest.Linked
