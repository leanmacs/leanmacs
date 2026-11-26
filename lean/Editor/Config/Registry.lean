import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Config.Owner
import Editor.Ex.Line
import Editor.InputScheme
import Editor.Menu
import Editor.Mode
import Editor.Setup
import Editor.State

/-!
# The registry, and what a `setup` registers

The registry is the editor's table of commands and of jobs. Each entry has an
*owner* (`Editor/Config/Owner.lean`), and an owner's entries are replaced as
a set, never added to: installing a reloaded config is `replace` for the
owner `config`, so a command the new config no longer registers is gone, and
one it registers again is there once. Every other owner is a package's
("Packages", below), whose entries a host registers once, when it starts.

A registered command is a value: the `EditorM` program `setup` handed over
(`Editor/Setup.lean`). Running it is running that program against the
editor's port. Nothing looks a command up in an environment.

A registered job is a value too: a function from the arguments the job is
started with to a `Work`, the job with the handler that makes the command
its result is taken to the editor with. A job registered without arguments
(`job`) is that function ignoring them. The job entries
are held apart from the command entries, by owner, and replaced as a set the
same way (`replaceJobs`). A job is not a command and is not counted as one.
Registering a job starts nothing: the runtime that owns the job table starts
it (`Editor/Job/Jobs.lean`).

The faces a config sets are held the same way: definitions
(`Editor/Face.lean`), each with its owner, apart from the commands and the
jobs, and replaced as a set (`replaceFaces`). `Registry.definitions` is
every owner's, oldest entry first, which is the order they are appended to
a theme in: a later definition of a name is over an earlier one.

`Registrations` is what one run of a `setup` asks for, collected by a pure
handler of the setup port and then checked. `Registrations.ofSetup` is the
whole of it: the registrations, or the message the `setup` is refused with.
A `setup` is refused when it declares a store name twice, keeps a store
across a restart twice, registers a command name twice or a job name twice, sets a face twice, defines a theme
twice or names one twice, binds a key sequence twice or binds no keys,
binds an ex name twice, defines a completion source twice, or registers a
command over a store it does not declare
(`Registrations.problem?`). So one owner's entries have different names, and
the number of commands a config registers is the number of names it can be
run by. Two owners may still register one name: a lookup then finds the
later entry.

## Key bindings

A key binding is a key sequence and a command's name (`KeyBinding`), held by
owner like a command and replaced as a set (`replaceBindings`). The registry
holds no scheme's binding type: `Registry.keymap` makes the keymap for a
scheme by asking the scheme what a key bound to a command name is
(`InputScheme.command`). The entries are bound oldest first, so of two
owners that bind one sequence the later owner's binding is the keymap's, as
`Keymap.ofList` has it. The name is not looked up here: a binding to a name
nobody registered is kept, and the name is looked up when the keys are
typed.

**A binding's keys are held as written** (`Key.Stroke`), `<leader>` and
`<localleader>` in place, and expanded when `keymap` makes the keymap,
against the leaders in force (`Registry.leaders`): the leader and the
localleader the installed config set (`leader`, `localLeader`, which an
install sets, `none` when config set none), or the scheme's
(`InputScheme.leaders`). The registry's leaders change only at an install,
so this is the same as expanding at the install, which could not: an
install knows no scheme, and a package's bindings are made before any config.
So the order of a `setup`'s calls does not matter, and a reload with a new
leader moves every binding written with it, and every mode's suffix
(`modeKeymaps`, `activeMaps`).

**What a binding is bound to** under the scheme:

- with `states`, what the scheme binds a key that holds only in those of
  its states to (`InputScheme.stateCommand`), under a leader or not;
- otherwise, when its expanded keys begin with the leader or the
  localleader in force, whichever is not empty, what the scheme binds a
  mode's key to (`InputScheme.modeCommand`), which under the Vim scheme
  does not hold where typing is text. The rule reads the expanded keys,
  so a binding written out as `SPC x` under the `SPC` leader is one too;
- otherwise, what it binds a key bound to a command name to
  (`InputScheme.command`).

**A binding may hold in one prompt category alone** (`KeyBinding.category`,
`bindKey … (category := some "<category>")`). Such a binding is left out of
the global keymap (`keymap`) and held in its category's keymap
(`categoryKeymap`), bound by the same rules, oldest first, so config's
binding of a sequence is over a package's. `activeMaps` puts the open
prompt's category's keymap first among the active keymaps of the prompt's
minibuffer view, ahead of its modes' and the global one. A minor mode could
not carry such a key: under the Vim scheme a mode's key does not hold where
typing is text, and a plain command binding does.

**Two bindings of one sequence are refused**, whatever states each names:
`keymap` holds a sequence once, so the later would hide the earlier in
every state. `Registrations.problem?` compares bindings' keys as written,
which finds what is bound twice under every scheme, so `<leader> f` bound
twice is refused. `Registrations.problemUnder?` compares them as they expand against
the leaders in force under the scheme the config is built for (the ones
config set, else the scheme's), so `<leader> f` with `SPC f` under the
`SPC` leader is bound twice too, and the message names both ways the keys
were written (`keysBoundTwice`). `Config.build` asks it after `problem?`.
Both compare bindings within one category: a sequence may be bound
globally and in a category, or in two categories, and twice in one
category is refused naming it (`keysWrittenTwiceIn`, `keysBoundTwiceIn`).

**The key hints read two labels.** A binding's description (`desc`,
`bindKey … (desc := …)`) rides on its `KeyBinding`, so `keymap` puts it on
the keymap's entry (`Keymap.descriptions`) and an install replaces it with
the binding. A prefix has no entry, so its name is a table of its own
(`PrefixName`, held by owner as `prefixNames` and replaced as a set by
`replacePrefixNames`), its keys as written. `prefixName?` expands them
against the leaders in force when it is asked, as `keymap` does a
binding's, so a reload with a new leader moves the names with the
bindings; of two owners' names for one prefix, the later owner's is found.
A prefix named twice is refused as a binding is: as written by `problem?`
(`prefixNamedTwice`), and as expanded under the scheme by `problemUnder?`
(`prefixNamedTwiceAs`).

**The menu bar shows a command's key from these bindings**
(`keyEquivalent?`): of the sequences the bindings, as one keymap, bind to
the command's name, the one bound last that is a single chord of one
character with the system key held, as a menu's key equivalent must be (a
key equivalent with no Command would take a plain key from typing, and a
named key has none). So config's binding is shown over a package's, a
sequence config binds to another command shows for that one, and a
command bound only to a longer sequence, a named key or a chord without
the system key shows none. A chord one of the menu's system items already
shows (`s-q` Quit, `s-h` Hide, `M-s-h` Hide Others) is skipped: AppKit
matches the system item first, so the command would never run by it, and
the command shows its next chord, or none. Mode-local bindings, a prompt
category's bindings, an input scheme's own keys and a binding written with
a placeholder are not looked at: the menu bar is the application's, and a sequence under the leader is
never a key equivalent.

## Modes

A mode (`Editor/Mode.lean`) is held by owner like a command, in a
`ModeEntry`, and replaced as a set (`replaceModes`): the owner is on the
entry, never on the mode, so `setup` cannot choose it. The latest entry of a
name is the one found (`mode?`), so config's mode of a package's mode's name
is used in its place until a reload drops it.

- **A mode's lineage** (`lineage`) is the mode, then its parent, and so
  on, nearest first, stopping at a name no mode is registered under and at
  a mode already in it, so a cycle ends.
- **The keymaps a mode contributes** for a scheme (`modeKeymaps`) are its
  lineage's, nearest first, each mode's tuned keymap then its roles and
  suffixes (`Mode.keymaps`), the suffixes under the localleader in force
  (`leaders`): a derived mode's own role wins, and a role it does not fill
  falls to the nearest parent that fills it.
- **The active keymaps of a view** (`activeMaps`) are its buffer's minor
  modes', the one added last first, then its major mode's, then the global
  keymap (`keymap`). A name no mode is registered under contributes
  nothing, and a view with no window has the global keymap alone. The host
  makes them for each key, so a reload's modes hold from the next key.
- **Setting a buffer's major mode** is a command's request
  (`ViewId.setMajorMode`, `Editor/Api.lean`), which the loop that runs the
  command answers (`Editor/Command/Dispatch.lean`). What the loop is told
  of the registry for it is `registered`: for a name a mode is registered
  under, the modes whose on-enter actions run when that mode becomes a
  buffer's major mode, which are its lineage, root first, as Emacs's
  derived modes run their parent's body first. A name no mode is
  registered under is refused there (`ModeRefusal.noSuchMode`). Adding a
  minor mode runs no action.

## Ex bindings

An ex name is bound to a command's name (`Ex.Binding`,
`Editor/Ex/Line.lean`), held by owner in an `ExEntry` and replaced as a set
(`replaceEx`), as a key binding is. `ex?` finds the latest entry of a name,
so config's binding of an ex name a package binds is the one a line
runs while config binds it, and the package's runs again once a reload
drops it. The command's name is not looked up here: it is looked up when
the line is run. An ex binding is not a command and is not counted as one.

Motions, operators and text objects will be registered the same way, as
vocabulary: entries by owner, replaced as a set, the latest of a name
winning. No table of them is here, since no type for their entries exists
yet.

## Themes

A theme (`NamedTheme`, `Editor/Face.lean`) is held by owner like a mode, in
a `ThemeEntry`, and replaced as a set (`replaceThemes`). The latest entry of
a name is the one found (`theme?`), so config's theme of a package's theme's
name is used in its place until a reload drops it. The `themes` package
registers the theme `default` (`Themes.defaultTheme`,
`packages/themes/Themes/Compiled.lean`) and the `shipped-themes` package, outside
the core, the palettes that ship (`ShippedThemes.themes`,
`packages/shipped-themes/ShippedThemes.lean`); `setup`
registers more with `defineTheme` (`Editor/Setup.lean`). `themeNames` lists each name once, in the order it
was first registered, and is what the loop is told for the command that
loads a theme (`registered`). Which theme is in force is not the registry's
to say: it is the reload reducer's state (`Editor/Config/Reload.lean`).

A `setup` that defines a theme name twice, or names the theme in force
twice (`useTheme`), is refused (`Registrations.problem?`). Naming a theme
nobody registered is not refused here: the name is looked up at install.

## Segments

A segment of the mode line (`Segment`, `Editor/ModeLine.lean`) is held by
owner like a theme, in a `SegmentEntry`, and replaced as a set
(`replaceSegments`). The latest entry of a name is the one found
(`segment?`), so config's segment of a shipped segment's name is drawn in
its place until a reload drops it. The `mode-line` package registers the
shipped segments (`ModeLine.shipped`; the default package `mode-line`, `packages/mode-line/`);
`setup` registers more with `defineSegment` (`Editor/Setup.lean`).
`resolve` turns a listing (`ModeLine.Order`) into the mode line and the
names nobody registered. Which listing is in force is not the registry's
to say: it is the reload reducer's state (`Config.State.modeLine`), and the
host resolves it for each step (`Headless.keys`).

