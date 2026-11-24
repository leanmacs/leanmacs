import ConfigTest.Check
import ConfigTest.Support.Configs
import Editor.Headless
import Editor.Job.ProtocolContract
import Editor.Job.Real
import Editor.SyntaxTree.DeliveryContract
import Editor.SyntaxTree.Fake
import Editor.Test.Linked.Host

/-!
# Config tests: `Editor/Test/Linked/Host.lean`

The tests of the stage makers a host check gets its fakes from that no
other check reaches: `stageMakerChecks`. A stepped stage (`Stage.stepped`):
its job runs only on the session's step, every piece, completion and
request on the check's thread; a step leaves a job asleep on the clock
held and the rest quiescent; the loop's end steps a cancelled job that was
never stepped to its end; a check that leaves a completion unstepped fails
at the bracket; a stepped stage refuses the library's services and a real
host refuses it; and a stall is said at once. A stage's fake syntax service
(`Stage.fakeSyntaxService`) on a stepped host: it is the host's syntax
handler, it learns a text from the stage's published table, and each step
posts a `parsed` event to the stage's memory queue that the host's loop
takes. The root module `ConfigTest` runs them; its module doc says what
they show.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- The last snapshot the stage's published table holds, with its text,
among the first `count` ids; `none` if it holds none of them. -/
def lastPublished (published : SnapshotReader) (count : Nat := 64) :
    IO (Option (SnapshotId × String)) := do
  let mut last := none
  for index in [0:count] do
    let id : SnapshotId := ⟨index⟩
    if let some text← Job.realSnapshots published id then
      last := some (id, text)
  return last

/-- The text `stageMakerChecks` types into the scratch buffer: a json list
of two numbers, which the query captures. -/
def typedJson : String :=
  "[1, 2]"

/-- The scene counts the host said, oldest first: each `published <n>` line
of the stage's output. -/
def publishedCounts {β σ : Type} (stage : Stage β σ) : IO (Array Nat) := do
  return (← stage.output.get).filterMap fun line =>
      match line.splitOn "published " with
      | ["", rest] => rest.toNat?
      | _ => none

