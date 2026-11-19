-- A config file: the module `Config.Keys`. It exports a text and a program
-- under its own names, and the root's `setup` calls the program.

import Editor

open Editor

namespace Config.Keys

/-- What `keys-hello` says. -/
def greeting : String :=
  "from Config.Keys"

/-- Registers `keys-hello`: what the root's `setup` calls. -/
def bindings : SetupM Unit :=
  command "keys-hello" (message greeting)

end Config.Keys
