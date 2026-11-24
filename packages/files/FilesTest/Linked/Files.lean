import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Completion
import Editor.Config.Packages
import Editor.Event
import Editor.Ex.Line
import Editor.Face
import Editor.File
import Editor.File.Model
import Editor.InputScheme.Test
import Editor.Job.Fake
import Editor.Language
import Editor.Mode
import Editor.Package
import Editor.Program
import Editor.Setup
import Editor.Test.Editing
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Lines
import Editor.Test.Linked.Shipped
import Editor.Test.Minibuffer
import Editor.Text
import Editor.Text.Model
import Files
import Files.Compiled
import Files.Paths
import FilesTest.Check

/-!
# Linked tests: `Files.lean`

The tests of `Files.lean`: `languageChecks`, `fileChecks`, `reloadChecks`
and `filePromptChecks`, through the headless host, stepped over the fakes.
The checks over the library's services, its watch service among them, are
of the wiring set (`FilesTest/Linked/Files/Real.lean`). They were the config test's
(`ConfigTest.<name>`, `lean/ConfigTest/Editor/Files.lean`) while the file
commands were modules of the core, and moved here with their sentences as
they were. The linked test's root, `FilesTest/Linked.lean`, runs them; its
module doc says what each shows.
-/

namespace FilesTest.Linked

open Editor
open Editor.Test.Linked

/-- A compiled command called `name`, written for the file checks, that runs
the compiled open command with `path` as its argument: the driver's `run`
hands a command no argument, so a check that opens a file hands its host a
command of this kind for each path. It looks the open command up among the
commands compiled code registers (`Files.package.registered.commands`), so what runs is that
registration. -/
def opening (name : String) (path : System.FilePath) : Config.Registration :=
  { name
    action :=
      .call fun call => do
        let registered : Option Config.Action :=
          (Files.package.registered.commands.find? (·.name == Files.openName)).map (·.action)
        match registered with
        | some (.call run) =>
          run { call with arguments := [.str path.toString] }
        | _ =>
          message "the open command is not a compiled command that is given its call" }

/-- What compiled code hands the file checks' hosts: the file commands and
their jobs as compiled code registers them
(`Files.package.registered.commands`, `Files.package.registered.jobs`), the
kit's minibuffer's commands and its mode
(`Test.Minibuffer.package.registered.commands`,
`Test.Minibuffer.package.registered.modes`, `Editor/Test/Minibuffer.lean`),
and, for each name and path of `opens`, a command of that name that opens
that path (`opening`), and `extra`. -/
def fileCompiled (opens : List (String × System.FilePath)) (extra : Array Config.Registration) :
    Compiled :=
  { commands :=
      Files.package.registered.commands ++ Test.Minibuffer.package.registered.commands ++
        (opens.map fun (name, path) => opening name path).toArray ++
        extra
    jobs := Files.package.registered.jobs
    modes := Test.Minibuffer.package.registered.modes }

/-- The directory of the stepped file checks' files: a made-up path, which
only the fake files' model holds. -/
def filesDirectory : System.FilePath :=
  "/files"

/-- A model of files holding `/`, `filesDirectory` and each of `files`, a
path and its bytes. -/
def filesModel (files : List (System.FilePath × ByteArray)) : FileModel :=
  files.foldl (fun model (path, bytes) => model.withFile path bytes)
    ((({} : FileModel).withDirectory "/").withDirectory filesDirectory)

