import Editor.Ffi

/-!
# Checks of the boundary with the Rust library

The `ffi-test` executable is linked exactly like `editor`: the same glue
object, Rust archive and entry point. It runs every check below, names the
ones that failed, and exits non-zero if any did. `mise run ffi-test` runs it,
and also runs `ffi-test exit 7` to see the exit status arrive.

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

/-- The least stack, in bytes, the thread that runs Lean's generated `main`
must have: 64 MiB, the size the entry point asks for. Module initialisers run
on it, and a thread's default stack is 512 KiB. -/
def entryStackSize : USize :=
  64 * 1024 * 1024

/-- Every check, in the order they run.

This is a function, not a constant, because Lean evaluates a module's
constants in its initialiser, and an initialiser must not call the Rust
library (`docs/design/lean-runtime.md`). -/
def checks (_ : Unit) : List Check :=
  [{ name := "a Rust function's result crosses into Lean", run := pure (Editor.Ffi.add 2 3 == 5) },
    { name := "Lean code does not run on the process's main thread",
      run := return !(← Editor.Ffi.isMainThread) },
    { name := "work handed to the main-thread service runs on the process's main thread",
      run := Editor.Ffi.mainThreadProbe },
    { name := "Lean's generated main runs on a thread with a large stack",
      run := return (← Editor.Ffi.entryStackSize) >= entryStackSize }]

/-- Runs `checks` and returns the names of those that failed. -/
def failures (checks : List Check) : IO (List String) :=
  checks.filterMapM fun check => do
    return if ← check.run then none else some check.name

/-- Reports a command line `main` does not understand; the exit status is 2. -/
def usage : IO UInt32 := do
  IO.eprintln "usage: ffi-test [exit <code>]"
  return 2

end FfiTest

/-- With no arguments, runs the checks: exits 0 when all hold, and 1 after
naming the ones that do not.

With the arguments `exit <code>`, exits with that status and does nothing
else. The `ffi-test` task uses this to see that the entry point passes the
arguments to Lean's `main` and makes its result the process's exit status. -/
def main (args : List String) : IO UInt32 := do
  match args with
  | [] =>
    let checks := FfiTest.checks ()
    let failed ← FfiTest.failures checks
    for name in failed do
      IO.eprintln s!"FAILED: {name}"
    if failed.isEmpty then
      IO.println s!"ffi-test: {checks.length} checks passed"
      return 0
    else
      return 1
  | ["exit", code] =>
    match code.toNat? with
    | some status =>
      return status.toUInt32
    | none =>
      FfiTest.usage
  | _ =>
    FfiTest.usage
