import Editor.Program

/-!
# The text port

The editor's interface to text storage, in the editor's own terms: make a
text, insert into it, delete from it, read it. It is deliberately small. The
point is the pattern every later interface follows:

- the port, here: the requests, the reply to each, and the operations a
  command is written with;
- its pure model, `Editor/Text/Model.lean`, which tests run against and
  theorems are stated about;
- its real binding, `Editor/Text/Real.lean`, the only module of the port that
  imports `Editor.Ffi`;
- its contract, `Editor/Text/Contract.lean`: one list of properties, run
  against the model by `model-test` and against the real binding by
  `contract-test`.

A command is a value of `EditorM`: a program over this port that may be
refused. Config and compiled commands are written at that one type, and the
same value runs against the model and against the real binding.

## The rules of the port

- A text is named by a `TextId`, which is plain data. Only `createText` makes
  one that names a text; any other is refused with `noSuchText`.
- Offsets are byte offsets into the text's UTF-8, as `Nat`.
- An edit is refused with `badRange` unless both of its offsets are character
  boundaries of the text, within it, and the start is not after the stop.
- A refused request changes nothing.
- A refusal is a `throw` in `EditorM`. A command that fails leaves the store
  as it was at the failure: nothing here rolls back the requests it had
  already made.

## Adding to the port

A new operation is a constructor of `TextRequest` with its case in
`TextRequest.Reply`, and an operation here that makes the request. It then
needs a clause in the model (`TextModel.handle`), a clause in the real binding
(`RealTexts.handle`), and a property in the contract (`TextContract.properties`),
which is what pins it for both. Grow the port with requests, not with new
ways to run a program.
-/

namespace Editor

/-- The name of a text held by the text store. It is plain data, so a request
can carry it. -/
structure TextId where
  /-- Which text: the store's index for it. -/
  index : Nat
  deriving DecidableEq, Repr

/-- Why the text store refused a request. -/
inductive TextError where
  /-- The id names no text: no `createText` returned it. -/
  | noSuchText
  /-- An offset is past the end of the text or inside a character, or the
  range ends before it starts. -/
  | badRange
  deriving DecidableEq, Repr

/-- What a command may ask of the text store. -/
inductive TextRequest where
  /-- Make a new text holding `initial`. -/
  | create (initial : String)
  /-- Insert `s` into `text` at the byte offset `offset`. -/
  | insert (text : TextId) (offset : Nat) (s : String)
  /-- Delete the bytes of `text` from `start` up to, not including, `stop`. -/
  | delete (text : TextId) (start stop : Nat)
  /-- Read the whole of `text`. -/
  | read (text : TextId)

/-- The type of the reply to each request: the new text's id for `create`,
and for the others a refusal or the result. -/
def TextRequest.Reply : TextRequest → Type
  | .create _ => TextId
  | .insert .. => Except TextError Unit
  | .delete .. => Except TextError Unit
  | .read _ => Except TextError String

/-- The text port: `TextRequest` and the reply to each request. -/
abbrev textPort : Port :=
  { Request := TextRequest, Reply := TextRequest.Reply }

/-- A command: a program over the editor's port that may be refused with a
`TextError`. It may change editor state, and it cannot block: it holds no
`IO`, and the port has no request that waits. -/
abbrev EditorM :=
  ExceptT TextError (Program textPort)

/-- Makes a new text holding `initial` and returns its id. -/
def createText (initial : String) : EditorM TextId :=
  ExceptT.lift (Program.request (port := textPort) (.create initial))

/-- Inserts `s` into `text` at the byte offset `offset`. Refused with
`badRange` unless `offset` is a character boundary within the text. -/
def TextId.insert (text : TextId) (offset : Nat) (s : String) : EditorM Unit :=
  ExceptT.mk (Program.request (port := textPort) (.insert text offset s))

/-- Deletes the bytes of `text` from `start` up to, not including, `stop`.
Refused with `badRange` unless both are character boundaries within the text
and `start ≤ stop`. -/
def TextId.delete (text : TextId) (start stop : Nat) : EditorM Unit :=
  ExceptT.mk (Program.request (port := textPort) (.delete text start stop))

/-- The whole of `text`. -/
def TextId.read (text : TextId) : EditorM String :=
  ExceptT.mk (Program.request (port := textPort) (.read text))

end Editor
