import Editor.Config.Packages
import WordCount.EditorPackage

/-!
# Model tests: `WordCount.lean`

The tests of the example package that need no Rust library. The test
driver's root, `WordCountTest/Model.lean`, runs them.
-/

namespace WordCountTest

open Editor

/-- The checks of the package `word-count`, each with what must hold as a
sentence. -/
def wordCountChecks : List (String × Bool) :=
  let (state, refused) : Config.State Unit Unit × Array String :=
    Config.State.ofPackages WordCount.EditorPackage.packages
  [("the empty text has no words", WordCount.count "" == 0),
    ("one word is one word", WordCount.count "lean" == 1),
    ("runs of spaces, tabs and line breaks separate words and count none",
      WordCount.count "  one \t two\n\nthree  \r\n" == 3),
    ("the package `word-count` is accepted, alone",
      refused == #[] && state.packages == #["word-count"]),
    ("it registers the command `word-count`, owned by `word-count`",
      state.registry.names == #["word-count"] &&
        state.registry.entries.all fun entry => entry.owner.name == "word-count")]

end WordCountTest
