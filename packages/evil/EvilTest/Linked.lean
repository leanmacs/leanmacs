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
for a command line that is not the two directories. The exit is explicit,
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

/-- Every check of the linked test, in the order they run, over `context`
and the syntax fixtures in `fixtures`. -/
def EvilTest.Linked.checks (context : Editor.Test.Linked.HostContext) (fixtures : System.FilePath) :
    List EvilTest.Check :=
  EvilTest.Linked.treeObjectChecks context ++ EvilTest.Linked.treeObjectFixtureChecks fixtures ++
    EvilTest.Linked.evilIndentChecks context fixtures ++
    EvilTest.Linked.evilChecks context ++
    EvilTest.Linked.evilLeaderChecks context

/-- Runs the checks (the module docs). -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [sysroot, oleans] =>
    let fixtures ← IO.FS.realPath syntaxFixtures
    let failed ←
      Editor.Test.Linked.HostContext.run sysroot (":".intercalate (oleans :: oleanDirectories))
          setPackages
          (fun context => do
            let checks := EvilTest.Linked.checks context fixtures
            let failed ← EvilTest.failures checks
            for name in failed do
              IO.eprintln s!"FAILED: {name}"
            if failed.isEmpty then
              IO.println s!"evil linked test: {checks.length} checks passed"
            return failed)
          (imports := #[`Editor, `Evil.EditorPackage])
    (← IO.getStdout).flush
    Editor.Test.Linked.shutdown
    IO.Process.exit (if failed.isEmpty then 0 else 1)
  | _ =>
    IO.eprintln "usage: EvilTest-Linked <sysroot> <core olean dir>"
    return 2
