-- The default config's `setup`: the starter leader map of `05-leader.lean`.
-- A config has one `setup`. To use the map in a config of your own, copy
-- `05-leader.lean` into it and call `leaderMap` from your `setup`: the
-- `05-` sorts before your chunks (chunks elaborate in the byte order of
-- their file names), so `leaderMap` is defined where your `setup` is.

def setup : SetupM Unit :=
  leaderMap
