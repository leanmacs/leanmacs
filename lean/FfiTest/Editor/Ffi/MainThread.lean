import Editor.Ffi.Counter
import Editor.Ffi.MainThread
import Editor.Ffi.Processes
import FfiTest.Check
import FfiTest.Support.Files
import FfiTest.Support.Processes
import Lean.Environment
import Lean.Util.Path

/-!
# FFI tests: `Editor/Ffi/MainThread.lean`

The tests of `Editor/Ffi/MainThread.lean` and of the entry point it
reads: `entryChecks`, and the `overflow` scenario (`say`, `overflowMarker`, `overflowUnsafe`, `overflow`). The root
module `FfiTest` runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- The least stack, in bytes, the thread that runs Lean's generated `main`
must have: 64 MiB, the size the entry point asks for. Module initialisers run
on it, and a thread's default stack is 512 KiB. -/
def entryStackSize : USize :=
  64 * 1024 * 1024

/-- Whether `size`, in bytes, is the stack the entry point gives every thread
Lean creates: 64 MiB, to which Lean adds 128 KiB. Lean's own default is a
gigabyte, and a thread's default is 512 KiB. -/
def isEditorStack (size : USize) : Bool :=
  size >= 64 * 1024 * 1024 && size < 65 * 1024 * 1024

/-- The checks of the entry point and of a plain call. -/
def entryChecks (_ : Unit) : List Check :=
  [{ name := "a Rust function's result crosses into Lean", run := pure (Editor.Ffi.add 2 3 == 5) },
    { name := "Lean code does not run on the process's main thread",
      run := return !(← Editor.Ffi.isMainThread) },
    { name := "work handed to the main-thread service runs on the process's main thread",
      run := Editor.Ffi.mainThreadProbe },
    { name := "Lean's generated main runs on a thread with a large stack",
      run := return (← Editor.Ffi.entryStackSize) >= entryStackSize },
    { name :=
        "every thread Lean creates has the editor's stack: Lean's main thread, a dedicated task and a pool task"
      run := do
        let onMain ← Editor.Ffi.threadStackSize
        let dedicated ← IO.asTask (prio := .dedicated) Editor.Ffi.threadStackSize
        let pool ← IO.asTask Editor.Ffi.threadStackSize
        let onDedicated ← IO.ofExcept (← IO.wait dedicated)
        let onPool ← IO.ofExcept (← IO.wait pool)
        return isEditorStack onMain && isEditorStack onDedicated && isEditorStack onPool },
    { name :=
        "the entry point hands the command line to Lean's main and makes its result the process's exit status: this executable run as a child of the library's process service with exit 7 ends with status 7"
      run :=
        inOwnDirectory (targets := [filesFlushed, processesFlushed]) fun directory => do
          let executable ← IO.appPath
          unless
            ←
              Editor.Ffi.processesRun 1180 executable.toString #["exit", "7"] false #[] #[]
                  directory.toString 65536 do
            return false
          unless ← processCompleted 1180 do
            return false
          return (← Editor.Ffi.processesTake 1180) matches some (.ran (.code 7) _ _) }]

/-- Prints a line of the overflow scenario and flushes it: the process is
about to abort, and an abort does not flush. -/
def say (line : String) : IO Unit := do
  IO.println s!"ffi-test overflow: {line}"
  (← IO.getStdout).flush

/-- What the overflow scenario says just before it recurses. The
`ffi-overflow` task in `mise.toml` requires this to be the last line of
stdout. -/
def overflowMarker : String :=
  "entering the recursion"

/-- The overflow scenario; see `overflow`. It is `unsafe` because evaluating a
constant from an environment trusts the type it is given. -/
unsafe def overflowUnsafe (sysroot oleanDir : String) : IO UInt8 := do
  try
    Lean.initSearchPath ⟨sysroot⟩ [⟨oleanDir⟩]
    let env ← Lean.importModules #[{ module := `InterpretedFixture }] {}
    let shallow ← IO.ofExcept (env.evalConst (IO Nat) {} `InterpretedFixture.shallow)
    let tooDeep ← IO.ofExcept (env.evalConst (IO Nat) {} `InterpretedFixture.tooDeep)
    unless (← shallow) == 10 do
      say "the interpreter did not run the fixture's shallow recursion"
      return 1
    say overflowMarker
    let depth ← tooDeep
    say s!"the recursion returned {depth}, and the process is still running"
    return 1
  catch error =>
    say s!"Lean caught an error: {error}"
    return 1

/-- Has Lean's interpreter run a recursion that overflows its stack, on this
thread, inside a Lean `try`/`catch`. The interpreter's stack check throws a
C++ exception, which the Lean handler does not see and nothing else catches,
and the process dies of SIGABRT: that is the outcome the scenario exists to
show. So this returns only when something is wrong, with the exit status 1.

Before it recurses it has the interpreter run a shallow recursion from the
same module and checks the value, then prints the marker line. The marker is
therefore the last line of stdout exactly when the process died in the deep
recursion and nowhere earlier.

`sysroot` is the Lean toolchain's directory and `oleanDir` the directory
holding `InterpretedFixture.olean`. -/
@[implemented_by overflowUnsafe]
opaque overflow (sysroot oleanDir : String) : IO UInt8

end FfiTest
