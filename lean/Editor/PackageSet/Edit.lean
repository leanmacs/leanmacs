import Editor.Config.LakePackage
import Editor.PackageSet.Fingerprint

/-!
# Edits of a config's `lakefile.toml`

The text edits behind `:package-install`, `:package-remove` and
`:package-update <name> <rev>` (`Editor/PackageSet/Commands.lean`;
`docs/design/packages.md`, "User package sets"). Each takes the
lakefile's text and its `[[require]]` tables as the last reload read them
with Lake's loader (`PackageSet.Facts`), and answers the new text or why
the edit is refused. Pure: `model-test` pins the exact texts
(`ModelTest.packageSetEditChecks`), and `config-test` reads each edited
text back with Lake's loader (`ConfigTest.packageSetEditChecks`).

## Where a table is

A table is found by its header line, `[[require]]`, the n-th header
holding the n-th require Lake read (`tables`). It runs to the last line
before the next header that is neither blank nor a comment: a comment
just before the next header is that table's. A lakefile whose requires are
not each a `[[require]]` table (an inline array) is refused: "edit it by
hand".

## The edits

- **Install** (`install`) adds a table after the last require, or at the
  end with none: `name` and then `path`; `git` with an optional `rev`; or
  `scope` with an optional `version` for Reservoir. A name already
  required is refused.
- **Remove** (`remove`) takes a require's table out, with one blank line
  after it. `editor-core` is refused ("the core cannot be removed"). A name
  the lakefile does not require is refused, unless the lakefile requires
  the shipped set by path and the name is one of that set's own requires:
  then the set's table is **expanded**, replaced by a table for each of the
  set's requires but that one, a path made absolute against the set's
  directory (`docs/design/packages.md`, "A config directory requires the
  set").
- **Set a rev** (`setRev`) writes `rev = "<rev>"` into a git require's
  table, in place of the one there or after its `git` line. A require that
  is not a git dependency is refused.
-/

namespace Editor.PackageSet

/-- The name of the core's Lake package, which no set can drop. -/
def coreName : String :=
  "editor-core"

/-- `text`'s lines, split at each line feed: a text ending in one has an
empty last line. -/
def linesOf (text : String) : Array String :=
  (text.splitOn "\n").toArray

/-- Whether `line` is a table header: it starts with `[` after its
indentation. -/
def isHeader (line : String) : Bool :=
  line.trimAscii.toString.startsWith "["

/-- Whether `line` is blank or a comment. -/
def isFiller (line : String) : Bool :=
  let trimmed := line.trimAscii.toString
  trimmed.isEmpty || trimmed.startsWith "#"

/-- The line range of each `[[require]]` table of `lines`, in order: its
header's index and the index after its last line ("Where a table is", in
the module docs). -/
def tables (lines : Array String) : Array (Nat × Nat) :=
  Id.run do
    let mut found := #[]
    for index in [0:lines.size] do
      if lines[index]!.trimAscii.toString == "[[require]]" then
        let mut stop := index + 1
        let mut next := index + 1
        while next < lines.size && !isHeader lines[next]! do
          if !isFiller lines[next]! then
            stop := next + 1
          next := next + 1
        found := found.push (index, stop)
    return found

/-- The lines of the table of `require`, with its path written as it is. -/
def Require.table (require : Require) : Array String :=
  let quoted := Config.LakePackage.quoted
  let field (key : String) (value : Option String) : Array String :=
    (value.map fun value => s!"{key} = {quoted value}").toArray
  #["[[require]]", s!"name = {quoted require.name}"] ++
    match require.source with
    | .path directory => #[s!"path = {quoted directory}"]
    | .git url rev subDir => #[s!"git = {quoted url}"] ++ field "rev" rev ++ field "subDir" subDir
    | .reservoir scope version =>
      field "scope" (if scope.isEmpty then none else some scope) ++ field "version" version

/-- The tables of `required` in `text`, paired with them, or why the
lakefile cannot be edited: its headers do not match the requires Lake
read. -/
def located (text : String) (required : Array Require) :
    Except String (Array String × Array (Require × Nat × Nat)) := do
  let lines := linesOf text
  let ranges := tables lines
  unless ranges.size == required.size do
    throw "its requires are not each a [[require]] table, so edit it by hand"
  return (lines, required.zip ranges)

