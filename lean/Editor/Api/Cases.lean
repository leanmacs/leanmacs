import Editor.Api
import Editor.Command.Dispatch

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

This module imports the API and the dispatch, and nothing else: no model
and no real binding. The list is plain data, programs that have not run.

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
the command was interrupted, which nothing here does. -/
def Case.play (case : Case) : EditorM Bool := do
  let state ← case.start
  match ← case.run.dispatched {} state with
  | (.finished held, _) =>
    return held
  | (.refused error, _) =>
    throw error
  | (.interrupted, _) =>
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

/-- Every case of the editor API, in the order they run. -/
def cases : List Case :=
  bufferCases

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
