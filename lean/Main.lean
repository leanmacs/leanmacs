import Editor.Command.Append
import Editor.Headless
import Editor.WindowCheck.Real

/-!
# The editor executable

Lean owns the process. With no arguments `main` only shows the build works:
it calls the Rust library and prints what comes back, and it runs one command
against the library through the text port's real binding.

`editor headless <sysroot> <olean dir> <config dir> <script file>` is the
headless mode (`Editor/Headless.lean`): it loads the config in a directory,
runs a script against it and prints what happened, for integration tests.

`editor window-check [--seconds <n>] [--no-ime]` is the keyboard check
(`Editor/WindowCheck.lean`): it opens a window and reports what of the
keyboard reached a Lean loop. A person runs it; nothing in the gate does.

Any other command line is reported, with the exit status 2.
-/

/-- The command the executable runs: it makes a text, appends to it and reads
it back. `Editor.append` is the command the model tests run against the pure
model (`ModelTest.commandProperties`); here the same source runs against the
Rust library. -/
def greeting : Editor.EditorM String := do
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

/-- With no arguments, the demonstration. With `headless` and four paths, the
headless mode, which exits with its own status: 0 when the script ran to its
end and 1 when it could not. With `window-check`, the keyboard check, which
opens a window and exits with its own status: 0 when the window ran and 1
when it could not be opened. Anything else is bad usage, with status 2. -/
def main (args : List String) : IO UInt32 := do
  match args with
  | [] =>
    demo
  | ["headless", sysroot, oleanDir, configDir, script] =>
    Editor.Headless.main sysroot oleanDir configDir script
  | "window-check" :: options =>
    Editor.WindowCheck.main options
  | _ =>
    IO.eprintln
        "usage: editor [headless <sysroot> <olean dir> <config dir> <script file> | window-check [--seconds <n>] [--no-ime]]"
    return 2
