import Editor.Display
import Editor.State

/-!
# What a view of an excerpt buffer shows

An excerpt buffer (`Editor/State.lean`, "Excerpt buffers") is shown in a
window like any buffer. Two things are drawn over its text that a plain
buffer's view has none of, each placed by the list of its text's snapshot
(`SnapshotId.excerpts`, `Editor/Text.lean`), so that what is drawn is placed
by the text that is drawn, whatever the sources did since:

- **A header above each excerpt** (`headers`, `blocksOf`): for each excerpt
  whose entry has a header that is not empty, a block (`Block`,
  `Editor/Scene.lean`) of the header's text before the excerpt's start, all
  of it in `headerFace`. An excerpt's start is always a row's start, so the
  header is drawn between the separator row above and the excerpt's first
  row. The separator row stays: it holds the end of the excerpt above.
- **Its sources' buffer spans** (`translated`, `sourceSpansOf`): each source
  buffer's spans (`Buffer.spans`) that meet the range of an excerpt of it,
  clipped to it and moved to where the excerpt is, so a span set once on a
  source is drawn at every excerpt of it. The loop draws them under the
  excerpt buffer's own spans and the search matches (`Editor/Loop.lean`,
  "Decorations").
- **What was not examined** (`unexamined`, `unexaminedOf`): over each
  tracked excerpt (`Buffer.ExcerptEntry.viewed`, `Editor/State.lean`,
  "Excerpt buffers") that no scene has shown, and that is not empty, a span
  over its bytes in `unexaminedFace`. The loop draws it above the excerpt
  buffer's own spans and under the search's matches (`Editor/Loop.lean`,
  "Decorations"), and reads it before the scene's rows mark what they show,
  so an excerpt is drawn unexamined in the first scene that shows it and
  plainly from the next.

**Viewed rows.** The excerpts a view shows (`shown`) are those one of its
rows starts in, `start ≤ row.start < stop`, and an empty excerpt a row
starts at. A separator row starts at the end of the excerpt above, so it
shows nothing. The loop asks the display for each view's rows
(`Display.rowsShown`, with its blocks) once the scene is decorated, and
marks what they show (`Editor/Loop.lean`, "After each event").

A source's syntax highlights are not this module's: they are the text's own
spans, translated by the library through the same list
(`crates/editor-ffi/src/display.rs`, `text_ref`). The selection and the
search matches are the excerpt view's own, asked of its own text, so
nothing is translated for them.

A plain buffer, and a list the store refuses, give no block and no span.
-/

namespace Editor

namespace ExcerptView

/-- The face an excerpt's header is drawn in, which the vocabulary
declares. -/
def headerFace : FaceName :=
  ⟨"block-header"⟩

/-- The header blocks of an excerpt text whose list is `placed`, with the
entries `entries`: for each index both have whose header is not empty, a
block of the header before the excerpt's start, all of it in `headerFace`.
The two are zipped to the shorter. -/
def headers (placed : Array Excerpt.Placed) (entries : Array Buffer.ExcerptEntry) : Array Block :=
  (placed.zip entries).filterMap fun (excerpt, entry) =>
    if entry.header.isEmpty then none
    else
      some
        { before := excerpt.start, text := entry.header
          decorations := #[⟨0, entry.header.utf8ByteSize, headerFace⟩] }

/-- The spans of an excerpt text whose list is `placed`, from each excerpt's
source's spans (`spansOf` the excerpt's index): for each excerpt in order,
those of its source's spans that meet its source range, clipped to it and
moved by where the excerpt starts less where its range starts, in the
source's order. An empty excerpt gets none. -/
def translated (placed : Array Excerpt.Placed) (spansOf : Nat → Array Decoration) :
    Array Decoration :=
  placed.zipIdx.flatMap fun (excerpt, index) =>
    (spansOf index).filterMap fun span =>
      let start := max span.start excerpt.sourceStart
      let stop := min span.stop excerpt.sourceStop
      if start < stop then
        some
          { span with
            start := start - excerpt.sourceStart + excerpt.start
            stop := stop - excerpt.sourceStart + excerpt.start }
      else none

