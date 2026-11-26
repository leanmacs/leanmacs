import Lake

open Lake DSL System

/-! The package `acp`: the implementation of `agents-api`'s service `agents`
over the Agent Client Protocol's Rust SDK (docs/design/agent-hosting.md,
"ACP"). It holds a crate of its own, `acp-service` (`rust/`), which pins the
SDK and keeps every SDK type inside it, and the glue that binds it
(`ffi/glue.c`), which the package-set build links into the set's editor
through the one Rust archive it generates from the set (the core's facet
`editorRust`; docs/design/packages.md, "Rust in a package").

It is an implementation package: it declares no `editor-interface`
keyword, and no package imports it (owner decision): consumers import
`agents-api` alone. It is opt-in (docs/design/packages.md, "The module
map"): the default set does not require it, since its crate needs the
user's own Cargo, which the app never ships; the fixture set
(tests/packages) does.

Its lakefile is Lean and not TOML, as echo's is: a TOML lakefile cannot
declare a target that compiles C, a library's `moreLinkObjs`, or the target
that declares the crate.

- `editorRustCrate` declares the crate: its manifest, `rust/Cargo.toml`.
- `acpGlue.o` is the package's glue, `ffi/glue.c`, compiled against the
  toolchain's `lean.h`.
- `Acp` is the package's library: the codec of the crate's text
  (`Acp.Codec`), the service over a binding (`Acp.Service`), Claude Code's
  adapter (`Acp.ClaudeCode`), the sessions and the conversation buffer
  (`Acp.Conversation` and the modules under it), its list of packages and
  its entry module. It requires `buffers-api` for the hook
  `BuffersApi.Closing`, at which a closed conversation buffer stops its
  session. `AcpReal` is the Rust-backed binding alone,
  whose `moreLinkObjs` is the glue, so the glue is linked into exactly the
  executables that import `Acp.Real`: the set's editor, through the entry
  module, and the linked test.
- `acp-test` is its test driver (`lake test`): the codec's golden lines,
  the service over a binding written in the test, and the conversation's
  pure parts and registration, which need no Rust, rooted at
  `AcpTest/Model.lean`.
- `AcpTest` holds the test modules, `AcpTest/Linked.lean` among them: the
  root of the executable the core's `editorLinked` facet links as the
  editor is linked, which runs the conversation on the stepped host over
  `agents-api`'s fake, and `agents-api`'s contract and the wiring check on
  the real crate; and `AcpTest/FixtureSupport.lean`, the setup of the
  headless fixture `tests/headless/conversation/`, which only the fixture
  harness's generated root imports.

After changing a `require`, run in lean/:
  lake -d ../packages/acp update --keep-toolchain
then the same for every set that reaches this package (tests/packages),
and commit each lake-manifest.json.

Every Lean linter is on and a warning fails the build, as in the core, and
the build's own linters are loaded as a Lean plugin (`lintPlugin`). -/

package acp where
  testDriver := "«acp-test»"
  leanOptions := #[⟨`linter.all, true⟩, ⟨`warningAsError, true⟩]

require «agents-api» from ".." / "agents-api"

/-- The interface package of the buffer commands: the hook `BuffersApi.Closing`,
at which closing a conversation buffer stops its session. -/
require «buffers-api» from ".." / "buffers-api"

require «editor-core» from ".." / ".." / "lean"

/-- The core's build linters as a Lean plugin, which each library and the
test driver load (the core's `lintPlugin`). -/
def lintPlugin : TargetArray Dynlib :=
  #[`@«editor-core»/lintShared]

/-- The package's crate: the path of its manifest. -/
target editorRustCrate pkg : FilePath :=
  return Job.pure (pkg.dir / "rust" / "Cargo.toml")

/-- The package's glue (`ffi/glue.c`), compiled against the toolchain's own
`lean.h`. Nothing lints C for us, so every warning is an error. -/
target acpGlue.o pkg : FilePath := do
  let srcJob ← inputTextFile <| pkg.dir / "ffi" / "glue.c"
  buildLeanO (pkg.buildDir / "ffi" / "glue.o") srcJob #[] #["-O2", "-Wall", "-Wextra", "-Werror"]

/-- The codec, the service, the packages and the entry module: every module
of the package but its tests and the binding. -/
@[default_target] lean_lib Acp where
  globs :=
  #[.one `Acp.Codec, .one `Acp.Service, .one `Acp.ClaudeCode, .andSubmodules `Acp.Conversation,
    .one `Acp.Packages, .one `Acp.EditorPackage]
  plugins := lintPlugin

/-- The Rust-backed binding, with the package's glue. -/
@[default_target] lean_lib AcpReal where
  roots := #[`Acp.Real]
  moreLinkObjs := #[acpGlue.o]
  plugins := lintPlugin

/-- The test modules. -/
@[default_target] lean_lib AcpTest where
  globs := #[.submodules `AcpTest]
  plugins := lintPlugin

/-- The test driver: the tests that need no Rust. -/
lean_exe «acp-test» where
  root := `AcpTest.Model
  plugins := lintPlugin
