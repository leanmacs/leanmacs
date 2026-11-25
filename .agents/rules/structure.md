# Module structure

What a module may import, where the core's modules sit, which targets
load the build's linters, where a Rust crate's bans live and where a site
may opt out of them, and how a Lake root reads the Lean pin. Review holds a change to these rules; no gate
step checks them (`gates.md`). The Lean linters (the wait and real-host
linters) and Lake's own resolution of `require`s stay automated, and
rdm task `lean-structure-rules-tool` is where automated checking of the
rules below comes back.

## Core imports

- `Editor.Core` is the core's root. It imports, directly or through other
  modules, every `Editor.…` module that any build root reaches. Import a
  new core module from the root in the change that adds it, so the build
  makes it and nothing in the core is left outside.
- The core imports no package. A feature that is moving out of the core
  has its imports from the core cut before it moves; Lake refuses the
  import once it has moved, since the core requires no package.
- Every executable root that reaches the config elaborator adapter
  (`Editor.Config.Elaborate`) also links the config base (`Editor`): the
  elaborator imports the base's modules at runtime, so each must already be
  linked in. That includes the root the package-set build generates for
  the editor and the one it generates for the fixture harness.
- The config base and the model tests' root (`ModelTest`) are plain Lean.
  Neither they nor anything they import, directly or not, imports `Lean`,
  `Lake` or a module under them: a base that holds Lean's frontend costs
  every config its memory and its start, and `model-test` tests the session
  on a model of the elaborator.
- The model tests' root reaches no raw binding (`Editor.Ffi` or anything
  under it): `model-test` links no Rust library. Write a port's fakes and
  contracts over the port alone.

See `docs/design/packages.md`, "The core's root", and
`docs/design/overview.md`, "Config is elaborated behind a port, and two
adapters link Lean's frontend".

## Host imports

- The executable's host modules import no feature module. The host modules
  are everything a generated set root, or the fixture harness's root,
  imports apart from the entry modules (`….EditorPackage`), with what
  those import. A feature module is an entry module or a module an entry
  module imports directly.
- The host is handed its packages as a value, by the executable's root,
  and names none of them. An entry module imports package modules and
  nothing else.

See `docs/design/lean-runtime.md`, "Packages".

## What a package may import

The rule is about direct `import` lines, by four kinds of importer.

- A library module imports only the core's API and the core interface
  (`FilesApi`).
- A test module (`<P>Test.…`) may also import the test doubles: the pure
  models, contracts, fakes, `Editor.Test` and what is under it except
  `Editor.Test.Linked`, a feature's kit still in the core (`Editor.*.Kit`),
  and `FilesApiTest` except what is under `FilesApiTest.Linked`.
- The linked test (`<P>Test.Linked` and the modules under it) may also
  import the linked test kit (`Editor.Test.Linked…`, `<I>Test.Linked…`).
- The linked test's root alone may also import the real bindings of the
  ports (`….Real`), the headless host (`Editor.Headless`) and the config
  base (`Editor`): it is an executable's root, linked as the editor is.
  Nothing else opens to it: the window hosts' real modules
  (`Editor.Window.Real`, `Editor.WindowCheck.Real`), the raw bindings
  (`Editor.Ffi…`), the loop, the rest of the config session and the
  host's parts (`Editor.Headless.Queue`, `.Stepped`, `.Wait`,
  `Editor.Job.Activity`) stay refused to the root as to every other
  module.
- No package module imports an internal module, the linked test's root
  included beyond the three exceptions above: the hosts and their parts
  (`Editor.Headless.Queue`, `.Stepped`, `.Wait`, `Editor.Job.Activity`),
  the loop and its dispatch, the config session, the raw bindings,
  `Editor.Core`, `Editor.Internal…`, or any module of the core's Lake
  package not named `Editor.…` other than the core interface.

A core module that is neither internal nor a test double is part of the
API. See `docs/design/packages.md`, "What a package may import", for the
full lists.

## Three layers

- The core imports nothing of any package.
- No package, interface or implementation, imports a module of an
  implementation package. That holds of its tests and its linked test too:
  a test that imports another feature's implementation stops building
  when that feature is left out, so use the interface package's fake.
- A package is an interface only if its lakefile declares
  `keywords = ["editor-interface"]`; every other package is an
  implementation package.

