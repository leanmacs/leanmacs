# Packages and the core

What the core is, what a package may import of it, how an editor is built
from the core and a set of packages, which modules are core and which are
features that could become packages, and what each feature would have to
cross to move out. Written by the packages roadmap: its phase 3 built the
core's root module, cut every import from the core into the two features
that move in that roadmap (the compile mode and the shipped palettes), and
put a check of that in the gate; its phase 4 built the package set and its
build, which links the editor; its phase 5 moved the shipped palettes out
of the core into the first default package, `shipped-themes`, and built
the check of what a package imports; its phase 6 moved the compile mode
out into the second, `compile`, published the core's test support as a
test kit for a package's tests, and made the base config is elaborated on
the package set's. What a package is and how a host registers one are in
[lean-runtime.md](lean-runtime.md), "Packages".

Every feature but the shipped palettes and the compile mode is still in
the core's Lake package (`lean/lakefile.lean`, the package `editor-core`).
The default package set (`packages/lakefile.toml`) requires the core and
two default packages, `shipped-themes` (`packages/shipped-themes/`) and
`compile` (`packages/compile/`). This document draws the lines later moves
cut along.

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
theirs.

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
- **The list of the core's packages is not a module of the editor.**
  `EditorCore.EditorPackage` (`lean/EditorCore/EditorPackage.lean`) is the
  entry module of the core's Lake package ("A package's entry module",
  below): its `packages` names every package still in that Lake package,
  in the one order the headless fixtures show
  ("Registration order is visible", below). It is a module outside
  `lean/Editor/` and outside the namespace `Editor`, in a library of its
  own (`lean_lib EditorCore`), which the generated root and the tests that
  need the list import. So it is no core module and no feature's, the
  core's root does not import it, and the core imports check, which is of
  the modules named `Editor.…`, exempts nothing by name. The Lake package
  is named `editor-core` for this: named `editor`, its entry module would
  be `Editor.EditorPackage`, under the namespace that check rules.
- **The executable's body is a core module, `Editor.Main`**
  (`lean/Editor/Main.lean`). `Editor.Main.run` takes the packages and the
  config base as values and acts on the mode the command line selects; the
  demonstration is there too. It is a module of the host, internal, and it
  imports neither a package nor the config base. `Editor.Core` imports it,
  and through it the hosts.
- **The executable's root is generated, not written.** No module under
  `lean/` defines `main` for the editor. The package-set build writes the
  root from the set's Lake packages: it imports the core's base,
  `Editor.Main` and each entry module, and its `main` is one call of
  `Editor.Main.run`, with the packages and the names of the base's modules
  ("The package set and its build", below).
