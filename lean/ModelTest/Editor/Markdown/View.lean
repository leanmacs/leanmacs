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
`markdownTableViewChecks`, `markdownAppendChecks` and
`markdownIndentViewChecks`. Each runs commands
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

/-- The shipped language table's trees, as the view reads them. -/
def shippedTable : List Mode.SyntaxTree :=
  Language.shipped.toList.map (·.syntaxTree)

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
- `whole`: `stream.md`, whole, into a new buffer `whole`, with the root;
- `stream`: `stream-head.md` into a new buffer `stream`, with the root, its
  text's revision then kept as `revision`, and its first heading folded;
- `append`: the stream's next chunk, the chunk's index the value `chunk`
  of `stream`, appended to `stream`; the first edit's start since
  `revision` kept as `edited`;
- `append-unknown`: a chunk whose tail the model has no answer for,
  appended to `stream`;
- `append-absent`: an append to a buffer there is none of, kept on
  `stream` as `absent`;
- `reply`:the empty document into a new buffer `reply`, with the root;
- `reply-append`: the reply's next chunk, the chunk's index the value
  `chunk` of `reply`, appended to `reply`;
- `reply-whole`: `reply.md`, whole, into a new buffer `reply-whole`, with
  the root;
- `lists`: `lists.md` into a new buffer `lists`;
- `rich-over`: `doc` written from a rich-text description of its own
  (`BufferId.setRichText`), then appended to, the append's answer kept as
  `over`. -/
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
    ("whole", fun call => do
      let some whole ← generated call "whole" | return none
      keepResult whole
          (← whole.renderMarkdown Support.Markdown.stream.source { root := some markdownRoot })
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
      return none),
    ("append-unknown", fun _ => do
      let some stream ← findBuffer "stream" | return none
      keepResult stream (← stream.appendMarkdown "Nothing answers this tail.\n")
      return none),
    ("append-absent", fun _ => do
      let some stream ← findBuffer "stream" | return none
      let result ← (⟨99⟩ : BufferId).appendMarkdown "x"
      discard <| stream.setValue "absent" (.str (refusalWords result))
      return none),
    ("reply", fun call => do
      let some reply ← generated call "reply" | return none
      keepResult reply
          (← reply.renderMarkdown Support.Markdown.empty.source { root := some markdownRoot })
      discard <| reply.setValue "chunk" (.nat 0)
      return none),
    ("reply-append", fun _ => do
      let some reply ← findBuffer "reply" | return none
      let some (.nat chunk) ← reply.value? "chunk" | return none
      let some more := Support.Markdown.replyChunks[chunk]? | return none
      keepResult reply (← reply.appendMarkdown more)
      discard <| reply.setValue "chunk" (.nat (chunk + 1))
      return none),
    ("reply-whole", fun call => do
      let some whole ← generated call "reply-whole" | return none
      keepResult whole
          (← whole.renderMarkdown Support.Markdown.reply.source { root := some markdownRoot })
      return none),
    ("lists", fun call => do
      let some lists ← generated call "lists" | return none
      keepResult lists (← lists.renderMarkdown Support.Markdown.lists.source)
      return none),
    ("rich-over", fun _ => do
      let some doc ← findBuffer "doc" | return none
      discard <| doc.setRichText { text := "plain\n" }
      let result ← doc.appendMarkdown "more"
      discard <| doc.setValue "over" (.str (refusalWords result))
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
          ("C-c t", invoke "table"), ("C-c w", invoke "whole"), ("C-c s", invoke "stream"),
          ("C-c a", invoke "append"), ("C-c e", invoke "reply"), ("C-c n", invoke "reply-append"),
          ("C-c y", invoke "reply-whole"), ("C-c k", invoke "append-unknown"),
          ("C-c b", invoke "append-absent"), ("C-c l", invoke "lists"),
          ("C-c o", invoke "rich-over")]
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

