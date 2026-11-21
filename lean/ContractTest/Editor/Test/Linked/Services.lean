import ContractTest.Check
import ContractTest.Support.FileHold
import Editor.Job.Runner
import Editor.Test.Linked.Services

/-!
# Contract tests: `Editor/Test/Linked/Services.lean`

The bracket a check's temporary directory lives in (`Linked.withFiles`),
over the library's real file service: `linkedServicesChecks`. The service's
worker is held in process (`FileHold`) while an append into the directory
waits behind it, and the hold is let go only by the bracket's own report of
the hang, so the bracket is seen waiting for the queued work before it
removes the directory, every run, with no sleep. The flush itself and a
request's handle are pinned elsewhere (`flushContractChecks`,
`handleContractChecks`); these checks pin the bracket's rules. The root
module `ContractTest` runs them over the services it starts.
-/

namespace ContractTest

open Editor

/-- How long a check here waits for a reply it holds the task of: a guard
against a hang, never a result. -/
def linkedPatience : Nat :=
  10000

/-- `true` when `holds`; otherwise throws `seen`, so the check's failure
says what it saw. -/
def holdsOrSays (holds : Bool) (seen : String) : IO Bool := do
  unless holds do
    throw (IO.userError s!"saw {seen}")
  return true

/-- The checks of `Linked.withFiles` over the library's file service among
`services`, whose pump runs. -/
def linkedServicesChecks (services : Job.Services) : List Check :=
  [{  name :=
        "a directory's bracket removes it only once the file service has worked what was handed to it under the directory: with the worker held, an append into it ends ok before the directory goes, and the bracket's guard says a hang once"
      run := do
        let hold ← FileHold.hold services.completions
        let said ← IO.mkRef (#[] : Array String)
        let kept ← IO.mkRef (none : Option (Task (Except FileError Unit) × System.FilePath))
        try
          Test.Linked.withFiles services (guard := 0) (hung := fun line => do
              said.modify (·.push line)
              hold.release) fun directory => do
              let appended ← services.fileWorked (.append (directory / "log") "y".toUTF8)
              kept.set (some (appended, directory))
        finally
          hold.release
        let some (appended, directory) ← kept.get | return false
        let reply ← Job.awaitWithin linkedPatience appended
        let gone := !(← directory.pathExists)
        let said ← said.get
        holdsOrSays (reply matches some (.ok ()) && said.size == 1 && gone)
            s!"reply={repr reply} said={said} gone={gone}" },
    { name :=
        "a directory's bracket removes it only once the file service has worked what was handed to it under the directory, when its body throws, and the body's error is the one thrown"
      run := do
        let hold ← FileHold.hold services.completions
        let said ← IO.mkRef (#[] : Array String)
        let kept ← IO.mkRef (none : Option (Task (Except FileError Unit) × System.FilePath))
        let bracketed : IO Unit :=
          Test.Linked.withFiles services (guard := 0) (hung := fun line => do
            said.modify (·.push line)
            hold.release) fun directory => do
            let appended ← services.fileWorked (.append (directory / "log") "y".toUTF8)
            kept.set (some (appended, directory))
            throw (IO.userError "the body broke")
        let thrown ←
          try
            bracketed
            pure none
          catch error =>
            pure (some (toString error))
        hold.release
        let some (appended, directory) ← kept.get | return false
        let reply ← Job.awaitWithin linkedPatience appended
        let gone := !(← directory.pathExists)
        let said ← said.get
        holdsOrSays
            (thrown == some "the body broke" && reply matches some (.ok ()) && said.size == 1 &&
              gone)
            s!"thrown={thrown} reply={repr reply} said={said} gone={gone}" },
    { name := "a refused flush is said as a hang and the directory still goes"
      run := do
        -- The file port of these services refuses every flush, as a service
        -- whose queues are quit does.
        let refusing : Job.Services :=
          { services with
            files :=
              { services.files with flush := fun id => services.completions.finish id .cancelled } }
        let said ← IO.mkRef (#[] : Array String)
        let kept ← IO.mkRef (none : Option System.FilePath)
        Test.Linked.withFiles refusing (hung := fun line => said.modify (·.push line))
            fun directory => kept.set (some directory)
        let some directory ← kept.get | return false
        let gone := !(← directory.pathExists)
        let said ← said.get
        holdsOrSays (said.size == 1 && gone) s!"said={said} gone={gone}" }]

end ContractTest
