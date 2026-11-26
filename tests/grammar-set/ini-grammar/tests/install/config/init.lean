-- The config of the on-demand install check
-- (crates/editor-syntax-fixture-ini/tests/package_install.rs): a root and
-- nothing else of its own. The check copies it into a temporary config
-- directory, has the default set's editor generate the directory's
-- lakefile there, and adds the test package to it, as `:package-install`
-- does; the installed editor then elaborates it. It declares no grammar:
-- the grammar `ini` is the package's.

import Editor

open Editor

/-- Opens `settings.ini` in the editor's working directory, in the focused
view: the check runs the installed editor in a directory that holds a copy
of the INI fixture. -/
def openFixture : EditorM Unit := do
  let state ← editorState
  Files.open state.frame.focused (state.workingDirectory / "settings.ini")

def setup : SetupM Unit :=
  command "open-fixture" openFixture
