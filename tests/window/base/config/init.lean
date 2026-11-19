import Editor
open Editor

-- A config that names a declaration of a module the config base `Editor`
-- does not import, `ConfigFixture.bump`, so it elaborates only when the
-- window mode hands the elaborator the base it was handed
-- (`ffi-test window-host-base`, whose base is `Editor` and `ConfigFixture`).
-- It keeps the system's standard title bar, which the window mode opens its
-- window with only once this config has installed.

/-- Names the module outside `Editor`. -/
def fixtureBump : IO Nat :=
  ConfigFixture.bump

def setup : SetupM Unit := do
  titleBar .standard
