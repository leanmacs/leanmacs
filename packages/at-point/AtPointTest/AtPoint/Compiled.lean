import AtPoint.Compiled
import AtPointApiTest.Contract
import AtPointTest.Check
import Editor.Config.Packages

/-!
# Model tests: `AtPoint/Compiled.lean`

The model tests of `AtPoint/Compiled.lean`: `atPointPackageChecks`, the
contract check of the interface package this package implements,
`at-point-api` (`AtPointApiTest.contractChecks`), over the `Package` value,
then what the `Package` value registers beyond the contract: the source
`words`, its job and its at-point source, and the use of `words` for every
buffer. The test driver's root, `AtPointTest/Model.lean`, runs them.
-/

namespace AtPointTest

open Editor

/-- The checks of the package `at-point` against the contract of
`at-point-api`: it registers a command under each name the interface
declares. The contract's checks are sentences with whether each holds,
and each is one check here. Then what the contract does not hold: a host
handed the package alone starts with its source, job and at-point source
`words`, and `words` as every buffer's chain. -/
def atPointPackageChecks : List Check :=
  (AtPointApiTest.contractChecks AtPoint.package).map
      (fun (name, held) => { name, run := pure held }) ++
    [{  name :=
          "a host handed the at-point package starts with the source words registered by it in the category word, its job words registered by it, the at-point source words registered by it, and a modeless buffer's at-point chain is words"
        run :=
          let (state, refused) : Config.State Unit Unit × Array String :=
            Config.State.ofPackages #[AtPoint.package]
          let registry := state.registry
          pure
            (refused == #[] &&
              registry.sources.any
                (fun entry =>
                  entry.source.name == "words" && entry.owner == AtPoint.package.owner) &&
              registry.sourcesIn Completion.Words.category == #["words"] &&
              registry.jobs.any
                (fun entry =>
                  entry.registration.name == Completion.Words.job &&
                    entry.owner == AtPoint.package.owner) &&
              registry.atPoints.any
                (fun entry =>
                  entry.atPoint.name == "words" && entry.owner == AtPoint.package.owner) &&
              registry.atPointNames none #[] == #["words"] &&
              registry.unknownAtPoints == #[]) }]

end AtPointTest
