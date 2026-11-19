import Lake

open Lake DSL System

/-- The trivial package of the user-side link check (`mise run
user-link-check`, `tools/user-link-check.sh`;
`docs/design/lean-runtime.md`, "A link on the user's machine, measured"),
as the check stages it: one module with one command, its entry module, and
an `editor` linked from them, from the root the package-set build
generated and from pieces of the editor that are already built.

This is the package's lakefile on the user's side of the link. The check
copies it into `<stage>/package` beside the package's sources
(`tests/user-link/package`, whose own `lakefile.toml` is the package as
the checkout sees it, and is not staged) and the generated root,
`EditorSetRoot.lean`. It stands for the build a user's machine runs, which
the packages roadmap's later phases ship; the root it compiles is already
the generator's, not written here.

Nothing of the editor is built here. Its modules' `.olean` files come from
the package it requires (`«editor-core»` below), and their objects, the glue
object and the Rust archive are link arguments, all read from the stage the
check lays out and names with `-K stage=<dir>`.

Every Lean linter is on, and a warning fails the build, as in the editor's
own package. -/
package «user-link» where leanOptions := #[⟨`linter.all, true⟩, ⟨`warningAsError, true⟩]

/-- The stage: the directory `tools/user-link-check.sh` lays the pieces of
the relink out in, named with `-K stage=<dir>`. Without the option it is
the working directory, which holds no stage, and Lake says which directory
it did not find. -/
def stage : FilePath :=
  (get_config? stage).getD "."

/-- The editor's modules, prebuilt: `<stage>/core`, a package with no
target (`tools/user-link/core/lakefile.toml`), whose library directory holds
their `.olean` files. It is required by path, so nothing is fetched.

It is a package because that is how Lake lets this package's modules import
them. Lake hands `lean` a search path of the library directories of the
workspace's packages and nothing else, so an `LEAN_PATH` in the environment
does not reach a module's build (`Module.buildLean` in Lake's
`Build/Module.lean` passes the workspace's path alone). With no target,
Lake builds nothing of it and writes nothing into it. -/
require «editor-core» from stage / "core"

/-- The package's one module, with the one command. -/
lean_lib UserLinkFixture

/-- The package's entry module, `UserLink.EditorPackage`, which lists its
packages and which the generated root imports
(`docs/design/packages.md`, "A package's entry module"). -/
lean_lib UserLink where roots := #[`UserLink.EditorPackage]

/-- The files in `dir`, at any depth, whose names end with `ending`, in
order of their paths. -/
def filesEnding (dir : FilePath) (ending : String) : IO (Array String) := do
  let paths ← dir.walkDir
  return ((paths.map (·.toString)).filter (·.endsWith ending)).qsort (· < ·)

/-- The link arguments that name the system's libraries, for the stage
`stage`.

With stubs staged (`<stage>/stubs`, written by `tools/link-stubs.sh`): the
two search paths, then every stub the directory holds, a framework for each
`<name>.framework` and a library for each `lib<name>.tbd`, then the platform
version in the directory's `platform-version` (`<minos> <sdk>`). So the link
names exactly what the stage ships a stub for, no SDK is read, and the
executable records the SDK version the editor's own build recorded, where a
linker with no SDK would record the minimum macOS in its place.

With none: the frameworks and the two libraries the editor's own link names
(`linkArgs` in `lean/lakefile.lean`), for a linker that finds them in an
SDK, which is the check's `--linker system`. -/
def systemLibraryArgs (stage : FilePath) : IO (Array String) := do
  let stubs := stage / "stubs"
  if ← stubs.isDir then
    let names := ((← stubs.readDir).map (·.fileName)).qsort (· < ·)
    let named :=
      names.flatMap fun name =>
        if name.endsWith ".framework" then
          #["-framework", (name.dropEnd ".framework".length).toString]
        else if name.startsWith "lib" && name.endsWith ".tbd" then
          #[s!"-l{((name.drop 3).dropEnd 4).toString}"]
        else #[]
    let line := ((← IO.FS.readFile (stubs / "platform-version")).splitOn "\n").headD ""
    let [minos, sdk] := line.splitOn " " |
      throw <| IO.userError s!"{stubs / "platform-version"} must hold `<minos> <sdk>`, but holds {repr line}"
    return #["-F", stubs.toString, "-L", stubs.toString] ++ named ++
        #[s!"-Wl,-platform_version,macos,{minos},{sdk}"]
  else
    return #["-framework", "ApplicationServices", "-framework", "CoreGraphics", "-framework",
      "CoreVideo", "-framework", "Carbon", "-framework", "CoreFoundation", "-framework", "AppKit",
      "-framework", "Foundation", "-framework", "Metal", "-framework", "QuartzCore", "-framework",
      "CoreText", "-liconv", "-lobjc"]

/-- What the link of `editor` names beyond this package's own objects, all
of it under the stage:

- the editor's compiled modules, every `.c.o.export` under
  `<stage>/core/obj`;
- the glue object and the Rust archive, prebuilt;
- the directory of the toolchain's `libgmp`, `libuv`, `libssl` and
  `libcrypto`, which Lake leaves out when `LEAN_CC` is set;
- the entry point, as the editor's own link sets it (`linkArgs` in
  `lean/lakefile.lean`);
- the system's libraries (`systemLibraryArgs`);
- `-dependency_info`, so the linker writes every file it opened to
  `.lake/build/link.dependency-info` in this package, which the check reads.

The staged directories are read when the package is configured. -/
def stagedLinkArgs : Array String :=
  run_io do
    let core := stage / "core"
    let objects ← filesEnding (core / "obj") ".c.o.export"
    let libraries ← systemLibraryArgs stage
    let report := __dir__ / ".lake" / "build" / "link.dependency-info"
    return objects ++ #[(core / "glue.o").toString, (core / "libeditor_ffi.a").toString, "-L",
          (stage / "toolchain" / "lib").toString, "-Wl,-e,_editor_entry"] ++
        libraries ++
        #[s!"-Wl,-dependency_info,{report}"]

/-- The relinked editor: the root `EditorSetRoot`, linked with the staged
pieces. The root is the one the package-set build generates for the set
`tests/user-link`, the default set and this package (`lake -d
../tests/user-link query :editorRoot` in `lean/`), which the check stages
as `EditorSetRoot.lean` beside this file: the editor's own entry
(`Editor.Main.run`) handed the core's packages and then this package's. No
root is written by hand. `supportInterpreter` exports its symbols, as the
editor's own link does, so interpreted config finds compiled
definitions. -/
lean_exe editor where
  root := `EditorSetRoot
  supportInterpreter := true
  moreLinkArgs := stagedLinkArgs
