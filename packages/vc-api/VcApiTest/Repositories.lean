import VcApi
import VcApiTest.Fake

/-!
# vc-api's test support: Repositories

A repository of `vc-api`'s fake, the pure model (`VcApiTest/Fake.lean`),
with a file in every state, and the status it stands for: shared by the
fake's tests (`VcApiTest/VcApiTest/Fake.lean`) and version control's,
whose git fixtures print it (`VersionControlTest/Support/Git.lean`, in the
`version-control` package). It holds no
checks of its own. Published with the fake as `vc-api`'s test support, so
a package's tests may import it, and it imports no core test module.
-/

namespace VcApiTest

open Editor

/-- A status of every state a file can be in, sorted by path: what git's
porcelain of the mixed repository stands for (`VersionControlTest.porcelainMixed`). -/
def mixedStatus : VersionControl.Status :=
  { head := .branch "main"
    files :=
      #[{ path := "aa.txt", state := .conflicted .bothAdded },
        { path := "added.txt", state := .changed (some .added) none },
        { path := "deleted.txt", state := .changed (some .deleted) none },
        { path := "dir/new.txt", state := .untracked },
        { path := "du.txt", state := .conflicted .deletedByUs },
        { path := "gone.txt", state := .changed none (some .deleted) },
        { path := "héllo.txt", state := .untracked },
        { path := "mm.txt", state := .changed (some .modified) (some .modified) },
        { path := "new.txt", state := .renamed "old.txt" none },
        { path := "sm.txt", state := .changed (some .modified) none },
        { path := "ud.txt", state := .conflicted .deletedByThem },
        { path := "um.txt", state := .changed none (some .modified) },
        { path := "uu.txt", state := .conflicted .bothModified },
        { path := "with space.txt", state := .changed none (some .modified) }] }

/-- A model repository with a file in every state, whose status is
`mixedStatus`. -/
def mixedRepository : VersionControl.Model.Repository :=
  { committed :=
      #[("deleted.txt", "d"), ("du.txt", "base"), ("gone.txt", "g"), ("mm.txt", "m"),
        ("old.txt", "old"), ("sm.txt", "s"), ("ud.txt", "base"), ("um.txt", "u"),
        ("uu.txt", "base"), ("with space.txt", "space")]
    index :=
      #[("aa.txt", .conflict none (some "ours") (some "theirs")), ("added.txt", .file "added"),
        ("du.txt", .conflict (some "base") none (some "theirs")), ("gone.txt", .file "g"),
        ("mm.txt", .file "staged"), ("new.txt", .file "old"), ("sm.txt", .file "staged"),
        ("ud.txt", .conflict (some "base") (some "ours") none), ("um.txt", .file "u"),
        ("uu.txt", .conflict (some "base") (some "ours") (some "theirs")),
        ("with space.txt", .file "space")]
    worktree :=
      #[("aa.txt", "x"), ("added.txt", "added"), ("dir/new.txt", "new"), ("du.txt", "theirs"),
        ("héllo.txt", "h"), ("mm.txt", "both"), ("new.txt", "old"), ("sm.txt", "staged"),
        ("ud.txt", "ours"), ("um.txt", "unstaged"), ("uu.txt", "x"),
        ("with space.txt", "changed")] }

end VcApiTest
