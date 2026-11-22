/-!
# The interface package `tab-commands-api`

The interface package of the tab commands (`docs/design/extension-points.md`,
"Three layers"): the contract between the default package `tab-commands`, which
implements it, and whatever reaches the tab commands by name. A name another
package reaches is part of the contract a replacement must keep, so it is
declared here, in the interface package, and a reacher names the constant,
never the text ("Reaches by name"). The Vim scheme's
tab table binds them under `C-w` (`Vim.Default.tabKeys`,
`packages/evil/Evil/Vim/Default.lean`), so `evil` requires this package.
The default config, which binds the tab commands under its leader
(`config/default/Config/Leader.lean`), is elaborated at run time on
whatever set the editor has, and names them as text, as a user's config
does.
It registers no behaviour.

Its test library publishes a fake (`TabCommandsApiTest.fake`) and the contract
check every implementation runs (`TabCommandsApiTest.contractChecks`).
-/

namespace TabCommandsApi

/-- The name of the command that opens a tab. -/
def newName : String :=
  "tab-new"

/-- The name of the command that closes a tab. -/
def closeName : String :=
  "tab-close"

/-- The name of the command that selects the next tab. -/
def nextName : String :=
  "tab-next"

/-- The name of the command that selects the previous tab. -/
def previousName : String :=
  "tab-previous"

/-- The name of the command that selects a tab by name. -/
def switchName : String :=
  "tab-switch"

/-- The name of the command that names a tab. -/
def renameName : String :=
  "tab-rename"

/-- The name of the command that moves a tab one place right. -/
def moveRightName : String :=
  "tab-move-right"

/-- The name of the command that moves a tab one place left. -/
def moveLeftName : String :=
  "tab-move-left"

/-- The name of the command that selects tab `n`, numbered from 1:
`tab-select-1` to `tab-select-9` are declared (`names`). -/
def selectName (n : Nat) : String :=
  s!"tab-select-{n}"

/-- Every name this interface declares: the names an implementation must
register, which the contract check holds it to, in the order
the default package registers them: the eight, then `tab-select-1` to
`tab-select-9`. -/
def names : Array String :=
  #[newName, closeName, nextName, previousName, switchName, renameName, moveRightName,
      moveLeftName] ++
    (Array.range 9).map fun index => selectName (index + 1)

end TabCommandsApi
