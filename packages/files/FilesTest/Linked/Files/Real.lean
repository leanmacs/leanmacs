import Editor.RealHost
import FilesTest.Linked.Files

/-!
# Linked tests: `Files.lean` over the library's services

A module of the wiring set (`AGENTS.md`, "Deterministic concurrency in
tests"; `docs/dev-practices/real-thread-checks.md`), beside the mirror of
`Files.lean`, `FilesTest/Linked/Files.lean`, whose stepped checks it must
not hold: the files feature's checks run the core's adapters through the
package's commands, and those adapters have no module of this package.

**The real adapters.** The library's file service (a write end to end, the
bytes on disk), its watch service (a change on disk reaching the buffer, on
a real host), and its syntax service with the shipped grammars and queries
the syntax model does not hold (rust, toml, lean; W91). **Why.** Each is a
real service's end-to-end check (AC4): the fakes stand in for them in every
other check of the package.

- `realLanguageChecks`: a .rs, a .toml and Cargo.lock, and a .lean and
  lakefile.lean, each attached and highlighted with its shipped grammar,
  wiring only; the order of a buffer's requests is the stepped json
  check's (`languageChecks`), the injections the syntax model's
  (`ModelTest/Editor/Highlight.lean`);
- `fileServiceChecks`: the save of a modified buffer writes its bytes to
  disk, wiring only; the echo and the status line are
  `FilesTest.fileCommandChecks`';
- `autoReloadChecks`: a rewrite on disk reaches an unmodified buffer over
  real watches, wiring only; criteria 9 and 10 are
  `FilesTest.autoReloadChecks`' over the watch model, the adapter
  `ContractTest/Editor/Watch/Contract.lean`'s.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.FilesTest.Linked.Files.Real : Editor.WiringSet :=
  .wiring "the library's file, watch and syntax services, through the files package's commands"
    "each is a real service's end-to-end check: the fakes stand in for them in every other check of the package"

namespace FilesTest.Linked

open Editor
open Editor.Test.Linked

/-- The stage of the file checks' hosts over the library's file service
(`Stage.overFiles`), with the config directory `directory`, handed
`fileCompiled opens extra`. -/
private def fileStage (context : HostContext) (directory : System.FilePath)
    (opens : List (String × System.FilePath)) (extra : Array Config.Registration) :
    IO (Stage Config.Elaborate.Base Config.Elaborate.Handle) :=
  Stage.overFiles context (Config.Directory.source directory) (fileCompiled opens extra)

