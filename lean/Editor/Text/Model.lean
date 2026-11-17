import Editor.Text

/-!
# The pure model of the text port

The text store as a value: the texts and the snapshots made so far, and a
pure function that answers each request of the port (`Editor/Text.lean`).
Editor logic is tested against it, with no Rust library, and theorems about
commands are stated about `TextM.runModel`.

A text is a string and a revision. A snapshot is a copy of that pair, so
that a snapshot is unaffected by later edits holds of the model by
construction. A text made of what a text or a snapshot holds
(`TextModel.copy`) is a new text made of the source's string, exactly as
`create` makes one of a string (`TextModel.made`), so that it has nothing
else of its source holds by construction too. The library shares the rope
and copies no text; the model copies the string.

What a job held when it ended reaches its command as a value
(`TextModel.arrived`): each snapshot as the job's name for it and its
content. It is not part of the store. Whoever plays a job's command fills it
for that run and empties it after; `adopt` reads it and copies a content
into the snapshots. So "a run is handed what the job held" is, in the
model, handing the run that value, and nothing a job made is in the store
unless a command put it there. Rows and points are found by walking the string's characters,
which is slow and plainly right: the model is what the library is compared
with, not what the editor runs on.

A transaction's changes are applied as the ranges they change
(`TextModel.runsOf`): one range for each stretch of deletes and inserts
between two retains, each spliced into the string as an insert or a delete
is. The library keeps its changes in a normal form and walks them; the model
never builds that form, so the two reach the same text by different routes.

A text's edit log is modelled beside the texts (`TextModel.logs`), not
inside them, so a snapshot carries none. The model of a log (`TextLog`) is
not a log at all: it keeps who wrote every byte of the text as it is now,
each byte with an identity no other byte ever had, and the whole text at
every revision it has had. What changed since a revision is then the gaps
between the bytes the two states share, and who wrote a range is read off
its bytes. The library keeps neither: it composes the ranges each edit
recorded, and walks its entries back. That two such different routes give
the same patch and the same trace is what the contract checks. The model is
quadratic and forgets nothing; it runs on texts of tens of bytes.

A text's markers are modelled beside the texts too (`TextModel.markers`):
one table a text, in which a marker's id is an index, with the text the
table is of: an id of another text names nothing in it
(`TextModel.heldUnder?`). Every accepted edit
goes through `TextModel.changed`, which moves each marker through the
ranges the edit changed (`TextModel.mapOffset`): the same runs the text is
spliced by, and not the library's walk of its changes. The form a selection
is kept in (`TextModel.normal`) is a sort and one pass over the ranges, on
plain offsets.

What a text keeps of its edits so that they can be taken back is modelled
beside the texts as well (`TextModel.histories`, a `TextHistory` a text),
and the model keeps no inverse at all. The text the inverse of a run leaves
is read, not computed: the log's model already holds the text at every
revision. What the inverse changed, for the log and the markers, is the gaps
between the bytes the text at the run's last revision and the text before
its first share, by the identities the log's model gives every byte
(`TextHistory.runsBetween`), and it goes through `TextModel.changed` like
any edit. The library composes the inverses it kept of each edit of the run.
Whether an inverse is allowed is decided as the library decides it, by the
name of the state the text was in at each revision, which the history keeps
with the selections each edit carried and which inverses were dropped.

What a selection covers (`TextModel.extents`) is read off the string's rows
(`TextModel.rowsOf`), each with the cells of its content, found in one walk
of its characters. A block's columns are indexes into a row's cells. The
library walks its rope a cell at a time and keeps no such table.

One row's content and a range of a text are read as the characters that
start between two offsets (`TextModel.between`), found by walking the whole
string; the library reads the pieces of the range and no others.

A motion (`TextModel.motion?`) is answered by listing first and picking
after: every cell start of the text, or its rows with their cells, read off
`TextModel.rowsOf`, and then the first after the position or the last before
it. The library lists nothing: it walks its rope from the position, a cell
at a time. The line start is the model's own conversions: the offset of
column 0 of the position's row. Two theorems are stated about them at the
end of this module: a conversion that answers is undone by the other
(`TextModel.offsetOf_pointOf`), and so the line start of a line start is
itself (`TextModel.lineStart_idempotent`).

An excerpt text is modelled beside the texts (`TextModel.excerpts`): its
content, and for each excerpt its source, the indexes of its two anchors in
the source's table of markers, the source's revision it last read and its
range then (`ExcerptPiece`). **Between requests its slot in `TextModel.texts`
is empty**; a request that names it lends it its content there
(`TextModel.onText`), catches it up first (`TextModel.caughtUp`), answers as
for any text and takes the content back. So an inverse, an edit script and a
trace of it find no text there and are refused with `excerpted` by
`TextModel.lookup` alone, and a hypothesis that a text's slot holds content
says it is a plain text: every theorem about plain texts stands as it was.
An insert, a delete and a transaction go through `TextModel.editAny`, which
takes today's path for a text whose slot holds content and lends an excerpt
text for `TextModel.excerptApply`: the plain checks on what it holds, the
runs mapped to its sources by the library's rule (`TextModel.excerptEdits`),
each source given its runs through `TextModel.changed` like any edit, and
then one catch-up. A catch-up cuts the source's patch to each excerpt by the
rule the library uses (`TextModel.clipped`) and goes through
`TextModel.changed` like any edit. A source that is released while an
excerpt text reads it is kept as it was (`TextModel.retired`), its log
staying where it is, and an edit through the excerpt text no longer reaches
it.

The contract (`Editor/Text/Contract.lean`) is what says the model and the real
binding agree. A clause added to `TextModel.handle`, to `TextModel.answer` or
to `TextModel.answerLog` needs its property there.
-/

namespace Editor

/-- What a text holds at one revision: the model of a text, and of a
snapshot. -/
structure TextContent where
  /-- The text. -/
  contents : String
  /-- How many edits the text had accepted. -/
  revision : Nat := 0
  deriving DecidableEq, Repr

/-- One byte of a text, as the model of its edit log knows it. -/
structure Cell where
  /-- The byte's identity: a number no other byte of the text ever had. -/
  id : Nat
  /-- The revision whose edit inserted the byte: 0 for a byte the text was
  made with. -/
  revision : Nat
  deriving Repr

/-- The model of a text's edit log. It keeps far more than a log would, and
is plainly right for it: who wrote every byte of the text, and the whole text
at every revision it has had. -/
structure TextLog where
  /-- One cell for each byte of the text as it is now, in order. -/
  cells : Array Cell := #[]
  /-- The identity the next byte inserted gets. -/
  nextId : Nat := 0
  /-- The origin of each edit: the one that produced the revision `r` is at
  `r - 1`. -/
  origins : Array Origin := #[]
  /-- The text at every revision before the one it is at: what it held, and
  the identities of its bytes. The revision `r` is at `r`. -/
  past : Array (String × Array Nat) := #[]
  /-- Where the log starts: the revision it was last forgotten up to, and 0
  until then. -/
  horizon : Nat := 0
  deriving Repr

/-- The model of what a text keeps of its edits so that they can be taken
back. It keeps no inverse at all: the text an inverse leaves is read off the
log's model, which holds the text at every revision. What is here is what
decides whether an inverse is allowed and what it hands back. Each array is
indexed by revision, with a slot for revision 0, which no edit produced. It
forgets nothing. -/
structure TextHistory where
  /-- The name of the state the text was in at each revision: the revision
  of the edit that first put it there. An edit names a new state, and the
  inverse of a run copies the name the text had before the run. -/
  names : Array Nat := #[0]
  /-- The selection before and the selection after that the edit which
  produced each revision carried, in the form the store keeps one in. -/
  carried : Array (Option Selection × Option Selection) := #[(none, none)]
  /-- Whether the inverse of each revision was dropped. -/
  dropped : Array Bool := #[false]
  deriving Repr

/-- One excerpt of an excerpt text, as the model keeps it. -/
structure ExcerptPiece where
  /-- The source. -/
  source : TextId
  /-- The index of its start anchor in the source's table of markers. -/
  start : Nat
  /-- The index of its end anchor there. -/
  stop : Nat
  /-- The source's revision when the excerpt last read it. -/
  seen : Nat
  /-- The range of the source the excerpt holds, at `seen`. -/
  range : Nat × Nat
  deriving Repr

/-- The model of an excerpt text beside its text: its content between two
requests, and its excerpts. -/
structure ExcerptModel where
  /-- What the text holds, while no request has lent it to the texts. -/
  content : TextContent := { contents := "" }
  /-- The excerpts, in order. -/
  pieces : Array ExcerptPiece := #[]
  deriving Repr

/-- The model of the text store: every text and every snapshot made so far.
An id is an index here, and a slot is `none` once its text or its snapshot
has been released, so an id is never used again. -/
structure TextModel where
  /-- The texts, in the order they were made. -/
  texts : Array (Option TextContent) := #[]
  /-- The snapshots, in the order they were taken. -/
  snapshots : Array (Option TextContent) := #[]
  /-- The text each snapshot was taken of, by snapshot id: `none` for one
  adopted from a job, and for one this array has no slot for. It is what
  another model that keeps something per text reads to tell two snapshots
  of one text from two texts (`EditorModel.snapshotDocuments`). -/
  snapshotOf : Array (Option TextId) := #[]
  /-- The edit log of each text, in the order the texts were made. It is
  beside the texts and not inside them, so that a snapshot, which is a copy
  of a text's content, carries none. -/
  logs : Array TextLog := #[]
  /-- The markers of each text, in the order the texts were made: a table a
  text, in which a marker's id is an index and a slot is `none` once its
  marker has been given up. It is beside the texts for the reason the logs
  are: a snapshot carries none. -/
  markers : Array (Array (Option Marker)) := #[]
  /-- What each text keeps of its edits so that they can be taken back, in
  the order the texts were made. It is beside the texts for the reason the
  logs are: a snapshot carries none. -/
  histories : Array TextHistory := #[]
  /-- The snapshots this run was handed: what a job held when it ended, each
  under the job's name for it. It is empty unless whoever runs a job's
  command fills it for that run, and it is not part of the store: `adopt`
  reads it and nothing writes it. -/
  arrived : Array (JobSnapshotId × TextContent) := #[]
  /-- Each excerpt text, by text id: `none` for a text that is not one, and
  for one this array has no slot for. An excerpt text's slot in `texts` is
  empty between requests (the module docs say why). -/
  excerpts : Array (Option ExcerptModel) := #[]
  /-- Each source that was released while an excerpt text read it, by text
  id: what it held and its markers when it was released. -/
  retired : Array (Option (TextContent × Array (Option Marker))) := #[]
  /-- The list of the excerpt text each snapshot was taken of, by snapshot
  id, as it was placed when the snapshot was taken: `none` for a snapshot
  of a plain text, one adopted from a job, and one this array has no slot
  for. -/
  snapshotPlaced : Array (Option (Array Excerpt.Placed)) := #[]
  deriving Repr

namespace TextModel

/-- What each text that has not been released holds, in the order they were
made. This is what a test compares, where the revisions do not matter. -/
def contents (model : TextModel) : Array String :=
  model.texts.filterMap (·.map (·.contents))

/-- What `source` names: the text as it is now, or the snapshot. The refusal
when it names nothing, or something that was released. -/
def lookup (model : TextModel) : TextSource → Except TextError TextContent
  | .text id =>
    match model.texts[id.index]? with
    | some (some content) => .ok content
    | _ =>
      if ((model.excerpts[id.index]?).join).isSome then .error .excerpted else .error .noSuchText
  | .snapshot id =>
    match model.snapshots[id.index]? with
    | some (some content) => .ok content
    | _ => .error .noSuchSnapshot

/-- `text` with its bytes from `start` up to, not including, `stop` replaced by
`s`. `none` unless both offsets are character boundaries of `text`, within
it, and `start ≤ stop`: the ranges the port refuses. -/
def splice (text : String) (start stop : Nat) (s : String) : Option String :=
  if valid :
      (String.Pos.Raw.mk start).IsValid text ∧
        (String.Pos.Raw.mk stop).IsValid text ∧ start ≤ stop then
    some
      ((text.sliceTo (text.pos ⟨start⟩ valid.1)).copy ++ s ++
        (text.sliceFrom (text.pos ⟨stop⟩ valid.2.1)).copy)
  else none

/-- How many rows `text` has: one more than its line feeds. -/
def rowCount (text : String) : Nat :=
  (text.toList.filter (· == '\n')).length + 1

/-- How wide `c` is in a column counted in `unit`: its bytes of UTF-8, its
UTF-16 code units, which are two for a character outside the Basic
Multilingual Plane, or one cell.

Within a row every character starts a cell: a row's line feed is not walked
as a column, and the carriage return before it starts the line break's cell.
So the position between that carriage return and its line feed is one column
past the carriage return's, with the line break's cell before it, which is
what counting each character as one gives. -/
def width (unit : ColumnUnit) (c : Char) : Nat :=
  match unit with
  | .bytes => c.utf8Size
  | .utf16 => if c.val < 0x10000 then 1 else 2
  | .cells => 1

/-- The point of the byte offset `offset` in `text`, with its column in
`unit`. `none` unless the offset is a position: a character boundary of the
text, within it. -/
def pointOf (unit : ColumnUnit) (text : String) (offset : Nat) : Option Point :=
  go text.toList 0 ⟨0, 0⟩
where
  /-- Walks the characters that are left. `here` is the byte offset reached
  and `point` the point of it. -/
  go : List Char → Nat → Point → Option Point
    | [], here, point => if here == offset then some point else none
    | c :: rest, here, point =>
      if here == offset then some point
      else
        if here > offset then none
        else
          go rest (here + c.utf8Size)
            (if c == '\n' then ⟨point.row + 1, 0⟩ else ⟨point.row, point.column + width unit c⟩)

/-- The byte offset of `point` in `text`, where the point's column is in
`unit`. `none` unless the point names a position: a row the text has, and a
column within the row that is not inside a character. -/
def offsetOf (unit : ColumnUnit) (text : String) (point : Point) : Option Nat :=
  go text.toList 0 ⟨0, 0⟩
where
  /-- Walks the characters that are left. `offset` is the byte offset reached
  and `here` the point of it. At a line feed the walk is at the end of a row:
  if that is the row asked for, its columns have all been passed. -/
  go : List Char → Nat → Point → Option Nat
    | [], offset, here => if here == point then some offset else none
    | c :: rest, offset, here =>
      if here == point then some offset
      else
        if c == '\n' then
          if here.row == point.row then none else go rest (offset + c.utf8Size) ⟨here.row + 1, 0⟩
        else go rest (offset + c.utf8Size) ⟨here.row, here.column + width unit c⟩

/-- One changed range of a transaction: the bytes of the text before from
`start` up to, not including, `stop` are replaced by `inserted`. -/
structure Run where
  /-- Where the range starts, in the text before. -/
  start : Nat
  /-- Where the range stops, in the text before. -/
  stop : Nat
  /-- What takes its place. -/
  inserted : String
  deriving Repr

/-- What `changes` change, and how far into the text they reach: one run for
each stretch of deletes and inserts between two retains, in order. Changes
that do nothing are passed over, so they neither start a run nor end one. -/
def runsOf (changes : Array Change) : Array Run × Nat :=
  go changes.toList 0 #[] false