/-- Whether the buffer called `name` holds the rich-text description of the
document it keeps (`Doc.richText`) in all six parts, its stops and indents
among them, the document's measured stops being those it keeps. -/
def holdsRichText (driver : TestDriver) (name : String) : Bool :=
  match markdownBuffer driver name with
  | none => false
  | some buffer =>
    match buffer.markdown with
    | none => false
    | some doc =>
      let rich := doc.richText
      markdownText driver buffer == some rich.text && buffer.spans == rich.spans &&
        buffer.stops == rich.stops &&
        buffer.links == rich.links &&
        buffer.folds == rich.folds &&
        buffer.indents == rich.indents

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
            markdownValue driver "doc" "absent" == some (.str "buffer noSuchBuffer") },
    { name :=
        "an append whose tail the syntax tree has no answer for is refused as parse unknownGrammar, and the buffer's text, spans, stops, links, folds and document are left as they were"
      run :=
        pure <|
          let before := markdownDriver.map (markdownFed · "C-c s")
          let after := markdownDriver.map (markdownFed · "C-c s C-c k")
          let parts (driver : TestDriver) :=
            (markdownBuffer driver "stream").map fun buffer =>
              (markdownText driver buffer, buffer.spans, buffer.stops, buffer.links, buffer.folds,
                buffer.markdown)
          match before, after with
          | some before, some after =>
            markdownValue after "stream" "result" == some (.str "parse unknownGrammar") &&
              (parts before).isSome &&
              parts after == parts before &&
              ((markdownBuffer after "stream").bind (·.markdown)).map (·.source) ==
                some Support.Markdown.streamHead.source
          | _, _ => false },
    { name := "an append to a buffer there is none of is refused as buffer noSuchBuffer"
      run :=
        pure <|
          match markdownDriver.map (markdownFed · "C-c s C-c b") with
          | none => false
          | some driver =>
            markdownValue driver "stream" "absent" == some (.str "buffer noSuchBuffer") },
    { name :=
        "after renderMarkdown of view.md and of table.md each buffer holds its measured document's rich-text description in all six parts, table.md's stops among them"
      run :=
        pure <|
          match markdownDriver.map (markdownFed · "C-c r C-c t") with
          | none => false
          | some driver =>
            holdsRichText driver "doc" && holdsRichText driver "table" &&
              ((markdownBuffer driver "table").map (!·.stops.isEmpty)) == some true },
    { name :=
        "a setRichText over a rendered buffer drops its document, so a following appendMarkdown is refused notRendered"
      run :=
        pure <|
          match rendered.map (markdownFed · "C-c o") with
          | none => false
          | some driver =>
            markdownValue driver "doc" "over" == some (.str "notRendered") &&
              ((markdownBuffer driver "doc").bind (markdownText driver ·)) == some "plain\n" &&
              ((markdownBuffer driver "doc").bind (·.markdown)).isNone }]

/-- `stream.md` rendered whole, its text. -/
def streamText : String :=
  (Markdown.render viewOptions Support.Markdown.stream.source
      Support.Markdown.stream.layers).description.text

/-- The stops of `stream.md`'s table, its fourth block, in the whole text:
one at each later cell's first byte, at the x a widest first cell of 1 in
the editor model's cells of 1 and a gap of 16 give. -/
def streamStops : Array AlignStop :=
  let table := (over streamText "a b\n1 2\n3 4").1
  #[{ offset := table + 2, x := 17 }, { offset := table + 6, x := 17 },
    { offset := table + 10, x := 17 }]

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
              (markdownView driver).map (·.stops) == some expected },
    { name :=
        "a table after other blocks, as in stream.md rendered whole, has its stops at its later cells' offsets in the whole text, past the blocks before it"
      run :=
        pure <|
          match markdownDriver.map (markdownFed · "C-c w") with
          | none => false
          | some driver =>
            (over streamText "a b").1 > 0 &&
              (markdownBuffer driver "whole").map (·.stops) == some streamStops }]

/-- The checks that an append through the core call re-renders only the
changed tail and rewrites only the bytes from where the text first changes
(**criterion 7** through the call). -/
def markdownAppendChecks : List Check :=
  let (docs, _) := streamed
  let whole :=
    Markdown.render { viewOptions with faces := facesOf shippedTable }
      Support.Markdown.stream.source Support.Markdown.stream.layers
  let once := markdownDriver.map (markdownFed · "C-c s C-c a")
  let all := markdownDriver.map (markdownFed · "C-c s C-c a C-c a C-c a C-c w")
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
              buffer.folds.any fun fold => fold.key == "code 1" && !fold.folded },
    { name :=
        "after every chunk is appended the buffer's stops are those a fresh renderMarkdown of stream.md whole puts, at its table's later cells in the whole text"
      run :=
        pure <|
          match all with
          | none => false
          | some driver =>
            (markdownBuffer driver "stream").map (·.stops) == some streamStops &&
              (markdownBuffer driver "stream").map (·.stops) ==
                (markdownBuffer driver "whole").map (·.stops) },
    { name :=
        "after renderMarkdown of the empty document and appendMarkdown of a reply's first chunk, one unfinished paragraph, the buffer holds that paragraph alone, rendered once"
      run :=
        pure <|
          match markdownDriver.map (markdownFed · "C-c e C-c n") with
          | none => false
          | some driver =>
            let head :=
              Markdown.render viewOptions Support.Markdown.replyHead.source
                Support.Markdown.replyHead.layers
            markdownValue driver "reply" "result" == some (.str "ok") &&
              ((markdownBuffer driver "reply").bind (markdownText driver ·)) ==
                some head.description.text &&
              ((markdownBuffer driver "reply").bind (·.markdown)).map (·.rendered) == some 1 },
    { name :=
        "after every chunk of the reply is appended to the empty render, the buffer's text, spans, links and stops are those a fresh renderMarkdown of reply.md whole puts"
      run :=
        pure <|
          match markdownDriver.map (markdownFed · "C-c e C-c n C-c n C-c y") with
          | none => false
          | some driver =>
            match markdownBuffer driver "reply", markdownBuffer driver "reply-whole" with
            | some reply, some whole =>
              let description :=
                (Markdown.render viewOptions Support.Markdown.reply.source
                    Support.Markdown.reply.layers).description
              markdownValue driver "reply" "result" == some (.str "ok") &&
                markdownText driver reply == some description.text &&
                markdownText driver whole == some description.text &&
                reply.spans == whole.spans &&
                reply.links == whole.links &&
                !whole.stops.isEmpty &&
                reply.stops == whole.stops &&
                reply.markdown.map (·.rendered) == some 3
            | _, _ => false }]

