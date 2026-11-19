import Editor
open Editor

-- The config of the fixture package's headless fixture. It registers
-- nothing: the command the script runs is the package's, compiled into the
-- executable, and no config names it.
def setup : SetupM Unit :=
  pure ()
