-- The config file the language server check's root imports
-- (tests/config-package/lsp/init.lean): the module `Config.Keys`.

import Editor

open Editor

namespace Config.Keys

/-- What the root's command says. -/
def greeting : String :=
  "from Config.Keys"

end Config.Keys
