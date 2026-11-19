# Packages and the core

What the core is, what a package may import of it, which modules are core
and which are features that could become packages, and what each feature
would have to cross to move out. Written by the packages roadmap's phase 3,
which built the core's root module, cut every import from the core into the
two features that move in that roadmap (the compile mode and the shipped
palettes), and put a check of that in the gate. What a package is, how a
host registers one and the list of the packages that ship are in
[lean-runtime.md](lean-runtime.md), "Packages".

Everything is still one Lake package (`lean/lakefile.lean`). This document
draws the lines the later phases cut along: phase 4 gives the package set a
directory and a generated root, phase 5 moves the shipped palettes out and
phase 6 the compile mode.

## The core and its root

**The core** is every module under `lean/Editor/` except:

- the modules of the two features that move out in this roadmap, called
  **the moving modules** here: the compile mode (`Editor.Compile` and every
  module under it, phase 6) and the shipped palettes
  (`Editor.Themes.Solarized`, `Editor.Themes.FairyFloss` and
  `Editor.Themes.Shipped`, phase 5);
- `Editor.PackageSet`, the hand-written list of the packages that ship.

So the ex line, files, workspaces, version control and every other feature
that does not move yet are core modules, and "core" in the gate's check
means this set. The module map below says which of them are features that
could move later.

- **The core's root module is `Editor.Core`** (`lean/Editor/Core.lean`). It
  declares nothing and imports the core modules no other core module
  imports, so its import closure is the whole core. It is a second root of
  the `Editor` library, beside `Editor` (the `roots` of `lean_lib Editor`
  in `lean/lakefile.lean`), so `lake build` builds it and with it every
  core module. No host module, no package and no executable's root imports
  it.
- **`Editor` is the config base, not the core's root** (`lean/Editor.lean`).
  User config is elaborated on it, and it imports both moving features
  (`Editor.Compile`, `Editor.Compile.Shipped`) so that config can call
  them. It keeps its imports until the base changes (phase 7). It is not
  under `lean/Editor/` and is not a core module: after phase 6 it imports a
  package.
- **`Editor.PackageSet` is neither core nor a feature.** It names every
  package, the moving ones among them, in the one order the headless
  fixtures show ("Registration order is visible", below), so it cannot be a
  core module, and it holds no feature's code. The core's root does not
  import it, and both import checks exempt it by name. Phase 4 replaces it
  with a generated root. It is the one module the map below gives neither
  class.
- **A root that links the elaborator imports the config base.** The
  elaborator adapter (`Editor.Config.Elaborate`) imports the base's modules
  from their `.olean` files at runtime, and each must already be linked
  into the executable ([lean-runtime.md](lean-runtime.md), "One shared
  state"). The adapter used to import `Editor` to make that so, and through
  that import it, the headless host and the window host reached the
  compile mode. Now each root that links the adapter imports `Editor`
  beside it: `lean/Main.lean`, `lean/ConfigTest/Check.lean`,
  `lean/FfiTest/Editor/Window/Real.lean`, and the root of the user-side
  link fixture (`tests/user-link/package/Main.lean`). **The root phase 4
  generates must import the base as `Main` does**, and the check below
  fails a root that does not.

## What a package may import

The core's API is the set of core modules a package may name in an `import`
line. It is defined by a rule over the module map, and each row of the map
says which side of the rule its modules are on.

- **A package may import any core module that is not internal.** The rule
  is about `import` lines. Lean's imports are transitive, so a module an
  importable module imports is visible to the package's code whether or not
  the package may name it; what the rule limits is what a package depends
  on by name, which is what a later rename or move can break.
- **A package's tests may also import the core's test doubles**: the pure
  models of the ports (`….Model`), the contracts and cases (`….Contract`,
  `….Cases`), the fakes (`Editor.Completion.Fake`, `Editor.Job.Fake`), the
  test scheme (`Editor.InputScheme.Test`) and the loop's driver
  (`Editor.Loop.Driver`).
- **Internal modules** are those that exist to run the editor and not to be
  written against:
  - the hosts and the executable's modules (`Editor.Headless`,
    `Editor.Headless.CommandLine`, `Editor.Window`, `Editor.Window.Real`,
    `Editor.WindowCheck`, `Editor.WindowCheck.Real`, `Editor.Executable`,
    `Editor.Version`, `Editor.ModuleLookup`);
  - the loop and its dispatch (`Editor.Loop`, `Editor.Command.Dispatch`,
    `Editor.Event.Queue`, `Editor.State.Outbox`);
  - the config session (`Editor.Config.*`);
  - the raw bindings (`Editor.Ffi`, `Editor.Ffi.*`);
  - the real bindings of the ports and what runs them (`….Real`,
    `Editor.Clipboard.InProcess`, `Editor.Display.Recorder`,
    `Editor.Job.Runner`, `Editor.Job.Jobs`, `Editor.Job.Table`,
    `Editor.Job.Pool`);
  - the entry modules of the packages still in the core (`….Compiled`);
  - `Editor.Core` and `Editor.PackageSet`.
- **The internal namespace is `Editor.Internal`.** A core module that no
  package may import is created under it from now on, so that its name
  says so. The modules listed above are internal today under older names
  and keep them: renaming about 85 modules moves their mirrored test
  modules and every path the documents cite, and is filed as a task of its
  own (`internal-namespace-rename`).
- **`Editor`, the config base, is not part of the API.** A package imports
  the modules it uses, not the base.
