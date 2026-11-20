-- The config of tools/user-sets-test.sh: its root imports `HelloInit`, a
-- module of the fixture package `hello-init`, so it loads only in an editor
-- whose package set links that package.

import Editor
import HelloInit

open Editor

def setup : SetupM Unit :=
  pure ()
