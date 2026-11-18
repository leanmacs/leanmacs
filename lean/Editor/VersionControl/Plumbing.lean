import Editor.VersionControl
import Editor.VersionControl.Porcelain

/-!
# Reading git's plumbing

The pure readers of what the git implementation's worktree, branch and
change runs print (`Editor/VersionControl/Git.lean`), beside the reader of
its status (`Editor/VersionControl/Porcelain.lean`). Each is tested on
output git printed, checked in as fixtures with the commands that made it
(`ModelTest.versionControlParserChecks`).

## The worktree list

`parseWorktrees` reads `git worktree list --porcelain -z`: records of
attributes, each attribute ended by a NUL and each record by one more.
With `-z` git never quotes a path.

| Attribute | Read as |
|---|---|
| `worktree <path>` | Its path, the rest of the attribute, so a space survives; first in every record |
| `branch refs/heads/<name>` | `.branch name` |
| `detached` | `.detached` |
| `bare` | A bare main repository, which is no worktree and is dropped |
| `HEAD <id>`, `locked`, `prunable` and any other | Ignored, as a later git may add some |

- The first record is the main worktree, kept first; the linked ones after
  it are sorted by path. When the main repository is bare, every record
  left is a linked worktree, sorted by path.
- A record with no `worktree` attribute first, or with neither a branch nor
  `detached` nor `bare`, and output that is not UTF-8, are refused.

## The branches

`parseBranches` reads `git for-each-ref --format=%(refname) refs/heads/`:
one full ref name a line, each `refs/heads/` stripped, sorted in byte
order. The full name is read, never `%(refname:short)`, which git
shortens differently when a tag shares the branch's name. A line outside
`refs/heads/` is refused.

## The raw diff

`parseRawDiff` reads `git diff-tree -r -z --no-renames <old> <new>`:
each change a record `:<old mode> <new mode> <old id> <new id> <status>`
and then its path, each ended by a NUL. Renames are off, so every status
is `A`, `M`, `D` or `T` (a type change) with one path. A change whose two
ids are equal changed its mode alone, kept its content, and is dropped.
A record with too few fields, a status that names two paths, a missing
path and output that is not UTF-8 are refused.

## The batch

`parseBatch` reads `git cat-file --batch`: for each id fed, `<id> <type>
<size>`, a line feed, exactly `size` bytes and a line feed. The content is
read by its size, so a blob holding a line feed or a NUL is whole. An id
git answers `missing`, an object that is not a blob, a header that cannot
be read and content cut short are refused.
-/

namespace Editor.VersionControl.Plumbing

/-- Reads the worktree records `records`, each a list of attributes. -/
def readWorktree (record : List String) : Except String (Option Worktree) := do
  let first :: rest := record | throw "an empty worktree record"
  unless first.startsWith "worktree " do
    throw s!"a worktree record that does not start with its path: {first.quote}"
  let path : System.FilePath := (first.drop "worktree ".length).toString
  if rest.contains "bare" then
    return none
  let branch :=
    rest.findSome? fun field =>
      if field.startsWith "branch " then
        let name := (field.drop "branch ".length).toString
        some
          (if name.startsWith "refs/heads/" then (name.drop "refs/heads/".length).toString
          else name)
      else none
  match branch with
  | some name =>
    return some { path, head := .branch name }
  | none =>
    if rest.contains "detached" then
      return some { path, head := .detached }
    else
      throw s!"a worktree record with no branch: {first.quote}"

/-- The records of `attributes`, split where an empty attribute ends one. -/
def splitRecords (attributes : List String) : List (List String) :=
  let (done, current) :=
    attributes.foldl
      (fun (done, current) field =>
        if field.isEmpty then if current.isEmpty then (done, current) else (done ++ [current], [])
        else (done, current ++ [field]))
      (([] : List (List String)), ([] : List String))
  if current.isEmpty then done else done ++ [current]

/-- `worktrees` sorted by path. -/
def byPath (worktrees : Array Worktree) : Array Worktree :=
  worktrees.qsort fun a b => decide (a.path.toString < b.path.toString)