/-- `lines` joined with line feeds. -/
def joined (lines : Array String) : String :=
  "\n".intercalate lines.toList

/-- The text with `require` added ("The edits", in the module docs). -/
def install (text : String) (required : Array Require) (require : Require) : Except String String :=
  do
  if required.any (·.name == require.name) then
    throw s!"the lakefile already requires {require.name}"
  let (lines, tabled) ← located text required
  match tabled.back? with
  | some (_, _, stop) =>
    return joined (lines.extract 0 stop ++ #[""] ++ require.table ++ lines.extract stop lines.size)
  | none =>
    let body := if text.isEmpty || text.endsWith "\n" then text else text ++ "\n"
    return body ++ "\n" ++ joined require.table ++ "\n"

/-- `lines` with the range `start` to `stop` replaced by `inserted`, and the
blank line after the range dropped when nothing is inserted. -/
def replaced (lines : Array String) (start stop : Nat) (inserted : Array String) : Array String :=
  let after :=
    if
        inserted.isEmpty && stop < lines.size && lines[stop]!.trimAscii.isEmpty &&
          stop + 1 < lines.size then
      stop + 1
    else stop
  lines.extract 0 start ++ inserted ++ lines.extract after lines.size

/-- The shipped set's `require` of `required`, when it is one by path: its
name is `set`. -/
def setRequire? (required : Array Require) (set : Option String) : Option (Require × String) := do
  let name ← set
  let require ← required.find? (·.name == name)
  let .path directory := require.source | none
  pure (require, directory)

/-- The text with the require `name` taken out, or the shipped set expanded
without it ("The edits", in the module docs). `config` is the config
directory, `set` the shipped set's name and `setRequired` that set's own
requires, as the reload read them. -/
def remove (text : String) (required : Array Require) (name : String) (config : String)
    (set : Option String) (setRequired : Array Require) : Except String String := do
  if name == coreName then
    throw "the core cannot be removed"
  let (lines, tabled) ← located text required
  if let some (_, start, stop) := tabled.find? (·.1.name == name) then
    return joined (replaced lines start stop #[])
  match setRequire? required set with
  | some (setRequire, directory) =>
    unless setRequired.any (·.name == name) do
      throw s!"the lakefile does not require {name}, and neither does {setRequire.name}"
    let setDirectory := normalise config directory
    let kept :=
      (setRequired.filter (·.name != name)).map fun (require : Require) =>
        match require.source with
        | .path path => { require with source := .path (normalise setDirectory path) }
        | _ => require
    let some (_, start, stop) := tabled.find? (·.1.name == setRequire.name)
      | throw s!"the lakefile does not require {name}"
    let tables :=
      kept.foldl
        (fun (out : Array String) require =>
          (if out.isEmpty then out else out.push "") ++ require.table)
        #[]
    return joined (replaced lines start stop tables)
  | none =>
    throw s!"the lakefile does not require {name}"

/-- The text with the git require `name`'s `rev` set to `rev` ("The edits",
in the module docs). -/
def setRev (text : String) (required : Array Require) (name rev : String) : Except String String :=
  do
  let (lines, tabled) ← located text required
  let some (require, start, stop) := tabled.find? (·.1.name == name)
    | throw s!"the lakefile does not require {name}"
  let .git .. := require.source | throw s!"{name} is not a git dependency, so it has no rev"
  let line := s!"rev = {Config.LakePackage.quoted rev}"
  let keyed (key : String) (index : Nat) : Bool :=
    let trimmed := lines[index]!.trimAscii.toString
    trimmed.startsWith key && (trimmed.drop key.length).trimAscii.startsWith "="
  match (List.range (stop - start)).map (· + start) |>.find? (keyed "rev") with
  | some index =>
    return joined (lines.set! index line)
  | none =>
    let at_ := ((List.range (stop - start)).map (· + start) |>.find? (keyed "git")).map (· + 1)
    let index := at_.getD stop
    return joined (lines.extract 0 index ++ #[line] ++ lines.extract index lines.size)

end Editor.PackageSet
