# Packages and the core

What the core is, what a package may import of it, how an editor is built
from the core and a set of packages, which modules are core and which are
features that could become packages, and what each feature would have to
cross to move out. Written by the packages roadmap: its phase 3 built the
core's root module, cut every import from the core into the two features
that move in that roadmap (the compile mode and the shipped palettes), and
put a check of that in the gate; its phase 4 built the package set and its
build, which links the editor. What a package is and how a host registers
one are in [lean-runtime.md](lean-runtime.md), "Packages".

Every feature is still in the core's Lake package (`lean/lakefile.lean`,
the package `editor-core`), and the default package set
(`packages/lakefile.toml`) requires the core alone. This document draws the
lines the later phases cut along: phase 5 moves the shipped palettes out
into the first default package and phase 6 the compile mode.

## The core and its root

**The core** is every module under `lean/Editor/` except the modules of
the two features that move out in this roadmap, called **the moving
modules** here: the compile mode (`Editor.Compile` and every module under
it, phase 6) and the shipped palettes (`Editor.Themes.Solarized`,
`Editor.Themes.FairyFloss` and `Editor.Themes.Shipped`, phase 5).

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
- **The list of the core's packages is not a module of the editor.**
  `EditorCore.EditorPackage` (`lean/EditorCore/EditorPackage.lean`) is the
  entry module of the core's Lake package ("A package's entry module",
  below): its `packages` names every package still in that Lake package,
  the moving ones among them, in the one order the headless fixtures show
  ("Registration order is visible", below). It is a module outside
  `lean/Editor/` and outside the namespace `Editor`, in a library of its
  own (`lean_lib EditorCore`), which the generated root and the tests that
  need the list import. So it is no core module and no feature's, the
  core's root does not import it, and the core imports check, which is of
  the modules named `Editor.…`, exempts nothing by name. The Lake package
  is named `editor-core` for this: named `editor`, its entry module would
  be `Editor.EditorPackage`, under the namespace that check rules.
- **The executable's body is a core module, `Editor.Main`**
  (`lean/Editor/Main.lean`). `Editor.Main.run` takes the packages as a
  value and acts on the mode the command line selects; the demonstration
  is there too. It is a module of the host, internal, and it imports
  neither a package nor the config base. `Editor.Core` imports it, and
  through it the hosts.
- **The executable's root is generated, not written.** No module under
  `lean/` defines `main` for the editor. The package-set build writes the
  root from the set's Lake packages: it imports the config base,
  `Editor.Main` and each entry module, and its `main` is one call of
  `Editor.Main.run` ("The package set and its build", below).
