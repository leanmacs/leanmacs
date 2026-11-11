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
  return if sum == 5 then 0 else 1
