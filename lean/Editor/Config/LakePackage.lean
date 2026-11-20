/-!
# The config directory as a Lake package

A config directory is a Lake package, so that Lean's language server,
started in it, checks a config file as the editor elaborates it: a
`lakefile.toml` that requires the editor's own core and its package set,
and a
`lean-toolchain` that pins the editor's Lean. The editor generates the two
files when they are absent. This module is the pure part of that: the text
of the lakefile for a set (`lakefile`), and what to do given what the
directory holds (`actions`). It reads and writes nothing, so `model-test`
pins it (`ModelTest.lakePackageChecks`). The session core performs the
actions through the host's ports (`Editor/Config/Session.lean`, "The
package ports").

- **Absent: create.** A directory with no lakefile, `lakefile.toml` or
  `lakefile.lean`, gets a `lakefile.toml`, and one with no `lean-toolchain`
  gets one holding the editor's pin.
- **Present: never rewritten.** A file that is there is the user's. A
  `lean-toolchain` that names another toolchain than the editor's pin is a
  warning that names both: the language server then checks config with a
  Lean the editor does not elaborate it with.
- **No set or core directory: no lakefile.** The lakefile requires the
  editor's core and its package set by their directories, and an editor
  that knows neither, or only one, writes none: Lake rejects a lakefile whose `require` names a path that
  does not exist, and the editor never rewrites a file. That is said as
  information, by every reload that finds the directory without a
  lakefile.

## The generated lakefile

```toml
name = "config"

[[require]]
name = "editor-core"
path = "<the running editor's core directory>"

[[require]]
name = "<the set's Lake name>"
path = "<the set's directory>"

[[lean_lib]]
name = "Config"
globs = ["Config.+"]
```

The core is required at the root, ahead of the set, by the directory of
the core the running editor links (`Editor/ModuleLookup.lean`, "The
core"): Lake's root require wins over any a package makes, so a package
that names the core from git builds against this editor's core, and
nothing is cloned (`docs/design/packages.md`, "A config directory requires
the core and the set").

The library is every module under `Config/`: the config files other than
the root. The root, `init.lean`, is in no library, so Lake never builds
it: on a file system that ignores case, a built `init.olean` is found for
Lean's own `Init`. The language server still checks it, as a file of the
package that no library holds.
-/

namespace Editor.Config.LakePackage

/-- The name of the lakefile the editor generates. -/
def lakefileName : String :=
  "lakefile.toml"

/-- The name of a lakefile written in Lean: a directory that holds one has
a lakefile, and the editor generates none. -/
def leanLakefileName : String :=
  "lakefile.lean"

/-- The name of the file that pins the Lean toolchain. -/
def toolchainName : String :=
  "lean-toolchain"

/-- The package set an editor was built from, and the core it links, as
its config's lakefile names them. -/
structure Set where
  /-- The set's Lake package name. -/
  name : String
  /-- The set's directory: an absolute path. -/
  directory : String
  /-- The directory of the core the editor links: an absolute path
  (`ModuleLookup.coreDirectory?`). -/
  core : String
  deriving DecidableEq, Repr

/-- What the build says of the editor it links, for the generated files: the
Lake name of the package set it is built from, and the toolchain pin. The
root the package-set build generates hands it to the executable's entry
(`Editor/Main.lean`); where the set is on this machine is not in it, since
an editor may be copied (`Editor/ModuleLookup.lean`, "The set"). -/
structure Origin where
  /-- The Lake name of the package set. -/
  setName : String
  /-- The text of the core's `lean-toolchain`. -/
  pin : String
  deriving DecidableEq, Repr

/-- The package set of an editor of `origin` whose set directory is
`directory` and whose core directory is `core`, when it knows both. -/
def Origin.set (origin : Origin) (directory core : Option String) : Option Set := do
  return { name := origin.setName, directory := ← directory, core := ← core }

/-- `text` as a TOML basic string: in double quotes, with a backslash before
each backslash and each double quote. -/
def quoted (text : String) : String :=
  let escaped :=
    text.foldl
      (fun escaped character =>
        if character == '\\' || character == '"' then (escaped.push '\\').push character
        else escaped.push character)
      ""
  s!"\"{escaped}\""

/-- The text of the lakefile generated for a config directory of an editor
built from `set` ("The generated lakefile", in the module docs). -/
def lakefile (set : Set) : String :=
  s!"name = \"config\"\n\n[[require]]\nname = \"editor-core\"\npath = {quoted set.core}\n\n[[require]]\nname = {quoted set.name}\npath = {quoted set.directory}\n\n[[lean_lib]]\nname = \"Config\"\nglobs = [\"Config.+\"]\n"

/-- What a config directory holds of the two files. -/
structure Holds where
  /-- Whether it holds a lakefile, `lakefile.toml` or `lakefile.lean`. -/
  lakefile : Bool
  /-- The text of its `lean-toolchain`, or none when it holds none. -/
  toolchain : Option String
  deriving DecidableEq, Repr

/-- One thing to do about a config directory's two files. -/
inductive Action where
  /-- Create the file called `name` holding `text`. -/
  | create (name text : String)
  /-- Say `message` as a warning. -/
  | warn (message : String)
  /-- Say `message` as information. -/
  | inform (message : String)
  deriving DecidableEq, Repr

/-- The toolchain a `lean-toolchain` file's text names: the text without
the white space around it. -/
def named (text : String) : String :=
  text.trimAscii.toString

/-- What to do about the two files of a config directory that holds
`holds`, for an editor whose pin is the text `pin` and which was built from
`set`, or knows no set directory: the lakefile first, then the toolchain
file (the module docs give the rules). -/
def actions (pin : String) (set : Option Set) (holds : Holds) : Array Action :=
  let lakefileActions : Array Action :=
    if holds.lakefile then #[]
    else
      match set with
      | some set => #[.create lakefileName (lakefile set)]
      | none =>
        #[.inform
            s!"no {lakefileName} is generated: this editor knows no directory of its core or of the package set it was built from, which the lakefile would require"]
  let toolchainActions : Array Action :=
    match holds.toolchain with
    | none => #[.create toolchainName pin]
    | some text =>
      if named text == named pin then #[]
      else
        #[.warn
            s!"{toolchainName} names {named text}, and this editor elaborates config with {named pin}: Lean's language server may not check config as the editor does"]
  lakefileActions ++ toolchainActions

end Editor.Config.LakePackage