- **A root that links the elaborator imports the config base.** The
  elaborator adapter (`Editor.Config.Elaborate`) imports the base's modules
  from their `.olean` files at runtime, and each must already be linked
  into the executable ([lean-runtime.md](lean-runtime.md), "One shared
  state"). The adapter used to import `Editor` to make that so, and through
  that import it, the headless host and the window host reached the
  compile mode. Now each root that links the adapter imports `Editor`
  beside it: the generated root, `lean/ConfigTest/Check.lean`,
  `lean/FfiTest/Editor/Window/Real.lean`. The check below fails a root
  that does not, the generated root of the default set among them.

## The package set and its build

**A package set is a Lake package whose `require`s are the set.** Its
lakefile declares no target and it holds no Lean source. The editor is
built from one:

- **The default set is `packages/lakefile.toml`** (the Lake package
  `default-set`). It requires the core (`editor-core`, from `../lean`) and
  nothing else yet; each default package gets a directory under `packages/`
  and a `require` there (phase 5 adds the first). It is the lakefile a
  user's set starts from.
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
  user (phases 7 and 8), and the shipped core will supply the same facets
  over prebuilt pieces (phase 9).

| Facet | On | Gives |
|---|---|---|
| `editor` | a package, the set | `<set>/.lake/build/bin/editor`, and beside it `editor.oleans`, the record of where the set's `.olean` directories are |
| `editorApp` | a package, the set | `<set>/.lake/build/Leanmacs.app`, from the set's `editor` ([building.md](../dev-practices/building.md), "The app bundle") |
| `editorLinked` | a module | An executable rooted at that module, linked as the editor is, in its package's `bin/`, named as the module with a dash for each dot |
| `editorRoot` | a package, the set | For `lake query`: writes the set's root module and prints its path; links and builds nothing |
| `editorRootImports`, `editorRootTransImports` | a package, the set | For `lake query`: the generated root's direct and transitive imports, one module a line |
| `editorPackages` | a package, the set | For `lake query`: the set's packages a gate step runs over, one a line |

`linkAsEditor` is the one link: a root module's object and those of every
module it imports, with their symbols exported (`-rdynamic`), then the glue
and the Rust archive, then the link arguments. `editor` and `editorLinked`
both call it, and the core's test executables are `lean_exe`s configured
to the same line. The editor built this way has the same size, minimum
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
  holds 22.
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

### The generated root

`EditorSetRoot`, written to `<set>/.lake/build/root/EditorSetRoot.lean`,
and only when its text would change. For the default set it is:

```lean
import Editor
import Editor.Main
import EditorCore.EditorPackage

def main (args : List String) : IO UInt32 :=
  Editor.Main.run (EditorCore.EditorPackage.packages) args
```

with a module doc and a doc string, since it is built with the core's Lean
options and a warning in it fails the build. For a set with more packages
it imports each entry module in order and appends their `packages` in that
order.

- **It imports the config base, `Editor`**, for the link alone, as every
  root that links the elaborator does ("The core and its root", above).
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
- **So the build records where the modules are, for the editor it links.**
  The set's build directory holds the editor and its root and no other
  module, so an editor run directly cannot find the modules config is
  elaborated on relative to itself. The `editor` facet writes
  `<set>/.lake/build/bin/editor.oleans`: the `.olean` directory of each
  Lake package of the set that holds a library, one a line, absolute, the
  core's first and each other package after the ones it requires. Outside
  a bundle the editor's default `.olean` directory is the first of them
  ([lean-runtime.md](lean-runtime.md), "Start-up and shutdown";
  `lean/Editor/ModuleLookup.lean`). One is enough while the config base's
  modules are all the core's; the list is what the elaborator's search
  path grows to when the base holds a package's modules (phase 6 moves
  the compile mode, which the base imports, out of the core). The gate
  starts the window mode's wiring for both sets' editors with that default
  and requires config to load (`ffi-test window-host-direct`), and checks
  the fixture set's record names its three directories in order.
- **What "no hand-written list of packages" means.** No module names the
  Lake packages of a set: the set's lakefile is the one place, and the
  root is generated from it. Each Lake package's entry module still lists
  its own `Package` values, which is what the root reads. The core's lists
  22 until features move out.
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
  package after the core (`ffi-test`). What is left for a later phase is
  shipping the generator: on a user's machine there is no checkout to ask,
  so the prebuilt core must carry the facets (phase 9).

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
  ("The fixture set", below);
- **its headless fixtures** are the directories
  `<package>/tests/headless/<name>/`, each a `config/`, a `script` and an
  `expected`, run on the editor built from the set.

| Step | Per package | In task |
|---|---|---|
| `test` | `lake -d <package> test --wfail`; a package with no test driver fails the step | `lean-test`, with the `cargo` that fails first on the `PATH` |
| `build` | Once, the set's `editor`; then `lake -d <package> build --wfail`, the package's default targets under its own linter options; and its linked test's executable | `lean` |
| `fmt` (`format` rewrites) | `lean-fmt format --check` and `lean-fmt check`, with `--root <package>`, from the formatter's host | `lean-fmt` (`lean-format`) |
| `run` | The linked test, in the package's directory; then each headless fixture on the set's `editor`, compared with its `expected`. It prints what it ran, and the gate requires the fixture packages' linked test and fixtures among it | `ffi-test` |

