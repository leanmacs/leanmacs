import Editor
import Editor.Headless
import Editor.PackageSet
import UserLinkFixture

/-!
# The root of the relinked editor

A root written by hand for the user-side link check (`mise run
user-link-check`; `docs/design/lean-runtime.md`, "A link on the user's
machine, measured"). It stands in for the root the packages roadmap
generates (its phase 4) from the package set; that replaces this file.

It imports the config base, `Editor`, as the editor's own root does
(`lean/Main.lean`): the elaborator adapter imports the base's modules at
runtime and each must be linked in, and the adapter does not import the
base itself.

A host registers the packages it is handed (`lean/Editor/Package.lean`), so
this root names the packages and nothing of the host's body:

- `editor headless …` is the shipped headless host, `Editor.Headless.main`,
  handed the packages that ship (`Editor.PackageSet.shipped`), as the
  editor's own root hands them: the standing headless fixture runs on the
  relinked executable.
- `editor headless-with-package …` is the same host handed those packages
  and then this package's (`UserLinkFixture.package`), so its command
  registers after the shipped ones. It takes the same command line.

Any other command line is refused with the usage and the status 2. The
window mode, the keyboard check, the demonstration and `--version` are not
here: the check runs headless.
-/

/-- Runs the mode the command line names: `headless`, the shipped host with
the packages that ship, or `headless-with-package`, that host with this
package's after them. -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | "headless" :: rest =>
    Editor.Headless.main Editor.PackageSet.shipped rest
  | "headless-with-package" :: rest =>
    Editor.Headless.main (Editor.PackageSet.shipped.push UserLinkFixture.package) rest
  | _ =>
    IO.eprintln "usage: editor headless|headless-with-package <sysroot> <olean dir> <config dir> <script file>"
    return 2
