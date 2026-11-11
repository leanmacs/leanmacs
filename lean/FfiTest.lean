import Editor.Ffi
import Lean.Environment
import Lean.Util.Path

/-!
# Checks of the boundary with the Rust library

The `ffi-test` executable is linked exactly like `editor`: the same glue
object, Rust archive and entry point. With no arguments it runs every check in
`checks`, names the ones that failed, and exits non-zero if any did.

Some behaviour needs a process of its own, so it is a scenario chosen by an
argument (see `main`): `exit <code>` for the exit status, `shutdown` and
`exit-while-blocked` because quitting the queues is for good, and `overflow`
because it ends in an abort. `mise run ffi-test` runs the checks and every
scenario, under a time limit.

Each check pins what the C glue and the entry point do, as Lean sees it. What
the Rust functions themselves compute is pinned by `editor-ffi`'s own tests.

A check never waits without a bound: a pull runs on a dedicated task that the
check polls (`pull`, `eventually`), so broken code fails a check within
seconds instead of hanging the executable.
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

/-- How many times a check polls, a millisecond apart, for something that
should happen at once: about five seconds. Only broken code takes this long,
and the check then fails instead of hanging. -/
def patience : Nat :=
  5000

/-- Polls `condition` until it holds; `false` if it still does not after
`patience` polls. -/
def eventually (condition : IO Bool) : IO Bool := do
  for _ in [0:patience] do
    if ← condition then
      return true
    IO.sleep 1
  return false

/-- One event pulled from `queue`, or `none` if the pull does not return in
time. The pull runs on a dedicated task, so one that never returns fails its
check instead of hanging the executable. -/
def pull (queue : Editor.Ffi.Queue) : IO (Option Editor.Ffi.Event) := do
  let task ← IO.asTask (prio := .dedicated) (Editor.Ffi.nextEvent queue)
  unless ← eventually (IO.hasFinished task) do
    return none
  return some (← IO.ofExcept task.get)

/-- The message `postEvent` queues for the Lean source `sourceId`. -/
def message (sourceId code : UInt64) (text : String) : Editor.Ffi.Event :=
  { source := { kind := .lean, id := sourceId }, kind := .message, code, text }

/-- Posts a message to the editor queue and pulls it back; `true` when what
comes back is that message, from the Lean source `sourceId`. -/
def roundTrips (sourceId code : UInt64) (text : String) : IO Bool := do
  unless ← Editor.Ffi.postEvent .editor sourceId code text do
    return false
  return (← pull .editor) == some (message sourceId code text)

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

/-- The checks of the two event queues: Rust threads push, Lean pulls. -/
def queueChecks (_ : Unit) : List Check :=
  [{ name := "events posted to a queue are pulled from that queue, in order",
     run := do
       let first ← Editor.Ffi.postEvent .editor 5 1 ""
       let other ← Editor.Ffi.postEvent .completion 5 2 ""
       let second ← Editor.Ffi.postEvent .editor 5 3 ""
       -- The completion queue first: were the two one queue, this would be
       -- the first event posted.
       let fromCompletion ← pull .completion
       let fromEditor := [← pull .editor, ← pull .editor]
       return first && other && second && fromCompletion == some (message 5 2 "") &&
           fromEditor == [some (message 5 1 ""), some (message 5 3 "")] },
    { name := "a pull parks until an event is posted to its queue"
      run := do
        let task ← IO.asTask (prio := .dedicated) (Editor.Ffi.nextEvent .completion)
        let parked ← eventually (return (← Editor.Ffi.waiting .completion) == 1)
        let othersParked ← Editor.Ffi.waiting .editor
        let finishedEarly ← IO.hasFinished task
        let posted ← Editor.Ffi.postEvent .completion 6 1 "wake"
        let woken ← eventually (IO.hasFinished task)
        unless parked && othersParked == 0 && !finishedEarly && posted && woken do
          return false
        return (← IO.ofExcept task.get) == message 6 1 "wake" },
    { name := "a script fed from a Rust thread arrives in order, tagged with its source"
      run := do
        unless ← Editor.Ffi.feedScript .completion 9 3 do
          return false
        for code in ([0, 1, 2] : List UInt64) do
          let some event ← pull .completion | return false
          unless
            event.source == { kind := .script, id := 9 } && event.kind == .message &&
              event.code == code do
            return false
        return true }]

/-- Every check, in the order they run. -/
def checks (_ : Unit) : List Check :=
  entryChecks () ++ handleChecks () ++ dataChecks () ++ queueChecks ()

/-- Runs `checks` and returns the names of those that failed. A check that
throws has failed, and its error is reported with its name. -/
def failures (checks : List Check) : IO (List String) :=
  checks.filterMapM fun check => do
    try
      return if ← check.run then none else some check.name
    catch error =>
      return some s!"{check.name} ({error})"

