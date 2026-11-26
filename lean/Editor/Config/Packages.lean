import Editor.Config.Reload
import Editor.Package

/-!
# Registering packages

What a host does with the packages it is handed (`Editor/Package.lean`):
`Config.State.ofPackages` makes the config state a host starts from, with
every package registered, in the order of the array, before any config.
It is pure, so the model tests run it (`ModelTest.packageChecks`).

## A package's grammars

A package declares the grammars its Lake package ships on
`Package.grammars`, with paths relative to that Lake package's `grammars/`
directory (`Editor/Package.lean`). `collected` resolves them against the
directory where that directory is staged beside the running editor, which
the host is handed as a table of Lake packages' directories
(`ofPackages`'s `grammarDirectories`, read from the `editor.grammars`
record, `Editor/ModuleLookup.lean`), and appends them to what the
package's `setup` collected, so they are owned by the package and
registered as config's are, by the core's `register-grammars` job at each
install. A path that is absolute or climbs out of the directory
(`Language.Grammar.within?`) refuses the package with the path
(`leavesGrammars`), and so does a package with grammars whose Lake package
has no staged directory, or that no root tagged with a Lake package
(`noGrammarsDirectory`). Packages register before config, and the grammar
table puts config's declarations over every package's by name
(`Registry.grammarTable`), so config overrides a package's grammar by
name, and the one job registers each name once, from the winning owner.

## Owners

A package's registrations belong to the owner named after it
(`Package.owner`). The registry replaces an owner's entries as a set
(`Editor/Config/Registry.lean`), and an install replaces the entries of
`config` alone (`Editor/Config/Reload.lean`), so a reload never replaces a
package's registrations and cancels none of its jobs. Lookups find the
latest entry of a name, and an install puts config's entries after every
other owner's, so config's command, binding, mode, ex name, theme, segment,
source, style, display, at-point source or menu of a package's name is used
in the package's place until a reload drops it.

## What a package's `setup` means

A package's `setup` is run by the handler that collects config's
(`Config.Registrations.ofSetup`), so it is all-or-nothing and the same
things are refused: a name registered twice, a mode that cannot be meant,
keys bound twice. What it collected is then one of three kinds.

- **Owned.** Registered for the package's owner, as an install registers
  config's for `config` (`Config.Registry.replaceOwned`): commands, plain,
  given their call and over a store; jobs; key bindings and prefix names;
  modes; ex names; faces; themes; segments; languages; completion sources, styles and displays; at-point sources
  and their uses; and menus. Its stores are cells of its owner
  (`Config.Cells.install`), made when the host starts and never replaced,
  so a package's command over its store finds its cell
  (`Config.State.command?`).
- **A default.** `useStyleFor category name` is the package's style for the
  category (`Config.Registry.styleDefaults`), which sits between config's
  two choices: config's `useStyleFor` overrides it and its `useStyle` does
  not reach it. Of two packages' defaults for one category the later
  package's is used.
- **Config's alone, refused in a package** (`Registrations.configOnly`):
  `useTheme`, `modeLine`, `framePadding`, `keyHintDelay`, `layout`, `tabBar`,
  `titleBar`, `processEnvironment`, `autoReload`, `workspace`,
  `workspaceLister`, `projectLister`, `displayRule`, `shellTimeLimit`,
  `syntaxRefreshDelay`, `leaderKey`, `localLeaderKey`, `useStyle`,
  `useDisplay` and `useDisplayFor`. They are what an install
  sets for config and nothing holds by owner, so a package that set one
  would have it dropped by the first reload. The message names the package
  and the setting (`Package.setsConfigOnly`).

## What is refused

A package is refused, and registers nothing, when

- its name is empty (`Package.nameless`), or is `config` or `compiled`
  (`Package.reservedName`): a package named `config` would lose its entries
  at the first reload;
- its name is that of a package registered before it
  (`Package.namedTwice`): the second would replace the first's entries;
- its `setup` throws, or what it registered cannot be meant
  (`Registrations.problem?`);
- its `setup` sets what only config may choose.

