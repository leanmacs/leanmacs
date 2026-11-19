-- A root that imports a module of a package this directory's lakefile
-- requires: `Greeting`, of the fixture package `greeting`. An editor whose
-- package set holds that package loads it; one whose set does not rejects
-- the reload and says the set needs a rebuild.

import Editor
import Greeting

open Editor

def setup : SetupM Unit :=
  bindKey "C-c g" "greeting-hello"
