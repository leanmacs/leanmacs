import Editor.File
import VcApi

/-!
# Reading git's history

The pure readers of what the git implementation's log, blame and range-diff
runs print (`Editor/VersionControl/Git.lean`), beside the readers of its
plumbing (`Editor/VersionControl/Plumbing.lean`). Each is tested on output
git printed, checked in as fixtures with the commands that made it
(`ModelTest.versionControlHistoryParserChecks`). Text is decoded by the
store's escape rule (`File.decodeBytes`), so a byte that is not UTF-8 is
kept as its escape.

## The log

`parseLog` reads `git rev-list` with
`--format=%H%x00%P%x00%an%x00%at%x00%s` and `--no-commit-header`: one
record a line, five fields separated by NULs, the commit's id, its parents
separated by spaces (none for a root), its author's name, its author time
in seconds and its subject. A record of another number of fields, a time
that is not all digits and an empty id are refused, the record quoted.

## The blame

`parseBlame` reads `git blame --porcelain`. Each line of the file is a
header `<id> <orig> <final> [<count>]`, then, the first time the commit is
named, its headers, of which `author`, `author-time` and `summary` are read
and every other (`previous`, `boundary`, `filename`, the committer's) is
ignored, then a tab and the line. Lines are placed by their final number,
which must be each of 1 to n exactly once; the commits are listed in the
order of their first line. A commit whose line comes before its `author`,
`author-time` and `summary` are read is refused, as is a header that cannot
be read. git's porcelain cannot tell a last line with no line feed, so a
line is read without one.

## The range-diff

`parseRangeDiff` reads `git range-diff --no-color`: a pair header is a line
with fewer than four leading spaces of the form `<n|->: <id|-...> <rel>
<n|->: <id|-...> <subject>`, its numbers padded to the widest, `<rel>` one of
`=`, `!`, `<` and `>`, `-` the side it is not in. Every line with four
leading spaces or more, and every empty line, is the text of a pair's diff
of diffs. Any other line is refused. The reply's text is the whole output.
-/

namespace Editor.VersionControl.HistoryRead

/-- The lines of `bytes` decoded by the store's escape rule, the empty last
one a final line feed leaves dropped. -/
def textLines (bytes : ByteArray) : List String :=
  let lines := (File.decodeBytes bytes).splitOn "\n"
  if lines.getLast? == some "" then lines.dropLast else lines

/-- One log record `record`, read ("The log", in the module docs). -/
def readLogRecord (record : String) : Except String LogEntry :=
  match record.splitOn "\x00" with
  | [id, parents, author, time, subject] =>
    if id.isEmpty then .error s!"a log record with no id: {record.quote}"
    else
      match time.toNat? with
      | none => .error s!"a log record whose time is not a number: {record.quote}"
      | some time =>
        .ok {
            id, parents := ((parents.splitOn " ").filter (!·.isEmpty)).toArray
            authored := { author, time, subject } }
  | _ => .error s!"a log record that is not five fields: {record.quote}"

/-- What the log run printed, read ("The log", in the module docs), or why it
cannot be read. -/
def parseLog (bytes : ByteArray) : Except String (Array LogEntry) :=
  (textLines bytes).toArray.mapM readLogRecord

/-- The commit a blame line's header names and its line's final number, and
what is read of the commit's headers so far. -/
structure BlameGroup where
  /-- The commit's id. -/
  id : String
  /-- The line's final number, from 1. -/
  final : Nat
  /-- The author, once read. -/
  author : Option String := none
  /-- The author time, once read. -/
  time : Option Nat := none
  /-- The subject, once read. -/
  subject : Option String := none

/-- The group a blame header `line` starts, or why it cannot be read. -/
def readBlameHeader (line : String) : Except String BlameGroup :=
  match line.splitOn " " with
  | [id, orig, final] | [id, orig, final, _] =>
    match orig.toNat?, final.toNat? with
    | some _, some final =>
      if id.isEmpty || final == 0 then .error s!"a blame header that cannot be read: {line.quote}"
      else .ok { id, final }
    | _, _ => .error s!"a blame header that cannot be read: {line.quote}"
  | _ => .error s!"a blame header that cannot be read: {line.quote}"

/-- `group` with the commit header `line` read into it: its author, author
time or subject; any other header ignored. -/
def readBlameField (group : BlameGroup) (line : String) : Except String BlameGroup :=
  if line.startsWith "author " then .ok { group with author := some (line.drop 7).toString }
  else
    if line.startsWith "author-time " then
      match (line.drop 12).toString.toNat? with
      | some time => .ok { group with time := some time }
      | none => .error s!"an author time that is not a number: {line.quote}"
    else
      if line.startsWith "summary " then .ok { group with subject := some (line.drop 8).toString }
      else if line == "summary" then .ok { group with subject := some "" } else .ok group

/-- What the blame run printed, read ("The blame", in the module docs), or
why it cannot be read. -/
def parseBlame (bytes : ByteArray) : Except String Blame := do
  let mut known : Array (String × Authored) := #[]
  let mut group : Option BlameGroup := none
  let mut placed : Array (Nat × BlameLine) := #[]
  for line in textLines bytes do
    match group with
    | none =>
      group := some (← readBlameHeader line)
    | some current =>
      if line.startsWith "\t" then
        unless known.any (·.1 == current.id) do
          match current.author, current.time, current.subject with
          | some author, some time, some subject =>
            known := known.push (current.id, { author, time, subject })
          | _, _, _ =>
            throw s!"commit {current.id} is named before its headers"
        placed := placed.push (current.final, { id := current.id, text := (line.drop 1).toString })
        group := none
      else
        group := some (← readBlameField current line)
  if let some current := group then
    throw s!"commit {current.id}'s line is missing"
  let sorted := placed.qsort fun a b => a.1 < b.1
  unless sorted.map (·.1) == (Array.range sorted.size).map (· + 1) do
    throw "the blamed lines are not each of 1 to n once"
  let lines := sorted.map (·.2)
  let commits :=
    lines.foldl
      (fun (commits : Array (String × Authored)) line =>
        if commits.any (·.1 == line.id) then commits
        else
          match known.find? (·.1 == line.id) with
          | some named => commits.push named
          | none => commits)
      #[]
  return { commits, lines }

/-- The side a range-diff header's number `field` names: its index, or none
for `-:`. -/
def readRangeIndex (field : String) : Option (Option Nat) :=
  if field == "-:" then some none
  else if field.endsWith ":" then ((field.dropEnd 1).toString.toNat?).map some else none

/-- The relation a range-diff header's mark names. -/
def readRelation : String → Option RangeRelation
  | "=" => some .same
  | "!" => some .changed
  | "<" => some .removed
  | ">" => some .added
  | _ => none

/-- The pair a range-diff header `line` names, or why it cannot be read. -/
def readRangePair (line : String) : Except String RangePair :=
  let refused : Except String RangePair :=
    .error s!"a range-diff line that cannot be read: {line.quote}"
  match (line.splitOn " ").filter (!·.isEmpty) with
  | old :: _ :: mark :: new :: _ :: _ =>
    match readRangeIndex old, readRelation mark, readRangeIndex new with
    | some old, some relation, some new =>
      let fits :=
        match relation with
        | .same | .changed => old.isSome && new.isSome
        | .removed => old.isSome && new.isNone
        | .added => old.isNone && new.isSome
      if fits then .ok { old, new, relation } else refused
    | _, _, _ => refused
  | _ => refused

/-- What the range-diff run printed, read ("The range-diff", in the module
docs), or why it cannot be read. -/
def parseRangeDiff (bytes : ByteArray) : Except String RangeDiff := do
  let pairs ←
    (textLines bytes).toArray.filterMapM fun line =>
        if line.isEmpty || line.startsWith "    " then pure none else some <$> readRangePair line
  return { pairs, text := File.decodeBytes bytes }

end Editor.VersionControl.HistoryRead