A package that is refused is skipped, and the others register:
`ofPackages` hands back each refusal's message, which names the package
(`Package.refused`), for the host to log. Across packages nothing is
refused: of two packages that register one name, the later is the one
found, as config's is found before a package's. Whether two bindings are
one sequence under a scheme's leaders (`Registrations.problemUnder?`) is
not asked of a package: it needs a scheme, and a package's keys are bound
under whichever scheme the host runs.
-/

namespace Editor

namespace Package

/-- The owner of what `package` registers: the one named after it. -/
def owner (package : Package) : Config.Owner :=
  { name := package.name }

/-- What the package called `name` is refused with, for `reason`. -/
def refused (name reason : String) : String :=
  s!"the package `{name}` is refused: {reason}"

/-- What a package with no name is refused with. -/
def nameless : String :=
  "a package with no name is refused: its name names the owner of what it registers"

/-- What a package called `name`, a name another owner has, is refused
with. -/
def reservedName (name : String) : String :=
  refused name s!"the name `{name}` is reserved"

/-- What a package called `name` is refused with when a package of that
name is registered before it. -/
def namedTwice (name : String) : String :=
  refused name "a package of that name is registered before it"

/-- Why a package whose `setup` sets `setting`, named as its setup
operation, is refused. -/
def setsConfigOnly (setting : String) : String :=
  s!"it sets `{setting}`, which only config may choose"

/-- Why a package whose grammar `grammar`'s path `path` is absolute, or
climbs out of its grammars directory, is refused. -/
def leavesGrammars (grammar : String) (path : System.FilePath) : String :=
  s!"its grammar `{grammar}`'s path `{path}` leaves its grammars directory"

/-- Why a package that declares grammars is refused when no grammars
directory of its Lake package is staged beside the editor, or it is tagged
with no Lake package. -/
def noGrammarsDirectory : String :=
  "it declares grammars, and no grammars directory of its Lake package is staged beside this editor: a Lake package that ships grammars carries the keyword `editor-grammars`"

end Package

namespace Config

/-- The settings `collected` holds that only config may choose, each named
as the setup operation that sets it ("What a package's `setup` means", in
the module docs). -/
def Registrations.configOnly (collected : Registrations) : List String :=
  let listers (ofProject : Bool) : Bool :=
    collected.workspaceListers.any fun declared =>
      match declared.scope with
      | .root _ => !ofProject
      | .project _ => ofProject
  [(!collected.namedThemes.isEmpty, "useTheme"), (!collected.modeLines.isEmpty, "modeLine"),
        (!collected.framePaddings.isEmpty, "framePadding"),
        (!collected.keyHintDelays.isEmpty, "keyHintDelay"), (!collected.layouts.isEmpty, "layout"),
        (!collected.tabBars.isEmpty, "tabBar"), (!collected.titleBars.isEmpty, "titleBar"),
        (!collected.environments.isEmpty, "processEnvironment"),
        (!collected.autoReload.isEmpty, "autoReload"),
        (!collected.workspaceRoots.isEmpty, "workspace"), (listers false, "workspaceLister"),
        (listers true, "projectLister"), (!collected.displayRules.isEmpty, "displayRule"),
        (!collected.shellTimeLimits.isEmpty, "shellTimeLimit"),
        (!collected.syntaxRefreshDelays.isEmpty, "syntaxRefreshDelay"),
        (!collected.leaders.isEmpty, "leaderKey"),
        (!collected.localLeaders.isEmpty, "localLeaderKey"),
        (collected.styleChoices.any (·.1.isNone), "useStyle"),
        (collected.displayChoices.any (·.1.isNone), "useDisplay"),
        (collected.displayChoices.any (·.1.isSome), "useDisplayFor")].filterMap
    fun (set, name) => if set then some name else none

/-- The style defaults `collected` holds: each `useStyleFor`, a category and
a style's name, in order. -/
def Registrations.styleDefaults (collected : Registrations) : Array (String × String) :=
  collected.styleChoices.filterMap fun (category, name) => category.map (·, name)

end Config

namespace Package

/-- What is wrong with `package`'s name by itself, if anything: it is empty
(`nameless`), or another owner's (`reservedName`). -/
def nameProblem? (package : Package) : Option String :=
  if package.name.isEmpty then some nameless
  else
    if package.owner == .config || package.owner == .compiled then some (reservedName package.name)
    else none

