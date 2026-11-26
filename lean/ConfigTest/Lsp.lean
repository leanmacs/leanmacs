import ConfigTest.Check
import Editor.Config.LakePackage
import Editor.Job.Runner
import Lean.Data.Lsp

/-!
# Config tests: the language server check

`config-test lsp <sysroot> <config dir>` (`ConfigTest.Lsp.run`): Lean's
language server, started in a config directory, checks the directory's
root as the editor elaborates it. config-test's run holds it in
`lspChecks`, on a temporary directory of its own into which it writes the
config package an editor of the default set generates (`writePackage`:
the lakefile `Editor.Config.LakePackage.lakefile` gives for the set, by
its Lake name, and the core, and the core's toolchain pin) and the root and
the config file of `tests/config-package/lsp`; so no run of the built
editor is read. `tools/config-package-check.sh` runs `lsp` too, on a
directory the built editor generated. It tests no module of the
editor, so it mirrors none; it sits beside the mirrored test modules under
`ConfigTest/`, as the benchmark does.

It starts `<sysroot>/bin/lake serve` in the directory, which is how an
editor starts the server in a Lake package, and speaks the language server
protocol to it over its standard input and output, with Lean's own
messages (`Lean.JsonRpc`, `Lean.Lsp`): `initialize`, `initialized`,
`textDocument/didOpen` of `init.lean`, and `textDocument/waitForDiagnostics`,
Lean's request that is answered once the file is elaborated. The
diagnostics are the last `textDocument/publishDiagnostics` the server sent
for the file before that answer.

- **It waits for the response to its own request by id.** The server sends
  requests of its own, whose ids start at the same numbers as a client's;
  those, and every notification but the diagnostics, are passed over.
- **What must hold.** The file has exactly one error, at the line and
  column the caller names. So no import failed: an import that cannot be
  resolved is an error at the header, and everything after it fails too.
- **It does not hang.** The exchange runs on a task, and the check gives up
  after `patience`, kills the server and fails.

`run` writes nothing itself (`lspChecks` writes its package into its own
temporary directory, which it removes). Lake, run by the server, writes
`lake-manifest.json` and `.lake/` in the config directory, which is the
caller's temporary directory, and builds there the config files the root
imports; it fetches nothing, since the lakefile requires the package set
by path.
-/

namespace ConfigTest.Lsp

open Lean

/-- The guard of the exchange's end, the server's diagnostics of the file
read; only a hang reaches it, and the check then fails as a hang. A first
run takes a few seconds; only a server that hangs takes this long. -/
def patience : Editor.HangGuard :=
  .on "the exchange's end, the server's diagnostics of the file read" 180000

/-- An error the server reported: its place, from 1 for the line and from 0
for the column, as the editor's own diagnostics count, and its first
line. -/
structure Problem where
  /-- The line, from 1. -/
  line : Nat
  /-- The column, from 0. -/
  column : Nat
  /-- The first line of the message. -/
  message : String
  deriving Repr

/-- The errors among `diagnostics`, the `diagnostics` array of a
`textDocument/publishDiagnostics`: the ones of severity 1. -/
def errorsOf (diagnostics : Json) : Array Problem :=
  (diagnostics.getArr?.toOption.getD #[]).filterMap fun diagnostic => do
    let severity ← (diagnostic.getObjValAs? Nat "severity").toOption
    guard (severity == 1)
    let start ← ((diagnostic.getObjVal? "range").bind (·.getObjVal? "start")).toOption
    let line ← (start.getObjValAs? Nat "line").toOption
    let column ← (start.getObjValAs? Nat "character").toOption
    let message := ((diagnostic.getObjValAs? String "message").toOption.getD "")
    pure { line := line + 1, column, message := (message.splitOn "\n").headD "" }

/-- Reads messages from `output` until the response to the request `id`
arrives, and returns the diagnostics of the last
`textDocument/publishDiagnostics` for a file whose URI ends in `suffix`
that came before it, if one came. The server's own requests and its other
notifications are passed over. Throws when the response is an error. -/
partial def awaitResponse (output : IO.FS.Stream) (id : Nat) (suffix : String)
    (latest : Option Json := none) : IO (Option Json) := do
  match ← output.readLspMessage with
  | .response (.num answered) _ =>
    if answered == (id : JsonNumber) then
      return latest
    else
      awaitResponse output id suffix latest
  | .responseError (.num answered) _ message _ =>
    if answered == (id : JsonNumber) then
      throw (IO.userError s!"the server refused request {id}: {message}")
    else
      awaitResponse output id suffix latest
  | .notification "textDocument/publishDiagnostics" (some params) =>
    let params := toJson params
    let uri := (params.getObjValAs? String "uri").toOption.getD ""
    if uri.endsWith suffix then
      awaitResponse output id suffix ((params.getObjVal? "diagnostics").toOption <|> latest)
    else
      awaitResponse output id suffix latest
  | _ =>
    awaitResponse output id suffix latest

/-- The exchange with a server whose standard input is `input` and whose
standard output is `output`, about the file at `path` whose text is
`text`, in the workspace at `directory`: the errors the server reports for
the file once it is elaborated. -/
def exchange (input output : IO.FS.Stream) (directory path : System.FilePath) (text : String) :
    IO (Array Problem) := do
  let uri := System.Uri.pathToUri path
  input.writeLspRequest
      (⟨(0 : Nat), "initialize",
          Json.mkObj
            [("processId", Json.null), ("rootUri", Json.str (System.Uri.pathToUri directory)),
              ("capabilities", Json.mkObj [])]⟩ :
        JsonRpc.Request Json)
  discard <| awaitResponse output 0 path.toString
  input.writeLspNotification (⟨"initialized", Json.mkObj []⟩ : JsonRpc.Notification Json)
  input.writeLspNotification
      (⟨"textDocument/didOpen",
          Json.mkObj
            [("textDocument",
                Json.mkObj
                  [("uri", Json.str uri), ("languageId", Json.str "lean"), ("version", (1 : Nat)),
                    ("text", Json.str text)])]⟩ :
        JsonRpc.Notification Json)
  input.writeLspRequest
      (⟨(1 : Nat), "textDocument/waitForDiagnostics",
          Json.mkObj [("uri", Json.str uri), ("version", (1 : Nat))]⟩ :
        JsonRpc.Request Json)
  let diagnostics ← awaitResponse output 1 path.fileName.get!
  -- The server is asked to end; the caller kills it whatever it answers.
  input.writeLspRequest (⟨(2 : Nat), "shutdown", Json.null⟩ : JsonRpc.Request Json)
  return errorsOf (diagnostics.getD (Json.arr #[]))

/-- `config-test lsp <sysroot> <config dir> <line> <column>`: starts
`<sysroot>/bin/lake serve` in the config directory, opens its `init.lean`
and waits for the server to elaborate it. 0, and one line on stdout, when
the file's one error is at `line`, from 1, and `column`, from 0; 1, saying
what the server reported instead, otherwise, and when the server does not
answer within `patience`. -/
def run (sysroot configDir : String) (line column : Nat) : IO UInt8 := do
  let directory ← IO.FS.realPath configDir
  let path := directory / "init.lean"
  let text ← IO.FS.readFile path
  let server ←
    IO.Process.spawn
        { cmd := (System.FilePath.mk sysroot / "bin" / "lake").toString, args := #["serve"]
          cwd := some directory, stdin := .piped, stdout := .piped, stderr := .null }
  let task ←
    IO.asTask (prio := .dedicated)
        (exchange (IO.FS.Stream.ofHandle server.stdin) (IO.FS.Stream.ofHandle server.stdout)
          directory path text)
  -- The exchange's end is waited on (`Job.awaitWithin`), never polled.
  let finished ← Editor.Job.awaitWithin patience task
  server.kill
  discard <| server.wait
  let some answered := finished |
    IO.eprintln
        s!"config-test lsp: a hang: the language server did not answer within {patience.ms} ms"
    return 1
  match answered with
  | .error error =>
    IO.eprintln s!"config-test lsp: {error}"
    return 1
  | .ok problems =>
    let places := problems.map fun problem => (problem.line, problem.column)
    if places == #[(line, column)] then
      IO.println
          s!"config-test lsp: init.lean: no import error, and the type error is at {line}:{column}"
      return 0
    IO.eprintln
        s!"config-test lsp: init.lean: the language server reports {problems.size} errors, not the one at {line}:{column}:"
    for problem in problems do
      IO.eprintln s!"  {problem.line}:{problem.column}: {problem.message}"
    return 1

/-- The Lake name of a package set, from its lakefile's text `lakefile`:
the value of its first `name = "…"` line, the package's own, as the editor
writes the name the build handed it. -/
def setNameOf (lakefile : String) : Option String :=
  (lakefile.splitOn "\n").findSome? fun line =>
    (line.dropPrefix? "name = \"").bind fun rest =>
      (rest.toString.dropSuffix? "\"").map (·.toString)

/-- Writes in `directory` the config package an editor of the set at
`setDirectory`, linking the core at `coreDirectory`, both absolute,
generates there (`Editor.Config.LakePackage`): its `lakefile.toml`
requiring the set by its Lake name and the core, last, and its
`lean-toolchain`, the core's pin; then the root `init.lean` and the config
file `Config/Keys.lean` of `fixture`. -/
def writePackage (directory setDirectory coreDirectory fixture : System.FilePath) : IO Unit := do
  let some name := setNameOf (← IO.FS.readFile (setDirectory / "lakefile.toml"))
    | throw (IO.userError s!"no name = \"…\" line in {setDirectory / "lakefile.toml"}")
  let set : Editor.Config.LakePackage.Set :=
    { name, directory := setDirectory.toString, core := coreDirectory.toString }
  IO.FS.writeFile (directory / Editor.Config.LakePackage.lakefileName)
      (Editor.Config.LakePackage.lakefile set)
  IO.FS.writeFile (directory / Editor.Config.LakePackage.toolchainName)
      (← IO.FS.readFile (coreDirectory / "lean-toolchain"))
  IO.FS.writeFile (directory / "init.lean") (← IO.FS.readFile (fixture / "init.lean"))
  IO.FS.createDirAll (directory / "Config")
  IO.FS.writeFile (directory / "Config" / "Keys.lean")
      (← IO.FS.readFile (fixture / "Config" / "Keys.lean"))

end ConfigTest.Lsp

namespace ConfigTest

/-- The language server check in config-test's run (`ConfigTest.Lsp`): in
a temporary directory of its own, the config package an editor of the set
at `context.setDirectory`, linking the core at `context.coreDirectory`,
generates, holding the root and the config file of `context.lspFixture`
(`tests/config-package/lsp`), whose root holds one type error at 8:19. -/
def lspChecks (context : Context) : List Check :=
  [{  name :=
        "Lean's language server, started in a config package written as an editor of the set generates it (its lakefile and toolchain pin) and holding the fixture's root and config file, reports the root's one type error at 8:19 and no import error"
      run :=
        IO.FS.withTempDir fun directory => do
          Lsp.writePackage directory context.setDirectory context.coreDirectory context.lspFixture
          return (← Lsp.run context.sysroot directory.toString 8 19) == 0 }]

end ConfigTest
