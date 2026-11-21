import Editor.AtPoint.Compiled
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Later
import Editor.Completion.Words
import Editor.Config.Registry
import Editor.InputScheme.Vim.Default
import Editor.Job
import Editor.Loop
import ModelTest.Support.AtPoint
import ModelTest.Support.Evil

/-!
# Model tests: support: Words

The fixture of the checks of the `at-point` package that ships
(`ModelTest.atPointChecks`, `wordsChecks`): the evil driver of
`ModelTest/Support/AtPoint.lean` with that package's commands
(`AtPoint.package`, `Editor/AtPoint/Compiled.lean`) in place of the kit's,
and its source `words`, its job and its at-point source `words` beside the
sources the core's checks complete from. It holds no checks of its own.
-/

namespace ModelTest

open Editor

/-- The completion sources at-point's own checks complete from: the core's
checks' (`atPointSources`) and the shipped `words`. -/
def shippedAtPointSources : List Completion.Source :=
  atPointSources ++ [Completion.Words.source]

/-- What a step of at-point's own checks is handed: `atPointHandedOver` the
sources `shippedAtPointSources`, with the shipped at-point source `words`
beside `atPoints`, and the commands the `at-point` package registers run in
place of the kit's, then those of `more`. -/
def shippedAtPointHanded (chain : Array String) (atPoints : List Completion.AtPoint)
    (more : Array Config.Registration := #[]) : Loop.Keys Vim.Default.scheme :=
  atPointHandedOver shippedAtPointSources [Completion.AtPoint.words] chain atPoints
    (AtPoint.package.registered.commands ++ more)

/-- A driver of at-point's own checks over the fixture `fixture`
(`evilState`), handed `shippedAtPointHanded chain atPoints more`, with the
job `words` registered. -/
def shippedAtPointDriver (fixture : String) (chain : Array String)
    (atPoints : List Completion.AtPoint) (more : Array Config.Registration := #[]) :
    Option EvilDriver :=
  let jobs (name : String) : Option (List Argument → Work) :=
    if name == Completion.Words.job then some (Completion.answering Completion.Words.gather)
    else none
  atPointDriverOver (shippedAtPointHanded chain atPoints more) jobs fixture

end ModelTest
