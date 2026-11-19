-- The root of a config of several modules: the one file whose `setup` the
-- editor runs. It imports `Lean`, a module of a package of the default set
-- (`Compile`) and two config files, and names a declaration of each.

import Editor
import Lean
import Compile
import Config.Keys
import Config.Unused

open Editor

/-- A format of config's own, of the compile package's type. -/
def ownFormat : Compile.Format :=
  { name := "own", pattern := [] }

/-- Says a text made with Lean's own JSON from what `Config.Keys` exports,
and the name of a format of the compile package's type. -/
def facts : EditorM Unit :=
  message s!"{(Lean.Json.arr #[Lean.Json.str Config.Keys.greeting]).compress} {ownFormat.name}"

-- `Config.Unused.setup` is in scope here and is not called: the editor runs
-- this `setup`, the root's, and no other.
def setup : SetupM Unit := do
  Config.Keys.bindings
  command "facts" facts