- **The packages a step runs over** are those of the set that are path
  dependencies and hold a Lean library, other than the core, which the
  gate's own tasks cover. A step exits 2 when there is none, so it cannot
  pass by running over nothing, and `lean-test` shows that on a set kept
  for it, `tests/empty-set`, which requires the core alone.
- **The gate gives the steps the fixture set**, which requires the default
  set. So the default packages are run over through it from phase 5 on,
  and the default set's own `editor` is built beside it, for the standing
  fixtures under `tests/headless/`.
- **A package's headless fixtures are excluded from the formatter** by a
  `lean-fmt.toml` in the package (`exclude = ["tests/**"]`): a config chunk
  is Lean with no import line, elaborated on the config base at runtime,
  and does not compile as a module of the package.
- **The fixture packages' tests import internal modules.** Their model
  tests read what a package registers through `Config.State.ofPackages`
  (`Editor.Config.Packages`, `Editor.Config.Reload`), and the linked test
  runs a command on the real text binding (`Editor.Text.Real`), starts the
  headless host (`Editor.Headless`), shuts the library down with the
  bindings that come with it, and names the core's entry module for the
  set's packages. The import
  rule ("What a package may import", below) does not allow a package's
  tests those. Nothing checks the rule yet; phase 5, which adds the check,
  settles what a package's tests may import.

### The fixture set

Two packages and a set under `tests/packages/`, used by tests alone. They
show the path a default package and a user's package take before any
feature moves.

| Path | What |
|---|---|
| `tests/packages/lakefile.toml` | The fixture set, `fixture-set`: it requires `greeting-loud`, then the default set |
| `tests/packages/greeting/` | The Lake package `greeting`: the commands `greeting-hello` and `greeting-reply` (`Greeting.lean`), its entry module, its test driver (`GreetingTest/Model.lean`, which runs `GreetingTest/Greeting.lean`), its linked test (`GreetingTest/Linked.lean`, with the config it loads in `tests/linked/config`) and the fixture `tests/headless/hello` |
| `tests/packages/greeting-loud/` | The Lake package `greeting-loud`, which requires `greeting` and registers `greeting-reply` again with another text; its test driver and the fixture `tests/headless/reply` |

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
- **Every fixture lakefile is TOML**, turns every Lean linter on with
  `warningAsError`, as the core does, and names default targets. A
  package's test driver is not a default target, as the core's
  `model-test` is not: `mise run lean` links with the system compiler,
  which a TOML lakefile has no flags for.
- **The fixtures are hermetic.** They are checked in and build into their
  own `.lake/` directories, as the core builds into `lean/.lake`. Every
  dependency is a path, and nothing is written outside those directories.
  `.gitignore` ignores `.lake/` and `.lean-fmt-cache` in any directory.

### Manifests: a set's build fetches nothing

**Every Lake root has its `lake-manifest.json` committed**: the core, the
default set, the fixture set, each fixture package, the empty set, the
user-side link's set and its package, and the formatter's host.

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
`lean/` holds a copy of it** (the default set, the fixture set and its two
packages, the empty set, the user-side link's set and its package, and the
formatter's host): `lean-fmt` refuses a root with no
`lean-toolchain`, and elan reads the file when Lake is run in that
directory. `tools/toolchain-check.sh`, first in `lean-test`, fails when a
tracked copy differs from the pin, naming it. A bump of the pin
(`AGENTS.md`, "Toolchains") changes every copy in the same commit.

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
  - the hosts and the executable's modules (`Editor.Main`,
    `Editor.Headless`, `Editor.Headless.CommandLine`, `Editor.Window`,
    `Editor.Window.Real`, `Editor.WindowCheck`, `Editor.WindowCheck.Real`,
    `Editor.Executable`, `Editor.Version`, `Editor.ModuleLookup`);
  - the loop and its dispatch (`Editor.Loop`, `Editor.Command.Dispatch`,
    `Editor.Event.Queue`, `Editor.State.Outbox`);
  - the config session (`Editor.Config.*`);
  - the raw bindings (`Editor.Ffi`, `Editor.Ffi.*`);
  - the real bindings of the ports and what runs them (`….Real`,
    `Editor.Clipboard.InProcess`, `Editor.Display.Recorder`,
    `Editor.Job.Runner`, `Editor.Job.Jobs`, `Editor.Job.Table`,
    `Editor.Job.Pool`);
  - the modules that define the packages still in the core
    (`….Compiled`);
  - `Editor.Core`.
