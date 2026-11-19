import Editor.Api.Cases
import Editor.Api.Theorems
import Editor.AtPoint.Compiled
import Editor.BindingSearch.Compiled
import Editor.Buffers.Compiled
import Editor.Clipboard.Contract
import Editor.Command.Append
import Editor.Completion.AtPointContract
import Editor.Completion.Compiled
import Editor.Completion.Contract
import Editor.Completion.DisplayContract
import Editor.Completion.Fake
import Editor.Completion.StyleContract
import Editor.Display.Contract
import Editor.Evil.Compiled
import Editor.Evil.Theorems
import Editor.Ex.Compiled
import Editor.Executable
import Editor.ExecuteCommand.Compiled
import Editor.File.Cases
import Editor.Files.Compiled
import Editor.FrameCommands.Compiled
import Editor.InputScheme.Contract
import Editor.Json
import Editor.Language.Compiled
import Editor.Loop.Driver
import Editor.Menu.Compiled
import Editor.Minibuffer.Compiled
import Editor.ModeLine.Compiled
import Editor.Shell.Compiled
import Editor.SyntaxTree.Contract
import Editor.TabCommands.Compiled
import Editor.Themes.Compiled
import Editor.Version
import Editor.VersionControl.Compiled
import Editor.VersionControl.Contract
import Editor.Watch.Contract
import Editor.Window.Real
import Editor.WindowCheck.Real
import Editor.WindowCommands.Compiled
import Editor.Workspace.Compiled
import Editor.Workspace.Contract

/-!
# The core

The root module of the core: it imports every core module, directly or
through another, and declares nothing. The core is every module under
`lean/Editor/` except the modules of the features that move out of it into
packages of their own (the compile mode, `Editor/Compile.lean` and
`Editor/Compile/`, and the shipped palettes, `Editor/Themes/Solarized.lean`,
`Editor/Themes/FairyFloss.lean` and `Editor/Themes/Shipped.lean`). The
hand-written list of the packages that ship is not under `lean/Editor/`
(`EditorCore/EditorPackage.lean`, a library of its own), and this module does not import
it. `docs/design/packages.md` says which modules those are, what a package may
import of the core, and what each feature still in the core would have to
cross to move out.

It is a root of the `Editor` library beside `Editor` (`lakefile.lean`), so
the build makes it and with it every core module. It is not the config
base: user config is elaborated on `Editor` (`Editor.lean`), which imports
both moving features until the base changes. It is not a host either: no
host module, no package and no executable's root imports it, so the host
imports check (`tools/host-imports-check.sh`) does not meet it.

## What it imports

The core modules no other core module imports: the entry modules of the
packages still in the core (`….Compiled`), the contracts, fakes, cases and
theorems, the hosts and the executable's modules, `Editor.Json`,
`Editor.Command.Append`, and the driver of the loop that tests run it with
(`Editor.Loop.Driver`). Everything else comes with them. The theorem
modules and `Editor.Command.Append` are also the config base's imports
(`Editor.lean`); they are named here because no core module imports the
base.

## The check

`tools/core-imports-check.sh` checks, on Lake's module graph, in `mise run
ffi-test`, that this module and what it imports hold no moving module, and
that every module named `Editor.…` an executable or a test executable
reaches is among them, unless it is moving. So a new core
module that nothing here reaches fails the gate until it is imported here,
and a core module that comes to import a moving one fails it too. It also
checks that an executable that links the elaborator links the config base
(`Editor/Config/Elaborate.lean`, "The base").
-/
