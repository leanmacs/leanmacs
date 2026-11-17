import Editor.Value

/-!
# Error formats: locations in a compilation's output

What the compile mode (`Editor/Compile.lean`, "Locations") finds in the
lines of a compilation's output: a file, a line, maybe a column, and a
severity. Pure Lean with no outside world, so it is its own model and has
no port, and free of the editor API, so that a minor mode's config can name
and build formats (phase 5 of the shell-and-compile roadmap).

## Formats are data

An error format (`Format`) is a record: its name; a pattern over one
output line (`Pattern`), whose pieces say which part of the line gives the
file, the line, the column, the severity and the message (`Part`);
optionally a pattern of a following line that continues it
(`continuation`); optionally a pattern of the line before it that gives its
severity and message (`lead`), for a tool that prints the location on the
line after its message, as rustc does; the words that name each severity
(`severities`, `Severity.words` by default) and the severity of a line that
names none (`severity`, an error by default); and what the tool calls the
first column (`columnBase`, 1 by default, as GNU and rustc count; Lean
counts from 0). A field a later format needs is added with a default, so
every existing format is unchanged.

## The matcher

A pattern (`Pattern.match?`) is a list of steps, each a sequence of
pieces, and anchored at both ends of the line. A piece is an atom
(`Atom`): a literal; one or more digits; one or more blanks (spaces or
tabs); one or more characters none of which is in a list; one of a list of
words, tried in order; or the rest of the line, maybe nothing. A piece may
capture its text as a part. An optional step is tried matched first, then
skipped. A variable-length atom tries its longest match first, then
shorter ones, and the first complete match in that order wins. A captured
part keeps its text and its byte range in the line.

It is written by recursion on the steps and pieces, over the line's
characters as an array, so trying a shorter match costs nothing to set up.
For the general format each attempt that is not the longest fails at the
next literal in one character, so a line costs time linear in its length
(a line may be as long as `Compile.lineBound`, a mebibyte).

**Why the editor's own matcher, not a regex behind a port.** The one regex
in the tree is the search port's (`crates/editor-search`): it answers match
ranges only, with no submatches, so it cannot say which part is the file
or the line; its text model answers literal patterns alone
(`docs/design/rust-library.md`, "Search, as built"), so these formats
could not be checked on the models; and it searches a text or a snapshot,
where locations are read from output lines as strings before they are any
text. A format this matcher cannot express is the measured problem that
would put a regex behind a port.

## The general format

`Format.general`, the format every run falls back to; the tool-specific
formats (rustc's, Lean's) ship in `Editor/Compile/Shipped.lean`. It reads
GNU's `file:line:col: message` and `file:line: message`, with an optional
`error`, `warning` or `note` after the location. The file stops at a colon,
a space or a tab, so a compilation's header (`r@main in /r: make`), an
indented help line and its last line are no locations. A line that names
no severity is an error.

## Reading, sites and `scan`

- **A reading** (`Format.read?`) is what one line gives: the file and the
  line, both required, the column if captured, the line and column as
  printed (not rebased), the severity, the message if captured, and the
  byte range that gets a face, from the start of the earliest of the file,
  line and column to the end of the latest. Handed a lead's captures, it
  takes the severity and the message from the lead where the line captures
  none.
- **A site** (`Site`) is a location of a compilation: the resolved file,
  the line and column as printed and the format's column base, the
  severity, the format's name (for its continuation), the compilation
  buffer's rows it covers, `first` through `last`, the byte range of its
  location text in that buffer, and its message, if its format read one.
  The message is data only: nothing says it yet. A site's tree written
  before messages were kept has no `message` field and reads with none, so
  the stores keep their version. It is called a site because
  `Editor.Location` is a workspace's location.
- **`resolve`** keeps an absolute file and joins a relative one to the
  compilation's directory, then drops `.` components and has `..` remove the
  component before it, lexically, with no file system: so the path is the
  string `EditorState.findFile` compares.