where
  /-- Walks the changes that are left. `offset` is how far into the text
  before the walk is, and `inRun` says whether the last run is still being
  added to. -/
  go : List Change → Nat → Array Run → Bool → Array Run × Nat
    | [], offset, runs, _ => (runs, offset)
    | .retain count :: rest, offset, runs, inRun =>
      go rest (offset + count) runs (inRun && count == 0)
    | .delete count :: rest, offset, runs, inRun =>
      if count == 0 then go rest offset runs inRun
      else
        match inRun, runs.back? with
        | true, some run =>
          go rest (offset + count) (runs.pop.push { run with stop := offset + count }) true
        | _, _ => go rest (offset + count) (runs.push ⟨offset, offset + count, ""⟩) true
    | .insert s :: rest, offset, runs, inRun =>
      if s.isEmpty then go rest offset runs inRun
      else
        match inRun, runs.back? with
        | true, some run =>
          go rest offset (runs.pop.push { run with inserted := run.inserted ++ s }) true
        | _, _ => go rest offset (runs.push ⟨offset, offset, s⟩) true

/-- What `changes` make of `text`. `none` when they do not fit it: unless
they end exactly at its length, and every range they change starts and stops
at a character boundary. -/
def applyChanges (text : String) (changes : Array Change) : Option String :=
  let (runs, reached) := runsOf changes
  if reached == text.utf8ByteSize then
    -- From the last run back, so that the offsets of the runs still to
    -- splice are offsets of the text as it is.
    runs.foldrM (fun run made => splice made run.start run.stop run.inserted) text
  else none

/-- Whether `selection`, if there is one, is a selection: it has a range, and
its primary names one. -/
def isSelection : Option Selection → Bool
  | none => true
  | some selection => selection.primary < selection.ranges.size

/-- The lower of the two ends of `range`. -/
def lower (range : SelectionRange) : Nat :=
  min range.anchor range.head

/-- The higher of the two ends of `range`. -/
def higher (range : SelectionRange) : Nat :=
  max range.anchor range.head

/-- Whether the head of `range` is before its anchor. A range with equal
ends points forward. -/
def backward (range : SelectionRange) : Bool :=
  range.head < range.anchor

/-- The range from `start` to `stop`, with its head at `start` when
`backward` and at `stop` otherwise. -/
def pointing (start stop : Nat) (backward : Bool) : SelectionRange :=
  if backward then ⟨stop, start⟩ else ⟨start, stop⟩

/-- Whether `later`, which starts at or after `earlier`, overlaps it by the
rule of `shape`. -/
def overlap (shape : Shape) (earlier later : SelectionRange) : Bool :=
  match shape with
  | .exclusive => lower later < higher earlier || lower later == lower earlier
  | _ => lower later ≤ higher earlier

