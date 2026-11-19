import Editor
import Compile
open Editor

-- The shipped modes reading output, with no process: each command hands
-- canned output, as the tool prints it, to the compile mode's own reader
-- (`Compile.scan`) with the formats the shipped contributions give for the
-- modes that are on (`Compile.formatsOf Compile.shipped`), and says the
-- locations it finds in the echo area. The output is that of the package's
-- fixture programs (`tests/compile/bin/cargo-build.txt`, `lake-build.txt`
-- and `mise-run-test.txt`), written out here so that the fixture reads no
-- file. Every path is relative: the run's directory is `proj`.

/-- What `cargo build` prints for a type error, as cargo 1.98 prints it. -/
def cargoOutput : Array String :=
  #["   Compiling fixture v0.1.0", "error[E0308]: mismatched types", " --> src/main.rs:4:18",
    "  |", "4 |     let x: i32 = \"a\";", "  |            ---   ^^^ expected `i32`, found `&str`",
    "  |            |", "  |            expected due to this", "",
    "For more information about this error, try `rustc --explain E0308`.",
    "error: could not compile `fixture` (bin \"fixture\") due to 1 previous error"]

/-- What `lake build` prints for an unknown identifier. -/
def lakeOutput : Array String :=
  #["[2/4] Building Foo.Bar", "error: ./Foo/Bar.lean:12:4: unknown identifier 'x'",
    "Some required targets logged failures:", "- Foo.Bar", "error: build failed"]

/-- What `mise run test` prints in a mise project whose task runs cargo in
a nested crate: rustc's error, with the crate's path. -/
def miseOutput : Array String :=
  #["   Compiling crate v0.1.0", "error[E0308]: mismatched types", " --> crate/src/main.rs:4:18",
    "  |", "4 |     let x: i32 = \"a\";", "  |            ---   ^^^ expected `i32`, found `&str`",
    "  |            |", "  |            expected due to this", "",
    "For more information about this error, try `rustc --explain E0308`.",
    "error: could not compile `crate` (bin \"crate\") due to 1 previous error"]

/-- What `mise tasks ls --json` prints for two tasks. -/
def miseTaskList : String :=
  "[\n  {\"name\": \"build\", \"dir\": \"proj\", \"hide\": false, \"depends\": [], \"run\": [\"cargo build\"]},\n  {\"name\": \"test\", \"dir\": \"proj\", \"hide\": false, \"depends\": [\"build\"], \"run\": [\"cargo test\"]}\n]\n"

/-- The locations the compile mode finds in `lines`, the output of a run in
the directory `proj` with the modes `modes` on, nearest first: each as its
format, its severity, its file, line and column as printed, the rows of the
output it covers, counted from 1 as in a compilation buffer under its
header, and its message. -/
def located (modes : Array String) (lines : Array String) : String :=
  let formats := Compile.formatsOf Compile.shipped (modes.map fun mode => { mode, root := "proj" })
  let sites := Compile.scan formats "proj" #[] 1 0 lines
  let said :=
    sites.map fun site =>
      s!"{site.format} {site.severity.name} {site.file}:{site.line}:{(site.column.map toString).getD "-"} rows {site.first}-{site.last} {site.message.getD "-"}"
  s!"{sites.size} of {formats.map (·.name)}: " ++ "; ".intercalate said.toList

/-- `cargo-mode` on: rustc's format reads cargo's output. -/
def readCargo : EditorM Unit :=
  message s!"cargo-mode reads {located #["cargo-mode"] cargoOutput}"

/-- `lake-mode` on: Lean's format reads lake's output. -/
def readLake : EditorM Unit :=
  message s!"lake-mode reads {located #["lake-mode"] lakeOutput}"

/-- `mise-mode` has no format of its own: with it alone on, rustc's lines
are read by no shipped format; with `cargo-mode` on beside it, as in a
crate inside a mise project, cargo-mode's format reads them. -/
def readMise : EditorM Unit :=
  message
      s!"mise-mode alone reads {located #["mise-mode"] miseOutput}; with cargo-mode reads {located #["cargo-mode", "mise-mode"] miseOutput}"

/-- `mise-mode`'s commands are computed: its reader turns mise's task list
into one named command a task. -/
def readMiseTasks : EditorM Unit :=
  message <|
      match Compile.miseTasks miseTaskList.toUTF8 with
      | .ok commands =>
        "mise-mode lists " ++
          "; ".intercalate
            (commands.map fun command =>
                s!"{command.name}: {command.line} in {(command.directory.map toString).getD "-"}").toList
      | .error why => s!"mise-mode's task list is refused: {why}"

def setup : SetupM Unit := do
  command "shipped-read-cargo" readCargo
  command "shipped-read-lake" readLake
  command "shipped-read-mise" readMise
  command "shipped-read-mise-tasks" readMiseTasks