- **The internal namespace is `Editor.Internal`.** A core module that no
  package may import is created under it from now on, so that its name
  says so. The modules listed above are internal today under older names
  and keep them: renaming about 84 modules moves their mirrored test
  modules and every path the documents cite, and is filed as a task of its
  own (`internal-namespace-rename`).
- **`Editor`, the config base, is not part of the API.** A package imports
  the modules it uses, not the base. Nor is `EditorCore.EditorPackage`,
  which is no module of the core: it imports the packages, and no package
  imports it.
- **A feature still in the core is importable where its row says so.** The
  compile mode imports `Editor.Shell` and `Editor.Workspace.Modes`, which
  are features' modules; until those features move they are core modules a
  package may import.
- **No module lists the API and no check enforces it yet.** This document
  is the authority, written as a rule a check on Lake's module graph can
  apply. The check that a package imports only API modules comes with the
  first package built outside the core (phase 5), which extends the API
  here if it needs to.

Checked against the graph at `6ba99de5`: every core module the moving
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
when they move them. The fixture packages' tests do the same ("A
package's tests and the gate's steps over them", above), so the question
is already open for a package outside the core:

- the compile mode's tests (`ModelTest.Editor.Compile` and the modules
  under it, `ConfigTest.Editor.Compile`, `ContractTest.Editor.Compile` and
  `.Compile.Shipped`): `Editor.Command.Dispatch`, `Editor.Command.Real`,
  `Editor.Config.Elaborate`, `Editor.Config.Packages`,
  `Editor.Config.Registry`, `Editor.Config.Session`,
  `Editor.Config.Stores`, `Editor.Display.Recorder`,
  `Editor.Ffi.Processes`, `Editor.Ffi.Snapshot`, `Editor.Job.Runner`,
  `Editor.Loop` and `Editor.Text.Real`;
- the shipped palettes' tests (`ModelTest.Editor.Themes.Shipped`,
  `.Solarized`, `.FairyFloss`, `FfiTest.Editor.Themes.Shipped`):
  `Editor.Config.Packages`, `Editor.Config.Registry`,
  `Editor.Display.Real`, `Editor.Ffi.Display`, `Editor.Ffi.Document`,
  `Editor.Ffi.Marker`, `Editor.Ffi.Snapshot`, `Editor.Ffi.Window`,
  `Editor.Loop` and `Editor.Text.Real`.

**The core's tests do not name the compile mode.** A test module that
mirrors a core module imports no module of the compile mode, so that
phase 6 moves the compile mode's tests with it and splits none of the
core's: the listing's checks build their host from core packages'
commands and jobs (`ModelTest/Support/Listing.lean`), the contribution and
the format data have checks of their own (`ModelTest.contributionChecks`,
`ModelTest.formatDataChecks`), and what the compile mode makes of them is
checked in its own test modules. Three test modules outside the compile
mode's own still name it, each because it is the feature's own helper or
names every package by design; the `compile` entry of the map lists them:

- `ModelTest.Support.Compile`, the compile checks' own support, which
  moves with them;
- `ConfigTest.Editor.Headless`, which holds `ConfigTest.shippedChecks`,
  the test of the shipped set as the executable's hosts register it, and
  so names every package;
- `ContractTest.Support.Projects`, the rig of the project-mode contract
  checks over the real services, which registers the compile package.
  Three version-control contract checks build on that rig and reach the
  compile package through it; phase 6 splits the rig or moves it.

