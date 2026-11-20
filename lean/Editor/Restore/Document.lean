import Editor.Restore.Frame
import Editor.Restore.Kept
import Editor.Restore.Workspaces

/-!
# The session index

What a run writes of its session under the state directory
(`<state>/session/`, `Editor/Restore.lean`): the index document, one file a
run, `session-<run>.json`, written only by that run; and the names of the
journals beside it, `journals/<run>-<buffer>-<generation>.base` and `.log`.
Pure: the document (`Document`), as its JSON (`Document.render`), read with
the version rule (`Document.read`), the index a restore takes in and those
it removes (`Document.choose`), and the next run's number (`nextRun`).

## The document

`{"format":2,"run":n,"ended":false,"focused":view,"buffers":[…],"frame":{…},
"workspaces":{…},"stores":[…],"jobs":[…],"otherJobs":n}`: the format, the run that wrote
it, whether that run ended cleanly (only the index a clean end writes says
so), the focused view, and for each buffer kept:

- `key`, the buffer's index, which names its journals;
- `name`;
- `file`: `{"path":…,"stamp":{…}}`, or absent for a buffer with no file;
- `lineEnding`, `lf` or `crlf`;
- `major`, `minors` and `language`, each absent when the buffer has none;
- `journal`: `{"key":k,"generation":g}`, the buffer's live journal of this
  run, or absent;
- `views`: one place for each window on the buffer (`Restore.Place`): its
  view's id, the anchor and the head of its primary selection as a row and
  a byte column, its scroll's top row, and its jump list (`jumps`,
  `{"entries":[…],"index":i,"previous":<jump>}`, absent when it has none;
  `Editor/Restore/Frame.lean`), and `run`, absent on a place of a window of
  the run that wrote the index: on a place a restore read and did not put
  back, written again (`Kept.places`), the run whose view ids it is under,
  since view ids are unique only within one run.

Format 2 added, beside the buffers, each absent when there is none:

- `frame`: the tabs and windows (`Frame.Record`, `Editor/Restore/Frame.lean`);
- `workspaces`: the workspace table with the cells kept across a restart
  (`Document.Workspaces`, `Editor/Restore/Workspaces.lean`);
- `stores`: the declared stores' cells kept across a restart, each
  `{"owner":o,"name":n,"version":v,"value":<value>}`, the value a plain
  tree's JSON (`Editor/Restore/Value.lean`);
- `jobs`: the reported jobs running when it was written, each
  `{"owner":o,"name":n,"key":k}`, `key` absent for a job with none;
- `otherJobs`: how many other jobs were running then, a count only: those
  neither reported nor restarted by their owner (`Restore.otherJobs`), as
  of the last write another change started;
- and in a place, `run`.

Nothing of format 1 changed shape or meaning. The number moved to 2 so that
a format-1 editor reads a format-2 index leniently, naming the keys it does
not know and leaving the file as it is, rather than removing it as
understood once its own index is written.

## The version rule

A read never throws: every problem is a line of its report.

- A format at or below this editor's is read fully: a format-1 index has
  no frame, workspaces, stores, jobs or other jobs.
- A newer format is read leniently: the known fields are read, and every
  key this editor does not know, at the top or in a buffer, is named in the
  report.
- A buffer entry that does not parse is skipped, and said; so is a `stores`
  or a `jobs` entry, and a `frame` or a `workspaces` that does not parse
  is read as none, and said.
- A file that does not parse is said, and read as nothing: the restore goes
  on from the journals alone.

**Choosing** (`choose`): the index of the highest run is the one restored,
whatever its format; none is when it says `ended`. Every index of a format
this editor understands is to be removed once this run's first index is
written; one of a newer format, or one that does not parse, is left as it
is, never written over, and said once.

**The next run** (`nextRun`) is one more than the largest run found in an
index's name, in an index's `run`, and in a journal's name, so an index or a
journal this run leaves untouched never outranks it.

Pinned by `ModelTest.restoreDocumentChecks`.
-/

namespace Editor.Restore

/-- The format of the index this editor writes, and the newest it reads
fully. -/
def indexFormat : Nat :=
  2

/-- A buffer's file, as the index records it. -/
structure Document.File where
  /-- Its path. -/
  path : String
  /-- Its stamp when it was last loaded or saved. -/
  stamp : File.Stamp
  deriving DecidableEq, Repr

/-- A buffer's live journal of the index's run. -/
structure Document.Journal where
  /-- The buffer's key. -/
  key : Nat
  /-- The journal's generation. -/
  generation : Nat
  deriving DecidableEq, Repr

