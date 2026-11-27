import Acp.Real
import AcpTest.Check
import Editor.PackageLibrary
import Editor.RealHost
import Editor.Restore.Restart
import Editor.Test.Linked.Services
import Editor.Test.Linked.Trees
import Editor.Test.Linked.UserSet

/-!
# Linked tests: a config laid out as `install --agents` leaves it builds with no Cargo, and its editor loads acp's library

`mise run install -- --agents` builds acp's library from the checkout into
the package's `lib/` and adds `agents-api` and `acp`, by the checkout's
paths, to the config's lakefile, ahead of `editor-core`
(`tools/install-app.sh`). The installed app's `:reload` then builds that
config with the bundle's `lake` and no Cargo: the core's archive is
reused as it is built (`rustSource false`), and acp's library target, for
a set outside the repository whose package holds `lib/`, answers the
library already built (`acpLibraryForm`, `acpInRepository` in acp's
lakefile). This check builds such a config with the toolchain's `lake` the
linked test is handed, through the real process port, in a temporary
directory of its own, with no `cargo` on the child's `PATH`
(docs/design/packages.md, "acp, ported, as built"):

1. It checks no `cargo` is on that `PATH` first: on a machine where one is,
   it fails saying it cannot show the property, rather than passing.
2. It copies acp (the working directory, `.lake` left out) to
   `<tmp>/checkout/packages/acp`, beside a stub `<tmp>/checkout/Cargo.toml`,
   so that, as in the real checkout, the directory two above acp holds a
   `Cargo.toml` and only the workspace's root, the config outside it, makes
   the set a user's. It puts the library this linked test loaded
   (`Editor.PackageLibrary.staged "acp" "acp"`) at the copy's
   `lib/libacp_service.<ext>`, and points the copy's three requires
   (`agents-api`, `buffers-api`, `editor-core`) at the checkout's
   (`Editor.Test.Linked.repointRequires`).
3. It writes `<tmp>/config/lakefile.toml` as the install leaves a config
   that had none: the editor's generated lakefile with `agents-api` and the
   copy of acp added through `:package-install`'s core-last edit
   (`Editor.Test.Linked.installedConfigLakefile`), the checkout's default
   set and core standing in for the bundle's. It asserts, on the written
   text, that the requires are `default-set`, `agents-api`, `acp`,
   `editor-core` in that order, the core last, as `coreRefusal?` and the
   install require.