- **`scan`** finds the sites of lines appended at a row and a byte offset of
  the compilation buffer, one row each. A line that the last site's
  format's continuation matches, on the row after that site's last, joins
  it; otherwise the first format whose reading answers makes a new site.
  When that format has a lead, the line before matches it and no site
  covers that line's row (`leadOf`), the site starts at the lead's row and
  takes the lead's severity and message where its own line gives none; its
  location text stays its own line's. The line before the first of `lines`
  is handed in (`previous`). The join and the lead need nothing but the
  sites and that line, so lines that arrive in two posts give the sites
  they give in one.

Pinned by `ModelTest.compileErrorChecks`.
-/

namespace Editor.Compile

/-- How bad a location is. -/
inductive Severity where
  /-- An error. -/
  | error
  /-- A warning. -/
  | warning
  /-- A note. -/
  | note
  deriving DecidableEq, Repr

/-- The severity's name, as it crosses in a tree. -/
def Severity.name : Severity → String
  | .error => "error"
  | .warning => "warning"
  | .note => "note"

/-- The severity a name is (`Severity.name`), if it is one. -/
def Severity.ofName? : String → Option Severity
  | "error" => some .error
  | "warning" => some .warning
  | "note" => some .note
  | _ => none

/-- The words that name each severity, as GNU's tools write them. -/
def Severity.words : List (String × Severity) :=
  [("error", .error), ("warning", .warning), ("note", .note)]

/-- What a captured piece's text gives. -/
inductive Part where
  /-- The file. -/
  | file
  /-- The line. -/
  | line
  /-- The column. -/
  | column
  /-- The severity's word. -/
  | severity
  /-- The location's message. -/
  | message
  deriving DecidableEq, Repr

/-- What one piece of a pattern matches. -/
inductive Atom where
  /-- Exactly `text`. -/
  | literal (text : String)
  /-- One or more of `0` to `9`. -/
  | digits
  /-- One or more spaces or tabs. -/
  | blanks
  /-- One or more characters, none of them in `excluded`. -/
  | noneOf (excluded : List Char)
  /-- One of `words`, tried in order. -/
  | oneOf (words : List String)
  /-- Every character to the line's end, maybe none. -/
  | rest
  deriving DecidableEq, Repr

/-- A piece of a pattern: an atom, and the part its text gives, if any. -/
structure Piece where
  /-- What it matches. -/
  atom : Atom
  /-- The part its text gives. -/
  into : Option Part := none
  deriving DecidableEq, Repr

/-- A step of a pattern: pieces in sequence, all of them or, for an
optional step, maybe none. -/
structure Step where
  /-- Its pieces. -/
  pieces : List Piece
  /-- Whether it may be skipped. -/
  optional : Bool := false
  deriving DecidableEq, Repr

/-- A pattern over one line, anchored at both ends ("The matcher", in the
module docs). -/
abbrev Pattern :=
  List Step

/-- An error format ("Formats are data", in the module docs). -/
structure Format where
  /-- Its name. -/
  name : String
  /-- The pattern of a location's line. -/
  pattern : Pattern
  /-- The pattern of a following line that continues a location. -/
  continuation : Option Pattern := none
  /-- The words that name each severity. -/
  severities : List (String × Severity) := Severity.words
  /-- The severity of a line with no severity part, or a word not in
  `severities`. -/
  severity : Severity := .error
  /-- What the tool calls the first column. -/
  columnBase : Nat := 1
  /-- The pattern of the line before a location's line that gives its
  severity and message, as rustc prints `error[E0308]: mismatched types`
  before ` --> src/main.rs:4:18`; none for a format whose location is on its
  message's line. -/
  lead : Option Pattern := none
  deriving DecidableEq, Repr

