import Editor.Json

/-!
# A package set's fingerprint

What a user's package set is, as far as deciding whether the running
editor was linked from it goes (`docs/design/packages.md`, "User package
sets"): the config's lakefile's `[[require]]` tables and the git pins of
its `lake-manifest.json`. A reload reads the facts (`Facts`) and compares
the config's fingerprint with the running executable's (`same`); when they
differ the package-set build starts (`Editor/PackageSet/Build.lean`). Pure:
`model-test` pins it (`ModelTest.packageSetFingerprintChecks`), and the
one read, the lakefile's required, is the TOML adapter's
(`Editor/Config/Lakefile/Toml.lean`, `requireEntries`).

## The parts

- **Requires**, in the lakefile's order, each one line (`Require.line`),
  but the root's own-core require (`Require.ownCore`): `editor-core` by a
  path naming the running editor's own core directory. Every lakefile the
  editor writes has it, and the one an older editor generated has not;
  both are the same set, the shipped default's. A root `editor-core`
  naming another directory, or any other source, is kept, so that set
  differs, and its build's core check refuses it
  (`Editor/PackageSet/Build.lean`).
  `path <name> <directory>`, the directory made absolute against the
  config directory and normalised lexically (`normalise`); `git <name>
  <url> <rev or -> <subDir or ->`; or `reservoir <name> <scope> <version
  or ->`.
- **Pins**: each git entry of the manifest, `pin <name> <url> <rev>`
  (`pins`). Path entries are left out: the lakefile decides them, and
  Lean's language server writes them into a manifest the user never
  touched, so its writing one is no change. A stale entry for a package no
  longer required stays on both sides, so it never starts a build.
- **The shipped set's name**, `set <name>`, carried for the edit that
  drops a default package (`Editor/PackageSet/Edit.lean`). It is not
  compared.

A **`lakefile.lean`** is not read: it is a program. Its one require line
is `lakefile.lean <hash of its text>`, so any edit of it starts a build.

## The running executable's

- **A per-user install** has the record `editor.packages` beside it
  (`text`, `parse?`), written by the build that made it from the
  fingerprint it started from, the pins read again after the resolve.
- **An executable built from a set directory**, the shipped default,
  has the fingerprint of the lakefile it would generate (`shipped`): one
  `path <set name> <set directory>` require, the own-core one left out, and
  no pin. So a generated lakefile matches it and starts no build.

## Where an addition goes

A new kind of require is a `Source` constructor with its line. A new part
of the fingerprint is a field of `Fingerprint`, a line kind of the record
(raising `recordVersion`), and a clause of `same`.
-/

namespace Editor.PackageSet

/-- Where a required package comes from, as the lakefile says. -/
inductive Source where
  /-- A directory: `path = "<dir>"`, relative to the config directory or
  absolute. -/
  | path (directory : String)
  /-- A git repository: `git = "<url>"`, with an optional `rev` and
  `subDir`. -/
  | git (url : String) (rev : Option String) (subDir : Option String)
  /-- Reservoir: a `scope` and an optional `version`. -/
  | reservoir (scope : String) (version : Option String)
  deriving DecidableEq, Repr, BEq, Inhabited

/-- A `[[require]]` table of a lakefile. -/
structure Require where
  /-- The package's name. -/
  name : String
  /-- Where it comes from. -/
  source : Source
  deriving DecidableEq, Repr, BEq, Inhabited

/-- Whether `source` is fetched with git: a git or a Reservoir
dependency. -/
def Source.fetched : Source → Bool
  | .path _ => false
  | .git .. => true
  | .reservoir .. => true

/-- `path` made absolute against `base`, an absolute directory, and
normalised lexically: empty and `.` components dropped, a `..` taking the
component before it away (none above the root). -/
def normalise (base : String) (path : String) : String :=
  let whole := if path.startsWith "/" then path else base ++ "/" ++ path
  let parts :=
    (whole.splitOn "/").foldl
      (fun (kept : Array String) part =>
        if part.isEmpty || part == "." then kept
        else if part == ".." then kept.pop else kept.push part)
      #[]
  "/" ++ "/".intercalate parts.toList

/-- Whether `directory`, a path a lakefile or manifest of the config
directory `config` writes, names the running editor's core directory
`core`: a relative one resolved against `config`, and both normalised
lexically (`normalise`). The one test of "is this the running core" that
the fingerprint (`Require.ownCore`), the edits (`isCoreAt`,
`Editor/PackageSet/Edit.lean`) and the build's core check
(`coreRefusal?`, `Editor/PackageSet/Build.lean`) each make. -/
def namesCore (config core directory : String) : Bool :=
  normalise config directory == normalise "/" core

/-- The value `value`, or `-` for none. -/
def orDash (value : Option String) : String :=
  value.getD "-"

/-- The require's line in a fingerprint ("The parts", in the module docs),
its path made absolute against the config directory `config`. -/
def Require.line (config : String) (require : Require) : String :=
  match require.source with
  | .path directory => s!"path {require.name} {normalise config directory}"
  | .git url rev subDir => s!"git {require.name} {url} {orDash rev} {orDash subDir}"
  | .reservoir scope version => s!"reservoir {require.name} {scope} {orDash version}"

/-- A Lake name as the manifest writes it, with Lean's `«»` quotes taken
off: `«default-set»` is `default-set`. -/
def unquoted (name : String) : String :=
  if name.startsWith "«" && name.endsWith "»" then ((name.drop 1).dropEnd 1).toString else name

/-- A git entry of a manifest. -/
structure Pin where
  /-- The package's name, unquoted. -/
  name : String
  /-- The repository it was cloned from. -/
  url : String
  /-- The commit it is pinned at. -/
  rev : String
  /-- The revision the lakefile asked for when it was pinned, if any. -/
  inputRev : Option String
  deriving DecidableEq, Repr, BEq

/-- The git entries of the manifest whose text is `manifest`, in its order;
none for a text that is not a manifest. -/
def gitEntries (manifest : String) : Array Pin :=
  match Json.parse manifest.toUTF8 with
  | .error _ => #[]
  | .ok document =>
    match document.field? "packages" with
    | some (.array entries) =>
      entries.filterMap fun entry => do
        let .string "git" ← entry.field? "type" | none
        let .string name ← entry.field? "name" | none
        let .string url ← entry.field? "url" | none
        let .string rev ← entry.field? "rev" | none
        let inputRev :=
          match entry.field? "inputRev" with
          | some (.string text) => some text
          | _ => none
        some { name := unquoted name, url, rev, inputRev }
    | _ => #[]

/-- What a manifest resolves `editor-core` to. -/
inductive CoreEntry where
  /-- A directory: a `path` entry, inherited or the root's, its `dir` as
  the manifest writes it. -/
  | path (directory : String)
  /-- A git repository, cloned at `rev`, with its `subDir`, if any. -/
  | git (url : String) (rev : String) (subDir : Option String)
  deriving DecidableEq, Repr, BEq

/-- The entry of `editor-core` in the manifest whose text is `manifest`
(its name unquoted); none when it holds none, or is no manifest, or the
entry is of another kind. -/
def Fingerprint.coreEntry? (manifest : String) : Option CoreEntry := do
  let .ok document := Json.parse manifest.toUTF8 | none
  let some (.array entries) := document.field? "packages" | none
  let entry ←
    entries.find? fun entry =>
        match entry.field? "name" with
        | some (.string name) => unquoted name == "editor-core"
        | _ => false
  let string? (key : String) : Option String :=
    match entry.field? key with
    | some (.string text) => some text
    | _ => none
  match string? "type" with
  | some "path" =>
    return .path (← string? "dir")
  | some "git" =>
    return .git (← string? "url") (← string? "rev") (string? "subDir")
  | _ =>
    none

/-- The pins of a manifest's text: `pin <name> <url> <rev>` for each git
entry, in its order ("The parts", in the module docs). -/
def pins (manifest : Option String) : Array String :=
  ((manifest.map gitEntries).getD #[]).map fun pin => s!"pin {pin.name} {pin.url} {pin.rev}"

/-- What a config's lakefile is, as a reload read it. -/
inductive Lakefile where
  /-- There is none. -/
  | absent
  /-- A `lakefile.toml`: its text and its requires, in order. -/
  | toml (text : String) (required : Array Require)
  /-- A `lakefile.lean`: its text, which is not read. -/
  | lean (text : String)
  /-- A lakefile that could not be read, and why. -/
  | unreadable (why : String)
  deriving DecidableEq, Repr, BEq, Inhabited

/-- What a reload read of the config directory as a package set. -/
structure Facts where
  /-- The lakefile. -/
  lakefile : Lakefile := .absent
  /-- The text of `lake-manifest.json`, if there is one. -/
  manifest : Option String := none
  /-- The requires of the shipped set's own `lakefile.toml`, when the
  lakefile required that set by path: what dropping one of its packages
  expands it to (`Editor/PackageSet/Edit.lean`). -/
  setRequires : Array Require := #[]
  deriving DecidableEq, Repr, BEq, Inhabited

/-- A package set's fingerprint ("The parts", in the module docs). -/
structure Fingerprint where
  /-- The requires' lines, in order. -/
  required : Array String := #[]
  /-- The pins' lines, in the manifest's order. -/
  pins : Array String := #[]
  /-- The shipped set's name, if it is known. -/
  set : Option String := none
  deriving DecidableEq, Repr, BEq, Inhabited

/-- Whether two fingerprints are of one set: the same requires and the same
pins. The set's name is not compared. -/
def same (one other : Fingerprint) : Bool :=
  one.required == other.required && one.pins == other.pins

/-- The hash of `text`, in hex: what a `lakefile.lean` is known by. -/
def textHash (text : String) : String :=
  String.ofList (Nat.toDigits 16 (hash text).toNat)

/-- Whether `require` is the root's own-core require for the running
editor whose core directory is `core`: `editor-core` by a path that names
that directory, however it is spelled (`namesCore`; "The parts", in the
module docs). -/
def Require.ownCore (config : String) (core : Option String) (require : Require) : Bool :=
  match require.name, require.source, core with
  | "editor-core", .path directory, some core => namesCore config core directory
  | _, _, _ => false

/-- The fingerprint of the config in the directory `config` whose facts are
`facts`, carrying `set`, the shipped set's name, for the running editor
whose core directory is `core`; none when it has no lakefile, or one that
cannot be read, which never starts a build. -/
def Fingerprint.ofFacts (config : String) (facts : Facts) (set : Option String)
    (core : Option String) : Option Fingerprint :=
  match facts.lakefile with
  | .toml _ required =>
    some
      { required := (required.filter (!·.ownCore config core)).map (·.line config)
        pins := PackageSet.pins facts.manifest, set }
  | .lean text =>
    some
      { required := #[s!"lakefile.lean {textHash text}"], pins := PackageSet.pins facts.manifest,
        set }
  | .absent => none
  | .unreadable _ => none

/-- The fingerprint of an executable built from the set `name` in the
directory `directory`: the generated lakefile's ("The running
executable's", in the module docs). -/
def shipped (name directory : String) : Fingerprint :=
  { required := #[s!"path {name} {normalise "/" directory}"], set := some name }

/-- The first line of the record `editor.packages`: its format and
version. -/
def recordVersion : String :=
  "leanmacs-packages 1"

/-- The record `editor.packages` of `fingerprint`: the version line, then
`require <line>` for each require, `pin <line>` for each pin, and `set
<name>`, each a line. -/
def Fingerprint.text (fingerprint : Fingerprint) : String :=
  let lines :=
    #[recordVersion] ++ fingerprint.required.map ("require " ++ ·) ++ fingerprint.pins ++
      (fingerprint.set.map ("set " ++ ·)).toArray
  String.join (lines.toList.map (· ++ "\n"))

/-- The fingerprint the record `text` holds (`Fingerprint.text`); none for
a text of another format or version, or a line of no kind it knows. -/
def Fingerprint.parse? (text : String) : Option Fingerprint := do
  let lines := (text.splitOn "\n").filter (!·.isEmpty)
  let first :: rest := lines | none
  guard (first == recordVersion)
  rest.foldlM
      (fun (fingerprint : Fingerprint) line =>
        if line.startsWith "require " then
          some { fingerprint with required := fingerprint.required.push (line.drop 8).toString }
        else
          if line.startsWith "pin " then
            some { fingerprint with pins := fingerprint.pins.push line }
          else
            if line.startsWith "set " then
              some { fingerprint with set := some (line.drop 4).toString }
            else none)
      {}

end Editor.PackageSet
