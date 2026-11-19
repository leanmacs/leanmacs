-- The config the user-side link check loads (`mise run user-link-check`,
-- tests/user-link/script). It registers nothing: `user-link-hello` is the
-- package's command, compiled and linked into the editor the check builds
-- (tests/user-link/package), not config's.
def setup : SetupM Unit :=
  pure ()
