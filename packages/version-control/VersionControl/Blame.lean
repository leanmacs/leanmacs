import Editor.Api
import Editor.Command.Call
import Editor.Mode
import VersionControl.Git
import VersionControl.Review
import VersionControl.Status
import VersionControl.Views

/-!
# Blame: `vc-blame`

Each line of a file with the commit that last changed it and that commit's
author, magit's blame as a buffer of its own: a read-only buffer of
generated text, one row per line of the file, whose `activate` opens the
change of the row's commit as a review buffer
(`VersionControl/Review.lean`). Written over the editor API
(`Editor/Api.lean`), the job port and the version-control interface's
`blame` (`Editor/VersionControl.lean`), through its git implementation. A
read is the command that starts the job `vc-blame-read`, the job, which
asks `blame`, and the command it finishes with (`blameShown`), which makes
the buffer. The commands, the job and the mode as compiled code registers
them are in `VersionControl/Compiled.lean`.

## The view

Pure, and tested on values (`BlameView`):

- **Row r is line r** of the file: there is no header row. Each is
  `<id8> <author> <day> | <line>`: the first 8 characters of the commit that
  last changed the line, its author cut at 16 characters and padded to the
  widest author of the view, the author time's date in UTC (`dayOf`,
  `VersionControl/Views.lean`), a bar, and the line without its line
  feed.
- **The commit on a row** is its line's (`BlameView.idAt`); past the last
  row there is none.

## The record

The blame buffer's value `vc-blame` (`BlameRecord.localName`) is its root,
its revision, its path and the id of each line's commit, in row order.

## The commands

