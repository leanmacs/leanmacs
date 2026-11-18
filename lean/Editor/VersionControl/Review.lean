import Editor.Api
import Editor.Command.Call
import Editor.Files
import Editor.Mode
import Editor.ModeLine
import Editor.Store
import Editor.VersionControl.Git
import Editor.VersionControl.Gutter
import Editor.VersionControl.ReviewHunks
import Editor.VersionControl.Stage
import Editor.VersionControl.Status

/-!
# The review buffer: `vc-review`

A branch's change against its base, hunk by hunk, each kept or reverted,
with what was not examined drawn so. It is an excerpt buffer
(`Editor/State.lean`, "Excerpt buffers") of the hunks of each changed
file: the base's lines a hunk removes, read from a read-only buffer of the
file at the merge base (the *old buffer*), and the hunk with its context,
read from the working file's buffer. Written over the editor API
(`Editor/Api.lean`), the job port, the diff service (`Diff.hunks`,
`Editor/Diff.lean`), the pure core (`Editor/VersionControl/ReviewHunks.lean`)
and the version-control interface's `worktrees` and `changes`
(`Editor/VersionControl.lean`), through its git implementation. The
commands, jobs, mode and segment as compiled code registers them are in
`Editor/VersionControl/Compiled.lean`.

## The command