/-- The list of `snapshot`, the excerpt text's snapshot a view of `buffer`
shows, when `buffer` is an excerpt buffer and `wanted` says its entries
need it; none for a plain buffer, and when the store refuses. -/
def placedOf (buffer : Buffer) (snapshot : SnapshotId) (wanted : Buffer.Excerpts → Bool) :
    TextM (Option (Array Excerpt.Placed × Buffer.Excerpts)) := do
  let some excerpts := buffer.excerpts | return none
  unless wanted excerpts do
    return none
  match ← (observing snapshot.excerpts : TextM (Except TextError (Array Excerpt.Placed))) with
  | .ok placed =>
    return some (placed, excerpts)
  | .error _ =>
    return none

/-- The header blocks of a view of `buffer` that shows `snapshot`
(`headers`): none for a plain buffer, for an excerpt buffer with no header,
and when the store refuses the list. It asks the list once, and not at all
when there is no header. -/
def blocksOf (buffer : Buffer) (snapshot : SnapshotId) : TextM (Array Block) := do
  let some (placed, excerpts) ←
    placedOf buffer snapshot (·.entries.any (!·.header.isEmpty)) | return #[]
  return headers placed excerpts.entries

/-- The spans of its sources' buffers (`Buffer.spans`) drawn in a view of
`buffer` that shows `snapshot` (`translated`): each excerpt's source buffer
is the buffer of `state` over its source's text (`EditorState.bufferOver?`),
and an excerpt whose source no buffer holds has none. None for a plain
buffer, when no source buffer has a span, and when the store refuses the
list. It asks the list once, and not at all when no source has a span. -/
def sourceSpansOf (state : EditorState) (buffer : Buffer) (snapshot : SnapshotId) :
    TextM (Array Decoration) := do
  let spansOf (entry : Buffer.ExcerptEntry) : Array Decoration :=
    (((state.bufferOver? entry.source).bind state.buffer?).map (·.spans)).getD #[]
  let some (placed, excerpts) ←
    placedOf buffer snapshot (·.entries.any fun entry => !(spansOf entry).isEmpty) | return #[]
  return translated placed fun index => (excerpts.entries[index]?.map spansOf).getD #[]

/-- The face a tracked excerpt no scene has shown is drawn in, which the
vocabulary declares. -/
def unexaminedFace : FaceName :=
  ⟨"review-unexamined"⟩

/-- The indexes of the excerpts of the list `placed` that `rows` show ("Viewed
rows", in the module docs): each one a row starts in, or an empty one a row
starts at, in list order. -/
def shown (placed : Array Excerpt.Placed) (rows : Array Display.Row) : Array Nat :=
  (placed.zipIdx.filter fun (excerpt, _) =>
        rows.any fun row =>
          if excerpt.start == excerpt.stop then row.start == excerpt.start
          else excerpt.start ≤ row.start && row.start < excerpt.stop).map
    (·.2)

/-- The spans of what was not examined of an excerpt text whose list is
`placed`, with the entries `entries`: for each index both have whose entry
is tracked and not shown by a scene and whose excerpt is not empty, a span
over its bytes in `unexaminedFace`. -/
def unexamined (placed : Array Excerpt.Placed) (entries : Array Buffer.ExcerptEntry) :
    Array Decoration :=
  (placed.zip entries).filterMap fun (excerpt, entry) =>
    match entry.viewed with
    | some viewed =>
      if !viewed.examined && excerpt.start < excerpt.stop then
        some ⟨excerpt.start, excerpt.stop, unexaminedFace⟩
      else none
    | none => none

/-- The spans of what was not examined drawn in a view of `buffer` that shows
`snapshot` (`unexamined`): none for a plain buffer, for an excerpt buffer
with no tracked entry, and when the store refuses the list. It asks the list
once, and not at all when no entry is tracked. -/
def unexaminedOf (buffer : Buffer) (snapshot : SnapshotId) : TextM (Array Decoration) := do
  let some (placed, excerpts) ←
    placedOf buffer snapshot (·.entries.any (·.viewed.isSome)) | return #[]
  return unexamined placed excerpts.entries

end ExcerptView

end Editor
