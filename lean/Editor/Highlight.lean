import Editor.Command
import Editor.Face.Vocabulary
import Editor.Mode

/-!
# Highlighting a buffer's text from its major mode

What a major mode with a syntax tree (`Mode.SyntaxTree`, `Editor/Mode.lean`)
asks of the library's syntax service when it becomes a buffer's major mode,
and the rule that says which face each of a highlights query's captures is
drawn in. Parsing, running the query over what is shown and drawing it are
the library's: highlights reach the display there and never pass through
Lean (`crates/editor-ffi/src/syntax.rs`, "Highlights"). What crosses is a
query and one face, or none, for each of its captures.

## The capture-to-face rule (`faceOf`)

The shipped default (`defaultFaces`) maps each capture name `c` of the face
vocabulary's syntax captures (`Face.syntaxCaptures`,
`Editor/Face/Vocabulary.lean`) to the face `syntax.c`. It is computed from
that list, not copied, so it cannot drift from the vocabulary. A mode's
config (`Mode.SyntaxTree.captures`) is a mapping over it: the mapping a
capture is looked up in is config's entries, then the default's.

1. An entry for the capture's full name gives its face, and an entry of
   `none` draws nothing and stops the fallback.
2. Otherwise, a dotted name (`keyword.control`) takes the entry of its first
   component (`keyword`).
3. Otherwise the capture draws nothing (Rust's shipped `@escape`, `@label`).

So config can override any mapping, a first component's too, which then
reaches every dotted capture under it that has no entry of its own. The
fallback is to the first component only: `a.b.c` does not fall back to
`a.b` (an open question, `docs/design/rust-library.md`).

`faces` is `faceOf` over a query's capture names, in order: the table that
crosses (`SyntaxTree.highlight`).

## Entering a major mode with a syntax tree (`enter`)

The loop runs it, inside the command that set the mode, before the new
lineage's on-enter actions (`Editor/Command/Dispatch.lean`). With a snapshot
of the buffer's text (`TextId.withSnapshot`):

1. `attach` the snapshot with the grammar;
2. the query's source: the mode's own, or the grammar's shipped highlights
   (`shippedQuery`);
3. `compile` it, and read its `captureNames`;
4. `highlight` the snapshot with the query and `faces` of the mode's
   mapping;
5. `release` the query: the library's highlighter keeps it.

A refusal from the syntax tree port stops the steps and is said in the echo
area, ``highlights: `<mode>`: <refusal>``. The mode is still set and the
command is not refused: a query of config's that does not compile keeps no
buffer out of its mode.

`leave` detaches the text, when a major mode with no syntax tree replaces
one with a syntax tree. A mode that says nothing of a syntax tree, set over
one that said nothing either, asks the port nothing.

Pinned by `ModelTest.highlightFaceChecks` (the rule, pure) and
`ModelTest.highlightEnterChecks` (on the editor's models, through the
loop's dispatch).
-/

namespace Editor.Highlight

/-- The shipped default: each capture name of the face vocabulary's syntax
captures, and its face, `syntax.` and the name. -/
def defaultFaces : List (String × FaceName) :=
  Face.syntaxCaptures.toList.map fun (capture, _) => (capture, ⟨s!"syntax.{capture}"⟩)

/-- The face the capture `capture` is drawn in, by config's mapping `config`
over the shipped default (the rule of the module docs); `none` when it draws
nothing. -/
def faceOf (config : List (String × Option FaceName)) (capture : String) : Option FaceName :=
  let mapping := config ++ defaultFaces.map fun (name, face) => (name, some face)
  let entry (name : String) : Option (Option FaceName) := (mapping.find? (·.1 == name)).map (·.2)
  match entry capture with
  | some face => face
  | none =>
    match capture.splitOn "." with
    | first :: _ :: _ => (entry first).join
    | _ => none

/-- The face of each of a query's capture names `names`, in order, by
config's mapping `config` (`faceOf`): the table `SyntaxTree.highlight`
takes. -/
def faces (config : List (String × Option FaceName)) (names : Array String) :
    Array (Option FaceName) :=
  names.map (faceOf config)

/-- Puts `text` in the echo area: the state request the API's `message`
makes (`Editor/Api.lean`), asked here, below the API, since the loop's
dispatch runs this module's steps. -/
private def say (text : String) : EditorM Unit :=
  ExceptT.lift (Program.request (port := editorPort) (.state (.message text)))

/-- What setting a major mode with `syntaxTree` asks of the syntax tree port
for its text `text` (the steps of the module docs): attached with the
grammar, and highlighted with the query in the faces `faces` gives; or,
refused, said in the echo area under the mode's name `mode`. Never refused
itself. -/
def enter (mode : String) (text : TextId) (syntaxTree : Mode.SyntaxTree) : EditorM Unit :=
  text.withSnapshot fun snapshot => do
    let steps : SyntaxTreeM Unit := do
      SyntaxTree.attach snapshot syntaxTree.grammar
      let source ←
        match syntaxTree.highlights with
        | some source =>
          pure source
        | none =>
          SyntaxTree.shippedQuery syntaxTree.grammar .highlights
      let query ← SyntaxTree.compile syntaxTree.grammar source
      try
        let names ← SyntaxTree.captureNames query
        SyntaxTree.highlight snapshot query (faces syntaxTree.captures names)
      catch refusal =>
        SyntaxTree.release query
        throw refusal
      SyntaxTree.release query
    match ← SyntaxTree.lift steps with
    | .ok () =>
      pure ()
    | .error refusal =>
      say s!"highlights: `{mode}`: {refusal.describe}"

/-- What setting a major mode with no syntax tree over one with a syntax
tree asks of the syntax tree port for its text `text`: it is detached, which
drops its highlights. -/
def leave (text : TextId) : EditorM Unit :=
  text.withSnapshot fun snapshot => discard (SyntaxTree.lift (SyntaxTree.detach snapshot))

end Editor.Highlight
