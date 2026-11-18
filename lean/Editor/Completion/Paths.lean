import Editor.Completion.Later
import Editor.TypedPath

/-!
# File names: the source a file prompt lists

The completion source of the category `file` (`Paths.category`): the
entries of the directory typed so far, as Emacs's `find-file` under Doom's
vertico lists them. It is written against the interfaces as any package
would write it: a source that answers later (`Editor/Completion/Later.lean`),
asked again when the directory part changes, and nothing of its own in the
minibuffer or the loop. `open-file` and `edit-file` ask with it
(`Files.askPath`, `Editor/Files.lean`).

## The source and its job

- **`Paths.source`**, called `files`, answers later from the job `files`
  (`Paths.job`, `Paths.gather`), asked again when the text through its last
  `/` changes (`Reask.beforeLast '/'`), at once: typing within one
  directory reads it once, and an answer for another directory is not
  listed.
- **The job** (`gather`) splits the typed text at its last `/`
  (`TypedPath.split`), tidies the directory part (`TypedPath.tidy`: a
  restart after `//` or `/~/`, `.` and `..`), expands it under the query's
  place (`TypedPath.expand`, `Completion.Place`: the asking view's
  directory and the home), lists that one directory (`File.list`, the job
  port's file request) and delivers the entries in batches of at most
  `batchSize`. It reads nothing else. A directory that cannot be expanded
  or listed throws `cannot list <shown>: <why>`, which the echo area says
  (`StateRequest.sourceFailed`), `<shown>` being the tidied directory part,
  or `./` for none.
- **The order** (`ordered`): directories first, then files and the rest,
  each group by name ignoring case, then by bytes. It is the order before
  matching: the listing for an empty last component, and the tie-break of
  the fuzzy style.
- **A candidate** (`candidate`) is written under the tidied directory, so
  inserting it tidies the input. A directory's text ends in `/`, its label
  is its name and a `/`, its annotation `directory`, its kind `directory`,
  and it is partial (`Candidate.isPartial`): `RET` on it goes into it. A
  file's label is its name and its kind `file`; anything else's kind is
  `other`. The label ends the text, so the display draws the matched ranges
  of the last component on it.
- **Hidden entries.** A name that starts with `.` is hidden until the last
  component typed starts with `.` (`Candidate.hiddenUntil`): the listing's
  projection leaves it out until then, from the same one read.

## Where an addition goes

| Addition | Where | Pinned by |
|---|---|---|
| Another field of a candidate | `candidate` | `ModelTest.pathsChecks` |
| Another order | `ordered` | `ModelTest.pathsChecks` |
| Another rule for what is hidden | `candidate`'s `hiddenUntil` | `ModelTest.pathsChecks` |
-/

namespace Editor.Completion

namespace Paths

/-- The category of file names: what a file prompt asks, and what the path
style is compiled code's default for. -/
def category : String :=
  "file"

/-- The name of the job that lists a directory for the source. -/
def job : String :=
  "files"

/-- The most entries one batch delivers. -/
def batchSize : Nat :=
  1000

/-- Whether `one` sorts before `other` by name, ignoring case, then by
bytes. -/
def nameBefore (one other : String) : Bool :=
  let (lowerOne, lowerOther) := (one.toLower, other.toLower)
  lowerOne < lowerOther || (lowerOne == lowerOther && one < other)

/-- `entries` in the order a file prompt lists them before matching:
directories first, then files and the rest, each group by name ignoring
case, then by bytes. -/
def ordered (entries : Array File.Entry) : Array File.Entry :=
  let directories := entries.filter (·.kind == .directory)
  let rest := entries.filter (·.kind != .directory)
  let sorted (group : Array File.Entry) :=
    group.qsort fun one other => nameBefore one.name other.name
  sorted directories ++ sorted rest

/-- The candidate of `entry`, written under the tidied directory part
`shown`: a directory's with a trailing `/`, annotated, partial; a name that
starts with `.` hidden until a `.` is typed. -/
def candidate (shown : String) (entry : File.Entry) : Candidate :=
  let hiddenUntil := if entry.name.startsWith "." then some "." else none
  match entry.kind with
  | .directory =>
    { text := shown ++ entry.name ++ "/", label := some (entry.name ++ "/")
      annotation := some "directory", kind := some "directory", isPartial := true, hiddenUntil }
  | .file =>
    { text := shown ++ entry.name, label := some entry.name, kind := some "file", hiddenUntil }
  | .other =>
    { text := shown ++ entry.name, label := some entry.name, kind := some "other", hiddenUntil }

/-- The job of the source: lists the directory part of the query's text,
read under its place, and delivers its entries in `ordered`'s order, in
batches of at most `batchSize`. A directory that cannot be read under the
place, or listed, throws `cannot list <shown>: <why>`. -/
def gather (query : Query) (deliver : Array Candidate → JobM Unit) : JobM Unit := do
  let (directory, _) := TypedPath.split query.text
  let shown := TypedPath.tidy directory
  let said := if shown.isEmpty then "./" else shown
  let path ←
    match TypedPath.expand shown query.place.directory query.place.home with
    | .ok path =>
      pure path
    | .error why =>
      throw s!"cannot list {said}: {why}"
  match ← File.list path with
  | .error error =>
    throw s!"cannot list {said}: {error.describe}"
  | .ok entries =>
    let candidates := (ordered entries).map (candidate shown)
    let mut start := 0
    while start < candidates.size do
      deliver (candidates.extract start (start + batchSize))
      start := start + batchSize

/-- The completion source `files`: the entries of the directory typed so
far, answered later by the job `files`, asked again when the directory part
changes. -/
def source : Source :=
  { name := "files", category, candidates := fun _ => pure #[]
    later := some { job, reask := .beforeLast '/' } }

/-- The completion sources file names ship as. -/
def shipped : Array Source :=
  #[source]

end Paths

end Editor.Completion
