-- The config of the on-demand install check of the default set
-- (packages/languages/rust/tests/default_install.rs): a root and nothing
-- else, which is "no config". The installed editor needs a root module in
-- its config directory for `headless --generate` to write the directory's
-- lakefile and for the install to build; this one registers nothing, so
-- every language, grammar and key the run uses is the default set's.

import Editor

open Editor

/-- Registers nothing: the run uses the default set alone. -/
def setup : SetupM Unit :=
  pure ()