- **A feature still in the core is importable where its row says so.** The
  compile mode imports `Editor.Shell` and `Editor.Workspace.Modes`, which
  are features' modules; until those features move they are core modules a
  package may import.
- **No module lists the API and no check enforces it yet.** This document
  is the authority, written as a rule a check on Lake's module graph can
  apply. The check that a package imports only API modules comes with the
  first package built outside the core (phase 5), which extends the API
  here if it needs to.

Checked against the graph at `ec882976`: every core module the moving
modules import directly is importable. The compile mode's modules import
`Editor.Api`, `Editor.Command.Call`, `Editor.File`, `Editor.Json`,
`Editor.Mode`, `Editor.Package`, `Editor.ProjectMode`,
`Editor.ProjectMode.Format`, `Editor.ProjectMode.Listing`, `Editor.Shell`
and `Editor.Workspace.Modes`; the shipped palettes' import `Editor.Face` and
`Editor.Package`. `Editor.Themes.Check`, the completeness check phase 5's
tests run, is importable.

**The moving features' tests import internal modules today**, which the
rule does not allow a package's tests. They are recorded here, not allowed
by widening the rule; phases 5 and 6 extend the API, or change the tests,
when they move them:

- the compile mode's tests (`ModelTest.Editor.Compile` and the modules
  under it, `ContractTest.Editor.Compile` and `.Compile.Shipped`):
  `Editor.Command.Dispatch`, `Editor.Command.Real`,
  `Editor.Config.Packages`, `Editor.Config.Registry`,
  `Editor.Config.Stores`, `Editor.Display.Recorder`,
  `Editor.Ffi.Processes`, `Editor.Ffi.Snapshot`, `Editor.Job.Runner`,
  `Editor.Loop` and `Editor.Text.Real`;
- the shipped palettes' tests (`ModelTest.Editor.Themes.Shipped`,
  `.Solarized`, `.FairyFloss`, `FfiTest.Editor.Themes.Shipped`):
  `Editor.Config.Packages`, `Editor.Config.Registry`,
  `Editor.Display.Real`, `Editor.Ffi.Display`, `Editor.Ffi.Document`,
  `Editor.Ffi.Marker`, `Editor.Ffi.Snapshot`, `Editor.Ffi.Window`,
  `Editor.Loop` and `Editor.Text.Real`.

## The interfaces the core owns for the two moving features

Seven import edges led from a core module to a module outside the core.
Each is cut, so the core's root reaches no moving module and phase 6 cuts
none. What replaced each edge is an interface the core owns.

| Edge that was cut | What the core owns now |
|---|---|
| `Editor.Setup` → `Editor.Compile.Contribution`; `Editor.Command.Registry` → `Editor.Compile.Contribution` | The contribution vocabulary, as data |
| `Editor.Workspace.Modes` → `Editor.Compile.Listing` | The listing of computed commands |
| `Editor.Ex.Compiled` → `Editor.Compile` | Ex names bound by the package that owns the commands |
| `Editor.Themes.Compiled` → `Editor.Themes.Solarized`, `Editor.Themes.FairyFloss` | The `themes` package, with the palettes in a package of their own |
| `Editor.Config.Elaborate` → `Editor` | The base imported at the executables' roots ("The core and its root", above) |

- **The contribution vocabulary** (`lean/Editor/ProjectMode.lean`,
  `lean/Editor/ProjectMode/Format.lean`). The setup port registers
  contributions, the registry holds them by owner, the loop is told them
  and the workspace turns a contribution's minor mode on from its markers,
  so the types were the core's in everything but their module. The first
  module holds `NamedCommand`, `Listing`, `Contribution`,
  `ProjectCommands` and `Hook`; the second an error format as data
  (`Severity`, `Part`, `Atom`, `Piece`, `Step`, `Pattern`, `Format`, the
  builders `step` and `optionalStep`, `Format.general`) and the two tree
  helpers both sides use. **Every declaration keeps its full name**
  (`Editor.Compile.Contribution`, `Editor.Compile.Format`, …), so config
  and tests changed only `import` lines; a core module that declares names
  in `Editor.Compile` is unusual, and the two modules' docs say why. What
  stays with the compile mode is what reads them: the matcher and the
  sites it yields (`lean/Editor/Compile/Errors.lean`), and the offers and
  the formats in use (`lean/Editor/Compile/Contribution.lean`). No general
  "contribute to a named point" operation was built: it would be a new
  mechanism with owner, reload and refusal rules of its own.
- **The listing** (`lean/Editor/ProjectMode/Listing.lean`). Running a
  contribution's listing and keeping what it gave is upkeep of the core's
  own data, and the workspace starts it when a mode turns on. The module
  moved whole, names unchanged (`Compile.refreshListings`,
  `Compile.listedCommands`, `Compile.listJob`, the store
  `compile-listings`). **The job `compile-list` is registered by the
  `workspace` package**, beside `find-mode-markers`, which starts it, and
  no longer by the `compile` package. The cost: a set without the compile
  package still lists a contribution's commands, which nothing then
  reads. Calling a hook by a command name was not chosen: it would run as
  a second command, after the one that turned the modes on, which changes
  when the listing starts.
- **Ex names by owning package.** A package binds the ex names of its own
  commands (`exCommand`): the `compile` package its six
  (`lean/Editor/Compile/Compiled.lean`) and the `version-control` package
  its twelve (`lean/Editor/VersionControl/Compiled.lean`). The `ex`
  package keeps the files', its own and the buffers', which are features
  still in the core, and imports neither the compile mode nor version
  control. Version control's names moved with compile's although version
  control stays in the core, so that the names are bound in the order they
  were ("Registration order is visible").