/-- One buffer of the index. -/
structure Document.Buffer where
  /-- Its key: its index in the run that wrote the index. -/
  key : Nat
  /-- Its name. -/
  name : String
  /-- Its file, if it holds one. -/
  file : Option Document.File := none
  /-- Its line ending. -/
  lineEnding : File.LineEnding := .lf
  /-- Its major mode's name. -/
  major : Option String := none
  /-- Its minor modes' names. -/
  minors : Array String := #[]
  /-- Its language's name. -/
  language : Option String := none
  /-- Its live journal, if it has one. -/
  journal : Option Document.Journal := none
  /-- The place of each window on it. -/
  views : Array Place := #[]
  deriving DecidableEq, Repr

/-- The session index of a run. -/
structure Document where
  /-- The format it was written in. -/
  format : Nat := indexFormat
  /-- The run that wrote it. -/
  run : Nat
  /-- Whether that run ended cleanly. -/
  ended : Bool := false
  /-- The focused view's id. -/
  focused : Option Nat := none
  /-- The buffers kept. -/
  buffers : Array Document.Buffer := #[]
  /-- The frame's tabs and windows, when recorded. -/
  frame : Option Frame.Record := none
  /-- The workspace table, when recorded. -/
  workspaces : Option Document.Workspaces := none
  /-- The declared stores' cells kept across a restart. -/
  stores : Array KeptCell := #[]
  /-- The reported jobs running when it was written. -/
  jobs : Array RunningJob := #[]
  /-- How many other jobs were running when it was written: those neither
  reported nor restarted by their owner (`Restore.otherJobs`). -/
  otherJobs : Nat := 0
  deriving BEq, Repr

/-- A place as JSON. -/
def Place.toJson (place : Place) : Json.Value :=
  .object <|
    #[("view", Journal.natJson place.view), ("anchor", place.anchor.toJson),
        ("head", place.head.toJson), ("top", Journal.natJson place.top)] ++
      optionalMember "jumps" (place.jumps.map (·.toJson)) ++
      optionalMember "run" (place.run.map Journal.natJson)

/-- A running job as JSON. -/
def RunningJob.toJson (job : RunningJob) : Json.Value :=
  .object <|
    #[("owner", .string job.owner), ("name", .string job.name)] ++
      optionalMember "key" (job.key.map .string)

/-- A running job from JSON, or none. -/
def RunningJob.ofJson? (value : Json.Value) : Option RunningJob := do
  let key ←
    match value.field? "key" with
    | none =>
      some none
    | some (.string key) =>
      some (some key)
    | some _ =>
      none
  return { owner := ← Journal.stringField? value "owner",
           name := ← Journal.stringField? value "name", key }

