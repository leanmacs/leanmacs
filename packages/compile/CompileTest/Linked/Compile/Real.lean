import CompileTest.Linked.Compile
import Editor.RealHost

/-!
# Linked tests: the compile mode over the library's process service

A module of the wiring set (`AGENTS.md`, "Deterministic concurrency in
tests"; `docs/dev-practices/real-thread-checks.md`), beside the mirror of
`Compile.lean`, `CompileTest/Linked/Compile.lean`, whose stepped checks it
must not hold: the compile mode runs the core's process adapter, which has
no module of this package.

**The real adapter.** The library's process service: a child's streamed
lines and its exit status (W33). **Why.** It is the process service's
end-to-end check (AC4); the process model stands in for it in every other
check of the package.

`compileRunChecks`: the fixture `three-lines`' lines and its exit status
reach the compilation buffer, wiring only; that each line is shown as it is
delivered is `CompileTest.compileChecks`', and the order of a streamed
child's reads the process contract's (`Editor/Job/Contract.lean`). Its root
hands it the services `main` started (`CompileTest/Linked.lean`).
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.CompileTest.Linked.Compile.Real : Editor.WiringSet :=
  .wiring "the library's process service, through the compile mode"
    "it is the process service's end-to-end check, which the process model stands in for everywhere else"

namespace CompileTest

open Editor
open Editor.Test.Linked

/-- A check of `compileRunChecks`, a declaration of its own. It stays over the
real process service (row W33 of `docs/dev-practices/inferred-waits.md`):
streaming output and the exit status, end to end. Its directory is removed
once a flush of the process service, a barrier on its own child's work, is
completed (`withFiles`). -/
def criterion11RealProcessCheck (services : Job.Services) (fixtures : System.FilePath) : Check :=
  { name :=
      "over the real process service, the fixture three-lines' lines and its exit status reach the compilation buffer"
    run := do
      -- Wiring only: the process service is reached, streams the child's
      -- lines and answers its exit status. That each line is shown as it
      -- is delivered, before the child ends, is the model's over the
      -- process model (`CompileTest.compileChecks`' criterion 1 and 5,
      -- `CompileTest/Compile.lean`), and the order of a streamed child's
      -- reads is the process contract's (`Editor/Job/Contract.lean`).
      -- The directory is removed only once the process service has worked
      -- what was handed to it under it.
      withFiles services (targets := [.processes]) fun directory => do
          let published ← Snapshots.new
          let recorder ← DisplayRecorder.new { advance := 8, lineHeight := 16 } published.reader
          let display := recorder.handle
          -- A scratch buffer has no workspace: the directory scope is the
          -- loop's working directory, where the fixture looks for its files.
          let begin : EditorM (Loop TestScheme.scheme) := do
            let loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
            return { loop with state := { loop.state with workingDirectory := directory } }
          let (started, texts) ← begin.runReal (RealTexts.over published) display
          let .ok loop := started | return false
          let line := s!"'{fixtures / "three-lines"}'"
          let (stepped, texts) ←
            (loop.invoke compileKeys
                    { command := Compile.compileName, arguments := [.str line] }).runReal
                texts display
          let .ok stepped := stepped | return false
          let some start := stepped.starts[0]? | return false
          let some work :=
            (Compile.package.registered.jobs.find? (·.name == start.name)).map
              (·.work start.arguments) | return false
          let posts ← IO.mkRef (#[] : Array Invocation)
          -- Resolved, and replaced, by each post and by the job's end, on the
          -- job's thread: what a wait for a post wakes on.
          let posted ← IO.mkRef (← IO.Promise.new : IO.Promise Unit)
          let bump : BaseIO Unit := do
            let fresh ← IO.Promise.new
            (← posted.modifyGet fun current => (current, fresh)).resolve ()
          let handle ←
            Job.spawn services work bump fun invocation => do
                posts.modify (·.push invocation)
                bump
          let loopRef ← IO.mkRef stepped.loop
          let textsRef ← IO.mkRef texts
          -- Delivers `command` as the loop delivers a job's, and reads the
          -- compilation buffer after it.
          let deliver (command : EditorM Unit) : IO (Option String) := do
            let (next, after) ←
              ((← loopRef.get).deliver compileKeys s!"job 1 {Compile.runJob}" command).runReal
                  (← textsRef.get) display
            textsRef.set after
            let .ok next := next | return none
            loopRef.set next.loop
            let (text, after) ← (compilationText next.loop).runReal (← textsRef.get) display
            textsRef.set after
            return (text.toOption).join
          -- Whether the job has made `count` posts, waited for on each post
          -- and on the job's end, never by time: the promise is read before
          -- the posts, so a post between the two still wakes the wait. A job
          -- that ended with fewer has made all it will (its posts are handed
          -- before its outcome). `patience` is a hang guard.
          let postsAt (count : Nat) : IO Bool := do
            repeat
              let wake ← posted.get
              if (← posts.get).size ≥ count then
                return true
              if ← handle.ended then
                return false
              if (← Job.awaitWithin patience wake.result?).isNone then
                return false
            return false
          let deliverPost (index : Nat) : IO (Option String) := do
            let some invocation := (← posts.get)[index]? | return none
            deliver (runPosted invocation)
          unless ← postsAt 1 do
            handle.cancel
            return false
          discard <| deliverPost 0
          IO.FS.writeFile (directory / "go-1") ""
          unless ← postsAt 2 do
            handle.cancel
            return false
          let second ← deliverPost 1
          IO.FS.writeFile (directory / "go-2") ""
          -- hang guard: the job's end, on its outcome.
          if (← Job.awaitWithin patience handle.outcome.result?).isNone then
            handle.cancel
            return false
          -- What the child wrote after `two` came in posts of its own or with
          -- its end: each is delivered, in order, then the job's command.
          let mut last := second
          for index in [2:(← posts.get).size] do
            last ← deliverPost index
          let some (.finished command) ← handle.outcome? | return false
          last ← deliver command
          handle.settle
          let lastLine (text : String) : String :=
            ((text.splitOn "\n").filter (!·.isEmpty)).getLast?.getD ""
          let has (text : Option String) (part : String) : Bool :=
            text.any fun text => (text.splitOn "\n").contains part
          return has last "one" && has last "two" && has last "three" &&
              (last.map lastLine).any
                (·.startsWith "Compilation exited abnormally with code 2 after ") }

/-- What only the real process service shows of a compile: its output in
the compilation buffer before the child ends, with the fixture
`three-lines` (`fixtures`, `tests/compile`), which waits for files the
check makes. -/
def compileRunChecks (services : Job.Services) (fixtures : System.FilePath) : List Check :=
  [criterion11RealProcessCheck services fixtures]

end CompileTest
