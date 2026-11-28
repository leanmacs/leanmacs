import Editor.Api
import Editor.Columns
import Editor.Command
import Editor.Face
import Editor.Language
import Editor.Loop
import Editor.Loop.Driver
import Editor.Markdown.View
import Editor.State
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models
import ModelTest.Check
import ModelTest.Editor.Markdown.Doc
import ModelTest.Support.Markdown

/-!
# Model tests: `Editor/Markdown/View.lean`

The model tests of `Editor/Markdown/View.lean`: `markdownViewChecks`,
`markdownTableViewChecks` and `markdownAppendChecks`. Each runs commands
that render into a read-only buffer on the stepped loop driver over the
editor's models, the syntax tree model answering the fixtures' canned layers
(`ModelTest.Support.Markdown.canned`) and the loop's language table the
shipped one. The root module `ModelTest` runs them; its module doc says what
each shows.
-/

namespace ModelTest

open Editor
open Editor.Markdown
open Editor.Test

/-- What a rendered view's call answered, as words: `ok`, or its refusal. -/
def refusalWords : Except Markdown.Refusal Unit → String
  | .ok () => "ok"
  | .error (.buffer (.noSuchBuffer _)) => "buffer noSuchBuffer"
  | .error (.buffer _) => "buffer"
  | .error .notRendered => "notRendered"
  | .error (.parse .unknownGrammar) => "parse unknownGrammar"
  | .error (.parse _) => "parse"

/-- The shipped language table, as the view reads it. -/
def shippedTable : List (String × List (String × Option FaceName)) :=
  Language.shipped.toList.map fun language =>
    (language.syntaxTree.grammar, language.syntaxTree.captures)

/-- The options the view checks render with, the faces the shipped table's. -/
def viewOptions : Options :=
  { root := some markdownRoot, faces := facesOf shippedTable }

/-- The buffer called `name`, made read-only and shown in `call`'s window,
made now. -/
def generated (call : Call) (name : String) : EditorM (Option BufferId) := do
  let .ok buffer ← createBuffer name | return none
  discard <| buffer.setReadOnly true
  discard <| call.target.window.id.show buffer
  return some buffer

/-- `result` kept under the value `result` of the buffer `buffer`. -/
def keepResult (buffer : BufferId) (result : Except Markdown.Refusal Unit) : EditorM Unit :=
  discard <| buffer.setValue "result" (.str (refusalWords result))

/-- The commands of the rendered-view checks:

- `render`: `view.md` into a new buffer `doc`, with the root;
- `render-unknown`: a source the model has no answer for into `doc`;
- `render-absent`: into a buffer there is none of, kept on `doc` as
  `absent`;
- `append-plain`: an append to a new buffer `plain` never rendered;
- `table`: `table.md` into a new buffer `table`;
- `stream`: `stream-head.md` into a new buffer `stream`, with the root, its
  text's revision then kept as `revision`, and its first heading folded;
- `append`: the stream's next chunk, the chunk's index the value `chunk`
  of `stream`, appended to `stream`; the first edit's start since
  `revision` kept as `edited`. -/
def markdownViewCommands : List (String × Dispatched) :=
  [("render", fun call => do
      let some doc ← generated call "doc" | return none
      keepResult doc
          (← doc.renderMarkdown Support.Markdown.view.source { root := some markdownRoot })
      return none),
    ("render-unknown", fun _ => do
      let some doc ← findBuffer "doc" | return none
      keepResult doc (← doc.renderMarkdown "Nothing answers this.\n")
      return none),
    ("render-absent", fun _ => do
      let some doc ← findBuffer "doc" | return none
      let result ← (⟨99⟩ : BufferId).renderMarkdown "x"
      discard <| doc.setValue "absent" (.str (refusalWords result))
      return none),
    ("append-plain", fun call => do
      let some plain ← generated call "plain" | return none
      keepResult plain (← plain.appendMarkdown "more")
      return none),
    ("table", fun call => do
      let some table ← generated call "table" | return none
      keepResult table (← table.renderMarkdown Support.Markdown.table.source)
      return none),
    ("stream", fun call => do
      let some stream ← generated call "stream" | return none
      keepResult stream
          (← stream.renderMarkdown Support.Markdown.streamHead.source { root := some markdownRoot })
      let .ok text ← stream.text | return none
      discard <| stream.setValue "revision" (.nat (← text.revision))
      discard <| stream.setValue "chunk" (.nat 1)
      discard <| stream.setFolded "heading 1" true
      return none),
    ("append", fun _ => do
      let some stream ← findBuffer "stream" | return none
      let some (.nat chunk) ← stream.value? "chunk" | return none
      let some more := Support.Markdown.streamChunks[chunk]? | return none
      keepResult stream (← stream.appendMarkdown more)
      discard <| stream.setValue "chunk" (.nat (chunk + 1))
      if chunk == 1 then
        let .ok text ← stream.text | return none
        let some (.nat revision) ← stream.value? "revision" | return none
        let patch ← text.changesSince revision
        discard <|
            stream.setValue "edited" (.nat ((patch.edits.map (·.old.start)).foldl min 1000000))
      return none)]