/-- Runs `check` against a host stepped on the check's thread over a stepped
stage (`Stage.stepped`) handed `fileCompiled opens extra`, whose file fake
holds `files`, with an empty config directory of its own: its jobs run on
the check's steps, and what they write is read from the fake's model.
`false` if the check did not hold or the host did not settle. -/
def withFileHost (context : HostContext) (opens : List (String × System.FilePath))
    (files : FileModel) (check : Session → IO Bool) (extra : Array Config.Registration := #[]) :
    IO Bool :=
  IO.FS.withTempDir fun directory => do
    let stage ←
      Stage.new context context.elaborator (Config.Directory.source directory)
          (fileCompiled opens extra)
    let stage ← stage.stepped files
    onStage stage fun drive stage => check (Session.ofStage drive directory stage)

/-- The file fake of a session's stepped stage. Throws on a session with no
fakes. -/
def fakeFiles (session : Session) : IO Job.FakeFiles := do
  let some fakes := session.fakes | throw (IO.userError "the session's stage is not stepped")
  return fakes.services.files

/-- The bytes the file fake of `session`'s stage holds at `path`, if any. -/
def modelBytes (session : Session) (path : System.FilePath) : IO (Option ByteArray) := do
  return ((← (← fakeFiles session).model).file? path).map (·.bytes)

/-- The stamp the file fake of `session`'s stage has for `path`, if any. -/
def modelStamp (session : Session) (path : System.FilePath) : IO (Option File.Stamp) := do
  return ((← (← fakeFiles session).model).file? path).map (·.stamp)

/-- Writes `bytes` as the file at `path` in the file fake of `session`'s
stage, behind the editor, as another program writes. -/
def writeBehind (session : Session) (path : System.FilePath) (bytes : ByteArray) : IO Unit := do
  (← fakeFiles session).state.modify fun state =>
      { state with model := state.model.withFile path bytes }

/-- A config whose `setup` registers two jobs that each load a file and whose
handler makes a text of what was loaded: `open`, of `note.txt` in
`directory`, and `missing`, of a file that is not there. A load that is
refused is thrown, as the refusal's description. -/
def openText (directory : System.FilePath) : String :=
  "def openFile (path : String) : Unit → JobM JobSnapshotId := fun _ => do
  match ← File.load path 1000 with
  | .ok file => return file.snapshot
  | .error error => throw error.describe

def setup : SetupM Unit := do
  job \"open\" (openFile " ++
    (directory / "note.txt").toString.quote ++
    ") fun loaded => discard loaded.toText
  job \"missing\" (openFile " ++
    (directory / "missing.txt").toString.quote ++
    ") fun loaded => discard loaded.toText
"

/-- The stamp of the file at `path`, as the file system has it: when it was
last modified, and how long it is. -/
def stampOf (path : System.FilePath) : IO File.Stamp := do
  let metadata ← path.metadata
  return {
      seconds := metadata.modified.sec, nanoseconds := metadata.modified.nsec.toNat
      size := metadata.byteSize.toNat }

/-- The status line of view 0 on `noteText` opened from `path`, called
`note.txt`, its cursor on the first row at `column`: two rows, the empty one
after the final line break not counted (`statusOf`). -/
def noteStatus (path : System.FilePath) (modified : Bool := false) (column : Nat := 0)
    (changed : Bool := false) : String :=
  statusOf (name := "note.txt") (modified := modified) (cursor := ⟨0, column⟩) (lines := 2) (file :=
    some path) (changed := changed)

/-- A config whose `setup` registers `language-report`, which says in the
echo area the language and the major mode of the buffer the focused window
shows, each `none` when it has none (`rust code`, `none none`), and then
runs `more`, lines of a `do` block indented by two spaces. -/
def languageReportText (more : String := "") : String :=
  "def report : EditorM Unit := do
  let state ← editorState
  match state.target? state.frame.focused with
  | some target =>
    message (target.buffer.language.getD \"none\" ++ \" \" ++ target.buffer.major.getD \"none\")
  | none => message \"no window\"

def setup : SetupM Unit := do
  command \"language-report\" report
" ++
    more

/-- Runs `check` against a host stepped on the check's thread over a stepped
stage (`Stage.stepped`) whose file fake holds `files`, handed what
`languageStage` hands its host, whose syntax tree is the stage's fake of the
syntax service (`Stage.fakeSyntaxService`) with every request recorded
(`recordedRequest`) in the array `check` is handed: the requests the host
hands the syntax port are the subject, and the fake records them on the
check's thread. The config is loaded before `check` runs. -/
def withLanguageHost (context : HostContext) (more : String)
    (opens : List (String × System.FilePath)) (files : FileModel)
    (check : Session → IO.Ref (Array String) → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeConfig directory [("init.lean", languageReportText more)]
    let stage ←
      Stage.new context context.elaborator (Config.Directory.source directory)
          { commands :=
              Files.package.registered.commands ++ Test.Minibuffer.package.registered.commands ++
                (opens.map fun (name, path) => opening name path).toArray
            jobs := Files.package.registered.jobs
            modes := Test.Minibuffer.package.registered.modes ++ Language.modes
            languages := Language.shipped }
    let (stage, fake) ← (← stage.stepped files).fakeSyntaxService
    let asked ← IO.mkRef #[]
    let recorded : SyntaxTreeHandler := fun request => do
      asked.modify (·.push (recordedRequest request))
      fake.handle request
    let stage :=
      { stage with
        collaborators := { stage.collaborators with syntaxTree := fun _ => pure recorded } }
    onStage stage fun drive stage => do
        let session := Session.ofStage drive directory stage
        session.ask [.reload]
        check session asked

/-- What the host's `language-report` says of the focused buffer once the
command `name` has opened its file: its language and its major mode,
quoted as the scene line has the echo area, or none when the open's jobs
did not end. On a stepped stage the run is stepped to rest
(`Session.ranStepped`); on a real host it waits for the run's own jobs'
end lines (`Session.outputReaches`). -/
def reportedAfter (session : Session) (name : String) : IO (Option String) := do
  if session.fakes.isSome then
    unless ← session.ranStepped name do
      return none
  else
    let before := (← session.output.get).size
    session.ask [.run name]
    let ended (lines : Array String) : Bool :=
      let since := lines.extract before lines.size
      since.any (·.endsWith ": started") && startedJobsEnded since
    unless ← session.outputReaches ended do
      return none
  session.ask [.run "language-report"]
  return some (← session.scene).1

/-- Whether no line of the host's scene says a highlights refusal. -/
def noHighlightsRefusal (session : Session) : IO Bool := do
  return (← session.sceneLines).all fun line => (line.splitOn "highlights:").length == 1

/-- The checks of a file's language through the headless host
(`packages/files/Files.lean`, "Open"; `Editor/Language.lean`): the file commands
and the languages that ship as compiled code registers them, with the real
elaborator. A json file and a file of no language are on a stepped stage
over the file fake and the syntax fake (`withLanguageHost`), whose model
holds json; the grammars and shipped queries the model does not hold, rust,
markdown, toml and lean, are the real syntax binding's, on a real host over
real files (`withRealLanguageHost`, row W91 of
`docs/dev-practices/inferred-waits.md`), sharing the file checks' table of
waits (`Stage.overFiles`). -/
def languageChecks (context : HostContext) : List Check :=
  [{  name :=
        "opening a .json file gives its buffer the language json and the major mode code, and highlights its text with json's shipped query"
      run :=
        -- On the syntax fake, whose model holds json and its highlights:
        -- the requests are the model's answers. Markdown's grammar and its
        -- injection are the syntax model's (`ModelTest/Editor/Highlight.lean`,
        -- injections), not this host's.
        let jsonModel := filesModel [(filesDirectory / "data.json", "{\"a\": [1, true]}\n".toUTF8)]
        withLanguageHost context "" [("open-json", filesDirectory / "data.json")] jsonModel
          fun session asked => do
          let report ← reportedAfter session "open-json"
          let requests ← asked.get
          saw
              (report == some "json code".quote &&
                requests.extract 0 7 ==
                  #["refreshAfter 500", "attach json", "shippedQuery json highlights",
                    "compile json", "captureNames",
                    "highlight syntax.string, syntax.string, syntax.number, syntax.constant",
                    "release"] &&
                (← noHighlightsRefusal session))
              s!"report {report}, requests {requests}" },
    { name :=
        "opening a file whose name matches no language gives its buffer no language and no major mode, and asks the syntax tree port nothing"
      run :=
        let path := filesDirectory / "notes.txt"
        withLanguageHost context "" [("open-txt", path)] (filesModel [(path, "plain\n".toUTF8)])
          fun session asked => do
          let report ← reportedAfter session "open-txt"
          return report == some "none none".quote && (← asked.get).isEmpty }]

/-- A check of `fileChecks`, a declaration of its own. -/
def jobLoadsFileThroughCheck (context : HostContext) : Check :=
  {
    name :=
      "a job loads a file through the host and its handler makes a text of it, with its two-byte character: the job's line says ok, show prints the text, and the host's table of what jobs hold is empty once the load's snapshot is released; a job whose file is not there fails with the refusal's description",
    run :=
      IO.FS.withTempDir fun config => do
        writeConfig config [("init.lean", openText filesDirectory)]
        let stage ←
          (← Stage.new context context.elaborator (Config.Directory.source config)).stepped
              (filesModel [(filesDirectory / "note.txt", "héllo\n".toUTF8)])
        let some fakes := stage.fakes | return false
        onStage stage fun drive stage => do
            let session := Session.ofStage drive config stage
            session.ask [.reload]
            session.ask [.spawn "open"]
            session.step
            session.ask [.spawn "missing"]
            session.step
            session.ask [.show]
            let released := (← fakes.services.files.released).map (·.number)
            saw
                ((← stage.collaborators.held.size) == 0 && released == #[0] &&
                  (← stage.output.get) ==
                    #["reload 1: installed, 1 files, 0 commands", "spawn open: job 1",
                      "job 1 open: ok", "spawn missing: job 2",
                      "job 2 missing: failed: nothing is at the path", "commands:", "text 0: \"\"",
                      "text 1: \"héllo\\n\""])
                s!"released {released}, held {← stage.collaborators.held.size}, output {← stage.output.get}" }

