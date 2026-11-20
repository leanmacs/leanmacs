import Editor.Ffi.Launch
import Editor.Restart.Handover

/-!
# The restart's exec, at the edge

`Restart.real` is what the executable's hosts exec a restart's plan with
(`Restart.Plan.invocation`, `Editor/Restart/Handover.lean`), once they have
shut down: the library's exec (`Ffi.exec`), which replaces the process and
keeps its id. It answers only when the exec failed, with the reason; a
host then says so and exits, and the session it wrote is restored at the
next start. A host that has none refuses (`Headless.Collaborators.replace`).

It is imported by the hosts alone (`Editor/Headless.lean`,
`Editor/Window/Real.lean`, `Editor/Main.lean`): it links the Rust library.
-/

namespace Editor.Restart

/-- Execs `invocation` in place of this process; answers only when the exec
failed, with the reason. -/
def real (invocation : Invocation) : IO String :=
  Ffi.exec invocation.program.toString invocation.arguments

end Editor.Restart
