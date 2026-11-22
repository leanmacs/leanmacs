import VcApi
import VersionControl.Plumbing
import VersionControlTest.Check
import VersionControlTest.Git.Model

/-!
# Model tests: `VersionControl/Plumbing.lean`

The model tests of `VersionControl/Plumbing.lean`:
`versionControlPlumbingChecks`. The test driver's root,
`VersionControlTest/Model.lean`, runs them; its module doc says what each
shows.
-/

namespace VersionControlTest

open Editor

/-- What `git worktree list --porcelain -z` printed in `/d/r`, a main
checkout on `main` with three linked worktrees, made in a directory written
here `/d`: `git init r; cd r; echo a > a.txt; git add -A; g commit -m head;
git branch b; git branch feature/x`, then `git worktree add ../b-wt b; git
worktree add --detach "../a wt"; git worktree add ../gone -b gone; git
worktree lock ../b-wt --reason kept; rm -rf ../gone`. git lists the linked
ones by their administrative directories' names. -/
def worktreeListMixed : String :=
  "worktree /d/r\x00HEAD a655a818d91215d2e13ebd735265b112d61e150d\x00branch refs/heads/main\x00\x00" ++
    "worktree /d/a wt\x00HEAD a655a818d91215d2e13ebd735265b112d61e150d\x00detached\x00\x00" ++
    "worktree /d/gone\x00HEAD a655a818d91215d2e13ebd735265b112d61e150d\x00branch refs/heads/gone\x00prunable gitdir file points to non-existent location\x00\x00" ++
    "worktree /d/b-wt\x00HEAD a655a818d91215d2e13ebd735265b112d61e150d\x00branch refs/heads/b\x00locked kept\x00\x00"

/-- What `git worktree list --porcelain -z` printed in a bare repository
with one linked worktree: `git clone --bare r bare.git; cd bare.git; git
worktree add ../from-bare main`, in `/d`. -/
def worktreeListBare : String :=
  "worktree /d/bare.git\x00bare\x00\x00" ++
    "worktree /d/from-bare\x00HEAD a655a818d91215d2e13ebd735265b112d61e150d\x00branch refs/heads/main\x00\x00"

/-- What `git for-each-ref --format=%(refname) refs/heads/` printed in
`worktreeListMixed`'s repository. -/
def branchRefs : String :=
  "refs/heads/b\nrefs/heads/feature/x\nrefs/heads/gone\nrefs/heads/main\n"

/-- What `git diff-tree -r -z --no-renames <base> <next>` printed: `git init
sub` holding a commit, then `git init d; cd d`, `m.txt`, `d.txt`, `t.txt`,
`x.sh`, `with space.txt` and `héllo.txt` written and committed as `base`;
then `m.txt`, `with space.txt` and `héllo.txt` changed, `git rm d.txt`,
`a.txt` written, `t.txt` made a link to `m.txt`, `chmod +x x.sh`, `git
submodule add ../sub sub`, and all committed as `next`. -/
def rawDiffMixed : String :=
  ":000000 100644 0000000000000000000000000000000000000000 8688a8ca6cf509b12d9b25114e11207f53ac3fd1 A\x00.gitmodules\x00" ++
    ":000000 100644 0000000000000000000000000000000000000000 78981922613b2afb6025042ff6bd878ac1994e85 A\x00a.txt\x00" ++
    ":100644 000000 4bcfe98e640c8284511312660fb8709b0afa888e 0000000000000000000000000000000000000000 D\x00d.txt\x00" ++
    ":100644 100644 6e9f0da13f19b444ec3a9c3d6e795ad35c0554a2 c48b5634fe43460805dc0ca67824bbb970dd4b04 M\x00héllo.txt\x00" ++
    ":100644 100644 28ce6a8b26aa170e1de65536fe8abe1832bd3242 08bb2331e777f431177c40df6841c0034f89fb58 M\x00m.txt\x00" ++
    ":000000 160000 0000000000000000000000000000000000000000 99b40b2607860a2c0bd8347079713da7ea949dd3 A\x00sub\x00" ++
    ":100644 120000 718f4d2ff533cf8ead8d3556cf43912bd245fbc4 347bda8b202a5db796d1fe649680232fde0f6c3a T\x00t.txt\x00" ++
    ":100644 100644 f05367e3b20ebba4db1ac176615bde75d2fc1638 ae138b0b5c6ef541479c06869a3cc2fc78dc7350 M\x00with space.txt\x00" ++
    ":100644 100755 587be6b4c3f93f93c489c0111bba5596147a26cb 587be6b4c3f93f93c489c0111bba5596147a26cb M\x00x.sh\x00"

/-- What `git cat-file --batch` printed fed two ids, a line each: the blob of
`line\nwith\0nul\n` and the empty blob. -/
def batchTwo : ByteArray :=
  "b15bec5cc12be2d6c08c29b7fb19d58f8af19499 blob 14\nline\nwith".toUTF8 ++ ByteArray.mk #[0] ++
    "nul\n\ne69de29bb2d1d6434b8b29ae775ad8c2e48c5391 blob 0\n\n".toUTF8

