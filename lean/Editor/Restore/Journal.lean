import Editor.File
import Editor.Json
import Editor.Text

/-!
# A buffer's journal, as its log holds it

A journal is how a buffer's unsaved text outlives an abort of the process
(`Editor/Restore.lean`): a base, the text whole, and a log of what changed
since, one record a line. This module is the log's format, pure: its
records (`Journal.Record`), each as the bytes appended for it
(`Record.bytes`), what a log's text reads as (`Journal.decode`), and the
log played over a text (`Journal.replay`).

## The format

The log is JSON lines, each written with one append.

- **The first line is a header**:
  `{"format":1,"kind":"header","name":…,"path":…,"stamp":{…},"lineEnding":"lf","revision":r}`,
  with the buffer's name, its file's path and stamp when it holds a file
  (absent otherwise), its line ending (`lf` or `crlf`), and the revision of
  its text the base was taken at.
- **Each later line is one record of edits**:
  `{"kind":"edits","edits":[[oldStart,oldEnd,"inserted"],…]}`, the edits
  in the coordinates of the text before the record, sorted and disjoint,
  each the bytes from `oldStart` up to `oldEnd` replaced by the inserted
  text. A record is one transaction when replayed.
- **The inserted text crosses as JSON strings.** The JSON reader refuses a
  NUL even escaped (`Editor/Json.lean`), so a NUL splits the inserted text
  into pieces: an edit is the two offsets and then the pieces, which the
  text is joined from with a NUL between each two. A text with no NUL is one
  piece.
- **Bytes that are not UTF-8 round-trip.** A line is written as the store
  writes a text (`File.encodeText`), so an escape is its one byte; the log
  is loaded as any file is, which decodes those bytes back to their escapes
  (`File.decodeBytes`), and the text read is parsed. Being JSON, the log
  holds no NUL byte, so a load takes it as text.

## Reading a log

`decode` never throws: what it does not understand ends what it reads, and
says so.

- A line of a newer format than this editor's (`format` above
  `Journal.format`), or of a kind it does not know, stops the reading
  before it, with why (`Decoded.stopped`): what came before is replayed,
  and the journal is left on disk.
- A last line with no line break that does not parse is torn, the tail of a
  write the process did not finish: it is dropped, and its length in bytes
  said (`Decoded.torn`). Any other line that does not parse stops the
  reading, as an unknown kind does.
- A log whose first line is not a header has none (`Decoded.header`): its
  base is restored as a buffer with no file.

Pinned by `ModelTest.journalFormatChecks`.
-/

namespace Editor.Restore.Journal

/-- The format this editor writes, and the newest it reads. -/
def format : Nat :=
  1

/-- A log's first line: what the buffer was when its base was taken. -/
structure Header where
  /-- The buffer's name. -/
  name : String
  /-- Its file's path, when it holds a file. -/
  path : Option String := none
  /-- Its file's stamp then, when it holds a file. -/
  stamp : Option File.Stamp := none
  /-- Its line ending. -/
  lineEnding : File.LineEnding := .lf
  /-- The revision of its text the base was taken at. -/
  revision : Nat := 0
  deriving DecidableEq, Repr

/-- One edit of a record: the bytes from `start` up to `stop` of the text
before the record, replaced by `inserted`. -/
structure Edit where
  /-- Where the replaced bytes start. -/
  start : Nat
  /-- Where they stop, not included. -/
  stop : Nat
  /-- What replaced them. -/
  inserted : String
  deriving DecidableEq, Repr, Inhabited

/-- One line of a log. -/
inductive Record where
  /-- The first line. -/
  | header (header : Header)
  /-- The edits one record made, sorted and disjoint. -/
  | edits (edits : Array Edit)
  deriving DecidableEq, Repr

/-- A natural number as JSON. -/
def natJson (value : Nat) : Json.Value :=
  .number (toString value)

/-- A stamp as JSON. -/
def stampJson (stamp : File.Stamp) : Json.Value :=
  .object
    #[("seconds", .number (toString stamp.seconds)), ("nanoseconds", natJson stamp.nanoseconds),
      ("size", natJson stamp.size)]

/-- A line ending's name. -/
def endingName : File.LineEnding → String
  | .lf => "lf"
  | .crlf => "crlf"

/-- A record as JSON ("The format", in the module docs). -/
def Record.toJson : Record → Json.Value
  | .header first =>
    .object <|
      #[("format", natJson format), ("kind", .string "header"), ("name", .string first.name)] ++
        (first.path.map fun path => #[("path", Json.Value.string path)]).getD #[] ++
        (first.stamp.map fun stamp => #[("stamp", stampJson stamp)]).getD #[] ++
        #[("lineEnding", .string (endingName first.lineEnding)),
          ("revision", natJson first.revision)]
  | .edits made =>
    .object
      #[("kind", .string "edits"),
        ("edits",
          .array <|
            made.map fun edit =>
              .array <|
                #[natJson edit.start, natJson edit.stop] ++
                  ((edit.inserted.splitOn "\x00").map Json.Value.string).toArray)]

/-- The record as its line: its JSON and a line feed. -/
def Record.line (record : Record) : String :=
  Json.render record.toJson ++ "\n"

/-- The bytes appended for the record: its line, as the store writes a text
(`File.encodeText`). -/
def Record.bytes (record : Record) : ByteArray :=
  File.encodeText record.line

/-- What a log's text reads as. -/
structure Decoded where
  /-- Its header, when its first line is one. -/
  header : Option Header := none
  /-- Its records of edits, in order, each one transaction. -/
  records : Array (Array Edit) := #[]
  /-- How many bytes of a torn last line were dropped. -/
  torn : Nat := 0
  /-- Why the reading stopped before a line, when it did: that line and the
  rest are not replayed. -/
  stopped : Option String := none
  deriving DecidableEq, Repr