`vc-review` (`reviewName`) takes text (the ex binding's `takes := .text`):
the branch to review the focused buffer's repository's `HEAD` against, or
none for the main worktree's branch. Its gate is `vc-status`'s
(`readOrder`, `Editor/VersionControl/Status.lean`): a buffer with no
workspace, or one whose location cannot run commands, is refused the same
way. A name that starts with `-` is refused before any job, as the
interface refuses it (`Request.invalid?`), with `vc-review: <why>`.
Otherwise it starts `vc-review-read`, keyed by the workspace
(`reviewKey`), so asking again replaces the read in flight.

## The pipeline

A command may not wait and a job may, so each step that asks git or the
diff service is a job, and each job's command does the next step:

1. **`vc-review-read`** (`reviewReadWork`). With no name it asks
   `worktrees` and takes the main worktree's branch; a detached main
   worktree says `vc-review: the main worktree is detached; name a branch
   to review against`. Then `changes "HEAD" <branch>`, and the load of
   each file with a new side under the root (`File.load`, under
   `Files.limit`). It finishes with `reviewRead`. Its implementation is a
   parameter (`connect`, git's by default), so the model checks run the
   read over the interface's model (`Model.readHandler`).
2. **`reviewRead`**: a failure says `vc-review: <Error.describe>`, and a
   change with no file `vc-review: no change against <branch>`. Otherwise
   each loaded file is taken into its buffer, the one that holds it or a
   new one, shown nowhere (`Files.adopt`); a file whose load was refused is
   left out, and named once the buffer is made. Each file with an old side
   gets an old buffer: `<path>@<the base's first 8 characters>`, or the
   first free name of that, holding the base's content, read-only, with no
   file, the workspace's, with its language and `code`, as `vc-show`'s is.
   It snapshots each old buffer and each working buffer, recording the
   working text's revision, an empty text standing for a side a file lacks,
   and starts `vc-review-diff` with them. A refused start releases every
   snapshot and removes the old buffers that no window shows.
3. **`vc-review-diff`** asks the hunks of each file's old side against its
   new side (`Diff.hunks`, under `Files.diffLineLimit`), and finishes with
   `reviewDiffed`.
4. **`reviewDiffed`** groups each file's hunks (`ReviewSpan.group`, over
   the snapshots), reads each side's whole text for the order, and then
   releases every snapshot, on every path. A diff refused says
   `vc-review: <DiffError.describe>`; a working buffer whose text moved
   since its snapshot says `vc-review: <path> changed while the review was
   read; run vc-review again`. Otherwise the files are ordered
   (`orderFiles`), each with the lines its spans change. With no hunk at
   all it says the files left out, or that there is no change. Otherwise
   the buffer is built ("Hunks and their excerpts"): a new one called
   `*vc-review: <label>*`, or the first free name of that, given the
   workspace, or, for a refresh, the kept one's list replaced
   (`BufferId.setExcerpts`). Its
   gutter, mode and record are set, the store written, and a new one shown
   where the display rules say for the opener `vc-review` and focused. A
   refresh then removes the previous round's old buffers that no window
   shows, and an old buffer no hunk of this round reads is removed. A round
   that ends before its buffer is built, on any path, removes the old
   buffers it made that no window shows (`reviewDiffed`).

The read and the diff are not one job because the working buffers must be
snapshotted on the editor thread once the files are taken in. The diff is
not keyed: a keyed restart would cancel a job whose command releases
snapshots.

## Hunks and their excerpts

Each review hunk (`ReviewSpan`) is one or two excerpts, each tracked
(`BufferExcerpt.tracked`), under one header:

- **The old excerpt**, when the hunk removes lines: the old buffer's range
  from the first removed line to the last (`ReviewSpan.oldExcerpt?`).
- **The new excerpt**, when the file exists on the branch: the working
  buffer's range of the hunk with its context. A deleted file has only its
  old excerpt, an added one only its new.
- **The header** is on the first of the two: the path and git's numbers
  (`ReviewSpan.header`), then two spaces and `kept` or `reverted` once
  decided (`ReviewHunk.headerText`).
- **The gutter** of the review buffer (`Buffer.gutter`) marks each added
  line `+` in `diff.added` and each removed line `-` in `diff.removed`, in
  the review text at its revision, so a view carries them through its
  edits.
- **The new text is the working file's buffer**: hunks are of the base's
  content against a snapshot of it, so uncommitted work on a changed file
  shows, and an edit typed in a new excerpt is an edit of that buffer. An
  old excerpt is read-only, as its buffer is.

## Keep and revert

In a review buffer only; elsewhere each says `<command>: <buffer> is not a
review buffer`. The cursor's hunk is the one whose excerpt holds the
cursor, both ends included (`Review.hunkAt`), over the review text's list;
with none, `vc-review: no hunk on this line`.

- **`vc-review-keep`** records `kept`: the header is rewritten
  (`BufferId.setExcerptHeaders`, which keeps what was viewed), the record
  and the store are written, and it says `kept a hunk of <path>`.
- **`vc-review-revert`** replaces the hunk's new excerpt, in the review
  text, with the old side of the hunk, context included, read from the old
  buffer, or the empty text for an added file: one edit through the
  excerpt text (`TextId.replaceRange`), so one transaction on the working
  buffer, and one step of the review buffer, which `u` in it takes back.
  The dispatcher's rules for an edit of an excerpt source apply, as for a
  typed edit (`Editor/Command/Dispatch.lean`, "Read-only buffers and
  excerpt sources"). Then it records `reverted` as keep does, and says
  `reverted a hunk of <path>`. A hunk with no new excerpt says
  `vc-review-revert: <path> is deleted on the branch; nothing to revert
  into`. **A recorded departure**: an undo of a revert takes the text back
  but leaves the decision `reverted`: the decision is what was chosen, not
  the text's state.

## The mode and the status line

The mode `vc-review` (`reviewMode`) fills the role `refresh` with
`vc-review-refresh`, which reads the change again, against the record's
branch, into the same buffer, and has the leader suffixes `k`
(`vc-review-keep`) and `r` (`vc-review-revert`). It is not read-only: the
buffer is edited in place.

The segment `review` (`reviewSegment`, `VersionControl.segments`) gives, in
a buffer with a record, one field in `mode-line.secondary`:
`<k> kept · <r> reverted · <n> not examined` (`Review.statusText`), a hunk
not examined while one of its excerpts has never been on screen; elsewhere
it gives none.

## The record

The live record of a review (`ReviewRecord`: its hunks, their excerpts and
decisions, its branch and base, its old buffers) is the review buffer's
value `vc-review` (`ReviewRecord.localName`), which the commands and the
segment read. Each workspace keeps a copy of each round in its store
(`reviewStore`, `ReviewStore`): the buffer's number and, for each round,
the branch, the base, and each hunk's path, header, decision and what was
viewed of each of its excerpts (`Buffer.Viewed`). A round is added at
each build and refresh, and the last one rewritten at each keep and
revert; the store keeps the last `Review.keptRounds`. It outlives the
buffer and a config reload, not a restart: writing it to disk is task
`review-record-on-disk`.

Pinned by `ModelTest.reviewBufferChecks` on the loop's driver over the
editor's models, the job model, the file model and the version-control
interface's model, and `ContractTest.reviewBufferChecks` over real git.
-/

namespace Editor.VersionControl

/-- The name `vc-review` is registered under, the opener its buffer is shown
for, and its job key's prefix. -/
def reviewName : String :=
  "vc-review"

/-- The name of the command that reads the change again into the review
buffer. -/
def reviewRefreshName : String :=
  "vc-review-refresh"

/-- The name of the command that keeps the cursor's hunk. -/
def reviewKeepName : String :=
  "vc-review-keep"

/-- The name of the command that reverts the cursor's hunk. -/
def reviewRevertName : String :=
  "vc-review-revert"

/-- The name of the job that reads the change and its files. -/
def reviewReadJob : String :=
  "vc-review-read"

/-- The name of the job that diffs each file. -/
def reviewDiffJob : String :=
  "vc-review-diff"

/-- The name of the review buffer's mode. -/
def reviewModeName : String :=
  "vc-review"

/-- How many rounds the store keeps. -/
def Review.keptRounds : Nat :=
  20

/-- The name of the review buffer of the workspace labelled `label`. -/
def reviewBufferName (label : String) : String :=
  s!"*{reviewName}: {label}*"

/-- The job key of the reads of the repository at `root`. -/
def reviewKey (root : System.FilePath) : String :=
  s!"{reviewName} {(Location.local root).describe}"

/-! ## The store -/

/-- One hunk of a round as the store keeps it. -/
structure ReviewStore.Hunk where
  /-- Its path. -/
  path : String
  /-- Its header, without the decision. -/
  header : String
  /-- What was decided. -/
  decision : Decision
  /-- What was viewed of each of its excerpts, the old one first. -/
  viewed : Array Buffer.Viewed
  deriving DecidableEq, Repr

/-- One round of a review as the store keeps it. -/
structure ReviewStore.Round where
  /-- The branch reviewed against. -/
  against : String
  /-- The merge base. -/
  base : String
  /-- Its hunks. -/
  hunks : Array ReviewStore.Hunk
  deriving DecidableEq, Repr

/-- What a workspace keeps of its reviews ("The record", in the module
docs). -/
structure ReviewStore where
  /-- The number of its last review buffer. -/
  buffer : Option Nat := none
  /-- The rounds, the last one last. -/
  rounds : Array ReviewStore.Round := #[]
  deriving DecidableEq, Repr

/-- What was viewed as a tree. -/
def encodeViewed (viewed : Buffer.Viewed) : Value :=
  .record
    [("scenes", .nat viewed.scenes), ("firstAt", encodeIndex viewed.firstAt),
      ("shownFor", .nat viewed.shownFor)]

/-- What was viewed a tree is (`encodeViewed`), if it is that. -/
def decodeViewed? : Value → Option Buffer.Viewed
  | .record [("scenes", .nat scenes), ("firstAt", firstAt), ("shownFor", .nat shownFor)] => do
    return { scenes, firstAt := ← decodeIndex? firstAt, shownFor }
  | _ => none

/-- A round's hunk as a tree. -/
def ReviewStore.Hunk.encode (hunk : ReviewStore.Hunk) : Value :=
  .record
    [("path", .str hunk.path), ("header", .str hunk.header), ("decision", .str hunk.decision.word),
      ("viewed", .list (hunk.viewed.toList.map encodeViewed))]

/-- The round's hunk a tree is, if it is one. -/
def ReviewStore.Hunk.decode? : Value → Option ReviewStore.Hunk
  |
  .record
      [("path", .str path), ("header", .str header), ("decision", .str decision),
        ("viewed", .list viewed)] =>
    do
    return {
        path, header, decision := ← Decision.ofWord? decision
        viewed := ← viewed.toArray.mapM decodeViewed? }
  | _ => none

/-- A round as a tree. -/
def ReviewStore.Round.encode (round : ReviewStore.Round) : Value :=
  .record
    [("against", .str round.against), ("base", .str round.base),
      ("hunks", .list (round.hunks.toList.map (·.encode)))]

/-- The round a tree is, if it is one. -/
def ReviewStore.Round.decode? : Value → Option ReviewStore.Round
  | .record [("against", .str against), ("base", .str base), ("hunks", .list hunks)] => do
    return { against, base, hunks := ← hunks.toArray.mapM ReviewStore.Hunk.decode? }
  | _ => none

/-- What a workspace keeps of its reviews as a tree. -/
def ReviewStore.encode (kept : ReviewStore) : Value :=
  .record
    [("buffer", encodeIndex kept.buffer), ("rounds", .list (kept.rounds.toList.map (·.encode)))]

/-- What a workspace keeps of its reviews a tree is, if it is that. -/
def ReviewStore.decode? : Value → Option ReviewStore
  | .record [("buffer", buffer), ("rounds", .list rounds)] => do
    return { buffer := ← decodeIndex? buffer,
             rounds := ← rounds.toArray.mapM ReviewStore.Round.decode? }
  | _ => none

/-- A workspace's record of its reviews. -/
def reviewStore : Store ReviewStore :=
  { name := "vc-review", version := 1, initial := {}, encode := ReviewStore.encode
    decode := ReviewStore.decode? }

/-- The round `record` is, with what `entries` say was viewed. -/
def ReviewStore.roundOf (record : ReviewRecord) (entries : Array Buffer.ExcerptEntry) :
    ReviewStore.Round :=
  { against := record.against, base := record.base
    hunks :=
      record.hunks.map fun hunk =>
        { path := hunk.path, header := hunk.header, decision := hunk.decision
          viewed := hunk.excerpts.map fun index => ((entries[index]?.bind (·.viewed)).getD {}) } }

/-- Writes the round of the review buffer `id`, whose record is `record`, to
its workspace's store: a new round when `fresh`, and otherwise in place of
the last when the store's last review is this buffer's; the oldest dropped
past `Review.keptRounds`. -/
def writeRound (id : BufferId) (record : ReviewRecord) (fresh : Bool) : EditorM Unit := do
  let state ← editorState
  let location := Location.local (System.FilePath.mk record.root)
  let entries := (((state.buffer? id).bind (·.excerpts)).map (·.entries)).getD #[]
  let kept := state.workspaces.get reviewStore location
  let round := ReviewStore.roundOf record entries
  let rounds :=
    if fresh || kept.buffer != some id.index || kept.rounds.isEmpty then kept.rounds.push round
    else kept.rounds.pop.push round
  let rounds := rounds.extract (rounds.size - Review.keptRounds) rounds.size
  discard <| Workspace.set reviewStore location { buffer := some id.index, rounds }

/-! ## The orders -/

/-- An optional buffer as a number: one more than its index, 0 for none. -/
def bufferNumber : Option BufferId → Nat
  | some id => id.index + 1
  | none => 0

/-- The optional buffer a number is (`bufferNumber`). -/
def numberBuffer (number : Nat) : Option BufferId :=
  if number == 0 then none else some ⟨number - 1⟩

/-- What a read of a review is started with. -/
structure ReviewOrder where
  /-- The repository's root, the workspace's. -/
  root : System.FilePath
  /-- The git program. -/
  git : String
  /-- The workspace's label. -/
  label : String
  /-- The view that asked. -/
  view : ViewId
  /-- The branch to review against; empty for the main worktree's. -/
  against : String
  /-- The review buffer to read into, for a refresh; none to make one. -/
  into : Option BufferId := none
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with. -/
def ReviewOrder.arguments (order : ReviewOrder) : List Argument :=
  [.str order.root.toString, .str order.git, .str order.label, .nat order.view.index,
    .str order.against, .nat (bufferNumber order.into)]

/-- The order at the start of `arguments`, if they start with one, and the
arguments after it. -/
def ReviewOrder.split? : List Argument → Option (ReviewOrder × List Argument)
  | .str root :: .str git :: .str label :: .nat view :: .str against :: .nat into :: rest =>
    some ({ root, git, label, view := ⟨view⟩, against, into := numberBuffer into }, rest)
  | _ => none

/-- The order `arguments` are, if they are one (`ReviewOrder.arguments`). -/
def ReviewOrder.ofArguments? (arguments : List Argument) : Option ReviewOrder :=
  match ReviewOrder.split? arguments with
  | some (order, []) => some order
  | _ => none

/-- One file of a review's diff: its path, the snapshots of its two sides,
its old buffer and its working buffer when it has them, and the working
text's revision at its snapshot. -/
structure ReviewFile where
  /-- Its path, relative to the root. -/
  path : String
  /-- The snapshot of its old side: the old buffer's, or an empty text. -/
  old : SnapshotId
  /-- The snapshot of its new side: the working buffer's, or an empty
  text. -/
  new : SnapshotId
  /-- Its old buffer, when it has an old side. -/
  oldBuffer : Option BufferId
  /-- Its working buffer, when it exists on the branch. -/
  working : Option BufferId
  /-- The working text's revision at its snapshot. -/
  revision : Nat
  deriving DecidableEq, Repr

/-- What a review's diff is started with: the read's order, its branch
resolved, the merge base, the paths left out, and the files. -/
structure ReviewDiffOrder where
  /-- The read's order, its `against` the branch reviewed against. -/
  order : ReviewOrder
  /-- The merge base's id. -/
  base : String
  /-- The paths whose load was refused. -/
  missing : Array String
  /-- The files to diff. -/
  files : Array ReviewFile
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with: the read's, the base,
how many paths are left out and each, then six for each file. -/
def ReviewDiffOrder.arguments (order : ReviewDiffOrder) : List Argument :=
  order.order.arguments ++ [.str order.base, .nat order.missing.size] ++
    order.missing.toList.map .str ++
    order.files.toList.flatMap fun file =>
      [.str file.path, .nat file.old.index, .nat file.new.index, .nat (bufferNumber file.oldBuffer),
        .nat (bufferNumber file.working), .nat file.revision]

/-- The files `arguments` are, six each, if they are. -/
def reviewFiles? : List Argument → Option (Array ReviewFile)
  | [] => some #[]
  | .str path :: .nat old :: .nat new :: .nat oldBuffer :: .nat working :: .nat revision :: rest =>
    (reviewFiles? rest).map fun files =>
      #[{ path, old := ⟨old⟩, new := ⟨new⟩, oldBuffer := numberBuffer oldBuffer,
          working := numberBuffer working, revision }] ++
        files
  | _ => none