A `setup` that defines a segment name twice, or lists the mode line twice
(`modeLine`), is refused. Listing a segment nobody registered is not
refused here: it is left out at install, and the report names it.

## Languages

A language (`Editor/Language.lean`) is held by owner like a theme, in a
`LanguageEntry`, and replaced as a set (`replaceLanguages`). The
`languages` package registers the languages that ship (`Language.shipped`;
the default package `languages`, `packages/languages/`); `setup` registers more with
`defineLanguage` (`Editor/Setup.lean`). The table a path's language is
chosen from (`languageTable`) is each owner's entries over the earlier
owners' (`Language.over`): config's first, in the order it defined them,
then the packages' it did not replace by name. So config's entry of a
shipped name is used in that one's place until a reload drops it, and the
loop is told the table (`registered`).

A `setup` that defines a language name twice, or a language with a pattern
no file name can be meant by (`Language.problems`), is refused.

## Sources

A completion source (`Completion.Source`, `Editor/Completion.lean`) is held
by owner like a theme, in a `SourceEntry`, and replaced as a set
(`replaceSources`). The latest entry of a name is the one found (`source?`),
so config's source of a package's source's name is used in its place until a
reload drops it. Packages register the shipped sources, each the package of
the feature that lists it; `setup` registers more with
`defineSource` (`Editor/Setup.lean`). The loop is told the lookup
(`registered`, `Loop.Registered.sources`), and runs the source a prompt
names inside the asking command (`ControlRequest.askSource`,
`Editor/Command/Dispatch.lean`).

The sources of a category (`sourcesIn`) are the names whose latest entry
is of it, each once, in the order the name was first registered: packages'
entries come first, so config's source of a shipped name keeps the
shipped one's place and answers in its stead, and config's of a new name
come after the packages', in config's order. The loop is told them
(`Loop.Registered.categorySources`) for a prompt that asks for a category
(`RegistryRequest.categorySources`).

A `setup` that defines a source name twice is refused
(`Registrations.sourceTwice`).

## Styles

A completion style (`Completion.Style`, `Editor/Completion/Style.lean`) is
held by owner like a source, in a `StyleEntry`, and replaced as a set
(`replaceStyles`). The latest entry of a name is the one found (`style?`),
so config's style of a shipped style's name is used in its place until a
reload drops it. The default package `completion` registers the shipped
styles, `fuzzy`, `orderless` and `path`
(`packages/completion/Completion/Compiled.lean`); `setup` registers more
with `defineStyle` (`Editor/Setup.lean`).