The shipped palettes are not yet cut out of the core's tests in the same
way: five test modules of core modules use a palette as their fixture
theme (the `shipped-themes` entry of the map lists them), which is phase
5's to settle when it moves the palettes.

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

Every module under `lean/Editor/`, 256 of them
(`find lean/Editor -name '*.lean' | wc -l`; 254 at `6ba99de5`, phase 4
added `Editor.Main` and phase 5 `Editor.Themes.Picture`), is **core** or part of a **feature that could become
a package**. The counts below add up to 256: 169 core and 87 in 21
features.

- **Core** is what a host with no packages needs to start and run: the
  ports with their models and bindings, the state, the scene and display
  types, the loop, the setup port, the config session and the hosts; and
  any module a core module imports for a type it carries (`Editor.Ex.Line`,
  `Editor.Menu`, `Editor.ModeLine`, `Editor.Language`, `Editor.Workspace`,
  the three `Editor.ProjectMode` modules).
- **A feature** is code reached through a package's registrations: the 22
  packages of the core's list, as 21 features (the two version-control packages are
  one), with the Vim scheme counted with evil.
- **Every feature but `compile` and `shipped-themes` still lives in the
  core's Lake package**, and is a core module in the sense of the section
  above and of the gate's check. The map guides later moves; it does not
  commit to them.

One row covers modules that share a class and a side of the import rule.
"A package may import it" is `yes`, `in tests` (a test double), `no`
(internal) or, for the two moving features, the phase that moves it.
"Under it" counts the modules below a name, not the module of that name.

| Modules | Count | Class | A package may import it |
|---|---|---|---|
| `Editor.Core` | 1 | core | no |
| The hosts and the executable's modules: `Editor.Main`, `Editor.Headless`, `.Headless.CommandLine`, `Editor.Window`, `.Window.Real`, `Editor.WindowCheck`, `.WindowCheck.Real`, `Editor.Executable`, `Editor.Version`, `Editor.ModuleLookup` | 10 | core | no |
| The loop and its dispatch: `Editor.Loop`, `Editor.Command.Dispatch`, `Editor.Event.Queue`, `Editor.State.Outbox` | 4 | core | no |
| The config session: `Editor.Config.Diagnostic`, `.Directory`, `.Display`, `.Elaborate`, `.Owner`, `.Packages`, `.Registry`, `.Reload`, `.Session`, `.Stores` | 10 | core | no |
| The raw bindings: `Editor.Ffi` and the 26 modules under it | 27 | core | no |
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
| `Editor.Evil` and 10 of the modules under it (all but `.Compiled`); `Editor.InputScheme.Vim`, `.Vim.Default` | 13 | feature: evil | yes |
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
| `Editor.Themes.Picture`, the theme picture check | 1 | feature: themes | in tests |
| `Editor.VersionControl.Compiled` | 1 | feature: version-control | no |
| `Editor.VersionControl.Model`, `.Contract` | 2 | feature: version-control | in tests |
| `Editor.VersionControl` and 16 of the modules under it (all but `.Compiled`, `.Model` and `.Contract`) | 17 | feature: version-control | yes |
| `Editor.WindowCommands` | 1 | feature: window-commands | yes |
| `Editor.WindowCommands.Compiled` | 1 | feature: window-commands | no |
| `Editor.Workspace.Compiled` | 1 | feature: workspace | no |
| `Editor.Workspace.Model`, `.Contract` | 2 | feature: workspace | in tests |
| `Editor.Workspace.Attach`, `.Finder`, `.FindFile`, `.FindInProject`, `.Lister`, `.Modes`, `.Projects`, `.Reach` | 8 | feature: workspace | yes |

### What each feature would have to cross

