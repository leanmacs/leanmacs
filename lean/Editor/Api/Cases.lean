import Editor.InputScheme.Test
import Editor.Loop

/-!
# The cases of the editor API

What the operations of the editor API (`Editor/Api.lean`) do, as one list
of cases. A case is a command over the editor's port that returns whether
it held, and the editor state it starts from. It is played as the loop
plays a command: the state is made, and the command runs dispatched from it
(`EditorM.dispatched`, `Editor/Command/Dispatch.lean`), so its state
requests are answered from that state and every other request reaches the
runner.

The same list runs against the editor's models (`model-test`, under
`lake test`) and against the text port's real binding with a display
recorder (`contract-test`, linked with the Rust library). So every request
an operation makes of the library is answered the same by the model and by
the binding, for each case: this is the contract check of the requests that
reach the library. What an operation does to Lean state alone has one
implementation, the state requests' handler, and is pinned once, on the
models (`ModelTest.stateRequestChecks`, `ModelTest.apiStateChecks`).

This module imports the loop, which brings the API and the dispatch, and
the test scheme, for the one case that asks the loop what the next scene's
views are (`Loop.views`). It imports no model and no real binding. The list
is plain data, programs that have not run.

Offsets are byte offsets. "é" and "ö" are two bytes each: `"héllo"` is 6
bytes and `"héllo wörld"` is 13.

## Where an addition goes

A new operation of `Editor/Api.lean` that makes a text request gets a case
here, which says what the operation leaves in the text store and in the
state, and what it does when the store or the state refuses it.
-/

namespace Editor.ApiCases

/-- One case of the editor API. -/
structure Case where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Makes the editor state the command starts from: by default the initial
  state, one window on the buffer `scratch`, over the store's first text. -/
  start : TextM EditorState := EditorState.initial ⟨640, 480⟩
  /-- Observes the case; `true` when it holds. A command that fails has not
  held. -/
  run : EditorM Bool

/-- The case as one command: makes the state it starts from, and runs its
command dispatched from it. Refused when the command is, and `false` when
the command was interrupted or gave up, which nothing here does. -/
def Case.play (case : Case) : EditorM Bool := do
  let state ← case.start
  match ← case.run.dispatched {} state with
  | (.finished held, _) =>
    return held
  | (.refused error, _) =>
    throw error
  | (.interrupted, _) | (.gaveUp _, _) =>
    return false

/-- Whether `reply` is the refusal `refusal`. -/
def refusedAs {ε α : Type} [BEq ε] (reply : Except ε α) (refusal : ε) : Bool :=
  match reply with
  | .error was => was == refusal
  | .ok _ => false

/-- Runs `command` and returns whether the text store refused it with
`error`. -/
def refusedWith {α : Type} (error : TextError) (command : EditorM α) : EditorM Bool :=
  try
    discard command
    return false
  catch refusal =>
    return refusal == error

/-- The selection of shape `shape` with `ranges`, each an anchor and a head,
whose primary is the one at `primary`. -/
def selection (ranges : Array (Nat × Nat)) (shape : Shape := .exclusive) (primary : Nat := 0) :
    Selection :=
  { ranges := ranges.map fun (anchor, head) => ⟨anchor, head⟩, primary, shape }

/-- The initial state with its buffer holding `text` and its window's
selection placed at `selected`: view 0 on buffer 0, over the store's first
text. -/
def holding (text : String) (selected : Selection) : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let some target := state.focusedTarget? | throw .noSuchText
  target.buffer.text.insert 0 text
  target.buffer.text.place target.window.selection (.selection selected)
  return state

/-- The text of the buffer `scratch` of the initial state: the store's
first. -/
def scratch : TextId :=
  ⟨0⟩

