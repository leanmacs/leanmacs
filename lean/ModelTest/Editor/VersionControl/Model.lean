import Editor.Process
import Editor.VersionControl
import Editor.VersionControl.Contract
import Editor.VersionControl.Model
import Editor.VersionControl.Porcelain
import ModelTest.Check
import ModelTest.Support.Git

/-!
# Model tests: `Editor/VersionControl/Model.lean`

The model tests of `Editor/VersionControl/Model.lean`:
`versionControlModelChecks`. The root module `ModelTest` runs them; its module
doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the model of a repository
(`Editor/VersionControl/Model.lean`): its status of each state, how it
pairs renames, what its writes do, and that the real parser reads what its
printer prints as its status. -/
def versionControlModelChecks : List Check :=
  let pairs : VersionControl.Model.Repository :=
    { committed := #[("a.txt", "x"), ("b.txt", "x"), ("e.txt", "")]
      index := #[("c.txt", .file "x"), ("f.txt", .file ""), ("z.txt", .file "x")]
      worktree := #[("c.txt", "x"), ("f.txt", ""), ("z.txt", "x")] }
  let printed (repository : VersionControl.Model.Repository) : Bool :=
    (VersionControl.Porcelain.parseStatus repository.porcelain).toOption == some repository.status
  [{  name :=
        "the model's status of a repository in every state is each file with its state, sorted by path"
      run := pure (mixedRepository.status == mixedStatus) },
    { name :=
        "the model pairs renames as git does: the added paths in path order each take the first deleted path with their content, an empty file among them"
      run :=
        pure <|
          pairs.status.files ==
            #[{ path := "c.txt", state := .renamed "a.txt" none },
              { path := "f.txt", state := .renamed "e.txt" none },
              { path := "z.txt", state := .renamed "b.txt" none }] },
    { name := "a path deleted in the index and still on disk is a staged deletion and untracked"
      run :=
        pure <|
          ({ committed := #[("d.txt", "d")], worktree := #[("d.txt", "d")] } :
                VersionControl.Model.Repository).status.files ==
            #[{ path := "d.txt", state := .changed (some .deleted) none },
              { path := "d.txt", state := .untracked }] },
    { name := "a path in a rename's origin and on disk is untracked beside the rename"
      run :=
        pure <|
          ({ committed := #[("o.txt", "m")], index := #[("n.txt", .file "m")],
             worktree := #[("n.txt", "m"), ("o.txt", "m")] } :
                VersionControl.Model.Repository).status.files ==
            #[{ path := "n.txt", state := .renamed "o.txt" none },
              { path := "o.txt", state := .untracked }] },
    { name :=
        "staging a path in neither the index nor the working tree is refused with status 128, and nothing changes"
      run :=
        pure <|
          let repository :=
            VersionControlContract.writing (VersionControlContract.clean #[("a.txt", "one")])
              "a.txt" "two"
          let (reply, after) :=
            VersionControl.Model.handle (.stage #["a.txt", "nope.txt"]) repository
          reply matches .error (.failed (.code 128) _) && after == repository },
    { name := "the real parser reads what the model prints as the model's status, in every state"
      run :=
        pure <|
          printed mixedRepository && printed pairs &&
            printed { mixedRepository with head := .detached } &&
            printed { index := #[("a.txt", .file "a")], worktree := #[("a.txt", "a")] } },
    { name :=
        "the real parser reads what the model prints as the model's status, for every repository of the contract"
      run :=
        pure (VersionControlContract.properties.all fun property => printed property.repository) },
    { name :=
        "the model resolves HEAD and the checked-out branch to HEAD's commit while it is born, a branch to its commit, a tag and a commit's id to themselves, and nothing else"
      run :=
        pure <|
          let repository : VersionControl.Model.Repository :=
            { VersionControlContract.clean
                #[("a", "a")] with
              commits := #[("C", { files := #[] })], branches := #[("b", "C")]
              revisions := #[("v1", #[])] }
          let unborn : VersionControl.Model.Repository := {}
          ["HEAD", "main", "b", "v1", "C", "nope"].map repository.resolve ==
              [some "head", some "head", some "C", some "v1", some "C", none] &&
            unborn.resolve "HEAD" == none &&
            unborn.resolve "main" == none },
    { name :=
        "the model's merge base is the first of one commit's ancestors, breadth-first, that is the other's, and none for two with no common ancestor"
      run :=
        pure <|
          let repository :=
            VersionControlContract.forked #[] #[]
              #[("F", { parents := #["B"], files := #[] }),
                ("G", { parents := #["F"], files := #[] }), ("L", { files := #[] })]
              #[]
          repository.ancestors "G" == #["G", "F", "B"] &&
            repository.mergeBase "G" "head" == some "B" &&
            repository.mergeBase "head" "G" == some "B" &&
            repository.mergeBase "F" "G" == some "F" &&
            repository.mergeBase "L" "G" == none },
    { name :=
        "a commit in the model freezes HEAD's commit with its parents and who wrote it, and HEAD becomes a new commit whose parent it is, with the subject given; on an unborn branch nothing is frozen"
      run :=
        pure <|
          let repository :=
            VersionControlContract.writing (VersionControlContract.clean #[("a", "one")]) "a" "two"
          let after := (VersionControl.Model.Repository.stageOne repository "a").commit "next"
          let first := ({ index := #[("a", .file "a")] } : VersionControl.Model.Repository).commit
          after.commits ==
              #[("head",
                  { files := #[("a", "one")]
                    authored := { VersionControl.Model.fixedAuthored with subject := "head" } })] &&
            after.parents == #["head"] &&
            after.headId != "head" &&
            after.committed == #[("a", "two")] &&
            after.headAuthored.subject == "next" &&
            first.commits == #[] &&
            first.committed == #[("a", "a")] &&
            first.headAuthored.subject == "commit" },
    { name :=
        "a commit request keeps its message's subject as git's %s gives it: the first paragraph after any blank lines, each line's trailing white space dropped, its lines joined by a space"
      run :=
        pure <|
          let repository : VersionControl.Model.Repository :=
            { committed := #[("a", "one")], index := #[("a", .file "two")]
              worktree := #[("a", "two")] }
          let (reply, after) :=
            VersionControl.Model.handle (.commit "\n  Subject line  \nwraps here\t\n\nbody\n")
              repository
          let reply : Except VersionControl.Error Unit := reply
          let logged : Except VersionControl.Error (Array VersionControl.LogEntry) :=
            (VersionControl.Model.handle (.log "HEAD" 2) after).1
          reply == .ok () &&
            (logged.toOption.map fun entries => entries.map (·.authored.subject)) ==
              some #["  Subject line wraps here", "head"] }]

end ModelTest