/-- A buffer as JSON. -/
def Document.Buffer.toJson (buffer : Document.Buffer) : Json.Value :=
  let optional (name : String) (value : Option Json.Value) : Array (String × Json.Value) :=
    (value.map fun value => #[(name, value)]).getD #[]
  .object <|
    #[("key", Journal.natJson buffer.key), ("name", .string buffer.name)] ++
      optional "file"
        (buffer.file.map fun file =>
          .object #[("path", .string file.path), ("stamp", Journal.stampJson file.stamp)]) ++
      #[("lineEnding", .string (Journal.endingName buffer.lineEnding))] ++
      optional "major" (buffer.major.map .string) ++
      (if buffer.minors.isEmpty then #[] else #[("minors", .array (buffer.minors.map .string))]) ++
      optional "language" (buffer.language.map .string) ++
      optional "journal"
        (buffer.journal.map fun journal =>
          .object
            #[("key", Journal.natJson journal.key),
              ("generation", Journal.natJson journal.generation)]) ++
      #[("views", .array (buffer.views.map (·.toJson)))]

/-- The document as JSON. -/
def Document.toJson (document : Document) : Json.Value :=
  .object <|
    #[("format", Journal.natJson document.format), ("run", Journal.natJson document.run),
        ("ended", .bool document.ended)] ++
      ((document.focused.map fun view => #[("focused", Journal.natJson view)]).getD #[]) ++
      #[("buffers", .array (document.buffers.map (·.toJson)))] ++
      optionalMember "frame" (document.frame.map (·.toJson)) ++
      optionalMember "workspaces" (document.workspaces.map (·.toJson)) ++
      (if document.stores.isEmpty then #[]
      else #[("stores", .array (document.stores.map (·.toJson)))]) ++
      (if document.jobs.isEmpty then #[] else #[("jobs", .array (document.jobs.map (·.toJson)))]) ++
      if document.otherJobs == 0 then #[] else #[("otherJobs", Journal.natJson document.otherJobs)]

/-- The document as the text of its file. -/
def Document.render (document : Document) : String :=
  Json.render document.toJson

/-- The keys of the document this editor knows. -/
def Document.knownKeys : Array String :=
  #["format", "run", "ended", "focused", "buffers", "frame", "workspaces", "stores", "jobs",
    "otherJobs"]

/-- The keys of a buffer this editor knows. -/
def Document.Buffer.knownKeys : Array String :=
  #["key", "name", "file", "lineEnding", "major", "minors", "language", "journal", "views"]

/-- A place from JSON, or none. -/
def Place.ofJson? (value : Json.Value) : Option Place := do
  return {
      view := ← Journal.natField? value "view", anchor := ← Spot.ofJson? (← value.field? "anchor")
      head := ← Spot.ofJson? (← value.field? "head"), top := ← Journal.natField? value "top"
      jumps := ← optionalField? value "jumps" Jumps.Record.ofJson?
      run :=
        ←
          optionalField? value "run" fun
              | .number run => run.toNat?
              | _ => none }

/-- An optional string member: `some none` when absent, `none` when it is
there and not a string. -/
def optionalString? (value : Json.Value) (name : String) : Option (Option String) :=
  match value.field? name with
  | none => some none
  | some (.string text) => some (some text)
  | some _ => none

/-- A buffer from JSON, or none. -/
def Document.Buffer.ofJson? (value : Json.Value) : Option Document.Buffer := do
  let file ←
    match value.field? "file" with
    | none =>
      some none
    | some file =>
      some
          (some
            { path := ← Journal.stringField? file "path"
              stamp := ← Journal.stampOf? (← file.field? "stamp") })
  let minors ←
    match value.field? "minors" with
    | none =>
      some #[]
    | some (.array items) =>
      items.mapM fun item =>
          match item with
          | .string name => some name
          | _ => none
    | some _ =>
      none
  let journal ←
    match value.field? "journal" with
    | none =>
      some none
    | some journal =>
      some
          (some
            { key := ← Journal.natField? journal "key"
              generation := ← Journal.natField? journal "generation" })
  let views ←
    match value.field? "views" with
    | none =>
      some #[]
    | some (.array items) =>
      items.mapM Place.ofJson?
    | some _ =>
      none
  return {
      key := ← Journal.natField? value "key", name := ← Journal.stringField? value "name"
      file, lineEnding := ← Journal.endingOf? (← Journal.stringField? value "lineEnding")
      major := ← optionalString? value "major", minors
      language := ← optionalString? value "language", journal, views }

/-- What a read of an index came to. -/
structure Document.Read where
  /-- What of it this editor understands; none for a file that does not
  parse. -/
  document : Option Document := none
  /-- Whether its format is newer than this editor's. -/
  newer : Bool := false
  /-- What the read has to say, a line each. -/
  report : Array String := #[]
  deriving BEq, Repr

/-- The names of `value`'s members that are not among `known`. -/
def unknownKeys (value : Json.Value) (known : Array String) : Array String :=
  match value with
  | .object members => (members.map (·.1)).filter (!known.contains ·)
  | _ => #[]

/-- What is said of the index file called `name` that does not parse, for
`why`. -/
def unparsed (name why : String) : String :=
  s!"{name} does not parse ({why}): it is left as it is"

/-- The index the text `text` of the file called `name` holds, by the
version rule ("The version rule", in the module docs). -/
def Document.read (name text : String) : Document.Read :=
  Id.run do
    let value ←
      match Json.parse text.toUTF8 with
      | .ok value =>
        pure value
      | .error why =>
        return { report := #[unparsed name why] }
    let some found :=
      Journal.natField? value "format" | return { report := #[unparsed name "it has no format"] }
    let some run :=
      Journal.natField? value "run" | return { report := #[unparsed name "it has no run"] }
    let newer := found > indexFormat
    let mut report :=
      if newer then
        #[s!"{name} is of format {found}, newer than this editor's {indexFormat}: what is known of it is restored, and it is left as it is"] ++
          (unknownKeys value Document.knownKeys).map fun key =>
            s!"{name}: the key {key} is not known"
      else #[]
    let mut buffers := #[]
    let entries :=
      match value.field? "buffers" with
      | some (.array items) => items
      | _ => #[]
    for index in [0:entries.size] do
      let entry := entries[index]!
      match Document.Buffer.ofJson? entry with
      | some buffer =>
        buffers := buffers.push buffer
        if newer then
          report :=
            report ++
              (unknownKeys entry Document.Buffer.knownKeys).map fun key =>
                s!"{name}: buffer {buffer.key}: the key {key} is not known"
      | none =>
        report := report.push s!"{name}: buffer entry {index + 1} does not parse and is skipped"
    let ended :=
      match value.field? "ended" with
      | some (.bool ended) => ended
      | _ => false
    -- What format 2 added, each read as none and said when it does not
    -- parse.
    let mut frame := none
    if let some member := value.field? "frame" then
      match Frame.Record.ofJson? member with
      | some record =>
        frame := some record
      | none =>
        report := report.push s!"{name}: its frame does not parse and is not restored"
    let mut workspaces := none
    if let some member := value.field? "workspaces" then
      match Document.Workspaces.ofJson? member with
      | some record =>
        workspaces := some record
      | none =>
        report := report.push s!"{name}: its workspaces do not parse and are not restored"
    let entriesOf (key : String) : Array Json.Value :=
      match value.field? key with
      | some (.array items) => items
      | _ => #[]
    let mut stores := #[]
    let storeEntries := entriesOf "stores"
    for index in [0:storeEntries.size] do
      match KeptCell.ofJson? storeEntries[index]! with
      | some cell =>
        stores := stores.push cell
      | none =>
        report := report.push s!"{name}: store entry {index + 1} does not parse and is skipped"
    let mut jobs := #[]
    let jobEntries := entriesOf "jobs"
    for index in [0:jobEntries.size] do
      match RunningJob.ofJson? jobEntries[index]! with
      | some job =>
        jobs := jobs.push job
      | none =>
        report := report.push s!"{name}: job entry {index + 1} does not parse and is skipped"
    return {
        document :=
          some
            { format := found, run, ended, focused := Journal.natField? value "focused", buffers
              frame, workspaces, stores, jobs
              otherJobs := (Journal.natField? value "otherJobs").getD 0 }
        newer, report }

/-- The name of a run's index file. -/
def indexName (run : Nat) : String :=
  s!"session-{run}.json"

/-- The run an index file's name names, if it is one's. -/
def runOfIndex? (name : String) : Option Nat := do
  unless name.startsWith "session-" && name.endsWith ".json" do
    none
  ((name.drop 8).dropEnd 5).toString.toNat?

/-- The stem of a journal's two files: `<run>-<buffer>-<generation>`. -/
def journalStem (run buffer generation : Nat) : String :=
  s!"{run}-{buffer}-{generation}"

/-- What a journal file's name names: its run, buffer and generation, and
whether it is the base (`.base`) or the log (`.log`). -/
def journalOf? (name : String) : Option (Nat × Nat × Nat × Bool) := do
  let (stem, base) ←
    if name.endsWith ".base" then
      some ((name.dropEnd 5).toString, true)
    else if name.endsWith ".log" then
      some ((name.dropEnd 4).toString, false)
    else
      none
  let [run, buffer, generation] := stem.splitOn "-" | none
  return (← run.toNat?, ← buffer.toNat?, ← generation.toNat?, base)

/-- The next run's number: one more than the largest run named by `names`,
the files of the session directory and of its journals, and by `runs`, the
`run` of each index read ("The next run", in the module docs). -/
def nextRun (names : Array String) (runs : Array Nat) : Nat :=
  let named := names.filterMap fun name => (runOfIndex? name) <|> ((journalOf? name).map (·.1))
  (named ++ runs).foldl max 0 + 1

/-- What a restore makes of the indexes it read ("Choosing", in the module
docs). -/
structure Document.Choice where
  /-- The index taken in, if one is. -/
  restored : Option Document := none
  /-- The runs of the indexes to remove once this run's first index is
  written: those of a format this editor understands. -/
  remove : Array Nat := #[]
  /-- What is said of the indexes, a line each. -/
  report : Array String := #[]
  deriving BEq, Repr

/-- The choice among `indexes`, each a run and what its read came to. -/
def Document.choose (indexes : Array (Nat × Document.Read)) : Document.Choice :=
  let sorted := indexes.qsort (·.1 < ·.1)
  let highest := sorted.back?
  let restored : Option Document :=
    highest.bind fun (_, read) => read.document.filter fun (document : Document) => !document.ended
  let understood (read : Document.Read) : Bool := read.document.isSome && !read.newer
  { restored
    remove := (sorted.filter (understood ·.2)).map (·.1)
    report := sorted.flatMap (·.2.report) }

end Editor.Restore
