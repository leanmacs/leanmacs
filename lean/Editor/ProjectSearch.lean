import Editor.Grep
import Editor.Value

/-!
# Project search: the decisions

What `project-search` decides, as pure functions: the rows each excerpt of
a file's matches shows, the header above a file's first excerpt, where a
file's excerpts go in the results buffer, the record the results buffer
keeps, and the sentences the echo area says. The commands and the jobs that
use them are `Editor/ProjectSearch/Run.lean`; the search itself is the
library's, reached through the job port (`Editor/Grep.lean`).

- **Context**: `contextRows` rows each side of a match's row. Excerpts whose
  rows overlap are merged, as the review merges hunks (`ReviewSpan.group`):
  two matches exactly `2 * contextRows` rows apart share a row and are one
  excerpt; one row further apart they are two, one after the other.
- **A header** (`header`) is drawn above a file's first excerpt only: its path
  relative to the root, and how many matches its buffer's text holds.
- **The order is the walk's.** Each file the library finds gets the next
  sequence number of the record, and its excerpts go after those of every
  file before it in the walk that is placed (`Record.slot`), whatever order
  the files' buffers came to be ready in.
- **The record** (`Record`) is the results buffer's value `project-search`:
  the root, the label, the pattern, each file found, in walk order, as
  `pending` (its buffer is being loaded), `placed` in a buffer with so many
  excerpts, or `dropped` (it could not be loaded, or its text holds no match
  now), and the sentence the search ended with.
- **The limits** (`limits`) stop a search after 200 files with a match or
  2,000 matches: each matched file becomes a buffer, so the limit is what
  keeps a broad pattern from opening thousands of them.
-/

namespace Editor

namespace ProjectSearch

/-- How many rows each side of a match's row its excerpt shows. -/
def contextRows : Nat :=
  2

/-- Where a search stops: 200 files with a match or 2,000 matches, whichever
comes first. -/
def limits : Grep.Limits :=
  { files := 200, found := 2000 }

/-- How many matches a delivery of the search holds at most. -/
def bound : Nat :=
  200