/-- A driver whose window shows an empty buffer, with each of
`markdownViewCommands` on a key (`C-c` and a letter), the syntax tree model
answering the fixtures' canned layers and the loop's language table the
shipped one; `none` if making the state was refused. -/
def markdownDriver : Option TestDriver :=
  let keys :=
    {
      dispatchKeys
        [("C-c r", invoke "render"), ("C-c u", invoke "render-unknown"),
          ("C-c x", invoke "render-absent"), ("C-c p", invoke "append-plain"),
          ("C-c t", invoke "table"), ("C-c s", invoke "stream"), ("C-c a", invoke "append")]
        markdownViewCommands with
      registered := { languages := Language.shipped.toList } }
  let model := { editorModel with syntaxTree := { once := Support.Markdown.canned } }
  (Loop.Driver.over keys (fun _ => none) (EditorState.initial ⟨640, 480⟩) model).toOption

/-- `driver` fed the key strings `presses`. -/
def markdownFed (driver : TestDriver) (presses_ : String) : TestDriver :=
  (fedTo driver (presses presses_)).1

/-- The buffer called `name` in `driver`'s state. -/
def markdownBuffer (driver : TestDriver) (name : String) : Option Buffer := do
  let id ← driver.loop.state.findBuffer name
  driver.loop.state.buffer? id

/-- What the buffer `buffer`'s text holds in `driver`'s text model. -/
def markdownText (driver : TestDriver) (buffer : Buffer) : Option String :=
  (driver.model.texts.texts[buffer.text.index]?).join.map (·.contents)

/-- The value `name` of the buffer called `buffer` in `driver`'s state. -/
def markdownValue (driver : TestDriver) (buffer name : String) : Option Value := do
  driver.loop.state.value? (← driver.loop.state.findBuffer buffer) name

/-- The view 0 of the last scene `driver` published. -/
def markdownView (driver : TestDriver) : Option View :=
  driver.model.display.scenes.back?.bind fun scene => scene.views.find? (·.id == ⟨0⟩)

/-- Whether the buffer called `name` holds `description`'s text, spans,
links and folds, and `doc` as its document. -/
def holdsDescription (driver : TestDriver) (name : String) (doc : Doc) : Bool :=
  let description := doc.description
  match markdownBuffer driver name with
  | none => false
  | some buffer =>
    markdownText driver buffer == some description.text && buffer.spans == description.spans &&
      buffer.links == description.links &&
      buffer.folds == description.folds &&
      buffer.markdown == some doc

/-- The checks of the one core call that renders Markdown into a generated
buffer (**criterion 1**), over `view.md`, which has a heading, emphasis, a
link, a `path:line` and a fence. -/
def markdownViewChecks : List Check :=
  let expected :=
    Markdown.render viewOptions Support.Markdown.view.source Support.Markdown.view.layers
  let rendered := markdownDriver.map (markdownFed · "C-c r")
  [{  name :=
        "one renderMarkdown of view.md sets the buffer's text, spans, links and folds to its description's, and keeps the document"
      run :=
        pure <|
          match rendered with
          | none => false
          | some driver =>
            markdownValue driver "doc" "result" == some (.str "ok") &&
              holdsDescription driver "doc" expected &&
              expected.description.links.size == 2 &&
              (expected.description.folds.map (·.key)) == #["heading 1", "code 1"] &&
              expected.description.spans.any (·.face == ⟨"syntax.keyword"⟩) },
    { name :=
        "the next scene's view of the buffer carries its spans and text.link over each link, and no fold, since every range is unfolded"
      run :=
        pure <|
          match rendered.bind markdownView with
          | none => false
          | some view =>
            let description := expected.description
            description.links.all
                (fun link =>
                  view.decorations.contains
                    { start := link.start, stop := link.stop, face := Link.face }) &&
              description.spans.all view.decorations.contains &&
              view.folds.isEmpty },
    { name :=
        "the text.heading.1 span over the rendered # Title resolves, through the built-in theme, to a face larger than the body's"
      run :=
        pure <|
          match rendered.bind (markdownBuffer · "doc") with
          | none => false
          | some buffer =>
            let title := over expected.description.text "Title"
            let body := ((Theme.builtin.merged ⟨"default"⟩).size.map (·.sixtyFourths)).getD 0
            buffer.spans.any fun span =>
              span.face == ⟨"text.heading.1"⟩ && span.start == title.1 && span.stop == title.2 &&
                ((Theme.builtin.merged span.face).size.map (·.sixtyFourths)).getD 0 > body },
    { name :=
        "a source the syntax tree has no answer for is refused as parse unknownGrammar, and the buffer is left as it was"
      run :=
        pure <|
          match rendered.map (markdownFed · "C-c u") with
          | none => false
          | some driver =>
            markdownValue driver "doc" "result" == some (.str "parse unknownGrammar") &&
              holdsDescription driver "doc" expected },
    { name := "an append to a buffer never rendered is refused as notRendered, and leaves it empty"
      run :=
        pure <|
          match markdownDriver.map (markdownFed · "C-c p") with
          | none => false
          | some driver =>
            markdownValue driver "plain" "result" == some (.str "notRendered") &&
              ((markdownBuffer driver "plain").bind (markdownText driver ·)) == some "" },
    { name := "a render into a buffer there is none of is refused as buffer noSuchBuffer"
      run :=
        pure <|
          match rendered.map (markdownFed · "C-c x") with
          | none => false
          | some driver =>
            markdownValue driver "doc" "absent" == some (.str "buffer noSuchBuffer") }]

