# Packages and the core

What the core is, what a package may import of it, how an editor is built
from the core and a set of packages, which modules are the core's, and
which package each feature that was the core's is. Written by the packages roadmap: its phase 3 built the
core's root module, cut every import from the core into the two features
that move in that roadmap (the compile mode and the shipped palettes), and
put a check of that in the gate; its phase 4 built the package set and its
build, which links the editor; its phase 5 moved the shipped palettes out
of the core into the first default package, `shipped-themes`, and built
the check of what a package imports; its phase 6 moved the compile mode
out into the second, `compile`, published the core's test support as a
test kit for a package's tests, and made the base config is elaborated on
the package set's. The features-as-packages roadmap's phase 3 moved four
more features out, each into a default package of its own: the mode line's
segments (`mode-line`), the command prompt (`execute-command`), the
binding search (`binding-search`) and the languages (`languages`), with
the first two feature interface packages, `execute-command-api` and
`binding-search-api`. Its phase 4 moved three more: the completion styles
and displays (`completion`), completion at point (`at-point`) and the
minibuffer's commands and mode (`minibuffer`), each with an interface
package of its own (`completion-api`, `at-point-api`, `minibuffer-api`),
and gave the core a style and a display of its own for a set that
registers none. Its phase 6 moved the files cluster out, seven features,
each into a default package of its own: the file commands (`files`), the
buffer commands (`buffers`), the workspaces (`workspace`), project search
(`project-search`), the working sets (`working-set`), the shell (`shell`)
and version control (`version-control`, two packages), with two
names-only interface packages, `project-search-api` and `working-set-api`,
and two interface libraries the core had staged, `project-api` and
`vc-api`, as interface packages of their own. Its phase 7 moved evil, with
the Vim scheme, and the themes out (`evil`, `themes`), with two names-only
interface packages, `evil-api` and `themes-api`: the input scheme is a
package's since, and an editor whose set supplies none refuses to start
("Input schemes", below). Its phase 8 moved the last features out: the
ex line (`ex`), the frame, window and tab commands (`frame-commands`,
`window-commands`, `tab-commands`) and the menu bar that ships (`menu`),
and with them session restore's registrations (`restore`) and the
package-set commands (`package-set`), with four names-only interface
packages (`ex-api`, `frame-commands-api`, `window-commands-api`,
`tab-commands-api`), the compile mode's contributions as extension points
of a new interface package (`compile-api`), and the last two interface
libraries the core had staged as interface packages of their own
(`buffers-api`, `shell-api`). The core's Lake package lists no package
since, and has no entry module. What a package is and how a
host registers one are in [lean-runtime.md](lean-runtime.md), "Packages".

**No feature is in the core's Lake package** (`lean/lakefile.lean`, the
package `editor-core`): it registers no `Package` and has no entry module
("A package's entry module", below). The default package set
(`packages/lakefile.toml`) requires the core and twenty-five default
packages, in this order, each with the interface packages it requires:

1. `ex` (`ex-api`, `buffers-api`, `shell-api`), `frame-commands`
   (`frame-commands-api`), `menu` (`evil-api`, `frame-commands-api`),
   `window-commands` (`window-commands-api`), `tab-commands`
   (`tab-commands-api`), `restore` and `package-set`: the seven the core's
   own list held last, which phase 8 moved out;
2. `evil` (`evil-api`, `minibuffer-api`, `at-point-api`,
   `window-commands-api`, `tab-commands-api`, `ex-api`, `buffers-api`,
   `shell-api`) and `themes` (`themes-api`), phase 7's;
3. `files` (`buffers-api`), `buffers` (`buffers-api`), `workspace`
   (`project-api`, `vc-api`, `compile-api`), `project-search`
   (`project-search-api`), `working-set` (`working-set-api`, `vc-api`,
   `buffers-api`), `shell` (`shell-api`) and `version-control`
   (`project-api`, `vc-api`, `buffers-api`), phase 6's;
4. `completion` (`completion-api`), `mode-line`, `minibuffer`
   (`minibuffer-api`), `shipped-themes`, `execute-command`
   (`execute-command-api`, `minibuffer-api`), `binding-search`
   (`binding-search-api`, `minibuffer-api`), `compile` (`minibuffer-api`,
   `compile-api`, `shell-api`), `at-point` (`at-point-api`, `evil-api`)
   and `languages`, the earlier phases'.

Each has a directory under `packages/`, as each of the eighteen interface
packages has. "The module map", below, lists them with what each
registers at and reads.

What a package author and a user read is in `docs/packages/`: the guide
to writing a package ([writing-a-package.md](../packages/writing-a-package.md))
and the guide to installing, updating and removing them
([installing-packages.md](../packages/installing-packages.md)).

## The core and its root

**The core** is every module under `lean/Editor/`. Between phase 3, which
cut the core's imports of a feature, and the phase that moved it, the
feature's modules were still under `lean/Editor/` and not the core's: they
were called **the moving modules**. There is none now. The shipped palettes
moved in phase 5 and the compile mode in phase 6: they are the Lake
packages `shipped-themes` and `compile`, their modules are named
`ShippedThemes.…` and `Compile.…`, and no module under `lean/Editor/` is
theirs. The four features of the features-as-packages roadmap's phase 3
are the Lake packages `mode-line`, `execute-command`, `binding-search` and
`languages`, their modules named `ModeLine.…`, `ExecuteCommand…`,
`BindingSearch…` and `Languages.…`; the three of its phase 4 are the Lake
packages `completion`, `at-point` and `minibuffer`, their modules named
`Completion.…`, `AtPoint…` and `Minibuffer…`.

So the ex line, files, workspaces, version control and every other feature
that has not moved are core modules, and "core" in the gate's check
means this set. The module map below says which of them are features that
could move later.

- **The core's root module is `Editor.Core`** (`lean/Editor/Core.lean`). It
  declares nothing and imports the core modules no other core module
  imports, so its import closure is the whole core. It is a second root of
  the `Editor` library, beside `Editor` (the `roots` of `lean_lib Editor`
  in `lean/lakefile.lean`), so `lake build` builds it and with it every
  core module. No host module, no package and no executable's root imports
  it.
- **`Editor` is the core's config base, not the core's root**
  (`lean/Editor.lean`). User config is elaborated on it: it imports what
  config may call of the core. It imports no package and cannot, since the
  core requires none, so a set with no package still loads config on it.
  It imported the compile mode (`Editor.Compile`, `Editor.Compile.Shipped`)
  until phase 6 moved that mode out; it never imported a palette. It is not
  under `lean/Editor/` and is not a core module.
- **The base an editor elaborates config on is its package set's**: this
  module, then the entry module of each package of the set outside the
  core, in the order they register ("The config base of a set", below). So
  config names what a default package declares (`Compile.cargoMode`,
  `ShippedThemes.themes`), as it named the compile mode's declarations
  while that was in the core.
- **The core's Lake package lists no package.** It has no entry module
  ("A package's entry module", below), so an editor of the core alone
  hands its hosts no package (`tests/empty-set`). Until the
  features-as-packages roadmap's phase 8 it had one,
  `EditorCore.EditorPackage`, a library of its own outside `lean/Editor/`
  whose `packages` named every package still in that Lake package. The
  Lake package is still named `editor-core`, not `editor`: a package named
  `editor` that did list packages would list them at
  `Editor.EditorPackage`, under the namespace the core imports check
  rules, and `editor-core` is the name the staged core of the user-side
  link has.

