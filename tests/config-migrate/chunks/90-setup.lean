-- The last file of a config in the old form: it defines `setup`, over what
-- the file before it defined. Converted, it is the root, `init.lean`.

def setup : SetupM Unit :=
  leaderMap
