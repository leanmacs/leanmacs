import Editor.Api.Cases
import Editor.Api.Theorems
import Editor.Clipboard.Contract
import Editor.Completion.AtPointContract
import Editor.Completion.DisplayContract
import Editor.Completion.Fake
import Editor.Completion.Filtering
import Editor.Completion.StyleContract
import Editor.Config.Elaborator.Contract
import Editor.Config.Elaborator.Model
import Editor.Display.Contract
import Editor.Headless.Journal.Contract
import Editor.Headless.Queue.Contract
import Editor.Indent
import Editor.InputScheme.Contract
import Editor.Job.FlushContract
import Editor.Job.HandleContract
import Editor.Job.Protocol.Theorems
import Editor.Job.ProtocolContract
import Editor.Job.PumpContract
import Editor.Job.SchedulerContract
import Editor.Jumps.Go
import Editor.Main
import Editor.SearchRoot
import Editor.SyntaxTree.DeliveryContract
import Editor.Test.AtPoint
import Editor.Test.Excerpt
import Editor.Test.Fixture.Main
import Editor.Test.Frame
import Editor.Test.Hosted
import Editor.Test.Linked.Bench
import Editor.Test.Linked.Frames
import Editor.Test.Linked.Grammar
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Lines
import Editor.Test.Linked.Rig
import Editor.Test.Linked.Shipped
import Editor.Test.Linked.Trees
import Editor.Test.Listings
import Editor.Test.Modes
import Editor.Test.PackageSet
import Editor.Test.Prompts
import Editor.Test.Restore
import Editor.Test.Shell
import Editor.Test.Sources
import Editor.Test.Views
import Editor.Test.Windows
import Editor.Text.Word
import Editor.Theme.Check
import Editor.Theme.Picture
import Editor.UndoTree.Theorems
import Editor.Vocabulary
import Editor.Watch.Contract

/-!
# The core

The root module of the core: it imports every core module, directly or
through another, and declares nothing. The core is every module under
`lean/Editor/`: no feature is between having its edges from the core cut
and moving out. The two that were have moved, the shipped palettes
(`packages/shipped-themes/`) and the compile mode (`packages/compile/`),
and are Lake packages that require the core. The core's Lake package
lists no package of its own and has no entry module since the
features-as-packages roadmap's phase 8. `docs/design/packages.md` says
which modules the core's are, what a package may import of the core, and
which package each feature that was the core's is.

It is a root of the `Editor` library beside `Editor` (`lakefile.lean`), so
the build makes it and with it every core module. It is not the config
base: user config is elaborated on `Editor` (`Editor.lean`) and, in an
editor built from a package set, on the entry modules of the set's
packages after it (`Editor/Main.lean`, "The base"). It is not a host either: no
host module, no package and no executable's root imports it, so the rule
on host imports (`.agents/rules/structure.md`, "Host imports") does not
meet it.

## What it imports

The core modules no other core module imports: the modules that define
the packages still in the core (`….Compiled`), the source a command
filters (`Editor.Completion.Filtering`, which the workspace package's finder
is built on), what a search covers (`Editor.SearchRoot`, which the project
search package reads), what evil, a package since phase 7, is written on
and no core module imports (the indent primitives, `Editor.Indent`, going
to a place, `Editor.Jumps.Go`, the word rule, `Editor.Text.Word`, the
vocabularies, `Editor.Vocabulary`, and the undo tree's theorems,
`Editor.UndoTree.Theorems`), the contracts, fakes, cases and theorems, the elaborator port's model
(`Editor.Config.Elaborator.Model`), the executable's entry (`Editor.Main`, which brings the
hosts, the executable's modes and `Editor.Command.Append`),
and the test kit the core publishes for a package's tests: the model
tests' (`Editor.Test.…`, `Editor/Test/`: `Editor.Test.Prompts`, which
imports much of it, among it the kit's
hand-written minibuffer (`Editor.Test.Minibuffer`), and
`Editor.Test.Shipped`, `Editor.Test.Sources`, the kit's hand-written
at-point (`Editor.Test.AtPoint`), and `Editor.Test.Files`, `.Hosted`
and `.Opener`, which no other kit module imports since the
listing's kit moved to `compile-api` in phase 8, the kit's stand-ins for
session restore's and the package-set build's registrations and for the
window and tab commands (`Editor.Test.Restore`, `.PackageSet`, `.Windows`,
phase 8), a shell command's child and replies on the process model
(`Editor.Test.Shell`, which brings `Editor.Test.Workspace`), the frame
driver (`Editor.Test.Frame`) and the style and
display written for tests (`Editor.Test.Listings`, the core's test support
until the ex line's tests needed it, phase 8), with `Editor.File.Cases`
and `Editor.UndoTree.Cases`, which it brought) and the
linked tests' (`Editor.Test.Linked.…`, `Editor/Test/Linked/`: its rig, its
services, its trees, its hosts over the real elaborator, which bring
their listings, and its shipped host, `Editor.Test.Linked.Shipped`); and the feature kits still in the core: none since phase
6, which moved the files feature's (`FilesTest.Kit`), the workspace's
(`WorkspaceTest.Kit`, with the finder's model and contract) and the
shell's (`ShellTest.Kit`) into their packages, and phase 7, which moved
evil's (`EvilTest.Kit`, with the linked kit's host of the Vim scheme,
`EvilTest.Linked.Support.Vim`) into the package `evil`. Everything else comes with them: the kit is the support the
core's own tests are written on, so it imports the driver of the loop that
tests run it with (`Editor.Loop.Driver`) and the modules that define the
packages its fixtures register, and those are not named here again. The theorem modules of
the editor API and the undo tree are also the config base's imports
(`Editor.lean`); they are named here because no core module imports the
base. The job runner protocol's theorems (`Editor.Job.Protocol.Theorems`)
are not: config has no use for them, and this module is what has the build
check them.

## The rule

Every module named `Editor.…` an executable or a test executable reaches
is this module or one it imports, so a new core module is imported here
in the change that adds it. An executable that links the elaborator links
the config base (`Editor/Config/Elaborate.lean`, "The base"). Both are
reviewer rules (`.agents/rules/structure.md`, "Core imports"): no gate
step checks them.
-/
