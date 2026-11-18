import Editor.Api
import Editor.Command.Call
import Editor.Mode
import Editor.VersionControl.Git
import Editor.VersionControl.Review
import Editor.VersionControl.Status
import Editor.VersionControl.Views

/-!
# The log buffer: `vc-log`

A branch's commits, newest first, one per line, magit's log as a buffer of
its own: a read-only buffer of generated text whose `activate` opens the
change of the commit on the cursor's line as a review buffer
(`Editor/VersionControl/Review.lean`). Written over the editor API
(`Editor/Api.lean`), the job port and the version-control interface's `log`
(`Editor/VersionControl.lean`), through its git implementation. As the
status buffer's, a read is the command that starts the job `vc-log-read`,
the job, which asks `log`, and the command it finishes with (`logShown`),
which writes the buffer. The commands, the job and the mode as compiled code
registers them are in `Editor/VersionControl/Compiled.lean`.

## The view

Pure, and tested on values (`LogView`):

- **Row 0** is `<label>: log of <revision>`.
- **Each commit** is a row, newest first, along first parents, as `log`
  answers: `<id8> <day> <subject> (<author>)`, the day the author time's
  date in UTC (`dayOf`, `Editor/VersionControl/Views.lean`). A merge is
  one row.
- **No commit** is the row `no commits`.
- **The limit**: the read asks for `Log.limit` (256) commits and one more;
  when the one more is there, the first `Log.limit` are shown and a last
  row says `more commits past <limit>`.
- **The commit on a row** is the shown one before it: row r ≥ 1 is commit
  r - 1 (`LogView.entryAt`); the head row, the last row and past it are
  none.

## The record

The log buffer's value `vc-log` (`LogRecord.localName`) is its root, its
revision and the id of each commit it shows, in row order.

## The commands

