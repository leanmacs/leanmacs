import Workspace.Finder
import WorkspaceTest.Finder.Model

/-!
# The contract of the workspace finder

Properties the finder must have, each a world (`Workspace.World`), the
config roots of the settings, the directories asked about and the answer
each must get. One list, run three ways, so the model cannot drift from the
real finder:

- by `workspace-test`, against `World.find`, the pure model;
- by `workspace-test`, against `Workspace.find`, the real finder, run on the job
  model of the world (`World.jobModel`);
- by the workspace's linked test, against `Workspace.find` over the library's process
  and file services, on the world written out in a temporary directory, with
  a fixture script standing in for git (`tests/workspaces/git`).

Every path of a property is under `base`, so that the linked test builds the
world in a directory of its own and `workspace-test` at the root.

`asksGit` is `false` for a property whose directories git must not be asked
about: the model run checks that no process was started for them.

## Adding to this

A new adapter's behaviour is a new property here, with the world that shows
it; what it needs written to disk is `materialize`'s, in `WorkspaceTest.Linked`.
-/

namespace Editor.Workspace.FinderContract

/-- One property: a world, config's roots, and what the finder answers for
each directory asked about. -/
structure Property where
  /-- What must hold, as a sentence. -/
  name : String
  /-- The roots config declares. -/
  roots : Array ConfigRoot := #[]
  /-- The world. -/
  world : World
  /-- Each directory asked about, and its answer. -/
  asked : Array (System.FilePath × Option Found)
  /-- Whether git may be asked about these directories. -/
  asksGit : Bool := true

/-- The settings of `property` with the program `git`. -/
def Property.settings (property : Property) (git : String) : Settings :=
  { roots := property.roots, git }

/-- The answers the real finder gives to the property's directories, in
order, with the program `git`. -/
def Property.answers (property : Property) (git : String) : JobM (Array (Option Found)) :=
  property.asked.mapM fun (directory, _) => find (property.settings git) directory

/-- The answers the property expects, in order. -/
def Property.expected (property : Property) : Array (Option Found) :=
  property.asked.map (·.2)

/-- Whether the real finder gives the property's answers, with the program
`git`. -/
def Property.holds (property : Property) (git : String) : JobM Bool := do
  return (← property.answers git) == property.expected

/-- The URL the clones of the properties have as their `origin`, in ssh
form. -/
def sshOrigin : String :=
  "git@github.com:o/r.git"

/-- The same repository's URL in https form, with no `.git`. -/
def httpsOrigin : String :=
  "https://github.com/o/r"