/-- A part a match captured: its text and its byte range in the line. -/
structure Capture where
  /-- The part. -/
  part : Part
  /-- Its text. -/
  text : String
  /-- The byte offset where it starts. -/
  start : Nat
  /-- The byte offset where it stops, not included. -/
  stop : Nat
  deriving DecidableEq, Repr

/-- What a match captured, in the order of the pieces. -/
abbrev Captures :=
  Array Capture

/-- A line as the matcher reads it: its characters, and the byte offset
each starts at, with the line's length last. -/
structure Line where
  /-- Its characters. -/
  chars : Array Char
  /-- The byte offset of each character, then the line's length. -/
  offsets : Array Nat

/-- `text` as the matcher reads it. -/
def Line.of (text : String) : Line :=
  let chars := text.toList.toArray
  { chars
    offsets :=
      chars.foldl (fun offsets char => offsets.push ((offsets.back?.getD 0) + char.utf8Size)) #[0] }

/-- Where the run of characters that `holds` from `start` stops. -/
def Line.runEnd (line : Line) (holds : Char → Bool) (start : Nat) : Nat :=
  Id.run do
    let mut stop := start
    for index in [start:line.chars.size] do
      if line.chars[index]?.any holds then
        stop := index + 1
      else
        break
    return stop

/-- Whether `word` is at the character `start` of the line. -/
def Line.hasAt (line : Line) (start : Nat) (word : String) : Bool :=
  word.toList.zipIdx.all fun (char, index) => line.chars[start + index]? == some char

/-- Where an atom's match from the character `start` can stop, the one
tried first first ("The matcher", in the module docs). -/
def Atom.stops (atom : Atom) (line : Line) (start : Nat) : List Nat :=
  let run (holds : Char → Bool) : List Nat :=
    let stop := line.runEnd holds start
    (List.range (stop - start)).map (stop - ·)
  match atom with
  | .literal text => if line.hasAt start text then [start + text.length] else []
  | .digits => run Char.isDigit
  | .blanks => run fun char => char == ' ' || char == '\t'
  | .noneOf excluded => run fun char => !excluded.contains char
  | .oneOf words =>
    words.filterMap fun word => if line.hasAt start word then some (start + word.length) else none
  | .rest => if start ≤ line.chars.size then [line.chars.size] else []

/-- How much is left of `steps` to match: one for each step and each of its
pieces. -/
def weight (steps : List Step) : Nat :=
  (steps.map (·.pieces.length + 1)).sum

/-- The captures of the first complete match of `steps` from the character
`start` of `line` to its end, after `captures`, which hold character
indices in place of byte offsets and an empty text. -/
def matchFrom (line : Line) : List Step → Nat → Captures → Option Captures
  | [], start, captures => if start == line.chars.size then some captures else none
  | { pieces := [], .. } :: steps, start, captures => matchFrom line steps start captures
  | { pieces := piece :: pieces, optional } :: steps, start, captures =>
    let taken :=
      (piece.atom.stops line start).findSome? fun stop =>
        matchFrom line ({ pieces } :: steps) stop
          (match piece.into with
          | some part => captures.push { part, text := "", start, stop }
          | none => captures)
    if optional then taken <|> matchFrom line steps start captures else taken
termination_by steps => weight steps
decreasing_by all_goals simp [weight]

/-- The captures of the first match of `pattern` over the whole of `text`
("The matcher", in the module docs), if it matches. -/
def Pattern.match? (pattern : Pattern) (text : String) : Option Captures :=
  let line := Line.of text
  (matchFrom line pattern 0 #[]).map fun captures =>
    captures.map fun capture =>
      { capture with
        text := String.ofList (line.chars.extract capture.start capture.stop).toList
        start := line.offsets[capture.start]?.getD 0
        stop := line.offsets[capture.stop]?.getD 0 }

/-- What one line gives ("Reading, sites and `scan`", in the module
docs). -/
structure Reading where
  /-- The file, as printed. -/
  file : String
  /-- The line, as printed. -/
  line : Nat
  /-- The column, as printed, if there is one. -/
  column : Option Nat
  /-- The severity. -/
  severity : Severity
  /-- The byte offset where the location's text starts. -/
  start : Nat
  /-- The byte offset where it stops, not included. -/
  stop : Nat
  /-- The message, if the line or its lead captured one. -/
  message : Option String := none
  deriving DecidableEq, Repr

/-- What `format` reads in `text`, if its pattern matches and captures a
file and a line. With `lead`, the captures of the format's lead on the line
before, a part the line does not capture is taken from the lead: its
severity and its message. -/
def Format.read? (format : Format) (text : String) (lead : Captures := #[]) : Option Reading := do
  let captures ← format.pattern.match? text
  let of (part : Part) : Option Capture :=
    (captures.find? (·.part == part)).orElse fun _ => lead.find? (·.part == part)
  let file ← captures.find? (·.part == .file)
  let line ← captures.find? (·.part == .line)
  let lineNumber ← line.text.toNat?
  let column := captures.find? (·.part == .column)
  let severity :=
    ((of .severity).bind fun word => (format.severities.find? (·.1 == word.text)).map (·.2)).getD
      format.severity
  let spans := #[file, line] ++ column.toArray
  return {
      file := file.text, line := lineNumber, column := column.bind (·.text.toNat?), severity
      start := (spans.map (·.start)).foldl min file.start
      stop := (spans.map (·.stop)).foldl max file.stop, message := (of .message).map (·.text) }

/-- A step of the pieces `pieces`. -/
def step (pieces : List Piece) : Step :=
  { pieces }

/-- An optional step of the pieces `pieces`. -/
def optionalStep (pieces : List Piece) : Step :=
  { pieces, optional := true }

/-- The general format ("The general format", in the module docs). -/
def Format.general : Format :=
  { name := "general"
    pattern :=
      [step
          [{ atom := .noneOf [':', ' ', '\t'], into := some .file }, { atom := .literal ":" },
            { atom := .digits, into := some .line }],
        optionalStep [{ atom := .literal ":" }, { atom := .digits, into := some .column }],
        step [{ atom := .literal ":" }],
        optionalStep
          [{ atom := .blanks },
            { atom := .oneOf ["error", "warning", "note"], into := some .severity },
            { atom := .literal ":" }],
        step [{ atom := .rest }]] }

/-- A location of a compilation ("Reading, sites and `scan`", in the module
docs). -/
structure Site where
  /-- The file, resolved against the compilation's directory. -/
  file : System.FilePath
  /-- The line, as printed. -/
  line : Nat
  /-- The column, as printed, if there is one. -/
  column : Option Nat
  /-- What the format calls the first column. -/
  columnBase : Nat
  /-- The severity. -/
  severity : Severity
  /-- The name of the format that found it. -/
  format : String
  /-- The first row of the compilation buffer it covers, from 0. -/
  first : Nat
  /-- The last row it covers. -/
  last : Nat
  /-- The byte offset in the compilation buffer where its location's text
  starts. -/
  start : Nat
  /-- The byte offset where it stops, not included. -/
  stop : Nat
  /-- Its message, if its format read one. -/
  message : Option String := none
  deriving DecidableEq, Repr

/-- An optional value as a tree: `null` for none. -/
def optional {α : Type} (encode : α → Value) : Option α → Value
  | some value => encode value
  | none => .null

/-- The field `name` of `fields`. -/
def field (fields : List (String × Value)) (name : String) : Value :=
  ((fields.find? (·.1 == name)).map (·.2)).getD .null

/-- A site as a tree. -/
def Site.encode (site : Site) : Value :=
  .record
    [("file", .str site.file.toString), ("line", .nat site.line),
      ("column", optional .nat site.column), ("columnBase", .nat site.columnBase),
      ("severity", .str site.severity.name), ("format", .str site.format),
      ("first", .nat site.first), ("last", .nat site.last), ("start", .nat site.start),
      ("stop", .nat site.stop), ("message", optional .str site.message)]

/-- The site a tree is (`Site.encode`), if it is one. -/
def Site.decode : Value → Option Site
  | .record fields => do
    let .str file := field fields "file" | none
    let .nat line := field fields "line" | none
    let column ←
      match field fields "column" with
      | .nat n =>
        some (some n)
      | .null =>
        some none
      | _ =>
        none
    let .nat columnBase := field fields "columnBase" | none
    let .str severity := field fields "severity" | none
    let severity ← Severity.ofName? severity
    let .str format := field fields "format" | none
    let .nat first := field fields "first" | none
    let .nat last := field fields "last" | none
    let .nat start := field fields "start" | none
    let .nat stop := field fields "stop" | none
    -- A site written before messages were kept has no field, which reads
    -- as `null`.
    let message ←
      match field fields "message" with
      | .str text =>
        some (some text)
      | .null =>
        some none
      | _ =>
        none
    return { file, line, column, columnBase, severity, format, first, last, start, stop, message }
  | _ => none

/-- `file` resolved against `directory` ("Reading, sites and `scan`", in the
module docs). -/
def resolve (directory : System.FilePath) (file : String) : System.FilePath :=
  let joined : System.FilePath :=
    if (file : System.FilePath).isAbsolute then file else directory / file
  let kept :=
    (joined.toString.splitOn "/").foldl
      (fun (kept : Array String) part =>
        if part == "" || part == "." then kept
        else if part == ".." then kept.pop else kept.push part)
      #[]
  let path := "/".intercalate kept.toList
  if joined.isAbsolute then "/" ++ path else path

/-- The captures of `format`'s lead on `previous`, the text of the row
before `row`, when it has a lead that matches and no site of `sites` covers
that row ("Reading, sites and `scan`", in the module docs). -/
def leadOf (format : Format) (sites : Array Site) (row : Nat) (previous : Option String) :
    Option Captures := do
  let pattern ← format.lead
  let text ← previous
  guard (row ≥ 1 && sites.back?.all (·.last + 1 < row))
  pattern.match? text

/-- The sites after `lines`, appended at the row `row` and the byte offset
`offset` of the compilation buffer, one row each, are found with `formats`
after `sites`, relative files resolving against `directory`; `previous` is
the text of the row before `row`, if it is one of the output's ("Reading,
sites and `scan`", in the module docs). -/
def scan (formats : Array Compile.Format) (directory : System.FilePath) (sites : Array Site)
    (row offset : Nat) (lines : Array String) (previous : Option String := none) : Array Site :=
  (lines.foldl
      (fun (state : Array Site × Nat × Nat × Option String) (text : String) =>
        let (sites, row, offset, previous) := state
        let continued :=
          match sites.back? with
          | some last =>
            last.last + 1 == row &&
              ((formats.find? fun (format : Compile.Format) => format.name == last.format).bind
                    (·.continuation)).any
                fun (pattern : Pattern) => (pattern.match? text).isSome
          | none => false
        let sites :=
          if continued then sites.modify (sites.size - 1) fun last => { last with last := row }
          else
            match
              formats.findSome? fun (format : Compile.Format) =>
                (format.read? text).map (format, ·) with
            | some (format, reading) =>
              let lead := leadOf format sites row previous
              let reading := (lead.bind (format.read? text ·)).getD reading
              sites.push
                { file := resolve directory reading.file, line := reading.line
                  column := reading.column, columnBase := format.columnBase
                  severity := reading.severity, format := format.name
                  first := if lead.isSome then row - 1 else row, last := row
                  start := offset + reading.start, stop := offset + reading.stop
                  message := reading.message }
            | none => sites
        (sites, row + 1, offset + text.utf8ByteSize + 1, some text))
      (sites, row, offset, previous)).1

end Editor.Compile
