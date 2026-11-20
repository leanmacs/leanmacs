import Editor.Json

/-!
# Working sets: the stored form

A working set is a named list of ranges of files, each with a note, kept per
workspace (`docs/design/review-and-navigation.md`, "Working sets"). While the
editor runs a range is held by two anchors of its file's buffer
(`Editor/WorkingSet/Places.lean`); this module is the form a range is kept
in when no buffer holds it, and on disk. It is pure: no port, no state.

## The stored form

A range is stored (`WorkingSet.Stored`) as text it can be found by again
after its file changed, rdm's text-quote anchor in shape
(`docs/design/review-and-navigation.md`, "Anchoring comments"):

- **the path** of its file, relative to the workspace's root;
- **the commit** `HEAD` was at when the form was last refreshed, or empty
  where there is no repository;
- **the quote**, the range's text, and **its context**: up to
  `contextChars` (32) characters before it and after it;
- **its points**: the line and column where it starts and where it stops,
  each 1-based, a column counted in characters, as a compiler's diagnostics
  count them;
- **its note**.

`capture` makes one from a text and two byte offsets. `Point.offsetIn` turns
a point back into a byte offset of a text, clamped: a line past the end is
the text's end, and a column past the end of its line is that line's end.

## The document on disk

`Document` is what a workspace keeps: a version (`version`, 1), the
workspace's root, and its sets in order, each a name and its ranges. It is
written as JSON (`Document.render`, over `Json.render`) and read with
`Document.read`:

```json
{"version":1,"root":"/abs/root","sets":[{"name":"auth","ranges":[
  {"path":"src/a.rs","commit":"…","quote":"…","prefix":"…","suffix":"…",
   "start":{"line":12,"column":5},"stop":{"line":14,"column":1},"note":""}]}]}
```

A document that does not parse, or whose version is above `version`, is
refused with why (`version 2 is newer than this editor's 1`): the caller
then shows none of the workspace's sets and never writes over the file.

**Where**: `storeFile state root`, `<state>/workspaces/<key>/working-sets.json`,
where `<key>` is the root, absolute, with `%` written `%25` and `/` written
`%2F` (`key`): one directory per workspace, reversible, and computable by an
agent.

## The thresholds

The re-find ladder (`Editor/WorkingSet/Refind.lean`) is tuned by the
constants here, which are pinned by `ModelTest.workingSetRefindChecks` and
are not config: `fuzzyRatio`, `fuzzyMinimum`, `fuzzyWindow`, `fuzzyWhole`
and `fuzzyEnds`.

## The excerpts of a set

A set opens as an excerpt buffer of its ranges' lines (`excerpts`): ranges
are grouped by file, in the order of each file's first range; within a
file, ranges whose rows overlap or touch are one excerpt, as project search
merges its matches' (`ProjectSearch.excerptRows`), so no two excerpts are
over one source byte. Each excerpt's header (`header`, `driftedHeader`) is
its path and line, with what is known of its ranges.

Pinned by `ModelTest.workingSetChecks`.
-/

namespace Editor.WorkingSet

/-- The version of the document this editor writes, and the newest it
reads. -/
def version : Nat :=
  1

/-- How many characters of context are kept on each side of a quote: rdm's
`DERIVE_CONTEXT_CHARS`. -/
def contextChars : Nat :=
  32

/-- The errors a fuzzy search allows a quote: one for each `fuzzyRatio`
bytes of it, rounded down. -/
def fuzzyRatio : Nat :=
  4

/-- A quote shorter than this, in characters, is not looked for with
errors: one edit in a short quote matches noise. -/
def fuzzyMinimum : Nat :=
  8

/-- How far before and after where a quote is expected a fuzzy search
looks, in bytes. -/
def fuzzyWindow : Nat :=
  16384

/-- A quote longer than this, in bytes, is looked for by its two ends. -/
def fuzzyWhole : Nat :=
  1024

/-- How long each end of a long quote is, in bytes. -/
def fuzzyEnds : Nat :=
  128

/-- A place in a text: its line and its column, each 1-based, the column
counted in characters. -/
structure Point where
  /-- The line, 1 for the first. -/
  line : Nat
  /-- The column, 1 for the first character of the line. -/
  column : Nat
  deriving DecidableEq, Repr, Inhabited

