import Editor.BindingSearch
import Editor.Config.Registry

/-!
# The binding search, as compiled code registers it

What a host is handed so that it has the binding search
(`Editor/BindingSearch.lean`). A host registers it for the owner `compiled`
when its loop starts, before any config (`Editor/Config/Registry.lean`,
"Compiled commands"), so it holds when config fails to load and a reload
does not replace it.

- **`BindingSearch.commands`**: `search-bindings`, a command that is given
  what it was called with (`Action.call`), which runs the binding its
  string names or asks for one among those the scheme reaches
  (`BindingSearch.searchBindings`). A host must be handed the minibuffer's
  commands too (`Editor/Minibuffer/Compiled.lean`) for that prompt to be
  answered.
- **`BindingSearch.sources`**: the completion source of the key bindings
  (`BindingSearch.source`), so config can ask for it by name.

This module is apart from `Editor/BindingSearch.lean` because it names the
registry, which is the config session's: `Editor.lean` imports the command,
so that config can call it, and not this.

Pinned by `ModelTest.bindingSearchChecks` and `ConfigTest.shippedChecks`.
-/

namespace Editor.BindingSearch

/-- The binding search, as a host registers it for the owner `compiled`. -/
def commands : Array Config.Registration :=
  #[{ name, action := .call searchBindings }]

/-- The binding completion source, as a host registers it for the owner
`compiled`, so config can ask for it by name. -/
def sources : Array Completion.Source :=
  #[source]

end Editor.BindingSearch
