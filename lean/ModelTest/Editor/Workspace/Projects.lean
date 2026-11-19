import Editor.VersionControl
import Editor.Workspace
import Editor.Workspace.Projects
import ModelTest.Check

/-!
# Model tests: `Editor/Workspace/Projects.lean`

The model tests of `Editor/Workspace/Projects.lean`:
`projectWorkspaceChecks`. The root module `ModelTest` runs them; its module
doc says what each shows.
-/

namespace ModelTest

open Editor

namespace ProjectsTest

/-- What is asked from `/r` on `main`, of the project `r`, whose table
holds `/r` and the workspaces `others`. -/
def askedFromR (others : Array Workspace.Projects.Known := #[]) : Workspace.Projects.Asked :=
  { git := "git", repository := some "/r", name := "r", current := .local "/r"
    known := #[{ location := .local "/r", label := "r@main" }] ++ others }

/-- The worktrees of `/r`'s repository: `/r` on `main`, `/u` on `fix` and
`/w` on `feature`. -/
def threeWorktrees : Array VersionControl.Worktree :=
  #[{ path := "/r", head := .branch "main" }, { path := "/u", head := .branch "fix" },
    { path := "/w", head := .branch "feature" }]

/-- The texts, annotations and whether the table knows each entry. -/
def shown (entries : Array Workspace.Projects.Entry) : Array (String × String × Bool) :=
  entries.map fun entry => (entry.text, entry.annotation, entry.known)

/-- A workspace registered on another machine. -/
def remote : Location :=
  .reachable "ssh" "host" "/srv/r"

end ProjectsTest

open ProjectsTest in
/-- The checks of the project's workspaces (`Editor/Workspace/Projects.lean`),
pure. -/
def projectWorkspaceChecks : List Check :=
  [{  name :=
        "the project's workspaces are its worktrees in the reply's order, each not found yet labelled name@branch and annotated with its root, the current one last"
      run :=
        pure <|
          shown (Workspace.Projects.entries (askedFromR) threeWorktrees) ==
            #[("r@fix", "/u", false), ("r@feature", "/w", false), ("r@main", "/r", true)] },
    { name :=
        "a worktree the table knows takes the table's label, even where its branch has moved on, and is known"
      run :=
        pure <|
          let asked := askedFromR #[{ location := .local "/w", label := "r@old-name" }]
          shown (Workspace.Projects.entries asked threeWorktrees) ==
            #[("r@fix", "/u", false), ("r@old-name", "/w", true), ("r@main", "/r", true)] },
    { name := "a location listed twice, by the worktrees or by them and the table, gives one entry"
      run :=
        pure <|
          let asked := askedFromR #[{ location := .local "/u", label := "r@fix" }]
          (Workspace.Projects.entries asked
                  (threeWorktrees.push { path := "/u", head := .branch "fix" })).map
              (·.location) ==
            #[.local "/u", .local "/w", .local "/r"] },
    { name := "a detached worktree is labelled by its directory's last component"
      run :=
        pure <|
          shown
              (Workspace.Projects.entries (askedFromR)
                #[{ path := "/r", head := .branch "main" },
                  { path := "/a/d", head := .detached }]) ==
            #[("r@d", "/a/d", false), ("r@main", "/r", true)] },
    { name :=
        "the table's workspaces no worktree matched follow the worktrees: a registered one is annotated with its root; with no repository asked, only the table's are listed"
      run :=
        pure <|
          let asked := askedFromR #[{ location := remote, label := "r@agent" }]
          shown (Workspace.Projects.entries asked threeWorktrees) ==
              #[("r@fix", "/u", false), ("r@feature", "/w", false), ("r@agent", "/srv/r", true),
                ("r@main", "/r", true)] &&
            shown (Workspace.Projects.entries { asked with repository := none } #[]) ==
              #[("r@agent", "/srv/r", true), ("r@main", "/r", true)] &&
            shown
                (Workspace.Projects.entries
                  (askedFromR #[{ location := .branchOnly "o/r" "agent", label := "r@agent" }])
                  #[]) ==
              #[("r@agent", "only the branch agent of o/r", true), ("r@main", "/r", true)] },
    { name :=
        "two entries with one label are told apart by their annotation, and each resolves exactly; a text no entry has resolves to none"
      run :=
        pure <|
          let asked := askedFromR #[{ location := remote, label := "r@main" }]
          let entries := Workspace.Projects.entries asked threeWorktrees
          entries.map (·.text) == #["r@fix", "r@feature", "r@main (/srv/r)", "r@main (/r)"] &&
            (Workspace.Projects.resolveExact entries "r@main (/srv/r)").map (·.location) ==
              some remote &&
            (Workspace.Projects.resolveExact entries "r@main (/r)").map (·.location) ==
              some (.local "/r") &&
            (Workspace.Projects.resolveExact entries "r@main").isNone },
    { name :=
        "what is asked survives its arguments' round trip, with a repository and with none, every kind of location among the known, and anything after it ignored"
      run :=
        pure <|
          let full :=
            askedFromR
              #[{ location := remote, label := "r@agent" },
                { location := .branchOnly "o/r" "b", label := "r@b" }]
          let bare : Workspace.Projects.Asked :=
            { git := "/bin/git", repository := none, name := "m", current := .local "/m"
              known := #[] }
          [full, bare].all fun asked =>
            Workspace.Projects.Asked.ofArguments? asked.toArguments == some asked &&
              Workspace.Projects.Asked.ofArguments? (asked.toArguments ++ [.str "more"]) ==
                some asked &&
              Workspace.Projects.Asked.ofArguments? (asked.toArguments.take 3) == none },
    { name :=
        "a worktree's head is a workspace's branch: a branch by its name, detached as detached"
      run :=
        pure <|
          Workspace.Projects.Head.branch (.branch "fix") == .named "fix" &&
            Workspace.Projects.Head.branch .detached == .detached }]

end ModelTest
