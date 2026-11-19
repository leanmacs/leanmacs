import Editor.ModuleLookup

/-!
# The headless mode's command line

`editor headless [--render] [<sysroot> <olean dir>] <config dir> <script file>`
(`Editor/Headless.lean`). This module is the pure part of it: what the
command line after `headless` asks for, given where the executable is. It
reads nothing itself, so `model-test` pins it
(`ModelTest.headlessCommandLineChecks`).

- **Four paths** are the Lean toolchain's directory, the directory of the
  editor's `.olean` files, the config directory and the script, wherever the
  executable is. The `.olean` directory is a search path: one directory, or
  several joined with `:`, searched in order; outside a bundle the
  directories the build recorded for the executable are searched after
  them (`Editor/ModuleLookup.lean`, "The record"), so the core's directory
  alone is enough for an editor the package-set build linked.
- **Two paths** are the config directory and the script, and the two module
  directories are resolved from the executable's path
  (`Editor/ModuleLookup.lean`): in a bundle, the bundle's. Outside one there
  is no toolchain to use, so two paths are refused there (`noToolchain`):
  the headless mode never runs without one, and never looks for one
  relative to the working directory.
- **`--render`**, before the paths, draws what the host publishes.

The two directories are given both or neither, so three or five paths are
refused, and so is any other first argument starting with `--`. Nothing is
read from the environment.
-/

namespace Editor.Headless

/-- What the headless mode's command line asks for. -/
structure Arguments where
  /-- Whether to draw (`--render`). -/
  render : Bool
  /-- The Lean toolchain's directory. -/
  sysroot : String
  /-- The directories of the editor's `.olean` files, in the order they
  are searched; never empty. -/
  oleans : List String
  /-- The config directory. -/
  config : String
  /-- The script file. -/
  script : String
  deriving DecidableEq, Repr

/-- The headless mode's command line, after `headless`. -/
def usage : String :=
  "headless [--render] [<sysroot> <olean dir>] <config dir> <script file>"

/-- Why two paths are refused outside a bundle, and what to give: the
`.olean` directory is a search path, and config is elaborated on the base of
the editor's package set, so the path must hold the core's modules and each
package's, unless the build recorded their directories beside the
executable. -/
def noToolchain : String :=
  "no Lean toolchain: give <sysroot> <olean dir> before the config directory, or run the executable from an app bundle; <olean dir> is a search path, directories joined with `:`, which must hold the core's and every package's of the editor's set unless the build recorded them beside the executable (<executable>.oleans)"

/-- What `arguments`, the command line after `headless`, asks for, for an
executable at `appPath` for which the build recorded the `.olean`
directories `recorded` (`ModuleLookup.recorded`, which the edge reads); or
why it is refused: the empty string when the usage alone says it, as for a
number of paths it does not take. -/
def read (appPath : String) (arguments : List String) (recorded : List String := []) :
    Except String Arguments :=
  let (render, paths) :=
    match arguments with
    | "--render" :: paths => (true, paths)
    | paths => (false, paths)
  let named : Option (ModuleLookup.Given × String × String) :=
    match paths with
    | [config, script] => some ({}, config, script)
    | [sysroot, oleans, config, script] =>
      some ({ sysroot := some sysroot, oleans := some oleans }, config, script)
    | _ => none
  match paths.head?.filter (·.startsWith "--"), named with
  | none, some (explicit, config, script) =>
    -- Four paths give both directories and two give neither, so both are
    -- known together: in a bundle, or given. Outside a bundle two paths
    -- name no toolchain, whatever the build recorded for the executable.
    let directories := ModuleLookup.resolve appPath explicit recorded
    match directories.sysroot, directories.oleans with
    | some sysroot, directory :: rest =>
      .ok { render, sysroot, oleans := directory :: rest, config, script }
    | _, _ => .error noToolchain
  | _, _ => .error ""

end Editor.Headless
