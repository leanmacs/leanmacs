import Editor.VersionControl

/-!
# Reading git's porcelain status

`parseStatus` reads what `git status --porcelain=v2 -z --branch
--untracked-files=all --find-renames` prints (`Editor/VersionControl/Git.lean`)
as a `Status`. It is pure, and tested on output git printed, checked in as
fixtures (`ModelTest.versionControlParserChecks`).

## The records

The output is records, each ended by a NUL; a trailing empty record is
allowed. Each record is UTF-8, or the whole output is refused.

| Record | Fields | Meaning |
|---|---|---|
| `# branch.head <name>` | | `.branch name` |
| `# branch.head (detached)` | | `.detached` |
| any other `# ...` header | | ignored |
| `1 XY sub mH mI mW hH hI path` | 7 fields after the kind, then the path | a change; the path is the rest of the record, so spaces survive |
| `2 XY sub mH mI mW hH hI Xscore path` | 8 fields after the kind, then the path | a rename; the next record is its origin. Only `R` is read: copies are never asked for |
| `u XY sub m1 m2 m3 mW h1 h2 h3 path` | 9 fields after the kind, then the path | a conflict |
| `? path` | | untracked |

- In `1` and `2` records, each of `X` (staged) and `Y` (unstaged) maps
  `.` to no change, `M` and `T` to `modified`, `A` to `added` and `D` to
  `deleted`.
- In a `u` record, `XY` names the conflict: `UU`, `AA`, `DD`, `AU`, `UA`,
  `DU` and `UD`.
- An unknown kind, an unknown `XY`, a rename with no origin after it, a
  record with too few fields or an empty path, and output with no
  `branch.head` header are refused, with the record quoted.
- The files are sorted as a status holds them (`VersionControl.sorted`):
  git lists conflicts and untracked files after the other changes.
-/

namespace Editor.VersionControl.Porcelain

/-- A change as `X` or `Y` of a `1` or `2` record says it: `none` for `.`,
and nothing for a letter it is not. -/
def change? : Char → Option (Option Change)
  | '.' => some none
  | 'M' => some (some .modified)
  | 'T' => some (some .modified)
  | 'A' => some (some .added)
  | 'D' => some (some .deleted)
  | _ => none

/-- A conflict as the `XY` of a `u` record says it. -/
def conflict? : String → Option Conflict
  | "UU" => some .bothModified
  | "AA" => some .bothAdded
  | "DD" => some .bothDeleted
  | "AU" => some .addedByUs
  | "UA" => some .addedByThem
  | "DU" => some .deletedByUs
  | "UD" => some .deletedByThem
  | _ => none

/-- The first `count` space-separated fields of `text` and the rest after
them, each field ended by one space; `none` when there are fewer, or when
the rest is empty. -/
def fields (count : Nat) (text : String) : Option (List String × String) :=
  let parts := text.splitOn " "
  if parts.length ≤ count then none
  else
    let rest := " ".intercalate (parts.drop count)
    if rest.isEmpty then none else some (parts.take count, rest)

/-- What a record that cannot be read is refused with: `why`, and the record
quoted. -/
def refused {α : Type} (why : String) (record : String) : Except String α :=
  .error s!"{why}: {record.quote}"

/-- Reads the records `records` into `head` and `files`, through at most
`fuel` records. -/
def readRecords :
    Nat → List String → Option Head → Array FileStatus → Except String (Option Head × Array FileStatus)
  | 0, _, head, files => .ok (head, files)
  | _, [], head, files => .ok (head, files)
  | fuel + 1, record :: rest, head, files =>
    if record.isEmpty then
      if rest.isEmpty then .ok (head, files) else refused "an empty record" record
    else
      if record.startsWith "# " then
        let header := (record.drop 2).toString
        if header.startsWith "branch.head " then
          let name := (header.drop "branch.head ".length).toString
          let head := if name == "(detached)" then Head.detached else .branch name
          readRecords fuel rest (some head) files
        else readRecords fuel rest head files
      else
        if record.startsWith "1 " then
          match fields 7 (record.drop 2).toString with
          | some (xy :: _, path) =>
            match xy.toList with
            | [x, y] =>
              match change? x, change? y with
              | some none, some none => refused "a change record that changes nothing" record
              | some staged, some unstaged =>
                readRecords fuel rest head (files.push { path, state := .changed staged unstaged })
              | _, _ => refused "a change record with an unknown XY" record
            | _ => refused "a change record with an unknown XY" record
          | _ => refused "a change record with too few fields" record
        else
          if record.startsWith "2 " then
            match fields 8 (record.drop 2).toString with
            | some (xy :: _, path) =>
              match xy.toList with
              | ['R', y] =>
                match change? y, rest with
                | some unstaged, origin :: rest =>
                  if origin.isEmpty then refused "a rename record with no origin" record
                  else
                    readRecords fuel rest head
                      (files.push { path, state := .renamed origin unstaged })
                | some _, [] => refused "a rename record with no origin" record
                | none, _ => refused "a rename record with an unknown XY" record
              | ['C', _] => refused "a copy record, though copies are never asked for" record
              | _ => refused "a rename record with an unknown XY" record
            | _ => refused "a rename record with too few fields" record
          else
            if record.startsWith "u " then
              match fields 9 (record.drop 2).toString with
              | some (xy :: _, path) =>
                match conflict? xy with
                | some how =>
                  readRecords fuel rest head (files.push { path, state := .conflicted how })
                | none => refused "a conflict record with an unknown XY" record
              | _ => refused "a conflict record with too few fields" record
            else
              if record.startsWith "? " then
                let path := (record.drop 2).toString
                if path.isEmpty then refused "an untracked record with no path" record
                else readRecords fuel rest head (files.push { path, state := .untracked })
              else refused "a record of an unknown kind" record

/-- The records of `bytes`: split on NUL, each decoded as UTF-8; `none` when
one is not UTF-8. -/
def records (bytes : ByteArray) : Option (List String) :=
  let (pieces, start) :=
    (List.range bytes.size).foldl (init := ((#[] : Array ByteArray), 0)) fun (pieces, start) at_ =>
      if bytes.get! at_ == 0 then (pieces.push (bytes.extract start at_), at_ + 1)
      else (pieces, start)
  let pieces := pieces.push (bytes.extract start bytes.size)
  pieces.toList.mapM String.fromUTF8?

/-- What `git status --porcelain=v2 -z --branch --untracked-files=all
--find-renames` printed, read as a status ("The records", in the module
docs), or why it cannot be read. -/
def parseStatus (bytes : ByteArray) : Except String Status := do
  let some records := records bytes | throw "a record is not UTF-8"
  let (head, files) ← readRecords (records.length + 1) records none #[]
  let some head := head | throw "there is no branch.head header"
  return { head, files := sorted files }

end Editor.VersionControl.Porcelain
