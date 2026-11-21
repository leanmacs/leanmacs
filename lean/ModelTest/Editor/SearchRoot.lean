import Editor.Command.Call
import Editor.SearchRoot
import Editor.State
import Editor.Test.Models
import Editor.Workspace
import ModelTest.Check

/-!
# Model tests: `Editor/SearchRoot.lean`

The model tests of `Editor/SearchRoot.lean`: `searchRootChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The state of the search root checks: the initial state, its scratch
buffer in view 0 with no file, with a workspace found at `/w` and one
registered at `kube pod/dev /src`, which cannot list its files; and, with
`inWorkspace`, the scratch buffer in `/w`'s. -/
def searchRootState (inWorkspace : Bool := false) : Option EditorState := do
  let state ← onTextModel (EditorState.initial ⟨640, 480⟩)
  let found : Workspace.Found := { root := "/w", project := Project.of "/w" none none none }
  let state := state.recordWorkspace "/w" 0 (some found)
  let (.ok (), state) :=
    state.registerWorkspace (.reachable "kube" "pod/dev" "/src") "git@h:o/r.git" (some "main")
    | none
  if inWorkspace then
    let (.ok (), state) :=
      state.setValue ⟨0⟩ Workspace.bufferLocal (Location.encode (.local "/w")) | none
    return state
  return state

/-- What `Workspace.searchRoot` answers in `state` for a call in view 0 with
`arguments`, its refusals naming `c`: the refusal on the left, the root on
the right. -/
def searchRootOf (state : EditorState) (arguments : List Argument) :
    Option (String ⊕ Workspace.SearchRoot) := do
  let target ← state.target? ⟨0⟩
  return match Workspace.searchRoot state { target, arguments } "c" with
    | .ok root => .inr root
    | .error said => .inl said

/-- The checks of what a search covers (`Editor/SearchRoot.lean`). -/
def searchRootChecks : List Check :=
  [{  name :=
        "a location given as the arguments is searched when the table has a workspace there: its root, its label, the text typed after the location, and the workspace"
      run :=
        pure <|
          match searchRootState with
          | none => false
          | some state =>
            let workspace := state.workspaces.workspace? (.local "/w")
            searchRootOf state (Location.arguments (.local "/w") ++ [.str "ab"]) ==
                some
                  (.inr
                    { root := "/w", label := (workspace.map (·.label)).getD "", typed := "ab"
                      workspace }) &&
              workspace.isSome },
    { name :=
        "a location given where the table has no workspace is refused with noSuchWorkspace, naming the command and the location"
      run :=
        pure <|
          match searchRootState with
          | none => false
          | some state =>
            searchRootOf state (Location.arguments (.local "/z")) ==
              some (.inl (Workspace.noSuchWorkspace (.local "/z") "c")) },
    { name :=
        "a workspace whose location cannot read files and run commands is refused with cannotList, given as the arguments and as the buffer's alike"
      run :=
        pure <|
          match searchRootState with
          | none => false
          | some state =>
            let location : Location := .reachable "kube" "pod/dev" "/src"
            match state.workspaces.workspace? location with
            | none => false
            | some remote =>
              searchRootOf state (Location.arguments location) ==
                  some (.inl (Workspace.cannotList remote "c")) &&
                match state.setValue ⟨0⟩ Workspace.bufferLocal (Location.encode location) with
                | (.ok (), held) =>
                  searchRootOf held [] == some (.inl (Workspace.cannotList remote "c"))
                | _ => false },
    { name :=
        "with no location given, the workspace of the window's buffer is searched, with no typed text"
      run :=
        pure <|
          match searchRootState (inWorkspace := true) with
          | none => false
          | some state =>
            let workspace := state.workspaces.workspace? (.local "/w")
            searchRootOf state [] ==
                some
                  (.inr { root := "/w", label := (workspace.map (·.label)).getD "", workspace }) &&
              workspace.isSome },
    { name :=
        "a buffer with no workspace is searched in the directory a command run for it would use, which labels it, with no workspace; other arguments, such as a count, are ignored"
      run :=
        pure <|
          match searchRootState with
          | none => false
          | some state =>
            let directory := state.commandDirectoryOf ⟨0⟩
            searchRootOf state [] ==
                some (.inr { root := directory, label := directory.toString, workspace := none }) &&
              searchRootOf state [.nat 3] == searchRootOf state [] }]

end ModelTest
