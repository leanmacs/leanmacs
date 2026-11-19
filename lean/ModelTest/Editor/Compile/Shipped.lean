import Editor.Command.Dispatch
import Editor.Compile.Contribution
import Editor.Compile.Errors
import Editor.Compile.Shipped
import Editor.Completion.Candidate
import Editor.Config.Registry
import Editor.Event
import Editor.File.Model
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job.Model
import Editor.Loop
import Editor.Loop.Driver
import Editor.Process
import Editor.Process.Model
import Editor.Program
import Editor.ProjectMode
import Editor.ProjectMode.Format
import Editor.ProjectMode.Listing
import Editor.Scene
import Editor.Setup
import Editor.State
import Editor.Text
import Editor.Workspace
import Editor.Workspace.Model
import Editor.Workspace.Modes
import ModelTest.Check
import ModelTest.Support.Compile
import ModelTest.Support.Driver
import ModelTest.Support.Files
import ModelTest.Support.Keys
import ModelTest.Support.Models
import ModelTest.Support.Prompts
import ModelTest.Support.Shell
import ModelTest.Support.Workspace

/-!
# Model tests: `Editor/Compile/Shipped.lean`

The model tests of `Editor/Compile/Shipped.lean`: `projectFormatChecks`,
`projectModeChecks` and `miseTaskChecks`. The root module `ModelTest` runs them; its module doc says
what each shows.
-/

namespace ModelTest

open Editor

/-- What cargo prints of rustc's error in the probe crate, after its
`Compiling` line: the message, its location and the snippet under it. -/
def rustcLines : Array String :=
  #["error[E0308]: mismatched types", " --> src/main.rs:4:18", "  |", "4 |     let x: i32 = \"a\";",
    "  |            ---   ^^^ expected `i32`, found `&str`", "  |            |",
    "  |            expected due to this", "",
    "For more information about this error, try `rustc --explain E0308`.",
    "error: could not compile `probe` (bin \"probe\") due to 1 previous error"]