/-- The display model over the last scene `driver` published, knowing the
text of the buffer called `name`, in the editor model's cells of 1 by 1, so
that a point is a cell; with the snapshot view 0 shows and that text. -/
def displayedIn (driver : TestDriver) (name : String) :
    Option (DisplayModel × SnapshotId × String) := do
  let view ← markdownView driver
  let buffer ← markdownBuffer driver name
  let text ← markdownText driver buffer
  let scene ← driver.model.display.scenes.back?
  return ({
        cells := { advance := 1, lineHeight := 1 }, texts := #[(view.snapshot, text)]
        published := #[scene] },
      view.snapshot, text)

/-- The x of the spot of `position` of `snapshot` in `model`, in a view
`width` wide and tall enough for every row, shown from `anchor`. -/
def spotX (model : DisplayModel) (snapshot : SnapshotId) (width anchor position : Nat) :
    Option Nat :=
  ((model.spot { snapshot, width, height := 1000, anchor, position }).toOption.join).map (·.x)

/-- The starts of the rows of `snapshot` in `model` a view `width` wide
shows from `anchor` that start before `stop`. -/
def rowStarts (model : DisplayModel) (snapshot : SnapshotId) (width anchor stop : Nat) :
    Array Nat :=
  (((model.rows { snapshot, width, height := 1000, anchor }).toOption.getD #[]).map
        (·.start)).filter
    (· < stop)

/-- The checks that a rendered list item's wrapped lines continue under its
text and a block quote's are indented by its depth, over `lists.md` on the
loop's driver, laid out by the display model under the scene the loop
published (**criteria 5 and 6**). -/
def markdownIndentViewChecks : List Check :=
  let expected :=
    Markdown.render viewOptions Support.Markdown.lists.source Support.Markdown.lists.layers
  let rendered := markdownDriver.map (markdownFed · "C-c l")
  [{  name :=
        "renderMarkdown of lists.md gives the buffer, and its published view, the description's indents"
      run :=
        pure <|
          match rendered with
          | none => false
          | some driver =>
            let indents := expected.description.indents
            markdownValue driver "lists" "result" == some (.str "ok") && !indents.isEmpty &&
              ((markdownBuffer driver "lists").map (·.indents)) == some indents &&
              ((markdownView driver).map (·.indents)) == some indents },
    { name :=
        "a wrapped nested list item continues under the text after its marker: its second row starts at the x of its text's first character, past the item's first-line indent of 16"
      run :=
        pure <|
          match rendered.bind (displayedIn · "lists") with
          | none => false
          | some (model, snapshot, text) =>
            let (start, stop) := over text "• two point one"
            -- 26 cells: 10 after the indent of 16, which "two point one"
            -- does not fit.
            let starts := rowStarts model snapshot 26 start stop
            let after := start + "• ".utf8ByteSize
            match starts[1]? with
            | none => false
            | some second =>
              spotX model snapshot 26 start second == spotX model snapshot 26 start after &&
                (spotX model snapshot 26 start after).any (· > 16) &&
                spotX model snapshot 26 start start == some 16 },
    { name := "every row of a wrapped nested quote is 32 points in, and the quote's 16"
      run :=
        pure <|
          match rendered.bind (displayedIn · "lists") with
          | none => false
          | some (model, snapshot, text) =>
            let (start, stop) := over text "nested quote"
            let (outer, outerStop) := over text "A quote"
            -- 40 cells: 8 after the indent of 32, which "nested quote" does
            -- not fit.
            let nested := rowStarts model snapshot 40 start stop
            let quote := rowStarts model snapshot 40 outer outerStop
            nested.size ≥ 2 && nested.all (spotX model snapshot 40 start · == some 32) &&
              !quote.isEmpty &&
              quote.all (spotX model snapshot 40 outer · == some 16) }]

end ModelTest
