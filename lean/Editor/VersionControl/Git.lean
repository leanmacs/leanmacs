import Editor.VersionControl
import Editor.VersionControl.Porcelain
import Editor.Workspace

namespace Editor.VersionControl.Git

/-- The most bytes of each stream a git run may write: 16 MiB. -/
def statusOutput : Nat :=
  16 * 1024 * 1024

/-- How long a git run may take, in milliseconds. -/
def gitTime : Nat :=
  30000

/-- The environment of every git run: the editor's, with `GIT_DIR`,
`GIT_WORK_TREE` and `GIT_INDEX_FILE` removed, so git answers for the
directory it runs in and its own index, with `GIT_OPTIONAL_LOCKS=0`, so a
read never takes the index lock, and with `GIT_LITERAL_PATHSPECS=1`, so a
path is never read as a pattern. -/
def environment : Process.Environment :=
  { unset := Workspace.Git.environment.unset.push "GIT_INDEX_FILE"
    set := #[("GIT_OPTIONAL_LOCKS", "0"), ("GIT_LITERAL_PATHSPECS", "1")] }

/-- The arguments of a status read. -/
def statusArguments : Array String :=
  #["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--find-renames"]

/-- The arguments that stage `paths`. -/
def stageArguments (paths : Array String) : Array String :=
  #["add", "--all", "--"] ++ paths

/-- The arguments that unstage `paths`. -/
def unstageArguments (paths : Array String) : Array String :=
  #["reset", "-q", "--"] ++ paths

/-- The arguments of `request`. -/
def arguments : Request → Array String
  | .status => statusArguments
  | .stage paths => stageArguments paths
  | .unstage paths => unstageArguments paths

/-- The command that runs `git` with the arguments of `request` in `root`. -/
def command (git : String) (root : System.FilePath) (request : Request) : Process.Command :=
  { program := git, arguments := arguments request, environment, directory := root }

end Editor.VersionControl.Git
