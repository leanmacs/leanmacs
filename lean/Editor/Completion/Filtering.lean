import Editor.Completion.Later
import Editor.Job

/-!
# Sources a command filters

A completion source that answers later (`Editor/Completion/Later.lean`)
whose job hands both the listing and the filtering to external programs,
as fzf.vim and Emacs's consult (`consult-fd`, `consult-ripgrep`) do: a
*lister*, whose standard output is the candidates, one a record, and a
*filter*, fed that output with the typed text as one of its arguments,
whose standard output is the matches, best first. Only the first `limit`
of them reach the prompt, so a list of 100,000 files is never passed to
Lean whole. It is written against the job port alone and knows nothing of
files or workspaces: which commands list and filter is the caller's
choice, per source.

## How it answers

- **The lister runs first** (`Process.runWithin`), its output held whole up
  to `listBytes` (64 MiB by default). A refusal, a time-out, or an exit
  that is not 0 fails the source, naming the program
  (`<program>: exited with status 2: <first line of stderr>`), unless the
  exit is in `partialListing`: a lister that declares one, as `find`'s 1
  past a directory it cannot read, still answers the records it printed.
  None is declared by default.
- **The filter is fed the lister's output** with the typed text appended to
  its arguments, as one argument. No shell sees it, so no text typed into
  a prompt can run a command.
- **The filter's output is read as a head** (`Process.runHead`): past
  `filterBytes` the filter is ended and its first `filterBytes` bytes are
  kept, so a filter given an empty text, which prints every candidate,
  still answers. A cut output's last record, which has no separator, is
  dropped, so every record answered is whole.
- **Records** split on a line feed or a NUL (`Separator`); an empty record,
  or one that is not UTF-8, is dropped.