/-- The order `arguments` are, if they are one (`ReviewDiffOrder.arguments`). -/
def ReviewDiffOrder.ofArguments? (arguments : List Argument) : Option ReviewDiffOrder := do
  let (order, rest) ← ReviewOrder.split? arguments
  let .str base :: .nat count :: rest := rest | none
  let missing ←
    (rest.take count).toArray.mapM fun
        | .str path => some path
        | _ => none
  guard (missing.size == count)
  return { order, base, missing, files := ← reviewFiles? (rest.drop count) }

/-- The snapshots `order` names, each released once. -/
def ReviewDiffOrder.release (order : ReviewDiffOrder) : EditorM Unit := do
  for file in order.files do
    file.old.release
    file.new.release

/-! ## The pipeline -/

/-- Starts the read of `order`, keyed by its root; a refused start is
said. -/
def startReview (order : ReviewOrder) : EditorM Unit := do
  if let .error refusal←
      startJob reviewReadJob order.arguments (key := some (reviewKey order.root)) then
    message s!"{reviewName}: {refusal.describe}"

/-- The record of the review buffer `id` in `state`, if it is one. -/
def reviewRecordOf (state : EditorState) (id : BufferId) : Option ReviewRecord :=
  (state.value? id ReviewRecord.localName).bind ReviewRecord.decode?

