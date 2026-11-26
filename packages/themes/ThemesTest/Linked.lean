import Editor
import Editor.Test.Linked.Host
import Editor.Test.Linked.Services
import Themes.EditorPackage
import ThemesTest.Check
import ThemesTest.Linked.Themes

/-!
# The linked test of the package `themes`

The package-set step `run` (`tools/package-set.sh`, in `mise run ffi-test`)
builds this root's executable with the Rust library linked, and runs it in
the package's directory with the Lean toolchain's directory and the core's
`.olean` directory. It prints `themes linked test: N checks passed`, and
exits 0 when all hold, 1 after naming on stderr the ones that do not, and 2
for a command line that is not the two directories, with `--wiring` after
them or not. Its check set (`ThemesTest.Linked.checks`) holds no module of
the wiring set, so with `--wiring` it selects no check and exits 0, building
no host (`Editor.CheckGroup.running`), and `wiring-modules` prints none. The
exit is explicit,
after the library's services are shut down and its queues quit: a task may
still be blocked in the library.

Its checks are the themes' through the headless host over the real
elaborator, the display's real binding and the library's layout, in
`ThemesTest/Linked/Themes.lean`, which mirrors the module it tests; they
were the config test's (`ConfigTest.themeChecks`) while the themes were
modules of the core:

- `themeChecks`: named themes through a host over the display's real
  binding: `load-theme` switches the frame to the chosen theme with
  config's face over it, with no reload, and the scene line names the
  theme; a config naming a theme nobody registered says so in the echo
  area; and a prompt of config's that asks for the themes' source by name
  lists the registered themes, and config's own source under that name in
  its place.

They are handed the context of a harness of hosts over the real elaborator
(`Editor.Test.Linked.HostContext.run`), on the config base `Editor`, found
in the core's `.olean` directory, with the packages a set that holds this
Lake package hands its editor (`setPackages`). Each check hands its host
what it registers itself: the themes package's commands and theme, and the
kit's minibuffer. It imports the config base, `Editor`, for the link alone,
as every root that links the elaborator does: the elaborator imports the
base's modules from their `.olean` files at runtime, and each must already
be linked into the executable. The config the hosts load names no
declaration of this package.
-/

/-- The packages this Lake package hands a set's editor: its own. The
core's Lake package, which it requires, hands a set none. -/
def setPackages : Array Editor.Package :=
  Themes.EditorPackage.packages

/-- The root's check set (`Editor.CheckGroup`): the themes' checks, over the
harness's context, in a plain group, since it holds no module of the wiring
set. -/
def ThemesTest.Linked.checks :
    List (Editor.CheckGroup Editor.Test.Linked.HostContext ThemesTest.Check) :=
  [.plain ThemesTest.Linked.themeChecks]

/-- The usage, on stderr, and status 2. -/
private def ThemesTest.Linked.usage : IO UInt32 := do
  IO.eprintln
      "usage: ThemesTest-Linked <sysroot> <core olean dir> [--wiring], or ThemesTest-Linked wiring-modules"
  return 2

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["wiring-modules"] =>
    for module in Editor.CheckGroup.modules ThemesTest.Linked.checks do
      IO.println module
    return 0
  | sysroot :: oleans :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      Editor.CheckGroup.running mode ThemesTest.Linked.checks do
          let failed ←
            Editor.Test.Linked.HostContext.run sysroot oleans setPackages fun context => do
                let checks := Editor.CheckGroup.select mode ThemesTest.Linked.checks context
                let failed ← ThemesTest.failures checks
                for name in failed do
                  IO.eprintln s!"FAILED: {name}"
                if failed.isEmpty then
                  IO.println s!"themes linked test: {checks.length} {mode.what} passed"
                return failed
          (← IO.getStdout).flush
          Editor.Test.Linked.shutdown
          IO.Process.exit (if failed.isEmpty then 0 else 1)
    | none =>
      ThemesTest.Linked.usage
  | _ =>
    ThemesTest.Linked.usage
