import Editor.RealHost
import ShippedThemesTest.Linked.ShippedThemes

/-!
# The linked test of the package `shipped-themes`

The root of an executable linked as the editor is linked, with the glue and
the Rust library (the core's `editorLinked` facet,
`lake build +ShippedThemesTest.Linked:editorLinked`): the tests of the
package that need the real library. The gate builds it in `mise run lean`
and runs it in `mise run ffi-test` (`tools/package-set.sh`), in the
package's directory, with the toolchain's directory and the core's `.olean`
directory as its arguments. It uses neither: it elaborates no config.

It only imports the linked test modules, under `ShippedThemesTest/Linked/`,
each of which mirrors the module it tests, and runs them:

- `Linked.themePictures` (`ShippedThemesTest/Linked/ShippedThemes.lean`):
  each shipped theme's picture matches its reference image in
  `tests/render/`, and carries the palette's colours.

With `--write` after the two directories it writes the reference images
instead of comparing them (`mise run theme-references`); the gate never
does.
-/

/-- The root's check set (`Editor.CheckGroup`), over whether it writes the
references: the pictures (`Linked.themePictures`), whose run is their
status, in a plain group, since it holds no module of the wiring set. -/
def ShippedThemesTest.Linked.checks : List (Editor.CheckGroup Bool (IO UInt8)) :=
  [.plain fun write => [ShippedThemesTest.Linked.themePictures write]]

/-- The usage, on stderr, and status 2. -/
private def ShippedThemesTest.Linked.usage : IO UInt32 := do
  IO.eprintln
      "usage: ShippedThemesTest-Linked <sysroot> <core olean dir> [--wiring] [--write], or ShippedThemesTest-Linked wiring-modules"
  return 2

/-- Runs the linked tests and exits 0 when they hold and 1 when one does
not; 2 for a command line that is not the two directories, with `--wiring`,
`--write` or both, in that order, after them or not. Its check set
(`ShippedThemesTest.Linked.checks`) holds no module of the wiring set, so
with `--wiring` it selects no check and exits 0
(`Editor.CheckGroup.running`), and `wiring-modules` prints none. The exit is
explicit, as the core's picture scenario's is: a task of the library may
still be running. -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["wiring-modules"] =>
    for module in Editor.CheckGroup.modules ShippedThemesTest.Linked.checks do
      IO.println module
    return 0
  | _ :: _ :: rest =>
    let write? : List String → Option Bool
      | [] => some false
      | ["--write"] => some true
      | _ => none
    match Editor.CheckGroup.Mode.read? write? rest with
    | some (mode, write) =>
      Editor.CheckGroup.running mode ShippedThemesTest.Linked.checks do
          let statuses ←
            (Editor.CheckGroup.select mode ShippedThemesTest.Linked.checks write).mapM id
          (← IO.getStdout).flush
          IO.Process.exit (statuses.foldl max 0)
    | none =>
      ShippedThemesTest.Linked.usage
  | _ =>
    ShippedThemesTest.Linked.usage
