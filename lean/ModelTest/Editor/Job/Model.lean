import Editor.File
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Fuzzy
import Editor.Fuzzy.Model
import Editor.Invocation
import Editor.Job
import Editor.Job.Contract
import Editor.Job.Model
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.SyntaxTree.Registration
import Editor.SyntaxTree.Registration.Model
import Editor.Test.Jobs
import Editor.Text.Model
import ModelTest.Check
import ModelTest.Support.Packages

/-!
# Model tests: `Editor/Job/Model.lean`

The model tests of `Editor/Job/Model.lean`: `jobModelChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A reply of another type than the count's: what a service that shares the
count's name would answer. -/
structure OtherReply where
  /-- What it says. -/
  text : String
  deriving TypeName

/-- A model whose service named as the count's answers every request with an
`OtherReply`, as a second package sharing the count's name would. -/
def sharedNameModel : PackageModel := fun request =>
  if request.service == countService then some (.ok (.mk (OtherReply.mk "not a count"))) else none

/-- The checks of the job port's pure model (`Editor/Job/Model.lean`). -/
def jobModelChecks : List Check :=
  [{
      name :=
        "in the job model, now reads the clock, sleep moves it by its duration, waitUntil a later instant sets it, and waitUntil a past instant leaves it",
      run :=
        let job : JobM (Nat × Nat × Nat × Nat) := do
          let start ← now
          sleep 5
          let slept ← now
          waitUntil 20
          let waited ← now
          waitUntil 3
          return (start, slept, waited, ← now)
        pure (modelled job { now := 2 } == (.finished (2, 7, 20, 20), 20)) },
    { name :=
        "in the job model, a job that throws ends failed with its message, at the instant it threw"
      run :=
        let job : JobM Nat := do
          sleep 4
          throw "no thanks"
        pure (modelled job == (.failed "no thanks", 4)) },
    { name :=
        "in the job model, with cancelAt inside a wait the job ends cancelled at that instant and makes no later request"
      run :=
        let job : JobM Nat := do
          sleep 10
          sleep 10
          sleep 10
          return 1
        -- A third sleep would leave the clock at 25 or later.
        pure (modelled job { cancelAt := some 15 } == (.cancelled, 15)) },
    { name :=
        "in the job model, a job that catches every error around each wait is still cancelled, in its first wait"
      run := pure (modelled stubborn { cancelAt := some 5 } == (.cancelled, 5)) },
    { name :=
        "in the job model, a job whose cancelAt has passed makes no request, and is cancelled whatever it would have returned"
      run :=
        let waits : JobM Nat := do
          sleep 10
          return 1
        pure
          (modelled waits { now := 5, cancelAt := some 3 } == (.cancelled, 5) &&
            modelled (pure 1 : JobM Nat) { now := 5, cancelAt := some 3 } == (.cancelled, 5)) },
    -- Not a property of the contract: it is an equality, which a real clock
    -- would fail, and the contract's inequality cannot see drift, because a
    -- timer that drifts ticks late, which is still "not before". Only a wait
    -- moves the model's clock, so the work between two ticks is a sleep
    -- shorter than the period.
    { name :=
        "in the job model, a timer does not drift: three ticks of a period of 10, with 3 ms of work after the first and the second, leave the clock at exactly 30"
      run :=
        let job : JobM Unit := do
          let timer ← Timer.every 10
          let timer ← timer.tick
          sleep 3
          let timer ← timer.tick
          sleep 3
          discard timer.tick
        pure (modelled job == (.finished (), 30)) },
    { name :=
        "in the job model, a run whose script takes longer than its time limit is refused as timedOut with the clock at exactly its start plus the limit, and is killed; one within its limit moves the clock by what it takes and is not killed"
      run :=
        let slow := JobContract.sh "/p" "/bin/sleep 600"
        let quick := JobContract.sh "/p" "exit 0"
        let model : JobModel :=
          { now := 10
            processes :=
              {
                scripts :=
                  #[{ command := slow,
                      reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty }
                      takes := 600000 },
                    { command := quick,
                      reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty }
                      takes := 30 }] } }
        let (late, afterLate) := (Process.runWithin slow 100 50).runModel model
        let (inTime, afterInTime) := (Process.runWithin quick 100 50).runModel model
        pure
          ((match late with
            | .finished (.error (.timedOut 50)) => true
            | _ => false) &&
            afterLate.now == 60 &&
            afterLate.processes.killed == #[slow] &&
            (match inTime with
            | .finished (.ok ran) => ran.exit == .code 0
            | _ => false) &&
            afterInTime.now == 40 &&
            afterInTime.processes.killed == #[]) },
    { name :=
        "in the job model, a cancel that falls before a run's time limit ends the job cancelled at that instant, and the run is killed once"
      run :=
        let slow := JobContract.sh "/p" "/bin/sleep 600"
        let model : JobModel :=
          { cancelAt := some 20
            processes :=
              {
                scripts :=
                  #[{ command := slow,
                      reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty }
                      takes := 600000 }] } }
        let (outcome, after) := (Process.runWithin slow 100 50).runModel model
        pure
          ((match outcome with
            | .cancelled => true
            | _ => false) &&
            after.now == 20 &&
            after.processes.killed == #[slow]) },
    { name :=
        "in the job model, environment requests are answered from its environments without moving the clock, and a message they say is reported"
      run :=
        let failure := Process.Failure.signalled 9
        let entry : Process.Entry := { stamps := #[], found := .failed failure }
        let job : JobM (Option Process.Entry × Process.Policy) := do
          Process.askEnvironment (.record "/p/d" entry)
          let found ← Process.askEnvironment (.cached "/p/d")
          let policy ← Process.askEnvironment .policy
          return (found, policy)
        let (outcome, after) :=
          job.runModel { now := 7, environments := { setting := .inherited, limit := 3 } }
        pure
          (outcome ==
              .finished
                (some entry,
                  { setting := .inherited, host := .headless, resolved := none, limit := 3 }) &&
            after.now == 7 &&
            after.reported == #[Process.failureMessage "/p/d" failure]) },
    { name := "in the job model, a post is recorded and answered at once, without moving the clock"
      run :=
        let job : JobM Nat := do
          post (JobContract.posting "first")
          sleep 5
          post (JobContract.posting "second" [.nat 2])
          return 9
        let (outcome, after) := job.runModel { now := 3 }
        pure
          (outcome == .finished 9 && after.now == 8 &&
            after.posted ==
              #[JobContract.posting "first", JobContract.posting "second" [.nat 2]]) },
    { name :=
        "in the job model, a run that parks parks at each post, with it recorded and the clock where it was, and resumes from there to its end"
      run :=
        let job : JobM Nat := do
          post (JobContract.posting "first")
          sleep 5
          post (JobContract.posting "second" [.nat 2])
          return 9
        let parkedAt {α : Type} : JobModel.Ran α → Option (Invocation × Array Invocation × Nat)
          | .posted invocation model _ => some (invocation, model.posted, model.now)
          | _ => none
        let first := JobModel.runParking job.run { now := 3 }
        let second :=
          match first with
          | .posted _ model resume => some (JobModel.runParking (resume ()) model)
          | _ => none
        let third :=
          match second with
          | some (.posted _ model resume) => some (JobModel.runParking (resume ()) model)
          | _ => none
        pure
          (parkedAt first ==
              some (JobContract.posting "first", #[JobContract.posting "first"], 3) &&
            (second.bind parkedAt).map (·.1) == some (JobContract.posting "second" [.nat 2]) &&
            (second.bind parkedAt).map (·.2.2) == some 8 &&
            (match third with
            | some (.ended (some (.ok 9)) model) => model.posted.size == 2
            | _ => false)) },
    { name :=
        "in the job model, a run that parks does not park at a post once a cancel is due: the job is cancelled at its wait"
      run :=
        let job : JobM Unit := do
          post (JobContract.posting "first")
          sleep 10
          post (JobContract.posting "second")
        pure
          (match JobModel.runParking job.run { cancelAt := some 5 } with
          | .ended none model => model.posted == #[JobContract.posting "first"] && model.now == 5
          | _ => false) },
    { name :=
        "in the job model, a fuzzy request is answered with the fuzzy model's ranking and moves no clock; with a refusal set it is answered as an error, `fuzzy: ` and the refusal, which the job can catch and go on from, and which, uncaught, fails the job"
      run :=
        let candidates := #["wq", "edit", "w"]
        let ranked : JobM (Array Nat) := Job.embedFuzzy (Fuzzy.rank "w" candidates)
        let caught : JobM String := do
          try
            discard ranked
            return "answered"
          catch message =>
            sleep 1
            return message
        pure
          (modelled ranked { now := 4 } == (.finished (FuzzyModel.rank "w" candidates), 4) &&
            modelled caught { fuzzyRefusal := some "broken" } == (.finished "fuzzy: broken", 1) &&
            modelled ranked { fuzzyRefusal := some "broken" } == (.failed "fuzzy: broken", 0)) },
    { name :=
        "in the job model, a package request is answered by the model's packages at once, read back typed, a refusal as a value, and a service the model does not know is noSuchService"
      run :=
        let job : JobM (Option Nat × Bool × Bool × Nat) := do
          let counted ← PackageService.askAs CountReply (countAfter 4)
          let refused ← PackageService.askAs CountReply { countAfter 0 with operation := "back" }
          let unknown ← PackageService.ask { countAfter 0 with service := "elsewhere" }
          return (counted.toOption.map (·.value), refused matches .error (.refused _),
              unknown matches .error (.noSuchService "elsewhere"), ← now)
        let unknownByDefault : JobM Bool := do
          return (← PackageService.ask (countAfter 1)) matches .error (.noSuchService _)
        pure
          (modelled job { now := 3, packages := countModel } ==
              (.finished (some 5, true, true, 3), 3) &&
            modelled unknownByDefault == (.finished true, 0)) },
    { name :=
        "in the job model, a package reply of another type than the one asked for, as a service sharing another's name gives, is refused as a value, never a crash, and the job goes on"
      run :=
        let job : JobM (Bool × Bool) := do
          let counted ← PackageService.askAs CountReply (countAfter 4)
          let raw ← PackageService.ask (countAfter 4)
          return (counted matches .error (.refused _), raw matches .ok _)
        pure (modelled job { packages := sharedNameModel } == (.finished (true, true), 0)) },
    { name :=
        "a registration in the job model moves no clock, and the registry it answers from records it"
      run :=
        let python : GrammarSource :=
          { library := "/lib/grammars.so", symbol := "tree_sitter_python" }
        let table : GrammarRegistry :=
          {
            libraries :=
              some #[("/lib/grammars.so", .exports #[("tree_sitter_python", .grammar)])] }
        let job : JobM (Bool × Nat) := do
          let answer ← Grammar.register python
          return (answer matches .ok "python", ← now)
        let (outcome, after) := job.runModel { now := 6, grammars := table }
        let refused : JobM Bool := do
          return (← Grammar.register python) matches .error (.refused .unsupported)
        pure
          (outcome == .finished (true, 6) && after.now == 6 &&
            after.grammars.sourceOf? "python" == some python &&
            modelled refused == (.finished true, 0)) },
    { name :=
        "a contract property whose job returns false, throws or is cancelled has not held, and each is named with how it ended"
      run := do
        let properties : List JobContract.Property :=
          [{ name := "holds", holds := pure true }, { name := "false", holds := pure false },
            { name := "throws", holds := throw "no thanks" },
            { name := "cancelled",
              holds := do
                sleep 10
                return true }]
        let failed ←
          JobContract.failures (fun job => pure (job.runModel { cancelAt := some 5 }).1) properties
        return failed ==
            ["false", "throws (the job failed with `no thanks`)",
              "cancelled (the job was cancelled)"] }]

end ModelTest
