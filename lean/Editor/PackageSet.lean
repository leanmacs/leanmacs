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
# The packages that ship

`PackageSet.shipped` is the array of packages (`Editor/Package.lean`) the
executable's hosts are handed (`Headless.main`, `Window.main`), written by
hand. It is the one place the executable's packages are named: `Main.lean`
imports this module and passes the array on, and a host registers the
array it is given, in order, when it starts, before any config
(`Config.State.ofPackages`, `Editor/Config/Packages.lean`).

## This module is outside the host

No module of a host imports this one, or any module it imports: a host
takes its packages as a value and names none of them. The gate checks that
on Lake's module graph (`tools/host-imports-check.sh`, in `mise run
ffi-test`): the modules `Main` imports other than this one, with everything
they import, hold neither this module nor a module it imports directly.

So **this module imports package modules and nothing else**: its direct
imports are what that check forbids a host. A helper it needed would have
to live in a package's module, or the check would forbid the host that
helper too. Tests import it for the list (`ModelTest.packageSetChecks`,
`ConfigTest.shippedChecks`).

## This module is outside the core too

It names every package, the two that move out of the core among them (the
compile mode's, `Editor/Compile/Compiled.lean`, and the shipped palettes',
`Editor/Themes/Shipped.lean`), so it is neither a core module nor a
feature's: the core's root (`Editor/Core.lean`) does not import it, and
the core imports check exempts it by name
(`tools/core-imports-check.sh`; `docs/design/packages.md`).

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

Nothing is ordered by what a package depends on: a command's name is looked
up when it is run, so a package may name a command of a later one.
-/

namespace Editor.PackageSet

/-- The packages that ship, in the order a host registers them ("The
order", in the module docs). -/
def shipped : Array Package :=
  #[Completion.package, ModeLine.package, Files.package, Minibuffer.package, Evil.package,
    Ex.package, Buffers.package, FrameCommands.package, Menu.package, WindowCommands.package,
    TabCommands.package, Themes.package, Themes.Shipped.package, ExecuteCommand.package,
    BindingSearch.package, Workspace.package, Shell.package, Compile.package, AtPoint.package,
    VersionControl.package, VersionControl.gutterPackage, Language.package]

end Editor.PackageSet
