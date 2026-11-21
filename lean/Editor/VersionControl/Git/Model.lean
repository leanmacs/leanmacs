import Editor.Job.Model
import Editor.VersionControl.Git
import VcApiTest.Fake

/-!
# The git implementation's half of the repository model

What the git implementation prints and runs, as the pure model of a
repository (`VcApiTest/Fake.lean`, the interface library `vc-api`'s fake)
would make git print it: `Repository.porcelain` prints the status as git
prints it with the git implementation's flags, so the real parser reads the
model's status (`Editor/VersionControl/Porcelain.lean`), and
`Repository.worktreePorcelain` the worktree list; `blobId` names a blob as
the job model does; and `Repository.jobModel` is the job model (`JobModel`,
`Editor/Job/Model.lean`) whose process scripts answer the git
implementation's command lines in a repository, so the git implementation
runs on the models too. It is version control's, not the interface's: a jj
backend would have a half of its own, and the port's model knows nothing of
git. It keeps the model's namespace, `Editor.VersionControl.Model`, so
`repository.jobModel …` reads as it did.

Its module is named as a test double (`Editor.*.Model`), and the core's
root imports it: the version-control tests are written on it.

Pinned by `ModelTest.gitModelChecks`; the git implementation on it by
`ModelTest.versionControlGitChecks`.
-/

namespace Editor.VersionControl.Model

namespace Repository

/-- An object name of none of git's objects, which the printer prints in
every place git prints one. -/
def zeros : String :=
  "0000000000000000000000000000000000000000"

/-- The letter git prints for a change, `.` for none. -/
def letter : Option Change → Char
  | none => '.'
  | some .added => 'A'
  | some .modified => 'M'
  | some .deleted => 'D'

/-- The `XY` git prints for a conflict. -/
def conflictCode : Conflict → String
  | .bothModified => "UU"
  | .bothAdded => "AA"
  | .bothDeleted => "DD"
  | .addedByUs => "AU"
  | .addedByThem => "UA"
  | .deletedByUs => "DU"
  | .deletedByThem => "UD"

/-- The record git prints for `file`, its NUL included, with placeholder
modes and object names. -/
def record (file : FileStatus) : String :=
  match file.state with
  | .changed staged unstaged =>
    s!"1 {letter staged}{letter unstaged} N... 100644 100644 100644 {zeros} {zeros} {file.path}\x00"
  | .renamed origin unstaged =>
    s!"2 R{letter unstaged} N... 100644 100644 100644 {zeros} {zeros} R100 {file.path}\x00{origin}\x00"
  | .conflicted how =>
    s!"u {conflictCode how} N... 100644 100644 100644 100644 {zeros} {zeros} {zeros} {file.path}\x00"
  | .untracked => s!"? {file.path}\x00"

/-- Where git lists a file: changes and renames, then conflicts, then
untracked files. -/
def listing : FileState → Nat
  | .changed .. | .renamed .. => 0
  | .conflicted _ => 1
  | .untracked => 2

/-- What the git implementation's status read (`Git.statusArguments`)
prints of `repository`: the `branch.oid` and `branch.head` headers, then a
record for each file in git's order. -/
def porcelain (repository : Repository) : ByteArray :=
  let status := repository.status
  let oid := if repository.committed.isEmpty then "(initial)" else zeros
  let head :=
    match status.head with
    | .branch name => name
    | .detached => "(detached)"
  let listed :=
    (List.range 3).toArray.flatMap fun place => status.files.filter (listing ·.state == place)
  (s!"# branch.oid {oid}\x00# branch.head {head}\x00" ++
      String.join (listed.map record).toList).toUTF8

/-- A run of `git` that exits 0 having written `stdout`. -/
def ran (stdout : ByteArray) : Except ProcessError Process.Ran :=
  .ok { exit := .code 0, stdout, stderr := .empty }

/-- What the git implementation's worktree list read
(`Git.worktreeListArguments`) prints of `repository`, as git prints it with
`-z`: a record for each worktree, its path, `HEAD` and its branch or
`detached`. -/
def worktreePorcelain (repository : Repository) : ByteArray :=
  String.join
      (repository.worktreesOf.toList.map fun worktree =>
        let head :=
          match worktree.head with
          | .branch name => s!"branch refs/heads/{name}"
          | .detached => "detached"
        s!"worktree {worktree.path}\x00HEAD {zeros}\x00{head}\x00\x00") |>.toUTF8

end Repository

/-- The id the job model gives the blob of `content`: made of its content
alone, so equal contents share it, as git's do. -/
def blobId (content : String) : String :=
  s!"blob{hash content}"

namespace Repository

/-- The job model in which the git implementation, running `git` in `root`,
meets `repository`: its status read prints `porcelain`; each of `writes`
exits 0; `fileAt`'s two runs answer each file of `HEAD`, of the index (the
empty revision) and of each named revision, its id and then its bytes; its first run exits 1 for each
revision and path of `missing`; and `watched` prints the git and the common
directories; and its worktree list read prints `worktreePorcelain`. A hunk's apply of `writes` exits 0 whatever it is fed, and so
does its commit, but in a repository with a `hook`, where it exits 1 with
the hook's output on its standard error. A command no script names is refused as `notFound`, as a
program that is not there is. -/
def jobModel (repository : Repository) (git : String) (root : System.FilePath)
    (writes : Array Request := #[]) (missing : Array (String × String) := #[]) : JobModel :=
  let script (arguments : Array String) (stdout : ByteArray) : Process.Script :=
    { command := Git.command git root arguments, reply := ran stdout }
  let files :=
    (("HEAD", repository.committed) ::
          ("", repository.indexFiles) :: repository.revisions.toList).toArray.flatMap
      fun (revision, files) => files.map fun (path, content) => (revision, path, content)
  {
    processes :=
      {
        scripts :=
          #[script Git.statusArguments repository.porcelain,
              script Git.worktreeListArguments repository.worktreePorcelain] ++
            writes.filterMap
              (fun write =>
                match write with
                | .stage paths => some (script (Git.stageArguments paths) .empty)
                | .unstage paths => some (script (Git.unstageArguments paths) .empty)
                | .stageHunk .. => some (script (Git.applyArguments false) .empty)
                | .unstageHunk .. => some (script (Git.applyArguments true) .empty)
                | .commit _ =>
                  some
                    { command := Git.commitCommand git root
                      reply :=
                        match repository.hook with
                        | some printed =>
                          .ok {
                              exit := .code 1, stdout := .empty
                              stderr := File.encodeText printed }
                        | none => ran .empty }
                | _ => none) ++
            files.flatMap
              (fun (revision, path, content) =>
                #[script (Git.revisionArguments revision path) s!"{blobId content}\n".toUTF8,
                  script (Git.blobArguments (blobId content)) (File.encodeText content)]) ++
            missing.map
              (fun (revision, path) =>
                { command := Git.command git root (Git.revisionArguments revision path)
                  reply := .ok { exit := .code 1, stdout := .empty, stderr := .empty } }) ++
            #[script Git.watchedArguments
                s!"{repository.gitDir}\n{repository.commonDir}\n".toUTF8] } }

end Repository

end Editor.VersionControl.Model