- **An exit in `noMatches`** (fzf's 1 by default) answers no records, which
  is no failure. Any other exit that is not 0, and a refusal, fail the
  source, naming the filter's program: `fzf` not installed is said as
  that, never as an empty list.
- **It delivers one batch**, the first `limit` records, even an empty one,
  so an answer of no matches replaces the previous text's at once. A
  failure throws, and `Completion.answering` finishes the job with
  `StateRequest.sourceFailed`, which says `<source>: <message>`.
- **The source is filtered** (`Source.filtered`): its candidates are listed
  in the filter's order, none dropped, with the style's ranges where it
  matches (`Candidates.listing`, `Editor/Loop.lean`). It is asked again
  after a pause when the text changes (`Reask.afterPause`), so a new text
  cancels the job for the previous one.

## Where an addition goes

| Addition | Where |
|---|---|
| A default filter of another program | A function beside `fzf` that makes its `Process.Command` |
| A new record separator | A constructor of `Separator` and its byte in `Separator.byte` |
| A source rooted somewhere per query | The function of the query `answer` is given |
| A new policy default (`limit`, `filterBytes`, `time`) | A field default of `Filtering` |
| A lister whose non-zero exit still answers its records | Its statuses in `partialListing`, set by the caller that knows the lister |

Pinned on the job model and the loop's driver by
`ModelTest.filteringChecks`, and over real processes with a fixture filter
by `ContractTest.filteringChecks`.
-/

namespace Editor.Completion

/-- How a lister's and a filter's records are separated. -/
inductive Filtering.Separator where
  /-- A line feed. -/
  | newline
  /-- A NUL byte (`git ls-files -z`, `fzf --read0 --print0`). -/
  | nul
  deriving DecidableEq, Repr

/-- The byte that ends a record. -/
def Filtering.Separator.byte : Filtering.Separator → UInt8
  | .newline => 10
  | .nul => 0

/-- A source a command filters: what lists the candidates, what filters
them, and the limits of each. -/
structure Filtering where
  /-- The command whose standard output is the candidates, run in its own
  directory. -/
  lister : Process.Command
  /-- The command fed the lister's output, the typed text appended to its
  arguments, whose standard output is the matches, best first. -/
  filter : Process.Command
  /-- How both commands' records are separated. -/
  separator : Filtering.Separator := .newline
  /-- How many records are delivered. -/
  limit : Nat := 200
  /-- How many bytes of the filter's output are kept: its head. -/
  filterBytes : Nat := 256 * 1024
  /-- How many bytes of the lister's output may be held, whole. -/
  listBytes : Nat := 64 * 1024 * 1024
  /-- How long each of the two runs may take, in milliseconds. -/
  time : Nat := 10000
  /-- The filter's exit statuses that mean no candidate matched. -/
  noMatches : List Nat := [1]
  /-- The lister's exit statuses that still answer the records it printed:
  a listing it could make only in part. -/
  partialListing : List Nat := []
  deriving DecidableEq, Repr

namespace Filtering

/-- fzf as a filter, in `directory`: `fzf --filter`, reading and printing
NUL-separated records for `.nul`. The text follows `--filter` as its own
argument. -/
def fzf (directory : System.FilePath) (separator : Separator := .newline) : Process.Command :=
  { program := "fzf"
    arguments :=
      match separator with
      | .newline => #["--filter"]
      | .nul => #["--read0", "--print0", "--filter"]
    directory }

/-- The records of `bytes`, split on `separator`'s byte, in order. The bytes
after the last separator are a last record unless the output was `cut`,
when they are a part of one and are dropped. An empty record, and one that
is not UTF-8, is dropped. -/
def records (separator : Separator) (bytes : ByteArray) (cut : Bool) : Array String :=
  Id.run do
    let byte := separator.byte
    let mut records : Array String := #[]
    let mut start := 0
    for index in [0:bytes.size] do
      if bytes[index]! == byte then
        if index > start then
          if let some record := String.fromUTF8? (bytes.extract start index) then
            records := records.push record
        start := index + 1
    if !cut && bytes.size > start then
      if let some record := String.fromUTF8? (bytes.extract start bytes.size) then
        records := records.push record
    return records

/-- What a run that did not end with the status 0 says: the program, and how
it ended, with the first line of its standard error when there is one. -/
def ended (program : String) (ran : Process.Ran) : String :=
  let how :=
    match ran.exit with
    | .code status => s!"exited with status {status}"
    | .signal signal => s!"was ended by the signal {signal}"
  let said := (((String.fromUTF8? ran.stderr).getD "").splitOn "\n").head!.trimAscii.toString
  if said.isEmpty then s!"{program}: {how}" else s!"{program}: {how}: {said}"

/-- The command `filtering`'s filter runs for `text`: its arguments with
`text` after them, one argument whatever it holds. -/
def filterFor (filtering : Filtering) (text : String) : Process.Command :=
  { filtering.filter with arguments := filtering.filter.arguments.push text }

/-- The matches of `filtering` for `text`: the lister's output fed to the
filter given `text`, the first `limit` records it answered, in its order;
or why it could not answer, naming the program ("How it answers", in the
module docs). -/
def found (filtering : Filtering) (text : String) : JobM (Except String (Array String)) := do
  let lister := filtering.lister
  let listed ←
    match ← Process.runWithin lister filtering.listBytes filtering.time with
    | .error error =>
      return .error s!"{lister.program}: {error.describe}"
    | .ok ran =>
      pure ran
  match listed.exit with
  | .code 0 =>
    pure ()
  | .code status =>
    unless filtering.partialListing.contains status do
      return .error (ended lister.program listed)
  | .signal _ =>
    return .error (ended lister.program listed)
  let filter := filtering.filterFor text
  let records ←
    match ← Process.runHead filter listed.stdout filtering.filterBytes filtering.time with
    | .error error =>
      return .error s!"{filter.program}: {error.describe}"
    | .ok (.cut stdout _) =>
      pure (records filtering.separator stdout true)
    | .ok (.whole ran) =>
      match ran.exit with
      | .code 0 =>
        pure (records filtering.separator ran.stdout false)
      | .code status =>
        if filtering.noMatches.contains status then
          pure #[]
        else
          return .error (ended filter.program ran)
      | .signal _ =>
        return .error (ended filter.program ran)
  return .ok (records.extract 0 filtering.limit)

/-- A source's answer (`Completion.answering`) from the filtering
`filtering` makes for each query: one batch of the matches for the query's
text, delivered even when it is empty; a failure throws its message. It is
handed a function of the query so a caller can root the commands at the
query's place; one with fixed commands passes `fun _ => pure filtering`. -/
def answer (filtering : Query → JobM Filtering) (query : Query)
    (deliver : Array Candidate → JobM Unit) : JobM Unit := do
  match ← (← filtering query).found query.text with
  | .error message =>
    throw message
  | .ok records =>
    deliver (records.map Candidate.ofText)

/-- A source called `name`, of `category`, answered by the job registered as
`job` (`sourceJob job (Filtering.answer …)`, `Editor/Setup.lean`): it has
filtered already, and is asked again `pause` milliseconds after the text
changes. -/
def source (name category job : String) (pause : Nat := 50) : Source :=
  Source.answeringLater name category job (.afterPause pause) (filtered := true)

end Filtering

end Editor.Completion
