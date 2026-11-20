import BindingSearch
import Editor.Package

/-!
# The `binding-search` package: the binding search

What a host registers so that it has the binding search
(`BindingSearch.lean`): the package `binding-search`
(`BindingSearch.package`, the core's `lean/Editor/Package.lean`), which
the entry module `BindingSearch/EditorPackage.lean` lists. A host
registers it for the owner `binding-search` when its loop starts, before
any config (the core's `lean/Editor/Config/Packages.lean`), so it holds
when config fails to load and a reload does not replace it.

- **The command**: `search-bindings`, a command that is given
  what it was called with (`commandWith`), which runs the binding its
  string names or asks for one among those the scheme reaches
  (`BindingSearch.searchBindings`). A host must be handed the minibuffer's
  package too (the core's `lean/Editor/Minibuffer/Compiled.lean`) for that
  prompt to be answered.
- **The source**: the completion source of the key bindings
  (`BindingSearch.source`), so config can ask for it by name.

This module is apart from `BindingSearch.lean` because it is what a host
is handed, not what config calls.

Pinned by `BindingSearchTest.bindingSearchChecks` and by the contract
check of `binding-search-api`, which `BindingSearchTest.bindingSearchPackageChecks`
runs over it (`BindingSearchTest/BindingSearch/Compiled.lean`).
-/

namespace Editor.BindingSearch

/-- The package `binding-search`: the binding search and the completion
source of the key bindings. -/
def package : Package :=
  { name := "binding-search"
    setup := do
      commandWith name searchBindings
      defineSource source }

end Editor.BindingSearch
