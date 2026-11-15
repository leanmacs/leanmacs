/-!
# The window mode's command line

`editor [--config <dir>] [--sysroot <dir>] [--oleans <dir>] [--no-ime] <file>`
opens `<file>` in a window (`Editor/Window/Real.lean`). This module is the
pure part of that: what the command line asks for, given what the edge read
of the world (`Environment`), and whether config is loaded at start
(`Options.configPlan`). It reads nothing itself, so `model-test` pins it
(`ModelTest.windowOptionChecks`).

- **The file** is resolved against the working directory: the file port
  takes absolute paths only. Exactly one file is taken.
- **`--sysroot`** is the Lean toolchain's directory. Lean cannot run
  `lean --print-prefix` (that would spawn a process), so with none given no
  config is loaded, and the echo area says so (`noToolchain`).
- **`--oleans`** is the directory of the editor's `.olean` files, and is
  `<directory of the executable>/../lib/lean` when not given, where Lake puts
  them in the build tree.
- **`--config`** is the config directory. When not given it is `leanmacs`
  under `$XDG_CONFIG_HOME`, or under `$HOME/.config` when that is unset or
  empty. A default directory that does not exist loads nothing and says
  nothing; a given one is reloaded whether it exists or not, so that a
  directory that does not exist is a rejected reload, said in the echo area.
- **`--no-ime`** runs the window with no input method composing.

No file, two files, an option it does not know, and an option with no value
are refused, with the usage (`usage`).
-/

namespace Editor.Window

/-- What the edge of the program read of the world for the command line:
the working directory, the two variables a config directory is found by,
and where the executable is (`IO.appPath`). -/
structure Environment where
  /-- The working directory, absolute. -/
  workingDirectory : String
  /-- `$XDG_CONFIG_HOME`, if it is set. -/
  xdgConfigHome : Option String
  /-- `$HOME`, if it is set. -/
  home : Option String
  /-- The executable's path. -/
  appPath : String
  deriving DecidableEq, Repr

/-- What the window mode's command line asks for. -/
structure Options where
  /-- The file to open, absolute. -/
  file : String
  /-- The config directory: given, or the default; none when there is no
  default, because neither variable it is found by is set. -/
  config : Option String
  /-- Whether the config directory was given with `--config`. -/
  configGiven : Bool
  /-- The Lean toolchain's directory, if one was given. -/
  sysroot : Option String
  /-- The directory of the editor's `.olean` files. -/
  oleans : String
  /-- Whether an input method may compose: `false` with `--no-ime`. -/
  composition : Bool
  deriving DecidableEq, Repr

/-- The window mode's command line, as the usage says it. -/
def usage : String :=
  "[--config <dir>] [--sysroot <dir>] [--oleans <dir>] [--no-ime] <file>"

/-- What the echo area says when no config is loaded because no toolchain
was given. -/
def noToolchain : String :=
  "config: not loaded: no Lean toolchain given (--sysroot)"

/-- The default config directory: `leanmacs` under `$XDG_CONFIG_HOME`, or
under `$HOME/.config` when that is unset or empty; none when neither is
set. -/
def defaultConfig (environment : Environment) : Option String :=
  match environment.xdgConfigHome.filter (!·.isEmpty), environment.home with
  | some xdg, _ => some (System.FilePath.mk xdg / "leanmacs").toString
  | none, some home => some (System.FilePath.mk home / ".config" / "leanmacs").toString
  | none, none => none

/-- `path` resolved against the working directory: kept when it is
absolute. -/
def resolve (environment : Environment) (path : String) : String :=
  let path := System.FilePath.mk path
  if path.isAbsolute then path.toString
  else (System.FilePath.mk environment.workingDirectory / path).toString

/-- The options read so far. -/
structure Read where
  /-- The file, as given. -/
  file : Option String := none
  /-- `--config`'s directory. -/
  config : Option String := none
  /-- `--sysroot`'s directory. -/
  sysroot : Option String := none
  /-- `--oleans`'s directory. -/
  oleans : Option String := none
  /-- `false` once `--no-ime` is read. -/
  composition : Bool := true

/-- Reads `arguments` into `read`, or says what is wrong. -/
def readAll (read : Read) : List String → Except String Read
  | [] => .ok read
  | "--config" :: directory :: rest => readAll { read with config := some directory } rest
  | "--sysroot" :: directory :: rest => readAll { read with sysroot := some directory } rest
  | "--oleans" :: directory :: rest => readAll { read with oleans := some directory } rest
  | "--no-ime" :: rest => readAll { read with composition := false } rest
  | argument :: rest =>
    if argument.startsWith "-" then
      if ["--config", "--sysroot", "--oleans"].contains argument then
        .error s!"{argument} needs a directory after it"
      else .error s!"{argument} is not an option"
    else
      match read.file with
      | some _ => .error "only one file is opened"
      | none => readAll { read with file := some argument } rest

/-- What `arguments`, the command line, asks for, given `environment`; or
why it is refused, followed by a line of the usage. -/
def parse (environment : Environment) (arguments : List String) : Except String Options :=
  let refused (reason : String) : Except String Options :=
    .error s!"{reason}\nusage: editor {usage}"
  match readAll {} arguments with
  | .error reason => refused reason
  | .ok read =>
    match read.file with
    | none => refused "no file to open"
    | some file =>
      let executable := (System.FilePath.mk environment.appPath).parent.getD "."
      .ok {
          file := resolve environment file
          config := read.config <|> defaultConfig environment
          configGiven := read.config.isSome
          sysroot := read.sysroot
          oleans := read.oleans.getD (executable / ".." / "lib" / "lean").toString
          composition := read.composition }

/-- Whether config is loaded at start, and what the echo area says if it
is not. -/
inductive ConfigPlan where
  /-- A reload of this directory is posted before the first event. -/
  | load (directory : String)
  /-- Nothing is loaded; the echo area says this, if anything. -/
  | skip (said : Option String)
  deriving DecidableEq, Repr

/-- Whether config is loaded at start, given whether the default config
directory exists (`defaultExists`, which the edge reads): never with no
toolchain, which is said; from a directory given with `--config`, whether
it exists or not; and from the default one only when it exists. -/
def Options.configPlan (options : Options) (defaultExists : Bool) : ConfigPlan :=
  match options.sysroot, options.config with
  | none, _ => .skip (some noToolchain)
  | some _, none => .skip none
  | some _, some directory =>
    if options.configGiven || defaultExists then .load directory else .skip none

end Editor.Window