- **The `themes` package and `shipped-themes`.** The `themes` package
  (`lean/Editor/Themes/Compiled.lean`) keeps `load-theme`, the theme
  `default` (`Theme.builtin`) and the theme source, and imports no
  palette. The package `shipped-themes` (`lean/Editor/Themes/Shipped.lean`)
  defines `solarized-dark`, `solarized-light` and `fairy-floss` and
  registers nothing else; the list names it directly after `themes`. Phase
  5 may rename it when it becomes a Lake package.
- **The `compilation.*` faces.** The face vocabulary
  (`lean/Editor/Face/Vocabulary.lean`) lists `compilation.error`,
  `compilation.warning` and `compilation.note`, and every palette defines
  them (`Palette.theme`, `lean/Editor/Face.lean`). They are the core's
  names for what the compile mode draws: the compile mode names faces the
  core's vocabulary holds, and no core module imports it for them. No edge
  was cut here; they stay in the core's vocabulary when the mode moves.

## The module map

Every module under `lean/Editor/`, 255 of them at `ec882976` (`find
lean/Editor -name '*.lean' | wc -l`), is **core** or part of a **feature
that could become a package**, except `Editor.PackageSet`, which is neither
("The core and its root"). The counts below add up to 255: 168 core,
86 in 21 features, and 1 neither.

- **Core** is what a host with no packages needs to start and run: the
  ports with their models and bindings, the state, the scene and display
  types, the loop, the setup port, the config session and the hosts; and
  any module a core module imports for a type it carries (`Editor.Ex.Line`,
  `Editor.Menu`, `Editor.ModeLine`, `Editor.Language`, `Editor.Workspace`,
  the three `Editor.ProjectMode` modules).
- **A feature** is code reached through a package's registrations: the 22
  packages of the set, as 21 features (the two version-control packages are
  one), with the Vim scheme counted with evil.
- **Every feature but `compile` and `shipped-themes` still lives in the
  core's Lake package**, and is a core module in the sense of the section
  above and of the gate's check. The map guides later moves; it does not
  commit to them.

One row covers modules that share a class and a side of the import rule.
"A package may import it" is `yes`, `in tests` (a test double), `no`
(internal) or, for the two moving features, the phase that moves it.

