import Editor.Restore.Workspaces
import Editor.Store
import ModelTest.Check

/-!
# Model tests: `Editor/Restore/Workspaces.lean`

The model tests of `Editor/Restore/Workspaces.lean`: `restoreWorkspaceChecks`,
pure. The root module `ModelTest` runs them; its module doc says what each
shows.
-/

namespace ModelTest

open Editor
open Editor.Restore

namespace RestoreWorkspaceTest

/-- A store of a count at version 2, which migrates a version-1 count by
doubling it. -/
def tally : Store Nat :=
  { name := "tally", version := 2, initial := 0, encode := .nat
    decode := fun
      | .nat n => some n
      | _ => none
    migrate := fun version tree =>
      match version, tree with
      | 1, .nat n => some (.nat (2 * n))
      | _, _ => none }

/-- A store of a buffer number and a note, whose codec drops the number. -/
def noted : Store (Option Nat × String) :=
  { name := "noted", version := 1, initial := (none, "")
    encode := fun (buffer, note) =>
      .record [("buffer", (buffer.map .nat).getD .null), ("note", .str note)]
    decode := fun
      | .record [("buffer", .nat buffer), ("note", .str note)] => some (some buffer, note)
      | .record [("buffer", .null), ("note", .str note)] => some (none, note)
      | _ => none }

/-- The codecs of the checks: `tally`'s and `noted`'s, the buffer dropped, of
the package `pkg`. -/
def codecs (name : String) : Option (String × StoreCodec) :=
  if name == "tally" then some ("pkg", tally.codec)
  else if name == "noted" then some ("pkg", noted.codec fun (_, note) => (none, note)) else none

/-- A project with a remote. -/
def project : Project :=
  { identity := .remote "github.com/o/r", name := "r", remote := some "git@github.com:o/r.git"
    commonDir := some "/w/r/.git" }