/-- What compiled code hands the stepped stage's checks: the job `load`,
which loads `/stage/a.txt`, and the command `load-it`, which starts it, with
`nappingCompiled`'s job `nap` and command `rest`. -/
def loadingCompiled : Compiled :=
  { nappingCompiled with
    commands :=
      nappingCompiled.commands ++
        #[{ name := "load-it", action := .plain (discard <| startJob "load") }]
    jobs :=
      nappingCompiled.jobs ++
        #[{ name := "load", work := fun _ => ProtocolContract.loader "/stage/a.txt" }] }

/-- The files the stepped stage's checks load from: `/stage/a.txt`. -/
def stageFiles : FileModel :=
  (({} : FileModel).withDirectory "/stage").withFile "/stage/a.txt" "a\n".toUTF8

/-- A stepped stage (`Stage.stepped`) over `loadingCompiled` and
`stageFiles`. -/
def steppedStage (context : Context) : IO (Stage Config.Elaborate.Base Config.Elaborate.Handle) :=
  do
  (← Stage.new context context.elaborator (memorySource []) loadingCompiled).stepped stageFiles

/-- The checks of a stepped stage (`Stage.stepped`) and its session's
steps. -/
def steppedStageChecks (context : Context) : List Check :=
  [{  name :=
        "a stepped stage's job runs only on the session's step: asked, its start is held in the fake scheduler and nothing is loaded; stepped to rest, it has loaded and ended, and every piece of its code, its completion, its request and its line are on the check's thread"
      run := do
        let stage ← steppedStage context
        let some fakes := stage.fakes | saw false "the stepped stage has no fakes"
        let thread ← IO.getTID
        onStage stage fun drive stage => do
            let session := Session.ofStage drive "/" stage
            session.ask [.run "load-it"]
            let held ← fakes.services.scheduler.size
            let startedBefore := (← fakes.services.files.started).size
            let before ← session.output.get
            session.step
            let after ← session.output.get
            let pieces ← fakes.services.scheduler.ranThreads
            let finished ← fakes.services.pump.finishedThreads
            let starts ← fakes.services.files.startThreads
            let lines ← session.threads.get
            saw
                (held == 1 && startedBefore == 0 && !before.contains "job 1 load: ok" &&
                  after.contains "job 1 load: ok" &&
                  !pieces.isEmpty &&
                  pieces.all (· == thread) &&
                  !finished.isEmpty &&
                  finished.all (· == thread) &&
                  starts == #[thread] &&
                  lines.all (· == thread) &&
                  (← fakes.services.quiescent))
                s!"held {held} pieces and {startedBefore} loads before the step; output {before} then {after}; pieces on {pieces}, completions on {finished}, loads on {starts}, lines on {lines}, the check on {thread}" },
    { name :=
        "a stepped session's step leaves a job asleep on the fake clock held, with nothing due and its line not printed; once the check moves the clock, a step ends it"
      run := do
        let stage ← steppedStage context
        let some fakes := stage.fakes | saw false "the stepped stage has no fakes"
        onStage stage fun drive stage => do
            let session := Session.ofStage drive "/" stage
            session.ask [.run "rest"]
            session.step
            let asleep :=
              (← session.clock.waiting) == 1 && (← fakes.services.scheduler.size) == 1 &&
                (← fakes.services.pump.quiescent) &&
                !(← session.output.get).contains "job 1 nap: ok"
            session.clock.advance 10
            session.step
            saw
                (asleep && (← session.output.get).contains "job 1 nap: ok" &&
                  (← fakes.services.quiescent))
                s!"asleep {asleep}; output {← session.output.get}" },
    { name :=
        "a stepped stage's loop's end steps a job it cancelled that was never stepped to its end, on the check's thread, and leaves its fakes quiescent"
      run := do
        let stage ← steppedStage context
        let some fakes := stage.fakes | saw false "the stepped stage has no fakes"
        let held ← IO.mkRef 0
        let held' := held
        let ended ←
          onStage stage fun drive stage => do
              let session := Session.ofStage drive "/" stage
              session.ask [.run "rest"]
              held'.set (← fakes.services.scheduler.size)
              return true
        let ran ← fakes.services.scheduler.ranThreads
        saw
            (ended && (← held.get) == 1 && ran == #[← IO.getTID] && (← fakes.services.quiescent) &&
              (← stage.clock.waiting) == 0)
            s!"the bracket said {ended}; {← held.get} pieces held at the end; the end ran pieces on {ran}" },
    { name :=
        "a stepped stage's bracket fails a check that left a completion unstepped: the load's completion still due once the loop's end has stepped its cancelled job"
      run := do
        let stage ← steppedStage context
        let some fakes := stage.fakes | saw false "the stepped stage has no fakes"
        let outcome ←
          try
            discard <|
                onStage stage fun drive stage => do
                  let session := Session.ofStage drive "/" stage
                  session.ask [.run "load-it"]
                  -- The job's start alone: its load is started and its
                  -- completion handed to the pump, which is not stepped.
                  discard <| fakes.services.scheduler.step
                  return true
            pure "the bracket returned"
          catch error =>
            pure (toString error)
        saw ((outcome.splitOn "the fake pump holds 1 due completions").length == 2)
            s!"the bracket said: {outcome}" },
    { name :=
        "a stepped stage refuses a stage over the library's services, and a real host refuses a stepped stage"
      run := do
        let real ← Stage.overFiles context (memorySource [])
        let refusedReal ←
          try
            discard <| real.stepped
            pure false
          catch _ =>
            pure true
        let stage ← steppedStage context
        let refusedHost ←
          try
            discard <| onRealStage stage fun _ _ => pure true
            pure false
          catch _ =>
            pure true
        saw (refusedReal && refusedHost)
            s!"Stage.stepped refused overFiles {refusedReal}; onRealStage refused a stepped stage {refusedHost}" },
    { name :=
        "a stepped session's stepUntil answers false at once on a stall: nothing it steps can move its output to what it waits for"
      run := do
        let stage ← steppedStage context
        onStage stage fun drive stage => do
            let session := Session.ofStage drive "/" stage
            let reached ← session.stepUntil (·.contains "never printed")
            saw (!reached) "stepUntil reached a line no one prints" }]

/-- The checks of the stage makers no other check reaches. -/
def stageMakerChecks (context : Context) : List Check :=
  steppedStageChecks context ++
    [{  name :=
          "a stage's fake syntax service is the host's syntax handler: it learns the text the host published of what was typed, from the stage's table, refuses its captures as not parsed until the check steps it, and its step posts one `parsed` event to the stage's memory queue, which the stepped host's loop takes and answers with one scene"
        run := do
          let stage ←
            Stage.new context context.elaborator (memorySource [])
                {
                  commands :=
                    #[{ name := "type-json"
                        action :=
                          .call fun call => do
                            discard <| call.target.window.id.insertAtSelections typedJson }] }
          let (stage, fake) ← stage.fakeSyntaxService
          let thread ← IO.getTID
          onStage stage fun drive stage => do
              drive.send (.run "type-json")
              unless ← drive.settle hangGuard do
                return false
              let some (snapshot, text) ←
                lastPublished
                    stage.collaborators.published.reader | saw false "no snapshot published once the host had run a command"
              let handler ← stage.collaborators.syntaxTree stage.collaborators.published.reader
              let .ok () ←
                (SyntaxTree.attach snapshot "json").runWith
                    handler | saw false s!"the attach of {repr snapshot} was refused"
              let learnt := (← fake.state.get).model.text? snapshot
              let .ok compiled ←
                (SyntaxTree.compile "json" SyntaxDeliveryContract.query).runWith
                    handler | saw false "the query was refused"
              let captures := fun () =>
                (SyntaxTree.captures snapshot compiled 0 text.utf8ByteSize).runWith handler
              let before ← captures ()
              -- The count three times, each request settled before the
              -- next, the step between the second and the third: the step
              -- posts its event to the memory queue before the third request,
              -- so the settle after that request drains both. What the event
              -- published is the second difference less the first, each
              -- holding a request's scene and a settle's.
              drive.send .published
              unless ← drive.settle hangGuard do
                return false
              drive.send .published
              unless ← drive.settle hangGuard do
                return false
              let stepped ← fake.step
              drive.send .published
              unless ← drive.settle hangGuard do
                return false
              let after ← captures ()
              let counts ← publishedCounts stage
              let scenes :=
                match counts.toList.reverse with
                | c :: b :: a :: _ => some ((c : Int) - b - (b - a))
                | _ => none
              let posts ← fake.postThreads
              let requests ← fake.requestThreads
              saw
                  (text == typedJson && learnt == some text &&
                    SyntaxDeliveryContract.same before (.error .notParsed) &&
                    stepped &&
                    SyntaxDeliveryContract.same after (SyntaxDeliveryContract.modelAnswer text) &&
                    scenes == some 1 &&
                    posts == #[thread] &&
                    requests.all (· == thread) &&
                    (← fake.quiescent))
                  s!"learnt {learnt} of the published {text}; captures before the step {SyntaxDeliveryContract.shown before}, after {SyntaxDeliveryContract.shown after}; stepped {stepped}; scene counts {counts}; posts on {posts}, requests on {requests}, the check's thread {thread}" }]

end ConfigTest
