import Editor.Job
import Editor.Job.Model
import Editor.Process
import Editor.VersionControl.Git
import ModelTest.Support.Repositories
import VcApi

/-!
# Model tests: support: Git

What git prints and runs, as the version-control checks meet it: the
porcelain status of a clean checkout and of a repository in every state, the
status and the model repository that stand for it, and the commands the git
implementation runs in `/r`. Shared by several test modules under
`ModelTest/Editor/`; it holds no checks of its own.

## The fixtures

What `git -c status.renames=true -c diff.renames=true status
--porcelain=v2 -z --branch --untracked-files=all --find-renames` printed,
byte for byte, with each NUL written `\x00`. Each was captured with git
2.56.1, with `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null` unless
its comment names another config, a fresh `HOME`, author and committer `a
<a@example.com>` at `2026-01-01T00:00:00Z`, in a repository made by `git -c
init.defaultBranch=main init` and the commands each fixture's comment
gives (`g` is `git -c commit.gpgsign=false`).
-/

namespace ModelTest

open Editor

/-- On `main`, nothing changed: `echo a > a.txt; git add -A; g commit -m
head`. -/
def porcelainClean : String :=
  "# branch.oid a655a818d91215d2e13ebd735265b112d61e150d\x00" ++ "# branch.head main\x00"

/-- Every state at once. Each of `sm um mm uu ud du gone deleted` written
as `<name>.txt` holding its name, `old.txt` holding `old` and `with
space.txt` holding `space`, committed as `base`; on a branch `other`,
`uu.txt`, `aa.txt` and `du.txt` written `theirs` and `ud.txt` removed,
committed; on `main`, `uu.txt`, `aa.txt` and `ud.txt` written `ours` and
`du.txt` removed, committed; then `g merge other`, which stops in conflict;
then `sm.txt` written and staged, `um.txt` written, `mm.txt` written,
staged and written again, `added.txt` written and staged, `git rm
deleted.txt`, `rm gone.txt`, `dir/new.txt` written, `with space.txt`
written, `héllo.txt` written, and `git mv old.txt new.txt`. -/
def porcelainMixed : String :=
  "# branch.oid 78576d68d8f3fbaca58094a963d069afbd1f86f2\x00" ++ "# branch.head main\x00" ++
    "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 d5f7fc3f74f7dec08280f370a975b112e8f60818 added.txt\x00" ++
    "1 D. N... 100644 000000 000000 71779d2cab258b810b2f567c9a619f6e0105f44e 0000000000000000000000000000000000000000 deleted.txt\x00" ++
    "1 .D N... 100644 100644 000000 286c5f5776916d7d7d5849988ca9d83e722cf9c2 286c5f5776916d7d7d5849988ca9d83e722cf9c2 gone.txt\x00" ++
    "1 MM N... 100644 100644 100644 dba863d1633701b13bbd23ec0e2b9104cf90e850 19d9cc8584ac2c7dcf57d2680375e80f099dc481 mm.txt\x00" ++
    "2 R. N... 100644 100644 100644 3367afdbbf91e638efe983616377c60477cc6612 3367afdbbf91e638efe983616377c60477cc6612 R100 new.txt\x00" ++
    "old.txt\x00" ++
    "1 M. N... 100644 100644 100644 ffcdb2a6c8d3d589b0edffd494c1cf2fe327e1ed 19d9cc8584ac2c7dcf57d2680375e80f099dc481 sm.txt\x00" ++
    "1 .M N... 100644 100644 100644 8a6e397be49d2632f2e4e5c624eb781ae852b787 8a6e397be49d2632f2e4e5c624eb781ae852b787 um.txt\x00" ++
    "1 .M N... 100644 100644 100644 9495c3c5a31810439c36d49aad161b7f3db75d09 9495c3c5a31810439c36d49aad161b7f3db75d09 with space.txt\x00" ++
    "u AA N... 000000 100644 100644 100644 0000000000000000000000000000000000000000 b19a1e93bec1317dc6097229e12afaffbfa74dc2 950b81b7eee953d050aa05a641f8e056c85dd1bd aa.txt\x00" ++
    "u DU N... 100644 000000 100644 100644 37dc93f7c0cb2a9a454ded553b3cda499f949d17 0000000000000000000000000000000000000000 950b81b7eee953d050aa05a641f8e056c85dd1bd du.txt\x00" ++
    "u UD N... 100644 100644 000000 100644 11e6c5065a0a24b8cd9fc5b2fbae5db3e94c61a1 b19a1e93bec1317dc6097229e12afaffbfa74dc2 0000000000000000000000000000000000000000 ud.txt\x00" ++
    "u UU N... 100644 100644 100644 100644 1725e6630303461c56479543dedc4bc177dc5b57 b19a1e93bec1317dc6097229e12afaffbfa74dc2 950b81b7eee953d050aa05a641f8e056c85dd1bd uu.txt\x00" ++
    "? dir/new.txt\x00" ++
    "? héllo.txt\x00"

/-- The git implementation's status read in `/r` on `model`. -/
def gitStatus (model : JobModel) :
    Job.Outcome (Except VersionControl.Error VersionControl.Status) × JobModel :=
  (VersionControl.Git.handler "git" "/r" .status :
        JobM (Except VersionControl.Error VersionControl.Status)).runModel
    model

/-- The command the git implementation runs in `/r` with `arguments`: `git`,
with the editor's environment less `GIT_DIR`, `GIT_WORK_TREE` and
`GIT_INDEX_FILE`, and with optional locks off and pathspecs literal. -/
def gitRun (arguments : Array String) : Process.Command :=
  { program := "git", arguments, directory := "/r"
    environment :=
      { unset := #["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"]
        set := #[("GIT_OPTIONAL_LOCKS", "0"), ("GIT_LITERAL_PATHSPECS", "1")] } }

/-- The command a commit runs in `/r`: `git commit --file=- --cleanup=whitespace`,
with the environment of every git run but `GIT_LITERAL_PATHSPECS`. -/
def gitCommitRun : Process.Command :=
  { gitRun #["commit", "--file=-", "--cleanup=whitespace"] with
    environment :=
      { unset := #["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"]
        set := #[("GIT_OPTIONAL_LOCKS", "0")] } }

/-- The command a hunk's apply runs in `/r`, reversed for an unstage. -/
def gitApplyRun (reverse : Bool) : Process.Command :=
  gitRun
    (#["-c", "apply.whitespace=nowarn", "-c", "apply.ignoreWhitespace=false", "apply",
        "--cached"] ++
      (if reverse then #["--reverse"] else #[]) ++
      #["-"])

end ModelTest
