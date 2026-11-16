import Editor.Workspace.Finder
import Editor.Workspace.Model

/-!
# The contract of the workspace finder

Properties the finder must have, each a world (`Workspace.World`), the
config roots of the settings, the directories asked about and the answer
each must get. One list, run three ways, so the model cannot drift from the
real finder:

- by `model-test`, against `World.find`, the pure model;
- by `model-test`, against `Workspace.find`, the real finder, run on the job
  model of the world (`World.jobModel`);
- by `contract-test`, against `Workspace.find` over the library's process
  and file services, on the world written out in a temporary directory, with
  a fixture script standing in for git (`tests/workspaces/git`).

Every path of a property is under `base`, so that `contract-test` builds the
world in a directory of its own and `model-test` at the root.

`asksGit` is `false` for a property whose directories git must not be asked
about: the model run checks that no process was started for them.

## Adding to this

A new adapter's behaviour is a new property here, with the world that shows
it; what it needs written to disk is `materialize`'s, in `ContractTest`.
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
