import Editor.Ffi.Events
import FfiTest.Check
import FfiTest.Editor.Display.Real
import FfiTest.Editor.Event.Queue
import FfiTest.Editor.ExcerptView
import FfiTest.Editor.Ffi.Counter
import FfiTest.Editor.Ffi.Diffs
import FfiTest.Editor.Ffi.Display
import FfiTest.Editor.Ffi.Document
import FfiTest.Editor.Ffi.Events
import FfiTest.Editor.Ffi.Files
import FfiTest.Editor.Ffi.Fuzzy
import FfiTest.Editor.Ffi.Grep
import FfiTest.Editor.Ffi.Interrupt
import FfiTest.Editor.Ffi.Inverse
import FfiTest.Editor.Ffi.Launch
import FfiTest.Editor.Ffi.MainThread
import FfiTest.Editor.Ffi.Marker
import FfiTest.Editor.Ffi.Pair
import FfiTest.Editor.Ffi.Processes
import FfiTest.Editor.Ffi.Render
import FfiTest.Editor.Ffi.Search
import FfiTest.Editor.Ffi.Snapshot
import FfiTest.Editor.Ffi.Syntax
import FfiTest.Editor.Ffi.Timers
import FfiTest.Editor.Ffi.Transaction
import FfiTest.Editor.Ffi.Watches
import FfiTest.Editor.Ffi.Window
import FfiTest.Editor.State
import FfiTest.Editor.Themes.Picture
import FfiTest.Editor.Window.Real
import FfiTest.Editor.WindowCheck.Real

/-!
# Checks of the boundary with the Rust library

The `ffi-test` executable is linked exactly like `editor`: the same glue
object, Rust archive and entry point. With no arguments it runs every check in
`checks`, names the ones that failed, and exits non-zero if any did.

The checks themselves live in test modules that mirror the module they
test: the checks of `Editor/Ffi/Document.lean` are in
`FfiTest/Editor/Ffi/Document.lean` (`FfiTest.Editor.Ffi.Document`), and a
list that tests a module other than a binding family is in that module's
mirror, such as `sceneChecks` in `FfiTest/Editor/Display/Real.lean`. A
binding family with no list of its own has no test module. A test module
keeps the helpers only its checks use. Helpers that several test modules use
are in small support modules under `FfiTest/Support/`, each of one kind of
fixture, and `FfiTest.Check` holds the `Check` type, `failures`, `run` and
`usage`. Everything is in the namespace `FfiTest`, so a list is
`FfiTest.<name>Checks` whichever module holds it. This module keeps only
`checks`, which runs them in order, and `main`.

The lists are functions, not constants, because Lean evaluates a module's
constants in its initialiser, and an initialiser must not call the Rust
library (`docs/design/lean-runtime.md`). A test module's initialiser runs at
start-up just as this module's does.

Some behaviour needs a process of its own, so it is a scenario chosen by an
argument (see `main`): `exit <code>` for the exit status, `shutdown` and
`exit-while-blocked` because quitting the queues is for good, and `overflow`
because it ends in an abort. `theme-pictures <dir> <font>` compares the
picture of the theme `default`, of a fixture file, with its reference image
(`themePictures`, which runs the core's theme picture check,
`Editor/Themes/Picture.lean`), and with `--write` makes it again. `mise run ffi-test` runs the checks and every
scenario but `overflow`, under a time limit, and is part of the gate.
`mise run ffi-overflow` runs `overflow`, on demand only: on macOS every abort
leaves a crash report on the machine.

Each check pins what the C glue and the entry point do, as Lean sees it. What
the Rust functions themselves compute is pinned by `editor-ffi`'s own tests.

A check never waits without a bound: a pull runs on a dedicated task that the
check polls (`pull`, `eventually`), so broken code fails a check within
seconds instead of hanging the executable.
-/

namespace FfiTest

/-- Every check, in the order they run. -/
def checks (_ : Unit) : List Check :=
  entryChecks () ++ handleChecks () ++ dataChecks () ++ queueChecks () ++ timerChecks () ++
    fileChecks () ++
    diffChecks () ++
    processChecks () ++
    watchChecks () ++
    grepChecks () ++
    documentChecks () ++
    snapshotChecks () ++
    transactionChecks () ++
    markerChecks () ++
    inverseChecks () ++
    windowChecks () ++
    displayChecks () ++
    sceneChecks () ++
    decodeChecks () ++
    eventDecodeChecks () ++
    eventChecks () ++
    interruptChecks () ++
    ffiLaunchChecks () ++
    fuzzyChecks () ++
    syntaxChecks () ++
    searchChecks () ++
    pairChecks () ++
    pictureChecks () ++
    themePicturesChecks () ++
    paddingChecks () ++
    renderChecks ()

