/-!
# Code for the interpreter to run

`ffi-test overflow`, which `mise run ffi-overflow` runs on demand, loads this
module from its `.olean` at runtime and has Lean's interpreter run it. The
gate builds it but does not run it. Nothing imports it, so it is never linked
into an
executable. Were it linked, `tooDeep` would run as native code and overflow
the real stack, instead of tripping the interpreter's stack check.
-/

namespace InterpretedFixture

/-- `n`, by a recursion `n` frames deep. Not a tail call, so every step keeps
its frame. -/
def depth : Nat → Nat
  | 0 => 0
  | n + 1 => depth n + 1

/-- A recursion a few frames deep: shows the interpreter runs this module. -/
def shallow : IO Nat :=
  return depth 10

/-- A recursion far deeper than any stack. The interpreter's stack check ends
it by throwing a C++ exception. -/
def tooDeep : IO Nat :=
  return depth 100000000

end InterpretedFixture