/-- A natural number member, or none. -/
def natField? (value : Json.Value) (name : String) : Option Nat := do
  let .number text ← value.field? name | none
  text.toNat?

/-- A string member, or none. -/
def stringField? (value : Json.Value) (name : String) : Option String := do
  let .string text ← value.field? name | none
  some text

/-- A stamp from JSON, or none. -/
def stampOf? (value : Json.Value) : Option File.Stamp := do
  let .number seconds ← value.field? "seconds" | none
  return {
      seconds := ← seconds.toInt?, nanoseconds := ← natField? value "nanoseconds"
      size := ← natField? value "size" }

/-- A line ending from its name, or none. -/
def endingOf? : String → Option File.LineEnding
  | "lf" => some .lf
  | "crlf" => some .crlf
  | _ => none

/-- A header from JSON, or none. -/
def headerOf? (value : Json.Value) : Option Header := do
  let path ←
    match value.field? "path" with
    | none =>
      some none
    | some (.string path) =>
      some (some path)
    | some _ =>
      none
  let stamp ←
    match value.field? "stamp" with
    | none =>
      some none
    | some stamp =>
      (stampOf? stamp).map some
  return {
      name := ← stringField? value "name", path, stamp
      lineEnding := ← endingOf? (← stringField? value "lineEnding")
      revision := ← natField? value "revision" }

/-- An edit from JSON, or none: two offsets in order, then the pieces of its
inserted text. -/
def editOf? (value : Json.Value) : Option Edit := do
  let .array items := value | none
  let .number start := (← items[0]?) | none
  let .number stop := (← items[1]?) | none
  let start ← start.toNat?
  let stop ← stop.toNat?
  unless start ≤ stop do
    none
  let pieces ←
    (items.extract 2 items.size).mapM fun piece =>
        match piece with
        | .string text => some text
        | _ => none
  if pieces.isEmpty then
    none
  return { start, stop, inserted := "\x00".intercalate pieces.toList }

/-- A record of edits from JSON, or none: its edits sorted and disjoint. -/
def editsOf? (value : Json.Value) : Option (Array Edit) := do
  let .array items := (← value.field? "edits") | none
  let edits ← items.mapM editOf?
  let ordered :=
    (List.range (edits.size - 1)).all fun index => edits[index]!.stop ≤ edits[index + 1]!.start
  if ordered then
    some edits
  else
    none

/-- What the log's text `text` reads as ("Reading a log", in the module
docs). -/
def decode (text : String) : Decoded :=
  Id.run do
    let lines := (text.splitOn "\n").toArray
    -- A text that ends with a line break leaves an empty last piece.
    let complete := text.endsWith "\n" || text.isEmpty
    let count := if complete then lines.size - 1 else lines.size
    let mut decoded : Decoded := {}
    for index in [0:count] do
      let line := lines[index]!
      let last := index + 1 == count && !complete
      let number := index + 1
      match Json.parse line.toUTF8 with
      | .error _ =>
        if last then
          decoded := { decoded with torn := line.utf8ByteSize }
        else
          decoded := { decoded with stopped := some s!"line {number} does not parse" }
        break
      | .ok value =>
        if let some found := natField? value "format" then
          if found > format then
            decoded :=
              { decoded with
                stopped :=
                  some s!"line {number} is of format {found}, newer than this editor's {format}" }
            break
        match stringField? value "kind" with
        | some "header" =>
          if index == 0 then
            match headerOf? value with
            | some header =>
              decoded := { decoded with header := some header }
            | none =>
              decoded := { decoded with stopped := some s!"line {number} is not a header" }
              break
          else
            decoded := { decoded with stopped := some s!"line {number} is a second header" }
            break
        | some "edits" =>
          match editsOf? value with
          | some edits =>
            decoded := { decoded with records := decoded.records.push edits }
          | none =>
            decoded := { decoded with stopped := some s!"line {number} is not a record of edits" }
            break
        | some kind =>
          decoded :=
            { decoded with
              stopped :=
                some s!"line {number} is of the kind {kind}, which this editor does not know" }
          break
        | none =>
          decoded := { decoded with stopped := some s!"line {number} has no kind" }
          break
    return decoded

/-- The transaction that makes the edits `edits` to a text of `length`
bytes: each edit's bytes deleted and its text inserted, the rest kept. -/
def transaction (length : Nat) (edits : Array Edit) : Transaction :=
  let (changes, at_) :=
    edits.foldl
      (fun (changes, position) edit =>
        (changes ++
            #[Change.retain (edit.start - position), .delete (edit.stop - edit.start),
              .insert edit.inserted],
          edit.stop))
      (#[], 0)
  { changes := changes.push (.retain (length - at_)) }

/-- Plays `records` over `text`, each one transaction, in order, and answers
how many it played: a record the text refuses ends the replay there, and
what came before stays. -/
def replay (text : TextId) (records : Array (Array Edit)) : TextM Nat := do
  let mut played := 0
  for edits in records do
    let length ← text.byteLength
    let last := (edits.back?.map (·.stop)).getD 0
    if last > length then
      break
    match ← observing (text.apply (transaction length edits)) with
    | .ok _ =>
      played := played + 1
    | .error _ =>
      break
  return played

/-- The edits of `patch`, the change of a text since a record, each with the
text it inserted read from the text as it is now by `slice`. -/
def editsOf (patch : Patch) (slice : Nat → Nat → TextM String) : TextM (Array Edit) :=
  patch.edits.mapM fun edit => do
    return {
        start := edit.old.start, stop := edit.old.stop
        inserted := ← slice edit.new.start edit.new.stop }

end Editor.Restore.Journal