/-- The checks of the shipped error formats (`Editor/Compile/Shipped.lean`,
"The formats"): pure, with no driver. -/
def projectFormatChecks : List Check :=
  let general := Compile.Format.general
  [{  name :=
        "modes criterion 3: rustc's format finds error[E0308]: mismatched types followed by   --> src/main.rs:4:18 as one location at src/main.rs line 4 column 18, severity error, with the message mismatched types"
      run :=
        pure
          (Compile.scan #[Compile.rustcFormat] "/c" #[] 1 0
              #["error[E0308]: mismatched types", "  --> src/main.rs:4:18"] ==
            #[{ file := "/c/src/main.rs", line := 4, column := some 18, columnBase := 1
                severity := .error, format := "rustc", first := 1, last := 2, start := 37
                stop := 53, message := some "mismatched types" }]) },
    { name :=
        "rustc's location line scanned alone after its lead in an earlier post gives the same site; a warning's lead gives a warning with its message; the snippet joins the site up to the blank line; and the general format reads none of rustc's lines"
      run :=
        let alone :=
          Compile.scan #[Compile.rustcFormat] "/c"
            (Compile.scan #[Compile.rustcFormat] "/c" #[] 1 0 #["error[E0308]: mismatched types"]) 2
            31 #["  --> src/main.rs:4:18"] (previous := some "error[E0308]: mismatched types")
        let warned :=
          Compile.scan #[Compile.rustcFormat] "/c" #[] 1 0
            #["warning: unused variable: `y`", " --> src/main.rs:2:9"]
        let whole := Compile.scan #[Compile.rustcFormat, general] "/c" #[] 1 0 rustcLines
        pure
          (alone ==
              Compile.scan #[Compile.rustcFormat] "/c" #[] 1 0
                #["error[E0308]: mismatched types", "  --> src/main.rs:4:18"] &&
            warned.map (fun site => (site.severity, site.line, site.column, site.message)) ==
              #[(.warning, 2, some 9, some "unused variable: `y`")] &&
            whole.map (fun site => (site.file.toString, site.first, site.last, site.message)) ==
              #[("/c/src/main.rs", 1, 7, some "mismatched types")] &&
            (rustcLines.push "   ::: src/lib.rs:3:5").all (general.read? · == none)) },
    { name :=
        "modes criterion 4: Lean's format finds error: ./Foo/Bar.lean:12:4: unknown identifier 'x' at Foo/Bar.lean line 12 column 4, counting columns from 0, and the same line with warning: as a warning"
      run :=
        let line := "error: ./Foo/Bar.lean:12:4: unknown identifier 'x'"
        let warning := "warning: ./Foo/Bar.lean:12:4: unknown identifier 'x'"
        pure
          (Compile.leanFormat.read? line ==
              some
                { file := "./Foo/Bar.lean", line := 12, column := some 4, severity := .error
                  start := 7, stop := 26, message := some "unknown identifier 'x'" } &&
            (Compile.scan #[Compile.leanFormat] "/l" #[] 1 0 #[line]).map
                (fun site => (site.file.toString, site.line, site.column, site.columnBase)) ==
              #[("/l/Foo/Bar.lean", 12, some 4, 0)] &&
            (Compile.leanFormat.read? warning).map (·.severity) == some .warning) },
    { name :=
        "Lean's format reads info: as a note and Lake's form with no ./, and reads none of Lake's other lines; the general format reads none of Lake's lines"
      run :=
        let lake :=
          #["✖ [2/4] Building Foo.Bar (156ms)", "error: Foo/Bar.lean:13:6: Unknown identifier `x`",
            "warning: Foo/Bar.lean:14:7: Variable name `y` is not explicitly referenced.",
            "info: Foo/Bar.lean:14:0: 1", "Some required targets logged failures:", "- Foo.Bar",
            "error: build failed"]
        pure
          ((Compile.leanFormat.read? "info: Foo/Bar.lean:14:0: 1").map (·.severity) == some .note &&
            (lake.filterMap Compile.leanFormat.read?).map
                (fun reading => (reading.file, reading.line, reading.severity)) ==
              #[("Foo/Bar.lean", 13, .error), ("Foo/Bar.lean", 14, .warning),
                ("Foo/Bar.lean", 14, .note)] &&
            (lake.push "error: ./Foo/Bar.lean:12:4: unknown identifier 'x'").all
              (general.read? · == none)) }]

/-- The world of the project mode checks: repositories `/c` (Cargo), `/l`
(Lake), `/m` (mise, with a crate in `/m/crate`), `/mw`, a worktree of `/m`'s
repository on `feature`, and `/r2`, a Cargo workspace with a member crate in
`/r2/crates/m`; and their marker files. -/
def projectWorld : Workspace.World :=
  { repositories :=
      #[{ toplevel := "/c", commonDir := "/c/.git" }, { toplevel := "/l", commonDir := "/l/.git" },
        { toplevel := "/m", commonDir := "/m/.git" },
        { toplevel := "/mw", commonDir := "/m/.git", branch := some "feature" },
        { toplevel := "/r2", commonDir := "/r2/.git" }]
    markerDirectories := #["/c/.git", "/l/.git", "/m/.git", "/r2/.git"]
    markers :=
      #["/c/Cargo.toml", "/l/lakefile.lean", "/m/mise.toml", "/m/crate/Cargo.toml", "/mw/mise.toml",
        "/r2/Cargo.toml", "/r2/crates/m/Cargo.toml"] }

