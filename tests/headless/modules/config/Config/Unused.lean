-- A config file that defines a `setup` of its own. The root imports it and
-- does not call it, so the command it registers is never registered: only
-- the root's `setup` is run.

import Editor

open Editor

namespace Config.Unused

/-- A `setup` outside the root: the editor does not run it. -/
def setup : SetupM Unit :=
  command "unused" (message "never said")

end Config.Unused