/-- A check of `fileChecks`, a declaration of its own. -/
def openCommandFileTemporaryCheck (context : HostContext) : Check :=
  { name :=
      "the open command on a file: the host says the load job started and ended, and the focused view shows a buffer whose text is the file's, with its cursor at the start, and whose status line is the file's base name alone"
    run :=
      let path := filesDirectory / "note.txt"
      withFileHost context [("open-note", path)] (filesModel [(path, noteText.toUTF8)])
        fun session => do
        let joined ← session.ranStepped "open-note"
        let (echo, lines) ← session.viewsAndStatus
        return joined &&
            (← session.output.get).extract 0 3 ==
              #["run open-note: ok", s!"job 1 {Files.loadJob}: started",
                s!"job 1 {Files.loadJob}: ok"] &&
            echo == "".quote &&
            lines == #[viewLine noteText 0, noteStatus path] }

/-- A check of `fileChecks`, a declaration of its own. -/
def openingPathOpenStartsCheck (context : HostContext) : Check :=
  { name :=
      "opening a path that is open starts no second load and makes no second text: the open command a second time prints its own line alone, and show lists the texts it listed before"
    run :=
      let path := filesDirectory / "note.txt"
      withFileHost context [("open-note", path)] (filesModel [(path, noteText.toUTF8)])
        fun session => do
        unless ← session.ranStepped "open-note" do
          return false
        let shown ← session.shown
        let before := (← session.output.get).size
        let again ← session.ranStepped "open-note"
        let printed := (← session.output.get).extract before
        let (_, lines) ← session.viewsAndStatus
        return again && printed == #["run open-note: ok"] && (← session.shown) == shown &&
            (shown.filter (·.startsWith "text ")).size == 2 &&
            lines == #[viewLine noteText 0, noteStatus path] }

/-- A check of `fileChecks`, a declaration of its own. -/
def openSaveEditWritesCheck (context : HostContext) : Check :=
  { name :=
      "open then save with no edit writes the file and leaves its bytes as they were, for a file whose lines end in line feeds and one whose lines end in CRLF: each save job ends ok, the echo area says the file was written, and the bytes the file fake holds are the bytes the check put there"
    run :=
      let cases : List (String × System.FilePath × ByteArray × Nat) :=
        [("open-lf", filesDirectory / "lf.txt", "one\ntwo\n".toUTF8, 2),
          ("open-crlf", filesDirectory / "crlf.txt", "one\r\ntwo\r\n".toUTF8, 4)]
      withFileHost context (cases.map fun (name, path, _, _) => (name, path))
        (filesModel (cases.map fun (_, path, bytes, _) => (path, bytes))) fun session => do
        let mut held := true
        for (name, path, bytes, job) in cases do
          let opened ← session.ranStepped name
          let saved ← session.ranStepped Files.saveName
          let (echo, _) ← session.viewsAndStatus
          held :=
            held && opened && saved && echo == (Files.wrote path).quote &&
              (← session.output.get).contains s!"job {job} {Files.saveJob}: ok" &&
              (← modelBytes session path) == some bytes
        return held }

/-- A check of `fileChecks`, a declaration of its own. -/
def saveBufferWhoseFileCheck (context : HostContext) : Check :=
  { name :=
      "a save of a buffer whose file changed after it was loaded leaves the file as it is: the file's bytes are the ones written behind the editor, the view's status line still has the modified field, and the echo area says the changed-on-disk refusal with the stamp the file now has"
    run :=
      let path := filesDirectory / "note.txt"
      withFileHost context [("open-note", path)] (filesModel [(path, noteText.toUTF8)])
        fun session => do
        unless ← session.ranStepped "open-note" do
          return false
        let other := "another program wrote this, at another length\n".toUTF8
        writeBehind session path other
        let some found ← modelStamp session path | return false
        session.commit "x"
        -- The commit was the buffer's first edit, which starts a check: it
        -- finds the file changed, so the status line has the changed field
        -- too. It is stepped to its end before the save, so the echo
        -- area's last word is the save's refusal, not the check's.
        session.step
        let saved ← session.ranStepped Files.saveName
        let (echo, lines) ← session.viewsAndStatus
        let bytes ← modelBytes session path
        saw
            (saved && bytes == some other &&
              lines ==
                #[viewLine ("x" ++ noteText) 1,
                  noteStatus path (modified := true) (column := 1) (changed := true)] &&
              echo == (Files.notSaved path (.changed (some found))).quote)
            s!"saved={saved} same={bytes == some other} echo={echo} lines={lines} output={← session.output.get}" }

