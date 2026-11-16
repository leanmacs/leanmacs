-- Keeps the system's standard title bar: the window mode reads it once the
-- start-up reload has installed, and opens its window with it
-- (`ffi-test window-host-config`).
def setup : SetupM Unit := do
  titleBar .standard
