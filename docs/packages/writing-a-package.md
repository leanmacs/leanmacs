# Writing a package

A package adds commands, keys, modes, themes and the rest to the editor,
written in Lean against the core's API. This guide builds one, `word-count`,
which says how many words the focused buffer holds. Its files are in
[`word-count/`](word-count/), beside this guide, and every block of code
below is one of them, whole. The gate tests, builds, format-checks and runs
that package on every change, so the code here compiles and does what this
guide says.

To install a package someone else wrote, see
[installing-packages.md](installing-packages.md).

## What a package is

A package is a Lake package that requires the editor's core,
`editor-core`, and lists the `Editor.Package` values it contributes in one
module, its entry module. A `Package` is a name and a `setup`: the same
kind of program over the same operations as your config's `setup`
(`lean/Editor/Package.lean`).

The editor is one executable linked from a set of packages: the core, the
default packages, and whatever your config's `lakefile.toml` requires.
So a package reaches the editor at the next build of that set, which
restarts the editor into the new executable with your session. It is not
loaded into a running editor, and it is not unloaded from one (see the
README's [Limitations](../../README.md#limitations)). While you write it,
you can run the same code live as config, and move it into a package once
it works ("Developing it live, as config", below).

How the set is built, and how the core and the packages fit together, is in
[packages.md](../design/packages.md), "The package set and its build".

## The lakefile

[`word-count/lakefile.toml`](word-count/lakefile.toml):

```toml
# The example package of docs/packages/writing-a-package.md, quoted whole
# there: change the guide with it. The fixture set (tests/packages/) requires
# it, so the gate tests, builds, format-checks and runs it headless.
name = "word-count"
testDriver = "«word-count-test»"
defaultTargets = ["WordCount", "WordCountTest"]
leanOptions = { linter.all = true, warningAsError = true }

[[require]]
name = "editor-core"
path = "../../../lean"

[[lean_lib]]
name = "WordCount"
globs = ["WordCount.*"]

[[lean_lib]]
name = "WordCountTest"
globs = ["WordCountTest.+"]

[[lean_exe]]
name = "word-count-test"
root = "WordCountTest.Model"
```

- **The `editor-core` require** is the dependency on the core. Name it
  `editor-core` and point `path` at the core of the editor you build
  against: in a checkout of this repository that is its `lean/` directory
  (here `../../../lean`, relative to the package); with the app it is
  `/Applications/Leanmacs.app/Contents/Resources/lean/lean`. Your config's
  package set requires the same core, and the package is built against it.
- **`globs = ["WordCount.*"]`** puts every module under `WordCount` in the
  library, the entry module included. A library declared by its name
  alone holds only what its root module imports, and the root,
  `WordCount.lean`, does not import the entry module
  ([packages.md](../design/packages.md), "A package's tests and the gate's
  steps over them").
- **`testDriver`** names the executable `lake test` runs: here
  `word-count-test`, rooted at `WordCountTest/Model.lean` ("Testing it",
  below). It is no default target. `WordCountTest`, the library of test
  modules, is one, so a build checks the tests compile.
- **`leanOptions`** turns every Lean linter on and makes a warning fail the
  build, as the core does. The gate builds every package of this
  repository that way. A package of your own may choose its options.

## The entry point

A Lake package named `p` lists its packages in the module
`<P>.EditorPackage`, where `<P>` is `p` in upper camel case, the name
`lake new` gives its library: `word-count` gives `WordCount.EditorPackage`.
The module declares `packages : Array Editor.Package` in the namespace of
its own name ([packages.md](../design/packages.md), "A package's entry
module"). The build that links the editor imports it; a Lake package with
no such module contributes nothing.

[`word-count/WordCount/EditorPackage.lean`](word-count/WordCount/EditorPackage.lean):

```lean
-- Quoted whole in docs/packages/writing-a-package.md: change the guide with it.
import WordCount

/-!
# The entry module of the Lake package `word-count`

The package-set build imports this module and registers `packages`, after
the packages of every Lake package this one requires.
-/

namespace WordCount.EditorPackage

/-- The packages of the Lake package `word-count`, in the order a host
registers them. -/
def packages : Array Editor.Package :=
  #[WordCount.package]

end WordCount.EditorPackage
```

[`word-count/WordCount.lean`](word-count/WordCount.lean), which defines the
command and the `Package` value:

```lean
-- Quoted whole in docs/packages/writing-a-package.md: change the guide with it.
import Editor.Api
import Editor.Package

/-!
# The package `word-count`

The example of the guide to writing a package: the command `word-count`
says in the echo area how many words the focused window's buffer holds.
-/

namespace WordCount

open Editor

/-- The number of words in `text`: its runs of characters that are not
white space. -/
def count (text : String) : Nat :=
  ((text.split Char.isWhitespace).toList.filter fun word => !word.isEmpty).length

/-- Says how many words the focused window's buffer holds. -/
def countFocused : EditorM Unit := do
  let some target := (← editorState).focusedTarget?
    | message "word-count: no window is focused"
  let text ← target.buffer.text.read
  message s!"{count text} words"

/-- The package `word-count`: the command `word-count`. -/
def package : Package :=
  { name := "word-count"
    setup := command "word-count" countFocused }

end WordCount
```

- **The package's name owns what it registers.** A reload replaces only
  config's registrations, so a package's stay. The name must not be
  empty, `config` or `compiled`, and no two packages of one editor may
  share it.
- **Packages register in dependency order**: each after every package its
  Lake package requires, the core's first, and packages that do not depend
  on each other in the order the set's lakefile names them
  ([packages.md](../design/packages.md), "The order packages register
  in"). Of two registrations of one name the later is found.
- **Config's registrations are found before any package's.** A command
  your config registers under a package's command's name runs in its
  place.

## What the core's API offers

A package writes against the same API config does:

- **`Editor.Api`** (`lean/Editor/Api.lean`): the operations a command
  (`EditorM`) is written with. Buffers (`createBuffer`, `findBuffer`,
  `BufferId.text`), edits at positions, selections, undo, messages
  (`message`), questions to the editor state (`editorState`, and pure
  functions over it such as `EditorState.focusedTarget?`), the registry
  and config settings, and the loop's control (`runCommand`, `giveUp`).
- **`Editor.Setup`** (`lean/Editor/Setup.lean`): `SetupM`, what a
  `setup` registers. Commands (`command`, `commandWith`), jobs (`job`,
  `jobWith`), keys (`bindKey`, `bindKeys`, `leaderKey`), ex names
  (`exCommand`), modes (`defineMode`), faces and themes (`face`,
  `defineTheme`), styles, displays, menus, mode-line segments, languages,
  workspaces and project commands.
- **`Editor.Text`** (`lean/Editor/Text.lean`): the text port, `TextM`,
  whose reads (`TextId.read`, `rowContent`, `slice`) and edits a command
  runs on a buffer's text.
- **`Editor.Package`** (`lean/Editor/Package.lean`): the `Package`
  structure.
- **For tests**: `Editor.Config.Packages` (`Config.State.ofPackages`,
  what a package registers, with no host), the core's model test kit
  (`Editor.Test` and the modules under it), the ports' pure models and
  fakes, and, for a linked test only, the linked test kit
  (`Editor.Test.Linked`).

**The import rule.** A package's library may import any core module that
is not internal: the hosts, the loop, the config session, the raw and real
bindings and the `….Compiled` modules are internal. It may never import
`Editor`, the config base, which only the root of a package's linked test
may import. A config file starts with `import Editor`; a package's module
imports the modules it uses instead, as `WordCount.lean` imports
`Editor.Api` and `Editor.Package`. The gate's package imports check refuses
anything else, each with its reason. The full rule is in
[packages.md](../design/packages.md), ["What a package may
import"](../design/packages.md#what-a-package-may-import), and which
modules are core, internal or features is in ["The module
map"](../design/packages.md#the-module-map).

A layered set of extension points for packages is planned
([extension-points.md](../design/extension-points.md)), not built.

## Developing it live, as config

Write the code as a config file first. A config file is a Lean module under
your config directory's `Config/`, and `:reload` re-elaborates only the
files that changed and the files that import them, so you edit, reload and
try it with no rebuild. The `lakefile.toml` and `lean-toolchain` the editor
generates in the config directory let Lean's language server check the file
in any editor.

This is `word-count` as config. The gate runs it as the headless fixture
[`as-config`](word-count/tests/headless/as-config/):
[`config/Config/WordCount.lean`](word-count/tests/headless/as-config/config/Config/WordCount.lean)

```lean
-- Quoted whole in docs/packages/writing-a-package.md, "Developing it live,
-- as config": change the guide with it.
import Editor
open Editor

namespace Config.WordCount

/-- The number of words in `text`: its runs of characters that are not
white space. -/
def count (text : String) : Nat :=
  ((text.split Char.isWhitespace).toList.filter fun word => !word.isEmpty).length

/-- Says how many words the focused window's buffer holds. -/
def countFocused : EditorM Unit := do
  let some target := (← editorState).focusedTarget?
    | message "word-count: no window is focused"
  let text ← target.buffer.text.read
  message s!"{count text} words"

/-- Registers the command `word-count`. -/
def setup : SetupM Unit :=
  command "word-count" countFocused

end Config.WordCount
```

and [`config/init.lean`](word-count/tests/headless/as-config/config/init.lean),
which imports it and calls its `setup`. Only the `setup` that `init.lean`
defines runs, so a config file's `setup` runs when the root calls it.

```lean
-- Quoted whole in docs/packages/writing-a-package.md, "Developing it live,
-- as config": change the guide with it.
import Editor
import Config.WordCount
open Editor

def setup : SetupM Unit := do
  Config.WordCount.setup
```

The fixture's script types three words, runs `word-count`, and requires
`reload 1: installed, 2 files, 1 commands` and the echo `3 words`
([`expected`](word-count/tests/headless/as-config/expected)).

## Moving it into a package

The package's code is the config file's with four changes:

| Config file | Package |
|---|---|
| `import Editor` | `import Editor.Api` and `import Editor.Package`: the modules it uses, never the config base |
| `namespace Config.WordCount` | `namespace WordCount`, with `open Editor` inside it |
| `def setup : SetupM Unit := command …` | `def package : Package := { name := "word-count", setup := command … }` |
| `init.lean` calls `Config.WordCount.setup` | The entry module `WordCount/EditorPackage.lean` lists `WordCount.package`, and the lakefile above makes it a Lake package |

Then:

1. Make the package's directory with its `lakefile.toml`, `lean-toolchain`
   (a copy of the core's), `WordCount.lean` and `WordCount/EditorPackage.lean`.
2. Install it: `:package-install word-count <its directory>`, or add a
   `[[require]]` for it to your config's `lakefile.toml` and `:reload`
   ([installing-packages.md](installing-packages.md)).
3. Delete `Config/WordCount.lean` and its import and call in `init.lean`.
   Config's command of a name is found before a package's, so while the
   config file still registers `word-count`, config's runs
   (`ModelTest.packageChecks`, "config's command of a package's command's
   name runs in its place").

The build runs in the background and the editor restarts into the new
executable. Until then, a config file that imports the package's module is
refused, with a diagnostic that the package set needs a rebuild.

After the restart a config file can import the package's modules and use
its declarations. The fixture
[`from-config`](word-count/tests/headless/from-config/) does:
[`config/init.lean`](word-count/tests/headless/from-config/config/init.lean)

```lean
-- Quoted whole in docs/packages/writing-a-package.md, "Moving it into a
-- package": change the guide with it.
import Editor
import WordCount
open Editor

def setup : SetupM Unit := do
  command "word-count-scratch" (message s!"{WordCount.count "a b c d"} words")
  bindKey "C-c w" "word-count"
```

Its script presses `C-c w`, which runs the package's `word-count`, and runs
config's `word-count-scratch`, which calls the package's `WordCount.count`
([`expected`](word-count/tests/headless/from-config/expected)).

## Testing it

A package's tests, by convention
([packages.md](../design/packages.md), "A package's tests and the gate's
steps over them"):

- **Model tests, in its Lake test driver** (`lake test`): the tests that
  need no Rust library. `word-count`'s driver,
  [`WordCountTest/Model.lean`](word-count/WordCountTest/Model.lean), runs
  the checks in
  [`WordCountTest/WordCount.lean`](word-count/WordCountTest/WordCount.lean):
  `count` on the empty text, on one word and on runs of white space; and,
  through `Config.State.ofPackages`, that the package is accepted alone and
  registers `word-count`, owned by `word-count`. A test module mirrors the
  module it tests, under `<P>Test/`.
- **Headless fixtures**: each directory `tests/headless/<name>/` holds a
  `config/` directory, a `script` and an `expected`. The editor built from a
  set that holds the package runs the script on that config with no window
  and must print exactly `expected`. The script's directives (`reload`,
  `key`, `commit`, `run`, `scene` and the rest) are in
  [headless-mode.md](../dev-practices/headless-mode.md).
  `word-count` has three: [`count`](word-count/tests/headless/count/), its
  command compiled in, and the two stages above.
- **A linked test**, when the package needs the Rust library: the module
  `<P>Test.Linked`, the root of one executable linked as the editor is. It
  may import the linked test kit, and its root alone may import the real
  bindings, the headless host (`Editor.Headless`), the config base and the
  core's entry module. `word-count` has none;
  [`tests/packages/greeting`](../../tests/packages/greeting/) has one.
- **`lean-fmt.toml`** with `exclude = ["tests/**"]`: the fixtures' config
  files are modules of a config directory, which the editor elaborates at
  runtime, not modules of the package.

In a checkout, the gate runs each of these over every package of a package
set, from `lean/`: `sh ../tools/package-set.sh test|build|fmt|run <set dir>`
([the-gate.md](../dev-practices/the-gate.md), "The package steps"). The
fixture set `tests/packages/` requires `word-count`, so `mise run ci` runs
its driver, builds it with `--wfail`, format-checks it, checks its imports
and runs its three fixtures.

## Native code

The app ships the Lean toolchain only: no macOS SDK, no C library headers,
and no Cargo. A pure-Lean package builds from the app alone. A package with
native code needs the user's own tooling or a prebuilt binary, the way an
Emacs package with a native module either compiles it or fetches one
([packages.md](../design/packages.md), ["Who can build
it"](../design/packages.md#who-can-build-it)).

- **A C FFI is the preferred way to bring native code.** Bind a C function
  with an `@[extern]` declaration, compile the C with the toolchain's
  compiler as Lake builds the core's glue (`buildLeanO`), and link its
  object through the library's `moreLinkObjs`. That needs a
  `lakefile.lean`, since a TOML lakefile cannot declare the C target.
  [`tests/user-sets/c-glue`](../../tests/user-sets/c-glue/) is the
  example.
- **What builds from the app**: C that includes `lean/lean.h` alone and
  calls only the system functions the shipped editor itself uses. C that
  includes a system header (`<stdio.h>`), or links another framework or
  library, needs the Xcode command line tools (`xcode-select --install`),
  or a prebuilt binary that the package's lakefile fetches. When such a
  build fails, the build's last line and the echo area say which header,
  framework or library is missing.
- **Say which in the package's own documentation**: what tooling it needs,
  or which prebuilt binary it fetches.
- **Rust**: a Rust crate inside this repository builds with the user's own
  Cargo, installed with rustup, from a checkout only. A crate from outside
  the repository is refused for now, with the reason.

## Publishing

A user's set can require a package in three ways
([installing-packages.md](installing-packages.md)):

- **A path**: `:package-install word-count <directory>`.
- **A git repository**: `:package-install word-count <url> [<rev>]`. Git
  and Reservoir packages need the system `git`.
- **Reservoir**: `:package-install <scope>/word-count [<version>]`.

A published package names the core from git, by this repository, its
core in the `lean/` directory, at the tag of a nightly build:

```toml
[[require]]
name = "editor-core"
git = "https://github.com/leanmacs/leanmacs"
subDir = "lean"
rev = "nightly-<build id>"
```

- **Pin a nightly's own tag**, never the moving `nightly`. Each nightly
  build has a tag `nightly-<build id>` that stays where it is: `editor
  --version` prints it on its `core` line, and the nightly release's
  `build.json` holds it as `"tag"`. Pin the one of the editor you develop
  against.
- **In a user's set it is only a name.** The lakefile of a user's config
  requires `editor-core` itself, by the running editor's own core
  directory, as its last require, and Lake takes that one over the
  package's: the package builds against the user's core, and nothing is
  cloned ([installing-packages.md](installing-packages.md)). So the `rev`
  says which core the package was written against, not which it gets.
- **On its own**, when you run `lake build` or `lake test` in the
  package's directory, Lake clones this repository at that `rev` and
  builds the core from source, so the package needs no checkout of the
  editor.
- **A package written against a newer core than the user's fails to
  build.** The build buffer shows Lean's errors, an unknown identifier or a
  type mismatch in the package's own modules, and the editor keeps running
  on the editor it had. There is no version constraint, so say in the
  package's README which core it needs: the tag it pins.

The example `word-count` requires the core by path, `../../../lean`,
because it builds in this repository against the checkout's core; a
published copy of it would use the git form above.
