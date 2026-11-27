import Editor.RealHost
import Editor.Test.Linked.Services
import Editor.Test.Linked.Trees
import Editor.Test.Linked.UserSet
import LanguagesTest.Check
import LanguagesTest.Linked.Languages.Grammars.Real

/-!
# Linked tests: a set whose package's grammar source does not compile fails its build, naming the package and the grammar

The failure check of a grammar shipped from source
(`docs/design/packages.md`, "A package's grammars", "From source"), with
the toolchain's `lake` the linked test is handed, through the real process
port, in a temporary directory of the check's own:

- It writes a package `broken-grammar` there: a `lakefile.toml` with the
  keyword `editor-grammars` and the input file `editorGrammarSources`, whose
  path is the absolute `Cargo.toml` of the fixture crate
  `editor-grammar-build-fixture`, whose one grammar, `broken`, does not
  compile; and an empty `grammars/queries/`. Beside it, a set requiring
  the package and the core by their absolute directories.
- `lake update --keep-toolchain` resolves the set, and
  `lake build :editorGrammars` must exit non-zero with the core's sentence
  for the package and the grammar (`grammarDidNotCompile` in
  `lean/lakefile.lean`, whose `#guard` pins the whole text). The set is
  outside the repository and the package has neither a
  `grammars/<platform>/` nor a build directory, so the set's build runs
  Cargo on the fixture crate: the branch a third party's source package
  takes (`grammarSourceForm`).

**The child's environment** is the test's own, `PATH` and `HOME` passed
through, so `cargo` and its registry cache are the developer's, with
`CARGO_NET_OFFLINE=true`, so nothing is fetched: the fixture crate's
dependencies are in the root lock, which the gate's Rust steps fetched.

**What it writes outside its directory.** The fixture crate is a member of
the root workspace, so Cargo builds it in the root's `target/`, the build
cache every set build in the gate writes; and Lake reads the core's
lakefile as the core's own builds leave it. Its directory is removed only
once a flush of the process service and of the file service has completed
(`Editor.Test.Linked.withFlushedBase`), so nothing still runs in it. Each
run's completion is waited for on the run itself, the bound a hang guard.

The linked test runs in the package's directory (`tools/package-set.sh`),
so the repository is found from there.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.LanguagesTest.Linked.Languages.Grammars.Real.SourceSet : Editor.WiringSet :=
  .wiring
    "the toolchain's lake, and cargo through the set's build, run through the real process port on a set in a temporary directory of its own"
    "only a real build shows that a grammar source that does not compile fails the set's build; no fake builds a set"

namespace LanguagesTest.Linked

open Editor Editor.Test.Linked

/-- The lakefile of the package `broken-grammar`: the grammars keyword, and
its grammar sources at `manifest`. -/
def brokenGrammarLakefile (manifest : System.FilePath) : String :=
  s!"name = \"broken-grammar\"\nkeywords = [\"editor-grammars\"]\n\n[[input_file]]\nname = \"editorGrammarSources\"\npath = \"{manifest}\"\n"

/-- The start of the sentence the set's build fails with for the package
`broken-grammar`'s grammar `broken` (`grammarDidNotCompile` in
`lean/lakefile.lean`, whose `#guard` pins the whole text), and of the
reason the fixture's compile gives. -/
def brokenGrammarSaid : String :=
  "the package `broken-grammar`'s grammar `broken` did not compile from its source: the C compiler failed"

/-- The checks of a set whose package's grammar source does not compile,
built with the toolchain's `lake` through the context's real process port,
in a temporary directory of its own. -/
def sourceSetChecks (context : Context) : List Check :=
  [{  name :=
        "a set whose package declares a grammar source that does not compile fails its build with lake build :editorGrammars, naming the package broken-grammar and the grammar broken"
      run :=
        withFlushedBase context.services.jobs fun tmp => do
          let repo ← IO.FS.realPath (".." / "..")
          let lake := (context.sysroot / "bin" / "lake").toString
          let environment : Process.Environment := { set := #[("CARGO_NET_OFFLINE", "true")] }
          let package := tmp / "broken-grammar"
          IO.FS.createDirAll (package / "grammars" / "queries")
          IO.FS.writeFile (package / "lakefile.toml")
              (brokenGrammarLakefile
                (repo / "crates" / "editor-grammar-build-fixture" / "Cargo.toml"))
          let set := tmp / "set"
          IO.FS.createDirAll set
          IO.FS.writeFile (set / "lakefile.toml")
              (userSetLakefile "source-set"
                [("broken-grammar", package), ("editor-core", repo / "lean")])
          if let .error how←
              lakeSucceeds context.services lake environment set
                #["update", "--keep-toolchain"] then
            return ← saw false how
          match
            ←
              runToEnd context.services
                  { program := lake, arguments := #["build", ":editorGrammars"], environment,
                    directory := set } with
          | .error how =>
            saw false how
          | .ok ran =>
            saw (ran.exit != .code 0 && (ranLines ran).any (·.contains brokenGrammarSaid))
                s!"the build ended {repr ran.exit}:\n{ranTail ran}" }]

end LanguagesTest.Linked
