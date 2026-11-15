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
  executable is.
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
  /-- The directory of the editor's `.olean` files. -/
  oleans : String
  /-- The config directory. -/
  config : String
  /-- The script file. -/
  script : String
  deriving DecidableEq, Repr

/-- The headless mode's command line, after `headless`. -/
def usage : String :=
  "headless [--render] [<sysroot> <olean dir>] <config dir> <script file>"

/-- Why two paths are refused outside a bundle. -/
def noToolchain : String :=
  "no Lean toolchain: give <sysroot> <olean dir> before the config directory, or run the executable from an app bundle"

/-- What `arguments`, the command line after `headless`, asks for, for an
executable at `appPath`; or why it is refused: the empty string when the
usage alone says it, as for a number of paths it does not take. -/
def read (appPath : String) (arguments : List String) : Except String Arguments :=
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
    let directories := ModuleLookup.resolve appPath explicit
    match directories.sysroot with
    | some sysroot => .ok { render, sysroot, oleans := directories.oleans, config, script }
    | none => .error noToolchain
  | _, _ => .error ""

end Editor.Headless
