import Editor.Restore.Journal
import Editor.Restore.Records
import Editor.Restore.Value

/-!
# The workspace table as the session index records it

The workspaces, the projects and the unscoped store of the editor state's
table (`Workspace.Table`, `Editor/Workspace.lean`) as the session index
writes them (`Document.Workspaces`, `Editor/Restore/Records.lean`), and the
table a restore makes of them. Pure.

## What is recorded

- **Every workspace** by its location, with its branch and its project's
  identity; **every project** by its identity, with its name, its remote
  and its common git directory; and **the cells kept across a restart** of
  each store, the workspace's, the project's and the unscoped one. The
  directory cache is not recorded: the next run asks again.
- **A cell is recorded only when its store has a codec**
  (`Editor/Store/Codec.lean`, "Kept across a restart"), through the codec's
  `keep`, at the codec's version and with its owner's name: a store with no
  codec is never written. A tree the codec does not accept is not written
  either.

## What a restore makes of it (`restore`)

The table with every workspace and project of the record, and each cell:

- **with a codec now** (a package's, registered before the restore), met by
  the install rule (`StoreDeclaration.meet`): kept at its version,
  migrated, or reset to the initial tree with a report line;
- **with none** (config's, which registers after the restore), handed back
  parked, with its scope, for the reconciler to meet once config has
  installed (`Editor/Restore.lean`).

## The JSON

```
{"workspaces":[{"location":<Location.encode as JSON>,"branch":{"named":b}|"detached",
                "project":<identity>,"cells":[<cell>…]}],
 "projects":[{"identity":<identity>,"name":n,"remote":u,"commonDir":d,"cells":[<cell>…]}],
 "unscoped":[<cell>…]}
<identity> = {"remote":n} | {"commonDir":p} | {"root":p} | {"declared":n}
<cell>     = {"owner":o,"name":n,"version":v,"value":<value>}
```

`branch`, `remote` and `commonDir` are absent when there is none; a value
is a plain tree's JSON (`Editor/Restore/Value.lean`).

Pinned by `ModelTest.restoreWorkspaceChecks`.
-/

namespace Editor.Restore

open Journal (natJson natField? stringField?)

/-! ## The JSON -/

/-- A project's identity as JSON. -/
def identityJson : Project.Identity → Json.Value
  | .remote normalised => .object #[("remote", .string normalised)]
  | .commonDir path => .object #[("commonDir", .string path.toString)]
  | .root path => .object #[("root", .string path.toString)]
  | .declared name => .object #[("declared", .string name)]

/-- A project's identity from JSON, or none. -/
def identityOf? : Json.Value → Option Project.Identity
  | .object #[("remote", .string normalised)] => some (.remote normalised)
  | .object #[("commonDir", .string path)] => some (.commonDir path)
  | .object #[("root", .string path)] => some (.root path)
  | .object #[("declared", .string name)] => some (.declared name)
  | _ => none

/-- A branch as JSON. -/
def branchJson : Workspace.Branch → Json.Value
  | .named name => .object #[("named", .string name)]
  | .detached => .string "detached"

/-- A branch from JSON, or none. -/
def branchOf? : Json.Value → Option Workspace.Branch
  | .object #[("named", .string name)] => some (.named name)
  | .string "detached" => some .detached
  | _ => none

/-- A location as JSON: its plain tree (`Location.encode`) as JSON. -/
def locationJson (location : Location) : Json.Value :=
  location.encode.toJson

/-- A location from JSON, or none. -/
def locationOf? (value : Json.Value) : Option Location :=
  (Value.ofJson? value).bind Location.decode?

/-- A kept cell as JSON. -/
def _root_.Editor.KeptCell.toJson (cell : KeptCell) : Json.Value :=
  .object
    #[("owner", .string cell.owner), ("name", .string cell.name), ("version", natJson cell.version),
      ("value", cell.value.toJson)]

/-- A kept cell from JSON, or none. -/
def _root_.Editor.KeptCell.ofJson? (value : Json.Value) : Option KeptCell := do
  return {
      owner := ← stringField? value "owner", name := ← stringField? value "name"
      version := ← natField? value "version", value := ← Value.ofJson? (← value.field? "value") }

/-- The cells of an array member of `value`, or none; none in place of no
member. -/
def cellsField? (value : Json.Value) (name : String) : Option (Array KeptCell) :=
  match value.field? name with
  | none => some #[]
  | some (.array items) => items.mapM KeptCell.ofJson?
  | some _ => none

/-- A workspace's record as JSON. -/
def Workspace.Record.toJson (record : Workspace.Record) : Json.Value :=
  .object <|
    #[("location", locationJson record.location)] ++
      (record.branch.map fun branch => #[("branch", branchJson branch)]).getD #[] ++
      #[("project", identityJson record.project), ("cells", .array (record.cells.map (·.toJson)))]

/-- A workspace's record from JSON, or none. -/
def Workspace.Record.ofJson? (value : Json.Value) : Option Workspace.Record := do
  let branch ←
    match value.field? "branch" with
    | none =>
      some none
    | some branch =>
      (branchOf? branch).map some
  return {
      location := ← locationOf? (← value.field? "location"), branch
      project := ← identityOf? (← value.field? "project"), cells := ← cellsField? value "cells" }

/-- A project's record as JSON. -/
def Project.Record.toJson (record : Project.Record) : Json.Value :=
  .object <|
    #[("identity", identityJson record.identity), ("name", .string record.name)] ++
      (record.remote.map fun remote => #[("remote", Json.Value.string remote)]).getD #[] ++
      (record.commonDir.map fun path => #[("commonDir", Json.Value.string path.toString)]).getD
        #[] ++
      #[("cells", .array (record.cells.map (·.toJson)))]

/-- A project's record from JSON, or none. -/
def Project.Record.ofJson? (value : Json.Value) : Option Project.Record := do
  let optional (name : String) : Option (Option String) :=
    match value.field? name with
    | none => some none
    | some (.string text) => some (some text)
    | some _ => none
  return {
      identity := ← identityOf? (← value.field? "identity"), name := ← stringField? value "name"
      remote := ← optional "remote", commonDir := (← optional "commonDir").map System.FilePath.mk
      cells := ← cellsField? value "cells" }

/-- The table's record as JSON ("The JSON", in the module docs). -/
def Document.Workspaces.toJson (record : Document.Workspaces) : Json.Value :=
  .object
    #[("workspaces", .array (record.workspaces.map (·.toJson))),
      ("projects", .array (record.projects.map (·.toJson))),
      ("unscoped", .array (record.unscoped.map (·.toJson)))]

/-- The table's record from JSON, or none. -/
def Document.Workspaces.ofJson? (value : Json.Value) : Option Document.Workspaces := do
  let items (name : String) : Option (Array Json.Value) :=
    match value.field? name with
    | none => some #[]
    | some (.array items) => some items
    | some _ => none
  return {
      workspaces := ← (← items "workspaces").mapM Workspace.Record.ofJson?
      projects := ← (← items "projects").mapM Project.Record.ofJson?
      unscoped := ← cellsField? value "unscoped" }

/-! ## Recording and restoring -/

/-- The cells of `cells` whose store has a codec (`codec?`), each through
the codec's `keep`, at its version and with its owner's name ("What is
recorded", in the module docs). -/
def keptCells (codec? : String → Option (String × StoreCodec)) (cells : Array (String × Value)) :
    Array KeptCell :=
  cells.filterMap fun (name, value) => do
    let (owner, codec) ← codec? name
    let kept ← codec.keep value
    return { owner, name, version := codec.declaration.version, value := kept }

/-- The record of `table` ("What is recorded", in the module docs). -/
def Workspaces.record (table : Workspace.Table) (codec? : String → Option (String × StoreCodec)) :
    Document.Workspaces :=
  { workspaces :=
      table.workspaces.map fun (workspace, cells) =>
        { location := workspace.location, branch := workspace.branch
          project := workspace.project.identity, cells := keptCells codec? cells }
    projects :=
      table.projects.map fun (project, cells) =>
        { identity := project.identity, name := project.name, remote := project.remote
          commonDir := project.commonDir, cells := keptCells codec? cells }
    unscoped := keptCells codec? table.unscoped }

/-- The record with `parked`, cells parked with their scopes, put back in
their stores, each after the store's recorded cells, a scope the record
does not hold dropped with them: what an index written while cells are
parked carries. -/
def Document.Workspaces.withParked (record : Document.Workspaces)
    (parked : Array (Document.Scope × KeptCell)) : Document.Workspaces :=
  let of (scope : Document.Scope) : Array KeptCell := (parked.filter (·.1 == scope)).map (·.2)
  { workspaces :=
      record.workspaces.map fun workspace =>
        { workspace with cells := workspace.cells ++ of (.workspace workspace.location) }
    projects :=
      record.projects.map fun project =>
        { project with cells := project.cells ++ of (.project project.identity) }
    unscoped := record.unscoped ++ of .unscoped }

/-- What a restore makes of `record` ("What a restore makes of it", in the
module docs): the table, the cells parked with their scopes, and the report
lines. -/
def Workspaces.restore (record : Document.Workspaces)
    (codec? : String → Option (String × StoreCodec)) :
    Workspace.Table × Array (Document.Scope × KeptCell) × Array String :=
  Id.run do
    let mut parked : Array (Document.Scope × KeptCell) := #[]
    let mut report : Array String := #[]
    let mut stores : Array (Document.Scope × Array (String × Value)) := #[]
    let scopes : Array (Document.Scope × Array KeptCell) :=
      record.workspaces.map (fun workspace => (.workspace workspace.location, workspace.cells)) ++
        record.projects.map (fun project => (.project project.identity, project.cells)) ++
        #[(.unscoped, record.unscoped)]
    for (scope, cells) in scopes do
      let mut met : Array (String × Value) := #[]
      for cell in cells do
        match codec? cell.name with
        | some (_, codec) =>
          let meeting := codec.declaration.meet (some (cell.version, cell.value))
          met := met.push (cell.name, meeting.value)
          if let some why := meeting.lost then
            report := report.push s!"store {cell.name}: {why}"
        | none =>
          parked := parked.push (scope, cell)
      stores := stores.push (scope, met)
    let cellsOf (scope : Document.Scope) : Array (String × Value) :=
      ((stores.find? (·.1 == scope)).map (·.2)).getD #[]
    let projectOf (identity : Project.Identity) : Project :=
      match record.projects.find? (·.identity == identity) with
      | some project =>
        { identity, name := project.name, remote := project.remote, commonDir := project.commonDir }
      | none => { identity, name := "" }
    let table : Workspace.Table :=
      { workspaces :=
          record.workspaces.map fun workspace =>
            let made : Workspace :=
              { location := workspace.location, branch := workspace.branch
                project := projectOf workspace.project }
            (made, cellsOf (.workspace workspace.location))
        projects :=
          record.projects.map fun project =>
            (projectOf project.identity, cellsOf (.project project.identity))
        unscoped := cellsOf .unscoped }
    return (table, parked, report)

end Editor.Restore
