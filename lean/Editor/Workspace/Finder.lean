import Editor.Job
import Editor.Workspace

/-!
# The workspace finder

`Workspace.find`: the workspace of a local directory, found through the job
port's process and file requests (`Editor/Job.lean`), so it needs no new
binding. It is the real implementation of the finder; its pure model is
`World.find` (`Editor/Workspace/Model.lean`), and the two are held to one
contract (`Workspace.FinderContract`, `Editor/Workspace/Contract.lean`): run
on the models by `model-test`, and over the library's process and file
services by `contract-test`.

## The adapters, in order

The first that answers wins.

- **Config** (`Workspace.fromConfig?`, pure, first): the deepest config
  root that holds the directory. No process is run for it.
- **Git** (`Git.revParse`, then `Git.origin`): `git rev-parse
  --path-format=absolute --show-toplevel --git-common-dir --abbrev-ref
  HEAD` in the directory, then `git remote get-url origin` there. Each runs
  through `Process.runWithin`, so it gets the directory's environment, with
  `GIT_DIR` and `GIT_WORK_TREE` removed, under the limits `gitOutput` and
  `gitTime`.
  - A status other than 0, a refusal (git missing is `notFound`), a run
    past its limit and output that is not three lines mean git does not
    answer, and the markers are asked.
  - `HEAD` as the third line is a detached checkout.
  - A common directory that is not absolute is resolved against the
    directory; `--path-format=absolute` makes git print an absolute one.
  - An `origin` run that does not exit 0 means there is no `origin`.
  - In a repository with no commit, `--abbrev-ref HEAD` fails, so git does
    not answer and the `.git` marker does.
- **Markers** (`markerFound`): `File.stamp` of each marker in the directory
  and in each of its ancestors, nearest first (`Workspace.markerPaths`). A
  marker is there when it has a stamp, or when it is refused as `notAFile`:
  a main checkout's `.git` is a directory. Its directory is the root, and
  the workspace is its own project.

None answering is `none`: the directory has no workspace.
-/

namespace Editor.Workspace

/-- What `git rev-parse` answers in `directory` (`Git.revParseCommand`), or
`none` when git does not answer. -/
def Git.revParse (git : String) (directory : System.FilePath) : JobM (Option Git.Answer) := do
  match ← Process.runWithin (Git.revParseCommand git directory) gitOutput gitTime with
  | .ok { exit := .code 0, stdout, .. } =>
    return Git.parseRevParse directory stdout
  | _ =>
    return none

/-- The URL of the `origin` of the repository of `directory`, or `none` when
it has none or git does not say. -/
def Git.origin (git : String) (directory : System.FilePath) : JobM (Option String) := do
  match ← Process.runWithin (Git.originCommand git directory) gitOutput gitTime with
  | .ok { exit := .code 0, stdout, .. } =>
    return Git.parseOrigin stdout
  | _ =>
    return none

/-- The marker adapter: the nearest directory, `directory` or one of its
ancestors, holding one of the settings' markers, in marker order. -/
def markerFound (settings : Settings) (directory : System.FilePath) : JobM (Option Found) := do
  for (root, path) in markerPaths settings directory do
    match ← File.stamp path with
    | .ok (some _) =>
      return some (Found.ofMarker root)
    | .error .notAFile =>
      return some (Found.ofMarker root)
    | _ =>
      pure ()
  return none

/-- The workspace of the local directory `directory`: config, then git, then
the markers, the first that answers ("The adapters, in order", in the module
docs); `none` when none does. -/
def find (settings : Settings) (directory : System.FilePath) : JobM (Option Found) := do
  let directory := Process.trimmed directory
  if let some found := fromConfig? settings directory then
    return some found
  if let some answer← Git.revParse settings.git directory then
    return some (Found.ofGit answer (← Git.origin settings.git directory))
  markerFound settings directory

end Editor.Workspace