- **A root that links the elaborator imports the config base.** The
  elaborator adapter (`Editor.Config.Elaborate`) imports the base's modules
  from their `.olean` files at runtime, and each must already be linked
  into the executable ([lean-runtime.md](lean-runtime.md), "One shared
  state"). The adapter used to import `Editor` to make that so, and through
  that import it, the headless host and the window host reached the
  compile mode. Now each root that links the adapter imports `Editor`
  beside it: the generated root, which also imports every other module of
  its base, the entry modules; `lean/ConfigTest/Check.lean`;
  `lean/FfiTest/Editor/Window/Real.lean`; and the root of a package's
  linked test that starts a host. The check below fails a root of the
  core's build that does not, the generated root of the default set among
  them.

## The package set and its build

**A package set is a Lake package whose `require`s are the set.** Its
lakefile declares no target and it holds no Lean source. The editor is
built from one:

- **The default set is `packages/lakefile.toml`** (the Lake package
  `default-set`). It requires the core (`editor-core`, from `../lean`) and
  the default packages, each of which has a directory under `packages/`
  and a `require` there. There are two, `shipped-themes`
  (`packages/shipped-themes/`, "The first default package", below) and
  `compile` (`packages/compile/`, "The default package `compile`", below),
  required in that order. It is the lakefile a user's set starts from.
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
| `editorShipped` | a package, the set | For `lake query`: what an app bundle ships of the set, built: one line `file<TAB><source><TAB><place>` a file (the core's `Editor` and `EditorCore` libraries and each other package's libraries but its tests, with their sources and every file Lake wrote; the lakefiles; the core's glue; the Rust archive), and one `oleans<TAB><place>` a `.olean` directory, for `tools/stage-bundle.sh` ([lean-runtime.md](lean-runtime.md), "The app ships the toolchain") |
| `editorPackages` | a package, the set | For `lake query`: the set's packages a gate step runs over, one a line |
| `editorPackageImports` | a package, the set | For `lake query`: each direct import of a core module by a module of those packages, one a line, with the module's kind (`library`, `test`, `linked`, `linked-test`); what the package imports check reads |
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
`shipped-themes` gives `ShippedThemes.EditorPackage`, and `editor-core`
gives `EditorCore.EditorPackage`.

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
  values, which register in the order the array lists them; the core's
  holds 23, and `shipped-themes`' and `compile`'s one each.
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
- **The core is not exempt**: its Lake package was renamed `editor-core`
  so that the convention gives it a module outside `Editor/` ("The core
  and its root", above). That is also the name the staged core of the
  user-side link has, so one set lakefile can name the core built here and
  the core the app ships.

### The order packages register in

The set's packages are visited from the set, **each after the packages it
`require`s**, and those in the order its lakefile declares them
(`setPackages` in `lean/lakefile.lean`). So:

- a package registers after every package it depends on;
- the core's packages come first, since every package with an entry module
  requires the core;
- packages that do not depend on each other register in the order the
  set's lakefile names them.

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
import EditorCore.EditorPackage
import ShippedThemes.EditorPackage
import Compile.EditorPackage

def main (args : List String) : IO UInt32 :=
  Editor.Main.run (EditorCore.EditorPackage.packages ++ ShippedThemes.EditorPackage.packages ++ Compile.EditorPackage.packages) #[`Editor, `ShippedThemes.EditorPackage, `Compile.EditorPackage] { setName := "default-set", pin := "leanprover/lean4:v4.35.0\n" } args
```

with a module doc and a doc string, since it is built with the core's Lean
options and a warning in it fails the build. It imports each entry module
of the set in order and appends their `packages` in that order; a set of
the core alone (`tests/empty-set`) passes the core's array as it is and
the base `Editor` alone. The last value before the arguments is what the
build says of the editor for the files it generates in a config directory
("A config directory requires the core and the set", below): the set's Lake name and the
text of the core's `lean-toolchain`. The gate requires the default set's root to
import exactly these five modules (`lake -d ../packages query
:editorRootImports`, in `ffi-test`), and its base to be the three named
(`:editorBase`).

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
  three directories, the core's, then `shipped-themes`' and `compile`'s,
  and the fixture set's seven, the core's, `greeting`'s, `greeting-loud`'s,
  `echo`'s, `shipped-themes`', `compile`'s and `word-count`'s, each
  holding its package's modules.
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
  23, and fewer as features move out.
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
  reaches each of them, `shipped-themes` and `compile`. The default set's own
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
  library need a place the driver does not import. **A check that starts
  a host is in the root itself**, `<P>Test/Linked.lean`: only that module
  may import the headless host, the config base and the core's entry
  module ("What a package may import", below), so a module under
  `<P>Test/Linked/` cannot hold it. `GreetingTest.Linked` and
  `CompileTest.Linked` each hold theirs.
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
  facet lists every module's imports. `shipped-themes` declares its
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
  `Editor.TabBar` and `Editor.Themes.Check`, which are API, and the test
  double `Editor.Config.Packages`; its linked test module imports the test
  double `Editor.Themes.Picture`. The package imports check holds that
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
  requires the core alone. `mise run lean` links an editor from it and
  `ffi-test` runs the core's fixture `tests/headless/core-themes` on that
  editor: it starts in the theme `default`, `load-theme` offers `default`
  and the theme config defines and no palette, and a palette's name is
  answered with `load-theme: no theme is registered as …`.
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
phase 6. The default set requires it after `shipped-themes`, so every
editor built from the default set, or from a set that requires the default
set, holds it. It is the first package with behaviour: commands, a job
over the process service, a major mode, ex names and contributions.

| Path | What |
|---|---|
| `README.md` | What the package gives, and a walk through its source and tests in reading order, for a package author |
| `lakefile.toml` | The package: it requires the core by path, declares the library `Compile` with `globs = ["Compile.*"]`, the test library `CompileTest` and the test driver `compile-test`, and turns every linter on |
| `Compile.lean` | The commands and the run: `compile`, `compile-command`, `recompile`, `kill-compilation`, the output's commands, the locations and the steps over them, the mode `compilation` (from `lean/Editor/Compile.lean`) |
| `Compile/Errors.lean`, `Compile/Contribution.lean`, `Compile/Shipped.lean` | The matcher and the sites it yields; the offers and the formats in use; `cargo-mode`, `lake-mode` and `mise-mode` with rustc's and Lean's formats |
| `Compile/Compiled.lean` | The `Package` value `Editor.Compile.package`, still named `compile`: nine commands, the job `compile-run`, the mode, the three contributions and six ex names |
| `Compile/EditorPackage.lean` | The entry module: `packages := #[Editor.Compile.package]`. It imports `Compile.Compiled`, and so the whole library, which is what config sees of the package |
| `CompileTest/Model.lean` | The test driver's root, which runs the ten model lists, 98 checks, in the test modules that mirror the library's (`CompileTest/Compile.lean`, `CompileTest/Compile/…`), over the support in `CompileTest/Support/Compile.lean` |
| `CompileTest/Linked.lean` | The linked test's root: the two lists over the real process service (`CompileTest/Linked/Compile.lean`, `CompileTest/Linked/Compile/Shipped.lean`) and, in the root itself, a compile in a headless host; 7 checks |
| `tests/headless/ex-names`, `config`, `shipped-formats` | Its headless fixtures |
| `tests/linked/run/` | The script the host check runs, and the lines the host must print |
| `tests/compile/` | The fixtures of the checks over the real process service: `three-lines`, the programs that stand for cargo, lake, mise and git, and the trees the shipped modes are checked in |

- **Its library imports the core's API alone**, eleven modules, with no
  addition to the API: `Editor.Api`, `Editor.Command.Call`, `Editor.File`,
  `Editor.Json`, `Editor.Mode`, `Editor.Package`, `Editor.ProjectMode`,
  `Editor.ProjectMode.Format`, `Editor.ProjectMode.Listing`,
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
  (`lean/Editor/ProjectMode.lean`, `lean/Editor/ProjectMode/Format.lean`);
  the listing, its store `compile-listings` and its job `compile-list`,
  which the `workspace` package registers
  (`lean/Editor/ProjectMode/Listing.lean`); `compileContribution` and
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
  passed to the rig, which names no feature outside the core. The root
  adds `hostCheck`: the headless host over the core's packages and this
  one's, in a temporary working directory, runs
  `tests/linked/run/script`, which starts a child that writes one error
  line and blocks, steps to its location, kills it and recompiles; each
  line of `tests/linked/run/holds` must be part of a line the host
  printed. The output holds the temporary directory's path, which is why
  it is not a headless fixture compared with a file. It prints `compile
  linked test: 7 checks passed`.
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
- **It carries its own copy of the git fixture** (`tests/compile/bin/git`,
  a byte-for-byte copy of the core's `tests/workspaces/git`): a linked
  test runs in its package's directory, and a package that read
  `../../tests/workspaces` could not be fetched from anywhere else later.
- **Dropping the package leaves an editor that starts.** The editor of
  `tests/empty-set` loads config and answers `:compile` with `compile: not
  an ex command`, the words it has for `:bogus`
  (`tests/headless/core-ex-names`, in `ffi-test`). The listing job stays
  registered there and lists a contribution's commands, which nothing
  then reads.
- **The app bundle carries its modules**, built, in this package's own
  build directory under `Contents/Resources/lean/set`, and `bundle-test`
  runs the fixture `config` from
  a staged bundle with an empty environment.

### The fixture set

Three packages and a set under `tests/packages/`, used by tests alone. They
showed the path a default package and a user's package take before any
feature moved, and they still show what the default package does not: a
package that requires another package, and a linked test that starts a
host. The set requires the default set, so its editor holds the default
packages too, and the example package of the guide to writing a package,
`docs/packages/word-count/`, so the gate's package steps cover the code the
guide quotes.

| Path | What |
|---|---|
| `tests/packages/lakefile.toml` | The fixture set, `fixture-set`: it requires `greeting-loud`, then `echo`, then the default set, and through it `shipped-themes` and `compile`, then `word-count` |
| `tests/packages/greeting/` | The Lake package `greeting`: the commands `greeting-hello` and `greeting-reply` (`Greeting.lean`), its entry module, its test driver (`GreetingTest/Model.lean`, which runs `GreetingTest/Greeting.lean`), its linked test (`GreetingTest/Linked.lean`, with the config it loads in `tests/linked/config`) and the fixture `tests/headless/hello` |
| `tests/packages/greeting-loud/` | The Lake package `greeting-loud`, which requires `greeting` and registers `greeting-reply` again with another text; its test driver and the fixture `tests/headless/reply` |
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
default set, each default package (`shipped-themes`, `compile`), the
fixture set, each fixture package (`echo` among them), the writing guide's
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
`lean/` holds a copy of it** (the default set and its packages
`shipped-themes` and `compile`, the fixture set and its three packages, the
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
  objects of every module of the core's two libraries (`Editor` and
  `EditorCore`), the core's glue (`glue.o`), the core's Rust archive
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
- **A `lakefile.lean`** is never edited: the commands say they edit
  `lakefile.toml` only.
- **The core's require, at the root, last** (packages phase 12). Each
  edit writes `editor-core` at the lakefile's root by the running editor's
  core directory, as the last require (`withCoreEdit`, `withCore`): any
  `editor-core` table is taken out before the edit, whatever its source,
  and the core's added after the last `[[require]]` table once the edit is
  made, so an installed package comes before it. A lakefile whose last
  require is already that directory is left as it is by `withCore`. So every edit
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

The core package `package-set` (`lean/Editor/PackageSet/Compiled.lean`,
the 24th, right after `restore`) registers `:package-install <name>
<path>|<git url> [<rev>]` or `<scope>/<name> [<version>]`,
`:package-remove <name>` and `:package-update [<name> [<rev>]]`. Each edit
("The lakefile's edits") is computed from the lakefile as the last reload
read it, and written by the job `package-edit`, which reads the file again
first and refuses one that changed since ("the lakefile changed since the
last reload; :reload and try again"); its command then asks for a reload,
which compares the fingerprints and starts the build. `:package-update`
with no rev edits nothing: the lakefile names what is required and the
manifest pins the revision, so it starts the build with `lake update` for
the named package, or every git and Reservoir one.

A config file named `Config/EditorPackage.lean` would be taken as the
`config` package's entry module and linked; nothing refuses it yet.

## What a package may import

The core's API is the set of core modules a package may name in an `import`
line. It is defined by a rule over the module map, and each row of the map
says which side of the rule its modules are on.

This is the rule as built. As the remaining features move out it becomes
three layers, the core, interface packages and implementation packages,
with no package importing an implementation package
([extension-points.md](extension-points.md), "Three layers").

- **A package may import any core module that is not internal.** The rule
  is about `import` lines. Lean's imports are transitive, so a module an
  importable module imports is visible to the package's code whether or not
  the package may name it; what the rule limits is what a package depends
  on by name, which is what a later rename or move can break.
- **A package's tests may also import the core's test doubles**: the pure
  models of the ports (`….Model`), the contracts and cases (`….Contract`,
  `….Cases`), the fakes (`Editor.Completion.Fake`, `Editor.Job.Fake`), the
  test scheme (`Editor.InputScheme.Test`), the loop's driver
  (`Editor.Loop.Driver`), the reading of what a package registers
  (`Editor.Config.Packages`: `Package.registered`,
  `Config.State.ofPackages`), the theme picture check
  (`Editor.Themes.Picture`), and the core's model test kit, `Editor.Test`
  and every module under it but `Editor.Test.Linked`: the support the
  core's own model tests are written on (`Editor.Test.…`, 14 modules). A
  package's tests are the modules under `<P>Test`.
- **A package's linked test may also import the linked test kit, and only
  it**: `Editor.Test.Linked` and every module under it (4 modules), the
  rig of the core's checks over the real services. The linked test is the
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
  (`Editor.Headless`), the config base (`Editor`) and the core's entry
  module (`EditorCore.EditorPackage`). The module `<P>Test.Linked` is an
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
    `Editor.Executable`, `Editor.Version`, `Editor.ModuleLookup`);
  - the loop and its dispatch (`Editor.Loop`, `Editor.Command.Dispatch`,
    `Editor.Event.Queue`, `Editor.State.Outbox`);
  - the config session (`Editor.Config.*`, but for `Editor.Config.Packages`,
    a test double);
  - the raw bindings (`Editor.Ffi`, `Editor.Ffi.*`);
  - the real bindings of the ports and what runs them (`….Real`,
    `Editor.Clipboard.InProcess`, `Editor.Display.Recorder`,
    `Editor.Job.Runner`, `Editor.Job.Jobs`, `Editor.Job.Table`,
    `Editor.Job.Pool`);
  - the modules that define the packages still in the core
    (`….Compiled`);
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
  the modules it uses, not the base. Nor is `EditorCore.EditorPackage`,
  which is no module of the core: it imports the packages, and no package
  imports it. Nor is any other module of the core's Lake package that is
  not named `Editor.…`, such as the core's own test modules. The root of a
  linked test alone names the base and the entry module, above.
- **A feature still in the core is importable where its row says so.** The
  compile mode imports `Editor.Shell` and `Editor.Workspace.Modes`, which
  are features' modules; until those features move they are core modules a
  package may import.
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
  above). **The lists are in the script**: the test doubles, the linked
  test kit, the internal modules, and what the linked test's root may
  import beyond them, as names and patterns. No module lists the
  API: a core module that is neither internal nor a test double is part
  of it. A change to the rule changes the script, this section and the
  lines the gate holds the script to (`tests/package-imports/`).

Checked against the graph at `6ba99de5`, before either feature moved:
every core module the two features' modules imported directly was
importable. The compile mode's modules imported
`Editor.Api`, `Editor.Command.Call`, `Editor.File`, `Editor.Json`,
`Editor.Mode`, `Editor.Package`, `Editor.ProjectMode`,
`Editor.ProjectMode.Format`, `Editor.ProjectMode.Listing`, `Editor.Shell`
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
(`lean/Editor/Test/Listing.lean`), the contribution and the format data
have checks of their own (`ModelTest.contributionChecks`,
`ModelTest.formatDataChecks`), and what the compile mode makes of them is
checked in its own test modules, which moved with it. The three test
modules outside the compile mode's own that still named it then went as
follows:

- `ModelTest.Support.Compile`, the compile checks' own support, moved with
  them (`packages/compile/CompileTest/Support/Compile.lean`);
- `ConfigTest.Editor.Headless`, which holds `ConfigTest.shippedChecks`,
  the test of the core's list as the executable's hosts register it,
  states that the list holds nothing of the compile mode;
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
`ModelTest.packageSetChecks` state the core's list alone: 24 packages, the
one theme `default`, and nothing of the compile mode.

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
| `Editor.Test.Config` | Config fixtures: registered commands, faces, themes, bindings, the loop's context |
| `Editor.Test.Loop` | The command loop stepped on the editor's models, with keymaps and commands written in the test |
| `Editor.Test.Driver` | The loop's driver over the editor's models and the job model, and what a check reads back from it |
| `Editor.Test.Files` | The file commands' keys, files and driver |
| `Editor.Test.Workspace` | The workspace's world, jobs, commands, keys and driver |
| `Editor.Test.Shell` | The shell command's jobs, bindings, commands and replies |
| `Editor.Test.Prompts` | Prompts and the minibuffer: their commands, bindings, registry and driver |
| `Editor.Test.Listing` | A contribution with a listing and its world, which names core modules only |

The linked kit:

| Module | What it holds |
|---|---|
| `Editor.Test.Linked.Jobs` | Jobs on the real runner: how long a check waits, a job's outcome as a check compares it |
| `Editor.Test.Linked.Trees` | Temporary directories of a check's own, and files written into them |
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
  `CompileTest.Linked` imports `Editor`, `Editor.Headless` and
  `EditorCore.EditorPackage` for its check of a host, and
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
  went with the compile mode is what reads them: the matcher and the
  sites it yields (`packages/compile/Compile/Errors.lean`), and the offers
  and the formats in use (`packages/compile/Compile/Contribution.lean`). No general
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
  (`packages/compile/Compile/Compiled.lean`) and the `version-control`
  package its twelve (`lean/Editor/VersionControl/Compiled.lean`). The `ex`
  package keeps the files', its own and the buffers', which are features
  still in the core, and imports neither the compile mode nor version
  control. Version control's names moved with compile's in phase 3
  although version control stays in the core, so that the names were bound
  in the order they had been; the compile package's are bound after
  version control's since it moved ("Registration order is visible").
- **The `themes` package and `shipped-themes`.** The `themes` package
  (`lean/Editor/Themes/Compiled.lean`) keeps `load-theme`, the theme
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

Every module under `lean/Editor/`, 303 of them
(`find lean/Editor -name '*.lean' | wc -l`; 254 at `6ba99de5`, phase 4
added `Editor.Main`, phase 5 added `Editor.Themes.Picture` and moved
the three modules of the shipped palettes out, phase 6 moved the five
of the compile mode out and added the 18 of the test kit, phase 7 added
six to the config session, and the merge of
`main` that brought the working sets, project search, the jump list and
marks added 19, session-restore phase 1 added six, and phase 2 six more,
the store codec and five of the reconciler's records and formats), is
**core** or part of a **feature that could become a package**. The counts
below add up to 303: 210 core and 93 in 22 features.

- **Core** is what a host with no packages needs to start and run: the
  ports with their models and bindings, the state, the scene and display
  types, the loop, the setup port, the config session and the hosts; and
  any module a core module imports for a type it carries (`Editor.Ex.Line`,
  `Editor.Menu`, `Editor.ModeLine`, `Editor.Language`, `Editor.Workspace`,
  the three `Editor.ProjectMode` modules).
- **A feature** is code reached through a package's registrations: the 24
  packages of the core's list, as 23 features (the two version-control packages are
  one), with the Vim scheme counted with evil.
- **Every feature here is in the core's Lake package**,
  and is a core module in the sense of the section above and of the gate's
  check. The map guides later moves; it does not commit to them. The
  shipped palettes and the compile mode are no longer in the map: they are
  the Lake packages `shipped-themes` and `compile` ("The first default
  package" and "The default package `compile`", above).

One row covers modules that share a class and a side of the import rule.
"A package may import it" is `yes`, `in tests` (a test double) or `no`
(internal).
"Under it" counts the modules below a name, not the module of that name.

| Modules | Count | Class | A package may import it |
|---|---|---|---|
| `Editor.Core` | 1 | core | no |
| The hosts and the executable's modules: `Editor.Main`, `Editor.Headless`, `.Headless.CommandLine`, `Editor.Window`, `.Window.Real`, `Editor.WindowCheck`, `.WindowCheck.Real`, `Editor.Executable`, `Editor.Version`, `Editor.ModuleLookup` | 10 | core | no |
| The loop and its dispatch: `Editor.Loop`, `Editor.Command.Dispatch`, `Editor.Event.Queue`, `Editor.State.Outbox` | 4 | core | no |
| The session's journal reconciler, which the loop runs after each publish, and the data and formats it keeps: `Editor.Restore`, `.Restore.Kept`, `.Restore.Journal`, `.Restore.Document`, `.Restore.Records`, `.Restore.Indexed`, `.Restore.Frame`, `.Restore.Workspaces`, `.Restore.Value` | 9 | core | no |
| The config session: `Editor.Config.Diagnostic`, `.Directory`, `.Display`, `.Elaborate`, `.ExactPath`, `.LakePackage`, `.Lakefile`, `.Lakefile.Toml`, `.Owner`, `.Registry`, `.Reload`, `.Session`, `.Stores` | 13 | core | no |
| What a package registers, read by a test: `Editor.Config.Packages` | 1 | core | in tests |
| The raw bindings: `Editor.Ffi` and the 27 modules under it | 28 | core | no |
| The real bindings of ports and what runs them: `Editor.Clipboard.Real`, `.Clipboard.InProcess`, `Editor.Command.Real`, `Editor.Display.Real`, `.Display.Recorder`, `Editor.Fuzzy.Real`, `Editor.Job.Real`, `.Job.Runner`, `.Job.Jobs`, `.Job.Table`, `.Job.Pool`, `Editor.SyntaxTree.Real`, `Editor.Text.Real`, `Editor.Watch.Real` | 14 | core | no |
| The models: `Editor.Clipboard.Model`, `Editor.Command.Model`, `Editor.Config.Elaborator.Model`, `Editor.Diff.Model`, `Editor.Display.Model`, `Editor.File.Model`, `Editor.FileWatch.Model`, `Editor.Fuzzy.Model`, `Editor.Grep.Model`, `Editor.Job.Model`, `Editor.Process.Model`, `Editor.SyntaxTree.Model`, `.Model.Json`, `.Model.Query`, `Editor.Text.Model`, `Editor.Watch.Model` | 16 | core | in tests |
| The contracts and cases: `Editor.Clipboard.Contract`, `Editor.Completion.Contract`, `.AtPointContract`, `.DisplayContract`, `.StyleContract`, `Editor.Config.Elaborator.Contract`, `Editor.Display.Contract`, `Editor.Fuzzy.Contract`, `Editor.InputScheme.Contract`, `Editor.Job.Contract`, `Editor.SyntaxTree.Contract`, `Editor.Text.Contract`, `Editor.Watch.Contract`, `Editor.Api.Cases`, `Editor.File.Cases`, `Editor.UndoTree.Cases` | 16 | core | in tests |
| The fakes, the test scheme and the loop's driver: `Editor.Completion.Fake`, `Editor.Job.Fake`, `Editor.InputScheme.Test`, `Editor.Loop.Driver` | 4 | core | in tests |
| The model test kit: `Editor.Test.Completion`, `.Config`, `.Driver`, `.Files`, `.Geometry`, `.Jobs`, `.Keys`, `.Listing`, `.Loop`, `.Models`, `.Prompts`, `.Shell`, `.States`, `.Workspace` | 14 | core | in tests |
| The linked test kit: `Editor.Test.Linked.Jobs`, `.Rig`, `.Services`, `.Trees` | 4 | core | in tests |
| The editor API and what is proved of it: `Editor.Api`, `.Api.Theorems`, `Editor.UndoTree`, `.UndoTree.Theorems` | 4 | core | yes |
| The composite port and a command: `Editor.Command`, `.Call`, `.Control`, `.Registry`, `.Append`, `Editor.Program` | 6 | core | yes |
| The ports: `Editor.Clipboard`, `Editor.Diff`, `.Diff.Script`, `Editor.Display`, `Editor.File`, `Editor.FileWatch`, `Editor.Fuzzy`, `Editor.Grep`, `Editor.Job`, `Editor.Process`, `.Process.Environment`, `Editor.SyntaxTree`, `Editor.Text`, `Editor.Watch` | 14 | core | yes |
| The setup port, packages and stores: `Editor.Setup`, `Editor.Package`, `Editor.Store`, `.Store.Codec`, `Editor.Value`, `Editor.Json` | 6 | core | yes |
| The state: `Editor.State`, `.State.Request`, `Editor.Event`, `Editor.DisplayRules`, `Editor.Floating`, `Editor.Layout`, `Editor.GeneratedView`, `Editor.ExcerptView`, `Editor.Gutter`, `Editor.Workspace` | 10 | core | yes |
| Places, jump lists and marks, which the state holds and the loop follows through edits: `Editor.JumpList`, `Editor.Marks`, `.Marks.Follow`, `Editor.Jumps` | 4 | core | yes |
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
| `Editor.Completion.Styles`, `.Displays` | 2 | feature: completion | yes |
| `Editor.Completion.Compiled` | 1 | feature: completion | no |
| `Editor.Evil.Compiled` | 1 | feature: evil | no |
| `Editor.Evil` and 12 of the modules under it (all but `.Compiled`); `Editor.InputScheme.Vim`, `.Vim.Default` | 15 | feature: evil | yes |
| `Editor.Ex` | 1 | feature: ex | yes |
| `Editor.Ex.Compiled` | 1 | feature: ex | no |
| `Editor.ExecuteCommand` | 1 | feature: execute-command | yes |
| `Editor.ExecuteCommand.Compiled` | 1 | feature: execute-command | no |
| `Editor.Files`, `Editor.Completion.Paths`, `Editor.Jumps.Go` | 3 | feature: files | yes |
| `Editor.Files.Compiled` | 1 | feature: files | no |
| `Editor.FrameCommands` | 1 | feature: frame-commands | yes |
| `Editor.FrameCommands.Compiled` | 1 | feature: frame-commands | no |
| `Editor.Language.Compiled` | 1 | feature: languages | no |
| `Editor.Menu.Compiled` | 1 | feature: menu | no |
| `Editor.Minibuffer` | 1 | feature: minibuffer | yes |
| `Editor.Minibuffer.Compiled` | 1 | feature: minibuffer | no |
| `Editor.ModeLine.Compiled` | 1 | feature: mode-line | no |
| `Editor.ProjectSearch`, `.ProjectSearch.Run` | 2 | feature: project-search | yes |
| `Editor.ProjectSearch.Compiled` | 1 | feature: project-search | no |
| `Editor.Shell` | 1 | feature: shell | yes |
| `Editor.Shell.Compiled` | 1 | feature: shell | no |
| `Editor.TabCommands` | 1 | feature: tab-commands | yes |
| `Editor.TabCommands.Compiled` | 1 | feature: tab-commands | no |
| `Editor.Themes`, `Editor.Themes.Check` | 2 | feature: themes | yes |
| `Editor.Themes.Compiled` | 1 | feature: themes | no |
| `Editor.Themes.Picture`, the theme picture check | 1 | feature: themes | in tests |
| `Editor.VersionControl.Compiled` | 1 | feature: version-control | no |
| `Editor.VersionControl.Model`, `.Contract` | 2 | feature: version-control | in tests |
| `Editor.VersionControl` and 16 of the modules under it (all but `.Compiled`, `.Model` and `.Contract`) | 17 | feature: version-control | yes |
| `Editor.WindowCommands` | 1 | feature: window-commands | yes |
| `Editor.WindowCommands.Compiled` | 1 | feature: window-commands | no |
| `Editor.WorkingSet`, `.WorkingSet.Disk`, `.WorkingSet.Places`, `.WorkingSet.Refind`, `.WorkingSet.Run` | 5 | feature: working-set | yes |
| `Editor.WorkingSet.Compiled` | 1 | feature: working-set | no |
| `Editor.Restore.Run` | 1 | feature: restore | yes |
| `Editor.Restore.Compiled` | 1 | feature: restore | no |
| `Editor.Workspace.Compiled` | 1 | feature: workspace | no |
| `Editor.Workspace.Model`, `.Contract` | 2 | feature: workspace | in tests |
| `Editor.Workspace.Attach`, `.Finder`, `.FindFile`, `.FindInProject`, `.Lister`, `.Modes`, `.Projects`, `.Reach` | 8 | feature: workspace | yes |

### What each feature would have to cross

For each feature, from each module's `import` lines, which are Lake's
direct imports (`lake query +<module>:imports`), at the head of the
packages roadmap's phase 6, with the compile mode moved out and the test
kit published (the lists were first computed at `6ba99de5`, and computed
again for this section then). The merge of `main` that brought the working
sets, project search, the jump list and marks added the entries
`project-search` and `working-set` and amended `buffers`, `evil`, `files`,
`version-control` and `workspace` for the modules it added and the imports
of them; the rest were not computed again for it:

- its modules;
- the core modules that import one of them, each with what it imports (the
  core's root, `Editor.Core`, imports every feature's `Compiled` module
  and is left out, as is the list of the core's packages,
  `EditorCore.EditorPackage`, which is outside `lean/Editor/`);
- the modules of the core's test kit that import one of them
  (`Editor.Test.…`), which are core modules too, and a test double: a
  feature that moved out would take its part of the kit with it, or the
  kit would be split;
- the other features' modules that import one of them;
- the other features it imports;
- the modules of a package outside the core that import one of them, its
  tests' among them (`packages/`, with the Lake package's name first);
- the core's test modules that import one of them, other than its own
  tests, which are the test modules that mirror its modules' paths (a
  `Support` module is listed even where it is that feature's own helper,
  since it would move or be split with it); names are written without the
  `Editor.` after the test root, and "the root" is the test executable's
  root module;
- which of its modules the core's config base (`Editor`) imports, so that
  config can call them;
- the reaches by name it is known to have, which the import graph does not
  show: a command named in the Vim scheme's default tables, in a menu, by
  an ex name or in the default config. **These are not exhaustive.**

#### `at-point`

- **Modules** (3): `AtPoint`, `AtPoint.Compiled`, `Completion.Words`.
- **Core modules that import it**: `Loop` (`AtPoint`).
- **The test kit's modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: none.
- **Modules of packages outside the core that import it**: none.
- **Test modules outside its own tests that import it** (9): `ModelTest`: `Completion.AtPointContract`, `Config.Registry`, `Config.Reload`, `InputScheme.Vim.Default`, `Loop`, `Support.AtPoint`, `Support.Evil`; `ConfigTest`: `Bench`, `Headless`.
- **The config base imports**: `AtPoint`, `Completion.Words`.
- **Reaches by name** (not exhaustive): the Vim scheme's default tables name its commands (`at-point-complete`, `at-point-next` and the rest, `InputScheme/Vim/Default.lean`), and the loop asks it by import.

#### `binding-search`

- **Modules** (2): `BindingSearch`, `BindingSearch.Compiled`.
- **Core modules that import it**: none.
- **The test kit's modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: none.
- **Modules of packages outside the core that import it**: none.
- **Test modules outside its own tests that import it** (2): `ModelTest`: `Completion.Contract`; `ConfigTest`: `ExecuteCommand`.
- **The config base imports**: `BindingSearch`.
- **Reaches by name** (not exhaustive): the default config binds `search-bindings` (`config/default`).

#### `buffers`

- **Modules** (2): `Buffers`, `Buffers.Compiled`.
- **Core modules that import it**: none.
- **The test kit's modules that import it**: `Test.Files` (`Buffers.Compiled`).
- **Other features' modules that import it**: ex: `Ex.Compiled` (`Buffers`); version-control: `VersionControl.Commit` (`Buffers`).
- **Other features it imports**: files (`Files`); working-set (`WorkingSet.Places`, which `Buffers` imports to detach a closed buffer's ranges).
- **Modules of packages outside the core that import it**: none.
- **Test modules outside its own tests that import it** (6): `ModelTest`: `Completion.Contract`, `DisplayRules`, `VersionControl.Gutter`, `Support.Buffers`; `ConfigTest`: `Headless`, `Minibuffer`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the `ex` package binds `b`, `ls` and `bd` to its commands; the default config binds `switch-buffer`, `list-buffers` and `close-buffer`.

#### `compile`

Moved out of the core by phase 6: the Lake package `compile`
(`packages/compile/`; "The default package `compile`", above). It has
nothing left to cross. No core module and no test of a core module
imports it, and Lake would refuse the import: the core requires no
package. It imports two features' modules that are still the core's,
`Shell` and `Workspace.Modes`, and when either feature moves into a
package it requires that package. What reaches it by name: config names
its declarations through the set's base (`Compile.cargoMode`); the face
vocabulary lists `compilation.error`, `compilation.warning` and
`compilation.note` (`Face/Vocabulary.lean`), which every palette defines;
it reads the store `compile-listings` and starts the job `compile-list`,
both the core's; and its six ex names need the `ex` package for a line to
run them.

#### `completion`

- **Modules** (3): `Completion.Compiled`, `Completion.Displays`, `Completion.Styles`.
- **Core modules that import it**: `Command.Dispatch` (`Completion.Styles`); `Loop` (`Completion.Displays`, `Completion.Styles`); `Setup` (`Completion.Displays`, `Completion.Styles`).
- **The test kit's modules that import it**: `Test.Driver` (`Completion.Styles`); `Test.Files` (`Completion.Styles`); `Test.Linked.Rig` (`Completion.Displays`, `Completion.Styles`); `Test.Loop` (`Completion.Displays`); `Test.Prompts` (`Completion.Displays`, `Completion.Styles`).
- **Other features' modules that import it**: none.
- **Other features it imports**: none.
- **Modules of packages outside the core that import it**: compile: `CompileTest.Linked.Compile` (`Completion.Displays`, `Completion.Styles`).
- **Test modules outside its own tests that import it** (33): `ModelTest`: `Api`, `AtPoint`, `Completion.Contract`, `Completion.DisplayContract`, `Completion.Filtering`, `Completion.Style`, `Completion.StyleContract`, `Config.Packages`, `Config.Registry`, `Config.Reload`, `Ex`, `Face.Vocabulary`, `Files`, `Loop`, `Setup`, `State`, `TabBar`, `TabCommands`, `Themes`, `Workspace`, `Support.AtPoint`, `Support.Candidates`, `Support.Evil`; `ConfigTest`: `Bench`, `AtPoint`, `Completion.Keys`, `Headless`, `Minibuffer`, `Support.Hosts`; `FfiTest`: `State`; `ContractTest`: `Completion.StyleContract`, `Shell`, `Watch.Real`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the names `fuzzy`, `orderless`, `path` and `minibuffer`, which config chooses with `useStyle`, `useStyleFor`, `useDisplay`, and which the file prompt's category is given (`path`).

#### `evil`

- **Modules** (16): `Evil`, `Evil.Clipboard`, `Evil.Compiled`, `Evil.Jumps`, `Evil.Marks`, `Evil.Motions`, `Evil.Objects`, `Evil.Operators`, `Evil.Registers`, `Evil.Repeat`, `Evil.Scroll`, `Evil.Theorems`, `Evil.TreeObjects`, `Evil.Undo`, `InputScheme.Vim`, `InputScheme.Vim.Default`.
- **Core modules that import it**: `Headless` (`InputScheme.Vim.Default`).
- **The test kit's modules that import it**: `Test.Config` (`InputScheme.Vim`).
- **Other features' modules that import it**: menu: `Menu.Compiled` (`Evil.Clipboard`); project-search: `ProjectSearch.Run` (`Evil.Motions`); themes: `Themes.Check` (`InputScheme.Vim.Default`), `Themes.Picture` (`InputScheme.Vim`).
- **Other features it imports**: files (`Jumps.Go`, which `Evil` imports to go to a mark).
- **Modules of packages outside the core that import it**: none.
- **Test modules outside its own tests that import it** (27): `ModelTest`: `Api`, `AtPoint`, `ExcerptView`, `Face.Vocabulary`, `InputScheme.Contract`, `Loop`, `Menu`, `Minibuffer`, `State`, `TabBar`, `TabCommands`, `WindowCommands`, `Workspace.FindInProject`, `Support.AtPoint`, `Support.Evil`, `Support.Excerpt`, `Support.OperatorRows`, `Support.Views`, `Support.Vim`, `Support.Windows`; `ConfigTest`: `Bench`, `DefaultConfig`, `Headless`, `Indent`, `Support.Syntax`; `FfiTest`: `ExcerptView`; `ContractTest`: `SyntaxTree.Real`.
- **The config base imports**: `Evil.Clipboard`, `Evil.Jumps`, `Evil.Operators`, `Evil.Repeat`, `Evil.Scroll`, `Evil.Theorems`, `Evil.TreeObjects`, `Evil.Undo`, `InputScheme.Vim.Default`.
- **Reaches by name** (not exhaustive): every command the Vim scheme's default tables name is looked up when its key is pressed, evil's own and other features'; the `menu` package names `undo` and `redo` as strings; the face vocabulary and the completeness check name the cursor face of each Vim state (`Themes/Check.lean`); the headless and window hosts are typed by `Vim.Default.scheme` (the section on input schemes, below).

#### `ex`

- **Modules** (2): `Ex`, `Ex.Compiled`.
- **Core modules that import it**: `Loop` (`Ex`).
- **The test kit's modules that import it**: `Test.Files` (`Ex`, `Ex.Compiled`); `Test.Shell` (`Ex`, `Ex.Compiled`).
- **Other features' modules that import it**: frame-commands: `FrameCommands.Compiled` (`Ex`); window-commands: `WindowCommands` (`Ex`).
- **Other features it imports**: buffers (`Buffers`); files (`Files`); shell (`Shell`).
- **Modules of packages outside the core that import it**: none.
- **Test modules outside its own tests that import it** (11): `ModelTest`: `Completion.Contract`, `Evil`, `FrameCommands`, `Loop`, `Menu`, `Support.Buffers`, `Support.Frame`, `Support.Windows`; `ConfigTest`: `Headless`, `Support.Configs`; `ContractTest`: `Shell`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the Vim scheme's default tables name `ex`; `frame-commands` binds a key to `quit` and `window-quit` runs it, both by its name; the `version-control` package and, outside the core, the `compile` package bind ex names, which need this package for a line to run them.

#### `execute-command`

- **Modules** (2): `ExecuteCommand`, `ExecuteCommand.Compiled`.
- **Core modules that import it**: none.
- **The test kit's modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: none.
- **Modules of packages outside the core that import it**: none.
- **Test modules outside its own tests that import it** (2): `ModelTest`: `Completion.Contract`; `ConfigTest`: `Headless`.
- **The config base imports**: `ExecuteCommand`.
- **Reaches by name** (not exhaustive): the default config binds `execute-command`.

#### `files`

- **Modules** (4): `Completion.Paths`, `Files`, `Files.Compiled`, `Jumps.Go`.
- **Core modules that import it**: `Loop` (`Files`).
- **The test kit's modules that import it**: `Test.Files` (`Completion.Paths`, `Files`, `Files.Compiled`); `Test.Linked.Rig` (`Files`, `Files.Compiled`); `Test.Workspace` (`Files`).
- **Other features' modules that import it**: buffers: `Buffers` (`Files`); evil: `Evil` (`Jumps.Go`); ex: `Ex` (`Files`), `Ex.Compiled` (`Files`); menu: `Menu.Compiled` (`Files`); project-search: `ProjectSearch.Run` (`Files`, `Jumps.Go`); shell: `Shell` (`Files`); working-set: `WorkingSet.Disk` (`Files`), `WorkingSet.Run` (`Files`, `Jumps.Go`); version-control: `VersionControl.Gutter` (`Files`), `VersionControl.Review` (`Files`), `VersionControl.Show` (`Files`), `VersionControl.Stage` (`Files`), `VersionControl.Status` (`Files`); workspace: `Workspace.FindFile` (`Files`).
- **Other features it imports**: workspace (`Workspace.Attach`); working-set (`WorkingSet.Places`, which `Files` imports to hold a file's ranges again when it opens).
- **Modules of packages outside the core that import it**: compile: `CompileTest.Compile` (`Files`).
- **Test modules outside its own tests that import it** (20): `ModelTest`: `Buffers`, `Command.Dispatch`, `Completion.Contract`, `DisplayRules`, `Ex`, `Loop`, `Menu`, `State`, `VersionControl.Stage`, `Window`, `Workspace.Attach`, `Workspace.FindFile`, `Support.Buffers`, `Support.VersionControl`; `ConfigTest`: `Bench`, `Ex`, `Headless`, `Loop`, `VersionControl.Gutter`, `Support.Configs`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the `ex` package binds `w`, `w!`, `e`, `e!`, `autoread` and `noautoread` to its commands; the `menu` package's Open and Save; the workspace finder accepts through `open-file` (`Workspace/FindFile.lean`); the default config binds `open-file`, `save-buffer` and `reload-buffer`.

#### `frame-commands`

- **Modules** (2): `FrameCommands`, `FrameCommands.Compiled`.
- **Core modules that import it**: none.
- **The test kit's modules that import it**: none.
- **Other features' modules that import it**: menu: `Menu.Compiled` (`FrameCommands`).
- **Other features it imports**: ex (`Ex`).
- **Modules of packages outside the core that import it**: none.
- **Test modules outside its own tests that import it** (4): `ModelTest`: `Menu`, `Support.Frame`; `ConfigTest`: `Headless`; `FfiTest`: `Window.Real`.
- **The config base imports**: `FrameCommands`.
- **Reaches by name** (not exhaustive): the `menu` package's Minimise and Enter Full Screen.

#### `languages`

- **Modules** (1): `Language.Compiled`.
- **Core modules that import it**: none.
- **The test kit's modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: none.
- **Modules of packages outside the core that import it**: none.
- **Test modules outside its own tests that import it** (1): `ConfigTest`: `Headless`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): opening a file sets the mode `code` (`Language.codeName`, a core module's name) and chooses a language from the table this package fills.

#### `menu`

- **Modules** (1): `Menu.Compiled`.
- **Core modules that import it**: none.
- **The test kit's modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: evil (`Evil.Clipboard`); files (`Files`); frame-commands (`FrameCommands`).
- **Modules of packages outside the core that import it**: none.
- **Test modules outside its own tests that import it** (5): `ModelTest`: `Evil.Clipboard`, `Menu`, `Support.Frame`; `ConfigTest`: `Headless`; `FfiTest`: `Window.Real`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): none known.

#### `minibuffer`

- **Modules** (2): `Minibuffer`, `Minibuffer.Compiled`.
- **Core modules that import it**: none.
- **The test kit's modules that import it**: `Test.Files` (`Minibuffer`, `Minibuffer.Compiled`); `Test.Prompts` (`Minibuffer`, `Minibuffer.Compiled`); `Test.Shell` (`Minibuffer`, `Minibuffer.Compiled`).
- **Other features' modules that import it**: none.
- **Other features it imports**: none.
- **Modules of packages outside the core that import it**: compile: `CompileTest.Support.Compile` (`Minibuffer`).
- **Test modules outside its own tests that import it** (21): `ModelTest`: `Api`, `BindingSearch`, `Evil`, `Evil.Clipboard`, `Ex`, `ExecuteCommand`, `Files`, `InputScheme.Vim.Default`, `Loop`, `Themes`, `Workspace.FindInProject`, `Support.Buffers`, `Support.Candidates`, `Support.Evil`, `Support.FindFile`; `ConfigTest`: `Bench`, `Files`, `Headless`, `Themes`, `VersionControl.Gutter`, `Support.Configs`.
- **The config base imports**: `Minibuffer`.
- **Reaches by name** (not exhaustive): the Vim scheme's default tables name its commands (`minibuffer-accept`, `minibuffer-cancel` and the rest); every feature that asks a prompt needs this package for the prompt to be answered.

#### `mode-line`

- **Modules** (1): `ModeLine.Compiled`.
- **Core modules that import it**: none.
- **The test kit's modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: none.
- **Modules of packages outside the core that import it**: none.
- **Test modules outside its own tests that import it** (2): `ConfigTest`: `Bench`, `Support.Hosts`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the default order of the mode line names its segments (`ModeLine.Order.standard`: `state`, `buffer`, `modified`, `changed`, `directory`).

#### `project-search`

- **Modules** (3): `ProjectSearch`, `ProjectSearch.Compiled`, `ProjectSearch.Run`.
- **Core modules that import it**: none.
- **The test kit's modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: evil (`Evil.Motions`); files (`Files`, `Jumps.Go`); workspace (`Workspace.FindFile`).
- **Modules of packages outside the core that import it**: none.
- **Test modules outside its own tests that import it** (5): `ModelTest`: `WorkingSet.Run`, `Support.WorkingSet`; `ConfigTest`: `DefaultConfig`, `Headless`; `ContractTest`: `WorkingSet.Run`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the default config binds `project-search` and `project-search-symbol`; `working-set-add` pins a row of its results buffer as its file's range, found as `project-search-visit` finds it (`WorkingSet/Run.lean`).

#### `shell`

- **Modules** (2): `Shell`, `Shell.Compiled`.
- **Core modules that import it**: none.
- **The test kit's modules that import it**: `Test.Shell` (`Shell`, `Shell.Compiled`).
- **Other features' modules that import it**: ex: `Ex` (`Shell`).
- **Other features it imports**: files (`Files`).
- **Modules of packages outside the core that import it**: compile: `Compile` (`Shell`).
- **Test modules outside its own tests that import it** (1): `ModelTest`: `InputScheme.Vim.Default`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): none known beyond its imports: the ex line's `:!` calls it, and so does the compile mode, from its package.

#### `shipped-themes`

Moved out of the core by phase 5: the Lake package `shipped-themes`
(`packages/shipped-themes/`; "The first default package", above). It has
nothing left to cross. No core module and no test of a core module
imports it, and Lake would refuse the import: the core requires no
package. What reaches it by name: config names a palette (`useTheme` with
`solarized-light`, as the package's fixture `shipped-themes` does), and
the user asks `load-theme` for one.

#### `tab-commands`

- **Modules** (2): `TabCommands`, `TabCommands.Compiled`.
- **Core modules that import it**: none.
- **The test kit's modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: window-commands (`WindowCommands`).
- **Modules of packages outside the core that import it**: none.
- **Test modules outside its own tests that import it** (4): `ModelTest`: `Completion.Contract`, `InputScheme.Vim.Default`, `Support.Windows`; `ConfigTest`: `Headless`.
- **The config base imports**: `TabCommands`.
- **Reaches by name** (not exhaustive): the Vim scheme's tab table and the default config name its commands (`tab-new`, `tab-close`, `tab-next` and the rest).

#### `themes`

- **Modules** (4): `Themes`, `Themes.Check`, `Themes.Compiled`, `Themes.Picture`.
- **Core modules that import it**: none.
- **The test kit's modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: evil (`InputScheme.Vim`, `InputScheme.Vim.Default`).
- **Modules of packages outside the core that import it**: shipped-themes: `ShippedThemesTest.Linked.ShippedThemes` (`Themes.Picture`), `ShippedThemesTest.ShippedThemes` (`Themes.Check`).
- **Test modules outside its own tests that import it** (9): `ModelTest`: `Appearance`, `Completion.Contract`, `ExecuteCommand`, `Face.Vocabulary`; `ConfigTest`: `ExecuteCommand`, `Headless`, `Minibuffer`; `FfiTest`: `ExcerptView`, `Support.Scenes`.
- **The config base imports**: `Themes`.
- **Reaches by name** (not exhaustive): the default config binds `load-theme`; the theme `default` is the one in force when config names none (`Theme.defaultName`); the package `shipped-themes`, outside the core, imports `Themes.Check` and `Themes.Picture` in its tests.

#### `version-control`

- **Modules** (20): `VersionControl`, `VersionControl.Blame`, `VersionControl.Commit`, `VersionControl.Compiled`, `VersionControl.Contract`, `VersionControl.Git`, `VersionControl.Gutter`, `VersionControl.HistoryRead`, `VersionControl.Hunk`, `VersionControl.Log`, `VersionControl.Model`, `VersionControl.Plumbing`, `VersionControl.Porcelain`, `VersionControl.Review`, `VersionControl.ReviewHunks`, `VersionControl.Show`, `VersionControl.Stage`, `VersionControl.Status`, `VersionControl.Views`, `VersionControl.Worktrees`.
- **Core modules that import it**: `Loop` (`VersionControl.Gutter`).
- **The test kit's modules that import it**: none.
- **Other features' modules that import it**: working-set: `WorkingSet.Disk` (`VersionControl`, `VersionControl.Git`); workspace: `Workspace.FindInProject` (`VersionControl.Git`), `Workspace.Projects` (`VersionControl`).
- **Other features it imports**: buffers (`Buffers`); files (`Files`); workspace (`Workspace.Attach`, `Workspace.Reach`).
- **Modules of packages outside the core that import it**: none.
- **Test modules outside its own tests that import it** (8): `ModelTest`: `the root`, `Workspace.FindInProject`, `Workspace.Projects`, `Support.Git`, `Support.VersionControl`; `ContractTest`: `the root`, `Support.Git`, `Support.VersionControl`.
- **The config base imports**: `VersionControl.Commit`, `VersionControl.Stage`.
- **Reaches by name** (not exhaustive): the default order of the mode line names its segment `review`; its twelve `vc-` ex names are its own package's.

#### `window-commands`

- **Modules** (2): `WindowCommands`, `WindowCommands.Compiled`.
- **Core modules that import it**: none.
- **The test kit's modules that import it**: none.
- **Other features' modules that import it**: tab-commands: `TabCommands` (`WindowCommands`).
- **Other features it imports**: ex (`Ex`).
- **Modules of packages outside the core that import it**: none.
- **Test modules outside its own tests that import it** (3): `ModelTest`: `InputScheme.Vim.Default`, `Support.Windows`; `ConfigTest`: `Headless`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the Vim scheme's `C-w` table and the default config name its commands (`window-split`, `window-close` and the rest).

#### `working-set`

- **Modules** (6): `WorkingSet`, `WorkingSet.Compiled`, `WorkingSet.Disk`, `WorkingSet.Places`, `WorkingSet.Refind`, `WorkingSet.Run`.
- **Core modules that import it**: none.
- **The test kit's modules that import it**: none.
- **Other features' modules that import it**: buffers: `Buffers` (`WorkingSet.Places`); files: `Files` (`WorkingSet.Places`).
- **Other features it imports**: files (`Files`, `Jumps.Go`); version-control (`VersionControl`, `VersionControl.Git`); workspace (`Workspace.Attach`).
- **Modules of packages outside the core that import it**: none.
- **Test modules outside its own tests that import it** (3): `ModelTest`: `Support.WorkingSet`; `ConfigTest`: `DefaultConfig`, `Headless`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the default config binds `working-set-add` and `working-set-open`. Its ranges are held while the editor runs through `files` and `buffers`, which import `WorkingSet.Places` to hold them again when a file opens and detach them when its buffer closes: moving it out would need a hook the core offers for both, where the import is now.

#### `restore`

- **Modules** (2): `Restore.Compiled`, `Restore.Run`. The journal's reconciler, `Restore`, with `Restore.Kept`, `Restore.Journal`, `Restore.Document` and phase 2's `Restore.Records`, `Restore.Indexed`, `Restore.Frame`, `Restore.Workspaces` and `Restore.Value`, is core: the loop runs it after each publish and the state holds what it keeps.
- **Core modules that import it**: none.
- **The test kit's modules that import it**: none.
- **Other features' modules that import it**: none.
- **Other features it imports**: files (`Files`, for `Files.adopt` and `Files.limit`).
- **Modules of packages outside the core that import it**: none.
- **Test modules outside its own tests that import it** (2): `ConfigTest`: `Headless`, `Bench` (through `EditorCore.EditorPackage`); `ContractTest`: `Restore.Run`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the hosts start its job `restore` by name (`Headless.Request.restore`), and the loop journals only where that job is registered.

#### `workspace`

- **Modules** (11): `Workspace.Attach`, `Workspace.Compiled`, `Workspace.Contract`, `Workspace.FindFile`, `Workspace.FindInProject`, `Workspace.Finder`, `Workspace.Lister`, `Workspace.Model`, `Workspace.Modes`, `Workspace.Projects`, `Workspace.Reach`.
- **Core modules that import it**: none.
- **The test kit's modules that import it**: `Test.Linked.Rig` (`Workspace.Compiled`); `Test.Listing` (`Workspace.Model`, `Workspace.Modes`); `Test.Shell` (`Workspace.Attach`); `Test.Workspace` (`Workspace.Attach`, `Workspace.Model`, `Workspace.Modes`).
- **Other features' modules that import it**: files: `Files` (`Workspace.Attach`); project-search: `ProjectSearch.Run` (`Workspace.FindFile`); version-control: `VersionControl.Views` (`Workspace.Attach`), `VersionControl.Worktrees` (`Workspace.Reach`); working-set: `WorkingSet.Run` (`Workspace.Attach`).
- **Other features it imports**: files (`Files`); version-control (`VersionControl`, `VersionControl.Git`).
- **Modules of packages outside the core that import it**: compile: `Compile` (`Workspace.Modes`), `CompileTest.Compile` (`Workspace.Attach`, `Workspace.Model`, `Workspace.Modes`), `CompileTest.Compile.Shipped` (`Workspace.Model`, `Workspace.Modes`), `CompileTest.Linked.Compile.Shipped` (`Workspace.Modes`).
- **Test modules outside its own tests that import it** (13): `ModelTest`: `the root`, `Completion.Contract`, `ProjectMode.Listing`, `VersionControl.Gutter`, `VersionControl.Worktrees`, `Support.FindFile`, `Support.VersionControl`; `ConfigTest`: `Bench`, `DefaultConfig`, `Headless`, `VersionControl.Gutter`; `ContractTest`: `the root`, `Workspace`.
- **The config base imports**: none of its modules directly.
- **Reaches by name** (not exhaustive): the default config binds `find-file-in-workspace` and `find-file-in-project`; its package registers the job `compile-list`, which the compile mode, in its package, starts by name.

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
the check again to see each rule bite: told that a feature still in the
core, the shell, is moving (`Editor.Core Editor.Shell`, exit 1), pointed
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
  registration order: the core's, then the compile package's nine after
  version control's, then config's.
- **The ex candidates for `e`** in `tests/headless/ex/expected` are the ex
  names in the order they were first bound (`Registry.exNames`), which the
  fuzzy rank keeps among equal scores. The names are bound by `ex`, then
  `version-control`, the sixth and the twenty-first packages of the core's
  list, then by `compile`, which registers after the core's twenty-three.

`ModelTest.packageSetChecks` pins what a model test can see of the core's
list: its 23 names in order, with no package of the palettes or of the
compile mode among them; the ex names in bound order, the `ex` package's
and then version control's twelve; and that the one theme it registers is
`default`. It is the test of the core's entry module
(`lean/ModelTest/EditorCore/EditorPackage.lean`), over
`EditorCore.EditorPackage.packages`.

**Packages register by dependency, which puts a default package after the
core's.** The default set holds two, so the generated root registers the
core's 23, then `shipped-themes`, then `compile`.

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
