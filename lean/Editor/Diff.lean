import Editor.Diff.Script
import Editor.File

/-!
# A line diff, as a job asks for one

The data of the one diff request a job can make: the line diff of two
snapshots, answered with an edit script (`Diff.Script`,
`Editor/Diff/Script.lean`). It is a request of the job port
(`Editor/Job.lean`, `JobRequest.diff`), not of the text port, because a diff
is long computation and the editor thread never does that
(`docs/design/concurrency.md`, the threads table): the library's diff service
works it on a thread of its own, and only the script comes back, which a
command applies with `TextId.applyScript`. That is how a reload of a file
(`Files.reload`, `Editor/Files.lean`) turns the buffer's text into the
file's as one edit that keeps the cursor and the markers.

## The rules

- **Its sources** are `File.Source`s, as a save's is: a snapshot a command
  took, by its `SnapshotId`, or one this job holds, by its `JobSnapshotId`.
  A source that names no snapshot is refused with `noSuchSnapshot`, under
  the rule a save keeps: a snapshot a command released, and a
  `JobSnapshotId` this job does not hold.
- **The script** is one line diff of the two (`crates/editor-diff`):
  - the lines the two share at their start and at their end are stripped
    first, in linear time;
  - the engine is asked about what is left, the middle, only when each side
    of it is at most `limit` lines, and otherwise the middle is one hunk;
  - each changed hunk is trimmed to the longest common prefix and suffix
    that end on a character boundary of both texts, so a cursor in the
    unchanged head of a changed line stays put and no step starts or stops
    inside a character (an escape a load kept is one character);
  - matched lines are retained, and the rest is deleted or inserted. Equal
    texts give one retain.
- **The limit** is the editor's policy, as a load's is, and there is no
  default.
- **Which hunks an engine picks may differ** between the model
  (`Editor/Diff/Model.lean`, an LCS of lines) and the library's engine
  (imara-diff's histogram). The contract (`JobContract.diffProperties`)
  holds what both keep: the script gives the new text, keeps a block both
  texts share, keeps the common prefix and suffix, has one hunk over the
  limit, and steps only at character boundaries.
- **Errors are values**, as a file request's are.

## Adding to this

A new diff request is a constructor of `DiffRequest` with its case in
`DiffRequest.Reply`, and an operation in `Editor/Job.lean`. It needs a clause
in the model (`FileModel.diff`, which holds the snapshots it names), in the
fake and the real diff service of the job runner (`Editor/Job/Fake.lean`,
`Editor/Job/Real.lean`), and a property in `JobContract.diffProperties`.
-/

namespace Editor

/-- Why a diff was refused. -/
inductive DiffError where
  /-- A source names no snapshot: one a command released or never took, or
  one this job does not hold. -/
  | noSuchSnapshot
  /-- Anything else; `detail` says what. -/
  | failed (detail : String)
  deriving DecidableEq, Repr

/-- What a refusal says, as a sentence for a person. -/
def DiffError.describe : DiffError → String
  | .noSuchSnapshot => "the diff names no snapshot"
  | .failed detail => s!"the diff failed: {detail}"

/-- What a job may ask of the diff service. -/
inductive DiffRequest where
  /-- The line diff of what `old` and `new` hold, with the engine asked about
  at most `limit` lines a side. -/
  | lines (old new : File.Source) (limit : Nat)
  deriving DecidableEq, Repr

/-- The type of the reply to each diff request: a refusal or the script. -/
def DiffRequest.Reply : DiffRequest → Type
  | .lines .. => Except DiffError Diff.Script

/-- The reply of a refused request. -/
def DiffRequest.refused : (request : DiffRequest) → DiffError → request.Reply
  | .lines .., error => .error error

end Editor
