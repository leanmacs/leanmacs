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

The contract (`Editor/Text/Contract.lean`) is what says the model and the real
binding agree. A clause added to `TextModel.handle` or to `TextModel.answer`
needs its property there.
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

/-- The model of the text store: every text and every snapshot made so far.
An id is an index here, and a slot is `none` once its text or its snapshot
has been released, so an id is never used again. -/
structure TextModel where
  /-- The texts, in the order they were made. -/
  texts : Array (Option TextContent) := #[]
  /-- The snapshots, in the order they were taken. -/
  snapshots : Array (Option TextContent) := #[]
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

/-- The model's answer to an edit of the text `id`, replacing its bytes from
`start` up to `stop` by `s`, and the model after it. An accepted edit adds
one to the text's revision. A refused edit leaves the model as it was. -/
def edit (model : TextModel) (id : TextId) (start stop : Nat) (s : String) :
    Except TextError Unit × TextModel :=
  match model.lookup (.text id) with
  | .error refusal => (.error refusal, model)
  | .ok content =>
    match splice content.contents start stop s with
    | none => (.error .badRange, model)
    | some text =>
      (.ok (),
        { model with
          texts :=
            model.texts.setIfInBounds id.index
              (some { contents := text, revision := content.revision + 1 }) })

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

/-- Whether every end of every range of `selection`, if there is one, is a
position of `text`. -/
def selectionFits (text : String) : Option Selection → Bool
  | none => true
  | some selection =>
    selection.ranges.all fun range =>
      decide ((String.Pos.Raw.mk range.anchor).IsValid text) &&
        decide ((String.Pos.Raw.mk range.head).IsValid text)

/-- The model's answer to applying `transaction` to the text `id`, and the
model after it. An accepted transaction adds one to the text's revision,
however many changes it has. A refused one leaves the model as it was. -/
def apply (model : TextModel) (id : TextId) (transaction : Transaction) :
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
            { model with
              texts :=
                model.texts.setIfInBounds id.index
                  (some { contents := text, revision := content.revision + 1 }) })
        else (.error .badSelection, model)

/-- The model after `source`, which it holds, is released: its slot is
emptied and stays, so later ids are what they would have been. -/
def released (model : TextModel) : TextSource → TextModel
  | .text id => { model with texts := model.texts.setIfInBounds id.index none }
  | .snapshot id => { model with snapshots := model.snapshots.setIfInBounds id.index none }

/-- The model's answer to each request, and the model after it. -/
def handle : (request : TextRequest) → TextModel → request.Reply × TextModel
  | .create initial, model =>
    (⟨model.texts.size⟩, { model with texts := model.texts.push (some { contents := initial }) })
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
  -- The model keeps no log yet, so who made the edit changes nothing in it.
  | .apply id transaction _, model => model.apply id transaction

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
        { model with texts := model.texts.push (some { contents := initial }) }) :=
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
    (id.apply transaction origin).runModel model = model.apply id transaction :=
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
