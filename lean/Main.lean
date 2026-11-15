import Editor.Command.Append
import Editor.Executable
import Editor.Headless
import Editor.Window.Real
import Editor.WindowCheck.Real

/-!
# The executable

Lean owns the process. `main` acts on the mode the command line selects
(`Editor/Executable.lean`, which pins the dispatch as a pure function).

`editor demo` only shows the build works: it calls the Rust library and
prints what comes back, and it runs one command against the library through
the text port's real binding.

`editor headless [--render] [<sysroot> <olean dir>] <config dir> <script file>`
is the headless mode (`Editor/Headless.lean`): it loads the config in a
directory, runs a script against it and prints what happened, for
integration tests; with `--render` what it publishes is drawn by the
library's headless render session. The toolchain's directory and the
editor's `.olean` directory may be left out in an app bundle, which holds
both (`Editor/ModuleLookup.lean`). `Main` hands it the rest of the command
line after `headless`, and the headless mode reads that itself.

`editor window-check [--seconds <n>] [--no-ime]` is the keyboard check
(`Editor/WindowCheck.lean`): it opens a window and reports what of the
keyboard reached a Lean loop. A person runs it; nothing in the gate does.

Any other command line is the window mode's,
`editor [--config <dir>] [--sysroot <dir>] [--oleans <dir>] [--no-ime] [<file>]`
(`Editor/Window.lean`, `Editor/Window/Real.lean`): the editor in a window,
on a file, or on its one empty buffer when none is given. An empty command
line is that, which is how Finder starts the app. So a file called `demo`,
`headless` or `window-check` is opened as `./demo`. A command line the
window mode does not take, an option it does not know or two files, is
reported with its usage, with the exit status 2.
-/

/-- The command the executable runs: it makes a text, appends to it and reads
it back. `Editor.append` is the command the model tests run against the pure
model (`ModelTest.commandProperties`); here the same source runs against the
Rust library. -/
def greeting : Editor.TextM String := do
  let text ← Editor.createText "héllo"
  Editor.append text " wörld"
  text.read

/-- Calls the Rust library, prints the results, and returns non-zero if one is
not what it should be. -/
def demo : IO UInt32 := do
  let sum := Editor.Ffi.add 2 3
  IO.println s!"Rust says 2 + 3 = {sum}"
  let leanOnMain ← Editor.Ffi.isMainThread
  IO.println s!"Lean's main is on the process's main thread: {leanOnMain}"
  let serviceOnMain ← Editor.Ffi.mainThreadProbe
  IO.println s!"The main-thread service is on the process's main thread: {serviceOnMain}"
  let appended ←
    match (← greeting.runReal (← Editor.RealTexts.new)).1 with
    | .ok text =>
      IO.println s!"A command appended to a text held by Rust: {text}"
      pure (text == "héllo wörld")
    | .error refusal =>
      IO.println s!"A command run against the Rust library was refused: {repr refusal}"
      pure false
  return if sum == 5 && !leanOnMain && serviceOnMain && appended then 0 else 1

/-- Runs the mode the command line selects (`Executable.mode`). The match
is exhaustive on purpose: `main` must act on every mode.

With `demo`, the demonstration. With `headless`, the headless mode, handed
the rest of the command line, which exits with its own status: 0 when the
script ran to its end, 1 when it could not, and 2 for a command line it does
not take. With `window-check`, the keyboard check, which opens a window and
exits with its own status: 0 when the window ran and 1 when it could not be
opened. Any other command line, an empty one too, is the window mode's,
which opens a window, on a file when one is given, and exits 0 when the
window ran, 1 when it could not be opened, and 2, with its usage, for a
command line it does not take. -/
def main (args : List String) : IO UInt32 := do
  match Editor.Executable.mode args with
  | .demo =>
    demo
  | .headless rest =>
    Editor.Headless.main rest
  | .windowCheck options =>
    Editor.WindowCheck.main options
  | .window arguments =>
    Editor.Window.main arguments
