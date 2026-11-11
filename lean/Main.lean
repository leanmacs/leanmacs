import Editor.Ffi

/-!
# The editor executable

Lean owns the process. For now `main` only shows the build works: it calls the
Rust library and prints what comes back.
-/

/-- Calls the Rust library, prints the results, and exits non-zero if one is
not what it should be. -/
def main : IO UInt32 := do
  let sum := Editor.Ffi.add 2 3
  IO.println s!"Rust says 2 + 3 = {sum}"
  let leanOnMain ← Editor.Ffi.isMainThread
  IO.println s!"Lean's main is on the process's main thread: {leanOnMain}"
  let serviceOnMain ← Editor.Ffi.mainThreadProbe
  IO.println s!"The main-thread service is on the process's main thread: {serviceOnMain}"
  return if sum == 5 && !leanOnMain && serviceOnMain then 0 else 1
