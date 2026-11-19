import Editor.Headless
import UserLinkFixture

/-!
# The root of the relinked editor

A root written by hand for the user-side link check (`mise run
user-link-check`; `docs/design/lean-runtime.md`, "A link on the user's
machine, measured"). It stands in for the root the packages roadmap
generates (its phase 4) from the package list its phase 2 defines; both
replace this file.

- `editor headless …` is the shipped headless host, `Editor.Headless.main`,
  untouched: the standing headless fixture runs on the relinked executable.
- `editor headless-with-package …` is the same host with the package's
  registration (`UserLinkFixture.commands`) after the shipped commands. It
  takes the same command line.

Any other command line is refused with the usage and the status 2. The
window mode, the keyboard check, the demonstration and `--version` are not
here: the check runs headless.
-/

/-- The headless host with the package's commands after the shipped ones,
handed the command line after `headless-with-package`.

It is the body of `Editor.Headless.main` (`lean/Editor/Headless.lean`) with
`UserLinkFixture.commands` appended to the collaborators' `commands`, and
without `--render`, which it refuses. It is a copy because the shipped host
takes no package yet. -/
def headlessWithPackage (arguments : List String) : IO UInt32 := do
  let { render := drawn, sysroot, oleans := oleanDir, config := configDir, script := scriptPath } ←
    match Editor.Headless.read (← IO.appPath).toString arguments with
    | .ok read =>
      pure read
    | .error reason =>
      unless reason.isEmpty do
        IO.eprintln s!"editor: {reason}"
      IO.eprintln s!"usage: editor {Editor.Headless.usage}"
      return 2
  if drawn then
    IO.eprintln "editor: headless-with-package does not draw"
    return 2
  let directives ←
    try
      let text ← IO.FS.readFile scriptPath
      IO.ofExcept ((Editor.Headless.script text).mapError IO.userError)
    catch error =>
      IO.eprintln s!"editor: cannot run the script {scriptPath}: {error}"
      return 1
  let shipped ←
    Editor.Headless.shipped sysroot oleanDir configDir IO.println .headless (fakeClock := true)
  let workingDirectory ← IO.currentDir
  let failure ←
    Editor.Headless.run
        { shipped with
          workingDirectory
          commands := shipped.commands ++ UserLinkFixture.commands }
        directives Editor.Headless.settlePatience
  (← IO.getStdout).flush
  if let some failure := failure then
    IO.eprintln s!"editor: {failure.describe Editor.Headless.settlePatience}"
  Editor.Ffi.processesShutdown
  Editor.Ffi.watchesShutdown
  Editor.Ffi.quit
  IO.Process.exit (if failure.isNone then 0 else 1)

/-- Runs the mode the command line names: `headless`, the shipped host, or
`headless-with-package`, that host with the package's command. -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | "headless" :: rest =>
    Editor.Headless.main rest
  | "headless-with-package" :: rest =>
    headlessWithPackage rest
  | _ =>
    IO.eprintln "usage: editor headless|headless-with-package <sysroot> <olean dir> <config dir> <script file>"
    return 2
