import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Model
import Editor.Compile.Contribution
import Editor.Completion.Candidate
import Editor.Completion.Displays
import Editor.Completion.Later
import Editor.Completion.Paths
import Editor.Completion.Style
import Editor.Completion.Styles
import Editor.Config.Owner
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.Event
import Editor.File
import Editor.File.Cases
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Files
import Editor.Files.Compiled
import Editor.Fuzzy.Model
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Contract
import Editor.Job.Model
import Editor.Language
import Editor.Loop
import Editor.Loop.Driver
import Editor.Minibuffer
import Editor.Minibuffer.Compiled
import Editor.Mode
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.Role
import Editor.Scene
import Editor.State
import Editor.SyntaxTree
import Editor.SyntaxTree.Model
import Editor.SyntaxTree.Model.Query
import Editor.Text
import Editor.Text.Model
import Editor.UndoTree
import Editor.Value
import Editor.Watch.Model
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.Driver
import ModelTest.Support.Files
import ModelTest.Support.Jobs
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Models
import ModelTest.Support.Modes
import ModelTest.Support.Prompts

/-!
# Model tests: `Editor/Files.lean`

The model tests of `Editor/Files.lean`: `languageOpenChecks`,
`fileCommandChecks`, `fileReloadChecks` and `fileNameChecks`.
`languageOpenChecks` check the language a file is opened in
(`Editor/Language.lean`) through the file commands, and `fileNameChecks`
`open-file`'s prompt over file names, with the file source
(`Editor/Completion/Paths.lean`) and the path style.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- What reading `snapshot` is refused with in `driver`'s text model:
`some none` when it reads. -/
def snapshotRefusal (driver : TestDriver) (snapshot : SnapshotId) : Option (Option TextError) :=
  ((refusalOf snapshot.read).runModel driver.model.texts).1.toOption

/-- The registry of the language open checks: the `code` mode, and the
languages `json` and `modelRs`, as compiled code registers them. -/
def languageRegistry : Config.Registry :=
  (({} : Config.Registry).replaceModes .compiled Language.modes).replaceLanguages .compiled
    #[Language.json, modelRs]

/-- The files of the language open checks: the file command checks', and,
beside `note.txt`, `data.json` and `main.rs`, each holding a JSON text. -/
def languageFiles : FileModel :=
  (commandFiles.withFile (inFiles "data.json") "[1, null]".toUTF8).withFile (inFiles "main.rs")
    "[2]".toUTF8

/-- What a step of the language open checks is handed: `C-o j`, `C-o r` and
`C-o n` bound to the open command with the paths of `data.json`, `main.rs`
and `note.txt`, `C-o 1` and `C-o 2` to the on-enter checks' `enter` of the
modes `own-json` and `derived` through view 0, and what `registry` says of
its modes and languages. -/
def languageKeys (registry : Config.Registry) : Loop.Keys TestScheme.scheme :=
  {
    dispatchKeys
      [("C-o j", opens (inFiles "data.json")), ("C-o r", opens (inFiles "main.rs")),
        ("C-o n", opens (inFiles "note.txt")), ("C-o 1", entersMode ⟨0⟩ "own-json"),
        ("C-o 2", entersMode ⟨0⟩ "derived")]
      [(Files.openName, fun call => do
          Files.openCommand call
          return none),
        ("enter", enter)] with
    registered := registry.registered }

