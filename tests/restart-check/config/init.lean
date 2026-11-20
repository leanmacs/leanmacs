import Editor
open Editor

/-! The config of `mise run restart-check` (tools/restart-check.sh), which
writes it into a temporary config directory with `@ELSEWHERE@` and `@BAD@`
replaced by two executables' paths. Opening a file named `*.restart-elsewhere`
restarts into the first, and `*.restart-bad` into the second, so the check
drives each restart with an open-file event, as Finder sends one. Only a
buffer opened in this run restarts: one the restore made or reopened
(`Buffer.historyRestored`) is the session handed over, and restarting for it
would restart again at every start. -/

/-- The editor outside the bundle the first restart goes into. -/
def elsewhere : System.FilePath :=
  "@ELSEWHERE@"

/-- The program that passes the probe and then fails, which the second
restart goes into. -/
def bad : System.FilePath :=
  "@BAD@"

/-- Restarts for the buffer `view` shows, when its language asks for one and
this run opened it. -/
def restartFor (view : ViewId) : EditorM Unit := do
  let state ← editorState
  let some window := state.window? view | return
  let some buffer := state.buffer? window.buffer | return
  if buffer.historyRestored then
    return
  match buffer.language with
  | some "restart-elsewhere" => Editor.restart (into := some elsewhere)
  | some "restart-bad" => Editor.restart (into := some bad)
  | _ => pure ()

def setup : SetupM Unit := do
  defineLanguage
    { name := "restart-elsewhere", patterns := [.extension "restart-elsewhere"]
      syntaxTree := { grammar := "toml" } }
  defineLanguage
    { name := "restart-bad", patterns := [.extension "restart-bad"]
      syntaxTree := { grammar := "toml" } }
  -- The code mode every buffer with a language is put in, with the restart
  -- on entering it: config's mode of a name replaces a package's.
  defineMode { Language.codeMode with onEnter := restartFor }
