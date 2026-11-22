import ModelTest.Check
import ModelTest.Editor.Restore
import ModelTest.Support.Restore

/-!
# Model tests: `Editor/Restore/Restart.lean`

The model tests of `Editor/Restore/Restart.lean`: `restartChecks`, on the
loop's driver over the editor's models and the job model, with the probe's
replies scripted on the process model and the state directory `/state`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test
open Editor.Restore
open RestoreTest
open JournalReconcileTest

namespace RestartTest

/-- The running executable of the checks. -/
def running : System.FilePath :=
  "/A.app/Contents/MacOS/editor"

/-- The launcher of the checks. -/
def launcher : System.FilePath :=
  "/A.app/Contents/MacOS/leanmacs"

/-- How the checks' editor was launched. -/
def launch : Restart.Launch :=
  { launchedBy := some launcher, shipped := some running, running := some running
    arguments := ["headless", "--resume", "1", "/c", "/t"] }

/-- The probe of `target` replying with `exit` and the two streams. -/
def probeReply (target : System.FilePath) (exit : Process.Exit) (stdout : String)
    (stderr : String := "") : Process.Script :=
  { command := probeCommand target
    reply := .ok { exit, stdout := stdout.toUTF8, stderr := stderr.toUTF8 } }

/-- The probe of `target` passing. -/
def passing (target : System.FilePath) : Process.Script :=
  probeReply target (.code 0) "probe: ok\nlaunched-by none\nbundle none\n"

/-- A command that restarts into `/u/8/editor` through the API. -/
def restartIntoCommand : Config.Registration :=
  { name := "test-restart-into"
    action := .call fun _ => Editor.restart (into := some "/u/8/editor") }

/-- `driver` launched as the checks' editor, its probes replying as
`scripts` say, with `test-restart-into`. -/
def launched (driver : RestoreDriver) (scripts : Array Process.Script) : RestoreDriver :=
  { driver with
    loop := { driver.loop with state := { driver.loop.state with launch } }
    jobs :=
      { driver.jobs with
        processes :=
          { driver.jobs.processes with scripts := scripts ++ driver.jobs.processes.scripts } }
    keys :=
      { driver.keys with
        command? := fun name =>
          if name == restartIntoCommand.name then
            match restartIntoCommand.action with
            | .call run =>
              some fun call => do
                run call;
                return none
            | _ => none
          else driver.keys.command? name } }

