import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Candidate
import Editor.DisplayRules
import Editor.Ex.Line
import Editor.File
import Editor.Language
import Editor.Mode
import Editor.Program
import Editor.ProjectMode
import Editor.ProjectMode.Format
import Editor.Scene
import Editor.State
import Editor.State.Request
import Editor.Test.Driver
import Editor.Test.Models
import Editor.Test.States
import Editor.Test.Workspace
import Editor.Text
import Editor.Value
import Editor.Workspace
import ModelTest.Check

/-!
# Model tests: `Editor/Workspace.lean`

The model tests of `Editor/Workspace.lean`: `workspaceDataChecks`,
`workspaceGitChecks`, `workspaceStateChecks` and `modeMarkerChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The checks of projects, workspaces and locations as data
(`Editor/Workspace.lean`): how an `origin` URL is normalised, how a project
is identified and named, how a workspace is labelled, what each location can
do, and a location's round trip through a buffer-local value. -/
def workspaceDataChecks : List Check :=
  let origin := "git@github.com:o/r.git"
  [{  name :=
        "an origin URL normalises to host/path whatever its form: git@github.com:o/r.git, https://github.com/o/r, ssh://git@github.com/o/r.git and https://github.com/o/r.git/ are one, and so are a host in capitals and an ssh port"
      run :=
        pure <|
          [origin, "https://github.com/o/r", "ssh://git@github.com/o/r.git",
                  "https://github.com/o/r.git/", "https://GitHub.com/o/r",
                  "ssh://git@github.com:22/o/r"].map
              Workspace.normaliseRemote ==
            List.replicate 6 "github.com/o/r" },
    { name :=
        "a project is identified by its normalised origin, else by its common git directory, else by its root, and a name config declares wins; it is named by the origin's last component, else by the common directory's parent's, else by the root's"
      run :=
        let byOrigin := Project.of "/x/clone" (some "/x/clone/.git") (some origin) none
        let byCommon := Project.of "/w" (some "/r/.git") none none
        let byRoot := Project.of "/m" none none none
        let declared := Project.of "/r/tools" none none (some "tools")
        let both := Project.of "/r" (some "/r/.git") (some origin) (some "mine")
        pure
          ((byOrigin.identity, byOrigin.name, byOrigin.remote, byOrigin.commonDir) ==
              (Project.Identity.remote "github.com/o/r", "r", some origin,
                some ("/x/clone/.git" : System.FilePath)) &&
            (byCommon.identity, byCommon.name) == (Project.Identity.commonDir "/r/.git", "r") &&
            (byRoot.identity, byRoot.name) == (Project.Identity.root "/m", "m") &&
            (declared.identity, declared.name) == (Project.Identity.declared "tools", "tools") &&
            (both.identity, both.name) == (Project.Identity.declared "mine", "mine")) },
    { name :=
        "a workspace is labelled name@branch, and name@ and its root's last component when it is detached or has no branch"
      run :=
        let project := Project.of "/r" (some "/r/.git") (some origin) none
        let onMain : Workspace :=
          { location := .local "/r", branch := some (.named "main"), project }
        let detached : Workspace := { location := .local "/w", branch := some .detached, project }
        let marked : Workspace :=
          { location := .local "/m", project := Project.of "/m" none none none }
        pure ([onMain, detached, marked].map Workspace.label == ["r@main", "r@w", "m@m"]) },
    { name :=
        "a worktree not yet found is labelled by the one rule a workspace is: labelOf gives r@d for a detached /a/d, r@fix on fix, name@<last component> for no branch and for a registered root, and agrees with label"
      run :=
        let project := Project.of "/r" (some "/r/.git") (some origin) none
        let workspaces : List Workspace :=
          [{ location := .local "/r", branch := some (.named "main"), project },
            { location := .local "/w", branch := some .detached, project },
            { location := .reachable "ssh" "host" "/srv/r", project }]
        pure <|
          Workspace.labelOf "r" (some .detached) (.local "/a/d") == "r@d" &&
            Workspace.labelOf "r" (some (.named "fix")) (.local "/u") == "r@fix" &&
            Workspace.labelOf "r" none (.local "/a/d/") == "r@d" &&
            Workspace.labelOf "r" none (.reachable "ssh" "host" "/srv/r") == "r@r" &&
            workspaces.all fun workspace =>
              Workspace.labelOf workspace.project.name workspace.branch workspace.location ==
                workspace.label },
    { name :=
        "a local location can read files, run commands and watch files; one reachable by a command and one known only by its branch can do none of them"
      run :=
        let all : Location.Capabilities :=
          { readFiles := true, runCommands := true, watchFiles := true }
        let none : Location.Capabilities :=
          { readFiles := false, runCommands := false, watchFiles := false }
        pure
          ((Location.local "/r").can == all &&
            (Location.reachable "kube" "pod/dev" "/src").can == none &&
            (Location.branchOnly origin "agent/x").can == none) },
    { name :=
        "a location crosses as a buffer-local value and back, and a value that is no location reads as none"
      run :=
        let locations : List Location :=
          [.local "/r", .reachable "kube" "pod/dev" "/src", .branchOnly origin "agent/x"]
        pure
          (locations.all (fun location => Location.decode? location.encode == some location) &&
            [Value.null, .str "/r", .record [("local", .nat 1)], .record []].all
              (Location.decode? · == none)) }]

/-- The checks of how the git adapter reads what git prints
(`Editor/Workspace.lean`, "The git adapter's command lines"). -/
def workspaceGitChecks : List Check :=
  let printed (text : String) : ByteArray := text.toUTF8
  [{  name :=
        "rev-parse's three lines are the top level, the common directory and the branch; HEAD is a detached checkout, and a common directory that is not absolute is resolved against the directory asked about"
      run :=
        pure
          (Workspace.Git.parseRevParse "/r/src" (printed "/r\n/r/.git\nmain\n") ==
              some { toplevel := "/r", commonDir := "/r/.git", branch := .named "main" } &&
            Workspace.Git.parseRevParse "/r" (printed "/r\n.git\nHEAD\n") ==
              some { toplevel := "/r", commonDir := "/r/.git", branch := .detached }) },
    { name :=
        "output that is not three lines, a top level that is not absolute and bytes that are not UTF-8 are no answer"
      run :=
        pure
          ([printed "/r\n/r/.git\n", printed "", printed "r\n/r/.git\nmain\n",
                printed "/r\n/r/.git\nmain\nextra\n", ByteArray.mk #[0xff, 0x0a]].all
            (Workspace.Git.parseRevParse "/r" · == none)) },
    { name := "the origin is the first line git prints, and an empty output is no origin"
      run :=
        pure
          (Workspace.Git.parseOrigin (printed "git@github.com:o/r.git\n") ==
              some "git@github.com:o/r.git" &&
            Workspace.Git.parseOrigin (printed "") == none) }]

/-- The checks of the workspaces and projects the editor state keeps
(`EditorState.workspaces`, `Editor/Workspace.lean`, "The table"), through
the state requests that change them (`Editor/State/Request.lean`) and the
editor API (`Editor/Api.lean`, "Workspaces"). -/
def workspaceStateChecks : List Check :=
  let origin := "git@github.com:o/r.git"
  let main :=
    Workspace.Found.ofGit { toplevel := "/r", commonDir := "/r/.git", branch := .named "main" } none
  let worktree :=
    Workspace.Found.ofGit { toplevel := "/w", commonDir := "/r/.git", branch := .named "feature" }
      none
  let request (state : EditorState) (request : StateRequest) : EditorState :=
    (state.handle request).2
  let recorded : EditorState :=
    request (request EditorState.none (.recordWorkspace "/r/src" 0 (some main)))
      (.recordWorkspace "/w/src" 0 (some worktree))
  let one : BufferId := ⟨1⟩
  [{  name :=
        "the directory a view's names are read from is its buffer's file's directory, else its local workspace's root, else the editor's working directory; and its place adds the home"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let state :=
              { state with
                workingDirectory := "/work", home := some "/home/me" }
            let withFile :=
              { state with
                buffers :=
                  state.buffers.modify 1 fun buffer =>
                    buffer.map fun (buffer : Buffer) =>
                      { buffer with
                        file :=
                          some
                            { path := "/w/src/a.lean"
                              stamp := { seconds := 0, nanoseconds := 0, size := 0 } } } }
            let inWorkspace :=
              request (request state (.recordWorkspace "/r/src" 0 (some main)))
                (.setValue ⟨0⟩ Workspace.bufferLocal (Location.local "/r").encode)
            state.directoryOf ⟨0⟩ == ("/work" : System.FilePath) &&
              withFile.directoryOf ⟨1⟩ == ("/w/src" : System.FilePath) &&
              withFile.directoryOf ⟨0⟩ == ("/work" : System.FilePath) &&
              inWorkspace.directoryOf ⟨0⟩ == ("/r" : System.FilePath) &&
              state.placeOf ⟨0⟩ == { directory := some "/work", home := some "/home/me" } &&
              EditorState.none.home == none },
    { name :=
        "where a command run for a buffer runs is decided on the state: its local workspace's root, its workspace's location when that is elsewhere, its file's directory with no separator at its end and / kept, or none; on this machine it runs there, and in the editor's working directory for a workspace elsewhere and for none"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let state := { state with workingDirectory := "/work" }
            let withFile (path : System.FilePath) : EditorState :=
              { state with
                buffers :=
                  state.buffers.modify 1 fun buffer =>
                    buffer.map fun (buffer : Buffer) =>
                      { buffer with
                        file :=
                          some { path, stamp := { seconds := 0, nanoseconds := 0, size := 0 } } } }
            let inWorkspace :=
              request (request state (.recordWorkspace "/r/src" 0 (some main)))
                (.setValue ⟨0⟩ Workspace.bufferLocal (Location.local "/r").encode)
            let reachable := Location.reachable "kube" "pod/dev" "/src"
            let elsewhere :=
              request (request state (.registerWorkspace reachable origin none))
                (.setValue ⟨0⟩ Workspace.bufferLocal reachable.encode)
            (withFile "/w/src//a.lean").workingDirectoryOf ⟨1⟩ == .fileDirectory "/w/src" &&
              (withFile "/a.lean").workingDirectoryOf ⟨1⟩ == .fileDirectory "/" &&
              (withFile "/w/src//a.lean").commandDirectoryOf ⟨1⟩ == ("/w/src" : System.FilePath) &&
              state.workingDirectoryOf ⟨0⟩ == .none &&
              state.commandDirectoryOf ⟨0⟩ == ("/work" : System.FilePath) &&
              inWorkspace.workingDirectoryOf ⟨0⟩ == .workspace "/r" &&
              inWorkspace.commandDirectoryOf ⟨0⟩ == ("/r" : System.FilePath) &&
              elsewhere.workingDirectoryOf ⟨0⟩ == .elsewhere reachable &&
              elsewhere.commandDirectoryOf ⟨0⟩ == ("/work" : System.FilePath) },
    { name :=
        "a workspace registered with a location known only by its branch and one reachable through kube belong to the project of their remote, whichever form it is in, and neither can run commands or read files; registering a local location is refused, with the state as it was"
      run :=
        let branchOnly := Location.branchOnly origin "agent/x"
        let reachable := Location.reachable "kube" "pod/dev" "/src"
        let (first, state) :=
          EditorState.none.handle (.registerWorkspace branchOnly origin (some "agent/x"))
        let (second, state) :=
          state.handle (.registerWorkspace reachable "https://github.com/o/r" none)
        let (refused, after) := state.handle (.registerWorkspace (.local "/r") origin none)
        let table := state.workspaces
        pure
          (replied first == .inr () && replied second == .inr () &&
            [branchOnly, reachable].all
              (fun location =>
                ((table.workspace? location).map (·.project.identity)) ==
                    some (.remote "github.com/o/r") &&
                  !location.can.runCommands &&
                  !location.can.readFiles) &&
            table.projects.size == 1 &&
            replied refused == .inl .local &&
            after.workspaces == table) },
    { name :=
        "a main checkout and a linked worktree found once each are two workspaces of one project: a value in one's workspace store is not seen from the other's, and one in the project store is seen through both"
      run :=
        let mainAt := Location.local "/r"
        let worktreeAt := Location.local "/w"
        let (set, state) := recorded.handle (.setWorkspaceValue mainAt "x" (.nat 1))
        let identity := (state.workspaces.workspace? mainAt).map (·.project.identity)
        let shared := (state.workspaces.workspace? worktreeAt).map (·.project.identity)
        match identity with
        | none => pure false
        | some identity =>
          let (told, state) := state.handle (.setProjectValue identity "h" (.str "make"))
          let table := state.workspaces
          pure
            (replied set == .inr () && replied told == .inr () &&
              table.workspaceValue? mainAt "x" == some (.nat 1) &&
              table.workspaceValue? worktreeAt "x" == none &&
              shared == some identity &&
              table.projectValue? identity "h" == some (.str "make") &&
              table.workspaces.size == 2 &&
              table.projects.size == 1) },
    { name :=
        "a value for a workspace or a project there is none of is refused, noSuchWorkspace and noSuchProject, with the state as it was"
      run :=
        let (noWorkspace, kept) := recorded.handle (.setWorkspaceValue (.local "/z") "x" .null)
        let (noProject, held) := recorded.handle (.setProjectValue (.root "/z") "x" .null)
        pure
          (replied noWorkspace == .inl (.noSuchWorkspace (.local "/z")) &&
            replied noProject == .inl (.noSuchProject (.root "/z")) &&
            kept.workspaces == recorded.workspaces &&
            held.workspaces == recorded.workspaces) },
    { name :=
        "a workspace found again keeps its root, its project and its store, and takes the branch it now has"
      run :=
        let (_, stored) := recorded.handle (.setWorkspaceValue (.local "/r") "x" (.nat 1))
        let moved :=
          Workspace.Found.ofGit
            { toplevel := "/r", commonDir := "/r/.git", branch := .named "other" } (some origin)
        let again := request stored (.recordWorkspace "/r/lib" 0 (some moved))
        let workspace := again.workspaces.workspace? (.local "/r")
        pure
          ((workspace.map fun found => (found.branch, found.project.identity)) ==
              some (some (.named "other"), .commonDir "/r/.git") &&
            again.workspaces.workspaceValue? (.local "/r") "x" == some (.nat 1) &&
            again.workspaces.workspaces.size == 2) },
    { name :=
        "each directory's answer is cached under the generation it was found under, a directory with no workspace included, and is not an answer under another"
      run :=
        let none' := request recorded (.recordWorkspace "/x/" 0 none)
        let table := none'.workspaces
        pure
          (table.cached? "/r/src" 0 == some (some (.local "/r")) &&
            table.cached? "/r/src" 1 == none &&
            table.cached? "/x" 0 == some none &&
            table.cached? "/y" 0 == none) },
    { name :=
        "a dispatched command that asks for the shell time limit is answered the limit the loop was told of"
      run :=
        let program : EditorM (Guarded (Option Nat) × EditorState) := do
          (RegistryRequest.ask .shellTimeLimit).dispatched { shellTimeLimit := some 5000 }
              (← twoBuffers)
        pure <|
          match (program.runModel editorModel).1 with
          | .ok (.finished answer, _) => answer == some 5000
          | _ => false },
    { name :=
        "a dispatched command that asks for the syntax refresh delay is answered the delay the loop was told of"
      run :=
        let program : EditorM (Guarded (Option Nat) × EditorState) := do
          (RegistryRequest.ask .syntaxRefreshDelay).dispatched { syntaxRefreshDelay := some 250 }
              (← twoBuffers)
        pure <|
          match (program.runModel editorModel).1 with
          | .ok (.finished answer, _) => answer == some 250
          | _ => false },
    { name :=
        "a dispatched command that asks for the compile hook is answered what the loop was told, and the workspace settings carry the contributions' marker modes in registration order"
      run :=
        let hook : Compile.Hook :=
          { contributions :=
              #[{ mode := "b-mode", markers := #["b.toml"] },
                { mode := "a-mode", markers := #["a.toml", "a2.toml"] }]
            projects := #[{ project := .remote "github.com/o/r", mode := "b-mode" }] }
        let asking : EditorM (Compile.Hook × Workspace.Settings) := do
          return (← RegistryRequest.ask .compileHook, (← RegistryRequest.ask .workspaceSettings).1)
        let program : EditorM (Guarded (Compile.Hook × Workspace.Settings) × EditorState) := do
          asking.dispatched { compile := hook } (← twoBuffers)
        pure <|
          match (program.runModel editorModel).1 with
          | .ok (.finished (told, settings), _) =>
            told.contributions.map (·.mode) == #["b-mode", "a-mode"] &&
              told.projects == hook.projects &&
              settings.markerModes ==
                #[{ mode := "b-mode", markers := #["b.toml"] },
                  { mode := "a-mode", markers := #["a.toml", "a2.toml"] }]
          | _ => false },
    { name :=
        "a dispatched command that asks for the workspace settings is answered config's roots and the config generation the loop was told of"
      run :=
        let roots : Array Workspace.ConfigRoot := #[{ root := "/r/tools", project := some "tools" }]
        let registered : Loop.Registered := { workspaceRoots := roots, generation := 3 }
        let program : EditorM (Guarded (Workspace.Settings × Nat) × EditorState) := do
          (RegistryRequest.ask .workspaceSettings).dispatched registered (← twoBuffers)
        pure <|
          match (program.runModel editorModel).1 with
          | .ok (.finished answer, _) => answer == ({ roots }, 3)
          | _ => false },
    { name :=
        "from a command: a buffer whose local value names a workspace has that workspace and its project; one that inherits from it has the same, and its working directory is the workspace's root; a buffer with none has no workspace and no working directory, and a store's value reads as its initial until it is set"
      run :=
        pure <|
          match
            dispatchedFrom do
              discard <| EditorState.ask (.recordWorkspace "/r/src" 0 (some main))
              discard <| one.setValue Workspace.bufferLocal (Location.local "/r").encode
              let found ← one.workspace?
              let none' ← (⟨0⟩ : BufferId).workspace?
              let before := (← editorState).workspaces.get countStore (.local "/r")
              let set ← Workspace.set countStore (.local "/r") 3
              let inherited ← (⟨0⟩ : BufferId).inheritWorkspace one
              return (found, none', before, set, inherited, ← (⟨0⟩ : BufferId).workspace?,
                  ← (⟨0⟩ : BufferId).workingDirectory) with
          | some ((found, none', before, set, inherited, after, directory), state) =>
            (found.map fun (workspace, project) => (workspace.location, project.identity)) ==
                some (.local "/r", .commonDir "/r/.git") &&
              none'.isNone &&
              before == 0 &&
              replied set == .inr () &&
              state.workspaces.get countStore (.local "/r") == 3 &&
              state.workspaces.get countStore (.local "/w") == 0 &&
              replied inherited == .inr () &&
              after == found &&
              directory == .workspace "/r"
          | none => false },
    { name :=
        "from a command: the unscoped store, for buffers outside any workspace, reads a store as its initial value until it is set there, then as what was set, a value of its own name beside it; and the editor's working directory is / until a host sets it, while a buffer with no workspace and no file still has none"
      run :=
        pure <|
          match
            dispatchedFrom do
              let before := (← editorState).workspaces.getUnscoped countStore
              Workspace.setUnscoped countStore 4
              Workspace.setUnscopedValue "other" (.str "kept")
              return (before, ← (⟨0⟩ : BufferId).workingDirectory) with
          | some ((before, directory), state) =>
            before == 0 && state.workspaces.getUnscoped countStore == 4 &&
              state.workspaces.unscopedValue? "other" == some (.str "kept") &&
              state.workspaces.unscopedValue? "missing" == none &&
              state.workspaces.workspaces.isEmpty &&
              state.workingDirectory == ("/" : System.FilePath) &&
              EditorState.none.workingDirectory == ("/" : System.FilePath) &&
              directory == .none
          | none => false },
    { name :=
        "from a command: a buffer with no workspace and no file has no working directory, and the API's registration and project values are the state requests'"
      run :=
        pure <|
          match
            dispatchedFrom do
              let directory ← (⟨0⟩ : BufferId).workingDirectory
              let local' ← Workspace.register (.local "/r") origin none
              let registered ←
                Workspace.register (.branchOnly origin "agent/x") origin (some "agent/x")
              let told ← Project.setValue (.remote "github.com/o/r") "h" (.nat 2)
              let typed ← Project.set countStore (.remote "github.com/o/r") 5
              let unknown ← Workspace.setValue (.local "/z") "x" .null
              return (directory, local', registered, told, typed, unknown) with
          | some ((directory, local', registered, told, typed, unknown), state) =>
            directory == .none && replied local' == .inl .local && replied registered == .inr () &&
              replied told == .inr () &&
              replied typed == .inr () &&
              replied unknown == .inl (.noSuchWorkspace (.local "/z")) &&
              state.workspaces.projectValue? (.remote "github.com/o/r") "h" == some (.nat 2) &&
              state.workspaces.getOfProject countStore (.remote "github.com/o/r") == 5
          | none => false }]

/-- The checks of the pure rules of the search for a minor mode's markers
within a workspace (`Editor/Workspace.lean`, "Modes on markers"): where it
looks, which modes the markers it found turn on, and how an on-mode
crosses as a tree. -/
def modeMarkerChecks : List Check :=
  [{  name :=
        "markerSearchPaths looks from /r/a/b/c up to and including the bound /r, each marker in order, and with a bound that does not hold the directory in the directory alone"
      run :=
        let expected : Array (System.FilePath × System.FilePath × String) :=
          #[("/r/a/b/c", "/r/a/b/c/x.toml", "x.toml"), ("/r/a/b/c", "/r/a/b/c/y.toml", "y.toml"),
            ("/r/a/b", "/r/a/b/x.toml", "x.toml"), ("/r/a/b", "/r/a/b/y.toml", "y.toml"),
            ("/r/a", "/r/a/x.toml", "x.toml"), ("/r/a", "/r/a/y.toml", "y.toml"),
            ("/r", "/r/x.toml", "x.toml"), ("/r", "/r/y.toml", "y.toml")]
        let alone : Array (System.FilePath × System.FilePath × String) :=
          #[("/r/a", "/r/a/x.toml", "x.toml")]
        pure
          (Workspace.markerSearchPaths #["x.toml", "y.toml"] "/r/a/b/c" "/r" == expected &&
            Workspace.markerSearchPaths #["x.toml", "y.toml"] "/r/a/b/c/" "/r/" == expected &&
            Workspace.markerSearchPaths #["x.toml"] "/r/a" "/w" == alone &&
            Workspace.markerSearchPaths #["x.toml"] "/r/a" "/r/a/b" == alone) },
    { name :=
        "onModes puts the nearest root first and, at one root, keeps registration order, whatever order the markers were found in"
      run :=
        let modes : Array Workspace.MarkerMode :=
          #[{ mode := "b-mode", markers := #["b.toml"] },
            { mode := "a-mode", markers := #["a.toml"] },
            { mode := "c-mode", markers := #["b.toml"] }]
        let present : Array (System.FilePath × String) :=
          #[("/r/k/l", "a.toml"), ("/r/k", "b.toml")]
        let expected : Array Workspace.OnMode :=
          #[{ mode := "a-mode", root := "/r/k/l" }, { mode := "b-mode", root := "/r/k" },
            { mode := "c-mode", root := "/r/k" }]
        pure
          (Workspace.onModes modes "/r/k/l" "/r" present == expected &&
            Workspace.onModes modes "/r/k/l" "/r" present.reverse == expected &&
            -- A mode is on at its nearest marker only.
            Workspace.onModes #[{ mode := "a-mode", markers := #["a.toml"] }] "/r/k/l" "/r"
                #[("/r/k", "a.toml"), ("/r/k/l", "a.toml")] ==
              #[{ mode := "a-mode", root := "/r/k/l" }] &&
            Workspace.onModes modes "/r/k/l" "/r" #[] == #[] &&
            Workspace.markersOf modes == #["b.toml", "a.toml"]) },
    { name :=
        "an outermost mode's root is its farthest marker within the bound: a nearest mode at a deeper root still comes first, a marker above the bound is not looked at, and with one marker the root is that one's"
      run :=
        let outer : Workspace.MarkerMode :=
          { mode := "o-mode", markers := #["o.toml"], outermost := true }
        let nearest : Workspace.MarkerMode := { mode := "n-mode", markers := #["n.toml"] }
        let present : Array (System.FilePath × String) :=
          #[("/r/k/l", "o.toml"), ("/r/k", "n.toml"), ("/r", "o.toml"), ("/", "o.toml")]
        pure
          (Workspace.onModes #[outer, nearest] "/r/k/l" "/r" present ==
              #[{ mode := "n-mode", root := "/r/k" }, { mode := "o-mode", root := "/r" }] &&
            Workspace.onModes #[{ outer with outermost := false }, nearest] "/r/k/l" "/r" present ==
              #[{ mode := "o-mode", root := "/r/k/l" }, { mode := "n-mode", root := "/r/k" }] &&
            Workspace.onModes #[outer, nearest] "/r/k/l" "/r" #[("/r/k/l", "o.toml")] ==
              #[{ mode := "o-mode", root := "/r/k/l" }] &&
            (Compile.Contribution.markerMode
                { mode := "o-mode", markers := #["o.toml"], outermost := true }) ==
              outer) },
    { name := "an on-mode crosses as a tree and back; a tree that is no on-mode reads as none"
      run :=
        let on : Workspace.OnMode := { mode := "a-mode", root := "/a b/é" }
        pure
          (Workspace.OnMode.decode? on.encode == some on &&
            [Value.str "a-mode", .list [.str "a-mode"], .list [.nat 1, .str "/r"]].all
              (Workspace.OnMode.decode? · == none) &&
            Workspace.modesLocal == "marker-modes") }]

end ModelTest