/-- A range as it is kept when no buffer holds it ("The stored form", in the
module docs). -/
structure Stored where
  /-- Its file, relative to the workspace's root. -/
  path : String
  /-- The commit `HEAD` was at when it was last refreshed; empty for none. -/
  commit : String := ""
  /-- Its text. -/
  quote : String
  /-- Up to `contextChars` characters of the text before it. -/
  before : String := ""
  /-- Up to `contextChars` characters of the text after it. -/
  after : String := ""
  /-- Where it starts. -/
  start : Point
  /-- Where it stops. -/
  stop : Point
  /-- Its note. -/
  note : String := ""
  deriving DecidableEq, Repr, Inhabited

/-- A named working set: its ranges, in the order they were added. -/
structure Set where
  /-- Its name. -/
  name : String
  /-- Its ranges. -/
  ranges : Array Stored := #[]
  deriving DecidableEq, Repr, Inhabited

/-- What a workspace keeps on disk ("The document on disk", in the module
docs). -/
structure Document where
  /-- The version it was written in. -/
  version : Nat := WorkingSet.version
  /-- The workspace's root, absolute. -/
  root : String
  /-- Its sets, in order. -/
  sets : Array Set := #[]
  deriving DecidableEq, Repr, Inhabited

/-! ## Points and offsets -/

/-- Whether the byte at `index` of `bytes` starts a character. -/
def starts (bytes : ByteArray) (index : Nat) : Bool :=
  (bytes.get! index &&& 0xC0) != 0x80

/-- The point of the byte offset `offset` of `bytes`, a text's UTF-8. -/
def pointAt (bytes : ByteArray) (offset : Nat) : Point :=
  Id.run do
    let mut line := 1
    let mut column := 1
    for index in [0:min offset bytes.size] do
      if bytes.get! index == 10 then
        line := line + 1
        column := 1
      else if starts bytes index then
        column := column + 1
    return { line, column }

/-- The byte offset of `point` in `bytes`, a text's UTF-8, clamped: a line
past the last is the text's end, and a column past the end of its line is
that line's end. -/
def Point.offsetIn (point : Point) (bytes : ByteArray) : Nat :=
  Id.run do
    let mut index := 0
    let mut line := 1
    while line < point.line && index < bytes.size do
      if bytes.get! index == 10 then
        line := line + 1
      index := index + 1
    if line < point.line then
      return bytes.size
    let mut column := 1
    while column < point.column && index < bytes.size && bytes.get! index != 10 do
      index := index + 1
      while index < bytes.size && !starts bytes index do
        index := index + 1
      column := column + 1
    return index

/-- The text of the bytes of `bytes` from `start` to `stop`, both character
boundaries; empty if they are not. -/
def slice (bytes : ByteArray) (start stop : Nat) : String :=
  (String.fromUTF8? (bytes.extract start stop)).getD ""

/-- The stored form of the range from the byte offset `start` to `stop` of
`text`, both character boundaries: its quote, its context and its points;
the path, the commit and the note are the caller's. -/
def capture (text : String) (start stop : Nat) (path : String) (commit note : String := "") :
    Stored :=
  let bytes := text.toUTF8
  let stop := min stop bytes.size
  let start := min start stop
  -- A character is at most four bytes, so the context is in these.
  let lead :=
    Id.run do
      let mut from_ := start - min start (4 * contextChars)
      while from_ < start && !starts bytes from_ do
        from_ := from_ + 1
      return from_
  let tail :=
    Id.run do
      let mut upTo := min bytes.size (stop + 4 * contextChars)
      while upTo > stop && upTo < bytes.size && !starts bytes upTo do
        upTo := upTo - 1
      return upTo
  let beforeChars := (slice bytes lead start).toList
  let afterChars := (slice bytes stop tail).toList
  { path, commit, note, quote := slice bytes start stop
    before := String.ofList (beforeChars.drop (beforeChars.length - contextChars))
    after := String.ofList (afterChars.take contextChars)
    start := pointAt bytes start
    stop := pointAt bytes stop }

/-! ## The document as JSON -/

/-- A point as JSON. -/
def Point.toJson (point : Point) : Json.Value :=
  .object #[("line", .number (toString point.line)), ("column", .number (toString point.column))]

