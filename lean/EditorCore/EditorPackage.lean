import Editor.Ex.Compiled
import Editor.FrameCommands.Compiled
import Editor.Menu.Compiled
import Editor.PackageSet.Compiled
import Editor.Restore.Compiled
import Editor.TabCommands.Compiled
import Editor.Themes.Compiled
import Editor.WindowCommands.Compiled

/-!
# The core's entry module: the packages of the core's Lake package

`EditorCore.EditorPackage.packages` is the array of packages
(`Editor/Package.lean`) the features still in the core's Lake package
make, written by hand, in the order a host registers them.

It is **the entry module** of the Lake package `editor-core`
(`lakefile.lean`): a Lake package named `p` lists its `Package` values as
`packages` in the module `<P>.EditorPackage`, `<P>` being `p` in upper
camel case (`docs/design/packages.md`, "The package set and its build").
The package-set build writes the executable's root from the entry modules
of the set's Lake packages, each after the ones it requires, so these
register first, and that root passes the whole array to the hosts
(`Editor.Main.run`; `Headless.main`, `Window.main`). A host registers the
array it is given, in order, when it starts, before any config
(`Config.State.ofPackages`, `Editor/Config/Packages.lean`). When a feature
moves out into a Lake package of its own, its `Package` leaves this list
for that package's entry module.

## This module is outside `Editor/`

It is not a module of the editor: it is under neither `Editor/` nor the
namespace `Editor`, and it is a library of its own (`lean_lib EditorCore`,
`lakefile.lean`), which the generated root and the tests that need the
list import. It names every package of the core's Lake package, so it is
no feature's module, and it is no core module either
(`docs/design/packages.md`): the core's root (`Editor/Core.lean`) does not
import it, and the core imports check, which is of the modules named
`Editor.…`, does not meet it (`tools/core-imports-check.sh`). The compile
mode's package was in it until that mode moved out, into the Lake package
`compile` (`packages/compile/`), whose entry module lists it now.

## This module is outside the host

No module of a host imports this one, or any module it imports: a host
takes its packages as a value and names none of them. The gate checks that
on Lake's module graph (`tools/host-imports-check.sh`, in `mise run
ffi-test`): the modules the executable's root imports other than the entry
modules, with everything they import, hold neither an entry module nor a
module one imports directly.

So **this module imports package modules and nothing else**: its direct
imports are what that check forbids a host. A helper it needed would have
to live in a package's module, or the check would forbid the host that
helper too. Tests import it for the list (`ModelTest.packageSetChecks`,
`ConfigTest.shippedChecks`).

## No scheme

This module declares no `scheme`: the core's Lake package supplies no input
scheme, and its lakefile does not declare the keyword `editor-input-scheme`
(`docs/design/packages.md`, "Input schemes"). The Vim scheme is the default
package `evil`'s (`packages/evil/`), whose entry module declares it, since
the features-as-packages roadmap's phase 7; until then this module declared
`scheme := Evil.scheme`. So an editor built from the core alone has no
input scheme, and refuses to start (`Editor.Main.run`).

## The order

A host registers the packages in the order of the array, and of two
packages that register one name the later is the one found. The order below
keeps each kind of entry in the order the hosts registered it before there
were packages, so the command prompt, the keymaps, the mode line and the
language table read as they did:

- `menu` comes after `frame-commands`: the key bindings are the frame's,
  then the menu's;
- `themes` defines the theme `default` and no package after it defines a
  theme, so the themes of a Lake package that requires the core (the
  palettes of `shipped-themes`, `packages/shipped-themes/`) follow
  `default`, as the theme prompt lists them;
- `restore` comes after `themes`: it keeps state under the state
  directory, and what it registers follows the themes';
- `package-set` comes right after `restore`: a user's package-set build
  restarts the editor through the restore's restart, and its ex names
  follow `restart`'s;
- `ex` comes first of the packages that bind ex names: the ex names'
  completion lists them in the order they were bound, the `ex` package's
  first, and every Lake package's after the core's.

Nothing in this list is ordered by what a package depends on: a command's
name is looked up when it is run, so a package may name a command of a
later one. Between Lake packages the order is by dependency: every package
here registers before any package of a Lake package that requires the
core. So the compile mode's package, which was seventeenth here, between
`shell` and `at-point`, registers after all of these now: its commands
follow version control's in the command prompt, and its ex names follow
version control's (`docs/design/packages.md`, "Registration order is
visible"). The languages' package, which was last here, is the default
package `languages` (`packages/languages/`) now, and registers after the
core's and the compile mode's: the `code` mode still follows version
control's modes. The mode line's package, which was second here, is the
default package `mode-line` (`packages/mode-line/`), and registers its
segments after version control's `review`: a listing names segments, and
resolves them by name, so the order shows nowhere. The command prompt's
package, which was thirteenth here, after `themes`, is the default package
`execute-command` (`packages/execute-command/`): its command follows
version control's in the command prompt now. The binding search's, which
was after it, is the default package `binding-search`
(`packages/binding-search/`), and registers directly after it. The
completion styles' and displays' package, which was first here, is the
default package `completion` (`packages/completion/`), and is the first
default package to register: its styles and displays are still the first
registered in the default set, so `fuzzy` and `minibuffer` are still its
defaults (`Config.Registry.styleEntry`, `displayEntry`). Completion at
point's package, which was seventeenth here, after `shell`, is the default
package `at-point` (`packages/at-point/`), and registers after the compile
mode's: its commands follow compile's in the command prompt. The
minibuffer's package, which was second here, after `files`, is the
default package `minibuffer` (`packages/minibuffer/`), and registers after
the mode line's, before the shipped themes': its commands follow version
control's gutter's in the command prompt, and its mode follows version
control's modes. The seven features the features-as-packages roadmap's
phase 6 moved out are default packages now (`packages/<p>/`), which the
default set requires first, in the order they held here (its D5):
`files`, which was first here, `buffers`, after `ex`, `workspace`,
`project-search` and `working-set`, after `themes`, `shell`, after
`package-set`, and version control's two, `version-control` and
`version-control-gutter`, which were last and are both listed by that
package's entry module. So they register after every
package here and before every other default package: their commands
follow `package-set`'s in the command prompt, in their old order, and
before the minibuffer's; the workspace finder's escape, its one binding,
still follows the menu's; and version control's ex names still follow
ex's and come before the compile mode's. Evil's package, which
was first here, is the default package `evil` (`packages/evil/`) since
that roadmap's phase 7, and the first default package to register (its
D6): its commands, which were the first registered, follow `package-set`'s
in the command prompt now and come before the files'.
-/

namespace EditorCore.EditorPackage

open Editor

/-- The packages of the core's Lake package, in the order a host registers
them ("The order", in the module docs). -/
def packages : Array Package :=
  #[Ex.package, FrameCommands.package, Menu.package, WindowCommands.package, TabCommands.package,
    Themes.package, Restore.package, PackageSet.package]

end EditorCore.EditorPackage