See `docs/design/extension-points.md`, "Three layers".

## Leave-out

- Every implementation package can be dropped from a set's `[[require]]`s,
  and the set still builds an editor whose generated root imports every
  other entry module. It follows from the three-layer rule.
- To check it by hand, drop one `[[require]]` from a set's lakefile, run
  `lake update --keep-toolchain` there and then `lake build --wfail :editor`.

See `docs/design/packages.md`, "The generated root", and
`docs/design/extension-points.md`, "Three layers".

## Module map

- When you add, move or remove a module under `lean/Editor/`, a package, a
  package's layer, or a package's registration at or read of an extension
  point, update the module map in `docs/design/packages.md` ("The module
  map") in the same change.
- "The core's modules" names every `Editor.…` module and no others.
- Each package of the default set has a row with its layer, its
  registrations (column 4) and its reads (column 5).

## Lint plugins

- Every `lean_lib` and `lean_exe` of the core and of every package in this
  repository loads the build's linters as a plugin (`plugins`, the core's
  `lintPlugin`: `lean/Lint/Wait.lean`, `lean/Lint/RealHost.lean`), or
  imports the core's `Lint`. A target that loads no plugin is never
  linted, and nothing else says so.
- A package written as a user's (`docs/packages/word-count`) is not held
  to this.

See `docs/dev-practices/the-gate.md`, "The wait lints".

## Clippy's bans

What clippy holds (the bans, the lint levels, a stale or reasonless mark)
it holds by itself under `mise run lint`; these are the parts of the rule
it cannot see.

- Every ban lives in the root `clippy.toml`. No crate, and no fixture,
  gets a `clippy.toml` of its own: clippy reads only the nearest one, so a
  crate with its own would read none of the root's bans.
- Every workspace member's `Cargo.toml` has `[lints] workspace = true`,
  so the root `Cargo.toml`'s `[workspace.lints.clippy]` levels hold in it.
  A package's crate (`tests/packages/*/rust`, `packages/*/rust`) too.
- An opt-out from `disallowed_methods` is an `#[expect(…, reason = "…")]`
  at its site: on the statement or `let` that makes the banned call, or on
  the `fn` or `impl` whose call it is; never on a module or a crate, a
  test module and a test file included: the wait bans are the same lint,
  and a module's or crate's mark would silence them there. Its reason says
  what the site waits for, or reaches, and why. A test module that calls
  its readout again and again does so through one helper `fn`, whose
  statement carries the mark. A mark on an `assert!` does nothing (lint
  attributes on a macro's statement are unused), so bind the call with a
  `let` first.
- An item's mark never covers a wait. A banned wait inside an `fn` or an
  `impl` that carries a `disallowed_methods` mark for the outside world, or
  for another wait, has a statement-level
  `#[expect(clippy::disallowed_methods, reason = "…")]` of its own, whose
  reason is the wait's. Prefer a statement's mark to an item's in a
  function that holds any wait.
- An opt-out from `disallowed_types`, which bans no wait, may sit on a
  crate only in a crate whose job is the real file system.
- Each new wait-ban path that a crate other than its owner can call gets
  one call in `tests/wait-lints/src/lib.rs`, under an `#[expect]` of its
  own that covers that call alone.
- Each `allow-invalid` ban has a call under an `#[expect]` that covers it
  alone: at a site in the workspace, or, for an entry point no crate
  calls, in `tests/wait-lints/src/lib.rs` (`unreached`). Clippy does not
  refuse an `allow-invalid` path that resolves to nothing, so a ban with
  no such call bans nothing and fails nothing. When the last site of one
  goes, its call moves to the fixture.

See the root `clippy.toml`'s header and
`docs/dev-practices/the-gate.md`, "The wait lints".

## The Lean pin

- `lean/lean-toolchain` is the one pin. A new Lake root outside `lean/`
  links its `lean-toolchain` to it with a relative symbolic link (`ln -s
  <relative path>/lean/lean-toolchain lean-toolchain`) and never copies
  it, so a bump of the pin changes one file.
- A script or build step that carries such a directory out of the tree
  dereferences the link (`cp -RL`, or the file's resolved path, as
  `editorShipped` lists it), so what leaves holds the pin's text rather
  than a link that dangles.

See `docs/design/packages.md`, "The toolchain links".