/-- A stored range as JSON. -/
def Stored.toJson (stored : Stored) : Json.Value :=
  .object
    #[("path", .string stored.path), ("commit", .string stored.commit),
      ("quote", .string stored.quote), ("prefix", .string stored.before),
      ("suffix", .string stored.after), ("start", stored.start.toJson),
      ("stop", stored.stop.toJson), ("note", .string stored.note)]

/-- A set as JSON. -/
def Set.toJson (set : Set) : Json.Value :=
  .object #[("name", .string set.name), ("ranges", .array (set.ranges.map (·.toJson)))]

/-- A document as JSON. -/
def Document.toJson (document : Document) : Json.Value :=
  .object
    #[("version", .number (toString document.version)), ("root", .string document.root),
      ("sets", .array (document.sets.map (·.toJson)))]

/-- The document as the bytes of its file. -/
def Document.render (document : Document) : String :=
  Json.render document.toJson

/-- The string member `name` of `value`, or why there is none. -/
def stringOf (value : Json.Value) (name : String) : Except String String :=
  match value.field? name with
  | some (.string text) => .ok text
  | _ => .error s!"{name} is not a string"

/-- The natural number member `name` of `value`, or why there is none. -/
def natOf (value : Json.Value) (name : String) : Except String Nat :=
  match value.field? name with
  | some (.number text) =>
    match text.toNat? with
    | some number => .ok number
    | none => .error s!"{name} is not a natural number"
  | _ => .error s!"{name} is not a number"

/-- The array member `name` of `value`, or why there is none. -/
def arrayOf (value : Json.Value) (name : String) : Except String (Array Json.Value) :=
  match value.field? name with
  | some (.array items) => .ok items
  | _ => .error s!"{name} is not an array"

/-- The point member `name` of `value`, or why there is none. -/
def pointOf (value : Json.Value) (name : String) : Except String Point := do
  let some point := value.field? name | throw s!"{name} is missing"
  return { line := ← natOf point "line", column := ← natOf point "column" }

/-- A stored range from JSON, or why it is not one. -/
def Stored.ofJson? (value : Json.Value) : Except String Stored := do
  return {
      path := ← stringOf value "path", commit := ← stringOf value "commit"
      quote := ← stringOf value "quote", before := ← stringOf value "prefix"
      after := ← stringOf value "suffix", start := ← pointOf value "start"
      stop := ← pointOf value "stop", note := ← stringOf value "note" }

/-- A set from JSON, or why it is not one. -/
def Set.ofJson? (value : Json.Value) : Except String Set := do
  return { name := ← stringOf value "name",
           ranges := ← (← arrayOf value "ranges").mapM Stored.ofJson? }

/-- A document from JSON, or why it is not one: a version above `version`
is refused first. -/
def Document.ofJson? (value : Json.Value) : Except String Document := do
  let found ← natOf value "version"
  if found > WorkingSet.version then
    throw s!"version {found} is newer than this editor's {WorkingSet.version}"
  return {
      version := found, root := ← stringOf value "root"
      sets := ← (← arrayOf value "sets").mapM Set.ofJson? }

/-- The document the bytes of its file hold, or why they hold none. -/
def Document.read (bytes : ByteArray) : Except String Document := do
  Document.ofJson? (← Json.parse bytes)

/-! ## Where a workspace keeps it -/

/-- The directory name of the workspace whose root is `root`: the root with
`%` written `%25` and `/` written `%2F`. -/
def key (root : String) : String :=
  root.foldl (init := "") fun out character =>
    match character with
    | '%' => out ++ "%25"
    | '/' => out ++ "%2F"
    | character => out.push character

/-- The directory the workspace whose root is `root` keeps its state in,
under the state directory `state`. -/
def storeDirectory (state : System.FilePath) (root : String) : System.FilePath :=
  state / "workspaces" / key root

/-- The file the workspace whose root is `root` keeps its working sets in,
under the state directory `state`. -/
def storeFile (state : System.FilePath) (root : String) : System.FilePath :=
  storeDirectory state root / "working-sets.json"

/-! ## Headers and excerpts -/

/-- The header of an excerpt of placed ranges of the file `path`, starting
on `line`: the path and the line, ` · changed` when a range of it was found
with errors, and each note that is not empty. -/
def header (path : String) (line : Nat) (changed : Bool) (notes : Array String) : String :=
  let parts :=
    #[s!"{path}:{line}"] ++ (if changed then #["changed"] else #[]) ++ notes.filter (!·.isEmpty)
  " · ".intercalate parts.toList

