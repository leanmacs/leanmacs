import Editor.Ffi.Launch
import Editor.Restart.Handover

/-!
# The restart's exec, at the edge

`Restart.real` is the exec the executable's hosts are handed as their
collaborators' (`Headless.Collaborators.replace`), and exec a restart's
plan through once they have shut down (`Restart.Plan.exec`,
`Editor/Restart/Handover.lean`): the library's exec (`Ffi.exec`), which
replaces the process and keeps its id. It answers only when the exec
failed, with the reason; the host then says so and exits 1, and the
session it wrote is restored at the next start. A host handed none refuses
(`Restart.noExec`).

It is imported by the hosts alone (`Editor/Headless.lean`,
`Editor/Window/Real.lean`, `Editor/Main.lean`): it links the Rust library.
-/

namespace Editor.Restart

/-- Execs `invocation` in place of this process; answers only when the exec
failed, with the reason. -/
def real (invocation : Invocation) : IO String :=
  Ffi.exec invocation.program.toString invocation.arguments

end Editor.Restart
