import Editor.Job.Model
import Editor.Workspace

/-!
# The pure model of the workspace finder

What the finder (`Workspace.find`, `Workspace/Finder.lean`) asks
about, as a value: the repositories there are, each with its top level, its
common git directory, its branch and its `origin`; the marker files and
directories there are; and whether git is installed at all. `World.find`
answers a directory as a pure function, and `World.jobModel` builds the job
model (`JobModel`, `Editor/Job/Model.lean`) whose process scripts and files
are what the real finder's requests meet in that world, so the real finder
runs on the models too.

## How it answers

The adapters are tried in order, the first that answers wins:

- **config**: the deepest config root that holds the directory
  (`Workspace.fromConfig?`, shared with the real finder);
- **git**, when it is installed: the repository whose top level is the
  nearest ancestor of the directory, or the directory itself;
- **markers**: the nearest ancestor, or the directory itself, holding one of
  the settings' markers, in marker order (`Workspace.markerPaths`).

A minor mode's markers within a workspace (`World.presentMarkers`) are the
paths of `Workspace.markerSearchPaths` that `present` holds, in order.

## What the job model holds

- **A rev-parse** in a directory a repository covers prints its top level,
  its common directory and its branch, or `HEAD` when it is detached, and
  exits 0; its `origin` run prints the URL and exits 0, or exits 2 for a
  repository with none, as git does. Outside every repository, rev-parse
  exits 128, as git does.
- **No git** is no script at all: the process model refuses the command as
  `notFound`, as a program that is not there is.
- **The markers** are files with no bytes, and the marker directories
  directories, so a stamp of `.git` in a main checkout is refused as
  `notAFile`, as the real file service refuses it.

The contract (`Workspace.FinderContract`, `WorkspaceTest/Finder/Contract.lean`)
is what says the model and the real finder agree.
-/

namespace Editor.Workspace

/-- A repository of the model's world. -/
structure Repository where
  /-- Its top level: the root of the checkout. -/
  toplevel : System.FilePath
  /-- Its common git directory. -/
  commonDir : System.FilePath
  /-- The branch checked out, or `none` when `HEAD` is detached. -/
  branch : Option String := some "main"
  /-- The URL of its `origin`, if it has one. -/
  origin : Option String := none
  deriving DecidableEq, Repr

/-- What the finder asks about, as a value. -/
structure World where
  /-- The repositories, each a checkout. -/
  repositories : Array Repository := #[]
  /-- The marker files there are. -/
  markers : Array System.FilePath := #[]
  /-- The marker directories there are, a main checkout's `.git`. -/
  markerDirectories : Array System.FilePath := #[]
  /-- Whether git is installed. -/
  git : Bool := true
  deriving DecidableEq, Repr

namespace Repository

/-- What git prints of the repository: its rev-parse's answer. -/
def answer (repository : Repository) : Git.Answer :=
  { toplevel := Process.trimmed repository.toplevel
    commonDir := Process.trimmed repository.commonDir
    branch :=
      match repository.branch with
      | some branch => .named branch
      | none => .detached }

/-- What a rev-parse in the repository prints. -/
def revParsed (repository : Repository) : ByteArray :=
  let answer := repository.answer
  let branch :=
    match answer.branch with
    | .named branch => branch
    | .detached => "HEAD"
  s!"{answer.toplevel}\n{answer.commonDir}\n{branch}\n".toUTF8

end Repository

namespace World

/-- The repository whose top level is the nearest ancestor of `directory`,
or `directory` itself. -/
def repository? (world : World) (directory : System.FilePath) : Option Repository :=
  (Process.ancestry directory).findSome? fun at_ =>
    world.repositories.find? (Process.trimmed ·.toplevel == at_)

/-- Whether something is at `path`: a marker file or a marker directory. -/
def present (world : World) (path : System.FilePath) : Bool :=
  world.markers.contains path || world.markerDirectories.contains path

/-- The finder's answer for `directory` in `world` with `settings`: config,
then git, when it is installed, then the markers ("How it answers", in the
module docs). -/
def find (world : World) (settings : Settings) (directory : System.FilePath) : Option Found :=
  let directory := Process.trimmed directory
  match fromConfig? settings directory with
  | some found => some found
  | none =>
    let byGit :=
      if world.git then
        (world.repository? directory).map fun repository =>
          Found.ofGit repository.answer repository.origin
      else none
    match byGit with
    | some found => some found
    | none =>
      (markerPaths settings directory).findSome? fun (root, path) =>
        if world.present path then some (Found.ofMarker root) else none

/-- The markers of `markers` there are in `world` in the directories
searched from `directory` within `bound`, each with its directory: the
model of `Workspace.presentMarkers`, over the same paths
(`Workspace.markerSearchPaths`). -/
def presentMarkers (world : World) (markers : Array String) (directory bound : System.FilePath) :
    Array (System.FilePath × String) :=
  (markerSearchPaths markers directory bound).filterMap fun (at_, path, marker) =>
    if world.present path then some (at_, marker) else none

/-- A run that exits with `status` and writes `stderr`, nothing on its
standard output. -/
def exited (status : Nat) (stderr : String) : Except ProcessError Process.Ran :=
  .ok { exit := .code status, stdout := .empty, stderr := stderr.toUTF8 }

/-- The job model of `world` for the finder's runs of the program `git` in
each of `directories` ("What the job model holds", in the module docs). -/
def jobModel (world : World) (git : String) (directories : Array System.FilePath) : JobModel :=
  let files := world.markers.foldl (fun (files : FileModel) path => files.withFile path .empty) {}
  let files := world.markerDirectories.foldl FileModel.withDirectory files
  let scripts : Array Process.Script :=
    if !world.git then #[]
    else
      directories.flatMap fun directory =>
        let directory := Process.trimmed directory
        match world.repository? directory with
        | some repository =>
          #[{ command := Git.revParseCommand git directory
              reply := .ok { exit := .code 0, stdout := repository.revParsed, stderr := .empty } },
            { command := Git.originCommand git directory
              reply :=
                match repository.origin with
                | some origin =>
                  .ok { exit := .code 0, stdout := s!"{origin}\n".toUTF8, stderr := .empty }
                | none => exited 2 "error: No such remote 'origin'\n" }]
        | none =>
          #[{ command := Git.revParseCommand git directory
              reply :=
                exited 128
                  "fatal: not a git repository (or any of the parent directories): .git\n" }]
  { files, processes := { scripts } }

end World

end Editor.Workspace
