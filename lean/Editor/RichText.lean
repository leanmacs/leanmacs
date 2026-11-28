import Editor.Fold
import Editor.Link
import Editor.Scene

/-!
# The rich-text description

One value that says everything a generated buffer shows
(`docs/design/text-and-display.md`, "The rich-text description, as
built"): its text and, at byte offsets of that text, each part a view
draws over it. A producer builds one and writes a buffer from it in one
call (`BufferId.setRichText`, `BufferId.appendRichText`, `Editor/Api.lean`),
in place of a call per part. Pure.

- **The text** (`text`): what the buffer holds.
- **Face spans** (`spans`): byte ranges, each drawn in a face, a later one
  over an earlier one (`Decoration`, `Editor/Scene.lean`).
- **Align-to stops** (`stops`): byte offsets, each with an x in whole
  points where a cell of a row starts (`AlignStop`). The producer measures
  them (`Editor/Columns.lean`): the description is layout-complete.
- **Span targets** (`links`): byte ranges, each naming a target to follow
  (`Link`, `Editor/Link.lean`).
- **Fold ranges** (`folds`): byte ranges, each keyed by its producer, with
  a placeholder and a declared state (`Foldable`, `Editor/Fold.lean`). A
  buffer written again keeps the toggled state of each key that survives
  (`Fold.merge`).
- **Wrap indents** (`indents`): byte ranges, each with where the visual
  lines of the rows it covers start (`WrapIndent`).

It is plain in-process data for generated buffers: it is not the content
vocabulary a remote client would be sent (`docs/design/remote-clients.md`,
"The vocabulary"), and nothing serialises it.

- **`shift`** moves every offset of every part, and leaves the text and a
  placeholder's own spans, which are offsets of the placeholder, alone.
- **`append`** puts one description after another: the texts one after the
  other, the second's parts moved past the first's text and listed after
  the first's.
- **`replaceFrom held start rich`**, the prefix rule, is what a buffer
  holding `held` holds once it is written from `rich` from `start` on:
  - the text before `start` is `held`'s, and the rest `rich`'s;
  - one part at a time, a part of `held` that lies before `start` is kept,
    and every part of `rich` that does not is taken. A range lies before
    `start` when it starts before it and stops at it or before; an empty
    range at `start` is the tail's. A stop lies before `start` when its
    offset does;
  - the kept parts come first, in `held`'s order, and the taken ones after,
    in `rich`'s, so spans keep their draw order;
  - a kept fold whose key a taken fold has is dropped, so each key is
    declared once, and the folds are then ordered by start, stably.

## Where an addition goes

| Addition | Where |
|---|---|
| A new part | A field here, its arm in `shift`, `concat` and `replaceFrom`, its `Buffer` field and the two handlers of `Editor/State.lean` (`setRichText`, `appendRichText`), and a check in `ModelTest.richTextChecks` |
| A new producer | A module of its own that builds a `RichText` and calls `BufferId.setRichText` or `BufferId.appendRichText`; nothing here |

Pinned by `ModelTest.richTextChecks`.
-/

namespace Editor

/-- What a generated buffer shows: its text and the parts drawn over it, at
byte offsets of that text ("The rich-text description", in the module
docs). -/
structure RichText where
  /-- The text. -/
  text : String := ""
  /-- The face spans, a later one drawn over an earlier one. -/
  spans : Array Decoration := #[]
  /-- The align-to stops, measured by the producer. -/
  stops : Array AlignStop := #[]
  /-- The span targets. -/
  links : Array Link := #[]
  /-- The fold ranges, by key. -/
  folds : Array Foldable := #[]
  /-- The wrap indents, a later one over a row winning. -/
  indents : Array WrapIndent := #[]
  deriving DecidableEq, Repr, Inhabited

namespace RichText

/-- The bytes of `text` from `start` up to `stop`, as a string; the empty
string when they do not end between characters. -/
def bytes (text : String) (start stop : Nat) : String :=
  (String.fromUTF8? (text.toUTF8.extract start stop)).getD ""

/-- `rich` with every offset of every part moved `distance` bytes on, its
text and its placeholders' own spans as they were. -/
def shift (rich : RichText) (distance : Nat) : RichText :=
  { rich with
    spans :=
      rich.spans.map fun span =>
        { span with
          start := span.start + distance, stop := span.stop + distance }
    stops := rich.stops.map fun stop => { stop with offset := stop.offset + distance }
    links :=
      rich.links.map fun link =>
        { link with
          start := link.start + distance, stop := link.stop + distance }
    folds :=
      rich.folds.map fun fold =>
        { fold with
          start := fold.start + distance, stop := fold.stop + distance }
    indents :=
      rich.indents.map fun indent =>
        { indent with
          start := indent.start + distance, stop := indent.stop + distance } }

/-- `before`'s text then `after`'s, and `before`'s parts then `after`'s, each
as it is. -/
def concat (before after : RichText) : RichText :=
  { text := before.text ++ after.text, spans := before.spans ++ after.spans
    stops := before.stops ++ after.stops, links := before.links ++ after.links
    folds := before.folds ++ after.folds, indents := before.indents ++ after.indents }

/-- `before`, then `after` with its parts moved past `before`'s text. -/
def append (before after : RichText) : RichText :=
  before.concat (after.shift before.text.utf8ByteSize)

/-- Whether the range `start` to `stop` lies before the byte `at`: it starts
before it and stops at it or before. An empty range at `at` does not. -/
private def liesBefore (start stop at_ : Nat) : Bool :=
  start < at_ && stop ≤ at_

/-- What a buffer holding `held` holds once it is written from `rich` from
the byte `start` on (the prefix rule, in the module docs). -/
def replaceFrom (held : RichText) (start : Nat) (rich : RichText) : RichText :=
  let cut := min start (min held.text.utf8ByteSize rich.text.utf8ByteSize)
  let part {α : Type} (range : α → Nat × Nat) (held rich : Array α) : Array α :=
    held.filter (fun item => liesBefore (range item).1 (range item).2 start) ++
      rich.filter fun item => !liesBefore (range item).1 (range item).2 start
  let taken := rich.folds.filter fun fold => !liesBefore fold.start fold.stop start
  let kept :=
    held.folds.filter fun fold =>
      liesBefore fold.start fold.stop start && !taken.any (·.key == fold.key)
  { text := bytes held.text 0 cut ++ bytes rich.text cut rich.text.utf8ByteSize
    spans := part (fun span => (span.start, span.stop)) held.spans rich.spans
    stops :=
      held.stops.filter (·.offset < start) ++ rich.stops.filter fun stop => !(stop.offset < start)
    links := part (fun link => (link.start, link.stop)) held.links rich.links
    folds := (kept ++ taken).insertionSort fun a b => a.start < b.start
    indents := part (fun indent => (indent.start, indent.stop)) held.indents rich.indents }

end RichText

end Editor