/-- Runs `check` against a host stepped on the check's thread over the file
checks' stage on the library's file service (`fileStage`), with an empty
config directory of its own: for the file service's one end-to-end check
here. -/
private def withFileServiceHost (context : HostContext) (opens : List (String × System.FilePath))
    (check : Session → IO Bool) (extra : Array Config.Registration := #[]) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    let stage ← fileStage context directory opens extra
    onStage stage fun drive stage => check (Session.ofStage drive directory stage)

/-- `withFileServiceHost` with a real host (`onRealStage`), whose config
directory is `directory`, made here: the caller's, inside the bracket that
flushes the services before it removes it. -/
def withRealFileHost (context : HostContext) (directory : System.FilePath)
    (opens : List (String × System.FilePath)) (check : RealSession → IO Bool)
    (extra : Array Config.Registration := #[]) : IO Bool := do
  IO.FS.createDirAll directory
  let stage ← fileStage context directory opens extra
  onRealStage stage fun host stage => check (RealSession.ofStage host directory stage)

-- inferred-waits W91: stays (A5: the grammars and shipped queries of rust, markdown, toml and lean, which the syntax model does not hold, over the real binding)
set_option linter.inferredWait false in
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
def languageStage (context : HostContext) (directory : System.FilePath) (more : String)
    (opens : List (String × System.FilePath)) :
    IO (Stage Config.Elaborate.Base Config.Elaborate.Handle × IO.Ref (Array String)) := do
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
  return ({ stage with
        collaborators := { stage.collaborators with syntaxTree := recordingSyntaxTree asked } },
      asked)

/-- A real host (`onRealStage`) over `languageStage`'s stage: for a buffer that
attaches to the library's syntax service, whose parses come back over the
library's editor queue, with a grammar and shipped queries only the
library holds (row W91 of `docs/dev-practices/inferred-waits.md`). -/
def withRealLanguageHost (context : HostContext) (more : String)
    (opens : List (String × System.FilePath))
    (check : RealSession → IO.Ref (Array String) → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    let (stage, asked) ← languageStage context directory more opens
    onRealStage stage fun host stage => do
        let session := RealSession.ofStage host directory stage
        session.ask [.reload]
        check session asked

/-- The requests the entry of a buffer's mode makes of the syntax tree
port before its injections, for a language parsed with `grammar` and
highlighted with the grammar's shipped query, its captures mapped by
`captures` over the shipped default, as `recordedRequest` writes them. -/
def shippedHighlightRequests (grammar : String) (captures : List (String × Option FaceName) := []) :
    IO (Array String) :=
  return #["refreshAfter 500", s!"attach {grammar}", s!"shippedQuery {grammar} highlights",
      s!"compile {grammar}", "captureNames", ← shippedFaces grammar captures, "release"]

/-- The checks of a file's language over the library's syntax service
(this module's doc says what pins each). -/
def realLanguageChecks (context : HostContext) : List Check :=
  [{  name :=
        "opening a .rs file gives its buffer the language rust and the major mode code, and its text is attached with rust and highlighted over the library's syntax service, with no refusal said"
      run :=
        -- Wiring only: the shipped Rust grammar and highlights query, which
        -- the syntax model does not hold, are reached and answer. The order
        -- of the requests a buffer's mode makes is the stepped json check's
        -- (`languageChecks` in `FilesTest/Linked/Files.lean`).
        context.withFiles fun files => do
          let path := files / "main.rs"
          IO.FS.writeFile path "fn main() {\n    let x = 1;\n}\n"
          withRealLanguageHost context "" [("open-rs", path)] fun session asked => do
              let report ← reportedAfter session "open-rs"
              let requests ← asked.get
              return report == some "rust code".quote && requests.contains "attach rust" &&
                  requests.any (·.startsWith "highlight ") &&
                  (← noHighlightsRefusal session) },
    { name :=
        "opening a .toml file and a file named Cargo.lock gives each buffer the language toml and the major mode code, and highlights its text with TOML's shipped query, keys and table headers in the type face, strings in the string face, brackets in the punctuation face and booleans in the constant face, with no refusal said"
      run :=
        context.withFiles fun files => do
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
            withRealLanguageHost context "" [(name, path)] fun session asked => do
              let report ← reportedAfter session name
              return report == some "toml code".quote && (← asked.get).extract 0 7 == expected &&
                  (← noHighlightsRefusal session)
          return drawn && (← opened "open-toml" toml) && (← opened "open-lock" lock) },
    { name :=
        "opening a .lean file and a file named lakefile.lean gives each buffer the language lean and the major mode code, and asks the syntax tree port to highlight its text with Lean's shipped query and the lean entry's captures, the faces asked for including the keyword, string, comment, constant and module faces, with no refusal said"
      run :=
        context.withFiles fun files => do
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
            withRealLanguageHost context "" [(name, path)] fun session asked => do
              let report ← reportedAfter session name
              return report == some "lean code".quote && (← asked.get).extract 0 7 == expected &&
                  (← noHighlightsRefusal session)
          return drawn && (← opened "open-lean" main) && (← opened "open-lake" lakefile) }]

/-- A check of `fileChecks`, a declaration of its own. It stays over the
library's file service (row W37 of `docs/dev-practices/inferred-waits.md`):
the file service's write, end to end, with the bytes read back from disk.
Its waits are its own jobs' end lines: the load's, each check job the first
edit started, numbered from its started line, and the save's; the disk is
read after the save's. -/
def saveCommandModifiedBufferCheck (context : HostContext) : Check :=
  { name :=
      "the save command on a modified buffer, over the library's file service: once the save job has ended ok, the file's bytes on disk are the buffer's text"
    run :=
      -- Wiring only: the file service's write is reached and answers. The
      -- status line's modified field and the echo of the write are the
      -- model's (`FilesTest.fileCommandChecks`, "the save command on a
      -- modified buffer", `FilesTest/Files.lean`).
      context.withFiles fun files => do
        let path := files / "note.txt"
        IO.FS.writeBinFile path noteText.toUTF8
        withFileServiceHost context [("open-note", path)] fun session => do
            session.ask [.run "open-note"]
            unless ← session.outputReaches (endedOk · Files.loadJob) do
              return false
            let before := (← session.output.get).size
            session.commit "x"
            -- The commit was the buffer's first edit, which starts a check
            -- of its file: each job started since ends before the save.
            let checked (lines : Array String) : Bool :=
              let since := lines.extract before lines.size
              since.any (·.endsWith ": started") && startedJobsEnded since
            unless ← session.outputReaches checked do
              return false
            let asked := (← session.output.get).size
            session.ask [.run Files.saveName]
            unless
              ←
                session.outputReaches fun lines =>
                    endedOk (lines.extract asked lines.size) Files.saveJob do
              return false
            return (← IO.FS.readBinFile path) == ("x" ++ noteText).toUTF8 }

/-- The file service's end-to-end check (this module's doc says what pins
it). -/
def fileServiceChecks (context : HostContext) : List Check :=
  [saveCommandModifiedBufferCheck context]

/-- A check of `autoReloadChecks`, a declaration of its own. It stays on a
real host over the library's file and watch services (row W41 of
`docs/dev-practices/inferred-waits.md`): the watch service, end to end. Its
waits are its own jobs' lines, and its config directory is inside the
bracket that flushes the files and the watches before it is removed. -/
def criteria910RealCheck (context : HostContext) : Check :=
  { name :=
      "on real files, with auto-reload on, another process's rewrite of an unmodified buffer's file reaches the buffer over the library's watch service and is shown"
    run :=
      context.withFiles (targets := [.files, .fileWatches]) fun files => do
        let path := files / "note.txt"
        -- Wiring only: a change on disk reaches the buffer. Criteria 9 and
        -- 10 (an edited buffer left and marked) are the model's, over the
        -- watch model (`FilesTest.autoReloadChecks`, `FilesTest/Files.lean`), and
        -- the watch adapter's behaviour is ContractTest's
        -- (`ContractTest/Editor/Watch/Contract.lean`).
        let (old, new) := ("one\ntwo\n", "one\ntwo\nthree\n")
        IO.FS.writeBinFile path old.toUTF8
        withRealFileHost context (files / "config") [("open-note", path)] fun session => do
            session.ask [.run "open-note"]
            unless ← session.outputReaches (endedOk · Files.loadJob) do
              return false
            -- With no argument the command toggles: off, so on.
            session.ask [.run Files.autoReloadName]
            -- The command starts the follow job, which says so as it starts:
            -- read once the ask has waited for the command.
            let armed :=
              (← session.output.get).any fun line =>
                line.startsWith "job " && line.endsWith s!" {FileJobs.followJob}: started"
            unless armed do
              return false
            unless ← rewriteFromOutside path new do
              return false
            -- The watch's delivery wakes the follow job, whose command starts
            -- the reload: the scene is asked again at each of their lines,
            -- never after a time. How soon is `config-bench`'s to measure.
            let jobLine (line : String) : Bool := line.startsWith "job "
            let (shown, saw) ← session.shownOn jobLine (·.contains (viewLine new 0))
            unless shown do
              throw (IO.userError s!"the rewrite was not shown: {saw}")
            return true }

/-- The checks of auto-reload through the headless host on real files, with
the library's watch service (`Editor/Loop.lean`, "Auto-reload"): criteria 9
and 10, that the rewrite is shown and the edited buffer marked, each seen on
the scene asked at each job line the follow job and the reload it starts
print (`Session.shownOn`), with `hangGuard` against a hang only. How soon
they are shown, the criteria's "within a second", is real time and is
measured, not pass or fail here: `config-bench`'s auto-reload row
(`FilesTest.Linked.Bench.autoReloadRow`, `FilesTest/Linked/Files/Bench.lean`)
prints the rewrite-to-shown latency over real watches with its budget
beside it.
Measured on 2026-11-16 on macOS (FSEvents), over six runs: the rewrite was
shown 66 to 83 ms after the other process exited, a median of about 80 ms,
and the edited buffer marked in 78 to 84 ms; the 50 ms coalescing window is
most of it. -/
def autoReloadChecks (context : HostContext) : List Check :=
  [criteria910RealCheck context]

end FilesTest.Linked
