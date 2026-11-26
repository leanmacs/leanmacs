import Editor.Extension
import Editor.Process.Environment
import Editor.Setup
import EnvironmentApi

/-!
# mise, as a child's directory environment source

`mise env --json`, run in a child's directory, as a directory source of the
core's interface library `environment-api` (`EnvironmentApi.DirectorySource`,
`lean/EnvironmentApi.lean`): the core layers what it prints over the base,
for each directory, kept by the stamps of mise's config files
(`Editor/Process/Environment.lean`). The value the package registers is
`directorySource` (`Mise/Compiled.lean`); config's setting is
`Mise.executable`.

## The rules

- **Where mise is.** Never looked up by bare name: launchd's `PATH` holds
  none of the usual places. In the window mode, the first of
  `~/.local/bin/mise`, `/opt/homebrew/bin/mise` and `/usr/local/bin/mise`
  whose stamp a file request answers (`candidates`), resolved once and kept
  until a reload; with none of them there it is skipped, and nothing is
  said.
- **The headless mode looks nothing up**: the value gives no source there,
  so the checks and the headless fixtures start their children exactly as
  their commands say.
- **The setting.** `Mise.executable "/path"` in config registers a value of
  the same name, `mise`, at `/path`, in every mode (`at`); the hook replaces
  the package's value with it in its place (`EnvironmentApi.DirectorySource.ordered`).
  A relative path is refused (`relativePath`). It replaces the retired
  `processEnvironment (.mise (some path))`.
- **No lookup at all**: leave this package out of the package set, which
  replaces the retired `processEnvironment .inherited`.
- **The lookup** (`lookupCommand`): `<mise> env --json` in the directory,
  with the layers below set over the editor's environment; what it prints is
  one JSON object of strings, read with the core's `Process.parseVariables`,
  under the core's time and output limits.
- **What keeps it** (`stampNames`): the stamps of `mise.toml`, `.mise.toml`,
  `.tool-versions` and `mise.local.toml` in the directory and each of its
  ancestors. mise also reads its global config and environment variables; a
  change to those is picked up after a reload.

Pinned by `MiseTest.miseChecks` and `MiseTest.miseLookupChecks` on the
models, and by `MiseTest.Linked.miseContractChecks` over the real process
service.
-/

namespace Mise

open Editor

/-- Where mise is looked for in the window mode, in order: under the home
directory, if there is one, then Homebrew's two prefixes. -/
def candidates (home : Option System.FilePath) : Array System.FilePath :=
  let underHome : Array System.FilePath :=
    match home with
    | some home => #[Process.inDirectory home ".local/bin/mise"]
    | none => #[]
  underHome ++ #[("/opt/homebrew/bin/mise" : System.FilePath), "/usr/local/bin/mise"]

/-- The lookup's command: `executable env --json` in `directory`, with
`environment`, the variables of the layers below, set over the editor's. -/
def lookupCommand (executable : System.FilePath) (directory : System.FilePath)
    (environment : Process.Environment := {}) : Process.Command :=
  { program := executable.toString, arguments := #["env", "--json"], directory, environment }

/-- The names of mise's config files: the files whose stamps keep a
directory's lookup. -/
def stampNames : Array String :=
  #["mise.toml", ".mise.toml", ".tool-versions", "mise.local.toml"]

/-- mise, with its executable at `program`, as a source: it prints a JSON
object of strings, and its result is kept by the stamps of `stampNames`. -/
def source (program : Process.Program) : Process.Source :=
  { name := "mise", program
    command := fun executable directory environment =>
      lookupCommand executable directory environment
    parse := Process.parseVariables, output := "a JSON object of strings", stampNames }

/-- The package's directory source: in the window mode, mise at the first of
`candidates` there is, skipped with none; in the headless mode, no lookup. -/
def directorySource : EnvironmentApi.DirectorySource :=
  { name := "mise"
    source := fun
      | .headless => none
      | .window home => some (source (.firstOf (candidates home) .skip)) }

/-- The directory source of mise at `path`, in every mode: what config's
setting registers. -/
def «at» (path : System.FilePath) : EnvironmentApi.DirectorySource :=
  { name := "mise", source := fun _ => some (source (.at path)) }

/-- What `Mise.executable` is refused with for a path that is not absolute. -/
def relativePath (path : System.FilePath) : String :=
  s!"the path to mise must be absolute: {path}"

/-- The package's setting, called in config: runs mise at `path`, an
absolute path, in place of looking for it in the usual places, in every
mode. It registers a value of the name `mise`, which replaces the package's
in its place. It replaces the retired `processEnvironment (.mise (some
path))`. Refuses the `setup` for a path that is not absolute. -/
def executable (path : System.FilePath) : SetupM Unit := do
  unless path.isAbsolute do
    throw (relativePath path)
  Extension.add («at» path)

end Mise
