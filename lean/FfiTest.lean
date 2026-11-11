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

/-- The checks of the entry point and of a plain call.

This and the lists after it are functions, not constants, because Lean
evaluates a module's constants in its initialiser, and an initialiser must not
call the Rust library (`docs/design/lean-runtime.md`). -/
def entryChecks (_ : Unit) : List Check :=
  [{ name := "a Rust function's result crosses into Lean", run := pure (Editor.Ffi.add 2 3 == 5) },
    { name := "Lean code does not run on the process's main thread",
      run := return !(← Editor.Ffi.isMainThread) },
    { name := "work handed to the main-thread service runs on the process's main thread",
      run := Editor.Ffi.mainThreadProbe },
    { name := "Lean's generated main runs on a thread with a large stack",
      run := return (← Editor.Ffi.entryStackSize) >= entryStackSize }]

/-- Makes a counter starting at `start`, increments it twice and drops it. Only
plain data leaves: the second count. -/
def useCounter (start : UInt64) : IO UInt64 := do
  let counter ← Editor.Ffi.Counter.new start
  discard counter.increment
  counter.increment

/-- The checks of a handle: a Rust object held by Lean as an external object
(`Editor.Ffi.Counter`). -/
def handleChecks (_ : Unit) : List Check :=
  [{ name := "a counter keeps its count in Rust", run := return (← useCounter 40) == 42 },
    { name := "a counter is freed when Lean drops the last reference"
      run := do
        let before ← Editor.Ffi.Counter.live
        discard <| useCounter 0
        return (← Editor.Ffi.Counter.live) == before },
    { name := "a counter stays alive while any reference is held, on any thread"
      run := do
        let before ← Editor.Ffi.Counter.live
        let counter ← Editor.Ffi.Counter.new 0
        let task ← IO.asTask (prio := .dedicated) counter.increment
        let fromTask ← IO.ofExcept (← IO.wait task)
        let live ← Editor.Ffi.Counter.live
        let fromMain ← counter.increment
        return fromTask == 1 && live == before + 1 && fromMain == 2 },
    { name := "a counter whose last reference is dropped on another thread is freed"
      run := do
        let before ← Editor.Ffi.Counter.live
        let counter ← Editor.Ffi.Counter.new 5
        -- The task's closure is the only holder from here on.
        let task ← IO.asTask (prio := .dedicated) counter.increment
        let fromTask ← IO.ofExcept (← IO.wait task)
        return fromTask == 6 && (← Editor.Ffi.Counter.live) == before }]

/-- Text whose byte offsets and character counts differ: "é" and "ö" are two
bytes each. -/
def haystack : String :=
  "héllo wörld, hello"

/-- Posts a message to the editor queue and pulls it back; `true` when what
comes back is that message, from the Lean source `sourceId`. A refused post
fails the check at once, so the pull cannot park. -/
def roundTrips (sourceId code : UInt64) (text : String) : IO Bool := do
  unless ← Editor.Ffi.postEvent .editor sourceId code text do
    return false
  let event ← Editor.Ffi.nextEvent .editor
  return event == { source := { kind := .lean, id := sourceId }, kind := .message, code, text }

/-- The checks of plain data: an option and a byte range (`Editor.Ffi.find`),
and a string, enums and a small structure (an event), in both directions. -/
def dataChecks (_ : Unit) : List Check :=
  [{ name := "find returns the byte range of the first match",
     run := pure (Editor.Ffi.find haystack "llo" == some { start := 3, stop := 6 }) },
    { name := "find starts looking at the start offset it is given"
      run := pure (Editor.Ffi.find haystack "llo" (some 4) == some { start := 17, stop := 20 }) },
    { name := "find returns none when there is no match from a usable start"
      run :=
        pure
          (Editor.Ffi.find haystack "zzz" == none &&
            Editor.Ffi.find haystack "llo" (some 2) == none &&
            Editor.Ffi.find haystack "llo" (some 21) == none) },
    { name := "an event posted to a queue is pulled back whole"
      run := roundTrips 7 42 "héllo wörld" },
    { name := "an event's text keeps an embedded NUL byte"
      run := roundTrips 8 43 "before\x00after" },
    { name := "an event with empty text and the largest code crosses"
      run := roundTrips 9 0xFFFFFFFFFFFFFFFF "" },
    { name := "a tag the bindings do not know is refused"
      run :=
        pure ((Editor.Ffi.EventKind.ofTag? 2).isNone && (Editor.Ffi.SourceKind.ofTag? 3).isNone) }]

/-- Every check, in the order they run. -/
def checks (_ : Unit) : List Check :=
  entryChecks () ++ handleChecks () ++ dataChecks ()

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