/-- `selection` in the form the store keeps one in, as the rules of the port
give it: sorted, ranges that overlap made one, and the primary followed to
the range it ended in. A selection that is none is returned as it is. -/
def normal (selection : Selection) : Selection :=
  if selection.primary < selection.ranges.size then
    -- Each range with the place it was given at, so the primary can be
    -- followed. The sort keeps ranges that start and end alike in the order
    -- they were given in.
    let given :=
      selection.ranges.zipIdx.toList.mergeSort fun (one, _) (other, _) =>
        lower one < lower other || (lower one == lower other && higher one ≤ higher other)
    let (ranges, primary) :=
      given.foldl
        (fun (merged, primary) (range, index) =>
          let isPrimary := index == selection.primary
          let merged : Array SelectionRange :=
            match merged.back? with
            | some last =>
              if overlap selection.shape last range then
                let leader := if isPrimary then range else last
                merged.pop.push
                  (pointing (lower last) (max (higher last) (higher range)) (backward leader))
              else merged.push range
            | none => merged.push range
          (merged, if isPrimary then merged.size - 1 else primary))
        (#[], 0)
    { selection with
      ranges, primary }
  else selection

/-- Whether every end of every range of `selection`, if there is one, is a
position of `text`, once the selection is in the form the store keeps one
in: an end of a range that merged into another is no end of the
selection. -/
def selectionFits (text : String) : Option Selection → Bool
  | none => true
  | some selection =>
    (normal selection).ranges.all fun range =>
      decide ((String.Pos.Raw.mk range.anchor).IsValid text) &&
        decide ((String.Pos.Raw.mk range.head).IsValid text)

/-- Why `marker` cannot be held by a text that holds `text`; `none` when it
can. A selection that is none is refused as one that does not fit is. -/
def markerRefusal? (text : String) : Marker → Option TextError
  | .anchor anchor =>
    if (String.Pos.Raw.mk anchor.offset).IsValid text then none else some .badPosition
  | .selection selection =>
    if isSelection (some selection) && selectionFits text (some selection) then none
    else some .badSelection

/-- `marker` as the store holds it: a selection in its form. -/
def held : Marker → Marker
  | .anchor anchor => .anchor anchor
  | .selection selection => .selection (normal selection)

/-- Where the position `offset` of a text is once the ranges `runs` of it
have been changed, by `bias`. A position before a run moves by what the runs
before it added and removed. A position where a run only inserts stays
before what it inserted or goes after it, and so does one at the start of or
inside a range a run removes: to the start of what took its place, or to its
end. A position at the end of a removed range is past the run. -/
def mapOffset (runs : Array Run) (bias : Bias) (offset : Nat) : Nat :=
  go runs.toList 0 0
where
  /-- Walks the runs that are left. `added` and `removed` are the bytes the
  runs already passed put in and took out. -/
  go : List Run → Nat → Nat → Nat
    | [], added, removed => offset + added - removed
    | run :: rest, added, removed =>
      if offset < run.start then offset + added - removed
      else
        if offset == run.start ∨ offset < run.stop then
          match bias with
          | .before => run.start + added - removed
          | .after => run.start + added - removed + run.inserted.utf8ByteSize
        else go rest (added + run.inserted.utf8ByteSize) (removed + (run.stop - run.start))

/-- `selection`, which is in its form, once the ranges `runs` of its text
have been changed: each end moved as an anchor, with the bias the rules of
the port give it, a range whose ends passed each other made a cursor at its
start, and the form made again. -/
def mapSelection (runs : Array Run) (selection : Selection) : Selection :=
  let moved (range : SelectionRange) : SelectionRange :=
    let stopBias : Bias :=
      if selection.shape == .exclusive && lower range < higher range then .before else .after
    let start := mapOffset runs .after (lower range)
    pointing start (max start (mapOffset runs stopBias (higher range))) (backward range)
  normal { selection with ranges := selection.ranges.map moved }

/-- `marker` once the ranges `runs` of its text have been changed. -/
def mapMarker (runs : Array Run) : Marker → Marker
  | .anchor anchor => .anchor { anchor with offset := mapOffset runs anchor.bias anchor.offset }
  | .selection selection => .selection (mapSelection runs selection)

/-- Where the cell that starts at the position `offset` of `text` ends: after
the character there, or after the line feed when the character is a carriage
return with a line feed after it. At the end of the text, where no cell
starts, it is `offset`. -/
def cellEnd (text : String) (offset : Nat) : Nat :=
  go text.toList 0
where
  /-- Walks the characters that are left. `here` is the byte offset
  reached. -/
  go : List Char → Nat → Nat
    | [], _ => offset
    | c :: rest, here =>
      if here == offset then
        match c, rest with
        | '\r', '\n' :: _ => offset + 2
        | _, _ => offset + c.utf8Size
      else go rest (here + c.utf8Size)

/-- One row of a text, as what a selection covers is read off it. -/
structure Row where
  /-- Where the row starts. -/
  start : Nat
  /-- Where its content stops: before its line break. -/
  content : Nat
  /-- Where the row stops, its line feed included if it has one. -/
  stop : Nat
  /-- The cells of its content, in order. No line break is one of them. -/
  cells : Array Extent
  deriving Repr

/-- The rows of `text`: at least one. -/
def rowsOf (text : String) : Array Row :=
  go text.toList 0 0 #[] #[]
where
  /-- Walks the characters that are left. `here` is the byte offset reached,
  `start` where the row being walked starts, and `cells` its cells so far. A
  carriage return with a line feed after it ends the row's content; any
  other is a cell of it. -/
  go : List Char → Nat → Nat → Array Extent → Array Row → Array Row
    | [], here, start, cells, rows => rows.push ⟨start, here, here, cells⟩
    | '\n' :: rest, here, start, cells, rows =>
      go rest (here + 1) (here + 1) #[] (rows.push ⟨start, here, here + 1, cells⟩)
    | '\r' :: '\n' :: rest, here, start, cells, rows =>
      go rest (here + 2) (here + 2) #[] (rows.push ⟨start, here, here + 2, cells⟩)
    | c :: rest, here, start, cells, rows =>
      go rest (here + c.utf8Size) start (cells.push ⟨here, here + c.utf8Size⟩) rows

/-- The row of `rows` the position `offset` is in: the last that starts at
or before it. -/
def rowAt (rows : Array Row) (offset : Nat) : Row :=
  (rows.filter (·.start ≤ offset)).back?.getD ⟨0, 0, 0, #[]⟩

/-- The column of the position `offset` of `row`: how many cells of the row
start before it. A line break is one more cell after the content. -/
def column (row : Row) (offset : Nat) : Nat :=
  (row.cells.filter (·.start < offset)).size + if offset > row.content then 1 else 0

/-- What `selection`, which is one and fits `text`, covers in it: the
extents of its ranges by its shape, sorted, with those that overlap made
one. -/
def extents (text : String) (selection : Selection) : Array Extent :=
  let rows := rowsOf text
  let covered : Array Extent :=
    selection.ranges.flatMap fun range =>
      let (start, stop) := (lower range, higher range)
      match selection.shape with
      | .exclusive => #[⟨start, stop⟩]
      | .inclusive => #[⟨start, cellEnd text stop⟩]
      | .line => #[⟨(rowAt rows start).start, (rowAt rows stop).stop⟩]
      | .block =>
        let one := column (rowAt rows range.anchor) range.anchor
        let other := column (rowAt rows range.head) range.head
        let (low, high) := (min one other, max one other)
        let between :=
          rows.filter fun row =>
            (rowAt rows start).start ≤ row.start && row.start ≤ (rowAt rows stop).start
        between.map fun row =>
          match row.cells[low]? with
          | some first => ⟨first.start, (row.cells[min high (row.cells.size - 1)]?.getD first).stop⟩
          -- The row is too short for the lower column.
          | none => ⟨row.content, row.content⟩
  let sorted :=
    covered.toList.mergeSort fun one other =>
      one.start < other.start || (one.start == other.start && one.stop ≤ other.stop)
  sorted.foldl
    (fun merged extent =>
      match merged.back? with
      | some last =>
        if extent.start < last.stop || extent.start == last.start then
          merged.pop.push { last with stop := max last.stop extent.stop }
        else merged.push extent
      | none => merged.push extent)
    #[]

/-- The characters of `text` that start at a byte offset from `start` up to,
not including, `stop`. -/
def between (text : String) (start stop : Nat) : String :=
  String.ofList (go text.toList 0)
where
  /-- Walks the characters that are left. `here` is the byte offset
  reached. -/
  go : List Char → Nat → List Char
    | [], _ => []
    | c :: rest, here =>
      if start ≤ here ∧ here < stop then c :: go rest (here + c.utf8Size)
      else go rest (here + c.utf8Size)

/-- The content of the row `row` of `text`: its characters from where the
row starts up to where its line break does. `none` when the text has no such
row. -/
def rowContent (text : String) (row : Nat) : Option String :=
  (rowsOf text)[row]?.map fun found => between text found.start found.content

/-- The text of `text` from the byte offset `start` up to, not including,
`stop`. `none` unless both offsets are character boundaries of `text`,
within it, and `start ≤ stop`: the ranges an edit refuses. -/
def slice (text : String) (start stop : Nat) : Option String :=
  if
      (String.Pos.Raw.mk start).IsValid text ∧
        (String.Pos.Raw.mk stop).IsValid text ∧ start ≤ stop then
    some (between text start stop)
  else none

/-- Where every cell of `text` starts, in order: the cells of each row's
content, and then the row's line break, when it has one. -/
def cellStarts (text : String) : Array Nat :=
  (rowsOf text).flatMap fun row =>
    let content := row.cells.map (·.start)
    if row.content < row.stop then content.push row.content else content

/-- The character of `text` that starts at the byte offset `offset`; `none`
when none does. -/
def characterAt (text : String) (offset : Nat) : Option Char :=
  go text.toList 0
where
  /-- Walks the characters that are left. `here` is the byte offset
  reached. -/
  go : List Char → Nat → Option Char
    | [], _ => none
    | c :: rest, here => if here == offset then some c else go rest (here + c.utf8Size)

/-- Whether the character of `text` that starts at `offset` is a blank: a
space or a tab. -/
def blankAt (text : String) (offset : Nat) : Bool :=
  characterAt text offset == some ' ' || characterAt text offset == some '\t'

/-- The position `column` cells into the content of `row`, or where the
content ends when it has fewer. -/
def atColumn (row : Row) (column : Nat) : Nat :=
  (row.cells[column]?.map (·.start)).getD row.content

/-- What a cell is to a word motion. -/
inductive WordClass where
  /-- It is in no word: a blank, or the line break of a row that has
  content. -/
  | blank
  /-- The line break of an empty line: a word alone. -/
  | emptyLine
  /-- A word character; for a WORD, any character that is not a blank. -/
  | word
  /-- Any other character. A WORD has none. -/
  | punctuation
  deriving DecidableEq, Repr

/-- The class of the character `c` for words of `kind`, in the model's own
words: a blank is a space or a tab; a word character is an ASCII letter, an
ASCII digit, an underscore, or any character from U+0080 up; every other
character is punctuation. For a WORD every character that is not a blank is
of one class. `Char.isAlphanum` is ASCII only. -/
def classOf (kind : WordKind) (c : Char) : WordClass :=
  if c == ' ' || c == '\t' then .blank
  else
    match kind with
    | .bigWord => .word
    | .word => if wordCharacter c then .word else .punctuation

/-- Every cell of `text` with its class for words of `kind`, in order: the
cells of each row's content, and then the row's line break, when it has one,
which is an empty line's when the row has no content. -/
def classedCells (kind : WordKind) (text : String) : Array (Nat × WordClass) :=
  (rowsOf text).flatMap fun row =>
    let content :=
      row.cells.map fun cell =>
        (cell.start, ((characterAt text cell.start).map (classOf kind)).getD .blank)
    if row.content < row.stop then
      content.push (row.content, if row.cells.isEmpty then .emptyLine else .blank)
    else content

/-- One word of a text. -/
structure WordSpan where
  /-- Where its first cell starts. -/
  start : Nat
  /-- Where its last cell starts. -/
  last : Nat
  /-- Whether it is the line break of an empty line. -/
  empty : Bool
  deriving Repr

/-- The words of `kind` of `text`, in order: each a longest run of
neighbouring cells of one class, or the line break of an empty line,
alone. -/
def wordsOf (kind : WordKind) (text : String) : Array WordSpan :=
  -- The class of the run the cell before is in, when it is in one.
  let (words, _) :=
    (classedCells kind text).foldl
      (fun ((words, running) : Array WordSpan × Option WordClass) (start, found) =>
        match found with
        | .blank => (words, none)
        | .emptyLine => (words.push ⟨start, start, true⟩, none)
        | found =>
          match words.back? with
          | some word =>
            if running == some found then (words.pop.push { word with last := start }, some found)
            else (words.push ⟨start, start, false⟩, some found)
          | none => (words.push ⟨start, start, false⟩, some found))
      (#[], none)
  words

/-- Where `motion` leads from the byte offset `offset` of `text`. `none`
unless the offset is a position.

Each answer is picked from a list of the whole text: its cell starts, its
words, or its rows with their cells. The library lists nothing and walks
from the position. The line start is the offset of column 0 of the
position's row, by the model's own conversions. -/
def motion? (text : String) (motion : Motion) (offset : Nat) : Option Nat :=
  (pointOf .bytes text offset).bind fun point =>
    let rows := rowsOf text
    let row := rowAt rows offset
    match motion with
    | .nextCell => some (((cellStarts text).find? (· > offset)).getD text.utf8ByteSize)
    | .previousCell => some (((cellStarts text).filter (· < offset)).back?.getD 0)
    | .nextWordStart kind =>
      some ((((wordsOf kind text).find? (·.start > offset)).map (·.start)).getD text.utf8ByteSize)
    | .nextWordEnd kind =>
      some
        ((((wordsOf kind text).find? fun word => word.last > offset && !word.empty).map
              (·.last)).getD
          text.utf8ByteSize)
    | .previousWordStart kind =>
      some ((((wordsOf kind text).filter (·.start < offset)).back?.map (·.start)).getD 0)
    | .previousWordEnd kind =>
      some ((((wordsOf kind text).filter (·.last < offset)).back?.map (·.last)).getD 0)
    | .lineStart => offsetOf .bytes text ⟨point.row, 0⟩
    | .lineEnd => some row.content
    | .lineFirstNonBlank =>
      some (((row.cells.find? fun cell => !blankAt text cell.start).map (·.start)).getD row.content)
    | .textStart => some 0
    | .textEnd => some text.utf8ByteSize
    | .rowsUp count column => some (atColumn (rows[point.row - count]?.getD row) column)
    | .rowsDown count column =>
      some (atColumn (rows[min (point.row + count) (rows.size - 1)]?.getD row) column)

/-- A literal pattern, as the model reads one: the characters it finds, and
whether a word must start where they start (`\<`) and end where they end
(`\>`). -/
structure Literal where
  /-- Whether `\<` begins the pattern. -/
  wordStart : Bool
  /-- The characters, unescaped. -/
  chars : List Char
  /-- Whether `\>` ends the pattern. -/
  wordEnd : Bool

/-- The characters a literal pattern writes with a backslash before them,
and that are not literal without one. -/
def specials : List Char :=
  ['\\', '.', '*', '[', '~', '^', '$']

/-- `pattern` as a literal ("Search", in the rules of the port): every
character is literal, none of `specials` and no line feed, or a backslash
before one of `specials`, `/` or `]`, with an optional `\<` first and `\>`
last; `none` for any other pattern and for the empty one. -/
def literalOf (pattern : String) : Option Literal :=
  let chars := pattern.toList
  let (wordStart, chars) :=
    match chars with
    | '\\' :: '<' :: rest => (true, rest)
    | _ => (false, chars)
  let (wordEnd, chars) :=
    match chars.reverse with
    | '>' :: '\\' :: rest => (true, rest.reverse)
    | _ => (false, chars)
  let rec unescape : List Char → Option (List Char)
    | [] => some []
    | '\\' :: c :: rest =>
      if specials.contains c || c == '/' || c == ']' then (unescape rest).map (c :: ·) else none
    | c :: rest => if specials.contains c || c == '\n' then none else (unescape rest).map (c :: ·)
  match unescape chars with
  | some found => if found.isEmpty then none else some { wordStart, chars := found, wordEnd }
  | none => none

/-- What the model answers for a pattern that is not literal: it matches
literal patterns only. -/
def notLiteral : String :=
  "the text model matches literal patterns only"

/-- Every match of `literal` in `text`, in order, as the walk of the rules
of the port finds them: from the text's start, the next occurrence that
meets the word assertions is a match and the walk goes on from its end; an
occurrence that does not meet them is passed over, and the walk goes on one
character after its start. -/
def literalMatches (text : String) (literal : Literal) : Array Extent :=
  Id.run do
    let chars := text.toList.toArray
    let offsets :=
      (chars.foldl (fun (acc : Array Nat × Nat) c => (acc.1.push acc.2, acc.2 + c.utf8Size))
          (#[], 0)).1
    let length := text.utf8ByteSize
    let word (index : Nat) : Bool := (chars[index]?.map wordCharacter).getD false
    let width := literal.chars.length
    let mut found := #[]
    let mut index := 0
    while index + width ≤ chars.size do
      let here := (chars.extract index (index + width)).toList == literal.chars
      let starts := !literal.wordStart || word index && (index == 0 || !word (index - 1))
      let ends := !literal.wordEnd || word (index + width - 1) && !word (index + width)
      if here && starts && ends then
        found := found.push ⟨offsets[index]!, (offsets[index + width]?).getD length⟩
        index := index + width
      else
        index := index + 1
    return found

/-- Whether `offset` is a position of `text`: a character boundary within
it. -/
def isPosition (text : String) (offset : Nat) : Bool :=
  (String.Pos.Raw.mk offset).IsValid text

/-- The model's answer to a search of `text` for `pattern` from `offset`
("Search", in the rules of the port), for a literal pattern. -/
def search (text : String) (pattern : String) (forward : Bool) (offset : Nat) :
    Except TextError Searched :=
  if !isPosition text offset then .error .badPosition
  else
    match literalOf pattern with
    | none => .ok (.invalid notLiteral)
    | some literal =>
      let all := literalMatches text literal
      let found (extent : Extent) (wrapped : Bool) : Searched :=
        .found extent.start extent.stop wrapped
      if forward then
        match all.find? (·.start > offset), all[0]? with
        | some extent, _ => .ok (found extent false)
        | none, some first => .ok (found first true)
        | none, none => .ok .notFound
      else
        match (all.filter (·.start < offset)).back?, all.back? with
        | some extent, _ => .ok (found extent false)
        | none, some last => .ok (found last true)
        | none, none => .ok .notFound

/-- The model's answer to the matches of `pattern` in `text` that start from
`start` up to `stop`, for a literal pattern. -/
def matchesIn (text : String) (pattern : String) (start stop : Nat) : Except TextError Matched :=
  if !(isPosition text start && isPosition text stop && start ≤ stop) then .error .badRange
  else
    match literalOf pattern with
    | none => .ok (.invalid notLiteral)
    | some literal =>
      .ok
        (.ranges
          ((literalMatches text literal).filter fun extent =>
            start ≤ extent.start && extent.start < stop))

/-- The characters of `text`, each with the byte offset it starts pos. -/
def charsAt (text : String) : Array (Nat × Char) :=
  (text.toList.foldl
      (fun (chars, walked) char => (chars.push (walked, char), walked + char.utf8Size)) (#[], 0)).1

/-- The byte at `here` of `bytes` as a number, or 0, Vim's NUL, at or past
`stop`, where a row's content ends. -/
def byteIn (bytes : ByteArray) (stop here : Nat) : Nat :=
  if here < stop then bytes[here]!.toNat else 0

/-- How many backslashes stand right before `here` of `bytes`, after the
offset `start` a row starts at. -/
def backslashesBefore (bytes : ByteArray) (start here : Nat) : Nat :=
  Id.run do
    let mut run := here
    while run > start && bytes[run - 1]! == 92 do
      run := run - 1
    return here - run

/-- How long the character is whose first byte is `byte`, in bytes. -/
def leadWidth (byte : Nat) : Nat :=
  if byte < 0x80 then 1 else if byte < 0xE0 then 2 else if byte < 0xF0 then 3 else 4

/-- Vim 9.1's count of the double quotes of the row of `bytes` from `start`
to `stop` (`do_quotes`, in `findmatchlimit`): whether it is even, and
whether an even number stands before the offset `looked` at, which is true
when the count passes over that offset (`at_start`). A double quote is
counted unless a backslash escapes it or a single quote is on each side of
it. -/
def rowQuotes (bytes : ByteArray) (start stop looked : Nat) : Bool × Bool :=
  Id.run do
    let mut count := 0
    let mut evenAtStart := true
    let mut walked := start
    while walked < stop do
      if walked == looked then
        evenAtStart := count % 2 == 0
      let byte := byteIn bytes stop walked
      if
          byte == 34 &&
            (walked == start || byteIn bytes stop (walked - 1) != 39 ||
              byteIn bytes stop (walked + 1) != 39) then
        count := count + 1
      if byte == 92 && byteIn bytes stop (walked + 1) != 0 then
        walked := walked + 1
      walked := walked + 1
    return (count % 2 == 0, evenAtStart)

/-- The model's answer to the bracket a walk leaves unbalanced ("Pairs", in
the rules of the port): Vim 9.1's `findmatchlimit`, over the bytes of
`text` a row here a time, from `offset`, or from where its row's content ends
when `offset` is in the line break. -/
def unmatched? (text : String) (bracket : Bracket) (opening forward escaped skipQuoted : Bool)
    (offset : Nat) : Except TextError (Option Nat) :=
  if !isPosition text offset then .error .badPosition
  else
    let bytes := text.toUTF8
    let rows := (rowsOf text).map fun row => (row.start, row.content)
    let (sought, other) :=
      if opening then (bracket.opening.toNat, bracket.closing.toNat)
      else (bracket.closing.toNat, bracket.opening.toNat)
    .ok <|
      Id.run do
        let mut row := (rows.findIdx? (·.1 > offset)).getD rows.size - 1
        let mut start := rows[row]!.1
        let mut stop := rows[row]!.2
        let mut here := min offset stop
        -- Vim's `do_quotes` (counted, and read), `inquote` and
        -- `start_in_quotes`.
        let mut counted := false
        let mut read := false
        let mut inside := false
        let mut started : Option Bool := none
        let mut depth := 0
        while true do
          let mut entered := false
          if forward then
            if here == stop then
              if row + 1 ≥ rows.size then
                return none
              row := row + 1
              start := rows[row]!.1
              stop := rows[row]!.2
              here := start
              entered := true
            else
              here := here + leadWidth bytes[here]!.toNat
          else if here == start then
            if row == 0 then
              return none
            row := row - 1
            start := rows[row]!.1
            stop := rows[row]!.2
            here := stop
            entered := true
          else
            here := here - 1
            while bytes[here]! &&& 0xC0 == 0x80 do
              here := here - 1
          if skipQuoted && (entered || !counted) then
            counted := true
            let (even, evenAtStart) :=
              rowQuotes bytes start stop (if forward then here else here + 1)
            read := even
            if !even then
              inside := false
              -- A string that goes on across this row's line break.
              if byteIn bytes stop (stop - 1) == 92 then
                read := true
                if started.isNone then
                  inside := true
                  started := some true
                else if !forward then
                  inside := true
              -- And one that goes on across the line break before it.
              if row > 0 then
                let (aboveStart, aboveStop) := rows[row - 1]!
                if aboveStop > aboveStart && byteIn bytes aboveStop (aboveStop - 1) == 92 then
                  read := true
                  if started.isNone then
                    inside := evenAtStart
                    if inside then
                      started := some true
                  else if forward then
                    inside := true
          if started.isNone then
            started := some false
          if here == stop then
            if skipQuoted && (here == start || byteIn bytes stop (here - 1) != 92) then
              inside := false
              started := some false
            continue
          let byte := bytes[here]!.toNat
          if skipQuoted then
            if byte == 34 then
              if read && backslashesBefore bytes start here % 2 == 0 then
                inside := !inside
                started := some false
              continue
            -- 'x' and '\x' are passed over.
            if byte == 39 then
              if forward then
                if byteIn bytes stop (here + 1) != 0 then
                  if
                      byteIn bytes stop (here + 1) == 92 && byteIn bytes stop (here + 2) != 0 &&
                        byteIn bytes stop (here + 3) == 39 then
                    here := here + 3
                    continue
                  else if byteIn bytes stop (here + 2) == 39 then
                    here := here + 2
                    continue
              else if here - start > 1 then
                if byteIn bytes stop (here - 2) == 39 then
                  here := here - 2
                  continue
                else if
                  byteIn bytes stop (here - 2) == 92 && here - start > 2 &&
                    byteIn bytes stop (here - 3) == 39 then
                  here := here - 3
                  continue
          if
              (!inside || started == some true) && (byte == sought || byte == other) &&
                (backslashesBefore bytes start here % 2 == 1) == escaped then
            if byte == other then
              depth := depth + 1
            else if depth == 0 then
              return some here
            else
              depth := depth - 1
        return none

/-- The first quote `quote` among `line`, the characters of a row's content,
at or after the index `first`, passing over each character a backslash
escapes when `escapes` (Vim's `find_next_quote`). -/
def nextQuote (line : Array (Nat × Char)) (quote : Char) (first : Nat) (escapes : Bool) :
    Option Nat :=
  Id.run do
    let mut index := first
    while index < line.size do
      let char := line[index]!.2
      if escapes && char == '\\' then
        index := index + 2
      else if char == quote then
        return some index
      else
        index := index + 1
    return none

/-- The nearest quote `quote` among `line` before the index `first` that is
not escaped, or 0 when there is none (Vim's `find_prev_quote`): a character
after an odd number of backslashes is passed over with them. -/
def previousQuote (line : Array (Nat × Char)) (quote : Char) (first : Nat) : Nat :=
  Id.run do
    let mut index := first
    while index > 0 do
      index := index - 1
      let run := ((line.extract 0 index).toList.reverse.takeWhile (·.2 == '\\')).length
      if run % 2 == 1 then
        index := index - run
      else if line[index]!.2 == quote then
        break
    return index

/-- The model's answer to the quoted string round `offset` ("Pairs", in the
rules of the port): Vim's walk over the characters of `offset`'s row. -/
def quoted? (text : String) (quote : Quote) (offset : Nat) : Except TextError (Option Extent) :=
  if !isPosition text offset then .error .badPosition
  else
    let chars := charsAt text
    -- The row: from after the last line feed before the offset to the next
    -- line feed, without a carriage return right before it.
    let start :=
      ((chars.filter fun (pos, char) => char == '\n' && pos < offset).back?.map (·.1 + 1)).getD 0
    let feed := (chars.find? fun (pos, char) => char == '\n' && pos ≥ start).map (·.1)
    let row := chars.filter fun (pos, _) => pos ≥ start && feed.all (pos < ·)
    let line := if feed.isSome && (row.back?.map (·.2)) == some '\r' then row.pop else row
    let cursor := (line.findIdx? (·.1 ≥ offset)).getD line.size
    let q := quote.char
    let extent (opening closing : Nat) : Extent := ⟨line[opening]!.1, line[closing]!.1 + 1⟩
    let found : Option Extent :=
      if (line[cursor]?.map (·.2)) == some q then
        -- The pairs from the row's start, until one holds the cursor.
        let rec pairs (first : Nat) (fuel : Nat) : Option Extent :=
          match fuel with
          | 0 => none
          | fuel + 1 => do
            let opening ← nextQuote line q first false
            if opening > cursor then
              none
            else
              let closing ← nextQuote line q (opening + 1) true
              if cursor ≤ closing then
                some (extent opening closing)
              else
                pairs (closing + 1) fuel
        pairs 0 (line.size + 1)
      else do
        let before := previousQuote line q cursor
        let opening ←
          if (line[before]?.map (·.2)) == some q then
            some before
          else
            nextQuote line q before false
        let closing ← nextQuote line q (opening + 1) true
        some (extent opening closing)
    .ok found

/-- The model's answer to `query` about `content`. -/
def answer (content : TextContent) : (query : TextQuery) → Except TextError query.Answer
  | .revision => .ok content.revision
  | .byteLength => .ok content.contents.utf8ByteSize
  | .rowCount => .ok (rowCount content.contents)
  | .contents => .ok content.contents
  | .pointOf unit offset =>
    match pointOf unit content.contents offset with
    | some point => .ok point
    | none => .error .badPosition
  | .offsetOf unit point =>
    match offsetOf unit content.contents point with
    | some offset => .ok offset
    | none => .error .badPosition
  | .extents selection =>
    if isSelection (some selection) && selectionFits content.contents (some selection) then
      .ok (extents content.contents (normal selection))
    else .error .badSelection
  | .rowContent row =>
    match rowContent content.contents row with
    | some read => .ok read
    | none => .error .badPosition
  | .slice start stop =>
    match slice content.contents start stop with
    | some read => .ok read
    | none => .error .badRange
  | .motion motion offset =>
    match motion? content.contents motion offset with
    | some position => .ok position
    | none => .error .badPosition
  | .search pattern forward offset => search content.contents pattern forward offset
  | .matches pattern start stop => matchesIn content.contents pattern start stop
  | .unmatched bracket opening forward escaped skipQuoted offset =>
    unmatched? content.contents bracket opening forward escaped skipQuoted offset
  | .quoted quote offset => quoted? content.contents quote offset
  -- Only a text answers it, and an excerpt text is answered before its
  -- content is reached (`TextModel.locate`).
  | .locate _ => .error .notExcerpted
  -- An excerpt text and a snapshot of one are answered before their content
  -- is reached (`TextModel.excerptsOf`).
  | .excerpts => .error .notExcerpted

end TextModel

namespace TextLog

/-- `count` cells for bytes inserted by the edit that produced `revision`,
with the identities from `first` on. -/
def fresh (first count revision : Nat) : Array Cell :=
  (Array.range count).map fun index => ⟨first + index, revision⟩

/-- The log of a text just made holding `initial`. -/
def new (initial : String) : TextLog :=
  { cells := fresh 0 initial.utf8ByteSize 0, nextId := initial.utf8ByteSize }

/-- The log after an edit by `origin` changed the ranges `runs` of the text,
which held `before`, and so produced `revision`. A byte that is kept keeps
its cell, and a byte that is inserted gets a new one. -/
def record (log : TextLog) (before : String) (revision : Nat) (runs : Array TextModel.Run)
    (origin : Origin) : TextLog :=
  -- From the last run back, as the text is spliced, so that the offsets of
  -- the runs still to make are offsets of the cells as they are.
  let (cells, nextId) :=
    runs.foldr
      (fun run (cells, next) =>
        (cells.extract 0 run.start ++ fresh next run.inserted.utf8ByteSize revision ++
            cells.extract run.stop cells.size,
          next + run.inserted.utf8ByteSize))
      (log.cells, log.nextId)
  { log with
    cells
    nextId
    origins := log.origins.push origin
    past := log.past.push (before, log.cells.map (·.id)) }

/-- The span of `text` from `start` to `stop`, with its points counted from
the string. -/
def span (text : String) (start stop : Nat) : Span where
  start := start
  stop := stop
  startPoint := (TextModel.pointOf .bytes text start).getD ⟨0, 0⟩
  stopPoint := (TextModel.pointOf .bytes text stop).getD ⟨0, 0⟩

/-- What changed between a text that held `old`, whose bytes had the
identities `oldIds`, and the same text now, holding `new` with the cells
`cells`.

The bytes the two share are the cells that were written at or before
`revision`, the revision of the old text: they are in both, in the same
order. Each stretch between two of them that is not empty in both texts is
one edit. This is not how the library finds a patch, which composes what
each edit recorded: that the two agree is what the contract checks. -/
def editsBetween (revision : Nat) (old new : String) (oldIds : Array Nat) (cells : Array Cell) :
    Array Edit :=
  go (oldIds.size + cells.size + 1) 0 0 #[]
where
  /-- Finds the edits from the offsets `oldHere` and `newHere` on. `fuel` is
  more than the bytes left, so it does not run out. -/
  go : Nat → Nat → Nat → Array Edit → Array Edit
    | 0, _, _, edits => edits
    | fuel + 1, oldHere, newHere, edits =>
      -- What only the new text holds, up to the next byte both hold.
      let newStop := skipNew newHere (cells.size - newHere)
      let shared := cells[newStop]?.map (·.id)
      -- What only the old text holds, up to that byte.
      let oldStop := skipOld shared oldHere (oldIds.size - oldHere)
      let edits :=
        if oldStop > oldHere ∨ newStop > newHere then
          edits.push ⟨span old oldHere oldStop, span new newHere newStop⟩
        else edits
      if shared.isNone then edits else go fuel (oldStop + 1) (newStop + 1) edits
  /-- The offset of the first byte of the new text at or after `here` that the
  old text held too, or the new text's length. -/
  skipNew (here : Nat) : Nat → Nat
    | 0 => here
    | fuel + 1 =>
      match cells[here]? with
      | some cell => if cell.revision > revision then skipNew (here + 1) fuel else here
      | none => here
  /-- The offset of the byte `shared` of the old text at or after `here`, or
  the old text's length when there is none. -/
  skipOld (shared : Option Nat) (here : Nat) : Nat → Nat
    | 0 => here
    | fuel + 1 =>
      match oldIds[here]? with
      | some id => if some id == shared then here else skipOld shared (here + 1) fuel
      | none => here

/-- The log's answer to what changed since `revision` in its text, which
holds `content` now. -/
def since (log : TextLog) (content : TextContent) (revision : Nat) : Except TextError Patch :=
  if revision > content.revision then .error .unknownRevision
  else
    if revision < log.horizon then .error .forgotten
    else
      match log.past[revision]? with
      -- Only the revision the text is at has no past state.
      | none => .ok ⟨revision, content.revision, #[]⟩
      | some (old, oldIds) =>
        .ok
          ⟨revision, content.revision, editsBetween revision old content.contents oldIds log.cells⟩

/-- Who wrote the byte `cell`: the edit that inserted it, or nobody the log
still knows when that edit is at or before where the log starts. -/
def author (log : TextLog) (cell : Cell) : Author :=
  if cell.revision ≤ log.horizon then .earlier log.horizon
  else .entry cell.revision (log.origins[cell.revision - 1]?.getD .unattributed)

/-- The log's answer to who wrote the bytes from `start` up to `stop` of its
text, which holds `content` now: the author of each byte, with neighbours
that have one author as one piece. -/
def trace (log : TextLog) (content : TextContent) (start stop : Nat) :
    Except TextError (Array Attribution) :=
  if
      (String.Pos.Raw.mk start).IsValid content.contents ∧
        (String.Pos.Raw.mk stop).IsValid content.contents ∧ start ≤ stop then
    .ok <|
      (log.cells.extract start stop).foldl (init := #[]) fun pieces cell =>
        let author := log.author cell
        match pieces.back? with
        | some last =>
          if last.author == author then pieces.pop.push { last with stop := last.stop + 1 }
          else pieces.push ⟨last.stop, last.stop + 1, author⟩
        | none => pieces.push ⟨start, start + 1, author⟩
  else .error .badRange

end TextLog

namespace TextHistory

/-- The history after an edit that carried the selections `carried` and put
the text in the state named `state`, or for `none` in a new state, named by
`revision`, the revision the edit produced. -/
def record (history : TextHistory) (revision : Nat) (state : Option Nat)
    (carried : Option Selection × Option Selection) : TextHistory
    where
  names := history.names.push (state.getD revision)
  carried := history.carried.push carried
  dropped := history.dropped.push false

/-- Whether the inverse of a revision from `first` to `last` was dropped. -/
def touchesDrop (history : TextHistory) (first last : Nat) : Bool :=
  (List.range' first (last + 1 - first)).any fun revision => history.dropped[revision]?.getD false

/-- The history with the inverse of every revision from `first` to `last`
dropped. -/
def drop (history : TextHistory) (first last : Nat) : TextHistory :=
  { history with
    dropped :=
      history.dropped.mapIdx fun revision was => was || (first ≤ revision && revision ≤ last) }

/-- What an inverse changes: the ranges of a text whose bytes had the
identities `oldIds` that are replaced to make the text that held `new`,
whose bytes had the identities `newIds`.

The bytes the two share are those with one identity in both, and they are in
both in the same order. Each stretch between two of them that is not empty in
both texts is one run: the old text's bytes there are replaced by the new
text's. This is the shape of `TextLog.editsBetween`, and not how the library
finds the inverse of a run, which composes the inverse it kept of each
edit. The two agree because a composed inverse keeps exactly the bytes every
edit of the run kept, which are the bytes the two states share.

`oldIds` must be the identities the text had when the run ended, not those
it has now. The two texts read the same when the inverse is allowed, but a
byte that was deleted and restored since has another identity now, and
would be found changed. -/
def runsBetween (oldIds newIds : Array Nat) (new : String) : Array TextModel.Run :=
  go (oldIds.size + newIds.size + 1) 0 0 #[]
where
  /-- Finds the runs from the offsets `oldHere` and `newHere` on. `fuel` is
  more than the bytes left, so it does not run out. -/
  go : Nat → Nat → Nat → Array TextModel.Run → Array TextModel.Run
    | 0, _, _, runs => runs
    | fuel + 1, oldHere, newHere, runs =>
      -- What only the new text holds, up to the next byte both hold.
      let newStop := skipNew newHere (newIds.size - newHere)
      let shared := newIds[newStop]?
      -- What only the old text holds, up to that byte.
      let oldStop := skipOld shared oldHere (oldIds.size - oldHere)
      let runs :=
        if oldStop > oldHere ∨ newStop > newHere then
          runs.push ⟨oldHere, oldStop, TextModel.between new newHere newStop⟩
        else runs
      if shared.isNone then runs else go fuel (oldStop + 1) (newStop + 1) runs
  /-- The offset of the first byte of the new text at or after `here` that the
  old text held too, or the new text's length. -/
  skipNew (here : Nat) : Nat → Nat
    | 0 => here
    | fuel + 1 =>
      match newIds[here]? with
      | some id => if oldIds.contains id then here else skipNew (here + 1) fuel
      | none => here
  /-- The offset of the byte `shared` of the old text at or after `here`, or
  the old text's length when there is none. -/
  skipOld (shared : Option Nat) (here : Nat) : Nat → Nat
    | 0 => here
    | fuel + 1 =>
      match oldIds[here]? with
      | some id => if some id == shared then here else skipOld shared (here + 1) fuel
      | none => here

end TextHistory

namespace TextModel

/-- The model after an edit by `origin` to the text `id`, which held
`content`: it holds `text`, made by changing the ranges `runs`, at the next
revision, its log has recorded the edit, every marker it holds has moved,
and its history has recorded the selections `carried` and the state the edit
put the text in: `state`, or for `none` a new one. Every accepted edit comes
through here, an applied inverse included. -/
def changed (model : TextModel) (id : TextId) (content : TextContent) (text : String)
    (runs : Array Run) (origin : Origin) (state : Option Nat := none)
    (carried : Option Selection × Option Selection := (none, none)) : TextModel :=
  { model with
    texts :=
      model.texts.setIfInBounds id.index
        (some { contents := text, revision := content.revision + 1 })
    logs :=
      model.logs.modify id.index (·.record content.contents (content.revision + 1) runs origin)
    markers := model.markers.modify id.index (·.map (·.map (mapMarker runs)))
    histories := model.histories.modify id.index (·.record (content.revision + 1) state carried) }

/-- The model's answer to an edit of the text `id`, replacing its bytes from
`start` up to `stop` by `s`, and the model after it. An accepted edit adds
one to the text's revision, and is recorded in its log as the transaction
with that one change is, made by nobody. A refused edit leaves the model as
it was. -/
def edit (model : TextModel) (id : TextId) (start stop : Nat) (s : String) :
    Except TextError Unit × TextModel :=
  match model.lookup (.text id) with
  | .error refusal => (.error refusal, model)
  | .ok content =>
    match splice content.contents start stop s with
    | none => (.error .badRange, model)
    | some text => (.ok (), model.changed id content text #[⟨start, stop, s⟩] .unattributed)

/-- The model's answer to applying `transaction` to the text `id`, with
`origin` as who made the edit, and the model after it. An accepted
transaction adds one to the text's revision, however many changes it has,
and is recorded in its log. A refused one leaves the model as it was. -/
def apply (model : TextModel) (id : TextId) (transaction : Transaction) (origin : Origin) :
    Except TextError Nat × TextModel :=
  match model.lookup (.text id) with
  | .error refusal => (.error refusal, model)
  | .ok content =>
    if !(isSelection transaction.before && isSelection transaction.after) then
      (.error .badSelection, model)
    else
      match applyChanges content.contents transaction.changes with
      | none => (.error .badChange, model)
      | some text =>
        if
            selectionFits content.contents transaction.before &&
              selectionFits text transaction.after then
          (.ok (content.revision + 1),
            model.changed id content text (runsOf transaction.changes).1 origin none
              (transaction.before.map normal, transaction.after.map normal))
        else (.error .badSelection, model)

/-- The model's answer to applying to the text `id` the inverse of its run
of revisions from `first` to `last`, with `origin` as who made the edit, and
the model after it. The refusals are looked for in the order the port gives.

The text an accepted inverse leaves is read, not computed: the log's model
holds the text at every revision, so it is the text at the revision before
`first`. What the inverse changed, for the log and the markers, is the gaps
between the bytes that text shares with the text as it was at `last`
(`TextHistory.runsBetween`). Whether it is allowed is decided as the library
decides it, by the names of the states. A refused inverse leaves the model
as it was. -/
def applyInverse (model : TextModel) (id : TextId) (first last : Nat) (origin : Origin) :
    Except TextError Inverted × TextModel :=
  match model.lookup (.text id) with
  | .error refusal => (.error refusal, model)
  | .ok content =>
    let history := model.histories[id.index]?.getD {}
    let log := model.logs[id.index]?.getD {}
    if first > content.revision ∨ last > content.revision then (.error .unknownRevision, model)
    else
      if first == 0 ∨ first > last ∨ history.touchesDrop first last then (.error .noInverse, model)
      else
        if history.names[content.revision]? != history.names[last]? then (.error .notInState, model)
        else
          match log.past[first - 1]? with
          -- Every revision before the one the text is at has a past state.
          | none => (.error .notInState, model)
          | some (text, ids) =>
            -- The identities the text had when the run ended: only the
            -- revision the text is at has no past state.
            let ended := (log.past[last]?.map (·.2)).getD (log.cells.map (·.id))
            let selection := history.carried[first]?.bind (·.1)
            (.ok ⟨content.revision + 1, selection⟩,
              model.changed id content text (TextHistory.runsBetween ended ids text) origin
                history.names[first - 1]? (history.carried[last]?.bind (·.2), selection))

/-- The model's answer to dropping the inverses the text `id` keeps for its
revisions from `first` to `last`, and the model after it. The text and its
log are untouched. -/
def dropInverses (model : TextModel) (id : TextId) (first last : Nat) :
    Except TextError Unit × TextModel :=
  match model.lookup (.text id) with
  | .error refusal => (.error refusal, model)
  | .ok content =>
    if last > content.revision then (.error .unknownRevision, model)
    else (.ok (), { model with histories := model.histories.modify id.index (·.drop first last) })

/-- The model's answer to `query` about the log `log` of a text that holds
`content`. -/
def answerLog (log : TextLog) (content : TextContent) :
    (query : LogQuery) → Except TextError query.Answer
  | .since revision => log.since content revision
  | .trace start stop => log.trace content start stop

/-- The model's answer to forgetting the log of the text `id` up to
`revision`, and the model after it: the log starts there, unless it starts
later already. The text is untouched. -/
def forget (model : TextModel) (id : TextId) (revision : Nat) : Except TextError Unit × TextModel :=
  match model.lookup (.text id) with
  | .error refusal => (.error refusal, model)
  | .ok content =>
    if revision > content.revision then (.error .unknownRevision, model)
    else
      (.ok (),
        { model with
          logs :=
            model.logs.modify id.index fun log =>
              { log with horizon := max log.horizon revision } })

/-- The model after `source`, which it holds, is released: its slot is
emptied and stays, so later ids are what they would have been. A text's
markers go with it. -/
def released (model : TextModel) : TextSource → TextModel
  | .text id =>
    { model with
      texts := model.texts.setIfInBounds id.index none
      markers := model.markers.setIfInBounds id.index #[] }
  | .snapshot id => { model with snapshots := model.snapshots.setIfInBounds id.index none }

/-- The markers of the text `id`: its table, in which a marker's id is an
index. -/
def markersOf (model : TextModel) (id : TextId) : Array (Option Marker) :=
  model.markers[id.index]?.getD #[]

/-- The model's answer to marking the text `id` with `marker`, and the model
after it: the marker is held, in its form, under the next id of that text,
which names the text.
A refused marker leaves the model as it was. -/
def mark (model : TextModel) (id : TextId) (marker : Marker) :
    Except TextError MarkerId × TextModel :=
  match model.lookup (.text id) with
  | .error refusal => (.error refusal, model)
  | .ok content =>
    match markerRefusal? content.contents marker with
    | some refusal => (.error refusal, model)
    | none =>
      (.ok ⟨id, (model.markersOf id).size⟩,
        { model with markers := model.markers.modify id.index (·.push (some (held marker))) })

/-- The marker the text `id` holds under `marker`; `none` when it holds
none: another text gave the id out (`MarkerId.numberIn?`), no text did, or
the marker was given up. -/
def heldUnder? (model : TextModel) (id : TextId) (marker : MarkerId) : Option Marker :=
  match marker.numberIn? id with
  | some number => (model.markersOf id)[number]?.join
  | none => none

/-- The model's answer to reading the marker `marker` of the text `id`. -/
def markerOf (model : TextModel) (id : TextId) (marker : MarkerId) : Except TextError Marker :=
  match model.lookup (.text id) with
  | .error refusal => .error refusal
  | .ok _ =>
    match model.heldUnder? id marker with
    | some found => .ok found
    | none => .error .noSuchMarker

/-- The model's answer to putting `marker` in place of the marker `at` of
the text `id`, and the model after it. The refusals are looked for in the
order the port gives: the text, a selection that is none, the id, and then
whether the marker is in the text. A refused place leaves the model as it
was. -/
def place (model : TextModel) (id : TextId) («at» : MarkerId) (marker : Marker) :
    Except TextError Unit × TextModel :=
  match model.lookup (.text id) with
  | .error refusal => (.error refusal, model)
  | .ok content =>
    let none? :=
      match marker with
      | .selection selection => !isSelection (some selection)
      | .anchor _ => false
    if none? then (.error .badSelection, model)
    else
      match model.heldUnder? id «at» with
      | some _ =>
        match markerRefusal? content.contents marker with
        | some refusal => (.error refusal, model)
        | none =>
          (.ok (),
            { model with
              markers :=
                model.markers.modify id.index (·.setIfInBounds «at».index (some (held marker))) })
      | none => (.error .noSuchMarker, model)

/-- The model's answer to giving up the marker `marker` of the text `id`,
and the model after it: its slot is emptied and stays, so its id is never
used again. -/
def unmark (model : TextModel) (id : TextId) (marker : MarkerId) :
    Except TextError Unit × TextModel :=
  match model.lookup (.text id) with
  | .error refusal => (.error refusal, model)
  | .ok _ =>
    match model.heldUnder? id marker with
    | some _ =>
      (.ok (),
        { model with markers := model.markers.modify id.index (·.setIfInBounds marker.index none) })
    | none => (.error .noSuchMarker, model)

/-- The id of a new text holding `initial`, and the model with it: the text
is at revision 0, with a log that starts there, no markers and a history
that holds nothing. Its id is the next index, so no id is used again. This is
the one way the model gains a text, whether it is made of a string or of what
another text or a snapshot holds. -/
def made (model : TextModel) (initial : String) : TextId × TextModel :=
  (⟨model.texts.size⟩,
    { model with
      texts := model.texts.push (some { contents := initial })
      logs := model.logs.push (.new initial)
      markers := model.markers.push #[]
      histories := model.histories.push {} })

/-- The model's answer to making a text of what `source` holds, and the model
after it: a new text holding the source's string and nothing else of it
(`made`). A source that names nothing is refused and makes no text. -/
def copy (model : TextModel) (source : TextSource) : Except TextError TextId × TextModel :=
  match model.lookup source with
  | .error refusal => (.error refusal, model)
  | .ok content =>
    let (id, model) := model.made content.contents
    (.ok id, model)

/-- `slots` cut or padded with `none` to `size` slots: `snapshotOf` lined up
with the snapshots before one more of each is pushed. -/
private def padded (slots : Array (Option TextId)) (size : Nat) : Array (Option TextId) :=
  slots.extract 0 size ++ Array.replicate (size - slots.size) none

/-- The model's answer to taking the job's snapshot `snapshot` into the
store, and the model after it: what this run was handed under that name
(`arrived`) becomes a snapshot of the store, under the next id, as one
`TextId.snapshot` took would. What was handed stays as it was, so adopting
again gives another id. A name this run was not handed is refused and takes
nothing in. -/
def adopt (model : TextModel) (snapshot : JobSnapshotId) :
    Except TextError SnapshotId × TextModel :=
  match model.arrived.find? (·.1 == snapshot) with
  | some (_, content) =>
    (.ok ⟨model.snapshots.size⟩,
      { model with
        snapshots := model.snapshots.push (some content)
        snapshotOf := (padded model.snapshotOf model.snapshots.size).push none })
  | none => (.error .noSuchSnapshot, model)

/-- The changes that apply `script` to a text, taking what it puts in from
`source`: `none` when the steps do not walk the whole of `source`, an insert
does not start where the walk is, or a step starts or stops at an offset that
is not a position of it. Whether the changes fit the text is `apply`'s to
say. -/
def scriptChanges (script : Diff.Script) (source : String) : Option (Array Change) := do
  let mut offset := 0
  let mut changes := #[]
  for step in script do
    match step with
    | .retain count =>
      offset := offset + count
      changes := changes.push (.retain count)
    | .delete count =>
      changes := changes.push (.delete count)
    | .insert start count =>
      unless start == offset do
        none
      changes := changes.push (.insert (← slice source start (start + count)))
      offset := start + count
    unless isPosition source offset do
      none
  unless offset == source.utf8ByteSize do
    none
  return changes

/-- The model's answer to applying `script` to the text `id`, taking what it
puts in from `source`, with `origin` as who made the edit, unless its
revision is not `base`; and the model after it. The refusals are looked for
in the order the port gives. An accepted script is the transaction of its
changes with no selection, so it goes through `apply` and is one edit like
any other. -/
def applyScript (model : TextModel) (id : TextId) (base : Nat) (source : TextSource)
    (script : Diff.Script) (origin : Origin) : Except TextError Nat × TextModel :=
  match model.lookup (.text id) with
  | .error refusal => (.error refusal, model)
  | .ok content =>
    if content.revision != base then (.error .moved, model)
    else
      match model.lookup source with
      | .error refusal => (.error refusal, model)
      | .ok taken =>
        match scriptChanges script taken.contents with
        | none => (.error .badChange, model)
        | some changes => model.apply id { changes } origin

/-- `slots` with `value` at `index`, padded with `none` up to it. -/
def setSlot {α : Type} (slots : Array (Option α)) (index : Nat) (value : Option α) :
    Array (Option α) :=
  (slots ++ Array.replicate (index + 1 - slots.size) none).setIfInBounds index value

/-- The excerpt text `id`; `none` when it is not one, or was released. -/
def excerptOf? (model : TextModel) (id : TextId) : Option ExcerptModel :=
  (model.excerpts[id.index]?).join

/-- Whether the text `id` is an excerpt text. -/
def isExcerpt (model : TextModel) (id : TextId) : Bool :=
  (model.excerptOf? id).isSome

/-- The source `id` as an excerpt reads it: what it holds now and its
markers, or, once it was released, what it held and its markers then. -/
def sourceOf? (model : TextModel) (id : TextId) : Option (TextContent × Array (Option Marker)) :=
  match model.texts[id.index]? with
  | some (some content) => some (content, model.markersOf id)
  | _ => (model.retired[id.index]?).join

/-- The offset of the anchor at `index` of `markers`, if it is one. -/
def anchorAt? (markers : Array (Option Marker)) (index : Nat) : Option Nat :=
  match markers[index]? with
  | some (some (.anchor anchor)) => some anchor.offset
  | _ => none

/-- Where the anchors of `piece` are in its source now, when the source has
moved since the excerpt read it and still holds both. -/
def endsOf? (model : TextModel) (piece : ExcerptPiece) : Option (Nat × Nat) := do
  let (content, markers) ← model.sourceOf? piece.source
  guard (content.revision != piece.seen)
  let start ← anchorAt? markers piece.start
  let stop ← anchorAt? markers piece.stop
  return (start, max start stop)

/-- Where the range `range` and the closed range `bound` meet: `none` when
they do not, and an empty range when they only touch. -/
def meet (range bound : Nat × Nat) : Option (Nat × Nat) :=
  let start := max range.1 bound.1
  let stop := min range.2 bound.2
  if start ≤ stop then some (start, stop) else none

/-- The edits `edits` of a source cut to an excerpt: each old range to `old`,
where the excerpt was, and each new range to `new`, where its anchors are
now; an edit left with both empty is passed over. `none` when the cut edits
do not line up with the two ranges: in order, and with every stretch they
keep as long in both. This is the library's rule (`editor_text::excerpt`). -/
def clipped (edits : Array Edit) (old new : Nat × Nat) :
    Option (Array ((Nat × Nat) × (Nat × Nat))) := do
  let mut cut := #[]
  let mut oldAt := old.1
  let mut newAt := new.1
  for edit in edits do
    match meet (edit.old.start, edit.old.stop) old, meet (edit.new.start, edit.new.stop) new with
    | none, none =>
      continue
    | none, some n =>
      unless n.1 == n.2 do
        none
    | some o, none =>
      unless o.1 == o.2 do
        none
    | some o, some n =>
      unless o.1 == o.2 && n.1 == n.2 do
        unless o.1 ≥ oldAt && n.1 ≥ newAt && o.1 - oldAt == n.1 - newAt do
          none
        oldAt := o.2
        newAt := n.2
        cut := cut.push (o, n)
  guard (old.2 ≥ oldAt && new.2 ≥ newAt && old.2 - oldAt == new.2 - newAt)
  return cut

/-- The runs that catch an excerpt text of `pieces` up with its sources, in
the order they come, and the pieces after. Each piece starts in the text one
byte after the last ends. -/
def catchUp (model : TextModel) (pieces : Array ExcerptPiece) : Array Run × Array ExcerptPiece :=
  let (runs, next, _) :=
    pieces.foldl (init := (#[], #[], 0)) fun (runs, next, here) piece =>
      let length := piece.range.2 - piece.range.1
      match model.endsOf? piece, model.sourceOf? piece.source with
      | some new, some (content, _) =>
        let log := model.logs[piece.source.index]?.getD {}
        let cut := (log.since content piece.seen).toOption.bind (clipped ·.edits piece.range new)
        let made : Array Run :=
          match cut with
          | some cut =>
            cut.map fun (o, n) =>
              ⟨here + (o.1 - piece.range.1), here + (o.2 - piece.range.1),
                between content.contents n.1 n.2⟩
          | none => #[⟨here, here + length, between content.contents new.1 new.2⟩]
        (runs ++ made.filter (fun run => run.start != run.stop || !run.inserted.isEmpty),
          next.push
            { piece with
              seen := content.revision, range := new },
          here + length + 1)
      | _, _ => (runs, next.push piece, here + length + 1)
  (runs, next)

/-- The model after the list of the excerpt text `id` wrote it, producing
`revision`, leaving it with `pieces`: the inverse of that revision is
dropped, as the library drops it. -/
def listWrote (model : TextModel) (id : TextId) (pieces : Array ExcerptPiece) (revision : Nat) :
    TextModel :=
  { model with
    excerpts := model.excerpts.modify id.index (·.map ({ · with pieces }))
    histories := model.histories.modify id.index (·.drop revision revision) }

/-- The model with the excerpt text `id`, which is lent its content, caught
up with its sources: one edit for all that changed in its excerpts, when any
source moved, and the model as it was otherwise. -/
def caughtUp (model : TextModel) (id : TextId) : TextModel :=
  match model.excerptOf? id, model.texts[id.index]? with
  | some excerpt, some (some content) =>
    if excerpt.pieces.any (fun piece => (model.endsOf? piece).isSome) then
      let (runs, pieces) := model.catchUp excerpt.pieces
      let text :=
        (runs.foldrM (fun run made => splice made run.start run.stop run.inserted)
              content.contents).getD
          content.contents
      (model.changed id content text runs .unattributed).listWrote id pieces (content.revision + 1)
    else model
  | _, _ => model

/-- The model after `f`, with the text `id` lent to it when it is an excerpt
text: its content put in its slot of `texts` and caught up first, and taken
back after. For a plain text, and for an id that names nothing, it is `f`
of the model as it is. -/
def onText {α : Type} (model : TextModel) (id : TextId) (f : TextModel → α × TextModel) :
    α × TextModel :=
  match model.texts[id.index]? with
  | some (some _) => f model
  | _ =>
    match model.excerptOf? id with
    | some excerpt =>
      let lent := { model with texts := model.texts.setIfInBounds id.index (some excerpt.content) }
      let (reply, after) := f (lent.caughtUp id)
      match after.texts[id.index]? with
      | some (some content) =>
        (reply,
          { after with
            texts := after.texts.setIfInBounds id.index none
            excerpts := after.excerpts.modify id.index (·.map ({ · with content })) })
      | _ => (reply, after)
    | none => f model

/-- `onText` for the text a source names, and `f` of the model as it is for
a snapshot. -/
def onSource {α : Type} (model : TextModel) (source : TextSource) (f : TextModel → α × TextModel) :
    α × TextModel :=
  match source with
  | .text id => model.onText id f
  | .snapshot _ => f model

/-- Whether the text `id` is one the store holds, plain or excerpt. -/
def holds (model : TextModel) (id : TextId) : Bool :=
  (match model.texts[id.index]? with
    | some (some _) => true
    | _ => false) ||
    model.isExcerpt id

/-- Why the store refuses `list` as an excerpt text's, in the order the port
gives; `none` when it does not. -/
def listRefusal? (model : TextModel) (list : Array Excerpt) : Option TextError :=
  if list.any (fun excerpt => !model.holds excerpt.source) then some .noSuchText
  else
    if list.any (fun excerpt => model.isExcerpt excerpt.source) then some .excerpted
    else
      let fits (excerpt : Excerpt) : Bool :=
        match model.lookup (.text excerpt.source) with
        | .ok content =>
          excerpt.start ≤ excerpt.stop && isPosition content.contents excerpt.start &&
            isPosition content.contents excerpt.stop
        | .error _ => false
      if list.all fits then none else some .badRange

/-- The model with the anchors of `piece` given up in its source, if the
source is held. -/
def unmarkPiece (model : TextModel) (piece : ExcerptPiece) : TextModel :=
  match model.texts[piece.source.index]? with
  | some (some _) =>
    { model with
      markers :=
        model.markers.modify piece.source.index fun table =>
          (table.setIfInBounds piece.start none).setIfInBounds piece.stop none }
  | _ => model

/-- The model with the anchors of `excerpt` marked in its source, start then
end, and the piece that holds them. -/
def markPiece (model : TextModel) (excerpt : Excerpt) : TextModel × ExcerptPiece :=
  let start := (model.markersOf excerpt.source).size
  let revision := ((model.lookup (.text excerpt.source)).toOption.map (·.revision)).getD 0
  ({ model with
      markers :=
        model.markers.modify excerpt.source.index fun table =>
          (table.push (some (.anchor ⟨excerpt.start, .before⟩))).push
            (some (.anchor ⟨excerpt.stop, .after⟩)) },
    ⟨excerpt.source, start, start + 1, revision, (excerpt.start, excerpt.stop)⟩)

/-- The model after the list of the excerpt text `id`, lent and caught up,
is replaced with `list`, which the store accepts: the excerpts the two lists
start and end with alike are kept, the others' anchors given up and new ones
marked, and one edit replaces the bytes between the two kept runs. -/
def setList (model : TextModel) (id : TextId) (list : Array Excerpt) : TextModel :=
  match model.excerptOf? id, model.texts[id.index]? with
  | some excerpt, some (some content) =>
    let old := excerpt.pieces
    let alike (piece : ExcerptPiece) (wanted : Excerpt) : Bool :=
      piece.source == wanted.source && piece.range == (wanted.start, wanted.stop)
    let kept :=
      ((old.toList.zip list.toList).takeWhile fun (piece, wanted) => alike piece wanted).length
    let most := min old.size list.size - kept
    let keptAtEnd :=
      (((old.toList.reverse.zip list.toList.reverse).take most).takeWhile fun (piece, wanted) =>
          alike piece wanted).length
    -- Where each old excerpt starts in the text: one byte after the last.
    let starts :=
      (old.foldl (init := (#[], 0)) fun (starts, here) piece =>
          (starts.push here, here + (piece.range.2 - piece.range.1) + 1)).1
    let length := content.contents.utf8ByteSize
    let keptStart :=
      match kept with
      | 0 => 0
      | last + 1 =>
        (starts[last]?.getD 0) +
          ((old[last]?.map fun piece => piece.range.2 - piece.range.1).getD 0)
    let keptEnd := if keptAtEnd == 0 then length else (starts[old.size - keptAtEnd]?.getD length)
    let model := (old.extract kept (old.size - keptAtEnd)).foldl unmarkPiece model
    let fresh := list.extract kept (list.size - keptAtEnd)
    let (model, made) :=
      fresh.foldl (init := (model, #[])) fun (model, made) wanted =>
        let (model, piece) := model.markPiece wanted
        (model, made.push piece)
    let read (wanted : Excerpt) : String :=
      match model.lookup (.text wanted.source) with
      | .ok source => between source.contents wanted.start wanted.stop
      | .error _ => ""
    let inserted :=
      (if kept > 0 && (!fresh.isEmpty || keptAtEnd > 0) then "\n" else "") ++
        "\n".intercalate (fresh.map read).toList ++
        if keptAtEnd > 0 && !fresh.isEmpty then "\n" else ""
    let text := (splice content.contents keptStart keptEnd inserted).getD content.contents
    let pieces := old.extract 0 kept ++ made ++ old.extract (old.size - keptAtEnd) old.size
    (model.changed id content text #[⟨keptStart, keptEnd, inserted⟩] .unattributed).listWrote id
      pieces (content.revision + 1)
  | _, _ => model

/-- The model's answer to making an excerpt text of `list`, and the model
after it: a new text, at the next id, made empty as `made` makes one and then
given the list, so that it is at revision 1. A refused list makes no text. -/
def createExcerpts (model : TextModel) (list : Array Excerpt) :
    Except TextError TextId × TextModel :=
  match model.listRefusal? list with
  | some refusal => (.error refusal, model)
  | none =>
    let (id, model) := model.made ""
    let model :=
      { model with
        texts := model.texts.setIfInBounds id.index none
        excerpts := setSlot model.excerpts id.index (some {}) }
    model.onText id fun model => (.ok id, model.setList id list)

/-- The model's answer to replacing the list of the text `id` with `list`,
and the model after it. The refusals are looked for in the order the port
gives, before anything is caught up. -/
def setExcerpts (model : TextModel) (id : TextId) (list : Array Excerpt) :
    Except TextError Unit × TextModel :=
  if !model.holds id then (.error .noSuchText, model)
  else
    if !model.isExcerpt id then (.error .notExcerpted, model)
    else
      match model.listRefusal? list with
      | some refusal => (.error refusal, model)
      | none => model.onText id fun model => (.ok (), model.setList id list)

/-- The model after the text `id`, which it holds, is released: an excerpt
text gives its anchors up in its sources and its excerpts go; a plain text
that an excerpt text reads is kept as it was for that excerpt text
(`retired`). Either way the slot is then emptied as `released` empties it. -/
def releasing (model : TextModel) (id : TextId) : TextModel :=
  match model.excerptOf? id with
  | some excerpt =>
    let model := excerpt.pieces.foldl unmarkPiece model
    { model with excerpts := model.excerpts.setIfInBounds id.index none }.released (.text id)
  | none =>
    let read :=
      model.excerpts.any fun slot => slot.any fun excerpt => excerpt.pieces.any (·.source == id)
    let model :=
      match model.texts[id.index]?, read with
      | some (some content), true =>
        { model with
          retired := setSlot model.retired id.index (some (content, model.markersOf id)) }
      | _, _ => model
    model.released (.text id)

/-- Where each of `pieces` starts in its excerpt text: one byte after the
last ends. -/
def startsOf (pieces : Array ExcerptPiece) : Array Nat :=
  (pieces.foldl (init := (#[], 0)) fun (starts, here) piece =>
      (starts.push here, here + (piece.range.2 - piece.range.1) + 1)).1

/-- Each of `pieces` as it is placed: its range of its excerpt text, by the
walk `startsOf` takes, and its range of its source. -/
def placedOf (pieces : Array ExcerptPiece) : Array Excerpt.Placed :=
  (startsOf pieces).zipWith
    (fun start piece =>
      ⟨start, start + (piece.range.2 - piece.range.1), piece.range.1, piece.range.2⟩)
    pieces

/-- The model's answer to where each excerpt of `source` is: of an excerpt
text, its pieces as they are placed after the catch-up; of a snapshot, the
list it was taken with. A plain text and a snapshot of one are refused with
`notExcerpted`. -/
def excerptsOf (model : TextModel) (source : TextSource) :
    Except TextError (Array Excerpt.Placed) × TextModel :=
  match source with
  | .text id =>
    model.onText id fun model =>
      match model.excerptOf? id, model.lookup (.text id) with
      | some excerpt, .ok _ => (.ok (placedOf excerpt.pieces), model)
      | _, .error refusal => (.error refusal, model)
      | none, .ok _ => (.error .notExcerpted, model)
  | .snapshot id =>
    match model.lookup (.snapshot id) with
    | .error refusal => (.error refusal, model)
    | .ok _ =>
      match (model.snapshotPlaced[id.index]?).join with
      | some list => (.ok list, model)
      | none => (.error .notExcerpted, model)

/-- The piece of `pieces` that holds the position `offset` of its excerpt
text, both its ends included, and where it starts there: the last that starts
at or before `offset`, if it reaches it. `none` for an empty list, and past
the end. -/
def pieceAt? (pieces : Array ExcerptPiece) (offset : Nat) : Option (Nat × Nat) := do
  let (start, index) ← ((startsOf pieces).zipIdx.toList.filter (·.1 ≤ offset)).getLast?
  let piece ← pieces[index]?
  guard (offset ≤ start + (piece.range.2 - piece.range.1))
  return (index, start)

/-- The runs `runs` of an edit of an excerpt text of `pieces`, mapped to its
sources: each source the edit changes, by ascending id, with its runs, by
ascending start. Refused with `outsideExcerpt` when a run is not inside one
piece, both ends included, or its range in the source meets another piece of
that source, both ends included; then with `noSuchText` when a source is no
longer held (`retired`). This is the library's rule
(`editor_text::excerpt`). -/
def excerptEdits (model : TextModel) (pieces : Array ExcerptPiece) (runs : Array Run) :
    Except TextError (Array (TextId × Array Run)) := do
  let mut mapped : Array (TextId × Run) := #[]
  for run in runs do
    let some (index, here) := pieceAt? pieces run.start | throw .outsideExcerpt
    let some piece := pieces[index]? | throw .outsideExcerpt
    unless run.stop ≤ here + (piece.range.2 - piece.range.1) do
      throw .outsideExcerpt
    let start := piece.range.1 + (run.start - here)
    let stop := piece.range.1 + (run.stop - here)
    let twice :=
      pieces.zipIdx.any fun (other, at') =>
        at' != index && other.source == piece.source && (meet (start, stop) other.range).isSome
    if twice then
      throw .outsideExcerpt
    mapped := mapped.push (piece.source, ⟨start, stop, run.inserted⟩)
  let held (source : TextId) : Bool :=
    match model.texts[source.index]? with
    | some (some _) => true
    | _ => false
  if mapped.any (fun (source, _) => !held source) then
    throw .noSuchText
  let sources := (mapped.map (·.1.index)).toList.mergeSort (· ≤ ·) |>.eraseDups
  return sources.toArray.map fun index =>
      (⟨index⟩,
        ((mapped.filter (·.1.index == index)).map (·.2)).toList.mergeSort
            (fun one other => one.start ≤ other.start) |>.toArray)

/-- The model after the source `id` is given the edit of the runs `runs`, in
order, with `origin`, as an edit of it would be: one revision, recorded in
its log, its markers moved. -/
def sourceEdited (model : TextModel) (id : TextId) (runs : Array Run) (origin : Origin) :
    TextModel :=
  match model.texts[id.index]? with
  | some (some content) =>
    let text :=
      (runs.foldrM (fun run made => splice made run.start run.stop run.inserted)
            content.contents).getD
        content.contents
    model.changed id content text runs origin
  | _ => model

/-- The model's answer to an edit of the excerpt text `id`, and the model
after it. `check`, given what the text holds once caught up, refuses the edit
as a plain text would, or gives the runs it changes. They are mapped to the
sources (`excerptEdits`), each source is given its edit with `origin`, by
ascending id, and the excerpt text then catches up once: its revision is the
reply. An edit that changes nothing is one revision of the excerpt text, as
an edit of the list that changes nothing is. A refused edit changes no
source. -/
def excerptApply (model : TextModel) (id : TextId) (check : String → Except TextError (Array Run))
    (origin : Origin) : Except TextError Nat × TextModel :=
  model.onText id fun model =>
    match model.excerptOf? id, model.texts[id.index]? with
    | some excerpt, some (some content) =>
      let checked :=
        check content.contents |>.bind fun runs =>
          model.excerptEdits excerpt.pieces
            (runs.filter fun run => run.start != run.stop || !run.inserted.isEmpty)
      match checked with
      | .error refusal => (.error refusal, model)
      | .ok edits =>
        let model :=
          edits.foldl (fun model (source, runs) => model.sourceEdited source runs origin) model
        let model := model.caughtUp id
        match model.texts[id.index]? with
        | some (some after) =>
          if after.revision == content.revision then
            let pieces := ((model.excerptOf? id).map (·.pieces)).getD excerpt.pieces
            (.ok (content.revision + 1),
              (model.changed id content content.contents #[] .unattributed).listWrote id pieces
                (content.revision + 1))
          else (.ok after.revision, model)
        | _ => (.ok content.revision, model)
    | _, _ => (.error .noSuchText, model)

/-- The runs a transaction changes of `text`, or its refusal, in the port's
order: as `apply` refuses it. -/
def transactionRuns (transaction : Transaction) (text : String) : Except TextError (Array Run) :=
  if !(isSelection transaction.before && isSelection transaction.after) then .error .badSelection
  else
    match applyChanges text transaction.changes with
    | none => .error .badChange
    | some after =>
      if selectionFits text transaction.before && selectionFits after transaction.after then
        .ok (runsOf transaction.changes).1
      else .error .badSelection

/-- The run of a replace of `text`'s bytes from `start` up to `stop` by `s`,
or `badRange`, as `edit` refuses it. -/
def replaceRuns (start stop : Nat) (s : String) (text : String) : Except TextError (Array Run) :=
  match splice text start stop s with
  | none => .error .badRange
  | some _ => .ok #[⟨start, stop, s⟩]

/-- `plain` of the model when the text `id` is a plain text, or names
nothing, and `excerpt` of it when it is an excerpt text. A text whose slot of
`texts` holds content is plain, so every theorem about plain texts is about
`plain`. -/
def editAny {α : Type} (model : TextModel) (id : TextId)
    (plain excerpt : TextModel → α × TextModel) : α × TextModel :=
  match model.texts[id.index]? with
  | some (some _) => plain model
  | _ => if model.isExcerpt id then excerpt model else plain model

/-- The model's answer to an insert or a delete of the text `id` that
replaces its bytes from `start` up to `stop` by `s`: `edit` for a plain text,
and for an excerpt text its sources' edit, made by nobody. -/
def editText (model : TextModel) (id : TextId) (start stop : Nat) (s : String) :
    Except TextError Unit × TextModel :=
  model.editAny id (·.edit id start stop s) fun model =>
    let (reply, model) := model.excerptApply id (replaceRuns start stop s) .unattributed
    (reply.map fun _ => (), model)

/-- The model's answer to applying `transaction` to the text `id`, with
`origin`: `apply` for a plain text, and for an excerpt text its sources'
edit. -/
def applyText (model : TextModel) (id : TextId) (transaction : Transaction) (origin : Origin) :
    Except TextError Nat × TextModel :=
  model.editAny id (·.apply id transaction origin)
    (·.excerptApply id (transactionRuns transaction) origin)

/-- The model's answer to where the position `offset` of the excerpt text
`id` is, caught up first: its piece, the piece's source, and the offset that
far into the piece's range there. -/
def locate (model : TextModel) (id : TextId) (offset : Nat) :
    Except TextError (Option Located) × TextModel :=
  model.onText id fun model =>
    match model.excerptOf? id, model.texts[id.index]? with
    | some excerpt, some (some content) =>
      if isPosition content.contents offset then
        (.ok do
            let (index, here) ← pieceAt? excerpt.pieces offset
            let piece ← excerpt.pieces[index]?
            return ⟨index, piece.source, piece.range.1 + (offset - here)⟩,
          model)
      else (.error .badPosition, model)
    | none, some (some _) => (.error .notExcerpted, model)
    | _, _ => (.error .noSuchText, model)

/-- The model's answer to each request, and the model after it. -/
def handle : (request : TextRequest) → TextModel → request.Reply × TextModel
  | .create initial, model => model.made initial
  | .insert id offset s, model => model.editText id offset offset s
  | .delete id start stop, model => model.editText id start stop ""
  | .read id, model =>
    model.onText id fun model =>
      match model.lookup (.text id) with
      | .error refusal => (.error refusal, model)
      | .ok content => (.ok content.contents, model)
  | .snapshot id, model =>
    model.onText id fun model =>
      match model.lookup (.text id) with
      | .error refusal => (.error refusal, model)
      | .ok content =>
        (.ok ⟨model.snapshots.size⟩,
          { model with
            snapshots := model.snapshots.push (some content)
            snapshotOf := (padded model.snapshotOf model.snapshots.size).push (some id)
            snapshotPlaced :=
              setSlot model.snapshotPlaced model.snapshots.size
                ((model.excerptOf? id).map (placedOf ·.pieces)) })
  | .ask (.text id) (.locate offset), model => model.locate id offset
  | .ask source .excerpts, model => model.excerptsOf source
  | .ask source query, model =>
    model.onSource source fun model =>
      match model.lookup source with
      | .error refusal => (.error refusal, model)
      | .ok content => (answer content query, model)
  | .release source, model =>
    match source with
    | .text id =>
      if model.holds id then (.ok (), model.releasing id) else (.error .noSuchText, model)
    | .snapshot _ =>
      match model.lookup source with
      | .error refusal => (.error refusal, model)
      | .ok _ => (.ok (), model.released source)
  | .apply id transaction origin, model => model.applyText id transaction origin
  | .log id query, model =>
    let answered (model : TextModel) : Except TextError query.Answer × TextModel :=
      match model.lookup (.text id) with
      | .error refusal => (.error refusal, model)
      | .ok content => (answerLog (model.logs[id.index]?.getD {}) content query, model)
    -- A trace of an excerpt text is refused, with nothing caught up.
    if query matches .trace .. then answered model else model.onText id answered
  | .forget id revision, model => model.onText id (·.forget id revision)
  | .mark id marker, model => model.onText id (·.mark id marker)
  | .marker id marker, model => model.onText id fun model => (model.markerOf id marker, model)
  | .place id «at» marker, model => model.onText id (·.place id «at» marker)
  | .unmark id marker, model => model.onText id (·.unmark id marker)
  | .applyInverse id first last origin, model => model.applyInverse id first last origin
  | .dropInverses id first last, model => model.onText id (·.dropInverses id first last)
  | .copy source, model => model.onSource source (·.copy source)
  | .adopt snapshot, model => model.adopt snapshot
  | .applyScript id base source script origin, model =>
    -- The source is caught up only once the text and its revision passed.
    match model.lookup (.text id) with
    | .error refusal => (.error refusal, model)
    | .ok content =>
      if content.revision != base then (.error .moved, model)
      else model.onSource source (·.applyScript id base source script origin)
  | .excerpts list, model => model.createExcerpts list
  | .setExcerpts id list, model => model.setExcerpts id list

/-- An edit of a plain text is `plain`, whatever `excerpt` is: the excerpt
path is taken only by a text whose slot holds no content. -/
theorem editAny_plain {α : Type} (model : TextModel) (id : TextId) (content : TextContent)
    (plain excerpt : TextModel → α × TextModel)
    (live : model.texts[id.index]? = some (some content)) :
    model.editAny id plain excerpt = plain model := by simp [editAny, live]

/-- An insert or a delete of a plain text is `edit`. -/
@[simp]
theorem editText_plain (model : TextModel) (id : TextId) (content : TextContent) (start stop : Nat)
    (s : String) (live : model.texts[id.index]? = some (some content)) :
    model.editText id start stop s = model.edit id start stop s :=
  editAny_plain model id content _ _ live

/-- A transaction of a plain text is `apply`. -/
@[simp]
theorem applyText_plain (model : TextModel) (id : TextId) (content : TextContent)
    (transaction : Transaction) (origin : Origin)
    (live : model.texts[id.index]? = some (some content)) :
    model.applyText id transaction origin = model.apply id transaction origin :=
  editAny_plain model id content _ _ live

end TextModel

/-- Runs a command against the model `model`: its result, or the refusal it
failed with, and the model after its last request. -/
def TextM.runModel {α : Type} (command : TextM α) (model : TextModel) :
    Except TextError α × TextModel :=
  Program.run (port := textPort) TextModel.handle command.run model

/-! What `runModel` does to each way of building a command: `pure`, a bind,
and each operation of the port. They are `simp` lemmas, so a theorem about a
command is proved by unfolding the command and calling `simp`, which is left
with facts about the model alone. A new operation gets its lemma here. -/

namespace TextM

variable {α β : Type}

@[simp]
theorem runModel_pure (value : α) (model : TextModel) :
    (pure value : TextM α).runModel model = (.ok value, model) :=
  rfl

@[simp]
theorem runModel_bind (command : TextM α) (after : α → TextM β) (model : TextModel) :
    (command >>= after).runModel model =
      match command.runModel model with
      | (.ok value, model) => (after value).runModel model
      | (.error refusal, model) => (.error refusal, model) := by
  -- A bind in `TextM` is a bind of programs, whose second part goes on to
  -- `after` on a result and stops on a refusal.
  have unfolded : (command >>= after).run = command.run >>= ExceptT.bindCont after := rfl
  simp only [runModel, unfolded, Program.run_bind]
  generalize Program.run TextModel.handle command.run model = outcome
  obtain ⟨_ | _, _⟩ := outcome <;> rfl

@[simp]
theorem runModel_createText (initial : String) (model : TextModel) :
    (createText initial).runModel model =
      (.ok ⟨model.texts.size⟩,
        { model with
          texts := model.texts.push (some { contents := initial })
          logs := model.logs.push (.new initial)
          markers := model.markers.push #[]
          histories := model.histories.push {} }) :=
  rfl

@[simp]
theorem runModel_read (id : TextId) (model : TextModel) :
    id.read.runModel model = TextModel.handle (.read id) model :=
  rfl

@[simp]
theorem runModel_insert (id : TextId) (offset : Nat) (s : String) (model : TextModel) :
    (id.insert offset s).runModel model = model.editText id offset offset s :=
  rfl

@[simp]
theorem runModel_delete (id : TextId) (start stop : Nat) (model : TextModel) :
    (id.delete start stop).runModel model = model.editText id start stop "" :=
  rfl

@[simp]
theorem runModel_snapshot (id : TextId) (model : TextModel) :
    id.snapshot.runModel model = TextModel.handle (.snapshot id) model :=
  rfl

@[simp]
theorem runModel_ask (source : TextSource) (query : TextQuery) (model : TextModel) :
    (source.ask query).runModel model = TextModel.handle (.ask source query) model :=
  rfl

/-- The length of a text is asked like any question. It is a lemma of its
own because `simp` does not see `runModel_ask` in a question written at its
answer's type, here `Nat`. -/
@[simp]
theorem runModel_byteLength (id : TextId) (model : TextModel) :
    id.byteLength.runModel model = TextModel.handle (.ask (.text id) .byteLength) model :=
  rfl

/-- The revision of a text is asked like any question, and is a lemma of its
own for the reason `runModel_byteLength` is. -/
@[simp]
theorem runModel_revision (id : TextId) (model : TextModel) :
    id.revision.runModel model = TextModel.handle (.ask (.text id) .revision) model :=
  rfl

@[simp]
theorem runModel_release (source : TextSource) (model : TextModel) :
    source.release.runModel model = TextModel.handle (.release source) model :=
  rfl

@[simp]
theorem runModel_apply (id : TextId) (transaction : Transaction) (origin : Origin)
    (model : TextModel) :
    (id.apply transaction origin).runModel model = model.applyText id transaction origin :=
  rfl

@[simp]
theorem runModel_askLog (id : TextId) (query : LogQuery) (model : TextModel) :
    (id.askLog query).runModel model = TextModel.handle (.log id query) model :=
  rfl

@[simp]
theorem runModel_forget (id : TextId) (revision : Nat) (model : TextModel) :
    (id.forget revision).runModel model = model.onText id (·.forget id revision) :=
  rfl

@[simp]
theorem runModel_mark (id : TextId) (marker : Marker) (model : TextModel) :
    (id.mark marker).runModel model = model.onText id (·.mark id marker) :=
  rfl

@[simp]
theorem runModel_marker (id : TextId) (marker : MarkerId) (model : TextModel) :
    (id.marker marker).runModel model =
      model.onText id fun model => (model.markerOf id marker, model) :=
  rfl

@[simp]
theorem runModel_place (id : TextId) («at» : MarkerId) (marker : Marker) (model : TextModel) :
    (id.place «at» marker).runModel model = model.onText id (·.place id «at» marker) :=
  rfl

@[simp]
theorem runModel_unmark (id : TextId) (marker : MarkerId) (model : TextModel) :
    (id.unmark marker).runModel model = model.onText id (·.unmark id marker) :=
  rfl

@[simp]
theorem runModel_applyInverse (id : TextId) (first last : Nat) (origin : Origin)
    (model : TextModel) :
    (id.applyInverse first last origin).runModel model = model.applyInverse id first last origin :=
  rfl

@[simp]
theorem runModel_dropInverses (id : TextId) (first last : Nat) (model : TextModel) :
    (id.dropInverses first last).runModel model = model.onText id (·.dropInverses id first last) :=
  rfl

@[simp]
theorem runModel_copy (source : TextSource) (model : TextModel) :
    source.copy.runModel model = model.onSource source (·.copy source) :=
  rfl

@[simp]
theorem runModel_adopt (snapshot : JobSnapshotId) (model : TextModel) :
    snapshot.adopt.runModel model = model.adopt snapshot :=
  rfl

end TextM

/-- A splice at the end of a text is an append: the length of a text in bytes
is a character boundary of it, and nothing follows it. -/
theorem TextModel.splice_end (text s : String) :
    TextModel.splice text text.utf8ByteSize text.utf8ByteSize s = some (text ++ s) := by
  have valid : (String.Pos.Raw.mk text.utf8ByteSize).IsValid text :=
    String.Pos.Raw.isValid_rawEndPos
  have atEnd : text.pos ⟨text.utf8ByteSize⟩ valid = text.endPos := String.Pos.ext rfl
  simp [TextModel.splice, valid, atEnd, String.sliceTo_endPos]

/-- A splice of a text written as three parts, over the middle one, replaces
that part: the ends of the first part and of the first two are character
boundaries of the whole, and what is before the one and after the other are
the first part and the last. Every fact about a splice below comes from
this one. -/
theorem TextModel.splice_append (before between after s : String) :
    TextModel.splice (before ++ between ++ after) before.utf8ByteSize
        (before.utf8ByteSize + between.utf8ByteSize) s =
      some (before ++ s ++ after) := by
  have startValid : (String.Pos.Raw.mk before.utf8ByteSize).IsValid (before ++ between ++ after) :=
    String.Pos.Raw.isValid_iff_exists_append.2
      ⟨before, between ++ after, by simp [String.append_assoc], rfl⟩
  have stopValid :
    (String.Pos.Raw.mk (before.utf8ByteSize + between.utf8ByteSize)).IsValid
      (before ++ between ++ after) :=
    String.Pos.Raw.isValid_iff_exists_append.2
      ⟨before ++ between, after, rfl, by
        ext; simp⟩
  have left :
    ((before ++ between ++ after).sliceTo
          ((before ++ between ++ after).pos ⟨before.utf8ByteSize⟩ startValid)).copy =
      before :=
    String.copy_sliceTo_eq_iff_exists_splits.2
      ⟨between ++ after, ⟨by simp [String.append_assoc], rfl⟩⟩
  have right :
    ((before ++ between ++ after).sliceFrom
          ((before ++ between ++ after).pos ⟨before.utf8ByteSize + between.utf8ByteSize⟩
            stopValid)).copy =
      after :=
    String.copy_sliceFrom_eq_iff_exists_splits.2
      ⟨before ++ between,
        ⟨rfl, by
          ext; simp⟩⟩
  simp [TextModel.splice, startValid, stopValid, left, right]

/-- A splice that replaces nothing with nothing, at a character boundary,
leaves the text. -/
theorem TextModel.splice_nothing (text : String) (position : Nat)
    (boundary : (String.Pos.Raw.mk position).IsValid text) :
    TextModel.splice text position position "" = some text := by
  obtain ⟨before, after, rfl, atEnd⟩ := String.Pos.Raw.isValid_iff_exists_append.1 boundary
  have positionEq : position = before.utf8ByteSize := congrArg String.Pos.Raw.byteIdx atEnd
  subst positionEq
  simpa using TextModel.splice_append before "" after ""

/-- Inserting a string at a character boundary of a text and then deleting
the range it occupies, from that boundary for the string's length in bytes,
gives back the text. Both splices are accepted. -/
theorem TextModel.splice_insert_delete (text s : String) (position : Nat)
    (boundary : (String.Pos.Raw.mk position).IsValid text) :
    (TextModel.splice text position position s).bind
        (TextModel.splice · position (position + s.utf8ByteSize) "") =
      some text := by
  obtain ⟨before, after, rfl, atEnd⟩ := String.Pos.Raw.isValid_iff_exists_append.1 boundary
  have positionEq : position = before.utf8ByteSize := congrArg String.Pos.Raw.byteIdx atEnd
  subst positionEq
  have inserted := TextModel.splice_append before "" after s
  have deleted := TextModel.splice_append before s after ""
  simp only [String.append_empty, String.utf8ByteSize_empty, Nat.add_zero] at inserted deleted
  simp [inserted, deleted]

/-- A splice that is accepted was over a range in order whose ends are
character boundaries of the text. -/
theorem TextModel.splice_boundaries {text s made : String} {start stop : Nat}
    (spliced : TextModel.splice text start stop s = some made) :
    (String.Pos.Raw.mk start).IsValid text ∧
      (String.Pos.Raw.mk stop).IsValid text ∧ start ≤ stop := by
  unfold TextModel.splice at spliced
  split at spliced
  · assumption
  · cases spliced

/-- What `Transaction.replacing` makes of a text is the splice of its range,
for a range in order within the text that starts at a character boundary.

The boundary is needed for one corner: a transaction that replaces nothing
with nothing changes no range, so it fits any text wherever it was aimed,
while a splice is refused at an offset inside a character. -/
theorem TextModel.applyChanges_replacing (text s : String) (start stop : Nat)
    (boundary : (String.Pos.Raw.mk start).IsValid text) (ordered : start ≤ stop)
    (within : stop ≤ text.utf8ByteSize) :
    TextModel.applyChanges text (Transaction.replacing text.utf8ByteSize start stop s).changes =
      TextModel.splice text start stop s := by
  have whole : stop + (text.utf8ByteSize - stop) = text.utf8ByteSize := by omega
  have stopEq : start + (stop - start) = stop := by omega
  by_cases empty : s.isEmpty <;> by_cases same : stop = start
  · subst same
    have nothing : s = "" := String.isEmpty_iff.1 empty
    subst nothing
    simp [TextModel.applyChanges, Transaction.replacing, TextModel.runsOf, TextModel.runsOf.go,
      whole, TextModel.splice_nothing text stop boundary]
  · have nothing : s = "" := String.isEmpty_iff.1 empty
    subst nothing
    have some : ¬stop - start = 0 := by omega
    simp [TextModel.applyChanges, Transaction.replacing, TextModel.runsOf, TextModel.runsOf.go,
      some, whole, stopEq]
  · subst same
    simp [TextModel.applyChanges, Transaction.replacing, TextModel.runsOf, TextModel.runsOf.go,
      empty, whole]
  · have some : ¬stop - start = 0 := by omega
    simp [TextModel.applyChanges, Transaction.replacing, TextModel.runsOf, TextModel.runsOf.go,
      empty, some, whole, stopEq]

/-- The walk of `offsetOf` never answers an offset before the one it is at:
it answers where it is, or walks on, and a character is at least a byte. -/
theorem TextModel.offsetOf_go_le (unit : ColumnUnit) (point : Point) (chars : List Char)
    (offset : Nat) (here : Point) (found : Nat)
    (answered : offsetOf.go unit point chars offset here = some found) : offset ≤ found := by
  induction chars generalizing offset here with
  | nil =>
    unfold offsetOf.go at answered
    split at answered
    · injection answered with same
      omega
    · contradiction
  | cons c rest ih =>
    unfold offsetOf.go at answered
    split at answered
    · injection answered with same
      omega
    · split at answered
      · split at answered
        · contradiction
        · have := ih _ _ answered
          omega
      · have := ih _ _ answered
        omega

/-- The two conversions walk a text alike: from the same characters, offset
and point, where the walk of `offsetOf` answers an offset for `point`, the
walk of `pointOf` answers `point` for that offset. Each step of one is a step
of the other, and the walk of `pointOf` does not stop early, because the
offset answered is not before where the walk is. -/
theorem TextModel.pointOf_go_of_offsetOf_go (unit : ColumnUnit) (point : Point) (chars : List Char)
    (offset : Nat) (here : Point) (found : Nat)
    (answered : offsetOf.go unit point chars offset here = some found) :
    pointOf.go unit found chars offset here = some point := by
  induction chars generalizing offset here with
  | nil =>
    unfold offsetOf.go at answered
    split at answered
    next same =>
      injection answered with reached
      have arrived : here = point := by simpa using same
      simp [pointOf.go, reached, arrived]
    next => contradiction
  | cons c rest ih =>
    unfold offsetOf.go at answered
    split at answered
    next same =>
      injection answered with reached
      have arrived : here = point := by simpa using same
      simp [pointOf.go, reached, arrived]
    next =>
      have size := Char.utf8Size_pos c
      split at answered
      next lineFeed =>
        split at answered
        · contradiction
        · have past := offsetOf_go_le _ _ _ _ _ _ answered
          have rest := ih _ _ answered
          have before : (offset == found) = false := by
            simp
            omega
          have notPast : ¬offset > found := by omega
          simp [pointOf.go, before, notPast, lineFeed, rest]
      next notLineFeed =>
        have past := offsetOf_go_le _ _ _ _ _ _ answered
        have rest := ih _ _ answered
        have before : (offset == found) = false := by
          simp
          omega
        have notPast : ¬offset > found := by omega
        simp [pointOf.go, before, notPast, notLineFeed, rest]

/-- A conversion that answers is undone by the other: where a point names an
offset, that offset's point is the point, in every unit. This is the port's
rule that the conversions are inverses wherever they answer, for the
model. -/
theorem TextModel.offsetOf_pointOf (unit : ColumnUnit) (text : String) (point : Point)
    (offset : Nat) (found : offsetOf unit text point = some offset) :
    pointOf unit text offset = some point :=
  pointOf_go_of_offsetOf_go unit point text.toList 0 ⟨0, 0⟩ offset found

/-- Line start is idempotent: the line start of a line start is itself. If
the model answers `start` to the line start from `offset`, it answers `start`
to the line start from `start`.

The line start from a position is the offset of column 0 of the position's
row. That offset's point is column 0 of the same row (`offsetOf_pointOf`), so
the line start from it asks for the same offset again. -/
theorem TextModel.lineStart_idempotent (content : TextContent) (offset start : Nat)
    (answered : answer content (.motion .lineStart offset) = .ok start) :
    answer content (.motion .lineStart start) = .ok start := by
  have asked (position : Nat) :
    motion? content.contents .lineStart position =
      (pointOf .bytes content.contents position).bind fun point =>
        offsetOf .bytes content.contents ⟨point.row, 0⟩ :=
    rfl
  simp only [answer, asked] at answered ⊢
  cases located : pointOf .bytes content.contents offset with
  | none => simp [located] at answered
  | some point =>
    cases column : offsetOf .bytes content.contents ⟨point.row, 0⟩ with
    | none => simp [located, column] at answered
    | some first =>
      simp only [located, Option.bind_some, column] at answered
      injection answered with same
      subst same
      have back := offsetOf_pointOf .bytes content.contents ⟨point.row, 0⟩ first column
      simp [back, column]

/-! ## A text in step, and undoing an accepted edit

The model computes the text an inverse leaves by reading it: `applyInverse`
takes the text at the revision before the run from the log's `past`. An
accepted edit pushes the text it replaced onto `past`, so the inverse of
that one revision reads it back. That needs the log and the record of kept
inverses to have one entry a revision, which is what `InStep` says.

- `TextModel.InStep`: the log's `past` has as many entries as the text's
  revision, and the history's `dropped` and `carried` one more. It is
  stated so that it can be decided, and a check holds it of every live
  text after each request of a sample sequence
  (`ModelTest.textModelStepChecks`).
- `TextModel.inStep_made` and `TextModel.inStep_changed`: where it comes
  from. A text made in the empty store is in step, and an accepted edit,
  an applied inverse among them, keeps a text in step. That every request
  keeps it is not proved: the check holds it for the rest.
- `TextModel.apply_accepted`: an accepted transaction leaves `changed` of
  the model, at the next revision.
- `TextModel.apply_applyInverse`: for a text in step, an accepted
  transaction and then the inverse of the revision it produced leave the
  text holding what it held, and hand back the selection the transaction
  carried as the one before it.

The undo tree's theorems are built on the last
(`Editor/UndoTree/Theorems.lean`). -/

/-- The log and the kept inverses of the text `id` of `model` are in step
with the revision `revision`: the log holds the text at each of the
`revision` earlier revisions, and the record of kept inverses has a slot
for each revision from 0. -/
def TextModel.InStep (model : TextModel) (id : TextId) (revision : Nat) : Prop :=
  model.logs[id.index]?.map (·.past.size) = some revision ∧
    model.histories[id.index]?.map (·.dropped.size) = some (revision + 1) ∧
    model.histories[id.index]?.map (·.carried.size) = some (revision + 1)

instance (model : TextModel) (id : TextId) (revision : Nat) :
    Decidable (model.InStep id revision) := by
  unfold TextModel.InStep
  infer_instance

/-- What being in step says of the text's log and of its record of kept
inverses, each named. -/
theorem TextModel.InStep.parts {model : TextModel} {id : TextId} {revision : Nat}
    (inStep : model.InStep id revision) :
    (∃ log, model.logs[id.index]? = some log ∧ log.past.size = revision) ∧
      ∃ history,
        model.histories[id.index]? = some history ∧
          history.dropped.size = revision + 1 ∧ history.carried.size = revision + 1 := by
  obtain ⟨logged, dropped, carried⟩ := inStep
  obtain ⟨log, logAt, logSize⟩ := Option.map_eq_some_iff.mp logged
  obtain ⟨history, historyAt, droppedSize⟩ := Option.map_eq_some_iff.mp dropped
  refine ⟨⟨log, logAt, logSize⟩, history, historyAt, droppedSize, ?_⟩
  simpa [historyAt] using carried

/-- A text whose log and whose record of kept inverses have the sizes the
revision asks for is in step. -/
theorem TextModel.InStep.of {model : TextModel} {id : TextId} {revision : Nat} (log : TextLog)
    (history : TextHistory) (logAt : model.logs[id.index]? = some log)
    (logSize : log.past.size = revision) (historyAt : model.histories[id.index]? = some history)
    (droppedSize : history.dropped.size = revision + 1)
    (carriedSize : history.carried.size = revision + 1) : model.InStep id revision := by
  simp [TextModel.InStep, logAt, historyAt, logSize, droppedSize, carriedSize]

/-- A text made in the empty store is in step. -/
theorem TextModel.inStep_made (initial : String) :
    (({} : TextModel).made initial).2.InStep (({} : TextModel).made initial).1 0 := by
  refine .of (TextLog.new initial) {} ?_ ?_ ?_ ?_ ?_ <;> simp [TextModel.made, TextLog.new]

/-- An accepted edit keeps a text in step. -/
theorem TextModel.inStep_changed (model : TextModel) (id : TextId) (content : TextContent)
    (text : String) (runs : Array TextModel.Run) (origin : Origin) (state : Option Nat)
    (carried : Option Selection × Option Selection) (inStep : model.InStep id content.revision) :
    (model.changed id content text runs origin state carried).InStep id (content.revision + 1) := by
  obtain ⟨⟨log, logAt, logSize⟩, ⟨history, historyAt, historySize, carriedSize⟩⟩ := inStep.parts
  refine
    .of (log.record content.contents (content.revision + 1) runs origin)
      (history.record (content.revision + 1) state carried) ?_ ?_ ?_ ?_ ?_
  · simp [TextModel.changed, Array.getElem?_modify, logAt]
  · simp [TextLog.record, logSize]
  · simp [TextModel.changed, Array.getElem?_modify, historyAt]
  · simp [TextHistory.record, historySize]
  · simp [TextHistory.record, carriedSize]

/-- What an accepted transaction leaves: `changed` of the model, at the next
revision, carrying the transaction's two selections. -/
theorem TextModel.apply_accepted (model : TextModel) (id : TextId) (content : TextContent)
    (transaction : Transaction) (origin : Origin) (revision : Nat)
    (live : model.texts[id.index]? = some (some content))
    (accepted : (model.apply id transaction origin).1 = .ok revision) :
    ∃ text runs,
      model.apply id transaction origin =
        (.ok (content.revision + 1),
          model.changed id content text runs origin none
            (transaction.before.map normal, transaction.after.map normal)) := by
  unfold TextModel.apply at accepted ⊢
  simp only [TextModel.lookup, live] at accepted ⊢
  split at accepted
  · simp at accepted
  · rename_i selections
    split at accepted
    · simp at accepted
    · rename_i text made
      split at accepted
      · rename_i fits
        simp only [selections, fits, ↓reduceIte]
        exact ⟨text, _, rfl⟩
      · simp at accepted

/-- An accepted transaction and then the inverse of the revision it produced
leave the text holding what it held, two revisions on, and the inverse
hands back the selection the transaction carried as the one before it. -/
theorem TextModel.apply_applyInverse (model : TextModel) (id : TextId) (content : TextContent)
    (transaction : Transaction) (origin undoer : Origin) (revision : Nat)
    (live : model.texts[id.index]? = some (some content))
    (inStep : model.InStep id content.revision)
    (accepted : (model.apply id transaction origin).1 = .ok revision) :
    ∃ after,
      (model.apply id transaction origin).2.applyInverse id (content.revision + 1)
            (content.revision + 1) undoer =
          (.ok ⟨content.revision + 2, transaction.before.map normal⟩, after) ∧
        after.texts[id.index]? =
          some (some { contents := content.contents, revision := content.revision + 2 }) := by
  obtain ⟨text, runs, applied⟩ :=
    TextModel.apply_accepted model id content transaction origin revision live accepted
  obtain ⟨⟨log, logAt, logSize⟩, ⟨history, historyAt, historySize, carriedSize⟩⟩ := inStep.parts
  have inTexts : id.index < model.texts.size := by
    have found := live
    simp only [Array.getElem?_eq_some_iff] at found
    exact found.1
  have inLogs : id.index < model.logs.size := by
    have found := logAt
    simp only [Array.getElem?_eq_some_iff] at found
    exact found.1
  have inHistories : id.index < model.histories.size := by
    have found := historyAt
    simp only [Array.getElem?_eq_some_iff] at found
    exact found.1
  have logIs : model.logs[id.index] = log := by
    have found := logAt
    simp only [Array.getElem?_eq_some_iff] at found
    exact found.2
  have historyIs : model.histories[id.index] = history := by
    have found := historyAt
    simp only [Array.getElem?_eq_some_iff] at found
    exact found.2
  have kept : (history.dropped.push false)[content.revision + 1]? = some false := by
    rw [← historySize]
    exact Array.getElem?_push_size
  have carried :
    (history.carried.push
          (transaction.before.map normal, transaction.after.map normal))[content.revision + 1]? =
      some (transaction.before.map normal, transaction.after.map normal) := by
    rw [← carriedSize]
    exact Array.getElem?_push_size
  have past :
    (log.past.push (content.contents, log.cells.map (·.id)))[content.revision]? =
      some (content.contents, log.cells.map (·.id)) := by
    rw [← logSize]
    exact Array.getElem?_push_size
  rw [applied]
  simp only [TextModel.applyInverse, TextModel.changed, TextModel.lookup]
  simp [inTexts, inLogs, inHistories, logIs, historyIs, TextHistory.record, TextLog.record,
    TextHistory.touchesDrop, kept, carried, past, Array.getElem_modify_self]

end Editor
