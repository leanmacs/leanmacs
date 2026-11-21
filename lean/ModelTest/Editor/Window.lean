import Editor.Event
import Editor.File.Cases
import Editor.FileJobs
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Loop
import Editor.Loop.Driver
import Editor.Scene
import Editor.State
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Opener
import Editor.Text
import Editor.Window
import ModelTest.Check

/-!
# Model tests: `Editor/Window.lean`

The model tests of `Editor/Window.lean`: `windowOptionChecks`,
`windowReportChecks` and `windowStartChecks`. `windowStartChecks` run the window
mode's starts on the driver whose commands are the compiled ones. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- What the window mode is told of the world by the checks of its command
line: a working directory, both variables a config directory is found by,
where the executable is, outside a bundle, and the `.olean` directory the
build recorded for it. -/
def windowEnvironment : Window.Environment :=
  { workingDirectory := "/work/project", xdgConfigHome := some "/xdg", home := some "/home/ada"
    appPath := "/opt/leanmacs/bin/editor", recordedOleans := ["/opt/core/lib/lean"] }

/-- The checks of the window mode's command line (`Editor/Window.lean`): the
file, the options and their defaults, when config is loaded, and what is
refused. -/
def windowOptionChecks : List Check :=
  let parsed (arguments : List String) (environment := windowEnvironment) : Option Window.Options :=
    (Window.parse environment arguments).toOption
  let refused (arguments : List String) : Bool :=
    match Window.parse windowEnvironment arguments with
    | .error message => message.endsWith Window.usage
    | .ok _ => false
  [{  name :=
        "a restart hands on every option given and drops the file: what the next run parses of it is this run's options with no file, for options with each flag given"
      run :=
        let full :=
          ["--config", "c", "--state", "st", "--sysroot", "/s", "--oleans", "/o", "--no-ime", "f",
            "--report", "--present-mode", "mailbox", "--frame-latency", "2"]
        let again (arguments : List String) : Bool :=
          match parsed arguments with
          | some options => parsed options.restartArguments == some { options with file := none }
          | none => false
        pure
          (again full && again ["f"] && again [] && again ["--no-ime", "f"] &&
            (parsed full).map (·.restartArguments.contains "f") == some false) },
    { name :=
        "the word a restart drops is the one the parser read as the file: each option's value is kept, wherever the file is, even a value spelled as the file is"
      run :=
        let handed (arguments : List String) : Option (List String) :=
          (parsed arguments).map (·.restartArguments)
        let valued :=
          [("--config", "c"), ("--state", "st"), ("--sysroot", "/s"), ("--oleans", "/o"),
            ("--present-mode", "fifo"), ("--frame-latency", "3")]
        pure
          (valued.all
              (fun (option, value) =>
                handed [option, value, "f"] == some [option, value] &&
                  handed ["f", option, value] == some [option, value]) &&
            handed ["--config", "f", "f"] == some ["--config", "f"] &&
            handed ["f", "--state", "f"] == some ["--state", "f"] &&
            handed ["--no-ime", "f", "--report"] == some ["--no-ime", "--report"]) },
    { name :=
        "a run a restart started with --restore restores that index first; without one the restore names none"
      run :=
        let named : Window.Options → Window.Options := fun options =>
          { options with launch := { restore := some "/s/session/session-2.json" } }
        pure
          ((parsed ["--state", "/s", "f"]).map (fun o => (named o).starts (.skip none) #[]) ==
              some #[.restore (some "/s/session/session-2.json"), .open "/work/project/f"] &&
            (parsed ["--state", "/s"]).map (·.starts (.skip none) #[]) == some #[.restore none]) },
    { name :=
        "the state directory is --state's, resolved against the working directory; else leanmacs under XDG_STATE_HOME, else under HOME's .local/state when that is unset or empty; and none when neither is set"
      run :=
        let unset := { windowEnvironment with xdgStateHome := none }
        let xdg := { windowEnvironment with xdgStateHome := some "/xdg-state" }
        let empty := { windowEnvironment with xdgStateHome := some "" }
        let homeless :=
          { windowEnvironment with
            xdgStateHome := none, home := none }
        pure
          ((parsed [] xdg).map (·.state) == some (some "/xdg-state/leanmacs") &&
            (parsed [] unset).map (·.state) == some (some "/home/ada/.local/state/leanmacs") &&
            (parsed [] empty).map (·.state) == some (some "/home/ada/.local/state/leanmacs") &&
            (parsed [] homeless).map (·.state) == some none &&
            (parsed ["--state", "/s"] xdg).map (·.state) == some (some "/s") &&
            (parsed ["--state", "here"]).map (·.state) == some (some "/work/project/here") &&
            (parsed ["--state", "/s"]).map (·.stateDirectory) ==
              some (some (System.FilePath.mk "/s"))) },
    { name :=
        "the data directory is --data's, resolved against the working directory; else leanmacs under XDG_DATA_HOME, else under HOME's .local/share when that is unset or empty; and none when neither is set"
      run :=
        let unset := { windowEnvironment with xdgDataHome := none }
        let xdg := { windowEnvironment with xdgDataHome := some "/xdg-data" }
        let empty := { windowEnvironment with xdgDataHome := some "" }
        let homeless :=
          { windowEnvironment with
            xdgDataHome := none, home := none }
        pure
          ((parsed [] xdg).map (·.data) == some (some "/xdg-data/leanmacs") &&
            (parsed [] unset).map (·.data) == some (some "/home/ada/.local/share/leanmacs") &&
            (parsed [] empty).map (·.data) == some (some "/home/ada/.local/share/leanmacs") &&
            (parsed [] homeless).map (·.data) == some none &&
            (parsed ["--data", "/d"] xdg).map (·.data) == some (some "/d") &&
            (parsed ["--data", "here"]).map (·.data) == some (some "/work/project/here") &&
            refused ["--data"]) },
    { name := "--state with no directory after it is refused, with the usage"
      run := pure (refused ["--state"] && refused ["f", "--state"]) },
    { name :=
        "a relative file is resolved against the working directory, and an absolute one is kept as it is"
      run :=
        pure
          ((parsed ["notes.txt"]).map (·.file) == some (some "/work/project/notes.txt") &&
            (parsed ["src/a.lean"]).map (·.file) == some (some "/work/project/src/a.lean") &&
            (parsed ["/tmp/b.txt"]).map (·.file) == some (some "/tmp/b.txt")) },
    { name := "no file parses to options with no file, with every default as with one"
      run :=
        pure
          (parsed [] ==
              some
                { file := none, config := some "/xdg/leanmacs", configGiven := false,
                  state := some "/home/ada/.local/state/leanmacs",
                  data := some "/home/ada/.local/share/leanmacs", sysroot := none,
                  oleans := ["/opt/core/lib/lean"], composition := true } &&
            (parsed ["--no-ime"]).map (·.file) == some none) },
    { name :=
        "a Finder start: no arguments, / as the working directory, HOME set and XDG_CONFIG_HOME unset, in a bundle: no file, config from ~/.config/leanmacs, the bundle's toolchain and the .olean directories its record names"
      run :=
        let finder : Window.Environment :=
          { workingDirectory := "/", xdgConfigHome := none, home := some "/Users/ada"
            appPath := "/Applications/Leanmacs.app/Contents/MacOS/editor"
            recordedOleans := ["/Applications/Leanmacs.app/Contents/Resources/lean/lean/lib"] }
        pure <|
          match parsed [] finder with
          | none => false
          | some options =>
            options.file == none && options.config == some "/Users/ada/.config/leanmacs" &&
              options.sysroot ==
                some "/Applications/Leanmacs.app/Contents/Resources/lean/toolchain" &&
              options.oleans == ["/Applications/Leanmacs.app/Contents/Resources/lean/lean/lib"] &&
              options.configPlan true == .load "/Users/ada/.config/leanmacs" },
    { name :=
        "with no option, config is looked for in the directory leanmacs under XDG_CONFIG_HOME, or under HOME's .config when that is unset; no toolchain is given; the editor's .olean files are beside the executable's directory; and an input method may compose"
      run :=
        let unset := { windowEnvironment with xdgConfigHome := none }
        let empty := { windowEnvironment with xdgConfigHome := some "" }
        let neither :=
          { windowEnvironment with
            xdgConfigHome := none, home := none }
        pure
          (parsed ["f"] ==
              some
                { file := some "/work/project/f", config := some "/xdg/leanmacs",
                  configGiven := false, state := some "/home/ada/.local/state/leanmacs",
                  data := some "/home/ada/.local/share/leanmacs", sysroot := none,
                  oleans := ["/opt/core/lib/lean"], composition := true } &&
            (parsed ["f"] unset).bind (·.config) == some "/home/ada/.config/leanmacs" &&
            (parsed ["f"] empty).bind (·.config) == some "/home/ada/.config/leanmacs" &&
            (parsed ["f"] neither).map (·.config) == some none) },
    { name :=
        "--config, --sysroot, --oleans and --no-ime are read, in any order, before or after the file; outside a bundle the directory --oleans gives is searched before the recorded one"
      run :=
        let given : Option Window.Options :=
          some
            { file := some "/work/project/f", config := some "/c", configGiven := true,
              state := some "/home/ada/.local/state/leanmacs",
              data := some "/home/ada/.local/share/leanmacs", sysroot := some "/s"
              oleans := ["/o", "/opt/core/lib/lean"], composition := false }
        pure
          ((parsed ["--config", "/c", "--sysroot", "/s", "--oleans", "/o", "--no-ime", "f"]).map
                ({ · with given := [] }) ==
              given &&
            (parsed ["--no-ime", "f", "--oleans", "/o", "--sysroot", "/s", "--config", "/c"]).map
                ({ · with given := [] }) ==
              given) },
    { name :=
        "config is loaded from the default directory only when it exists, from a directory given with --config whether it exists or not, and never with no toolchain, which is said"
      run :=
        let plan (arguments : List String) (exists_ : Bool) : Option Window.ConfigPlan :=
          (parsed arguments).map (·.configPlan exists_)
        pure
          (plan ["--sysroot", "/s", "f"] false == some (.skip none) &&
            plan ["--sysroot", "/s", "f"] true == some (.load "/xdg/leanmacs") &&
            plan ["--sysroot", "/s", "--config", "/c", "f"] false == some (.load "/c") &&
            plan ["f"] true == some (.skip (some Window.noToolchain)) &&
            plan ["--config", "/c", "f"] true == some (.skip (some Window.noToolchain)) &&
            plan ["--oleans", "/o", "f"] true == some (.skip (some Window.noToolchain)) &&
            (parsed ["--sysroot", "/s", "f"]
                    { windowEnvironment with
                      xdgConfigHome := none, home := none }).map
                (·.configPlan true) ==
              some (.skip none)) },
    { name :=
        "an executable in a bundle, with no --sysroot or --oleans, loads config from the bundle's toolchain and the .olean directories its record names, and --sysroot and --oleans still override them there, --oleans with each directory a colon joins and none recorded added"
      run :=
        let installed :=
          { windowEnvironment with
            appPath := "/Applications/Leanmacs.app/Contents/MacOS/editor"
            recordedOleans := ["/Applications/Leanmacs.app/Contents/Resources/lean/lean/lib"] }
        let directories (arguments : List String) : Option (Option String × List String) :=
          (parsed arguments installed).map fun options => (options.sysroot, options.oleans)
        pure
          (directories ["f"] ==
              some
                (some "/Applications/Leanmacs.app/Contents/Resources/lean/toolchain",
                  ["/Applications/Leanmacs.app/Contents/Resources/lean/lean/lib"]) &&
            (parsed ["f"] installed).map (·.configPlan true) == some (.load "/xdg/leanmacs") &&
            directories ["--sysroot", "/s", "--oleans", "/o:/p", "f"] ==
              some (some "/s", ["/o", "/p"])) },
    { name :=
        "an executable outside a bundle, given --sysroot and no --oleans, loads config from every .olean directory the build recorded for it, in order; with no record it loads none and says to give --oleans; and the directories --oleans gives, each one a colon joins, are searched before the recorded ones"
      run :=
        let recorded := ["/w/lean/.lake/build/lib/lean", "/w/other/.lake/build/lib/lean"]
        let built :=
          { windowEnvironment with
            appPath := "/w/packages/.lake/build/bin/editor", recordedOleans := recorded }
        let unrecorded := { built with recordedOleans := [] }
        let found (arguments : List String) (environment : Window.Environment) :
          Option (List String × Window.ConfigPlan) :=
          (parsed arguments environment).map fun options =>
            (options.oleans, options.configPlan true)
        pure
          (found ["--sysroot", "/s", "f"] built == some (recorded, .load "/xdg/leanmacs") &&
            found ["--sysroot", "/s", "f"] unrecorded == some ([], .skip (some Window.noModules)) &&
            found ["--sysroot", "/s", "--config", "/c", "f"] unrecorded ==
              some ([], .skip (some Window.noModules)) &&
            found ["--sysroot", "/s", "--oleans", "/o", "f"] built ==
              some ("/o" :: recorded, .load "/xdg/leanmacs") &&
            found ["--sysroot", "/s", "--oleans", "/o:/p", "f"] unrecorded ==
              some (["/o", "/p"], .load "/xdg/leanmacs") &&
            found ["f"] unrecorded == some ([], .skip (some Window.noToolchain)) &&
            (Window.noModules.splitOn "--oleans").length > 1) },
    { name :=
        "what is said when the .olean directories are not known names the record that is missing, <executable>.oleans, and says that --oleans takes a search path, directories joined with a colon, which must cover the core and every package of the editor's set"
      run :=
        let says (part : String) : Bool := (Window.noModules.splitOn part).length > 1
        pure
          (says "<executable>.oleans" && says "--oleans" && says "joined with `:`" &&
            says "the core's and every package's") },
    { name :=
        "two files, an option it does not know and an option with no value are each refused with the usage"
      run :=
        pure
          (refused ["a", "b"] && refused ["--bogus", "f"] && refused ["f", "--bogus"] &&
            refused ["f", "--config"] &&
            refused ["--sysroot"]) },
    { name :=
        "--present-mode with each of wgpu's names, --frame-latency with a number and --report are read; with none of them the renderer decides and nothing is reported"
      run :=
        let read (arguments : List String) :
          Option (Option Window.PresentMode × Option Nat × Bool) :=
          (parsed arguments).map fun options =>
            (options.presentMode, options.frameLatency, options.report)
        pure
          (read ["f"] == some (none, none, false) &&
            read ["--present-mode", "immediate", "f"] == some (some .immediate, none, false) &&
            read ["--present-mode", "fifo", "f"] == some (some .fifo, none, false) &&
            read ["--present-mode", "fifo-relaxed", "f"] == some (some .fifoRelaxed, none, false) &&
            read ["--present-mode", "mailbox", "f"] == some (some .mailbox, none, false) &&
            read ["f", "--frame-latency", "2"] == some (none, some 2, false) &&
            read ["--report", "f"] == some (none, none, true) &&
            read ["--report", "--present-mode", "immediate", "--frame-latency", "2", "f"] ==
              some (some .immediate, some 2, true)) },
    { name :=
        "a present mode wgpu has no name for, and a frame latency that is no number or is 0, are refused with the usage"
      run :=
        pure
          (refused ["--present-mode", "vsync", "f"] && refused ["--frame-latency", "x", "f"] &&
            refused ["--frame-latency", "0", "f"] &&
            refused ["f", "--present-mode"]) }]

/-- A journal entry of the window report's checks: its `present − input`
is `latency` microseconds, and it was presented `at` microseconds after the
window was asked to open. -/
def reportEntry (at_ latency : Nat) : Window.Report.Entry :=
  { inputNs := (at_ - latency) * 1000, presentNs := at_ * 1000 }

/-- The checks of the window mode's report (`Window.Report`): its figures
over journal entries built by hand. -/
def windowReportChecks : List Check :=
  let entries :=
    #[reportEntry 10000 5000, reportEntry 20000 1000, reportEntry 90000 3000,
      reportEntry 100000 2000, reportEntry 110000 4000]
  [{  name :=
        "the report's latencies are each entry's present - input, in microseconds: the median and the 99th percentile by nearest rank, and the largest"
      run :=
        let summary := Window.Report.summary 0 120000000 entries
        pure
          (summary.frames == 5 && summary.median == 3000 && summary.p99 == 5000 &&
            summary.max == 5000 &&
            (Window.Report.summary 0 1 (entries.extract 0 4)).median == 2000 &&
            (Window.Report.summary 0 1 (entries.extract 0 4)).p99 == 5000) },
    { name :=
        "the longest stretch with no entry is the longest of: from the open to the first entry, between two entries, and from the last entry to the close"
      run :=
        pure
          ((Window.Report.summary 0 120000000 entries).longestGap == 70000 &&
            (Window.Report.summary 0 300000000 entries).longestGap == 190000 &&
            (Window.Report.summary 0 120000000 #[reportEntry 100000 1000]).longestGap == 100000) },
    { name :=
        "an empty journal has no frame, latencies of 0, and one stretch from the open to the close"
      run :=
        let summary := Window.Report.summary 5000000 65000000 #[]
        pure
          (summary.frames == 0 && summary.median == 0 && summary.p99 == 0 && summary.max == 0 &&
            summary.longestGap == 60000) }]

/-- The checks of what the window mode posts to the editor loop before the
first event (`Window.Options.starts`), and of the loop it starts, on the
driver whose commands and jobs are the kit's opener's (`Opener.driver`):
each open of the starts is run as the host's open request runs it. -/
def windowStartChecks : List Check :=
  let parsed (arguments : List String) : Option Window.Options :=
    (Window.parse windowEnvironment arguments).toOption
  let started (starts : Array Window.Start) : Option TestDriver :=
    Opener.driver.map fun driver =>
      starts.foldl
        (fun driver start =>
          match start with
          | .open path =>
            (driver.stepped
                (driver.loop.invoke driver.handed
                  { command := FileJobs.openFileCommand, arguments := [.str path] })).1
          | _ => driver)
        driver
  [{  name :=
        "the window mode's state directory, --state's or the default under XDG_STATE_HOME, is the loop's first state's, as the host hands it over (EditorState.hostedBy); with neither variable set it has none"
      run :=
        let firstState (options : Option Window.Options) : Option (Option System.FilePath) := do
          let driver ← Opener.driver
          let options ← options
          return (driver.loop.state.hostedBy "/work/project" none
                options.stateDirectory).stateDirectory
        let xdg := { windowEnvironment with xdgStateHome := some "/xdg-state" }
        let homeless :=
          { windowEnvironment with
            xdgStateHome := none, home := none }
        pure
          (firstState (parsed ["--state", "/s"]) == some (some (System.FilePath.mk "/s")) &&
            firstState (Window.parse xdg [] |>.toOption) ==
              some (some (System.FilePath.mk "/xdg-state/leanmacs")) &&
            firstState (Window.parse homeless [] |>.toOption) == some none) },
    { name :=
        "with a state directory the restore is the first start, before the open, what is said and the reload; with none there is no restore, and that unsaved text is not journalled is said first of what is said"
      run :=
        let homeless :=
          { windowEnvironment with
            xdgStateHome := none, home := none }
        let without := (Window.parse homeless ["f"]).toOption
        pure
          ((parsed ["--state", "/s", "f"]).map (·.starts (.load "/c") #["a"]) ==
              some #[.restore none, .open "/work/project/f", .say "a", .reload] &&
            without.map (·.starts (.load "/c") #["a"]) ==
              some #[.open "/work/project/f", .say Window.notJournalled, .say "a", .reload]) },
    { name :=
        "the window mode started with no file opens nothing: it posts what it has to say and the reload, and no open; and the editor loop it starts holds one buffer, scratch, empty, with one window on it"
      run :=
        let empty := (parsed []).map (·.starts (.load "/xdg/leanmacs") #["hi"])
        let withFile := (parsed [(inFiles "note.txt").toString]).map (·.starts (.skip none) #[])
        pure <|
          empty == some #[.restore none, .say "hi", .reload] &&
            (parsed ["f"]).map (·.starts (.skip none) #[]) ==
              some #[.restore none, .open "/work/project/f"] &&
            (parsed ["f"]).map (·.starts (.load "/c") #["a", "b"]) ==
              some #[.restore none, .open "/work/project/f", .say "a", .say "b", .reload] &&
            match empty.bind started, withFile.bind started with
            | some opened, some loading =>
              opened.loop.state.buffers.size == 1 &&
                (opened.loop.state.buffers[0]?).join.map (·.name) == some "scratch" &&
                (showing opened).bind (·.text) == some "" &&
                opened.loop.state.windows.size == 1 &&
                opened.pending.isEmpty &&
                loading.pending.map (·.name) == #[Opener.loadJob]
            | _, _ => false },
    { name :=
        "the window mode started with no file and then handed an open-files input of one path shows that file's buffer once its load is finished, beside scratch"
      run :=
        pure <|
          let path := inFiles "note.txt"
          match ((parsed []).map (·.starts (.load "/xdg/leanmacs") #[])).bind started with
          | none => false
          | some empty =>
            let (asked, _) := fedTo empty [.openFiles [path.toString]]
            let (opened, _) := asked.finish 1
            let state := opened.loop.state
            empty.pending.isEmpty && asked.pending.map (·.name) == #[Opener.loadJob] &&
              state.buffers.size == 2 &&
              (state.buffer? ⟨0⟩).map (·.name) == some "scratch" &&
              state.findFile path == some ⟨1⟩ &&
              (showing opened state.frame.focused).map (·.id) == some ⟨1⟩ &&
              (showing opened state.frame.focused).bind (·.text) == some FileCases.noteText }]

end ModelTest
