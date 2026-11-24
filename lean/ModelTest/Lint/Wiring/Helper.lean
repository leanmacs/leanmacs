/-!
# Model tests: `Lint/Wiring.lean`, a helper of a module of the wiring set

A module that declares no wiring set, which the `.wiring` fixture
`ModelTest/Lint/Wiring/Wired.lean` imports: it defines an `IO (List String)`
helper, the shape of the version-control package's lane runner, which rule
(b) of `linter.wiringSet` does not reach, as it holds only a module of the
wiring set's own declarations.
-/

/-- A helper that runs and hands back a list of strings: refused nothing
here, outside the wiring set. -/
def ModelTest.WiringFixture.helperRun : IO (List String) :=
  pure []
