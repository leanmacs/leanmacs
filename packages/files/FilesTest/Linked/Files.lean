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
import Editor.Language
import Editor.Mode
import Editor.Program
import Editor.Scene
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

The tests of `Files.lean`: `languageChecks`, `fileChecks`, `reloadChecks`,
`filePromptChecks` and `autoReloadChecks`, through the headless host on real
files, the last with the library's watch service: what the files feature's
follow job does through the loop, which starts it under the core's name
(the core's `lean/Editor/FileJobs.lean`). They were the config test's
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

/-- Runs `check` against a host over the library's file service
(`Stage.overFiles`), with an empty config directory of its own, that is
handed the file commands and their jobs as compiled code registers them
(`Files.package.registered.commands`, `Files.package.registered.jobs`), the
kit's minibuffer's commands and its mode (`Test.Minibuffer.package.registered.commands`,
`Test.Minibuffer.package.registered.modes`, `Editor/Test/Minibuffer.lean`), and,
for each name and path of `opens`, a command of that name that opens that
path (`opening`). Stops the host: `false` if the check did not hold or the
host did not stop. -/
def withFileHost (context : HostContext) (opens : List (String × System.FilePath))
    (check : Session → IO Bool) (extra : Array Config.Registration := #[]) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    let stage ←
      Stage.overFiles context (Config.Directory.source directory)
          { commands :=
              Files.package.registered.commands ++ Test.Minibuffer.package.registered.commands ++
                (opens.map fun (name, path) => opening name path).toArray ++
                extra
            jobs := Files.package.registered.jobs
            modes := Test.Minibuffer.package.registered.modes }
    onStage stage fun host stage =>
        check
          { host, directory, output := stage.output, threads := stage.threads, clock := stage.clock,
            watches := stage.watches, log := stage.log }

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

/-- Lines of a `setup` that define a language `rust` over the shipped one,
whose highlights query is its own, `(identifier) @variable`. -/
def rustOverride : String :=
  "  defineLanguage
    { Language.rust with
      syntaxTree := { Language.rust.syntaxTree with highlights := some \"(identifier) @variable\" } }
"

/-- Runs `check` against a host over the library's file service
(`Stage.overFiles`), with a config directory of its own holding
`languageReportText` with `more` lines of its `setup`, that is handed the file commands and
their jobs, the kit's minibuffer's commands and its mode
(`Editor/Test/Minibuffer.lean`), the `code` mode and the
languages that ship (`Language.modes`, `Language.shipped`), as the
executable is, and, for each name and path of `opens`, a command of that
name that opens that path (`opening`). Its syntax tree is the real binding
with every request recorded in the array `check` is handed
(`recordingSyntaxTree`). The config is loaded before `check` runs. Stops the
host: `false` if the check did not hold or the host did not stop. -/
def withLanguageHost (context : HostContext) (more : String)
    (opens : List (String × System.FilePath)) (check : Session → IO.Ref (Array String) → IO Bool) :
    IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeConfig directory [("init.lean", languageReportText more)]
    let asked ← IO.mkRef #[]
    let stage ←
      Stage.overFiles context (Config.Directory.source directory)
          { commands :=
              Files.package.registered.commands ++ Test.Minibuffer.package.registered.commands ++
                (opens.map fun (name, path) => opening name path).toArray
            jobs := Files.package.registered.jobs
            modes := Test.Minibuffer.package.registered.modes ++ Language.modes
            languages := Language.shipped }
    onStage
        { stage with
          collaborators := { stage.collaborators with syntaxTree := recordingSyntaxTree asked } }
        fun host stage => do
        let session : Session :=
          { host, directory, output := stage.output, threads := stage.threads, clock := stage.clock,
            watches := stage.watches, log := stage.log }
        session.ask [.reload]
        check session asked

/-- What the host's `language-report` says of the focused buffer once the
command `name` has opened its file: its language and its major mode,
quoted as the scene line has the echo area, or none when the open's jobs
did not settle. -/
def reportedAfter (session : Session) (name : String) : IO (Option String) := do
  unless ← session.ran name do
    return none
  session.ask [.run "language-report"]
  return some (← session.scene).1

/-- Whether no line of the host's scene says a highlights refusal. -/
def noHighlightsRefusal (session : Session) : IO Bool := do
  return (← session.sceneLines).all fun line => (line.splitOn "highlights:").length == 1

/-- The requests the entry of a buffer's mode makes of the syntax tree
port before its injections, for a language parsed with `grammar` and
highlighted with the grammar's shipped query, its captures mapped by
`captures` over the shipped default, as `recordedRequest` writes them. -/
def shippedHighlightRequests (grammar : String) (captures : List (String × Option FaceName) := []) :
    IO (Array String) :=
  return #["refreshAfter 500", s!"attach {grammar}", s!"shippedQuery {grammar} highlights",
      s!"compile {grammar}", "captureNames", ← shippedFaces grammar captures, "release"]

/-- The checks of a file's language through the headless host
(`Editor/Files.lean`, "Open"; `Editor/Language.lean`): the file commands
and the languages that ship as compiled code registers them, on real files,
with the real elaborator and the real syntax binding. They share the file
checks' table of waits (`Stage.overFiles`). -/
def languageChecks (context : HostContext) : List Check :=
  [{  name :=
        "opening a .rs file gives its buffer the language rust and the major mode code, and its text is attached with rust and highlighted with Rust's shipped query in the default faces, with no refusal said"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "main.rs"
          IO.FS.writeFile path "fn main() {\n    let x = 1;\n}\n"
          withLanguageHost context "" [("open-rs", path)] fun session asked => do
              let report ← reportedAfter session "open-rs"
              let requests ← asked.get
              return report == some "rust code".quote &&
                  requests.extract 0 7 == (← shippedHighlightRequests "rust") &&
                  (← noHighlightsRefusal session) },
    { name :=
        "opening a .json file and a .md file gives each buffer that language and the major mode code, and highlights its text with that grammar's shipped query; Markdown's inline grammar is injected"
      run :=
        IO.FS.withTempDir fun files => do
          let json := files / "data.json"
          let markdown := files / "notes.md"
          IO.FS.writeFile json "{\"a\": [1, true]}\n"
          IO.FS.writeFile markdown "# Title\n\nSome *text* here.\n"
          let jsonHeld ←
            withLanguageHost context "" [("open-json", json)] fun session asked => do
                let report ← reportedAfter session "open-json"
                return report == some "json code".quote &&
                    (← asked.get).extract 0 7 == (← shippedHighlightRequests "json") &&
                    (← noHighlightsRefusal session)
          let markdownHeld ←
            withLanguageHost context "" [("open-md", markdown)] fun session asked => do
                let report ← reportedAfter session "open-md"
                let requests ← asked.get
                return report == some "markdown code".quote &&
                    requests.extract 0 7 == (← shippedHighlightRequests "markdown") &&
                    requests.contains "injectLanguage markdown_inline" &&
                    (← noHighlightsRefusal session)
          return jsonHeld && markdownHeld },
    { name :=
        "opening a .toml file and a file named Cargo.lock gives each buffer the language toml and the major mode code, and highlights its text with TOML's shipped query, keys and table headers in the type face, strings in the string face, brackets in the punctuation face and booleans in the constant face, with no refusal said"
      run :=
        IO.FS.withTempDir fun files => do
          let toml := files / "mise.toml"
          let lock := files / "Cargo.lock"
          IO.FS.writeFile toml "[tools]\nrust = \"1.91\"\nenabled = true\n"
          IO.FS.writeFile lock "version = 4\n\n[[package]]\nname = \"cc\"\n"
          let expected ← shippedHighlightRequests "toml" Language.toml.syntaxTree.captures
          let faces := ((expected[5]?.getD "").replace "highlight " "").splitOn ", "
          let drawn :=
            ["syntax.type", "syntax.string", "syntax.punctuation", "syntax.operator",
                  "syntax.constant"].all
              faces.contains
          let opened (name : String) (path : System.FilePath) : IO Bool :=
            withLanguageHost context "" [(name, path)] fun session asked => do
              let report ← reportedAfter session name
              return report == some "toml code".quote && (← asked.get).extract 0 7 == expected &&
                  (← noHighlightsRefusal session)
          return drawn && (← opened "open-toml" toml) && (← opened "open-lock" lock) },
    { name :=
        "opening a .lean file and a file named lakefile.lean gives each buffer the language lean and the major mode code, and asks the syntax tree port to highlight its text with Lean's shipped query and the lean entry's captures, the faces asked for including the keyword, string, comment, constant and module faces, with no refusal said"
      run :=
        IO.FS.withTempDir fun files => do
          let main := files / "Main.lean"
          let lakefile := files / "lakefile.lean"
          IO.FS.writeFile main
              "/-- Says hello. -/\ndef main : IO Unit := IO.println \"hi\" -- greet\n"
          IO.FS.writeFile lakefile "import Lake\nopen Lake DSL\n\npackage demo\n"
          let expected ← shippedHighlightRequests "lean" Language.lean.syntaxTree.captures
          let faces := ((expected[5]?.getD "").replace "highlight " "").splitOn ", "
          let drawn :=
            ["syntax.keyword", "syntax.string", "syntax.comment", "syntax.constant",
                  "syntax.module"].all
              faces.contains
          let opened (name : String) (path : System.FilePath) : IO Bool :=
            withLanguageHost context "" [(name, path)] fun session asked => do
              let report ← reportedAfter session name
              return report == some "lean code".quote && (← asked.get).extract 0 7 == expected &&
                  (← noHighlightsRefusal session)
          return drawn && (← opened "open-lean" main) && (← opened "open-lake" lakefile) },
    { name :=
        "opening a file whose name matches no language gives its buffer no language and no major mode, and asks the syntax tree port nothing"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "notes.txt"
          IO.FS.writeFile path "plain\n"
          withLanguageHost context "" [("open-txt", path)] fun session asked => do
              let report ← reportedAfter session "open-txt"
              return report == some "none none".quote && (← asked.get).isEmpty },
    { name :=
        "a major mode with no syntax tree set over the code mode of an opened .rs file detaches its text"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "main.rs"
          IO.FS.writeFile path "fn main() {\n    let x = 1;\n}\n"
          let plain :=
            "  defineMode { name := \"plain\" }
  command \"to-plain\" (do discard <| (← editorState).frame.focused.setMajorMode \"plain\")
"
          withLanguageHost context plain [("open-rs", path)] fun session asked => do
              unless (← reportedAfter session "open-rs") == some "rust code".quote do
                return false
              let opened := (← asked.get).size
              session.ask [.run "to-plain", .run "language-report"]
              let report := (← session.scene).1
              let requests ← asked.get
              return report == "rust plain".quote &&
                  (requests.extract opened requests.size).contains "detach" },
    { name :=
        "config's language rust, over the shipped one, with its own highlights query, is the one an opened .rs file is highlighted with: its query is compiled in place of the shipped one, and its one capture drawn in its default face"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "main.rs"
          IO.FS.writeFile path "fn main() {\n    let x = 1;\n}\n"
          withLanguageHost context rustOverride [("open-rs", path)] fun session asked => do
              let report ← reportedAfter session "open-rs"
              let requests ← asked.get
              return report == some "rust code".quote &&
                  requests.extract 0 6 ==
                    #["refreshAfter 500", "attach rust", "compile rust", "captureNames",
                      "highlight syntax.variable", "release"] &&
                  !requests.contains "shippedQuery rust highlights" &&
                  (← noHighlightsRefusal session) }]

/-- The checks of files through the headless host (`Editor/Headless.lean`),
with the real elaborator, the real queue, the real text binding and the
library's file service: the checks of this executable whose hosts are over a
real service. They share one table of waits and one completion pump over it
(`HostContext.fileWaits`, `Stage.overFiles`), started by the first of them. No
other check of the gated run starts a pump, so none takes these checks'
completions.

The first is a job from config. The others are the file commands and their
jobs as compiled code registers them (`Files/Compiled.lean`), on real
files: each check writes its files' bytes itself, in a temporary directory
it makes, and hands its host the paths (`withFileHost`). -/
def fileChecks (context : HostContext) : List Check :=
  [{
      name :=
        "a job loads a file through the host and its handler makes a text of it, with its two-byte character: the job's line says ok, show prints the text, and the library then holds no snapshot more than before but the one of the loop's scene; a job whose file is not there fails with the refusal's description",
      run :=
        IO.FS.withTempDir fun files =>
          IO.FS.withTempDir fun config => do
            IO.FS.writeBinFile (files / "note.txt") "héllo\n".toUTF8
            writeConfig config [("init.lean", openText files)]
            let stage ← Stage.overFiles context (Config.Directory.source config)
            let snapshots ← Ffi.Snapshot.live
            let host ← Headless.start stage.collaborators
            try
              let ask (requests : List Headless.Request) : IO Unit := do
                for request in requests do
                  host.send request
                unless ← host.settle patience do
                  throw (IO.userError "the editor thread did not settle")
              ask [.reload]
              ask [.spawn "open"]
              let opened ← host.join patience
              ask [.spawn "missing"]
              let missed ← host.join patience
              ask [.show]
              -- The loop delivered the job's command, so it has a frame: the
              -- one snapshot more is the one its scene holds of the scratch
              -- buffer's text, which is text 0.
              let freed ← eventually (return (← Ffi.Snapshot.live) == snapshots + 1)
              let stopped ← host.stop patience
              return opened == .settled && missed == .settled && freed && stopped &&
                  (← stage.collaborators.held.size) == 0 &&
                  (← stage.output.get) ==
                    #["reload 1: installed, 1 files, 0 commands", "spawn open: job 1",
                      "job 1 open: ok", "spawn missing: job 2",
                      "job 2 missing: failed: nothing is at the path", "commands:", "text 0: \"\"",
                      "text 1: \"héllo\\n\""]
            catch error =>
              discard <| host.halt patience
              throw error },
    { name :=
        "the open command on a file in a temporary directory: the host says the load job started and ended, and the focused view shows a buffer whose text is the file's, with its cursor at the start, and whose status line is the file's base name alone"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          withFileHost context [("open-note", path)] fun session => do
              let joined ← session.ran "open-note"
              let (echo, lines) ← session.viewsAndStatus
              return joined &&
                  (← session.output.get).extract 0 3 ==
                    #["run open-note: ok", s!"job 1 {Files.loadJob}: started",
                      s!"job 1 {Files.loadJob}: ok"] &&
                  echo == "".quote &&
                  lines == #[viewLine noteText 0, noteStatus path] },
    { name :=
        "the save command on a modified buffer: after a commit the view's status line has the modified field, and once the save job has ended the file's bytes are the buffer's text, the echo area says the file was written, and the status line has the name alone"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          withFileHost context [("open-note", path)] fun session => do
              unless ← session.ran "open-note" do
                return false
              unless ← Event.post (.commit "x") do
                return false
              -- The commit was the buffer's first edit, which starts a check
              -- of its file: its lines are printed before the scene is asked.
              unless (← session.host.join patience) == .settled do
                return false
              let (_, edited) ← session.viewsAndStatus
              let saved ← session.ran Files.saveName
              let (echo, lines) ← session.viewsAndStatus
              return saved &&
                  edited ==
                    #[viewLine ("x" ++ noteText) 1,
                      noteStatus path (modified := true) (column := 1)] &&
                  endedOk (← session.output.get) Files.saveJob &&
                  (← IO.FS.readBinFile path) == ("x" ++ noteText).toUTF8 &&
                  echo == (Files.wrote path).quote &&
                  lines == #[viewLine ("x" ++ noteText) 1, noteStatus path (column := 1)] },
    { name :=
        "opening a path that is open starts no second load and makes no second text: the open command a second time prints its own line alone, and show lists the texts it listed before"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          withFileHost context [("open-note", path)] fun session => do
              unless ← session.ran "open-note" do
                return false
              let shown ← session.shown
              let before := (← session.output.get).size
              let again ← session.ran "open-note"
              let printed := (← session.output.get).extract before
              let (_, lines) ← session.viewsAndStatus
              return again && printed == #["run open-note: ok"] && (← session.shown) == shown &&
                  (shown.filter (·.startsWith "text ")).size == 2 &&
                  lines == #[viewLine noteText 0, noteStatus path] },
    { name :=
        "open then save with no edit writes the file and leaves its bytes as they were, for a file whose lines end in line feeds and one whose lines end in CRLF: each save job ends ok, the echo area says the file was written, and the bytes read back are the bytes the check wrote"
      run :=
        IO.FS.withTempDir fun files => do
          let cases : List (String × System.FilePath × ByteArray × Nat) :=
            [("open-lf", files / "lf.txt", "one\ntwo\n".toUTF8, 2),
              ("open-crlf", files / "crlf.txt", "one\r\ntwo\r\n".toUTF8, 4)]
          for (_, path, bytes, _) in cases do
            IO.FS.writeBinFile path bytes
          withFileHost context (cases.map fun (name, path, _, _) => (name, path)) fun session => do
              let mut held := true
              for (name, path, bytes, job) in cases do
                let opened ← session.ran name
                let saved ← session.ran Files.saveName
                let (echo, _) ← session.viewsAndStatus
                held :=
                  held && opened && saved && echo == (Files.wrote path).quote &&
                    (← session.output.get).contains s!"job {job} {Files.saveJob}: ok" &&
                    (← IO.FS.readBinFile path) == bytes
              return held },
    { name :=
        "a save of a buffer whose file changed on disk after it was loaded leaves the file as it is: the file's bytes are the ones written behind the editor, the view's status line still has the modified field, and the echo area says the changed-on-disk refusal with the stamp the file now has"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          withFileHost context [("open-note", path)] fun session => do
              unless ← session.ran "open-note" do
                return false
              -- Another length, so the change is seen whatever the file
              -- system's clock.
              let other := "another program wrote this, at another length\n".toUTF8
              IO.FS.writeBinFile path other
              let found ← stampOf path
              unless ← Event.post (.commit "x") do
                return false
              let saved ← session.ran Files.saveName
              let (echo, lines) ← session.viewsAndStatus
              -- The commit was the buffer's first edit, which starts a check:
              -- it finds the file changed, so the status line has the
              -- changed field too.
              return saved && (← IO.FS.readBinFile path) == other &&
                  lines ==
                    #[viewLine ("x" ++ noteText) 1,
                      noteStatus path (modified := true) (column := 1) (changed := true)] &&
                  echo == (Files.notSaved path (.changed (some found))).quote },
    { name :=
        "the open command on a path with no file: the echo area says the refusal, and the focused view still shows the buffer it showed, with its text, its cursor and its name"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "missing.txt"
          withFileHost context [("open-missing", path)] fun session => do
              unless ← Event.post (.commit "kept") do
                return false
              let joined ← session.ran "open-missing"
              let (echo, lines) ← session.viewsAndStatus
              return joined && (← session.output.get).contains s!"job 1 {Files.loadJob}: ok" &&
                  echo == (Files.notOpened path .notFound).quote &&
                  lines == #[viewLine "kept" 4, statusOf (modified := true) (cursor := ⟨0, 4⟩)] },
    { name :=
        "the open command with no path asks for one and opens the answer: run by its name, it lists the stage's working directory, /; with the path of a file in a temporary directory committed into the minibuffer after its /, read by the restart after //, which lists that directory, and the accept key pressed, the host says the listing jobs and the load job started and ended, the prompt is closed, and the view the command was asked from shows the file's text in a buffer called by its base name"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          withFileHost context [] fun session => do
              session.ask [.run Files.openName]
              -- The prompt lists the stage's working directory, /: the
              -- listing is waited for, so its job's lines are all printed.
              let listed := (← session.host.join patience) == .settled
              -- The path is committed after the prompt's /: the restart
              -- after // reads it as it is. Its directory is listed in
              -- turn, and waited for.
              unless ← Event.post (.commit path.toString) do
                return false
              let relisted := (← session.host.join patience) == .settled
              let asking ← session.sceneLines
              session.pressKeys acceptKeys
              let joined := (← session.host.join patience) == .settled
              let (echo, lines) ← session.viewsAndStatus
              let output ← session.output.get
              let typed := "/" ++ path.toString
              let files := Completion.Paths.job
              return listed && relisted && joined && !acceptKeys.isEmpty &&
                  asking.extract 1 5 ==
                    #[viewLine "" 0, statusOf, minibufferLine typed typed.utf8ByteSize,
                      promptStatus Files.openPrompt] &&
                  output.contains s!"run {Files.openName}: ok" &&
                  output.filter (·.startsWith "job ") ==
                    #[s!"job 1 {files}: started", s!"job 1 {files}: ok", s!"job 1 {files}: ok",
                      s!"job 2 {files}: started", s!"job 2 {files}: ok", s!"job 2 {files}: ok",
                      s!"job 3 {Files.loadJob}: started", s!"job 3 {Files.loadJob}: ok"] &&
                  echo == "".quote &&
                  lines == #[viewLine noteText 0, noteStatus path] }]

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

/-- The checks of reloading a buffer from its file (`Files.reload`,
`Editor/Files.lean`) through the headless host, on real files, with the
library's file and diff services. -/
def reloadChecks (context : HostContext) : List Check :=
  [{  name :=
        "criterion 1: a file rewritten behind its buffer is reloaded by e: the reload job ends ok, show prints the new text, the scene's view shows it with the cursor on the same character of the unchanged second row, and the status line has neither the modified field nor any other"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          let (old, new) := ("one\ntwo\nthree\n", "one, and more\ntwo\nthree\n")
          IO.FS.writeBinFile path old.toUTF8
          withFileHost context [("open-note", path)] (extra := #[placing "cursor" 6]) fun session =>
              do
              unless ← session.ran "open-note" do
                return false
              -- Row 1, column 2: the "o" of "two".
              session.ask [.run "cursor"]
              let (_, placed) ← session.viewsAndStatus
              IO.FS.writeBinFile path new.toUTF8
              let reloaded ← session.ran Files.editName
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
                  lines == #[viewLine new 16, status] }]

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

/-- Runs `check` on a host under the Vim scheme over `promptFiles`, with
`open-file` run, its listing of `/` waited for, `w/` committed after its
`/`, and the listing of `/w/` waited for. -/
def atW (context : HostContext) (check : Session → IO Bool) : IO Bool :=
  withVimHost context [] (fileModel := some promptFiles) fun session => do
    session.ask [.run Files.openName]
    unless (← session.host.join patience) == .settled do
      return false
    unless ← Event.post (.commit "w/") do
      return false
    unless (← session.host.join patience) == .settled do
      return false
    check session

/-- The checks of the file prompt and of putting a candidate into the
minibuffer, over the recorder, under the Vim scheme that ships. -/
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
    { name :=
        "AC 2 over the recorder: at /w/, n o TAB makes the input /w/notes/ and starts one listing, after which t lists todo.md"
      run :=
        atW context fun session => do
          let before := listingsStarted (← session.output.get)
          session.typed "n o TAB"
          let inserted ← session.sceneLines
          unless (← session.host.join patience) == .settled do
            return false
          session.typed "t"
          let typed ← session.sceneLines
          return minibufferHolds inserted "/w/notes/" && listLabels typed == ["todo.md"] &&
              listingsStarted (← session.output.get) == before + 1 },
    { name :=
        "AC 4 over the recorder, on real files: in a temporary directory holding alpha.txt and alps.md, committed after the prompt's /, a l C-n RET opens the first listed file: view 0's status line names it, the view holds its text, and the load job ended"
      run :=
        IO.FS.withTempDir fun directory => do
          IO.FS.writeFile (directory / "alpha.txt") "alpha\n"
          IO.FS.writeFile (directory / "alps.md") "alps\n"
          withVimHost context [] (realFiles := true) fun session => do
              session.ask [.run Files.openName]
              unless (← session.host.join patience) == .settled do
                return false
              unless ← Event.post (.commit s!"{directory}/") do
                return false
              unless (← session.host.join patience) == .settled do
                return false
              let some first := (← realOrder "al" #["alpha.txt", "alps.md"])[0]? | return false
              session.typed "a l C-n RET"
              unless (← session.host.join patience) == .settled do
                return false
              let lines ← session.sceneLines
              let text := if first == "alpha.txt" then "alpha\n" else "alps\n"
              let output ← session.output.get
              return lines.any
                    (fun line =>
                      line.startsWith "status 0 in mode-line.active: " &&
                        (line.splitOn s!"mode-line.buffer {first.quote}").length > 1) &&
                  lines.any (fun line => line.startsWith s!"view 0 0,0 0x0: {text.quote}") &&
                  output.any
                    (fun line =>
                      line.startsWith "job " && line.endsWith s!" {Files.loadJob}: ok") &&
                  !output.any (·.startsWith "loop: refused") },
    { name :=
        "the host's home reaches the editor, on real files: started with a temporary directory as its home and its notes/ as its working directory, open-file asks with ~/notes/ and lists todo.md, and ~/alpha.txt RET opens the home's alpha.txt"
      run :=
        IO.FS.withTempDir fun home => do
          IO.FS.writeFile (home / "alpha.txt") "alpha\n"
          IO.FS.createDir (home / "notes")
          IO.FS.writeFile (home / "notes" / "todo.md") "todo\n"
          withVimHost context [] (realFiles := true) (workingDirectory := home / "notes") (home :=
              some home) fun session => do
              session.ask [.run Files.openName]
              unless (← session.host.join patience) == .settled do
                return false
              let asked ← session.sceneLines
              session.typed "C-u"
              unless ← Event.post (.commit "~/alpha.txt") do
                return false
              unless (← session.host.join patience) == .settled do
                return false
              session.typed "RET"
              unless (← session.host.join patience) == .settled do
                return false
              let lines ← session.sceneLines
              return minibufferHolds asked "~/notes/" && listLabels asked == ["todo.md"] &&
                  lines.any (fun line => line.startsWith s!"view 0 0,0 0x0: {"alpha\n".quote}") &&
                  lines.any
                    (fun line =>
                      line.startsWith "status 0 in mode-line.active: " &&
                        (line.splitOn s!"mode-line.buffer {"alpha.txt".quote}").length > 1) &&
                  !(← session.output.get).any (·.startsWith "loop: refused") },
    { name :=
        "AC 6 over the recorder: committing w/locked/ says files: cannot list /w/locked/: the file system does not allow it in the echo area and lists nothing; RET then says the load's refusal, and no prompt is left open"
      run :=
        withVimHost context [] (fileModel := some promptFiles) fun session => do
          session.ask [.run Files.openName]
          unless (← session.host.join patience) == .settled do
            return false
          unless ← Event.post (.commit "w/locked/") do
            return false
          unless (← session.host.join patience) == .settled do
            return false
          let lines ← session.sceneLines
          let (echo, _) ← session.scene
          session.typed "RET"
          unless (← session.host.join patience) == .settled do
            return false
          let (after, views) ← session.scene
          return echo == "files: cannot list /w/locked/: the file system does not allow it".quote &&
              (listRows lines).getD [""] == [""] &&
              after == (Files.notOpened "/w/locked" .notAFile).quote &&
              views.size == 1 &&
              !(← session.output.get).any (·.startsWith "loop: refused") },
    { name :=
        "AC 5: under the Vim scheme, in a prompt that is not a file prompt, C-n C-n TAB puts the second listed candidate in the minibuffer with the bar at its end, not the first; e TAB puts the first listed for e; the prompt stays open, its status line and the list view still drawn, and nothing is refused"
      run :=
        withVimHost context [("init.lean", pickText)] fun session => do
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

/-- The checks of auto-reload through the headless host on real files, with
the library's watch service (`Editor/Loop.lean`, "Auto-reload"): criteria 9
and 10. Measured on 2026-11-16 on macOS (FSEvents), over six runs: the
rewrite was shown 66 to 83 ms after the other process exited, a median of
about 80 ms, and the edited buffer marked in 78 to 84 ms; the 50 ms
coalescing window is most of it. The bound is a second, and every wait is
polled, never a fixed sleep. -/
def autoReloadChecks (context : HostContext) : List Check :=
  [{  name :=
        "criteria 9 and 10 on real files: with auto-reload on, another process's rewrite of an unmodified buffer's file is shown within a second; once the buffer is edited, another rewrite leaves its text and marks its status line within a second"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          let (old, new, again) := ("one\ntwo\n", "one\ntwo\nthree\n", "rewritten again\n")
          IO.FS.writeBinFile path old.toUTF8
          withFileHost context [("open-note", path)] fun session => do
              unless ← session.ran "open-note" do
                return false
              -- With no argument the command toggles: off, so on.
              session.ask [.run Files.autoReloadName]
              let armed ←
                eventually do
                    return (← session.output.get).any fun line =>
                        line.startsWith "job " && line.endsWith s!" {FileJobs.followJob}: started"
              unless armed do
                return false
              unless ← rewriteFromOutside path new do
                return false
              let (shown, saw) ← session.within 1000 (·.contains (viewLine new 0))
              unless shown.isSome do
                throw (IO.userError s!"the rewrite was not shown within a second: {saw}")
              unless ← Event.post (.commit "x") do
                return false
              unless ← rewriteFromOutside path again do
                return false
              let edited := "x" ++ new
              let (marked, last) ←
                session.within 1000 fun lines =>
                    lines ==
                      #[viewLine edited 1,
                        statusOf (name := "note.txt") (modified := true) (cursor := ⟨0, 1⟩)
                          (lines := 3) (file := some path) (changed := true)]
              unless marked.isSome do
                throw (IO.userError s!"the edited buffer was not marked within a second: {last}")
              return (← IO.FS.readBinFile path) == again.toUTF8 }]

end FilesTest.Linked
