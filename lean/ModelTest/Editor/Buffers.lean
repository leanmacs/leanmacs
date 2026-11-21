import Editor.Buffers
import Editor.Command.Model
import Editor.Completion.Candidate
import Editor.Display.Model
import Editor.Event
import Editor.File
import Editor.File.Cases
import Editor.Fuzzy.Model
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job.Contract
import Editor.Layout
import Editor.Loop
import Editor.Loop.Driver
import Editor.ModeLine
import Editor.Scene
import Editor.State
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Keys
import Editor.Test.Opener
import Editor.Test.Prompts
import Editor.Text
import Editor.Text.Model
import ModelTest.Check
import ModelTest.Support.Buffers

/-!
# Model tests: `Editor/Buffers.lean`

The model tests of `Editor/Buffers.lean`: `bufferCommandChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The buffer's fields of the status line of the view `view` in the last
scene `driver`'s display recorded, a view that is not selected: what
`statusOf` reads of a selected view, for a view every field of which is in
`ModeLine.inactiveFace` (`ModeLine.fields`). The faces no longer tell the
buffer's fields from the others, so they are told by their text: the
buffer's name `name`, the modified mark and the changed mark
(`ModeLine.modifiedMark`, `ModeLine.changedMark`), each on the left. A
position field on the right, such as `1:1` or `All`, is not one of them. -/
def inactiveStatusOf (driver : TestDriver) (view : ViewId) (name : String) :
    Option (Array StatusField) :=
  driver.model.display.scenes.back?.bind fun scene =>
    (scene.views.find? (·.id == view)).map fun view =>
      view.status.filter fun field =>
        field.face == ModeLine.inactiveFace && field.side == .left &&
          [name, ModeLine.modifiedMark, ModeLine.changedMark].contains field.text

/-- The buffer called `name` in `driver`'s state. -/
def bufferNamed (driver : TestDriver) (name : String) : Option BufferId :=
  driver.loop.state.findBuffer name

/-- The checks of the buffer commands (`Editor/Buffers.lean`,
`Editor/Buffers/Compiled.lean`) and the ex names `b`, `ls` and `bd`, on the
loop's driver over the editor's models, the model of files and the test
scheme. Each message is read from the function that makes it, and an order
the fuzzy matcher decides is computed with its model. -/
def bufferCommandChecks : List Check :=
  [{  name :=
        "closing a buffer shown only in a hidden tab's window shows the fallback there and removes the buffer; the tab in view stays in view"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (tabbed, _) := fedTo opened (presses "C-b t" ++ exLine "b scratch")
            let hidden := tabbed.loop.state.frame.tabsAfter.flatMap (·.windows)
            let (closed, _) := fedTo tabbed (exLine "bd lf.txt")
            let state := closed.loop.state
            hidden.size == 1 && (hidden.all fun view => shownName tabbed view == some "lf.txt") &&
              shownName tabbed == some "scratch" &&
              state.findBuffer "lf.txt" == none &&
              state.frame.tabIndex == 0 &&
              (hidden.all fun view => (shownName closed view).any (· != "lf.txt")) &&
              state.wellFormed },
    { name :=
        "b with no argument opens a prompt labelled with the switch prompt's label, whose continuation is switch-buffer, and whose candidates are the open buffers' names, most recently used first and the asking window's buffer last, without the minibuffer's; called with a count and a register, as a key under the Vim scheme calls it, it asks the same"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let asked (events : List Event) : Bool :=
              let (asking, _) := fedTo opened events
              let state := asking.loop.state
              let minibuffer := (state.minibufferBuffer?.bind state.buffer?).map (·.name)
              state.prompt.map (fun asked => (asked.label, asked.continuation)) ==
                  some (Buffers.switchPrompt, { command := Buffers.switchName }) &&
                (candidatesOf asking).map (·.all.map (·.text)) ==
                  some #["crlf.txt", "note.txt", "scratch", "lf.txt"] &&
                minibuffer.isSome &&
                !((candidatesOf asking).any fun candidates =>
                    minibuffer.any (candidates.all.map (·.text)).contains)
            asked (exLine "b") && asked (presses "C-b b") },
    { name :=
        "a pattern typed after b and accepted with nothing chosen shows the best match in the window: its status line names it and it is the most recently used; where more than one buffer matches, the one the fuzzy model ranks first over the names in the switch prompt's order, the window's own buffer last, so the first the prompt would list"
      run :=
        pure <|
          match buffersOpen, buffersOpen.bind (showing ·) with
          | some opened, some shown =>
            let (switched, _) := fedTo opened (exLine "b nte")
            let names := Buffers.candidates opened.loop.state shown.id
            let best := (FuzzyModel.rank "txt" names)[0]?.bind (names[·]?)
            let (several, _) := fedTo opened (exLine "b txt")
            shownName switched == some "note.txt" && statusOf switched == some (named "note.txt") &&
              switched.loop.state.recent[0]? == bufferNamed switched "note.txt" &&
              switched.loop.state.prompt == none &&
              best.isSome &&
              shownName several == best
          | _, _ => false },
    { name :=
        "a candidate chosen with the minibuffer's next command and accepted is the buffer shown"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (chosen, _) := fedTo opened (exLine "b" ++ presses "C-e t")
            let (switched, _) := fedTo chosen (presses "C-e y")
            let expected := (candidatesOf chosen).bind (·.listed[0]?.map (·.text))
            expected.isSome && (candidatesOf chosen).bind (·.chosen) == some 0 &&
              shownName switched == expected &&
              switched.loop.state.prompt == none },
    { name :=
        "b with an exact name switches with no prompt; b with a pattern nothing matches leaves the window as it was and says so by the switch command's message"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (exact, _) := fedTo opened (exLine "b scratch")
            let (missed, _) := fedTo opened (exLine "b zzz")
            shownName exact == some "scratch" && exact.loop.state.prompt == none &&
              shownName missed == some "lf.txt" &&
              promptEcho missed == Buffers.noMatch "zzz" &&
              missed.loop.state.wellFormed },
    { name :=
        "switch-buffer called with a name from the minibuffer's view shows the buffer in the window the prompt was asked from, and the prompt stays open"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (asking, _) := fedTo opened (presses "C-e e")
            let (switched, _) := fedTo asking (presses "C-b n")
            asking.loop.state.minibufferView? == some asking.loop.state.frame.focused &&
              shownName switched == some "note.txt" &&
              switched.loop.state.prompt.isSome &&
              switched.loop.state.wellFormed },
    { name :=
        "ls shows, in a new window at the end of the list, focused, a buffer called buffer-list with no file, whose text is one line per open buffer, most recently used first, + for unsaved changes and the path of a buffer with a file; the minibuffer and the list itself are not in it, and the modified scratch buffer, which holds no file, has no +; the window it was called in keeps its buffer"
      run :=
        pure <|
          match buffersDriver with
          | none => false
          | some driver =>
            let opened := threeOpen (fedTo driver [.commit "typed"]).1
            let (listed, _) := fedTo opened (exLine "b note.txt" ++ [.commit "x"] ++ exLine "ls")
            let path (name : String) : String := (inFiles name).toString
            let expected :=
              s!"+ note.txt  {path "note.txt"}\n  lf.txt  {path "lf.txt"}\n  crlf.txt  {path "crlf.txt"}\n  scratch\n"
            let state := listed.loop.state
            let list := showing listed state.frame.focused
            (list.map fun shown => (shown.buffer.name, shown.buffer.file.isNone)) ==
                some (Buffers.listBuffer, true) &&
              list.bind (·.text) == some expected &&
              state.frame.windows.size == 2 &&
              state.frame.windows.back? == some state.frame.focused &&
              state.frame.focused != ⟨0⟩ &&
              shownName listed ⟨0⟩ == some "note.txt" &&
              state.wellFormed },
    { name :=
        "ls again replaces the list's text and makes no second buffer: after note.txt is saved its line has no +"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (first, _) := fedTo opened (exLine "b note.txt" ++ [.commit "x"] ++ exLine "ls")
            let (saved, _) := fedTo first (exLine "b note.txt" ++ exLine "w")
            let (saved, _) := saved.finish 4
            let (again, _) := fedTo saved (exLine "ls")
            let path (name : String) : String := (inFiles name).toString
            let expected :=
              s!"  note.txt  {path "note.txt"}\n  lf.txt  {path "lf.txt"}\n  crlf.txt  {path "crlf.txt"}\n  scratch\n"
            let focused := again.loop.state.frame.focused
            bufferNamed first Buffers.listBuffer != none &&
              bufferNamed again Buffers.listBuffer == bufferNamed first Buffers.listBuffer &&
              shownName again focused == some Buffers.listBuffer &&
              (showing again focused).bind (·.text) == some expected &&
              (again.loop.state.buffers.filter
                    (·.any (·.name.startsWith Buffers.listBuffer))).size ==
                1 },
    { name :=
        "ls with a file called buffer-list open leaves that buffer's text as it was and unmodified, lists it, and shows the list in a buffer of its own with no file, under a free name; ls again makes no third"
      run :=
        pure <|
          match buffersDriver with
          | none => false
          | some driver =>
            let path := inFiles Buffers.listBuffer
            let contents := "kept\n"
            let withFile := rewritten driver path contents.toUTF8
            let (opened, _) := fedTo withFile (exLine s!"e {path}")
            let (opened, _) := opened.finish 1
            let (listed, _) := fedTo opened (exLine "ls")
            let (again, _) := fedTo listed (exLine "ls")
            let (back, _) := fedTo again (exLine s!"b {Buffers.listBuffer}")
            let expected := s!"  {Buffers.listBuffer}  {path}\n  scratch\n"
            let state := again.loop.state
            let list := listed.loop.state.frame.focused
            (showing opened).bind (·.text) == some contents &&
              ((showing listed list).map fun shown => (shown.buffer.file.isNone, shown.text)) ==
                some (true, some expected) &&
              shownName listed list == some (opened.loop.state.freeName Buffers.listBuffer) &&
              again.loop.state.frame.focused == list &&
              (showing again list).bind (·.text) == some expected &&
              state.openBuffers.size == 3 &&
              state.findFile path == bufferNamed opened Buffers.listBuffer &&
              (heldFile back).map (·.path) == some path &&
              (showing back).bind (·.text) == some contents &&
              (showing back).map (·.buffer.isModified) == some false &&
              state.wellFormed },
    { name :=
        "bd closes an unmodified file buffer shown in two windows: it is gone, no buffer holds its file, both windows show crlf.txt, the buffer used before it, and their status lines name it, the order of use lacks it, the state is well formed, and its text is released; a second bd falls back to note.txt"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (split, _) := fedTo opened (presses "C-b s")
            let before := split.loop.state
            let other := (before.frame.windows.filter (· != ⟨0⟩))[0]?.getD ⟨0⟩
            let closed := bufferNamed split "lf.txt"
            let text := (closed.bind before.buffer?).map (·.text)
            let (after, _) := fedTo split (exLine "bd")
            let state := after.loop.state
            let (second, _) := fedTo after (exLine "bd")
            other != ⟨0⟩ && shownName split other == some "lf.txt" && closed.isSome &&
              (closed.bind state.buffer?).isNone &&
              state.findFile (inFiles "lf.txt") == none &&
              shownName after == some "crlf.txt" &&
              shownName after other == some "crlf.txt" &&
              (closed.bind before.mostRecent) == bufferNamed after "crlf.txt" &&
              statusOf after == some (named "crlf.txt") &&
              inactiveStatusOf after other "crlf.txt" ==
                some #[{ ModeLine.field "crlf.txt" ModeLine.inactiveFace with side := .left }] &&
              closed.all (!state.recent.contains ·) &&
              state.wellFormed &&
              (text.bind fun text => (after.model.texts.texts[text.index]?).join).isNone &&
              text.isSome &&
              shownName second == some "note.txt" &&
              shownName second other == some "note.txt" &&
              second.loop.state.wellFormed },
    { name :=
        "bd with a name closes the named buffer, not the window's; bd with a name no buffer has says so by the close command's message and closes nothing"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (named', _) := fedTo opened (exLine "bd note.txt")
            let (missed, _) := fedTo opened (exLine "bd nope")
            bufferNamed named' "note.txt" == none && shownName named' == some "lf.txt" &&
              named'.loop.state.wellFormed &&
              promptEcho missed == Buffers.noBuffer "nope" &&
              missed.loop.state.openBuffers == opened.loop.state.openBuffers },
    { name :=
        "a modified buffer with no file closes, by q's rule: bd on the scratch buffer with text typed in it closes it and the window shows the buffer used before it"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (closed, _) := fedTo opened (exLine "b scratch" ++ [.commit "typed"] ++ exLine "bd")
            bufferNamed closed "scratch" == none && shownName closed == some "lf.txt" &&
              closed.loop.state.wellFormed },
    { name :=
        "bd on a buffer with a save in flight leaves it open and shown, with its text, and the echo area says why by the close command's message; once the save is delivered and says the file was written, bd closes it"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (saving, _) := fedTo opened ([.commit "x"] ++ exLine "w")
            let (refused, _) := fedTo saving (exLine "bd")
            let delivered := finishNamed refused Opener.saveJob
            let (closed, _) := fedTo delivered (exLine "bd")
            (heldFile saving).bind (·.saving) != none &&
              refused.loop.state.findFile (inFiles "lf.txt") != none &&
              shownName refused == some "lf.txt" &&
              (showing refused).bind (·.text) == (showing saving).bind (·.text) &&
              echoOf refused == some (Buffers.beingSaved "lf.txt") &&
              refused.loop.state.wellFormed &&
              echoOf delivered == some s!"wrote {inFiles "lf.txt"}" &&
              closed.loop.state.findFile (inFiles "lf.txt") == none &&
              shownName closed == some "crlf.txt" },
    { name :=
        "bd on a buffer whose save in flight is then refused, the file having changed behind the editor: the buffer is still open and shown, with its edit, and still modified, and the echo area has the save's refusal"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let path := inFiles "lf.txt"
            let changed := rewritten opened path JobContract.otherFile
            let (saving, _) := fedTo changed ([.commit "x"] ++ exLine "w")
            let (closing, _) := fedTo saving (exLine "bd")
            let refused := finishNamed closing Opener.saveJob
            refused.loop.state.findFile path != none && shownName refused == some "lf.txt" &&
              (showing refused).bind (·.text) == (showing saving).bind (·.text) &&
              ((showing saving).bind (·.text)).any (·.startsWith "x") &&
              (showing refused).map (·.buffer.isModified) == some true &&
              echoOf refused == some (Opener.notSaved path (.changed (stampOf changed path))) &&
              refused.loop.state.wellFormed },
    { name :=
        "close-buffer run from the minibuffer's view, and run with the name of the minibuffer's buffer, closes nothing and says so by the close command's message; the prompt stays open and the state is well formed"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (asking, _) := fedTo opened (presses "C-e e")
            let minibuffer := asking.loop.state.minibufferBuffer?
            [presses "C-b d", presses "C-b m"].all fun keys =>
              let (refused, _) := fedTo asking keys
              let state := refused.loop.state
              (minibuffer.bind asking.loop.state.buffer?).map (·.name) == some Prompt.bufferName &&
                promptEcho refused == Buffers.ofMinibuffer &&
                state.openBuffers == asking.loop.state.openBuffers &&
                state.minibufferBuffer? == minibuffer &&
                state.prompt == asking.loop.state.prompt &&
                state.wellFormed },
    { name :=
        "switch-buffer with no buffer named while a prompt is open asks for none: the echo area says the prompt's refusal by the switch command's message, and the open prompt is as it was"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (asking, _) := fedTo opened (presses "C-e e")
            let (refused, _) := fedTo asking (presses "C-b b")
            match asking.loop.state.minibufferView? with
            | none => false
            | some view =>
              promptEcho refused == Buffers.notAsking (.alreadyOpen view) &&
                refused.loop.state.prompt == asking.loop.state.prompt &&
                refused.loop.state.minibufferView? == some view &&
                refused.loop.state.wellFormed },
    { name :=
        "bd on the only buffer, the initial scratch with text typed in it: the window shows a buffer called scratch with no file, whose text is empty; the old slot is empty, one buffer is open, and the state is well formed"
      run :=
        pure <|
          match buffersDriver with
          | none => false
          | some driver =>
            let (closed, _) := fedTo driver ([.commit "typed"] ++ exLine "bd")
            let state := closed.loop.state
            driverText driver == some "" &&
              ((showing closed).map fun shown =>
                  (shown.buffer.name, shown.buffer.file.isNone, shown.text, shown.id != ⟨0⟩)) ==
                some (EditorState.scratchName, true, some "", true) &&
              state.buffers[0]? == some none &&
              state.openBuffers.size == 1 &&
              state.wellFormed },
    { name :=
        "bd on each of threeOpen's buffers in turn leaves, after the last, an empty buffer called scratch with no file, the one open buffer"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let (closed, _) :=
              fedTo opened (exLine "bd" ++ exLine "bd" ++ exLine "bd" ++ exLine "bd")
            let state := closed.loop.state
            ((showing closed).map fun shown =>
                  (shown.buffer.name, shown.buffer.file.isNone, shown.text)) ==
                some (EditorState.scratchName, true, some "") &&
              state.openBuffers.size == 1 &&
              ["note.txt", "crlf.txt", "lf.txt"].all (bufferNamed closed · == none) &&
              state.wellFormed },
    { name :=
        "Buffers.close closes a buffer whatever it holds, unsaved changes too: the window shows the most recently used buffer left; on the only buffer it leaves an empty buffer called scratch with no file"
      run :=
        pure <|
          match buffersOpen, buffersDriver with
          | some opened, some driver =>
            let (closed, _) :=
              fedTo opened (exLine "b note.txt" ++ [.commit "x"] ++ presses "C-b c")
            let (last, _) := fedTo driver ([.commit "typed"] ++ presses "C-b c")
            bufferNamed closed "note.txt" == none && shownName closed == some "lf.txt" &&
              closed.loop.state.wellFormed &&
              ((showing last).map fun shown =>
                  (shown.buffer.name, shown.buffer.file.isNone, shown.text)) ==
                some (EditorState.scratchName, true, some "") &&
              last.loop.state.openBuffers.size == 1 &&
              last.loop.state.wellFormed
          | _, _ => false },
    { name :=
        "bd on note.txt with an edit committed leaves the buffer open and shown, with the edit, and the echo area says why by the close command's message; and so when the edit and the close are one command"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let text := "x" ++ FileCases.noteText
            let (refused, _) := fedTo opened (exLine "b note.txt" ++ [.commit "x"] ++ exLine "bd")
            let (onePass, _) := fedTo opened (exLine "b note.txt" ++ presses "C-b x")
            [refused, onePass].all fun driver =>
              bufferNamed driver "note.txt" != none && shownName driver == some "note.txt" &&
                (showing driver).bind (·.text) == some text &&
                echoOf driver == some (Buffers.notClosing "note.txt") &&
                driver.loop.state.wellFormed },
    { name :=
        "bd on a buffer shown only in a window docked at an edge closes it: the docked window shows the buffer used before it, and stays docked"
      run :=
        pure <|
          match buffersOpen with
          | none => false
          | some opened =>
            let state := opened.loop.state
            let edged :=
              { opened with
                loop :=
                  { opened.loop with
                    state :=
                      { state with
                        frame := { state.frame with layout := .edge .left 25 Layout.default } } } }
            let (docked, _) := fedTo edged (presses "C-b s" ++ presses "C-b h")
            let (closed, _) := fedTo docked (exLine "b note.txt" ++ exLine "bd lf.txt")
            match docked.loop.state.frame.docked.toList with
            | [(sidebar, .left)] =>
              shownName docked sidebar == some "lf.txt" && bufferNamed closed "lf.txt" == none &&
                shownName closed sidebar == some "note.txt" &&
                closed.loop.state.frame.docked == #[(sidebar, .left)] &&
                closed.loop.state.wellFormed
            | _ => false }]

end ModelTest
