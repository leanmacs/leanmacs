import Editor.Language.Grammar.Answer
import ModelTest.Check

/-!
# Model tests: `Editor/Language/Grammar/Answer.lean`

The model tests of `Editor/Language/Grammar/Answer.lean`:
`grammarAnswerChecks`. The root module `ModelTest` runs them; its module doc
says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of a declared grammar's recorded answers
(`Editor/Language/Grammar/Answer.lean`), pure. -/
def grammarAnswerChecks : List Check :=
  [{  name := "an answer is found only under the generation it was recorded for"
      run :=
        let queries : Language.Grammar.Queries := { highlights := some "(number) @number" }
        let answers : Language.Grammar.Answers :=
          { generation := 3
            answers :=
              #[("ini", .registered queries), ("conf", .refused (.refused .notFound) false)]
            registered := #["ini"] }
        pure
          (answers.answerOf? 3 "ini" == some (.registered queries) &&
            answers.answerOf? 3 "conf" == some (.refused (.refused .notFound) false) &&
            answers.answerOf? 3 "toml" == none && answers.answerOf? 2 "ini" == none &&
            answers.answerOf? 4 "ini" == none &&
            ({} : Language.Grammar.Answers).answerOf? 0 "ini" == none) }]

end ModelTest