/-- The rows the excerpts of matches on `matchRows`, in order, show in a text
of `rowCount` rows, each with `context` rows each side, clipped to the text:
each as its first and its last row. Excerpts whose rows overlap are one. -/
def excerptRows (matchRows : Array Nat) (context rowCount : Nat) : Array (Nat × Nat) :=
  if rowCount == 0 then #[]
  else
    matchRows.foldl (init := #[]) fun excerpts row =>
      let first := row - context
      let last := min (row + context) (rowCount - 1)
      match excerpts.back? with
      | some (start, stop) =>
        if first ≤ stop then excerpts.pop.push (start, max stop last)
        else excerpts.push (first, last)
      | none => excerpts.push (first, last)

/-- The header above a file's first excerpt: its path relative to the root,
and how many matches it holds. -/
def header (relative : String) (count : Nat) : String :=
  if count == 1 then s!"{relative} · 1 match" else s!"{relative} · {count} matches"

/-- `path` relative to `root`, or as it is when it is not under it. -/
def relative (root path : String) : String :=
  let lead := if root.endsWith "/" then root else root ++ "/"
  if path.startsWith lead then (path.drop lead.length).toString else path

/-- The name of the results buffer of a search of `pattern` in the workspace
labelled `label`: running the same search again reuses it. -/
def bufferName (pattern label : String) : String :=
  s!"*search: {pattern} in {label}*"

/-- `count` and the noun for it, singular for one. -/
def counted (count : Nat) (one many : String) : String :=
  if count == 1 then s!"1 {one}" else s!"{count} {many}"

/-- What the echo area says when a search ends complete. -/
def summary (found files : Nat) : String :=
  s!"project-search: {counted found "match" "matches"} in {counted files "file" "files"}"

/-- What the echo area says when a search stops at a limit. -/
def truncated (found files : Nat) : String :=
  s!"project-search: stopped after {counted found "match" "matches"} in {counted files "file" "files"}; narrow the pattern"

/-- What the echo area says when a search finds nothing. -/
def noMatch (pattern label : String) : String :=
  s!"project-search: no match for {pattern} in {label}"

/-- What the echo area says when a search is refused. -/
def refused (error : GrepError) : String :=
  s!"project-search: {error.describe}"

/-- Where a file found stands in the results buffer. -/
inductive FileState where
  /-- Its buffer is being loaded. -/
  | pending
  /-- It is placed: its buffer, by number, and how many excerpts it has. -/
  | placed (buffer excerpts : Nat)
  /-- It is not in the results: it could not be loaded, or its text holds no
  match now. -/
  | dropped
  deriving DecidableEq, Repr

/-- A file found, as the record keeps it. -/
structure FileEntry where
  /-- Its place in the walk, from 0. -/
  sequence : Nat
  /-- Its path. -/
  path : String
  /-- Where it stands. -/
  state : FileState
  deriving DecidableEq, Repr

/-- The record the results buffer keeps (its value `project-search`). -/
structure Record where
  /-- The root searched. -/
  root : String
  /-- The workspace's label. -/
  label : String
  /-- The pattern. -/
  pattern : String
  /-- Each file found, in walk order. -/
  files : Array FileEntry := #[]
  /-- The sentence the search ended with, once it has. -/
  ended : Option String := none
  /-- The snapshots of open buffers the search was started with, by index:
  released when it ends, or when the next search into the buffer starts. -/
  snapshots : Array Nat := #[]
  deriving DecidableEq, Repr

/-- The name of the results buffer's value that holds its record. -/
def Record.localName : String :=
  "project-search"

/-- The index in the results buffer's list where the excerpts of the file
`sequence` go: after every excerpt of a placed file earlier in the walk. -/
def Record.slot (record : Record) (sequence : Nat) : Nat :=
  record.files.foldl (init := 0) fun index file =>
    match file.state with
    | .placed _ excerpts => if file.sequence < sequence then index + excerpts else index
    | _ => index

/-- The file whose path is `path`, if the record has it. -/
def Record.find? (record : Record) (path : String) : Option FileEntry :=
  record.files.find? (·.path == path)

/-- `record` with the file `sequence` standing at `state`. -/
def Record.set (record : Record) (sequence : Nat) (state : FileState) : Record :=
  { record with
    files :=
      record.files.map fun file => if file.sequence == sequence then { file with state } else file }

/-- `record` with `path` added at the end of the walk, pending; as it was if
it has it, which a file cut across deliveries is. -/
def Record.add (record : Record) (path : String) : Record × Option Nat :=
  if (record.find? path).isSome then (record, none)
  else
    let sequence := record.files.size
    ({ record with files := record.files.push { sequence, path, state := .pending } },
      some sequence)

/-- A file's state as a tree. -/
def FileState.encode : FileState → Value
  | .pending => .str "pending"
  | .placed buffer excerpts => .record [("buffer", .nat buffer), ("excerpts", .nat excerpts)]
  | .dropped => .str "dropped"

/-- The state a tree is (`FileState.encode`), if it is one. -/
def FileState.decode? : Value → Option FileState
  | .str "pending" => some .pending
  | .str "dropped" => some .dropped
  | .record [("buffer", .nat buffer), ("excerpts", .nat excerpts)] => some (.placed buffer excerpts)
  | _ => none

/-- The record as a tree. -/
def Record.encode (record : Record) : Value :=
  .record
    [("root", .str record.root), ("label", .str record.label), ("pattern", .str record.pattern),
      ("files",
        .list
          (record.files.toList.map fun file =>
            .record
              [("sequence", .nat file.sequence), ("path", .str file.path),
                ("state", file.state.encode)])),
      ("ended",
        match record.ended with
        | some sentence => .str sentence
        | none => .null),
      ("snapshots", .list (record.snapshots.toList.map .nat))]

/-- The record a tree is (`Record.encode`), if it is one. -/
def Record.decode? : Value → Option Record
  |
  .record
      [("root", .str root), ("label", .str label), ("pattern", .str pattern),
        ("files", .list files), ("ended", ended), ("snapshots", .list snapshots)] =>
    do
    let files ←
      files.toArray.mapM fun
          | .record [("sequence", .nat sequence), ("path", .str path), ("state", state)] => do
            return { sequence, path, state := ← FileState.decode? state }
          | _ => none
    let ended ←
      match ended with
      | .str sentence =>
        some (some sentence)
      | .null =>
        some none
      | _ =>
        none
    let snapshots ←
      snapshots.toArray.mapM fun
          | .nat index => some index
          | _ => none
    return { root, label, pattern, files, ended, snapshots }
  | _ => none

end ProjectSearch

end Editor