/-- The headers of an excerpt list of `count` entries of `record`: each
hunk's header text at its first excerpt, and none elsewhere. -/
def reviewHeaders (record : ReviewRecord) (count : Nat) : Array String :=
  record.hunks.foldl
    (fun headers hunk =>
      match hunk.excerpts[0]? with
      | some index => headers.setIfInBounds index hunk.headerText
      | none => headers)
    (Array.replicate count "")

/-- Makes the old buffer of `path` at `base`, holding `content` ("The
pipeline", in the module docs). -/
def oldBufferOf (root : System.FilePath) (path base content : String) : EditorM (Option BufferId) :=
  do
  let .ok id ←
    createBuffer ((← editorState).freeName s!"{path}@{(base.take 8).toString}")
        content | return none
  discard <| id.setReadOnly true
  Workspace.setBufferWorkspace id (.local root)
  if let some language← languageOf (root / path) then
    discard <| id.setLanguage (some language)
    discard <| id.setMajorMode Language.codeName
  return some id

/-- The groups of each file of `order` that has a hunk, by its diff of
`diffs` ("The pipeline", in the module docs): its spans, and the change as
the order reads it, each side's text from its snapshot; or the sentence
that says why there are none. -/
def reviewSpansOf (order : ReviewDiffOrder) (diffs : Array (Except DiffError Diff.Hunks)) :
    TextM (Except String (Array (ReviewFile × Array ReviewSpan × FileChange))) := do
  let mut read := #[]
  for (file, diff) in order.files.zip diffs do
    let hunks ←
      match diff with
      | .ok hunks =>
        pure hunks
      | .error error =>
        return .error s!"{reviewName}: {error.describe}"
    let old ← snapshotLines file.old
    let new ← snapshotLines file.new
    let spans ← ReviewSpan.group old new hunks
    if spans.isEmpty then
      continue
    let oldText ←
      if file.oldBuffer.isSome then
        some <$> file.old.slice 0 old.size
      else
        pure none
    let newText ←
      if file.working.isSome then
        some <$> file.new.slice 0 new.size
      else
        pure none
    read := read.push (file, spans, { path := file.path, old := oldText, new := newText })
  return .ok read

/-- The excerpts, the hunks and the gutter's marks of `read`, the files in
the policy's order ("Hunks and their excerpts", in the module docs): each
mark is the excerpt's index and a range of its source. -/
def reviewBuild (read : Array (ReviewFile × Array ReviewSpan × FileChange)) :
    Array BufferExcerpt × Array ReviewHunk × Array (Nat × Nat × Nat × GutterMark) :=
  let order :=
    Review.order (read.map fun (_, spans, change) => (change, spans.foldl (· + ·.changed) 0))
  order.foldl
    (fun (list, hunks, marks) index =>
      match read[index]? with
      | none => (list, hunks, marks)
      | some (file, spans, _) =>
        spans.foldl
          (fun (list, hunks, marks) span =>
            let header := span.header file.path
            let (list, marks, old?) :=
              match file.oldBuffer, span.oldExcerpt? with
              | some buffer, some (start, stop) =>
                (list.push { buffer, start, stop, header, tracked := true },
                  marks ++
                    span.removed.map fun (start, stop) =>
                      (list.size, start, stop,
                        { start, stop, text := "-", face := removedFace : GutterMark }),
                  some list.size)
              | _, _ => (list, marks, none)
            let (list, marks, new?) :=
              match file.working with
              | some buffer =>
                (list.push
                    { buffer, start := span.newStart, stop := span.newStop
                      header := if old?.isSome then "" else header, tracked := true },
                  marks ++
                    span.added.map fun (start, stop) =>
                      (list.size, start, stop,
                        { start, stop, text := "+", face := addedFace : GutterMark }),
                  some list.size)
              | none => (list, marks, none)
            (list,
              hunks.push
                { path := file.path, header, old?, new?, oldBuffer? := file.oldBuffer.map (·.index)
                  oldStart := span.oldStart, oldStop := span.oldStop },
              marks))
          (list, hunks, marks))
    (#[], #[], #[])

/-- The gutter of the review text `text`: each mark of `marks` moved from its
source range to where its excerpt is, sorted, at the text's revision. -/
def reviewGutter (text : TextId) (marks : Array (Nat × Nat × Nat × GutterMark)) :
    EditorM Buffer.Gutter := do
  let placed ← text.excerpts
  let moved :=
    marks.filterMap fun (index, start, stop, mark) =>
      placed[index]?.map fun excerpt =>
        { mark with
          start := start - excerpt.sourceStart + excerpt.start
          stop := stop - excerpt.sourceStart + excerpt.start }
  return { revision := ← text.revision, marks := moved.qsort (·.start < ·.start) }

/-- What is said of the paths `missing`, whose load was refused; none when
there are none. -/
def leftOut (missing : Array String) : Option String :=
  if missing.isEmpty then none
  else some s!"{reviewName}: left out {", ".intercalate missing.toList}: its load was refused"

/-- Removes each buffer of `olds` that no window shows. -/
def removeUnshown (olds : Array BufferId) : EditorM Unit := do
  for id in olds do
    let state ← editorState
    unless state.windows.any (·.buffer == id) do
      discard <| id.remove

/-- Removes the old buffers `order` made that no window shows: what a round
that ends before its review buffer is built does with them ("The pipeline",
in the module docs). -/
def ReviewDiffOrder.removeOlds (order : ReviewDiffOrder) : EditorM Unit :=
  removeUnshown (order.files.filterMap (·.oldBuffer))

/-- Builds the review buffer of `order` from `diffs`, or says why there is
none (`reviewDiffed`): whether it was built. -/
def reviewBuilt (order : ReviewDiffOrder) (diffs : Array (Except DiffError Diff.Hunks)) :
    EditorM Bool := do
  let read ←
    tryCatch (reviewSpansOf order diffs) fun error => do
        order.release
        throw error
  order.release
  let read ←
    match read with
    | .error sentence =>
      message sentence
      return false
    | .ok read =>
      pure read
  for file in order.files do
    if let some working := file.working then
      if let .ok text← working.text then
        if (← text.revision) != file.revision then
          message
              s!"{reviewName}: {file.path} changed while the review was read; run {reviewName} again"
          return false
  let against := order.order.against
  let (list, hunks, marks) := reviewBuild read
  if list.isEmpty then
    message ((leftOut order.missing).getD s!"{reviewName}: no change against {against}")
    return false
  let root := order.order.root
  let location := Location.local root
  let state ← editorState
  let previous := order.order.into.bind fun id => (reviewRecordOf state id).map (id, ·)
  let id ←
    match previous with
    | some (id, _) =>
      let .ok () ← id.setExcerpts list | return false
      pure id
    | none =>
      let .ok id ←
        createExcerptBuffer (state.freeName (reviewBufferName order.order.label))
            list | return false
      Workspace.setBufferWorkspace id location
      discard <| id.setMajorMode reviewModeName
      pure id
  let .ok text ← id.text | return false
  discard <| id.setGutter (some (← reviewGutter text marks))
  let used := hunks.filterMap (·.oldBuffer?)
  let olds := (order.files.filterMap (·.oldBuffer)).map (·.index)
  let record : ReviewRecord :=
    { root := root.toString, against, base := order.base, hunks, olds := olds.filter used.contains }
  discard <| id.setValue ReviewRecord.localName record.encode
  writeRound id record true
  -- An old buffer no hunk reads, and, for a refresh, the last round's, go
  -- unless a window shows them.
  let gone := olds.filter (!used.contains ·) ++ ((previous.map (·.2.olds)).getD #[])
  removeUnshown (gone.map (⟨·⟩))
  if previous.isNone then
    let state ← editorState
    let view := order.order.view
    let asking := if (state.window? view).isSome then view else state.frame.focused
    discard <| id.display asking reviewName
  if let some sentence := leftOut order.missing then
    message sentence
  return true

/-- The command a finished diff hands the loop ("The pipeline", in the module
docs): the review buffer built (`reviewBuilt`), or, on every other path, the
old buffers the round made removed unless a window shows them. -/
def reviewDiffed (order : ReviewDiffOrder) (diffs : Array (Except DiffError Diff.Hunks)) :
    EditorM Unit := do
  let built ←
    tryCatch (reviewBuilt order diffs) fun error => do
        order.removeOlds
        throw error
  unless built do
    order.removeOlds

/-- The diff job: the hunks of each file's old side against its new side, and
finishes with what they come to (`reviewDiffed`). It fails only for
arguments that are not a diff order. -/
def reviewDiffWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    ReviewDiffOrder.ofArguments?
      arguments | throw s!"{reviewDiffJob}: its arguments are not a review diff order"
  let mut diffs := #[]
  for file in order.files do
    diffs := diffs.push (← Diff.hunks (.snapshot file.old) (.snapshot file.new) Files.diffLineLimit)
  return reviewDiffed order diffs

/-- The command a finished read hands the loop ("The pipeline", in the module
docs): the files taken in, the old buffers made, every side snapshotted and
the diff started. -/
def reviewRead (order : ReviewOrder) (reply : Except String (String × Changes))
    (loads : Array (String × Except FileError File.Loaded)) : EditorM Unit := do
  let (against, changes) ←
    match reply with
    | .error why =>
      message s!"{reviewName}: {why}"
      return
    | .ok read =>
      pure read
  if changes.files.isEmpty then
    message s!"{reviewName}: no change against {against}"
    return
  let mut files := #[]
  let mut missing := #[]
  for change in changes.files do
    let working ←
      if change.new.isNone then
        pure none
      else
        match
          ((loads.find? (·.1 == change.path)).map (·.2) :
            Option (Except FileError File.Loaded)) with
        | some (.ok loaded) =>
          Files.adopt (order.root / change.path) loaded
        | _ =>
          pure none
    if change.new.isSome && working.isNone then
      missing := missing.push change.path
      continue
    let oldBuffer ←
      match change.old with
      | some content =>
        oldBufferOf order.root change.path changes.base content
      | none =>
        pure none
    if change.old.isSome && oldBuffer.isNone then
      missing := missing.push change.path
      continue
    let old ←
      match oldBuffer with
      | some id =>
        match ← id.text with
        | .ok text =>
          text.snapshot
        | .error _ =>
          snapshotOf ""
      | none =>
        snapshotOf ""
    let (new, revision) ←
      match working with
      | some id =>
        match ← id.text with
        | .ok text =>
          pure (← text.snapshot, ← text.revision)
        | .error _ =>
          pure (← snapshotOf "", 0)
      | none =>
        pure (← snapshotOf "", 0)
    files := files.push { path := change.path, old, new, oldBuffer, working, revision }
  let diff : ReviewDiffOrder :=
    { order := { order with against }, base := changes.base, missing, files }
  if let .error refusal← startJob reviewDiffJob diff.arguments then
    diff.release
    diff.removeOlds
    message s!"{reviewName}: {refusal.describe}"

/-- The read job: the branch to review against, the change of `HEAD` against
it and each changed file's load, asked of the implementation `connect`
makes of the order's git and root, git's by default; it finishes with what
they come to (`reviewRead`). It fails only for arguments that are not a
review order. -/
def reviewReadWork (connect : String → System.FilePath → Handler := Git.handler)
    (arguments : List Argument) : Work := fun _ => do
  let some order :=
    ReviewOrder.ofArguments?
      arguments | throw s!"{reviewReadJob}: its arguments are not a review order"
  let handler := connect order.git order.root
  let against : Except String String ←
    if order.against.isEmpty then
      match ← Program.runM handler worktrees with
      | .error error =>
        pure (.error error.describe)
      | .ok listed =>
        match (listed[0]?.map (·.head) : Option Head) with
        | some (.branch name) =>
          pure (.ok name)
        | _ =>
          pure (.error "the main worktree is detached; name a branch to review against")
    else
      pure (.ok order.against)
  let against ←
    match against with
    | .error why =>
      return reviewRead order (.error why) #[]
    | .ok against =>
      pure against
  match ← Program.runM handler (changes "HEAD" against) with
  | .error error =>
    return reviewRead order (.error error.describe) #[]
  | .ok changes =>
    let mut loads := #[]
    for file in changes.files do
      if file.new.isSome then
        loads := loads.push (file.path, ← File.load (order.root / file.path) Files.limit)
    return reviewRead order (.ok (against, changes)) loads

/-! ## The commands -/

/-- `vc-review` ("The command", in the module docs). -/
def reviewCommand (call : Call) : EditorM Unit := do
  let text :=
    match call.arguments with
    | .str text :: _ => text.trimAscii.toString
    | _ => ""
  let some read ← readOrder reviewName call | return
  if let some why := (Request.changes "HEAD" text).invalid? then
    message s!"{reviewName}: {why}"
    return
  startReview
      { root := read.root, git := read.git, label := read.label, view := read.view,
        against := text }

/-- The review buffer `call` was made in and its record; said and `none`, as
the command `name` says it, when it is not a review buffer. -/
def reviewOf (call : Call) (name : String) : EditorM (Option (BufferId × ReviewRecord)) := do
  let id := call.target.window.buffer
  match reviewRecordOf (← editorState) id with
  | some record =>
    return some (id, record)
  | none =>
    message s!"{name}: {call.target.buffer.name} is not a review buffer"
    return none

/-- The index of the hunk on `call`'s cursor among `record`'s, and the review
text's list; said and `none` when there is none ("Keep and revert", in the
module docs). -/
def cursorHunk (call : Call) (record : ReviewRecord) :
    EditorM (Option (Nat × Array Excerpt.Placed)) := do
  let selection ← call.target.selection
  let head := (selection.ranges[selection.primary]?.map (·.head)).getD 0
  let placed ← call.target.buffer.text.excerpts
  match Review.hunkAt placed record head with
  | some index =>
    return some (index, placed)
  | none =>
    message s!"{reviewName}: no hunk on this line"
    return none

/-- Records `decision` of the hunk `index` of the review buffer `id`, whose
record is `record`: its header rewritten, the record and the store
written. -/
def recordDecision (id : BufferId) (record : ReviewRecord) (index : Nat) (decision : Decision) :
    EditorM Unit := do
  let record := { record with hunks := record.hunks.modify index ({ · with decision }) }
  let count := ((((← editorState).buffer? id).bind (·.excerpts)).map (·.entries.size)).getD 0
  discard <| id.setExcerptHeaders (reviewHeaders record count)
  discard <| id.setValue ReviewRecord.localName record.encode
  writeRound id record false

/-- `vc-review-keep` ("Keep and revert", in the module docs). -/
def reviewKeepCommand (call : Call) : EditorM Unit := do
  let some (id, record) ← reviewOf call reviewKeepName | return
  let some (index, _) ← cursorHunk call record | return
  let some hunk := record.hunks[index]? | return
  recordDecision id record index .kept
  message s!"kept a hunk of {hunk.path}"

/-- `vc-review-revert` ("Keep and revert", in the module docs). -/
def reviewRevertCommand (call : Call) : EditorM Unit := do
  let some (id, record) ← reviewOf call reviewRevertName | return
  let some (index, placed) ← cursorHunk call record | return
  let some hunk := record.hunks[index]? | return
  let some excerpt :=
    hunk.new?.bind
      (placed[·]?) | message s!"{reviewRevertName}: {hunk.path} is deleted on the branch; nothing to revert into"
  let old ←
    match hunk.oldBuffer? with
    | some old =>
      match ← (⟨old⟩ : BufferId).text with
      | .ok text =>
        text.slice hunk.oldStart hunk.oldStop
      | .error _ =>
        message
            s!"{reviewRevertName}: the base's buffer of {hunk.path} is gone; run {reviewName} again"
        return
    | none =>
      pure ""
  call.target.buffer.text.replaceRange excerpt.start excerpt.stop old
  recordDecision id record index .reverted
  message s!"reverted a hunk of {hunk.path}"

/-- `vc-review-refresh` ("The mode and the status line", in the module
docs). -/
def reviewRefreshCommand (call : Call) : EditorM Unit := do
  let some (id, record) ← reviewOf call reviewRefreshName | return
  let some read ← readOrder reviewRefreshName call | return
  startReview
      { root := read.root, git := read.git, label := read.label, view := read.view
        against := record.against, into := some id }

/-- The review buffer's mode ("The mode and the status line", in the module
docs). -/
def reviewMode : Mode :=
  { name := reviewModeName, roles := [(Role.refresh, reviewRefreshName)]
    locals := [("k", reviewKeepName), ("r", reviewRevertName)] }

/-- The `review` segment ("The mode and the status line", in the module
docs). -/
def reviewSegment : Segment where
  name := "review"
  fields context :=
    match
      (context.buffer.locals.find? (·.1 == ReviewRecord.localName)).bind
        (ReviewRecord.decode? ·.2) with
    | some record =>
      #[ModeLine.field
          (Review.statusText record ((context.buffer.excerpts.map (·.entries)).getD #[]))
          ModeLine.secondaryFace]
    | none => #[]

end Editor.VersionControl
