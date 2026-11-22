/-!
# The interface package `themes-api`

The interface package of the themes (`docs/design/extension-points.md`,
"Three layers"): the contract between the default package `themes`, which
implements it, and whatever reaches the command that loads a theme by its
name. A name another package reaches is part of the contract a replacement
must keep, so it is declared here, in the interface package, and a reacher
names the constant, never the text ("Reaches by name"). The default
config, which binds `SPC h t` to loading a theme
(`config/default/Config/Leader.lean`), is in the core until it moves out,
and the core cannot import a package, so it and the core's tests of it name
the name as text. It registers no behaviour.

Its test library publishes a fake (`ThemesApiTest.fake`) and the contract
check every implementation runs (`ThemesApiTest.contractChecks`).
-/

namespace ThemesApi

/-- The name the command that loads a theme, or asks for one among the
registered themes, is registered under: Emacs's name for it. -/
def loadName : String :=
  "load-theme"

/-- Every name this interface declares: the names an implementation must
register, which the contract check holds it to. -/
def names : Array String :=
  #[loadName]

end ThemesApi