/-- The checks of shutdown, run by `ffi-test shutdown` in a process of their
own because quit is for good. They run in order: the first quits the queues. -/
def shutdownChecks (_ : Unit) : List Check :=
  [{ name := "quit wakes a task parked on each queue with a quit event",
     run := do
       let editor ← IO.asTask (prio := .dedicated) (Editor.Ffi.nextEvent .editor)
       let completion ← IO.asTask (prio := .dedicated) (Editor.Ffi.nextEvent .completion)
       let parked ←
         eventually do
             return (← Editor.Ffi.waiting .editor) == 1 && (← Editor.Ffi.waiting .completion) == 1
       Editor.Ffi.quit
       let returned ←
         eventually do
             return (← IO.hasFinished editor) && (← IO.hasFinished completion)
       unless parked && returned do
         return false
       let woken := [← IO.ofExcept editor.get, ← IO.ofExcept completion.get]
       return woken.all (·.kind == .quit) },
    { name := "after quit every pull returns a quit event at once"
      run := do
        let pulled := [← pull .editor, ← pull .completion, ← pull .editor]
        return pulled.all fun event => (event.map (·.kind)) == some .quit },
    { name := "after quit a post is refused"
      run := return !(← Editor.Ffi.postEvent .editor 1 1 "after quit") }]

/-- Parks a dedicated task in a pull that nothing will ever wake. `true` once
it is parked. -/
def blockForGood : IO Bool := do
  discard <| IO.asTask (prio := .dedicated) (Editor.Ffi.nextEvent .editor)
  eventually (return (← Editor.Ffi.waiting .editor) == 1)

/-- Prints a line of the overflow scenario and flushes it: the process is
about to abort, and an abort does not flush. -/
def say (line : String) : IO Unit := do
  IO.println s!"ffi-test overflow: {line}"
  (← IO.getStdout).flush

/-- The overflow scenario; see `overflow`. It is `unsafe` because evaluating a
constant from an environment trusts the type it is given. -/
unsafe def overflowUnsafe (sysroot oleanDir : String) : IO UInt8 := do
  Lean.initSearchPath ⟨sysroot⟩ [⟨oleanDir⟩]
  let env ← Lean.importModules #[{ module := `InterpretedFixture }] {}
  let shallow ← IO.ofExcept (env.evalConst (IO Nat) {} `InterpretedFixture.shallow)
  unless (← shallow) == 10 do
    say "the interpreter did not run the fixture's shallow recursion"
    return 1
  say "the interpreter runs the fixture; now a recursion deeper than its stack"
  let tooDeep ← IO.ofExcept (env.evalConst (IO Nat) {} `InterpretedFixture.tooDeep)
  let depth ← tooDeep
  say s!"the recursion returned {depth}, and the process is still running"
  return 1

/-- Has Lean's interpreter run a recursion that overflows its stack, on this
thread, with nothing in the way. The interpreter's stack check throws a C++
exception, nothing catches it, and the process dies of SIGABRT: that is the
outcome the scenario exists to show, so this returns only when something is
wrong, with the exit status 1.

`sysroot` is the Lean toolchain's directory and `oleanDir` the directory
holding `InterpretedFixture.olean`. -/
@[implemented_by overflowUnsafe]
opaque overflow (sysroot oleanDir : String) : IO UInt8

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
      "usage: ffi-test [exit <code> | shutdown | exit-while-blocked | overflow <sysroot> <olean dir>]"
  return 2

end FfiTest

/-- With no arguments, runs the checks: exits 0 when all hold, and 1 after
naming the ones that do not.

With the arguments `exit <code>`, exits with that status and does nothing
else. The `ffi-test` task uses this to see that the entry point passes the
arguments to Lean's `main` and makes its result the process's exit status.

`shutdown` runs the shutdown sequence: tasks parked in a pull on each queue,
quit, then an explicit exit, with status 0 when every task came back with a
quit event.

`exit-while-blocked` parks a task in a pull, never quits, and exits
explicitly with status 0. It shows that the process ends although a dedicated
task is still blocked in the library, which returning from `main` would wait
for.

`overflow <sysroot> <olean dir>` has the interpreter run a recursion deeper
than its stack. Nothing catches the C++ exception the interpreter throws, so
the process dies of SIGABRT, and the `ffi-test` task requires exactly that.
Any exit status of its own means the scenario went wrong. -/
def main (args : List String) : IO UInt32 := do
  match args with
  | [] =>
    if (← FfiTest.run "ffi-test" (FfiTest.checks ())) == 0 then
      return 0
    else
      -- A failed check may have left a task parked in the library, and
      -- returning from `main` would wait for it for ever.
      IO.Process.exit 1
  | ["shutdown"] =>
    IO.Process.exit (← FfiTest.run "ffi-test shutdown" (FfiTest.shutdownChecks ()))
  | ["exit-while-blocked"] =>
    IO.Process.exit (if ← FfiTest.blockForGood then 0 else 1)
  | ["overflow", sysroot, oleanDir] =>
    IO.Process.exit (← FfiTest.overflow sysroot oleanDir)
  | ["exit", code] =>
    match code.toNat? with
    | some status =>
      return status.toUInt32
    | none =>
      FfiTest.usage
  | _ =>
    FfiTest.usage
