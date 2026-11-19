-- The default config's root: the one file whose `setup` the editor runs. It
-- is the starter leader map of `Config/Leader.lean`.
--
-- A config is this file, `init.lean`, and the files under `Config/` it
-- imports, each a Lean module: `Config/Leader.lean` is `Config.Leader`. To
-- use the map in a config of your own, copy `Config/Leader.lean` into it,
-- import it as below and call `leaderMap` from your `setup`.

import Editor
import Config.Leader

open Editor

def setup : SetupM Unit :=
  leaderMap
