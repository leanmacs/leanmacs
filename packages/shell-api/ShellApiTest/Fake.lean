import Editor.Config.Packages
import ShellApi

/-!
# The fake of `shell-api`

A package named `shell` that registers the interface's three commands over
the core's API alone, and the codec of the history's store: its
`shell-command` records the ex line it is handed in the history of the
window's buffer's scope (`Shell.record`) and says it, running nothing; its
`shell-filter` says it filters nothing; and its `keyboard-quit` says there is
nothing to quit. A consumer's tests register it in place of the shell, as ex's
do: the ex line hands a `:!` line to `shell-command`, and offers the history
the fake wrote.
-/

namespace ShellApiTest

open Editor

/-- What the fake's `shell-command` says of the ex line `line`. -/
def ranText (line : String) : String :=
  s!"the fake shell ran {line}"

/-- The fake's `setup`, but for what `dropped` names: command names, and
`codec` for the history's codec. -/
def fakeSetup (dropped : List String := []) : SetupM Unit := do
  let commands : List (String × (Call → EditorM Unit)) :=
    [(ShellApi.commandName, fun call => do
        match call.arguments with
        | .str _ :: .str line :: _ =>
          let state ← editorState
          Shell.record (Shell.Scope.of state call.target.window.buffer) line
          message (ranText line)
        | _ =>
          message ShellApi.noCommand),
      (ShellApi.filterName, fun _ => message "the fake shell filters nothing"),
      (ShellApi.interruptName, fun _ => message "the fake shell has nothing to quit")]
  for (name, run) in commands do
    unless dropped.contains name do
      commandWith name run
  unless dropped.contains "codec" do
    Shell.historyStore.keptAcrossRestart

/-- The fake: a package named `shell`. -/
def fake : Package :=
  { name := "shell", setup := fakeSetup }

end ShellApiTest
