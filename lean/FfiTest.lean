import Editor.Ffi

/-!
# Checks of the boundary with the Rust library

The `ffi-test` executable is linked exactly like `editor`: the same glue
object, Rust archive and entry point. It runs every check below, names the
ones that failed, and exits non-zero if any did. `mise run ffi-test` runs it.

Each check pins what the C glue and the entry point do, as Lean sees it. What
the Rust functions themselves compute is pinned by `editor-ffi`'s own tests.
-/

namespace FfiTest

/-- One behaviour of the boundary, and how to observe it. -/
structure Check where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the behaviour; `true` when it holds. -/
  run : IO Bool

/-- Every check, in the order they run.

This is a function, not a constant, because Lean evaluates a module's
constants in its initialiser, and an initialiser must not call the Rust
library (`docs/design/lean-runtime.md`). -/
def checks (_ : Unit) : List Check :=
  [{ name := "a Rust function's result crosses into Lean", run := pure (Editor.Ffi.add 2 3 == 5) },
    { name := "Lean code does not run on the process's main thread",
      run := return !(← Editor.Ffi.isMainThread) },
    { name := "work handed to the main-thread service runs on the process's main thread",
      run := Editor.Ffi.mainThreadProbe }]

/-- Runs `checks` and returns the names of those that failed. -/
def failures (checks : List Check) : IO (List String) :=
  checks.filterMapM fun check => do
    return if ← check.run then none else some check.name

end FfiTest

/-- Runs the checks. Exits 0 when all hold, and 1 after naming the ones that
do not. -/
def main : IO UInt32 := do
  let checks := FfiTest.checks ()
  let failed ← FfiTest.failures checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"ffi-test: {checks.length} checks passed"
    return 0
  else
    return 1