/-- A check of `fileChecks`, a declaration of its own. -/
def openCommandPathFileCheck (context : HostContext) : Check :=
  { name :=
      "the open command on a path with no file: the echo area says the refusal, and the focused view still shows the buffer it showed, with its text, its cursor and its name"
    run :=
      let path := filesDirectory / "missing.txt"
      withFileHost context [("open-missing", path)] (filesModel []) fun session => do
        session.commit "kept"
        let joined ← session.ranStepped "open-missing"
        let (echo, lines) ← session.viewsAndStatus
        return joined && (← session.output.get).contains s!"job 1 {Files.loadJob}: ok" &&
            echo == (Files.notOpened path .notFound).quote &&
            lines == #[viewLine "kept" 4, statusOf (modified := true) (cursor := ⟨0, 4⟩)] }

/-- A check of `fileChecks`, a declaration of its own. -/
def openCommandPathAsksCheck (context : HostContext) : Check :=
  { name :=
      "the open command with no path asks for one and opens the answer: run by its name, it lists the stage's working directory, /; with the path of a file committed into the minibuffer after its /, read by the restart after //, which lists that directory, and the accept key pressed, the host says the listing jobs and the load job started and ended, the prompt is closed, and the view the command was asked from shows the file's text in a buffer called by its base name"
    run :=
      let path := filesDirectory / "note.txt"
      withFileHost context [] (filesModel [(path, noteText.toUTF8)]) fun session => do
        session.ask [.run Files.openName]
        -- The prompt lists the stage's working directory, /: the
        -- listing is waited for, so its job's lines are all printed.
        session.step
        -- The path is committed after the prompt's /: the restart
        -- after // reads it as it is. Its directory is listed in
        -- turn, and waited for.
        session.commit path.toString
        session.step
        let asking ← session.sceneLines
        session.pressKeys acceptKeys
        session.step
        let (echo, lines) ← session.viewsAndStatus
        let output ← session.output.get
        let typed := "/" ++ path.toString
        let files := Completion.Paths.job
        return !acceptKeys.isEmpty &&
            asking.extract 1 5 ==
              #[viewLine "" 0, statusOf, minibufferLine typed typed.utf8ByteSize,
                promptStatus Files.openPrompt] &&
            output.contains s!"run {Files.openName}: ok" &&
            output.filter (·.startsWith "job ") ==
              #[s!"job 1 {files}: started", s!"job 1 {files}: ok", s!"job 1 {files}: ok",
                s!"job 2 {files}: started", s!"job 2 {files}: ok", s!"job 2 {files}: ok",
                s!"job 3 {Files.loadJob}: started", s!"job 3 {Files.loadJob}: ok"] &&
            echo == "".quote &&
            lines == #[viewLine noteText 0, noteStatus path] }

