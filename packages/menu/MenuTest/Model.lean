import MenuTest.Check
import MenuTest.Menu.Compiled

/-!
# The test driver of the package `menu`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of
`Menu/Compiled.lean` are in `MenuTest/Menu/Compiled.lean`. They run on the
core's test kit. They were the core's (`ModelTest.standardMenuChecks`)
while the package was a module of the core, and moved here with their
sentences as they were.

- `standardMenuChecks`: the standard menu (`Menu/Compiled.lean`) on the
  kit's frame driver, over the package's bindings and the two chords the
  frame commands' package binds to the Window menu's commands, written in
  the test: the Edit menu's clipboard items and `s-x`, `s-c`, `s-v` and
  `s-a` name the core's clipboard names; its Undo and Redo, and `s-z` and
  `s-Z`, name `evil-api`'s; the published menu is the standard one with
  the chords bound to its commands; the Edit, Window and File menus' items;
  and what the `Package` value registers: the eight bindings, the four
  menus, and nothing else.
-/

/-- Every check of the test driver, in the order they run. -/
def MenuTest.checks : List MenuTest.Check :=
  MenuTest.standardMenuChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← MenuTest.failures MenuTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"menu-test: {MenuTest.checks.length} checks passed"
    return 0
  else
    return 1
