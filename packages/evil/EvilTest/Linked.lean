import Editor
import Editor.Test.AtPoint
import Editor.Test.Linked.Host
import Editor.Test.Linked.Services
import Editor.Test.Minibuffer
import Editor.Test.Shipped
import Evil.EditorPackage
import EvilTest.Check
import EvilTest.Linked.Evil
import EvilTest.Linked.Evil.Operators
import EvilTest.Linked.Evil.TreeObjects
import FilesApiTest.Fake

/-!
# The linked test of the package `evil`

The package-set step `run` (`tools/package-set.sh`, in `mise run ffi-test`)
builds this root's executable with the Rust library linked, and runs it in
the package's directory with the Lean toolchain's directory and the core's
`.olean` directory. It prints `evil linked test: N checks passed`, and
exits 0 when all hold, 1 after naming on stderr the ones that do not, and 2
for a command line it does not take. The exit is explicit,
after the library's services are shut down and its queues quit: a task may
still be blocked in the library.

Its checks are evil's through the headless host over the real elaborator
and the library's syntax service, in the modules under `EvilTest/Linked/`,
each of which mirrors the module it tests; they were the config test's
(`ConfigTest.<name>`), and `treeObjectFixtureChecks` the contract test's
before that, while evil was modules of the core:

- `treeObjectChecks` (`EvilTest/Linked/Evil/TreeObjects.lean`): the syntax
  tree's text objects through a host of the Vim scheme that ships, in a
  Rust buffer: `v a f`, `d a f`, `v i f` and the rest select and delete the
  node the library's tree answers;
- `treeObjectFixtureChecks` (the same module): the objects' spans over the
  real binding with no host, on the Rust fixture `tests/syntax/rust/objects.rs`,
  before and after edits, and the names the shipped Rust text objects query
  captures;
- `evilIndentChecks` (`EvilTest/Linked/Evil/Operators.lean`): evil's `=`
  and its indented new lines through a host of the Vim scheme that ships,
  over the library's Rust grammar: `gg=G` on the mangled Rust indent
  fixture (`tests/syntax/rust/indent.rs`) gives the fixture back, `=af`
  re-indents one function, one `u` undoes it and `.` repeats it, rows
  inside a string and a comment keep their indent, `RET` after an opening
  brace and `o`/`O` in a body start at the tree's level, and a buffer with
  no language or no indents query is as before;
- `evilChecks` (`EvilTest/Linked/Evil.lean`): evil from config through the
  host, with the test scheme: a config that the real elaborator loads names
  the vocabulary the editor ships (`Evil.motions`) and hands it to evil's
  move command, as it is and with a motion of config's own added. It shows
  what the set's base lets config name of this package, through its entry
  module; where a motion of the editor's leads is not said here;