- **The default set is `packages/lakefile.toml`** (the Lake package
  `default-set`). It requires the core (`editor-core`, from `../lean`) and
  the default packages, each of which has a directory under `packages/`
  and a `require` there. There are twenty-five, required in the order the
  top of this document lists: the seven of phase 8 ("The default packages
  of the features-as-packages roadmap's phase 8", below), `evil` and
  `themes` ("… phase 7"), the seven of phase 6 ("… phase 6"), then
  `completion`, `mode-line`, `minibuffer`, `shipped-themes`,
  `execute-command`, `binding-search`, `compile`, `at-point` and
  `languages` ("The first default package", "The default package
  `compile`", "… phase 3" and "… phase 4"). Twenty of them require an
  interface package of their own or another's, which is in the set through
  that `require`. It is the lakefile a user's set starts from.
- **The core defines the build**, as Lake facets in `lean/lakefile.lean`.
  Run in `lean/`, `lake -d ../packages build :editor` writes a root module
  from the set's packages, builds it and links
  `packages/.lake/build/bin/editor` with the glue and the Rust archive.
  `mise run lean`, `mise run edit`, `mise run app` and the gate all use
  that file. The core declares no `editor` executable, and
  `lean/.lake/build/bin/editor` does not exist.
- **A set's lakefile is data.** The link's objects and arguments are the
  core's knowledge, and a lakefile cannot import another's definitions, so
  the build is a facet and not a stanza each set repeats. A facet a
  required package defines works on a root whose lakefile is TOML. The
  default set's lakefile is the one a later phase generates and edits for a
  user (phases 7 and 8), and the app ships the core built, so the same
  facets run over its prebuilt pieces (phase 9).

| Facet | On | Gives |
|---|---|---|
| `editor` | a package, the set | `<set>/.lake/build/bin/editor`, and beside it `editor.oleans`, the record of where the set's `.olean` directories are |
| `editorApp` | a package, the set | `<set>/.lake/build/Leanmacs.app`, from the set's `editor` ([building.md](../dev-practices/building.md), "The app bundle") |
| `editorLinked` | a module | An executable rooted at that module, linked as the editor is, in its package's `bin/`, named as the module with a dash for each dot |
| `editorRoot` | a package, the set | For `lake query`: writes the set's root module and prints its path; links and builds nothing |
| `editorRootImports`, `editorRootTransImports` | a package, the set | For `lake query`: the generated root's direct and transitive imports, one module a line |
| `editorBase` | a package, the set | For `lake query`: the set's config base, one module a line: `Editor`, then the entry module of each package of the set outside the core |
| `editorShipped` | a package, the set | For `lake query`: what an app bundle ships of the set, built: one line `file<TAB><source><TAB><place>` a file (the core's `Editor` library, its interface library `FilesApi` and each other package's libraries but its tests, with their sources and every file Lake wrote; the lakefiles; the core's glue; the Rust archive), and one `oleans<TAB><place>` a `.olean` directory, for `tools/stage-bundle.sh` ([lean-runtime.md](lean-runtime.md), "The app ships the toolchain") |
| `editorPackages` | a package, the set | For `lake query`: the set's packages a gate step runs over, one a line |
| `editorPackageImports` | a package, the set | For `lake query`: each direct import of a core module by a module of those packages, one a line, with the module's kind (`library`, `test`, `linked`, `linked-test`); what the package imports check reads |
| `editorLayerImports` | a package, the set | For `lake query`: each direct import of a workspace module by a module of the core or of those packages, one a line, with the layer of the importing and the imported package (`core`, `interface`, `implementation`); what the layer imports check reads |
| `editorPackageGraph` | a package, the set | For `lake query`: the same packages as `editorPackages`, one a line, with each one's layer, directory and the packages of the set it requires; what the pre-commit hook decides over (`tools/hook-targets.sh`) |
| `editorRustCrates` | a package, the set | For `lake query`: the set's package crates, one a line ("Rust in a package", below) |
| `editorRustCrate` | a package, the set | For `lake query`: writes the crate generated from the set's package crates and prints its directory; builds nothing |
| `editorRust` | a package, the set | The set's one Rust archive: the generated crate, built, or the core's (`rustlib`) for a set with no package crate |

`linkAsEditor` is the one link: a root module's object and those of every
module it imports, with their symbols exported (`-rdynamic`), the glue of
every package library among them, then the core's glue and the set's one
Rust archive (`editorRust`), then the link arguments and the system
libraries that archive needs. `editor` and `editorLinked` both call it, the
latter for the set of the module's package, and the core's test
executables are `lean_exe`s configured to the same line. The editor built this way has the same size, minimum
macOS and link line as the `lean_exe` it replaced, but for its root's
object.

### A package's entry module

**The convention: a Lake package named `p` lists its packages in the
module `<P>.EditorPackage`, where `<P>` is `p` in upper camel case**, the
name `lake new` gives the package's library (`Lake.toUpperCamelCase`):
`shipped-themes` gives `ShippedThemes.EditorPackage`. The core's Lake
package, `editor-core`, has no such module ("The core has no entry
module", at the end of this section).

```lean
import Greeting

namespace Greeting.EditorPackage

/-- The packages of the Lake package `greeting`, in the order a host
registers them. -/
def packages : Array Editor.Package :=
  #[Greeting.package]

end Greeting.EditorPackage
```

- **The module declares `packages : Array Editor.Package`** in the
  namespace of its own name. A Lake package may hold several `Package`
  values, which register in the order the array lists them;
  `version-control`'s holds two (`version-control` and
  `version-control-gutter`), and each other default package's one. An interface package has no
  entry module and contributes no `Package`.
- **A package that supplies the editor's input scheme also declares
  `scheme : Editor.SchemePackage`** there, and its lakefile declares the
  keyword `editor-input-scheme` (`keywords = ["editor-input-scheme"]`),
  which is how the build knows to hand the declaration to the hosts. Lake
  is asked for the keyword, as for `editor-interface`, so the build reads
  no source; a keyword with no `scheme` fails the generated root's build,
  naming `<P>.EditorPackage.scheme`. The default package `evil` is the one
  that does ("Input schemes", below):

  ```lean
  def scheme : Editor.SchemePackage :=
    Editor.Evil.scheme
  ```
- **A Lake package with no such module contributes nothing.** The build
  asks Lake whether a library of the package holds a module of that name
  (`Package.findModule?`) and whether its source file exists. It reads no
  source text. The default set itself, which has no library, is such a
  package.
- **A module of that name with no `packages` fails the build** of the
  generated root, with Lean's error naming `<P>.EditorPackage.packages`.
- **Why a fixed name and not an attribute collected at compile time.** The
  order of the `Package` values inside one Lake package is visible in
  fixtures ("Registration order is visible", below), and an attribute
  collected by import order cannot state it. A fixed name also keeps the
  generated root plain text, and keeps Lean's elaborator out of what a
  package must import.
- **Why `<P>.EditorPackage` and not a shared prefix
  (`EditorPackage.<P>`).** A library as `lake new` makes it holds
  `<P>.EditorPackage` with no configuration. A shared prefix needs an
  explicit root in every package, and a library that claimed the whole
  prefix would shadow the others'.
- **The core has no entry module** (the features-as-packages roadmap's
  phase 8, its plan's D9). Its Lake package is one "with no such module"
  and contributes nothing to a set's root, and the build writes `#[]` for
  a set with no entry module at all (`rootSource` in `lean/lakefile.lean`),
  so the build needs none for the core.
  - **The choice was between removing the module and keeping it with an
    empty list.** It was removed: an empty list that the generated root,
    six linked roots and the core's own tests imported and appended would
    read as if the core had packages, and it could not even name the type
    `Package` without importing a module every host reaches, which the
    host imports check forbids an entry module.
  - **What says so**: `lean/EditorCore/` is gone; the gate requires the
    empty set's root to import `Editor` and `Editor.Main` alone
    (`:editorRootImports`, in `ffi-test`); and
    `ModelTest.packageChecks` holds that a host handed no package starts
    from a registry that holds nothing.
  - **Session restore's registrations and the package-set commands are
    default packages too** (that plan's D1), though the phase named five
    features: the core's list held seven packages, `restore` and
    `package-set` having joined it after the roadmap was written, and
    "the core's Lake package registers no `Package`" reaches both. Only
    the registrations moved. The machinery stays the core's, as modules a
    package may import: the journal reconciler the loop runs, the restore
    and the restart (`Editor.Restore.*`, `Editor.Restart.*`), and the
    package set's data, edit and build (`Editor.PackageSet.*`). The hosts,
    the loop and the config session start that work by names the core
    declares, and each already treats "no such job registered" as an
    ordinary case, as the loop's reconcilers treat the files' and the
    gutter's jobs since phase 5. The other choices were to keep the two in
    a list the core registers, which changes the criterion, or to have the
    hosts install them outside any package list, a second mechanism that
    is a `Package` in all but type. What a set without either does is
    under "Dropping one of the seven leaves…", below.

### The order packages register in

The set's packages are visited from the set, **each after the packages it
`require`s**, and those in the order its lakefile declares them
(`setPackages` in `lean/lakefile.lean`). So:

- a package registers after every package it depends on;
- packages that do not depend on each other register in the order the
  set's lakefile names them;
- an interface package has no entry module and registers nothing, so a
  `require` of one reorders nothing.

So the default set registers its twenty-five in the order its lakefile
requires them. Each phase that moved features out of the core's own list
put them first in the set, in the order that list held them, because the
core's packages registered before every default package:

- **Phase 6** put its seven first (`files`, `buffers`, `workspace`,
  `project-search`, `working-set`, `shell`, `version-control` and
  `version-control-gutter`; its D5): their order among themselves and
  against the default packages is unchanged, and only the packages then
  still in the core's list registered before them.
- **Phase 7** put `evil`, then `themes`, before those seven (its D6):
  evil's package was the first of the core's list and the themes' its
  sixth, so requiring them first keeps their order against every default
  package and between them. The one change was against the seven packages
  then still in the core's list, which registered before them.
- **Phase 8** moved those seven, `ex`, `frame-commands`, `menu`,
  `window-commands`, `tab-commands`, `restore` and `package-set`, in the
  reverse of that order, each to the front of the set (its D2). The
  package that moved was each time the last still in the core's list, so
  after every one of its commits the order was what it was before it, and
  the phase changed no fixture line ("Registration order is visible",
  below).

Lake's own list of a workspace's packages is not in that order: it holds a
package reached only through another after the package that requires it,
so the build walks the `require`s itself. The fixture set shows it
("The fixture set", below).

### What a package keeps across a restart

A package's `setup` registers what it keeps across a restart, as config's
may, with two registrations of the setup port (session-restore phase 2;
[lean-runtime.md](lean-runtime.md), "Persistence across a restart"):

- **`store.keptAcrossRestart (keep := …)`** keeps a store across a
  restart: a declared store's cell, or a workspace, project or unscoped
  store of the table under that name. Use it for a store whose value means
  something in the next process, such as a history or review decisions;
  `keep` drops what does not, such as a buffer number. A store with no
  codec is never written and starts empty. A package registers before the
  restore, so its cells are met with its codec at once: kept, migrated by
  its `migrate`, or reset, said in `*restore*`. The shipped `shell` and
  `version-control` packages keep `shell-history` and `vc-review`.
- **`workJob name work (reported := true)`** marks a job a person waits on,
  such as a build, a search or a commit: one running when the process ends
  uncleanly is named as stopped by the next start's restore.
- **`workJob name work (restarted := true)`** marks a job its package
  starts again after a restart anyway, such as a watcher a reconciler arms
  for each buffer open: one running then is not said. Every job with
  neither flag, a save, a write or a read, is counted by the restore as
  stopped (`and M other jobs were running: the restart stopped them`).

### The generated root

`EditorSetRoot`, written to `<set>/.lake/build/root/EditorSetRoot.lean`,
and only when its text would change. For the default set it is:

```lean
import Editor
import Editor.Main
import Ex.EditorPackage
import FrameCommands.EditorPackage
import Menu.EditorPackage
import WindowCommands.EditorPackage
import TabCommands.EditorPackage
import Restore.EditorPackage
import PackageSet.EditorPackage
import Evil.EditorPackage
import Themes.EditorPackage
import Files.EditorPackage
import Buffers.EditorPackage
import Workspace.EditorPackage
import ProjectSearch.EditorPackage
import WorkingSet.EditorPackage
import Shell.EditorPackage
import VersionControl.EditorPackage
import Completion.EditorPackage
import ModeLine.EditorPackage
import Minibuffer.EditorPackage
import ShippedThemes.EditorPackage
import ExecuteCommand.EditorPackage
import BindingSearch.EditorPackage
import Compile.EditorPackage
import AtPoint.EditorPackage
import Languages.EditorPackage

def main (args : List String) : IO UInt32 :=
  Editor.Main.run (Ex.EditorPackage.packages ++ FrameCommands.EditorPackage.packages ++ Menu.EditorPackage.packages ++ WindowCommands.EditorPackage.packages ++ TabCommands.EditorPackage.packages ++ Restore.EditorPackage.packages ++ PackageSet.EditorPackage.packages ++ Evil.EditorPackage.packages ++ Themes.EditorPackage.packages ++ Files.EditorPackage.packages ++ Buffers.EditorPackage.packages ++ Workspace.EditorPackage.packages ++ ProjectSearch.EditorPackage.packages ++ WorkingSet.EditorPackage.packages ++ Shell.EditorPackage.packages ++ VersionControl.EditorPackage.packages ++ Completion.EditorPackage.packages ++ ModeLine.EditorPackage.packages ++ Minibuffer.EditorPackage.packages ++ ShippedThemes.EditorPackage.packages ++ ExecuteCommand.EditorPackage.packages ++ BindingSearch.EditorPackage.packages ++ Compile.EditorPackage.packages ++ AtPoint.EditorPackage.packages ++ Languages.EditorPackage.packages) #[Evil.EditorPackage.scheme] #[`Editor, `Evil.EditorPackage, `Themes.EditorPackage, `Files.EditorPackage, `Buffers.EditorPackage, `Workspace.EditorPackage, `ProjectSearch.EditorPackage, `WorkingSet.EditorPackage, `Shell.EditorPackage, `VersionControl.EditorPackage, `Completion.EditorPackage, `ModeLine.EditorPackage, `Minibuffer.EditorPackage, `ShippedThemes.EditorPackage, `ExecuteCommand.EditorPackage, `BindingSearch.EditorPackage, `Compile.EditorPackage, `AtPoint.EditorPackage, `Languages.EditorPackage] { setName := "default-set", pin := "leanprover/lean4:v4.35.0\n" } args
```

with a module doc and a doc string, since it is built with the core's Lean
options and a warning in it fails the build. It imports each entry module
of the set in order and appends their `packages` in that order; a set of
the core alone (`tests/empty-set`), which has no entry module, passes
`#[]` and the base `Editor` alone, and imports `Editor` and `Editor.Main`
and nothing else, which the gate requires of it. The array after the packages holds the `scheme`
of each entry module whose Lake package declares the keyword
`editor-input-scheme`, in that order: the input schemes the set supplies,
of which the editor runs the last ("Input schemes", below). The default
package `evil` declares it, so the default set's array holds
`Evil.EditorPackage.scheme`; the empty set's is `#[]`. The last value before the arguments is what the
build says of the editor for the files it generates in a config directory
("A config directory requires the core and the set", below): the set's Lake name and the
text of the core's `lean-toolchain`. The gate requires the default set's root to
import exactly these twenty-seven modules (`lake -d ../packages query
:editorRootImports`, in `ffi-test`), and its base to be the twenty-six named
(`:editorBase`). The interface packages have no entry module, so neither
names them; their modules come with their implementations' libraries.

#### The config base of a set

**An editor elaborates config on its set's base: `Editor`, then the entry
module of each package of the set outside the core, in the order they
register** (`setBase` in `lean/lakefile.lean`; the facet `editorBase`;
`lean/Editor/Main.lean`, "The base"). Decided in phase 6, when the compile
mode, which the base imported, left the core.

- **The root hands the hosts the base as names**, beside the packages, and
  imports every module of it, so each is linked into the executable: the
  elaborator imports the base's modules from their `.olean` files at
  runtime, and an imported module that is not linked would have its
  initialisers run beside the editor's threads
  ([lean-runtime.md](lean-runtime.md), "One shared state").
- **No new convention.** The entry module is the one module every package
  has, and it imports the package's library, so what config sees of a
  package is what its entry module imports. A package that wants config
  to see less puts less behind its entry module.
- **The core's own entry module is not in the base.** What config sees of
  the core is what `Editor` imports, as before, and does not change with
  the set.
- **A set without a package elaborates on less.** The editor of
  `tests/empty-set` has the base `Editor` alone: it loads config, and a
  config that names `Compile.cargoMode` is rejected there with `Unknown
  identifier`.
- **What left the core's base with the compile mode**: the four modules of
  it that `Editor` reached, and `Editor.Json`, the JSON reader, a core
  module `Editor` reached only through the shipped modes. The default
  editor's config still sees all five, through the compile package's
  entry module. Config on an editor without that package does not see
  `Editor.Json`; nothing else of the core left the base (computed from
  the import lines before and after the move).
- **Config can name a default package's declarations**, the palettes'
  among them (`ShippedThemes.themes`), which it could not before:
  a side effect of the rule, pinned by the fixture
  `packages/shipped-themes/tests/headless/package-names`.
- **Every host is told its base; none defaults to one.** `Headless.shipped`,
  `Headless.shippedOver` and `Window.host` take the base as a required
  argument, after the packages, so a caller that leaves it out does not
  build, and none falls back to `Editor` without a word. The editor's two
  `main`s hand on the set's. A package's linked test whose config names no
  declaration of a package writes `Editor` alone, and then needs only the
  core's `.olean` directory, which is what the package steps hand it.
- **Both hosts are shown to hand the base to the elaborator.** The
  headless mode by the packages' fixtures, whose configs name a package's
  declarations (`package-names` of `shipped-themes`, `config` of
  `compile`), run on the editor and from a staged bundle. The window mode
  by `ffi-test window-host-base`: the scripted window host, handed
  `Editor` and a module `Editor` does not import (`ConfigFixture`), loads
  a config that names that module's declaration
  (`tests/window/base/config`), which is rejected on `Editor` alone. What
  the gate does not run is the window mode's `main` itself, which opens
  the system's window; `mise run app-check` runs the shipped bundle's
  headless mode.
- **The base is where config starts, and it grows** (phase 7). A config
  file is a Lean module with real import lines
  ([lean-runtime.md](lean-runtime.md), "Config and reload"). It may import a
  module the set's base holds, and a module of `Init`, `Std` or `Lean`,
  which the base then grows to hold: every module of those three is linked
  into an executable that links the elaborator, by the elaborator adapter's
  own imports. An eager base of every linked module was measured and
  refused: 0.61 s and 1.40 GB resident for each headless start, against
  0.23 s and 0.60 GB. So what a set decides is still the base config starts
  on, and an import of a module of a package that is not in the set is
  refused, naming the module.

#### A config directory requires the core and the set

A config directory is a Lake package, so that Lean's language server,
started in it, checks a config file as the editor elaborates it. The editor
generates its `lakefile.toml` when there is none
(`lean/Editor/Config/LakePackage.lean`):

```toml
name = "config"

[[require]]
name = "default-set"
path = "/…/packages"

[[require]]
name = "editor-core"
path = "/…/lean"

[[lean_lib]]
name = "Config"
globs = ["Config.+"]
```

- **It requires the set, by path, then the running editor's own core at
  its root, by path, last, and nothing else** (packages phase 12). The set
  requires the core and each of its packages, so Lake resolves, for the
  language server, exactly the modules the editor links, from the build
  directories the editor's own build filled: nothing is fetched and
  nothing under the set is rebuilt. The core's require at the root, last,
  is what keeps it so for a package that names the core from git. Lake
  4.35 resolves a root's requires last first, a dependency's own manifest
  entries with it, and the first resolution of a name wins. So a root
  `editor-core` after every package wins over a package's git require of
  the core: that package builds against this editor's core and no core is
  cloned. One before the package loses to it, and so does a set that
  reaches the core only through another package: Lake clones the git core
  (measured 2026-11-20 with a `file://` stand-in: core first, the
  package's manifest entry won and the core was cloned; core last, the
  root's path entry, nothing cloned). The phase's probe had found the root
  winning whichever its place; that was not so once the package carried
  its own manifest.
  The core's directory is the one the editor links
  (`lean/Editor/ModuleLookup.lean`, "The core"): the checkout's `lean/`, or
  the app's `Contents/Resources/lean/lean`.
- **The build tells the editor what to write.** The generated root hands
  `Editor.Main.run` the set's Lake name and the pin, and the `editor` facet
  writes the set's directory beside the executable, in
  `<set>/.lake/build/bin/editor.set`, as it writes `editor.oleans`. In a
  bundle the directory is `Contents/Resources/lean/set`, where the app
  ships the default set (`lean/Editor/ModuleLookup.lean`, "The set"), so
  the app generates the lakefile too, naming that set (decided
  2026-11-19, deferred to phase 9; `bundle-test` and `app-check` check
  it). An editor that finds no set directory, or no core directory,
  generates `lean-toolchain` alone.
- **The lakefile is the user's once it is there.** The editor never
  rewrites it. When a config file imports a module that is not linked, the
  editor reads the lakefile's `[[require]]` names, with Lake's TOML loader
  and without running Lake (`lean/Editor/Config/Lakefile/Toml.lean`), and
  when the module belongs to a package named there, by the entry-module
  rule's casing (`greeting-loud` gives `GreetingLoud`), the diagnostic says
  the package set needs a rebuild. A `lakefile.lean` is not read.
- **What phase 8 builds on.** A user's own package set replaces the one
  `require` of the default set: the lakefile then names the user's set, or
  that set's own requires when a default package is dropped, and the
  rebuild the diagnostic asks for is the build of that set. The
  needs-a-rebuild diagnostic and its fixture
  (`tests/headless/needs-rebuild`, a config whose lakefile requires the
  fixture package `greeting`) are the half of that this phase built.
- **What phase 8 does with the launcher** (session-restore phase 3,
  `crates/editor-launch`). The per-user executable lives outside the
  bundle, so the bundle's launcher, `Contents/MacOS/leanmacs`, starts it:
  its cold-start rule (today the shipped `Contents/MacOS/editor`, or
  `--default`) gains "the newest per-user executable", with the previous one
  and then the shipped default as its fallbacks. The install ends with
  `Editor.restart (into := some <new executable>)`, which probes the new
  executable, writes the session and hands it over through the launcher, so
  the new build starts with the session as it was, keeps the app's
  identity (`CFProcessPath`), and falls back to the previous executable,
  then the shipped default, when it fails before restoring the session
  (`docs/design/lean-runtime.md`, "Restart, as built").

- **It imports the core's config base, `Editor`**, for the link alone, as
  every root that links the elaborator does ("The core and its root",
  above), and the rest of its base with the entry modules.
- **No library declares it.** The build makes a library value in the set's
  package whose source directory is that build directory, and a module in
  it, which is how Lake builds an executable's root. So the set's lakefile
  needs no stanza, the root's `.olean` and object are in the set's build
  directory, and `lake query +EditorSetRoot:…` does not find it: the two
  import facets answer for it.
- **A package's build output stays in its own directory.** The core's
  modules are built in `lean/.lake/build` whichever root asks, and
  building the core as the root, then through a set, then as the root
  again rebuilds nothing. So `lean/` and the sets are all roots of builds
  the gate runs.
- **And it records where the set is.** Beside `editor.oleans` the `editor`
  facet writes `editor.set`, the set's directory on one line, absolute
  ("A config directory requires the core and the set", above).
- **So the build records where the modules are, for the editor it links.**
  The set's build directory holds the editor and its root and no other
  module, so an editor run directly cannot find the modules config is
  elaborated on relative to itself. The `editor` facet writes
  `<set>/.lake/build/bin/editor.oleans`: the `.olean` directory of each
  Lake package of the set that holds a library, one a line, absolute, the
  core's first and each other package after the ones it requires. Outside
  a bundle the editor searches every one of them for the modules of its
  base ([lean-runtime.md](lean-runtime.md), "Start-up and shutdown";
  `lean/Editor/ModuleLookup.lean`): the base holds each package's entry
  module, whose `.olean` files are in that package's directory. Until
  phase 6 the base's modules were all the core's and the first directory
  alone was used. The gate starts the window mode's wiring for both sets'
  editors with that default and requires config to load (`ffi-test
  window-host-direct`), and checks each record: the default set's names
  forty-four directories, the core's, then those of its twenty-five
  default packages and eighteen interface packages in the order the build
  visits them, each interface package before the first package that
  requires it (`shell-api`'s, `ex-api`'s, `buffers-api`'s, `ex`',
  `frame-commands-api`'s, `frame-commands`', `evil-api`'s, `menu`'s,
  `window-commands-api`'s, `window-commands`', `tab-commands-api`'s,
  `tab-commands`', `restore`'s, `package-set`'s, `minibuffer-api`'s,
  `at-point-api`'s, `evil`'s, `themes-api`'s, `themes`', `files`',
  `buffers`', `compile-api`'s, `project-api`'s, `vc-api`'s, `workspace`'s,
  `project-search-api`'s, `project-search`'s, `working-set-api`'s,
  `working-set`'s, `shell`'s, `version-control`'s, `completion-api`'s,
  `completion`'s, `mode-line`'s, `minibuffer`'s, `shipped-themes`',
  `execute-command-api`'s, `execute-command`'s, `binding-search-api`'s,
  `binding-search`'s, `compile`'s, `at-point`'s and `languages`'), and the
  fixture set's forty-nine, the core's, `greeting-api`'s, `greeting`'s,
  `greeting-loud`'s, `echo`'s, the default set's forty-three in that order,
  and `word-count`'s, each holding its package's modules.
- **A directory given on the command line is a search path**, one
  directory or several joined with `:`, and outside a bundle the recorded
  directories are searched after the ones given (`ModuleLookup.resolve`).
  So every gate line that gives the core's directory alone (`editor
  headless <sysroot> lean/.lake/build/lib/lean …`, the package steps'
  fixtures) still finds a package's modules through the record, and an
  editor with no record, a staged or relinked one, is given every
  directory: the user-side link check gives its relinked editor two. In a
  bundle the directories are those the bundle's record names,
  `Contents/Resources/editor.oleans`, relative to `Contents/Resources`:
  the staged core's and each default package's own
  ([lean-runtime.md](lean-runtime.md), "The app ships the toolchain").
- **What "no hand-written list of packages" means.** No module names the
  Lake packages of a set: the set's lakefile is the one place, and the
  root is generated from it. Each Lake package's entry module still lists
  its own `Package` values, which is what the root reads. The core's lists
  17, and fewer as features move out.
- **No root is written by hand, the user-side link's included.** That
  check ([lean-runtime.md](lean-runtime.md), "A link on the user's
  machine, measured") links an editor against a staged core of prebuilt
  pieces, which carries no facet, with a linker that is not Lake's own
  here. Its fixture is a package of a set of its own, `tests/user-link`
  (the default set and the package `user-link`, whose entry module is
  `UserLink.EditorPackage`), and the check asks the checkout for that
  set's root alone: the facet `editorRoot` writes a set's root and prints
  its path, and links and builds nothing
  (`lake -d ../tests/user-link query :editorRoot`). The check stages that
  file as the relinked editor's root. So the one generator writes every
  root, and the gate shows that set's root generates and lists the
  package after the core (`ffi-test`). On a user's machine there is no
  checkout to ask, so the app ships the core built with its lakefile,
  which carries the facets (phase 9; [lean-runtime.md](lean-runtime.md),
  "The app ships the toolchain").

### A package's tests and the gate's steps over them

A package outside the core is tested, linted, formatted and run headless
by the same gate tasks as the core, through `tools/package-set.sh <step>
<set dir>`, which asks Lake for the set's packages
(`lake -d <set dir> query :editorPackages`) and runs one step over each
([the-gate.md](../dev-practices/the-gate.md), "The package steps").

**A package's tests, by convention:**

- **its Lake test driver** holds the tests that need no Rust library, as
  `model-test` is the core's;
- **the module `<P>Test.Linked`**, when the package has one, is the root of
  one executable linked as the editor is (`editorLinked`), for the tests
  that need the Rust library, as `ffi-test` and `config-test` are the
  core's. One executable, not two: the core's two differ in what they
  check, not in how they are linked, so a package's holds both kinds of
  check. It is handed the toolchain's directory and the core's `.olean`
  directory, which a config session on the real elaborator needs, and is
  run in the package's directory, so it can name a config directory of its
  own. The fixture package's shows both kinds: a command on the real text
  binding, and the headless host over the set's packages loading a config
  that binds a key to the package's command, which the key then runs
  ("The fixture set", below). The compile package's runs a compile over
  the real process service and in a headless host ("The default package
  `compile`", below);
- **its headless fixtures** are the directories
  `<package>/tests/headless/<name>/`, each a `config/`, a `script` and an
  `expected`, run on the editor built from the set.

| Step | Per package | In task |
|---|---|---|
| `test` | `lake -d <package> test --wfail`; a package with no test driver fails the step | `lean-test`, with the `cargo` that fails first on the `PATH` |
| `build` | Once, the set's `editor`; then `lake -d <package> build --wfail`, the package's default targets under its own linter options; and its linked test's executable | `lean` |
| `fmt` (`format` rewrites) | `lean-fmt format --check` and `lean-fmt check`, with `--root <package>`, from the formatter's host | `lean-fmt` (`lean-format`) |
| `run` | The linked test, in the package's directory; then each headless fixture on the set's `editor`, compared with its `expected`. It prints what it ran, and the gate requires the fixture packages' and the default packages' linked tests and fixtures among it | `ffi-test`, over the fixture set and over the default set |

- **The packages a step runs over** are those of the set that are path
  dependencies and hold a Lean library, other than the core, which the
  gate's own tasks cover. A step exits 2 when there is none, so it cannot
  pass by running over nothing, and `lean-test` shows that on a set kept
  for it, `tests/empty-set`, which requires the core alone.
- **The gate gives the steps the fixture set**, which requires the default
  set. So the default packages are tested, built, formatted and run through
  it, and `lean-test` requires the line the `test` step prints as it
  reaches each of them, the twenty-five default packages and the eighteen
  interface packages. The default set's own
  `editor` is built beside it, for the standing fixtures under
  `tests/headless/`, and **`run` is also given the default set**, so the
  default packages' linked tests and fixtures hold of the editor that is
  shipped, not only of the fixture set's.
- **A package's linked-only test modules are under `<P>Test/Linked/`**,
  each mirroring the module it tests
  (`ShippedThemesTest/Linked/ShippedThemes.lean`), and `<P>Test/Linked.lean`
  imports them and runs them. A package has one test namespace where
  the core has four test roots, so its model tests keep `<P>Test/<path>`,
  which the test driver's root imports, and the ones that link the Rust
  library need a place the driver does not import. **The root makes the
  context of a check that starts a host**, `<P>Test/Linked.lean`: only
  that module may import the headless host's entry points, the config base
  and the core's entry module ("What a package may import", below), so it
  makes the context of a harness of hosts (`HostContext.run`) and hands it
  to the checks. A module under `<P>Test/Linked/` holds checks that start
  a host on the core's linked test kit, a stage over that context
  (`Editor.Test.Linked.Host`), which it may import, as
  `FilesTest.Linked.fileChecks` and `CompileTest.compileHostChecks` do.
  `GreetingTest.Linked` holds its one check in the root.
- **A package's headless fixtures are excluded from the formatter** by a
  `lean-fmt.toml` in the package (`exclude = ["tests/**"]`): a config file
  is a module of a config directory, another Lake package, which the editor
  elaborates at runtime, and is not built with this package.
- **A library's `globs` must hold every module of the package's library**
  when its root does not import them all. A Lake library declared by its
  name alone holds only what its root module imports, so a module beside
  it that the root does not import, the entry module or the module that
  defines the `Package` value, is no module of the library: it still
  builds, since the generated root imports it, but the facet that lists a
  package's imports asks the library for its modules and would not see it.
  `compile` declares `globs = ["Compile.*"]` for that, and with it the
  facet lists every module's imports; `execute-command`,
  `binding-search`, `at-point` and `minibuffer` do the same
  (`["AtPoint.*"]`, `["Minibuffer.*"]`), and `mode-line`, `languages` and
  `completion`, whose library has no root module, declare
  `globs = ["ModeLine.+"]`, `["Languages.+"]` and `["Completion.+"]` (`.*`
  would ask for a root module that is not there). `shipped-themes` declares its
  library by name alone: its root imports the palettes, and the one module
  the root does not import, the entry module, imports no core module, so
  no line is missed there. The facet could list the entry module whatever
  the globs say; that is filed as the task
  `package-imports-facet-entry-module`.
- **The fixture packages' tests pass the package imports check** ("What
  a package may import", below). Their model tests read what a package
  registers through `Config.State.ofPackages` (`Editor.Config.Packages`,
  a test double), and the linked test runs a command on the real text
  binding (`Editor.Text.Real`), starts the headless host
  (`Editor.Headless`), links the config base and names the core's entry
  module for the set's packages, each of which the root of a linked test
  may import and no other module of a package may.

### The first default package: `shipped-themes`

`packages/shipped-themes/` is the Lake package `shipped-themes`: Solarized
(dark and light) and Fairy Floss, which were modules of the core until
the packages roadmap's phase 5. The default set requires it, so every
editor built from the default set, or from a set that requires the default
set, holds its three themes.

| Path | What |
|---|---|
| `README.md` | What the package gives, and a walk through its source and tests in reading order, for a package author |
| `lakefile.toml` | The package: it requires the core by path, declares the library `ShippedThemes`, the test library `ShippedThemesTest` and the test driver `shipped-themes-test`, and turns every linter on, as a fixture package does |
| `ShippedThemes.lean` | The library's root: `ShippedThemes.themes` and the `Package` value `ShippedThemes.package`, still named `shipped-themes`, whose `setup` defines the three themes and nothing else |
| `ShippedThemes/Solarized.lean`, `ShippedThemes/FairyFloss.lean` | The palettes, each with its licence notice beside it (`Solarized-LICENSE.txt`, `FairyFloss-LICENSE.txt`) |
| `ShippedThemes/EditorPackage.lean` | The entry module: `packages := #[ShippedThemes.package]` |
| `ShippedThemesTest/Model.lean` | The test driver's root, which runs `ShippedThemesTest.shippedThemesChecks`, `.solarizedChecks` and `.fairyFlossChecks`, in the test modules that mirror the three library modules |
| `ShippedThemesTest/Linked.lean` | The linked test's root, which runs `ShippedThemesTest/Linked/ShippedThemes.lean`: each theme's picture against its reference image |
| `tests/headless/themes`, `shipped-themes`, `load-theme`, `package-names` | Its headless fixtures; the last, added in phase 6, loads a config that names the package's declaration `ShippedThemes.themes` |
| `tests/render/` | The three reference images, with the text they show, the one font they are laid out in and that font's licence |

- **It imports the core's API alone**: `Editor.Face` and `Editor.Package`.
  Its model tests also import `Editor.Appearance`, `Editor.Scene`,
  `Editor.TabBar` and `Editor.Theme.Check`, which are API, and the test
  double `Editor.Config.Packages`; its linked test module imports the test
  double `Editor.Theme.Picture`. The package imports check holds that
  ("What a package may import", below).
- **Its declarations are in the namespace `ShippedThemes`**
  (`ShippedThemes.themes`, `ShippedThemes.Solarized.dark`), where they
  were `Editor.Themes.Shipped.…` in the core. No config could name a
  palette's declaration before the move, since the config base never
  imported one, so nothing depended on the old names. Config names a theme
  by its name (`useTheme "solarized-light"`, `load-theme`), which did not
  change.
- **Its own tests run the core's completeness check on each theme**
  (`Themes.problems`, in `ShippedThemesTest.shippedThemesChecks`), as the
  core runs it on the theme `default`, and **the core's theme picture
  check on each theme** (`Themes.Picture.themePicturesScenario`, from the
  linked test), as the core runs it on `default`. The picture check draws
  through the raw bindings, which no package may import, so it is a test
  double of the core that takes the themes as an argument.
- **It carries its own copies of what its tests read**: the picture's
  text, a byte-for-byte copy of the core's `tests/render/themes/source.lean`,
  so the three reference images are the bytes they were; and the fixture
  font with its licence. A linked test runs in its package's directory,
  and a package that read `../../tests/fonts` could not be fetched from
  anywhere else later.
- **The fixture `load-theme` pins what the default editor offers.** On a
  config that defines no theme, the theme prompt's candidates are
  `default`, `solarized-dark`, `solarized-light` and `fairy-floss`, in
  that order, as before the move. The gate runs it on the default set's
  editor and on the fixture set's.
- **Dropping the package leaves the core's themes.** The set
  `tests/empty-set` is the default set with its packages dropped: it
  requires the core alone. `mise run lean` links an editor from it, and
  until the features-as-packages roadmap's phase 7, when that editor lost
  its input scheme with evil and the fixture was retired ("Dropping evil
  or themes leaves…", below),
  `ffi-test` ran the core's fixture `tests/headless/core-themes` on that
  editor: it started in the theme `default`, and `load-theme` offered
  `default` and the theme config defines and no palette. Until the
  minibuffer moved out (features-as-packages phase 4) a palette's name
  was answered there with `load-theme: no theme is registered as …`; that
  editor now has no command to accept a prompt with, so the fixture no
  longer reaches the answer ("The minibuffer", under "The default
  packages of the features-as-packages roadmap's phase 4", below), and
  that the core's list registers the one theme `default` was held by
  `ConfigTest.shippedChecks` and `ModelTest.packageSetChecks` (both checks
  went with the core's list in phase 8, when the theme became the themes
  package's own to pin, `ThemesTest.themeChecks`).
- **The app bundle carries its module files since phase 6.** Config names
  a theme by its name, and the themes are in the executable, so the bundle
  needed nothing of this package while the config base was the core's
  alone. The base is the set's now, and holds this package's entry module,
  so the bundle ships its modules, in this package's own build directory
  staged under `Contents/Resources/lean/set` (phase 9). `bundle-test` runs the
  package's `shipped-themes` and `package-names` fixtures from a staged
  bundle with an empty environment.

### The default package `compile`

`packages/compile/` is the Lake package `compile`: the compile mode,
`compile` into a workspace's compilation buffer, with the modes that ship
for cargo, lake and mise ([keymaps-and-modes.md](keymaps-and-modes.md),
"The compile mode, as built"). Its five modules were modules of the core,
`Editor.Compile` and the four under it, until the packages roadmap's
phase 6. The default set requires it after `binding-search` (after
`shipped-themes` until phase 3 of the features-as-packages roadmap), so every
editor built from the default set, or from a set that requires the default
set, holds it. It is the first package with behaviour: commands, a job
over the process service, a major mode, ex names and contributions.

| Path | What |
|---|---|
| `README.md` | What the package gives, and a walk through its source and tests in reading order, for a package author |
| `lakefile.toml` | The package: it requires the core by path and, since the minibuffer moved out (features-as-packages phase 4), the interface package `minibuffer-api`, whose names and fake its tests use; declares the library `Compile` with `globs = ["Compile.*"]`, the test library `CompileTest` and the test driver `compile-test`, and turns every linter on |
| `Compile.lean` | The commands and the run: `compile`, `compile-command`, `recompile`, `kill-compilation`, the output's commands, the locations and the steps over them, the mode `compilation` (from `lean/Editor/Compile.lean`) |
| `Compile/Errors.lean`, `Compile/Contribution.lean`, `Compile/Shipped.lean` | The matcher and the sites it yields; the offers and the formats in use; `cargo-mode`, `lake-mode` and `mise-mode` with rustc's and Lean's formats |
| `Compile/Compiled.lean` | The `Package` value `Editor.Compile.package`, still named `compile`: nine commands, the job `compile-run`, the mode, the three contributions and six ex names |
| `Compile/EditorPackage.lean` | The entry module: `packages := #[Editor.Compile.package]`. It imports `Compile.Compiled`, and so the whole library, which is what config sees of the package |
| `CompileTest/Model.lean` | The test driver's root, which runs the ten model lists, 98 checks, in the test modules that mirror the library's (`CompileTest/Compile.lean`, `CompileTest/Compile/…`), over the support in `CompileTest/Support/Compile.lean` |
| `CompileTest/Linked.lean` | The linked test's root: it makes the hosts' context (`HostContext.run`) and starts the real services, and runs `compileHostChecks`, a compile through a host on a stepped stage, the compile over the real process service (`CompileTest/Linked/Compile.lean`) and the shipped modes on a stepped rig (`CompileTest/Linked/Compile/Shipped.lean`); 8 checks |
| `tests/headless/ex-names`, `config`, `shipped-formats` | Its headless fixtures |
| `tests/compile/` | The fixtures of the linked checks: `three-lines`, which the compile over the real process service runs; the canned output of cargo, lake and mise, which the shipped modes' process fake answers; and the trees the shipped modes are checked in, read into the rig's file fake |

- **Its library imports the core's API alone**, eleven modules, with no
  addition to the API: `Editor.Api`, `Editor.Command.Call`, `Editor.File`,
  `Editor.Json`, `Editor.Mode`, `Editor.Package`, `CompileApi`,
  `CompileApi.Format`, `CompileApi.Listing`,
  `Editor.Shell` and `Editor.Workspace.Modes`, the same eleven recorded
  before the move. The package imports check holds that, over a library
  whose globs hold every module ("What a package may import", below).
- **Two of those are features' modules still in the core**: the shell
  (`Editor.Shell`) and the workspace's modes (`Editor.Workspace.Modes`).
  Both edges stay. When either feature moves into a package, this package
  requires that package.
- **Module names changed; no declaration did.** `Editor.Compile.Errors`
  is the module `Compile.Errors`, and every declaration is still in the
  namespace `Editor.Compile` (`Editor.Compile.compileName`,
  `Editor.Compile.cargoMode`, `Editor.Compile.package`). Config names them
  under `open Editor` (`Compile.cargoMode`), the core's vocabulary for the
  compile mode is in that namespace already (`Compile.Contribution`,
  `Compile.Format`), and about 4,700 lines of code and model tests changed
  no name. The modules are not named `Editor.…`, so the core imports
  check needs no name for them, as for the palettes.
- **What stayed in the core**, each because it is the core's own data or a
  core module uses it: the `compilation.*` faces
  (`lean/Editor/Face/Vocabulary.lean`, `lean/Editor/Face.lean`); the
  contribution vocabulary and the format data
  (`packages/compile-api/CompileApi.lean`, `packages/compile-api/CompileApi/Format.lean`);
  the listing, its store `compile-listings` and its job `compile-list`,
  which the `workspace` package registers
  (`packages/compile-api/CompileApi/Listing.lean`); `compileContribution` and
  `projectCommands` of the setup port; and the registry's hook with the
  loop being told the contributions ("The interfaces the core owns",
  below). No core module names a compile command: the default config, the
  Vim tables and the menu name none.
- **It registers after every package of the core's**, by dependency, as a
  user's package would, and not in the place it had in the core's list.
  Five lines of three standing fixtures changed for it ("Registration
  order is visible", below).
- **Its model tests are the ones it had in the core.** The ten lists moved
  with their sentences and assertions as they were, under the names
  `CompileTest.compileChecks`, `.compileErrorChecks`,
  `.compileLocationChecks`, `.compileHookChecks`, `.compileOfferChecks`,
  `.compileListedChecks`, `.compilePackageChecks`, `.projectFormatChecks`,
  `.projectModeChecks` and `.miseTaskChecks` (each was `ModelTest.<name>`).
  They run on the core's test kit ("What moving the compile mode added to
  the core's API", below). Three checks were added to them before the
  move, while they were still the core's, for what two config tests held:
  two in `compileHookChecks`, of a shipped contribution with one field
  overridden and of a contribution with a format of its own, on a `setup`
  written as compiled code (they were `ConfigTest.compileConfigChecks`, on
  a real config, which is the fixture `config` now); and one in
  `compilePackageChecks`, of what the package registers on its own (which
  `ConfigTest.shippedChecks` held of the core's list). So the driver
  prints `compile-test: 98 checks passed`, 95 and those three.
- **Its linked test runs what `contract-test` ran, and a host.**
  `CompileTest.compileRunChecks` was `ContractTest.compileChecks` and
  `CompileTest.projectRunChecks` was `ContractTest.projectModeChecks`: the
  model lists have the old names, and both are in one namespace now. They
  run on the core's linked test kit, with the compile mode's keys and jobs
  passed to the rig, which names no feature outside the core; the shipped
  modes' list runs on a stepped rig (`ProjectRig.stepped`), its children
  and files the rig's fakes. `compileHostChecks`
  (`CompileTest/Linked/Compile.lean`), over the root's `HostContext`, is a
  compile through a host on a stepped stage, handed the core's packages,
  the core's test kit's stand-in for the mode line and this one's: a child,
  the stage's process fake, writes one error line and keeps running, the
  check steps to its location, kills it and recompiles, and the visit of
  `next-error` is asked of the scene with its load held, and again once
  the load has ended. It was the script `tests/linked/run/script` until
  host-tests-on-fakes phase 4 (task `compile-linked-next-error-settle-race`).
  It prints `compile linked test: 8 checks passed`.
- **One table of waits a process.** The library has one completion queue,
  and a pump ends the waits of the one table it is given, so the host,
  which makes a table and starts the pump, is started first, and the
  services the other checks run over are made over the host's table
  (`Editor.Test.Linked.Services.over`).
- **Its fixtures were written before the move** and moved byte for byte,
  so that what they print is what the editor printed with the compile
  mode in the core: `ex-names` (each of `:next-error`, `:previous-error`,
  `:recompile`, `:kill-compilation`, `:compile` and `:compile-command`,
  typed in an editor that has compiled nothing, reaches its command) and
  `config` (a config that overrides a field of `Compile.cargoMode`,
  builds a `Compile.Format` and reads a line with it, and names
  `Compile.shipped`, elaborates and its command runs); and the host
  check's script and list, which a gate line ran on the default editor in
  a temporary directory before the move. `git log --follow` on each shows
  the one commit that wrote it and the rename.
- **The shipped formats are shown reading output by a third fixture,
  `shipped-formats`**, written after the move, in the phase's rework: the
  first two show each ex name reaching its command and config elaborating
  on the package's declarations, and neither shows `cargo-mode`'s,
  `lake-mode`'s or `mise-mode`'s reading. Its config hands canned output,
  as each tool prints it, to the compile mode's own reader (`Compile.scan`
  with `Compile.formatsOf Compile.shipped`), with no process, and says the
  locations found: rustc's format reads cargo's `src/main.rs:4:18` with the
  severity and message of its lead line; Lean's reads lake's
  `./Foo/Bar.lean:12:4`; `mise-mode`, which has no format, reads nothing of
  rustc's output alone and cargo-mode's format reads it with both on; and
  `Compile.miseTasks` turns a task list into `mise run <task>` commands.
  Every path in it is relative. **Its baseline is a build of the commit
  before the move**: the editor built at `c90a8d7f`, with the compile mode
  in the core, in a clone made for the comparison, printed for this
  fixture the bytes of its `expected` (1,795 bytes, compared with `cmp`),
  and for `ex-names` and `config` the bytes of theirs. The editor built
  from `tests/empty-set` rejects its config, with `Unknown identifier
  Compile.formatsOf`.
- **A whole run cannot be a static fixture**: the compilation buffer's
  first line and the echo of a visit hold the working directory's whole
  path. `ex-names` holds only its last name, `lean`, where the gate runs
  the editor.
- **It carried its own copy of the git fixture** (`tests/compile/bin/git`,
  a byte-for-byte copy of the core's `tests/workspaces/git`): a linked
  test runs in its package's directory, and a package that read
  `../../tests/workspaces` could not be fetched from anywhere else later.
  Since features-as-packages phase 6 its linked checks of the shipped
  modes give a file's workspace and its modes on markers by the core
  kit's stand-ins (`Editor.Test.attachByPackage`,
  `Editor.Test.markersByPackage`), so no git is run and the copy is gone.
- **Dropping the package leaves an editor that starts.** Until the
  features-as-packages roadmap's phase 7, when the empty set's editor lost
  its input scheme with evil and its fixtures were retired ("Dropping evil
  or themes leaves…", below), the editor of
  `tests/empty-set` loaded config and opened its ex line
  (`tests/headless/core-ex-names`, in `ffi-test`). Until the minibuffer
  moved out (features-as-packages phase 4) it answered `:compile` with
  `compile: not an ex command`, the words it has for `:bogus`; it now has
  no command to accept the line with, so the line is never run ("The
  minibuffer", under "The default packages of the features-as-packages
  roadmap's phase 4", below), and that `compile` is bound as no ex name
  there was held by `ConfigTest.shippedChecks` until the core's list
  emptied ("The empty registry's checks", below). The listing job stays
  registered there and lists a contribution's commands, which nothing
  then reads.
- **The app bundle carries its modules**, built, in this package's own
  build directory under `Contents/Resources/lean/set`, and `bundle-test`
  runs the fixture `config` from
  a staged bundle with an empty environment.

### The default packages of the features-as-packages roadmap's phase 3

Four features moved out of the core in that phase, each into a default
package of its own, because their libraries imported no other feature and
only the core's root, the config base and the core's entry module imported
them (checked on `:editorLayerImports` before the move). Each keeps its
declarations' names: modules drop the `Editor.` prefix, and every
declaration stays in its namespace (`Editor.ModeLine.package` in module
`ModeLine.Compiled`), as the compile mode's did, so config and tests under
`open Editor` changed import lines only. Each lakefile is shaped as
`compile`'s: the core by path, a library whose `globs` hold every module,
a test library, a test driver, every linter on. The minibuffer, planned
for the same phase, stayed in the core then, and moved in phase 4 ("The
default packages of the features-as-packages roadmap's phase 4", below).

| Package | Library (from) | Entry module | Test driver | Fixtures |
|---|---|---|---|---|
| `mode-line` (`packages/mode-line/`) | `ModeLine.Compiled` (`lean/Editor/ModeLine/Compiled.lean`) | `ModeLine.EditorPackage` | `mode-line-test`: `ModeLineTest.modeLinePackageChecks`, 1 check | `mode-line`, the core's until the move, byte for byte |
| `execute-command` (`packages/execute-command/`) | `ExecuteCommand`, `ExecuteCommand.Compiled` (`lean/Editor/ExecuteCommand.lean` and `…/Compiled.lean`) | `ExecuteCommand.EditorPackage` | `execute-command-test`: `ExecuteCommandTest.executeCommandChecks` and `.executeCommandPackageChecks`, 16 checks | `command-prompt`, written before the move |
| `binding-search` (`packages/binding-search/`) | `BindingSearch`, `BindingSearch.Compiled` (`lean/Editor/BindingSearch.lean` and `…/Compiled.lean`) | `BindingSearch.EditorPackage` | `binding-search-test`: `BindingSearchTest.bindingSearchChecks` and `.bindingSearchPackageChecks`, 13 checks | `binding-search`, written before the move |
| `languages` (`packages/languages/`) | `Languages.Compiled` (`lean/Editor/Language/Compiled.lean`) | `Languages.EditorPackage` | `languages-test`: `LanguagesTest.languagePackageChecks`, 1 check | none: the core's `open-file`, on the default set's editor, opens files in `code` |

- **What each library imports of the core** (`lake -d ../packages query
  :editorPackageImports`), API alone, with no addition to the API:
  `mode-line`'s `Editor.ModeLine` and `Editor.Package`; `languages`'
  `Editor.Language` and `Editor.Package`; `execute-command`'s and
  `binding-search`'s `Editor.Api`, `Editor.Command.Call` and
  `Editor.Package`, and each its own interface package's library
  (`ExecuteCommandApi`, `BindingSearchApi`), which the layer imports check
  allows: an implementation may import an interface.
- **Their data stays in the core.** The mode line's segments and its
  default listing (`ModeLine.shipped`, `ModeLine.Order.standard`,
  `lean/Editor/ModeLine.lean`) and the `code` mode and the languages
  (`Language.modes`, `Language.shipped`, `lean/Editor/Language.lean`) are
  read by the core's loop, its picture and its tests. Only the
  registration, the `….Compiled` module, moved. `mode-line` and
  `languages` reach and are reached only through names the core declares,
  so they need no interface package.
- **Their tests moved under their kept names** (each was
  `ModelTest.<name>`), with their sentences and assertions as they were.
  Each test module dropped its imports of internal modules (the loop, its
  dispatch, the registry, the minibuffer's and the themes' `….Compiled`):
  the names reach the tests through the kit's modules, and `load-theme`,
  which the command prompt's tests run, is registered from the API
  (`Themes.loadName`, `Themes.loadThemeCommand`). Before the moves the
  core's own tests stopped naming the four outside their mirrored modules:
  the source contract's runner moved into the kit
  (`Editor.Test.Sources`), and `ExecuteCommand.source` and
  `BindingSearch.source` are held to the contract by their own lists
  (`Editor.Test.sourceHolds`), under the sentences
  `sourceContractChecks` gave them; `ConfigTest.commandPromptChecks` was
  removed, its facts held by the fixtures `command-prompt` and
  `binding-search` and by a model check added to `executeCommandChecks`
  (a command config no longer registers is no candidate); and
  `ConfigTest.DefaultConfig` names the two commands the default config
  binds in default packages as text (`defaultPackageCommands`), its
  `SPC :` and `SPC ?` presses moved to the core's fixture
  `tests/headless/default-config` (below).
- **The core's tests keep what the default editor draws through two
  stand-ins** (`Editor.Test.Shipped`, "What moving the four features added
  to the core's API", below): `modeLine` and `languages`, which register
  the core's own data under the packages' names. A core test that hosts
  the core's list as the default editor appends them
  (`ConfigTest.shippedPackages`, `FfiTest.shippedPackages`), and since
  phase 4 the kit's minibuffer and at-point too ("What moving the
  completion, at-point and minibuffer features added to the core's API",
  below); one whose
  subject was the core's list (`ModelTest.packageSetChecks` and the checks
  of `ConfigTest.shippedChecks` over it, which all went with the core's
  list in phase 8) hosted the list alone, and stated that it held nothing
  of the four.
- **`tests/headless/default-config`** runs the default config, copied into
  a temporary directory, on the default set's editor: the binding search
  lists `SPC f f  open-file`, and `SPC :` and `SPC ?`, accepted from the
  search, which feeds a binding's keys to the scheme from rest, open the
  command prompt and the binding search. A script's `key` cannot press
  the space bar, so the keys are pressed that way.
- **Dropping `mode-line` leaves an editor that draws no shipped segment.**
  The editor of `tests/empty-set`, the core alone, registers none, so
  every status line of the main window in its fixtures is empty, `-`.
  Each line that changed for it when the package moved (phase 3, commit
  `feat(lean): move the mode-line package …`), from
  `status 0 in mode-line.active: mode-line.state.normal "NORMAL" +8,
  mode-line.buffer "scratch" +4 | mode-line.secondary "1:1" +4,
  mode-line.secondary "All" +4` to `status 0 in mode-line.active: -`,
  numbered as the files are since phase 4 added lines to both (they were
  lines 5, 9, 18 and 23, and 6 and 11):
  - `tests/headless/core-themes/expected`, lines 5, 9, 17 and 26;
  - `tests/headless/core-ex-names/expected`, lines 6 and 15.
  Version control's `review` is still registered there, and the default
  listing names it, but it draws nothing on a buffer with no review.
- **Dropping `languages`, `execute-command` or `binding-search`** changed
  no standing fixture: no fixture of the empty set's editor opens a file
  with a language or runs either command. That editor registers no `code`
  mode, no language, no command `execute-command` or `search-bindings`,
  and no source in the categories `command` or `binding`: it is handed
  no package, and a host handed none registers nothing
  (`ModelTest.packageChecks` and `ConfigTest.hostChecks`).
- **The compile mode's linked test appends the mode-line stand-in** to
  the packages its host is handed ("The default package `compile`",
  above), rather than requiring the package.

#### The interface packages `execute-command-api` and `binding-search-api`

The default config binds `SPC :` to `execute-command` and `SPC ?` to
`search-bindings` (`config/default/Config/Leader.lean`). Under "Reaches by
name" ([extension-points.md](extension-points.md)) a name another package
or the core reaches is declared in the interface package of the feature
that owns it, and every implementation runs that interface's contract
check. These are the first two feature interface packages, shaped as the
fixture `greeting-api` is.

| Package | Declares | Publishes for tests | Implemented by |
|---|---|---|---|
| `execute-command-api` (`packages/execute-command-api/`) | `ExecuteCommandApi.executeCommandName` = `"execute-command"`, `names` | `ExecuteCommandApiTest.fake`, `ExecuteCommandApiTest.contractChecks` | `execute-command`: `ExecuteCommand.name := ExecuteCommandApi.executeCommandName` |
| `binding-search-api` (`packages/binding-search-api/`) | `BindingSearchApi.searchBindingsName` = `"search-bindings"`, `names` | `BindingSearchApiTest.fake`, `BindingSearchApiTest.contractChecks` | `binding-search`: `BindingSearch.name := BindingSearchApi.searchBindingsName` |

- **Each declares `keywords = ["editor-interface"]`**, has no entry module,
  registers nothing, and its library imports nothing. Its test library
  imports `Editor.Api`, `Editor.Package` and the test double
  `Editor.Config.Packages`. It is in the default set through its
  implementation's `require`, so the package steps, the import checks and
  the pre-commit hook reach it (`tests/hook-targets/fixture-set-graph`
  pins each with the layer `interface`, and its implementation requiring
  it).
- **The contract check is `contractChecks (package : Package) : List
  (String × Bool)`**, one sentence for each declared name, over
  `Package.registered`: the shape `greeting-api` gives its own, so an
  interface package needs nothing of an implementation's test driver. Its
  own driver holds the fake to the contract and shows it refusing a
  package that lacks the name or misspells it (4 checks each). It has no
  `Check.lean`, as `greeting-api` has none.
- **Each implementation runs its interface's check** in a test module
  that mirrors its `Package` value (`ExecuteCommandTest/ExecuteCommand/Compiled.lean`,
  `BindingSearchTest/BindingSearch/Compiled.lean`), each pair mapped to one
  of its driver's checks (`{ name, run := pure held }`), so the driver's
  `N checks passed` counts them. The implementation registers under the
  interface's constant, so a rename on either side is a build error or a
  contract failure.
- **The default config, still in the core, names the names as text** until
  it moves out (phase 8): the core cannot import a package. Its test,
  `ConfigTest.DefaultConfig`, names them as text too
  (`defaultPackageCommands`).

### The default packages of the features-as-packages roadmap's phase 4

Three features moved out of the core in that phase, each into a default
package of its own with an interface package beside it: the completion
styles and displays that ship, completion at point, and the minibuffer's
commands and mode (the minibuffer was planned for phase 3 and moved here,
the task `minibuffer-as-package`, which is done when the phase lands).
Before the moves the core's edges into the three were cut, so that each
move cut none (checked on `:editorLayerImports`; criterion 1 of the phase:
`lake -d ../packages query :editorLayerImports | awk -F'\t' '$1 ==
"editor-core" && $4 != "editor-core"'` prints nothing):

- the core reads the styles and displays a set registers, and has its own
  for a set that registers none ("What moving the completion, at-point
  and minibuffer features added to the core's API", below);
- the loop asks for completion at point through command names the core
  declares (`Completion.AtPoint.triggeredCommand`, `.pausedCommand`), so
  it imports no at-point module;
- the core's tests answer prompts and complete at point through the kit's
  own hand-written minibuffer and at-point (`Editor.Test.Minibuffer`,
  `Editor.Test.AtPoint`), written over the core's API.

Each package keeps its declarations' names: modules drop the `Editor.`
prefix, and every declaration stays in its namespace
(`Editor.Completion.Styles.fuzzy` in module `Completion.Styles`,
`Editor.Minibuffer.package` in `Minibuffer.Compiled`), so config and tests
under `open Editor` changed import lines only. `Editor.Completion.Words`
became `AtPoint.Words`, under its own library's glob, so that no module
name is shared with `completion`. Each lakefile is shaped as `compile`'s,
and each implementation requires its interface package.

| Package | Library (from) | Entry module | Test driver | Fixtures |
|---|---|---|---|---|
| `completion` (`packages/completion/`) | `Completion.Styles`, `Completion.Displays`, `Completion.Compiled` (`lean/Editor/Completion/Styles.lean`, `…/Displays.lean`, `…/Compiled.lean`) | `Completion.EditorPackage` | `completion-test`: `CompletionTest.shippedStyleChecks`, `.minibufferDisplayChecks` and `.completionPackageChecks`, 19 checks; linked `CompletionTest.Linked`: `CompletionTest.shippedStyleFailures`, `completion linked test: 6 checks passed` | `completion-choices`, written before the move |
| `at-point` (`packages/at-point/`) | `AtPoint`, `AtPoint.Words`, `AtPoint.Compiled` (`lean/Editor/AtPoint.lean`, `lean/Editor/Completion/Words.lean`, `lean/Editor/AtPoint/Compiled.lean`) | `AtPoint.EditorPackage` | `at-point-test`: `AtPointTest.atPointChecks`, `.wordsChecks` and `.atPointPackageChecks`, 29 checks | `at-point`, the core's until the move, and `at-point-tuned`, written before it |
| `minibuffer` (`packages/minibuffer/`) | `Minibuffer`, `Minibuffer.Compiled` (`lean/Editor/Minibuffer.lean`, `…/Compiled.lean`) | `Minibuffer.EditorPackage` | `minibuffer-test`: `MinibufferTest.promptModeChecks` and `.minibufferPackageChecks`, 23 checks | `prompt` and `candidates`, the core's until the move |

- **What each registers.** `completion`: the styles `fuzzy`, `orderless`
  and `path` and the display `minibuffer` (`Styles.shipped`,
  `Displays.shipped`). `at-point`: the nine commands `at-point-complete`,
  `-next`, `-previous`, `-tab`, `-backtab`, `-return`, `-quit`,
  `-triggered` and `-paused`, the job `words` and the source `words`,
  with its at-point source. `minibuffer`: the nine commands
  `minibuffer-accept`, `-cancel`, `-next`, `-previous`, `-insert`,
  `-delete-backward`, `-delete-to-start`, `-ask` and `-candidates`, and
  the mode `minibuffer`, which the core makes the minibuffer's buffer with
  (`Prompt.mode`).
- **What each library imports of the core** (`lake -d ../packages query
  :editorPackageImports`), API alone: `completion`'s
  `Editor.Completion.Display`, `Editor.Completion.Style`, `Editor.Package`
  and `Editor.TypedPath`; `at-point`'s `Editor.Api`,
  `Editor.Completion.AtPoint`, `Editor.Completion.Later` and
  `Editor.Package`; `minibuffer`'s `Editor.Api`, `Editor.Command.Call`,
  `Editor.Completion.Later`, `Editor.Mode`, `Editor.Package` and
  `Editor.Role`. Each also imports its interface package's library
  (`CompletionApi`, `AtPointApi`, `MinibufferApi`), which the layer imports
  check allows. None imports another of the three.
- **Their interfaces stay in the core.** The completion interface, its
  styles', displays' and at-point sources' types and contracts, the
  sources that answer later and the prompt operations of the API
  (`Editor.Completion`, `.Style`, `.Display`, `.AtPoint`, `.Later`,
  `Editor.Api`) are read by the core's loop and registry, and a package
  registers a style, a display or an at-point source as a `SetupRequest`
  of them, as config does ([extension-points.md](extension-points.md),
  "Open questions").
- **Their tests moved under their kept names** (each was
  `ModelTest.<name>`, and `shippedStyleFailures` was
  `ContractTest.shippedStyleFailures`), with their sentences and
  assertions as they were. Each implementation's driver also runs its
  interface's contract over its own `Package` value
  (`completionPackageChecks`, `atPointPackageChecks`,
  `minibufferPackageChecks`), each pair one check. `at-point`'s test
  support (`AtPointTest/Support/Words.lean`) holds its own copies of the
  core's test helpers it used, since a package's tests may import neither
  the core's own test modules nor `Editor.Evil.Compiled`: evil's commands
  are not handed to its driver, and its listings are matched and drawn by
  the core's own style and display.
- **The core's tests keep a minibuffer and an at-point of their own.** A
  core test that answers a prompt or opens an at-point session hosts the
  kit's implementations, and one that hosts the core's list as the
  default editor appends them (`ConfigTest.shippedPackages`,
  `FfiTest.shippedPackages`). A test that read what only a shipped style
  or display makes, fuzzy's match ranges or the `minibuffer` display's
  rows and faces, now reads a style or display written in the test
  (`lean/Editor/Test/Listings.lean`, a module of the kit since phase 8, once `lean/ModelTest/Support/Listings.lean`, and the package `listings` of
  `lean/ConfigTest/Support/Listings.lean`, handed first to every config
  test's host; the linked kit's `lean/Editor/Test/Linked/Listings.lean`
  since phase 6), and the shipped value's own rule is held by the package's
  tests. `ModelTest.packageSetChecks` and the checks of
  `ConfigTest.shippedChecks` over the core's list (which all went with
  that list in phase 8) hosted the list alone, and stated that it held
  nothing of the three.
- **Their fixtures moved with them.** `prompt` and `candidates` moved byte
  for byte. `at-point` ran on the shared config `tests/headless/config`,
  which moved into it as its `config/`, byte for byte. `completion-choices`
  and `at-point-tuned` were written on the editor with the features in the
  core, before the moves, to show config naming each package's
  declarations through the set's base, and moved with their configs'
  imports changed (`import Completion.Styles` and `import
  Completion.Displays`; `import AtPoint.Words`). No `expected` changed.

#### The interface packages `completion-api`, `at-point-api` and `minibuffer-api`

Each declares the names another package or the core reaches its feature
by, shaped as `execute-command-api` is.

| Package | Declares | Publishes for tests | Implemented by |
|---|---|---|---|
| `completion-api` (`packages/completion-api/`) | `CompletionApi.pathStyleName` = `"path"`, the one completion name another feature reaches (the core's files package gives the file prompt's category the style `path`), and `names` | `CompletionApiTest.fake`, a package that registers `Style.keeping` under each name; `CompletionApiTest.contractChecks`, a style registered under each declared name | `completion`: `Styles.path`'s name is `CompletionApi.pathStyleName` |
| `at-point-api` (`packages/at-point-api/`) | `AtPointApi.completeName` … `quitName`, the seven names the Vim scheme's insert table binds; `triggeredName` and `pausedName`, the core's `Completion.AtPoint.triggeredCommand` and `.pausedCommand`; and `names`, the nine | `AtPointApiTest.fake`, which is the kit's `Editor.Test.AtPoint.package`; `AtPointApiTest.contractChecks`, a command under each declared name | `at-point`: `AtPoint.<x>Name := AtPointApi.<x>Name` |
| `minibuffer-api` (`packages/minibuffer-api/`) | `MinibufferApi.acceptName` … `deleteToStartName`, the seven names the Vim scheme's minibuffer table binds; `askName`, the Vim scheme's `askCommand`; `candidatesName`, the core's `Completion.candidatesCommand`, which every batch of a source's job is posted as; `modeName`, the core's `Prompt.mode`; and `names`, the nine commands | `MinibufferApiTest.fake`, which is the kit's `Editor.Test.Minibuffer.package`; `MinibufferApiTest.contractChecks`, a command under each declared name and a mode named `modeName` | `minibuffer`: `Minibuffer.<x>Name := MinibufferApi.<x>Name`, and its mode's name `modeName` |

- **Each declares `keywords = ["editor-interface"]`**, has no entry module
  and registers nothing. Their libraries import of the core what their
  names are written from: `completion-api`'s nothing, `at-point-api`'s
  `Editor.Completion.AtPoint`, `minibuffer-api`'s
  `Editor.Completion.Later` and `Editor.State`. Their test libraries
  import `Editor.Config.Packages`, and `completion-api`'s also
  `Editor.Completion.Style` and `Editor.Package`, the other two the kit's
  module that is their fake. `tests/hook-targets/fixture-set-graph` pins
  each with the layer `interface`, and its implementation requiring it.
- **Their own drivers** hold the fake to the contract, pin `names` whole,
  and show the contract refusing a package that registers nothing, one
  that lacks a name and one that misspells it; `minibuffer-api`'s also one
  that registers every command and no mode `minibuffer`
  (`completion-api-test: 6 checks passed`, `at-point-api-test: 7`,
  `minibuffer-api-test: 8`).
- **Two of the fakes are the kit's working implementations**, not
  names-only packages. The core cannot import an interface package, and
  its own tests need a minibuffer that accepts a prompt and an at-point
  that opens a session, so the kit holds `Editor.Test.Minibuffer` and
  `Editor.Test.AtPoint`, and the interface packages publish them as their
  fakes. One value to drift closes a chain of three checks: the core's
  Vim-table tests compare the tables' text with the kit's names
  (evil's `vimDefaultChecks`, `EvilTest.vimDefaultChecks` since phase 7); the interface's tests run its contract
  over the kit's implementation; and the shipped implementation runs the
  same contract and is checked to register under the kit's names, in
  order (`MinibufferTest.promptModeChecks`, `AtPointTest.atPointChecks`).
  A rename anywhere fails one of the three.
- **The reachers outside the core name the constants.** `compile`,
  `execute-command` and `binding-search` require `minibuffer-api`: their
  tests bind `MinibufferApi.acceptName` or `.cancelName` and register
  `MinibufferApiTest.fake`, and none imports the minibuffer. The core's
  reachers, the Vim tables, `Completion.Later.candidatesCommand`,
  `InputScheme.Vim.askCommand` and `Editor/Files/Compiled.lean`'s `path`,
  keep naming the text: the core cannot import a package.

#### Dropping `completion` leaves the core's own style and display

The editor of `tests/empty-set` registers no style and no display, so
every prompt is matched by the core's own style, `ranked` (the fuzzy
port's ranking, with no ranges), and its candidate list drawn by the core's
own display, `plain` (each row its text after two spaces, nothing marked,
with no faces). One fixture line changed, and one went, when the package
moved: `tests/headless/core-themes/expected`, the theme prompt's list with
nothing typed, which was

```text
view 2 0,0 0x0: "default\nfirst", scroll 0, selections , padding 8 0
decorations 2: minibuffer.candidate 0..7 minibuffer.candidate 8..13
```

and is line 12, `view 2 0,0 0x0: "  default\n  first", scroll 0,
selections , padding 8 0`, with no `decorations` line. The list later in
that fixture (line 20) is drawn the same way. In the default set nothing
changed: `completion` is the first package to register a style and a
display, so `fuzzy` and `minibuffer` are still the defaults.

#### Dropping `at-point` leaves insert state without line feed or tab

The Vim scheme's insert table binds `RET`, `TAB` and `C-g` to
`at-point-return`, `at-point-tab` and `at-point-quit`, which, with no
session open, run `insert-newline`, `insert-tab` and `keyboard-quit`
(`packages/evil/Evil/Vim/Default.lean` since phase 7). In a set without `at-point`
nothing registers those names: nothing fails to build, but the three keys
say `<name>: no such command` in the echo area and type nothing, and
`C-SPC`, `C-n` and `C-p` open no session. No standing fixture of the empty
set's editor types in insert state, so no line changed. Filed as the task
`at-point-insert-keys`: when evil moves out (phase 7), at-point
contributes its insert-state keys and evil's table stops naming at-point's
commands.

#### Dropping `minibuffer` leaves prompts that nothing answers

- **No later candidate arrives.** The core posts every batch a source's
  job answers as `minibuffer-candidates`, the minibuffer's command (the
  phase decided the name is the minibuffer's), so in a set without the
  package a prompt's job sources and at-point's `words` list nothing that
  answers later.
- **No prompt is answered.** The Vim scheme's minibuffer table binds
  `<Enter>`, `<Escape>`, `TAB`, `C-n`, `C-p`, `<Backspace>` and `C-u` to
  the seven `minibuffer-*` names, and its own asks for a text run
  `minibuffer-ask`, all of which nobody registers there. A prompt opens and
  takes typed text, and `<Enter>` says `minibuffer-accept: no such
  command` in the echo area and leaves it open and focused, and `<Escape>`
  does not close it.
- **The empty set's two fixtures no longer reach their subjects** (phase
  3's rule: a fixture of the core alone shows what the core alone has,
  and every changed line is recorded). Both scripts run to their end on
  that editor, so neither was cut; their steps are unchanged and their
  comments say what the core alone does. Past their first `<Enter>` they
  no longer show what they were written for, no shipped palette loaded and
  no compile ex name refused; that the core's list registers the one theme
  `default` and binds no ex name `compile` was held by
  `ConfigTest.shippedChecks` while the core had a list. Filed as the task
  `empty-set-prompts`, which
  names the other way: a config of those fixtures that registers a
  `minibuffer-accept` of its own would keep their subjects.
  - `tests/headless/core-themes/expected`, after `first` is typed and
    `<Enter>` pressed: line 15, which was `scene 0x0, focused 0, echo "",
    echo padding 8, preedit -, published 8, theme "first"`, is
    `scene 0x0, focused 1, echo "minibuffer-accept: no such command",
    echo padding 8, preedit -, published 6, theme "default"`, and lines
    18 to 21 are new: `view 1 0,0 0x0: "first", scroll 0, selections
    5..5, padding 8 0`, `status 1: minibuffer.prompt "Theme: "`,
    `view 2 0,0 0x0: "  first", scroll 0, selections , padding 8 0` and
    `status 2: -`. After the second `load-theme`, `solarized-dark` typed
    into the prompt still open and `<Enter>`: line 24, which was ``scene
    0x0, focused 0, echo "load-theme: no theme is registered as
    `solarized-dark`", echo padding 8, preedit -, published 13, theme
    "first"``, is `scene 0x0, focused 1, echo "minibuffer-accept: no such
    command", echo padding 8, preedit -, published 10, theme "default"`,
    and lines 27 to 30 are new: `view 1 0,0 0x0: "firstsolarized-dark",
    scroll 0, selections 19..19, padding 8 0`, `status 1:
    minibuffer.prompt "Theme: "`, `view 2 0,0 0x0: "", scroll 0,
    selections , padding 8 0` and `status 2: -`.
  - `tests/headless/core-ex-names/expected`, after `:compile` and
    `<Enter>`: line 4, which was `scene 0x0, focused 0, echo "compile: not
    an ex command", echo padding 8, preedit -, published 4, theme
    "default"`, is `scene 0x0, focused 1, echo "minibuffer-accept: no such
    command", echo padding 8, preedit -, published 3, theme "default"`, and
    lines 7 to 10 are new: `view 1 0,0 0x0: "compile", scroll 0,
    selections 7..7, padding 8 0`, `status 1: minibuffer.prompt ":"`,
    `view 2 0,0 0x0: "", scroll 0, selections , padding 8 0` and `status
    2: -`. After `:bogus`, typed into the line still open, and `<Enter>`:
    line 13, which was `scene 0x0, focused 0, echo "bogus: not an ex
    command", echo padding 8, preedit -, published 9, theme "default"`, is
    `scene 0x0, focused 1, echo "minibuffer-accept: no such command", echo
    padding 8, preedit -, published 7, theme "default"`, and lines 16 to 19
    are new: `view 1 0,0 0x0: "compile:bogus", scroll 0, selections
    13..13, padding 8 0`, `status 1: minibuffer.prompt ":"`, `view 2 0,0
    0x0: "", scroll 0, selections , padding 8 0` and `status 2: -`.

### The default packages of the features-as-packages roadmap's phase 6

Phase 6 moved the files cluster out of the core: seven features, each into
a default package of its own, with the two names-only interface packages
their names need and the two interface libraries phase 5 staged in the core,
which no core module imports once the seven are out. Every module keeps its
declarations' names (`Editor.Files.…`, `Editor.Workspace.…` and the like);
the modules drop `Editor.` from their names.

| Lake package | Library (from `lean/Editor/`) | Entry module's `packages` | Test driver / linked root | Requires |
|---|---|---|---|---|
| `files` (`packages/files/`) | `Files`, `Files.Compiled`, `Files.Paths` (`Files.lean`, `Files/Compiled.lean`, `Completion/Paths.lean`) | `#[Editor.Files.package]` | `files-test` / `FilesTest.Linked` | the core (`files-api` is the core's) |
| `buffers` (`packages/buffers/`) | `Buffers`, `Buffers.Compiled` | `#[Editor.Buffers.package]` | `buffers-test` / none | the core (`buffers-api` is staged in the core) |
| `workspace` (`packages/workspace/`) | `Workspace.Attach`, `.Compiled`, `.Finder`, `.FindFile`, `.FindInProject`, `.Lister`, `.Modes`, `.Projects`, `.Reach` (globs `Workspace.+`) | `#[Editor.Workspace.package]` | `workspace-test` / `WorkspaceTest.Linked` | `project-api`, `vc-api` |
| `project-search-api` (`packages/project-search-api/`) | `ProjectSearchApi` (new) | none (interface) | `project-search-api-test` | the core |
| `project-search` (`packages/project-search/`) | `ProjectSearch`, `.Run`, `.Compiled` | `#[Editor.ProjectSearch.package]` | `project-search-test` / `ProjectSearchTest.Linked` | `project-search-api` |
| `working-set-api` (`packages/working-set-api/`) | `WorkingSetApi` (new) | none (interface) | `working-set-api-test` | the core |
| `working-set` (`packages/working-set/`) | `WorkingSet`, `.Disk`, `.Places`, `.Refind`, `.Run`, `.Compiled` | `#[Editor.WorkingSet.package]` | `working-set-test` / `WorkingSetTest.Linked` | `working-set-api`, `vc-api` |
| `shell` (`packages/shell/`) | `Shell`, `Shell.Compiled` | `#[Editor.Shell.package]` | `shell-test` / `ShellTest.Linked` | the core (`shell-api` is staged in the core) |
| `version-control` (`packages/version-control/`) | the 17 under `VersionControl.` (globs `VersionControl.+`); git's half of the repository model is the test double `VersionControlTest.Git.Model` | `#[Editor.VersionControl.package, Editor.VersionControl.gutterPackage]` | `version-control-test` / `VersionControlTest.Linked` | `project-api`, `vc-api` |
| `project-api` (`packages/project-api/`) | `ProjectApi` (`lean/ProjectApi.lean`) | none (interface) | `project-api-test` | the core |
| `vc-api` (`packages/vc-api/`) | `VcApi` (`lean/VcApi.lean`) | none (interface) | `vc-api-test` | the core |

- **The set requires the seven first** (D5), in the order the core's list
  held them, so their registrations keep their order among themselves and
  against the default packages ("The order packages register in", above);
  the interface packages come in through their implementations' requires.
- **What each library imports of the core** (`lake -d ../packages query
  :editorPackageImports`), API alone: `files`'s `Editor.Completion.Later`,
  `Editor.Extension`, `Editor.FileJobs`, `Editor.Jumps`, `Editor.Language`,
  `Editor.Package`, `Editor.TypedPath`, `FilesApi`; `buffers`'s
  `BuffersApi`, `Editor.Api`, `Editor.Command.Call`, `Editor.Extension`,
  `Editor.Jumps`, `Editor.Package`; `workspace`'s `Editor.Api`,
  `Editor.Command.Call`, `Editor.Completion.Filtering`, `Editor.Extension`,
  `Editor.Invocation`, `Editor.Job`, `Editor.Package`, `Editor.Process`,
  `Editor.Process.Environment`, `CompileApi.Listing`,
  `Editor.SearchRoot`, `Editor.Workspace`, `FilesApi`; `project-search`'s
  `Editor.Api`, `Editor.Command.Call`, `Editor.Grep`, `Editor.Job`,
  `Editor.Jumps`, `Editor.Package`, `Editor.SearchRoot`, `Editor.Text.Word`,
  `Editor.Value`, `FilesApi`; `working-set`'s `BuffersApi`, `Editor.Api`,
  `Editor.Command.Call`, `Editor.Extension`, `Editor.File`, `Editor.Fuzzy`,
  `Editor.Job`, `Editor.Json`, `Editor.Jumps`, `Editor.Marks`,
  `Editor.Package`, `FilesApi`; `shell`'s `Editor.Api`,
  `Editor.Command.Call`, `Editor.File`, `Editor.Job`, `Editor.Package`,
  `ShellApi`; `version-control`'s `BuffersApi`, `Editor.Api`,
  `Editor.Command.Call`, `Editor.Diff.Script`, `Editor.Extension`,
  `Editor.File`, `Editor.Gutter.Track`, `Editor.Jumps`, `Editor.Language`,
  `Editor.Mode`, `Editor.ModeLine`, `Editor.Package`, `Editor.State`,
  `Editor.Store`, `Editor.Text`, `Editor.Value`, `Editor.Workspace`,
  `FilesApi`; `project-api`'s `Editor.Extension`, `Editor.Job`,
  `CompileApi.Listing`; `vc-api`'s `Editor.Diff.Script`,
  `Editor.Gutter.Track`, `Editor.Job`, `Editor.Program`. The interface
  packages' libraries import their own interface beside these, which the
  layer imports check allows; `project-search-api` and `working-set-api`
  import nothing. None of the seven imports another implementation (the
  phase's acceptance criterion 2), and no module of `project-search`,
  library or tests, reaches a module of evil, directly or transitively
  (criterion 3).
- **Their tests moved under their kept names.** Each model test module
  `ModelTest/Editor/<F>/<X>.lean` is `<P>Test/<P>/<X>.lean`, namespace
  `<P>Test`, each list's name kept: `FilesTest.languageOpenChecks` and the
  files' five others, `pathsChecks`, `filesPackageChecks`;
  `BuffersTest.bufferCommandChecks`, `buffersPackageChecks`;
  `WorkspaceTest.workspaceChecks`, `workspacePackageChecks`,
  `findFileChecks`, `findInProjectChecks`, `workspaceListerChecks`,
  `projectWorkspaceChecks`, `reachChecks`, `workspaceModesChecks` and the
  finder's two failure lists; `ProjectSearchTest.projectSearchChecks`,
  `projectSearchRunChecks`; the working sets' five; `ShellTest.shellChecks`;
  version control's 27; `ProjectApiTest.projectApiChecks`;
  `VcApiTest.vcApiChecks`, `versionControlModelChecks` and the contract's
  failure list. Each linked test module (`ConfigTest/Editor/<F>/…`,
  `ContractTest/Editor/<F>/…`) is `<P>Test/Linked/<P>/<X>.lean`, namespace
  `<P>Test.Linked`, run by the package's linked root, which prints
  `<p> linked test: N checks passed`. A feature's kit (`Editor.<F>.Kit`)
  is `<P>Test.Kit`. Their fixtures moved with them: `tests/workspaces/` is
  `packages/workspace/tests/workspaces/`, `tests/shell/` was
  `packages/shell/tests/shell/` until the shell's checks moved onto a rig
  over fakes (host-tests-on-fakes phase 4), and the workspace's lister checks run on a
  byte-for-byte copy of the core's `tests/completion/filter` in
  `packages/workspace/tests/completion/`, so `contract-test` takes three
  arguments, not five. The workspace finder's benchmark is an opt-in
  argument of the workspace's linked root (`mise run find-file-bench`).
- **The core's checks of what its hosts register** (`ConfigTest.shippedChecks`)
  each gained "the executable's hosts start with nothing of the <p>
  package", and their checks of what a moved package registers moved to
  that package's `<P>PackageChecks`, over the registry it makes alone
  (`Config.State.ofPackages #[<package>]`). `ModelTest.packageSetChecks` (which went with the core's list in phase 8)
  pinned the nine. The "start with nothing of" checks went with the list
  too ("The empty registry's checks", below).
- **No headless fixture moved** (D10): the fixtures that open, save, find
  and search files cross several of the seven, and run on the default set's
  editor.

#### The interface packages `project-search-api` and `working-set-api`

| Package | Declares | Publishes for tests | Implemented by |
|---|---|---|---|
| `project-search-api` (`packages/project-search-api/`) | `ProjectSearchApi.searchName` = `"project-search"`, `.symbolName` = `"project-search-symbol"`, `names` | `ProjectSearchApiTest.fake`, `ProjectSearchApiTest.contractChecks` | `project-search`: `ProjectSearch.name := ProjectSearchApi.searchName`, `symbolName := ProjectSearchApi.symbolName` |
| `working-set-api` (`packages/working-set-api/`) | `WorkingSetApi.addName` = `"working-set-add"`, `.openName` = `"working-set-open"`, `names` | `WorkingSetApiTest.fake`, `WorkingSetApiTest.contractChecks` | `working-set`: `WorkingSet.addName := WorkingSetApi.addName`, `openName := WorkingSetApi.openName` |

They are shaped as `execute-command-api` ("The default packages of the
features-as-packages roadmap's phase 3", above): the names the default
config binds (`SPC /`, `SPC s p`, `SPC *`; `SPC k a`, `SPC k o`,
`SPC RET`), a fake, a contract check each implementation's
`<P>PackageChecks` runs, and a driver of four checks. The default config,
still in the core, names the names as text.

#### Dropping the package leaves…

What each of the seven registered is gone from a set without it (D6):

- **without `files`**, nothing opens a file named on the command line, and
  `save-buffer` is unregistered: `files-api`'s `Files` value is absent, so
  session restore reports each file it would reopen and leaves it out, and
  the menu's `s-o` and `s-s` name commands no package registers;
- **without `buffers`**, ex's `b`, `ls` and `bd` name commands no package
  registers;
- **without `workspace`**, no buffer has a workspace, `compile-list` has no
  work, and a reach through `project-api` says there is no implementation;
- **without `project-search`** or **`working-set`**, the default config's
  keys name commands no package registers;
- **without `shell`**, ex says no `:!` line can run, and `C-g` in normal
  state names nothing (`keyboard-quit`);
- **without `version-control`**, no `vc-` command or ex name is registered,
  no gutter marks a line, and the working sets write their sets with no
  commit.

The empty set (`tests/empty-set`, the core alone) showed what remains in
its two fixtures, `core-themes` and `core-ex-names`, until phase 7 retired
them ("Dropping evil or themes leaves…", below). Neither changed in C9 to
C15: `core-ex-names` showed the ex line's status and no candidate, since
the empty set has no minibuffer to list them, and `core-themes` listed the
one theme. So no line of the empty set's fixtures is recorded here.

### The default packages of the features-as-packages roadmap's phase 7

Phase 7 moved evil, with the Vim scheme, and the themes out of the core,
each into a default package of its own, with a names-only interface
package each. The input scheme is now a package's: the core's Lake package
supplies none ("Input schemes", below). Every module keeps its
declarations' names (`Editor.Evil.…`, `Editor.Vim.…`,
`Editor.Vim.Default.…`, `Editor.Themes.…`); the modules drop `Editor.`
from their names, and `InputScheme.Vim` becomes `Evil.Vim`.

| Lake package | Library (from `lean/Editor/`) | Entry module | Test driver / linked root | Requires |
|---|---|---|---|---|
| `evil-api` (`packages/evil-api/`) | `EvilApi` (new) | none (interface) | `evil-api-test` | the core |
| `evil` (`packages/evil/`) | `Evil` (`Evil.lean`), the 13 under it (`Evil.Clipboard`, `.Compiled`, `.Jumps`, `.Marks`, `.Motions`, `.Objects`, `.Operators`, `.Registers`, `.Repeat`, `.Scroll`, `.Theorems`, `.TreeObjects`, `.Undo`), `Evil.Vim` (`InputScheme/Vim.lean`), `Evil.Vim.Default` (`InputScheme/Vim/Default.lean`) | `packages := #[Editor.Evil.package]`, `scheme := Editor.Evil.scheme`; the lakefile declares `keywords = ["editor-input-scheme"]` | `evil-test` / `EvilTest.Linked` | `evil-api`, `minibuffer-api`, `at-point-api` |
| `themes-api` (`packages/themes-api/`) | `ThemesApi` (new) | none (interface) | `themes-api-test` | the core |
| `themes` (`packages/themes/`) | `Themes`, `Themes.Compiled` | `packages := #[Editor.Themes.package]` | `themes-test` / `ThemesTest.Linked` | `themes-api` |

- **What the libraries import of the core** (`lake -d ../packages query
  :editorPackageImports`, the package imports check's input, direct
  imports alone). The themes': `Editor.Api`, `Editor.Command.Call` and
  `Editor.Package`. Evil's: `Editor.Api`, `Editor.Command.Call`,
  `Editor.Package`, the scheme's port and key strings
  (`Editor.InputScheme`, `Editor.Key.Notation`), the vocabularies
  (`Editor.Vocabulary`), the indent primitives (`Editor.Indent`), the
  syntax tree port (`Editor.SyntaxTree`), the jump list and going to a
  place (`Editor.Jumps`, `Editor.Jumps.Go`), the word rule
  (`Editor.Text.Word`), the undo tree's theorems
  (`Editor.UndoTree.Theorems`), the clipboard's names (`Editor.Clipboard`),
  and the names its tables run of features still in the core:
  `Editor.Ex`, `Editor.WindowCommands`, `Editor.TabCommands` and the
  staged interface library `ShellApi`. No module of either imports an
  internal module, and none imports the other package.
- **Each entry module imports its `Compiled` module**, which brings the
  library's other modules: a direct import of a module `Compiled` already
  brings is redundant, and the formatter's check refuses it. Evil's also
  imports `Evil.Theorems`, which nothing else of the library imports, so
  the build checks the proofs. So the set's config base holds what
  `Editor` held of both before the move, and config names
  `Evil.move Evil.motions` and `Themes.loadThemeCommand` as it did. The
  config base `Editor` imports by name the five core modules that only
  evil's modules brought (`Editor.Indent`, `Editor.Jumps.Go`,
  `Editor.Text.Word`, `Editor.UndoTree.Theorems`, `Editor.Vocabulary`), so
  an editor without evil elaborates config on a base that lost evil's
  modules and nothing else.
- **The host imports check** (`tools/host-imports-check.sh`) passes for
  both entry modules only because `lean/Editor.lean` dropped its nine evil
  imports and `import Editor.Themes` in the commits that made them: no
  host module reaches an entry module or a module one imports directly.
- **The tests moved with them**, under their names, sentences and
  assertions unchanged:
  - evil's model tests (`evil-test`, `EvilTest/Model.lean`):
    `vimEditChecks`, `vimRegistryChecks`, `vimGrammarChecks`,
    `vimStateChecks`, `vimHintChecks`, `vimKeyBindingChecks`,
    `vimDefaultChecks`, `vimDefaultHintChecks`, `vimContractChecks`,
    `treeObjectRuleChecks`, `atPointRepeatChecks`, `evilRestChecks`,
    `evilMotionChecks`, `evilStateChecks`, `evilInsertChecks`,
    `evilOperatorChecks`, `evilFindChecks`, `evilSearchChecks`,
    `evilSelectionChecks`, `evilObjectChecks`, `evilRegisterChecks`,
    `evilOpenChecks`, `evilIndentChecks`, `evilUndoChecks`,
    `evilRepeatChecks`, `evilJumpChecks`, `evilMarkChecks`,
    `evilScrollChecks` and `clipboardCommandChecks`, in
    `EvilTest/Vim.lean`, `EvilTest/Vim/Default.lean`,
    `EvilTest/Vim/Contract.lean`, `EvilTest/Evil.lean` and
    `EvilTest/Evil/*.lean`, on evil's kit (`EvilTest/Kit.lean`, which was
    `Editor.Evil.Kit`) and the drivers of `EvilTest/Support/`; and the
    package's own `evilPackageChecks` (`EvilTest/Evil/Compiled.lean`), the
    contract of `evil-api`;
  - evil's linked tests (`EvilTest.Linked`): `treeObjectChecks`,
    `treeObjectFixtureChecks`, `evilIndentChecks`, `evilChecks` and
    `evilLeaderChecks`, in `EvilTest/Linked/Evil.lean`,
    `EvilTest/Linked/Evil/Operators.lean` and
    `EvilTest/Linked/Evil/TreeObjects.lean`, on the host of the Vim scheme
    (`withVimHost`, `EvilTest/Linked/Support/Vim.lean`, which was the
    linked kit's `Editor.Test.Linked.Vim`). The root elaborates config on
    the base `Editor` and `Evil.EditorPackage`, found in the core's
    `.olean` directory, the package's own and those of the three
    interface packages it requires, and reads the repository's syntax
    fixtures (`tests/syntax`);
  - the themes' model tests (`themes-test`): `themeChecks`, in
    `ThemesTest/Themes.lean`, with the contract of `themes-api` and what
    the package registers; and its linked tests (`ThemesTest.Linked`):
    `themeChecks`, in `ThemesTest/Linked/Themes.lean`.
- **The core's tests name no module of either** (the plan's C5 to C12):
  what a core check typed under Vim keys it types on the test scheme, the
  kit's editing keys (`Editor.Test.Editing`) or a scheme written in the
  check, and a check whose subject was evil or the themes moved to their
  tests. The theme completeness check and the picture check are the
  core's (`Editor.Theme.Check`, `Editor.Theme.Picture`), since the shipped
  palettes' tests run them.
- **Neither package has a headless fixture of its own**: the standing
  fixtures under `tests/headless/`, which run on the default set's editor,
  press evil's keys, and the shipped palettes' fixtures load themes.

#### The interface packages `evil-api` and `themes-api`

| Package | Declares | Publishes for tests | Implemented by |
|---|---|---|---|
| `evil-api` (`packages/evil-api/`) | `EvilApi.insertNewlineName` = `"insert-newline"`, `.insertTabName` = `"insert-tab"`, `.undoName` = `"undo"`, `.redoName` = `"redo"`, `names` | `EvilApiTest.fake` (the four over the core's API: a line break and a tab at the selections, a step of the history undone and redone), `EvilApiTest.contractChecks` | `evil`: `Evil.Compiled` registers the four under the constants; `EvilTest.evilPackageChecks` runs the contract |
| `themes-api` (`packages/themes-api/`) | `ThemesApi.loadName` = `"load-theme"`, `names` | `ThemesApiTest.fake`, `ThemesApiTest.contractChecks` | `themes`: `Themes.loadName := ThemesApi.loadName`; `ThemesTest.themeChecks` runs the contract |

They are shaped as `working-set-api` ("The default packages of the
features-as-packages roadmap's phase 6", above). Who reaches the names:

- `insert-newline` and `insert-tab`: completion at point, whose `RET` and
  `TAB` run them with no session open
  (`packages/at-point/AtPoint.lean`). It requires `evil-api` and names the
  constants, and its tests run on the fake. The core's at-point stand-in
  (`Editor.Test.AtPoint`) names them as text.
- `undo` and `redo`: the Edit menu, which is the default package `menu`
  since phase 8 (`packages/menu/Menu/Compiled.lean`). It requires
  `evil-api` and names the constants, `EvilApi.undoName` and
  `EvilApi.redoName`, for its Undo and Redo items and for the chords `s-z`
  and `s-Z`; `MenuTest.standardMenuChecks` holds the items and the chords
  to them.
- `load-theme`: the default config (`<leader> h t`), as text, since it is
  a config: it is elaborated at run time on whatever set the editor has,
  as a user's config is, and imports only `Editor` ("The default config
  keeps naming commands as text", under phase 8's interface packages,
  below). `ConfigTest.DefaultConfig`'s `defaultPackageCommands` lists it.

Evil is itself a reacher that left the core, so its tables name other
features' commands by constants ([extension-points.md](extension-points.md),
"Reaches by name"): the minibuffer's from `MinibufferApi`, completion at
point's from `AtPointApi`, `keyboard-quit` from the staged `ShellApi`,
`ex` from `Editor.Ex.name`, the window and tab commands from
`Editor.WindowCommands` and `Editor.TabCommands`, and the clipboard four
from `Editor.Clipboard`, the core's names for the Edit menu's clipboard
items, which a scheme's package registers commands under.

#### Dropping evil or themes leaves…

What each registered is gone from a set without it (the plan's D7):

- **without `evil`**, the set has no input scheme unless another package
  supplies one, and an editor with none refuses to start: the headless
  mode, the window mode and `--probe` print the line below on stderr and
  exit 1. So the build that `:package-remove evil` starts fails at its
  own probe (step 6 of "The build, as a job", below), before the restart's:
  the staging directory is removed, nothing is published, no restart is
  asked for, and the echo area says `packages: the new editor did not
  start: it exited with status 1; editor: no input scheme is installed: no
  package of this editor's package set supplies one; this editor keeps
  running`. With another scheme, none of evil's 41 commands exists:
  completion at point's `RET` and `TAB` with no session name nothing
  (`insert-newline`, `insert-tab`), and the Edit menu's Undo, Redo, Cut,
  Copy, Paste and Select All name commands no package registers, unless
  that scheme's package implements `evil-api` and registers under the
  core's clipboard names;
- **without `themes`**, `load-theme`, the completion source `themes` and
  the registered theme `default` are gone. The theme in force is still
  named `default` (`Theme.defaultName`) and is the built-in theme, config
  still defines and names themes, and the default config's `<leader> h t`
  names a command no package registers.

The empty set (`tests/empty-set`, the core alone) is the set without
either, and without every other default package. Its editor refuses to
start, so the two fixtures that ran on it while the core supplied the
scheme are retired, and one fixture of the refusal replaces them:

- `tests/headless/core-themes` is removed. It showed an editor with no
  package but the core's: the theme `default` in force with no palette
  listed, the candidate list drawn by the core's own display, `<Enter>`
  running `minibuffer-accept`, which nothing registered, and empty status
  lines. Those facts were held by `ConfigTest.shippedChecks` and
  `ModelTest.packageSetChecks`, over the core's own list, until that list
  emptied in phase 8. Since then a host of the core alone is handed no
  package and so registers nothing (`ModelTest.packageChecks` and
  `ConfigTest.hostChecks`); the theme in force before any is registered
  is `default`
  (`ModelTest.reloadChecks`); with no style or display registered a prompt
  is matched and drawn with the core's own (`ModelTest.registryChecks`);
  and `ThemesTest.themeChecks` holds that the themes package registers
  `default`, the built-in theme.
- `tests/headless/core-ex-names` is removed. It showed the ex line of the
  same editor with no `compile` and no minibuffer to accept it. Those
  facts are held by the checks of a host handed no package, which
  registers nothing (`ModelTest.packageChecks` and
  `ConfigTest.hostChecks`), and by `ExTest.exChecks`; that the empty set's
  config base is `Editor` alone is a pin of `ffi-test`
  (`lake -d ../tests/empty-set query :editorBase`).
- `tests/headless/no-input-scheme` is added: `ffi-test` runs the empty
  set's editor in the headless mode on it, and with `--probe`, and each
  must exit 1 having printed exactly its `expected`, the one line of the
  block below.

No line of a fixture that still exists changed as a leave-out effect in
this phase: the lines that changed are registration order's ("Registration
order is visible", below). The one line this phase's leave-out added:

```text
editor: no input scheme is installed: no package of this editor's package set supplies one
```

### The default packages of the features-as-packages roadmap's phase 8

Phase 8 moved the last seven packages of the core's own list out, each
into a Lake package of its own, and emptied that list: the ex line, the
frame, window and tab commands and the menu bar that ships, which the
phase names, and session restore's registrations and the package-set
commands, which the list also held ("The core has no entry module",
above). Each moved with `git mv`, and every declaration keeps its name and
namespace (`Editor.Ex.…`, `Editor.WindowCommands.…`,
`Editor.Restore.package`), so config and tests changed `import` lines
only.

| Lake package | Library modules (from `lean/Editor/`) | Its `packages` | Test driver / linked root | Requires, beside the core |
|---|---|---|---|---|
| `ex` (`packages/ex/`) | `Ex` (`Ex.lean`), `Ex.Compiled` | `#[Editor.Ex.package]` | `ex-test` / `ExTest.Linked` | `ex-api`, `buffers-api`, `shell-api` |
| `frame-commands` (`packages/frame-commands/`) | `FrameCommands`, `FrameCommands.Compiled` | `#[Editor.FrameCommands.package]` | `frame-commands-test` | `frame-commands-api` |
| `menu` (`packages/menu/`) | `Menu.Compiled` | `#[Editor.Menu.package]` | `menu-test` | `evil-api`, `frame-commands-api` |
| `window-commands` (`packages/window-commands/`) | `WindowCommands`, `WindowCommands.Compiled` | `#[Editor.WindowCommands.package]` | `window-commands-test` | `window-commands-api` |
| `tab-commands` (`packages/tab-commands/`) | `TabCommands`, `TabCommands.Compiled` | `#[Editor.TabCommands.package]` | `tab-commands-test` | `tab-commands-api` |
| `restore` (`packages/restore/`) | `Restore.Compiled` | `#[Editor.Restore.package]` | `restore-test` | none |
| `package-set` (`packages/package-set/`) | `PackageSet.Compiled` | `#[Editor.PackageSet.package]` | `package-set-test` | none |

- **What each library imports of the core** (`lake -d ../packages query
  :editorPackageImports`), every one a module of the API:
  - `ex`: `Editor.Api`, `Editor.Command.Call`, `Editor.Ex.Line`,
    `Editor.Quit`, `Editor.Package` and the core's interface library
    `FilesApi`;
  - `frame-commands`: `Editor.Api`, `Editor.Package`, `Editor.Quit`;
  - `menu`: `Editor.Clipboard`, `Editor.Menu`, `Editor.Package`, `FilesApi`;
  - `window-commands`: `Editor.Api`, `Editor.Quit`, `Editor.Package`;
  - `tab-commands`: `Editor.Api`, `Editor.Package`;
  - `restore`: `Editor.Package`, `Editor.Restore.Restart`,
    `Editor.Restore.Run`;
  - `package-set`: `Editor.Api`, `Editor.Package`,
    `Editor.PackageSet.Build`, `Editor.PackageSet.Edit`.
- **The edges that were cut first.** The loop imported the ex line for the
  quit rule and its name, which are the core's now (`Editor.Quit`); the
  frame commands and `window-quit` name the same. The tab commands
  imported the window commands for a call's count and for giving up on a
  layout refusal, which are the core's API now (`Call.count`,
  `Call.steps`, `orGiveUp`). The menu names the frame commands, and evil's
  Vim tables the ex line and the window and tab commands, by the
  constants of the names-only interface packages below. No registration
  changed.
- **Their tests moved with them**, each list under the name it had:
  `exChecks` and `exPackageChecks` (`ExTest`, once `ModelTest`), and
  `exChecks` and `exScriptChecks` through the headless host
  (`ExTest.Linked`, once `ConfigTest`); `frameCommandChecks`
  (`FrameCommandsTest`); `standardMenuChecks` (`MenuTest`), the checks of
  the menu that ships, while the checks of the core's menu mechanism stay
  `ModelTest.menuChecks`, on a menu written in the test;
  `windowCommandChecks` (`WindowCommandsTest`); `tabCommandChecks`
  (`TabCommandsTest`); `restorePackageChecks` (`RestoreTest`); and
  `packageSetCommandChecks` (`PackageSetTest`), the checks of the
  `:package-…` commands, while the checks of the build job stay
  `ModelTest.packageSetBuildChecks`. Each package's list also holds what
  the core's own list's checks held of it: what it registers, and nothing
  else.
- **The empty registry's checks.** While the core had a list,
  `ConfigTest.shippedChecks` held what its hosts registered, and as each
  feature moved out it gained a check that the hosts "start with nothing
  of the <p> package", twenty-two by the end. With the list empty those
  checks read the registry `Config.State.ofPackages` makes of no package
  and asserted that it lacked names other packages own: they could not
  fail, and they pinned other packages' names in a core test (AGENTS.md,
  "Crate coupling"). They are removed. What they stood for is held where
  it can fail:
  - the core's Lake package has no entry module, so the root of the set
    with no package imports `Editor` and `Editor.Main` alone, a pin of
    `ffi-test` beside that set's base (`lake -d ../tests/empty-set query
    :editorRootImports`);
  - a host handed no package starts from a registry with no entry of any
    kind: `ModelTest.packageChecks`, on the model, beside a package of
    every kind that fills each one, and `ConfigTest.hostChecks`, through
    the headless host;
  - what the core falls back to there, its own style and display, owned
    by `compiled`, and the theme `default`, is `ModelTest.registryChecks`'
    and `ModelTest.reloadChecks`';
  - what each package registers is its own `<P>Test.<p>PackageChecks`.

  `shippedChecks` keeps its one check of the host itself, the state
  directory it is handed.
- **The core's tests run on the kit's stand-ins**: its own ex line over
  the core's ex line data (`Editor.Test.exLinePackage`) and a `quit` that
  runs the core's rule (`Editor.Test.quitPackage`), session restore's and
  the build's registrations over the core's work
  (`Editor.Test.Restore.package`, `Editor.Test.PackageSet.buildPackage`),
  window and tab commands written over the API (`Editor.Test.Windows`),
  the frame driver (`Editor.Test.Frame`) and the style and display written
  for tests (`Editor.Test.Listings`). A stand-in holds no checks: it is
  pinned by the checks that use it and by the package checks that hold
  the real package to it.
- **Their fixtures stay where they are.** `tests/headless/ex`, `tabs`,
  `restore`, `restart` and the rest cross features, so no package gained a
  `tests/headless/`, and the fixture counts did not change.
- **The compile mode's registrations left the core's setup port.**
  `SetupRequest` has no constructor that names the compile mode: a
  contribution and a project's commands are values at the extension
  points `Compile.Contribution` and `Compile.ProjectCommands`, declared
  by the interface package `compile-api` (`packages/compile-api/`), which
  also holds the vocabulary, the listing and their test kit
  (`CompileApi`, `CompileApi.Format`, `CompileApi.Listing`, once
  `Editor.ProjectMode` and the two modules under it). `compile`,
  `workspace` and `project-api` require it. The setup operations keep
  their names and signatures (`compileContribution`, `projectCommands`),
  and the reader, `Compile.hook`, ranks config's contributions first, as
  the registry did ("What moving the last seven added to the core's
  API", below). Two refusals went: a `setup` that registers one mode's
  contribution twice, or gives one project's commands for a mode twice,
  is no longer refused, and the later is used, as at every choice point;
  and a package may give project commands, which only config could.

#### The interface packages `ex-api`, `frame-commands-api`, `window-commands-api`, `tab-commands-api`, `compile-api`, `buffers-api` and `shell-api`

| Interface package | Declares | Implemented by | Named by |
|---|---|---|---|
| `ex-api` (`ExApi`) | `name` (`ex`), `quitName` (the core's `Quit.name`), `names` | `ex` | `evil` (`:`) |
| `frame-commands-api` (`FrameCommandsApi`) | `toggleFullscreenName`, `minimiseName`, `names` | `frame-commands` | `menu` (the Window menu) |
| `window-commands-api` (`WindowCommandsApi`) | the thirty-three names, `names` | `window-commands` | `evil` (`C-w`) |
| `tab-commands-api` (`TabCommandsApi`) | the eight names, `selectName`, `names` | `tab-commands` | `evil` (`C-w`) |
| `compile-api` (`CompileApi`, `CompileApi.Format`, `CompileApi.Listing`) | the points `Compile.Contribution` and `Compile.ProjectCommands`, the two setup operations, `Compile.hook`, the error formats as data, the listing and its job's name | `compile` reads; `compile` and config register | `workspace`, `project-api` |
| `buffers-api` (`BuffersApi`), `shell-api` (`ShellApi`) | as they did while the core staged them ("The interface libraries of the features-as-packages roadmap's phase 5", below) | `buffers`, `shell` | as before, and `ex`; `shell-api` also by `ex-api` |

- **Each names-only package is shaped as `evil-api`**: a library of
  constants and `names`, a fake, a contract check and a driver. The
  contract holds an implementation to registering a command under each
  name, and each implementation's package check runs it and shows it bite.
- **`ex-api`'s contract holds three more things** of the command `ex`,
  which other packages rely on: handed a line whose name is bound, it
  runs the bound command with the rest of the line; handed a bang line,
  it runs `shell-api`'s `shell-command` with the text and the line; handed
  no line, it asks for one, with itself as the continuation. Its fake is
  the kit's ex line with the kit's quit command, as `minibuffer-api`'s is
  the kit's minibuffer.
- **Nothing reaches the menu, session restore's registrations or the
  package-set commands by a name a package declares**, so those three
  have no interface package: what a replacement of `restore` or
  `package-set` must register is the core's names, and the kit's
  stand-ins are the fakes the core's tests run on.
- **The default config keeps naming commands as text.** It is a config,
  elaborated at run time on whatever set the editor has, and a user's
  config names commands as text; it is no core module and imports only
  `Editor`. `ConfigTest.defaultConfigChecks` holds every name it binds to
  a command the default set registers, the window and tab commands' as
  text beside the two interface packages that declare them.

#### Dropping one of the seven leaves…

`mise run leave-out` builds the default set without each implementation
package in turn, all twenty-five, and each editor builds
([the-gate.md](../dev-practices/the-gate.md), "The leave-out check"). What
an editor without one of this phase's seven has:

- **without `ex`**: no ex line. `:` runs nothing, and the ex names other
  packages bind have no line to run them. `quit` is no command, so the
  system's quit, Command-Q and `window-quit` on the last window say there
  is no such command; the window's close button still quits, by the rule
  the core runs itself.
- **without `frame-commands`**: no `toggle-fullscreen` or
  `minimise-window`, and `C-s-f`, `s-m` and `s-q` are unbound; the Window
  menu's two items name commands nobody registered.
- **without `menu`**: no menu bar unless config defines one, and `s-o`,
  `s-s`, `s-z`, `s-Z`, `s-x`, `s-c`, `s-v` and `s-a` are unbound.
- **without `window-commands` or `tab-commands`**: none of their
  commands, so the Vim scheme's keys under `C-w` and the default config's
  under `SPC w` and `SPC TAB` run nothing; the frame still lays its
  windows and tabs out, and a restored session still restores them.
- **without `restore`**: nothing is journalled and no session is
  restored, `restart` is no command, and a package-set build ends without
  a restart.
- **without `package-set`**: the three `:package-…` commands are gone,
  and a changed lakefile is not built, since the job the reload asks for
  is not registered.

No fixture line records a leave-out of this phase: the fixtures run on
the default set and the fixture set, which hold all seven. The block below
is for a fixture line a leave-out changed, and is empty.

```text
```

### The fixture set

Four packages and a set under `tests/packages/`, used by tests alone. They
showed the path a default package and a user's package take before any
feature moved, and they still show what the default package does not: a
package that requires another package, and a linked test that starts a
host, and an interface package with its fake and its contract check
([extension-points.md](extension-points.md), "Three layers"). The set
requires the default set, so its editor holds the default packages too,
and the example package of the guide to writing a package,
`docs/packages/word-count/`, so the gate's package steps cover the code the
guide quotes.

| Path | What |
|---|---|
| `tests/packages/lakefile.toml` | The fixture set, `fixture-set`: it requires `greeting-loud`, then `greeting-api`, then `echo`, then the default set, and through it the twenty-five default packages and the eleven interface packages, then `word-count` |
| `tests/packages/greeting-api/` | The interface package `greeting-api` (`keywords = ["editor-interface"]`): the name `greeting-reply` (`GreetingApi.replyName`) and every name it declares (`GreetingApi.names`); in its test library, the fake `GreetingApiTest.fake` and the contract check `GreetingApiTest.contractChecks`, and its test driver, which holds the fake to the contract and shows the contract refuse a package that lacks or misspells the name. It has no entry module and registers nothing |
| `tests/packages/greeting/` | The Lake package `greeting`, an implementation of `greeting-api`: the commands `greeting-hello` and `greeting-reply` (`Greeting.lean`), the second under `GreetingApi.replyName`, its entry module, its test driver (`GreetingTest/Model.lean`, which runs `GreetingTest/Greeting.lean` and greeting-api's contract check), its linked test (`GreetingTest/Linked.lean`, with the config it loads in `tests/linked/config`) and the fixture `tests/headless/hello` |
| `tests/packages/greeting-loud/` | The Lake package `greeting-loud`, which requires `greeting`, to register after it, and `greeting-api`, and registers `greeting-reply` again with another text, by the name `greeting-api` declares. It imports nothing of `greeting`; its tests use greeting-api's fake. Its test driver and the fixture `tests/headless/reply` |
| `tests/packages/echo/` | The Lake package `echo`, which holds Rust ("Rust in a package", below): its crate `echo-service` (`rust/`), its glue (`ffi/glue.c`), the port of its service with a pure model, a contract and the Rust-backed binding, its test driver (`EchoTest/Model.lean`) and its linked test (`EchoTest/Linked.lean`). It registers no package |
| `docs/packages/word-count/` | The Lake package `word-count`, the example the guide to writing a package ([writing-a-package.md](../packages/writing-a-package.md)) quotes: the command `word-count` (`WordCount.lean`), its entry module, its test driver (`WordCountTest/Model.lean`, which runs `WordCountTest/WordCount.lean`) and three fixtures: `count`, the command compiled in; `as-config`, the same code as a config file; and `from-config`, a config that imports the package's module. It has no linked test |

- **A package outside the core is built by the package-set build and its
  command runs.** The fixture set's editor prints `run greeting-hello: ok`
  and the scene with the package's text for `hello`. The default set's
  editor prints `run greeting-hello: no such command` for the same script,
  which `ffi-test` also checks, so the command came from the set.
- **A package registers after the package it requires.** Both packages
  register `greeting-reply`, and of two registrations of a name the later
  is the one found. The fixture set requires `greeting-loud`, and
  `greeting` is in the set through it alone: Lake's own list holds
  `greeting` after `greeting-loud` there, and with the root's entries in
  that order the scene of `reply` showed `greeting`'s text. With the
  build's order it shows `greeting-loud`'s.
- **Every fixture lakefile is TOML but `echo`'s**, turns every Lean linter
  on with `warningAsError`, as the core does, and names default targets.
  `echo`'s is Lean, because a TOML lakefile cannot declare a target that
  compiles C, `moreLinkObjs`, or the crate's target; so are those of the
  two packages of `tests/rust-bans/`, which declare a crate and hold no
  Lean. A
  package's test driver is not a default target, as the core's
  `model-test` is not: `mise run lean` links with the system compiler,
  which a TOML lakefile has no flags for.
- **The fixtures are hermetic.** They are checked in and build into their
  own `.lake/` directories, as the core builds into `lean/.lake`. Every
  dependency is a path, and nothing is written outside those directories.
  `.gitignore` ignores `.lake/` and `.lean-fmt-cache` in any directory.

### Manifests: a set's build fetches nothing

**Every Lake root has its `lake-manifest.json` committed**: the core, the
default set, each default package (`files`, `buffers`, `workspace`,
`project-search`, `working-set`, `shell`, `version-control`, `completion`,
`mode-line`, `minibuffer`, `shipped-themes`, `execute-command`,
`binding-search`, `compile`, `at-point`, `languages`) and each of the nine
interface packages of the default set (`project-api`, `vc-api`,
`project-search-api`, `working-set-api`, `completion-api`,
`minibuffer-api`, `execute-command-api`, `binding-search-api`,
`at-point-api`), the fixture
set, each fixture package (`echo` among them), the writing guide's
example package (`docs/packages/word-count/`), the empty set, the
user-side link's set and its package, the Rust bans check's set
(`tests/rust-bans/`) and its two packages, and the formatter's host.

- **A set's manifest holds path entries only.** With it present, a
  dependency the manifest does not hold fails the build (`dependency … not
  in manifest`) and fetches nothing. So a set's build is offline, and a
  `require` added to a set or to a package of it fails every build of the
  sets that reach it until their manifests are written again.
- **After changing a `require`**, run in `lean/`
  `lake -d <the root's directory> update --keep-toolchain` for the root
  that changed and for every set that reaches it, and commit the
  manifests. Without `--keep-toolchain` and outside elan, `lake update`
  also rewrites `lean-toolchain` and stops.
- **A root with no manifest gets one written by its first build**, which is
  why none is left out: a build must not write into the checkout.
- **The core requires no git repository.** A set that requires the core by
  path would clone every git dependency of the core into its own
  `.lake/packages`. So the Lean formatter is not a `require` of the core:
  it is the one `require` of a package of its own, its host
  (`tools/lean-fmt/lakefile.toml`), which nothing requires and whose
  `packagesDir` keeps the clone and its build under `lean/.lake/packages`,
  where CI caches it. `lake -d ../tools/lean-fmt exe lean-fmt … --root
  <package>` runs it over any package ([the-gate.md](../dev-practices/the-gate.md),
  "Formatting").

### The toolchain copies

`lean/lean-toolchain` is the one pin every task reads: every Lake command
runs in `lean/`, naming another root with `--dir`. **Each Lake root outside
`lean/` holds a copy of it** (the default set and its forty-three packages,
the twenty-five default packages and the eighteen interface packages, the fixture set and its three packages, the
writing guide's example package `word-count`, the empty set, the user-side link's set and its package, the Rust bans check's
set and its two packages, and the formatter's host): `lean-fmt` refuses a root with no
`lean-toolchain`, and elan reads the file when Lake is run in that
directory. `tools/toolchain-check.sh`, first in `lean-test`, fails when a
tracked copy differs from the pin, naming it. A bump of the pin
(`AGENTS.md`, "Toolchains") changes every copy in the same commit.

## User package sets

A user's config directory is a Lake package, and its lakefile is the
source of truth for the user's package set (packages phase 8). This
section is how a set the user names becomes the editor they run. The app
builds it itself, from the Lean toolchain, the core and the default
packages it ships, with no Lean, compiler or Cargo of the user's (phase 9;
[lean-runtime.md](lean-runtime.md), "The app ships the toolchain");
`bundle-test` and `app-check` build one from a bundle alone, read-only,
with decoys of every tool first on the `PATH`.

### The records beside a set's editor

The package-set build (the facet `editor`) writes three records beside the
executable it links, besides `editor.oleans` and `editor.set`:

- **`editor.core`**: the core's identity, one line, 16 hex digits
  (`coreIdentity` in `lean/lakefile.lean`). It mixes the traces of the
  objects of every module of the core's library `Editor`, the core's glue (`glue.o`), the core's Rust archive
  (`rustlib`) and the version of the Lean toolchain. Two sets over one
  core get the same identity, whatever their packages: `ffi-test` compares
  the default set's and the fixture set's. The whole libraries are hashed,
  not only the modules a set links, so a package that imports a core
  module the default set does not link does not change the identity. A
  per-user editor linked against another core is never started
  ([lean-runtime.md](lean-runtime.md), "A cold start picks the newest
  per-user editor"). `tools/stage-bundle.sh` copies the record
  in the bundle's resources, `Contents/Resources/editor.core`: `codesign`
  refuses a file in `Contents/MacOS` that is not code (found by `mise run
  app-check`). The launcher and the editor read it there for an executable
  in a bundle, and beside the executable otherwise.
- **`editor.build`**: the environment a rebuild must reproduce, one line
  `NAME=value` for each of `LEAN_CC` and `MACOSX_DEPLOYMENT_TARGET` that
  was set when the build ran (`buildRecordText`). In a checkout
  `mise run lean` links with `LEAN_CC=/usr/bin/cc`; a user-set build run
  without it could re-key Lake's traces of the core's C, rebuild shared
  outputs in `lean/.lake`, or fail to link the system frameworks. The
  record says what the last build of the facet ran with: it is written
  whether or not the link itself had to run.
- **`editor.coredir`**: the directory of the core the editor links, one
  absolute line: the workspace's `editor-core` package directory, the core
  Lake actually linked, as Lake spells it, never resolved through links.
  The editor reads it (`ModuleLookup.coreDirectory?`, normalised
  lexically, none when that directory is not there) into
  `PackageSet.Running.coreDirectory`. In a bundle it is not read: the
  directory is `Contents/Resources/lean/lean`, by the layout, as the set's
  is. A per-user install copies it, so a per-user editor knows the core it
  was built against.

### The install: a set's editor in one directory

`EDITOR_INSTALL_DIR=<dir> lake -d <set> build :editorInstall` (the facet
`editorInstall`) builds the set's editor and fills `<dir>`, which must not
exist yet:

```
<dir>/
  editor           a copy of the executable, signed ad hoc on macOS
  editor.core      the core's identity, copied
  editor.build     the build environment, copied
  editor.coredir   the core's directory, copied
  editor.oleans    one relative line: lib/lean
  lib/lean/...     .olean, .olean.server and .olean.private of every module
                   of the workspace the set's root imports
```

- **The modules are copied, not referenced.** A later build that fails
  after compiling rewrites a package's `.olean` files in the set's
  packages. The running editor and the previous install would then import
  modules that no longer match their linked code. A copy keeps each
  install self-contained, as the bundle is. The toolchain's own modules
  (`Init`, `Std`, `Lean`) stay in the toolchain.
- **`editor.oleans` is relative**, resolved against the executable's own
  directory (`Editor/ModuleLookup.lean`, "The record"), so `<dir>` can be
  renamed into place once it is complete.
- **No `editor.set` is written**: a per-user editor's set is the config
  directory itself.
- **Its size.** Measured on macOS arm64 for the fixture set: the
  executable is about 240 MB and the whole directory about 420 MB.

`ffi-test` installs the fixture set into a temporary directory, runs the
fixture package `greeting`'s headless fixture from it with no `.olean`
directory given, verifies its signature on macOS, and checks that a second
install into the same directory is refused.

### The fingerprint: when a set differs from the running editor's

"The lakefile's dependencies or `lake-manifest.json` differ from those the
running executable was linked with" is decided on a **fingerprint**
(`lean/Editor/PackageSet/Fingerprint.lean`):

- **Requires**: the lakefile's `[[require]]` tables, in order, each
  normalised to one line: `path <name> <absolute directory>` (made absolute
  against the config directory and normalised lexically), `git <name>
  <url> <rev|-> <subDir|->`, or `reservoir <name> <scope> <version|->`.
  The tables are read with Lake's TOML loader
  (`Config.Lakefile.Toml.requireEntries`). **The root's own-core require
  is left out**: `editor-core` by a path that names the running editor's
  own core directory, however it is spelled. So the lakefile an editor
  generates now and the one an older editor generated, the set alone,
  both match the shipped default and start no build; without that, every
  existing config would rebuild once after the upgrade, for an identical
  editor. A root `editor-core` naming another directory, or any other
  source, stays in the fingerprint: that set differs, a build starts, and
  its core check refuses it ("The build, as a job"). `editor.packages`
  records are written from the same fingerprint, so they leave the line
  out too.
- **Pins**: the git entries of `lake-manifest.json`, `pin <name> <url>
  <rev>`. Path entries are left out: the lakefile decides them, and Lean's
  language server writes them into a manifest the user never touched. A
  stale entry for a package no longer required stays on both sides, so it
  never starts a build.
- **The shipped set's name**, `set <name>`, carried for `:package-remove`
  and not compared.

A `lakefile.lean` is not read (it is a program): its fingerprint is the
hash of its text, so any edit of it starts a build.

Every reload reads the config directory's facts as a package set (its
lakefile, the manifest and, when the lakefile requires the shipped set by
path, that set's own requires) into its outcome (`Config.reload`,
`Config.packageFacts`), whether it installed or was refused: a config that
imports a package the set lacks is refused until the rebuild, and still
starts it.

The running executable's fingerprint (`lean/Editor/PackageSet/Running.lean`,
read once at the edge into `EditorState.packageSet`) is:

- for a **per-user install**, the record `editor.packages` beside it,
  `leanmacs-packages 1` and then its `require`, `pin` and `set` lines;
- for an **executable built from a set directory**, the shipped default,
  the fingerprint of the lakefile it would generate: one `path <set name>
  <set directory>` require and no pin. So a generated lakefile matches it
  and starts no build.

The running editor also reads `editor.core`, `editor.build` and
`editor.coredir` beside itself, and knows its toolchain's `lake` (`<sysroot>/bin/lake`, when it is
there).

### The lakefile's edits

`:package-install`, `:package-remove` and `:package-update <name> <rev>`
edit the config's `lakefile.toml` as text
(`lean/Editor/PackageSet/Edit.lean`), from its text and its require tables
as the last reload read them with Lake's loader:

- **A table** runs from its `[[require]]` header to its last line before
  the next header that is neither blank nor a comment. A lakefile whose
  requires are not each a `[[require]]` table is refused: edit it by hand.
- **Install** adds a table after the last require: `path`; `git` with an
  optional `rev`; or `scope` with an optional `version`.
- **Remove** takes a table out. When the lakefile requires the shipped
  set (`default-set`) and the name is one of that set's own requires, the
  set's table is replaced by a table for each of the set's requires but
  that one and the core, each path made absolute against the set's
  directory: the default set expanded, minus the package. The core is
  left out because the root already requires it. `editor-core` is refused
  ("the core cannot be removed"), as is a package nothing requires.
- **A rev** is written into a git require's table.
- **The core** is never installed, given a rev or removed: each refuses
  `editor-core` ("the core cannot be installed; the root requires it",
  "the core cannot be given a rev; the root requires it by path", "the
  core cannot be removed"), since the root's own core require is written
  after every edit.
- **A `lakefile.lean`** is never edited: the commands say they edit
  `lakefile.toml` only.
- **The core's require, at the root, last** (packages phase 12). Each
  edit writes `editor-core` at the lakefile's root by the running editor's
  core directory, as the last require (`withCoreEdit`, the one
  composition every command's edit is made through): any `editor-core`
  table is taken out before the edit, whatever its source, and the core's
  added after the last `[[require]]` table once the edit is made, so an
  installed package comes before it. When the edit changes nothing and the
  lakefile's last require is already that directory (by a path relative to
  the config directory or absolute, as the fingerprint and the build's
  core check resolve it, `namesCore`), with no other `editor-core`, it is
  left as it is by `withCoreEdit`: a repaired lakefile is a fixed point. So every edit
  repairs a lakefile an older editor generated (the set alone) or one
  edited by hand, and a package's git require of the core stays only a
  name. An editor that knows no core directory refuses the edits:
  "`<command>`: this editor knows no directory of its core, so it cannot
  write the lakefile's editor-core require". A reload never rewrites the
  lakefile: one edited by hand without the core's require builds as before
  while Lake still resolves the running core through the set by path, and
  is refused by the build's core check otherwise; the next edit repairs
  it.

`config-test` reads every text these edits make back with Lake's loader,
the core last.

### The build, as a job

A reload whose fingerprint differs from the running editor's starts the
job `package-build` (`lean/Editor/PackageSet/Build.lean`), whether the
config was installed or refused. The decision is the pure reload
reducer's (`lean/Editor/Config/Reload.lean`, `State.packagesAfter`): as
each reload finishes it keeps what the reload read, asks
`PackageSet.decide`, and has the effect `buildPackages` or `say`, which
the host only carries out; it keeps whether a build is in flight, which
the host tells it of a build `:package-update` started too, and whether
it has said why it cannot build. It starts none while one is in
flight, when the editor has no data directory or knows no core identity,
or when it has no `lake`; then it says once: "the package set changed, but
this editor has no lake to build it (`<sysroot>/bin/lake`)". The app ships
the toolchain since phase 9, so it has one. `:reload` retries a failed
build.

**The config directory is the set's root**: the build runs
`<sysroot>/bin/lake` in it, as Lean's language server does, so Lake
writes `<config>/.lake/` and `<config>/lake-manifest.json`, and git
dependencies are cloned into `<config>/.lake/packages`. The root's Lake
name is `config`, so a per-user editor's `Origin.setName` is `config`; its
shipped set's name is carried in `editor.packages` as `set <name>`.

The steps, each through the job port's process and file requests, so each
is pinned on the models (`ModelTest.packageSetBuildChecks`):

1. **Git**, when the lakefile directly names a git or Reservoir
   dependency: `git --version`. Not found, or a non-zero exit (macOS's
   command-line-tools shim), stops the build: "git is required to fetch
   `<names>`, and none works here (`<how>`): install it with
   `xcode-select --install` on macOS, or from https://git-scm.com, then
   :reload; this editor keeps running".
2. **Resolve**: `lake update --keep-toolchain <names>` for the requires the
   manifest lacks, whose entry has another url or revision, or, for a path
   require, whose entry is not a path entry naming the same directory (a
   repaired root `editor-core` over the git or inherited entry the set had:
   Lake keeps such a stale entry and only warns, `manifest out of date:
   source kind (git/path) of dependency '«editor-core»' changed`); for
   `:package-update`, the named package or every git and Reservoir one.
   Measured on Lake 5.0.0: a `require` missing from the manifest fails the
   build (`dependency 'b' not in manifest`), `lake update b` adds only
   `b`, and a stale entry for a removed require does not fail the build.
2b. **Core** (packages phase 12): the manifest is read once, here, and
   must resolve `editor-core` to the running editor's own core, a path
   entry whose directory, normalised lexically, is the editor's core
   directory: the root's own require, or the set's inherited
   `<set>/../lean`. Anything else stops the build before it links or
   makes a staging directory: "the package set resolves editor-core to
   `<git <url> at <rev> | the directory <dir> | nothing>`, not this
   editor's core `<core>`; require it at the root of
   `<config>/lakefile.toml` with path = "`<core>`", as its last require,
   after every other (:package-install and :package-remove write it), then
   :reload". That is a set that reaches the core only through another
   package, or requires it before a package, while that package names the
   core from git: Lake takes the git require, and would build a core from source that is not the one the
   editor links. The refusal comes after the resolve, which may already
   have fetched that core; the manifest is authoritative only then. Step 5
   reuses the manifest this step read. `user-sets-test` D shows it end to
   end.
3. **Rust**: `lake query :editorRustCrates`; a set that holds a package
   declaring a Rust crate stops here, refused ("Who can build it"). No
   Cargo is ever run.
4. **Build and install**: `lake build :editorInstall` with
   `EDITOR_INSTALL_DIR=<data>/editors/staging-<k>` and the environment of
   `editor.build`, its output streamed into the buffer `*package-build*`.
5. **Record**: the new editor's `editor.core` is read, and
   `editor.packages` written beside it: the requires as the reload read
   them, the pins read again after the resolve, and the set's name.
6. **Probe**: `<staging>/editor --probe` must print `probe: ok` within
   10 s, which catches a bad link, a bad signature or an `initialize` that
   throws before anything is published.
7. **Publish**: `/bin/mv <staging> <data>/editors/<core>/<n>`, atomic
   within one file system.
8. **Prune**: this core's versions older than `n-1`, every other core's
   directory, and leftover `staging-*`; the directory that holds the
   running executable is always kept, whichever core or version it is. An
   older version of this core can be the running one: a publish whose
   restart did not happen (refused, or the session not written), or whose
   new editor crashed so the launcher started the one before, leaves it
   running when the next build publishes.
9. **Restart** into the new editor through the restore's restart
   (`Editor.restart`), with the session handed over; with no state
   directory, "built `<exe>`; it starts at the next launch".

Every failure removes the staging directory, ends the buffer with `Package
build failed: <how> after <t>`, says `packages: <how>; this editor keeps
running` and publishes nothing, so the previous executable stays the
launcher's choice. The buffer is read-only, starts with a header line, is
shown through the display rules for the opener `package-build`, has the
child's output appended as it arrives (a post for each delivery of its
lines; no pause on the job clock, which the headless mode's is fake) and
ends with
`Package build finished after <t>` or the failure.

### Where per-user editors live

```
<data>/editors/<core>/<n>/       an installed editor (see "The install")
  editor.packages                the fingerprint it was built from
<data>/editors/staging-<k>/      a build's install before it is published
```

`<data>` is the window mode's `--data`, else `leanmacs` under
`$XDG_DATA_HOME`, else under `$HOME/.local/share`; the headless mode has
one only when `--data` is given, so no script can build into a user's
own. `<core>` is the core's identity, so an editor linked against another
core is never started; `<n>` is one more than the largest version there
(`lean/Editor/PackageSet/Layout.lean`). At most two versions are kept per
core, about 420 MB each, plus the running editor's own when it is older.

### The package commands

The default package `package-set`
(`packages/package-set/PackageSet/Compiled.lean`; a package of the core's
Lake package until the features-as-packages roadmap's phase 8, and still
registered right after `restore`) registers `:package-install <name>
<path>|<git url> [<rev>]` or `<scope>/<name> [<version>]`,
`:package-remove <name>` and `:package-update [<name> [<rev>]]`. Each edit
("The lakefile's edits") is computed from the lakefile as the last reload
read it, and written by the job `package-edit`, which reads the file again
first and refuses one that changed since ("the lakefile changed since the
last reload; :reload and try again"); its command then asks for a reload,
which compares the fingerprints and starts the build. `:package-update`
with no rev edits nothing: the lakefile names what is required and the
manifest pins the revision, so it starts the build with `lake update` for
the named package, or every git and Reservoir one. A lakefile without the
core's require at its root, last (an older editor's, which requires the
set alone), is first repaired instead (`repair`, the commands' one
composition with an edit that changes nothing), and nothing is updated:
`lake update` on it would resolve a git core a package names, cloning it,
before the build's core check refused it, and leave the lakefile as it
was. Its line says to run `:package-update` again.

A config file named `Config/EditorPackage.lean` would be taken as the
`config` package's entry module and linked; nothing refuses it yet.

## What a package may import

The core's API is the set of core modules a package may name in an `import`
line. It is defined by a rule over the module map, and each row of the map
says which side of the rule its modules are on.

This is the rule of what a package imports of the core. Beside it holds
the three-layer rule ([extension-points.md](extension-points.md), "Three
layers"), built in features-as-packages phase 1: the core imports no
package, and no package, interface or implementation, imports a module of
an implementation package; a package may import interface packages. A
package is an interface package when its lakefile declares
`keywords = ["editor-interface"]`, and an implementation package
otherwise. The rule holds for every module of a package, its tests
included. The twenty-five default packages are implementation packages:
each imports the core and, but for `mode-line`, `shipped-themes`,
`languages`, `restore` and `package-set`, one or more interface packages,
its own or another's ("The module map", below, lists each one's
`require`s). The eighteen interface packages import the core alone, but
for `ex-api`, whose contract names `shell-api`'s `shell-command`, and
`project-api`, which names `compile-api`'s listing job.

- **A package may import any core module that is not internal.** The rule
  is about `import` lines. Lean's imports are transitive, so a module an
  importable module imports is visible to the package's code whether or not
  the package may name it; what the rule limits is what a package depends
  on by name, which is what a later rename or move can break.
- **The core's interface library is part of the API**, though the
  core's Lake package holds it outside `Editor`: `FilesApi`, importable
  by every module of a package, library or test. It is a core interface
  for good: session restore, a core module, adopts files and reads the
  load limit through it. `BuffersApi` and `ShellApi` were staged beside
  it until ex, which reached them, moved out (phase 8), and are the
  interface packages `buffers-api` and `shell-api` since
  (`packages/buffers-api/`, `packages/shell-api/`). `ProjectApi` and
  `VcApi` were on the list until no core module imported them, and left
  it when they moved
  into interface packages of their own (features-as-packages phase 6,
  `packages/project-api/`, `packages/vc-api/`), whose modules the layer
  imports check allows as any interface package's. The list is named,
  never derived: a library staged in the core is added to it by hand.
  Their test libraries are test doubles and the linked support under them
  is of the linked test kit (below).
- **A package's tests may also import the core's test doubles**: the pure
  models of the ports (`….Model`), the contracts and cases (`….Contract`,
  `….Cases`), the fakes (`Editor.Completion.Fake`, `Editor.Job.Fake`), the
  test scheme (`Editor.InputScheme.Test`), the loop's driver
  (`Editor.Loop.Driver`), the reading of what a package registers
  (`Editor.Config.Packages`: `Package.registered`,
  `Config.State.ofPackages`), the theme picture check
  (`Editor.Theme.Picture`), and the core's model test kit, `Editor.Test`
  and every module under it but `Editor.Test.Linked`: the support the
  core's own model tests are written on (`Editor.Test.…`, 20 modules); and
  a feature's test kit in the core (`Editor.….Kit`; there is none since
  every feature moved out with its kit); and the
  test library of the core's interface library (`FilesApiTest`: its fake,
  contract check and support; `BuffersApiTest`, `ShellApiTest`,
  `ProjectApiTest` and `VcApiTest` were here until their libraries moved
  to `packages/`) but what
  is under `<I>Test.Linked`. A package's tests are the modules under
  `<P>Test`.
- **A package's linked test may also import the linked test kit, and only
  it**: `Editor.Test.Linked` and every module under it (4 modules), the
  rig of the core's checks over the real services, and the linked support
  of a core interface's test library, `<I>Test.Linked` and every module
  under it (such as `VcApiTest.Linked.Repositories`, the repositories
  over the real job runner). The linked test is the
  root `<P>Test.Linked` and the modules under it, `<P>Test.Linked.…`,
  which that root imports and no other part of the package's tests does.
  A plain test module is refused the linked kit, and so is a library: the
  kit runs over the Rust library, which the package's test driver does
  not link, and it hands over the loop, the real bindings of the ports and
  the raw bindings, which the rule refuses a test by name. So what reaches
  a package's model tests through a kit module is the models and the
  loop's driver, and what reaches the real library is confined to the one
  executable linked with it.
- **The kit is the core's test support as it is, published.** A test
  written on it uses the loop's key table and the registry's types, and a
  linked test the real services, which the kit's modules hand it by
  importing them: the package names none of them in an `import` line,
  which is what the rule limits. A kit with a surface that hides them, and
  that exposes no raw binding and no real binding's name to a package, is
  later work, filed as the task `package-test-kit-surface`.
- **The root of a package's linked test may import a little more, and
  only it**: the real bindings of the ports (`….Real`), the headless host
  (`Editor.Headless`) and the config base (`Editor`). The module `<P>Test.Linked` is an
  executable's root, linked as the editor is, and running a port against
  the library or a host over a set's packages is what it is for. The raw
  bindings (`Editor.Ffi…`), the loop and the rest of the config session
  stay refused to it, as do the window hosts' real modules. A harness that
  hid the host from the linked test would be a new mechanism; none is
  built. **A module under `<P>Test.Linked` is not the root**: beyond the
  linked test kit it has a test's allowance and no more, so a check that
  starts a host is written in the root (`GreetingTest.Linked`,
  `CompileTest.Linked`).
- **Internal modules** are those that exist to run the editor and not to be
  written against:
  - the hosts and the executable's modules (`Editor.Main`,
    `Editor.Headless`, `Editor.Headless.CommandLine`, `Editor.Window`,
    `Editor.Window.Real`, `Editor.WindowCheck`, `Editor.WindowCheck.Real`,
    `Editor.Executable`, `Editor.Version`, `Editor.ModuleLookup`), with
    what a host is made of and driven by: the editor queue as a port
    (`Editor.Headless.Queue`), the host stepped on its caller's thread
    (`Editor.Headless.Stepped`), a driver's wait, judged
    (`Editor.Headless.Wait`), and a host's activity count
    (`Editor.Job.Activity`). The stepped host runs the loop's turn and
    hands over raw events, as the headless host it wraps does. The other
    three are pure, and only the hosts, the queue's binding and contract,
    the job runner and the core's own tests import them. A package's
    tests are stepped and waited for through the kits
    (`Editor.Test.Linked.Host` imports the stepped host, and a wait's
    outcome reaches a test through it), so no package names one of the
    four in an `import` line and the rule takes nothing from a package's
    tests. The root of a linked test, which may import the headless host,
    is refused these too: the linked kit starts its stepped hosts;
  - the loop and its dispatch (`Editor.Loop`, `Editor.Command.Dispatch`,
    `Editor.Event.Queue`, `Editor.State.Outbox`);
  - the config session (`Editor.Config.*`, but for `Editor.Config.Packages`,
    a test double);
  - the raw bindings (`Editor.Ffi`, `Editor.Ffi.*`);
  - the real bindings of the ports and what runs them (`….Real`,
    `Editor.Clipboard.InProcess`, `Editor.Display.Recorder`,
    `Editor.Job.Runner`, `Editor.Job.Jobs`, `Editor.Job.Table`,
    `Editor.Job.Pool`);
  - `Editor.Core`.

  A test double is asked about first, so a kit module is importable by a
  test whatever its own name would otherwise make it.
- **The internal namespace is `Editor.Internal`.** A core module that no
  package may import is created under it from now on, so that its name
  says so. The modules listed above are internal today under older names
  and keep them: renaming about 84 modules moves their mirrored test
  modules and every path the documents cite, and is filed as a task of its
  own (`internal-namespace-rename`).
- **`Editor`, the config base, is not part of the API.** A package imports
  the modules it uses, not the base. Nor is any module of the core's Lake package that is
  not named `Editor.…`, such as the core's own test modules (`ModelTest.Check`
  among them), but for the core's interface libraries and their test
  libraries, above. The root of a linked test alone names the base,
  above.
- **The package imports check enforces the rule**
  (`tools/package-imports-check.sh`, in `mise run ffi-test`;
  [the-gate.md](../dev-practices/the-gate.md), "The package imports
  check"). It asks Lake for each direct import of a core module by a
  module of a set's packages, with whether the importing module is the
  package's library's, a test's, the linked test's root or a module under
  that root (the kinds `library`, `test`, `linked` and `linked-test`;
  `lake -d <set dir> query :editorPackageImports`), and refuses the ones
  the rule does not allow, each with its reason. It lists the modules of
  each of a package's libraries, so a library's globs must hold every
  module of it ("A package's tests and the gate's steps over them",
  above). **The lists are in the script**: the core's interface
  libraries, the test doubles, the linked test kit, the internal modules,
  and what the linked test's root may import beyond them, as names and
  patterns. No module lists the rest of the API: a core module named
  `Editor.…` that is neither internal nor a test double is part of it. A change to the rule changes the script, this section and the
  lines the gate holds the script to (`tests/package-imports/`).
- **The layer imports check enforces the three-layer rule**
  (`tools/layer-imports-check.sh`, in `mise run ffi-test`;
  [the-gate.md](../dev-practices/the-gate.md), "The layer imports check").
  It asks Lake for each direct import between workspace modules by a
  module of the core or of a set's packages, with the layer of each side
  (`lake -d <set dir> query :editorLayerImports`), and refuses a core
  module importing any package and a package importing an implementation
  package.

Checked against the graph at `6ba99de5`, before either feature moved:
every core module the two features' modules imported directly was
importable. The compile mode's modules imported
`Editor.Api`, `Editor.Command.Call`, `Editor.File`, `Editor.Json`,
`Editor.Mode`, `Editor.Package`, `CompileApi`,
`CompileApi.Format`, `CompileApi.Listing`, `Editor.Shell`
and `Editor.Workspace.Modes`; the shipped palettes' import `Editor.Face` and
`Editor.Package`. `Editor.Themes.Check`, the completeness check the
palettes' tests run, is importable. After each move the package's library
imports exactly those: `lake -d ../packages query :editorPackageImports`
lists the same eleven for `compile` and the same two for
`shipped-themes`.

**The compile mode's tests imported internal modules** while they were
the core's, which the rule does not allow a package's tests:
`Editor.Command.Dispatch`, `Editor.Command.Real`, `Editor.Config.Elaborate`,
`Editor.Config.Registry`, `Editor.Config.Session`, `Editor.Config.Stores`,
`Editor.Display.Recorder`, `Editor.Ffi.Processes`, `Editor.Ffi.Snapshot`,
`Editor.Job.Runner`, `Editor.Loop` and `Editor.Text.Real`, and the core's
own test support (`ModelTest.Support.…`, `ContractTest.Support.…`). The
rule was not widened to allow those. Phase 6 published the support as the
test kit and the tests stopped naming the rest ("What moving the compile
mode added to the core's API", below).

**The core's tests do not name the compile mode**, and could not: it is
another Lake package, which the core does not require. Phase 3 had made
that so while it was still under `lean/Editor/`: the listing's checks
build their host from core packages' commands and jobs
(`packages/compile-api/CompileApiTest/Listing.lean`), the contribution and the format data
have checks of their own (`CompileApiTest.contributionChecks`,
`CompileApiTest.formatDataChecks`), and what the compile mode makes of them is
checked in its own test modules, which moved with it. The three test
modules outside the compile mode's own that still named it then went as
follows:

- `ModelTest.Support.Compile`, the compile checks' own support, moved with
  them (`packages/compile/CompileTest/Support/Compile.lean`);
- `ConfigTest.Editor.Headless`, which holds `ConfigTest.shippedChecks`,
  then the test of the core's list as the executable's hosts registered
  it, stated that the list held nothing of the compile mode (until the
  list emptied in phase 8 and that check went with it);
- `ContractTest.Support.Projects`, the rig of the project-mode contract
  checks over the real services, registered the compile package, and
  three version-control contract checks built on it. The rig is the linked
  test kit's now (`lean/Editor/Test/Linked/Rig.lean`), its default keys and
  jobs the files' and the workspace's alone, and the compile mode's checks
  pass their own.

**The core's tests do not name a shipped palette either.** Five test
modules of core modules used a palette as their fixture theme
(`ModelTest.Editor.Appearance`, `ConfigTest.Editor.ExecuteCommand`,
`.Themes`, `.Themes.Check` and `FfiTest.Editor.ExcerptView`). Phase 5 gave
each a theme of the core's own before it moved the palettes: the excerpt
picture is drawn in the built-in theme, the three config tests share
fixture themes made with `Palette.theme` from palettes written in
`lean/ConfigTest/Support/Themes.lean`, and the appearance checks define
theirs. No copy of a palette's values is kept in the core, so no licence
notice is either. `ConfigTest.shippedChecks` and
`ModelTest.packageSetChecks` stated the core's list alone while the core
had one (their checks of it went with the list in phase 8): 7 packages
after the features-as-packages roadmap's phase 7 (9 after its phase 6, 17 after its phase 4,
20 after its phase 3, 24 when the palettes moved), no theme (the theme
`default` is the themes package's since phase 7), and nothing of evil, the themes, the
compile mode, the mode line, the command prompt, the binding search, the
languages, the completion styles and displays, completion at point, the
minibuffer, or the seven features of phase 6.

## What moving the shipped themes added to the core's API

The packages roadmap's phase 5 moved the palettes into a package that
imports only what the rule above allows. The rule and the core changed in
three places for it, and each is in the lists of
`tools/package-imports-check.sh`. Read against the import lines Lake
prints for the package (`lake -d ../packages query :editorPackageImports`,
in `lean/`):

| Addition | What it is | Who may import it | Why the move needed it |
|---|---|---|---|
| `Editor.Config.Packages` | An existing module, reclassified from internal to a test double: `Package.registered` and `Config.State.ofPackages`, which read what a package registers | A package's tests | `ShippedThemesTest.shippedThemesChecks` checks that the package alone is accepted and registers its three themes and nothing else. `lean/Editor/Package.lean` already named it as how a test reads a package; the fixture packages' tests use it the same way |
| `Editor.Themes.Picture` | A new core module, a test double: the theme picture check, with the helpers it reads pictures with | A package's tests | The palettes' reference pictures moved with them. Drawing one goes through the raw bindings (`Editor.Ffi.…`), which no package may import, so the scenario became a core module that takes the themes as an argument. The core runs it on `default` |
| The linked test's allowance | Not a module: the root of a linked test, `<P>Test.Linked`, may import the real bindings of the ports, the headless host, the config base and the core's entry module | The linked test's root alone | The check arrived with this phase and had to say what an executable linked as the editor is may name. `shipped-themes`' own linked test uses none of the allowance; the fixture package `greeting`'s uses all of it |

- **Nothing was added to what a package's library may import.** The
  palettes import `Editor.Face` and `Editor.Package`, which were API
  already.
- **`Editor.Themes.Check` was importable already**: the completeness
  check, `Themes.problems`, which the package's tests run on each theme,
  is a module of the feature `themes` that a package may import, and the
  move changed nothing about it.
- **`Editor.Appearance`, `Editor.Scene` and `Editor.TabBar`**, which the
  package's tests import, were API already.
- **What the tests stopped importing.** As core tests they imported
  `Editor.Config.Registry`, `Editor.Display.Real`, `Editor.Ffi.Display`,
  `Editor.Ffi.Document`, `Editor.Ffi.Marker`, `Editor.Ffi.Snapshot`,
  `Editor.Ffi.Window`, `Editor.Loop` and `Editor.Text.Real`, all internal.
  The model tests reach the registry through `Editor.Config.Packages`
  alone, and every other one was the picture scenario's, which is in
  `Editor.Themes.Picture` now.

## What moving the compile mode added to the core's API

The packages roadmap's phase 6 moved the compile mode into a package that
imports only what the rule above allows. **Nothing was added to what a
package's library may import**: the compile mode's five modules import the
eleven API modules they imported in the core ("The default package
`compile`", above). What changed is what a package's tests may import, in
two groups of test doubles, and one requirement on a package's lakefile.
Each is in the lists of `tools/package-imports-check.sh`, and the gate
holds the script to lines for them (`tests/package-imports/`). Read
against the import lines Lake prints for the package (`lake -d ../packages
query :editorPackageImports`, in `lean/`):

| Addition | What it is | Who may import it | Why the move needed it |
|---|---|---|---|
| `Editor.Test.…`, 14 modules under `lean/Editor/Test/` | The support the core's model tests are written on, moved from `lean/ModelTest/Support/` into the core's library and the namespace `Editor.Test`: test doubles | A package's tests | The compile mode's ten model lists run the loop's driver over the editor's models, in the worlds of files, workspaces and the shell the core's own tests use. As core tests they imported that support by name (`ModelTest.Support.…`), which is no module of the editor |
| `Editor.Test.Linked.…`, 4 modules under `lean/Editor/Test/Linked/` | The rig of the core's checks over the real services, moved from `lean/ContractTest/Support/`, with a new module for the services themselves: the linked test kit | A package's linked test alone: the root `<P>Test.Linked` and the modules under it. A plain test module and a library are refused it | The compile mode's two lists over the real process service drive the loop over the real text binding and the library's job services. As core tests they imported that rig (`ContractTest.Support.…`) and the raw bindings |
| A library's globs | Not a module: a package's library must hold every module of it, by `globs` when its root does not import them all | A package's lakefile | The facet that lists a package's imports reads each library's modules. Declared by name alone, `Compile` did not hold `Compile.Compiled`, `Compile.Shipped` or `Compile.EditorPackage`, and their imports were not checked |

The model kit, each module with what it holds. The compile package's tests
import nine of them by name (`Driver`, `Files`, `Keys`, `Listing`, `Loop`,
`Models`, `Prompts`, `Shell`, `Workspace`); the other five came because
those import them, and a kit that left them behind would not build.

| Module | What it holds |
|---|---|
| `Editor.Test.Models` | The editor's models, and programs over the ports run on their models |
| `Editor.Test.Keys` | Keys and key maps for fixtures: the keys a key string names, an invocation by name |
| `Editor.Test.Jobs` | Jobs run on the job model and on the runner over its fakes, with a fake clock |
| `Editor.Test.Completion` | Candidates and completion styles written as data |
| `Editor.Test.Geometry` | Rectangles, sample areas and window counts |
| `Editor.Test.States` | Editor states a check starts from: windows, buffers, tabs, open prompts |
| `Editor.Test.Config` | Config fixtures: registered commands, faces, themes, bindings, the loop's context; since phase 6 it names no module of evil (the context's badge face is the vocabulary's `mode-line.state.normal`) |
| `Editor.Test.Loop` | The command loop stepped on the editor's models, with keymaps and commands written in the test |
| `Editor.Test.Driver` | The loop's driver over the editor's models and the job model, and what a check reads back from it |
| `Editor.Test.Files` | The file commands' keys, files and driver |
| `Editor.Test.Workspace` | The workspace a check sees settled, a store for the stores' checks, and since the features-as-packages roadmap's phase 6 the stand-in for the workspace's attach (`attachAt`, `attachPackage found`, and by a directory's answer `attachBy`, `attachByPackage`), and the half of the workspace driver that names no workspace module (`openBindings`, `openCommandsWith`, `openJobs`, `openDriver`, with the stand-in for the finder's answer `openFound`), which the shell's and version control's checks are built on; the workspace's world, finder jobs, commands, keys and driver are the workspace feature's kit (`Editor.Workspace.Kit`) |
| `Editor.Test.Shell` | A shell command's child and its replies on the process model, compiled commands as a driver dispatches them, and what a check reads of a driver; since phase 6 the shell checks' jobs, bindings and commands are the shell feature's kit (`Editor.Shell.Kit`) |
| `Editor.Test.Prompts` | Prompts and the minibuffer: their bindings, registry and driver, over a minibuffer package a check hands in, the kit's own (`Editor.Test.Minibuffer`) when it hands none |
| `CompileApiTest.Listing` (`packages/compile-api/`; `Editor.Test.Listing` in the core until phase 8) | A contribution with a listing, its listings' runs and files, which names core modules only, and since phase 6 the stand-in for modes on markers (`markedPackage`), and the listing checks' stand-ins for the finder's answer and the marker search over the core's rules (`listingFound`, `listingOn`, `listingOpened`, `kubeOpened`, `markersBy`, `markersByPackage`), which the compile package's tests run on; the world it is found in (`listingWorld`, `listingJobModel`) is the workspace package's kit's (`WorkspaceTest.Kit`) |
| `Editor.Test.Sources` | Added in the features-as-packages roadmap's phase 3: the completion sources' contract runner over the editor's models (`sourceRunner`), and the contract's properties over one source as sentences (`sourceHolds`) |
| `Editor.Test.Shipped` | Added in the same phase: stand-ins for the default packages whose data the core keeps, `modeLine` and `languages` |
| `Editor.Test.Minibuffer` | Added in the features-as-packages roadmap's phase 4: a minibuffer written over the core's prompt API, the package `minibuffer` with its nine commands and the mode `Prompt.mode`, and `names`, the nine in registration order; `minibuffer-api`'s fake |
| `Editor.Test.AtPoint` | Added in the same phase: an at-point written over the API's completion at point, the package `at-point` with its nine commands and no source, and `names`; `at-point-api`'s fake |
| `Editor.Test.Ex` | Added in the features-as-packages roadmap's phase 6: the kit's ex line (`exLinePackage`), a stand-in for the `ex` package that registers ex's command from the core's `Editor.Ex` and the ex names files' and the buffers' tests type (`w`, `e`, `autoread`, `b`, `ls`, `bd` and their bang forms) bound to `files-api`'s and `buffers-api`'s names, so those tests drive ex lines with no import of `Editor.Ex.Compiled` |
| `Editor.Test.Modes` | Added in the same phase: the on-enter checks' command `enter` and its invocation (`entersMode`), what it says of a refusal, and the faces the syntax tree model last highlighted (`highlightedFaces`), moved from `ModelTest.Support.Modes` so the files feature's language checks need no core test support |
| `Editor.Test.Excerpt` | Added in the same phase: what a check reads of an excerpt buffer (`excerptBufferNamed`, `excerptRead`, over any scheme's driver), the commands of the excerpt buffer checks and what runs one and reads its view (`excerptRegistrations`, `excerptInvoked`, `excerptFed`, `lastView`, `blockedSeen`, added in phase 7 so that evil's checks of `u`, `C-r` and its scroll commands in an excerpt buffer start from the buffers the core's checks do), and the stand-in for a project search's results (`excerptFiles`, the command `excerpt-files`), which names no module of evil or of project search |
| `Editor.Evil.Kit` | Added in the same phase, evil's feature kit (`Editor.*.Kit`): the driver of evil's checks under the Vim scheme that ships (`EvilDriver`, `evilDriver`, `evilHanded`, `evilFed`, `evilShown`, over the core kit's bar fixtures, `Editor.Test.Editing`), which the working sets' and the workspace's tests use until phase 7 moves it with evil |
| `Editor.Test.Editing` | Added in the features-as-packages roadmap's phase 7: the kit's editing commands (`editingCommands`, `editingKeys`, `editingDispatched`, `editingBindings`, `editingPackage`), a stand-in for the editing commands an input scheme's package registers, over the core's API alone and for the test scheme: `self-insert`, `edit-newline`, `edit-delete-backward`, `edit-delete-forward`, the moves `edit-left`, `-right`, `-up`, `-down`, `-line-start`, `-line-end`, `-buffer-start` and `-buffer-end`, `edit-select-left`, `-right`, `-up` and `-down`, and `edit-undo` and `edit-redo`, on keys that print nothing. A test whose subject is not a scheme edits with these and drives no key of evil's. With them, a driver of the test scheme over a state a fixture writes with its cursor as a bar (`editingDriver`, `barred`, `barState`), and what a check feeds a driver of any scheme and reads back of it in that notation (`keysFed`, `selectionOf`, `shownOf`, `withBar`), which evil's kit is written on |
| `Editor.Test.Views` | Added in the same phase: views as the loop publishes them and the rows the display model answers for them, moved from the core's `ModelTest/Support/Views.lean`, `ModelTest/Support/Display.lean` and `ModelTest/Editor/Loop.lean` and made of any scheme: texts of numbered and of wrapping lines (`numbered`, `wrapping`, `ragged`), the display model over a text and its rows (`displayOver`, `onDisplay`, `areaOf`, `rowsFrom`, `allRows`, `rowAt`, `startOf`), the scroll margin as a property of those rows (`marginHolds`), a state of one window in a frame a few rows tall (`viewState`, `frameAround`), a resize fed to a driver (`viewResized`), a released snapshot (`releasedSnapshot`), and what the last scene shows of a view (`ViewSeen`, `seenIn`, `viewSeen`, `viewRan`, `viewPlaced`, `keyTimes`). The loop's checks of a view that follows its cursor read it under the test scheme, and evil's scroll checks under the Vim scheme |

The linked kit:

| Module | What it holds |
|---|---|
| `Editor.Test.Linked.Jobs` | Jobs on the real runner: how long a check waits, a job's outcome as a check compares it |
| `Editor.Test.Linked.Trees` | Temporary directories of a check's own, and files written into them |
| `Editor.Test.Linked.Host` | Hosts over the real elaborator, as the config tests start them: the context a harness is handed (`HostContext`), config text, a stage and what compiled code hands it, a session and what it printed, polling with a bound, the elaborator shared by a process's hosts (`sharing`), and since features-as-packages phase 6 the context a package's linked root runs its checks in (`HostContext.run`) and the table of waits its hosts and rig share (`HostContext.fileWaits`). Its hosts take their packages as an argument: it imports neither the config base nor `EditorCore.EditorPackage` |
| `Editor.Test.Linked.Bench` | Added in features-as-packages phase 6: what a benchmark of a feature's command over the real services needs and may not import itself: the rows its latencies are reported in (`Row`, with the bounds the job system and the prompts were accepted against), the job pool warmed as the editor warms it (`warmPool`), and a headless host of the test scheme over the real services, in its bracket (`withBenchHost`, which was `benchHost` until the deterministic-test-concurrency roadmap made it a bracket that ends the host). The config benchmarks and the workspace finder's (`WorkspaceTest.Linked.WorkspaceBench`) are written on it |
| `Editor.Test.Linked.Listings` | The styles and the display every stage of `Editor.Test.Linked.Host` hands its host (`listingsPackage`), written for the tests |
| `Editor.Test.Linked.Keys` | Keys typed into a host's session (`Session.type`, `.typed`, `.pressKeys`), a binding of them, and the test scheme's role keys |
| `Editor.Test.Linked.Lines` | What a host's printed scene lines say: a view's line and its status line, whether a view line shows a text and one selection (`showsText`, moved here in phase 7 from the config tests' indent checks, which evil's linked tests and the core's both read), a prompt's, a list view's, and the library matcher's order |
| `Editor.Test.Linked.Shipped` | A host made as the executable's are (`withShippedHost`, of the input scheme it is given and handed the harness's packages, `HostContext.packages`, unless a check hands others), and the real syntax binding with its requests recorded |
| `Editor.Test.Linked.Vim` | Added in phase 7, evil's: `withVimHost`, `withShippedHost` of the Vim scheme that ships. The one module of the linked kit that names a module of evil; it moves into evil's linked test support when evil becomes a package |
| `Editor.Test.Linked.Syntax` | Added in phase 7: the real syntax tree binding as a package's linked test reads it with no host: the capture names of a query the library ships (`shippedCaptureNames`), and a text of a source whose tree the binding keeps, over which a check runs commands of the editor's API, each question waiting for the tree of the last edit (`SyntaxText`), which a module under a linked root may not build itself (the real bindings are its root's alone). Evil's checks of the tree's text objects over the binding, moved from `contract-test`, are written on it. And the Rust indent fixture as the indent checks read it (`indentKept`, `mangledRust`, moved from the config tests' indent checks), for evil's linked tests and the core's |
| `Editor.Test.Linked.Frames` | Added in phase 7: a host that draws on the display's real binding over the library's layout, handed to a check with the frames it compares (`withFramedHost`): the host's frame of the last scene it published, and the frame a second display over the same snapshots lays out of that scene in a theme the check writes. The themes' linked check of a theme switched by its command is written on it: a module under a linked root may import neither the real bindings nor the raw ones |
| `Editor.Test.Linked.Rig` | The loop over the real services, as a check drives it: its jobs, commands and keys, runs settled until every job has run, and a child's `PATH` |
| `Editor.Test.Linked.Services` | New: the library's real job services over one table of waits, that table with the completion pump started, the shutdown, and how many children are not yet reaped. `contract-test`'s `main` held the first three inline, and the compile checks read the last from the raw binding |

- **The rig names no feature outside the core.** Its default keys and jobs
  are the file commands' and the workspace's, with no contribution told to
  the loop. It held the compile mode's too, and three version-control
  contract checks reached the compile mode through it. The compile mode's
  checks pass their own keys and jobs now, built from what the rig hands
  out (`rigCommands`, `rigJobs`) and the package's registrations.
- **What the tests stopped importing.** The model tests named
  `Editor.Loop`, `Editor.Command.Dispatch`, `Editor.Config.Registry`,
  `Editor.Config.Stores`, `Editor.Config.Owner` and `Editor.Ex.Compiled`;
  the two lists over the real services also `Editor.Command.Real`,
  `Editor.Display.Recorder`, `Editor.Ffi.Processes`, `Editor.Ffi.Snapshot`,
  `Editor.Job.Runner` and `Editor.Text.Real`, and through the old rig
  `Editor.Files.Compiled` and `Editor.Workspace.Compiled`. All are
  internal. Each import line went, and the names the tests still use of
  them come with the kit's modules. `Editor.Config.Elaborate` and
  `Editor.Config.Session` were the config test's
  (`ConfigTest.compileConfigChecks`), which did not move as code: it drove
  the config session's internals. Its two facts are held by the package's
  fixture `config`, that a real config written on the package's
  declarations elaborates, and by two checks of
  `CompileTest.compileHookChecks`, of what the hook makes of those
  registrations.
- **The linked test's root uses the allowance phase 5 settled**:
  `CompileTest.Linked` imports `Editor` and `Editor.Headless` for its
  check of a host (and imported the core's entry module while the core
  had one), and
  `Editor.Test.Linked.Services` for the services and the shutdown, so it
  names no raw binding.
- **The core's own tests are written on the same modules**: `model-test`
  and `contract-test` import the kit from its new place, with no copy.
  `Editor.Core` imports the kit, so it is in the core's closure and the
  core imports check's second rule holds of it.
- **Rejected**: allowing `ModelTest.Support.…` by name, which would widen
  the rule past the modules of the editor; copies of the support in the
  package, which would be two definitions of the shell's and the files'
  worlds; and rewriting the tests on a new, narrower harness, which would
  have changed about 2,400 lines of checks that the move had to leave as
  they were.
- **The cost, and what is filed.** The kit is wide: it is the support as
  the core's tests need it, and a package's test written on it depends on
  the loop's key table and the registry's types by name, if not by import
  line. Narrowing it to a surface that hides them is the task
  `package-test-kit-surface`.

## What moving the four features added to the core's API

The features-as-packages roadmap's phase 3 added nothing to the API: each
moved library imports API modules only ("The default packages of the
features-as-packages roadmap's phase 3", above). It added two modules to
the model test kit (16 modules where there were 14), each imported by
`Editor.Core`, as the core imports check's second rule requires:

| Addition | What it is | Who imports it | Why the move needed it |
|---|---|---|---|
| `Editor.Test.Sources` | `sourceRunner`, moved unchanged from the core's `ModelTest/Editor/Completion/Contract.lean`, with `sourceContract`, `answersSomething` and `sourceHolds` over it | `ModelTest.sourceContractChecks`; the command prompt's and the binding search's tests | Their sources were held to the completion sources' contract by the core's test, which could not keep naming them once they moved; their own lists run the contract on the same runner, under the same sentences |
| `Editor.Test.Shipped` | Two `Package` values named `mode-line` and `languages` that register the core's own data (`ModeLine.shipped`; `Language.modes`, then `Language.shipped`), and both as `packages` | The core's tests that host the core's list as the default editor (`ConfigTest.shippedPackages`, `FfiTest.shippedPackages`, `Editor.Test.Linked.Host`, `ConfigTest.Bench`) and the compile mode's linked test | Those tests show what the default editor draws, its segments and its languages, and the core cannot import the packages that register them. They are no fake of another package's behaviour: the data and its names are the core's, and the packages register exactly that, which their own tests pin |

## What moving the completion, at-point and minibuffer features added to the core's API

The features-as-packages roadmap's phase 4 added nothing to what a
package's library may import: each moved library imports API modules only
("The default packages of the features-as-packages roadmap's phase 4",
above). It added values to three API modules, so that the core's loop,
dispatch, registry and hosts no longer import a module of the three
features, and two modules to the model test kit (18 modules where there
were 16), each in `Editor.Core`'s closure, as the core imports check's
second rule requires (`Editor.Test.AtPoint` imported by it,
`Editor.Test.Minibuffer` through `Editor.Test.Prompts`):

| Addition | Where | What it is | Why the move needed it |
|---|---|---|---|
| `Completion.Style.unregistered`, `Completion.Matching.unregistered` | `lean/Editor/Completion/Style.lean` | The core's own style, `ranked`: the fuzzy port's ranking (`Fuzzy.rank`, a core port) with no ranges, owned by `compiled` and registered by no package; and the matching of a loop told of no registry, which matches every prompt with it | The loop, the dispatch and the registry fell back to the shipped `fuzzy` (`Matching.standard`, `Styles.fuzzy`), a module of `completion` |
| `Completion.Display.unregistered`, `Completion.Displaying.unregistered` | `lean/Editor/Completion/Display.lean` | The core's own display, the interface's model `Display.plain "plain"`, owned by `compiled`; and the displaying of a loop told of no registry | The same, for the shipped `minibuffer` display (`Displaying.standard`, `Displays.minibuffer`) |
| `Completion.Style.unknown`, `Completion.Display.unknown` | the same two modules | The install report's text for a name no style or display is registered under, moved from `Completion.Styles.unknown` and `Completion.Displays.unknown`, the same text | The config session and the headless host say it |
| `Completion.AtPoint.triggeredCommand`, `.pausedCommand`, `.noCompletions` | `lean/Editor/Completion/AtPoint.lean` ("The names the core runs") | `at-point-triggered`, which the loop runs when a typed character is a source's trigger; `at-point-paused`, which the headless host and the loop's driver run when a pause fires; and the echo `no completions`, which the loop says | The loop imported `Editor.AtPoint` for `AtPoint.triggeredName`, `.pausedName` and `.noCompletions`; an at-point package registers its commands under the two names, which `at-point-api` declares from these |
| `Editor.Test.Minibuffer`, `Editor.Test.AtPoint` | `lean/Editor/Test/` | The kit's own minibuffer and at-point, written over the API's prompt and completion-at-point operations, not copied from the shipped ones; where the shipped one makes a choice of its own they do something simpler | The core's tests answer prompts and open at-point sessions, and the core cannot import the packages; the two interface packages publish them as their fakes |

- **Which style and display a set gets by default.** With no choice made,
  the style registered first, in registration order (packages by
  dependency, then config), looked up by name, so that config's of that
  name is used in its place; the same rule picks the display. With none
  registered, the core's own (`Config.Registry.styleEntry`,
  `displayEntry`; `ModelTest.registryChecks`). In the default set nothing
  changed: `completion` registers first, so `fuzzy` and `minibuffer` are
  still the defaults. Letting a package set the default (`useStyle` in a
  package) was not chosen: it changes what a package may register, for no
  fixture's benefit.
- **Removed**: `Matching.standard`, `Displaying.standard`,
  `Completion.Styles.unknown` and `Completion.Displays.unknown`; and
  `Editor.AtPoint.noCompletions`, whose one caller was the loop.
- **Why names and not an extension point for at-point.** What the loop
  needs of the feature is to run a command at a trigger and at a pause,
  and the registry already resolves a command by its name when it runs
  ([extension-points.md](extension-points.md), "Reaches by name"). Sources,
  styles and displays are records any package registers already.
- **No linked kit module was added.** The completion package's linked
  test runs the fuzzy port's real binding through `Editor.Fuzzy.Real`,
  which the root of a linked test may import.
- **The core's tests' own doubles are not the kit's**: the styles and
  displays written for them (`lean/ModelTest/Support/Listings.lean`,
  `lean/ConfigTest/Support/Listings.lean`) are core test modules, which no
  package imports. (Phase 6 moved the second into the linked kit, as
  `Editor.Test.Linked.Listings`, with the hosts that hand it, and phase 8
  the first into the model kit, as `Editor.Test.Listings`, when the ex
  line's tests, which match and draw their prompt's listing with it,
  moved out.)

## What moving the files cluster added to the core's API

The features-as-packages roadmap's phase 6 moved into the core what the
seven used only of the core, so that no moved library imports another and
no core module imports a moved one:

| Addition | What it is | Who uses it |
|---|---|---|
| `Editor.Text.Word` (`lean/Editor/Text/Word.lean`) | The word under the cursor over the text port: a line's cells (`Word.cells`), blanks and word characters (`isBlank`, `isWord`), the word under the cursor (`underCursor`), its whole-word pattern (`wholePattern`) and Vim's E348 (`noneUnderCursor`); evil's six names are defined from these | evil's `*` and `#`; project search's `project-search-symbol` |
| `Workspace.SearchRoot`, `Workspace.searchRoot` (`lean/Editor/SearchRoot.lean`) | What a search covers: the root, its label, the text typed after a location and the workspace, from the buffer, the call's arguments and the command's name | project search; the workspace's `FindFile.searched`, which adds its lister |
| `Workspace.typedOf`, `noSuchWorkspace`, `cannotList` (`lean/Editor/Workspace.lean`) | The text typed after a location, and the two refusals a search says | the same |
| `Workspace.onModesOf`, `Workspace.turnOnModes` (`packages/compile-api/CompileApi/Listing.lean`) | A buffer's on-modes on markers, and turning them on: the value `modesLocal`, the minor modes farthest first, the listings refreshed | the workspace's mode marker search; the kit's stand-in for it (`Editor.Test.markedPackage`) |
| `Jumps.Go` (`lean/Editor/Jumps/Go.lean`), a core module now | Going to a place: a file's case visits it through `FilesApi.files?` with `record := false`, and says `FilesApi.noImplementation "jump"` with none | evil's jumps and marks; project search's visit |
| `FilesApi.Files.visit`'s `record` flag, and `FilesApi.notOpened` | Whether a visit records a jump, and the text files says of a load it refused | every visit but `Jumps.go` passes `true`; the compile mode's tests |
| `ShellApi` (`packages/shell-api/ShellApi.lean`, an interface package since phase 8; `lean/ShellApi.lean`, staged, until then) | The shell's names (`commandName`, `filterName`, `interruptName`, `names`, `noCommand`) and its history (`Editor.Shell.historyStore`, `remember`, `Scope`, `history`, `record`), with a fake and a contract | ex hands a `:!` line to the shell by name and its prompt offers the history; the compile mode copies a scope's history |

And to the core's test kit, each imported by `Editor.Core`:

- **`Editor.Test.Excerpt`**: what a check reads of an excerpt buffer, and the
  stand-in for a project search's results (`excerptFiles`), so the working
  sets' tests name no project search;
- **`Editor.Evil.Kit`**: evil's driver under the Vim scheme, which the working
  sets' and the workspace's tests use until evil moves;
- **`Editor.Test.Linked.Host`**: the config harness's hosts, published for a
  package's linked root (`HostContext.run`), and **`Editor.Test.Linked.Bench`**,
  the benchmarks' rows and host;
- **the halves left of `Editor.Test.Workspace`, `.Shell` and `.Listing`**:
  the stand-ins for the workspace's attach (`attachAt`, `attachPackage`,
  `attachByPackage`, `openFound`, `checkoutFound`) and the open driver
  (`openBindings`, `openCommandsWith`, `openJobs`, `openDriver`), the
  shell's child and replies, and the stand-ins for modes on markers and
  the marker search (`markedPackage`, `markersBy`, `markersByPackage`); the
  halves that named a feature are its package's kit
  (`WorkspaceTest.Kit`, `ShellTest.Kit`, `FilesTest.Kit`);
- **the opener's point, record and language**: the kit's opener
  (`Editor.Test.Opener`) loads a file at the point a visit asks for,
  records a jump only when asked, and opens it in the language the core's
  `languageOf` chooses, as files does, so `files-api`'s contract holds of
  the fake and of `files`.

## What moving evil and themes added to the core's API

The features-as-packages roadmap's phase 7 gave the core what a scheme's
package and its tests need of it, so that no core module, and no other
package, names a module of evil or of the themes:

| Addition | What it is | Who uses it |
|---|---|---|
| `SchemePackage`, `SchemePackage.chosen?`, `SchemePackage.noneInstalled` (`lean/Editor/InputScheme.lean`) | The scheme a package supplies, as a name and an `InputScheme`; the one an editor runs of those its set supplies, the last; and the refusal's text | a scheme package's entry module (`scheme`); `Editor.Main.run`; "Input schemes", below |
| `Executable.Mode.needsScheme` (`lean/Editor/Executable.lean`), and `Editor.Main.run`'s `schemes` | Which modes run a scheme (headless, window, probe), and the schemes the generated root hands `run` | the executable's entry; `ModelTest.executableModeChecks`, `schemePackageChecks` |
| The hosts' scheme argument: `Headless.shippedOver`, `.shipped`, `.main`, `Window.host`, `.main` take `(scheme : InputScheme)` first | A host is typed by the scheme it is handed and names none | `Editor.Main.run`; every linked root and the linked kit |
| `InputScheme.cursorFaces`, with the contract's `SchemeContract.cursorFacesReported` and `SchemeContract.failsOnly` (`lean/Editor/InputScheme/Contract.lean`) | The faces a scheme draws a cursor in, other than `cursor`, held to its reports; and a contract run that says which properties alone fail | the theme completeness check; evil's `vimContractChecks` |
| `Face.Entry.cursor`, `Face.cursorNames` (`lean/Editor/Face/Vocabulary.lean`) | The vocabulary marks its cursor faces | `Themes.problems`' default; the shipped palettes' tests; evil's `vimDefaultChecks` |
| `Editor.Theme.Check`, `Editor.Theme.Picture` (were `Editor.Themes.Check`, `.Picture`; the namespaces `Editor.Themes` and `Editor.Themes.Picture` are kept) | The completeness check, `Themes.problems theme (cursors := Face.cursorNames)` with `Themes.cursorFaces scheme`, and the picture check, which takes its faces' names; neither names a Vim state | the shipped palettes' tests; the core's `cursorResolutionChecks` and `pictureChecks` |
| `Editor.Clipboard.cutName`, `copyName`, `pasteName`, `selectAllName` (`lean/Editor/Clipboard.lean`) | The names of the Edit menu's clipboard items, which a scheme's package registers commands under | the menu (`Editor.Menu.Compiled`); evil's clipboard commands and run tables |
| `WindowCommands.names`, `TabCommands.names` | Every name the window and the tab commands register | evil's `vimDefaultChecks`, which holds its tables' rows to them |
| The config base's imports by name: `Editor.Indent`, `Editor.Jumps.Go`, `Editor.Text.Word`, `Editor.UndoTree.Theorems`, `Editor.Vocabulary` (`lean/Editor.lean`) | Core modules only evil's modules brought into the base | config of a set without evil |
| The model kit's `Editor.Test.Editing` | A stand-in for a scheme's editing commands on the test scheme, over the core's API: `self-insert`, `edit-newline`, `edit-delete-backward`, `edit-delete-forward`, `edit-left`, `-right`, `-up`, `-down`, `-line-start`, `-line-end`, `-buffer-start`, `-buffer-end`, `edit-select-left`, `-right`, `-up`, `-down`, `edit-undo` and `edit-redo`, on keys that print nothing (`editingCommands`, `editingKeys`, `editingBindings`, `editingDispatched`, `editingPackage`); the fixture notation of a cursor written as a bar (`barred`, `withBar`, `barState`, moved from evil's kit); and a driver over a fixture with what a check reads of it (`editingDriver`, `keysFed`, `selectionOf`, `shownOf`) | the core's tests that typed Vim keys; packages' tests (at-point, the working sets, files' linked test) |
| The model kit's `Editor.Test.Views` | What a scene shows of a view, asked of the driver's models: `viewState`, `viewSeen`, `viewRan`, `viewPlaced`, `marginHolds` and the rest, of any scheme | the loop's `viewChecks`; evil's `evilScrollChecks` |
| Additions to the model kit's modules | `Editor.Test.Excerpt`: `excerptStamp`, `excerptRegistrations`, `excerptInvoked`, `excerptFed`, `lastView`, `blockedSeen`; `Editor.Test.Modes`: `jsonIndents`; `Editor.Test.Files`: `jumpsPath`, `jumpFiles`; `Editor.Test.Ex`: `exLinePackage` | the core's excerpt and jump checks; evil's undo, scroll, indent, jump and mark checks |
| The linked kit's `withShippedHost (scheme : InputScheme)` (`Editor.Test.Linked.Shipped`, which also holds `rustObjectsText`) | A host made as the executable's are, of the scheme it is given; it replaces a host that named the Vim scheme | every linked test; evil's `withVimHost` is `withShippedHost Vim.Default.scheme`, in evil's tests |
| The linked kit's `Editor.Test.Linked.Syntax` | The real syntax binding as a check observes it with no host: `shippedCaptureNames`, `SyntaxText.over` and `.run`, `indentKept`, `mangledRust` | the core's `indentChecks`; evil's `evilIndentChecks` and `treeObjectFixtureChecks` |
| The linked kit's `Editor.Test.Linked.Frames` | `withFramedHost`: a host on the real display, with the frame a second display lays the same scene out in under a given theme | the themes' linked `themeChecks` |
| `Session.hints` (`Editor.Test.Linked.Host`), `showsText` (`Editor.Test.Linked.Lines`) | A scene's key hint lines, and whether a view line shows a text with a selection | the core's keymap and indent checks; evil's `evilLeaderChecks` and `evilIndentChecks` |

Nothing was added for another package to reach evil or the themes
through: what others reach of them is names, which `evil-api` and
`themes-api` declare ("The interface packages `evil-api` and
`themes-api`", above).

## What moving the last seven added to the core's API

What the features-as-packages roadmap's phase 8 added so that the last
seven packages of the core's list, and the compile mode's registrations,
could leave the core:

| Addition | Where | Why |
|---|---|---|
| `Extension.configValues` | `lean/Editor/Extension.lean` | The values config registered at a point, in order, apart from the packages': `Extension.values` holds the packages' and then config's. The compile hook ranks config's contributions first, which is visible in the order of a buffer's on-modes, so its reader asks for config's. This decides, for the one hook that needs it, the open question "Order within a hook" of [extension-points.md](extension-points.md) |
| `Quit.name`, `Quit.notQuitting`, `Quit.closeRequested` | `lean/Editor/Quit.lean` | The loop runs the quit rule for a window's close request whether or not any command is registered, and the command named `quit` for the system's quit. Both are the core's behaviour, and the core imports no package, so the rule and the name are the core's; the package `ex` registers the command under it |
| `Call.count`, `Call.steps` | `lean/Editor/Command/Call.lean` | A call's count, which the window and the tab commands both read |
| `orGiveUp` | `lean/Editor/Api.lean` | Giving up on a layout refusal with the refusal's sentence, beside `giveUp` |
| `PackageSet.startedCommand`, `PackageSet.outputCommand` | `lean/Editor/PackageSet/Build.lean` | The two commands the build job posts, beside their names, so the kit can register the build without the package |
| The kit's stand-ins: `Editor.Test.Restore`, `Editor.Test.PackageSet`, `Editor.Test.Windows`, `Editor.Test.Frame`, `Editor.Test.Listings`, and its own ex line and quit command in `Editor.Test.Ex` | `lean/Editor/Test/` | The core's tests register session restore, the build, window and tab commands and an ex line without importing a package |

What left it:

- **The contribution vocabulary, its listing and their kit**
  (`Editor.ProjectMode`, `Editor.ProjectMode.Format`,
  `Editor.ProjectMode.Listing`, `Editor.Test.Listing`): the interface
  package `compile-api`'s.
- **`SetupRequest.compileContribution` and `SetupRequest.projectCommands`**,
  the registry's hold of them by owner and its four refusal texts, and
  **`RegistryRequest.compileHook`** with `Loop.Registered.compile`: the
  registry holds contributions as it holds any extension value.
- **The core's filling of `Workspace.Settings.markerModes`**: the
  workspace package fills the settings it asks for from the hook
  (`Workspace.markerSettings`, in `compile-api`). The field stays in the
  core's type.
- **`EditorCore.EditorPackage` and its library** ("The core has no entry
  module", above), and the interface libraries `BuffersApi` and
  `ShellApi`, which are interface packages.

## The interfaces the core owns for the two features that moved

Seven import edges led from a core module to a module of one of the two
features. Phase 3 cut each, so that phases 5 and 6 moved the features and
cut none. What replaced each edge is an interface the core owns.

| Edge that was cut | What the core owns now |
|---|---|
| `Editor.Setup` → `Editor.Compile.Contribution`; `Editor.Command.Registry` → `Editor.Compile.Contribution` | The contribution vocabulary, as data |
| `Editor.Workspace.Modes` → `Editor.Compile.Listing` | The listing of computed commands |
| `Editor.Ex.Compiled` → `Editor.Compile` | Ex names bound by the package that owns the commands |
| `Editor.Themes.Compiled` → `Editor.Themes.Solarized`, `Editor.Themes.FairyFloss` | The `themes` package, with the palettes in a package of their own, which phase 5 moved out as `ShippedThemes.…` |
| `Editor.Config.Elaborate` → `Editor` | The base imported at the executables' roots ("The core and its root", above) |

- **The contribution vocabulary** (`lean/Editor/ProjectMode.lean` and
  `lean/Editor/ProjectMode/Format.lean` then; the interface package
  `compile-api`'s `packages/compile-api/CompileApi.lean` and
  `CompileApi/Format.lean` since the features-as-packages roadmap's phase
  8, which made a contribution a value at an extension point: "What
  moving the last seven added to the core's API", below). The setup port registered
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
  went with the compile mode is what reads them: the matcher and the
  sites it yields (`packages/compile/Compile/Errors.lean`), and the offers
  and the formats in use (`packages/compile/Compile/Contribution.lean`). No general
  "contribute to a named point" operation was built: it would be a new
  mechanism with owner, reload and refusal rules of its own.
- **The listing** (`lean/Editor/ProjectMode/Listing.lean` then,
  `packages/compile-api/CompileApi/Listing.lean` since phase 8). Running a
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
  (`packages/compile/Compile/Compiled.lean`) and the `version-control`
  package its twelve (`packages/version-control/VersionControl/Compiled.lean`). The `ex`
  package (`packages/ex/Ex/Compiled.lean`) keeps the files', its own and
  the buffers', each bound to a name an interface declares, and imports
  neither the compile mode nor version control. Version control's names moved with compile's in phase 3
  although version control stays in the core, so that the names were bound
  in the order they had been; the compile package's are bound after
  version control's since it moved ("Registration order is visible").
- **The `themes` package and `shipped-themes`.** The `themes` package
  (`packages/themes/Themes/Compiled.lean`, a default package of its own
  since the features-as-packages roadmap's phase 7) keeps `load-theme`, the theme
  `default` (`Theme.builtin`) and the theme source, and imports no
  palette. The package `shipped-themes` defines `solarized-dark`,
  `solarized-light` and `fairy-floss` and registers nothing else. Phase 3
  made it a package of the core's list, directly after `themes`; phase 5
  moved it out, under the same `Package` name, into the Lake package
  `shipped-themes` (`packages/shipped-themes/ShippedThemes.lean`; "The
  first default package", above), so it registers after all of the
  core's.
- **The `compilation.*` faces.** The face vocabulary
  (`lean/Editor/Face/Vocabulary.lean`) lists `compilation.error`,
  `compilation.warning` and `compilation.note`, and every palette defines
  them (`Palette.theme`, `lean/Editor/Face.lean`). They are the core's
  names for what the compile mode draws: the compile mode names faces the
  core's vocabulary holds, and no core module imports it for them. No edge
  was cut here; they stayed in the core's vocabulary when the mode moved.

## The interface libraries of the features-as-packages roadmap's phase 5

Five features still in the core, `files`, `buffers`, `working-set`,
`workspace` and `version-control`, imported each other's modules, and the
loop imported two of them, `files` and `version-control`. Phase 5 cut
those imports, so that phase 6 can move the five out and cut none. What
replaced each import is an interface, staged as a library of the core's
Lake package (`lean/lakefile.lean`): it has the layout it will keep as an
interface package of its own, a root module that declares and a test
library that publishes a fake and a contract check, and the core's bundle
ships it beside `Editor` (`stagedInterfaceLibraries`). Its module is
outside `lean/Editor/`, so no row of the module map counts it, and a
package of a set may not import it yet: the package imports check refuses
a module of the core's Lake package outside `Editor`. The interface
packages of phases 3 and 4 are the model; these become packages when their
features move.

| Library | Declares | Publishes for tests | Its own tests | Implemented by | Used by | Moves |
|---|---|---|---|---|---|---|
| `FilesApi` (`lean/FilesApi.lean`) | The hooks `FilesApi.Opened` and `.Saved`, run when a file opens into a buffer and when one is saved; the choice `FilesApi.Files` (`adopt`, `visit`, `save`) under the name `files`, answered by `files?`; `loadLimit` and `diffLineLimit`; the commands' and jobs' names (`names`, `jobs`) | `FilesApiTest.fake`, the kit's opener with the hooks as its runners; `FilesApiTest.contractChecks` | `ModelTest.filesApiChecks` | `files` (`Files.Compiled`, `packages/files/`), whose `filesPackageChecks` run the contract | buffers, working-set, workspace, version-control; the kit (`Editor.Test.Workspace`) | Stays a core interface: the core's file-opening is the files feature's, and every feature that opens a file reaches it |
| `BuffersApi` (`packages/buffers-api/BuffersApi.lean`, once `lean/BuffersApi.lean`) | The hook `BuffersApi.Closing`, run before a buffer closes; the choice `BuffersApi.Buffers` under the name `buffers`, answered by `buffers?`; the commands' names | `BuffersApiTest.fake`, a close over the core's API; `BuffersApiTest.contractChecks` | `BuffersApiTest.buffersApiChecks`, once `ModelTest.buffersApiChecks` | `buffers` (`Buffers.Compiled`, `packages/buffers/`), whose `buffersPackageChecks` run the contract | working-set (its ranges' detaching), version-control (`vc-commit`) | Moved in phase 8, when ex, its last user in the core, moved out |
| `ProjectApi` (`packages/project-api/ProjectApi.lean`, once `lean/ProjectApi.lean`) | The order and the continuation of a reach (`Reach.Order`, `Reach.Continuation`) and the roots a command names (`rootArguments`, `rootsOf?`); the choice `ProjectApi.Workspaces` (`reach`, `work`) under the name `workspace`, answered by `workspaces?`, and a job over it (`workOver`); its names | `ProjectApiTest.fake`, a `Workspaces` value that hands every continuation a given workspace; `ProjectApiTest.contractChecks` | `ProjectApiTest.projectApiChecks` (once `ModelTest.projectApiChecks`) | `workspace` (`Workspace.Compiled`), whose `workspacePackageChecks` run the contract | version-control (`vc-worktrees-visit`); the kit | Moved in phase 6: the interface package `project-api` |
| `VcApi` (`packages/vc-api/VcApi.lean`, once `lean/VcApi.lean` and before that `lean/Editor/VersionControl.lean`) | The interface a version-control system answers and its hunks; the backend point `VcApi.Backend`, a choice by the name `git`, connected by `connect?`, which takes the latest backend of that name; the backend `git`, the gutter's jobs and the mode line's segment `review` by name | `VcApiTest.Fake`, the model (once `Editor.VersionControl.Model`) and a backend over it; `VcApiTest.Contract`, the contract (once `Editor.VersionControl.Contract`), and `registrationChecks` | `VcApiTest.vcApiChecks`, `.versionControlModelChecks` and `.versionControlContractFailures` (once `ModelTest`'s) | `version-control` (`VersionControl.Compiled`), whose `versionControlPackageChecks` run the registration check; git's half of the model is its test double `VersionControlTest.Git.Model` | working-set, workspace | Moved in phase 6: the interface package `vc-api` |

Each implementing feature's package checks run the contract over its
package, each sentence one check, and show it bite: over a package of the
same name that registers nothing, every check of the contract fails. So a
contract that stopped checking shows as a failing check, and a feature
that stopped running its contract loses its checks from the count. Three other things moved
for the cut:

- **Jobs over an extension point.** A feature's job that runs over a
  value another feature registers is registered over its point
  (`Extension.workJob`, `SetupRequest.jobOver`), and the loop hands it
  the values at that point when it runs (`Config.State.work?`). A job over
  a point with no value fails naming its job.
- **The loop's reconcilers' names in the core.** The loop started the
  files' check and follow jobs and the gutter's jobs by importing `Files`
  and `VersionControl.Gutter`; it now starts them by names the core
  declares (`Editor.FileJobs`, `Editor.Gutter.Track`), which the features'
  packages register under.
- **The kit's own opener and hosted packages.** The core's model test kit
  opens files with its own opener (`Editor.Test.Opener`) and runs a
  check's packages through `Editor.Test.Hosted`; the drivers of the real
  file commands are the files feature's kit, `Editor.Files.Kit`, a test
  double, which moves into its test library when it moves out.

### Interface libraries left in the core

Each row is an interface library the core still holds and a core module
that imports it, by Lake's module graph, leaving out the core's test roots
and the interface's own test library. `FilesApi` is the one left, for
good. `project-api` and `vc-api` are interface packages since phase 6
(`packages/project-api/`, `packages/vc-api/`), and `buffers-api` and
`shell-api` since phase 8 (`packages/buffers-api/`,
`packages/shell-api/`), when the ex line and the menu, the last core
modules that imported them or `FilesApi` for a feature's sake, moved out.

| Library | Kept by | Why | Until |
|---|---|---|---|
| `FilesApi` | `Editor.Restore.Run` | session restore, which stays in the core, adopts a reopened file and reads the load limit through it, and runs `FilesApi.Opened` for a journaled buffer that holds a file | for good |
| `FilesApi` | `Editor.Jumps.Go` | going to a place visits a file through it; evil's jumps and marks reach it | for good: going to a place is the core's, and evil, a package since phase 7, reaches it |
| `FilesApi` | `Editor.Test.Ex` | the kit's ex line binds `w`, `e` and their kin to the names files-api declares | the kit's stand-in, while tests use it |
| `FilesApi` | `Editor.Test.Workspace` | the kit's stand-in: its attach registers at `FilesApi.Opened` in place of the workspace's | the kit's stand-in, while tests use it |

## Rust in a package

Status: **built** (`phase/packages/phase-11-rust-in-packages`). Third-party
packages that hold Rust, built on a user's machine, are still packages
phases 8 and 9's ("Who can build it", below).

A package may need code that exists as a Rust crate, as the agent client
protocol does: the ACP client could run on the protocol's Rust SDK instead
of writing JSON-RPC and the protocol's types again in Lean
([agent-hosting.md](agent-hosting.md), "Open questions"). A package brings
Rust as a crate of its own, a C file of glue and Lean bindings, and the
package-set build links all of it into the one executable. A Lean binding is
an `@[extern]` declaration of a glue function, which turns Lean objects into
plain data and calls a Rust function of the C ABI, as the core's are
(`editor_glue_…` over `editor_ffi_…`). The fixture package `echo`
(`tests/packages/echo/`) is the proof.

### One Rust archive per editor, generated from the set

The package-set build writes the executable's root module from the set's
Lake packages ("The generated root", above). It writes a Rust crate the same
way (`lean/lakefile.lean`):

| Facet | Gives |
|---|---|
| `editorRustCrates` (package, query) | One line per package crate of the set, in register order: the Lake package, the crate's name and its manifest, tab-separated. Empty for a set with no Rust |
| `editorRustCrate` (package, query) | Writes the generated crate and prints its directory. Builds nothing |
| `editorRust` (package) | Builds the generated crate's archive and gives its path. The system libraries it needs are beside the generated crate |

- **A package declares its crate** in its lakefile, with a target named
  `editorRustCrate` whose value is the path of the crate's manifest. The
  build walks the set's packages (`setPackages`), finds the target by name,
  runs it through its own declaration and reads the crate's name from the
  manifest with Lake's TOML reader: no list is kept by hand.
- **The generated crate** is keyed by the set's package crates, not by the
  set: `target/editor-rust/core/` (crate `editor-rust`, archive
  `target/release/libeditor_rust.a`) for a set with none, and
  `target/editor-rust/<packages>/` (`editor-rust-<packages>`) otherwise,
  `echo`'s being `editor-rust-echo`, archive `libeditor_rust_echo.a`. So
  the core's executables, the default set, `tests/empty-set` and every
  linked test of a package without Rust share one archive, the core's
  (`rustlib`). Its `Cargo.toml` is a `staticlib` whose dependencies are
  `editor-ffi` and each package crate, by absolute path; its `lib.rs`
  re-exports each, so each is linked; its `Cargo.lock` is seeded from the
  root's whenever the root's changes. The build runs `cargo fetch --locked`
  over the root, then `cargo rustc --offline` over the generated crate into
  the root's target directory, so dependencies are built once for every
  generated crate (a second key builds its own library alone, about 3 s).
  Every package crate is a member of the root workspace (`Cargo.toml`), so
  the root lock holds its versions and the gate's Rust tasks cover it.
- **The link** (`linkAsEditor`) takes the set's one archive, after the
  core's glue and every package's glue, and then the system libraries
  rustc printed for that archive (`--print native-static-libs`, written to
  `native-static-libs` beside the generated crate), so a package's crate
  that needs a system library links with no edit to the core's
  `linkArgs`, which keeps only the toolchain's library directory and the
  entry point. The core's `lean_exe`s read the core's line as a response
  file (`@…/native-static-libs`). `echo`'s crate links the system's zlib
  this way.
- **A package's glue** is a C file of its own, compiled by a target of its
  own lakefile against the toolchain's `lean.h`, and the `moreLinkObjs` of
  the library that holds its binding alone, so Lake links it into exactly
  the executables that import the binding. Its test driver imports no
  binding and links no glue and no Rust.

Such a package's lakefile is Lean, not TOML (the exception to "every fixture
lakefile is TOML"): a TOML lakefile cannot declare a target that compiles C,
`moreLinkObjs`, or the crate's target.

Not chosen:

- **An archive per package.** Each Rust static library carries its own copy
  of the standard library, and two in one executable clash on its symbols.
- **An archive per set, generated into the set's `.lake`.** Sets with the
  same crates would each bundle an 80 MB archive, and Cargo's target
  directory must be shared anyway to reuse dependency builds.
- **A library loaded when the editor runs** (`dlopen`). It needs no relink
  and no Cargo, which suits a third party's prebuilt binary, but
  `@[extern]` binds at link time, so every call would go through a table of
  pointers, and the signed app would have to relax library validation. It
  stays an option for third-party packages only.

### The service conventions as a crate of their own

A package's crate runs work the way the core's services do
([rust-library.md](rust-library.md)): `start` with the caller's id, which
never blocks; one completion event for each request, on the completion
queue; `cancel`; and plain data only, never a call into Lean. Those
conventions are the crate `editor-service`, which `editor-ffi` and every
package's crate depend on:

- `queue`: the two event queues, their events and the fake source, moved
  out of `editor-ffi`, which re-exports them. The editor holds one archive,
  so one copy of the crate and one of each queue.
- `service`: `Service::named("echo")`, made in a `static`, takes an id from
  a process-wide counter that starts at 1024 on first use (the core's
  services keep their fixed ids, 1 to 7), and `Service::complete` posts a
  completion from the library's source with that id. A service reports
  through the port `Completer`, whose published fake is
  `RecordingCompleter` and whose contract, `completer_contract`, runs on the
  fake and on the real queue (`crates/editor-service/tests/queue.rs`).
- `buffer`: the plain-data buffers that cross the boundary, lent, borrowed
  and reclaimed; a package's crate exports its own `<pkg>_ffi_free`.

It is the Rust counterpart of an interface package
([extension-points.md](extension-points.md)): a package's crate depends on
it, never on `editor-ffi` or on another package's crate.

**The rule is held by cargo-deny over the generated crate.** The package
crates are members of the root workspace, so the root `deny.toml` already
refuses an edge from one to any editor crate it has an entry for, and
`editor-service` has none. But nothing in the root graph depends on
`editor-ffi` or on a package crate, and cargo-deny bans a crate with no
parents under `wrappers = []` and fails a wrapper it never meets under
`-D unused-wrapper`, so the root cannot say "only the generated crate". The
generator writes a `deny.toml` beside the generated crate in which the
generated crate is the one wrapper of `editor-ffi` and of each package
crate, and `tools/rust-bans-check.sh <set dir>` runs cargo-deny's bans over
it. `ffi-test` runs it on the fixture set and the default set, and on
`tests/rust-bans/`, a set of two packages whose crates depend on
`editor-ffi` and on each other, where it must fail with both "explicitly
banned".

### Behind a port, so it stays replaceable

A package's Rust is an adapter. Its Lean side is a binding behind a port,
with a pure model and a contract check run against both, as every port is
(`AGENTS.md`). The port is to be declared by an interface package, so an
implementation backed by Rust and one written in Lean are both
implementation packages, and either can replace the other. Interface
packages are not built yet, so the fixture `echo` holds its port
(`Echo.lean`), pure model (`Echo/Model.lean`), contract
(`Echo/Contract.lean`) and binding (`Echo/Real.lean`) in one package: its
test driver runs the contract against the model, and its linked test
against the binding over the linked test kit's table of waits and
completion pump, where each request completes through the completion
queue. Its port holds no Rust, so splitting it out later is a move of
modules. No command uses its service: a package cannot add a service to
the job runner's `Job.Services` yet, which is the ACP roadmap's.

The port is phrased in the editor's terms, not the crate's. For ACP the
crate holds the JSON-RPC connection on its own threads and hands Lean
events such as a message chunk, a tool call or a permission request; Lean
does not get the protocol's raw messages, which would need every type of
the protocol again in Lean.

### Who can build it

**Decided by the owner, 2026-11-20 (packages phase 8): the app never ships
Cargo. And (phase 9): the app ships the Lean toolchain only, with no macOS
SDK and no C library headers.** A set of pure-Lean packages builds from the
app alone ([lean-runtime.md](lean-runtime.md), "The app ships the
toolchain"). A package with native code needs the user's own tooling (the
Xcode command line tools for C headers or the SDK, rustup's Cargo for
Rust) or a prebuilt binary its lakefile fetches with the system's `git` or
`curl`, and says so in its own documentation, the way an Emacs package with
a native module either compiles it or fetches a prebuilt one.

- **A C FFI is the preferred way for a package to bring native code**: C or
  C++ sources the toolchain's compiler builds, as Lake builds the core's
  own glue (`buildLeanO`), or a system C library it links. It needs
  nothing beyond the bundled toolchain. A package's object reaches the
  editor's link through its library's `moreLinkObjs`. The fixture package
  `tests/user-sets/c-glue` is one: its `c/cglue.c` is bound by an
  `@[extern]` declaration and answers its command. From the app, the
  bundled `clang` compiles C that includes `lean/lean.h` alone (`c-glue`
  does, in `bundle-test` and `app-check`), and its linker links what the
  link stubs hold, the system's functions the shipped editor itself
  imports. C that includes a header of the system's C library
  (`<stdio.h>`), or calls a system function the stubs lack, needs the
  user's own Xcode command line tools, which the package's own build must
  use. When such a build fails, the build buffer's failure line and the
  echo area say which header, framework or library is missing, and to
  install the Xcode command line tools (`xcode-select --install`) or use
  the package's prebuilt binary (`missingTooling?`,
  `lean/Editor/PackageSet/Build.lean`).
- **A user's set with no Rust crate never runs Cargo.** It links the core's
  Rust archive as it is already built (`libeditor_rust.a`, with its record
  of system libraries `target/editor-rust/core/native-static-libs`): no
  `cargo fetch`, no `cargo rustc`, nothing written into a Cargo `target/`
  (`rustSource` and `prebuiltRust` in `lean/lakefile.lean`; the facet
  `:editorRustSource` says `prebuilt`). A set is a user's when it is
  outside the repository; the checkout's own sets are built by Cargo, so a
  change to the core's Rust is built.
- **A Rust crate is supported, and needs the user's own Cargo**, installed
  with rustup. The package-set build checks `cargo --version` only when the
  set holds a package with a crate; when Cargo is missing or broken it
  stops before building: "Cargo is required to build `<package>`'s Rust
  crate `<crate>`, and none works here (`<how>`): install it from
  https://rustup.rs, then :reload; this editor keeps running"
  (`cargoRequired`, `lean/Editor/PackageSet/Build.lean`). This is git's
  stance too: require the system tool, say so when it is needed, never
  ship it.
- **Why not archives built ahead for each platform.** An editor links one
  Rust archive, so it holds one copy of Rust's standard library ("One Rust
  archive per editor"), so a package's crate cannot arrive as a prebuilt
  static library of its own. An archive built ahead would have to be the
  whole editor's archive for that exact combination of crates, core and
  platform, which no package author can build; a dynamic library loaded at
  run time was refused earlier (`@[extern]` binds at link time). So a
  package's Rust reaches an editor only by compiling the generated crate
  on the user's machine, with Cargo.

**From the app, no Rust package builds.** A package crate is outside the
bundle's "repository", `Contents/Resources/lean`, so the refusal below
applies: a Rust package builds only from a checkout, with the user's own
Cargo.

**Built, and refused.** A user's set builds the package crates the editor's
own Cargo workspace holds: every package crate under the repository, such
as the fixture `echo`, whose dependencies the core's `Cargo.lock` pins. A
crate whose manifest is outside the repository is refused by
`setRustCrates`, so `:editorRustCrates` and the build stop early with:
"`<package>`'s Rust crate `<crate>` is outside the editor's Cargo workspace
(`<repo>`): building a third party's Rust is not supported yet; see
docs/design/packages.md, 'Who can build it'". Two pieces are missing for
such a crate: its dependencies are not in the core's lock (the build is
`cargo fetch --locked` then `--offline`), and `editor-service` has no
published name for it to depend on.

`ffi-test` checks these: a set in a temporary directory that requires the
default set and `c-glue` is linked with a `cargo` that always fails first
on the PATH, and `c-glue`'s command answers from its C function; and a copy
of `echo` outside the repository is refused with its reason
(`tools/rust-outside-check.sh`).

## The module map

The end state of the features-as-packages roadmap: the core's modules,
and the packages of the default set with what each registers at and reads.
Written by its phase 8 so that commands can check it against the tree and
against Lake (the commands are below each table).

### The core's modules

Every module under `lean/Editor/`, each named in full once, by class.
None is a feature's: a **feature** is a Lake package under `packages/`,
and the core's Lake package registers no `Package`.

- **Core** is what a host with no packages needs to start and run, and
  what a package is written over: the ports with their models and
  bindings, the state, the scene and display types, the loop, the setup
  port, the config session and the hosts; the data a core module carries
  for a feature that is a package (an ex line's parts, the menu's types,
  the mode line's, a language, a workspace); and the work the hosts, the
  loop and the config session start by a name the core declares, which a
  default package registers under: session restore's and the package
  set's build.
- **"A package may import it"** is what the package imports check allows
  ("What a package may import", above): `yes` for a module of the API,
  `in tests` for a test double, `in a linked test` for the linked test
  kit, and `no` for an internal module.

| Modules | Count | Class | A package may import it |
|---|---|---|---|
| The core's root: `Editor.Core` | 1 | core | no |
| The hosts and the executable's modules, with what a host is made of and driven by: the editor queue as a port, the session journal as a port, a host stepped on its caller's thread, a driver's wait judged, and a host's activity count, which the tests' event waits are written on (`docs/design/concurrency.md`, "Stepped hosts in tests", "The idle signal"): `Editor.Executable`, `Editor.Headless`, `Editor.Headless.CommandLine`, `Editor.Headless.Journal`, `Editor.Headless.Queue`, `Editor.Headless.Stepped`, `Editor.Headless.Wait`, `Editor.Job.Activity`, `Editor.Main`, `Editor.ModuleLookup`, `Editor.Version`, `Editor.Window`, `Editor.Window.Real`, `Editor.WindowCheck`, `Editor.WindowCheck.Real` | 15 | core | no |
| The loop and its dispatch: `Editor.Command.Dispatch`, `Editor.Event.Queue`, `Editor.Loop`, `Editor.State.Outbox` | 4 | core | no |
| The models of the ports: `Editor.Clipboard.Model`, `Editor.Command.Model`, `Editor.Config.Elaborator.Model`, `Editor.Diff.Model`, `Editor.Display.Model`, `Editor.File.Model`, `Editor.FileWatch.Model`, `Editor.Fuzzy.Model`, `Editor.Grep.Model`, `Editor.Job.Model`, `Editor.Process.Model`, `Editor.SyntaxTree.Model`, `Editor.SyntaxTree.Model.Json`, `Editor.SyntaxTree.Model.Query`, `Editor.Text.Model`, `Editor.Watch.Model` | 16 | core | in tests |
| The contracts and cases: `Editor.Api.Cases`, `Editor.Clipboard.Contract`, `Editor.Completion.AtPointContract`, `Editor.Completion.Contract`, `Editor.Completion.DisplayContract`, `Editor.Completion.StyleContract`, `Editor.Config.Elaborator.Contract`, `Editor.Display.Contract`, `Editor.File.Cases`, `Editor.Fuzzy.Contract`, `Editor.Headless.Journal.Contract`, `Editor.Headless.Queue.Contract`, `Editor.InputScheme.Contract`, `Editor.Job.Contract`, `Editor.Job.FlushContract`, `Editor.Job.HandleContract`, `Editor.Job.ProtocolContract`, `Editor.Job.PumpContract`, `Editor.Job.SchedulerContract`, `Editor.SyntaxTree.Contract`, `Editor.SyntaxTree.DeliveryContract`, `Editor.Text.Contract`, `Editor.UndoTree.Cases`, `Editor.Watch.Contract` | 24 | core | in tests |
| The fakes, the test scheme, the loop's driver, the reading of what a package registers and the theme picture check: `Editor.Completion.Fake`, `Editor.Config.Packages`, `Editor.Headless.Journal.Fake`, `Editor.InputScheme.Test`, `Editor.Job.Fake`, `Editor.Loop.Driver`, `Editor.SyntaxTree.Fake`, `Editor.Theme.Picture` | 8 | core | in tests |
| The linked test kit: `Editor.Test.Linked.Bench`, `Editor.Test.Linked.Frames`, `Editor.Test.Linked.Host`, `Editor.Test.Linked.Jobs`, `Editor.Test.Linked.Keys`, `Editor.Test.Linked.Lines`, `Editor.Test.Linked.Listings`, `Editor.Test.Linked.Rig`, `Editor.Test.Linked.Services`, `Editor.Test.Linked.Shipped`, `Editor.Test.Linked.Syntax`, `Editor.Test.Linked.Trees` | 12 | core | in a linked test |
| The model test kit: `Editor.Test.AtPoint`, `Editor.Test.Completion`, `Editor.Test.Config`, `Editor.Test.Driver`, `Editor.Test.Editing`, `Editor.Test.Ex`, `Editor.Test.Excerpt`, `Editor.Test.Files`, `Editor.Test.Frame`, `Editor.Test.Geometry`, `Editor.Test.Hosted`, `Editor.Test.Jobs`, `Editor.Test.Keys`, `Editor.Test.Listings`, `Editor.Test.Loop`, `Editor.Test.Minibuffer`, `Editor.Test.Models`, `Editor.Test.Modes`, `Editor.Test.Opener`, `Editor.Test.PackageSet`, `Editor.Test.Prompts`, `Editor.Test.Restore`, `Editor.Test.Shell`, `Editor.Test.Shipped`, `Editor.Test.Sources`, `Editor.Test.States`, `Editor.Test.Views`, `Editor.Test.Windows`, `Editor.Test.Workspace` | 29 | core | in tests |
| The config session: `Editor.Config.Diagnostic`, `Editor.Config.Directory`, `Editor.Config.Display`, `Editor.Config.Elaborate`, `Editor.Config.ExactPath`, `Editor.Config.LakePackage`, `Editor.Config.Lakefile`, `Editor.Config.Lakefile.Toml`, `Editor.Config.Owner`, `Editor.Config.Registry`, `Editor.Config.Reload`, `Editor.Config.Session`, `Editor.Config.Stores` | 13 | core | no |
| The raw bindings: `Editor.Ffi`, `Editor.Ffi.Clipboard`, `Editor.Ffi.Counter`, `Editor.Ffi.Diffs`, `Editor.Ffi.Display`, `Editor.Ffi.Document`, `Editor.Ffi.Events`, `Editor.Ffi.Excerpts`, `Editor.Ffi.Files`, `Editor.Ffi.Fuzzy`, `Editor.Ffi.Grep`, `Editor.Ffi.Interrupt`, `Editor.Ffi.Inverse`, `Editor.Ffi.Launch`, `Editor.Ffi.Log`, `Editor.Ffi.MainThread`, `Editor.Ffi.Marker`, `Editor.Ffi.Pair`, `Editor.Ffi.Processes`, `Editor.Ffi.Render`, `Editor.Ffi.Search`, `Editor.Ffi.Snapshot`, `Editor.Ffi.Syntax`, `Editor.Ffi.Text`, `Editor.Ffi.Timers`, `Editor.Ffi.Transaction`, `Editor.Ffi.Watches`, `Editor.Ffi.Window`, `Editor.Ffi.Words` | 29 | core | no |
| The real bindings of the ports and what runs them: `Editor.Clipboard.InProcess`, `Editor.Clipboard.Real`, `Editor.Command.Real`, `Editor.Display.Real`, `Editor.Display.Recorder`, `Editor.Fuzzy.Real`, `Editor.Headless.Journal.Real`, `Editor.Headless.Queue.Real`, `Editor.Job.Jobs`, `Editor.Job.Pool`, `Editor.Job.Real`, `Editor.Job.Runner`, `Editor.Job.Table`, `Editor.Restart.Real`, `Editor.SyntaxTree.Real`, `Editor.Text.Real`, `Editor.Watch.Real` | 17 | core | no |
| The editor API and what is proved of it: `Editor.Api`, `Editor.Api.Theorems`, `Editor.UndoTree`, `Editor.UndoTree.Theorems` | 4 | core | yes |
| The job runner's protocol, a pure transition system the runner decides its steps with (`docs/design/concurrency.md`, "The runner's protocol, modelled"), and what is proved of it: `Editor.Job.Protocol`, `Editor.Job.Protocol.Theorems` | 2 | core | no |
| The composite port and a command: `Editor.Command`, `Editor.Command.Append`, `Editor.Command.Call`, `Editor.Command.Control`, `Editor.Command.Registry`, `Editor.Program` | 6 | core | yes |
| The ports: `Editor.Clipboard`, `Editor.Diff`, `Editor.Diff.Script`, `Editor.Display`, `Editor.File`, `Editor.FileWatch`, `Editor.Fuzzy`, `Editor.Grep`, `Editor.Job`, `Editor.Job.Pump`, `Editor.Process`, `Editor.Process.Environment`, `Editor.SyntaxTree`, `Editor.Text`, `Editor.Watch` | 15 | core | yes |
| The word under the cursor, over the text port: `Editor.Text.Word` | 1 | core | yes |
| The typed time bounds every bounded wait takes, a hang guard or real time under test, and the marks of the inferred waits, which the wait linters read to refuse one outside its modules (`docs/design/concurrency.md`, "What a test may still wait on time for"; `docs/dev-practices/inferred-waits.md`). The linters themselves are the library `Lint` (`lean/Lint/Wait.lean`), outside the core: they import `Lean`, so the build loads them as a plugin and no module imports them: `Editor.Bound`, `Editor.InferredWait` | 2 | core | yes |
| The setup port, packages, extension points and stores: `Editor.Extension`, `Editor.Json`, `Editor.Package`, `Editor.Setup`, `Editor.Store`, `Editor.Store.Codec`, `Editor.Value` | 7 | core | yes |
| The state, what a search of a workspace's files covers, and the names of the jobs the loop's reconcilers run: `Editor.DisplayRules`, `Editor.Event`, `Editor.ExcerptView`, `Editor.FileJobs`, `Editor.Floating`, `Editor.GeneratedView`, `Editor.Gutter`, `Editor.Gutter.Track`, `Editor.Layout`, `Editor.SearchRoot`, `Editor.State`, `Editor.State.Request`, `Editor.Workspace` | 13 | core | yes |
| Places, jump lists and marks, and going to a place: `Editor.JumpList`, `Editor.Jumps`, `Editor.Jumps.Go`, `Editor.Marks`, `Editor.Marks.Follow` | 5 | core | yes |
| The scene and display types: `Editor.Appearance`, `Editor.Face`, `Editor.Face.Vocabulary`, `Editor.Highlight`, `Editor.Menu`, `Editor.ModeLine`, `Editor.Scene`, `Editor.Scroll`, `Editor.TabBar` | 9 | core | yes |
| Keys and modes: `Editor.InputScheme`, `Editor.Invocation`, `Editor.Key.Notation`, `Editor.Keymap`, `Editor.Mode`, `Editor.Role`, `Editor.Vocabulary` | 7 | core | yes |
| Completion: `Editor.Completion`, `Editor.Completion.AtPoint`, `Editor.Completion.Candidate`, `Editor.Completion.Display`, `Editor.Completion.Filtering`, `Editor.Completion.Keys`, `Editor.Completion.Later`, `Editor.Completion.Style` | 8 | core | yes |
| Languages and indentation: `Editor.Indent`, `Editor.Language`, `Editor.Language.IndentUnit` | 3 | core | yes |
| What an ex line and a typed path are as data: `Editor.Ex.Line`, `Editor.TypedPath` | 2 | core | yes |
| The quit rule and its name, which the loop runs and the package `ex` registers a command under: `Editor.Quit` | 1 | core | yes |
| Session restore: the journal reconciler the loop runs after each publish, and the data and formats it keeps: `Editor.Restore`, `Editor.Restore.Document`, `Editor.Restore.Frame`, `Editor.Restore.Indexed`, `Editor.Restore.Journal`, `Editor.Restore.Kept`, `Editor.Restore.Records`, `Editor.Restore.Value`, `Editor.Restore.Workspaces` | 9 | core | yes |
| Session restore's run and restart, which the package `restore` registers: `Editor.Restore.Restart`, `Editor.Restore.Run` | 2 | core | yes |
| The package set's data, edit and build, which the reload, the hosts and the package `package-set` use: `Editor.PackageSet.Build`, `Editor.PackageSet.Edit`, `Editor.PackageSet.Fingerprint`, `Editor.PackageSet.Layout`, `Editor.PackageSet.Running` | 5 | core | yes |
| The restart's hand-over: `Editor.Restart.Handover`, `Editor.Restart.Launch` | 2 | core | yes |
| The theme completeness check: `Editor.Theme.Check` | 1 | core | yes |

The check below, its first part, prints nothing when every module under
`lean/Editor/` is in the table and the table names no module that is not
there.

The rows are generated from `find`, so no module is in no row, which
closes the task `module-map-count-drift`. Beside `lean/Editor/` the core's
Lake package holds one interface library, `FilesApi` (`lean/FilesApi.lean`,
with its test library `FilesApiTest`), which declares the extension points
of files and which the core keeps because session restore and going to a
place, core modules, reach files through it ("Interface libraries left in
the core", above); the config base, `lean/Editor.lean`; and the core's own
test roots.

### The packages

One row a package of the default set, in the order the build visits them
(`lake -d ../packages query :editorPackageGraph`): its layer as its
lakefile declares it, what it requires beside the core, the extension
points it registers at and reads, and the names it declares or reaches.

- **The extension points** are the types that derive `TypeName`:
  `FilesApi.Opened`, `FilesApi.Saved` and `FilesApi.Files` (the core's
  interface library), `BuffersApi.Closing` and `BuffersApi.Buffers`,
  `ProjectApi.Workspaces`, `VcApi.Backend`, and `Compile.Contribution`
  and `Compile.ProjectCommands` (`compile-api`'s).
- **A registration** is an `Extension.add` of a value of the point's type,
  or a call of a setup operation that is one: `compileContribution`
  (`Compile.Contribution`) and `projectCommands` (`Compile.ProjectCommands`),
  both `compile-api`'s.
- **A read** is an `Extension.values`, `Extension.named`,
  `Extension.configValues` or `Extension.workJob` over the point, or a
  call of a function that is one:

  | Reader | Point | Declared in |
  |---|---|---|
  | `FilesApi.runOpened` | `FilesApi.Opened` | `lean/FilesApi.lean` |
  | `FilesApi.runSaved` | `FilesApi.Saved` | `lean/FilesApi.lean` |
  | `FilesApi.files?` | `FilesApi.Files` | `lean/FilesApi.lean` |
  | `BuffersApi.runClosing` | `BuffersApi.Closing` | `packages/buffers-api/BuffersApi.lean` |
  | `BuffersApi.buffers?` | `BuffersApi.Buffers` | `packages/buffers-api/BuffersApi.lean` |
  | `ProjectApi.workspaces?` | `ProjectApi.Workspaces` | `packages/project-api/ProjectApi.lean` |
  | `VcApi.connect?`, which chooses among the backends a job over the point is handed | `VcApi.Backend` | `packages/vc-api/VcApi.lean` |
  | `Compile.hook` | `Compile.Contribution`, `Compile.ProjectCommands` | `packages/compile-api/CompileApi.lean` |
  | `Workspace.markerSettings`, `Compile.refreshListings`, `Compile.listWork`, each through `Compile.hook` | `Compile.Contribution`, `Compile.ProjectCommands` | `packages/compile-api/CompileApi/Listing.lean` |
- **An interface package declares its points and registers at and reads
  none**: what uses a point in the package that declares it is the body of
  one of the functions above, and the package that calls the function is
  the one that reads. A names-only interface package declares names alone.
- **The core reads `FilesApi.Files`** itself, in session restore
  (`lean/Editor/Restore/Run.lean`) and in going to a place
  (`lean/Editor/Jumps/Go.lean`), and its test kit registers stand-ins at
  the files' points; the core's Lake package is no row.

| Package | Layer | Requires, beside the core | Extension points it registers at | Extension points it reads | Names it declares, or reaches |
|---|---|---|---|---|---|
| `shell-api` | interface | none | none | none | declares `shell-command`, `shell-filter` and `keyboard-quit`, and the history of the lines run (`Shell.history`, its store and its rule) |
| `ex-api` | interface | `shell-api` | none | none | declares `ex` and `quit`, which is the core's quit name; its contract names `shell-api`'s `shell-command` |
| `buffers-api` | interface | none | none | none | declares the points `BuffersApi.Closing` and `BuffersApi.Buffers`, and `switch-buffer`, `list-buffers` and `close-buffer` |
| `ex` | implementation | `ex-api`, `buffers-api`, `shell-api` | none | `FilesApi.Files` | registers `ex-api`'s two names; its ex names reach the files' commands by `files-api`'s constants, the buffers' by `buffers-api`'s and the shell's by `shell-api`'s |
| `frame-commands-api` | interface | none | none | none | declares `toggle-fullscreen` and `minimise-window` |
| `frame-commands` | implementation | `frame-commands-api` | none | none | registers `frame-commands-api`'s two names; binds `s-q` to the core's `quit` |
| `evil-api` | interface | none | none | none | declares `insert-newline`, `insert-tab`, `undo` and `redo` |
| `menu` | implementation | `evil-api`, `frame-commands-api` | none | none | reaches `open-file` and `save-buffer` by `files-api`'s constants, the clipboard four by the core's, `undo` and `redo` by `evil-api`'s, and `minimise-window` and `toggle-fullscreen` by `frame-commands-api`'s |
| `window-commands-api` | interface | none | none | none | declares the thirty-three window commands' names, `window-split` to `window-float` |
| `window-commands` | implementation | `window-commands-api` | none | none | registers `window-commands-api`'s names; `window-quit` runs the core's `quit` |
| `tab-commands-api` | interface | none | none | none | declares the eight tab commands' names and `tab-select-1` to `tab-select-9` |
| `tab-commands` | implementation | `tab-commands-api` | none | none | registers `tab-commands-api`'s names |
| `restore` | implementation | none | none | none | registers under names the core declares: the jobs `restore`, `restore-files`, `restore-write`, `restore-save`, `restart-probe` and `restart-save`, and `restart` |
| `package-set` | implementation | none | none | none | registers under names the core declares: the job `package-build` and the two commands it posts; its own `package-install`, `package-remove` and `package-update` |
| `minibuffer-api` | interface | none | none | none | declares the minibuffer's nine commands' names and its mode's name |
| `at-point-api` | interface | none | none | none | declares completion at point's nine commands' names |
| `evil` | implementation | `evil-api`, `minibuffer-api`, `at-point-api`, `window-commands-api`, `tab-commands-api`, `ex-api`, `buffers-api`, `shell-api` | none | none | registers `evil-api`'s names and the core's clipboard four; its Vim tables reach `minibuffer-api`'s, `at-point-api`'s, `window-commands-api`'s, `tab-commands-api`'s and `ex-api`'s names and `shell-api`'s `keyboard-quit` by their constants; supplies the input scheme |
| `themes-api` | interface | none | none | none | declares `load-theme` |
| `themes` | implementation | `themes-api` | none | none | registers `themes-api`'s name |
| `files` | implementation | `buffers-api` | `FilesApi.Files` | `FilesApi.Opened`, `FilesApi.Saved` | registers `files-api`'s names (`open-file`, `save-buffer`, `edit-file`, `reload-buffer`, `auto-reload-mode`), an interface the core holds, and the jobs the loop starts under the core's names |
| `buffers` | implementation | `buffers-api` | `BuffersApi.Buffers` | `BuffersApi.Closing` | registers `buffers-api`'s names |
| `compile-api` | interface | none | none | none | declares the points `Compile.Contribution` and `Compile.ProjectCommands`, the setup operations that register at them, the hook that reads them, and the listing job's name, `compile-list` |
| `project-api` | interface | `compile-api` | none | none | declares the point `ProjectApi.Workspaces`, and `find-file-in-workspace` and `find-file-in-project`; names `compile-api`'s listing job |
| `vc-api` | interface | none | none | none | declares the point `VcApi.Backend`, the version-control port, its model and its contract, and the backend's name `git` |
| `workspace` | implementation | `project-api`, `vc-api`, `compile-api` | `FilesApi.Opened`, `ProjectApi.Workspaces` | `Compile.Contribution`, `Compile.ProjectCommands`, `VcApi.Backend` | registers `project-api`'s names and the listing job under `compile-api`'s name |
| `project-search-api` | interface | none | none | none | declares `project-search` and `project-search-symbol` |
| `project-search` | implementation | `project-search-api` | none | `FilesApi.Files` | registers `project-search-api`'s names |
| `working-set-api` | interface | none | none | none | declares `working-set-add` and `working-set-open` |
| `working-set` | implementation | `working-set-api`, `vc-api`, `buffers-api` | `BuffersApi.Closing`, `FilesApi.Opened`, `FilesApi.Saved` | `FilesApi.Files`, `VcApi.Backend` | registers `working-set-api`'s names |
| `shell` | implementation | `shell-api` | none | none | registers `shell-api`'s names and keeps its history |
| `version-control` | implementation | `project-api`, `vc-api`, `buffers-api` | `VcApi.Backend` | `BuffersApi.Buffers`, `FilesApi.Files`, `ProjectApi.Workspaces` | registers the `vc-…` commands and their twelve ex names, and the gutter's jobs under the core's names; two packages, `version-control` and `version-control-gutter` |
| `completion-api` | interface | none | none | none | declares the path style's name, `path` |
| `completion` | implementation | `completion-api` | none | none | registers the styles `fuzzy`, `orderless` and `path` and the display `minibuffer` |
| `mode-line` | implementation | none | none | none | registers the mode line's segments |
| `minibuffer` | implementation | `minibuffer-api` | none | none | registers `minibuffer-api`'s names and mode |
| `shipped-themes` | implementation | none | none | none | registers the Solarized and Fairy Floss themes |
| `execute-command-api` | interface | none | none | none | declares `execute-command` |
| `execute-command` | implementation | `execute-command-api`, `minibuffer-api` | none | none | registers `execute-command-api`'s name; reaches `minibuffer-api`'s names |
| `binding-search-api` | interface | none | none | none | declares `search-bindings` |
| `binding-search` | implementation | `binding-search-api`, `minibuffer-api` | none | none | registers `binding-search-api`'s name; reaches `minibuffer-api`'s names |
| `compile` | implementation | `minibuffer-api`, `compile-api`, `shell-api` | `Compile.Contribution` | `Compile.Contribution`, `Compile.ProjectCommands`, `FilesApi.Files` | registers the compile mode's commands and its six ex names; reaches `minibuffer-api`'s names and `shell-api`'s history |
| `at-point` | implementation | `at-point-api`, `evil-api` | none | none | registers `at-point-api`'s names; reaches `insert-newline` and `insert-tab` by `evil-api`'s constants |
| `languages` | implementation | none | none | none | registers the `code` mode and the languages that ship |

`tools/module-map-check.sh`, run in `lean/`, holds this table and the one
above to the tree and to Lake, and prints nothing when they agree: every
package of the set has its row, with its layer as Lake says it, and every
(package, point) pair the sources hold, by the rules above, is in that
package's row, and no row names a pair the sources lack. It reads the
library modules of each package (no test library, no fixture config) for
the registrations and reads, and the table's fourth and fifth columns for
the rows, and compares the two.

```sh
cd lean && sh ../tools/module-map-check.sh
```

The gate runs it, in `mise run ffi-test`, so the map cannot drift from the
tree. It is no test of the code: it holds a document to the sources it
describes. Its reading of the sources, the third part, is itself held by
a fixture in `mise run lean-test`, packages and maps written by hand
(`tests/module-map/`), where a map that agrees must pass and a stale one
must fail with exactly the two lines that differ
([the-gate.md](../dev-practices/the-gate.md), "The module map check"). A
new way to register or read is added to the rules above, to the script
and to that fixture.

### Where each feature went

Each feature that was a package of the core's own list, the Lake package
it is now, and the phase that moved it. What each had to cross to move is
in its phase's section, above.

| Feature | Lake package | Moved in |
|---|---|---|
| The shipped palettes | `shipped-themes` | the packages roadmap's phase 5 ("The first default package: `shipped-themes`") |
| The compile mode | `compile` | the packages roadmap's phase 6 ("The default package `compile`") |
| The mode line's segments | `mode-line` | features-as-packages phase 3 |
| The command prompt | `execute-command` | features-as-packages phase 3 |
| The binding search | `binding-search` | features-as-packages phase 3 |
| The languages | `languages` | features-as-packages phase 3 |
| The completion styles and displays | `completion` | features-as-packages phase 4 |
| Completion at point | `at-point` | features-as-packages phase 4 |
| The minibuffer's commands and mode | `minibuffer` | features-as-packages phase 4 |
| The file commands | `files` | features-as-packages phase 6 |
| The buffer commands | `buffers` | features-as-packages phase 6 |
| The workspaces | `workspace` | features-as-packages phase 6 |
| Project search | `project-search` | features-as-packages phase 6 |
| The working sets | `working-set` | features-as-packages phase 6 |
| The shell | `shell` | features-as-packages phase 6 |
| Version control and its gutter | `version-control` (two `Package` values) | features-as-packages phase 6 |
| Evil and the Vim scheme | `evil` | features-as-packages phase 7 |
| The themes | `themes` | features-as-packages phase 7 |
| The package-set commands | `package-set` | features-as-packages phase 8 |
| Session restore's registrations | `restore` | features-as-packages phase 8 |
| The tab commands | `tab-commands` | features-as-packages phase 8 |
| The window commands | `window-commands` | features-as-packages phase 8 |
| The menu bar that ships | `menu` | features-as-packages phase 8 |
| The frame commands | `frame-commands` | features-as-packages phase 8 |
| The ex command line | `ex` | features-as-packages phase 8 |

## Input schemes

**The input scheme comes from a package of the set, and an editor whose
set supplies none refuses to start** (decided 2026-11-17). It does not
fall back to a built-in scheme: a set with no scheme has no way to turn a
key into a command, and saying so at start-up is clearer than an editor
that opens and takes no input.

- **How a package supplies one.** A Lake package whose lakefile declares
  the keyword `editor-input-scheme` declares `scheme : Editor.SchemePackage`
  in its entry module, beside `packages` (`lean/Editor/InputScheme.lean`,
  "The scheme a package supplies"). Lake is asked for the keyword, as for
  `editor-interface`, so the build reads no source. The generated root
  hands `Editor.Main.run` the `scheme` of each such entry module, in the
  order the packages register, and the editor runs the last
  (`SchemePackage.chosen?`). A keyword with no `scheme` fails the generated
  root's build, naming `<P>.EditorPackage.scheme`; a keyword on a package
  with no entry module fails the build's facet, naming the package.
- **Why a declaration of the entry module, and not an extension point or a
  setup request.** A scheme is in `Type 1`: it carries its `State` and
  `Binding` types. An extension point's values travel as `Dynamic`, which
  holds values of types in `Type`, and a `Package` is plain data in `Type`.
  And the host's loop is typed by its scheme (`Loop scheme`), so the scheme
  is chosen before any package's `setup` runs, and a config reload could
  not replace it.
- **The hosts are handed their scheme.** `Headless.main`, `Headless.shipped`
  and `Window.host` take the scheme as their first argument and are typed
  by it (`Headless.Collaborators β σ scheme`); no host module names a
  scheme.
- **The refusal.** With no scheme supplied, the headless mode, the window
  mode and `--probe` print `editor: no input scheme is installed: no
  package of this editor's package set supplies one` on stderr and exit 1
  (`Executable.Mode.needsScheme`, `lean/Editor/Main.lean`, "The input
  scheme"). The probe refuses so that the build of such a set fails at its
  probe and publishes nothing ("The build, as a job", step 6), and a
  `:restart` into such an editor is given up before the session is handed
  over (`lean/Editor/Restore/Restart.lean`).
  Checking at the set's build that a set has a scheme is left to later
  ([extension-points.md](extension-points.md), "A required extension
  point").
- **The default package `evil` supplies it** (`packages/evil/`, the
  features-as-packages roadmap's phase 7): its lakefile declares the
  keyword, and `Evil.EditorPackage.scheme` is `Editor.Evil.scheme`, the Vim
  scheme over its default states and bindings, named `vim`
  (`packages/evil/Evil/Compiled.lean`). The value is in `Evil.Compiled` and
  not in the entry module, which imports package modules and nothing else.
  The core's Lake package declares no keyword and no `scheme`, so the set
  of the core alone (`tests/empty-set`) has none: `ffi-test` runs its
  editor in the headless mode and with `--probe` and requires exit 1 and
  the refusal's line each time (`tests/headless/no-input-scheme`). Until
  that phase's commit that moved evil, the core's Lake package declared the
  keyword and `EditorCore.EditorPackage.scheme`.
- **A test drives the loop on a scheme a package supplies**:
  `ModelTest.schemePackageChecks` (`lean/ModelTest/Editor/InputScheme.lean`)
  registers a scheme written in the test as a `SchemePackage`, takes the
  one chosen and runs the loop on it, with no module of evil.
- **What themes asks of a scheme** is `InputScheme.cursorFaces`: the faces
  the scheme draws a cursor in, other than `cursor`, which the scheme
  contract holds to its reports (`cursorFacesReported`). The completeness
  check of a theme is the core's (`lean/Editor/Theme/Check.lean`, with the
  picture check `lean/Editor/Theme/Picture.lean`) and names no scheme: it
  holds a theme to the vocabulary's cursor faces (`Face.cursorNames`, the
  entries marked `cursor`), and a scheme's tests hold that each face it
  draws a cursor in is one of them (evil's `EvilTest.vimDefaultChecks`).

## The core imports check

`tools/core-imports-check.sh`, in `mise run ffi-test`, after the host
imports check ([the-gate.md](../dev-practices/the-gate.md), "The core
imports check"). It asks Lake for transitive imports (`lake query
+<module>:transImports`), reads no source text and builds nothing. Given
the root `Editor.Core` and the moving names, it holds three rules. The
roots of the build it holds the second and third of are the test
executables' (`ModelTest`, `ConfigTest`, `FfiTest`, `ContractTest`) and
the root generated for the default set, whose transitive imports it asks
of the set (`lake -d ../packages query :editorRootTransImports`):

1. **The root and what it imports hold no moving module.** A core module
   that comes to import a moving one fails the gate, naming the module
   reached.
2. **Every `Editor.…` module the build reaches is in the root's closure**,
   unless it is a moving module. A new core module nothing in the core
   imports fails the gate until `Editor.Core` imports it, so the root's
   closure is the whole core, and the first rule is a statement about
   every core module.
3. **A root that reaches the elaborator adapter reaches the config base**,
   which keeps the invariant the adapter's own import of `Editor` used to
   give.

**There is no moving name now, so the first rule holds of nothing.** A
moving name is for the time between cutting a feature's edges and moving
it: modules still under `lean/Editor/` that are not the core's. The
compile mode's (`Editor.Compile` and what was under it) was the last;
phase 6 moved it. A feature that has moved needs no name, because the
direction is then Lake's to hold: its modules are in another Lake package,
which the core does not require, so a core module that imported one would
not build. The rule and the argument stay for the next feature whose edges
are cut before it moves, and for one whose modules keep the name
`Editor.…` after they move.

The moving names are arguments, not derived from the graph: "everything the
root does not reach" would pass whatever the core imported. The gate runs
the check again to see each rule bite: told that a module of the core,
the ex line's data, is moving (`Editor.Core Editor.Ex.Line`, exit 1; a
feature still in the core was named here until the last, the ex line,
moved out in the features-as-packages roadmap's phase 8), pointed
at `Editor.Setup` (exit 3), and told a config base no executable's root
imports (`--base Editor.Core`, exit 4). Until phase 6 the first of these
pointed the check at the root `Editor`, the config base, which imported
the compile mode. A run in which no root of the build reaches the
elaborator adapter is refused (exit 2), since the third rule would then
hold of nothing; the gate sees that too. The generated root is the only
root that links the elaborator into the editor itself, so it is among the
roots the script checks for the base.

## Registration order is visible

A host registers the packages in the order it is handed them: the order
of the generated root, which is the set's packages by dependency ("The
order packages register in", above) and, inside one Lake package, the
order of its entry module's array. Two headless outputs print that order,
so it is part of what the fixtures pin:

- **The `commands:` lines** of `tests/headless/expected` and
  `tests/headless/bundle/expected` print every command name in
  registration order: the core's, then the default packages' after
  version control's, the minibuffer's nine, `execute-command`,
  `search-bindings`, the compile package's nine and at-point's nine, then
  config's.
- **The ex candidates for `e`** in `tests/headless/ex/expected` are the ex
  names in the order they were first bound (`Registry.exNames`), which the
  fuzzy rank keeps among equal scores. The names are bound by `ex`, then
  `version-control`, the third and the sixteenth packages of the core's
  list, then by `compile`, which registers after the core's seventeen.

`ModelTest.packageSetChecks` pinned what a model test could see of the
core's list while the core had one, at the end of the packages roadmap:
its 17 names in order, with no package of the palettes, the compile
mode, the mode line, the command prompt, the binding search, the
languages, the completion styles and displays, completion at point or the
minibuffer among them; the ex names in bound order, the `ex` package's
and then version control's twelve; and that the one theme it registers is
`default`. It was the test of the core's entry module
(`lean/ModelTest/EditorCore/EditorPackage.lean`), over
`EditorCore.EditorPackage.packages`, and went with that module in the
features-as-packages roadmap's phase 8: what each default package
registers, and in what order, is held by that package's own checks, and
`ModelTest.packageChecks` holds that a host handed no package starts from
a registry that holds nothing.

**Packages register by dependency, which puts a default package after the
core's.** The default set holds nine, so the generated root registers the
core's 17, then `completion`, `mode-line`, `minibuffer`,
`shipped-themes`, `execute-command`, `binding-search`, `compile`,
`at-point` and `languages` (the five interface packages register
nothing).

- **No fixture line changed when the palettes moved.** The package was
  thirteenth of the core's 22, directly after `themes`, and registered
  last. It registers themes alone, and no core package after `themes`
  defines a theme, so the theme names read `default`, `solarized-dark`,
  `solarized-light`, `fairy-floss`, as they did, and a package that
  registers no command and no ex name changes neither the `commands:`
  lines nor the ex candidates. Checked on the built editor: every
  `expected` under `tests/headless/` was unchanged.
- **The theme order is pinned by a fixture of the package**,
  `packages/shipped-themes/tests/headless/load-theme`, which prints the
  theme prompt's candidates on a config that defines no theme. The other
  fixtures that name a theme print the theme in force, not the order.
- **Five lines of three standing fixtures changed when the compile mode
  moved** (phase 6). The package was seventeenth of the core's 21, between
  `shell` and `at-point`, and registers after all of the core's now:
  - `tests/headless/expected`, lines 4 and 9, and
    `tests/headless/bundle/expected`, line 3 (the `commands:` lines): the
    nine names `compile`, `compile-command`, `recompile`,
    `compile-confirm`, `kill-compilation`, `compilation-output`,
    `next-error`, `previous-error` and `compile-goto-error` moved from
    before `at-point-complete` to after `vc-gutter-moved`, the last of the
    core's, and before config's own commands. No name was added or lost;
  - `tests/headless/ex/expected`, lines 17 and 18 (the ten candidates the
    ex line offers for `e`, and their decorations): `e`, `e!`,
    `next-error`, `previous-error`, `autoread`, `noautoread` and `reload`
    stay; `compile`, `compile-command` and `recompile` gave way to
    `vc-stage-hunk`, `vc-unstage-hunk` and `vc-worktrees`, which score the
    same and are bound first now.
- **Why they were let change, and the package's old place not kept.**
  Keeping it would take a way for one package to register in the middle
  of another Lake package's list, which no user's package would have: it
  would be a mechanism for the default packages alone, against the
  roadmap's goal that a default package is built and loaded as a
  third-party one is. Nothing a compile command does depends on the
  order. What changed for a user: the command prompt lists the compile
  commands after version control's, and `:e` no longer offers `compile`,
  `compile-command` and `recompile` among its ten; typing `:c` does.
- **What the compile mode's own fixtures show is unchanged by the move.**
  They print no order: `packages/compile/tests/headless/ex-names` and
  `config` were written against the editor with the compile mode in the
  core and moved with no byte changed ("The default package `compile`",
  above).

**Two lines of two standing fixtures changed when `main`'s working sets
were merged in**, and only by names added: `tests/headless/expected`,
lines 4 and 9, and `tests/headless/bundle/expected`, line 3 (the
`commands:` lines). The `evil` package's three new commands,
`jump-backward`, `jump-forward` and `set-mark`, follow `select-all`, the
last it registered before; and the two new packages, `project-search` and
`working-set`, which register directly after `workspace`, put their ten
commands after `find-file-in-another-workspace` and before `shell`'s,
`project-search`, `project-search-found`, `project-search-symbol`,
`project-search-visit`, then `working-set-add`, `working-set-open`,
`working-set-visit`, `working-set-remove`, `working-set-note` and
`working-set-refresh`. That is where `main` placed them in its compiled
arrays, so only the compile package's nine stay where phase 6 moved them.
Neither package binds an ex name, so `tests/headless/ex/expected` did not
change.

**Three lines of two standing fixtures changed when the command prompt
and the binding search moved** (the features-as-packages roadmap's phase
3), and none for the mode line or the languages:

- `tests/headless/expected`, lines 4 and 9, and
  `tests/headless/bundle/expected`, line 3 (the `commands:` lines):
  `execute-command` and `search-bindings`, the thirteenth and fourteenth
  packages of the core's 24 when the phase began, directly after
  `themes`, moved from after `load-theme` to after `vc-gutter-moved`, the
  last of the core's, and before the compile package's nine, in that
  order. No name was added or lost.
- **The mode line's segments register after version control's `review`
  now** (`mode-line` was second of the core's list): a listing names
  segments and resolves them by name, so no fixture shows it. **The
  languages registered last of the core's list and register last of the
  set**, so the `code` mode still follows version control's modes, and
  no line changed for it.
- **Why the old places were not kept**: the compile argument above. A
  default package registers by dependency, as a user's does, and nothing
  the two commands do depends on the order: the command prompt lists them
  after version control's commands now.
- **What the moved fixtures show is unchanged.** `command-prompt` and
  `binding-search` were written on the editor with both features in the
  core and moved with one line changed each, the config's import
  (`import ExecuteCommand`, `import BindingSearch`); `mode-line` moved
  byte for byte. Their `expected` files did not change, and none prints
  the order of the commands.

**Five lines of three standing fixtures changed when completion at point
and the minibuffer moved** (the features-as-packages roadmap's phase 4),
and none for the completion styles and displays:

- `tests/headless/expected`, lines 4 and 9, and
  `tests/headless/bundle/expected`, line 3 (the `commands:` lines), twice:
  - when at-point moved, its nine names, `at-point-complete`,
    `at-point-next`, `at-point-previous`, `at-point-tab`,
    `at-point-backtab`, `at-point-return`, `at-point-quit`,
    `at-point-triggered` and `at-point-paused`, moved from after
    `keyboard-quit` (the package was seventeenth of the core's 19, after
    `shell`) to after `compile-goto-error`, before config's `greet`;
  - when the minibuffer moved, its nine names, `minibuffer-accept`,
    `minibuffer-cancel`, `minibuffer-next`, `minibuffer-previous`,
    `minibuffer-insert`, `minibuffer-delete-backward`,
    `minibuffer-delete-to-start`, `minibuffer-ask` and
    `minibuffer-candidates`, moved from after `auto-reload-mode` (the
    package was second of the core's 18, after `files`) to after
    `vc-gutter-moved`, the last of the core's, before `execute-command`.

  No name was added or lost, and nothing else on those lines changed.
- `tests/headless/default-config/expected`, lines 19 and 20: the first ten
  rows of `SPC :`'s listing, the command prompt's, and their decorations.
  The five rows `minibuffer-accept` … `minibuffer-insert` are gone, and
  `move`, `normal`, `visual  v`, `visual-line  V` and `insert  i` follow
  `auto-reload-mode`; the name column is padded to 18 where it was 21,
  since the longest name among the ten was `minibuffer-previous` and is
  `auto-reload-mode`; and the decorations line gives the new rows'
  candidate and annotation ranges.
- **The completion styles and displays registered first of the core's
  list and register first of the set**, by being required first, so
  `fuzzy` and `minibuffer` are still the first style and display
  registered and the defaults, and no line changed for them.
- **Neither binds an ex name**, so `tests/headless/ex/expected` did not
  change.
- **Why the old places were not kept**: the compile argument above. A
  default package registers by dependency, as a user's does, and nothing
  the at-point or minibuffer commands do depends on the order: the
  command prompt lists them after version control's commands now, and
  `SPC :` with nothing typed no longer shows the minibuffer's.
- **What the moved fixtures show is unchanged.** `prompt`, `candidates`
  and `at-point` moved byte for byte, `at-point` with the shared config it
  ran on; `completion-choices` and `at-point-tuned` were written on the
  editor with the features in the core and moved with their configs'
  imports changed. Their `expected` files did not change.
- **The empty set's fixtures changed for what leaving a package out
  removes, not for order**: "Dropping `completion` …" and "Dropping
  `minibuffer` …", under "The default packages of the features-as-packages
  roadmap's phase 4", above.

**The `commands:` lines and two lines of `SPC :`'s listing changed when the
files cluster moved** (the features-as-packages roadmap's phase 6), each by
its D5 alone, and nothing else. The seven features registered before every
default package, all of them packages of the core's list; the set now
requires them first, in the core's order, so their order among themselves
and against the default packages is kept, and the one change is against
the nine packages still in the core's list (`evil` … `package-set`), which
register before every Lake package. After each move the moved feature's
commands come, in D5's order, directly after those of the last package
still in the core's list (`version-control-gutter`'s `vc-gutter-moved`
until version control moved, `package-set`'s `package-build-output` after),
and before `completion`'s (the minibuffer's `minibuffer-accept`, since
`completion` registers no command). The empty set's fixtures and
`tests/headless/ex/expected` did not change (version control's ex names
still follow ex's and come before compile's), and only the workspace binds
a key, in its prompt category alone, so `completion`'s style and display
are still the first registered.

- `tests/headless/expected`, lines 4 and 9 (the same line), and
  `tests/headless/bundle/expected`, line 3 (whose last name is config's
  `greet` where the others' is `squares`): the moved commands, in each
  commit, `switch-buffer list-buffers close-buffer` (C9), `open-file
  save-buffer edit-file reload-buffer auto-reload-mode` (C10),
  `workspace-current find-file-in-workspace find-file-in-project
  find-file-in-another-workspace` (C11), the working sets' six (C12),
  project search's four (C13), `shell-command shell-filter keyboard-quit`
  (C14) and version control's, `vc-status` … `vc-gutter-moved` (C15). Each
  state of the lines, verbatim, before C9 and after each move:

  before C9, as C1 pinned them:

  ```text
  commands: open-file save-buffer edit-file reload-buffer auto-reload-mode move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config switch-buffer list-buffers close-buffer toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused greet
  commands: open-file save-buffer edit-file reload-buffer auto-reload-mode move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config switch-buffer list-buffers close-buffer toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused squares
  ```

  after C9 (`buffers`):

  ```text
  commands: open-file save-buffer edit-file reload-buffer auto-reload-mode move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved switch-buffer list-buffers close-buffer minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused greet
  commands: open-file save-buffer edit-file reload-buffer auto-reload-mode move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved switch-buffer list-buffers close-buffer minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused squares
  ```

  after C10 (`files`):

  ```text
  commands: move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused squares
  commands: move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused greet
  ```

  after C11 (`workspace`):

  ```text
  commands: move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused squares
  commands: move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused greet
  ```

  after C12 (`working-set`):

  ```text
  commands: move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme project-search project-search-found project-search-symbol project-search-visit restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused squares
  commands: move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme project-search project-search-found project-search-symbol project-search-visit restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused greet
  ```

  after C13 (`project-search`):

  ```text
  commands: move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused squares
  commands: move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused greet
  ```

  after C14 (`shell`):

  ```text
  commands: move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh shell-command shell-filter keyboard-quit minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused squares
  commands: move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh shell-command shell-filter keyboard-quit minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused greet
  ```

  after C15 (`version-control`):

  ```text
  commands: move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused squares
  commands: move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused greet
  ```
- `tests/headless/default-config/expected`, lines 19 and 20: the first ten
  rows of `SPC :`'s listing and their decorations, when the files' commands,
  which were the first ten's first five, moved (C10). Old, then new:

  ```text
  view 2 0,0 0x0: "open-file         s-o, SPC ., SPC f f  Find file\nsave-buffer       s-s, SPC f s, SPC b s  Save file\nedit-file\nreload-buffer     SPC b r  Revert buffer\nauto-reload-mode\nmove\nnormal\nvisual            v\nvisual-line       V\ninsert            i", scroll 0, selections , padding 8 0
  decorations 2: minibuffer.candidate 0..48 minibuffer.annotation 18..48 minibuffer.candidate 49..99 minibuffer.annotation 67..99 minibuffer.candidate 100..109 minibuffer.candidate 110..150 minibuffer.annotation 128..150 minibuffer.candidate 151..167 minibuffer.candidate 168..172 minibuffer.candidate 173..179 minibuffer.candidate 180..199 minibuffer.annotation 198..199 minibuffer.candidate 200..219 minibuffer.annotation 218..219 minibuffer.candidate 220..239 minibuffer.annotation 238..239
  view 2 0,0 0x0: "move\nnormal\nvisual             v\nvisual-line        V\ninsert             i\nappend             a\ninsert-line-start  I\nappend-line-end    A\nself-insert\noperate", scroll 0, selections , padding 8 0
  decorations 2: minibuffer.candidate 0..4 minibuffer.candidate 5..11 minibuffer.candidate 12..32 minibuffer.annotation 31..32 minibuffer.candidate 33..53 minibuffer.annotation 52..53 minibuffer.candidate 54..74 minibuffer.annotation 73..74 minibuffer.candidate 75..95 minibuffer.annotation 94..95 minibuffer.candidate 96..116 minibuffer.annotation 115..116 minibuffer.candidate 117..137 minibuffer.annotation 136..137 minibuffer.candidate 138..149 minibuffer.candidate 150..157
  ```

**The `commands:` lines and two lines of `SPC :`'s listing changed when evil
and the themes moved** (the features-as-packages roadmap's phase 7), each
by its D6 alone, and nothing else. Evil's package was first in the core's
list and the themes' sixth, so both registered before every default
package; the default set now requires `evil`, then `themes`, before every
other default package, so their order against the default packages and
between them is kept, and the one change is against the seven packages
still in the core's list (`ex` … `package-set`), which register before
every Lake package. So evil's 41 commands, `move` … `set-mark`, which were
the first registered, follow `package-set`'s `package-build-output` and
come before the files' `open-file`; and `load-theme`, which followed the
tab commands' `tab-select-9`, follows evil's `set-mark`. Neither package
binds a key, and no command name is registered twice in the default set,
so nothing else can show the order. The theme `default` is still the
first theme registered, before the shipped palettes', so no line of the
shipped palettes' fixtures changed. The interface packages `evil-api` and
`themes-api` register nothing. The lines, verbatim, each on a line of its
own:

- `tests/headless/expected`, lines 4 and 9 (the same line): before the
  phase (as its first commit pinned them), after evil moved, and after the
  themes moved:

```text
commands: move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused greet
commands: ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused greet
commands: ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark load-theme open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused greet
```

- `tests/headless/bundle/expected`, line 3 (whose last name is config's
  `greet`), in the same three states:

```text
commands: move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused squares
commands: ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 load-theme restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused squares
commands: ex quit save-and-quit reload-config toggle-fullscreen minimise-window window-split window-split-vertically window-new window-close window-quit window-only window-focus-left window-focus-down window-focus-up window-focus-right window-focus-next window-focus-previous window-focus-top window-focus-bottom window-focus-last window-exchange window-rotate window-rotate-back window-balance window-taller window-shorter window-wider window-narrower window-zoom window-promote window-demote window-main-more window-main-fewer window-edge-left window-edge-bottom window-edge-top window-edge-right window-float tab-new tab-close tab-next tab-previous tab-switch tab-rename tab-move-right tab-move-left tab-select-1 tab-select-2 tab-select-3 tab-select-4 tab-select-5 tab-select-6 tab-select-7 tab-select-8 tab-select-9 restore-modes restart restart-abandon package-install package-remove package-update package-build-started package-build-output move normal visual visual-line insert append insert-line-start append-line-end self-insert operate select-object delete-char put-after put-before open-below open-above undo redo repeat scroll-down scroll-up scroll-page-down scroll-page-up scroll-line-to-top scroll-line-to-center scroll-line-to-bottom insert-delete-backward insert-delete-word-backward insert-newline insert-tab insert-left insert-right insert-up insert-down clipboard-cut clipboard-copy clipboard-paste select-all jump-backward jump-forward set-mark load-theme open-file save-buffer edit-file reload-buffer auto-reload-mode switch-buffer list-buffers close-buffer workspace-current find-file-in-workspace find-file-in-project find-file-in-another-workspace project-search project-search-found project-search-symbol project-search-visit working-set-add working-set-open working-set-visit working-set-remove working-set-note working-set-refresh shell-command shell-filter keyboard-quit vc-status vc-status-refresh vc-status-visit vc-status-toggle vc-status-stage vc-status-unstage vc-show vc-stage-hunk vc-unstage-hunk vc-commit vc-commit-accept vc-commit-abort vc-worktrees vc-worktrees-refresh vc-worktrees-visit vc-review vc-review-refresh vc-review-keep vc-review-revert vc-review-since vc-log vc-log-visit vc-log-refresh vc-blame vc-blame-visit vc-gutter-moved minibuffer-accept minibuffer-cancel minibuffer-next minibuffer-previous minibuffer-insert minibuffer-delete-backward minibuffer-delete-to-start minibuffer-ask minibuffer-candidates execute-command search-bindings compile compile-command recompile compile-confirm kill-compilation compilation-output next-error previous-error compile-goto-error at-point-complete at-point-next at-point-previous at-point-tab at-point-backtab at-point-return at-point-quit at-point-triggered at-point-paused squares
```

- `tests/headless/default-config/expected`, lines 19 and 20: the first ten
  rows of `SPC :`'s listing and their decorations. They were evil's first
  ten commands and are the core's first ten since evil moved; the themes'
  move did not change them. Old, then new:

```text
view 2 0,0 0x0: "move\nnormal\nvisual             v\nvisual-line        V\ninsert             i\nappend             a\ninsert-line-start  I\nappend-line-end    A\nself-insert\noperate", scroll 0, selections , padding 8 0
decorations 2: minibuffer.candidate 0..4 minibuffer.candidate 5..11 minibuffer.candidate 12..32 minibuffer.annotation 31..32 minibuffer.candidate 33..53 minibuffer.annotation 52..53 minibuffer.candidate 54..74 minibuffer.annotation 73..74 minibuffer.candidate 75..95 minibuffer.annotation 94..95 minibuffer.candidate 96..116 minibuffer.annotation 115..116 minibuffer.candidate 117..137 minibuffer.annotation 136..137 minibuffer.candidate 138..149 minibuffer.candidate 150..157
view 2 0,0 0x0: "ex                       :\nquit                     s-q\nsave-and-quit\nreload-config\ntoggle-fullscreen        C-s-f\nminimise-window          s-m\nwindow-split             SPC w s, C-w s, C-w S, C-w C-s  Split window\nwindow-split-vertically  SPC w v, C-w v, C-w C-v  Split window vertically\nwindow-new               SPC w n, C-w C-n  New window\nwindow-close             SPC w c, C-w C-c  Close window", scroll 0, selections , padding 8 0
decorations 2: minibuffer.candidate 0..26 minibuffer.annotation 25..26 minibuffer.candidate 27..55 minibuffer.annotation 52..55 minibuffer.candidate 56..69 minibuffer.candidate 70..83 minibuffer.candidate 84..114 minibuffer.annotation 109..114 minibuffer.candidate 115..143 minibuffer.annotation 140..143 minibuffer.candidate 144..213 minibuffer.annotation 169..213 minibuffer.candidate 214..287 minibuffer.annotation 239..287 minibuffer.candidate 288..341 minibuffer.annotation 313..341 minibuffer.candidate 342..397 minibuffer.annotation 367..397
```

### Phase 8 changed no fixture line

The features-as-packages roadmap's phase 8 moved the seven packages the
core's own list still held to the front of the default set, in the order
that list held them, and moved them in the reverse of that order (its
plan's D2): the package that moved was each time the last still in the
core's list, and the core's packages registered before every default
package, so after each commit every package registered where it had. The
compile mode's contributions became values at extension points, and their
reader keeps the registry's order, config's first (`Compile.hook`). In the
fixture set the seven register after the fixture packages, as every
feature the earlier phases moved does, and no fixture of that set shows
it. So no line of any headless fixture changed between the phase's first
commit and its last, and none was added or removed; the block below, which
would quote a changed line, is empty.

```text
```

## Build times

What `mise run lean` takes, before and after the editor came from a
package set (the packages roadmap's phase 4). The task runs `lean-test`
first, so each figure includes the model tests; after, it also includes
the fixture set: its packages' tests, its editor and its packages' builds.

Wall clock, in seconds, three runs of each case and their median, on one
machine (Apple M5 Max, 18 cores, 128 GB, macOS 27.2.1, Lean 4.35.0) on
2026-11-19. Before is `fcf4e47b`, the commit phase 4 started from; after is
`420430fb`, with the whole of the phase's build in place. (At `28aff3b2`,
before the fixture's linked test came to link the config base, the three
medians were 68.5, 12.8 and 33.2.)

| Case | Before | After | Change |
|---|---|---|---|
| Clean: Lake's build directories emptied (`lean/.lake/build`, and after, those of the three sets and both fixture packages); Cargo's `target/` kept | 58.8, 60.0, 61.1: **60.0** | 67.3, 69.8, 69.9: **69.8** | +9.8 |
| Nothing changed | 8.70, 8.73, 8.73: **8.7** | 12.69, 12.72, 12.82: **12.7** | +4.0 |
| Incremental: one private definition added to `lean/Editor/Shell.lean` | 27.9, 28.2, 28.2: **28.2** | 33.9, 34.0, 34.1: **34.0** | +5.8 |

- **Most of the added time is the fixture set, not the default set.** With
  nothing changed, the commands of the task take: the model tests 7.9 s;
  the fixture packages' tests 1.1 s; the refusal of the empty set
  0.4 s; the core's build 0.5 s; the default set's editor 0.5 s; and the
  fixture set's editor, its two packages and the linked test 2.0 s, which
  is five Lake runs. A Lake run with nothing to do costs 0.4 to 0.5 s, and
  the task makes about ten where it made two.
- **The incremental case relinks more.** A changed core module relinks
  three executables as before (`ffi-test`, `config-test`,
  `contract-test`) and the editor, and now also the fixture set's editor
  and the linked test, each a link of about 230 MB against the Rust
  archive.
- **The clean case** also elaborates and compiles the two generated roots
  and the fixture packages' modules, and links the second editor.
- **Not separated**: how much of each difference is the default set alone.
  With nothing to do it is the 0.5 s above; a clean build of the default
  set's root and editor alone was 2.4 s when the build was prototyped.
- **CI** caches `lean/.lake` only, so each run there also builds the
  generated roots, links the editors and builds the packages outside the
  core ([ci.md](../dev-practices/ci.md), "Caches").
- **Measured again with the first default package in place** (2026-11-19,
  the same machine, the tree of the packages roadmap's phase 5, three runs
  each). Nothing changed: 14.04, 14.06, 14.09, median **14.1** s, 1.4 s
  more than the 12.7 above. Clean, with the build directories of the
  default package and of `tests/empty-set` emptied too: 69.1, 70.8, 71.3,
  median **70.8** s, 1.0 s more than the 69.8 above. The incremental case
  was not measured again. What the task gained: the default package's
  test driver, its build and its linked test's link among the package
  steps, and one more editor, linked from `tests/empty-set`; with nothing
  to do that is three more Lake runs. The same modules are compiled as
  before, three of them in the package's build directory and not the
  core's, so the clean case moved by the extra links alone.
- **Measured again with the second default package in place**
  (2026-11-19, the same machine, the tree of the packages roadmap's
  phase 6, three runs each). Nothing changed: 15.28, 15.33, 15.52, median
  **15.3** s, 1.2 s more than the 14.1 above. Clean, with the build
  directories of the core, the three sets, both default packages and both
  fixture packages emptied: 77.95, 78.12, 80.05, median **78.1** s, 7.3 s
  more than the 70.8 above. The incremental case was not measured again.
  What the task gained: the compile package's test driver, which links an
  executable of its own and runs 98 checks, its build under its own
  linter options, and its linked test's link, a third of about 230 MB
  beside the fixture package's and the shipped themes'; with nothing to
  do that is three more Lake runs. The compile mode's modules and tests
  are compiled as before, in the package's build directory and not the
  core's, and the generated roots import one module more. How the 7.3 s
  divides among the extra links and the rest was not separated.