/-- A driver of the language open checks over `languageRegistry` with
`modes` and `languages` registered for config, over `languageFiles`; `none`
if making the state was refused. -/
def languageDriver (modes : Array Mode := #[]) (languages : Array Language := #[]) :
    Option TestDriver :=
  let registry := (languageRegistry.replaceModes .config modes).replaceLanguages .config languages
  (Loop.Driver.over (languageKeys registry) fileJobs (EditorState.initial ⟨640, 480⟩)
        editorModel).toOption.map
    fun driver => { driver with jobs := { files := languageFiles } }

/-- `driver` once the keys `keys` were pressed and the job `job` their open
started is finished. -/
def openedBy (driver : TestDriver) (keys : String) (job : Nat := 1) : TestDriver :=
  ((fedTo driver (presses keys)).1.finish job).1

/-- The faces the syntax tree model's shipped `json` highlights query is
drawn in by the shipped default: each of its capture names'. -/
def modelJsonFaces : Array String :=
  #["syntax.string", "syntax.string", "syntax.number", "syntax.constant"]

/-- The job of the adopt check: it loads the file its one argument names and
finishes by adopting it (`Files.adopt`), saying the buffer's number. -/
def adoptWork (arguments : List Argument) : Work := fun _ => do
  let [.str path] := arguments | throw "adopt-load: its arguments are not a path"
  match ← File.load path Files.limit with
  | .ok loaded =>
    return do
      if let some buffer← Files.adopt path loaded then
        message s!"adopted {buffer.index}"
  | .error _ =>
    return message "not loaded"

/-- A driver of the language open checks over `languageRegistry`, with `C-o
j` bound to opening `data.json` and `C-o A` to starting `adopt-load` of
it, whose job is `adoptWork`; `none` if making the state was refused. -/
def adoptDriver : Option TestDriver :=
  let keys :=
    dispatchKeys [("C-o j", opens (inFiles "data.json")), ("C-o A", invoke "adopt")]
      [(Files.openName, fun call => do
          Files.openCommand call
          return none),
        ("adopt", fun _ => do
          discard <| startJob "adopt-load" [.str (inFiles "data.json").toString]
          return none)]
  let registered (name : String) : Option (List Argument → Work) :=
    if name == "adopt-load" then some adoptWork else fileJobs Files.limit name
  (Loop.Driver.over { keys with registered := languageRegistry.registered } registered
        (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { files := languageFiles } }

/-- The checks of what opening a file does with its language
(`Editor/Files.lean`, "Open"; `Editor/Language.lean`), on the loop's driver
over the editor's models and the model of files. The syntax tree model
knows one grammar, `json`, so every language here is parsed with it; Rust
and Markdown are `ConfigTest.languageChecks`'s, over the real binding. -/
def languageOpenChecks : List Check :=
  [{  name :=
        "opening a .json file gives its buffer the language json and the major mode code, and its text is attached with json and highlighted in the faces of the grammar's shipped query"
      run :=
        pure <|
          match languageDriver with
          | none => false
          | some driver =>
            let opened := openedBy driver "C-o j"
            languageAndMajor opened == some (some "json", some "code") &&
              opened.model.syntaxTree.attached.map (·.2) == #["json"] &&
              highlightedFaces opened.model.syntaxTree == some modelJsonFaces },
    { name :=
        "opening a .rs file chooses the language whose extension pattern is rs, and puts its buffer in code, attached with that language's grammar"
      run :=
        pure <|
          match languageDriver with
          | none => false
          | some driver =>
            let opened := openedBy driver "C-o r"
            languageAndMajor opened == some (some "model-rs", some "code") &&
              opened.model.syntaxTree.attached.map (·.2) == #["json"] &&
              highlightedFaces opened.model.syntaxTree == some modelJsonFaces },
    { name :=
        "opening a file whose name matches no language gives its buffer no language and no major mode, and asks the syntax tree port nothing"
      run :=
        pure <|
          match languageDriver with
          | none => false
          | some driver =>
            let opened := openedBy driver "C-o n"
            (showing opened).map (·.buffer.name) == some "note.txt" &&
              languageAndMajor opened == some (none, none) &&
              opened.model.syntaxTree.attached.isEmpty &&
              opened.model.syntaxTree.highlighted.isEmpty &&
              opened.model.syntaxTree.refreshAfter == none },
    { name :=
        "opening a file a buffer already holds shows it and asks the syntax tree port nothing more"
      run :=
        pure <|
          match languageDriver with
          | none => false
          | some driver =>
            let opened := openedBy driver "C-o j"
            let (again, _) := fedTo opened (presses "C-o j")
            again.pending.isEmpty && languageAndMajor again == some (some "json", some "code") &&
              again.model.syntaxTree.attached == opened.model.syntaxTree.attached &&
              again.model.syntaxTree.highlighted == opened.model.syntaxTree.highlighted &&
              again.model.syntaxTree.queries.size == opened.model.syntaxTree.queries.size },
    { name :=
        "a config mode with its own syntax tree, set over an opened json buffer, is highlighted with its own query and not the language's; a config mode derived from code with none is highlighted with the language's"
      run :=
        pure <|
          let own : Mode :=
            { name := "own-json",
              syntaxTree := some { grammar := "json", highlights := some "(number) @number" } }
          let derived : Mode := { name := "derived", parent := some "code" }
          match languageDriver #[own, derived] with
          | none => false
          | some driver =>
            let opened := openedBy driver "C-o j"
            let (owned, _) := fedTo opened (presses "C-o 1")
            let (back, _) := fedTo owned (presses "C-o 2")
            (showing owned).bind (·.buffer.major) == some "own-json" &&
              highlightedFaces owned.model.syntaxTree == some #["syntax.number"] &&
              (showing back).bind (·.buffer.major) == some "derived" &&
              highlightedFaces back.model.syntaxTree == some modelJsonFaces },
    { name :=
        "config's entry of the json language, with its own highlights query, is the one an opened .json buffer is highlighted with"
      run :=
        pure <|
          let numbers :=
            { Language.json with
              syntaxTree := { grammar := "json", highlights := some "(number) @number" } }
          match languageDriver (languages := #[numbers]) with
          | none => false
          | some driver =>
            let opened := openedBy driver "C-o j"
            languageAndMajor opened == some (some "json", some "code") &&
              highlightedFaces opened.model.syntaxTree == some #["syntax.number"] },
    { name :=
        "adopting a loaded file makes its buffer, attaches the file and sets its language and code without showing it; adopting a path a buffer holds gives that buffer and holds no snapshot"
      run :=
        pure <|
          match adoptDriver with
          | none => false
          | some driver =>
            let adopted := openedBy driver "C-o A"
            let path := inFiles "data.json"
            let made := adopted.loop.state.findFile path
            let buffer := made.bind adopted.loop.state.buffer?
            let opened := openedBy driver "C-o j"
            let again := openedBy opened "C-o A" 2
            let live (driver : TestDriver) := (driver.model.texts.snapshots.filter (·.isSome)).size
            (buffer.map fun buffer => (buffer.name, buffer.language, buffer.major)) ==
                some ("data.json", some "json", some "code") &&
              (showing adopted).map (·.buffer.name) == some "scratch" &&
              !adopted.loop.state.windows.any (some ·.buffer == made) &&
              echoOf adopted == made.map (s!"adopted {·.index}") &&
              echoOf again == (opened.loop.state.findFile path).map (s!"adopted {·.index}") &&
              again.loop.state.buffers.size == opened.loop.state.buffers.size &&
              live again == live opened }]

/-- `driver` once its first load job not yet delivered is delivered, with
the step the delivery handed back: the load among other jobs, a file
prompt's source's among them. -/
def finishedLoad (driver : TestDriver) : TestDriver × Option (Loop.Stepped TestScheme.scheme) :=
  match driver.pending.find? (·.name == Files.loadJob) with
  | some job => driver.finish job.id
  | none => (driver, none)

/-- The checks of the file commands (`Editor/Files.lean`), on the loop's
driver over the editor's models and the model of files: opening a file into
a buffer, and saving a buffer to its file. No file is touched. -/
def fileCommandChecks : List Check :=
  let started (steps : Array (Option (Loop.Stepped TestScheme.scheme))) : Array JobStart :=
    steps.flatMap fun step => (step.map (·.starts)).getD #[]
  [{  name :=
        "the open command on a file: once its job is finished, the view the command was called in shows a new buffer whose text is the file's, a byte that is not UTF-8 as its escape, named by the file's base name, with one cursor at its start, not modified, holding the file's path and the stamp the files have for it; the view's status line is that name alone"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, steps) := fedTo driver (presses "C-o n")
            let (opened, delivered) := asked.finish 1
            match showing opened with
            | none => false
            | some shown =>
              started steps ==
                  #[{ name := Files.loadJob
                      arguments := Files.LoadOrder.arguments { path, view := ⟨0⟩ } }] &&
                (delivered.map (·.ended)) == some (some .finished) &&
                shown.id == ⟨1⟩ &&
                shown.buffer.name == "note.txt" &&
                shown.text == some FileCases.noteText &&
                shown.cursors == some #[⟨0, 0⟩] &&
                !shown.buffer.isModified &&
                (shown.buffer.file.map fun file => (file.path, some file.stamp, file.saving)) ==
                  some (path, (opened.jobs.files.file? path).map (·.stamp), none) &&
                statusOf opened == some (named "note.txt") &&
                opened.loop.state.wellFormed &&
                opened.loop.state.buffers.size == 2 &&
                opened.model.texts.contents == #["", FileCases.noteText] },
    { name :=
        "a buffer's line ending is its file's dominant one: CRLF for a file most of whose lines end in CRLF, a line feed for one most of whose lines end in a line feed, and a line feed for a file with no line break"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let ending (key : String) : Option File.LineEnding :=
              let (asked, _) := fedTo driver (presses key)
              (showing (asked.finish 1).1).bind fun shown =>
                shown.buffer.file.map fun _ => shown.buffer.lineEnding
            ending "C-o c" == some .crlf && ending "C-o l" == some .lf &&
              ending "C-o p" == some .lf },
    { name :=
        "events that arrive while a load is in flight are handled before the load's result: after the open command the view still shows the scratch buffer, two commits fed before the job is finished are each in the scratch buffer's text after their own steps, and the file's buffer is there, and shown, only once the job is finished"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o n")
            let (first, _) := fedTo asked [.commit "a"]
            let (second, _) := fedTo first [.commit "b"]
            let (opened, _) := second.finish 1
            (showing asked).map (·.id) == some ⟨0⟩ && asked.pending.size == 1 &&
              driverText first == some "a" &&
              driverText second == some "ab" &&
              (showing second).map (·.id) == some ⟨0⟩ &&
              second.loop.state.buffers.size == 1 &&
              second.model.texts.contents == #["ab"] &&
              (showing opened).map (·.id) == some ⟨1⟩ &&
              (showing opened).bind (·.text) == some FileCases.noteText &&
              opened.model.texts.contents == #["ab", FileCases.noteText] },
    { name :=
        "the open command on a path with no file: the echo area says the refusal, the view still shows the buffer it showed, with its cursor, and there is no new buffer and no new text"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver ([.commit "kept"] ++ presses "C-o m")
            let (refused, delivered) := asked.finish 1
            (delivered.map (·.ended)) == some (some .finished) &&
              echoOf refused == some (Files.notOpened (inFiles "missing.txt") .notFound) &&
              (showing refused).map (fun shown => (shown.id, shown.text, shown.cursors)) ==
                some (⟨0⟩, some "kept", some #[⟨4, 4⟩]) &&
              refused.loop.state.buffers.size == 1 &&
              refused.model.texts.texts.size == 1 &&
              refused.model.texts.snapshots.size == asked.model.texts.snapshots.size &&
              refused.jobs.files == asked.jobs.files },
    { name :=
        "a file longer than the limit the load job is registered with is refused as too large, with its size and the limit, and a path that is not absolute is read under the working directory, /, where nothing is: each is said in the echo area by the same route, and nothing is opened"
      run :=
        pure <|
          match filesDriver (fileJobs 4), filesDriver with
          | some small, some driver =>
            let (large, _) := fedTo small (presses "C-o n")
            let (large, _) := large.finish 1
            let (relative, _) := fedTo driver (presses "C-o r")
            let (relative, _) := relative.finish 1
            echoOf large ==
                some
                  (Files.notOpened (inFiles "note.txt") (.tooLarge FileCases.noteBytes.size 4)) &&
              large.loop.state.buffers.size == 1 &&
              echoOf relative == some (Files.notOpened "/relative.txt" .notFound) &&
              relative.loop.state.buffers.size == 1
          | _, _ => false },
    { name :=
        "a load order's arguments are read back as the order, and arguments that are no order as none; the load job started with arguments that are no order fails"
      run :=
        pure <|
          let orders : List Files.LoadOrder :=
            [{ path := inFiles "note.txt", view := ⟨0⟩ }, { path := "relative.txt", view := ⟨7⟩ },
              { path := "/a b/é.txt", view := ⟨12⟩ }]
          orders.all (fun order => Files.LoadOrder.ofArguments? order.arguments == some order) &&
            [[], [.str "/a"], [.nat 0, .str "/a"], [.str "/a", .nat 0, .nat 1]].all
              (fun arguments => Files.LoadOrder.ofArguments? arguments == none) &&
            ((Files.loadWork Files.limit [.nat 1] ()).runModel { files := commandFiles }).1 matches
              .failed _ },
    { name :=
        "a visit's load order crosses as arguments and back with its point's first non-blank and whether it records a jump, and they default to the column and recording"
      run :=
        pure <|
          let point : Files.At := { row := 2, column := 3 }
          let defaults : Files.LoadOrder := { path := "/a", view := ⟨1⟩, point := some point }
          let set : Files.LoadOrder :=
            { defaults with
              point := some { point with firstNonBlank := true }, focus := true, record := false
              next := ["/b"] }
          point.firstNonBlank == false && defaults.record == true &&
            defaults.arguments ==
              [.str "/a", .nat 1, .nat 2, .nat 3, .bool false, .bool false, .bool true] &&
            Files.LoadOrder.ofArguments? defaults.arguments == some defaults &&
            set.arguments ==
              [.str "/a", .nat 1, .nat 2, .nat 3, .bool true, .bool true, .bool false, .str "/b"] &&
            Files.LoadOrder.ofArguments? set.arguments == some set },
    { name :=
        "a load order with paths to open next crosses as arguments and back, and one with none crosses as before"
      run :=
        pure <|
          let order : Files.LoadOrder :=
            { path := inFiles "note.txt", view := ⟨3⟩, next := [inFiles "crlf.txt", "/a b/é.txt"] }
          Files.LoadOrder.ofArguments? order.arguments == some order &&
            order.arguments ==
              [.str (inFiles "note.txt").toString, .nat 3, .str (inFiles "crlf.txt").toString,
                .str "/a b/é.txt"] &&
            ({ path := "/a", view := ⟨0⟩ } : Files.LoadOrder).arguments == [.str "/a", .nat 0] &&
            Files.LoadOrder.ofArguments? [.str "/a", .nat 0, .str "/b", .nat 1] == none },
    { name :=
        "the open command given two paths starts one load, of the first; once it is finished the first file's buffer is shown and the second's load starts; once that is finished two new buffers hold the two files and the view shows the second"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let note := inFiles "note.txt"
            let crlf := inFiles "crlf.txt"
            let (asked, steps) := fedTo driver (presses "C-o 2")
            let (first, delivered) := asked.finish 1
            let (both, _) := first.finish 2
            let state := both.loop.state
            started steps ==
                #[{ name := Files.loadJob
                    arguments :=
                      Files.LoadOrder.arguments { path := note, view := ⟨0⟩, next := [crlf] } }] &&
              asked.pending.size == 1 &&
              (showing first).map (·.id) == some ⟨1⟩ &&
              (delivered.map (·.starts)) ==
                some
                  #[{ name := Files.loadJob
                      arguments := Files.LoadOrder.arguments { path := crlf, view := ⟨0⟩ } }] &&
              first.pending.size == 1 &&
              state.buffers.size == 3 &&
              state.findFile note == some ⟨1⟩ &&
              state.findFile crlf == some ⟨2⟩ &&
              (showing both).map (·.id) == some ⟨2⟩ &&
              both.pending.isEmpty &&
              state.wellFormed },
    { name :=
        "the open command given an open path and then another shows the open one and starts the second's load at once"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some noted =>
            let crlf := inFiles "crlf.txt"
            let (scratch, _) := fedTo noted (presses "C-o 0")
            let (asked, steps) := fedTo scratch (presses "C-o 2")
            let (both, _) := asked.finish 2
            (showing scratch).map (·.id) == some ⟨0⟩ && (showing asked).map (·.id) == some ⟨1⟩ &&
              started steps ==
                #[{ name := Files.loadJob
                    arguments := Files.LoadOrder.arguments { path := crlf, view := ⟨0⟩ } }] &&
              both.loop.state.buffers.size == 3 &&
              (showing both).map (·.id) == both.loop.state.findFile crlf &&
              (both.loop.state.findFile crlf).isSome },
    { name :=
        "the open command given a path that cannot be opened and then one that can says the first cannot be opened and shows the second"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let lf := inFiles "lf.txt"
            let (asked, _) := fedTo driver (presses "C-o 3")
            let (refused, delivered) := asked.finish 1
            let (opened, _) := refused.finish 2
            echoOf refused == some (Files.notOpened (inFiles "missing.txt") .notFound) &&
              (showing refused).map (·.id) == some ⟨0⟩ &&
              (delivered.map (·.starts)) ==
                some
                  #[{ name := Files.loadJob
                      arguments := Files.LoadOrder.arguments { path := lf, view := ⟨0⟩ } }] &&
              opened.loop.state.buffers.size == 2 &&
              (showing opened).map (·.id) == opened.loop.state.findFile lf &&
              (opened.loop.state.findFile lf).isSome },
    { name :=
        "the markers of the window that showed the scratch buffer are given up once the file's buffer is shown in it, and not before: they answer while the load is in flight and refuse noSuchMarker after the delivery"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o n")
            let (opened, _) := asked.finish 1
            match driver.loop.state.window? ⟨0⟩ with
            | none => false
            | some old =>
              ((markerRefusals old).runModel asked.model.texts).1.toOption == some [none, none] &&
                ((markerRefusals old).runModel opened.model.texts).1.toOption ==
                  some [some .noSuchMarker, some .noSuchMarker] },
    { name :=
        "a file whose asking view was closed while it loaded is shown in the focused view: the command is called in a second view, that view is closed before the job is finished, and the file's buffer is then shown in the view that has the focus"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, steps) := fedTo driver (presses "C-o s C-o n")
            let (closed, _) := fedTo asked (presses "C-o k")
            let (opened, _) := closed.finish 1
            started steps ==
                #[{ name := Files.loadJob
                    arguments := Files.LoadOrder.arguments { path, view := ⟨1⟩ } }] &&
              asked.loop.state.frame.focused == ⟨1⟩ &&
              closed.loop.state.frame.focused == ⟨0⟩ &&
              (showing closed ⟨1⟩).isNone &&
              opened.loop.state.findFile path == some ⟨1⟩ &&
              (showing opened).map (·.id) == some ⟨1⟩ &&
              (showing opened).bind (·.text) == some FileCases.noteText &&
              opened.loop.state.wellFormed },
    { name :=
        "a file whose asking view was closed while it loaded, delivered while a prompt has the focus, is shown in the view the prompt was asked from, which is not the first window: the prompt is still open with the focus, the first window shows what it showed, and nothing is said"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            -- Views 0, 1 and 2; the open command is called in view 2, which
            -- is then closed, and the prompt is asked from view 1.
            let (asked, _) := fedTo driver (presses "C-o s C-o s C-o n")
            let (prompted, _) := fedTo asked (presses "C-o k C-o o")
            let (opened, delivered) := prompted.finish 1
            let state := opened.loop.state
            asked.loop.state.frame.focused == ⟨2⟩ && (showing prompted ⟨2⟩).isNone &&
              prompted.loop.state.prompt.map (·.asker) == some ⟨1⟩ &&
              (delivered.map (·.ended)) == some (some .finished) &&
              state.prompt.isSome &&
              state.prompt == prompted.loop.state.prompt &&
              some state.frame.focused == state.minibufferView? &&
              (state.findFile path).isSome &&
              (showing opened ⟨1⟩).map (·.id) == state.findFile path &&
              (showing opened ⟨1⟩).bind (·.text) == some FileCases.noteText &&
              (showing opened).map (·.id) == some ⟨0⟩ &&
              echoOf opened == some "" &&
              state.wellFormed },
    { name :=
        "a file delivered while a prompt has the focus, whose asking view and the view the prompt was asked from were both closed, is shown in the first window of the list, with the prompt still open"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            -- Views 0 and 1; the open command is called in view 1, the
            -- prompt is asked from it, and it is closed with the prompt open.
            let (asked, _) := fedTo driver (presses "C-o s C-o n C-o o")
            let (closed, _) := fedTo asked (presses "C-o K")
            let (opened, delivered) := closed.finish 1
            let state := opened.loop.state
            asked.loop.state.prompt.map (·.asker) == some ⟨1⟩ && (showing closed ⟨1⟩).isNone &&
              closed.loop.state.prompt == asked.loop.state.prompt &&
              (delivered.map (·.ended)) == some (some .finished) &&
              state.prompt.isSome &&
              state.prompt == asked.loop.state.prompt &&
              some state.frame.focused == state.minibufferView? &&
              (state.findFile path).isSome &&
              (showing opened).map (·.id) == state.findFile path &&
              (showing opened).bind (·.text) == some FileCases.noteText &&
              echoOf opened == some "" &&
              state.wellFormed },
    { name :=
        "the open command called in the minibuffer's view, with a path, shows the file in the view the prompt was asked from and leaves the prompt open: a file that is not open once its job is finished, and one that is open at once, with no job started"
      run :=
        pure <|
          match filesDriver, noteOpen with
          | some driver, some noted =>
            let path := inFiles "note.txt"
            let behind (before after : TestDriver) : Bool :=
              let state := after.loop.state
              state.prompt.isSome && state.prompt == before.loop.state.prompt &&
                some state.frame.focused == state.minibufferView? &&
                (state.findFile path).isSome &&
                (showing after).map (·.id) == state.findFile path &&
                (showing after).bind (·.text) == some FileCases.noteText &&
                echoOf after == some "" &&
                state.wellFormed
            let (prompted, _) := fedTo driver (presses "C-o o")
            let (asked, steps) := fedTo prompted (presses "C-o n")
            -- The prompt's file source started a job of its own first.
            let (opened, delivered) := finishedLoad asked
            -- The file is open in view 0, which then shows the scratch
            -- buffer again.
            let (shown, _) := fedTo noted (presses "C-o 0 C-o o")
            let (again, repeated) := fedTo shown (presses "C-o n")
            started steps ==
                #[{ name := Files.loadJob
                    arguments := Files.LoadOrder.arguments { path, view := ⟨1⟩ } }] &&
              prompted.loop.state.minibufferView? == some ⟨1⟩ &&
              (delivered.map (·.ended)) == some (some .finished) &&
              behind prompted opened &&
              (showing shown).map (·.id) == some ⟨0⟩ &&
              started repeated == #[] &&
              again.pending.all (·.name == Completion.Paths.job) &&
              behind shown again
          | _, _ => false },
    { name :=
        "a file loaded where no window can show it is said in the echo area as loaded and not shown: in a state whose focused view has no window, for an order whose view has none either, the buffer is there and holds the file, and the windows show what they showed"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let state := driver.loop.state
            let astray : TestDriver :=
              { driver with
                loop :=
                  { driver.loop with
                    state := { state with frame := { state.frame with focused := ⟨7⟩ } } } }
            let asked :=
              astray.started
                #[{ name := Files.loadJob
                    arguments := Files.LoadOrder.arguments { path, view := ⟨9⟩ } }]
            let (opened, _) := asked.finish 1
            echoOf opened == some (Files.notShown path) &&
              Files.notShown path != Files.notOpened path .notFound &&
              (showing opened).map (·.id) == some ⟨0⟩ &&
              opened.loop.state.findFile path == some ⟨1⟩ },
    { name :=
        "opening a path that is open shows its buffer and makes no second one: with the file open and another buffer shown in the view since, the open command shows the file's buffer again, with one cursor at its start, the step hands back no job to start, and there are as many buffers and texts as before"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o n")
            let (opened, _) := asked.finish 1
            let (back, _) := fedTo opened (presses "C-o 0")
            let (again, steps) := fedTo back (presses "C-o n")
            (showing back).map (·.id) == some ⟨0⟩ && started steps == #[] &&
              again.pending.isEmpty &&
              (showing again).map (fun shown => (shown.id, shown.text, shown.cursors)) ==
                some (⟨1⟩, some FileCases.noteText, some #[⟨0, 0⟩]) &&
              again.loop.state.buffers.size == opened.loop.state.buffers.size &&
              again.model.texts.texts.size == opened.model.texts.texts.size &&
              echoOf again == some "" },
    { name :=
        "two opens of one path in flight make one buffer: the command is run twice before either job is finished, and once both are, one buffer holds the path, the view shows it, and the second delivery made no text and left no snapshot"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, _) := fedTo driver (presses "C-o n C-o n")
            let (first, _) := asked.finish 1
            let (second, delivered) := first.finish 2
            asked.pending.size == 2 && (delivered.map (·.ended)) == some (some .finished) &&
              second.loop.state.findFile path == some ⟨1⟩ &&
              second.loop.state.buffers.size == 2 &&
              (showing second).map (·.id) == some ⟨1⟩ &&
              second.model.texts.texts.size == first.model.texts.texts.size &&
              second.model.texts.snapshots.filterMap id ==
                first.model.texts.snapshots.filterMap id &&
              second.jobs.files.held.all (·.isNone) &&
              echoOf second == echoOf first },
    { name :=
        "a second file with the base name a buffer has gets a name of its own: two files called x.txt in two directories open as x.txt and x.txt<2>, each buffer holding its own path and its own text"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o a")
            let (first, _) := asked.finish 1
            let (asked, _) := fedTo first (presses "C-o b")
            let (second, _) := asked.finish 2
            let seen (driver : TestDriver) :=
              (showing driver).map fun shown =>
                (shown.buffer.name, shown.buffer.file.map (·.path), shown.text)
            seen first == some ("x.txt", some (fileRoot / "a" / "x.txt"), some "first x\n") &&
              seen second ==
                some ("x.txt<2>", some (fileRoot / "b" / "x.txt"), some "second x\n") &&
              statusOf second == some (named "x.txt<2>") &&
              second.loop.state.buffers.size == 3 },
    { name :=
        "the open command where no load job is registered says so in the echo area, by the job's name, starts nothing and leaves the view as it was"
      run :=
        pure <|
          match filesDriver (fun _ => none) with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, steps) := fedTo driver (presses "C-o n")
            started steps == #[] && asked.pending.isEmpty &&
              echoOf asked == some (Files.notOpening path (.noSuchJob Files.loadJob)) &&
              Files.notOpening path (.noSuchJob Files.loadJob) != Files.notOpened path .notFound &&
              (showing asked).map (·.id) == some ⟨0⟩ &&
              asked.loop.state.buffers.size == 1 },
    { name :=
        "a refused start in an open of several paths is said once, for its own path, and opens nothing after it: refused for the first path, a path after it that a buffer holds is not shown; refused for the second path, when the first one's load is delivered, the third is not said"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let note := inFiles "note.txt"
            let lf := inFiles "lf.txt"
            let crlf := inFiles "crlf.txt"
            let unregistered (driver : TestDriver) : TestDriver :=
              { driver with registered := fun _ => none }
            -- `lf.txt` is open in buffer 1, and view 0 shows the scratch
            -- buffer again; then no load job is registered.
            let (held, _) := fedTo ((fedTo driver (presses "C-o l")).1.finish 1).1 (presses "C-o 0")
            let (first, steps) :=
              fedTo (unregistered held) [.openFiles [note.toString, lf.toString, crlf.toString]]
            -- The first load is started; the load job is then unregistered,
            -- so the start its delivery asks for is refused.
            let (asked, _) := fedTo driver [.openFiles [note.toString, crlf.toString, lf.toString]]
            let (second, delivered) := (unregistered asked).finish 1
            held.loop.state.findFile lf == some ⟨1⟩ && (showing held).map (·.id) == some ⟨0⟩ &&
              started steps == #[] &&
              first.pending.isEmpty &&
              echoOf first == some (Files.notOpening note (.noSuchJob Files.loadJob)) &&
              (showing first).map (·.id) == some ⟨0⟩ &&
              first.loop.state.buffers.size == 2 &&
              asked.pending.size == 1 &&
              (delivered.map (·.ended)) == some (some .finished) &&
              (delivered.map (·.starts)) == some #[] &&
              second.pending.isEmpty &&
              echoOf second == some (Files.notOpening crlf (.noSuchJob Files.loadJob)) &&
              (showing second).map (·.id) == second.loop.state.findFile note &&
              (second.loop.state.findFile note).isSome &&
              second.loop.state.findFile lf == none &&
              second.loop.state.buffers.size == 2 },
    { name :=
        "an open of several paths whose asking view is closed while the first one loads opens every path, in order, in the focused view: the first file's buffer is shown there, a path after it that a buffer holds is shown there at once, after it, the load after that is started for that view, and its buffer is shown there last; with no path a buffer holds after the first, the first file's buffer is what the focused view shows once its load is delivered"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let note := inFiles "note.txt"
            let lf := inFiles "lf.txt"
            let crlf := inFiles "crlf.txt"
            -- `lf.txt` is open in buffer 1 and view 0 shows the scratch
            -- buffer again; view 0 is split, and the open is asked in view
            -- 1, which is then closed.
            let (held, _) := fedTo ((fedTo driver (presses "C-o l")).1.finish 1).1 (presses "C-o 0")
            let (split, _) := fedTo held (presses "C-o s")
            let (asked, steps) :=
              fedTo split [.openFiles [note.toString, lf.toString, crlf.toString]]
            let (closed, _) := fedTo asked (presses "C-o k")
            let (first, delivered) := closed.finish 2
            let (last, _) := first.finish 3
            let state := last.loop.state
            -- The same with no path a buffer holds: view 0 shows the scratch
            -- buffer until the first file's load is delivered.
            let (alone, _) :=
              fedTo (fedTo driver (presses "C-o s")).1 [.openFiles [note.toString, crlf.toString]]
            let (aloneClosed, _) := fedTo alone (presses "C-o k")
            let (aloneFirst, aloneDelivered) := aloneClosed.finish 1
            (showing held).map (·.id) == some ⟨0⟩ && (showing split).map (·.id) == some ⟨0⟩ &&
              split.loop.state.frame.focused == ⟨1⟩ &&
              started steps ==
                #[{ name := Files.loadJob
                    arguments :=
                      Files.LoadOrder.arguments
                        { path := note, view := ⟨1⟩, next := [lf, crlf] } }] &&
              closed.loop.state.frame.focused == ⟨0⟩ &&
              (showing closed ⟨1⟩).isNone &&
              (delivered.map (·.ended)) == some (some .finished) &&
              (first.loop.state.findFile note).isSome &&
              (showing first).map (·.id) == some ⟨1⟩ &&
              echoOf first == some "" &&
              (delivered.map (·.starts)) ==
                some
                  #[{ name := Files.loadJob
                      arguments := Files.LoadOrder.arguments { path := crlf, view := ⟨0⟩ } }] &&
              state.buffers.size == 4 &&
              (state.findFile crlf).isSome &&
              (showing last).map (·.id) == state.findFile crlf &&
              (heldFile last).map (·.path) == some crlf &&
              last.pending.isEmpty &&
              state.wellFormed &&
              aloneClosed.loop.state.frame.focused == ⟨0⟩ &&
              (showing aloneClosed).map (·.id) == some ⟨0⟩ &&
              aloneFirst.loop.state.findFile note == some ⟨1⟩ &&
              (showing aloneFirst).map (·.id) == some ⟨1⟩ &&
              (aloneDelivered.map (·.starts)) ==
                some
                  #[{ name := Files.loadJob
                      arguments := Files.LoadOrder.arguments { path := crlf, view := ⟨0⟩ } }] },
    { name :=
        "an interrupted delivery of a load in an open of several paths is rolled back with the rest of the open: wherever the interrupt key arrives in it, no buffer is made, the path after it that a buffer holds is not shown, and no later load is started; run to its end it starts the last load; and once the flag is down the same open opens every path"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let note := inFiles "note.txt"
            let lf := inFiles "lf.txt"
            let crlf := inFiles "crlf.txt"
            let paths := [note.toString, lf.toString, crlf.toString]
            -- `lf.txt` is open in buffer 1, view 0 shows the scratch buffer
            -- again, and the open's first load is job 2.
            let (held, _) := fedTo ((fedTo driver (presses "C-o l")).1.finish 1).1 (presses "C-o 0")
            let (asked, _) := fedTo held [.openFiles paths]
            -- The interrupt key arrives once the delivery has made `asks`
            -- requests of the models.
            let arriving (asks : Nat) : TestDriver :=
              let watch := { asked.model.watch with arrivesAfter := some asks }
              { asked with model := { asked.model with watch } }
            let delivered (asks : Nat) := (arriving asks).finish 2
            let rolledBack (asks : Nat) : Bool :=
              let (after, stepped) := delivered asks
              match stepped.map (·.ended) with
              | some (some Loop.Ending.interrupted) =>
                stepped.map (·.starts) == some #[] && after.pending.isEmpty &&
                  after.loop.state.buffers.size == 2 &&
                  after.loop.state.findFile note == none &&
                  (showing after).map (·.id) == some ⟨0⟩
              | some (some Loop.Ending.finished) =>
                stepped.map (·.starts) ==
                  some
                    #[{ name := Files.loadJob
                        arguments := Files.LoadOrder.arguments { path := crlf, view := ⟨0⟩ } }]
              | _ => false
            let (stopped, _) := delivered 0
            let (lowered, _) := stopped.feed interruptArrives
            let (again, _) := fedTo lowered [.openFiles paths]
            let (opened, _) := (again.finish 3).1.finish 4
            asked.pending.size == 1 &&
              ((delivered 0).2.map (·.ended)) == some (some .interrupted) &&
              ((delivered 40).2.map (·.ended)) == some (some .finished) &&
              (List.range 41).all rolledBack &&
              opened.loop.state.buffers.size == 4 &&
              (opened.loop.state.findFile note).isSome &&
              (showing opened).map (·.id) == opened.loop.state.findFile crlf &&
              (opened.loop.state.findFile crlf).isSome &&
              opened.loop.state.wellFormed },
    { name :=
        "the open command with no path among its arguments, with none and with the count and the register an input scheme hands a command, starts no load and asks for the path: a prompt is open, labelled as the open command's, whose continuation is the open command with the mark of a typed answer, asked from the view the command was called in, starting at the working directory, /, with the file source asking, whose job is the one started"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            ["C-o o", "C-o V"].all fun typed =>
              let (asked, steps) := fedTo driver (presses typed)
              (started steps).map (·.name) == #[Completion.Paths.job] &&
                asked.pending.all (·.name == Completion.Paths.job) &&
                echoOf asked == some "" &&
                asked.loop.state.prompt.map
                    (fun prompt =>
                      (prompt.label, prompt.view, prompt.asker, prompt.continuation)) ==
                  some
                    (Files.openPrompt, ⟨1⟩, ⟨0⟩,
                      { command := Files.openName, arguments := Files.typedMark }) &&
                asked.loop.state.prompt.map (·.candidates.asking.map (·.source)) ==
                  some #["files"] &&
                minibufferText asked == some "/" &&
                !Files.openPrompt.isEmpty &&
                asked.loop.state.frame.focused == ⟨1⟩ &&
                asked.loop.state.wellFormed },
    { name :=
        "the open command with no path while a prompt is open cannot ask: the echo area says so, with the refusal, and the one prompt is still open"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o o")
            let (again, steps) := fedTo asked (presses "C-o o")
            started steps == #[] && echoOf again == some (Files.notAsking (.alreadyOpen ⟨1⟩)) &&
              again.loop.state.prompt == asked.loop.state.prompt &&
              again.loop.state.prompt.isSome &&
              again.loop.state.windows.size == 2 },
    { name :=
        "the open command asks for its path and opens the answer: with the commands compiled code registers, the open command with no argument, the path of a file committed into the minibuffer after its /, read by the restart after //, the accept command and the load job finished leave the view the command was called in showing the file's text, in a buffer called by the file's base name, with the prompt closed, and the file source's job and one load were started"
      run :=
        pure <|
          match compiledDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, _) := fedTo driver (presses "C-o o")
            let (typed, _) := fedTo asked [.commit path.toString]
            let (accepted, _) := fedTo typed (presses "C-o y")
            let (opened, delivered) := finishedLoad accepted
            asked.loop.state.prompt.isSome && asked.pending.all (·.name == Completion.Paths.job) &&
              -- The path is typed after the prompt's /, and the restart
              -- after // reads it as it is.
              minibufferText typed == some ("/" ++ path.toString) &&
              accepted.loop.state.prompt == none &&
              accepted.loop.state.frame.focused == ⟨0⟩ &&
              -- The file source's jobs were cancelled when the prompt closed.
              accepted.pending.map (·.name) == #[Files.loadJob] &&
              (delivered.map (·.ended)) == some (some .finished) &&
              opened.pending.isEmpty &&
              (showing opened).map (fun shown => (shown.buffer.name, shown.text)) ==
                some ("note.txt", some FileCases.noteText) &&
              statusOf opened == some (named "note.txt") &&
              opened.loop.state.wellFormed },
    { name :=
        "the save command on a modified buffer: once its job is finished, the file's bytes are the buffer's text as a save writes it, the buffer is not modified, its stamp is the one the files now have, no save is in flight, the snapshot the command took is released, the echo area says the file was written, and the view's status line has no modified field"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (saving, _) := fedTo opened ([.commit "x"] ++ presses "C-o w")
            let (saved, delivered) := saving.finish 2
            match (heldFile saving).bind (·.saving), showing saved with
            | some flight, some shown =>
              (delivered.map (·.ended)) == some (some .finished) && shown.text == some text &&
                bytesOf saved path == some (FileModel.encode text) &&
                !shown.buffer.isModified &&
                shown.buffer.file.map (·.stamp) == stampOf saved path &&
                stampOf saved path != stampOf opened path &&
                (shown.buffer.file.map (·.saving)) == some none &&
                snapshotRefusal saved flight.snapshot == some (some .noSuchSnapshot) &&
                echoOf saved == some (Files.wrote path) &&
                statusOf saved == some (named "note.txt")
            | _, _ => false },
    { name :=
        "while a save is in flight the buffer is still modified: after the save command and before its job is finished, the step has handed back the save job with its order, the buffer's save is in flight with a snapshot that reads as the buffer's text and the stamp the file was opened with, and the view's status line has the modified field"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (edited, _) := fedTo opened [.commit "x"]
            let (saving, steps) := fedTo edited (presses "C-o w")
            match (heldFile saving).bind (·.saving), (heldFile opened).map (·.stamp) with
            | some flight, some stamp =>
              started steps ==
                  #[{ name := Files.saveJob
                      arguments :=
                        Files.SaveOrder.arguments
                          { buffer := ⟨1⟩, snapshot := flight.snapshot, path
                            expect := .unchanged stamp } }] &&
                saving.pending.size == 1 &&
                (showing saving).map (·.buffer.isModified) == some true &&
                (heldFile saving).map (·.stamp) == some stamp &&
                ((flight.snapshot.read.runModel saving.model.texts).1.toOption) ==
                  some ("x" ++ FileCases.noteText) &&
                some flight.state == (showing edited).map (·.buffer.history.state) &&
                statusOf saving == some (namedModified "note.txt")
            | _, _ => false },
    { name :=
        "a save of a buffer whose file changed on disk after it was loaded leaves the file as it is and says the changed-on-disk refusal in the echo area, with the stamp the file now has: the buffer is still modified, with the stamp it was opened with, no save is in flight, and the snapshot is released"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let changed := rewritten opened path JobContract.otherFile
            let (saving, _) := fedTo changed ([.commit "x"] ++ presses "C-o w")
            let (refused, delivered) := saving.finish 2
            match (heldFile saving).bind (·.saving), stampOf changed path with
            | some flight, some found =>
              (delivered.map (·.ended)) == some (some .finished) &&
                bytesOf refused path == some JobContract.otherFile &&
                stampOf refused path == some found &&
                some found != stampOf opened path &&
                echoOf refused == some (Files.notSaved path (.changed (some found))) &&
                (showing refused).map (·.buffer.isModified) == some true &&
                (heldFile refused).map (fun file => (some file.stamp, file.saving)) ==
                  some (stampOf opened path, none) &&
                snapshotRefusal refused flight.snapshot == some (some .noSuchSnapshot) &&
                statusOf refused == some (namedModified "note.txt")
            | _, _ => false },
    { name :=
        "open then save with no edit writes the file and leaves its bytes as they were, for a file whose lines end in line feeds, one whose lines end in CRLF, one with both and two with bytes that are not UTF-8: the save's job has run, the files have a new stamp for the path, which is the buffer's, the echo area says the file was written, and the bytes are byte for byte what they were"
      run :=
        pure <|
          ["a\nb\n".toUTF8, "a\r\nb\r\n".toUTF8, mostlyCrlf, FileCases.noteBytes,
                JobContract.rawFile].all
            fun bytes =>
            match noteOpen (fileModelOf #[("note.txt", bytes)]) with
            | none => false
            | some opened =>
              let path := inFiles "note.txt"
              let (saving, _) := fedTo opened (presses "C-o w")
              let (saved, delivered) := saving.finish 2
              (saving.pending.map fun job => (job.name, job.outcome matches .finished _)) ==
                  #[(Files.saveJob, true)] &&
                (delivered.map (·.ended)) == some (some .finished) &&
                bytesOf saved path == some bytes &&
                (stampOf saved path).isSome &&
                stampOf saved path != stampOf opened path &&
                (heldFile saved).map (·.stamp) == stampOf saved path &&
                echoOf saved == some (Files.wrote path) &&
                (showing saved).map (·.buffer.isModified) == some false },
    { name :=
        "a save with a follow-up starts it, with its arguments and its key, once the file is written, and a refused save starts nothing"
      run :=
        pure <|
          let registered (name : String) : Option (List Argument → Work) :=
            if name == "follow" then
              some fun arguments _ =>
                pure <|
                  match arguments with
                  | [.str said] => message s!"followed {said}"
                  | _ => message "followed nothing"
            else fileJobs Files.limit name
          match
            (filesDriver registered).map fun driver =>
              ((fedTo driver (presses "C-o n")).1.finish 1).1 with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (saving, _) := fedTo opened (presses "C-o t")
            let (saved, _) := saving.finish 2
            let (followed, _) := saved.finish 3
            let changed := rewritten opened path JobContract.otherFile
            let (refused, _) := (fedTo changed (presses "C-o t")).1.finish 2
            saving.pending.map (·.name) == #[Files.saveJob] &&
              saved.pending.map (fun job => (job.name, job.key)) == #[("follow", some "k")] &&
              echoOf followed == some "followed x" &&
              refused.pending.isEmpty &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf changed path))) },
    { name :=
        "a save order's arguments are read back as the order, for each thing a save can expect and for a stamp from before 1970, and arguments that are no order as none; the save job started with arguments that are no order fails"
      run :=
        pure <|
          let stamps : List File.Stamp :=
            [{ seconds := 5, nanoseconds := 7, size := 9 },
              { seconds := -3, nanoseconds := 999999999, size := 0 }]
          let expects : List File.Expect := stamps.map .unchanged ++ [.absent, .whatever]
          let afters : List (Option JobStart) :=
            [none, some { name := "follow" },
              some
                { name := "follow", arguments := [.str "x", .nat 2, .bool false], key := some "k" }]
          expects.all
                (fun expect =>
                  afters.all fun after =>
                    let order : Files.SaveOrder :=
                      { buffer := ⟨3⟩, snapshot := ⟨11⟩, path := "/a b/é.txt", expect, after }
                    Files.SaveOrder.ofArguments? order.arguments == some order) &&
              [[], [.nat 1], [.nat 1, .nat 2, .str "/a"],
                    [.nat 1, .nat 2, .str "/a", .str "sometimes"],
                    [.nat 1, .nat 2, .str "/a", .str "absent", .nat 1],
                    [.str "/a", .nat 1, .nat 2, .str "absent"]].all
                (fun arguments => Files.SaveOrder.ofArguments? arguments == none) &&
            ((Files.saveWork [.nat 1] ()).runModel { files := commandFiles }).1 matches .failed _ },
    { name :=
        "the save command on a buffer with no file says so in the echo area, by the buffer's name, starts no job and takes no snapshot; saving a buffer there is none of says so too"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (shown, _) := fedTo driver [pressF5]
            let (asked, steps) := fedTo shown (presses "C-o w")
            let (absent, absentSteps) := fedTo shown (presses "C-o x")
            match (showing driver).map (·.buffer.name) with
            | none => false
            | some name =>
              started steps == #[] && asked.pending.isEmpty &&
                echoOf asked == some (Files.noFile name) &&
                asked.model.texts.snapshots.size == shown.model.texts.snapshots.size &&
                started absentSteps == #[] &&
                echoOf absent == some Files.noBuffer &&
                absent.model.texts.snapshots.size == shown.model.texts.snapshots.size &&
                Files.noBuffer != Files.noFile name },
    { name :=
        "a second save while one is in flight is refused when it is asked: the echo area says the file is being saved, no second job is started and no snapshot is taken, and once the first is finished the buffer is saved once, not modified, with the stamp the files have"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (saving, _) := fedTo opened ([.commit "x"] ++ presses "C-o w")
            let (again, steps) := fedTo saving (presses "C-o w")
            let (saved, _) := again.finish 2
            started steps == #[] && again.pending.size == 1 &&
              echoOf again == some (Files.beingSaved path) &&
              again.model.texts.snapshots.size == saving.model.texts.snapshots.size &&
              heldFile again == heldFile saving &&
              (showing saved).map (·.buffer.isModified) == some false &&
              (heldFile saved).map (fun file => (some file.stamp, file.saving)) ==
                some (stampOf saved path, none) &&
              saved.jobs.files.writes == opened.jobs.files.writes + 1 &&
              echoOf saved == some (Files.wrote path) },
    { name :=
        "a save that reports late marks the state it wrote: a commit fed between the save command and its job's end leaves the buffer modified once the job is finished, with the new stamp, and one undo, back to the state that was written, leaves it not modified"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (saving, _) := fedTo opened ([.commit "x"] ++ presses "C-o w")
            let (typed, _) := fedTo saving [.commit "y"]
            let (saved, _) := typed.finish 2
            let (undone, _) := fedTo saved (presses "C-o u")
            bytesOf saved path == some (FileModel.encode ("x" ++ FileCases.noteText)) &&
              (showing saved).bind (·.text) == some ("xy" ++ FileCases.noteText) &&
              (showing saved).map (·.buffer.isModified) == some true &&
              (heldFile saved).map (fun file => (some file.stamp, file.saving)) ==
                some (stampOf saved path, none) &&
              statusOf saved == some (namedModified "note.txt") &&
              (showing undone).bind (·.text) == some ("x" ++ FileCases.noteText) &&
              (showing undone).map (·.buffer.isModified) == some false &&
              statusOf undone == some (named "note.txt") },
    { name :=
        "a forced save writes over a file that changed on disk: with the file written by another program since it was opened, the save command with true as its argument writes the buffer's text as the file, and the buffer is not modified, with the new stamp; with the arguments the Vim scheme gives a bound command it is a plain save, and is refused as changed on disk"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (edited, _) := fedTo (rewritten opened path JobContract.otherFile) [.commit "x"]
            let (forcing, steps) := fedTo edited (presses "C-o f")
            let (forced, _) := forcing.finish 2
            let (plain, _) := fedTo edited (presses "C-o v")
            let (refused, _) := plain.finish 2
            (started steps).map
                  (fun start => (Files.SaveOrder.ofArguments? start.arguments).map (·.expect)) ==
                #[some .whatever] &&
              bytesOf forced path == some (FileModel.encode text) &&
              (showing forced).map (·.buffer.isModified) == some false &&
              (heldFile forced).map (fun file => (some file.stamp, file.saving)) ==
                some (stampOf forced path, none) &&
              echoOf forced == some (Files.wrote path) &&
              bytesOf refused path == some JobContract.otherFile &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf edited path))) &&
              (showing refused).map (·.buffer.isModified) == some true },
    { name :=
        "the save command where no save job is registered says so in the echo area, by the job's name, and leaves no save in flight: nothing is started, the snapshot it took is released, the buffer is as it was, and once the job is registered the buffer is saved"
      run :=
        pure <|
          match
            (filesDriver fun name =>
                  if name == Files.loadJob then fileJobs Files.limit name else none).map
              fun driver => ((fedTo driver (presses "C-o n")).1.finish 1).1 with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (edited, _) := fedTo opened [.commit "x"]
            let (asked, steps) := fedTo edited (presses "C-o w")
            let registered : TestDriver := { asked with registered := fileJobs }
            let (saving, _) := fedTo registered (presses "C-o w")
            let (saved, _) := saving.finish 2
            let live (driver : TestDriver) := (driver.model.texts.snapshots.filterMap id).size
            started steps == #[] && asked.pending.isEmpty &&
              echoOf asked == some (Files.notSaving path (.noSuchJob Files.saveJob)) &&
              Files.notSaving path (.noSuchJob Files.saveJob) != Files.notSaved path .notFound &&
              heldFile asked == heldFile edited &&
              (heldFile asked).map (·.saving) == some none &&
              asked.model.texts.snapshots.size == edited.model.texts.snapshots.size + 1 &&
              live asked == live edited &&
              bytesOf asked path == some FileCases.noteBytes &&
              echoOf saved == some (Files.wrote path) &&
              (showing saved).map (·.buffer.isModified) == some false &&
              bytesOf saved path == some (FileModel.encode ("x" ++ FileCases.noteText)) },
    { name :=
        "a buffer removed while its save runs: the file is written, the delivery says so in the echo area and is not refused, and the buffer stays removed"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (saving, _) := fedTo opened ([.commit "x"] ++ presses "C-o w")
            let (removed, _) := fedTo saving (presses "C-o 0 C-o d")
            let (saved, delivered) := removed.finish 2
            removed.loop.state.buffer? ⟨1⟩ == none &&
              (delivered.map (·.ended)) == some (some .finished) &&
              echoOf saved == some (Files.wrote path) &&
              bytesOf saved path == some (FileModel.encode ("x" ++ FileCases.noteText)) &&
              saved.loop.state.buffers == removed.loop.state.buffers &&
              saved.loop.state.wellFormed },
    { name :=
        "the file commands and their jobs as compiled code registers them: the open, save, edit and reload commands are registered under their names and the load, save and reload jobs under theirs, the open command with a path opens the file and the save command saves the buffer, and the open command with no path starts no load, only the file source's job, and asks for one"
      run :=
        pure <|
          match compiledDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (bare, steps) := fedTo driver (presses "C-o o")
            let (asked, _) := fedTo driver (presses "C-o n")
            let (opened, _) := asked.finish 1
            let (saving, _) := fedTo opened ([.commit "x"] ++ presses "C-o w")
            -- The first edit starts a check of the file too: the save is
            -- found by its name.
            let saveId := ((saving.pending.find? (·.name == Files.saveJob)).map (·.id)).getD 0
            let (saved, _) := saving.finish saveId
            Files.commands.map (·.name) ==
                #[Files.openName, Files.saveName, Files.editName, Files.reloadName,
                  Files.autoReloadName] &&
              Files.jobs.map (·.name) ==
                #[Files.loadJob, Files.saveJob, Files.reloadJob, Files.checkJob, Files.followJob,
                  Completion.Paths.job] &&
              (started steps).map (·.name) == #[Completion.Paths.job] &&
              bare.pending.all (·.name == Completion.Paths.job) &&
              bare.loop.state.prompt.map (fun asking => (asking.label, asking.continuation)) ==
                some
                  (Files.openPrompt, { command := Files.openName, arguments := Files.typedMark }) &&
              (showing opened).bind (·.text) == some FileCases.noteText &&
              (showing saved).bind (·.text) == some text &&
              bytesOf saved path == some (FileModel.encode text) &&
              echoOf saved == some (Files.wrote path) },
    { name :=
        "a point's offset is its row's start and the bytes of its first column characters: the row is clamped to the last line, the column to the row's content"
      run :=
        let offset (point : Files.At) : Option Nat :=
          ((do
                  let text ← createText "ab\nαβγ\n"
                  Files.offsetAt text point).runModel
              {}).1.toOption
        pure
          (offset { row := 1, column := 2 } == some 7 &&
            offset { row := 1, column := 9 } == some 9 &&
            offset { row := 7, column := 0 } == some 3 &&
            offset { row := 0, column := 1 } == some 1) },
    { name :=
        "a visit of a path no buffer holds loads it, and once the load is delivered the view shows it with one cursor at the row and the character column, and is focused"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, steps) := fedTo driver (presses "C-o s C-o g")
            let (visited, _) := asked.finish 1
            started steps ==
                #[{ name := Files.loadJob
                    arguments :=
                      Files.LoadOrder.arguments
                        { path := inFiles "note.txt", view := ⟨0⟩,
                          point := some { row := 0, column := 2 }
                          focus := true } }] &&
              asked.loop.state.frame.focused == ⟨1⟩ &&
              (showing visited).map (·.buffer.name) == some "note.txt" &&
              (showing visited).bind (·.cursors) == some #[⟨6, 6⟩] &&
              visited.loop.state.frame.focused == ⟨0⟩ },
    { name :=
        "a visit of a path a buffer holds shows that buffer at once, puts its cursor at the point and focuses the view, with no job"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (opened, _) := (fedTo driver (presses "C-o n")).1.finish 1
            let (visited, steps) := fedTo opened (presses "C-o 0 C-o s C-o g")
            started steps == #[] && visited.pending.isEmpty &&
              (showing visited).map (·.buffer.name) == some "note.txt" &&
              (showing visited).bind (·.cursors) == some #[⟨6, 6⟩] &&
              visited.loop.state.frame.focused == ⟨0⟩ },
    { name :=
        "a visit whose load is refused says so and leaves the view, its cursor and the focus as they were"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o s C-o G")
            let (refused, _) := asked.finish 1
            echoOf refused == some (Files.notOpened (inFiles "missing.txt") .notFound) &&
              (showing refused).map (·.id) == some ⟨0⟩ &&
              (showing refused).bind (·.cursors) == some #[⟨0, 0⟩] &&
              refused.loop.state.frame.focused == ⟨1⟩ &&
              refused.loop.state.buffers.size == 1 },
    { name :=
        "a load order crosses as arguments and back with a point and the focus and without, an order with no point crosses as it did, and arguments of that shape still read"
      run :=
        let order : Files.LoadOrder := { path := "/a", view := ⟨2⟩, next := ["/b"] }
        let pointed : Files.LoadOrder :=
          { order with
            point := some { row := 3, column := 4 }, focus := true }
        pure
          (Files.LoadOrder.ofArguments? order.arguments == some order &&
            Files.LoadOrder.ofArguments? pointed.arguments == some pointed &&
            Files.LoadOrder.ofArguments? { pointed with focus := false }.arguments ==
              some { pointed with focus := false } &&
            order.arguments == [.str "/a", .nat 2, .str "/b"] &&
            Files.LoadOrder.ofArguments? [.str "/a", .nat 2] ==
              some { path := "/a", view := ⟨2⟩ }) }]

