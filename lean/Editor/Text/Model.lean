import Editor.Text

/-!
# The pure model of the text port

The text store as a value: the texts made so far, and a pure function that
answers each request of the port (`Editor/Text.lean`). Editor logic is tested
against it, with no Rust library, and theorems about commands are stated
about `EditorM.runModel`.

The contract (`Editor/Text/Contract.lean`) is what says the model and the real
binding agree. A clause added to `TextModel.handle` needs its property there.
-/

namespace Editor

/-- The model of the text store: every text made so far. A text's id is its
index here. -/
structure TextModel where
  /-- The texts, in the order they were made. -/
  texts : Array String := #[]
  deriving Repr

namespace TextModel

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

/-- The model's answer to an edit of the text `id`, replacing its bytes from
`start` up to `stop` by `s`, and the model after it. A refused edit leaves the
model as it was. -/
def edit (model : TextModel) (id : TextId) (start stop : Nat) (s : String) :
    Except TextError Unit × TextModel :=
  match model.texts[id.index]? with
  | none => (.error .noSuchText, model)
  | some text =>
    match splice text start stop s with
    | none => (.error .badRange, model)
    | some text => (.ok (), { model with texts := model.texts.setIfInBounds id.index text })

/-- The model's answer to each request, and the model after it. -/
def handle : (request : TextRequest) → TextModel → request.Reply × TextModel
  | .create initial, model => (⟨model.texts.size⟩, { model with texts := model.texts.push initial })
  | .insert id offset s, model => model.edit id offset offset s
  | .delete id start stop, model => model.edit id start stop ""
  | .read id, model =>
    match model.texts[id.index]? with
    | none => (.error .noSuchText, model)
    | some text => (.ok text, model)

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
      (.ok ⟨model.texts.size⟩, { model with texts := model.texts.push initial }) :=
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