| Modules | Count | Class | A package may import it |
|---|---|---|---|
| `Editor.Core` | 1 | core | no |
| The hosts and the executable's modules: `Editor.Headless`, `.Headless.CommandLine`, `Editor.Window`, `.Window.Real`, `Editor.WindowCheck`, `.WindowCheck.Real`, `Editor.Executable`, `Editor.Version`, `Editor.ModuleLookup` | 9 | core | no |
| The loop and its dispatch: `Editor.Loop`, `Editor.Command.Dispatch`, `Editor.Event.Queue`, `Editor.State.Outbox` | 4 | core | no |
| The config session: `Editor.Config.Diagnostic`, `.Directory`, `.Display`, `.Elaborate`, `.Owner`, `.Packages`, `.Registry`, `.Reload`, `.Session`, `.Stores` | 10 | core | no |
| The raw bindings: `Editor.Ffi` and the 25 modules under it | 27 | core | no |
| The real bindings of ports and what runs them: `Editor.Clipboard.Real`, `.Clipboard.InProcess`, `Editor.Command.Real`, `Editor.Display.Real`, `.Display.Recorder`, `Editor.Fuzzy.Real`, `Editor.Job.Real`, `.Job.Runner`, `.Job.Jobs`, `.Job.Table`, `.Job.Pool`, `Editor.SyntaxTree.Real`, `Editor.Text.Real`, `Editor.Watch.Real` | 14 | core | no |
| The models: `Editor.Clipboard.Model`, `Editor.Command.Model`, `Editor.Diff.Model`, `Editor.Display.Model`, `Editor.File.Model`, `Editor.FileWatch.Model`, `Editor.Fuzzy.Model`, `Editor.Job.Model`, `Editor.Process.Model`, `Editor.SyntaxTree.Model`, `.Model.Json`, `.Model.Query`, `Editor.Text.Model`, `Editor.Watch.Model` | 14 | core | in tests |
| The contracts and cases: `Editor.Clipboard.Contract`, `Editor.Completion.Contract`, `.AtPointContract`, `.DisplayContract`, `.StyleContract`, `Editor.Display.Contract`, `Editor.Fuzzy.Contract`, `Editor.InputScheme.Contract`, `Editor.Job.Contract`, `Editor.SyntaxTree.Contract`, `Editor.Text.Contract`, `Editor.Watch.Contract`, `Editor.Api.Cases`, `Editor.File.Cases`, `Editor.UndoTree.Cases` | 15 | core | in tests |
| The fakes, the test scheme and the loop's driver: `Editor.Completion.Fake`, `Editor.Job.Fake`, `Editor.InputScheme.Test`, `Editor.Loop.Driver` | 4 | core | in tests |
| The editor API and what is proved of it: `Editor.Api`, `.Api.Theorems`, `Editor.UndoTree`, `.UndoTree.Theorems` | 4 | core | yes |
| The composite port and a command: `Editor.Command`, `.Call`, `.Control`, `.Registry`, `.Append`, `Editor.Program` | 6 | core | yes |
| The ports: `Editor.Clipboard`, `Editor.Diff`, `.Diff.Script`, `Editor.Display`, `Editor.File`, `Editor.FileWatch`, `Editor.Fuzzy`, `Editor.Job`, `Editor.Process`, `.Process.Environment`, `Editor.SyntaxTree`, `Editor.Text`, `Editor.Watch` | 13 | core | yes |
| The setup port, packages and stores: `Editor.Setup`, `Editor.Package`, `Editor.Store`, `Editor.Value`, `Editor.Json` | 5 | core | yes |
| The state: `Editor.State`, `.State.Request`, `Editor.Event`, `Editor.DisplayRules`, `Editor.Floating`, `Editor.Layout`, `Editor.GeneratedView`, `Editor.ExcerptView`, `Editor.Gutter`, `Editor.Workspace` | 10 | core | yes |
| The scene and display types: `Editor.Scene`, `Editor.Scroll`, `Editor.Face`, `.Face.Vocabulary`, `Editor.Appearance`, `Editor.Highlight`, `Editor.TabBar`, `Editor.ModeLine`, `Editor.Menu` | 9 | core | yes |
| Keys and modes: `Editor.InputScheme`, `Editor.Invocation`, `Editor.Keymap`, `Editor.Key.Notation`, `Editor.Mode`, `Editor.Role`, `Editor.Vocabulary` | 7 | core | yes |
| Completion: `Editor.Completion`, `.Candidate`, `.Display`, `.Style`, `.AtPoint`, `.Keys`, `.Later`, `.Filtering` | 8 | core | yes |
| Languages and indentation: `Editor.Language`, `.Language.IndentUnit`, `Editor.Indent` | 3 | core | yes |
| What a minor mode contributes: `Editor.ProjectMode`, `.ProjectMode.Format`, `.ProjectMode.Listing` | 3 | core | yes |
| What the ex line and a typed path are as data: `Editor.Ex.Line`, `Editor.TypedPath` | 2 | core | yes |
| `Editor.AtPoint`, `Editor.Completion.Words` | 2 | feature: at-point | yes |
| `Editor.AtPoint.Compiled` | 1 | feature: at-point | no |
| `Editor.BindingSearch` | 1 | feature: binding-search | yes |
| `Editor.BindingSearch.Compiled` | 1 | feature: binding-search | no |
| `Editor.Buffers` | 1 | feature: buffers | yes |
| `Editor.Buffers.Compiled` | 1 | feature: buffers | no |
| `Editor.Compile`, `.Compiled`, `.Contribution`, `.Errors`, `.Shipped` | 5 | feature: compile | moving (phase 6) |
| `Editor.Completion.Styles`, `.Displays` | 2 | feature: completion | yes |
| `Editor.Completion.Compiled` | 1 | feature: completion | no |
| `Editor.Evil.Compiled` | 1 | feature: evil | no |
| `Editor.Evil` and the other 10 modules under it; `Editor.InputScheme.Vim`, `.Vim.Default` | 13 | feature: evil | yes |
| `Editor.Ex` | 1 | feature: ex | yes |
| `Editor.Ex.Compiled` | 1 | feature: ex | no |
| `Editor.ExecuteCommand` | 1 | feature: execute-command | yes |
| `Editor.ExecuteCommand.Compiled` | 1 | feature: execute-command | no |
| `Editor.Files`, `Editor.Completion.Paths` | 2 | feature: files | yes |
| `Editor.Files.Compiled` | 1 | feature: files | no |
| `Editor.FrameCommands` | 1 | feature: frame-commands | yes |
| `Editor.FrameCommands.Compiled` | 1 | feature: frame-commands | no |
| `Editor.Language.Compiled` | 1 | feature: languages | no |
| `Editor.Menu.Compiled` | 1 | feature: menu | no |
| `Editor.Minibuffer` | 1 | feature: minibuffer | yes |
| `Editor.Minibuffer.Compiled` | 1 | feature: minibuffer | no |
| `Editor.ModeLine.Compiled` | 1 | feature: mode-line | no |
| `Editor.Shell` | 1 | feature: shell | yes |
| `Editor.Shell.Compiled` | 1 | feature: shell | no |
| `Editor.Themes.Shipped`, `.Solarized`, `.FairyFloss` | 3 | feature: shipped-themes | moving (phase 5) |
| `Editor.TabCommands` | 1 | feature: tab-commands | yes |
| `Editor.TabCommands.Compiled` | 1 | feature: tab-commands | no |
| `Editor.Themes`, `Editor.Themes.Check` | 2 | feature: themes | yes |
| `Editor.Themes.Compiled` | 1 | feature: themes | no |
| `Editor.VersionControl.Compiled` | 1 | feature: version-control | no |
| `Editor.VersionControl.Model`, `.Contract` | 2 | feature: version-control | in tests |
| `Editor.VersionControl` and the other 16 modules under it | 17 | feature: version-control | yes |
| `Editor.WindowCommands` | 1 | feature: window-commands | yes |
| `Editor.WindowCommands.Compiled` | 1 | feature: window-commands | no |
| `Editor.Workspace.Compiled` | 1 | feature: workspace | no |
| `Editor.Workspace.Model`, `.Contract` | 2 | feature: workspace | in tests |
| `Editor.Workspace.Attach`, `.Finder`, `.FindFile`, `.FindInProject`, `.Lister`, `.Modes`, `.Projects`, `.Reach` | 8 | feature: workspace | yes |
| `Editor.PackageSet` | 1 | neither | no |