/-- Whether some piece of the whole text of the buffer `driver`'s view 0
shows was written by an edit of origin `origin`. -/
def tracedTo (driver : TestDriver) (origin : Origin) : Bool :=
  match showing driver with
  | none => false
  | some shown =>
    match shown.text with
    | none => false
    | some text =>
      match ((shown.buffer.text.trace 0 text.utf8ByteSize).runModel driver.model.texts).1 with
      | .ok pieces =>
        pieces.any fun piece =>
          match piece.author with
          | .entry _ by_ => by_ == origin
          | .earlier _ => false
      | .error _ => false

/-- The checks of reloading a buffer from its file (`Files.reload`,
`Files.reloaded`, `Editor/Files.lean`), on the loop's driver over the
editor's models and the model of files, with the commands and the jobs
compiled code registers. -/
def fileReloadChecks : List Check :=
  let textOf (driver : TestDriver) : Option String := (showing driver).bind (·.text)
  [{  name :=
        "one undo after a reload is the text from before it: the reload shows the file's new text, not modified, as one step over the opened root traced to the disk origin, and one undo brings the old text back, modified"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let (asked, _) := fedTo rewritten (presses "C-o r")
            let reloaded := finishNamed asked Files.reloadJob
            let (undone, _) := fedTo reloaded (presses "C-o u")
            (pendingOf asked Files.reloadJob).isSome && textOf reloaded == some reloadedText &&
              statusOf reloaded == some (named "note.txt") &&
              (showing reloaded).map (·.buffer.history.nodes.size) == some 2 &&
              tracedTo reloaded Origin.disk &&
              (heldFile reloaded).map (·.stamp) == stampOf reloaded (inFiles "note.txt") &&
              textOf undone == some FileCases.noteText &&
              statusOf undone == some (namedModified "note.txt") },
    { name :=
        "a reload of a buffer with unsaved edits changes nothing and says why: no reload job is started, the text is the edited text, and the echo area names :e!; edits made while the file loaded refuse it the same way when it is delivered"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let (edited, _) := fedTo rewritten [.commit "x"]
            let (refused, _) := fedTo edited (presses "C-o r")
            let (asked, _) := fedTo rewritten (presses "C-o r")
            let (late, _) := fedTo asked [.commit "x"]
            let lateRefused := finishNamed late Files.reloadJob
            (pendingOf refused Files.reloadJob).isNone &&
              textOf refused == some ("x" ++ FileCases.noteText) &&
              echoOf refused == some (Files.notReloading "note.txt") &&
              textOf lateRefused == some ("x" ++ FileCases.noteText) &&
              echoOf lateRefused == some (Files.notReloading "note.txt") &&
              (pendingOf lateRefused Files.reloadJob).isNone },
    { name :=
        "a forced reload takes the file's text as one step: after it the buffer is not modified, one undo brings the edited text back, modified, and one redo the file's text again; the ex line e! does the same"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let (edited, _) := fedTo rewritten [.commit "x"]
            let forced := finishNamed (fedTo edited (presses "C-o R")).1 Files.reloadJob
            let (undone, _) := fedTo forced (presses "C-o u")
            let (redone, _) := fedTo undone (presses "C-o U")
            let byEx := finishNamed (fedTo edited (exLine "e!")).1 Files.reloadJob
            textOf forced == some reloadedText && statusOf forced == some (named "note.txt") &&
              textOf undone == some ("x" ++ FileCases.noteText) &&
              statusOf undone == some (namedModified "note.txt") &&
              textOf redone == some reloadedText &&
              textOf byEx == some reloadedText &&
              (showing byEx).map (·.buffer.isModified) == some false },
    { name :=
        "a forced reload whose text moves while it loads applies nothing and starts one more reload, which reloads; if the text moves again the echo area says it was overtaken and the edited text stays"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let (asked, _) := fedTo rewritten (presses "C-o R")
            let (moved, _) := fedTo asked [.commit "x"]
            let retried := finishNamed moved Files.reloadJob
            let settled := finishNamed retried Files.reloadJob
            let (movedAgain, _) := fedTo retried [.commit "y"]
            let overtaken := finishNamed movedAgain Files.reloadJob
            textOf retried == textOf moved && (pendingOf retried Files.reloadJob).isSome &&
              pendingOf retried Files.reloadJob != pendingOf moved Files.reloadJob &&
              textOf settled == some reloadedText &&
              echoOf overtaken == some (Files.reloadOvertaken (inFiles "note.txt")) &&
              textOf overtaken == textOf movedAgain &&
              (pendingOf overtaken Files.reloadJob).isNone },
    { name :=
        "the ex line e with no argument reloads the window's buffer, and on the scratch buffer, which has no file, still asks for a path; a reload of a buffer with no file says so"
      run :=
        pure <|
          match noteRewritten, reloadDriver with
          | some rewritten, some fresh =>
            let byEx := finishNamed (fedTo rewritten (exLine "e")).1 Files.reloadJob
            let (asking, _) := fedTo fresh (exLine "e")
            let (noFile, _) := fedTo fresh (presses "C-o r")
            textOf byEx == some reloadedText &&
              asking.loop.state.prompt.map (·.label) == some Files.openPrompt &&
              echoOf noFile == some (Files.noReloadFile "scratch") &&
              (pendingOf noFile Files.reloadJob).isNone
          | _, _ => false }]

