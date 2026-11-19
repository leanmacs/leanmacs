import Editor.AtPoint.Compiled
import Editor.BindingSearch.Compiled
import Editor.Buffers.Compiled
import Editor.Compile.Compiled
import Editor.Completion.Compiled
import Editor.Evil.Compiled
import Editor.Ex.Compiled
import Editor.ExecuteCommand.Compiled
import Editor.Files.Compiled
import Editor.FrameCommands.Compiled
import Editor.Language.Compiled
import Editor.Menu.Compiled
import Editor.Minibuffer.Compiled
import Editor.ModeLine.Compiled
import Editor.Shell.Compiled
import Editor.TabCommands.Compiled
import Editor.Themes.Compiled
import Editor.Themes.Shipped
import Editor.VersionControl.Compiled
import Editor.WindowCommands.Compiled
import Editor.Workspace.Compiled

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
list import. It names every package of the core's Lake package, the two
that move out of the core among them (the compile mode's,
`Editor/Compile/Compiled.lean`, and the shipped palettes',
`Editor/Themes/Shipped.lean`), so it can be neither a core module nor a
feature's (`docs/design/packages.md`): the core's root (`Editor/Core.lean`)
does not import it, and the core imports check, which is of the modules
named `Editor.…`, does not meet it (`tools/core-imports-check.sh`).

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

## The order

A host registers the packages in the order of the array, and of two
packages that register one name the later is the one found. The order below
keeps each kind of entry in the order the hosts registered it before there
were packages, so the command prompt, the keymaps, the mode line and the
language table read as they did:

- `completion` and `mode-line` come first: the shipped styles and displays,
  and the shipped segments before version control's `review`;
- `menu` comes after `frame-commands` and before `workspace`: the key
  bindings are the frame's, then the menu's, then the workspace finder's;
- `shipped-themes` comes directly after `themes`: the theme `default`,
  then the palettes, as the theme prompt lists them;
- `ex` comes before `compile`, and `compile` before `version-control`:
  each binds its own ex names, and the ex names' completion lists them in
  the order they were bound, the `ex` package's first;
- `compile` comes between `shell` and `at-point`: the command prompt lists
  commands in registration order;
- `languages` comes last: the `code` mode after version control's modes.

Nothing in this list is ordered by what a package depends on: a command's
name is looked up when it is run, so a package may name a command of a
later one. Between Lake packages the order is by dependency: every package
here registers before any package of a Lake package that requires the
core.
-/

namespace EditorCore.EditorPackage

open Editor

/-- The packages of the core's Lake package, in the order a host registers
them ("The order", in the module docs). -/
def packages : Array Package :=
  #[Completion.package, ModeLine.package, Files.package, Minibuffer.package, Evil.package,
    Ex.package, Buffers.package, FrameCommands.package, Menu.package, WindowCommands.package,
    TabCommands.package, Themes.package, Themes.Shipped.package, ExecuteCommand.package,
    BindingSearch.package, Workspace.package, Shell.package, Compile.package, AtPoint.package,
    VersionControl.package, VersionControl.gutterPackage, Language.package]

end EditorCore.EditorPackage