/-- The cases of buffers: creating, finding and removing one, and editing
and reading one at positions. -/
def bufferCases : List Case :=
  [{  name :=
        "a buffer created from a command has the next id, holds the contents it was created with, is found by its name and by no other, and its history is a new tree over its text"
      run := do
        let .ok id ← createBuffer "notes" "héllo" | return false
        let .ok empty ← createBuffer "empty" | return false
        let state ← editorState
        let some buffer := state.buffer? id | return false
        let some blank := state.buffer? empty | return false
        return id == ⟨1⟩ && empty == ⟨2⟩ && buffer.name == "notes" &&
            (← findBuffer "notes") == some id &&
            (← findBuffer "scratch") == some ⟨0⟩ &&
            (← findBuffer "nothing") == none &&
            (← buffer.text.read) == "héllo" &&
            (← blank.text.read) == "" &&
            buffer.history == (← UndoTree.over buffer.text) &&
            !buffer.history.isModified &&
            state.wellFormed },
    { name :=
        "creating a buffer under a name a buffer has is refused with nameTaken and makes no text: the next text made has the id it would have had"
      run := do
        let before ← createText ""
        let refused ← createBuffer "scratch" "lost"
        let after ← createText ""
        return refusedAs refused (.nameTaken "scratch") && after.index == before.index + 1 &&
            (← editorState).buffers.size == 1 },
    { name :=
        "a buffer added over a text the command made holds that text, with a new tree over it as its history; a name a buffer has is refused with nameTaken"
      run := do
        let text ← createText "héllo"
        text.insert 6 " wörld"
        let .ok id ← addBuffer "adopted" text | return false
        let some buffer := (← editorState).buffer? id | return false
        return buffer.text == text && buffer.history == (← UndoTree.over text) &&
            buffer.history.state == ⟨1⟩ &&
            (← findBuffer "adopted") == some id &&
            refusedAs (← addBuffer "adopted" text) (.nameTaken "adopted") },
    { name :=
        "a buffer no window shows is removed: it is found no more and its id names nothing; removing it again is refused with noSuchBuffer, and removing a buffer a window shows with shown and the view"
      run := do
        let .ok id ← createBuffer "gone" | return false
        let removed ← id.remove
        let state ← editorState
        return removed matches .ok () && state.buffer? id == none &&
            (← findBuffer "gone") == none &&
            refusedAs (← id.remove) (.noSuchBuffer id) &&
            refusedAs (← (⟨0⟩ : BufferId).remove) (.shown ⟨0⟩) &&
            (← editorState) == state &&
            state.wellFormed },
    { name :=
        "inserting at an offset of a buffer and deleting a range of it each change its text as one revision made by the user, and leave the editor state as it was"
      run := do
        let .ok id ← createBuffer "edited" "héllo" | return false
        let .ok text ← id.text | return false
        let state ← editorState
        let .ok () ← id.insertAt 6 " wörld" | return false
        let inserted := (← text.read, ← text.revision)
        let .ok () ← id.deleteRange 0 3 | return false
        return inserted == ("héllo wörld", 1) && (← text.read) == "llo wörld" &&
            (← text.revision) == 2 &&
            (← text.trace 3 10) == #[⟨3, 10, .entry 1 Origin.user⟩] &&
            ((← text.changesSince 1).edits.size) == 1 &&
            (← editorState) == state },
    { name :=
        "an insertion or a deletion the store refuses, at an offset inside a character or past the end, or over a range that ends before it starts, is refused with badChange and leaves the text, its revision and the editor state as they were"
      run := do
        let .ok id ← createBuffer "kept" "héllo" | return false
        let .ok text ← id.text | return false
        let state ← editorState
        return (← refusedWith .badChange (id.insertAt 2 "x")) &&
            (← refusedWith .badChange (id.insertAt 7 "x")) &&
            (← refusedWith .badChange (id.deleteRange 1 2)) &&
            (← refusedWith .badChange (id.deleteRange 4 3)) &&
            (← refusedWith .badChange (id.deleteRange 3 9)) &&
            (← text.read) == "héllo" &&
            (← text.revision) == 0 &&
            (← editorState) == state },
    { name :=
        "inserting into, deleting from and asking for the text of a buffer there is none of are each refused with noSuchBuffer, a value, and make no request of the store"
      run := do
        let absent : BufferId := ⟨9⟩
        let before ← createText ""
        let inserted ← absent.insertAt 0 "x"
        let deleted ← absent.deleteRange 0 0
        let text ← absent.text
        let after ← createText ""
        return refusedAs inserted (.noSuchBuffer absent) &&
            refusedAs deleted (.noSuchBuffer absent) &&
            refusedAs text (.noSuchBuffer absent) &&
            after.index == before.index + 1 &&
            (← before.revision) == 0 },
    { name :=
        "a buffer's text is read through the text port's own reads: a row, a range, its length and its rows, as they are after an edit at a position"
      run := do
        let .ok id ← createBuffer "rows" "ab\ncdé\n" | return false
        let .ok text ← id.text | return false
        let .ok () ← id.insertAt 3 "x" | return false
        return (← text.rowContent 0) == "ab" && (← text.rowContent 1) == "xcdé" &&
            (← text.rowContent 2) == "" &&
            (← text.slice 3 6) == "xcd" &&
            (← text.byteLength) == 9 &&
            (← text.rowCount) == 3 }]

