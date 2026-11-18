import Editor.Api
import Editor.Command
import Editor.Command.Model
import Editor.Completion.Candidate
import Editor.Completion.Later
import Editor.Display.Model
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Loop
import Editor.Loop.Driver
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.Text.Model
import ModelTest.Check
import ModelTest.Support.Candidates
import ModelTest.Support.Completion
import ModelTest.Support.Driver
import ModelTest.Support.Keys
import ModelTest.Support.Prompts

/-!
# Model tests: `Editor/Completion/Later.lean`

The model tests of `Editor/Completion/Later.lean`: `laterChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- `driver` with the job that posted `arguments` delivering them, as the
command `minibuffer-candidates`, as a host delivers a job's post
(`runPosted`). -/
def deliveredBatch (driver : TestDriver) (arguments : List Argument) : TestDriver :=
  (driver.stepped
      (driver.loop.deliver driver.handed "job 1 later"
        (runPosted { command := Completion.candidatesCommand, arguments }))).1

/-- The checks of a source that answers later (`Editor/Completion/Later.lean`):
its order and its batches as arguments, its job on the job model, and the
command that takes a batch into the open prompt. -/
def laterChecks : List Check :=
  [{  name :=
        "an order round-trips with a place: a directory alone, a home alone, both and neither, with a region and texts after them; and the six arguments of an order still decode, with no place"
      run :=
        pure <|
          let placed (place : Completion.Place) : Completion.Order :=
            { laterOrder with
              query :=
                { laterOrder.query with
                  place, region := some { start := 1, stop := 2 }, texts := #[⟨5⟩] } }
          [({} : Completion.Place), { directory := some "/w" }, { home := some "/home/me" },
                  { directory := some "/w/src", home := some "/home/me" }].all
              (fun place =>
                Completion.Order.ofArguments? (placed place).arguments == some (placed place)) &&
            Completion.Order.ofArguments? [.nat 3, .nat 1, .nat 2, .str "w", .nat 0, .nat 30] ==
              some laterOrder &&
            (Completion.Order.ofArguments? [.nat 3, .nat 1, .nat 2, .str "w", .nat 0, .nat 30]).map
                (·.query.place) ==
              some {} },
    { name :=
        "an order round-trips with the context its command handed its sources: none, and plain arguments of every kind, numbers among them, with a place, a region and texts beside them; the six arguments of an order still decode, with no context, and a context cut short decodes to none"
      run :=
        pure <|
          let given (context : List Argument) : Completion.Order :=
            { laterOrder with
              query :=
                { laterOrder.query with
                  context, place := { directory := some "/w" }
                  region := some { start := 1, stop := 2 }, texts := #[⟨5⟩, ⟨6⟩] } }
          let contexts : List (List Argument) :=
            [[], [.str "fd", .nat 7, .bool true, .int (-1)], [.nat 2], [.bool false]]
          let whole := given [.str "fd", .nat 7]
          contexts.all
              (fun context =>
                Completion.Order.ofArguments? (given context).arguments == some (given context)) &&
            (Completion.Order.ofArguments? [.nat 3, .nat 1, .nat 2, .str "w", .nat 0, .nat 30]).map
                (·.query.context) ==
              some [] &&
            Completion.Order.ofArguments? (whole.arguments.take (whole.arguments.length - 3)) ==
              none },
    { name :=
        "an order and a batch round-trip through their arguments: an order with a region and texts, one with texts alone, and the six arguments of one with neither; a candidate with nothing beside its text, one with each optional field, all of them, and empty strings among them; malformed lists decode to none"
      run :=
        pure <|
          let batch : Array Completion.Candidate :=
            #[.ofText "a", { text := "", label := some "" }, { text := "dir/", isPartial := true },
              { text := ".env", hiddenUntil := some "." },
              { text := ".git/", isPartial := true, hiddenUntil := some "." },
              { text := "b", annotation := some "n" }, { text := "c", kind := some "k" },
              { text := "d", group := some "g" },
              { text := "e", label := some "l", annotation := some "a", kind := some "k"
                group := some "g" }]
          let atPoint : Completion.Order :=
            { laterOrder with
              query :=
                { laterOrder.query with
                  region := some { start := 2, stop := 5 }, texts := #[⟨4⟩, ⟨1⟩] } }
          let textsOnly : Completion.Order :=
            { laterOrder with query := { laterOrder.query with texts := #[⟨0⟩] } }
          Completion.Order.ofArguments? laterOrder.arguments == some laterOrder &&
            Completion.Order.ofArguments? atPoint.arguments == some atPoint &&
            Completion.Order.ofArguments? textsOnly.arguments == some textsOnly &&
            Completion.Order.ofArguments? [.nat 3, .nat 1, .nat 2, .str "w", .nat 0, .nat 30] ==
              some laterOrder &&
            Completion.Order.ofArguments? (atPoint.arguments ++ [.str "x"]) == none &&
            Completion.batchOfArguments? (Completion.batchArguments ⟨3⟩ 1 2 batch) ==
              some (⟨3⟩, 1, 2, batch) &&
            Completion.batchOfArguments? (Completion.batchArguments ⟨3⟩ 1 2 #[]) ==
              some (⟨3⟩, 1, 2, #[]) &&
            Completion.Order.ofArguments? [] == none &&
            Completion.Order.ofArguments? (laterOrder.arguments.drop 1) == none &&
            Completion.batchOfArguments? [.nat 3, .nat 1, .nat 2, .str "a"] == none &&
            Completion.batchOfArguments?
                [.nat 3, .nat 1, .nat 2, .nat 0, .bool false, .bool false, .bool false,
                  .bool false] ==
              none &&
            Completion.batchOfArguments? [.nat 3, .nat 1] == none &&
            Completion.batchOfArguments?
                [.nat 3, .nat 1, .nat 2, .str "a", .bool false, .bool false, .bool false,
                  .bool false] ==
              none &&
            Completion.batchOfArguments?
                [.nat 3, .nat 1, .nat 2, .str "a", .bool false, .bool false, .bool false,
                  .bool false, .bool false] ==
              none &&
            (Completion.Candidate.arguments { text := "a" }).length == 7 },
    { name :=
        "a source's job on the job model, given two batches, posts a minibuffer-candidates invocation for each, whose arguments decode to the batch with the order's view, index and generation, and then finishes; it waits the order's pause before its first post; one that echoes posts a candidate of the text it was asked; a malformed order fails the job"
      run :=
        pure <|
          let first := offered #["wq", "edit"]
          let second := offered #["rewrite", "w"]
          let work := Completion.Later.batches #[first, second]
          let (outcome, model) := (work laterOrder.arguments ()).runModel {}
          let (_, echoed) := (Completion.Later.echoing laterOrder.arguments ()).runModel {}
          let (bad, _) := (work [] ()).runModel {}
          let decoded (model : JobModel) :=
            model.posted.map fun posted =>
              (posted.command, Completion.batchOfArguments? posted.arguments)
          let pausedFirst :=
            match JobModel.runParking (work laterOrder.arguments ()).run {} with
            | .posted _ model _ => model.now == 30 && model.posted.size == 1
            | _ => false
          (outcome matches .finished _) &&
            decoded model ==
              #[(Completion.candidatesCommand, some (⟨3⟩, 1, 2, first)),
                (Completion.candidatesCommand, some (⟨3⟩, 1, 2, second))] &&
            pausedFirst &&
            decoded echoed ==
              #[(Completion.candidatesCommand, some (⟨3⟩, 1, 2, offered #["w!"]))] &&
            (bad matches .failed _) },
    { name :=
        "minibuffer-candidates, delivered as a job's post, takes its batch into the open prompt's asking source, in the source's group, and for arguments that are no batch says so in the echo area and takes nothing"
      run :=
        pure <|
          match pickDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            match asking.loop.state.minibufferView? with
            | none => false
            | some view =>
              let source : Completion.Asking :=
                { source := "later", later := { job := "j" }, askedFor := "", generation := 1 }
              let set :=
                { asking with
                  loop :=
                    { asking.loop with
                      state := (asking.loop.state.setCandidates { asking := #[source] }).2 } }
              let added := deliveredBatch set (Completion.batchArguments view 0 1 (offered #["a"]))
              let bad := deliveredBatch set [.str "x"]
              (candidatesOf added).map (·.asking.map (·.answered)) ==
                  some #[#[(Completion.Candidate.ofText "a").inGroup "later"]] &&
                bad.model.display.scenes.back?.map (·.echo) ==
                  some s!"{Completion.candidatesCommand}: malformed batch" &&
                (candidatesOf bad).map (·.asking) == (candidatesOf set).map (·.asking) }]

end ModelTest
