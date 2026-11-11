import Editor.Command.Append
import Editor.Text.Real

/-!
# The editor executable

Lean owns the process. For now `main` only shows the build works: it calls the
Rust library and prints what comes back, and it runs one command against the
library through the text port's real binding.
-/

/-- The command the executable runs: it makes a text, appends to it and reads
it back. `Editor.append` is the command the model tests run against the pure
model (`ModelTest.commandProperties`); here the same source runs against the
Rust library. -/
def greeting : Editor.EditorM String := do
  let text ← Editor.createText "héllo"
  Editor.append text " wörld"
  text.read

/-- Calls the Rust library, prints the results, and exits non-zero if one is
not what it should be. -/
def main : IO UInt32 := do
  let sum := Editor.Ffi.add 2 3
  IO.println s!"Rust says 2 + 3 = {sum}"
  let leanOnMain ← Editor.Ffi.isMainThread
  IO.println s!"Lean's main is on the process's main thread: {leanOnMain}"
  let serviceOnMain ← Editor.Ffi.mainThreadProbe
  IO.println s!"The main-thread service is on the process's main thread: {serviceOnMain}"
  let appended ←
    match (← greeting.runReal #[]).1 with
    | .ok text =>
      IO.println s!"A command appended to a text held by Rust: {text}"
      pure (text == "héllo wörld")
    | .error refusal =>
      IO.println s!"A command run against the Rust library was refused: {repr refusal}"
      pure false
  return if sum == 5 && !leanOnMain && serviceOnMain && appended then 0 else 1
