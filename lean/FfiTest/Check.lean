/-!
# FFI tests: the check

The type of one check of the boundary, `Check`; `failures`, which runs a list of
them; `run`, which runs a list and reports it; and `usage`, the command line
`main` does not understand. Every test module that writes a check imports this
one (the root module `FfiTest` describes the layout). This module needs nothing
of the editor.
-/

namespace FfiTest

/-- One behaviour of the boundary, and how to observe it. -/
structure Check where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the behaviour; `true` when it holds. -/
  run : IO Bool

/-- Runs `checks` and returns the names of those that failed. A check that
throws has failed, and its error is reported with its name. -/
def failures (checks : List Check) : IO (List String) :=
  checks.filterMapM fun check => do
    try
      return if ← check.run then none else some check.name
    catch error =>
      return some s!"{check.name} ({error})"

/-- Runs `checks`, names on stderr the ones that failed, and returns the exit
status: 0 when all hold, 1 otherwise. `scenario` names the run in the line
printed on success. -/
def run (scenario : String) (checks : List Check) : IO UInt8 := do
  let failed ← failures checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    return 1
  IO.println s!"{scenario}: {checks.length} checks passed"
  return 0

/-- Reports a command line `main` does not understand; the exit status is 2. -/
def usage : IO UInt32 := do
  IO.eprintln
      "usage: ffi-test [wiring] <test grammars dir> | ffi-test [exit <code> | shutdown | exit-while-blocked | overflow <sysroot> <olean dir> | display <fixture> | theme-pictures <dir> <font> [--write] | window-host [<file>] | window-host-config <sysroot> <olean dir> <config dir> | window-host-base <sysroot> <olean dir> <config dir> | window-host-generate <sysroot> <olean dir> <config dir> | window-host-direct <editor> <sysroot> <config dir> | window-host-undrawn <file>]"
  return 2

end FfiTest