/-- `package`'s grammars resolved against `directory?`, the directory its
Lake package's grammars directory is staged in ("A package's grammars", in
the module docs), or why the package is refused: no directory, a path that
leaves it, or a problem of a resolved declaration. -/
def grammarsUnder (package : Package) (directory? : Option System.FilePath) :
    Except String (Array Language.Grammar) := do
  if package.grammars.isEmpty then
    return #[]
  let some directory := directory? | throw noGrammarsDirectory
  package.grammars.mapM fun grammar => do
    match grammar.under directory with
    | .error path =>
      throw (leavesGrammars grammar.name path)
    | .ok resolved =>
      if let some problem := resolved.problem? then
        throw problem
      return resolved

/-- What `package`'s `setup` registers, with its grammars resolved against
`directory?` (`grammarsUnder`), or the message `package` is refused with
("What is refused", in the module docs): for its name, for what its `setup`
threw or what is wrong with what it registered, for a setting only config
may choose, or for its grammars. The message names the package. -/
def collected (package : Package) (directory? : Option System.FilePath := none) :
    Except String Config.Registrations := do
  if let some problem := package.nameProblem? then
    throw problem
  match Config.Registrations.ofSetup package.setup with
  | .error reason =>
    throw (refused package.name reason)
  | .ok collected =>
    if let some setting := collected.configOnly.head? then
      throw (refused package.name (setsConfigOnly setting))
    match package.grammarsUnder directory? with
    | .error reason =>
      throw (refused package.name reason)
    | .ok grammars =>
      let collected := { collected with grammars := collected.grammars ++ grammars }
      if let some problem := collected.problem? then
        throw (refused package.name problem)
      return collected

/-- What `package` registers, as a host registers it, its grammars resolved
against `directory?`: what its `setup` collects, or nothing when the package
is refused (`collected`). A test reads a package's parts through it. -/
def registered (package : Package) (directory? : Option System.FilePath := none) :
    Config.Registrations :=
  (package.collected directory?).toOption.getD {}

/-- The directory `package`'s Lake package's grammars directory is staged
in, from `directories`, each a Lake package's name and its directory; none
when the package is tagged with no Lake package or the table names none
for it. -/
def grammarsDirectory? (package : Package) (directories : List (String × System.FilePath)) :
    Option System.FilePath := do
  let lake ← package.lakePackage
  return (← directories.find? (·.1 == lake)).2

end Package

namespace Config.State

variable {β σ : Type}

/-- `state` with `package` registered: its owned registrations for its owner
(`Registry.replaceOwned`), its grammars among them, resolved against the
directory `directories` names for its Lake package; its style defaults after
the ones there are, the cells of its stores, and its name among the packages
registered. Or the message it is refused with, when its name is one already
registered (`Package.namedTwice`) or the package is refused by itself
(`Package.collected`); `state` is then unchanged. -/
def register (state : State β σ) (package : Package)
    (directories : List (String × System.FilePath) := []) : Except String (State β σ) := do
  if let some problem := package.nameProblem? then
    throw problem
  if state.packages.contains package.name then
    throw (Package.namedTwice package.name)
  let collected ← package.collected (package.grammarsDirectory? directories)
  let registry := state.registry.replaceOwned package.owner collected
  return { state with
      packages := state.packages.push package.name
      registry :=
        { registry with styleDefaults := registry.styleDefaults ++ collected.styleDefaults }
      cells := (state.cells.install package.owner collected.stores).1
      cellsRevision := state.cellsRevision + 1 }

/-- The config state a host handed `packages` starts from: each registered
in the array's order (`register`), from nothing, before any config, its
grammars resolved against the directory `grammarDirectories` names for its
Lake package (each a Lake package's name and the directory its grammars
directory is staged in, `ModuleLookup.grammarDirectories`); and the message
of each package that was refused, in order. A refused package is skipped and
the rest register. -/
def ofPackages (packages : Array Package) (grammarDirectories : List (String × System.FilePath) := [])
    : State β σ × Array String :=
  packages.foldl
    (fun (state, refused) package =>
      match state.register package grammarDirectories with
      | .ok state => (state, refused)
      | .error message => (state, refused.push message))
    ({}, #[])

end Config.State

end Editor