/-- The checks' driver, restored and launched, its probes as `scripts`
say. -/
def restartDriver (scripts : Array Process.Script := #[passing running]) : Option RestoreDriver :=
  JournalReconcileTest.driver.map fun begun => launched (drained begun) scripts

/-- The plan the checks' editor hands over, into `into`. -/
def planFor (run : Nat) (into : Option System.FilePath := none) : Restart.Plan :=
  { record := recordPath stateDirectory
    handover :=
      { session := indexPath stateDirectory run, shipped := running
        candidates := Restart.candidates launch into, arguments := launch.arguments }
    launcher := some launcher }

end RestartTest

open RestartTest in
/-- The checks of the restart (`Editor/Restore/Restart.lean`). -/
def restartChecks : List Check :=
  [{  name :=
        "restart is refused with no state directory, while the restore has not finished, while a restart is in flight, and for a relative executable, each said"
      run :=
        pure <|
          let said (driver : Option RestoreDriver) (arguments : List Argument := []) :=
            driver.map fun driver => (invoked driver restartName arguments).loop.state.echo
          let stateless :=
            (restoreDriver (state := none)).map fun driver => launched (begun driver) #[]
          let unrestored := (restoreDriver).map fun driver => launched driver #[]
          let flying :=
            (restartDriver).map fun driver =>
              { driver with
                loop :=
                  { driver.loop with
                    state :=
                      { driver.loop.state with
                        restore :=
                          { driver.loop.state.restore with
                            handing := some { plan := planFor 1 } } } } }
          said stateless == some "restart: no state directory, so the session cannot be kept" &&
            said unrestored == some "restart: the session is still being restored" &&
            said flying == some "restart: a restart is already in flight" &&
            said restartDriver [.str "bin/editor"] ==
              some "restart: bin/editor is not an absolute path" &&
            (restartDriver.map fun driver => pendingNamed (invoked driver restartName) probeJob) ==
              some 1 },
    { name :=
        "a probe that exits with another status is refused, said with its status and first line of standard error, and nothing is handed over or written"
      run :=
        pure <|
          match restartDriver #[probeReply running (.code 3) "" "dyld: missing library\nmore"] with
          | none => false
          | some driver =>
            let done := drained (invoked driver restartName)
            done.loop.state.echo ==
                s!"restart: {running} did not start: it exited with status 3; dyld: missing library; the editor keeps running" &&
              done.loop.state.restore.handing.isNone &&
              done.handOver.isNone &&
              bytesAt done (recordPath stateDirectory) == none },
    { name := "a probe whose first line is not probe: ok is refused and said with it"
      run :=
        pure <|
          match restartDriver #[probeReply running (.code 0) "hello\n"] with
          | none => false
          | some driver =>
            let done := drained (invoked driver restartName)
            done.loop.state.echo ==
                s!"restart: {running} did not start: its first line was `hello`, not `probe: ok`; the editor keeps running" &&
              done.handOver.isNone },
    { name :=
        "a probe that passes begins the hand-over: the plan kept, the line said, then the index, not ended, and the record's exact text written, and the plan handed to the host"
      run :=
        pure <|
          match restartDriver with
          | none => false
          | some driver =>
            let probed := finishNamed (invoked driver restartName) probeJob
            let done := drained probed
            let plan := planFor 1
            (probed.loop.state.restore.handing.map (·.plan)) == some plan &&
              probed.loop.state.echo == Restart.handingLine true &&
              pendingNamed probed restartSaveJob == 1 &&
              done.handOver == some plan &&
              done.loop.state.outbox.handOver.isNone &&
              bytesAt done (recordPath stateDirectory) == some plan.handover.encode.toUTF8 &&
              (indexOf done 1).map (·.ended) == some false },
    { name :=
        "the session is written after the journal's orders for the last edit, with every buffer, window, tab and journal"
      run :=
        pure <|
          match restartDriver with
          | none => false
          | some driver =>
            let edited := keysFed (opened driver "a.txt") (typing "new ")
            let split := ran (ran edited Test.Windows.splitName) Test.Windows.newTabName
            let done := drained (invoked split restartName)
            let index := indexOf done 1
            let a := indexNamed done "a.txt"
            let generation := ((liveOf done a).map (·.generation)).getD 0
            done.handOver.isSome &&
              (index.map fun document =>
                  document.buffers.any fun buffer =>
                    buffer.name == "a.txt" && buffer.journal.isSome) ==
                some true &&
              (index.bind (·.frame)).map (·.tabs.map (·.windows.size)) == some #[2, 1] &&
              journalText done 1 a generation == some ("new " ++ aText) },
    { name := "the session is written only once a save in flight has finished"
      run :=
        pure <|
          match restartDriver with
          | none => false
          | some driver =>
            let edited := keysFed (opened driver "a.txt") (typing "new ")
            let saving := invoked edited FilesApi.saveName
            let probed := finishNamed (invoked saving restartName) probeJob
            let done := drained probed
            probed.loop.state.isSaving && probed.loop.state.restore.handing.isSome &&
              pendingNamed probed restartSaveJob == 0 &&
              done.handOver.isSome &&
              pendingNamed done restartSaveJob == 0 },
    { name := "while handing over, typed keys change no text and say the hand-over again"
      run :=
        pure <|
          match restartDriver with
          | none => false
          | some driver =>
            let probed := finishNamed (invoked driver restartName) probeJob
            let typed := keysFed probed (typing "zzz")
            textNamed typed "scratch" == textNamed probed "scratch" &&
              typed.loop.state.echo == Restart.handingLine true },
    { name :=
        "a refused save of the session says so, gives the hand-over up and leaves the editor journalling"
      run :=
        pure <|
          match restartDriver with
          | none => false
          | some driver =>
            -- The record's path is a directory: its save is refused.
            let blocked :=
              { driver with
                jobs :=
                  { driver.jobs with
                    files := (driver.jobs.files.makeDirectory (recordPath stateDirectory)).2 } }
            let done := drained (invoked blocked restartName)
            let after := drained (keysFed done (typing "x"))
            done.loop.state.restore.handing.isNone && done.handOver.isNone &&
              (done.loop.state.echo.startsWith "restart: the session could not be written: ") &&
              done.loop.state.echo.endsWith "; the editor keeps running" &&
              textNamed after "scratch" == some "x" &&
              !(journalFiles after).isEmpty },
    { name :=
        "restart-abandon says its reason, gives the hand-over up, and the journal starts new generations and removes the old ones"
      run :=
        pure <|
          match restartDriver with
          | none => false
          | some driver =>
            let edited := drained (keysFed driver (typing "x"))
            let before := journalFiles edited
            let handing :=
              { edited with
                loop :=
                  { edited.loop with
                    state :=
                      { edited.loop.state with
                        restore :=
                          { edited.loop.state.restore with
                            handing := some { plan := planFor 1 } } } } }
            let abandoned := invoked handing abandonName [.str "restart: given up"]
            let after := drained (keysFed abandoned idle)
            abandoned.loop.state.echo == "restart: given up" &&
              abandoned.loop.state.restore.handing.isNone &&
              !before.isEmpty &&
              before.all (!(journalFiles after).contains ·) &&
              !(journalFiles after).isEmpty },
    { name :=
        "Editor.restart (into := some p) hands over to [p, the running executable, the shipped one]"
      run :=
        pure <|
          match restartDriver #[passing "/u/8/editor"] with
          | none => false
          | some driver =>
            let done := drained (invoked driver restartIntoCommand.name)
            (done.handOver.map (·.handover.candidates)) ==
                some #[("/u/8/editor" : System.FilePath), running] &&
              done.handOver == some (planFor 1 (some "/u/8/editor")) }]

end ModelTest