### What each feature would have to cross

For each feature, from Lake's direct imports (`lake query
+<module>:imports`) at `ec882976`:

- its modules;
- the core modules that import one of them, each with what it imports (the
  core's root, `Editor.Core`, imports every feature's entry module and is
  left out);
- the other features' modules that import one of them;
- the other features it imports;
- the test modules that import one of them, other than its own tests, which
  are the test modules that mirror its modules' paths (a `Support` module
  is listed even where it is that feature's own helper, since it would
  move or be split with it); names are written without the `Editor.`
  after the test root, and "the root" is the test executable's root
  module;
- which of its modules the config base (`Editor`) imports, so that config
  can call them;
- the reaches by name it is known to have, which the import graph does not
  show: a command named in the Vim scheme's default tables, in a menu, by
  an ex name or in the default config. **These are not exhaustive.**

#### `at-point`

- **Modules** (3): `AtPoint`, `AtPoint.Compiled`, `Completion.Words`.
- **Core modules that import it**: `Loop` (`AtPoint`).
- **Other features' modules that import it**: none.
- **Other features it imports**: none.
- **Test modules outside its own tests that import it** (9): `ModelTest`: `Completion.AtPointContract`, `Config.Registry`, `Config.Reload`, `InputScheme.Vim.Default`, `Loop`, `Support.AtPoint`, `Support.Evil`; `ConfigTest`: `Bench`, `Headless`.
- **The config base imports**: `AtPoint`, `Completion.Words`.
- **Reaches by name** (not exhaustive): the Vim scheme's default tables name its commands (`at-point-complete`, `at-point-next` and the rest, `InputScheme/Vim/Default.lean`), and the loop asks it by import.

#### `binding-search`

- **Modules** (2): `BindingSearch`, `BindingSearch.Compiled`.
- **Core modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: none.
- **Test modules outside its own tests that import it** (2): `ModelTest`: `Completion.Contract`; `ConfigTest`: `ExecuteCommand`.
- **The config base imports**: `BindingSearch`.
- **Reaches by name** (not exhaustive): the default config binds `search-bindings` (`config/default`).

#### `buffers`

- **Modules** (2): `Buffers`, `Buffers.Compiled`.
- **Core modules that import it**: none.
- **Other features' modules that import it**: ex: `Ex.Compiled` (`Buffers`); version-control: `VersionControl.Commit` (`Buffers`).
- **Other features it imports**: files (`Files`).
- **Test modules outside its own tests that import it** (7): `ModelTest`: `Completion.Contract`, `DisplayRules`, `VersionControl.Gutter`, `Support.Buffers`, `Support.Files`; `ConfigTest`: `Headless`, `Minibuffer`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the `ex` package binds `b`, `ls` and `bd` to its commands; the default config binds `switch-buffer`, `list-buffers` and `close-buffer`.

#### `compile`

- **Modules** (5): `Compile`, `Compile.Compiled`, `Compile.Contribution`, `Compile.Errors`, `Compile.Shipped`.
- **Core modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: shell (`Shell`); workspace (`Workspace.Modes`).
- **Test modules outside its own tests that import it** (6): `ModelTest`: `Json`, `ProjectMode.Listing`, `Support.Compile`; `ConfigTest`: `Files`, `Headless`; `ContractTest`: `Support.Projects`.
- **The config base imports**: `Compile`, `Compile.Shipped`.
- **Reaches by name** (not exhaustive): the face vocabulary lists `compilation.error`, `compilation.warning` and `compilation.note` (`Face/Vocabulary.lean`), which every palette defines; it reads the store `compile-listings` and starts the job `compile-list`, both the core's; its six ex names are its own package's.

#### `completion`

- **Modules** (3): `Completion.Compiled`, `Completion.Displays`, `Completion.Styles`.
- **Core modules that import it**: `Command.Dispatch` (`Completion.Styles`); `Loop` (`Completion.Displays`, `Completion.Styles`); `Setup` (`Completion.Displays`, `Completion.Styles`).
- **Other features' modules that import it**: none.
- **Other features it imports**: none.
- **Test modules outside its own tests that import it** (39): `ModelTest`: `Api`, `AtPoint`, `Completion.Contract`, `Completion.DisplayContract`, `Completion.Filtering`, `Completion.Style`, `Completion.StyleContract`, `Config.Packages`, `Config.Registry`, `Config.Reload`, `Ex`, `Face.Vocabulary`, `Files`, `Loop`, `Setup`, `State`, `TabBar`, `TabCommands`, `Themes`, `Workspace`, `Support.AtPoint`, `Support.Candidates`, `Support.Driver`, `Support.Evil`, `Support.Files`, `Support.Loop`, `Support.Prompts`; `ConfigTest`: `Bench`, `AtPoint`, `Completion.Keys`, `Headless`, `Minibuffer`, `Support.Hosts`; `FfiTest`: `State`; `ContractTest`: `Compile`, `Completion.StyleContract`, `Shell`, `Watch.Real`, `Support.Projects`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the names `fuzzy`, `orderless`, `path` and `minibuffer`, which config chooses with `useStyle`, `useStyleFor`, `useDisplay`, and which the file prompt's category is given (`path`).

#### `evil`

- **Modules** (14): `Evil`, `Evil.Clipboard`, `Evil.Compiled`, `Evil.Motions`, `Evil.Objects`, `Evil.Operators`, `Evil.Registers`, `Evil.Repeat`, `Evil.Scroll`, `Evil.Theorems`, `Evil.TreeObjects`, `Evil.Undo`, `InputScheme.Vim`, `InputScheme.Vim.Default`.
- **Core modules that import it**: `Headless` (`InputScheme.Vim.Default`).
- **Other features' modules that import it**: menu: `Menu.Compiled` (`Evil.Clipboard`); themes: `Themes.Check` (`InputScheme.Vim.Default`).
- **Other features it imports**: none.
- **Test modules outside its own tests that import it** (29): `ModelTest`: `Api`, `AtPoint`, `ExcerptView`, `Face.Vocabulary`, `InputScheme.Contract`, `Loop`, `Menu`, `Minibuffer`, `State`, `TabBar`, `TabCommands`, `WindowCommands`, `Workspace.FindInProject`, `Support.AtPoint`, `Support.Config`, `Support.Evil`, `Support.Excerpt`, `Support.OperatorRows`, `Support.Views`, `Support.Vim`, `Support.Windows`; `ConfigTest`: `Bench`, `DefaultConfig`, `Headless`, `Indent`, `Support.Syntax`; `FfiTest`: `ExcerptView`, `Themes.Shipped`; `ContractTest`: `SyntaxTree.Real`.
- **The config base imports**: `Evil.Clipboard`, `Evil.Operators`, `Evil.Repeat`, `Evil.Scroll`, `Evil.Theorems`, `Evil.TreeObjects`, `Evil.Undo`, `InputScheme.Vim.Default`.
- **Reaches by name** (not exhaustive): every command the Vim scheme's default tables name is looked up when its key is pressed, evil's own and other features'; the `menu` package names `undo` and `redo` as strings; the face vocabulary and the completeness check name the cursor face of each Vim state (`Themes/Check.lean`); the headless and window hosts are typed by `Vim.Default.scheme` (the section on input schemes, below).

#### `ex`

- **Modules** (2): `Ex`, `Ex.Compiled`.
- **Core modules that import it**: `Loop` (`Ex`).
- **Other features' modules that import it**: frame-commands: `FrameCommands.Compiled` (`Ex`); window-commands: `WindowCommands` (`Ex`).
- **Other features it imports**: buffers (`Buffers`); files (`Files`); shell (`Shell`).
- **Test modules outside its own tests that import it** (14): `ModelTest`: `Completion.Contract`, `Evil`, `FrameCommands`, `Loop`, `Menu`, `Support.Buffers`, `Support.Compile`, `Support.Files`, `Support.Frame`, `Support.Shell`, `Support.Windows`; `ConfigTest`: `Headless`, `Support.Configs`; `ContractTest`: `Shell`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the Vim scheme's default tables name `ex`; `frame-commands` binds a key to `quit` and `window-quit` runs it, both by its name; the `compile` and `version-control` packages bind ex names, which need this package for a line to run them.

#### `execute-command`

- **Modules** (2): `ExecuteCommand`, `ExecuteCommand.Compiled`.
- **Core modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: none.
- **Test modules outside its own tests that import it** (2): `ModelTest`: `Completion.Contract`; `ConfigTest`: `Headless`.
- **The config base imports**: `ExecuteCommand`.
- **Reaches by name** (not exhaustive): the default config binds `execute-command`.

#### `files`

- **Modules** (3): `Completion.Paths`, `Files`, `Files.Compiled`.
- **Core modules that import it**: `Loop` (`Files`).
- **Other features' modules that import it**: buffers: `Buffers` (`Files`); ex: `Ex` (`Files`), `Ex.Compiled` (`Files`); menu: `Menu.Compiled` (`Files`); shell: `Shell` (`Files`); version-control: `VersionControl.Gutter` (`Files`), `VersionControl.Review` (`Files`), `VersionControl.Show` (`Files`), `VersionControl.Stage` (`Files`), `VersionControl.Status` (`Files`); workspace: `Workspace.FindFile` (`Files`).
- **Other features it imports**: workspace (`Workspace.Attach`).
- **Test modules outside its own tests that import it** (24): `ModelTest`: `Buffers`, `Command.Dispatch`, `Compile`, `Completion.Contract`, `DisplayRules`, `Ex`, `Loop`, `Menu`, `State`, `VersionControl.Stage`, `Window`, `Workspace.Attach`, `Workspace.FindFile`, `Support.Buffers`, `Support.Files`, `Support.VersionControl`, `Support.Workspace`; `ConfigTest`: `Bench`, `Ex`, `Headless`, `Loop`, `VersionControl.Gutter`, `Support.Configs`; `ContractTest`: `Support.Projects`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the `ex` package binds `w`, `w!`, `e`, `e!`, `autoread` and `noautoread` to its commands; the `menu` package's Open and Save; the workspace finder accepts through `open-file` (`Workspace/FindFile.lean`); the default config binds `open-file`, `save-buffer` and `reload-buffer`.

#### `frame-commands`

- **Modules** (2): `FrameCommands`, `FrameCommands.Compiled`.
- **Core modules that import it**: none.
- **Other features' modules that import it**: menu: `Menu.Compiled` (`FrameCommands`).
- **Other features it imports**: ex (`Ex`).
- **Test modules outside its own tests that import it** (4): `ModelTest`: `Menu`, `Support.Frame`; `ConfigTest`: `Headless`; `FfiTest`: `Window.Real`.
- **The config base imports**: `FrameCommands`.
- **Reaches by name** (not exhaustive): the `menu` package's Minimise and Enter Full Screen.

#### `languages`

- **Modules** (1): `Language.Compiled`.
- **Core modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: none.
- **Test modules outside its own tests that import it** (1): `ConfigTest`: `Headless`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): opening a file sets the mode `code` (`Language.codeName`, a core module's name) and chooses a language from the table this package fills.

#### `menu`

- **Modules** (1): `Menu.Compiled`.
- **Core modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: evil (`Evil.Clipboard`); files (`Files`); frame-commands (`FrameCommands`).
- **Test modules outside its own tests that import it** (5): `ModelTest`: `Evil.Clipboard`, `Menu`, `Support.Frame`; `ConfigTest`: `Headless`; `FfiTest`: `Window.Real`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): none known.

#### `minibuffer`

- **Modules** (2): `Minibuffer`, `Minibuffer.Compiled`.
- **Core modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: none.
- **Test modules outside its own tests that import it** (25): `ModelTest`: `Api`, `BindingSearch`, `Evil`, `Evil.Clipboard`, `Ex`, `ExecuteCommand`, `Files`, `InputScheme.Vim.Default`, `Loop`, `Themes`, `Workspace.FindInProject`, `Support.Buffers`, `Support.Candidates`, `Support.Compile`, `Support.Evil`, `Support.Files`, `Support.FindFile`, `Support.Prompts`, `Support.Shell`; `ConfigTest`: `Bench`, `Files`, `Headless`, `Themes`, `VersionControl.Gutter`, `Support.Configs`.
- **The config base imports**: `Minibuffer`.
- **Reaches by name** (not exhaustive): the Vim scheme's default tables name its commands (`minibuffer-accept`, `minibuffer-cancel` and the rest); every feature that asks a prompt needs this package for the prompt to be answered.

#### `mode-line`

- **Modules** (1): `ModeLine.Compiled`.
- **Core modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: none.
- **Test modules outside its own tests that import it** (2): `ConfigTest`: `Bench`, `Support.Hosts`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the default order of the mode line names its segments (`ModeLine.Order.standard`: `state`, `buffer`, `modified`, `changed`, `directory`).

#### `shell`

- **Modules** (2): `Shell`, `Shell.Compiled`.
- **Core modules that import it**: none.
- **Other features' modules that import it**: compile: `Compile` (`Shell`); ex: `Ex` (`Shell`).
- **Other features it imports**: files (`Files`).
- **Test modules outside its own tests that import it** (2): `ModelTest`: `InputScheme.Vim.Default`, `Support.Shell`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): none known beyond its imports: the ex line's `:!` and the compile mode call it.

#### `shipped-themes`

- **Modules** (3): `Themes.FairyFloss`, `Themes.Shipped`, `Themes.Solarized`.
- **Core modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: none.
- **Test modules outside its own tests that import it** (5): `ModelTest`: `Appearance`; `ConfigTest`: `ExecuteCommand`, `Themes`, `Themes.Check`; `FfiTest`: `ExcerptView`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): config names a palette (`useTheme` with `solarized-light`, as the fixture `tests/headless/shipped-themes` does); the reference pictures of `tests/render/themes` are of its themes.

#### `tab-commands`

- **Modules** (2): `TabCommands`, `TabCommands.Compiled`.
- **Core modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: window-commands (`WindowCommands`).
- **Test modules outside its own tests that import it** (4): `ModelTest`: `Completion.Contract`, `InputScheme.Vim.Default`, `Support.Windows`; `ConfigTest`: `Headless`.
- **The config base imports**: `TabCommands`.
- **Reaches by name** (not exhaustive): the Vim scheme's tab table and the default config name its commands (`tab-new`, `tab-close`, `tab-next` and the rest).

#### `themes`

- **Modules** (3): `Themes`, `Themes.Check`, `Themes.Compiled`.
- **Core modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: evil (`InputScheme.Vim.Default`).
- **Test modules outside its own tests that import it** (8): `ModelTest`: `Appearance`, `Completion.Contract`, `ExecuteCommand`, `Face.Vocabulary`, `Themes.Shipped`; `ConfigTest`: `ExecuteCommand`, `Headless`, `Minibuffer`.
- **The config base imports**: `Themes`.
- **Reaches by name** (not exhaustive): the default config binds `load-theme`; the theme `default` is the one in force when config names none (`Theme.defaultName`).

#### `version-control`

- **Modules** (20): `VersionControl`, `VersionControl.Blame`, `VersionControl.Commit`, `VersionControl.Compiled`, `VersionControl.Contract`, `VersionControl.Git`, `VersionControl.Gutter`, `VersionControl.HistoryRead`, `VersionControl.Hunk`, `VersionControl.Log`, `VersionControl.Model`, `VersionControl.Plumbing`, `VersionControl.Porcelain`, `VersionControl.Review`, `VersionControl.ReviewHunks`, `VersionControl.Show`, `VersionControl.Stage`, `VersionControl.Status`, `VersionControl.Views`, `VersionControl.Worktrees`.
- **Core modules that import it**: `Loop` (`VersionControl.Gutter`).
- **Other features' modules that import it**: workspace: `Workspace.FindInProject` (`VersionControl.Git`), `Workspace.Projects` (`VersionControl`).
- **Other features it imports**: buffers (`Buffers`); files (`Files`); workspace (`Workspace.Attach`, `Workspace.Reach`).
- **Test modules outside its own tests that import it** (8): `ModelTest`: `the root`, `Workspace.FindInProject`, `Workspace.Projects`, `Support.Git`, `Support.VersionControl`; `ContractTest`: `the root`, `Support.Git`, `Support.VersionControl`.
- **The config base imports**: `VersionControl.Commit`, `VersionControl.Stage`.
- **Reaches by name** (not exhaustive): the default order of the mode line names its segment `review`; its twelve `vc-` ex names are its own package's.

#### `window-commands`

- **Modules** (2): `WindowCommands`, `WindowCommands.Compiled`.
- **Core modules that import it**: none.
- **Other features' modules that import it**: tab-commands: `TabCommands` (`WindowCommands`).
- **Other features it imports**: ex (`Ex`).
- **Test modules outside its own tests that import it** (3): `ModelTest`: `InputScheme.Vim.Default`, `Support.Windows`; `ConfigTest`: `Headless`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the Vim scheme's `C-w` table and the default config name its commands (`window-split`, `window-close` and the rest).

#### `workspace`

- **Modules** (11): `Workspace.Attach`, `Workspace.Compiled`, `Workspace.Contract`, `Workspace.FindFile`, `Workspace.FindInProject`, `Workspace.Finder`, `Workspace.Lister`, `Workspace.Model`, `Workspace.Modes`, `Workspace.Projects`, `Workspace.Reach`.
- **Core modules that import it**: none.
- **Other features' modules that import it**: compile: `Compile` (`Workspace.Modes`); files: `Files` (`Workspace.Attach`); version-control: `VersionControl.Views` (`Workspace.Attach`), `VersionControl.Worktrees` (`Workspace.Reach`).
- **Other features it imports**: files (`Files`); version-control (`VersionControl`, `VersionControl.Git`).
- **Test modules outside its own tests that import it** (20): `ModelTest`: `the root`, `Compile`, `Compile.Shipped`, `Completion.Contract`, `ProjectMode.Listing`, `VersionControl.Gutter`, `VersionControl.Worktrees`, `Support.Compile`, `Support.FindFile`, `Support.Shell`, `Support.VersionControl`, `Support.Workspace`; `ConfigTest`: `Bench`, `DefaultConfig`, `Headless`, `VersionControl.Gutter`; `ContractTest`: `the root`, `Compile.Shipped`, `Workspace`, `Support.Projects`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the default config binds `find-file-in-workspace` and `find-file-in-project`; its package registers the job `compile-list`, which the compile mode starts by name.

## Input schemes

An input scheme is not registered by a package today: it is the host's
type parameter (`Headless.Collaborators σ scheme`), and the executable's
hosts are typed by the Vim scheme with its default states and bindings
(`Vim.Default.scheme`, named in `lean/Editor/Headless.lean`). So the core
imports the feature `evil` for it, and the completeness check of themes
reads the Vim states' cursor faces from it (`lean/Editor/Themes/Check.lean`).

**When evil moves out of the core, the scheme comes from a package, and the
editor refuses to start with no input-scheme package in the set** (decided
2026-11-17). It does not fall back to a built-in scheme: a set with no
scheme has no way to turn a key into a command, and saying so at start-up
is clearer than an editor that opens and takes no input. How a package
supplies a scheme, and what the refusal says, are that move's work; this
phase records the decision and the edges it will have to cut (the `evil`
entry above).

## The core imports check

`tools/core-imports-check.sh`, in `mise run ffi-test`, after the host
imports check ([the-gate.md](../dev-practices/the-gate.md), "The core
imports check"). It asks Lake for transitive imports (`lake query
+<module>:transImports`), reads no source text and builds nothing. Given
the root `Editor.Core` and the moving names, it holds three rules:

1. **The root and what it imports hold no moving module.** A core module
   that comes to import the compile mode or a shipped palette fails the
   gate, naming the module reached.
2. **Every `Editor.…` module the build reaches is in the root's closure**,
   unless it is a moving module or `Editor.PackageSet`. This is what makes
   the first rule a statement about every core module: a new core module
   nothing in the core imports fails the gate until `Editor.Core` imports
   it.
3. **A root that reaches the elaborator adapter reaches the config base**,
   which keeps the invariant the adapter's own import of `Editor` used to
   give.

The moving names are arguments, not derived from the graph: "everything the
root does not reach" would pass whatever the core imported. The gate runs
the check a second and a third time to see it bite, pointed at `Editor`
(exit 1) and at `Editor.Setup` (exit 3). When a feature moves out of the
core, its modules' names are added to the check's moving names.

## Registration order is visible

A host registers the packages in the order of the list, and two headless
outputs print that order, so it is part of what the fixtures pin:

- **The `commands:` lines** of `tests/headless/expected` and
  `tests/headless/bundle/expected` print every command name in
  registration order. The compile mode's commands sit between the shell's
  and at-point's.
- **The ex candidates for `e`** in `tests/headless/ex/expected` are the ex
  names in the order they were first bound (`Registry.exNames`), which the
  fuzzy rank keeps among equal scores. The names are bound by `ex`, then
  `compile`, then `version-control`, the sixth, eighteenth and twentieth
  packages of the list.

`ModelTest.packageSetChecks` pins both orders the fixtures depend on that a
model test can see: the ex names in bound order, and the theme names.

**Phase 4 orders packages by dependency, which puts a default package
after the core's.** The compile package would then register after version
control and at-point, and both fixture lines would change, unless phase 6
keeps the compile package's place in the order. That is phase 6's choice
to make with the fixtures in view.
