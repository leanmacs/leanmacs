import Lake

open Lake DSL System

/-! The package `acp`: the implementation of `agents-api`'s service `agents`
over the Agent Client Protocol's Rust SDK (docs/design/agent-hosting.md,
"ACP"). It holds a crate of its own, `acp-service` (`rust/`), which pins the
SDK and keeps every SDK type inside it, and ships it as a library of its own
(docs/design/packages.md, "acp, ported, as built"): the package-set build
stages it beside every editor it links, and the glue that binds it
(`ffi/glue.c`) asks the core to load it from there when the editor starts.
No crate of a package is compiled into the editor's Rust archive.

It is an implementation package: it declares no `editor-interface`
keyword, and no package imports it (owner decision): consumers import
`agents-api` alone. It is opt-in (docs/design/packages.md, "The module
map"): the default set does not require it, since the bundle stages no
package's library yet; the fixture set (tests/packages) does, and
`mise run install -- --agents` adds it to a user's config with its library
built from the checkout.

Its lakefile is Lean and not TOML, as echo's is: a TOML lakefile cannot
declare a target that compiles C, a library's `moreLinkObjs`, or the target
that builds the library.

- `editorLibrary` is the package's library: the crate's `cdylib`, built by
  Cargo. The core's package-set build stages it beside every editor it
  links, and writes where in `<executable>.libraries`.
- `acpGlue.o` is the package's glue, `ffi/glue.c`, compiled against the
  toolchain's `lean.h`, with no path compiled in: `Acp.Real`'s initialiser
  reads the library's staged path from the record beside the running
  executable and hands it to the glue's load. The library is not linked,
  so a rebuilt library needs no relink.
- `Acp` is the package's library: the codec of the crate's text
  (`Acp.Codec`), the service over a binding (`Acp.Service`), Claude Code's
  adapter (`Acp.ClaudeCode`), the sessions and the conversation buffer
  (`Acp.Conversation` and the modules under it), the rewrite of a buffer
  whose text it generates (`Acp.Generated`), the queue of permission
  requests, the policy's application and the audit log (`Acp.Permissions`
  and the modules under it), the agent table, its agents lists, the stall
  watchdog and resume (`Acp.Table` and the modules under it), its list of
  packages and its entry module. It requires `buffers-api` for the hook
  `BuffersApi.Closing`, at which a closed conversation buffer stops its
  session. `AcpReal` is the Rust-backed binding alone,
  whose `moreLinkObjs` is the glue, so the glue is linked into exactly the
  executables that import `Acp.Real`: the set's editor, through the entry
  module, and the linked test.
- `acp-test` is its test driver (`lake test`): the codec's golden lines,
  the service over a binding written in the test, and the conversation's
  and the permissions' pure parts and registration, which need no Rust,
  rooted at `AcpTest/Model.lean`.
- `AcpTest` holds the test modules, `AcpTest/Linked.lean` among them: the
  root of the executable the core's `editorLinked` facet links as the
  editor is linked, which runs the conversation and the permissions on the
  stepped host over `agents-api`'s fake, the load of acp's library, and
  `agents-api`'s contract and the wiring check on the library; and `AcpTest/FixtureSupport.lean`, the setup of the
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

/-- The package's library (`docs/packages/writing-a-package.md`, "A native
library"), the target the package-set build stages beside every editor it
links (`editorLibrary`, found by name by the core's `setLibraries`): its
value is the library's absolute path, the crate's `cdylib` built by Cargo
through Lake's `proc` with its own up-to-date check (`cargo build --release
--locked --lib -p acp-service`) over the repository's manifest, into its
target directory, which the core's Rust builds share. `cargo` is the bare
command name, as the core's `buildRust` keeps it, so a missing Cargo fails
with Lake's own spawn line, which the core's staging reports naming acp and
cargo. Only the package-set build reaches this target, never the package's
test driver, so `mise run lean-test`'s failing `cargo` never runs it.

Its content is the trace. -/
target editorLibrary pkg : FilePath :=
  Job.async do
    let extension := if Platform.isOSX then "dylib" else "so"
    let name := s!"libacp_service.{extension}"
    let repo ← IO.FS.realPath (pkg.dir / ".." / "..")
    let targetDir := repo / "target"
    proc (quiet := true)
        { cmd := "cargo"
          args :=
            #["build", "--release", "--locked", "--lib", "-p", "acp-service", "--manifest-path",
              (repo / "Cargo.toml").toString, "--target-dir", targetDir.toString] }
    let library := targetDir / "release" / name
    setTrace (← computeTrace library)
    return library

/-- The package's glue (`ffi/glue.c`), compiled against the toolchain's own
`lean.h`. No path is compiled in: the library is the one the package-set
build staged beside the executable, which `Acp.Real`'s initialiser finds
when it runs. Nothing lints C for us, so every warning is an error. -/
target acpGlue.o pkg : FilePath := do
  let srcJob ← inputTextFile <| pkg.dir / "ffi" / "glue.c"
  buildLeanO (pkg.buildDir / "ffi" / "glue.o") srcJob #[] #["-O2", "-Wall", "-Wextra", "-Werror"]

/-- The codec, the service, the packages and the entry module: every module
of the package but its tests and the binding. -/
@[default_target] lean_lib Acp where
  globs :=
  #[.one `Acp.Codec, .one `Acp.Service, .one `Acp.ClaudeCode, .andSubmodules `Acp.Conversation,
    .one `Acp.Generated, .andSubmodules `Acp.Permissions, .andSubmodules `Acp.Table,
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
