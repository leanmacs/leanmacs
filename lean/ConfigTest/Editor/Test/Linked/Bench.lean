import ConfigTest.Check
import Editor.Test.Linked.Bench

/-!
# Config tests: `Editor/Test/Linked/Bench.lean`

The tests of the waits a benchmark's host is waited on with, on the lines
it printed (`Printed`, `Editor/Test/Linked/Bench.lean`): `benchWaitChecks`.
A job's end is the line after its posts' lines, or a line that is not
`ok`; a piece of work has run through once the fence is printed and every
job it started, the latest of each name, has ended, and a job started
after the fence is not waited for; the latest job of a name is found from
a start; and an armed wait is resolved by the note of the line that makes
it hold, and at once when it holds already. No host runs: the lines are
written here, and every note is made on the check's thread. The root
module `ConfigTest` runs them.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- What a key's step and its fence print in a prompt whose match runs off
the editor thread: the match job's start, the fence, and the match's end
once `delivered`. -/
def matchedKey (delivered : Bool) : Array String :=
  #["job 4 completion-match: started", "run noop: ok"] ++
    (if delivered then #["job 4 completion-match: ok"] else #[])

/-- The checks of a benchmark's waits on its host's lines. -/
def benchWaitChecks : List Check :=
  [{  name :=
        "a job's end is the line after its posts' lines, or one that is not ok: a source job's batch is not its end, and a failure is, whatever it posted"
      run := do
        let posted := #["job 2 words: started", "job 2 words: ok"]
        let ended := posted.push "job 2 words: ok"
        let failed := #["job 2 words: started", "job 2 words: failed: no words"]
        saw
            (startedJobs ended == #[("job 2 words", "words")] && !jobEnded posted "job 2 words" 1 &&
              jobEnded ended "job 2 words" 1 &&
              jobEnded posted "job 2 words" 0 &&
              jobEnded failed "job 2 words" 1 &&
              !jobEnded ended "job 3 words" 0)
            s!"started {startedJobs ended}" },
    { name :=
        "work has run through once its fence is printed and every job it started has ended; a job started after the fence is not waited for"
      run := do
        let before := #["reload 1: installed, 0 files, 2 commands"]
        let pending := before ++ matchedKey false
        let delivered := before ++ matchedKey true
        let unfenced := before ++ #["job 4 completion-match: started"]
        let later := delivered ++ #["job 5 completion-match: started"]
        saw
            (!ranThrough unfenced 1 1 && !ranThrough pending 1 1 && ranThrough delivered 1 1 &&
              ranThrough later 1 1 &&
              -- From a start past the job's, nothing is waited for.
              ranThrough pending 2 1 &&
              -- A fence searched for after the one printed is not there yet.
              !ranThrough delivered 1 4)
            s!"pending {pending}; delivered {delivered}" },
    { name :=
        "of the jobs of one name a piece of work started, the latest is waited for: a later start cancels the one before it, which ends with no line"
      run := do
        let superseded :=
          #["job 4 completion-match: started", "job 5 completion-match: started", "run noop: ok"]
        let posting :=
          #["job 6 words: started", "run noop: ok", "job 6 words: ok", "job 6 words: ok"]
        saw
            (!ranThrough superseded 0 0 &&
              ranThrough (superseded.push "job 5 completion-match: ok") 0 0 &&
              !ranThrough posting.pop 0 0 (posts := fun _ => 1) &&
              ranThrough posting 0 0 (posts := fun _ => 1))
            s!"superseded {superseded}; posting {posting}" },
    { name :=
        "the latest job of a name started from a start has run once its end is printed, and no job of that name started from it has not"
      run := do
        let lines :=
          #["job 1 words: started", "job 1 words: ok", "job 1 words: ok", "job 7 words: started",
            "job 7 words: ok"]
        saw
            (!jobRan lines 0 "words" 1 && jobRan (lines.push "job 7 words: ok") 0 "words" 1 &&
              jobRan lines 0 "words" 0 &&
              !jobRan lines 5 "words" 0 &&
              !jobRan lines 0 "other" 0)
            s!"lines {lines}" },
    { name :=
        "an armed wait on a benchmark's lines is resolved by the note of the line that makes it hold, and at once when it holds already"
      run := do
        let printed ← Printed.new
        let done (lines : Array String) : Bool := lines.contains "run noop: ok"
        let armed ← printed.arm done
        printed.note "job 4 completion-match: started"
        let early ← armed.isResolved
        printed.note "run noop: ok"
        let reached ← armed.isResolved
        let again ← printed.arm done
        let atOnce ← again.isResolved
        let waited ← printed.reaches hangGuard done
        saw (!early && reached && atOnce && waited && (← printed.size) == 2)
            s!"before the line {early}, after it {reached}; armed after it {atOnce}; reached {waited}" }]

end ConfigTest
