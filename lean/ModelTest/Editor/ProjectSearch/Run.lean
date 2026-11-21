import Editor.Api
import Editor.File
import Editor.File.Model
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Job.Model
import Editor.Loop.Driver
import Editor.ModeLine
import Editor.ProjectSearch.Compiled
import Editor.ProjectSearch.Run
import Editor.Scene
import Editor.State
import Editor.Test.Hosted
import Editor.Test.Loop
import Editor.WindowCommands.Compiled
import FilesApi
import FilesApiTest.Fake
import ModelTest.Check
import ModelTest.Support.Excerpt

/-!
# Model tests: `Editor/ProjectSearch/Run.lean`

The model tests of `Editor/ProjectSearch/Run.lean`: `projectSearchRunChecks`,
on the loop's driver over the editor's models and the job model, with evil's
keys. The root module `ModelTest` runs them; its module doc says what each
shows.
-/

namespace ModelTest

open Editor
open Editor.Test

namespace ProjectSearchTest

/-- The files of the checks, on the job model's disk: `a.txt` holds no match
on disk (its buffer's unsaved text holds one), `b.txt` two matches six rows
apart, `c.txt` none, `sym.txt` the word `foo_bar` twice and `foo_barx`. -/
def disk : FileModel :=
  [("/w/a.txt", "nothing\n"), ("/w/b.txt", "needle one\nb\nc\nd\ne\nf\nneedle two\n"),
        ("/w/c.txt", "no\n"), ("/w/sym.txt", "foo_bar x\nfoo_barx foo_bar\n")].foldl
    (fun (files : FileModel) (path, text) => files.withFile path text.toUTF8)
    (({} : FileModel).withDirectory "/w")

/-- `name` opened as a buffer of the file `/w/<name>` holding `text`, and
shown. -/
def opening (name text : String) : Config.Registration :=
  { name := s!"open-{name}"
    action :=
      .call fun call => do
        let .ok id ← createBuffer name text | return
        discard <| id.attachFile s!"/w/{name}" ⟨0, 0, text.utf8ByteSize⟩ .lf
        discard <| call.target.window.id.show id }

/-- The commands of the checks: project search's, the window commands,
opening `a.txt` with
unsaved text, `b.txt` as on disk and `d.txt` as on disk in the load checks'
world, and closing the results buffer. -/
def registrations : Array Config.Registration :=
  ProjectSearch.package.registered.commands ++ WindowCommands.package.registered.commands ++
    #[opening "a.txt" "x needle\nyy\n", opening "b.txt" "needle one\nb\nc\nd\ne\nf\nneedle two\n",
      opening "d.txt" "needle d\n", opening "sym.txt" "foo_bar x\nfoo_barx foo_bar\n",
      { name := "close-results"
        action :=
          .call fun _ => do
            let some id ← findBuffer "*search: needle in /w*" | return
            discard <| id.remove }]