/-- The `theme-pictures` scenario: the theme picture check
(`Themes.Picture.themePicturesScenario`) over the reference images in
`dir` and the font file `font`, on the theme `default` (`defaultRoles`),
the one theme the core defines. With `write` it writes the reference. A
package that ships themes runs the same check on its own from its linked
test (`packages/shipped-themes/ShippedThemesTest/Linked.lean`). -/
def themePictures (dir font : String) (write : Bool) : IO UInt8 :=
  Editor.Themes.Picture.themePicturesScenario "ffi-test theme-pictures" dir font write
    [defaultRoles]

end FfiTest

/-- With no arguments, runs the checks: exits 0 when all hold, and 1 after
naming the ones that do not.

With the arguments `exit <code>`, exits with that status and does nothing
else. The `ffi-test` task uses this to see that the entry point passes the
arguments to Lean's `main` and makes its result the process's exit status.

`shutdown` runs the shutdown sequence: tasks parked in a pull on each queue,
quit, then an explicit exit, with status 0 when every task came back with a
quit event.

`exit-while-blocked` parks a task in a pull, never quits, and exits
explicitly with status 0. It shows that the process ends although a dedicated
task is still blocked in the library, which returning from `main` would wait
for.

`overflow <sysroot> <olean dir>` has the interpreter run a recursion deeper
than its stack. Nothing catches the C++ exception the interpreter throws, so
the process dies of SIGABRT, and the `ffi-overflow` task requires exactly
that. Any exit status of its own means the scenario went wrong. -/
def main (args : List String) : IO UInt32 := do
  match args with
  | [] =>
    if (← FfiTest.run "ffi-test" (FfiTest.checks ())) == 0 then
      return 0
    else
      -- A failed check may have left a task parked in the library, and
      -- returning from `main` would wait for it for ever.
      IO.Process.exit 1
  | ["shutdown"] =>
    IO.Process.exit (← FfiTest.run "ffi-test shutdown" (FfiTest.shutdownChecks ()))
  | ["display", fixture] =>
    IO.Process.exit (← FfiTest.displayScenario fixture)
  | ["theme-pictures", dir, font] =>
    IO.Process.exit (← FfiTest.themePictures dir font false)
  | ["theme-pictures", dir, font, "--write"] =>
    IO.Process.exit (← FfiTest.themePictures dir font true)
  | ["excerpt-picture", dir, font] =>
    IO.Process.exit (← FfiTest.excerptPictureScenario dir font false)
  | ["excerpt-picture", dir, font, "--write"] =>
    IO.Process.exit (← FfiTest.excerptPictureScenario dir font true)
  | ["window-host", file] =>
    let status ← FfiTest.windowHostScenario (some file)
    Editor.Ffi.quit
    IO.Process.exit status
  | ["window-host"] =>
    let status ← FfiTest.windowHostScenario none
    Editor.Ffi.quit
    IO.Process.exit status
  | ["window-host-config", sysroot, oleanDir, configDir] =>
    let status ← FfiTest.windowHostConfigScenario sysroot oleanDir configDir
    Editor.Ffi.quit
    IO.Process.exit status
  | ["window-host-restart", sysroot, oleanDir, configDir] =>
    let status ← FfiTest.windowHostRestartScenario sysroot oleanDir configDir
    Editor.Ffi.quit
    IO.Process.exit status
  | ["window-host-base", sysroot, oleanDir, configDir] =>
    let status ← FfiTest.windowHostBaseScenario sysroot oleanDir configDir
    Editor.Ffi.quit
    IO.Process.exit status
  | ["window-host-generate", sysroot, oleanDir, configDir] =>
    let status ← FfiTest.windowHostGenerateScenario sysroot oleanDir configDir
    Editor.Ffi.quit
    IO.Process.exit status
  | ["window-host-direct", editorPath, sysroot, configDir] =>
    let status ← FfiTest.windowHostDirectScenario editorPath sysroot configDir
    Editor.Ffi.quit
    IO.Process.exit status
  | ["window-host-undrawn", file] =>
    let status ← FfiTest.windowHostUndrawnScenario file
    Editor.Ffi.quit
    IO.Process.exit status
  | ["exit-while-blocked"] =>
    IO.Process.exit (if ← FfiTest.blockForGood then 0 else 1)
  | ["overflow", sysroot, oleanDir] =>
    IO.Process.exit (← FfiTest.overflow sysroot oleanDir)
  | ["exit", code] =>
    match code.toNat? with
    | some status =>
      return status.toUInt32
    | none =>
      FfiTest.usage
  | _ =>
    FfiTest.usage