- **`vc-blame`** (`blameName`, and the ex name `vc-blame`, which takes text:
  a revision, `HEAD` with none): blames the committed file at that revision,
  not the buffer's unsaved text. Its gate is `vc-show`'s: a buffer with no
  workspace, or one whose location cannot run commands, or with no file
  under its workspace's root (`relativeTo`), is said, as `vc-blame: <why>`;
  a revision that starts with `-` is refused before any job, as the
  interface refuses it (`Request.invalid?`). Otherwise it starts
  `vc-blame-read`, keyed `vc-blame <location> <revision>:<path>`, so asking
  again for the same file replaces the first ask. Its implementation is a
  parameter (`connect`, git's by default), so the model checks run the read
  over the interface's model (`Model.readHandler`).
- **What the read comes to** (`blameShown`): a failure says `vc-blame:
  <Error.describe>`, and `none` says `vc-blame: <path> is not in
  <revision>`. A blame makes a buffer `*vc-blame: <path>@<revision>*`, or
  the first free name of that: read-only, given the workspace, in the mode
  `vc-blame`, its record written, shown where the display rules say for the
  opener `vc-blame` and focused.
- **`vc-blame-visit`** (`blameVisitName`, the mode's `activate`): the
  commit on the cursor's row, whose change opens as a review buffer
  (`startCommitReview`), or `vc-blame: no commit on this line`. In a buffer
  that is not a blame buffer it says `vc-blame-visit: <buffer> is not a
  blame buffer`.

## The mode

`vc-blame` (`blameMode`), read-only to editing commands: `activate` is
`vc-blame-visit`. No new role.

Which lines an agent wrote, as against a person, waits for provenance
(`docs/design/review-and-navigation.md`, "History views").

Pinned by `VersionControlTest.blameViewChecks` on values,
`VersionControlTest.blameBufferChecks` on the loop's driver over the editor's models
and the model of a repository; what git does of each request is the
version-control contract's over real git
(`VersionControlTest.Linked.versionControlFailures`).
-/

namespace Editor.VersionControl

/-- The name `vc-blame` is registered under, the opener its buffer is shown
for, and its job key's prefix. -/
def blameName : String :=
  "vc-blame"

/-- The name of the command that opens the change of the cursor's row's
commit. -/
def blameVisitName : String :=
  "vc-blame-visit"

/-- The name of the job that reads a blame. -/
def blameReadJob : String :=
  "vc-blame-read"

/-- The name of the blame buffer's mode. -/
def blameModeName : String :=
  "vc-blame"

/-! ## The view -/

namespace BlameView

/-- How many characters of an author a row shows. -/
def authorWidth : Nat :=
  16

/-- `text` padded with spaces to `width` characters. -/
def padded (text : String) (width : Nat) : String :=
  text ++ String.ofList (List.replicate (width - text.length) ' ')

/-- The text of `blame`, each row ended by a line feed ("The view", in the
module docs). -/
def render (blame : Blame) : String :=
  let authoredOf (id : String) : Option Authored := (blame.commits.find? (·.1 == id)).map (·.2)
  let authorOf (id : String) : String :=
    (((authoredOf id).map (·.author)).getD "").take authorWidth |>.toString
  let widest := blame.lines.foldl (fun widest line => max widest (authorOf line.id).length) 0
  String.join
    (blame.lines.toList.map fun line =>
      let time := ((authoredOf line.id).map (·.time)).getD 0
      s!"{shortId line.id} {padded (authorOf line.id) widest} {dayOf time} | {line.text}\n")

/-- The commit on row `row` of a blame of the lines whose commits are `ids`;
none past the last. -/
def idAt (ids : Array String) (row : Nat) : Option String :=
  ids[row]?

end BlameView

/-! ## The record -/

/-- What a blame buffer holds of its blame ("The record", in the module
docs). -/
structure BlameRecord where
  /-- The repository's root. -/
  root : String
  /-- The revision blamed at. -/
  revision : String
  /-- The path blamed, relative to the root. -/
  path : String
  /-- The id of each line's commit, in row order. -/
  ids : Array String := #[]
  deriving DecidableEq, Repr

/-- The name of the blame buffer's value that holds its record. -/
def BlameRecord.localName : String :=
  "vc-blame"

/-- A record as a tree. -/
def BlameRecord.encode (record : BlameRecord) : Value :=
  .record
    [("root", .str record.root), ("revision", .str record.revision), ("path", .str record.path),
      ("ids", .list (record.ids.toList.map .str))]

/-- The record a tree is (`BlameRecord.encode`), if it is one. -/
def BlameRecord.decode? : Value → Option BlameRecord
  |
  .record
      [("root", .str root), ("revision", .str revision), ("path", .str path), ("ids", .list ids)] =>
    do
    let ids ←
      ids.toArray.mapM fun
          | .str id => some id
          | _ => none
    return { root, revision, path, ids }
  | _ => none

/-! ## The commands -/

/-- What a read of a blame is started with. -/
structure BlameOrder where
  /-- The repository's root, the workspace's. -/
  root : System.FilePath
  /-- The git program. -/
  git : String
  /-- The revision. -/
  revision : String
  /-- The path, relative to the root. -/
  path : String
  /-- The view that asked. -/
  view : ViewId
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with. -/
def BlameOrder.arguments (order : BlameOrder) : List Argument :=
  [.str order.root.toString, .str order.git, .str order.revision, .str order.path,
    .nat order.view.index]

/-- The order `arguments` are, if they are one (`BlameOrder.arguments`). -/
def BlameOrder.ofArguments? : List Argument → Option BlameOrder
  | [.str root, .str git, .str revision, .str path, .nat view] =>
    some { root, git, revision, path, view := ⟨view⟩ }
  | _ => none

/-- The job key of the blames of `path` at `revision` in the repository at
`root`. -/
def BlameOrder.key (order : BlameOrder) : String :=
  s!"{blameName} {(Location.local order.root).describe} {order.revision}:{order.path}"

/-- The command a finished blame read hands the loop ("What the read comes
to", in the module docs). -/
def blameShown (order : BlameOrder) (reply : Except Error (Option Blame)) : EditorM Unit := do
  match reply with
  | .error error =>
    message s!"{blameName}: {error.describe}"
  | .ok none =>
    message s!"{blameName}: {order.path} is not in {order.revision}"
  | .ok (some blame) =>
    let some id ←
      readOnlyBufferOf s!"*{blameName}: {order.path}@{order.revision}*" (BlameView.render blame)
          (.local order.root) | return
    discard <| id.setMajorMode blameModeName
    let record : BlameRecord :=
      { root := order.root.toString, revision := order.revision, path := order.path
        ids := blame.lines.map (·.id) }
    discard <| id.setValue BlameRecord.localName record.encode
    displayFor id order.view blameName

/-- The blame read job: asks the implementation `connect` makes of its
order's git and root for the blame of its path at its revision, and
finishes with what it comes to (`blameShown`). It fails only for arguments
that are not a blame order. -/
def blameReadWork (connect : String → System.FilePath → Handler := Git.handler)
    (arguments : List Argument) : Work := fun _ => do
  let some order :=
    BlameOrder.ofArguments?
      arguments | throw s!"{blameReadJob}: its arguments are not a blame order"
  return blameShown order
      (← Program.runM (connect order.git order.root) (blame order.revision order.path))

/-- `vc-blame` ("The commands", in the module docs). -/
def blameCommand (call : Call) : EditorM Unit := do
  let text :=
    match call.arguments with
    | .str text :: _ => text.trimAscii.toString
    | _ => ""
  let revision := if text.isEmpty then "HEAD" else text
  let some read ← readOrder blameName call | return
  let state ← editorState
  let some path :=
    ((state.buffer? call.target.window.buffer).bind (·.file)).bind fun file =>
      Gutter.relativeTo read.root
        file.path | message s!"{blameName}: {call.target.buffer.name} has no file in {read.label}"
  if let some why := (Request.blame revision path).invalid? then
    message s!"{blameName}: {why}"
    return
  let order : BlameOrder :=
    { root := read.root, git := read.git, revision, path, view := read.view }
  if let .error refusal← startJob blameReadJob order.arguments (key := some order.key) then
    message s!"{blameName}: {refusal.describe}"

/-- `vc-blame-visit` ("The commands", in the module docs). -/
def blameVisitCommand (call : Call) : EditorM Unit := do
  let some record :=
    ((← editorState).value? call.target.window.buffer BlameRecord.localName).bind
      BlameRecord.decode? | message s!"{blameVisitName}: {call.target.buffer.name} is not a blame buffer"
  let some id :=
    BlameView.idAt record.ids (← cursorRowOf call) | message s!"{blameName}: no commit on this line"
  let some read ← readOrder blameVisitName call | return
  startCommitReview read.root read.git read.label read.view id

/-- The `vc-blame` mode ("The mode", in the module docs). -/
def blameMode : Mode :=
  { name := blameModeName, roles := [(Role.activate, blameVisitName)] }

end Editor.VersionControl