4. It runs `lake update --keep-toolchain`, then `lake build :editor`, both
   exiting 0: any Cargo run, for the core's archive, for acp's library or
   for a package's grammars, fails to spawn and fails the build. The config
   requires the checkout's default set, whose `languages` takes its grammar
   libraries from its build directory, which `mise run lean` filled
   (`grammarSourceForm`'s built branch, `lean/lakefile.lean`).
5. It removes the copy of acp, asserts the editor's `editor.libraries`
   names acp's library staged under the config's build directory, and that
   the editor's `--probe` passes the build's own judgement
   (`Editor.Restore.probeFailure`), which it reaches only once
   `Acp.Real`'s initialiser has loaded the library, from there.

**The child's environment** is the build job's shape, over the fixture
set's build record, with `PATH=/usr/bin:/bin` and a `HOME` of the check's
own (`Editor.Test.Linked.userSetEnvironment`). **What it writes outside
its directory** is only what the core's, the default set's and
`agents-api`'s builds would write in place, which `mise run lean` built
just before. Its directory is removed only once a flush of the process
service has completed (`Editor.Test.Linked.withFlushedBase`), so nothing
still runs in it. Each run's completion is waited for on the run itself
(`Editor.Test.Linked.runToEnd`), the bound a hang guard
(`Editor.Test.Linked.userSetBuildGuard`).

The linked test runs in the package's directory (`tools/package-set.sh`),
so acp's source and the repository are found from there.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.AcpTest.Linked.Acp.Real.InstalledSet : Editor.WiringSet :=
  .wiring
    "the toolchain's lake and the editor it builds, run through the real process port on a config laid out as install --agents leaves it, in a temporary directory of its own"
    "only a real build shows which tools a set's build runs, and only a real executable loads acp's staged library; no fake builds a set or starts an editor"

namespace AcpTest.Linked

open Editor Editor.Test.Linked

/-- The library file a build of acp makes on this platform. -/
def acpLibraryFile : String :=
  s!"libacp_service.{if System.Platform.isOSX then "dylib" else "so"}"

/-- The requires of the config's lakefile, in order, as the install leaves
them: the set, the two agents packages, and the core last. -/
def installedRequires : List String :=
  ["default-set", "agents-api", "acp", "editor-core"]

/-- Copies acp, from the working directory, into the package directory of
a checkout at `checkout` (`<checkout>/packages/acp`, beside a stub
`<checkout>/Cargo.toml`), with `library` at its `lib/` and its requires
pointed at the repository `repo`'s packages and core; answers the copy. -/
def copyAcp (checkout repo : System.FilePath) (library : String) : IO System.FilePath := do
  let copy := checkout / "packages" / "acp"
  copyPackage "." copy
  IO.FS.writeFile (checkout / "Cargo.toml")
      "# A stub: the directory two above acp holds a Cargo.toml, as the checkout does.\n"
  repointRequires copy
      [{ line := "require «agents-api» from \"..\" / \"agents-api\"", relative := "../agents-api",
         directory := repo / "packages" / "agents-api" },
        { line := "require «buffers-api» from \"..\" / \"buffers-api\"",
          relative := "../buffers-api", directory := repo / "packages" / "buffers-api" },
        { line := "require «editor-core» from \"..\" / \"..\" / \"lean\"", relative := "../../lean",
          directory := repo / "lean" }]
  IO.FS.createDirAll (copy / "lib")
  IO.FS.writeBinFile (copy / "lib" / acpLibraryFile) (← IO.FS.readBinFile library)
  return copy

/-- The check of a config laid out as `install --agents` leaves it, built
with the toolchain's `lake` under `sysroot` through `services`' real
process port, in a temporary directory of its own. -/
def acpInstalledSetChecks (sysroot : String) (services : Editor.Test.Linked.Services) :
    List Check :=
  let lake := (System.FilePath.mk sysroot / "bin" / "lake").toString
  [{  name :=
        "a config laid out as install --agents leaves it, with acp's library already built in its lib/, builds with the toolchain's lake and no cargo on PATH, and its editor loads acp's library from the set's build once acp's source is removed"
      run :=
        Editor.Test.Linked.withFlushedBase services.jobs fun tmp => do
          if let some reason← cargoOnUserPath? then
            return ← saw false reason
          let repo ← IO.FS.realPath (".." / "..")
          let record ←
            IO.FS.readFile
                (repo / "tests" / "packages" / ".lake" / "build" / "bin" / "editor.build")
          let home := tmp / "home"
          IO.FS.createDirAll home
          let environment := userSetEnvironment record home
          let acp ← copyAcp (tmp / "checkout") repo (← Editor.PackageLibrary.staged "acp" "acp")
          let config := tmp / "config"
          IO.FS.createDirAll config
          let text ←
            match
              installedConfigLakefile config (repo / "packages") (repo / "lean")
                [("agents-api", repo / "packages" / "agents-api"), ("acp", acp)] with
            | .ok text =>
              pure text
            | .error how =>
              return ← saw false s!"the config's lakefile could not be made: {how}"
          unless
            requireNames text == installedRequires && lastRequireName? text == some "editor-core" do
            return ←
                saw false
                    s!"the config's lakefile requires {requireNames text}, not {installedRequires} with the core last:\n{text}"
          IO.FS.writeFile (config / "lakefile.toml") text
          if let .error how←
              lakeSucceeds services lake environment config #["update", "--keep-toolchain"] then
            return ← saw false how
          if let .error how←
              lakeSucceeds services lake environment config #["build", ":editor"] then
            return ← saw false how
          IO.FS.removeDirAll acp
          let editor := config / ".lake" / "build" / "bin" / "editor"
          let staged := config / ".lake" / "build" / "libraries" / "acp" / acpLibraryFile
          let libraries ← IO.FS.readFile (editor.toString ++ ".libraries")
          unless libraries == s!"acp\t{staged}\n" do
            return ←
                saw false
                    s!"the config's editor.libraries holds {repr libraries}, not acp's library at {staged}"
          match
            ←
              runToEnd services
                  { program := editor.toString, arguments := #["--probe"], directory := "/" } with
          | .error how =>
            saw false how
          | .ok ran =>
            let failure := Editor.Restore.probeFailure ran
            saw (failure == none)
                s!"the config's editor, with acp's source removed: {failure.getD ""}" }]

end AcpTest.Linked