/-- The files of the file name checks: `/w` holds `alpha.txt`, `alps.md`,
`beta.txt` and the directories `notes` and `src`; `/w/notes` holds
`todo.md`; `/w/src` holds `main.lean`, `.env` and the directory
`.cache`. -/
def fileNameFiles : FileModel :=
  let model :=
    [("alpha.txt", "alpha\n"), ("alps.md", "alps\n"), ("beta.txt", "beta\n")].foldl
      (fun (model : FileModel) (name, text) => model.withFile ("/w" / name) text.toUTF8)
      ((({} : FileModel).withDirectory "/").withDirectory "/w")
  ((((model.withDirectory "/w/notes").withDirectory "/w/src").withFile "/w/notes/todo.md"
              "todo\n".toUTF8).withFile
          "/w/src/main.lean" "main\n".toUTF8).withFile
      "/w/src/.env" "env\n".toUTF8 |>.withDirectory
    "/w/src/.cache"

/-- What a step of the file name checks is handed: `C-o o` runs the open
command with no path, `TAB` the minibuffer's insert, `C-n` its next,
`C-u` its delete to the start, `<Backspace>` its delete backward and `RET`
its accept, and a key that prints is typed; the commands are the ones
compiled code registers for files and the minibuffer; the category `file`
is matched with the path style; and a prompt over more than `inline`
candidates is matched by a job. -/
def fileNameKeys (inline : Nat := Loop.inlineMatches) : Loop.Keys TestScheme.scheme :=
  let compiled : List (String × Dispatched) :=
    (Files.commands ++ Minibuffer.commands).toList.filterMap
      fun (registration : Config.Registration) =>
      match registration.action with
      | .call run =>
        let dispatched : Dispatched := fun call => do
          run call
          return none
        some (registration.name, dispatched)
      | _ => none
  let keys :=
    dispatchKeys
      [("C-o o", invoke Files.openName), ("TAB", invoke Minibuffer.insertName),
        ("C-n", invoke Minibuffer.nextName), ("C-u", invoke Minibuffer.deleteToStartName),
        ("<Backspace>", invoke Minibuffer.deleteBackwardName),
        ("RET", invoke Minibuffer.acceptName)]
      (compiled ++
        [((TestScheme.selfInsert "").command, fun call => do
            let [.str text] := call.arguments | throw .badRange
            call.target.insertAtSelections text
            return none)])
  { keys with
    inlineMatches := inline
    matching :=
      { default := Completion.Styles.fuzzy
        byCategory := fun category =>
          if category == Completion.Paths.category then some Completion.Styles.path else none } }