/-- The checks of the readers of git's plumbing
(`VersionControl/Plumbing.lean`), on the fixtures. -/
def versionControlPlumbingChecks : List Check :=
  let raw (status oldMode newMode oldId newId path : String) : VersionControl.Plumbing.RawChange :=
    { oldMode, newMode, oldId, newId, status, path }
  let zero := VersionControl.Model.Repository.zeros
  let one := "1" ++ (zero.drop 1).toString
  [{  name :=
        "a worktree list reads as the main worktree first, then the linked ones in path order, each with its branch, a detached one as detached, a path with a space whole, locked and prunable ones kept"
      run :=
        pure <|
          (VersionControl.Plumbing.parseWorktrees worktreeListMixed.toUTF8).toOption ==
            some
              #[{ path := "/d/r", head := .branch "main" },
                { path := "/d/a wt", head := .detached },
                { path := "/d/b-wt", head := .branch "b" },
                { path := "/d/gone", head := .branch "gone" }] },
    { name := "a bare main repository is no worktree: only its linked worktree is listed"
      run :=
        pure <|
          (VersionControl.Plumbing.parseWorktrees worktreeListBare.toUTF8).toOption ==
            some #[{ path := "/d/from-bare", head := .branch "main" }] },
    { name :=
        "a worktree record that does not start with its path, or names no head, is refused, and so is no record"
      run :=
        pure <|
          VersionControl.Plumbing.parseWorktrees "HEAD 0\x00detached\x00\x00".toUTF8 matches
              .error _ &&
            VersionControl.Plumbing.parseWorktrees "worktree /d/r\x00HEAD 0\x00\x00".toUTF8 matches
              .error _ &&
            VersionControl.Plumbing.parseWorktrees ByteArray.empty matches .error _ },
    { name := "the branches read as their names, refs/heads/ stripped, one with / whole"
      run :=
        pure <|
          (VersionControl.Plumbing.parseBranches branchRefs.toUTF8).toOption ==
              some #["b", "feature/x", "gone", "main"] &&
            (VersionControl.Plumbing.parseBranches ByteArray.empty).toOption == some #[] &&
            VersionControl.Plumbing.parseBranches "refs/tags/v1\n".toUTF8 matches .error _ },
    { name :=
        "a raw diff reads as each change's modes, ids, status and path: added, deleted, modified, a gitlink, a type change, a path with a space and a non-ASCII path; a change of mode alone is dropped"
      run :=
        pure <|
          (VersionControl.Plumbing.parseRawDiff rawDiffMixed.toUTF8).toOption ==
            some
              #[raw "A" "000000" "100644" zero "8688a8ca6cf509b12d9b25114e11207f53ac3fd1"
                  ".gitmodules",
                raw "A" "000000" "100644" zero "78981922613b2afb6025042ff6bd878ac1994e85" "a.txt",
                raw "D" "100644" "000000" "4bcfe98e640c8284511312660fb8709b0afa888e" zero "d.txt",
                raw "M" "100644" "100644" "6e9f0da13f19b444ec3a9c3d6e795ad35c0554a2"
                  "c48b5634fe43460805dc0ca67824bbb970dd4b04" "héllo.txt",
                raw "M" "100644" "100644" "28ce6a8b26aa170e1de65536fe8abe1832bd3242"
                  "08bb2331e777f431177c40df6841c0034f89fb58" "m.txt",
                raw "A" "000000" "160000" zero "99b40b2607860a2c0bd8347079713da7ea949dd3" "sub",
                raw "T" "100644" "120000" "718f4d2ff533cf8ead8d3556cf43912bd245fbc4"
                  "347bda8b202a5db796d1fe649680232fde0f6c3a" "t.txt",
                raw "M" "100644" "100644" "f05367e3b20ebba4db1ac176615bde75d2fc1638"
                  "ae138b0b5c6ef541479c06869a3cc2fc78dc7350" "with space.txt"] },
    { name :=
        "a raw diff with a change that names no path, a rename's two paths, or too few fields is refused; no change at all is none"
      run :=
        pure <|
          VersionControl.Plumbing.parseRawDiff s!":100644 100644 {zero} {one} M\x00".toUTF8 matches
              .error _ &&
            VersionControl.Plumbing.parseRawDiff
                s!":100644 100644 {zero} {one} R100\x00a\x00b\x00".toUTF8 matches
              .error _ &&
            VersionControl.Plumbing.parseRawDiff ":100644 M\x00a\x00".toUTF8 matches .error _ &&
            (VersionControl.Plumbing.parseRawDiff ByteArray.empty).toOption == some #[] },
    { name :=
        "a batch reads each blob by its size, one holding a line feed and a NUL whole, and an empty one empty"
      run :=
        pure <|
          (VersionControl.Plumbing.parseBatch batchTwo).toOption ==
            some
              #[("b15bec5cc12be2d6c08c29b7fb19d58f8af19499",
                  "line\nwith".toUTF8 ++ ByteArray.mk #[0] ++ "nul\n".toUTF8),
                ("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", ByteArray.empty)] },
    { name :=
        "a batch naming an id missing, an object that is not a blob, or content cut short is refused"
      run :=
        pure <|
          VersionControl.Plumbing.parseBatch
                "0123456789012345678901234567890123456789 missing\n".toUTF8 matches
              .error _ &&
            VersionControl.Plumbing.parseBatch s!"{zero} tree 0\n\n".toUTF8 matches .error _ &&
            VersionControl.Plumbing.parseBatch s!"{zero} blob 9\nshort\n".toUTF8 matches .error _ }]

end VersionControlTest
