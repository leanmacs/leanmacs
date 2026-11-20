import Editor.ModuleLookup

/-!
# The headless mode's command line

`editor headless [--render] [--generate] [--state <dir>] [--resume <k>]
[<sysroot> <olean dir>] <config dir> <script file>` (`Editor/Headless.lean`). This module is the pure part of it: what the
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
- **`--generate`**, before the paths, lets the headless mode write into the
  config directory: it creates the lakefile and the toolchain file a
  directory lacks, as the window mode does
  (`Editor/Config/LakePackage.lean`). Without it the headless mode writes
  nothing there, which is what lets the gate run it on the config
  directories checked in under `tests/`.

- **`--state <dir>`**, before the paths, is the state directory
  (`Collaborators.stateDirectory`): a session is restored from it at start
  and journalled to it (`Editor/Restore.lean`). Without it there is none,
  and the headless mode keeps nothing across a run.
- **`--resume <k>`**, before the paths, resumes the script after a restart
  (`Editor/Restore/Restart.lean`): the script is skipped through its k-th
  `restarted` directive. A run hands the next its own command line with
  `--resume` one more than its own (`handedOn`), so the count does not
  depend on where the driver was when the restart began.

The options come in any order, each at most once. The two
directories are given both or neither, so three or five paths are refused,
and so is any other argument starting with `--` before the paths. Nothing
is read from the environment.
-/

namespace Editor.Headless

/-- What the headless mode's command line asks for. -/
structure Arguments where
  /-- Whether to draw (`--render`). -/
  render : Bool
  /-- Whether to create the config directory's lakefile and toolchain file
  when they are absent (`--generate`). -/
  generate : Bool
  /-- The Lean toolchain's directory. -/
  sysroot : String
  /-- The directories of the editor's `.olean` files, in the order they
  are searched; never empty. -/
  oleans : List String
  /-- The config directory. -/
  config : String
  /-- The script file. -/
  script : String
  /-- The state directory (`--state`), if one was given. -/
  state : Option String := none
  /-- How many `restarted` directives of the script this run has passed
  (`--resume`): 0 for a run that no restart started. -/
  resume : Nat := 0
  /-- The data directory (`--data`), if one was given: where a user's
  package-set build installs its editors (`docs/design/packages.md`,
  "User package sets"). The headless mode has none unless it is given, so
  no script can build into a user's own. -/
  data : Option String := none
  deriving DecidableEq, Repr

/-- The headless mode's command line, after `headless`. -/
def usage : String :=
  "headless [--render] [--generate] [--state <dir>] [--data <dir>] [--resume <k>] [<sysroot> <olean dir>] <config dir> <script file>"

/-- Why two paths are refused outside a bundle, and what to give: the
`.olean` directory is a search path, and config is elaborated on the base of
the editor's package set, so the path must hold the core's modules and each
package's, unless the build recorded their directories beside the
executable. -/
def noToolchain : String :=
  "no Lean toolchain: give <sysroot> <olean dir> before the config directory, or run the executable from an app bundle; <olean dir> is a search path, directories joined with `:`, which must hold the core's and every package's of the editor's set unless the build recorded them beside the executable (<executable>.oleans)"

/-- The options that take a value after them. -/
def valuedOptions : List String :=
  ["--state", "--data", "--resume"]

/-- The options before the paths of `arguments`, in order, after those in
`seen`; each valued option's last value, after those in `values`; the
paths; and whether every valued option had a value after it that is no
option. -/
def split :
    List String →
      List String →
      List (String × String) → List String × List (String × String) × List String × Bool
  | option :: rest, seen, values =>
    if valuedOptions.contains option then
      match rest with
      | value :: more =>
        if value.startsWith "--" then (seen ++ [option], values, more, false)
        else split more (seen ++ [option]) (values ++ [(option, value)])
      | [] => (seen ++ [option], values, [], false)
    else
      if option.startsWith "--" then split rest (seen ++ [option]) values
      else (seen, values, option :: rest, true)
  | [], seen, values => (seen, values, [], true)

/-- The command line after `headless` a run hands the next at a restart
(`Restart.Launch.arguments`): `arguments`, its own, with every `--resume`
dropped and `--resume <resume + 1>` first. -/
def handedOn (arguments : List String) (resume : Nat) : List String :=
  let rec drop : List String → List String
    | "--resume" :: _ :: rest => drop rest
    | argument :: rest => argument :: drop rest
    | [] => []
  ["--resume", toString (resume + 1)] ++ drop arguments

/-- What `arguments`, the command line after `headless`, asks for, for an
executable at `appPath` for which the build recorded the `.olean`
directories `recorded` (`ModuleLookup.recorded`, which the edge reads); or
why it is refused: the empty string when the usage alone says it, as for a
number of paths it does not take. -/
def read (appPath : String) (arguments : List String) (recorded : List String := []) :
    Except String Arguments :=
  let (options, values, paths, valued) := split arguments [] []
  let render := options.contains "--render"
  let generate := options.contains "--generate"
  let state := (values.find? (·.1 == "--state")).map (·.2)
  let resume := (values.find? (·.1 == "--resume")).map (·.2)
  let data := (values.find? (·.1 == "--data")).map (·.2)
  -- Each option at most once, and none the mode does not know; a resume a
  -- number.
  let known :=
    valued &&
      options.all (["--render", "--generate", "--state", "--data", "--resume"].contains ·) &&
      options.eraseDups == options &&
      resume.all (·.toNat?.isSome)
  let named : Option (ModuleLookup.Given × String × String) :=
    match paths with
    | [config, script] => some ({}, config, script)
    | [sysroot, oleans, config, script] =>
      some ({ sysroot := some sysroot, oleans := some oleans }, config, script)
    | _ => none
  match known, named with
  | true, some (explicit, config, script) =>
    -- Four paths give both directories and two give neither, so both are
    -- known together: in a bundle, or given. Outside a bundle two paths
    -- name no toolchain, whatever the build recorded for the executable.
    let directories := ModuleLookup.resolve appPath explicit recorded
    match directories.sysroot, directories.oleans with
    | some sysroot, directory :: rest =>
      .ok {
          render, generate, sysroot, oleans := directory :: rest, config, script, state, data
          resume := (resume.bind (·.toNat?)).getD 0 }
    | _, _ => .error noToolchain
  | _, _ => .error ""

end Editor.Headless