/-- A driver of the file name checks over the initial state with `directory`
(`/w` unless given) as the working directory and `home` as the home
directory, its jobs the ones
compiled code registers for files, over `files`; `none` if making the state
was refused. -/
def fileNameDriver (home : Option System.FilePath := none) (files : FileModel := fileNameFiles)
    (inline : Nat := Loop.inlineMatches) (directory : System.FilePath := "/w") :
    Option TestDriver :=
  let start : TextM EditorState := do
    return { (← EditorState.initial ⟨640, 480⟩) with
        workingDirectory := directory, home }
  (Loop.Driver.over (fileNameKeys inline)
        (fun name => (Files.jobs.find? (·.name == name)).map (·.work)) start
        editorModel).toOption.map
    fun driver => { driver with jobs := { driver.jobs with files } }

/-- `driver` once every job it holds at a post has posted and every job it
started has been delivered, for at most `fuel` deliveries. -/
def settled (driver : TestDriver) : (fuel : Nat := 64) → TestDriver
  | 0 => driver
  | fuel + 1 =>
    match driver.posting[0]? with
    | some job => settled (driver.posted job.id).1 fuel
    | none =>
      match driver.pending[0]? with
      | some job => settled (driver.finish job.id).1 fuel
      | none => driver

/-- The labels the open prompt of `driver` lists, a candidate with none by
its text. -/
def fileLabels (driver : TestDriver) : Array String :=
  ((candidatesOf driver).map
        (·.listed.map fun listed => listed.candidate.label.getD listed.text)).getD
    #[]

