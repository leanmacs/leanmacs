import ContractTest.Check
import Editor.Api
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Jumps
import Editor.ProjectSearch.Compiled
import Editor.Test.Linked.Rig
import Editor.WorkingSet.Compiled
import Editor.Workspace.Kit
import FilesApiTest.Fake
import VcApiTest.Fake
import VcApiTest.Linked.Repositories

/-!
# Contract tests: `Editor/WorkingSet/Run.lean`

The tests of the working sets over the real bindings: `workingSetChecks`, both
acceptance criteria of navigation-and-windows phase 5 with the library's file
service, text store and fuzzy matcher and real git, which finds the
workspace, through a restart. The commit a set is written with comes from
the version-control interface, through `vc-api`'s fake backend
(`VcApiTest.backend`): the working set names no version-control
implementation.
-/

namespace ContractTest

open Editor
open Editor.Test.Linked
open VcApiTest.Linked

/-- The commit `HEAD` is at as the checks' version-control backend answers
it: `vc-api`'s fake (`VcApiTest.backend`) over a model repository whose
`HEAD` has this id, in place of the git implementation, which the working
set reaches only through that interface. -/
def fakeHead : String :=
  "c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00"

/-- The jobs of the working set checks: the file commands', the workspace
finder's, project search's and the working sets', as a host registers
them, each made as a host makes it (`JobRegistration.workWith`) with
`vc-api`'s fake backend over a repository at `fakeHead` registered, so the
write asks it for the commit. -/
def workingSetJobs : Array Config.JobRegistration :=
  (rigJobs #[FilesApiTest.fake, Test.workspaceFinderPackage] ++
        ProjectSearch.package.registered.jobs ++
        WorkingSet.package.registered.jobs).map
    fun job =>
    { job with
      work :=
        job.workWith
          (VcApiTest.backendValues
            #[VcApiTest.backend { committed := #[("a.txt", "")], headId := fakeHead }])
      over := none }

/-- The commands of the checks beside those: `goto-row` puts the window's
cursor at the start of the row its argument names; `select-rows` selects
the rows from its first argument to its second, line breaks included. -/
def workingSetExtras : Array Config.Registration :=
  #[{ name := "goto-row"
      action :=
        .call fun call => do
          let .nat row :: _ := call.arguments | return
          let offset ← (call.target.buffer.text.offsetOf ⟨row, 0⟩ : TextM Nat)
          Jumps.placeCursor call.target.window.id offset },
    { name := "select-rows"
      action :=
        .call fun call => do
          let .nat first :: .nat last :: _ := call.arguments | return
          let text := call.target.buffer.text
          let start ← (text.offsetOf ⟨first, 0⟩ : TextM Nat)
          let stop ← (text.offsetOf ⟨last + 1, 0⟩ : TextM Nat)
          let view := call.target.window.id
          if let .ok selection← view.selection then
            discard <|
                view.select
                  { selection with
                    ranges := #[⟨start, stop⟩], primary := 0 } }]

/-- The keys of the checks: none bound; the commands by name; the jobs
registered; the hooks of `files-api` as the packages register them. -/
def workingSetKeys : Loop.Keys TestScheme.scheme :=
  { command? := fun name =>
      ((rigCommands #[FilesApiTest.fake] ++ ProjectSearch.package.registered.commands ++
                WorkingSet.package.registered.commands ++
                workingSetExtras).find?
            (·.name == name)).bind
        fun registration =>
        match registration.action with
        | .call run =>
          some fun call => do
            run call
            return none
        | _ => none
    registered :=
      { jobs := fun name => workingSetJobs.any (·.name == name)
        -- The hooks the files implementation runs, as a host's registry holds
        -- them: the workspace's attach (the kit's package of the workspace's
        -- finding) and the working sets' own; and the fake's `Files` value.
        extensions :=
          (rigKeys
              #[FilesApiTest.fake, Test.workspaceFinderPackage,
                WorkingSet.package]).registered.extensions } }

/-- `a.txt` of the checks: r1, a 40-byte line, on its second row; r2, a
block of three rows from its third; r3, a row that will be deleted, on its
sixth. -/
def workingSetText : String :=
  "line one\nlet configuration = load_settings(path);\nblock start alpha\nblock middle beta\nblock end gamma\na line that will be deleted entirely\nlast line\n"

/-- `a.txt` as another program leaves it: one character of r1 changed, three
rows inserted above r2, r3's row deleted. -/
def workingSetEdited : String :=
  "line one\nlet configuration = load_setting5(path);\nnew one\nnew two\nnew three\nblock start alpha\nblock middle beta\nblock end gamma\nlast line\n"