/-- The finder's properties, every path under `base`. -/
def properties (base : System.FilePath) : List Property :=
  let at_ (path : String) : System.FilePath := Process.inDirectory base path
  let main : Repository :=
    { toplevel := at_ "r", commonDir := at_ "r/.git", branch := some "main",
      origin := some sshOrigin }
  let worktree : Repository :=
    { toplevel := at_ "w", commonDir := at_ "r/.git", branch := some "feature"
      origin := some sshOrigin }
  let remote := Project.Identity.remote "github.com/o/r"
  let viaGit (repository : Repository) : Found := Found.ofGit repository.answer repository.origin
  [{  name :=
        "a directory in a main checkout is the checkout's workspace: the top level is its root, its branch is the checkout's, and its project is identified by the normalised origin, with the common git directory"
      world := { repositories := #[main], markerDirectories := #[at_ "r/.git"] }
      asked :=
        #[(at_ "r/src",
            some
              { root := at_ "r", branch := some (.named "main")
                project :=
                  { identity := remote, name := "r", remote := some sshOrigin
                    commonDir := some (at_ "r/.git") } })] },
    { name :=
        "a directory in a linked worktree is a workspace of its own, rooted at the worktree with its own branch, of the same project as the main checkout"
      world :=
        { repositories := #[main, worktree], markerDirectories := #[at_ "r/.git"]
          markers := #[at_ "w/.git"] }
      asked := #[(at_ "r/src", some (viaGit main)), (at_ "w/src", some (viaGit worktree))] },
    { name :=
        "two clones whose origins are the ssh form with .git and the https form without it are one project"
      world :=
        {
          repositories :=
            #[{ toplevel := at_ "a", commonDir := at_ "a/.git", origin := some sshOrigin },
              { toplevel := at_ "b", commonDir := at_ "b/.git", origin := some httpsOrigin }] }
      asked :=
        #[(at_ "a",
            some
              (Found.ofGit
                { toplevel := at_ "a", commonDir := at_ "a/.git", branch := .named "main" }
                (some sshOrigin))),
          (at_ "b",
            some
              (Found.ofGit
                { toplevel := at_ "b", commonDir := at_ "b/.git", branch := .named "main" }
                (some httpsOrigin)))] },
    { name :=
        "a config root wins over git for a directory both cover: its root is the workspace's, and its project is the one config declares; git is not asked"
      roots := #[{ root := at_ "r/tools", project := some "tools" }]
      world := { repositories := #[main], markerDirectories := #[at_ "r/.git"] }
      asked :=
        #[(at_ "r/tools/x",
            some
              { root := at_ "r/tools",
                project := { identity := .declared "tools", name := "tools" } })]
      asksGit := false },
    { name :=
        "with no config and no git installed, the nearest directory holding a marker file is a workspace that is its own project, identified by its root"
      world := { git := false, markers := #[at_ "m/Cargo.toml"] }
      asked :=
        #[(at_ "m/src/deep",
            some { root := at_ "m", project := { identity := .root (at_ "m"), name := "m" } })] },
    { name :=
        "with git answering that a directory is in no repository, the nearest marker file's directory is the workspace, its own project"
      world := { markers := #[at_ "m/Cargo.toml"] }
      asked := #[(at_ "m/src/deep", some (Found.ofMarker (at_ "m")))] },
    { name :=
        "with git not answering for a directory, as in a repository with no commit, a .git directory is a marker: the nearest directory holding one is the workspace, its own project"
      world := { markerDirectories := #[at_ "u/.git"] }
      asked := #[(at_ "u/src", some (Found.ofMarker (at_ "u")))] },
    { name :=
        "two worktrees of a repository with no origin are one project, identified by their common git directory"
      world :=
        { repositories := #[{ main with origin := none }, { worktree with origin := none }]
          markerDirectories := #[at_ "r/.git"], markers := #[at_ "w/.git"] }
      asked :=
        #[(at_ "r/src",
            some
              { root := at_ "r", branch := some (.named "main")
                project :=
                  { identity := .commonDir (at_ "r/.git"), name := "r"
                    commonDir := some (at_ "r/.git") } }),
          (at_ "w/src",
            some
              { root := at_ "w", branch := some (.named "feature")
                project :=
                  { identity := .commonDir (at_ "r/.git"), name := "r"
                    commonDir := some (at_ "r/.git") } })] },
    { name := "a checkout whose HEAD is detached is a workspace with a detached branch"
      world :=
        { repositories := #[{ toplevel := at_ "d", commonDir := at_ "d/.git", branch := none }] }
      asked :=
        #[(at_ "d/src",
            some
              { root := at_ "d", branch := some .detached
                project :=
                  { identity := .commonDir (at_ "d/.git"), name := "d"
                    commonDir := some (at_ "d/.git") } })] },
    { name := "a directory no adapter answers for has no workspace"
      world := {}
      asked := #[(at_ "n/src", none)] }]

end Editor.Workspace.FinderContract

/-!
## The contract of the mode marker search

Properties the search for a minor mode's markers within a workspace must
have (`Workspace.presentMarkers`, `Workspace/Finder.lean`; "Modes on
markers", `Editor/Workspace.lean`): each a world, the markers looked for,
and for each directory and bound asked about, the markers found with their
directories. Run the same three ways as the finder's: against
`World.presentMarkers` and against the real search on the job model by
`workspace-test`, and over the library's file service, the world written
out under a temporary directory, by the package's linked test. Every path is under
`base`. The search runs no process, so no world needs git.
-/

namespace Editor.Workspace.MarkerContract

/-- One property: a world, the markers looked for, and what is found for
each directory and bound asked about. -/
structure Property where
  /-- What must hold, as a sentence. -/
  name : String
  /-- The world. -/
  world : World
  /-- The markers looked for, in order. -/
  markers : Array String
  /-- Each directory asked about, its bound, and the markers found, each
  with its directory, in order. -/
  asked : Array (System.FilePath × System.FilePath × Array (System.FilePath × String))

/-- What the real search finds for each of the property's directories, in
order. -/
def Property.answers (property : Property) : JobM (Array (Array (System.FilePath × String))) :=
  property.asked.mapM fun (directory, bound, _) => presentMarkers property.markers directory bound

/-- What the property expects found, in order. -/
def Property.expected (property : Property) : Array (Array (System.FilePath × String)) :=
  property.asked.map (·.2.2)

/-- Whether the real search finds what the property expects. -/
def Property.holds (property : Property) : JobM Bool := do
  return (← property.answers) == property.expected

/-- The mode marker search's properties, every path under `base`. -/
def properties (base : System.FilePath) : List Property :=
  let at_ (path : String) : System.FilePath := Process.inDirectory base path
  [{  name := "a marker two directories above the directory is found, with its directory"
      world := { markers := #[at_ "p/m.toml"] }
      markers := #["m.toml"]
      asked := #[(at_ "p/a/b", at_ "p", #[(at_ "p", "m.toml")])] },
    { name := "a marker above the bound is not found"
      world := { markers := #[at_ "q/m.toml"] }
      markers := #["m.toml"]
      asked := #[(at_ "q/w/a", at_ "q/w", #[])] },
    { name :=
        "markers at two depths are found nearest first, and two in one directory in the order they are looked for"
      world := { markers := #[at_ "c/x.toml", at_ "c/d/y.toml", at_ "c/d/x.toml"] }
      markers := #["x.toml", "y.toml"]
      asked :=
        #[(at_ "c/d", at_ "c",
            #[(at_ "c/d", "x.toml"), (at_ "c/d", "y.toml"), (at_ "c", "x.toml")])] },
    { name := "with a bound that does not hold the directory, the directory alone is looked in"
      world := { markers := #[at_ "e/m.toml", at_ "e/f/m.toml"] }
      markers := #["m.toml"]
      asked := #[(at_ "e/f", at_ "g", #[(at_ "e/f", "m.toml")])] },
    { name := "a marker that is a directory is found"
      world := { markerDirectories := #[at_ "h/.marker"] }
      markers := #[".marker"]
      asked := #[(at_ "h/src", at_ "h", #[(at_ "h", ".marker")])] }]

end Editor.Workspace.MarkerContract
