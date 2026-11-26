-- A config that calls the mise package's setting, `Mise.executable`, twice:
-- the editor refuses its `setup` (`Extension.setting`).

import Editor
import Mise

open Editor

def setup : SetupM Unit := do
  Mise.executable "/opt/mise"
  Mise.executable "/usr/local/bin/mise"