/-- The checks of files through the headless host (`Editor/Headless.lean`),
with the real elaborator, the real queue, the real text binding and the
library's file service: the checks of this executable whose hosts are over a
real service. They share one table of waits and one completion pump over it
(`HostContext.fileWaits`, `Stage.overFiles`), started by the first of them. No
other check of the gated run starts a pump, so none takes these checks'
completions.

The first is a job from config. The others are the file commands and their
jobs as compiled code registers them (`Files/Compiled.lean`), on real
files: each check puts its files' bytes in the stage's file fake
(`withFileHost`, `filesModel`) and hands its host the paths; the save of a
modified buffer stays over the library's file service, its one end-to-end
check (`withFileServiceHost`). -/
def fileChecks (context : HostContext) : List Check :=
  [jobLoadsFileThroughCheck context, openCommandFileTemporaryCheck context,
    openingPathOpenStartsCheck context, openSaveEditWritesCheck context,
    saveBufferWhoseFileCheck context, openCommandPathFileCheck context,
    openCommandPathAsksCheck context]

/-- A compiled command called `name`, written for the reload checks, that
puts the cursor of the window it is called with at the byte `offset`, in the
shape the window's selection has. -/
def placing (name : String) (offset : Nat) : Config.Registration :=
  { name
    action :=
      .call fun call => do
        let current ← call.target.selection
        call.target.select
            { current with
              ranges := #[⟨offset, offset⟩], primary := 0 } }

/-- A check of `reloadChecks`, a declaration of its own. -/
def criterion1FileRewrittenCheck (context : HostContext) : Check :=
  { name :=
      "criterion 1: a file rewritten behind its buffer is reloaded by e: the reload job ends ok, show prints the new text, the scene's view shows it with the cursor on the same character of the unchanged second row, and the status line has neither the modified field nor any other"
    run :=
      let path := filesDirectory / "note.txt"
      let (old, new) := ("one\ntwo\nthree\n", "one, and more\ntwo\nthree\n")
      withFileHost context [("open-note", path)] (filesModel [(path, old.toUTF8)]) (extra :=
        #[placing "cursor" 6]) fun session => do
        unless ← session.ranStepped "open-note" do
          return false
        -- Row 1, column 2: the "o" of "two".
        session.ask [.run "cursor"]
        let (_, placed) ← session.viewsAndStatus
        writeBehind session path new.toUTF8
        let reloaded ← session.ranStepped Files.editName
        let (echo, lines) ← session.viewsAndStatus
        session.ask [.show]
        let output ← session.output.get
        -- The first line grew by ten bytes, so the "o" is at 16: on
        -- row 1, column 2, of three rows, before and after.
        let status :=
          statusOf (name := "note.txt") (cursor := ⟨1, 2⟩) (lines := 3) (file := some path)
        return reloaded && placed == #[viewLine old 6, status] &&
            output.contains s!"job 2 {Files.reloadJob}: ok" &&
            output.contains s!"text 1: {new.quote}" &&
            echo == "".quote &&
            lines == #[viewLine new 16, status] }

/-- The checks of reloading a buffer from its file (`Files.reload`,
`packages/files/Files.lean`) through the headless host, on a stepped stage:
the file rewritten behind the buffer in the file fake, the reload's load and
diff answered by it. -/
def reloadChecks (context : HostContext) : List Check :=
  [criterion1FileRewrittenCheck context]

/-- A config whose `setup` registers `pick`, which asks `Pick: ` over the
fixed candidates `wq`, `edit` and `w`, and `picked`, which says its
answer in the echo area. -/
def pickText : String :=
  "def setup : SetupM Unit := do
  command \"pick\" (discard <| prompt \"Pick: \" { command := \"picked\" }
    (sources := [.given (.ofTexts \"picks\" \"pick\" #[\"wq\", \"edit\", \"w\"])]))
  commandWith \"picked\" fun _ => message \"picked\"
"

/-- Whether `lines` show the minibuffer holding `text` with the bar at its
end, whichever view it is: a view line of that text with one selection,
empty, at its end. -/
def minibufferHolds (lines : Array String) (text : String) : Bool :=
  let at_ := text.utf8ByteSize
  lines.any fun line =>
    line.startsWith "view " &&
      (afterId line).startsWith s!": {text.quote}, scroll 0, selections {at_}..{at_}, padding"

/-- The rows the candidate list of `lines` shows, one a line, whichever view
it is: the text of the view line with no selection; `none` when no list is
drawn. -/
def listRows (lines : Array String) : Option (List String) :=
  lines.findSome? fun line =>
    let after := afterId line
    if line.startsWith "view " && (after.splitOn "selections , padding").length > 1 then
      match after.splitOn "\", scroll" with
      | head :: _ => some ((String.ofList (head.toList.drop 3)).splitOn "\\n")
      | [] => none
    else none

/-- The labels the candidate list of `lines` shows, each row's text up to its
first space: a row's annotation follows its label after spaces. -/
def listLabels (lines : Array String) : List String :=
  ((listRows lines).getD []).map fun row => String.ofList (row.toList.takeWhile (· != ' '))

/-- The files of the file prompt checks over the recorder: `/`, and in it
`/w`, holding `alpha.txt`, `alps.md`, `beta.txt`, `.hidden` and the
directories `notes` and `locked`; `/w/notes` holds `todo.md`; `/w/locked`
cannot be read. -/
def promptFiles : FileModel :=
  let model :=
    [("alpha.txt", "alpha\n"), ("alps.md", "alps\n"), ("beta.txt", "beta\n"),
          (".hidden", "hidden\n")].foldl
      (fun (model : FileModel) (name, text) => model.withFile ("/w" / name) text.toUTF8)
      ((({} : FileModel).withDirectory "/").withDirectory "/w")
  {
    (((model.withDirectory "/w/notes").withDirectory "/w/locked").withFile "/w/notes/todo.md"
      "todo\n".toUTF8) with
    unreadable := #["/w/locked"] }

/-- How many listing jobs `output` says were started. -/
def listingsStarted (output : Array String) : Nat :=
  (output.filter fun line =>
      line.startsWith "job " && line.endsWith s!" {Completion.Paths.job}: started").size

/-- The keys of the prompt checks under the test scheme, as a package
handed last: the kit's editing commands (`Test.editingCommands`), so a
printable key types its character, on the kit's editing keys but `RET`,
which the minibuffer's mode has; and `TAB` on the minibuffer's command that
puts a candidate in the input and `C-u` on the one that deletes to the
input's start, the keys a scheme's table of a minibuffer's view binds them
to. -/
def promptTyping : Package :=
  { name := "prompt-typing"
    setup := do
      for (name, run) in Test.editingCommands do
        commandWith name run
      for (text, name) in Test.editingKeys.filter (·.1 != "RET") do
        bindKey text name
      bindKey "TAB" Test.Minibuffer.insertName
      bindKey "C-u" Test.Minibuffer.deleteToStartName }

/-- Runs `check` against a host of the test scheme made as the executable's
hosts are made (`withShippedHost TestScheme.scheme`, which says what each
argument is), handed the harness's packages and then the checks' keys
(`promptTyping`), over a stepped stage (`Stage.stepped`) whose file fake
holds `fileModel`. -/
def withPromptHost (context : HostContext) (files : List (String × String))
    (check : Session → IO Bool) (fileModel : Option FileModel := none)
    (workingDirectory : System.FilePath := "/") (home : Option System.FilePath := none) : IO Bool :=
  withShippedHost TestScheme.scheme context files check fileModel workingDirectory home
    (context.packages.push promptTyping)

/-- Runs `check` on a host of the test scheme (`withPromptHost`) over
`promptFiles`, with `open-file` run, its listing of `/` waited for, `w/`
committed after its `/`, and the listing of `/w/` waited for. -/
def atW (context : HostContext) (check : Session → IO Bool) : IO Bool :=
  withPromptHost context [] (fileModel := some promptFiles) fun session => do
    session.ask [.run Files.openName]
    session.step
    session.commit "w/"
    session.step
    check session

/-- A check of `filePromptChecks`, a declaration of its own. -/
def ac2RecorderWCheck (context : HostContext) : Check :=
  { name :=
      "AC 2 over the recorder: at /w/, n o TAB makes the input /w/notes/ and starts one listing, after which t lists todo.md"
    run :=
      atW context fun session => do
        let before := listingsStarted (← session.output.get)
        session.typed "n o TAB"
        let inserted ← session.sceneLines
        session.step
        session.typed "t"
        let typed ← session.sceneLines
        return minibufferHolds inserted "/w/notes/" && listLabels typed == ["todo.md"] &&
            listingsStarted (← session.output.get) == before + 1 }

/-- A check of `filePromptChecks`, a declaration of its own. -/
def ac4RecorderRealCheck (context : HostContext) : Check :=
  { name :=
      "AC 4 over the recorder: in a directory holding alpha.txt and alps.md, committed after the prompt's /, a l C-n RET opens the first listed file: view 0's status line names it, the view holds its text, and the load job ended"
    run :=
      let directory : System.FilePath := "/d"
      let files :=
        ((((({} : FileModel).withDirectory "/").withDirectory directory).withFile
              (directory / "alpha.txt") "alpha\n".toUTF8).withFile
          (directory / "alps.md") "alps\n".toUTF8)
      withPromptHost context [] (fileModel := some files) fun session => do
        session.ask [.run Files.openName]
        session.step
        session.commit s!"{directory}/"
        session.step
        let some first := (← realOrder "al" #["alpha.txt", "alps.md"])[0]? | return false
        session.typed "a l C-n RET"
        session.step
        let lines ← session.sceneLines
        let text := if first == "alpha.txt" then "alpha\n" else "alps\n"
        let output ← session.output.get
        return lines.any
              (fun line =>
                line.startsWith "status 0 in mode-line.active: " &&
                  (line.splitOn s!"mode-line.buffer {first.quote}").length > 1) &&
            lines.any (fun line => line.startsWith s!"view 0 0,0 0x0: {text.quote}") &&
            output.any
              (fun line => line.startsWith "job " && line.endsWith s!" {Files.loadJob}: ok") &&
            !output.any (·.startsWith "loop: refused") }

/-- A check of `filePromptChecks`, a declaration of its own. -/
def hostHomeReachesEditorCheck (context : HostContext) : Check :=
  { name :=
      "the host's home reaches the editor: started with a directory as its home and its notes/ as its working directory, open-file asks with ~/notes/ and lists todo.md, and ~/alpha.txt RET opens the home's alpha.txt"
    run :=
      let home : System.FilePath := "/home"
      let files :=
        (((((({} : FileModel).withDirectory "/").withDirectory home).withDirectory
                  (home / "notes")).withFile
              (home / "alpha.txt") "alpha\n".toUTF8).withFile
          (home / "notes" / "todo.md") "todo\n".toUTF8)
      withPromptHost context [] (fileModel := some files) (workingDirectory := home / "notes")
        (home := some home) fun session => do
        session.ask [.run Files.openName]
        session.step
        let asked ← session.sceneLines
        session.typed "C-u"
        session.commit "~/alpha.txt"
        session.step
        session.typed "RET"
        session.step
        let lines ← session.sceneLines
        return minibufferHolds asked "~/notes/" && listLabels asked == ["todo.md"] &&
            lines.any (fun line => line.startsWith s!"view 0 0,0 0x0: {"alpha\n".quote}") &&
            lines.any
              (fun line =>
                line.startsWith "status 0 in mode-line.active: " &&
                  (line.splitOn s!"mode-line.buffer {"alpha.txt".quote}").length > 1) &&
            !(← session.output.get).any (·.startsWith "loop: refused") }

/-- A check of `filePromptChecks`, a declaration of its own. -/
def ac6RecorderCommittingCheck (context : HostContext) : Check :=
  { name :=
      "AC 6 over the recorder: committing w/locked/ says files: cannot list /w/locked/: the file system does not allow it in the echo area and lists nothing; RET then says the load's refusal, and no prompt is left open"
    run :=
      withPromptHost context [] (fileModel := some promptFiles) fun session => do
        session.ask [.run Files.openName]
        session.step
        session.commit "w/locked/"
        session.step
        let lines ← session.sceneLines
        let (echo, _) ← session.scene
        session.typed "RET"
        session.step
        let (after, views) ← session.scene
        return echo == "files: cannot list /w/locked/: the file system does not allow it".quote &&
            (listRows lines).getD [""] == [""] &&
            after == (Files.notOpened "/w/locked" .notAFile).quote &&
            views.size == 1 &&
            !(← session.output.get).any (·.startsWith "loop: refused") }

/-- The checks of the file prompt and of putting a candidate into the
minibuffer, over the recorder, under the test scheme with keys of the
checks' own (`promptTyping`): which keys a shipped scheme puts the
minibuffer's commands on is that scheme's. -/
def filePromptChecks (context : HostContext) : List Check :=
  [{  name :=
        "AC 1 over the recorder: the file prompt at /w/ lists locked/, notes/, alpha.txt, alps.md, beta.txt, directories first, notes/ annotated directory and no .hidden; after a l it lists the library's order of alpha.txt and alps.md"
      run :=
        atW context fun session => do
          let at_ ← session.sceneLines
          session.typed "a l"
          let typed ← session.sceneLines
          let labels := #["locked/", "notes/", "alpha.txt", "alps.md", "beta.txt"]
          let ordered ← realOrder "al" #["locked", "notes", "alpha.txt", "alps.md", "beta.txt"]
          let expected :=
            ordered.filterMap fun last =>
              labels.find? fun label => label == last || label == last ++ "/"
          return listLabels at_ == labels.toList &&
              ((listRows at_).getD []).any
                (fun row => row.startsWith "notes/" && row.endsWith "directory") &&
              listLabels typed == expected &&
              !(← session.output.get).any (·.startsWith "loop: refused") },
    { name :=
        "dotfiles over the recorder: at /w/, a . lists .hidden among the names that hold a ., in the library's order, in the scene of that key, and no listing is started for it"
      run :=
        atW context fun session => do
          let before := listingsStarted (← session.output.get)
          session.typed "."
          let dotted ← session.sceneLines
          let ordered ←
            realOrder "." #["locked", "notes", ".hidden", "alpha.txt", "alps.md", "beta.txt"]
          return listLabels dotted == ordered && ordered.contains ".hidden" &&
              listingsStarted (← session.output.get) == before },
    ac2RecorderWCheck context, ac4RecorderRealCheck context, hostHomeReachesEditorCheck context,
    ac6RecorderCommittingCheck context,
    { name :=
        "AC 5: in a prompt that is not a file prompt, the key of next-item twice and then the key of minibuffer-insert puts the second listed candidate in the minibuffer with the bar at its end, not the first; e and that key puts the first listed for e; the prompt stays open, its status line and the list view still drawn, and nothing is refused"
      run :=
        withPromptHost context [("init.lean", pickText)] fun session => do
          session.ask [.reload]
          let listed ← realOrder "" #["wq", "edit", "w"]
          let some second := listed[1]? | return false
          let some first := listed[0]? | return false
          session.ask [.run "pick"]
          session.typed "C-n C-n TAB"
          let chosen ← session.sceneLines
          session.typed "C-u e TAB"
          let fallback ← session.sceneLines
          let some typedFirst := (← realOrder "e" #["wq", "edit", "w"])[0]? | return false
          let open_ (lines : Array String) : Bool :=
            lines.any
                (fun line =>
                  line.startsWith "status " &&
                    (afterId line).endsWith "minibuffer.prompt \"Pick: \"") &&
              lines.any fun line =>
                line.startsWith "view " &&
                  ((afterId line).splitOn "selections , padding").length > 1
          return second != first && minibufferHolds chosen second && open_ chosen &&
              minibufferHolds fallback typedFirst &&
              open_ fallback &&
              !(← session.output.get).any (·.startsWith "loop: refused") },
    { name :=
        "the executable's hosts start with the source files registered by the files package in the category file, its job files, and the file category given the style named path, which no package of the core's Lake package registers"
      run := do
        let (state, _) :
          Config.State Config.Elaborate.Base Config.Elaborate.Handle × Array String :=
          Config.State.ofPackages context.packages
        let registry := state.registry
        return registry.sources.any
              (fun entry => entry.source.name == "files" && entry.owner == Files.package.owner) &&
            registry.sourcesIn Completion.Paths.category == #["files"] &&
            registry.jobs.any
              (fun entry =>
                entry.registration.name == Completion.Paths.job &&
                  entry.owner == Files.package.owner) &&
            (registry.style? "path").isNone &&
            registry.styleDefaults == #[(Completion.Paths.category, "path")] }]

/-- Rewrites the file at `path` with `text` from another process, as agents
and editors write: a temporary file beside it, renamed over it. Waits for
the process to exit; whether it exited with 0. -/
def rewriteFromOutside (path : System.FilePath) (text : String) : IO Bool := do
  let child ←
    IO.Process.output
        { cmd := "/bin/sh"
          args :=
            #["-c", "printf '%s' \"$2\" > \"$1.tmp\" && mv \"$1.tmp\" \"$1\"", "sh", path.toString,
              text] }
  return child.exitCode == 0

end FilesTest.Linked
