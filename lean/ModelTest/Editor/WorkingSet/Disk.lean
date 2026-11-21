import Editor.WorkingSet.Compiled
import ModelTest.Check
import ModelTest.Support.Evil
import ModelTest.Support.Excerpt
import ModelTest.Support.WorkingSet
import VcApiTest.Fake

/-!
# Model tests: `Editor/WorkingSet/Disk.lean`

The model tests of `Editor/WorkingSet/Disk.lean`: `workingSetDiskChecks`, on the
loop's driver over the editor's models, the job model and the version-control
interface's model. The root module `ModelTest` runs them; its module doc says
what each shows.
-/

namespace ModelTest

open Editor
open WorkingSetTest

namespace WorkingSetDiskTest

/-- The commit `HEAD` is at in the checks' repository. -/
def headCommit : String :=
  "c0ffee1234567890abcdef1234567890abcdef12"

/-- The checks' repository at `/r`, its `HEAD` at `headCommit`. -/
def repository : VersionControl.Model.Repository :=
  { committed := #[("a.txt", aText)], headId := headCommit }

/-- A repository with an unborn branch: no commit for `HEAD`. -/
def unborn : VersionControl.Model.Repository :=
  {}

/-- `d.txt` as the checks write it: r1, a 40-byte line, on its second line;
r2, a block of three lines from its third; r3, a line that will be
deleted, on its sixth. -/
def dText : String :=
  "line one\nlet configuration = load_settings(path);\nblock start alpha\nblock middle beta\nblock end gamma\na line that will be deleted entirely\nlast line\n"

/-- `d.txt` edited by another program: one character of r1 changed, three
lines inserted above r2, and r3's line deleted. -/
def dEdited : String :=
  "line one\nlet configuration = load_setting5(path);\nnew one\nnew two\nnew three\nblock start alpha\nblock middle beta\nblock end gamma\nlast line\n"

/-- The store file of the workspace of the checks under `/state`. -/
def storePath : System.FilePath :=
  WorkingSet.storeFile "/state" root.toString

/-- The working set commands' jobs, each made as a host makes it
(`JobRegistration.workWith`) with `backends` registered at the
version-control backend point: the write's over `vc-api`'s fake of
`repository` by default (`VcApiTest.backend`). -/
def jobsOver (repository : VersionControl.Model.Repository)
    (backends : Array VcApi.Backend := #[VcApiTest.backend repository]) :
    Array Config.JobRegistration :=
  WorkingSet.package.registered.jobs.map fun job =>
    { job with
      work := job.workWith (VcApiTest.backendValues backends), over := none }

/-- A driver of the checks with the working sets' commands, mode and jobs,
the write's repository `repository`, the state directory `state`, and
`files` as its world when given. -/
def diskDriver (repository : VersionControl.Model.Repository := repository)
    (state : Option System.FilePath := some "/state") (files : Option FileModel := none)
    (backends : Array VcApi.Backend := #[VcApiTest.backend repository]) : Option EvilDriver :=
  (driverWith WorkingSet.package.registered.commands WorkingSet.package.registered.modes
        (jobsOver repository backends)).map
    fun driver =>
    let driver :=
      { driver with
        loop := { driver.loop with state := { driver.loop.state with stateDirectory := state } }
        jobs := { driver.jobs with files := files.getD driver.jobs.files } }
    onDisk driver "d.txt" dText

/-- `driver` once `command` is invoked with `arguments` and everything it
starts is settled. -/
def ran (driver : EvilDriver) (command : String) (arguments : List Argument := []) : EvilDriver :=
  drained (invoked driver command arguments)

/-- `driver` once `keys` are pressed and `working-set-add demo` runs, and
everything it starts is settled; the selection is let go of. -/
def addedOn (driver : EvilDriver) (keys : String) : EvilDriver :=
  evilFed (ran (evilFed driver keys) WorkingSet.addName [.str "demo"]) "<Escape>"

/-- `driver` with `d.txt` open and r1, r2 and r3 added to `demo`, in that
order. -/
def threeAdded (driver : EvilDriver) : EvilDriver :=
  addedOn (addedOn (addedOn (opened driver "d.txt") "2 G") "3 G V 2 j") "6 G"

/-- The bytes of the file at `path` in `driver`'s world. -/
def bytesOn (driver : EvilDriver) (path : System.FilePath) : Option ByteArray :=
  (driver.jobs.files.file? path).map (·.bytes)

/-- The document the store file holds in `driver`'s world. -/
def storeOf (driver : EvilDriver) : Option WorkingSet.Document := do
  (WorkingSet.Document.read (← bytesOn driver storePath)).toOption

/-- The ranges of `demo` the store file holds in `driver`'s world. -/
def storedDemo (driver : EvilDriver) : Array WorkingSet.Stored :=
  (((storeOf driver).bind (·.sets.find? (·.name == "demo"))).map (·.ranges)).getD #[]

/-- The name of the set `demo`'s buffer. -/
def demoBuffer : String :=
  WorkingSet.bufferName "demo" "r@main"

/-- The headers of the entries of the buffer called `name` that are not
empty. -/
def headersOf (driver : EvilDriver) (name : String) : Array String :=
  (((excerptBufferNamed driver name).bind (·.excerpts)).map fun excerpts =>
        (excerpts.entries.map (·.header)).filter (!·.isEmpty)).getD
    #[]

/-- A fresh driver over the world `driver` left, as after a restart: a new
state, no buffers, the same files. -/
def restarted (driver : EvilDriver) : Option EvilDriver :=
  diskDriver (files := some driver.jobs.files) |>.map fun fresh => onDisk fresh "d.txt" dEdited

end WorkingSetDiskTest

open WorkingSetDiskTest in
/-- The checks of the working sets on disk (`Editor/WorkingSet/Disk.lean`),
on the loop's driver over the models: the second acceptance criterion of
navigation-and-windows phase 5, and the store's refusals. -/
def workingSetDiskChecks : List Check :=
  [{  name :=
        "criterion 2, write: three ranges added to demo are written to the workspace's file under the state directory, each with HEAD's commit and its lines"
      run :=
        pure <|
          match diskDriver with
          | none => false
          | some driver =>
            let added := threeAdded driver
            (storedDemo added).map
                  (fun stored => (stored.commit, stored.start.line, stored.stop.line)) ==
                #[(headCommit, 2, 3), (headCommit, 3, 6), (headCommit, 6, 7)] &&
              (storedDemo added).map (·.quote) ==
                #["let configuration = load_settings(path);\n",
                  "block start alpha\nblock middle beta\nblock end gamma\n",
                  "a line that will be deleted entirely\n"] &&
              (storeOf added).map (·.root) == some "/r" },
    { name :=
        "criterion 2, restart: a fresh editor over the same files, d.txt edited by another program, opens demo as one buffer of r1 changed, r2 at its new lines and r3 drifted, its quote as stored, read-only, in working-set-drifted"
      run :=
        pure <|
          match diskDriver with
          | none => false
          | some driver =>
            match restarted (threeAdded driver) with
            | none => false
            | some fresh =>
              let shownSet := ran (opened fresh "a.txt") WorkingSet.openName [.str "demo"]
              let drifted := excerptBufferNamed shownSet "d.txt@drifted"
              headersOf shownSet demoBuffer ==
                  #["d.txt:2 · changed", "d.txt:6", "d.txt:6 · drifted since c0ffee12"] &&
                excerptRead shownSet demoBuffer ==
                  some
                    ("let configuration = load_setting5(path);\n" ++ "\n" ++
                      "block start alpha\nblock middle beta\nblock end gamma\n" ++
                      "\n" ++
                      "a line that will be deleted entirely\n") &&
                shownSet.loop.state.echo == "demo: 3 ranges, 1 drifted" &&
                drifted.map (·.readOnly) == some true &&
                (drifted.map (·.spans.map (·.face))) == some #[⟨"working-set-drifted"⟩] },
    { name :=
        "criterion 2, after: a further add writes the store again, and r3's drifted stored form is as it was, not moved"
      run :=
        pure <|
          match diskDriver with
          | none => false
          | some driver =>
            let before := threeAdded driver
            match restarted before with
            | none => false
            | some fresh =>
              let shownSet := ran (opened fresh "a.txt") WorkingSet.openName [.str "demo"]
              let more := addedOn (evilFed shownSet "C-o") "g g"
              (storedDemo more).size == 4 && (storedDemo more)[2]? == (storedDemo before)[2]? },
    { name :=
        "with no state directory the sets live in memory: the first add says so once, and nothing is written"
      run :=
        pure <|
          match diskDriver (state := none) with
          | none => false
          | some driver =>
            let first :=
              ran (evilFed (opened driver "d.txt") "2 G") WorkingSet.addName [.str "demo"]
            let second := ran (evilFed first "<Escape> 3 G") WorkingSet.addName [.str "demo"]
            first.loop.state.echo == s!"demo: added d.txt:2; {WorkingSet.memoryOnlySentence}" &&
              second.loop.state.echo == "demo: added d.txt:3" &&
              (kept second).disk == .memoryOnly &&
              (second.jobs.files.files.filter (·.path.toString.startsWith "/state")).isEmpty },
    { name :=
        "a store file of version 2, and one that does not parse, are unreadable: said, their sets not shown, and never written over after an add"
      run :=
        pure <|
          let cases := ["{\"version\":2,\"root\":\"/r\",\"sets\":[]}", "{\"version\":1,\"root\":"]
          cases.all fun text =>
            match diskDriver with
            | none => false
            | some driver =>
              let world := driver.jobs.files.withFile storePath text.toUTF8
              let driver := { driver with jobs := { driver.jobs with files := world } }
              let added :=
                ran (evilFed (opened driver "d.txt") "2 G") WorkingSet.addName [.str "demo"]
              let reason :=
                match (WorkingSet.Document.read text.toUTF8) with
                | .error why => why
                | .ok _ => ""
              (kept added).disk == .unreadable reason &&
                bytesOn added storePath == some text.toUTF8 &&
                (rangesOf added "demo").size == 1 },
    { name := "working-set-remove writes the set without the range removed"
      run :=
        pure <|
          match diskDriver with
          | none => false
          | some driver =>
            let shownSet := ran (threeAdded driver) WorkingSet.openName [.str "demo"]
            let removed := ran shownSet WorkingSet.removeName
            (storedDemo removed).map (·.start.line) == #[3, 6] },
    { name := "with no repository the commit written is empty"
      run :=
        pure <|
          match diskDriver (repository := unborn) with
          | none => false
          | some driver =>
            let added := addedOn (opened driver "d.txt") "2 G"
            (storedDemo added).map (·.commit) == #[""] },
    { name :=
        "with no version-control backend registered the write takes the case no repository: the commit written is empty, though the repository has HEAD's commit"
      run :=
        pure <|
          match diskDriver (backends := #[]), diskDriver with
          | some bare, some backed =>
            (storedDemo (addedOn (opened bare "d.txt") "2 G")).map (·.commit) == #[""] &&
              (storedDemo (addedOn (opened backed "d.txt") "2 G")).map (·.commit) == #[headCommit]
          | _, _ => false },
    { name :=
        "a save of a buffer holding a range writes the store with the range as edited, and closing the buffer writes its detached form"
      run :=
        pure <|
          match diskDriver with
          | none => false
          | some driver =>
            let added := addedOn (opened driver "d.txt") "2 G"
            let edited := evilFed added s!"g g O {typed "top"} <Escape>"
            let saved := ran edited Files.saveName
            let gone := closed saved "d.txt"
            (storedDemo added).map (·.start.line) == #[2] &&
              (storedDemo saved).map (·.start.line) == #[3] &&
              (storedDemo gone).map (·.start.line) == #[3] &&
              (rangesOf gone "demo").map (·.hold) == #[.detached] }]

end ModelTest
