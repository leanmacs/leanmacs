import Editor.FileJobs
import ModelTest.Check

/-!
# Model tests: `Editor/FileJobs.lean`

`fileJobChecks`: the names and the orders the loop starts the files
feature's jobs with, pure. The root module `ModelTest` runs them; its
module doc says what each shows. When the loop starts a check or a follow
is pinned by `ModelTest.loopFileJobChecks`, and what the jobs' commands do
by the files feature's `ModelTest.fileCommandChecks`.
-/

namespace ModelTest

open Editor

/-- Two files of a check, the second with a stamp before the epoch. -/
def checkedFiles : Array FileJobs.Checked :=
  #[{ buffer := ⟨2⟩, path := "/a/b.txt", stamp := { seconds := 3, nanoseconds := 4, size := 5 } },
    { buffer := ⟨0⟩, path := "/c", stamp := { seconds := -1, nanoseconds := 0, size := 0 } }]

/-- The checks of the file jobs' names and orders (`Editor/FileJobs.lean`). -/
def fileJobChecks : List Check :=
  [{  name :=
        "a check's files come back from the arguments the job is started with, in order, a stamp before the epoch among them; no file is an empty check, and arguments that are not a check's are none"
      run :=
        pure <|
          FileJobs.checkOfArguments? (FileJobs.checkArguments checkedFiles) == some checkedFiles &&
            FileJobs.checkOfArguments? (FileJobs.checkArguments #[]) == some #[] &&
            FileJobs.checkOfArguments? [.str "/c"] == none },
    { name :=
        "a follow order comes back from its arguments with the last stamp found and with none for a file that is gone; a stamp is three arguments, and arguments that are not an order are none"
      run :=
        pure <|
          let stamp : File.Stamp := { seconds := 7, nanoseconds := 8, size := 9 }
          let found : FileJobs.FollowOrder :=
            { buffer := ⟨1⟩, path := "/n.txt", stamp
              expected := some { stamp with size := 10 } }
          let gone : FileJobs.FollowOrder := { found with expected := none }
          FileJobs.FollowOrder.ofArguments? found.arguments == some found &&
            FileJobs.FollowOrder.ofArguments? gone.arguments == some gone &&
            FileJobs.stampArguments stamp == [.int 7, .nat 8, .nat 9] &&
            FileJobs.FollowOrder.ofArguments? (found.arguments.take 5) == none },
    { name :=
        "the names the loop runs and starts are the core's: `open-file`, `check-files` and `follow-file`"
      run :=
        pure <|
          FileJobs.openFileCommand == "open-file" && FileJobs.checkJob == "check-files" &&
            FileJobs.followJob == "follow-file" },
    { name :=
        "what the loop says of a first edit refused for a file changed on disk names `:e`, and for one gone `:w!`, each with the path"
      run :=
        pure <|
          FileJobs.changedOnDisk "/n.txt" ==
              "/n.txt changed on disk; :e reloads it, or edit again to keep this text" &&
            FileJobs.goneFromDisk "/n.txt" ==
              "/n.txt is gone from disk; :w! writes it again, or edit again to keep this text" }]

end ModelTest