Which style a prompt is matched with is config's choice, by category, with a
default for the rest (`useStyleFor`, `useStyle`): the choices are config's
alone, set by each install (`styleChoices`), as its project commands are.
A package may give a category a style of its own, with `useStyleFor`
(`styleDefaults`, as Emacs's `completion-category-defaults`), set when the
host starts and never by an install: it sits between config's two choices,
so config's `useStyleFor` overrides it and its `useStyle` does not reach
it, and of two packages' defaults for one category the later package's is
used. `styleEntry` resolves them to the one style entry a category is
matched with: the entry of the style chosen for it when one is registered
under that name, else a package's default's for it, else the chosen
default's, else the style registered under the name of the style
registered first (config's, when it registers one of that name), else the
core's own style (`Completion.Style.unregistered`), as the owner
`compiled`'s, for a registry where no style is. A chosen name
no style is registered under is reported at install (`unknownStyles`,
`Report.unknownStyles`, `Editor/Config/Reload.lean`). `matching` hands the
loop both the style and who registered it
(`Completion.Matching.ownerFor`), read from that one entry, so the two
cannot disagree. A match job that runs a style is that owner's
(`Editor/Loop.lean`, "Prompts"), so an install that cancels config's jobs
cancels a match of config's style.

A `setup` that defines a style name twice is refused
(`Registrations.styleTwice`), and so is one that chooses the style of one
category, or the default, twice (`Registrations.styleChosenTwice`).

## Displays

A completion display (`Completion.Display`, `Editor/Completion/Display.lean`)
is held by owner like a style, in a `DisplayEntry`, and replaced as a set
(`replaceDisplays`). The latest entry of a name is the one found
(`display?`), so config's display of a shipped display's name is used in
its place until a reload drops it: that is how config sets the rows the
minibuffer's list shows, with `defineDisplay (Completion.Displays.minibuffer
(rows := n))`. The default package `completion` registers the shipped
display, `minibuffer` (`packages/completion/Completion/Compiled.lean`);
`setup` registers more with `defineDisplay` (`Editor/Setup.lean`).

Which display a prompt is shown with is config's choice, by category, with
a default for the rest (`useDisplayFor`, `useDisplay`): the choices are
config's alone, set by each install (`displayChoices`). `displayEntry`
resolves them as `styleEntry` does: the entry of the display chosen for the
category when one is registered under that name, else the chosen
default's, else the display registered under the name of the display
registered first, else the core's own display
(`Completion.Display.unregistered`), as the owner `compiled`'s, for a
registry where none is. A chosen name no
display is registered under is reported at install (`unknownDisplays`,
`Report.unknownDisplays`, `Editor/Config/Reload.lean`). `displaying` hands
the loop the result. A display runs only inside the publish and is looked
up for every step, so no code of an old config runs after an install, and
no owner is needed: unlike a style's match job, nothing of a display
outlives the step.

A `setup` that defines a display name twice is refused
(`Registrations.displayTwice`), and so is one that chooses the display of
one category, or the default, twice (`Registrations.displayChosenTwice`).

## At-point sources

An at-point source (`Completion.AtPoint`, `Editor/Completion/AtPoint.lean`)
is held by owner like a display, in an `AtPointEntry`, and replaced as a set
(`replaceAtPoints`); the latest entry of a name is the one found
(`atPoint?`), so config tunes a shipped one by defining it again under its
name. Which a buffer asks is its chain (`atPointNames`): each of its minor
modes, the one added last first, and then its major mode, each mode with its
lineage, nearest first; for each mode, config's uses of it (`useAtPointIn`,
`Editor/Setup.lean`) in setup order, then the packages', then the mode's
own list (`Mode.atPoint`); and last the uses for every buffer (`useAtPoint`),
config's then the packages'. Each name is kept once, at its first place.
Uses are held by owner too, in an `AtPointUse` (`replaceAtPointUses`). The
use of the shipped `words` for every buffer is the default package
`at-point`'s (`packages/at-point/AtPoint/Compiled.lean`), so no core code
names it. A name in
a chain no at-point source is registered under is reported at install
(`unknownAtPoints`, `Report.unknownAtPoints`), and never asked.

A `setup` that defines an at-point source name twice is refused
(`Registrations.atPointTwice`).

## Menus

A menu of the menu bar (`Submenu`, `Editor/Menu.lean`) is held by owner
like a theme, in a `MenuEntry`, and replaced as a set (`replaceMenus`);
`setup` registers one with `defineMenu` (`Editor/Setup.lean`). The menu bar
(`menuBar?`) is each title once, at the place it was first registered, as
its latest entry: a later owner's menu of a title replaces the earlier
owner's where that one is, until it is dropped, and a menu of a new title
comes after the others. So config changes one menu without restating the
bar. Each command item's key is filled from the key bindings (`menuOf`,
`keyEquivalent?`; "Key bindings", above). A registry no menu is registered
in has no menu bar (`none`), and a host then publishes none.

A `setup` that defines a menu title twice is refused
(`Registrations.menuTwice`).

## Packages

A package (`Editor/Package.lean`) is a name and a `setup`, the program
config's is: how a feature registers. A host is handed an array of
packages and registers them when it starts, before any config
(`Config.State.ofPackages`, `Editor/Config/Packages.lean`), and it
registers nothing else.

- **Each package is an owner**, named after it (`Package.owner`): its
  commands, jobs, key bindings, prefix names, modes, ex bindings, faces,
  themes, segments, languages, sources, styles,
  displays, at-point sources and their uses and menus are registered for
  that owner (`replaceOwned`), and its stores are that owner's cells.
- **The order is the array's.** Each package's entries come after those of
  the packages before it, and `find?` and the other lookups return the
  latest entry of a name, so of two packages that register one name the
  later is the one found. The names commands are registered under
  (`names`), the packages' first in that order, are what the command
  prompt lists (`registered`, `packages/execute-command/ExecuteCommand.lean`).
- **Config comes after every package.** An install is `replaceOwned` for
  the owner `config`, which puts config's entries after every other
  owner's. So config's command of a name a package's command has is the
  one that runs while config registers it, and config's binding of a
  package's keys is the keymap's, and the package's runs again once a
  reload drops config's. A reload that drops config's command drops it
  from the prompt.
- **A reload leaves every package's registrations in place.** An install
  replaces the entries of `config` alone and cancels the jobs of `config`
  alone, so a package's job runs across a reload. The owner a job is
  started for is the one that registered it.
- **What is refused.** A package's `setup` is refused as config's is
  (`Registrations.problem?`), and also when it sets what only config may
  choose; and a package is refused for a name that is empty, `config`,
  `compiled` or an earlier package's. A refused package registers nothing,
  and the others register (`Editor/Config/Packages.lean`, "What is
  refused").

A command may be given what it was called with (`Action.call`,
`Editor/Command/Call.lean`): the window it acts on, the invocation's
arguments and the keys. `setup` registers one as such with `commandWith`,
in a package or in config; `setup`'s `command` registers a plain command,
which is told nothing of its call.

**The owner `compiled`** (`Owner.compiled`) registers nothing in a host. It
is the owner of what the core falls back to when no package registered it:
the fuzzy style and the minibuffer display of a registry that holds none
(`styleEntry`, `displayEntry`). No package may take its name.
-/

namespace Editor.Config

/-- What a registered command runs. -/
inductive Action where
  /-- A plain command. -/
  | plain (run : EditorM Unit)
  /-- A command over the store called `name`: `step` takes the tree of the
  store's cell to its new tree. -/
  | store (name : String) (step : Value → EditorM Value)
  /-- A command that is given what it was called with: the window it acts
  on, the invocation's arguments and the keys that yielded it. -/
  | call (run : Call → EditorM Unit)

/-- A command as `setup` registers it. -/
structure Registration where
  /-- The command's name. -/
  name : String
  /-- What it runs. -/
  action : Action

/-- An entry of the registry: a registered command and its owner. -/
structure Entry where
  /-- Who registered it. -/
  owner : Owner
  /-- The command. -/
  registration : Registration

/-- A job as `setup` registers it. -/
structure JobRegistration where
  /-- The job's name. -/
  name : String
  /-- The job, given the arguments it is started with, with the handler
  that makes the command its result is taken to the editor with. -/
  work : List Argument → Work
  /-- Whether one running when the process ends is reported as stopped by
  the next start's restore (`workJob … (reported := true)`,
  `Editor/Setup.lean`). -/
  reported : Bool := false
  /-- Whether its owner starts it again after a restart anyway, so one
  running when the process ends is not counted as stopped by the next
  start's restore (`workJob … (restarted := true)`, `Editor/Setup.lean`). -/
  restarted : Bool := false
  /-- For a job registered over an extension point (`Extension.workJob`,
  `Editor/Extension.lean`, "To a job"): the point's key, and what makes the
  job's work from the values registered there. Its `work` then fails at
  once (`overMessage`), and the work is made by `workWith`. -/
  over : Option (Lean.Name × (Array Dynamic → List Argument → Work)) := none

/-- What the `work` of the job called `name`, registered over an extension
point, fails with: it is made, with the point's values, where the job is
started. -/
def JobRegistration.overMessage (name : String) : String :=
  s!"{name}: made over an extension point; it is started through Config.State.work?"

/-- The work of `registration`, started with `arguments`, with `values` the
values registered at each extension point: `over` applied to its point's
values for a job registered over one, and `work` otherwise. -/
def JobRegistration.workWith (registration : JobRegistration) (values : Lean.Name → Array Dynamic)
    (arguments : List Argument) : Work :=
  match registration.over with
  | some (key, work) => work (values key) arguments
  | none => registration.work arguments

/-- A job entry of the registry: a registered job and its owner. -/
structure JobEntry where
  /-- Who registered it. -/
  owner : Owner
  /-- The job. -/
  registration : JobRegistration

/-- A key sequence bound to a command's name. -/
structure KeyBinding where
  /-- The keys, in order, as written: chords, and `<leader>` and
  `<localleader>` in place, expanded when the registry makes its
  keymap. -/
  keys : List Key.Stroke
  /-- The name of the command the keys run, looked up when they are
  typed. -/
  command : String
  /-- The names of the scheme's states the binding holds in; none for a
  binding that holds as the leader rule says ("Key bindings", in the
  module docs). -/
  states : List String := []
  /-- The binding's description for the key hints, if it has one. -/
  desc : Option String := none
  /-- The prompt category whose minibuffer the binding holds in
  (`categoryKeymap`); none for a binding of the global keymap. -/
  category : Option String := none
  deriving DecidableEq, Repr

/-- The binding of the keys `keys`, as chords, to the command called
`command`, in every state: what `bindKeys` makes of them with no states,
description or category. -/
def KeyBinding.ofKeys (keys : List Key) (command : String) : KeyBinding :=
  { keys := keys.map .key, command }

/-- A binding entry of the registry: a key binding and its owner. -/
structure BindingEntry where
  /-- Who bound the keys. -/
  owner : Owner
  /-- The binding. -/
  binding : KeyBinding
  deriving DecidableEq, Repr

/-- A prefix's name for the key hints: a prefix has no binding of its own,
so its name is held apart ("Key bindings", in the module docs). -/
structure PrefixName where
  /-- The prefix's keys, in order, as written: chords, and `<leader>` and
  `<localleader>` in place, expanded when the name is looked up. -/
  keys : List Key.Stroke
  /-- The name. -/
  name : String
  deriving DecidableEq, Repr

/-- A prefix name entry of the registry: a prefix name and its owner. -/
structure PrefixNameEntry where
  /-- Who named the prefix. -/
  owner : Owner
  /-- The prefix name. -/
  prefixName : PrefixName
  deriving DecidableEq, Repr

/-- A mode entry of the registry: a mode and its owner. -/
structure ModeEntry where
  /-- Who registered it. -/
  owner : Owner
  /-- The mode. -/
  mode : Mode

/-- An ex entry of the registry: an ex binding and its owner. -/
structure ExEntry where
  /-- Who bound the ex name. -/
  owner : Owner
  /-- The binding. -/
  binding : Ex.Binding
  deriving DecidableEq, Repr

/-- A theme entry of the registry: a named theme and who registered it. -/
structure ThemeEntry where
  /-- Who registered it. -/
  owner : Owner
  /-- The theme. -/
  named : NamedTheme

/-- A segment entry of the registry: a segment of the mode line and who
registered it. -/
structure SegmentEntry where
  /-- Who registered it. -/
  owner : Owner
  /-- The segment. -/
  segment : Segment

/-- A language entry of the registry: a language and who registered it. -/
structure LanguageEntry where
  /-- Who registered it. -/
  owner : Owner
  /-- The language. -/
  language : Language
  deriving DecidableEq, Repr

/-- A source entry of the registry: a completion source and who registered
it. -/
structure SourceEntry where
  /-- Who registered it. -/
  owner : Owner
  /-- The source. -/
  source : Completion.Source

/-- A style entry of the registry: a completion style and who registered
it. -/
structure StyleEntry where
  /-- Who registered it. -/
  owner : Owner
  /-- The style. -/
  style : Completion.Style

/-- A display entry of the registry: a completion display and who
registered it. -/
structure DisplayEntry where
  /-- Who registered it. -/
  owner : Owner
  /-- The display. -/
  display : Completion.Display

/-- An at-point entry of the registry: an at-point source and who registered
it. -/
structure AtPointEntry where
  /-- Who registered it. -/
  owner : Owner
  /-- The at-point source. -/
  atPoint : Completion.AtPoint

/-- A use of an at-point source: who made it, the mode it is for, or `none`
for every buffer, and the source's name. -/
structure AtPointUse where
  /-- Who made it. -/
  owner : Owner
  /-- The mode whose buffers ask it, or `none` for every buffer. -/
  mode : Option String := none
  /-- The at-point source's name. -/
  source : String
  deriving DecidableEq, Repr

/-- A menu entry of the registry: one menu of the menu bar and who
registered it. -/
structure MenuEntry where
  /-- Who registered it. -/
  owner : Owner
  /-- The menu. -/
  menu : Submenu
  deriving DecidableEq, Repr

/-- An extension entry of the registry: a value registered at an extension
point, the point's key, and who registered it (`Editor/Extension.lean`). -/
structure ExtensionEntry where
  /-- Who registered it. -/
  owner : Owner
  /-- The extension point's key: the name of the type the value was made
  from. -/
  key : Lean.Name
  /-- The value, of the type `key` names. -/
  value : Dynamic

/-- A face entry of the registry: a definition of a face and who made it. -/
structure FaceEntry where
  /-- Who set it. -/
  owner : Owner
  /-- The definition. -/
  definition : FaceDefinition

/-- The editor's table of commands, of jobs, of key bindings, of modes, of
ex bindings, of faces, of themes, of segments and of completion sources,
oldest entry first. -/
structure Registry where
  /-- The command entries. -/
  entries : Array Entry := #[]
  /-- The job entries. A job is not a command: these are apart. -/
  jobs : Array JobEntry := #[]
  /-- The key bindings. -/
  bindings : Array BindingEntry := #[]
  /-- The prefix names, for the key hints. -/
  prefixNames : Array PrefixNameEntry := #[]
  /-- The mode entries. -/
  modes : Array ModeEntry := #[]
  /-- The ex bindings. -/
  ex : Array ExEntry := #[]
  /-- The face entries: the definitions each owner made, apart too. -/
  faces : Array FaceEntry := #[]
  /-- The theme entries. -/
  themes : Array ThemeEntry := #[]
  /-- The segment entries. -/
  segments : Array SegmentEntry := #[]
  /-- The language entries. -/
  languages : Array LanguageEntry := #[]
  /-- The base of a child's environment config chose by name
  (`environmentBase`, `Editor/Setup.lean`); `none` when it chose none, so
  the packages' default holds (`baseName`). Set at every install. -/
  environmentBase : Option String := none
  /-- The packages' defaults of the base's name (`environmentBase` in a
  package), in the order they registered: set when the host starts
  (`Config.State.register`) and never by an install; the latest is the one
  used (`baseName`). -/
  baseDefaults : Array String := #[]
  /-- Whether config turns auto-reload on (`autoReload`,
  `Editor/Setup.lean`): false when it says nothing. -/
  autoReload : Bool := false
  /-- The workspace roots config declares (`workspace`, `Editor/Setup.lean`),
  in the order it declared them. -/
  workspaceRoots : Array Workspace.ConfigRoot := #[]
  /-- The workspace listers config declares (`workspaceLister`,
  `projectLister`, `Editor/Setup.lean`), in the order it declared them:
  set at every install. -/
  workspaceListers : Array Workspace.DeclaredLister := #[]
  /-- How many configs have been installed: the config generation a
  directory's cached workspace was found under (`Editor/Workspace.lean`).
  0 while only packages are registered. -/
  generation : Nat := 0
  /-- Config's display rules, in the order its `setup` made them, less the
  ones whose target the layout it chose lacks (`Editor/Config/Reload.lean`):
  set at every install. -/
  displayRules : Array DisplayRule := #[]
  /-- How long a `:!` or a filter may run, in milliseconds, as config set it
  (`shellTimeLimit`, `Editor/Setup.lean`); `none` when it did not, which
  the shell reads as its default. -/
  shellTimeLimit : Option Nat := none
  /-- How long a text goes unchanged after an edit before it is parsed
  whole again, in milliseconds, as config set it (`syntaxRefreshDelay`,
  `Editor/Setup.lean`); `none` when it did not, which a mode's entry reads
  as its default. -/
  syntaxRefreshDelay : Option Nat := none
  /-- The leader, as chords, as config set it (`leaderKey`,
  `Editor/Setup.lean`); `none` when it did not, which reads as the
  scheme's. -/
  leader : Option (List Key) := none
  /-- The localleader, as strokes over the leader, as config set it
  (`localLeaderKey`, `Editor/Setup.lean`); `none` when it did not, which
  reads as the scheme's. -/
  localLeader : Option (List Key.Stroke) := none
  /-- The completion source entries ("Sources", in the module docs). -/
  sources : Array SourceEntry := #[]
  /-- The completion style entries ("Styles", in the module docs). -/
  styles : Array StyleEntry := #[]
  /-- Config's choices of completion style (`useStyle`, `useStyleFor`,
  `Editor/Setup.lean`), each a category, or `none` for the default, and a
  style's name, in the order it made them: set at every install. -/
  styleChoices : Array (Option String × String) := #[]
  /-- The packages' styles for a category (`useStyleFor` in a package), each
  a category and a style's name, as Emacs's `completion-category-defaults`:
  set when the host starts (`Config.State.register`) and never by an
  install; the latest of a category is the one used ("Styles", in the
  module docs). -/
  styleDefaults : Array (String × String) := #[]
  /-- The completion display entries ("Displays", in the module docs). -/
  displays : Array DisplayEntry := #[]
  /-- Config's choices of completion display (`useDisplay`,
  `useDisplayFor`, `Editor/Setup.lean`), each a category, or `none` for the
  default, and a display's name, in the order it made them: set at every
  install. -/
  displayChoices : Array (Option String × String) := #[]
  /-- The at-point source entries ("At-point sources", in the module
  docs). -/
  atPoints : Array AtPointEntry := #[]
  /-- The uses of at-point sources, by mode or for every buffer ("At-point
  sources", in the module docs). -/
  atPointUses : Array AtPointUse := #[]
  /-- The menu entries ("Menus", in the module docs). -/
  menus : Array MenuEntry := #[]
  /-- The codecs stores are kept across a restart with
  (`Store.keptAcrossRestart`, `Editor/Setup.lean`), each with its owner,
  oldest first. -/
  codecs : Array (Owner × StoreCodec) := #[]
  /-- The values registered at extension points, in registration order
  (`Editor/Extension.lean`). -/
  extensions : Array ExtensionEntry := #[]

namespace Registry

/-- `registry` with every source entry of `owner` removed and `sources`
added as its source entries, in their order. -/
def replaceSources (registry : Registry) (owner : Owner) (sources : Array Completion.Source) :
    Registry :=
  { registry with
    sources :=
      registry.sources.filter (·.owner != owner) ++ sources.map fun source => { owner, source } }

/-- The completion source registered under `name`: the latest entry of that
name. -/
def source? (registry : Registry) (name : String) : Option Completion.Source :=
  (registry.sources.findRev? (·.source.name == name)).map (·.source)

/-- `registry` with every style entry of `owner` removed and `styles` added
as its style entries, in their order. -/
def replaceStyles (registry : Registry) (owner : Owner) (styles : Array Completion.Style) :
    Registry :=
  { registry with
    styles :=
      registry.styles.filter (·.owner != owner) ++ styles.map fun style => { owner, style } }

/-- The completion style registered under `name`: the latest entry of that
name. -/
def style? (registry : Registry) (name : String) : Option Completion.Style :=
  (registry.styles.findRev? (·.style.name == name)).map (·.style)

/-- The style entry a prompt of `category` (`none` for one with no
category) is matched with ("Styles", in the module docs): the latest entry
registered under the name config chose for the category, when one is; else
under the name a package gives the category (`styleDefaults`, the latest
of the category), when one
is; else under the name chosen for the default, when one is; else under
the name of the style registered first, so config's style of that name is
used in its place; else, for a registry where none is, the core's own
style (`Completion.Style.unregistered`), as the owner `compiled`'s. The one
lookup both the style and its owner are read from (`matching`). -/
def styleEntry (registry : Registry) (category : Option String) : StyleEntry :=
  let named (name : String) : Option StyleEntry := registry.styles.findRev? (·.style.name == name)
  let chosen (category : Option String) : Option StyleEntry :=
    (registry.styleChoices.find? (·.1 == category)).bind fun (_, name) => named name
  let defaulted (category : String) : Option StyleEntry :=
    (registry.styleDefaults.findRev? (·.1 == category)).bind fun (_, name) => named name
  ((category.bind fun category => chosen (some category)) <|>
        category.bind defaulted <|>
        chosen none <|> (registry.styles[0]?).bind fun first => named first.style.name).getD
    { owner := .compiled, style := Completion.Style.unregistered }

/-- The styles a prompt is matched with ("Styles", in the module docs), each
with who registered it, both read from the one entry a category resolves
to (`styleEntry`), so a match job runs the style of the owner it is spawned
under (`Editor/Loop.lean`, "Prompts"): the default is the entry's for no
category, and a category's the entry's for it, which is the default's when
config chose nothing for it. -/
def matching (registry : Registry) : Completion.Matching :=
  { default := (registry.styleEntry none).style
    byCategory := fun category => some (registry.styleEntry (some category)).style
    ownerFor := fun category => (registry.styleEntry category).owner }

/-- The names config chose that no style is registered under, in the order
chosen, each once. -/
def unknownStyles (registry : Registry) : Array String :=
  ((registry.styleChoices.map (·.2)).filter fun name =>
      (registry.style? name).isNone).toList.eraseDups.toArray

/-- `registry` with every display entry of `owner` removed and `displays`
added as its display entries, in their order. -/
def replaceDisplays (registry : Registry) (owner : Owner) (displays : Array Completion.Display) :
    Registry :=
  { registry with
    displays :=
      registry.displays.filter (·.owner != owner) ++
        displays.map fun display => { owner, display } }

/-- The completion display registered under `name`: the latest entry of
that name. -/
def display? (registry : Registry) (name : String) : Option Completion.Display :=
  (registry.displays.findRev? (·.display.name == name)).map (·.display)

/-- The display entry a prompt of `category` (`none` for one with no
category) is shown with ("Displays", in the module docs): the latest entry
registered under the name config chose for the category, when one is; else
under the name chosen for the default, when one is; else under the name of
the display registered first, so config's display of that name is used in
its place; else, for a registry where none is, the core's own display
(`Completion.Display.unregistered`), as the owner `compiled`'s.
`styleEntry`'s rule. -/
def displayEntry (registry : Registry) (category : Option String) : DisplayEntry :=
  let named (name : String) : Option DisplayEntry :=
    registry.displays.findRev? (·.display.name == name)
  let chosen (category : Option String) : Option DisplayEntry :=
    (registry.displayChoices.find? (·.1 == category)).bind fun (_, name) => named name
  ((category.bind fun category => chosen (some category)) <|>
        chosen none <|> (registry.displays[0]?).bind fun first => named first.display.name).getD
    { owner := .compiled, display := Completion.Display.unregistered }

/-- The displays a prompt is shown with ("Displays", in the module docs):
the default is the entry's for no category, and a category's the entry's
for it, which is the default's when config chose nothing for it
(`displayEntry`). -/
def displaying (registry : Registry) : Completion.Displaying :=
  { default := (registry.displayEntry none).display
    byCategory := fun category => some (registry.displayEntry (some category)).display }

/-- The names config chose that no display is registered under, in the
order chosen, each once. -/
def unknownDisplays (registry : Registry) : Array String :=
  ((registry.displayChoices.map (·.2)).filter fun name =>
      (registry.display? name).isNone).toList.eraseDups.toArray

/-- `registry` with every at-point entry of `owner` removed and `atPoints`
added as its entries, in their order. -/
def replaceAtPoints (registry : Registry) (owner : Owner) (atPoints : Array Completion.AtPoint) :
    Registry :=
  { registry with
    atPoints :=
      registry.atPoints.filter (·.owner != owner) ++
        atPoints.map fun atPoint => { owner, atPoint } }

/-- The at-point source registered under `name`: the latest entry of that
name. -/
def atPoint? (registry : Registry) (name : String) : Option Completion.AtPoint :=
  (registry.atPoints.findRev? (·.atPoint.name == name)).map (·.atPoint)

/-- `registry` with every use of an at-point source `owner` made removed and
`uses`, each a mode or `none` for every buffer and a source's name, added
as its uses, in their order. -/
def replaceAtPointUses (registry : Registry) (owner : Owner)
    (uses : Array (Option String × String)) : Registry :=
  { registry with
    atPointUses :=
      registry.atPointUses.filter (·.owner != owner) ++
        uses.map fun (mode, source) => { owner, mode, source } }

/-- The names of the completion sources registered in `category`: each name
once, in the order it was first registered, kept only when its latest
entry (`source?`) is of that category. Packages' entries come before
config's, so a config source of a package's name keeps the package's
place, and one of a new name comes after them. -/
def sourcesIn (registry : Registry) (category : String) : Array String :=
  let names := (registry.sources.map (·.source.name)).toList.eraseDups.toArray
  names.filter fun name => (registry.source? name).any (·.category == category)

/-- `registry` with every ex binding of `owner` removed and `bindings` added
as its ex bindings. -/
def replaceEx (registry : Registry) (owner : Owner) (bindings : Array Ex.Binding) : Registry :=
  { registry with
    ex := registry.ex.filter (·.owner != owner) ++ bindings.map fun binding => { owner, binding } }

/-- The ex binding of the ex name `name`: the latest entry of that name. -/
def ex? (registry : Registry) (name : String) : Option Ex.Binding :=
  (registry.ex.findRev? (·.binding.name == name)).map (·.binding)

/-- The ex names that are bound, each once, in the order they were first
bound: a name two owners bind is at the place of its first entry. -/
def exNames (registry : Registry) : Array String :=
  registry.ex.foldl
    (fun names entry =>
      if names.contains entry.binding.name then names else names.push entry.binding.name)
    #[]

/-- `registry` with every entry of `owner` removed and `registrations` added
as its entries. -/
def replace (registry : Registry) (owner : Owner) (registrations : Array Registration) : Registry :=
  { registry with
    entries :=
      registry.entries.filter (·.owner != owner) ++
        registrations.map fun registration => { owner, registration } }

/-- `registry` with every job entry of `owner` removed and `registrations`
added as its job entries. -/
def replaceJobs (registry : Registry) (owner : Owner) (registrations : Array JobRegistration) :
    Registry :=
  { registry with
    jobs :=
      registry.jobs.filter (·.owner != owner) ++
        registrations.map fun registration => { owner, registration } }

/-- `registry` with every face entry of `owner` removed and `definitions`
added as its face entries, in their order. -/
def replaceFaces (registry : Registry) (owner : Owner) (definitions : Array FaceDefinition) :
    Registry :=
  { registry with
    faces :=
      registry.faces.filter (·.owner != owner) ++
        definitions.map fun definition => { owner, definition } }

/-- Every owner's definitions of faces, oldest entry first: what is appended
to a theme, where a later definition of a name is over an earlier one. -/
def definitions (registry : Registry) : Array FaceDefinition :=
  registry.faces.map (·.definition)

/-- `registry` with every theme entry of `owner` removed and `themes` added
as its theme entries, in their order. -/
def replaceThemes (registry : Registry) (owner : Owner) (themes : Array NamedTheme) : Registry :=
  { registry with
    themes :=
      registry.themes.filter (·.owner != owner) ++ themes.map fun named => { owner, named } }

/-- The theme called `name`: the latest entry of that name. -/
def theme? (registry : Registry) (name : String) : Option NamedTheme :=
  (registry.themes.findRev? (·.named.name == name)).map (·.named)

/-- The names themes are registered under, each once, in the order they
were first registered: a name two owners register is at the place of its
first entry. -/
def themeNames (registry : Registry) : Array String :=
  registry.themes.foldl
    (fun names entry =>
      if names.contains entry.named.name then names else names.push entry.named.name)
    #[]

/-- `registry` with every segment entry of `owner` removed and `segments`
added as its segment entries, in their order. -/
def replaceSegments (registry : Registry) (owner : Owner) (segments : Array Segment) : Registry :=
  { registry with
    segments :=
      registry.segments.filter (·.owner != owner) ++
        segments.map fun segment => { owner, segment } }

/-- The segment called `name`: the latest entry of that name. -/
def segment? (registry : Registry) (name : String) : Option Segment :=
  (registry.segments.findRev? (·.segment.name == name)).map (·.segment)

/-- The mode line `order` lists, each name the latest segment of that name
(`segment?`), and the names no segment is registered under, in order, each
once (`ModeLine.resolve`). -/
def resolve (registry : Registry) (order : ModeLine.Order) : ModeLine × Array String :=
  ModeLine.resolve order registry.segment?

/-- `registry` with every codec of `owner` removed and `codecs` added as its
codecs, in their order. -/
def replaceCodecs (registry : Registry) (owner : Owner) (codecs : Array StoreCodec) : Registry :=
  { registry with codecs := registry.codecs.filter (·.1 != owner) ++ codecs.map (owner, ·) }

/-- The codec the store called `name` is kept across a restart with, and its
owner: the latest entry of that name. -/
def codec? (registry : Registry) (name : String) : Option (Owner × StoreCodec) :=
  registry.codecs.findRev? (·.2.name == name)

/-- The job entry `name` starts: the latest one of that name. -/
def findJob? (registry : Registry) (name : String) : Option JobEntry :=
  registry.jobs.findRev? (·.registration.name == name)

/-- Whether the job called `name` is reported as stopped by a restart: the
latest job entry of that name says. -/
def reported (registry : Registry) (name : String) : Bool :=
  (registry.findJob? name).any (·.registration.reported)

/-- Whether the job called `name` is started again by its owner after a
restart anyway, so not counted as stopped by it: the latest job entry of
that name says. -/
def restarted (registry : Registry) (name : String) : Bool :=
  (registry.findJob? name).any (·.registration.restarted)

/-- The entry `name` runs: the latest one of that name. -/
def find? (registry : Registry) (name : String) : Option Entry :=
  registry.entries.findRev? (·.registration.name == name)

/-- The names that run a command, each once, in the order they were first
registered. -/
def names (registry : Registry) : Array String :=
  registry.entries.foldl
    (fun names entry =>
      if names.contains entry.registration.name then names else names.push entry.registration.name)
    #[]

/-- `registry` with every key binding of `owner` removed and `bindings` added
as its bindings. -/
def replaceBindings (registry : Registry) (owner : Owner) (bindings : Array KeyBinding) :
    Registry :=
  { registry with
    bindings :=
      registry.bindings.filter (·.owner != owner) ++
        bindings.map fun binding => { owner, binding } }

/-- The leaders in force under `scheme`: the leader and the localleader the
installed config set, each the scheme's where it set none, with the
localleader's `<leader>` the leader in force. -/
def leaders (registry : Registry) (scheme : InputScheme) : Key.Leaders :=
  scheme.leaders registry.leader registry.localLeader

/-- `registry` with every prefix name of `owner` removed and `names` added as
its prefix names. -/
def replacePrefixNames (registry : Registry) (owner : Owner) (names : Array PrefixName) :
    Registry :=
  { registry with
    prefixNames :=
      registry.prefixNames.filter (·.owner != owner) ++
        names.map fun prefixName => { owner, prefixName } }

/-- The name of the prefix `keys`, as chords, under `scheme`, if one is
named: of the prefix names whose keys expand to `keys` against the leaders
in force, the latest's, so a later owner's name is over an earlier's. -/
def prefixName? (registry : Registry) (scheme : InputScheme) (keys : List Key) : Option String :=
  let leaders := registry.leaders scheme
  (registry.prefixNames.toList.reverse.find? fun entry =>
        (Key.expand leaders entry.prefixName.keys).map Key.chord == keys).map
    (·.prefixName.name)

/-- What `binding` is bound to under `scheme`, with `leaders` in force, and
its expanded keys: in the binding's states when it names any, as a mode's
key when the expanded keys begin with the leader or the localleader, and as
a command otherwise ("Key bindings", in the module docs). -/
def bound (scheme : InputScheme) (leaders : Key.Leaders) (binding : KeyBinding) :
    List Key × scheme.Binding :=
  let keys := Key.expand leaders binding.keys
  let underLeader :=
    [leaders.leader, leaders.localLeader].any fun leader =>
      !leader.isEmpty && leader.isPrefixOf keys
  let command := binding.command
  let bound :=
    if !binding.states.isEmpty then scheme.stateCommand binding.states command
    else if underLeader then scheme.modeCommand command else scheme.command command
  (keys, bound)

/-- The keymap of every owner's bindings of the prompt category `category`
(`none` for the global keymap) for `scheme`, each bound as `bound` says,
oldest first, so of two owners that bind one sequence the later owner's is
the keymap's. A binding's description is on its entry. -/
def keymapOf (registry : Registry) (scheme : InputScheme) (category : Option String) :
    Keymap scheme.Binding :=
  let leaders := registry.leaders scheme
  Keymap.ofDescribed
    ((registry.bindings.toList.filter (·.binding.category == category)).map fun entry =>
      let (keys, bound) := bound scheme leaders entry.binding
      (keys, bound, entry.binding.desc))

/-- The keymap of every owner's bindings for `scheme` that are in no prompt
category: each key sequence, expanded against the leaders in force, bound
to what the scheme says runs the command of its name: in the binding's
states when it names any, as a mode's key when the expanded keys begin
with the leader or the localleader, and as a command otherwise ("Key
bindings", in the module docs). The entries are bound oldest first, so of
two owners that bind one sequence the later owner's is the keymap's. A
binding's description is on its entry. -/
def keymap (registry : Registry) (scheme : InputScheme) : Keymap scheme.Binding :=
  registry.keymapOf scheme none

/-- The keymap of the prompt category `category` for `scheme`: every owner's
bindings given that category, bound as the global keymap's are, oldest
first, so config's binding of a sequence is over a package's ("Key
bindings", in the module docs). -/
def categoryKeymap (registry : Registry) (scheme : InputScheme) (category : String) :
    Keymap scheme.Binding :=
  registry.keymapOf scheme (some category)

/-- The key equivalent the menu bar shows for the command `command`: the
last chord the bindings bind to it alone that is one character with the
system key held and is none of `taken`, the keys the menu's system items
already show ("Key bindings", in the module docs); `none` when no binding
is such a chord. A binding written with a placeholder is not looked at. -/
def keyEquivalent? (registry : Registry) (command : String) (taken : List KeyEquivalent := []) :
    Option KeyEquivalent :=
  let keymap : Keymap String :=
    Keymap.ofList
      ((registry.bindings.toList.filter (·.binding.category.isNone)).filterMap fun entry =>
        (Key.Stroke.keys? entry.binding.keys).map (·, entry.binding.command))
  (keymap.keysFor (· == command)).reverse.findSome? fun
    | [chord] =>
      match chord.logical, chord.modifiers.superKey with
      | .character text, true =>
        match text.toList with
        | [character] =>
          let key : KeyEquivalent := { character, modifiers := chord.modifiers }
          if taken.contains key then none else some key
        | _ => none
      | _, _ => none
    | _ => none

/-- `menu` with each command item's key equivalent the one `registry`'s
bindings give its command (`keyEquivalent?`), never a key one of `menu`'s
system items shows (`Menu.systemKeys`). -/
def menuOf (registry : Registry) (menu : Menu) : Menu :=
  menu.withKeys (registry.keyEquivalent? (taken := menu.systemKeys))

/-- `registry` with every menu entry of `owner` removed and `menus` added as
its menu entries, in their order. -/
def replaceMenus (registry : Registry) (owner : Owner) (menus : Array Submenu) : Registry :=
  { registry with
    menus := registry.menus.filter (·.owner != owner) ++ menus.map fun menu => { owner, menu } }

/-- `registry` with every extension entry of `owner` removed and `values`,
each a key and a value, added as its extension entries, in their order. -/
def replaceExtensions (registry : Registry) (owner : Owner) (values : Array (Lean.Name × Dynamic)) :
    Registry :=
  { registry with
    extensions :=
      registry.extensions.filter (·.owner != owner) ++
        values.map fun (key, value) => { owner, key, value } }

/-- The values registered at the extension point `key`, in registration
order: the owners' in the order they installed, so a package's come before
config's. -/
def extensionsAt (registry : Registry) (key : Lean.Name) : Array Dynamic :=
  (registry.extensions.filter (·.key == key)).map (·.value)

/-- The name of the base of a child's environment: config's choice
(`environmentBase`), else the latest package's default (`baseDefaults`),
else the core's `inherited` (`Process.inheritedName`). -/
def baseName (registry : Registry) : String :=
  registry.environmentBase.getD (registry.baseDefaults.back?.getD Process.inheritedName)

/-- The values config registered at the extension point `key`, in
registration order: the tail of `extensionsAt`'s answer, since config
installs after every package. -/
def configExtensionsAt (registry : Registry) (key : Lean.Name) : Array Dynamic :=
  (registry.extensions.filter fun entry => entry.key == key && entry.owner == .config).map (·.value)

/-- The menu bar ("Menus", in the module docs): `none` when no menu is
registered; otherwise each title once, at the place it was first
registered, as its latest entry, with every command item's key filled from
the bindings (`menuOf`). So a later owner's menu of a title replaces an
earlier owner's where that one is, and one of a new title comes after. -/
def menuBar? (registry : Registry) : Option Menu :=
  if registry.menus.isEmpty then none
  else
    let titles := (registry.menus.map (·.menu.title)).toList.eraseDups.toArray
    let menus :=
      titles.filterMap fun title => (registry.menus.findRev? (·.menu.title == title)).map (·.menu)
    some (registry.menuOf { menus })

/-- `registry` with every mode entry of `owner` removed and `modes` added as
its mode entries. -/
def replaceModes (registry : Registry) (owner : Owner) (modes : Array Mode) : Registry :=
  { registry with
    modes := registry.modes.filter (·.owner != owner) ++ modes.map fun mode => { owner, mode } }

/-- `registry` with every language entry of `owner` removed and
`languages` added as its language entries, in their order. -/
def replaceLanguages (registry : Registry) (owner : Owner) (languages : Array Language) :
    Registry :=
  { registry with
    languages :=
      registry.languages.filter (·.owner != owner) ++
        languages.map fun language => { owner, language } }

/-- The language table, in precedence order (`Language.forPath`): each
owner's entries, in order, over the owners' before it (`Language.over`),
so the latest owner's come first and a name it registers replaces an
earlier owner's entry of that name whole. -/
def languageTable (registry : Registry) : List Language :=
  let owners :=
    registry.languages.foldl
      (fun owners entry => if owners.contains entry.owner then owners else owners.push entry.owner)
      #[]
  owners.foldl
    (fun table owner =>
      Language.over ((registry.languages.filter (·.owner == owner)).map (·.language)).toList table)
    []

/-- The mode called `name`: the latest entry of that name. -/
def mode? (registry : Registry) (name : String) : Option Mode :=
  (registry.modes.findRev? (·.mode.name == name)).map (·.mode)

/-- The lineage of the mode called `name`: that mode, then its parent, and
so on, nearest first. It stops at a name no mode is registered under, and
at a mode already in it, so a cycle ends; it has at most as many modes as
the registry has entries. -/
def lineage (registry : Registry) (name : String) : List Mode :=
  go registry.modes.size name []
where
  /-- The lineage from `name`, with `found` the modes already in it, the
  nearest last, and at most `fuel` more. -/
  go : Nat → String → List Mode → List Mode
    | 0, _, found => found.reverse
    | fuel + 1, name, found =>
      match registry.mode? name with
      | none => found.reverse
      | some mode =>
        if found.any (·.name == name) then found.reverse
        else
          match mode.parent with
          | some parent => go fuel parent (mode :: found)
          | none => (mode :: found).reverse

/-- The keymaps the mode called `name` contributes for `scheme`, in
precedence order: for each mode of its lineage, nearest first, its keymaps
(`Mode.keymaps`), its suffixes under the localleader in force
(`leaders`). None for a name no mode is registered under. -/
def modeKeymaps (registry : Registry) (scheme : InputScheme) (name : String) :
    List (Keymap scheme.Binding) :=
  let leaders := registry.leaders scheme
  (registry.lineage name).flatMap fun mode => mode.keymaps scheme leaders

/-- The active keymaps of `view` in `state` for `scheme`, in precedence
order: for the open prompt's minibuffer view, when the prompt has a
category, that category's keymap (`categoryKeymap`); then the keymaps of
each minor mode of the view's buffer, the one added last first, then its
major mode's, then the global keymap of every owner's key bindings in no
category (`keymap`). A view with no window has the global keymap alone. -/
def activeMaps (registry : Registry) (scheme : InputScheme) (state : EditorState) (view : ViewId) :
    List (Keymap scheme.Binding) :=
  let global := registry.keymap scheme
  match state.target? view with
  | none => [global]
  | some target =>
    let category :=
      match state.prompt with
      | some prompt =>
        if prompt.view == view then
          (prompt.candidates.category.map (registry.categoryKeymap scheme)).toList
        else []
      | none => []
    let minors := target.buffer.minors.toList.flatMap (registry.modeKeymaps scheme)
    let major := (target.buffer.major.map (registry.modeKeymaps scheme)).getD []
    category ++ minors ++ major ++ [global]

/-- The names the uses for `mode` (`none` for every buffer) give: config's
in the order it made them, then the packages'. -/
def usesFor (registry : Registry) (mode : Option String) : Array String :=
  let of (owner : Owner) :=
    (registry.atPointUses.filter fun use => use.owner == owner && use.mode == mode).map (·.source)
  of .config ++
    (registry.atPointUses.filter fun use => use.owner != .config && use.mode == mode).map (·.source)

/-- The chain of at-point sources of a buffer whose major mode is `major`
and whose minor modes are `minors`, the one added last first ("At-point
sources", in the module docs): each minor mode, then the major mode, each
with its lineage nearest first, each mode giving its uses, config's then
the packages', then its own list; then the uses for every buffer. Each
name once, at its first place. -/
def atPointNames (registry : Registry) (major : Option String) (minors : Array String) :
    Array String :=
  let ofMode (name : String) : Array String :=
    (registry.lineage name).toArray.flatMap fun mode =>
      registry.usesFor (some mode.name) ++ mode.atPoint.toArray
  let names := minors.flatMap ofMode ++ (major.map ofMode).getD #[] ++ registry.usesFor none
  names.toList.eraseDups.toArray

/-- The at-point source names a mode's list or a use names that no at-point
source is registered under, in order, each once. -/
def unknownAtPoints (registry : Registry) : Array String :=
  let named :=
    registry.atPointUses.map (·.source) ++ registry.modes.flatMap (·.mode.atPoint.toArray)
  (named.filter fun name => (registry.atPoint? name).isNone).toList.eraseDups.toArray

/-- Who registered each entry, kind by kind: the owners of the commands, of
the jobs, of the key bindings, of the prefix names, of the modes, of the ex
bindings, of the faces, of the themes, of the segments, of the languages,
of the completion sources, styles and
displays, of the at-point sources, of their uses, of the menus, of the
store codecs and of the values at extension points, each in the entries'
order. A registry nothing is registered in has none. -/
def ownersByKind (registry : Registry) : Array (Array Owner) :=
  #[registry.entries.map (·.owner), registry.jobs.map (·.owner), registry.bindings.map (·.owner),
    registry.prefixNames.map (·.owner), registry.modes.map (·.owner), registry.ex.map (·.owner),
    registry.faces.map (·.owner), registry.themes.map (·.owner), registry.segments.map (·.owner),
    registry.languages.map (·.owner), registry.sources.map (·.owner), registry.styles.map (·.owner),
    registry.displays.map (·.owner), registry.atPoints.map (·.owner),
    registry.atPointUses.map (·.owner), registry.menus.map (·.owner), registry.codecs.map (·.1),
    registry.extensions.map (·.owner)]

/-- What the loop is told of the registry for a command's state requests,
its questions to the registry and its control requests
(`Editor/Command/Dispatch.lean`): for a name a mode is registered under,
its lineage, root first, whose on-enter actions run when the mode becomes a
buffer's major mode; whether a job is registered under a name, for a
command to start; and the ex binding of an ex name (`ex?`) and the ex
names that are bound (`exNames`), for the ex line; and the names themes
are registered under (`themeNames`), for the command that loads one; the
names commands are registered under (`names`), each once, for the command
prompt, so a reload that drops config's command drops it from the prompt;
config's workspace roots and the config generation, for the finder;
config's workspace listers, for what lists a workspace's files;
config's display rules, for a command that displays a buffer; config's
shell time limit, for `:!`; the language table (`languageTable`), for a
file's open and a mode's entry; and the
completion source registered under a name (`source?`) and the names of
those registered in a category (`sourcesIn`), for a prompt that asks for
them; and the codec a store is kept across a restart with (`codec?`), with
its owner's name, and whether a job is reported as stopped by a restart
(`reported`), for the session restore. Which command a
name stands for, for a command run inside another,
is not said here: the loop takes it from the lookup it runs an invocation
by (`Loop.Keys.command?`, `Editor/Loop.lean`, "A command run inside
another"). -/
def registered (registry : Registry) : Loop.Registered :=
  { entering := fun name => (registry.mode? name).map fun _ => (registry.lineage name).reverse
    jobs := fun name => (registry.findJob? name).isSome, ex := registry.ex?
    exNames := registry.exNames, themeNames := registry.themeNames
    commandNames := registry.names
    autoReload := registry.autoReload, workspaceRoots := registry.workspaceRoots
    workspaceListers := registry.workspaceListers
    generation := registry.generation, displayRules := registry.displayRules
    shellTimeLimit := registry.shellTimeLimit, syntaxRefreshDelay := registry.syntaxRefreshDelay
    languages := registry.languageTable
    sources := registry.source?, categorySources := registry.sourcesIn
    atPoint := registry.atPoint?, atPointNames := registry.atPointNames
    codec? := fun name => (registry.codec? name).map fun (owner, codec) => (owner.name, codec)
    reported := registry.reported, extensions := registry.extensionsAt
    configExtensions := registry.configExtensionsAt }

end Registry

/-- What one run of a `setup` registers. -/
structure Registrations where
  /-- The commands, in the order they were registered. -/
  commands : Array Registration := #[]
  /-- The stores, in the order they were declared. -/
  stores : Array StoreDeclaration := #[]
  /-- The codecs stores are kept across a restart with, in the order they
  were registered. -/
  codecs : Array StoreCodec := #[]
  /-- The jobs, in the order they were registered. -/
  jobs : Array JobRegistration := #[]
  /-- The key bindings, in the order they were made, their keys as written,
  each key as a chord. -/
  bindings : Array KeyBinding := #[]
  /-- The prefix names (`prefixName`), in the order they were given, their
  keys as written, each key as a chord. -/
  prefixNames : Array PrefixName := #[]
  /-- The leaders `setup` set (`leaderKey`), in order: one at most, in a
  `setup` that is not refused. -/
  leaders : Array (List Key) := #[]
  /-- The localleaders `setup` set (`localLeaderKey`), in order: one at
  most, in a `setup` that is not refused. -/
  localLeaders : Array (List Key.Stroke) := #[]
  /-- The modes, in the order they were defined. -/
  modes : Array Mode := #[]
  /-- The ex bindings, in the order they were made. -/
  ex : Array Ex.Binding := #[]
  /-- The faces, in the order they were set. -/
  faces : Array FaceDefinition := #[]
  /-- The themes, in the order they were defined. -/
  themes : Array NamedTheme := #[]
  /-- The theme names `setup` named as the one in force (`useTheme`), in
order: more than one is refused (`problem?`), so a `setup` that is
accepted names at most one (`theme`). -/
  namedThemes : Array String := #[]
  /-- The segments of the mode line, in the order they were defined. -/
  segments : Array Segment := #[]
  /-- The listings of the mode line `setup` made (`modeLine`), in order:
  more than one is refused, so a `setup` that is accepted makes at most one
  (`modeLine`). -/
  modeLines : Array ModeLine.Order := #[]
  /-- The frame paddings `setup` set (`framePadding`), in points, in order:
  more than one is refused, so a `setup` that is accepted sets at most one
  (`framePadding`). -/
  framePaddings : Array Nat := #[]
  /-- The key hint delays `setup` set (`keyHintDelay`), in order: more than
  one is refused, so a `setup` that is accepted sets at most one
  (`keyHintDelay`). -/
  keyHintDelays : Array Completion.Keys.Delay := #[]
  /-- The layouts `setup` chose (`layout`), in order: more than one is
  refused, so a `setup` that is accepted chooses at most one (`layout`). -/
  layouts : Array Layout := #[]
  /-- When `setup` chose the tab bar to be shown (`tabBar`), in order: more
  than one is refused, so a `setup` that is accepted chooses it once at
  most (`tabBar`). -/
  tabBars : Array TabBar.Shown := #[]
  /-- The title bars `setup` chose (`titleBar`), in order: more than one is
  refused, so a `setup` that is accepted chooses at most one (`titleBar`). -/
  titleBars : Array Window.TitleBar := #[]
  /-- Each base of a child's environment the `setup` chose by name
  (`environmentBase`), in order: one at most, in a `setup` that is not
  refused. -/
  environmentBases : Array String := #[]
  /-- What each `autoReload` of the `setup` said, in order. -/
  autoReload : Array Bool := #[]
  /-- The workspace roots the `setup` declared, in order: a root once at
  most, in a `setup` that is not refused. -/
  workspaceRoots : Array Workspace.ConfigRoot := #[]
  /-- The workspace listers the `setup` declared (`workspaceLister`,
  `projectLister`), in order: one for a root or a project at most, in a
  `setup` that is not refused. -/
  workspaceListers : Array Workspace.DeclaredLister := #[]
  /-- The display rules the `setup` made (`displayRule`), in order. -/
  displayRules : Array DisplayRule := #[]
  /-- The shell time limits `setup` set (`shellTimeLimit`), in order: one at
  most, in a `setup` that is not refused. -/
  shellTimeLimits : Array Nat := #[]
  /-- The syntax refresh delays `setup` set (`syntaxRefreshDelay`), in
  order: one at most, in a `setup` that is not refused. -/
  syntaxRefreshDelays : Array Nat := #[]
  /-- The languages, in the order they were defined. -/
  languages : Array Language := #[]
  /-- The completion sources, in the order they were defined. -/
  sources : Array Completion.Source := #[]
  /-- The completion styles, in the order they were defined. -/
  styles : Array Completion.Style := #[]
  /-- The choices of completion style (`useStyle`, `useStyleFor`), each a
  category, or `none` for the default, and a style's name, in order: a
  category, or the default, once at most in a `setup` that is not
  refused. -/
  styleChoices : Array (Option String × String) := #[]
  /-- The completion displays, in the order they were defined. -/
  displays : Array Completion.Display := #[]
  /-- The choices of completion display (`useDisplay`, `useDisplayFor`),
  each a category, or `none` for the default, and a display's name, in
  order: a category, or the default, once at most in a `setup` that is not
  refused. -/
  displayChoices : Array (Option String × String) := #[]
  /-- The at-point sources, in the order they were defined. -/
  atPoints : Array Completion.AtPoint := #[]
  /-- The uses of at-point sources (`useAtPoint`, `useAtPointIn`), each a
  mode or `none` for every buffer and a source's name, in order. -/
  atPointUses : Array (Option String × String) := #[]
  /-- The menus of the menu bar (`defineMenu`), in the order they were
  defined. -/
  menus : Array Submenu := #[]
  /-- The values registered at extension points (`Extension.add`), each with
  its point's key, in the order they were registered. -/
  extensions : Array (Lean.Name × Dynamic) := #[]
  /-- The packages' settings the `setup` gave (`Extension.setting`), by
  name, in order: a setting once at most, in a `setup` that is not
  refused. -/
  settings : Array String := #[]

namespace Registrations

/-- The theme a `setup` named as the one in force, if it named one. -/
def theme (collected : Registrations) : Option String :=
  collected.namedThemes[0]?

/-- The listing of the mode line a `setup` made, if it made one. -/
def modeLine (collected : Registrations) : Option ModeLine.Order :=
  collected.modeLines[0]?

/-- The frame padding a `setup` set, in points, if it set one. -/
def framePadding (collected : Registrations) : Option Nat :=
  collected.framePaddings[0]?

/-- The key hint delay a `setup` set, if it set one. -/
def keyHintDelay (collected : Registrations) : Option Completion.Keys.Delay :=
  collected.keyHintDelays[0]?

/-- What a `setup` that sets the key hint delay twice is refused with. -/
def keyHintDelayTwice : String :=
  "the key hint delay is set twice"

/-- The layout a `setup` chose, if it chose one. -/
def layout (collected : Registrations) : Option Layout :=
  collected.layouts[0]?

/-- When a `setup` chose the tab bar to be shown, if it chose. -/
def tabBar (collected : Registrations) : Option TabBar.Shown :=
  collected.tabBars[0]?

/-- The title bar a `setup` chose, if it chose one. -/
def titleBar (collected : Registrations) : Option Window.TitleBar :=
  collected.titleBars[0]?

/-- The shell time limit a `setup` set, in milliseconds, if it set one. -/
def shellTimeLimit (collected : Registrations) : Option Nat :=
  collected.shellTimeLimits[0]?

/-- What a `setup` that sets the shell time limit twice is refused with. -/
def shellTimeLimitTwice : String :=
  "the shell time limit is set twice"

/-- The syntax refresh delay a `setup` set, in milliseconds, if it set one. -/
def syntaxRefreshDelay (collected : Registrations) : Option Nat :=
  collected.syntaxRefreshDelays[0]?

/-- What a `setup` that sets the syntax refresh delay twice is refused with. -/
def syntaxRefreshDelayTwice : String :=
  "the syntax refresh delay is set twice"

/-- The leader a `setup` set, as chords, if it set one. -/
def leader (collected : Registrations) : Option (List Key) :=
  collected.leaders[0]?

/-- What a `setup` that sets the leader twice is refused with. -/
def leaderTwice : String :=
  "the leader is set twice"

/-- The localleader a `setup` set, as strokes over the leader, if it set
one. -/
def localLeader (collected : Registrations) : Option (List Key.Stroke) :=
  collected.localLeaders[0]?

/-- What a `setup` that sets the localleader twice is refused with. -/
def localLeaderTwice : String :=
  "the localleader is set twice"

/-- What a `setup` that names the prefix written `keys` twice is refused
with. -/
def prefixNamedTwice (keys : List Key.Stroke) : String :=
  s!"the prefix `{Key.strokeNotations keys}` is named twice"

/-- `strokes` with each key as its chord, and each placeholder as it is. -/
private def chordStrokes (strokes : List Key.Stroke) : List Key.Stroke :=
  strokes.map fun
    | .key pressed => .key pressed.chord
    | placeholder => placeholder

/-- The handler of the setup port that collects: its answer to each request,
and what has been registered after it. -/
def collect : (request : SetupRequest) → Registrations → request.Reply × Registrations
  | .command name run, collected =>
    ((), { collected with commands := collected.commands.push { name, action := .plain run } })
  | .commandWith name run, collected =>
    ((), { collected with commands := collected.commands.push { name, action := .call run } })
  | .store declaration, collected =>
    ((), { collected with stores := collected.stores.push declaration })
  | .storeCommand name store step, collected =>
    ((),
      { collected with commands := collected.commands.push { name, action := .store store step } })
  | .keepAcrossRestart codec, collected =>
    ((), { collected with codecs := collected.codecs.push codec })
  | .job name work reported restarted, collected =>
    ((), { collected with jobs := collected.jobs.push { name, work, reported, restarted } })
  | .bind keys command states desc category, collected =>
    ((),
      { collected with
        bindings :=
          collected.bindings.push { keys := chordStrokes keys, command, states, desc, category } })
  | .prefixName keys name, collected =>
    ((),
      { collected with
        prefixNames := collected.prefixNames.push { keys := chordStrokes keys, name } })
  | .leader keys, collected =>
    ((), { collected with leaders := collected.leaders.push (keys.map Key.chord) })
  | .localLeader keys, collected =>
    ((), { collected with localLeaders := collected.localLeaders.push keys })
  | .mode mode, collected => ((), { collected with modes := collected.modes.push mode })
  | .ex binding, collected => ((), { collected with ex := collected.ex.push binding })
  | .face name attributes, collected =>
    ((), { collected with faces := collected.faces.push { name, face := attributes } })
  | .theme named, collected => ((), { collected with themes := collected.themes.push named })
  | .useTheme name, collected =>
    ((), { collected with namedThemes := collected.namedThemes.push name })
  | .segment segment, collected =>
    ((), { collected with segments := collected.segments.push segment })
  | .modeLine order, collected =>
    ((), { collected with modeLines := collected.modeLines.push order })
  | .framePadding points, collected =>
    ((), { collected with framePaddings := collected.framePaddings.push points })
  | .keyHintDelay delay, collected =>
    ((), { collected with keyHintDelays := collected.keyHintDelays.push delay })
  | .layout chosen, collected => ((), { collected with layouts := collected.layouts.push chosen })
  | .tabBar shown, collected => ((), { collected with tabBars := collected.tabBars.push shown })
  | .titleBar style, collected =>
    ((), { collected with titleBars := collected.titleBars.push style })
  | .environmentBase name, collected =>
    ((), { collected with environmentBases := collected.environmentBases.push name })
  | .autoReload on, collected => ((), { collected with autoReload := collected.autoReload.push on })
  | .workspace root project, collected =>
    ((), { collected with workspaceRoots := collected.workspaceRoots.push { root, project } })
  | .workspaceLister declared, collected =>
    ((), { collected with workspaceListers := collected.workspaceListers.push declared })
  | .displayRule rule, collected =>
    ((), { collected with displayRules := collected.displayRules.push rule })
  | .shellTimeLimit milliseconds, collected =>
    ((), { collected with shellTimeLimits := collected.shellTimeLimits.push milliseconds })
  | .syntaxRefreshDelay milliseconds, collected =>
    ((), { collected with syntaxRefreshDelays := collected.syntaxRefreshDelays.push milliseconds })
  | .language language, collected =>
    ((), { collected with languages := collected.languages.push language })
  | .source source, collected => ((), { collected with sources := collected.sources.push source })
  | .style style, collected => ((), { collected with styles := collected.styles.push style })
  | .useStyle category name, collected =>
    ((), { collected with styleChoices := collected.styleChoices.push (category, name) })
  | .display display, collected =>
    ((), { collected with displays := collected.displays.push display })
  | .useDisplay category name, collected =>
    ((), { collected with displayChoices := collected.displayChoices.push (category, name) })
  | .atPoint atPoint, collected =>
    ((), { collected with atPoints := collected.atPoints.push atPoint })
  | .useAtPoint mode name, collected =>
    ((), { collected with atPointUses := collected.atPointUses.push (mode, name) })
  | .menu menu, collected => ((), { collected with menus := collected.menus.push menu })
  | .extend key value, collected =>
    ((), { collected with extensions := collected.extensions.push (key, value) })
  | .setting name, collected => ((), { collected with settings := collected.settings.push name })
  | .jobOver key name work reported restarted, collected =>
    ((),
      { collected with
        jobs :=
          collected.jobs.push
            { name, work := fun _ _ => throw (JobRegistration.overMessage name), reported, restarted
              over := some (key, work) } })

/-- What a `setup` that gives the package's setting `name` twice is refused
with (`Extension.setting`). -/
def settingTwice (name : String) : String :=
  s!"the setting `{name}` is set twice"

/-- What a `setup` that sets auto-reload twice is refused with. -/
def autoReloadTwice : String :=
  "auto-reload is set twice"

/-- What a `setup` that declares the workspace root `root` twice is refused
with. -/
def workspaceTwice (root : System.FilePath) : String :=
  s!"the workspace root `{root}` is declared twice"

/-- What a `setup` that declares a workspace lister for `scope` twice is
refused with: one root, or one project. -/
def workspaceListerTwice (scope : Workspace.ListerScope) : String :=
  s!"a workspace lister is declared twice for {scope.describe}"

/-- What a `setup` that defines the completion source `name` twice is
refused with. -/
def sourceTwice (name : String) : String :=
  s!"the completion source `{name}` is registered twice"

/-- What a `setup` that defines the completion style `name` twice is refused
with. -/
def styleTwice (name : String) : String :=
  s!"the completion style `{name}` is registered twice"

/-- What a `setup` that chooses the completion style of `category` twice, or
with `none` the default style twice, is refused with. -/
def styleChosenTwice : Option String → String
  | some category => s!"the completion style of `{category}` is chosen twice"
  | none => "the default completion style is chosen twice"

/-- What a `setup` that defines the completion display `name` twice is
refused with. -/
def displayTwice (name : String) : String :=
  s!"the completion display `{name}` is registered twice"

/-- What a `setup` that chooses the completion display of `category` twice,
or with `none` the default display twice, is refused with. -/
def displayChosenTwice : Option String → String
  | some category => s!"the completion display of `{category}` is chosen twice"
  | none => "the default completion display is chosen twice"

/-- What a `setup` that defines the at-point source `name` twice is refused
with. -/
def atPointTwice (name : String) : String :=
  s!"the at-point completion source `{name}` is registered twice"

/-- What a `setup` that defines the menu titled `title` twice is refused
with. -/
def menuTwice (title : String) : String :=
  s!"the menu `{title}` is defined twice"

/-- The first of `items` that an earlier one already is, if any. -/
def repeated? {α : Type} [BEq α] (items : Array α) : Option α := do
  for index in [0:items.size] do
    if let some item := items[index]? then
      if (items.extract 0 index).contains item then
        return item
  none

/-- What a `setup` that binds the keys written `keys` twice in the prompt
category `category` is refused with. -/
def keysWrittenTwiceIn (category : String) (keys : List Key.Stroke) : String :=
  s!"the keys `{Key.strokeNotations keys}` are bound twice in the prompt category `{category}`"

/-- What is wrong with what was collected, if anything: a store declared
twice, a command name or a job name registered twice, a face set twice, a
theme defined twice, a theme named twice (by its first two names), a
segment defined twice, the mode line listed twice, the frame padding set
twice, the layout chosen twice, the tab bar chosen twice, the title bar chosen twice, the leader set twice (`leaderTwice`), the localleader set twice (`localLeaderTwice`), a key sequence bound twice (compared as written, whatever states each binding names; `problemUnder?` compares the keys as they expand), a binding of
no keys, an ex name bound twice, the base environment chosen twice,
auto-reload set twice, a package's setting given twice (`settingTwice`), a workspace root declared twice, the shell time limit set twice, a command over a store that is not declared, a store kept across a restart twice, a mode name defined twice, a
mode with a problem under any scheme (`Mode.problems`), of which the first
is named, a language name defined twice, a language with a pattern no
file name can be meant by (`Language.problems`), of which the first is
named, a completion source defined twice (`sourceTwice`), a completion
style defined twice (`styleTwice`), the style of a category, or the
default style, chosen twice (`styleChosenTwice`), a completion display
defined twice (`displayTwice`), or the display of a category, or the
default display, chosen twice (`displayChosenTwice`), or an at-point source
defined twice (`atPointTwice`), or a menu title defined twice
(`menuTwice`).

One config's names are each registered once. A second command under a name
would make the first unreachable, which is a mistake in the config and never
what it meant, so it is refused like a second store of a name; and so is a
second job, a second binding of one key sequence, to the same command or to
another, a second binding of one ex name, and a second mode of a name. A
job and a command may share a name: one is run and the other is spawned. A
binding's command is not looked up: it may be a package's, or not registered
at all; nor is a mode's, nor an ex binding's. A second `face` of a name in
one `setup` is refused the same way: the second would be over the first
attribute by attribute, which a config that sets a face in two places did
not mean. -/
def problem? (collected : Registrations) : Option String := do
  let stores := collected.stores.map (·.name)
  if let some name := repeated? stores then
    return s!"the store `{name}` is declared twice"
  if let some name := repeated? (collected.codecs.map (·.name)) then
    return s!"the store `{name}` is kept across a restart twice"
  if let some name := repeated? (collected.commands.map (·.name)) then
    return s!"the command `{name}` is registered twice"
  if let some name := repeated? (collected.jobs.map (·.name)) then
    return s!"the job `{name}` is registered twice"
  if let some name := repeated? (collected.faces.map (·.name.name)) then
    return s!"the face `{name}` is set twice"
  if let some name := repeated? (collected.themes.map (·.name)) then
    return s!"the theme `{name}` is defined twice"
  if let first :: second :: _ := collected.namedThemes.toList then
    return s!"the theme is named twice: `{first}`, then `{second}`"
  if let some name := repeated? (collected.segments.map (·.name)) then
    return s!"the segment `{name}` is defined twice"
  if collected.modeLines.size > 1 then
    return "the mode line is listed twice"
  if collected.framePaddings.size > 1 then
    return "the frame padding is set twice"
  if collected.keyHintDelays.size > 1 then
    return keyHintDelayTwice
  if collected.layouts.size > 1 then
    return "the layout is chosen twice"
  if collected.tabBars.size > 1 then
    return "the tab bar is chosen twice"
  if collected.titleBars.size > 1 then
    return "the title bar is chosen twice"
  if collected.environmentBases.size > 1 then
    return "the base environment is chosen twice"
  if collected.autoReload.size > 1 then
    return autoReloadTwice
  if let some name := repeated? collected.settings then
    return settingTwice name
  if let some root := repeated? (collected.workspaceRoots.map (Process.trimmed ·.root)) then
    return workspaceTwice root
  if let some scope := repeated? (collected.workspaceListers.map (·.scope.trimmed)) then
    return workspaceListerTwice scope
  if collected.shellTimeLimits.size > 1 then
    return shellTimeLimitTwice
  if collected.syntaxRefreshDelays.size > 1 then
    return syntaxRefreshDelayTwice
  if collected.leaders.size > 1 then
    return leaderTwice
  if collected.localLeaders.size > 1 then
    return localLeaderTwice
  for binding in collected.bindings do
    if binding.keys.isEmpty then
      return boundToNoKeys binding.command
  if let some (category, keys) :=
      repeated? (collected.bindings.map fun binding => (binding.category, binding.keys)) then
    match category with
    | none =>
      return s!"the keys `{Key.strokeNotations keys}` are bound twice"
    | some category =>
      return keysWrittenTwiceIn category keys
  if let some keys := repeated? (collected.prefixNames.map (·.keys)) then
    return prefixNamedTwice keys
  if let some name := repeated? (collected.ex.map (·.name)) then
    return s!"the ex name `{name}` is bound twice"
  for registration in collected.commands do
    if let .store store _ := registration.action then
      unless stores.contains store do
        return s!"the command `{registration.name}` is over the store `{store}`, which is not declared"
  if let some name := repeated? (collected.modes.map (·.name)) then
    return s!"the mode `{name}` is defined twice"
  for mode in collected.modes do
    if let some problem := mode.problems.head? then
      return s!"the mode `{mode.name}` cannot be meant: {problem.describe}"
  if let some name := repeated? (collected.languages.map (·.name)) then
    return s!"the language `{name}` is defined twice"
  for language in collected.languages do
    if let some problem := language.problems.head? then
      return s!"the language `{language.name}` cannot be meant: {problem}"
  if let some name := repeated? (collected.sources.map (·.name)) then
    return sourceTwice name
  if let some name := repeated? (collected.styles.map (·.name)) then
    return styleTwice name
  if let some category := repeated? (collected.styleChoices.map (·.1)) then
    return styleChosenTwice category
  if let some name := repeated? (collected.displays.map (·.name)) then
    return displayTwice name
  if let some category := repeated? (collected.displayChoices.map (·.1)) then
    return displayChosenTwice category
  if let some name := repeated? (collected.atPoints.map (·.name)) then
    return atPointTwice name
  if let some title := repeated? (collected.menus.map (·.title)) then
    return menuTwice title
  none

/-- What `setup` registers, or the message it is refused with: the one it
threw, or what is wrong with what it registered. A `setup` that is refused
registers nothing. -/
def ofSetup (setup : SetupM Unit) : Except String Registrations :=
  match Program.run (port := setupPort) collect setup.run {} with
  | (.error message, _) => .error message
  | (.ok (), collected) =>
    match collected.problem? with
    | some problem => .error problem
    | none => .ok collected

/-- What a `setup` whose bindings written as `first` and as `second` are the
one sequence `keys` under the leaders in force is refused with. -/
def keysBoundTwice (keys : List Key) (first second : List Key.Stroke) : String :=
  s!"the keys `{Key.notations keys}` are bound twice: as `{Key.strokeNotations first}` and as `{Key.strokeNotations second}`"

/-- What a `setup` whose bindings in the prompt category `category` written
as `first` and as `second` are the one sequence `keys` under the leaders in
force is refused with. -/
def keysBoundTwiceIn (category : String) (keys : List Key) (first second : List Key.Stroke) :
    String :=
  s!"the keys `{Key.notations keys}` are bound twice in the prompt category `{category}`: as `{Key.strokeNotations first}` and as `{Key.strokeNotations second}`"

/-- What a `setup` whose prefix names written as `first` and as `second` name
the one prefix `keys` under the leaders in force is refused with. -/
def prefixNamedTwiceAs (keys : List Key) (first second : List Key.Stroke) : String :=
  s!"the prefix `{Key.notations keys}` is named twice: as `{Key.strokeNotations first}` and as `{Key.strokeNotations second}`"

/-- Of `written`, each a sequence as written, the first whose expansion
against `leaders` is that of one written before it: its expansion, the
earlier as written, and it as written. -/
private def expandedTwice (leaders : Key.Leaders) (written : Array (List Key.Stroke)) :
    Option (List Key × List Key.Stroke × List Key.Stroke) := do
  let expanded := written.map fun keys => ((Key.expand leaders keys).map Key.chord, keys)
  for index in [0:expanded.size] do
    if let some (keys, second) := expanded[index]? then
      if let some (_, first) := (expanded.extract 0 index).find? (·.1 == keys) then
        return (keys, first, second)
  none

/-- What is wrong with what was collected under the input scheme `scheme`,
if anything: two bindings whose keys, expanded against the leaders in force
(the leader and the localleader `setup` set, each the scheme's where it set
none: `InputScheme.leaders`), are one sequence (`keysBoundTwice`), whatever
states each names; or two prefix names whose keys are one prefix
(`prefixNamedTwiceAs`). The registry's keymap holds a sequence once
(`Registry.keymap`), so the later would hide the earlier in every state,
and the later name would hide the earlier.
What `problem?` refuses is wrong under every scheme; this is what is wrong
under this one, so `Config.build` asks it of a `setup` `problem?` let by. -/
def problemUnder? (collected : Registrations) (scheme : InputScheme) : Option String := do
  let leaders := scheme.leaders collected.leader collected.localLeader
  let categories :=
    (collected.bindings.map (·.category)).foldl
      (fun seen category => if seen.contains category then seen else seen.push category) #[]
  for category in categories do
    let written := (collected.bindings.filter (·.category == category)).map (·.keys)
    if let some (keys, first, second) := expandedTwice leaders written then
      match category with
      | none =>
        return keysBoundTwice keys first second
      | some category =>
        return keysBoundTwiceIn category keys first second
  if let some (keys, first, second) :=
      expandedTwice leaders (collected.prefixNames.map (·.keys)) then
    return prefixNamedTwiceAs keys first second
  none

end Registrations

/-- `registry` with what `owner` registered replaced by what `registrations`
holds of the kinds an owner holds: its commands, jobs, key bindings, prefix
names, modes, ex bindings, faces, themes, segments, languages,
completion sources, styles and displays, at-point sources
and their uses, menus, store codecs and values at extension points. Every
other owner's entries are left, and so is
what no owner holds: config's own settings, which an install sets
(`Editor/Config/Reload.lean`), and the style defaults. It is the one
definition of what an owner's registrations are: an install calls it for
`config`, and a package's registration for the package's owner
(`Editor/Config/Packages.lean`). -/
def Registry.replaceOwned (registry : Registry) (owner : Owner) (registrations : Registrations) :
    Registry :=
  registry.replace owner registrations.commands |>.replaceJobs owner
                                    registrations.jobs |>.replaceBindings
                                  owner registrations.bindings |>.replacePrefixNames
                                owner registrations.prefixNames |>.replaceModes
                              owner registrations.modes |>.replaceEx
                            owner registrations.ex |>.replaceFaces
                          owner registrations.faces |>.replaceThemes
                        owner registrations.themes |>.replaceSegments
                      owner registrations.segments |>.replaceLanguages
                    owner registrations.languages |>.replaceSources
                  owner registrations.sources |>.replaceStyles
                owner registrations.styles |>.replaceDisplays
              owner registrations.displays |>.replaceAtPoints
            owner registrations.atPoints |>.replaceAtPointUses
          owner registrations.atPointUses |>.replaceMenus
        owner registrations.menus |>.replaceCodecs
      owner registrations.codecs |>.replaceExtensions
    owner registrations.extensions

end Editor.Config