/-- The starts of the file source's job among `steps`. -/
def filesStarts (steps : Array (Option (Loop.Stepped TestScheme.scheme))) : Array JobStart :=
  ((steps.filterMap id).flatMap (·.starts)).filter (·.name == Completion.Paths.job)

/-- The checks of `open-file`'s prompt over file names, on the editor's
models with the file model: the file source, the path style, the insert and
the accept, through the loop's driver. -/
def fileNameChecks : List Check :=
  let opened? : Option TestDriver := do
    let driver ← fileNameDriver
    return settled (fedTo driver (presses "C-o o")).1
  let labels := #["notes/", "src/", "alpha.txt", "alps.md", "beta.txt"]
  let lasts := #["notes", "src", "alpha.txt", "alps.md", "beta.txt"]
  [{  name :=
        "AC 1 on the model: C-o o opens the prompt with /w/ and lists notes/, src/, alpha.txt, alps.md, beta.txt once the job is finished; typing al lists the fuzzy model's order over the last components, each with its matched range on its label"
      run :=
        pure <|
          match fileNameDriver, opened? with
          | some driver, some opened =>
            let (asked, _) := fedTo driver (presses "C-o o")
            let (typed, _) := fedTo opened (presses "a l")
            minibufferText asked == some "/w/" && fileLabels opened == labels &&
              fileLabels typed == (FuzzyModel.rank "al" lasts).filterMap (labels[·]?) &&
              (candidatesOf typed).map
                  (·.listed.all fun listed => !(Completion.Displays.labelRanges listed).isEmpty) ==
                some true
          | _, _ => false },
    { name :=
        "AC 2 on the model: C-n chooses notes/ and TAB makes the input /w/notes/, hands back a start of files whose order's text is /w/notes/, and once it is finished the listing is todo.md"
      run :=
        pure <|
          match opened? with
          | none => false
          | some opened =>
            let (inserted, steps) := fedTo opened (presses "C-n TAB")
            minibufferText inserted == some "/w/notes/" &&
              (filesStarts steps).map
                  (fun start =>
                    (Completion.Order.ofArguments? start.arguments).map (·.query.text)) ==
                #[some "/w/notes/"] &&
              fileLabels (settled inserted) == #["todo.md"] },
    { name :=
        "AC 3 on the model, with the counting fake: after C-o o, a, l, p and the job finished, /w was listed once and one files start was handed back; after TAB on notes/ the listings are /w and /w/notes"
      run :=
        pure <|
          match fileNameDriver with
          | none => false
          | some driver =>
            let (asked, first) := fedTo driver (presses "C-o o")
            let opened := settled asked
            let (typed, more) := fedTo opened (presses "a l p")
            let done := settled typed
            let into := settled (fedTo opened (presses "C-n TAB")).1
            done.jobs.files.listed == #[("/w" : System.FilePath)] &&
              (filesStarts first).size + (filesStarts more).size == 1 &&
              into.jobs.files.listed == #[("/w" : System.FilePath), "/w/notes"] },
    { name :=
        "AC 4 on the model: al, C-n, RET closes the prompt and starts load-file for the chosen file's path; once that is finished view 0 shows a buffer of that name holding the file's text"
      run :=
        pure <|
          match opened? with
          | none => false
          | some opened =>
            let (typed, _) := fedTo opened (presses "a l")
            let first := (fileLabels typed)[0]?.getD ""
            let (picked, _) := fedTo typed (presses "C-n RET")
            let shown := showing (settled picked)
            picked.loop.state.prompt.isNone && picked.pending.map (·.name) == #[Files.loadJob] &&
              shown.bind (·.buffer.file.map (·.path)) == some (("/w" : System.FilePath) / first) &&
              shown.map (·.buffer.name) == some first &&
              shown.bind (·.text) == some (if first == "alpha.txt" then "alpha\n" else "alps\n") },
    { name :=
        "dotfiles are hidden until . is typed, from one read: src/ lists main.lean alone; . lists .cache/, .env and main.lean in the fuzzy model's order in the scene of that key, with no files start; /w/src was read once; <Backspace> back to src/ hides them again"
      run :=
        pure <|
          match opened? with
          | none => false
          | some opened =>
            let inSrc := settled (fedTo opened (presses "C-u s r c /")).1
            let (dotted, steps) := fedTo inSrc (presses ".")
            let (back, _) := fedTo dotted (presses "<Backspace>")
            let dots := #[".cache/", ".env", "main.lean"]
            fileLabels inSrc == #["main.lean"] &&
              fileLabels dotted ==
                (FuzzyModel.rank "." #[".cache", ".env", "main.lean"]).filterMap (dots[·]?) &&
              (filesStarts steps).isEmpty &&
              (dotted.jobs.files.listed.filter (· == ("/w/src" : System.FilePath))).size == 1 &&
              dotted.jobs.files.listed.back? == some ("/w/src" : System.FilePath) &&
              fileLabels back == #["main.lean"] },
    { name := "RET on a chosen directory keeps the prompt open with /w/notes/"
      run :=
        pure <|
          match opened? with
          | none => false
          | some opened =>
            let (entered, _) := fedTo opened (presses "C-n RET")
            entered.loop.state.prompt.isSome && minibufferText entered == some "/w/notes/" },
    { name :=
        "a relative text is read under /w: notes/ lists todo.md, and RET on notes/todo.md opens /w/notes/todo.md; with /w as the home ~/alpha.txt opens /w/alpha.txt, and with no home it says the home is not known"
      run :=
        pure <|
          match opened?, fileNameDriver (home := some "/w"), fileNameDriver with
          | some opened, some homed, some homeless =>
            let relative := settled (fedTo opened (presses "C-u n o t e s /")).1
            let fileOf (driver : TestDriver) : Option System.FilePath :=
              (showing (settled driver)).bind (·.buffer.file.map (·.path))
            let relativeOpened := (fedTo relative (presses "t o d o . m d RET")).1
            let homedOpened :=
              (fedTo (settled (fedTo homed (presses "C-o o")).1)
                  (presses "C-u ~ / a l p h a . t x t RET")).1
            let refused :=
              (fedTo (settled (fedTo homeless (presses "C-o o")).1)
                  (presses "C-u ~ / a l p h a . t x t RET")).1
            fileLabels relative == #["todo.md"] &&
              fileOf relativeOpened == some "/w/notes/todo.md" &&
              fileOf homedOpened == some "/w/alpha.txt" &&
              refused.pending.isEmpty &&
              refused.loop.state.echo == "cannot open ~/alpha.txt: the home directory is not known"
          | _, _, _ => false },
    { name :=
        "a path given as an argument is not restarted: open-file /w//alpha.txt, as Finder hands it, opens /w/alpha.txt, and /w/~/beta.txt opens that file, not ~/beta.txt"
      run :=
        let files := fileNameFiles.withDirectory "/w/~" |>.withFile "/w/~/beta.txt" "tilde\n".toUTF8
        pure <|
          match fileNameDriver (home := some "/w") (files := files) with
          | none => false
          | some driver =>
            let fileOf (driver : TestDriver) : Option System.FilePath :=
              (showing (settled driver)).bind (·.buffer.file.map (·.path))
            let doubled := (fedTo driver [.openFiles ["/w//alpha.txt"]]).1
            let tilde := (fedTo driver [.openFiles ["/w/~/beta.txt"]]).1
            fileOf doubled == some "/w/alpha.txt" && fileOf tilde == some "/w/~/beta.txt" &&
              (showing (settled tilde)).bind (·.text) == some "tilde\n" },
    { name := "a path typed into the prompt is restarted: /w/src//w/alpha.txt opens /w/alpha.txt"
      run :=
        pure <|
          match opened? with
          | none => false
          | some opened =>
            let typed := (fedTo opened (presses "C-u / w / s r c / / w / a l p h a . t x t RET")).1
            (showing (settled typed)).bind (·.buffer.file.map (·.path)) == some "/w/alpha.txt" },
    { name :=
        "a directory with a ~ component, which no text can name through the restart, starts the prompt empty, read under that directory: it lists /srv/~/proj, not ~/proj, and RET on plan.md opens /srv/~/proj/plan.md"
      run :=
        let files :=
          ((fileNameFiles.withDirectory "/srv").withDirectory "/srv/~").withDirectory
              "/srv/~/proj" |>.withFile
            "/srv/~/proj/plan.md" "plan\n".toUTF8
        pure <|
          match
            fileNameDriver (home := some "/w") (files := files) (directory := "/srv/~/proj") with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o o")
            let opened := settled asked
            let picked := (fedTo opened (presses "p l C-n RET")).1
            minibufferText asked == some "" && fileLabels opened == #["plan.md"] &&
              (showing (settled picked)).bind (·.buffer.file.map (·.path)) ==
                some "/srv/~/proj/plan.md" },
    { name :=
        "an unreadable directory: TAB on notes/ says files: cannot list /w/notes/: the file system does not allow it, and lists nothing"
      run :=
        pure <|
          match fileNameDriver (files := { fileNameFiles with unreadable := #["/w/notes"] }) with
          | none => false
          | some driver =>
            let opened := settled (fedTo driver (presses "C-o o")).1
            let refused := settled (fedTo opened (presses "C-n TAB")).1
            refused.loop.state.echo ==
                "files: cannot list /w/notes/: the file system does not allow it" &&
              fileLabels refused == #[] },
    { name :=
        "performance, structurally: with a prompt matched by a job past 2 candidates, typing a within the directory hands back no files start and spawns one match, whose finish lists the path style's order"
      run :=
        pure <|
          match fileNameDriver (inline := 2) with
          | none => false
          | some driver =>
            let opened := settled (fedTo driver (presses "C-o o")).1
            let (typed, steps) := fedTo opened (presses "a")
            let spawned := ((steps.filterMap id).flatMap (·.spawns))
            let matched := settled typed
            (filesStarts steps).isEmpty && spawned.size == 1 &&
              spawned.map (·.label) == #[Loop.matchLabel] &&
              fileLabels matched == (FuzzyModel.rank "a" lasts).filterMap (labels[·]?) }]

end ModelTest
