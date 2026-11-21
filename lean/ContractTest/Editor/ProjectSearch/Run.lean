import ContractTest.Check
import Editor.Api
import Editor.Config.Registry
import Editor.Files.Compiled
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job.Runner
import Editor.Loop
import Editor.ProjectSearch.Compiled
import Editor.Test.Linked.Rig
import Editor.Test.Linked.Services

/-!
# Contract tests: `Editor/ProjectSearch/Run.lean`

The tests of `Editor/ProjectSearch/Run.lean` over the real bindings:
`projectSearchChecks`, what only the library's grep service, file service and
text store together show.
-/

namespace ContractTest

open Editor
open Editor.Test.Linked

/-- The jobs of the project search checks: the file commands' and project
search's, as a host registers them. -/
def searchJobs : Array Config.JobRegistration :=
  Files.package.registered.jobs ++ ProjectSearch.package.registered.jobs

/-- The commands of the checks beside the file commands' and project
search's: `insert-needle` inserts `needle ` at the start of `a.txt`'s buffer,
unsaved; `edit-b` replaces the match of `x needle` in the results buffer's
text with `pin`, as a change typed there over it. -/
def searchExtras : Array Config.Registration :=
  #[{ name := "insert-needle"
      action :=
        .call fun _ => do
          let some id ← findBuffer "a.txt" | return
          discard <| id.insertAt 0 "needle " },
    { name := "edit-b"
      action :=
        .call fun _ => do
          let state ← editorState
          let some id :=
            (state.buffers.findIdx? fun slot =>
                  slot.any (·.name.startsWith "*search: needle in ")).map
              (⟨·⟩ : Nat → BufferId) | return
          let .ok text ← id.text | return
          let content ← text.read
          let some at' := (content.splitOn "x needle")[0]?.map (·.utf8ByteSize + 2) | return
          discard <| id.replaceRange at' (at' + 6) "pin" }]

/-- The keys of the checks: none bound; the commands by name; the jobs
registered. -/
def searchKeys : Loop.Keys TestScheme.scheme :=
  { command? := fun name =>
      ((Files.package.registered.commands ++ ProjectSearch.package.registered.commands ++
                searchExtras).find?
            (·.name == name)).bind
        fun registration =>
        match registration.action with
        | .call run =>
          some fun call => do
            run call
            return none
        | _ => none
    registered := { jobs := fun name => searchJobs.any (·.name == name) } }

/-- The checks of project search over the real bindings
(`Editor/ProjectSearch/Run.lean`), in a fresh temporary directory, removed
once the file service has worked what was handed to it (`Linked.withFiles`): a
`.gitignore`d `ignored.txt`, `a.txt` open with `needle` inserted unsaved, and
`b.txt` holding a match on disk. -/
def projectSearchChecks (services : Job.Services) : List Check :=
  [{  name :=
        "criteria 2 and 3 over the real bindings: the results hold a.txt's unsaved match and b.txt's on-disk match, not ignored.txt's; a change typed over b.txt's match in the results changes b.txt's buffer, and the file on disk is unchanged"
      run := do
        Editor.Test.Linked.withFiles services fun directory => do
            IO.FS.writeFile (directory / ".gitignore") "ignored.txt\n"
            IO.FS.writeFile (directory / "ignored.txt") "needle\n"
            IO.FS.writeFile (directory / "a.txt") "a\n"
            IO.FS.writeFile (directory / "b.txt") "x needle\n"
            let rig ← ProjectRig.over services
            let some (searched, texts) ←
              runSettled rig directory
                  [openFile (directory / "a.txt"), { command := "insert-needle" },
                    { command := ProjectSearch.name, arguments := [.str "needle"] }]
                  (keys := searchKeys) (jobs := searchJobs) | return false
            let results := ProjectSearch.bufferName "needle" directory.toString
            let found ← bufferText rig texts searched results
            let some (edited, texts) ←
              runSettledFrom rig searched texts [{ command := "edit-b" }] (keys := searchKeys)
                  (jobs := searchJobs) | return false
            let b ← bufferText rig texts edited "b.txt"
            let onDisk ← IO.FS.readFile (directory / "b.txt")
            return found == some "needle a\n\nx needle\n" && b == some "x pin\n" &&
                onDisk == "x needle\n" }]

end ContractTest