/-- Evil's keys with the commands of the checks, and project search's mode
registered, as a host's registry holds it: its roles on their keys in the
results buffer, and its name known to the loop that sets it; and the
extension points as `files-api`'s fake registers them, so a loaded file is
taken in through its `FilesApi.Files` value. -/
def searchKeys : Loop.Keys Vim.Default.scheme :=
  let handed := evilHanded registrations
  let registry :=
    ({} : Config.Registry).replaceModes .compiled ProjectSearch.package.registered.modes
  { handed with
    maps := fun state view =>
      registry.activeMaps Vim.Default.scheme state view ++ handed.maps state view
    registered :=
      { handed.registered with
        entering := fun name =>
          (ProjectSearch.package.registered.modes.find? (·.name == name)).map ([·])
        extensions := (Test.hostedRegistry #[FilesApiTest.fake]).extensionsAt } }

/-- The jobs of the checks: project search's. -/
def jobs (name : String) : Option (List Argument → Work) :=
  (ProjectSearch.package.registered.jobs.find? (·.name == name)).map (·.work)

/-- A driver over `files` whose window shows `b.txt` and then `a.txt`, both
open, `a.txt`'s text unsaved. -/
def driverOver (files : FileModel := disk) : Option EvilDriver :=
  (evilDriver "|" searchKeys).map fun driver =>
    let driver :=
      { driver with
        registered := jobs, jobs := { files } }
    excerptInvoked (excerptInvoked driver "open-b.txt") "open-a.txt"

/-- The load checks' disk: `disk`, and `d.txt`, after `c.txt` in the walk,
with one match. -/
def loadDisk : FileModel :=
  disk.withFile "/w/d.txt" "needle d\n".toUTF8

/-- A driver over `loadDisk` whose window shows `d.txt` and then `a.txt`,
both open, `a.txt`'s text unsaved; `b.txt` is open in no buffer. -/
def loadDriver : Option EvilDriver :=
  (evilDriver "|" searchKeys).map fun driver =>
    let driver :=
      { driver with
        registered := jobs, jobs := { files := loadDisk } }
    excerptInvoked (excerptInvoked driver "open-d.txt") "open-a.txt"

/-- `driver` once `command` is invoked with `arguments`. -/
def invoked (driver : EvilDriver) (command : String) (arguments : List Argument := []) :
    EvilDriver :=
  (driver.stepped (driver.loop.invoke driver.handed { command, arguments })).1

/-- `driver` once every post is delivered and every job finished, oldest
first. -/
def drained (driver : EvilDriver) : EvilDriver :=
  (List.range 64).foldl
    (fun driver _ =>
      match driver.posting[0]? with
      | some job => (driver.posted job.id).1
      | none =>
        match driver.pending[0]? with
        | some job => (driver.finish job.id).1
        | none => driver)
    driver

/-- The name of the buffer the view 0 of `driver` shows. -/
def shownName (driver : EvilDriver) : Option String := do
  let state := driver.loop.state
  let window ← state.window? ⟨0⟩
  return (← state.buffer? window.buffer).name

/-- The results buffer's name in the checks. -/
def results : String :=
  "*search: needle in /w*"

/-- What the results of a search of `needle` hold: `a.txt`'s unsaved row and
the one after it, then `b.txt`'s two matches each with two rows each side,
clipped, as two excerpts. -/
def resultsText : String :=
  "x needle\nyy\n" ++ "\n" ++ "needle one\nb\nc\n" ++ "\n" ++ "e\nf\nneedle two\n"

/-- `driver` once a search of `needle` has run and settled. -/
def searched (driver : EvilDriver) : EvilDriver :=
  drained (invoked driver ProjectSearch.name [.str "needle"])

end ProjectSearchTest

open ProjectSearchTest in
/-- The checks of `project-search` (`Editor/ProjectSearch/Run.lean`), on the
loop's driver over the editor's models and the job model. -/
def projectSearchRunChecks : List Check :=
  [{  name :=
        "project-search searches the directory of the buffer's file, labelled by it, into the results buffer it shows, and says how many matches it found in how many files"
      run :=
        pure <|
          match driverOver with
          | none => false
          | some driver =>
            let done := searched driver
            shownName done == some results &&
              done.loop.state.echo == "project-search: 3 matches in 2 files" },
    { name := "with no pattern project-search prompts for one, and a blank answer searches nothing"
      run :=
        pure <|
          match driverOver with
          | none => false
          | some driver =>
            let asked := invoked driver ProjectSearch.name
            let blank :=
              invoked asked ProjectSearch.name [.str " ", .bool true, .str "/w", .str "/w"]
            asked.loop.state.prompt.map (·.label) == some "Search /w: " &&
              (blank.loop.state.findBuffer results).isNone &&
              blank.pending.isEmpty &&
              blank.posting.isEmpty },
    { name := "after a search, C-o returns to the buffer it was asked from"
      run :=
        pure <|
          match driverOver with
          | none => false
          | some driver => shownName (evilFed (searched driver) "C-o") == some "a.txt" },
    { name :=
        "a search sets the last search to its pattern, forward, so the results view draws each match in search-match"
      run :=
        pure <|
          match driverOver with
          | none => false
          | some driver =>
            let done := searched driver
            let drawn :=
              ((lastView done).map fun view =>
                    view.decorations.filter (·.face == Loop.searchMatchFace)).getD
                #[]
            done.loop.state.lastSearch == some { pattern := "needle", forward := true } &&
              drawn.map (fun decoration => (decoration.start, decoration.stop)) ==
                #[(2, 8), (13, 19), (33, 39)] },
    { name :=
        "the results grow a delivery at a time: empty until the job's post is delivered, then each file's excerpts in walk order, a header above the first"
      run :=
        pure <|
          match driverOver with
          | none => false
          | some driver =>
            let started := invoked driver ProjectSearch.name [.str "needle"]
            let done := drained started
            excerptRead started results == some "" &&
              excerptRead done results == some resultsText &&
              ((excerptBufferNamed done results).bind (·.excerpts)).map
                  (·.entries.map (·.header)) ==
                some #["a.txt · 1 match", "b.txt · 2 matches", ""] },
    { name :=
        "a match in an open buffer's unsaved text is found: a.txt holds none on disk, and its buffer's match is in the results"
      run :=
        pure <|
          match driverOver with
          | none => false
          | some driver =>
            ((excerptRead (searched driver) results).map (·.startsWith "x needle\n")) ==
              some true },
    { name :=
        "editing a match in the results changes the file's buffer, which is modified, and the results view shows the modified mark"
      run :=
        pure <|
          match driverOver with
          | none => false
          | some driver =>
            let done := searched driver
            let changed := evilFed (excerptFed (evilFed done "w c w") [.commit "pin"]) "<Escape>"
            let marked := (lastView changed).any (·.status.any (·.text == ModeLine.modifiedMark))
            excerptRead changed "a.txt" == some "x pin\nyy\n" &&
              (excerptBufferNamed changed "a.txt").any (·.isModified) &&
              marked },
    { name := "a second search into the same results buffer cancels the first by its key"
      run :=
        pure <|
          match driverOver with
          | none => false
          | some driver =>
            -- The second from `a.txt` again, so it searches the same root.
            let twice :=
              invoked (evilFed (invoked driver ProjectSearch.name [.str "needle"]) "C-o")
                ProjectSearch.name [.str "needle"]
            let live :=
              twice.pending.filter fun job =>
                job.name == ProjectSearch.job && !(job.outcome matches .cancelled)
            let posting := twice.posting.filter (·.name == ProjectSearch.job)
            live.isEmpty && posting.size == 1 &&
              excerptRead (drained twice) results == some resultsText },
    { name :=
        "a delivery that arrives once the results buffer is closed does nothing and cancels the search"
      run :=
        pure <|
          match driverOver with
          | none => false
          | some driver =>
            let started := invoked driver ProjectSearch.name [.str "needle"]
            let closed := invoked (evilFed started "C-o") "close-results"
            let done := drained closed
            (done.loop.state.findBuffer results).isNone && done.pending.isEmpty &&
              done.posting.isEmpty &&
              !done.loop.state.echo.startsWith "project-search" },
    { name :=
        "a refused pattern is said in the echo area, and a search past the files limit says it stopped and to narrow the pattern"
      run :=
        pure <|
          let many :=
            (List.range 201).foldl
              (fun (files : FileModel) index =>
                files.withFile s!"/w/f{index + 1000}.txt" "needle\n".toUTF8)
              disk
          match driverOver, driverOver many with
          | some driver, some crowded =>
            (drained (invoked driver ProjectSearch.name [.str "a.b"])).loop.state.echo ==
                "project-search: the text model matches literal patterns only" &&
              (searched crowded).loop.state.echo ==
                "project-search: stopped after 201 matches in 200 files; narrow the pattern"
          | _, _ => false },
    { name :=
        "a file no buffer holds is loaded into a buffer shown nowhere, and its excerpts land at its walk slot though the open file after it was placed first"
      run :=
        pure <|
          match loadDriver with
          | none => false
          | some driver =>
            let done := searched driver
            let windows := done.loop.state.windows.size
            excerptRead done results == some (resultsText ++ "\n" ++ "needle d\n") &&
              excerptRead done "b.txt" == some "needle one\nb\nc\nd\ne\nf\nneedle two\n" &&
              shownName done == some results &&
              windows == 1 &&
              done.loop.state.echo == "project-search: 4 matches in 3 files" },
    { name :=
        "with no files implementation, a file no buffer holds is dropped from the results, nothing takes it in, and the search says it has no files implementation"
      run :=
        pure <|
          match loadDriver with
          | none => false
          | some driver =>
            let bare := { driver with keys := Test.withoutExtension FilesApi.Files driver.keys }
            let done := searched bare
            let echoes := done.model.display.scenes.map (·.echo)
            excerptRead done results == some ("x needle\nyy\n" ++ "\n" ++ "needle d\n") &&
              (done.loop.state.findBuffer "b.txt").isNone &&
              echoes.contains (FilesApi.noImplementation ProjectSearch.name) },
    { name := "a file whose text holds no match once it is loaded is dropped"
      run :=
        pure <|
          match loadDriver with
          | none => false
          | some driver =>
            let started := invoked driver ProjectSearch.name [.str "needle"]
            -- The disk changes after the search read it and before the load.
            let changed :=
              { started with
                jobs :=
                  { started.jobs with
                    files := started.jobs.files.withFile "/w/b.txt" "none\n".toUTF8 } }
            let done := drained changed
            let states :=
              (((excerptBufferNamed done results).map (·.text)).bind fun _ =>
                    (done.loop.state.findBuffer results).bind
                      (ProjectSearch.recordOf done.loop.state)).map
                fun record => record.files.map (·.state matches .dropped)
            excerptRead done results == some ("x needle\nyy\n" ++ "\n" ++ "needle d\n") &&
              states == some #[false, true, false] },
    { name := "editing through an adopted file's excerpt changes the adopted buffer"
      run :=
        pure <|
          match loadDriver with
          | none => false
          | some driver =>
            let done := searched driver
            let changed := evilFed (excerptFed (evilFed done "3 j c w") [.commit "pin"]) "<Escape>"
            excerptRead changed "b.txt" == some "pin one\nb\nc\nd\ne\nf\nneedle two\n" &&
              (excerptBufferNamed changed "b.txt").any (·.isModified) },
    { name :=
        "RET on a match in the results shows the file's buffer with the cursor on the match, and C-o returns to the results"
      run :=
        pure <|
          match driverOver with
          | none => false
          | some driver =>
            let visited := evilFed (searched driver) "w RET"
            let back := evilFed visited "C-o"
            shownName visited == some "a.txt" &&
              (evilSelection visited).map (·.ranges.map (·.head)) == some #[2] &&
              shownName back == some results },
    { name := "after C-w v, a visit in each window leaves the two windows on two matches"
      run :=
        pure <|
          match driverOver with
          | none => false
          | some driver =>
            let split := evilFed (searched driver) "C-w v"
            let first := evilFed split "w RET"
            let second := evilFed (evilFed first "C-w C-w") "3 j RET"
            let names :=
              second.loop.state.windows.filterMap fun window =>
                (second.loop.state.buffer? window.buffer).map (·.name)
            names.size == 2 && names.contains "a.txt" && names.contains "b.txt" },
    { name := "project-search-symbol on foo_bar searches \\<foo_bar\\>, as * builds it"
      run :=
        pure <|
          match driverOver with
          | none => false
          | some driver =>
            let done :=
              drained (invoked (excerptInvoked driver "open-sym.txt") ProjectSearch.symbolName)
            done.loop.state.lastSearch == some { pattern := "\\<foo_bar\\>", forward := true } &&
              shownName done == some "*search: \\<foo_bar\\> in /w*" &&
              excerptRead done "*search: \\<foo_bar\\> in /w*" ==
                some "foo_bar x\nfoo_barx foo_bar\n" }]

end ModelTest