For each feature, from Lake's direct imports (`lake query
+<module>:imports`) at `6ba99de5`:

- its modules;
- the core modules that import one of them, each with what it imports (the
  core's root, `Editor.Core`, imports every feature's `Compiled` module
  and is left out, as is the list of the core's packages,
  `EditorCore.EditorPackage`, which is outside `lean/Editor/`);
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
- **Test modules outside its own tests that import it** (3): `ModelTest`: `Support.Compile`; `ConfigTest`: `Headless`; `ContractTest`: `Support.Projects`.
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

- **Modules** (4): `Themes`, `Themes.Check`, `Themes.Compiled`, `Themes.Picture`.
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
- **Test modules outside its own tests that import it** (20): `ModelTest`: `the root`, `Compile`, `Compile.Shipped`, `Completion.Contract`, `ProjectMode.Listing`, `VersionControl.Gutter`, `VersionControl.Worktrees`, `Support.FindFile`, `Support.Listing`, `Support.Shell`, `Support.VersionControl`, `Support.Workspace`; `ConfigTest`: `Bench`, `DefaultConfig`, `Headless`, `VersionControl.Gutter`; `ContractTest`: `the root`, `Compile.Shipped`, `Workspace`, `Support.Projects`.
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
the root `Editor.Core` and the moving names, it holds three rules. The
roots of the build it holds the second and third of are the test
executables' (`ModelTest`, `ConfigTest`, `FfiTest`, `ContractTest`) and
the root generated for the default set, whose transitive imports it asks
of the set (`lake -d ../packages query :editorRootTransImports`):

1. **The root and what it imports hold no moving module.** A core module
   that comes to import the compile mode or a shipped palette fails the
   gate, naming the module reached.
2. **Every `Editor.…` module the build reaches is in the root's closure**,
   unless it is a moving module. This is what makes
   the first rule a statement about every core module: a new core module
   nothing in the core imports fails the gate until `Editor.Core` imports
   it.
3. **A root that reaches the elaborator adapter reaches the config base**,
   which keeps the invariant the adapter's own import of `Editor` used to
   give.

The moving names are arguments, not derived from the graph: "everything the
root does not reach" would pass whatever the core imported. The gate runs
the check again to see each rule bite: pointed at `Editor` (exit 1), at
`Editor.Setup` (exit 3), and told a config base no executable's root
imports (`--base Editor.Core`, exit 4). A run in which no root of the build
reaches the elaborator adapter is refused (exit 2), since the third rule
would then hold of nothing; the gate sees that too. The generated root is
the only root that links the elaborator into the editor itself, so it is
among the roots the script checks for the base. When a feature moves out
of the core, its modules' names are added to the check's moving names.

## Registration order is visible

A host registers the packages in the order it is handed them: the order
of the generated root, which is the set's packages by dependency ("The
order packages register in", above) and, inside one Lake package, the
order of its entry module's array. Two headless outputs print that order,
so it is part of what the fixtures pin:

- **The `commands:` lines** of `tests/headless/expected` and
  `tests/headless/bundle/expected` print every command name in
  registration order. The compile mode's commands sit between the shell's
  and at-point's.
- **The ex candidates for `e`** in `tests/headless/ex/expected` are the ex
  names in the order they were first bound (`Registry.exNames`), which the
  fuzzy rank keeps among equal scores. The names are bound by `ex`, then
  `compile`, then `version-control`, the sixth, eighteenth and twentieth
  packages of the core's list.

`ModelTest.packageSetChecks` pins both orders the fixtures depend on that a
model test can see: the ex names in bound order, and the theme names. It
is the test of the core's entry module
(`lean/ModelTest/EditorCore/EditorPackage.lean`), over
`EditorCore.EditorPackage.packages`.

The default set holds the core alone, so the generated root registers
exactly the core's list and no fixture line changed when the root became
generated.

**Packages register by dependency, which puts a default package after the
core's.** The compile package would then register after version control
and at-point, and both fixture lines would change, unless phase 6 keeps
the compile package's place in the order. That is phase 6's choice to make
with the fixtures in view.

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
- **CI** caches `lean/.lake` only, so each run there also builds both
  roots, links both editors and builds the fixture packages
  ([ci.md](../dev-practices/ci.md), "Caches").
