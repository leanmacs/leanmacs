-- A config directory that holds only its root. An editor that may write
-- here creates the directory's `lakefile.toml` and `lean-toolchain` before
-- it elaborates this file; the gate runs it on a temporary copy of this
-- directory, never here (tools/config-package-check.sh).

import Editor

open Editor

/-- Says that the config loaded. -/
def loaded : EditorM Unit :=
  message "generate: config loaded"

def setup : SetupM Unit :=
  command "loaded" loaded