/-- The loop of a host started fresh, with `state` as its state directory
and `base` as its working directory, once each of `invocations` has run and
settled. -/
def runHost (rig : ProjectRig) (base state : System.FilePath) (invocations : List Invocation) :
    IO (Option (Loop TestScheme.scheme × RealTexts)) := do
  let begin : EditorM (Loop TestScheme.scheme) := do
    let loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
    return { loop with state := loop.state.hostedBy base none (some state) }
  let (started, texts) ← begin.runReal (RealTexts.over rig.published) rig.display
  let .ok loop := started | return none
  runSettledFrom rig loop texts invocations workingSetKeys workingSetJobs

/-- The name of the first buffer of `loop` whose name starts with `lead`. -/
def bufferStarting (loop : Loop TestScheme.scheme) (lead : String) : Option String :=
  (loop.state.buffers.filterMap id |>.find? (·.name.startsWith lead)).map (·.name)

/-- The headers of the excerpts of the buffer called `name` that are not
empty. -/
def headersIn (loop : Loop TestScheme.scheme) (name : String) : Array String :=
  (((loop.state.findBuffer name).bind loop.state.buffer?).bind (·.excerpts) |>.map fun excerpts =>
        (excerpts.entries.map (·.header)).filter (!·.isEmpty)).getD
    #[]

/-- An invocation of `command` with `arguments`. -/
def invoking (command : String) (arguments : List Argument := []) : Invocation :=
  { command, arguments }

/-- The checks of the working sets over the real bindings, in a repository
and a state directory of their own, both temporary. -/
def workingSetChecks (services : Job.Services) : List Check :=
  [{  name :=
        "criteria 1 and 2 over the real bindings and real git: a.txt's rows and a row of project search's results are added and open as the files' rows; the store on disk carries HEAD's id as the version-control backend, vc-api's fake, answers it; a second host over the same state directory, a.txt rewritten outside the editor, opens demo as r1 changed, r2 moved and r3 drifted"
      run := do
        withRepository fun home repository => do
            let state := (home.parent.getD home) / "state"
            let files := #[("a.txt", workingSetText), ("b.txt", "one\nthe needle here\n")]
            writeGitRepository home repository { committed := files, worktree := files }
            let services := onIsolatedGit services home
            let rig ← ProjectRig.over services
            let a := repository / "a.txt"
            let some (added, texts) ←
              runHost rig repository state
                  [openFile a, invoking "goto-row" [.nat 1],
                    invoking WorkingSet.addName [.str "demo"],
                    invoking "select-rows" [.nat 2, .nat 4],
                    invoking WorkingSet.addName [.str "demo"], invoking "goto-row" [.nat 5],
                    invoking WorkingSet.addName [.str "demo"],
                    invoking ProjectSearch.name [.str "needle"], invoking "goto-row" [.nat 1],
                    invoking WorkingSet.addName [.str "pins"],
                    invoking WorkingSet.openName [.str "pins"]] | return false
            let some pins := bufferStarting added "*working-set: pins in " | return false
            let pinned ← bufferText rig texts added pins
            let head := fakeHead
            let stored ← IO.FS.readBinFile (WorkingSet.storeFile state repository.toString)
            let some document := (WorkingSet.Document.read stored).toOption | return false
            let demo := ((document.sets.find? (·.name == "demo")).map (·.ranges)).getD #[]
            let pinsStored := ((document.sets.find? (·.name == "pins")).map (·.ranges)).getD #[]
            IO.FS.writeFile a workingSetEdited
            let fresh ← ProjectRig.over services
            let some (reopened, freshTexts) ←
              runHost fresh repository state
                  [openFile (repository / "b.txt"),
                    invoking WorkingSet.openName [.str "demo"]] | return false
            let some demoBuffer := bufferStarting reopened "*working-set: demo in " | return false
            let shown ← bufferText fresh freshTexts reopened demoBuffer
            return pinned == some "the needle here\n" && headersIn added pins == #["b.txt:2"] &&
                demo.map (·.commit) == #[head, head, head] &&
                demo.map (·.start.line) == #[2, 3, 6] &&
                pinsStored.map (·.path) == #["b.txt"] &&
                headersIn reopened demoBuffer ==
                  #["a.txt:2 · changed", "a.txt:6",
                    s!"a.txt:6 · drifted since {String.ofList (head.toList.take 8)}"] &&
                shown ==
                  some
                    ("let configuration = load_setting5(path);\n" ++ "\n" ++
                      "block start alpha\nblock middle beta\nblock end gamma\n" ++
                      "\n" ++
                      "a line that will be deleted entirely\n") }]

end ContractTest
