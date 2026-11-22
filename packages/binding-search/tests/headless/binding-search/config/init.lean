import Editor
import BindingSearch
open Editor

-- A config for the binding search, `search-bindings`. It chooses a style of
-- its own for the search's category, so the listing is short and in the
-- scheme's order; registers a command bound to a key with a description;
-- and registers a command whose message names a declaration of the binding
-- search's module, so it elaborates only on a base that holds that module.

def setup : SetupM Unit := do
  defineStyle (.keeping "starts" fun text candidate => candidate.startsWith text)
  useStyleFor "binding" "starts"
  command "yy-said" (message "said")
  bindKey "SPC y y" "yy-said" (desc := "Say it")
  command "search-label" (message s!"the binding search asks {BindingSearch.label.quote}")
