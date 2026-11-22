import Editor.Config.Packages
import ExecuteCommand.Compiled
import ExecuteCommandApiTest.Contract
import ExecuteCommandTest.Check

/-!
# Model tests: `ExecuteCommand/Compiled.lean`

The model tests of `ExecuteCommand/Compiled.lean`:
`executeCommandPackageChecks`, the contract check of the interface package
this package implements, `execute-command-api`
(`ExecuteCommandApiTest.contractChecks`), over the `Package` value, and what the
`Package` value registers beyond the contract: its completion source under
its category, and nothing else. The
test driver's root, `ExecuteCommandTest/Model.lean`, runs them.
-/

namespace ExecuteCommandTest

/-- The checks of the package `execute-command` against the contract of
`execute-command-api`: it registers a command under each name the
interface declares. The contract's checks are sentences with whether each
holds, and each is one check here. Then what the contract does not hold:
the package registers its completion source under its category, the
source config asks for by name, and nothing but that and its command. -/
def executeCommandPackageChecks : List Check :=
  let registered := Editor.ExecuteCommand.package.registered
  (ExecuteCommandApiTest.contractChecks Editor.ExecuteCommand.package).map
      (fun (name, held) => { name, run := pure held }) ++
    [{  name :=
          "the execute-command package registers its completion source `commands` under the category `command`, the package's own source (`ExecuteCommand.source`), so config can ask for it by name"
        run :=
          pure
            (registered.sources.map (fun source => (source.name, source.category)) ==
                #[("commands", "command")] &&
              registered.sources.map (·.name) == #[Editor.ExecuteCommand.source.name] &&
              Editor.ExecuteCommand.source.category == "command") },
      { name :=
          "the execute-command package is accepted alone and registers the command `execute-command` and the source `commands` and nothing of any other kind: of every kind the registry holds by owner, two entries, and no store cell"
        run :=
          let (state, refused) : Editor.Config.State Unit Unit × Array String :=
            Editor.Config.State.ofPackages #[Editor.ExecuteCommand.package]
          pure
            (refused == #[] && registered.commands.map (·.name) == #["execute-command"] &&
              registered.sources.size == 1 &&
              state.registry.ownersByKind.flatten.size == 2 &&
              state.cells.cells.isEmpty) }]

end ExecuteCommandTest