- `evilLeaderChecks` (the same module): the Vim scheme's leader through a
  host of the Vim scheme that ships: a config's `<leader> f f` binding runs
  on `SPC f f` while config sets no leader, on `\ f f` once a reload sets
  the leader to `\` (and `SPC f f` then does not run it), `SPC` typed in
  insert state is a space while `SPC f f` after `<Escape>` runs the
  binding, and the scene's `hint` lines after `SPC` and after `SPC f` hold
  what config named and described.

They are handed the context of a harness of hosts over the real elaborator
(`Editor.Test.Linked.HostContext.run`), with the packages a set that holds
this Lake package hands its editor (`setPackages`), on the base such a
set's editor elaborates config on: `Editor`, found in the core's `.olean`
directory, and then this package's entry module, `Evil.EditorPackage`,
found in the package's own, with the modules of the interface packages it
imports found in theirs (`oleanDirectories`). The configs `evilChecks`
load name evil's declarations (`Evil.move`, `Evil.motions`,
`Evil.operators`), which reach config through that entry module alone
since the config base `Editor` imports no module of evil. It imports the
base's two modules for the link: the elaborator imports the base's modules
from their `.olean` files at runtime, and each must already be linked into
the executable.

**The syntax fixtures** are the repository's `tests/syntax`, which the
core's syntax checks read too, named from the package's directory, where
the gate runs this executable (`syntaxFixtures`).

Its checks are a check set (`EvilTest.Linked.checks`, `Editor.CheckGroup`,
`docs/dev-practices/real-thread-checks.md`, "How the set runs"):
the lists of its modules of the wiring set in groups of their module, which
the build's `linter.wiringSet` holds true and complete. With `--wiring`
after the three arguments it
runs those groups alone, the stress loop's `linked-wiring` suite
(`tools/package-set.sh run --wiring`), and `wiring-modules` prints their
modules, one a line, building nothing.
-/

/-- The packages a set that holds this Lake package hands its editor, as
the config tests' hosts were handed them: its own (the core's Lake
package, which it requires, hands a set none), then `files-api`'s fake (`FilesApiTest.fake`), in
place of the default package `files`, the core's test kit's stand-ins for
the default packages `mode-line` and `languages`
(`Editor.Test.Shipped.packages`, whose segments the host's status lines
print and whose languages and `code` mode the indent checks' buffers are
set to), and its implementations of the default packages `at-point`'s and
`minibuffer`'s commands, which insert state's `RET` and `TAB` run. -/
def setPackages : Array Editor.Package :=
  Evil.EditorPackage.packages ++ #[FilesApiTest.fake] ++ Editor.Test.Shipped.packages ++
    #[Editor.Test.AtPoint.package, Editor.Test.Minibuffer.package]

/-- The directories of the `.olean` files the base's second module,
`Evil.EditorPackage`, and what it imports are found in, from the package's
directory, where the gate runs this executable: this package's own, and
those of the interface packages it requires, `evil-api`, `minibuffer-api`,
`at-point-api`, `window-commands-api`, `tab-commands-api`, `ex-api` and `shell-api`, at the paths
its lakefile requires them by. A set's
editor is handed each package's directory the same way (`editor.oleans`). -/
def oleanDirectories : List String :=
  [".lake/build/lib/lean", "../evil-api/.lake/build/lib/lean",
    "../minibuffer-api/.lake/build/lib/lean", "../at-point-api/.lake/build/lib/lean",
    "../window-commands-api/.lake/build/lib/lean", "../tab-commands-api/.lake/build/lib/lean",
    "../ex-api/.lake/build/lib/lean", "../shell-api/.lake/build/lib/lean"]

/-- The directory of the syntax fixtures (`tests/syntax`), from the
package's directory, where the gate runs this executable. -/
def syntaxFixtures : System.FilePath :=
  "../../tests/syntax"

/-- What every check is handed: the harness's context, the directory of
the syntax fixtures, and the grammars the core's tests load (the third
argument, `Editor.Test.Linked.TestGrammars`), which the checks over the
library's syntax service register or declare, since the library compiles in
no grammar. -/
abbrev EvilTest.Linked.Context :=
  Editor.Test.Linked.HostContext × System.FilePath × Editor.Test.Linked.TestGrammars

/-- Every check of the linked test, in the order they run, over the
harness's context and the syntax fixtures: its check set
(`Editor.CheckGroup`), the lists of `EvilTest/Linked/Evil/TreeObjects.lean`
and `EvilTest/Linked/Evil/Operators.lean`, of the wiring set, in groups of
their module. -/
def EvilTest.Linked.checks : List (Editor.CheckGroup EvilTest.Linked.Context EvilTest.Check) :=
  [.wired "EvilTest.Linked.Evil.TreeObjects" wiringSet.EvilTest.Linked.Evil.TreeObjects
      fun (context, fixtures, grammars) =>
      EvilTest.Linked.treeObjectChecks context grammars ++
        EvilTest.Linked.treeObjectFixtureChecks context grammars fixtures,
    .wired "EvilTest.Linked.Evil.Operators" wiringSet.EvilTest.Linked.Evil.Operators
      fun (context, fixtures, grammars) =>
      EvilTest.Linked.evilIndentChecks context grammars fixtures,
    .plain fun (context, _, _) =>
      EvilTest.Linked.evilChecks context ++ EvilTest.Linked.evilLeaderChecks context]

/-- Runs the checks `mode` selects from the check set
(`Editor.CheckGroup.select`), and says which failed, or how many passed. -/
private def EvilTest.Linked.runSelected (sysroot oleans grammars : String)
    (mode : Editor.CheckGroup.Mode) : IO UInt32 := do
  let fixtures ← IO.FS.realPath syntaxFixtures
  let grammars : Editor.Test.Linked.TestGrammars := { directory := ← IO.FS.realPath grammars }
  let failed ←
    Editor.Test.Linked.HostContext.run sysroot (":".intercalate (oleans :: oleanDirectories))
        setPackages
        (fun context => do
          let checks :=
            Editor.CheckGroup.select mode EvilTest.Linked.checks (context, fixtures, grammars)
          let failed ← EvilTest.failures checks
          for name in failed do
            IO.eprintln s!"FAILED: {name}"
          if failed.isEmpty then
            IO.println s!"evil linked test: {checks.length} {mode.what} passed"
          return failed)
        (imports := #[`Editor, `Evil.EditorPackage])
  (← IO.getStdout).flush
  Editor.Test.Linked.shutdown
  IO.Process.exit (if failed.isEmpty then 0 else 1)

/-- Says the command lines it takes, and exits 2. -/
private def EvilTest.Linked.usage : IO UInt32 := do
  IO.eprintln
      "usage: EvilTest-Linked <sysroot> <core olean dir> <test grammars dir> [--wiring], or EvilTest-Linked wiring-modules"
  return 2

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["wiring-modules"] =>
    for module in Editor.CheckGroup.modules EvilTest.Linked.checks do
      IO.println module
    return 0
  | sysroot :: oleans :: grammars :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      EvilTest.Linked.runSelected sysroot oleans grammars mode
    | none =>
      EvilTest.Linked.usage
  | _ =>
    EvilTest.Linked.usage
