import BindingSearch.Compiled
import BindingSearchApiTest.Contract
import BindingSearchTest.Check
import Editor.Config.Packages

/-!
# Model tests: `BindingSearch/Compiled.lean`

The model tests of `BindingSearch/Compiled.lean`:
`bindingSearchPackageChecks`, the contract check of the interface package
this package implements, `binding-search-api`
(`BindingSearchApiTest.contractChecks`), over the `Package` value, and what the
`Package` value registers beyond the contract: its completion source under
its category, and nothing else. The
test driver's root, `BindingSearchTest/Model.lean`, runs them.
-/

namespace BindingSearchTest

/-- The checks of the package `binding-search` against the contract of
`binding-search-api`: it registers a command under each name the
interface declares. The contract's checks are sentences with whether each
holds, and each is one check here. Then what the contract does not hold:
the package registers its completion source under its category, the
source config asks for by name, and nothing but that and its command. -/
def bindingSearchPackageChecks : List Check :=
  let registered := Editor.BindingSearch.package.registered
  (BindingSearchApiTest.contractChecks Editor.BindingSearch.package).map
      (fun (name, held) => { name, run := pure held }) ++
    [{  name :=
          "the binding-search package registers its completion source `bindings` under the category `binding`, the package's own source (`BindingSearch.source`), so config can ask for it by name"
        run :=
          pure
            (registered.sources.map (fun source => (source.name, source.category)) ==
                #[("bindings", "binding")] &&
              registered.sources.map (·.name) == #[Editor.BindingSearch.source.name] &&
              Editor.BindingSearch.source.category == "binding") },
      { name :=
          "the binding-search package registers the command `search-bindings` and the source `bindings` and nothing else: no job, mode, binding, ex name, theme, face, segment, language, style, display, at-point source, menu, store or extension"
        run :=
          pure
            (registered.commands.map (·.name) == #["search-bindings"] &&
              registered.sources.size == 1 &&
              registered.jobs.isEmpty &&
              registered.modes.isEmpty &&
              registered.bindings.isEmpty &&
              registered.ex.isEmpty &&
              registered.themes.isEmpty &&
              registered.faces.isEmpty &&
              registered.segments.isEmpty &&
              registered.languages.isEmpty &&
              registered.styles.isEmpty &&
              registered.displays.isEmpty &&
              registered.atPoints.isEmpty &&
              registered.menus.isEmpty &&
              registered.stores.isEmpty &&
              registered.codecs.isEmpty &&
              registered.extensions.isEmpty) }]

end BindingSearchTest