/-- The bindings of the project mode checks: those of the compile mode's
checks of a listing (`compileListingBindings`), and `C-p
c`, `C-p l`, `C-p m`, `C-p n`, `C-p w` and `C-p r`, which open
`/c/src/main.rs`, `/l/Foo/Bar.lean`, `/m/notes.txt`, `/m/crate/src/main.rs`,
`/mw/notes.txt` and `/r2/crates/m/src/main.rs`. Test-scheme chords only. -/
def projectBindings : List (String × Invocation) :=
  compileListingBindings ++
    [("C-p c", opens "/c/src/main.rs"), ("C-p l", opens "/l/Foo/Bar.lean"),
      ("C-p m", opens "/m/notes.txt"), ("C-p n", opens "/m/crate/src/main.rs"),
      ("C-p w", opens "/mw/notes.txt"), ("C-p r", opens "/r2/crates/m/src/main.rs")]

/-- `mise tasks ls --json` in `directory`, as `mise-mode` runs it. -/
def miseList (directory : System.FilePath) : Process.Command :=
  { program := "mise", arguments := #["tasks", "ls", "--json"], directory }

/-- What each run of the project mode checks does: the listing in `/m`
prints `miseListing`, and in `/mw` one task, `wt-only`. -/
def projectScripts : Array Process.Script :=
  #[{ command := miseList "/m", reply := shellReply miseListing },
    { command := miseList "/mw",
      reply := shellReply "[{\"name\": \"wt-only\", \"dir\": \"/mw\"}]\n" }]

/-- The streaming children of the project mode checks: each line they run,
writing `ok`. -/
def projectStreams : Array Process.StreamScript :=
  #[("/c", "cargo clippy"), ("/l", "lake test"), ("/m", "mise run build"), ("/m", "mise run test"),
        ("/m/sub", "mise run lint"), ("/m", "mise run fmt")].map
    fun (directory, line) => { command := shellCommand directory line, steps := linesSteps ["ok"] }

/-- The registry of the project mode checks: the shipped contributions,
for the owner `compiled`, and no config. -/
def projectRegistry : Config.Registry :=
  hookRegistry (pure ()) Compile.shipped