/-- The checks that a rendered table's columns are aligned by align-to stops
measured through the display (the layout half of **criterion 4**). -/
def markdownTableViewChecks : List Check :=
  [{  name :=
        "a rendered table.md puts one stop at each later cell's first byte, at the x its columns' measured widths and a gap of 16 give, and its view's stops are those"
      run :=
        pure <|
          match markdownDriver.map (markdownFed · "C-c t") with
          | none => false
          | some driver =>
            -- The editor model's display lays out in cells of 1: the widest
            -- first cell, `Name`, is 4 wide, so the second column is at 20.
            let expected : Array AlignStop :=
              #[{ offset := 5, x := 20 }, { offset := 13, x := 20 }, { offset := 18, x := 20 }]
            let widths : Array (Array Nat) := #[#[4, 5], #[1, 1], #[2, 3], #[3]]
            Columns.starts widths 16 == #[0, 20] &&
              (markdownBuffer driver "table").map (·.stops) == some expected &&
              (markdownView driver).map (·.stops) == some expected }]

/-- The checks that an append through the core call re-renders only the
changed tail and rewrites only the bytes from where the text first changes
(**criterion 7** through the call). -/
def markdownAppendChecks : List Check :=
  let (docs, _) := streamed
  let whole :=
    Markdown.render { viewOptions with faces := facesOf shippedTable }
      Support.Markdown.stream.source Support.Markdown.stream.layers
  let once := markdownDriver.map (markdownFed · "C-c s C-c a")
  let all := markdownDriver.map (markdownFed · "C-c s C-c a C-c a C-c a")
  [{  name :=
        "after renderMarkdown of stream-head.md and appendMarkdown of the next chunk, the document's renders rose by exactly the two blocks of its tail"
      run :=
        pure <|
          match once.bind (markdownBuffer · "stream") with
          | none => false
          | some buffer =>
            buffer.markdown.map (·.rendered) == some 4 &&
              (docs.map (·.rendered)).extract 0 2 == #[2, 4] },
    { name := "the append's edit changes no byte of the text before the first changed offset"
      run :=
        pure <|
          match once with
          | none => false
          | some driver =>
            let firstChanged := Doc.firstChanged docs[0]! docs[1]!
            firstChanged > 0 &&
              match markdownValue driver "stream" "edited" with
              | some (.nat edited) => edited ≥ firstChanged
              | _ => false },
    { name :=
        "after every chunk is appended the buffer's text, spans and links are the whole render's, its relative link in the last chunk resolved against the root the document was first rendered with"
      run :=
        pure <|
          match all with
          | none => false
          | some driver =>
            match markdownBuffer driver "stream" with
            | none => false
            | some buffer =>
              let description := whole.description
              markdownText driver buffer == some description.text &&
                buffer.spans == description.spans &&
                buffer.links == description.links &&
                buffer.links.any (·.target == .location (markdownRoot / "src/s.rs") 1 0) &&
                buffer.markdown.map (·.rendered) == some 8 },
    { name := "a fold toggled in the kept prefix before the appends is still folded after them"
      run :=
        pure <|
          match all.bind (markdownBuffer · "stream") with
          | none => false
          | some buffer =>
            (buffer.folds.find? (·.key == "heading 1")).map (·.folded) == some true &&
              buffer.folds.any fun fold => fold.key == "code 1" && !fold.folded }]

end ModelTest
