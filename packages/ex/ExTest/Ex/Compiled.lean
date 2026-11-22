import Editor.Config.Packages
import Editor.Test.Hosted
import Ex.Compiled
import ExApiTest.Contract
import ExTest.Check

/-!
# The tests of `Ex/Compiled.lean`

The tests of the `ex` package: `exPackageChecks`. The test driver
`ExTest/Model.lean` runs them; its module doc says what each shows.
-/

namespace ExTest

open Editor
open Editor.Test

/-- The checks of the `ex` package (`Ex/Compiled.lean`): the ex
names it binds are the files', its own and the buffers', and no feature's
that binds its own; what it registers, and nothing else; and the contract
of `ex-api` (`ExApiTest.contractChecks`) over it, with a check that the
contract bites. -/
def exPackageChecks : List Check :=
  [{    name :=
          "the package ex binds the files', its own and the buffers' ex names, w, w!, e, e!, autoread, noautoread, q, wq, reload, b, ls and bd, in that order, and no other"
        run :=
          pure
            (Ex.package.registered.ex.map (·.name) ==
              #["w", "w!", "e", "e!", "autoread", "noautoread", "q", "wq", "reload", "b", "ls",
                "bd"]) },
      { name :=
          "the ex package registers its four commands, ex, quit, save-and-quit and reload-config, each its own; its twelve ex names, in the order they are bound, b, ls and bd to switch-buffer, list-buffers and close-buffer and q to quit; and its two sources, the ex line's history then its names, each its own, so config can ask for each by name, and the sources of the category ex-line in the order of the ex prompt's defaults; and nothing else: no binding, job, mode, menu, theme or store kept across a restart"
        run :=
          let registry := hostedRegistry #[Ex.package]
          let modes := (Package.registered Ex.package).modes
          pure
            (Ex.package.name == "ex" && modes.isEmpty &&
              registry.entries.map (·.registration.name) ==
                #["ex", "quit", "save-and-quit", "reload-config"] &&
              registry.entries.all (·.owner == Ex.package.owner) &&
              registry.exNames ==
                #["w", "w!", "e", "e!", "autoread", "noautoread", "q", "wq", "reload", "b", "ls",
                  "bd"] &&
              registry.sources.map (·.source.name) == #["ex-history", "ex-names"] &&
              registry.sources.all (·.owner == Ex.package.owner) &&
              (registry.source? Ex.historySource.name).isSome &&
              (registry.source? Ex.namesSource.name).isSome &&
              registry.sourcesIn "ex-line" == #[Ex.historySource.name, Ex.namesSource.name] &&
              ((registry.find? Ex.quitName).any (·.owner == Ex.package.owner)) &&
              [("b", "switch-buffer"), ("ls", "list-buffers"), ("bd", "close-buffer"),
                    ("q", "quit")].all
                (fun (name, command) => (registry.ex? name).map (·.command) == some command) &&
              registry.bindings.isEmpty &&
              registry.jobs.isEmpty &&
              registry.menus.isEmpty &&
              registry.menuBar? == none &&
              registry.themeNames == #[] &&
              registry.codecs.isEmpty &&
              registry.ownersByKind.flatten.all (·.name == "ex")) },
      { name :=
          "the contract of ex-api this list runs bites: a package that registers the ex command but no quit fails it, on quit's check alone"
        run :=
          let lacking : Package :=
            { name := "lacking"
              setup := commandWith Ex.name Ex.exCommand }
          let failing := ((ExApiTest.contractChecks lacking).filter (!·.2)).map (·.1)
          pure
            (failing.length == 1 &&
              failing.all fun sentence =>
                (sentence.splitOn s!"`{ExApi.quitName}`").length > 1) }] ++
    (ExApiTest.contractChecks Ex.package).map fun (name, held) => { name, run := pure held }

end ExTest
