import Editor.Text

/-!
# The pure model of the text port

The text store as a value: the texts and the snapshots made so far, and a
pure function that answers each request of the port (`Editor/Text.lean`).
Editor logic is tested against it, with no Rust library, and theorems about
commands are stated about `EditorM.runModel`.

A text is a string and a revision. A snapshot is a copy of that pair, so
that a snapshot is unaffected by later edits holds of the model by
construction. Rows and points are found by walking the string's characters,
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
one table a text, in which a marker's id is an index. Every accepted edit
goes through `TextModel.changed`, which moves each marker through the
ranges the edit changed (`TextModel.mapOffset`): the same runs the text is
spliced by, and not the library's walk of its changes. The form a selection
is kept in (`TextModel.normal`) is a sort and one pass over the ranges, on
plain offsets.

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
  deriving Repr

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

/-- The model of the text store: every text and every snapshot made so far.
An id is an index here, and a slot is `none` once its text or its snapshot
has been released, so an id is never used again. -/
structure TextModel where
  /-- The texts, in the order they were made. -/
  texts : Array (Option TextContent) := #[]
  /-- The snapshots, in the order they were taken. -/
  snapshots : Array (Option TextContent) := #[]
  /-- The edit log of each text, in the order the texts were made. It is
  beside the texts and not inside them, so that a snapshot, which is a copy
  of a text's content, carries none. -/
  logs : Array TextLog := #[]
  /-- The markers of each text, in the order the texts were made: a table a
  text, in which a marker's id is an index and a slot is `none` once its
  marker has been given up. It is beside the texts for the reason the logs
  are: a snapshot carries none. -/
  markers : Array (Array (Option Marker)) := #[]
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
    | _ => .error .noSuchText
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

/-- How wide `c` is in a column counted in `unit`: its bytes of UTF-8, or its
UTF-16 code units, which are two for a character outside the Basic
Multilingual Plane. -/
def width (unit : ColumnUnit) (c : Char) : Nat :=
  match unit with
  | .bytes => c.utf8Size
  | .utf16 => if c.val < 0x10000 then 1 else 2

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

namespace TextModel

/-- The model after an edit by `origin` to the text `id`, which held
`content`: it holds `text`, made by changing the ranges `runs`, at the next
revision, its log has recorded the edit, and every marker it holds has
moved. Every accepted edit comes through here. -/
def changed (model : TextModel) (id : TextId) (content : TextContent) (text : String)
    (runs : Array Run) (origin : Origin) : TextModel :=
  { model with
    texts :=
      model.texts.setIfInBounds id.index
        (some { contents := text, revision := content.revision + 1 })
    logs :=
      model.logs.modify id.index (·.record content.contents (content.revision + 1) runs origin)
    markers := model.markers.modify id.index (·.map (·.map (mapMarker runs))) }

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
            model.changed id content text (runsOf transaction.changes).1 origin)
        else (.error .badSelection, model)

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
after it: the marker is held, in its form, under the next id of that text.
A refused marker leaves the model as it was. -/
def mark (model : TextModel) (id : TextId) (marker : Marker) :
    Except TextError MarkerId × TextModel :=
  match model.lookup (.text id) with
  | .error refusal => (.error refusal, model)
  | .ok content =>
    match markerRefusal? content.contents marker with
    | some refusal => (.error refusal, model)
    | none =>
      (.ok ⟨(model.markersOf id).size⟩,
        { model with markers := model.markers.modify id.index (·.push (some (held marker))) })

/-- The model's answer to reading the marker `marker` of the text `id`. -/
def markerOf (model : TextModel) (id : TextId) (marker : MarkerId) : Except TextError Marker :=
  match model.lookup (.text id) with
  | .error refusal => .error refusal
  | .ok _ =>
    match (model.markersOf id)[marker.index]? with
    | some (some found) => .ok found
    | _ => .error .noSuchMarker

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
      match (model.markersOf id)[«at».index]? with
      | some (some _) =>
        match markerRefusal? content.contents marker with
        | some refusal => (.error refusal, model)
        | none =>
          (.ok (),
            { model with
              markers :=
                model.markers.modify id.index (·.setIfInBounds «at».index (some (held marker))) })
      | _ => (.error .noSuchMarker, model)

/-- The model's answer to giving up the marker `marker` of the text `id`,
and the model after it: its slot is emptied and stays, so its id is never
used again. -/
def unmark (model : TextModel) (id : TextId) (marker : MarkerId) :
    Except TextError Unit × TextModel :=
  match model.lookup (.text id) with
  | .error refusal => (.error refusal, model)
  | .ok _ =>
    match (model.markersOf id)[marker.index]? with
    | some (some _) =>
      (.ok (),
        { model with markers := model.markers.modify id.index (·.setIfInBounds marker.index none) })
    | _ => (.error .noSuchMarker, model)