/-- A table of two workspaces of one project, a project with no workspace,
an unscoped store and a cached directory, with cells with a codec and
without. -/
def table : Workspace.Table :=
  { workspaces :=
      #[({ location := .local "/w/r", branch := some (.named "main"), project },
          #[("tally", .nat 3), ("noted", noted.encode (some 7, "kept")), ("private", .str "x")]),
        ({ location := .reachable "kube" "pod" "/src", branch := some .detached, project }, #[])]
    projects :=
      #[(project, #[("tally", .nat 1)]),
        ({ identity := .root "/plain", name := "plain" }, #[("private", .nat 2)])]
    cache := #[("/w/r/src", some (.local "/w/r"), 1)]
    unscoped := #[("tally", .nat 5), ("private", .null)] }

/-- Whether `record` written as JSON, rendered, parsed and read back is
`record`. -/
def roundTrips (record : Document.Workspaces) : Bool :=
  match Json.parse (Json.render record.toJson).toUTF8 with
  | .ok json => Document.Workspaces.ofJson? json == some record
  | .error _ => false

end RestoreWorkspaceTest

open RestoreWorkspaceTest in
/-- The checks of the workspace table as the session index records it
(`Editor/Restore/Workspaces.lean`). -/
def restoreWorkspaceChecks : List Check :=
  [{  name :=
        "a table's record round-trips through its JSON: each kind of identity and location, a named and a detached branch, and cells"
      run :=
        pure <|
          let identities : List Project.Identity :=
            [.remote "github.com/o/r", .commonDir "/c/.git", .root "/p", .declared "mine"]
          let locations : List Location :=
            [.local "/w", .reachable "ssh" "host" "/srv", .branchOnly "github.com/o/r" "feature"]
          roundTrips (Workspaces.record table codecs) &&
            identities.all
              (fun identity => roundTrips { projects := #[{ identity, name := "n" }] }) &&
            locations.all fun location =>
              [none, some (Workspace.Branch.named "b"), some .detached].all fun branch =>
                roundTrips { workspaces := #[{ location, branch, project := .declared "d" }] } },
    { name :=
        "a table's record holds every workspace and project and only the cells whose store has a codec, through its keep, at its version and with its owner; no directory cache"
      run :=
        pure <|
          let record := Workspaces.record table codecs
          let cell (name : String) (version : Nat) (value : Value) : KeptCell :=
            { owner := "pkg", name, version, value }
          record.workspaces.map (·.location) == #[.local "/w/r", .reachable "kube" "pod" "/src"] &&
            record.workspaces.map (·.branch) == #[some (.named "main"), some .detached] &&
            (record.workspaces.map (·.cells)) ==
              #[#[cell "tally" 2 (.nat 3), cell "noted" 1 (noted.encode (none, "kept"))], #[]] &&
            record.projects.map (fun project => (project.identity, project.cells)) ==
              #[(.remote "github.com/o/r", #[cell "tally" 2 (.nat 1)]), (.root "/plain", #[])] &&
            record.unscoped == #[cell "tally" 2 (.nat 5)] },
    { name :=
        "a restore meets a cell at the same version, migrates one of another, resets one decode refuses with a report line, and parks one with no codec with its scope"
      run :=
        pure <|
          let cell (name : String) (version : Nat) (value : Value) : KeptCell :=
            { owner := "pkg", name, version, value }
          let record : Document.Workspaces :=
            { workspaces :=
                #[{ location := .local "/w", project := .declared "d"
                    cells :=
                      #[cell "tally" 2 (.nat 3),
                        { cell "later" 1 (.nat 9) with owner := "config" }] }]
              projects :=
                #[{ identity := .declared "d", name := "d", cells := #[cell "tally" 1 (.nat 4)] }]
              unscoped := #[cell "tally" 2 (.str "bad")] }
          let (restored, parked, report) := Workspaces.restore record codecs
          restored.workspaceValue? (.local "/w") "tally" == some (.nat 3) &&
            restored.projectValue? (.declared "d") "tally" == some (.nat 8) &&
            restored.unscopedValue? "tally" == some (.nat 0) &&
            (restored.workspace? (.local "/w")).map (·.project.name) == some "d" &&
            parked ==
              #[(.workspace (.local "/w"), { cell "later" 1 (.nat 9) with owner := "config" })] &&
            report ==
              #["store tally: the new config cannot decode the stored value, which was reset to the initial value"] &&
            restored.cache.isEmpty },
    { name :=
        "a kept cell met into its scope is written into that store, met by the install rule, with a report line when its value is lost; a scope the table does not hold leaves it as it is"
      run :=
        pure <|
          let cell (name : String) (version : Nat) (value : Value) : KeptCell :=
            { owner := "pkg", name, version, value }
          let (inWorkspace, kept) :=
            Workspaces.meetInto table (.workspace (.local "/w/r")) (cell "tally" 1 (.nat 4))
              tally.codec
          let (inProject, refused) :=
            Workspaces.meetInto table (.project (.root "/plain")) (cell "tally" 2 (.str "bad"))
              tally.codec
          let (unscoped, _) := Workspaces.meetInto table .unscoped (cell "tally" 2 (.nat 6)) tally.codec
          let (nowhere, _) :=
            Workspaces.meetInto table (.project (.declared "none")) (cell "tally" 2 (.nat 6))
              tally.codec
          inWorkspace.workspaceValue? (.local "/w/r") "tally" == some (.nat 8) && kept.isNone &&
            inProject.projectValue? (.root "/plain") "tally" == some (.nat 0) &&
            refused ==
              some
                "store tally: the new config cannot decode the stored value, which was reset to the initial value" &&
            unscoped.unscopedValue? "tally" == some (.nat 6) &&
            nowhere.projects.map (·.2) == table.projects.map (·.2) },
    { name := "a restore and then a record give back the record"
      run :=
        pure <|
          let record := Workspaces.record table codecs
          let (restored, parked, report) := Workspaces.restore record codecs
          Workspaces.record restored codecs == record && parked.isEmpty && report.isEmpty },
    { name := "parked cells are written back into their stores, after the recorded ones"
      run :=
        pure <|
          let parkedCell : KeptCell :=
            { owner := "config", name := "later", version := 1, value := .nat 9 }
          let record := Workspaces.record table codecs
          let carried :=
            record.withParked #[(.unscoped, parkedCell), (.project (.root "/plain"), parkedCell)]
          carried.unscoped == record.unscoped.push parkedCell &&
            (carried.projects.map (·.cells.size)) == #[1, 1] }]

end ModelTest
