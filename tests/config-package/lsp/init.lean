import Editor
import Lean
import Compile
import Config.Keys

open Editor

def wrong : Nat := "not a number"

-- The root of the config Lean's language server is asked about in the gate
-- (tools/config-package-check.sh, `config-test lsp`): it imports `Lean`, a
-- module of a package of the default set and a config file, names a
-- declaration of each, and holds one type error, on line 8, at column 19.
-- The header and that line stay where they are: the check names the place.

/-- A text made with Lean's own JSON from what `Config.Keys` exports. -/
def viaLean : Lean.Json :=
  Lean.Json.str Config.Keys.greeting

/-- A format of the compile package's type. -/
def ownFormat : Compile.Format :=
  { name := viaLean.compress, pattern := [] }

def setup : SetupM Unit :=
  command ownFormat.name (message Config.Keys.greeting)
