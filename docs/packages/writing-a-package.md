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
- **A package may supply the editor's input scheme.** Its `lakefile.toml`
  declares `keywords = ["editor-input-scheme"]`, and its entry module
  declares `scheme : Editor.SchemePackage` beside `packages`: a name and an
  `InputScheme` (`{ name := "mine", scheme := Mine.scheme }`). An editor
  runs the scheme its set supplies, the last one when several packages
  supply one, and refuses to start when none does. The default package
  `evil` supplies the Vim scheme
  ([packages.md](../design/packages.md), "Input schemes"; the interface a
  scheme implements is in
  [keymaps-and-modes.md](../design/keymaps-and-modes.md), "Input
  schemes"). The commands the Edit menu and completion at point reach of a
  scheme's package are declared by the interface package `evil-api` and by
  the core's clipboard names (`Editor.Clipboard`): a scheme's package
  registers its own under them.
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
`Editor.Api` and `Editor.Package`. The full rule is in
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
   Write the `lean-toolchain` yourself, or copy the one the editor
   generates in your config directory: `word-count/`'s is a link to this
   repository's pin, which dangles once the directory is copied elsewhere.
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
and no Cargo. A pure-Lean package builds from the app alone. A package
brings native code as **a library of its own with a C interface, loaded
when the editor starts** (the next section). That is the way for Rust, and
for any C, C++ or Zig of size, and a library the package ships already
built needs nothing of the user's, the way an Emacs package with a native
module either compiles it or fetches one
([packages.md](../design/packages.md), ["Who can build
it"](../design/packages.md#who-can-build-it)).

- **The glue every library needs, and the place for a few lines of C bound
  directly.** Bind a C function with an `@[extern]` declaration, compile
  the C with the toolchain's compiler as Lake builds the core's glue
  (`buildLeanO`), and link its object through the library's
  `moreLinkObjs`. That needs a `lakefile.lean`, since a TOML lakefile
  cannot declare the C target. The fixture package
  [`echo`](../../tests/packages/echo/lakefile.lean) declares its glue
  this way:

  ```lean
  target echoGlue.o pkg : FilePath := do
    let srcJob ← inputTextFile <| pkg.dir / "ffi" / "glue.c"
    buildLeanO (pkg.buildDir / "ffi" / "glue.o") srcJob #[] #["-O2", "-Wall", "-Wextra", "-Werror"]

  /-- The Rust-backed binding, with the package's glue. -/
  @[default_target] lean_lib EchoReal where
    roots := #[`Echo.Real]
    moreLinkObjs := #[echoGlue.o]
    plugins := lintPlugin
  ```

- **What builds from the app**: C that includes `lean/lean.h` alone and
  calls only the system functions the shipped editor itself uses. C that
  includes a system header (`<stdio.h>`), or links another framework or
  library, needs the Xcode command line tools (`xcode-select --install`),
  or a prebuilt binary that the package's lakefile fetches. When such a
  build fails, the build's last line and the echo area say which header,
  framework or library is missing.
- **Say which in the package's own documentation**: whether its library
  ships built, and for which platforms, or which tool builds it.
- **Rust**: ship it as a native library of its own (below), written
  against `editor-package`, as `echo` and `acp` do. The editor no longer
  compiles a package's Rust into its own archive: a package declaring an
  `editorRustCrate` target is refused, with that reason.

### A native library

A package may ship its native code as a dynamic library of its own, with a
C interface, which the editor loads when it starts, in the shape of an
Emacs dynamic module. You write four things:

- **The library**, which exports two symbols, its init,
  `editor_package_init`, and its declaration, `editor_package_declaration`.
- **The `editorLibrary` target**, in a `lakefile.lean` (a TOML lakefile
  cannot declare it).
- **The glue**, a C file that mirrors the library's table.
- **The Lean binding**: `@[extern]` functions over the glue, and a
  `builtin_initialize` that loads the library.

The package declares the library with **one lakefile target,
`editorLibrary`**, whose value is the library's absolute path. The
package-set build finds that target by name in every package of the set,
copies the library it names beside the editor (`.lake/build/libraries/<lake
package>/` beside a set's editor, `libraries/<lake package>/` in an
install), and records where in `<editor>.libraries`. The package's glue
loads it from there when the editor starts, never from the package's
source directory, so an installed editor keeps working after the package's
directory is gone ([packages.md](../design/packages.md), ["A package's
library, staged and loaded, as
built"](../design/packages.md#a-packages-library-staged-and-loaded-as-built)).

#### The library, in Rust, with `editor-package`

Write the library as a `cdylib` against the package wrapper,
`editor-package`. It is not on crates.io: depend on it by a git source,
pinned by revision (the line `crates/editor-package/src/lib.rs` gives):

```toml
editor-package = { git = "https://github.com/leanmacs/leanmacs", rev = "<sha>" }
```

The crate type is `cdylib`, with `rlib` beside it if the crate's own
integration tests link it, as echo's does
(`tests/packages/echo/rust/Cargo.toml`):

```toml
crate-type = ["cdylib", "rlib"]
```

The library holds:

- `#![deny(unsafe_code)]`: the wrapper holds all of the `unsafe`.
- **Its state**, made once by an init, a `fn(Runtime) -> S`, which
  registers its service (`runtime.register("<name>")`).
- **Its table**: a `#[repr(C)]` struct of `extern "C" fn`s over the
  wrapper's FFI-safe types, `Bytes` (bytes the caller lends for the call),
  `Lent` (a buffer the library lends, handed back to the table's `free`)
  and `Out` (a place written once).
- **Its functions**, declared with `functions!`, whose bodies see what the
  caller lent, borrowed for the call alone, with no `unsafe` of their own.
- **The package**, declared with `package! { interface 1; pub static
  PACKAGE: Package<…> = Package::new(…); }`, which exports the init and the
  declaration.

The crate docs' example, the doctest in `crates/editor-package/src/lib.rs`,
which `cargo test` compiles and runs, is a whole library and its test:

```rust
use editor_package::buffer::{Bytes, Lent, Out};
use editor_package::{Package, Runtime, Service, functions, package};

/// The library's state, made once by its init.
pub struct Loaded {
    service: Service,
}

impl Loaded {
    /// The init: registers the package's service through the runtime.
    pub fn new(runtime: Runtime) -> Self {
        Self { service: runtime.register("echo") }
    }
}

/// A reply as it crosses: `{ { uint8_t *bytes; size_t len; } text; }`.
#[repr(C)]
pub struct Reply {
    pub text: Lent,
}

/// The table's functions, behind the size the wrapper puts first.
#[repr(C)]
pub struct Functions {
    pub start: extern "C" fn(id: u64, text: Bytes<'_>) -> bool,
    pub take: extern "C" fn(id: u64, out: Out<'_, Reply>) -> bool,
    pub free: extern "C" fn(text: Lent),
}

functions! {
    /// `text` is the `&[u8]` the caller lent, for the call alone.
    extern "C" fn start(id: u64, text: Bytes<'_>) -> bool {
        !text.is_empty()
            && PACKAGE.state().is_some_and(|loaded| loaded.service.complete(id))
    }

    /// `out` is a `Place`, written once.
    extern "C" fn take(_id: u64, out: Out<'_, Reply>) -> bool {
        out.put(Reply { text: Lent::of(b"echoed".to_vec()) });
        true
    }
}

package! {
    interface 1;

    /// The library.
    pub static PACKAGE: Package<Loaded, Functions> = Package::new(
        Loaded::new,
        Functions { start, take, free: editor_package::buffer::free },
    );
}

// Its test, on the fake runtime, with no `unsafe`.
let fake = editor_package::fake::FakeRuntime::new().leak();
let (status, _table) = fake.init(editor_package_init);
assert_eq!(status, editor_package::raw::INIT_LOADED);
assert!((PACKAGE.table().functions().start)(7, Bytes::of(b"hi")));
assert_eq!(fake.next_completion(), Some((1024, 7)));
```

What the runtime gives the init (`Runtime`):

- `register(name)`: a service, whose id its completions and events carry.
- `take_over(child)`: a streaming child a job opened in the core's process
  service, pulled and written as a `stream::Child`.
- `lend(bytes)`: a buffer of the core's, handed back when it drops.

What a `Service` does: `complete(request)` posts a request's completion to
the completion queue, and `post(code, text)` posts an event to the editor.

Before the init has run, `PACKAGE.state()` is none. The wrapper does not
guard the table for you: making each function check `PACKAGE.state()` and
answer its "not loaded" value (false, or none) is your job, as echo's and
acp's functions do, and you pin it with a test like their
`tests/not_loaded.rs`. The example above skips that check in `take` for
brevity; `start` shows it. Whole examples: echo
(`tests/packages/echo/rust/`) and acp (`packages/acp/rust/`).

#### The library, in C, C++ or Zig, with the header

Build a shared library against the generated header,
`editor_package_runtime.h`: copy it from
`crates/editor-package-runtime/include/` at the editor's revision you
build against.

- **Define the init**, `uint32_t editor_package_init(const
  EditorPackageRuntime *runtime, const void **table)`, with default
  visibility. Check `EDITOR_PACKAGE_RUNTIME_HAS(runtime, member)` for each
  member past those you require, write your table (`{ size_t size;
  functions… }`), and answer `EDITOR_PACKAGE_INIT_LOADED`; or answer
  `EDITOR_PACKAGE_INIT_RUNTIME_TOO_SMALL` with the table unwritten.
- **Declare it**: `EDITOR_PACKAGE_DECLARE(<interface>, <last member>);`,
  once, at file scope, in the file that defines the init.
- **Every runtime member takes the runtime first.**
- **Buffers**: a buffer the core lends you (`buffer_lend`, or a write's
  refusal) goes back exactly once through `buffer_free`; a buffer you lend
  across your table is freed by your table's `free`.

The shape, from `crates/editor-package-library-fixture/fixture/current_runtime.c`,
the C file the gate compiles against the header and runs on the real
runtime (the bodies of `post` and `lend_twice` elided):

```c
#include "editor_package_runtime.h"

#define FIXTURE_EXPORT __attribute__((visibility("default")))

// The library's table: its size, its service's id and its functions.
struct current_table {
  size_t size;
  uint64_t service;
  bool (*fire)(uint64_t request);
  bool (*post)(uint64_t code, const uint8_t *text, size_t len);
  void (*lend_twice)(bool *first, bool *second);
};

static const EditorPackageRuntime *the_runtime;
static struct current_table the_table;

// Completes `request` from the library's service.
static bool fire(uint64_t request) {
  return the_runtime->complete(the_runtime, the_table.service, request);
}

FIXTURE_EXPORT uint32_t editor_package_init(const EditorPackageRuntime *runtime,
                                            const void **table) {
  if (runtime == NULL || !EDITOR_PACKAGE_RUNTIME_HAS(runtime, buffer_free)) {
    return EDITOR_PACKAGE_INIT_RUNTIME_TOO_SMALL;
  }
  static const char name[] = "current";
  the_runtime = runtime;
  the_table.size = sizeof(struct current_table);
  the_table.service = runtime->register_service(runtime, (const uint8_t *)name,
                                                sizeof(name) - 1);
  the_table.fire = fire;
  the_table.post = post;
  the_table.lend_twice = lend_twice;
  *table = &the_table;
  return EDITOR_PACKAGE_INIT_LOADED;
}

// The library's declaration: interface 1, and the runtime through
// `buffer_free`, the last member it calls.
EDITOR_PACKAGE_DECLARE(1, buffer_free);
```

- **C++**: give `editor_package_init` `extern "C"`. The declaration macro
  already has it (`EDITOR_PACKAGE_DECLARATION_LINKAGE`).
- **Zig**: import the header with `@cImport`, and export the two symbols
  with the C calling convention. Nothing in the gate compiles Zig, so this
  guide shows no Zig.

#### A worked example: wrapping a C-API library (libghostty)

This example is described, not built. libghostty is Ghostty's terminal
core, written in Zig, with a C API. A package that brings it would hold:

- **A small shim as its library**, in C or Zig, that links libghostty,
  exports `editor_package_init` and the declaration, and puts libghostty's
  calls behind the package's own table, whose shape is the package's
  interface version.
- **libghostty itself**, shipped inside the package's `lib/` beside the
  shim, or linked statically into it.
- **The glue**, which mirrors the shim's table, and **the Lean binding**,
  which wraps it behind a port with a model, as every adapter is.

What the runtime lacks: a terminal needs a PTY's descriptor, and the
runtime hands no descriptor. As "The package runtime, as built" in
[packages.md](../design/packages.md) says, such a package gets a trailing
runtime member with its own ownership rule. That is future work, outside
the roadmap that built package libraries.

#### The target

The target's body is yours, in one of two forms, or both:

- **Already built** (built ahead by you, or checked in): answer a path
  inside the package, with its content as the trace. No process runs, so a
  user's set builds with no compiler of the user's, from the app alone.
  For a package outside this repository this is how users get it with no
  Cargo: ship `lib/<library>` for the platforms you support. Fetching
  hash-pinned per-platform builds is not automated yet.
- **Built with the user's tooling** (Cargo, zig, cc): run the tool through
  Lake's `proc` and answer what it built. Run it through `proc`, not
  `IO.Process`: when the tool is missing, Lake's spawn failure is what the
  build reads to say `cargo is required to build <package>'s library`. Say
  in the package's documentation which tool it needs.

The fixture package [`echo`](../../tests/packages/echo/lakefile.lean) does
both: it answers `lib/libecho_service.dylib` when that file is in the
package, and builds its crate with Cargo otherwise.

```lean
target editorLibrary pkg : FilePath :=
  Job.async do
    let extension := if Platform.isOSX then "dylib" else "so"
    let name := s!"libecho_service.{extension}"
    let prebuilt := pkg.dir / "lib" / name
    if ← prebuilt.pathExists then
      let library ← IO.FS.realPath prebuilt
      setTrace (← computeTrace library)
      return library
    -- … otherwise `proc { cmd := "cargo", args := #["build", …] }`, and
    -- answer the library Cargo built.
```

#### The glue and the Lean binding

The glue declares the core's loader verbatim, mirrors the library's table
and its interface version, and keeps the loaded table in an `_Atomic`
pointer, set once by the load. Each `<package>_glue_*` function forwards
through that table, and answers false or none before a load. From echo's
glue, `tests/packages/echo/ffi/glue.c`:

```c
// The wrapper's `Table` of the library's `EchoFunctions`, member for member.
typedef struct {
  size_t size;
  bool (*start)(uint64_t id, echo_bytes text);
  bool (*cancel)(uint64_t id);
  bool (*take)(uint64_t id, echo_raw_reply *out);
  void (*flush)(uint64_t id);
  bool (*attach)(uint64_t request, uint64_t child);
  bool (*attach_take)(uint64_t request, echo_raw_reply *out);
  void (*free)(echo_lent text);
} echo_table;

// The interface version this glue was compiled for: the shape of
// `echo_table`, which the library declares too (`package! { interface 1; …
// }`, `rust/src/ffi.rs`). A change to the table's shape is a new version,
// here and in the library together.
#define ECHO_INTERFACE 1u

// The core's loader of a package's library (`editor-ffi`'s
// `package_library.rs`): 0 with the table written, or a refusal, 1 to 8,
// with the two numbers it compared written to `versions` for a newer
// runtime (7) or another interface (8).
uint32_t editor_ffi_package_load(const uint8_t *path, size_t len,
                                 uint32_t interface, const void **table,
                                 uint64_t *versions);

// The table of the library loaded, or none yet: set once, by a load, and
// read by every call, from any thread.
static _Atomic(const echo_table *) loaded = NULL;
```

```c
lean_obj_res echo_glue_load(b_lean_obj_arg path, uint32_t interface) {
  const void *table = NULL;
  uint64_t versions[2] = {0, 0};
  uint32_t status = editor_ffi_package_load(
      (const uint8_t *)lean_string_cstr(path), lean_string_size(path) - 1,
      interface, &table, versions);
  if (status == 0) {
    atomic_store_explicit(&loaded, (const echo_table *)table,
                          memory_order_release);
  }
  lean_object *numbers = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(numbers, 0, lean_box_uint64(versions[0]));
  lean_ctor_set(numbers, 1, lean_box_uint64(versions[1]));
  lean_object *answer = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(answer, 0, lean_box_uint32(status));
  lean_ctor_set(answer, 1, numbers);
  return lean_io_result_mk_ok(answer);
}
```

The Lean binding binds the load, reads a refusal back with the core's
`Editor.PackageLibrary.LoadRefusal.of?` and says it with
`LoadRefusal.describe`, naming the package, and loads the staged library
in a `builtin_initialize`. From `tests/packages/echo/Echo/Real.lean`:

```lean
@[extern "echo_glue_load"]
opaque loadFrom (path : @& String) (interface : UInt32) : IO (UInt32 × UInt64 × UInt64)

/-- Loads the library at `path` for a glue of interface `interface`, or
throws the refusal's sentence, naming echo: the initialiser's body with the
version a check can vary. -/
def loadExpecting (path : String) (interface : UInt32) : IO Unit := do
  let (status, first, second) ← loadFrom path interface
  if let some refusal := Editor.PackageLibrary.LoadRefusal.of? status first second then
    throw (IO.userError (refusal.describe "echo" path))

/-- Loads the library at `path` for the glue's own interface, or throws the
refusal's sentence: the body of the module's initialiser. -/
def load (path : String) : IO Unit := do
  loadExpecting path (← interface)
```

```lean
builtin_initialize
  load (← Editor.PackageLibrary.staged "echo" "echo")
```

`Editor.PackageLibrary.staged "<package>" "<lake package>"` is an `IO
String` that reads the record beside the running editor, and throws a
sentence naming your package when none is staged.

**It must be `builtin_initialize`, not `initialize`.** A
`builtin_initialize` runs before `main` in each executable that links the
module natively. A plain `initialize` would also run when the config
elaborator imports the package at run time, where the glue's symbols do
not exist.

#### The declaration and the interface version

Beside its init, `editor_package_init`, the library exports a declaration,
`editor_package_declaration`: the size of the package runtime it needs,
and the package's **interface version**, a number you choose for the shape
of your library's function table, which your glue mirrors. Your glue
passes the version it was compiled for to the core's load
(`editor_ffi_package_load`), and the editor refuses, before it calls
anything of the library, one that declares nothing, another interface
version, or a newer runtime than the editor's, with a message naming your
package and both versions. The editor opens the library to read its
declaration, so the library's load-time initialisers (C constructors, Rust
static initialisers) have run even when it is refused: keep them free of
work that needs the runtime. Change the interface version, in the library
and the glue together, whenever the table's shape changes.

- In Rust, with the package wrapper (`editor-package`), the macro writes
  both: `package! { interface 1; pub static PACKAGE: Package<…> = …; }`.
- In C, C++ or Zig, against the generated header
  (`crates/editor-package-runtime/include/editor_package_runtime.h`):
  `EDITOR_PACKAGE_DECLARE(1, buffer_free);` at file scope, its second
  argument the last member of the runtime your library calls without
  asking `EDITOR_PACKAGE_RUNTIME_HAS` first.

#### Testing it

A Rust library's tests run on the wrapper's fake runtime, on the test's
own thread, with no `unsafe`:

- `FakeRuntime::new().leak()` makes the fake, and
  `fake.init(editor_package_init)` runs your init on it, answering
  `(raw::INIT_LOADED, table)`.
- Call the table's functions, then read what reached the fake:
  `next_completion`, `next_event`, `services` and `outstanding` (buffers
  lent and not handed back).
- `FakeRuntime::over(source)`, with a `stream::fake::ScriptedSource`, for
  a child your library takes over.
- `RecordingCompleter` for the service port, in the logic's own tests.
- `FakeRuntime::new().sized(bytes).leak()` for an older, smaller runtime,
  whose init answers 1 (too small), and `FakeRuntime::new().later().leak()`
  for a newer, larger one. `sized` panics when `bytes` is more than the
  fake holds (the newer core's runtime, `later()`'s size).

Models: acp's `packages/acp/rust/tests/init.rs` and `not_loaded.rs`, and
echo's `tests/packages/echo/rust/tests/later_runtime.rs`. Echo and acp
also keep a `deny.toml` beside their crate, an allow list over its graph,
which you may copy.

The package's Lean side is tested as any port is: its model and contract
in its model tests, and its linked test (`<Package>Test.Linked`), which
loads the staged library through the real glue and asserts that a load
for another interface is refused naming the package
(`EchoTest.Linked.echoLoadChecks`, `AcpTest.Linked.acpLoadChecks`). A C,
C++ or Zig library's own unit tests are its language's; its load is
covered by the same linked test.

#### When a library is refused

Every refusal names the package. Nothing is published, and the running
editor keeps running. Where each one shows:

- **At `:reload`, the build.** Lake prints the sentence on an `error:`
  line in `*package-build*`. For a missing tool and an `editorRustCrate`
  target, the buffer ends `Package build failed: lake build exited with
  status 1: <sentence> after <t>`, and the echo area says `packages: lake
  build exited with status 1: <sentence>; this editor keeps running`. For
  the others, those two lines say `lake build exited with status 1`, and
  the sentence is in the buffer above them.
- **At start, caught by the build's probe.** The new editor's
  `builtin_initialize` throws the sentence, Lean's `main` prints
  `uncaught exception: <sentence>` and exits 1, and the build's probe
  fails: the buffer ends `Package build failed: the new editor did not
  start: it exited with status 1; uncaught exception: <sentence> after
  <t>`, and the echo area says `packages: the new editor did not start:
  it exited with status 1; uncaught exception: <sentence>; this editor
  keeps running`.

At `:reload`, from the build (`lean/lakefile.lean`):

| When | Message (exact) | What to do |
|---|---|---|
| The target's tool is missing (`libraryToolRequired`) | `<tool> is required to build <lake>'s library, and none works here (<how>): <install>, or use the package's prebuilt library, as its documentation says, then :reload`, where `<install>` is `install it with rustup from https://rustup.rs` for cargo and `install it` for any other tool | Install the tool, or use the package's prebuilt library, then `:reload` |
| The target failed for another reason | its own log, then `` the package <lake>'s library (its `editorLibrary` target) did not build `` | Fix the build error the log shows, or report it to the package's author |
| The target's value has no file name | `` the package <lake>'s library (its `editorLibrary` target) names no file: <library> `` | The package's target is wrong; report it to the author |
| `editorLibrary` is declared, but not as a target | `` the package <package> declares `editorLibrary`, but not as a target `` | The package's lakefile declares `editorLibrary` wrongly; it must be a `target`. Report it to the author |
| The package declares an `editorRustCrate` target (`rustCrateRefusal`) | `` <package> declares an `editorRustCrate` target, but the editor no longer compiles a package's Rust into its own archive: ship it as a package library of its own, declared with an `editorLibrary` target and written against `editor-package` (docs/packages/writing-a-package.md, 'A native library') `` | Ask the author for a version that ships a library |

At start, from the core (`lean/Editor/PackageLibrary.lean`,
`notStaged` and `LoadRefusal.describe`; the tag is the core's status):

| When | Message (exact) | What to do |
|---|---|---|
| No library is staged for the package (`notStaged`) | `<package>: no library is staged for its Lake package <lake> beside this editor (<record>); rebuild the package set (:reload)` | Rebuild the set with `:reload` |
| 1, missing | `<package>: its library <library> is missing; rebuild the package set (:reload)` | `:reload` |
| 2, not a library | `<package>: <library> is not a library this platform can load` | It is a library for another platform or architecture, or not a shared library: use the package's build for this platform |
| 3, no init | `<package>: the library <library> exports no editor_package_init` | The author must export it (`package!` in Rust, default visibility in C) |
| 4, runtime too small | `<package>: the library <library> needs a newer package runtime than this editor's` | Update the editor, or use an older build of the package |
| 5, failed init | `<package>: the library <library> failed its init` | The library's init refused for a reason of its own: report it to the author |
| 6, no declaration | `<package>: the library <library> exports no editor_package_declaration, so it says neither the runtime nor the interface it was built for; rebuild it against this editor's package runtime` | The author rebuilds the library against this editor's runtime (`package! { interface N; … }`, or `EDITOR_PACKAGE_DECLARE`) |
| 7, newer runtime | `<package>: the library <library> was built for a newer package runtime than this editor's: it needs <needs> bytes of runtime, and this editor's is <has>; update the editor, or use a build of <package> for this one` | Update the editor, or use a build of the package for this one |
| 8, another interface | `<package>: the library <library> has interface version <declared>, and this editor's <package> expects <expected>; rebuild the package set so the library and its package match` | Rebuild the set so the library and its glue match. For acp from a checkout, run `mise run install -- --agents` again after updating it |

#### Shipping it

- Say in the package's README which platforms its prebuilt library
  covers, and which tool builds it otherwise.
- The app is signed ad hoc without the hardened runtime, so a package's
  library needs no signature of the editor's.
- The library's load-time initialisers run in the user's editor, as all
  package code does ("Trust" in
  [installing-packages.md](installing-packages.md)).

## Shipping a grammar

A package can bring a tree-sitter grammar for a language the editor lacks,
with no rebuild of the editor: keep the grammar's prebuilt library, one per
platform, and its queries under a `grammars/` directory in the package,
give the lakefile `keywords = ["editor-grammars"]`, and declare the grammar
on your `Package` (`grammars := #[Language.Grammar.declarePerPlatform …]`),
with paths relative to `grammars/`, beside a `defineLanguage` that names
it. Build each library with `tree-sitter build`. The layout, the
declaration, the platform names and where the editor finds the files are in
[packages.md](../design/packages.md), ["A package's
grammars"](../design/packages.md#a-packages-grammars); the test package
[`ini-grammar`](../../tests/grammar-set/ini-grammar/IniGrammar.lean) is a
whole example.

Or ship the grammar from source, and let the set's build compile it for
the platform it builds on: hold a small Rust crate of your own (say
`rust/`) whose build script calls `editor-grammar-build` with the
grammars you declare, each a pinned build-dependency
(`build(&[Grammar::package("yaml", "tree-sitter-yaml")])`), and whose
`main` prints the report it wrote; then declare that crate's `Cargo.toml`
as a Lake input file named `editorGrammarSources` (`[[input_file]] name =
"editorGrammarSources"`, `path = "rust/Cargo.toml"`). Keep only the queries
and each grammar's licence under `grammars/`, and declare the libraries at
`<platform>/libtree-sitter-<name>.<ext>`, where the build stages them.
Building it needs Cargo and a C compiler on the user's machine; a source
that does not compile fails the set's build naming your package and the
grammar. The `languages` package
([`Languages/Grammars.lean`](../../packages/languages/Languages/Grammars.lean),
[`rust/`](../../packages/languages/rust)) is a whole example, and
[packages.md](../design/packages.md), "A package's grammars", "From
source", says how the build chooses between compiling and reusing.

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
