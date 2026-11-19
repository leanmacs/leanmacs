import Editor.Api
import Editor.Config.Registry
import Editor.File
import Editor.File.Model
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Job.Model
import Editor.Loop
import Editor.Loop.Driver
import Editor.ModeLine
import Editor.ProjectSearch.Compiled
import Editor.ProjectSearch.Run
import Editor.Scene
import Editor.State
import ModelTest.Check
import ModelTest.Support.Evil
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

namespace ProjectSearchTest

/-- The files of the checks, on the job model's disk: `a.txt` holds no match
on disk (its buffer's unsaved text holds one), `b.txt` two matches six rows
apart, `c.txt` none. -/
def disk : FileModel :=
  [("/w/a.txt", "nothing\n"), ("/w/b.txt", "needle one\nb\nc\nd\ne\nf\nneedle two\n"),
        ("/w/c.txt", "no\n")].foldl
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

/-- The commands of the checks: project search's, opening `a.txt` with
unsaved text and `b.txt` as on disk, and closing the results buffer. -/
def registrations : Array Config.Registration :=
  ProjectSearch.commands ++
    #[opening "a.txt" "x needle\nyy\n", opening "b.txt" "needle one\nb\nc\nd\ne\nf\nneedle two\n",
      { name := "close-results"
        action :=
          .call fun _ => do
            let some id ← findBuffer "*search: needle in /w*" | return
            discard <| id.remove }]

/-- The jobs of the checks: project search's. -/
def jobs (name : String) : Option (List Argument → Work) :=
  (ProjectSearch.jobs.find? (·.name == name)).map (·.work)

/-- A driver over `files` whose window shows `b.txt` and then `a.txt`, both
open, `a.txt`'s text unsaved. -/
def driverOver (files : FileModel := disk) : Option EvilDriver :=
  (evilDriver "|" (evilHanded registrations)).map fun driver =>
    let driver :=
      { driver with
        registered := jobs, jobs := { files } }
    excerptInvoked (excerptInvoked driver "open-b.txt") "open-a.txt"

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
          | _, _ => false }]

end ModelTest
