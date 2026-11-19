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

/-- Runs the linked tests and exits 0 when they hold and 1 when one does
not; 2 for a command line that is not the two directories, with `--write`
after them or not. The exit is explicit, as the core's picture scenario's
is: a task of the library may still be running. -/
def main (arguments : List String) : IO UInt32 := do
  let write ←
    match arguments with
    | [_, _] =>
      pure false
    | [_, _, "--write"] =>
      pure true
    | _ =>
      IO.eprintln "usage: ShippedThemesTest-Linked <sysroot> <core olean dir> [--write]"
      return 2
  let status ← ShippedThemesTest.Linked.themePictures write
  (← IO.getStdout).flush
  IO.Process.exit status