/-- The header of a drifted range's excerpt: its path and the line it was
stored at, `drifted`, the first eight characters of its commit when it has
one, and its note when it has one. -/
def driftedHeader (stored : Stored) : String :=
  let since :=
    if stored.commit.isEmpty then "" else s!" since {String.ofList (stored.commit.toList.take 8)}"
  let note := if stored.note.isEmpty then "" else s!" · {stored.note}"
  s!"{stored.path}:{stored.start.line} · drifted{since}{note}"

/-- An excerpt of a set's buffer, before it is made: the file it is of, its
first and its last row (0-based), and the indices of the ranges in it, in
order of their first rows. -/
structure Excerpt where
  /-- The file, as the ranges name it. -/
  path : String
  /-- Its first row. -/
  first : Nat
  /-- Its last row. -/
  last : Nat
  /-- The indices of its ranges among those given. -/
  ranges : Array Nat
  deriving DecidableEq, Repr

/-- The excerpts of `ranges`, each a file and its first and last row
(0-based), in the module docs' order: by file, in the order of each file's
first range; within a file by first row, ranges whose rows overlap or touch
in one excerpt. -/
def excerpts (ranges : Array (String × Nat × Nat)) : Array Excerpt :=
  Id.run do
    let mut files : Array String := #[]
    for (path, _, _) in ranges do
      unless files.contains path do
        files := files.push path
    let mut found := #[]
    for path in files do
      let indices := (Array.range ranges.size).filter fun index => ranges[index]!.1 == path
      let sorted :=
        indices.qsort fun a b =>
          ranges[a]!.2.1 < ranges[b]!.2.1 || (ranges[a]!.2.1 == ranges[b]!.2.1 && a < b)
      let mut merged : Array Excerpt := #[]
      for index in sorted do
        let (_, first, last) := ranges[index]!
        match merged.back? with
        | some excerpt =>
          if first ≤ excerpt.last + 1 then
            merged :=
              merged.pop.push
                { excerpt with
                  last := max excerpt.last last, ranges := excerpt.ranges.push index }
          else
            merged := merged.push { path, first, last, ranges := #[index] }
        | none =>
          merged := merged.push { path, first, last, ranges := #[index] }
      found := found ++ merged
    return found

/-! ## What is said -/

/-- The name of the buffer a set named `name` of the workspace labelled
`label` opens as. -/
def bufferName (name label : String) : String :=
  s!"*working-set: {name} in {label}*"

/-- The prompt that asks which set to add to. -/
def addPrompt (label : String) : String :=
  s!"Add to working set ({label}): "

/-- The prompt that asks which set to open. -/
def openPrompt (label : String) : String :=
  s!"Open working set ({label}): "

/-- What is said when a set's store cannot be read. -/
def unreadableSentence (label : String) (path : System.FilePath) (reason : String) : String :=
  s!"working sets of {label}: {path} cannot be read: {reason}; it is left as it is"

/-- What is said once a run, at the first add, when there is no state
directory. -/
def memoryOnlySentence : String :=
  "working sets are not kept across restarts: no state directory"

/-- What is said when a range is in the set already. -/
def alreadyIn (name : String) : String :=
  s!"already in {name}"

/-- What is said when a selection's ends are in two files. -/
def spansTwoFiles : String :=
  "working-set-add: the selection spans two files"

/-- What is said when the selection's text has no file. -/
def noFile (buffer : String) : String :=
  s!"working-set-add: {buffer} has no file"

/-- What is said when a range is added to a set. -/
def addedSentence (name path : String) (line : Nat) : String :=
  s!"{name}: added {path}:{line}"

/-- What `command` says when the buffer `buffer` is in no workspace. -/
def noWorkspace (command buffer : String) : String :=
  s!"{command}: {buffer} has no workspace"

/-- What is said when the workspace labelled `label` has no set `name`. -/
def noSuchSet (name label : String) : String :=
  s!"working-set-open: no working set {name} in {label}"

/-- What is said when a set opens. -/
def openedSentence (name : String) (count drifted : Nat) : String :=
  s!"{name}: {count} ranges, {drifted} drifted"

/-- What is said when a workspace's sets could not be saved. -/
def notSavedSentence (label reason : String) : String :=
  s!"working sets of {label} not saved: {reason}"

end Editor.WorkingSet