/-- What `git worktree list --porcelain -z` printed, read ("The worktree
list", in the module docs), or why it cannot be read. -/
def parseWorktrees (bytes : ByteArray) : Except String (Array Worktree) := do
  let some attributes := Porcelain.records bytes | throw "an attribute is not UTF-8"
  match splitRecords attributes with
  | [] =>
    throw "there is no worktree"
  | first :: rest =>
    let linked := byPath ((← rest.mapM readWorktree).filterMap id).toArray
    match ← readWorktree first with
    | some main =>
      return #[main] ++ linked
    | none =>
      return linked

/-- The ref name every branch's full name starts with. -/
def headsPrefix : String :=
  "refs/heads/"

/-- What `git for-each-ref --format=%(refname) refs/heads/` printed, read
("The branches", in the module docs), or why it cannot be read. -/
def parseBranches (bytes : ByteArray) : Except String (Array String) := do
  let some text := String.fromUTF8? bytes | throw "a ref name is not UTF-8"
  let names ←
    ((text.splitOn "\n").filter (!·.isEmpty)).toArray.mapM fun line =>
        if line.startsWith headsPrefix then pure (line.drop headsPrefix.length).toString
        else throw s!"a ref outside {headsPrefix}: {line.quote}"
  return names.qsort fun a b => decide (a < b)

/-- One change `git diff-tree --raw` printed: each side's mode and id, its
status letter and its path. -/
structure RawChange where
  /-- The old side's mode, `000000` where it lacks the path. -/
  oldMode : String
  /-- The new side's mode, `000000` where it lacks the path. -/
  newMode : String
  /-- The old side's object id. -/
  oldId : String
  /-- The new side's object id. -/
  newId : String
  /-- The status letter: `A`, `M`, `D` or `T`. -/
  status : String
  /-- The path, relative to the repository's root. -/
  path : String
  deriving DecidableEq, Repr

/-- The mode of a side that lacks the path. -/
def absentMode : String :=
  "000000"

/-- The mode of a submodule's commit, a gitlink. -/
def gitlinkMode : String :=
  "160000"

/-- Reads the records `records`, a change's fields then its path, into
`changes`, through at most `fuel` records. -/
def readChanges : Nat → List String → Array RawChange → Except String (Array RawChange)
  | 0, _, changes => .ok changes
  | _, [], changes => .ok changes
  | _, [""], changes => .ok changes
  | fuel + 1, record :: rest, changes =>
    match (record.drop 1).toString.splitOn " ", rest with
    | [oldMode, newMode, oldId, newId, status], path :: rest =>
      if !record.startsWith ":" then
        .error s!"a change that does not start with ':': {record.quote}"
      else
        if !["A", "M", "D", "T"].contains status then
          .error s!"a change of status {status.quote}: {record.quote}"
        else
          if path.isEmpty then .error s!"a change with no path: {record.quote}"
          else
            let change := { oldMode, newMode, oldId, newId, status, path }
            readChanges fuel rest (if oldId == newId then changes else changes.push change)
    | _, _ => .error s!"a change that cannot be read: {record.quote}"

/-- What `git diff-tree -r -z --no-renames <old> <new>` printed, read ("The
raw diff", in the module docs), or why it cannot be read. -/
def parseRawDiff (bytes : ByteArray) : Except String (Array RawChange) := do
  let some records := Porcelain.records bytes | throw "a record is not UTF-8"
  readChanges (records.length + 1) records #[]

/-- The offset of the first line feed in `bytes` at or after `start`. -/
def lineEnd (bytes : ByteArray) (start : Nat) : Option Nat :=
  ((List.range (bytes.size - start)).find? fun offset => bytes.get! (start + offset) == 10).map
    (start + ·)

/-- Reads the objects of `bytes` from `start`, through at most `fuel`
objects. -/
def readObjects :
    Nat → ByteArray → Nat → Array (String × ByteArray) → Except String (Array (String × ByteArray))
  | 0, _, _, objects => .ok objects
  | fuel + 1, bytes, start, objects =>
    if start ≥ bytes.size then .ok objects
    else
      match lineEnd bytes start with
      | none => .error "a header with no line feed"
      | some stop =>
        match String.fromUTF8? (bytes.extract start stop) with
        | none => .error "a header that is not UTF-8"
        | some header =>
          match header.splitOn " " with
          | [id, "missing"] => .error s!"{id} is missing"
          | [id, kind, size] =>
            if kind != "blob" then .error s!"{id} is a {kind}, not a blob"
            else
              match size.toNat? with
              | none => .error s!"a header whose size cannot be read: {header.quote}"
              | some size =>
                let begin := stop + 1
                if begin + size + 1 > bytes.size || bytes.get! (begin + size) != 10 then
                  .error s!"{id}'s content is cut short"
                else
                  readObjects fuel bytes (begin + size + 1)
                    (objects.push (id, bytes.extract begin (begin + size)))
          | _ => .error s!"a header that cannot be read: {header.quote}"

/-- What `git cat-file --batch` printed, read as each object's id and its
bytes ("The batch", in the module docs), or why it cannot be read. -/
def parseBatch (bytes : ByteArray) : Except String (Array (String × ByteArray)) :=
  readObjects (bytes.size + 1) bytes 0 #[]

end Editor.VersionControl.Plumbing