/-- A driver of the project mode checks over `registry`: the world of
`projectWorld`, with its bindings, the compile checks' jobs, its files, runs
and children; `none` if making the state was refused. -/
def projectDriver (registry : Config.Registry := projectRegistry) : Option TestDriver :=
  let model :=
    projectWorld.jobModel "git"
      #["/c/src", "/l/Foo", "/m", "/m/crate/src", "/mw", "/r2/crates/m/src"]
  let files :=
    [("/c/src/main.rs", "fn main() {}\n"), ("/l/Foo/Bar.lean", "x\n"), ("/m/notes.txt", "n\n"),
          ("/m/crate/src/main.rs", "fn main() {}\n"), ("/mw/notes.txt", "w\n"),
          ("/r2/crates/m/src/main.rs", "fn main() {}\n")].foldl
      (fun (files : FileModel) (path, text) => files.withFile path text.toUTF8) model.files
  let keys := compileKeysOf projectBindings
  let keys := { keys with registered := { keys.registered with compile := registry.compileHook } }
  (Loop.Driver.over keys compileJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver =>
    { driver with
      jobs :=
        { model with
          files
          processes :=
            { model.processes with
              scripts := model.processes.scripts ++ projectScripts, streams := projectStreams } } }

/-- `driver` once the loop is told the next config generation, as a reload
tells it. -/
def reloaded (driver : TestDriver) : TestDriver :=
  { driver with
    keys :=
      { driver.keys with
        registered :=
          { driver.keys.registered with generation := driver.keys.registered.generation + 1 } } }

/-- The candidates `compile-command`'s prompt offers in `driver` once
`keys` are pressed and their jobs settled. -/
def offeredAfter (driver : TestDriver) (keys : String) : Option (Array String) :=
  (candidatesOf (settledAfter driver keys)).map (·.all.map (·.text))

/-- The checks of the shipped modes (`Editor/Compile/Shipped.lean`), on the
loop's driver over the editor's models, the job model and the process
model, in the world of `projectWorld`, with only the shipped contributions
registered. -/
def projectModeChecks : List Check :=
  [{  name :=
        "modes criterion 1: a buffer under a Cargo.toml has cargo-mode on with that root, one under a lakefile.lean lake-mode, one under a mise.toml mise-mode, and one in a Cargo crate inside a mise project both, the crate's first"
      run :=
        pure <|
          match projectDriver with
          | none => false
          | some driver =>
            let modesOf (keys : String) :=
              let opened := settledAfter driver keys
              (shownOnModes opened, shownMinors opened)
            modesOf "C-p c" ==
                (some #[{ mode := "cargo-mode", root := "/c" }], some #["cargo-mode"]) &&
              modesOf "C-p l" ==
                (some #[{ mode := "lake-mode", root := "/l" }], some #["lake-mode"]) &&
              modesOf "C-p m" ==
                (some #[{ mode := "mise-mode", root := "/m" }], some #["mise-mode"]) &&
              modesOf "C-p n" ==
                (some
                    #[{ mode := "cargo-mode", root := "/m/crate" },
                      { mode := "mise-mode", root := "/m" }],
                  some #["cargo-mode", "mise-mode"]) },
    { name :=
        "lakefile.toml turns lake-mode on and .mise.toml mise-mode; cargo-mode's root is its outermost Cargo.toml, so in a member crate of /r2 it is /r2"
      run :=
        let markerModes := Compile.shipped.map (·.markerMode)
        pure <|
          Workspace.onModes markerModes "/x/a" "/x"
                #[("/x", "lakefile.toml"), ("/x/a", ".mise.toml")] ==
              #[{ mode := "mise-mode", root := "/x/a" }, { mode := "lake-mode", root := "/x" }] &&
            match projectDriver with
            | none => false
            | some driver =>
              shownOnModes (settledAfter driver "C-p r") ==
                some #[{ mode := "cargo-mode", root := "/r2" }] },
    { name :=
        "modes criterion 2: cargo-mode offers build, test and clippy as compile-command candidates, and clippy runs cargo clippy in /c; lake-mode offers build and test, and test runs lake test in /l"
      run :=
        pure <|
          match projectDriver with
          | none => false
          | some driver =>
            let cargo := settledAfter driver "C-p c"
            let lake := settledAfter driver "C-p l"
            let clippy := (fedTo cargo (exLine "compile-command clippy")).1
            let tested := (fedTo lake (exLine "compile-command test")).1
            offeredAfter cargo "C-k i" ==
                some #["build (cargo-mode)", "test (cargo-mode)", "clippy (cargo-mode)"] &&
              clippy.jobs.processes.started.back? == some (shellCommand "/c" "cargo clippy") &&
              offeredAfter lake "C-k i" == some #["build (lake-mode)", "test (lake-mode)"] &&
              tested.jobs.processes.started.back? == some (shellCommand "/l" "lake test") },
    { name :=
        "the shipped contributions offer exactly cargo build, cargo test and cargo clippy in a Cargo root, and lake build and lake test in a Lake root, each in its mode's root"
      run :=
        let offer (mode name line : String) (root : System.FilePath) : Compile.Offer :=
          { mode, name, line, root }
        pure
          (Compile.offers Compile.shipped #[] #[{ mode := "cargo-mode", root := "/c" }] ==
              #[offer "cargo-mode" "build" "cargo build" "/c",
                offer "cargo-mode" "test" "cargo test" "/c",
                offer "cargo-mode" "clippy" "cargo clippy" "/c"] &&
            Compile.offers Compile.shipped #[] #[{ mode := "lake-mode", root := "/l" }] ==
              #[offer "lake-mode" "build" "lake build" "/l",
                offer "lake-mode" "test" "lake test" "/l"] &&
            (Compile.formatsOf Compile.shipped
                    #[{ mode := "cargo-mode", root := "/c" }, { mode := "mise-mode", root := "/m" },
                      { mode := "lake-mode", root := "/l" }]).map
                (·.name) ==
              #["rustc", "lean", "general"]) },
    { name :=
        "modes criterion 5: mise-mode turning on runs mise tasks ls --json in its root, once, after find-mode-markers, and offers mise run <task> for each task it lists, each in the task's dir"
      run :=
        pure <|
          match projectDriver with
          | none => false
          | some driver =>
            let (opened, names) := settledNames driver "C-p m"
            let answered :=
              (fedTo (pressedOn opened "C-k i") ([.commit "test"] ++ presses "C-e y")).1
            let built := (fedTo opened (exLine "compile-command build")).1
            let linted := (fedTo opened (exLine "compile-command lint")).1
            let offer (name line : String) (root : System.FilePath) : Compile.Offer :=
              { mode := "mise-mode", name, line, root }
            names.filter (fun name => name == Workspace.markerJob || name == Compile.listJob) ==
                #[Workspace.markerJob, Compile.listJob] &&
              startedCount opened (miseList "/m") == 1 &&
              offeredAfter opened "C-k i" ==
                some #["build (mise-mode)", "test (mise-mode)", "lint (mise-mode)"] &&
              answered.jobs.processes.started.back? == some (shellCommand "/m" "mise run test") &&
              built.jobs.processes.started.back? == some (shellCommand "/m" "mise run build") &&
              linted.jobs.processes.started.back? == some (shellCommand "/m/sub" "mise run lint") &&
              Compile.offers Compile.shipped #[] #[{ mode := "mise-mode", root := "/m" }]
                  (Compile.listedCommands opened.loop.state (some (.local "/m"))) ==
                #[offer "build" "mise run build" "/m", offer "test" "mise run test" "/m",
                  offer "lint" "mise run lint" "/m/sub"] },
    { name :=
        "two worktrees list their own tasks: /mw runs its own listing in /mw and offers only wt-only, /m's offers are unchanged, and each listing is in its own workspace's store"
      run :=
        pure <|
          match projectDriver with
          | none => false
          | some driver =>
            let inM := settledAfter driver "C-p m"
            let inW := settledAfter inM "C-p w"
            let back := settledAfter inW "C-p m"
            let state := back.loop.state
            (shownWorkspace inW).map (·.1.location) == some (.local "/mw") &&
              startedCount inW (miseList "/mw") == 1 &&
              offeredAfter inW "C-k i" == some #["wt-only (mise-mode)"] &&
              offeredAfter back "C-k i" ==
                some #["build (mise-mode)", "test (mise-mode)", "lint (mise-mode)"] &&
              (Compile.entriesOf state (some (.local "/m"))).map (·.root.toString) == #["/m"] &&
              (Compile.entriesOf state (some (.local "/mw"))).map (·.root.toString) == #["/mw"] &&
              (Compile.entriesOf state none).isEmpty },
    { name :=
        "modes criterion 6: a listing that fails offers no task and says why once: compile-command then says no mode gives commands, and its check runs nothing and says nothing; a list that is not one says so"
      run :=
        pure <|
          match projectDriver with
          | none => false
          | some driver =>
            let failing :=
              withScript driver
                { command := miseList "/m", reply := shellReply "" "mise ERROR boom\n" (.code 1) }
            let opened := settledAfter failing "C-p m"
            let asked := pressedOn opened "C-k i"
            let settled := settledAfter opened "C-k i"
            let unread :=
              settledAfter
                (withScript driver { command := miseList "/m", reply := shellReply "{}" }) "C-p m"
            echoOf opened ==
                some
                  "mise-mode in /m: mise tasks ls --json exited with status 1: mise ERROR boom" &&
              asked.loop.state.prompt.isNone &&
              echoOf asked == some "compile-command: no mode gives commands in m@main" &&
              echoOf settled == some "compile-command: no mode gives commands in m@main" &&
              startedCount settled (miseList "/m") == 1 &&
              echoOf unread ==
                some
                  "mise-mode in /m: mise tasks ls --json printed no list of commands: it is not an array" },
    { name :=
        "modes criterion 7: after mise.toml's stamp changes, the next use of mise-mode lists the tasks again and the use after it offers the new list; with the stamps unchanged two uses list nothing, and after a reload the next use lists again"
      run :=
        pure <|
          match projectDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-p m"
            let changed :=
              withScript (rewritten opened "/m/mise.toml" "[tasks.fmt]\n".toUTF8)
                { command := miseList "/m",
                  reply := shellReply "[{\"name\": \"fmt\", \"dir\": \"/m\"}]" }
            let used := settledAfter changed "C-k i"
            let again := settledAfter used "C-k q C-k i"
            let twice := settledAfter (settledAfter opened "C-k i") "C-k q C-k i"
            let afterReload := settledAfter (reloaded (settledAfter opened "C-k i C-k q")) "C-k i"
            startedCount used (miseList "/m") == 2 &&
              (candidatesOf used).map (·.all.map (·.text)) ==
                some #["build (mise-mode)", "test (mise-mode)", "lint (mise-mode)"] &&
              (candidatesOf again).map (·.all.map (·.text)) == some #["fmt (mise-mode)"] &&
              startedCount again (miseList "/m") == 2 &&
              startedCount twice (miseList "/m") == 1 &&
              startedCount afterReload (miseList "/m") == 2 }]

/-- The checks of the reader of mise's task list (`Compile.miseTasks`,
`Editor/Compile/Shipped.lean`), over the JSON reader: pure. -/
def miseTaskChecks : List Check :=
  [{  name :=
        "mise's task list gives one command per task, mise run and the task's name, in the task's dir, in the order listed: build and test in /m, lint in /m/sub; an empty list gives none"
      run :=
        pure
          ((Compile.miseTasks miseListing.toUTF8).toOption.map
                (·.map fun command =>
                  (command.name, command.line, command.directory.map (·.toString))) ==
              some
                #[("build", "mise run build", some "/m"), ("test", "mise run test", some "/m"),
                  ("lint", "mise run lint", some "/m/sub")] &&
            (Compile.miseTasks "[]".toUTF8).toOption.map (·.size) == some 0) },
    { name :=
        "a task's name that is not a bare shell word is quoted: my task gives mise run 'my task', it's gives mise run 'it'\\''s; a name listed twice keeps its first, and a task with an empty dir has none"
      run :=
        let listing :=
          "[{\"name\": \"my task\", \"dir\": \"\"}, {\"name\": \"it's\"}, {\"name\": \"my task\", \"dir\": \"/x\"}, {\"name\": \"a:b/c@d%e+f=g,h_i-j.k\"}]"
        pure
          ((Compile.miseTasks listing.toUTF8).toOption.map
                (·.map fun command =>
                  (command.name, command.line, command.directory.map (·.toString))) ==
              some
                #[("my task", "mise run 'my task'", none), ("it's", "mise run 'it'\\''s'", none),
                  ("a:b/c@d%e+f=g,h_i-j.k", "mise run a:b/c@d%e+f=g,h_i-j.k", none)] &&
            Compile.shellWord "" == "''" &&
            Compile.shellWord "a$b" == "'a$b'") },
    { name :=
        "mise's task list is refused when it is not an array, a task is not an object, a task has no name or an empty one, or it is no JSON, saying why"
      run :=
        let refused (text : String) : Option String :=
          match Compile.miseTasks text.toUTF8 with
          | .error why => some why
          | .ok _ => none
        pure
          (refused "{}" == some "it is not an array" &&
            refused "[{\"name\": \"a\"}, 3]" == some "task 2 is not an object" &&
            refused "[{\"name\": \"a\"}, {\"dir\": \"/m\"}]" == some "task 2 has no name" &&
            refused "[{\"name\": \"\"}]" == some "task 1 has no name" &&
            refused "[{\"name\": 1}]" == some "task 1 has no name" &&
            refused "[" == some "a value is missing") }]

end ModelTest
