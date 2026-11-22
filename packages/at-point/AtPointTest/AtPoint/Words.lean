import AtPoint.Words
import AtPointTest.Check
import AtPointTest.Support.Words
import Editor.Command
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.AtPointContract
import Editor.Completion.Candidate
import Editor.Completion.Later
import Editor.Job
import Editor.Job.Model
import Editor.Test.Jobs
import Editor.Text

/-!
# Model tests: `AtPoint/Words.lean`

The model tests of `AtPoint/Words.lean`: `wordsChecks`. The test driver's
root, `AtPointTest/Model.lean`, runs them. They were the core's
(`ModelTest.wordsChecks`) while the source `words` was a module of the
core, and moved here with their sentences and assertions as they were.
-/

namespace AtPointTest

open Editor
open Editor.Test

/-- The order `words`' job is started with in the checks: the region `al`
at the end of `alpha beta al`, from view 0, over the snapshots 0, 1 and 2. -/
def wordsOrder : Completion.Order :=
  { view := ⟨0⟩, index := 0, generation := 1
    query :=
      { text := "al", view := ⟨0⟩, region := some { start := 11, stop := 13 }
        texts := #[⟨0⟩, ⟨1⟩, ⟨2⟩] } }

/-- The at-point sources the contract is run on: each shipped one, and
`words` tuned. -/
def wordsContractSubjects : List Completion.AtPoint :=
  Completion.AtPoint.shipped.toList ++
    [Completion.AtPoint.words (least := 1), Completion.AtPoint.words (pause := 100)]

/-- The checks of the words of the open buffers (`AtPoint/Words.lean`):
the rule, the at-point source and the job on the job model, and the
at-point sources' contract (the core's
`lean/Editor/Completion/AtPointContract.lean`) on every shipped at-point
source and on `words` tuned, under the sentences of the core's
`atPointContractChecks`. -/
def wordsChecks : List Check :=
  (wordsContractSubjects.flatMap fun atPoint =>
      Completion.AtPointContract.properties.map fun property =>
        { name := s!"the at-point source {atPoint.name}: {property.name}"
          run := pure (property.holds atPointRunner atPoint) }) ++
    [{  name :=
          "a text's words are its maximal runs of word characters, `_`, digits and a character past ASCII among them, split at a space and at CRLF, each once in order; a run that overlaps the region is left out, and the same word elsewhere is kept"
        run :=
          pure <|
            Completion.Words.of "alpha beta_2 é\r\nalpha x9" == #["alpha", "beta_2", "é", "x9"] &&
              Completion.Words.of "alpha beta_2 é\r\nalpha x9" (some { start := 0, stop := 5 }) ==
                #["beta_2", "é", "alpha", "x9"] &&
              Completion.Words.of "" == #[] &&
              Completion.Words.of "  .,;" == #[] },
      { name :=
          "the order is Vim's C-n order: the first text's words after the region, then those before it, then each other text's from its start, each word once at its first place"
        run :=
          pure <|
            Completion.Words.ordered #["alpha beta al gamma", "almond alpha zed"]
                  (some { start := 11, stop := 13 }) ==
                #["gamma", "alpha", "beta", "almond", "zed"] &&
              Completion.Words.ordered #["b a", "c"] none == #["b", "a", "c"] &&
              Completion.Words.ordered #[] none == #[] },
      { name :=
          "the words C-n completes al from in alpha beta al with almond alpaca open are alpha, beta, almond and alpaca, and al on the line after alpha alpine, alpha and alpine"
        run :=
          pure <|
            Completion.Words.ordered #["alpha beta al", "almond alpaca"]
                  (some { start := 11, stop := 13 }) ==
                #["alpha", "beta", "almond", "alpaca"] &&
              Completion.Words.ordered #["alpha alpine\nal"] (some { start := 13, stop := 15 }) ==
                #["alpha", "alpine"] },
      { name :=
          "the word before the cursor starts where its run of word characters does, and is empty after a space"
        run :=
          pure <|
            Completion.Words.startBefore "alpha al" 8 == 6 &&
              Completion.Words.startBefore "alpha al" 5 == 0 &&
              Completion.Words.startBefore "alpha al" 6 == 6 &&
              Completion.Words.startBefore "café" 5 == 0 &&
              Completion.Words.startBefore "" 0 == 0 },
      { name :=
          "the at-point source words answers the word before the cursor from the category word, an empty one on a key; on a pause it answers only once two characters are typed"
        run :=
          pure <|
            let words := Completion.AtPoint.words
            let answer (start stop : Nat) : Option (Option Completion.Region × Bool) :=
              some (some { start, stop, sources := [.category Completion.Words.category] }, true)
            atPointRunner "beta al" 7 .key words == answer 5 7 &&
              atPointRunner "beta a" 6 .key words == answer 5 6 &&
              atPointRunner "beta " 5 .key words == answer 5 5 &&
              atPointRunner "beta al" 7 (.pause 240) words == answer 5 7 &&
              atPointRunner "beta a" 6 (.pause 240) words == some (none, true) &&
              atPointRunner "beta é" 7 (.pause 240) words == some (none, true) &&
              atPointRunner "one\nal" 6 (.pause 240) words == answer 4 6 &&
              words.pause == some 240 &&
              words.name == "words" },
      { name :=
          "words' job on the job model reads each snapshot and posts one batch a buffer, in C-n order, a word once across the batches; a released snapshot is passed over; it then marks the source answered"
        run :=
          pure <|
            let published :=
              snapshotModelTable #[some "alpha beta al", none, some "almond alpha zed"]
            let work := Completion.answering Completion.Words.gather wordsOrder.arguments
            let (outcome, model) := (work ()).runModel { files := { snapshots := published } }
            let batches :=
              model.posted.toList.filterMap fun posted =>
                (Completion.batchOfArguments? posted.arguments).map fun (_, _, _, batch) =>
                  batch.map (·.text)
            batches == [#["alpha", "beta"], #["almond", "zed"]] &&
              model.posted.all (·.command == Completion.candidatesCommand) &&
              outcome matches .finished _ &&
              Completion.Words.source.later ==
                some { job := Completion.Words.job, reask := .never, readsTexts := true } }]

end AtPointTest