/-- The cases of a view's selections: inserting at them, deleting what they
cover, and reading and placing them. -/
def selectionCases : List Case :=
  [{  name :=
        "inserting at a view's selections, two cursors, puts the insertion at each and leaves each cursor just after its insertion, as one revision made by the user that carries the selection before and the cursors after"
      start := holding "abcd" (selection #[(1, 1), (3, 3)])
      run := do
        let .ok before ← (⟨0⟩ : ViewId).selection | return false
        let .ok () ← (⟨0⟩ : ViewId).insertAtSelections "X" | return false
        let text := (← scratch.read, ← scratch.revision)
        let .ok after ← (⟨0⟩ : ViewId).selection | return false
        let traced ← scratch.trace 0 6
        -- The insertion was the text's second revision: its inverse hands
        -- back the selection the transaction carried before it.
        let undone ← scratch.applyInverse 2 2
        return before == selection #[(1, 1), (3, 3)] && text == ("aXbcXd", 2) &&
            after == selection #[(2, 2), (5, 5)] &&
            traced.map (·.author) ==
              #[.entry 1 Origin.unattributed, .entry 2 Origin.user, .entry 1 Origin.unattributed,
                .entry 2 Origin.user, .entry 1 Origin.unattributed] &&
            undone.selection == some (selection #[(1, 1), (3, 3)]) &&
            (← scratch.read) == "abcd" },
    { name :=
        "inserting at selections that are ranges inserts at the head of each, forward or backward, and leaves a cursor after each insertion, with the primary and the shape kept; a string of two-byte characters moves the later cursors by its bytes"
      start := holding "abcdef" (selection #[(0, 2), (5, 3)] (primary := 1))
      run := do
        let .ok () ← (⟨0⟩ : ViewId).insertAtSelections "é" | return false
        let .ok after ← (⟨0⟩ : ViewId).selection | return false
        return (← scratch.read) == "abécédef" &&
            after == selection #[(4, 4), (7, 7)] (primary := 1) },
    { name :=
        "deleting a view's selections deletes what each range covers, by the selection's shape, as one revision made by the user, and leaves a cursor where each range started"
      start := holding "abcdef" (selection #[(1, 3), (5, 4)])
      run := do
        let .ok () ← (⟨0⟩ : ViewId).deleteSelections | return false
        let .ok exclusive ← (⟨0⟩ : ViewId).selection | return false
        let deleted := (← scratch.read, ← scratch.revision)
        -- An inclusive cursor covers the character it is on.
        let .ok () ← (⟨0⟩ : ViewId).select (selection #[(1, 1)] .inclusive) | return false
        let .ok () ← (⟨0⟩ : ViewId).deleteSelections | return false
        let .ok inclusive ← (⟨0⟩ : ViewId).selection | return false
        return deleted == ("adf", 2) && exclusive == selection #[(1, 1), (2, 2)] &&
            (← scratch.read) == "af" &&
            inclusive == selection #[(1, 1)] .inclusive &&
            (← scratch.revision) == 3 },
    { name :=
        "a view's selection is read as the store keeps it and placed as it is given: ranges that overlap are read back as one, and a selection the store refuses, with an end inside a character or with no range, is refused with badSelection and leaves the selection as it was"
      start := holding "héllo" (selection #[(0, 0)])
      run := do
        let view : ViewId := ⟨0⟩
        let .ok () ← view.select (selection #[(4, 6), (0, 3), (1, 3)] (primary := 1)) | return false
        let .ok merged ← view.selection | return false
        let inside ← refusedWith .badSelection (view.select (selection #[(0, 2)]))
        let empty ← refusedWith .badSelection (view.select (selection #[]))
        let .ok kept ← view.selection | return false
        return merged.ranges.size == 2 && inside && empty && kept == merged &&
            (← scratch.revision) == 1 },
    { name :=
        "reading, placing, inserting at and deleting the selections of a view with no window are each refused with noSuchWindow, a value, and make no request of the store"
      run := do
        let view : ViewId := ⟨9⟩
        let before ← createText ""
        let read ← view.selection
        let placed ← view.select (selection #[(0, 0)])
        let inserted ← view.insertAtSelections "x"
        let deleted ← view.deleteSelections
        let after ← createText ""
        return refusedAs read (.noSuchWindow view) && refusedAs placed (.noSuchWindow view) &&
            refusedAs inserted (.noSuchWindow view) &&
            refusedAs deleted (.noSuchWindow view) &&
            after.index == before.index + 1 &&
            (← scratch.revision) == 0 }]

/-- The cases of undo from a command: closing the group, undoing and
redoing over the buffer's own tree. -/
def undoCases : List Case :=
  [{  name :=
        "two groups undone and redone: after an edit, a boundary, a second edit and two undos, the text after each undo is the text before the edit it took back and the selection handed back is the selection before that edit; two redos give back both texts, each with the selection from after its edit"
      start := holding "ab" (selection #[(2, 2)])
      run := do
        let view : ViewId := ⟨0⟩
        let buffer : BufferId := ⟨0⟩
        -- What the buffer was made holding is a step of its own.
        let .ok () ← buffer.closeGroup | return false
        let .ok () ← view.insertAtSelections "c" | return false
        let .ok firstSelection ← view.selection | return false
        let first ← scratch.read
        let .ok () ← buffer.closeGroup | return false
        let .ok () ← view.select (selection #[(0, 0)]) | return false
        let .ok () ← view.insertAtSelections "X" | return false
        let .ok secondSelection ← view.selection | return false
        let second ← scratch.read
        -- The second edit's group is still open: the undo closes it.
        let .ok (some undoneSecond) ← buffer.undo | return false
        let afterSecond ← scratch.read
        let .ok (some undoneFirst) ← buffer.undo | return false
        let afterFirst ← scratch.read
        let .ok (some redoneFirst) ← buffer.redo | return false
        let againFirst ← scratch.read
        let .ok (some redoneSecond) ← buffer.redo | return false
        let againSecond ← scratch.read
        return first == "abc" && firstSelection == selection #[(3, 3)] && second == "Xabc" &&
            secondSelection == selection #[(1, 1)] &&
            afterSecond == "abc" &&
            undoneSecond == ⟨some (selection #[(0, 0)])⟩ &&
            afterFirst == "ab" &&
            undoneFirst == ⟨some (selection #[(2, 2)])⟩ &&
            againFirst == "abc" &&
            redoneFirst == ⟨some (selection #[(3, 3)])⟩ &&
            againSecond == "Xabc" &&
            redoneSecond == ⟨some (selection #[(1, 1)])⟩ },
    { name :=
        "an undo or a redo records the moved tree as the buffer's: the next undo goes on from where the last left the text, a redo after an undo and an edit finds nothing to redo, and the edit made after the undo is undone alone"
      start := holding "ab" (selection #[(2, 2)])
      run := do
        let view : ViewId := ⟨0⟩
        let buffer : BufferId := ⟨0⟩
        let .ok () ← buffer.closeGroup | return false
        let .ok () ← view.insertAtSelections "c" | return false
        let .ok (some _) ← buffer.undo | return false
        let .ok () ← view.insertAtSelections "d" | return false
        let edited ← scratch.read
        let .ok nothing ← buffer.redo | return false
        let .ok (some _) ← buffer.undo | return false
        let undone ← scratch.read
        let some held := (← editorState).buffer? buffer | return false
        return edited == "abd" && nothing == none && undone == "ab" && !held.history.pending &&
            held.history.nodes.size == 4 },
    { name :=
        "an undo and a redo of a buffer with no step to take find nothing and change nothing; closing a group with nothing in it makes no node; and each is refused with noSuchBuffer for a buffer there is none of"
      run := do
        let .ok buffer ← createBuffer "fresh" "text" | return false
        let .ok text ← buffer.text | return false
        let .ok undone ← buffer.undo | return false
        let .ok redone ← buffer.redo | return false
        let .ok () ← buffer.closeGroup | return false
        let some held := (← editorState).buffer? buffer | return false
        let absent : BufferId := ⟨9⟩
        return undone == none && redone == none && (← text.read) == "text" &&
            (← text.revision) == 0 &&
            held.history.nodes.size == 1 &&
            refusedAs (← absent.undo) (.noSuchBuffer absent) &&
            refusedAs (← absent.redo) (.noSuchBuffer absent) &&
            refusedAs (← absent.closeGroup) (.noSuchBuffer absent) },
    { name :=
        "a buffer says whether it is modified, from its history once told the revision its text is at: it is not when it is made, it is after an edit made in the same command, and it is not once that edit is undone; a buffer there is none of is refused with noSuchBuffer"
      run := do
        let .ok buffer ← createBuffer "fresh" "text" | return false
        let made ← buffer.isModified
        let .ok () ← buffer.insertAt 0 "x" | return false
        let edited ← buffer.isModified
        let .ok (some _) ← buffer.undo | return false
        let undone ← buffer.isModified
        let absent : BufferId := ⟨9⟩
        return made matches .ok false && edited matches .ok true && undone matches .ok false &&
            refusedAs (← absent.isModified) (.noSuchBuffer absent) },
    { name :=
        "an edit that carries the selections it is handed: replaceCarrying replaces an extent of the text in one revision and leaves the window's selection at the one after; an undo hands back the one before, which was not the window's, and a redo the one after; an extent that stops inside a character is refused with badChange, with the text, its revision and the window's selection as they were"
      start := holding "héllo wörld" (selection #[(0, 0)])
      run := do
        let view : ViewId := ⟨0⟩
        let buffer : BufferId := ⟨0⟩
        let .ok () ← buffer.closeGroup | return false
        let revision ← scratch.revision
        let before := selection #[(7, 10)]
        let after := selection #[(3, 1)] .inclusive
        let .ok () ← view.onTarget (·.replaceCarrying ⟨1, 6⟩ "ey" before after) | return false
        let replaced ← scratch.read
        let .ok placed ← view.selection | return false
        let made ← scratch.revision
        let .ok (some undone) ← buffer.undo | return false
        let restored ← scratch.read
        let .ok (some redone) ← buffer.redo | return false
        let again ← scratch.read
        let moved ← scratch.revision
        -- An undo and a redo place no selection: the marker is where the
        -- two edits left it.
        let .ok held ← view.selection | return false
        -- In "hey wörld" the "ö" is bytes 5 and 6.
        let refused ←
          refusedWith .badChange (view.onTarget (·.replaceCarrying ⟨2, 6⟩ "x" before after))
        let .ok kept ← view.selection | return false
        return replaced == "hey wörld" && placed == after && made == revision + 1 &&
            undone == ⟨some before⟩ &&
            restored == "héllo wörld" &&
            redone == ⟨some after⟩ &&
            again == "hey wörld" &&
            refused &&
            (← scratch.read) == "hey wörld" &&
            (← scratch.revision) == moved &&
            kept == held }]

/-- A cursor marker at the start of `text`, made and given up at once: its
number says how many markers the text had given out before it. -/
def nextMarker (text : TextId) : TextM Nat := do
  let marker ← text.mark (.selection (selection #[(0, 0)]))
  text.unmark marker
  return marker.index

/-- The cases of windows: splitting one, closing one, focusing one and
showing another buffer in one. -/
def windowCases : List Case :=
  [{  name :=
        "split then close: a split puts a new view, with an id no view had, below the view it was made from, on the same buffer, with markers of its own that read as the source's, and leaves the focus; closing the new view gives back the tree, the windows and the focus from before the split, and the source window's markers are the ones it had, where they were"
      start := holding "héllo" (selection #[(1, 3)])
      run := do
        let view : ViewId := ⟨0⟩
        let before ← editorState
        let some source := before.window? view | return false
        let markers := (← scratch.marker source.selection, ← scratch.marker source.scroll)
        let .ok made ← view.split .rows | return false
        let split ← editorState
        let some new := split.window? made | return false
        let copies := (← scratch.marker new.selection, ← scratch.marker new.scroll)
        let .ok () ← made.close | return false
        let after ← editorState
        return made == ⟨1⟩ && split.wellFormed &&
            split.frame.tree ==
              .split .rows (.split .rows (.window ⟨0⟩) (.window ⟨1⟩)) .minibuffer &&
            split.frame.focused == view &&
            new.buffer == source.buffer &&
            new.selection != source.selection &&
            new.scroll != source.scroll &&
            copies == markers &&
            after.frame == before.frame &&
            after.windows == before.windows &&
            after.buffers == before.buffers &&
            (← scratch.marker source.selection) == markers.1 &&
            (← scratch.marker source.scroll) == markers.2 },
    { name :=
        "a second split, along columns, puts its view to the right, with the next id and not the closed view's; focusing a view in the tree focuses it; and splitting, closing and focusing a view with no window are each refused with noSuchWindow, with no marker made"
      run := do
        let view : ViewId := ⟨0⟩
        let .ok first ← view.split .rows | return false
        let .ok () ← first.close | return false
        let .ok second ← view.split .columns | return false
        let .ok () ← second.focus | return false
        let state ← editorState
        let absent : ViewId := ⟨9⟩
        let marked ← nextMarker scratch
        let split ← absent.split .rows
        return first == ⟨1⟩ && second == ⟨2⟩ &&
            state.frame.tree ==
              .split .rows (.split .columns (.window ⟨0⟩) (.window ⟨2⟩)) .minibuffer &&
            state.frame.focused == second &&
            state.wellFormed &&
            refusedAs split (.noSuchWindow absent) &&
            refusedAs (← absent.close) (.noSuchWindow absent) &&
            refusedAs (← absent.focus) (.noSuchWindow absent) &&
            (← nextMarker scratch) == marked + 1 &&
            (← editorState) == state },
    { name :=
        "close the only window: it is refused with onlyWindow, and the tree and the rest of the state are as they were"
      run := do
        let before ← editorState
        let closed ← (⟨0⟩ : ViewId).close
        let after ← editorState
        return refusedAs closed .onlyWindow && after.frame.tree == before.frame.tree &&
            after == before },
    { name :=
        "showing another buffer in a view puts the view's window on it, with a scroll anchor at its start and one cursor at its start of the shape the view's selection had, and the view of the next scene reads that buffer's text; showing the buffer the view shows changes nothing and marks nothing; a buffer there is none of is refused with noSuchBuffer, and a view with no window with noSuchWindow"
      start := holding "first" (selection #[(2, 4)] .inclusive)
      run := do
        let view : ViewId := ⟨0⟩
        let .ok other ← createBuffer "other" "sécond" | return false
        let before ← editorState
        let marked ← nextMarker scratch
        let same ← view.show ⟨0⟩
        let unmarked := (← nextMarker scratch) == marked + 1 && (← editorState) == before
        let .ok () ← view.show other | return false
        let state ← editorState
        let some target := state.target? view | return false
        let .ok selected ← view.selection | return false
        let scroll ← target.buffer.text.marker target.window.scroll
        -- The views of the next scene, as the loop makes them of the state.
        let (views, _, unshown) ← ({ state } : Loop TestScheme.scheme).views
        let some shown := views.find? (·.id == view) | return false
        let absent : BufferId := ⟨9⟩
        return same matches .ok () && unmarked && target.window.buffer == other &&
            target.buffer.name == "other" &&
            selected == selection #[(0, 0)] .inclusive &&
            scroll == .anchor { offset := 0, bias := .before } &&
            (← shown.snapshot.read) == "sécond" &&
            unshown.isNone &&
            state.wellFormed &&
            refusedAs (← view.show absent) (.noSuchBuffer absent) &&
            refusedAs (← (⟨9⟩ : ViewId).show other) (.noSuchWindow ⟨9⟩) &&
            (← editorState) == state }]

/-- The cases of breaking a line: the break a command inserts is its
buffer's line ending. -/
def lineBreakCases : List Case :=
  [{  name :=
        "a line break in a buffer whose line ending is CRLF is a carriage return and a line feed, inserted at the cursor as one revision made by the user, with the cursor after both"
      start := holding "ab" (selection #[(1, 1)])
      run := do
        let view : ViewId := ⟨0⟩
        let stamp : File.Stamp := { seconds := 1, nanoseconds := 0, size := 2 }
        let .ok () ← (⟨0⟩ : BufferId).attachFile "/files/note.txt" stamp .crlf | return false
        let .ok () ← view.insertLineBreak | return false
        let .ok after ← view.selection | return false
        return (← scratch.read) == "a\r\nb" && after == selection #[(3, 3)] &&
            (← scratch.revision) == 2 &&
            (← scratch.trace 1 3) == #[⟨1, 3, .entry 2 Origin.user⟩] },
    { name :=
        "a line break in a buffer with no file is a line feed alone, and with two cursors each gets one, with a cursor after each; on the window and its buffer a command was handed it is the same"
      start := holding "abc" (selection #[(1, 1), (2, 2)])
      run := do
        let view : ViewId := ⟨0⟩
        let .ok () ← view.insertLineBreak | return false
        let .ok after ← view.selection | return false
        let broken ← scratch.read
        let .ok target ← view.target | return false
        target.insertLineBreak
        let .ok again ← view.selection | return false
        return broken == "a\nb\nc" && after == selection #[(2, 2), (4, 4)] &&
            (← scratch.read) == "a\n\nb\n\nc" &&
            again == selection #[(3, 3), (6, 6)] },
    { name :=
        "breaking a line in a view with no window is refused with noSuchWindow, a value, and makes no request of the store"
      run := do
        let view : ViewId := ⟨9⟩
        let before ← createText ""
        let broken ← view.insertLineBreak
        let after ← createText ""
        return refusedAs broken (.noSuchWindow view) && after.index == before.index + 1 &&
            (← scratch.revision) == 0 }]

/-- The continuation the prompts of these cases are asked with: a command's
name and an argument of the asker's own. -/
def greeting : Invocation :=
  { command := "greet", arguments := [.nat 7] }

/-- The cases of prompts: asking for one, and what the layout operations do
with the minibuffer's window while it is open. -/
def promptCases : List Case :=
  [{  name :=
        "asking for a prompt with an initial value replies the minibuffer's view, a new one, and leaves the prompt open with its label, its continuation and the view it was asked from: the minibuffer's buffer holds the initial value, with the minibuffer's mode and a new tree over its text, its window has a scroll anchor at the start and one exclusive cursor after the initial value, and it has the focus; the state is well formed"
      run := do
        let .ok view ← prompt "Name: " greeting "hé" | return false
        let state ← editorState
        let some target := state.target? view | return false
        let .ok selected ← view.selection | return false
        let scroll ← target.buffer.text.marker target.window.scroll
        return view == ⟨1⟩ &&
            state.prompt ==
              some { label := "Name: ", view, asker := ⟨0⟩, continuation := greeting } &&
            (← target.buffer.text.read) == "hé" &&
            target.buffer.major == some Prompt.mode &&
            target.buffer.history == (← UndoTree.over target.buffer.text) &&
            selected == selection #[(3, 3)] &&
            scroll == .anchor { offset := 0, bias := .before } &&
            state.frame.focused == view &&
            (← scratch.read) == "" &&
            state.wellFormed },
    { name :=
        "a prompt asked for with no initial value has an empty minibuffer, with its cursor at the start"
      run := do
        let .ok view ← prompt "Name: " greeting | return false
        let some target := (← editorState).target? view | return false
        let .ok selected ← view.selection | return false
        return (← target.buffer.text.read) == "" && selected == selection #[(0, 0)] },
    { name :=
        "asking for a prompt while one is open is refused with alreadyOpen and the open prompt's view, a value, makes no text, the next text made having the id it would have had, and leaves the state as it was"
      run := do
        let .ok view ← prompt "Name: " greeting "hé" | return false
        let state ← editorState
        let before ← createText ""
        let refused ← prompt "Again: " { command := "other" } "lost"
        let after ← createText ""
        return refusedAs refused (.alreadyOpen view) && after.index == before.index + 1 &&
            (← editorState) == state },
    { name :=
        "asking for a prompt where no window is focused, in the editor with nothing in it, is refused with noWindow, a value, makes no text, the next text made having the id it would have had, and leaves the state as it was"
      start := pure EditorState.none
      run := do
        let state ← editorState
        let before ← createText ""
        let refused ← prompt "Name: " greeting "lost"
        let after ← createText ""
        return refusedAs refused .noWindow && after.index == before.index + 1 &&
            (← editorState) == state },
    { name :=
        "splitting, closing and showing another buffer in the minibuffer's view, and showing the minibuffer's buffer in another view, are each refused with ofMinibuffer and the minibuffer's view, a value, and make no marker: the next marker made on each text has the number it would have had"
      run := do
        let .ok view ← prompt "Name: " greeting "hé" | return false
        let state ← editorState
        let some target := state.target? view | return false
        let text := target.buffer.text
        let marked := (← nextMarker scratch, ← nextMarker text)
        let split ← view.split .rows
        let closed ← view.close
        let shown ← view.show ⟨0⟩
        let elsewhere ← (⟨0⟩ : ViewId).show target.window.buffer
        return refusedAs split (.ofMinibuffer view) && refusedAs closed (.ofMinibuffer view) &&
            refusedAs shown (.ofMinibuffer view) &&
            refusedAs elsewhere (.ofMinibuffer view) &&
            (← nextMarker scratch) == marked.1 + 1 &&
            (← nextMarker text) == marked.2 + 1 &&
            (← editorState) == state },
    { name :=
        "the focus leaves the minibuffer's view for the view the prompt was asked from and comes back, each focus replying ok, and the prompt stays open"
      run := do
        let .ok view ← prompt "Name: " greeting | return false
        let away ← (⟨0⟩ : ViewId).focus
        let onWindow := (← editorState).frame.focused
        let back ← view.focus
        let state ← editorState
        return away matches .ok () && onWindow == ⟨0⟩ && back matches .ok () &&
            state.frame.focused == view &&
            state.prompt.isSome &&
            state.wellFormed },
    { name :=
        "accepting a prompt replies ok and closes it: the answer is the minibuffer's text as it is, the initial value and what was inserted at its cursor, recorded with the continuation as its first argument, before the continuation's own; the minibuffer's window is gone, the focus is on the view the prompt was asked from, and the state is well formed"
      run := do
        let .ok view ← prompt "Name: " greeting "hé" | return false
        let .ok () ← view.insertAtSelections "llo" | return false
        let accepted ← acceptPrompt
        let state ← editorState
        return accepted matches .ok () && state.prompt == none && state.window? view == none &&
            state.frame.focused == ⟨0⟩ &&
            state.answered == #[{ command := "greet", arguments := [.str "héllo", .nat 7] }] &&
            state.wellFormed },
    { name :=
        "cancelling a prompt replies ok, closes it and answers nothing: the minibuffer's window is gone and the focus is on the view the prompt was asked from"
      run := do
        let .ok view ← prompt "Name: " greeting "hé" | return false
        let cancelled ← cancelPrompt
        let state ← editorState
        return cancelled matches .ok () && state.prompt == none && state.window? view == none &&
            state.frame.focused == ⟨0⟩ &&
            state.answered == #[] &&
            state.wellFormed },
    { name :=
        "accepting and cancelling with no prompt open are each refused with notOpen, a value, and leave the state as it was"
      run := do
        let state ← editorState
        return refusedAs (← acceptPrompt) .notOpen && refusedAs (← cancelPrompt) .notOpen &&
            (← editorState) == state }]

/-- The cases of quitting: `quit` asks the text store for the revision of
each buffer that holds a file. -/
def quitCases : List Case :=
  [{  name :=
        "quit asks the editor to quit while the buffer that holds a file is in its saved state, and once the same command has edited that buffer it is refused with the buffer's name, a value, with the state as it was"
      start := do
        let state ← EditorState.initial ⟨640, 480⟩
        return (state.attachFile ⟨0⟩ "/files/note.txt" { seconds := 0, nanoseconds := 0, size := 0 }
              .lf).2
      run := do
        let clean ← quit
        let asked := (← editorState).quitting
        let .ok () ← (⟨0⟩ : BufferId).insertAt 0 "x" | return false
        let before ← editorState
        let refused ← quit
        return clean matches .ok () && asked && refusedAs refused (.unsaved "scratch") &&
            (← editorState) == before }]

/-- Every case of the editor API, in the order they run. -/
def cases : List Case :=
  bufferCases ++ selectionCases ++ undoCases ++ windowCases ++ lineBreakCases ++ promptCases ++
    quitCases

/-- Plays `cases` with `run`, each from a store with no text, and returns
the names of those that did not hold: one that returned `false`, and one
that was refused, with the refusal. -/
def failures (run : EditorM Bool → IO (Except TextError Bool)) (cases : List Case) :
    IO (List String) :=
  cases.filterMapM fun case => do
    match ← run case.play with
    | .ok true =>
      return none
    | .ok false =>
      return some case.name
    | .error error =>
      return some s!"{case.name} (the command failed with {repr error})"

end Editor.ApiCases