/-- The model's answer to each request, and the model after it. -/
def handle : (request : TextRequest) → TextModel → request.Reply × TextModel
  | .create initial, model =>
    (⟨model.texts.size⟩,
      { model with
        texts := model.texts.push (some { contents := initial })
        logs := model.logs.push (.new initial)
        markers := model.markers.push #[] })
  | .insert id offset s, model => model.edit id offset offset s
  | .delete id start stop, model => model.edit id start stop ""
  | .read id, model =>
    match model.lookup (.text id) with
    | .error refusal => (.error refusal, model)
    | .ok content => (.ok content.contents, model)
  | .snapshot id, model =>
    match model.lookup (.text id) with
    | .error refusal => (.error refusal, model)
    | .ok content =>
      (.ok ⟨model.snapshots.size⟩, { model with snapshots := model.snapshots.push (some content) })
  | .ask source query, model =>
    match model.lookup source with
    | .error refusal => (.error refusal, model)
    | .ok content => (answer content query, model)
  | .release source, model =>
    match model.lookup source with
    | .error refusal => (.error refusal, model)
    | .ok _ => (.ok (), model.released source)
  | .apply id transaction origin, model => model.apply id transaction origin
  | .log id query, model =>
    match model.lookup (.text id) with
    | .error refusal => (.error refusal, model)
    | .ok content => (answerLog (model.logs[id.index]?.getD {}) content query, model)
  | .forget id revision, model => model.forget id revision
  | .mark id marker, model => model.mark id marker
  | .marker id marker, model => (model.markerOf id marker, model)
  | .place id «at» marker, model => model.place id «at» marker
  | .unmark id marker, model => model.unmark id marker

end TextModel

/-- Runs a command against the model `model`: its result, or the refusal it
failed with, and the model after its last request. -/
def EditorM.runModel {α : Type} (command : EditorM α) (model : TextModel) :
    Except TextError α × TextModel :=
  Program.run (port := textPort) TextModel.handle command.run model

/-! What `runModel` does to each way of building a command: `pure`, a bind,
and each operation of the port. They are `simp` lemmas, so a theorem about a
command is proved by unfolding the command and calling `simp`, which is left
with facts about the model alone. A new operation gets its lemma here. -/

namespace EditorM

variable {α β : Type}

@[simp]
theorem runModel_pure (value : α) (model : TextModel) :
    (pure value : EditorM α).runModel model = (.ok value, model) :=
  rfl

@[simp]
theorem runModel_bind (command : EditorM α) (after : α → EditorM β) (model : TextModel) :
    (command >>= after).runModel model =
      match command.runModel model with
      | (.ok value, model) => (after value).runModel model
      | (.error refusal, model) => (.error refusal, model) := by
  -- A bind in `EditorM` is a bind of programs, whose second part goes on to
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
          markers := model.markers.push #[] }) :=
  rfl

@[simp]
theorem runModel_read (id : TextId) (model : TextModel) :
    id.read.runModel model = TextModel.handle (.read id) model :=
  rfl

@[simp]
theorem runModel_insert (id : TextId) (offset : Nat) (s : String) (model : TextModel) :
    (id.insert offset s).runModel model = model.edit id offset offset s :=
  rfl

@[simp]
theorem runModel_delete (id : TextId) (start stop : Nat) (model : TextModel) :
    (id.delete start stop).runModel model = model.edit id start stop "" :=
  rfl

@[simp]
theorem runModel_snapshot (id : TextId) (model : TextModel) :
    id.snapshot.runModel model = TextModel.handle (.snapshot id) model :=
  rfl

@[simp]
theorem runModel_ask (source : TextSource) (query : TextQuery) (model : TextModel) :
    (source.ask query).runModel model = TextModel.handle (.ask source query) model :=
  rfl

@[simp]
theorem runModel_release (source : TextSource) (model : TextModel) :
    source.release.runModel model = TextModel.handle (.release source) model :=
  rfl

@[simp]
theorem runModel_apply (id : TextId) (transaction : Transaction) (origin : Origin)
    (model : TextModel) :
    (id.apply transaction origin).runModel model = model.apply id transaction origin :=
  rfl

@[simp]
theorem runModel_askLog (id : TextId) (query : LogQuery) (model : TextModel) :
    (id.askLog query).runModel model = TextModel.handle (.log id query) model :=
  rfl

@[simp]
theorem runModel_forget (id : TextId) (revision : Nat) (model : TextModel) :
    (id.forget revision).runModel model = model.forget id revision :=
  rfl

@[simp]
theorem runModel_mark (id : TextId) (marker : Marker) (model : TextModel) :
    (id.mark marker).runModel model = model.mark id marker :=
  rfl

@[simp]
theorem runModel_marker (id : TextId) (marker : MarkerId) (model : TextModel) :
    (id.marker marker).runModel model = (model.markerOf id marker, model) :=
  rfl

@[simp]
theorem runModel_place (id : TextId) («at» : MarkerId) (marker : Marker) (model : TextModel) :
    (id.place «at» marker).runModel model = model.place id «at» marker :=
  rfl

@[simp]
theorem runModel_unmark (id : TextId) (marker : MarkerId) (model : TextModel) :
    (id.unmark marker).runModel model = model.unmark id marker :=
  rfl

end EditorM

/-- A splice at the end of a text is an append: the length of a text in bytes
is a character boundary of it, and nothing follows it. -/
theorem TextModel.splice_end (text s : String) :
    TextModel.splice text text.utf8ByteSize text.utf8ByteSize s = some (text ++ s) := by
  have valid : (String.Pos.Raw.mk text.utf8ByteSize).IsValid text :=
    String.Pos.Raw.isValid_rawEndPos
  have atEnd : text.pos ⟨text.utf8ByteSize⟩ valid = text.endPos := String.Pos.ext rfl
  simp [TextModel.splice, valid, atEnd, String.sliceTo_endPos]

end Editor
