import Editor.Api
import Editor.Command.Dispatch
import Editor.Completion.Candidate
import Editor.Completion.Display
import Editor.File
import Editor.Floating
import Editor.Invocation
import Editor.Language.Grammar.Answer
import Editor.Layout
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.State.Request
import Editor.Test.Completion
import Editor.Test.Models
import Editor.Test.States
import Editor.Text
import Editor.UndoTree
import Editor.Value
import ModelTest.Check

/-!
# Model tests: `Editor/State/Request.lean`

The model tests of `Editor/State/Request.lean`: `stateRequestChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The requests a well-formed state is seen to stay well formed under, on
`hiddenBuffer`, whose buffers' texts are 0, 1 and 2: each kind of request,
accepted and refused. -/
def stateRequests : List StateRequest :=
  let marker (text index : Nat) : MarkerId := ⟨⟨text⟩, index⟩
  [.read, .addBuffer "new" ⟨3⟩ (UndoTree.new ⟨3⟩ 0), .addBuffer "other" ⟨3⟩ (UndoTree.new ⟨3⟩ 0),
    .removeBuffer ⟨2⟩, .removeBuffer ⟨1⟩, .removeBuffer ⟨9⟩, .setHistory ⟨0⟩ (UndoTree.new ⟨0⟩ 4),
    .setHistory ⟨0⟩ (UndoTree.new ⟨1⟩ 0), .setValue ⟨0⟩ "count" (.nat 1),
    .setValue ⟨9⟩ "count" .null, .setSpans ⟨0⟩ #[{ start := 0, stop := 1, face := ⟨"a"⟩ }],
    .setSpans ⟨9⟩ #[], .setMajorMode ⟨0⟩ "listing", .setMajorMode ⟨9⟩ "listing",
    .addMinorMode ⟨1⟩ "one", .removeMinorMode ⟨1⟩ "one", .split ⟨0⟩ (marker 0 8) (marker 0 9),
    .split ⟨1⟩ (marker 1 8) (marker 1 9), .split ⟨0⟩ (marker 1 8) (marker 0 9),
    .split ⟨9⟩ (marker 0 8) (marker 0 9), .removeWindow ⟨1⟩, .removeWindow ⟨9⟩, .focus ⟨1⟩,
    .focus ⟨9⟩, .show ⟨0⟩ ⟨2⟩ (marker 2 0) (marker 2 1), .show ⟨0⟩ ⟨9⟩ (marker 2 0) (marker 2 1),
    .show ⟨0⟩ ⟨2⟩ (marker 0 0) (marker 2 1), .show ⟨9⟩ ⟨2⟩ (marker 2 0) (marker 2 1), .message "hi",
    .startJob "count" [.nat 1], .startJob "count" [.nat 1] (some "k"), .cancelJob "k",
    .attachFile ⟨2⟩ notePath noteStamp .crlf, .attachFile ⟨9⟩ notePath noteStamp .lf,
    .beginSave ⟨0⟩ ⟨4⟩ ⟨0⟩, .beginSave ⟨9⟩ ⟨4⟩ ⟨0⟩, .endSave ⟨0⟩ ⟨4⟩ (some noteStamp),
    .endSave ⟨9⟩ ⟨4⟩ none,
    .openPrompt "Name: " asked ⟨8⟩ (UndoTree.new ⟨8⟩ 0) (marker 8 0) (marker 8 1),
    .openPrompt "Name: " asked ⟨8⟩ (UndoTree.new ⟨8⟩ 0) (marker 0 0) (marker 8 1),
    .closePrompt none, .closePrompt (some "typed"),
    .setCandidates { all := offered #["one", "two"] },
    .setCandidates
      {
        asking :=
          #[{ source := "later", later := { job := "j" }, askedFor := "", generation := 1 }] },
    .addCandidates ⟨3⟩ 0 1 (offered #["three"]), .addCandidates ⟨3⟩ 4 1 #[],
    .sourceAnswered ⟨3⟩ 0 1, .listMatched ⟨3⟩ "" 0 #[], .matchFailed ⟨3⟩ "" 0 "no",
    .chooseCandidate .next, .chooseCandidate .previous,
    .setWanted ⟨0⟩ (some { column := .goal 3, head := 7 }), .setWanted ⟨1⟩ none,
    .setWanted ⟨9⟩ (some { column := .lineEnd, head := 0 }), .loadTheme "second", .invoke asked,
    .quit, .reload, .setRegister "a" { text := "a line\n", linewise := true }, .setScrollMargin 2,
    .split ⟨0⟩ (marker 0 8) (marker 0 9) { axis := .columns, before := true },
    .arrange ⟨0⟩ .promote, .arrange ⟨1⟩ (.exchange none), .arrange ⟨0⟩ .zoom, .arrange ⟨9⟩ .zoom,
    .arrange ⟨0⟩ (.mainCount true 1), .arrange ⟨1⟩ (.edge .left),
    .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) .stack,
    .openWindow ⟨2⟩ (marker 2 8) (marker 2 9) .stack,
    .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.edge .left),
    .openWindow ⟨9⟩ (marker 0 8) (marker 0 9) .stack,
    .openWindow ⟨0⟩ (marker 1 8) (marker 0 9) .stack,
    .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.float .frame {} false),
    .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.float (.window ⟨1⟩) {} true),
    .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.float (.position ⟨1⟩ (marker 1 3)) {} false),
    .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.float (.position ⟨1⟩ (marker 0 3)) {} false),
    .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.float (.window ⟨9⟩) {} false),
    .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.float (.window ⟨4⟩) {} false), .arrange ⟨1⟩ .float,
    .arrange ⟨0⟩ .float, .arrange ⟨4⟩ .float, .arrange ⟨4⟩ .promote, .arrange ⟨4⟩ (.edge .left),
    .arrange ⟨4⟩ (.resize .columns true 1), .arrange ⟨4⟩ .demote, .removeWindow ⟨4⟩,
    .removeWindow ⟨3⟩, .focus ⟨4⟩, .focus ⟨3⟩, .split ⟨4⟩ (marker 0 8) (marker 0 9),
    .show ⟨1⟩ ⟨0⟩ (marker 0 0) (marker 0 1), .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) .tab,
    .tab (.select 1), .tab (.rename 1 (some "notes")), .tab (.move 0 1), .tab (.select 0),
    .tab (.close 1), .tab (.close 0), .tab (.select 7), .setLanguage ⟨0⟩ (some "rust"),
    .setLanguage ⟨0⟩ none, .setLanguage ⟨9⟩ (some "rust"),
    .setJumps ⟨0⟩ { list := { entries := #[.held ⟨0⟩ (marker 0 7)], index := 1 } },
    .setJumps ⟨9⟩ {}, .setJumps ⟨0⟩ { previous := some (.held ⟨9⟩ (marker 0 7)) },
    .setJumps ⟨0⟩ { previous := some (.held ⟨0⟩ (marker 1 7)) },
    .setLocalMark ⟨0⟩ 'a' (some (marker 0 7)), .setLocalMark ⟨9⟩ 'a' none,
    .setLocalMark ⟨0⟩ 'b' (some (marker 1 7)), .setGlobalMark 'A' (some (.held ⟨0⟩ (marker 0 7))),
    .setGlobalMark 'B' (some (.held ⟨9⟩ (marker 0 7))),
    .setGlobalMark 'C' (some (.held ⟨0⟩ (marker 1 7))), .setGlobalMark 'D' (some (.file "/f" 1 2)),
    .setGlobalMark 'A' none, .setGrammars { generation := 1, answers := #[("ini", .registered {})] },
    .rehighlight #["ini"]]

/-- The checks of the state requests' pure handler (`EditorState.handle`,
`Editor/State/Request.lean`), on states made on the text model. The handler
asks the text store nothing, so a marker's id is written out by hand. -/
def stateRequestChecks : List Check :=
  let marker (text index : Nat) : MarkerId := ⟨⟨text⟩, index⟩
  [{  name := "setGrammars replaces the recorded answers; rehighlight is answered and changes no state"
      run :=
        pure <|
          let first : Language.Grammar.Answers :=
            { generation := 1, answers := #[("ini", .registered {})], registered := #["ini"] }
          let second : Language.Grammar.Answers :=
            { generation := 2, answers := #[("conf", .refused (.refused .notFound) false)]
              registered := #["ini"] }
          let (_, once) := EditorState.none.handle (.setGrammars first)
          let (_, twice) := once.handle (.setGrammars second)
          let (_, rehighlighted) := twice.handle (.rehighlight #["ini"])
          EditorState.none.grammars == {} && once.grammars == first && twice.grammars == second &&
            rehighlighted == twice },
    { name := "handOver keeps a restart's plan in the outbox, the latest in place of what was there"
      run :=
        pure <|
          let plan (record : String) : Restart.Plan := { record, handover := default }
          let (_, once) := EditorState.none.handle (.handOver (plan "/a"))
          let (_, twice) := once.handle (.handOver (plan "/b"))
          once.outbox.handOver == some (plan "/a") && twice.outbox.handOver == some (plan "/b") },
    { name :=
        "the restore's requests are their operations: restoreFrame puts a frame back, restoreWorkspaces takes in a table, markRestored marks a buffer, and restoreCells keeps the cells in the outbox, in order"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            match state.window? ⟨0⟩ with
            | none => false
            | some start =>
              let record : Restore.Frame.Record :=
                { tabs := #[{ windows := #[0], focused := 0 }, { windows := #[3], focused := 3 }] }
              let made : Window :=
                { start with
                  id := ⟨3⟩, scroll := marker 0 30, selection := marker 0 31 }
              let (framed, withFrame) := state.handle (.restoreFrame record #[start, made] #[] 4)
              let (_, withTable) :=
                state.handle (.restoreWorkspaces { unscoped := #[("n", .nat 1)] })
              let (marked, withMark) := state.handle (.markRestored ⟨0⟩)
              let cell (name : String) : KeptCell :=
                { owner := "config", name, version := 1, value := .nat 0 }
              let (_, once) := state.handle (.restoreCells #[cell "a"])
              let (_, twice) := once.handle (.restoreCells #[cell "b"])
              framed matches .ok () && withFrame.frame.tabsAfter.size == 1 &&
                withFrame.nextView == 4 &&
                withTable.workspaces.unscopedValue? "n" == some (.nat 1) &&
                marked matches .ok () &&
                (withMark.buffer? ⟨0⟩).map (·.historyRestored) == some true &&
                twice.outbox.restoredCells.map (·.name) == #["a", "b"] },
    { name :=
        "the at-point requests are their operations: open, choose, retype, retake and close a session, and retype pushes onto what commands typed"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            let session : AtPointSession :=
              { view := ⟨0⟩, buffer := ⟨0⟩, source := "line", start := marker 0 90
                stop := marker 0 91, typed := "a", shown := "a" }
            let collected : Completion.Collected := { all := offered #["a1", "a2"] }
            let (opened, open1) := state.handle (.openAtPoint session collected)
            let open1 :=
              open1.replaceCandidatesIn ⟨0⟩
                (((open1.candidatesIn? ⟨0⟩).getD {}).list "a" #[.ofIndex 0, .ofIndex 1])
            let (chose, chosen) := open1.handle (.chooseAtPoint .next)
            let (retyped, shown) := chosen.handle (.retypeAtPoint "a1" true)
            let (retaken, taken) := shown.handle (.retakeAtPoint "a1z")
            let (closed, gone) := taken.handle .closeAtPoint
            let ((), told) := state.handle (.retype ⟨0⟩ "\x08b")
            opened matches .ok () && chose matches .ok () && retyped matches .ok () &&
              retaken matches .ok () &&
              (chosen.atPoint.bind (·.candidates.chosen)) == some 0 &&
              shown.atPoint.map (·.shown) == some "a1" &&
              taken.atPoint.map (·.typed) == some "a1z" &&
              closed.toOption.map (·.source) == some "line" &&
              gone.atPoint.isNone &&
              told.retyped == #[(⟨0⟩, "\x08b")] &&
              (state.handle .closeAtPoint).1.toOption.isNone },
    { name :=
        "setLanguage records a buffer's language by name and clears it, and refuses a buffer there is none of with the state unchanged; a buffer has no language until one is set"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let languageOf (state : EditorState) : Option String :=
              (state.buffer? ⟨1⟩).bind (·.language)
            let (set, recorded) := state.handle (.setLanguage ⟨1⟩ (some "rust"))
            let (cleared, plain) := recorded.handle (.setLanguage ⟨1⟩ none)
            let (refused, same) := state.handle (.setLanguage ⟨9⟩ (some "rust"))
            set.toOption.isSome && languageOf state == none && languageOf recorded == some "rust" &&
              (recorded.buffer? ⟨0⟩).bind (·.language) == none &&
              cleared.toOption.isSome &&
              languageOf plain == none &&
              (match refused with
              | .error (.noSuchBuffer id) => id == ⟨9⟩
              | _ => false) &&
              same == state },
    { name := "a read hands back the whole state and changes nothing"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (read, after) := state.handle .read
            read == state && after == state },
    { name :=
        "a tab request is the change it carries (EditorState.changeTab), and a refused one leaves the state as it was"
      run :=
        pure <|
          match onTextModel threeTabs with
          | none => false
          | some state =>
            let (selected, after) := state.handle (.tab (.select 0))
            let (absent, same) := state.handle (.tab (.close 7))
            replied selected == .inr () && after == (state.changeTab (.select 0)).2 &&
              after.frame.tabIndex == 0 &&
              replied absent == .inl (.noSuchTab 7) &&
              same == state },
    { name :=
        "adding a buffer gives it the next slot's id and finds it by its name; a name a buffer has is refused with nameTaken, and a history over another text with notItsHistory, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let tree := UndoTree.new ⟨2⟩ 0
            let (added, after) := state.handle (.addBuffer "third" ⟨2⟩ tree)
            let (taken, same) := state.handle (.addBuffer "other" ⟨2⟩ tree)
            let (astray, still) := state.handle (.addBuffer "third" ⟨3⟩ tree)
            replied added == .inr ⟨2⟩ && after.findBuffer "third" == some ⟨2⟩ &&
              after.buffer? ⟨2⟩ == some { name := "third", text := ⟨2⟩, history := tree } &&
              state.findBuffer "third" == none &&
              state.findBuffer "other" == some ⟨1⟩ &&
              replied taken == .inl (.nameTaken "other") &&
              same == state &&
              replied astray == .inl .notItsHistory &&
              still == state },
    { name :=
        "renaming a buffer gives it the name, which then finds it; its own name changes nothing; a name another buffer has is refused with nameTaken, and a buffer there is none of with noSuchBuffer, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (renamed, after) := state.handle (.renameBuffer ⟨1⟩ "renamed")
            let (own, same) := state.handle (.renameBuffer ⟨1⟩ "other")
            let (taken, kept) := state.handle (.renameBuffer ⟨1⟩ EditorState.scratchName)
            let (absent, still) := state.handle (.renameBuffer ⟨9⟩ "x")
            replied renamed == .inr () && after.findBuffer "renamed" == some ⟨1⟩ &&
              after.findBuffer "other" == none &&
              replied own == .inr () &&
              same == state &&
              replied taken == .inl (.nameTaken EditorState.scratchName) &&
              kept == state &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              still == state },
    { name :=
        "removing a buffer empties its slot, and its id is not given to the next buffer; a buffer a window shows is refused with shown and that view, and one there is none of with noSuchBuffer, each with the state as it was"
      run :=
        pure <|
          match onTextModel hiddenBuffer with
          | none => false
          | some (state, _) =>
            let (removed, after) := state.handle (.removeBuffer ⟨2⟩)
            let (again, gone) := after.handle (.removeBuffer ⟨2⟩)
            let (next, _) := after.handle (.addBuffer "next" ⟨3⟩ (UndoTree.new ⟨3⟩ 0))
            let (shown, same) := state.handle (.removeBuffer ⟨1⟩)
            let (absent, still) := state.handle (.removeBuffer ⟨9⟩)
            replied removed == .inr () && after.buffers[2]? == some none &&
              after.buffer? ⟨2⟩ == none &&
              after.findBuffer "hidden" == none &&
              after.buffers.size == 3 &&
              replied again == .inl (.noSuchBuffer ⟨2⟩) &&
              gone == after &&
              replied next == .inr ⟨3⟩ &&
              replied shown == .inl (.shown ⟨1⟩) &&
              same == state &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              still == state },
    { name :=
        "setting a buffer's history replaces its tree; a tree over another text is refused with notItsHistory, and a buffer there is none of with noSuchBuffer, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let tree := UndoTree.new ⟨1⟩ 7
            let (set, after) := state.handle (.setHistory ⟨1⟩ tree)
            let (astray, same) := state.handle (.setHistory ⟨0⟩ tree)
            let (absent, still) := state.handle (.setHistory ⟨9⟩ tree)
            replied set == .inr () && (after.buffer? ⟨1⟩).map (·.history) == some tree &&
              after.buffer? ⟨0⟩ == state.buffer? ⟨0⟩ &&
              replied astray == .inl .notItsHistory &&
              same == state &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              still == state },
    { name :=
        "a buffer-local value is set under its name and read back, a second value of the name replaces the first, and other names and other buffers are left; a buffer there is none of is refused with noSuchBuffer"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (set, one) := state.handle (.setValue ⟨1⟩ "count" (.nat 1))
            let (_, two) := one.handle (.setValue ⟨1⟩ "label" (.str "a"))
            let (_, three) := two.handle (.setValue ⟨1⟩ "count" (.nat 2))
            let (absent, same) := state.handle (.setValue ⟨9⟩ "count" (.nat 1))
            replied set == .inr () && state.value? ⟨1⟩ "count" == none &&
              one.value? ⟨1⟩ "count" == some (.nat 1) &&
              three.value? ⟨1⟩ "count" == some (.nat 2) &&
              three.value? ⟨1⟩ "label" == some (.str "a") &&
              ((three.buffer? ⟨1⟩).map (·.locals.size)) == some 2 &&
              three.value? ⟨0⟩ "count" == none &&
              three.value? ⟨9⟩ "count" == none &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              same == state },
    { name :=
        "a buffer's spans are set, replacing those it had, and other buffers keep theirs; a buffer there is none of is refused with noSuchBuffer"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let spans : Array Decoration := #[{ start := 0, stop := 2, face := ⟨"a"⟩ }]
            let (set, one) := state.handle (.setSpans ⟨1⟩ spans)
            let (_, two) := one.handle (.setSpans ⟨1⟩ #[])
            let (absent, same) := state.handle (.setSpans ⟨9⟩ spans)
            replied set == .inr () && (state.buffer? ⟨1⟩).map (·.spans) == some #[] &&
              (one.buffer? ⟨1⟩).map (·.spans) == some spans &&
              (one.buffer? ⟨0⟩).map (·.spans) == some #[] &&
              (two.buffer? ⟨1⟩).map (·.spans) == some #[] &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              same == state },
    { name :=
        "the minor-mode requests are the state's operations: one added is first, one removed is gone, and a buffer there is none of is refused with noSuchBuffer"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (added, one) := state.handle (.addMinorMode ⟨0⟩ "one")
            let (removed, bare) := one.handle (.removeMinorMode ⟨0⟩ "one")
            let (absent, same) := state.handle (.addMinorMode ⟨9⟩ "one")
            replied added == .inr () && one == (state.addMinorMode ⟨0⟩ "one").2 &&
              ((one.buffer? ⟨0⟩).map (·.minors)) == some #["one"] &&
              replied removed == .inr () &&
              bare == state &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              same == state },
    { name :=
        "the major-mode request sets the mode of the buffer its view shows and says whether it became the major mode; a view with no window is refused with noSuchWindow, with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (set, listed) := state.handle (.setMajorMode ⟨1⟩ "listing")
            let (again, same) := listed.handle (.setMajorMode ⟨1⟩ "listing")
            let (absent, still) := state.handle (.setMajorMode ⟨9⟩ "listing")
            replied set == .inr true && listed == (state.setMajorMode ⟨1⟩ "listing").2 &&
              ((listed.buffer? ⟨1⟩).bind (·.major)) == some "listing" &&
              replied again == .inr false &&
              same == listed &&
              replied absent == .inl (.noSuchWindow ⟨9⟩) &&
              still == state },
    { name :=
        "a split gives the new window an id no window has or had, shows the source window's buffer in it with the markers handed in, puts it right after its source in the list, and leaves the focus"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            let (made, after) := state.handle (.split ⟨1⟩ (marker 0 8) (marker 0 9))
            let (closed, without) := after.handle (.removeWindow ⟨3⟩)
            let (next, later) := without.handle (.split ⟨0⟩ (marker 0 10) (marker 0 11))
            replied made == .inr ⟨3⟩ && after.wellFormed &&
              after.window? ⟨3⟩ ==
                some { id := ⟨3⟩, buffer := ⟨0⟩, scroll := marker 0 8, selection := marker 0 9 } &&
              after.frame.windows == #[⟨0⟩, ⟨1⟩, ⟨3⟩, ⟨2⟩] &&
              after.frame.focused == state.frame.focused &&
              after.windows.extract 0 3 == state.windows &&
              (replied closed).isRight &&
              replied next == .inr ⟨4⟩ &&
              without.frame.windows == state.frame.windows &&
              later.frame.windows == #[⟨0⟩, ⟨4⟩, ⟨1⟩, ⟨2⟩] &&
              later.frame.focused == state.frame.focused },
    { name :=
        "a split is refused with noSuchWindow for a view with no window, and with markersOfAnotherText when a marker handed in is not of the source buffer's text, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (absent, same) := state.handle (.split ⟨9⟩ (marker 0 8) (marker 0 9))
            let (scroll, still) := state.handle (.split ⟨0⟩ (marker 1 8) (marker 0 9))
            let (selection, yet) := state.handle (.split ⟨0⟩ (marker 0 8) (marker 1 9))
            replied absent == .inl (.noSuchWindow ⟨9⟩) && same == state &&
              replied scroll == .inl .markersOfAnotherText &&
              still == state &&
              replied selection == .inl .markersOfAnotherText &&
              yet == state },
    { name :=
        "splitting a window and removing the new window gives back the frame, its windows and the focus from before the split, from one window or three, whichever window is focused"
      run :=
        pure <|
          [onTextModel threeWindows, onTextModel (EditorState.initial ⟨640, 480⟩)].all fun
            | none => false
            | some start =>
              start.frame.windows.all fun focused =>
                let state := (start.focusWindow focused).2
                state.windows.all fun window =>
                  let (made, split) := state.handle (.split window.id (marker 0 8) (marker 0 9))
                  match made with
                  | .error _ => false
                  | .ok view =>
                    let (closed, after) := split.handle (.removeWindow view)
                    split.frame.windows != state.frame.windows && (replied closed).isRight &&
                      after.frame == state.frame &&
                      after.windows == state.windows &&
                      after.buffers == state.buffers },
    { name :=
        "the request to remove the only window is refused with onlyWindow, and the frame and the state are as they were"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            let (closed, after) := state.handle (.removeWindow ⟨0⟩)
            replied closed == .inl .onlyWindow && after.frame == state.frame && after == state },
    { name :=
        "the focus request focuses a window in the list, and refuses one that is not with noSuchWindow"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            let (focused, after) := state.handle (.focus ⟨2⟩)
            let (absent, same) := state.handle (.focus ⟨9⟩)
            replied focused == .inr () && after.frame.focused == ⟨2⟩ &&
              after == (state.focusWindow ⟨2⟩).2 &&
              replied absent == .inl (.noSuchWindow ⟨9⟩) &&
              same == state },
    { name :=
        "showing another buffer in a window sets its buffer and its markers and leaves the other windows; a buffer there is none of is refused with noSuchBuffer, a view with no window with noSuchWindow, and a marker of another text with markersOfAnotherText, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (shown, after) := state.handle (.show ⟨0⟩ ⟨1⟩ (marker 1 8) (marker 1 9))
            let (absent, same) := state.handle (.show ⟨0⟩ ⟨9⟩ (marker 1 8) (marker 1 9))
            let (unseen, still) := state.handle (.show ⟨9⟩ ⟨1⟩ (marker 1 8) (marker 1 9))
            let (astray, yet) := state.handle (.show ⟨0⟩ ⟨1⟩ (marker 0 8) (marker 1 9))
            replied shown == .inr () && after.wellFormed &&
              after.window? ⟨0⟩ ==
                some { id := ⟨0⟩, buffer := ⟨1⟩, scroll := marker 1 8, selection := marker 1 9 } &&
              after.window? ⟨1⟩ == state.window? ⟨1⟩ &&
              after.frame == state.frame &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              same == state &&
              replied unseen == .inl (.noSuchWindow ⟨9⟩) &&
              still == state &&
              replied astray == .inl .markersOfAnotherText &&
              yet == state },
    { name :=
        "the wanted-column request is the state's operation: the window keeps the column and the head, none clears it, and a view with no window is refused with noSuchWindow, with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let kept : Window.Wanted := { column := .goal 3, head := 7 }
            let (set, after) := state.handle (.setWanted ⟨1⟩ (some kept))
            let (cleared, bare) := after.handle (.setWanted ⟨1⟩ none)
            let (absent, same) := state.handle (.setWanted ⟨9⟩ (some kept))
            replied set == .inr () && after == (state.setWanted ⟨1⟩ (some kept)).2 &&
              (after.window? ⟨1⟩).map (·.wanted) == some (some kept) &&
              after.window? ⟨0⟩ == state.window? ⟨0⟩ &&
              replied cleared == .inr () &&
              bare == state &&
              replied absent == .inl (.noSuchWindow ⟨9⟩) &&
              same == state },
    { name :=
        "the jump and mark requests are the state's operations: setJumps a window's jumps, setLocalMark a buffer's mark and setGlobalMark a global mark, each refused as its operation refuses, with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let jumps : Jumps :=
              { list := { entries := #[.held ⟨1⟩ (marker 1 5)], index := 1 }
                previous := some (.held ⟨1⟩ (marker 1 5)) }
            let (set, after) := state.handle (.setJumps ⟨1⟩ jumps)
            let (absent, same) := state.handle (.setJumps ⟨9⟩ jumps)
            let (marked, withMark) := state.handle (.setLocalMark ⟨1⟩ 'a' (some (marker 1 6)))
            let (noBuffer, same2) := state.handle (.setLocalMark ⟨9⟩ 'a' (some (marker 1 6)))
            let (global, withGlobal) :=
              state.handle (.setGlobalMark 'A' (some (.held ⟨0⟩ (marker 0 6))))
            let (astray, same3) := state.handle (.setGlobalMark 'A' (some (.held ⟨0⟩ (marker 1 6))))
            replied set == .inr () && after == (state.setJumps ⟨1⟩ jumps).2 &&
              replied absent == .inl (.noSuchWindow ⟨9⟩) &&
              same == state &&
              replied marked == .inr () &&
              withMark == (state.setLocalMark ⟨1⟩ 'a' (some (marker 1 6))).2 &&
              replied noBuffer == .inl (.noSuchBuffer ⟨9⟩) &&
              same2 == state &&
              replied global == .inr () &&
              withGlobal == (state.setGlobalMark 'A' (some (.held ⟨0⟩ (marker 0 6)))).2 &&
              replied astray == .inl .markerOfAnotherText &&
              same3 == state },
    { name := "a message sets the echo area's text, and the last of two is the one kept"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let ((), one) := state.handle (.message "first")
            let ((), two) := one.handle (.message "second")
            one == { state with echo := "first" } && two == { state with echo := "second" } },
    { name :=
        "a request to start a job is appended to the state's starts, with its name and its arguments, in order"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (first, one) := state.handle (.startJob "count" [.nat 3])
            let (_, two) := one.handle (.startJob "load" [.str "a", .bool true])
            replied first == .inr () && state.outbox.starts == #[] &&
              two.outbox.starts ==
                #[{ name := "count", arguments := [.nat 3] },
                  { name := "load", arguments := [.str "a", .bool true] }] &&
              { two with outbox.starts := #[] } == state },
    { name :=
        "a request to start a job with a key keeps the key with the start, and a request to cancel a key is appended to the state's cancels, in order, and changes nothing else"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (started, one) := state.handle (.startJob "count" [.nat 3] (some "k"))
            let ((), two) := one.handle (.cancelJob "k")
            let ((), three) := two.handle (.cancelJob "j")
            replied started == .inr () && state.outbox.cancels == #[] &&
              one.outbox.starts == #[{ name := "count", arguments := [.nat 3], key := some "k" }] &&
              three.outbox.cancels == #["k", "j"] &&
              { three with outbox.cancels := #[] } == one },
    { name :=
        "attaching a file to a buffer sets its path, its stamp and its line ending, with no save in flight, and leaves the rest of the buffer and the other buffers; the buffer is then found by that path and by no other"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (attached, after) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            replied attached == .inr () &&
              (after.buffer? ⟨1⟩) ==
                (state.buffer? ⟨1⟩).map
                  ({ · with
                    file := some { path := notePath, stamp := noteStamp }, lineEnding := .crlf }) &&
              ((after.buffer? ⟨1⟩).bind (·.file)).map (·.saving) == some none &&
              after.buffer? ⟨0⟩ == state.buffer? ⟨0⟩ &&
              after.findFile notePath == some ⟨1⟩ &&
              after.findFile "/files/other.txt" == none &&
              after.findFile "/files/../files/note.txt" == none &&
              state.findFile notePath == none &&
              { after with buffers := state.buffers } == state },
    { name :=
        "attaching a file is refused with noSuchBuffer for a buffer there is none of, and with fileOpen and the buffer that holds the path when another buffer does, each with the state as it was; attaching the path a buffer holds to that buffer again replaces its stamp and its line ending"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let later : File.Stamp :=
              { noteStamp with
                seconds := 9, size := 12 }
            let (_, held) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            let (absent, same) := state.handle (.attachFile ⟨9⟩ notePath noteStamp .lf)
            let (taken, still) := held.handle (.attachFile ⟨0⟩ notePath later .lf)
            let (unseen, yet) := held.handle (.attachFile ⟨9⟩ notePath later .lf)
            let (again, replaced) := held.handle (.attachFile ⟨1⟩ notePath later .lf)
            replied absent == .inl (.noSuchBuffer ⟨9⟩) && same == state &&
              replied taken == .inl (.fileOpen ⟨1⟩) &&
              still == held &&
              replied unseen == .inl (.noSuchBuffer ⟨9⟩) &&
              yet == held &&
              replied again == .inr () &&
              ((replaced.buffer? ⟨1⟩).map fun buffer => (buffer.file, buffer.lineEnding)) ==
                some (some { path := notePath, stamp := later }, .lf) &&
              replaced.findFile notePath == some ⟨1⟩ },
    { name :=
        "beginning a save of a buffer with a file records the snapshot and the state as the save in flight and leaves the rest; it is refused with noFile for a buffer with no file, with beingSaved while a save is in flight and with noSuchBuffer, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, held) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            let (begun, saving) := held.handle (.beginSave ⟨1⟩ ⟨5⟩ ⟨3⟩)
            let (bare, same) := held.handle (.beginSave ⟨0⟩ ⟨5⟩ ⟨3⟩)
            let (twice, still) := saving.handle (.beginSave ⟨1⟩ ⟨6⟩ ⟨4⟩)
            let (absent, yet) := held.handle (.beginSave ⟨9⟩ ⟨5⟩ ⟨3⟩)
            replied begun == .inr () &&
              (saving.buffer? ⟨1⟩) ==
                (held.buffer? ⟨1⟩).map
                  ({ · with
                    file :=
                      some
                        { path := notePath, stamp := noteStamp
                          saving := some { snapshot := ⟨5⟩, state := ⟨3⟩ } } }) &&
              { saving with buffers := held.buffers } == held &&
              replied bare == .inl .noFile &&
              same == held &&
              replied twice == .inl .beingSaved &&
              still == saving &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              yet == held },
    { name :=
        "ending a save with a stamp clears the save in flight, records the stamp, and marks the state the save kept as saved: a buffer still in that state is no longer modified, and one whose text has moved on since still is; ending it with no stamp clears the save in flight and changes neither the stamp nor the saved state"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let later : File.Stamp :=
              { noteStamp with
                seconds := 9, size := 12 }
            let edited := (UndoTree.new ⟨1⟩ 0).record 3
            let (_, held) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            let (_, held) := held.handle (.setHistory ⟨1⟩ edited)
            let (_, saving) := held.handle (.beginSave ⟨1⟩ ⟨5⟩ edited.state)
            let (ended, saved) := saving.handle (.endSave ⟨1⟩ ⟨5⟩ (some later))
            let (_, moved) := saving.handle (.setHistory ⟨1⟩ (edited.record 4))
            let (_, late) := moved.handle (.endSave ⟨1⟩ ⟨5⟩ (some later))
            let (refused, unsaved) := saving.handle (.endSave ⟨1⟩ ⟨5⟩ none)
            let seen (state : EditorState) :=
              (state.buffer? ⟨1⟩).map fun buffer =>
                (buffer.file, buffer.isModified, buffer.history.saved)
            seen held == some (some { path := notePath, stamp := noteStamp }, true, some ⟨0⟩) &&
              replied ended == .inr () &&
              seen saved == some (some { path := notePath, stamp := later }, false, some ⟨3⟩) &&
              (saved.buffer? ⟨1⟩).map (·.history) == some (edited.markSaved edited.state) &&
              { saved with buffers := held.buffers } == held &&
              seen late == some (some { path := notePath, stamp := later }, true, some ⟨3⟩) &&
              replied refused == .inr () &&
              unsaved == held },
    { name :=
        "ending a save with no stamp withdraws a quit that was asked: the state is no longer asked to quit, whether or not the buffer is modified, and is otherwise as it was before the save began; ending it with a stamp leaves the state asked"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let asked (state : EditorState) : EditorState := { state with quitting := true }
            let edited := (UndoTree.new ⟨1⟩ 0).record 3
            let (_, clean) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            let (_, held) := clean.handle (.setHistory ⟨1⟩ edited)
            let ends (held : EditorState) (stamp : Option File.Stamp) : EditorState :=
              let history := ((held.buffer? ⟨1⟩).map (·.history.state)).getD ⟨0⟩
              let (_, saving) := held.handle (.beginSave ⟨1⟩ ⟨5⟩ history)
              ((asked saving).handle (.endSave ⟨1⟩ ⟨5⟩ stamp)).2
            (clean.buffer? ⟨1⟩).map (·.isModified) == some false &&
              (held.buffer? ⟨1⟩).map (·.isModified) == some true &&
              ends clean none == clean &&
              ends held none == held &&
              (ends clean (some noteStamp)).quitting &&
              (ends held (some noteStamp)).quitting },
    { name :=
        "ending a save is refused with notBeingSaved for a snapshot that is not the one of the save in flight, for a buffer with no save in flight and for one with no file, and with noSuchBuffer, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, held) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            let (_, saving) := held.handle (.beginSave ⟨1⟩ ⟨5⟩ ⟨3⟩)
            let (other, same) := saving.handle (.endSave ⟨1⟩ ⟨6⟩ (some noteStamp))
            let (idle, still) := held.handle (.endSave ⟨1⟩ ⟨5⟩ (some noteStamp))
            let (bare, yet) := saving.handle (.endSave ⟨0⟩ ⟨5⟩ none)
            let (absent, last) := saving.handle (.endSave ⟨9⟩ ⟨5⟩ none)
            replied other == .inl .notBeingSaved && same == saving &&
              replied idle == .inl .notBeingSaved &&
              still == held &&
              replied bare == .inl .notBeingSaved &&
              yet == saving &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              last == saving },
    { name :=
        "the request to open a prompt is the state's operation: it replies the minibuffer's view and leaves the prompt open, and a second is refused with alreadyOpen, a value, with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let request : StateRequest :=
              .openPrompt "Name: " asked ⟨7⟩ (UndoTree.new ⟨7⟩ 0) (marker 7 0) (marker 7 1)
            let (made, asking) := state.handle request
            let (again, same) := asking.handle request
            replied made == .inr ⟨2⟩ && asking == (prompted state).2 && asking.prompt.isSome &&
              replied again == .inl (.alreadyOpen ⟨2⟩) &&
              same == asking },
    { name :=
        "the request to close a prompt is the state's operation, with an answer and with none, and with no prompt open it is refused with notOpen, a value"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, asking) := prompted state
            let (cancelled, without) := asking.handle (.closePrompt none)
            let (accepted, answered) := asking.handle (.closePrompt (some "a"))
            let (refused, same) := state.handle (.closePrompt (some "a"))
            replied cancelled == .inr () && without == (asking.closePrompt none).2 &&
              without.prompt == none &&
              replied accepted == .inr () &&
              answered == (asking.closePrompt (some "a")).2 &&
              answered.outbox.answered.size == 1 &&
              replied refused == .inl .notOpen &&
              same == state },
    { name :=
        "the requests to set an open prompt's candidates and to choose among its listing are the state's operations, and with no prompt open each is refused with notOpen, a value, with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, asking) := prompted state
            let listed := picking asking
            let (set, replaced) := listed.handle (.setCandidates { all := offered #["x"] })
            let (next, first) := listed.handle (.chooseCandidate .next)
            let (previous, last) := listed.handle (.chooseCandidate .previous)
            let (noSet, sameSet) := state.handle (.setCandidates { all := offered #["x"] })
            let (noChoice, sameChoice) := state.handle (.chooseCandidate .next)
            replied set == .inr () &&
              replaced == (listed.setCandidates { all := offered #["x"] }).2 &&
              replaced.prompt.map (·.candidates) == some { all := offered #["x"] } &&
              replied next == .inr () &&
              first == (listed.chooseCandidate .next).2 &&
              first.prompt.map (·.candidates.chosen) == some (some 0) &&
              replied previous == .inr () &&
              last == (listed.chooseCandidate .previous).2 &&
              last.prompt.map (·.candidates.chosen) == some (some 2) &&
              replied noSet == .inl .notOpen &&
              sameSet == state &&
              replied noChoice == .inl .notOpen &&
              sameChoice == state },
    { name :=
        "a batch is taken for the open prompt's view, the asking source of its index and that source's generation: the first of a generation replaces what the source answered, a later one appends, each candidate in the source's group, and each bumps the revision; a batch for another view, another index or another generation, or with no prompt open, is dropped with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            match prompted state with
            | (.ok view, asking) =>
              let source : Completion.Asking :=
                { source := "later", later := { job := "j" }, askedFor := "", generation := 1
                  answered := offered #["old"] }
              let (_, set) := asking.setCandidates { asking := #[source] }
              let grouped (texts : Array String) : Array Completion.Candidate :=
                (offered texts).map (·.inGroup "later")
              let held (state : EditorState) : Option (Array (Array Completion.Candidate) × Nat) :=
                state.prompt.map fun asked =>
                  (asked.candidates.asking.map (·.answered), asked.candidates.revision)
              let (first, one) := set.handle (.addCandidates view 0 1 (offered #["a"]))
              let (second, two) := one.handle (.addCandidates view 0 1 (offered #["b"]))
              let (otherView, sameView) :=
                two.handle (.addCandidates ⟨view.index + 1⟩ 0 1 (offered #["x"]))
              let (otherIndex, sameIndex) := two.handle (.addCandidates view 1 1 (offered #["x"]))
              let (otherGeneration, sameGeneration) :=
                two.handle (.addCandidates view 0 2 (offered #["x"]))
              let (closed, sameClosed) := state.handle (.addCandidates view 0 1 (offered #["x"]))
              first && second && held set == some (#[offered #["old"]], 0) &&
                held one == some (#[grouped #["a"]], 1) &&
                held two == some (#[grouped #["a", "b"]], 2) &&
                !otherView &&
                sameView == two &&
                !otherIndex &&
                sameIndex == two &&
                !otherGeneration &&
                sameGeneration == two &&
                !closed &&
                sameClosed == state
            | _ => false },
    { name :=
        "a source's job's end marks the source done: a generation that delivered nothing clears what the source answered and bumps the revision, and one that delivered keeps it; for another generation, or with no prompt open, nothing changes"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            match prompted state with
            | (.ok view, asking) =>
              let source : Completion.Asking :=
                { source := "later", later := { job := "j" }, askedFor := "", generation := 1
                  answered := offered #["old"] }
              let (_, set) := asking.setCandidates { asking := #[source] }
              let (_, one) := set.handle (.addCandidates view 0 1 (offered #["a"]))
              let (_, cleared) := set.handle (.sourceAnswered view 0 1)
              let (_, kept) := one.handle (.sourceAnswered view 0 1)
              let (_, stale) := one.handle (.sourceAnswered view 0 2)
              let (_, closed) := state.handle (.sourceAnswered view 0 1)
              let held (state : EditorState) : Option (Array (Array String × Bool) × Nat) :=
                state.prompt.map fun asked =>
                  (asked.candidates.asking.map fun source =>
                      (source.answered.map (·.text), source.done),
                    asked.candidates.revision)
              held cleared == some (#[(#[], true)], 1) &&
                held kept == some (#[(#["a"], true)], 1) &&
                stale == one &&
                closed == state
            | _ => false },
    { name :=
        "a match is listed only for the open prompt's view and the pattern and revision of the match in flight: the listing is the one delivered, for that pattern, the choice kept on its candidate, and nothing is in flight after it; a delivery for another view, pattern or revision changes nothing"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            match prompted state with
            | (.ok view, asking) =>
              let listing (texts : Array String) : Array Completion.Listed :=
                (offered texts).map Completion.Listed.of
              let waiting :=
                withCandidates asking
                  { all := offered #["wq", "w"], listedFor := some "w",
                    listed := listing #["w", "wq"]
                    chosen := some 1, revision := 2
                    matching := some { pattern := "w", revision := 2, generation := 0 } }
              let (_, matched) := waiting.handle (.listMatched view "w" 2 (listing #["wq", "w"]))
              let (_, otherPattern) := waiting.handle (.listMatched view "x" 2 (listing #["wq"]))
              let (_, otherRevision) := waiting.handle (.listMatched view "w" 1 (listing #["wq"]))
              let (_, otherView) :=
                waiting.handle (.listMatched ⟨view.index + 1⟩ "w" 2 (listing #["wq"]))
              matched.prompt.map (·.candidates) ==
                  some
                    { all := offered #["wq", "w"], listedFor := some "w"
                      listed := listing #["wq", "w"], chosen := some 0, revision := 2
                      listedAt := 2 } &&
                otherPattern == waiting &&
                otherRevision == waiting &&
                otherView == waiting
            | _ => false },
    { name :=
        "a match that failed, for the match in flight, ends it, records its pattern and revision as unmatched and says `completion-match: ` and why in the echo area, leaving the listing as it was; for any other match nothing changes"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            match prompted state with
            | (.ok view, asking) =>
              let waiting :=
                withCandidates asking
                  { all := offered #["wq", "w"], revision := 2
                    matching := some { pattern := "w", revision := 2, generation := 0 } }
              let (_, failed) := waiting.handle (.matchFailed view "w" 2 "broken")
              let (_, other) := waiting.handle (.matchFailed view "w" 1 "broken")
              failed.prompt.map (·.candidates) ==
                  some { all := offered #["wq", "w"], revision := 2, unmatched := some ("w", 2) } &&
                failed.echo == "completion-match: broken" &&
                other == waiting
            | _ => false },
    { name :=
        "asked to load a theme, the handler takes any name and keeps the latest until the loop takes it out"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (first, loaded) := state.handle (.loadTheme "first")
            let (second, again) := loaded.handle (.loadTheme "second")
            replied first == .inr () && replied second == .inr () &&
              loaded == { state with outbox.theme := some "first" } &&
              again == { state with outbox.theme := some "second" } },
    { name :=
        "the request to have an invocation run next records it after what is recorded, the answer of a prompt that was closed among it, and changes nothing else"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let first : Invocation := { command := "one", arguments := [.str "a"] }
            let second : Invocation := { command := "two" }
            let (_, once) := state.handle (.invoke first)
            let (_, twice) := once.handle (.invoke second)
            let (_, asking) := prompted state
            let (_, answered) := asking.handle (.closePrompt (some "typed"))
            let (_, after) := answered.handle (.invoke second)
            once.outbox.answered == #[first] && twice.outbox.answered == #[first, second] &&
              { twice with outbox.answered := #[] } == state &&
              after.outbox.answered == answered.outbox.answered.push second &&
              answered.outbox.answered.size == 1 },
    { name :=
        "the request to quit sets the state's flag that the editor was asked to quit and changes nothing else; asked again, the state is as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, asked) := state.handle .quit
            let (_, again) := asked.handle .quit
            !state.quitting && asked.quitting && { asked with quitting := false } == state &&
              again == asked },
    { name :=
        "the request to reload the config sets the state's flag that a reload was asked for and changes nothing else"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, asked) := state.handle .reload
            !state.outbox.reload && asked.outbox.reload &&
              { asked with outbox.reload := false } == state },
    { name :=
        "the request to set a register sets the register of that name, in place of the one the name had, and changes nothing else of the state"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let word : Register := { text := "word" }
            let line : Register := { text := "a line\n", linewise := true }
            let (_, set) := state.handle (.setRegister "a" word)
            let (_, replaced) := set.handle (.setRegister "a" line)
            state.register? "a" == none && set.register? "a" == some word &&
              set == state.setRegister "a" word &&
              replaced.register? "a" == some line &&
              { replaced with remembered.registers := #[] } == state },
    { name :=
        "the request to set the scroll margin sets the state's margin, in place of the one it had, and changes nothing else of the state: with no prompt open and with one open, and in the state with nothing in it"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            [state, (prompted state).2, EditorState.none].all fun start =>
              let (_, set) := start.handle (.setScrollMargin 2)
              let (_, replaced) := set.handle (.setScrollMargin 7)
              start.scrollMargin == 0 && set == start.setScrollMargin 2 && set.scrollMargin == 2 &&
                replaced.scrollMargin == 7 &&
                { replaced with scrollMargin := 0 } == start },
    { name :=
        "every kind of request, accepted and refused, leaves a well-formed state well formed, with no prompt open and with one open, with no float and with a transient float at a position and a pinned one, and the state with nothing in it answers each without a buffer or a window"
      run := do
        let some (state, _) := onTextModel hiddenBuffer | return false
        let some floated :=
          onTextModel do
            withFloats (← hiddenBuffer).1 [(.position ⟨1⟩ (marker 1 2), false), (.frame, true)]
          | return false
        let (_, asking) := prompted state
        let (_, floatAsking) := prompted floated
        let spoiled :=
          [state, asking, floated, floatAsking].flatMap fun start =>
            stateRequests.filter fun request => !(start.handle request).2.wellFormed
        unless spoiled.isEmpty do
          throw
              (IO.userError
                s!"{spoiled.length} of the requests left a state that is not well formed")
        let (read, _) := EditorState.none.handle .read
        return state.wellFormed && asking.wellFormed && asking.prompt.isSome &&
            floated.wellFormed &&
            floated.frame.floats.size == 2 &&
            read.buffers.isEmpty &&
            read.windows.isEmpty &&
            stateRequests.all fun request =>
              let (_, after) := EditorState.none.handle request
              after.windows.isEmpty && after.frame == EditorState.none.frame },
    { name :=
        "the arrange request reaches the state's arrange, and a refused one leaves the state; the split request's placement reaches the split"
      run :=
        pure <|
          match onTextModel threeWindows, onTextModel (windowsUnder 1 Layout.manual) with
          | some state, some manual =>
            let (promoted, after) := state.handle (.arrange ⟨2⟩ .promote)
            let (absent, same) := state.handle (.arrange ⟨9⟩ .zoom)
            let (made, split) :=
              manual.handle
                (.split ⟨0⟩ (marker 0 8) (marker 0 9) { axis := .columns, before := true })
            replied promoted == .inr () && after == (state.arrange ⟨2⟩ .promote).2 &&
              after.frame.windows == #[⟨2⟩, ⟨0⟩, ⟨1⟩] &&
              replied absent == .inl (.noSuchWindow ⟨9⟩) &&
              same == state &&
              replied made == .inr ⟨1⟩ &&
              split.frame.windows == #[⟨1⟩, ⟨0⟩] &&
              split.frame.layout == .splits (.split .columns 1 1 .tile .tile)
          | _, _ => false },
    { name :=
        "the openWindow request reaches the state's openWindow with its spot, and a refused one leaves the state"
      run :=
        pure <|
          match onTextModel sidebar with
          | none => false
          | some state =>
            let (stacked, after) := state.handle (.openWindow ⟨0⟩ (marker 0 8) (marker 0 9) .stack)
            let (docked, edged) :=
              state.handle (.openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.edge .left))
            let (absent, same) :=
              state.handle (.openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.edge .top))
            replied stacked == .inr ⟨3⟩ &&
              after == (state.openWindow ⟨0⟩ (marker 0 8) (marker 0 9) .stack).2 &&
              after.frame.windows == #[⟨0⟩, ⟨1⟩, ⟨3⟩] &&
              replied docked == .inr ⟨3⟩ &&
              edged.frame.docked == #[(⟨2⟩, .left), (⟨3⟩, .left)] &&
              replied absent == .inl (.noSuchEdge .top) &&
              same == state },
    { name :=
        "the openWindow request with a float spot reaches the state's openWindow, and the arrange request's float reaches its arrange; a refused one leaves the state"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let spot : WindowSpot := .float (.window ⟨1⟩) { width := 50 } true
            let (opened, after) := state.handle (.openWindow ⟨0⟩ (marker 0 8) (marker 0 9) spot)
            let (floated, moved) := state.handle (.arrange ⟨1⟩ .float)
            let (absent, same) :=
              state.handle
                (.openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.float (.window ⟨9⟩) {} false))
            let (last, kept) := (moved.handle (.arrange ⟨0⟩ .float))
            replied opened == .inr ⟨2⟩ &&
              after == (state.openWindow ⟨0⟩ (marker 0 8) (marker 0 9) spot).2 &&
              after.frame.floats.map (·.view) == #[⟨2⟩] &&
              replied floated == .inr () &&
              moved == (state.arrange ⟨1⟩ .float).2 &&
              moved.frame.floats.map (·.view) == #[⟨1⟩] &&
              replied absent == .inl (.noSuchWindow ⟨9⟩) &&
              same == state &&
              replied last == .inl .lastTile &&
              kept == moved }]

end ModelTest
