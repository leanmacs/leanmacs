/-!
# A module with state, linked and imported at runtime

`config-test` imports this module, so it is compiled into that executable and
its initialiser runs once, when the process starts. The same process then
imports the module's `.olean` at runtime, as part of the base that config is
elaborated on, and has the interpreter run config that calls `bump`.

The check that uses it (`ConfigTest.elaboratorChecks`) shows that compiled
code and config see one cell: each reads what the other wrote, and the
runtime import did not run the initialiser a second time.
-/

namespace ConfigFixture

/-- A number that starts at 100, in a reference the module's initialiser
makes. -/
initialize cell : IO.Ref Nat ←
  IO.mkRef 100

/-- Adds one to the cell and returns its new value. -/
def bump : IO Nat :=
  cell.modifyGet fun count => (count + 1, count + 1)

end ConfigFixture