- **`vc-log`** (`logName`, and the ex name `vc-log`, which takes text: a
  revision, `HEAD` with none), in the focused buffer: under `vc-status`'s
  gate (`readOrder`), a buffer with no workspace, or one whose location
  cannot run commands, is said, and nothing starts; a revision that starts
  with `-` is refused before any job, as the interface refuses it
  (`Request.invalid?`), `vc-log: <why>`. Otherwise it starts `vc-log-read`,
  keyed `vc-log <location>` (`logKeyOf`), so a second read replaces the
  first. Its implementation is a parameter (`connect`, git's by default), so
  the model checks run the read over the interface's model
  (`Model.readHandler`).
- **What the read comes to** (`logShown`): a failure says `vc-log:
  <Error.describe>`. A log replaces the text of the workspace's buffer
  named `*vc-log: <label> <revision>*` that holds this log's record, each
  view keeping its cursor's row (`replace`), or makes one: read-only, given
  the workspace, in the mode `vc-log`. The record is written, and, but for
  a refresh, the buffer is shown where the display rules say for the opener
  `vc-log` and focused.
- **`vc-log-visit`** (`logVisitName`, the mode's `activate`): the commit on
  the cursor's row, whose change opens as a review buffer
  (`startCommitReview`), or `vc-log: no commit on this line`.
- **`vc-log-refresh`** (`logRefreshName`, the mode's `refresh`): reads the
  log of the record's revision again into the same buffer, unshown.
- Either in a buffer that is not a log buffer says `<command>: <buffer> is
  not a log buffer`.

## The mode

`vc-log` (`logMode`), read-only to editing commands: `refresh` is
`vc-log-refresh` and `activate` is `vc-log-visit`. No new role.

Pinned by `ModelTest.logViewChecks` on values, `ModelTest.logBufferChecks`
on the loop's driver over the editor's models and the model of a
repository, and `ContractTest.historyBufferChecks` over real git.
-/

namespace Editor.VersionControl

/-- The name `vc-log` is registered under, the opener its buffer is shown
for, and its job key's prefix. -/
def logName : String :=
  "vc-log"

/-- The name of the command that opens the change of the cursor's commit. -/
def logVisitName : String :=
  "vc-log-visit"

/-- The name of the command that reads the log again. -/
def logRefreshName : String :=
  "vc-log-refresh"

/-- The name of the job that reads a log. -/
def logReadJob : String :=
  "vc-log-read"

/-- The name of the log buffer's mode. -/
def logModeName : String :=
  "vc-log"

/-- How many commits a log buffer shows. -/
def Log.limit : Nat :=
  256

/-! ## The view -/

namespace LogView

/-- The row of `entry` ("The view", in the module docs). -/
def line (entry : LogEntry) : String :=
  s!"{shortId entry.id} {dayOf entry.authored.time} {entry.authored.subject} ({entry.authored.author})"

/-- The commits of `entries` a log shows: the first `limit`. -/
def shown (entries : Array LogEntry) (limit : Nat := Log.limit) : Array LogEntry :=
  entries.extract 0 limit

/-- The text of the log of `revision` in the workspace labelled `label`,
each row ended by a line feed ("The view", in the module docs). -/
def render (label revision : String) (entries : Array LogEntry) (limit : Nat := Log.limit) :
    String :=
  let rows :=
    if entries.isEmpty then #["no commits"]
    else
      (shown entries limit).map line ++
        if entries.size > limit then #[s!"more commits past {limit}"] else #[]
  String.join ((#[s!"{label}: log of {revision}"] ++ rows).toList.map (· ++ "\n"))

/-- The commit on row `row` of a log showing the commits `ids`: none on the
head row, or past the last. -/
def entryAt (ids : Array String) (row : Nat) : Option String :=
  match row with
  | 0 => none
  | row + 1 => ids[row]?

end LogView

/-! ## The record -/

/-- What a log buffer holds of its log ("The record", in the module docs). -/
structure LogRecord where
  /-- The repository's root. -/
  root : String
  /-- The revision logged. -/
  revision : String
  /-- The id of each commit shown, in row order from row 1. -/
  ids : Array String := #[]
  deriving DecidableEq, Repr

/-- The name of the log buffer's value that holds its record. -/
def LogRecord.localName : String :=
  "vc-log"

/-- A record as a tree. -/
def LogRecord.encode (record : LogRecord) : Value :=
  .record
    [("root", .str record.root), ("revision", .str record.revision),
      ("ids", .list (record.ids.toList.map .str))]

/-- The record a tree is (`LogRecord.encode`), if it is one. -/
def LogRecord.decode? : Value → Option LogRecord
  | .record [("root", .str root), ("revision", .str revision), ("ids", .list ids)] => do
    let ids ←
      ids.toArray.mapM fun
          | .str id => some id
          | _ => none
    return { root, revision, ids }
  | _ => none

/-- The record of the log buffer `id` in `state`, if it is one. -/
def logRecordOf (state : EditorState) (id : BufferId) : Option LogRecord :=
  (state.value? id LogRecord.localName).bind LogRecord.decode?

/-! ## The commands -/

/-- What a read of a log is started with. -/
structure LogOrder where
  /-- The repository's root, the workspace's. -/
  root : System.FilePath
  /-- The git program. -/
  git : String
  /-- The workspace's label. -/
  label : String
  /-- The view that asked. -/
  view : ViewId
  /-- The revision to log. -/
  revision : String
  /-- Whether the buffer is shown once it is written: not for a refresh. -/
  shows : Bool := true
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with. -/
def LogOrder.arguments (order : LogOrder) : List Argument :=
  [.str order.root.toString, .str order.git, .str order.label, .nat order.view.index,
    .str order.revision, .bool order.shows]

/-- The order `arguments` are, if they are one (`LogOrder.arguments`). -/
def LogOrder.ofArguments? : List Argument → Option LogOrder
  | [.str root, .str git, .str label, .nat view, .str revision, .bool shows] =>
    some { root, git, label, view := ⟨view⟩, revision, shows }
  | _ => none

/-- The job key of the log reads of the repository at `root`. -/
def logKeyOf (root : System.FilePath) : String :=
  s!"{logName} {(Location.local root).describe}"

/-- The name of the log buffer of `revision` in the workspace labelled
`label`. -/
def logBufferName (label revision : String) : String :=
  s!"*{logName}: {label} {revision}*"

/-- Starts the log read of `order`, keyed by its root; a refused start is
said. -/
def startLog (order : LogOrder) : EditorM Unit := do
  if let .error refusal←
      startJob logReadJob order.arguments (key := some (logKeyOf order.root)) then
    message s!"{logName}: {refusal.describe}"

/-- The command a finished log read hands the loop ("What the read comes
to", in the module docs). -/
def logShown (order : LogOrder) (reply : Except Error (Array LogEntry)) : EditorM Unit := do
  match reply with
  | .error error =>
    message s!"{logName}: {error.describe}"
  | .ok entries =>
    let state ← editorState
    let name := logBufferName order.label order.revision
    let record : LogRecord :=
      { root := order.root.toString, revision := order.revision
        ids := (LogView.shown entries).map (·.id) }
    let content := LogView.render order.label order.revision entries
    let kept :=
      (state.findBuffer name).filter fun id =>
        (logRecordOf state id).any fun held =>
          held.root == record.root && held.revision == record.revision
    let id ←
      match kept with
      | some id =>
        replace id content
        pure id
      | none =>
        let some id ← readOnlyBufferOf name content (.local order.root) | return
        discard <| id.setMajorMode logModeName
        pure id
    discard <| id.setValue LogRecord.localName record.encode
    if order.shows then
      displayFor id order.view logName

/-- The log read job: asks the implementation `connect` makes of its order's
git and root for the log of its revision, `Log.limit` commits and one more,
and finishes with what it comes to (`logShown`). It fails only for
arguments that are not a log order. -/
def logReadWork (connect : String → System.FilePath → Handler := Git.handler)
    (arguments : List Argument) : Work := fun _ => do
  let some order :=
    LogOrder.ofArguments? arguments | throw s!"{logReadJob}: its arguments are not a log order"
  return logShown order
      (← Program.runM (connect order.git order.root) (log order.revision (Log.limit + 1)))

/-- `vc-log` ("The commands", in the module docs). -/
def logCommand (call : Call) : EditorM Unit := do
  let text :=
    match call.arguments with
    | .str text :: _ => text.trimAscii.toString
    | _ => ""
  let revision := if text.isEmpty then "HEAD" else text
  let some read ← readOrder logName call | return
  if let some why := (Request.log revision 0).invalid? then
    message s!"{logName}: {why}"
    return
  startLog { root := read.root, git := read.git, label := read.label, view := read.view, revision }

/-- The log buffer `call` was made in and its record; said and `none`, as the
command `name` says it, when it is not a log buffer. -/
def logOf (call : Call) (name : String) : EditorM (Option LogRecord) := do
  match logRecordOf (← editorState) call.target.window.buffer with
  | some record =>
    return some record
  | none =>
    message s!"{name}: {call.target.buffer.name} is not a log buffer"
    return none

/-- `vc-log-visit` ("The commands", in the module docs). -/
def logVisitCommand (call : Call) : EditorM Unit := do
  let some record ← logOf call logVisitName | return
  let some id :=
    LogView.entryAt record.ids (← cursorRowOf call) | message s!"{logName}: no commit on this line"
  let some read ← readOrder logVisitName call | return
  startCommitReview read.root read.git read.label read.view id

/-- `vc-log-refresh` ("The commands", in the module docs). -/
def logRefreshCommand (call : Call) : EditorM Unit := do
  let some record ← logOf call logRefreshName | return
  let some read ← readOrder logRefreshName call | return
  startLog
      { root := read.root, git := read.git, label := read.label, view := read.view
        revision := record.revision, shows := false }

/-- The `vc-log` mode ("The mode", in the module docs). -/
def logMode : Mode :=
  { name := logModeName, roles := [(Role.refresh, logRefreshName), (Role.activate, logVisitName)] }

end Editor.VersionControl
