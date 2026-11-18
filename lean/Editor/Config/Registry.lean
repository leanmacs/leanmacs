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
one it registers again is there once.

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
A `setup` is refused when it declares a store name twice, registers a
command name twice or a job name twice, sets a face twice, defines a theme
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

**The menu bar shows a command's key from these bindings**
(`keyEquivalent?`): of the sequences the bindings, as one keymap, bind to
the command's name, the one bound last that is a single chord of one
character with the system key held, as a menu's key equivalent must be (a
key equivalent with no Command would take a plain key from typing, and a
named key has none). So config's binding is shown over a compiled one, a
sequence config binds to another command shows for that one, and a
command bound only to a longer sequence, a named key or a chord without
the system key shows none. A chord one of the menu's system items already
shows (`s-q` Quit, `s-h` Hide, `M-s-h` Hide Others) is skipped: AppKit
matches the system item first, so the command would never run by it, and
the command shows its next chord, or none. Mode-local bindings and an
input scheme's own keys are not looked at: the menu bar is the
application's.

## Modes

A mode (`Editor/Mode.lean`) is held by owner like a command, in a
`ModeEntry`, and replaced as a set (`replaceModes`): the owner is on the
entry, never on the mode, so `setup` cannot choose it. The latest entry of a
name is the one found (`mode?`), so config's mode of a compiled mode's name
is used in its place until a reload drops it.

- **A mode's lineage** (`lineage`) is the mode, then its parent, and so
  on, nearest first, stopping at a name no mode is registered under and at
  a mode already in it, so a cycle ends.
- **The keymaps a mode contributes** for a scheme (`modeKeymaps`) are its
  lineage's, nearest first, each mode's tuned keymap then its roles and
  suffixes (`Mode.keymaps`): a derived mode's own role wins, and a role it
  does not fill falls to the nearest parent that fills it.
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
so config's binding of an ex name a compiled binding has is the one a line
runs while config binds it, and the compiled one runs again once a reload
drops it. The command's name is not looked up here: it is looked up when
the line is run. An ex binding is not a command and is not counted as one.

Motions, operators and text objects will be registered the same way, as
vocabulary: entries by owner, replaced as a set, the latest of a name
winning. No table of them is here, since no type for their entries exists
yet.

## Themes

A theme (`NamedTheme`, `Editor/Face.lean`) is held by owner like a mode, in
a `ThemeEntry`, and replaced as a set (`replaceThemes`). The latest entry of
a name is the one found (`theme?`), so config's theme of a compiled theme's
name is used in its place until a reload drops it. Compiled code registers
the themes that ship (`Themes.shipped`, `Editor/Themes/Compiled.lean`),
`default` among them; `setup` registers more with `defineTheme`
(`Editor/Setup.lean`). `themeNames` lists each name once, in the order it
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
its place until a reload drops it. Compiled code registers the shipped
segments (`ModeLine.shipped`, through `Headless.Collaborators.segments`);
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
`LanguageEntry`, and replaced as a set (`replaceLanguages`). Compiled code
registers the languages that ship (`Language.shipped`, through
`Headless.Collaborators.languages`); `setup` registers more with
`defineLanguage` (`Editor/Setup.lean`). The table a path's language is
chosen from (`languageTable`) is each owner's entries over the earlier
owners' (`Language.over`): config's first, in the order it defined them,
then the compiled ones it did not replace by name. So config's entry of a
shipped name is used in that one's place until a reload drops it, and the
loop is told the table (`registered`).

A `setup` that defines a language name twice, or a language with a pattern
no file name can be meant by (`Language.problems`), is refused.

## Compile contributions

A compile contribution (`Compile.Contribution`,
`Editor/Compile/Contribution.lean`) is held by owner like a mode, in a
`ContributionEntry`, and replaced as a set (`replaceContributions`).
`compileContributions` is the registration order the compile mode uses:
config's contributions in the order its `setup` registered them, then the
others whose names config does not register, in their order. So config's
contribution of a compiled one's name replaces it whole, markers, commands
and formats, in config's place, until a reload drops it. Config's project
commands (`projectCommands`) are config's alone, replaced by each install.
The loop is told both (`compileHook`, `Loop.Registered.compile`).

A `setup` that registers a contribution twice, or one that names a command
twice, or that gives project commands twice for one project and mode, or
names a command twice in them, is refused (`Registrations.problem?`); one
with no marker is refused by `compileContribution` itself.

## Sources

A completion source (`Completion.Source`, `Editor/Completion.lean`) is held
by owner like a theme, in a `SourceEntry`, and replaced as a set
(`replaceSources`). The latest entry of a name is the one found (`source?`),
so config's source of a compiled source's name is used in its place until a
reload drops it. Compiled code registers the shipped sources (through
`Headless.Collaborators.sources`); `setup` registers more with
`defineSource` (`Editor/Setup.lean`). The loop is told the lookup
(`registered`, `Loop.Registered.sources`), and runs the source a prompt
names inside the asking command (`StateRequest.askSource`,
`Editor/Command/Dispatch.lean`).

The sources of a category (`sourcesIn`) are the names whose latest entry
is of it, each once, in the order the name was first registered: compiled
entries come first, so config's source of a shipped name keeps the
shipped one's place and answers in its stead, and config's of a new name
come after the compiled ones, in config's order. The loop is told them
(`Loop.Registered.categorySources`) for a prompt that asks for a category
(`StateRequest.categorySources`).

A `setup` that defines a source name twice is refused
(`Registrations.sourceTwice`).

## Styles

A completion style (`Completion.Style`, `Editor/Completion/Style.lean`) is
held by owner like a source, in a `StyleEntry`, and replaced as a set
(`replaceStyles`). The latest entry of a name is the one found (`style?`),
so config's style of a shipped style's name is used in its place until a
reload drops it. Every host registers the shipped styles, `fuzzy` and
`orderless`, for the owner `compiled` (`Headless.Collaborators.styles`);
`setup` registers more with `defineStyle` (`Editor/Setup.lean`).

Which style a prompt is matched with is config's choice, by category, with a
default for the rest (`useStyleFor`, `useStyle`): the choices are config's
alone, set by each install (`styleChoices`), as its project commands are.
`styleEntry` resolves them to the one style entry a category is matched
with: the entry of the style chosen for it when one is registered under
that name, else the chosen default's, else the style registered under
`fuzzy` (config's, when it registers one of that name), else the compiled
fuzzy style, for a registry where no style of that name is. A chosen name
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
(rows := n))`. Every host registers the shipped display, `minibuffer`, for
the owner `compiled` (`Headless.Collaborators.displays`); `setup` registers
more with `defineDisplay` (`Editor/Setup.lean`).

Which display a prompt is shown with is config's choice, by category, with
a default for the rest (`useDisplayFor`, `useDisplay`): the choices are
config's alone, set by each install (`displayChoices`). `displayEntry`
resolves them as `styleEntry` does: the entry of the display chosen for the
category when one is registered under that name, else the chosen
default's, else the display registered under `minibuffer`, else the
compiled minibuffer display, for a registry where none is. A chosen name no
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
`Editor/Setup.lean`) in setup order, then compiled code's, then the mode's
own list (`Mode.atPoint`); and last the uses for every buffer (`useAtPoint`),
config's then compiled code's. Each name is kept once, at its first place.
Uses are held by owner too, in an `AtPointUse` (`replaceAtPointUses`). The
compiled use of the shipped `words` for every buffer comes from the host
(`Headless.Collaborators.atPointUses`), so no core code names it. A name in
a chain no at-point source is registered under is reported at install
(`unknownAtPoints`, `Report.unknownAtPoints`), and never asked.

A `setup` that defines an at-point source name twice is refused
(`Registrations.atPointTwice`).

## Compiled commands

Compiled code is an owner too (`Owner.compiled`). A host registers its
compiled commands with `replace .compiled …` when it starts, before any
config, and nothing replaces them afterwards. `replace` puts an owner's
entries after every other owner's, and `find?` returns the latest entry of a
name, so config's command of a name a compiled command has is the one that
runs while config registers it, and the compiled one runs again once a
reload drops it.

A command may be given what it was called with (`Action.call`,
`Editor/Command/Call.lean`): the window it acts on, the invocation's
arguments and the keys. Compiled code registers one as such, and `setup`
does with `commandWith`; `setup`'s `command` registers a plain command,
which is told nothing of its call.

Compiled jobs are registered the same way, with `replaceJobs .compiled …`
when the host starts, and a command starts one by its name as it starts
config's. The owner a job is started for is the one that registered it, and
an install cancels the jobs of `config` alone, so a compiled job runs across
a reload. The file commands' jobs are the first (`Editor/Files/Compiled.lean`).
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

/-- A job entry of the registry: a registered job and its owner. -/
structure JobEntry where
  /-- Who registered it. -/
  owner : Owner
  /-- The job. -/
  registration : JobRegistration

/-- A key sequence bound to a command's name. -/
structure KeyBinding where
  /-- The keys, in order, as chords. -/
  keys : List Key
  /-- The name of the command the keys run, looked up when they are
  typed. -/
  command : String
  deriving DecidableEq, Repr

/-- A binding entry of the registry: a key binding and its owner. -/
structure BindingEntry where
  /-- Who bound the keys. -/
  owner : Owner
  /-- The binding. -/
  binding : KeyBinding
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

/-- A contribution entry of the registry: a compile contribution and who
registered it. -/
structure ContributionEntry where
  /-- Who registered it. -/
  owner : Owner
  /-- The contribution. -/
  contribution : Compile.Contribution

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
  /-- Where a child's environment comes from, as config set it; `none` when
it did not, which a host reads as `auto`. -/
  environment : Option Process.Setting := none
  /-- Whether config turns auto-reload on (`autoReload`,
  `Editor/Setup.lean`): false when it says nothing. -/
  autoReload : Bool := false
  /-- The workspace roots config declares (`workspace`, `Editor/Setup.lean`),
  in the order it declared them. -/
  workspaceRoots : Array Workspace.ConfigRoot := #[]
  /-- How many configs have been installed: the config generation a
  directory's cached workspace was found under (`Editor/Workspace.lean`).
  0 while only compiled code is registered. -/
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
  /-- The compile contribution entries ("Compile contributions", in the
  module docs). -/
  contributions : Array ContributionEntry := #[]
  /-- Config's project commands (`projectCommands`, `Editor/Setup.lean`), in
  the order it gave them. -/
  projectCommands : Array Compile.ProjectCommands := #[]
  /-- The completion source entries ("Sources", in the module docs). -/
  sources : Array SourceEntry := #[]
  /-- The completion style entries ("Styles", in the module docs). -/
  styles : Array StyleEntry := #[]
  /-- Config's choices of completion style (`useStyle`, `useStyleFor`,
  `Editor/Setup.lean`), each a category, or `none` for the default, and a
  style's name, in the order it made them: set at every install. -/
  styleChoices : Array (Option String × String) := #[]
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
under the name chosen for the default, when one is; else under `fuzzy`, so
config's style of that name is used in the shipped one's place; else, for
a registry where none is, the compiled fuzzy style, as compiled's. The one
lookup both the style and its owner are read from (`matching`). -/
def styleEntry (registry : Registry) (category : Option String) : StyleEntry :=
  let named (name : String) : Option StyleEntry := registry.styles.findRev? (·.style.name == name)
  let chosen (category : Option String) : Option StyleEntry :=
    (registry.styleChoices.find? (·.1 == category)).bind fun (_, name) => named name
  ((category.bind fun category => chosen (some category)) <|>
        chosen none <|> named Completion.Styles.fuzzy.name).getD
    { owner := .compiled, style := Completion.Styles.fuzzy }

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
under the name chosen for the default, when one is; else under
`minibuffer`, so config's display of that name is used in the shipped
one's place; else, for a registry where none is, the compiled minibuffer
display, as compiled's. `styleEntry`'s rule. -/
def displayEntry (registry : Registry) (category : Option String) : DisplayEntry :=
  let named (name : String) : Option DisplayEntry :=
    registry.displays.findRev? (·.display.name == name)
  let chosen (category : Option String) : Option DisplayEntry :=
    (registry.displayChoices.find? (·.1 == category)).bind fun (_, name) => named name
  ((category.bind fun category => chosen (some category)) <|>
        chosen none <|> named Completion.Displays.minibuffer.name).getD
    { owner := .compiled, display := Completion.Displays.minibuffer }

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
entry (`source?`) is of that category. Compiled entries come before
config's, so a config source of a compiled name keeps the compiled one's
place, and one of a new name comes after them. -/
def sourcesIn (registry : Registry) (category : String) : Array String :=
  let names := (registry.sources.map (·.source.name)).toList.eraseDups.toArray
  names.filter fun name => (registry.source? name).any (·.category == category)

/-- `registry` with every contribution entry of `owner` removed and
`contributions` added as its entries, in their order. -/
def replaceContributions (registry : Registry) (owner : Owner)
    (contributions : Array Compile.Contribution) : Registry :=
  { registry with
    contributions :=
      registry.contributions.filter (·.owner != owner) ++
        contributions.map fun contribution => { owner, contribution } }

/-- The compile contributions in registration order ("Compile
contributions", in the module docs): config's in its order, then the others
whose names config does not register. -/
def compileContributions (registry : Registry) : Array Compile.Contribution :=
  let config := (registry.contributions.filter (·.owner == .config)).map (·.contribution)
  let others :=
    (registry.contributions.filter (·.owner != .config)).map (·.contribution) |>.filter
      fun contribution => !config.any (·.mode == contribution.mode)
  config ++ others

/-- What the loop is told of the compile contributions: them in
registration order, and config's project commands. -/
def compileHook (registry : Registry) : Compile.Hook :=
  { contributions := registry.compileContributions, projects := registry.projectCommands }

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

/-- The job entry `name` starts: the latest one of that name. -/
def findJob? (registry : Registry) (name : String) : Option JobEntry :=
  registry.jobs.findRev? (·.registration.name == name)

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

/-- The keymap of every owner's bindings for `scheme`: each key sequence
bound to what the scheme says runs the command of its name. The entries are
bound oldest first, so of two owners that bind one sequence the later
owner's is the keymap's. -/
def keymap (registry : Registry) (scheme : InputScheme) : Keymap scheme.Binding :=
  Keymap.ofList
    (registry.bindings.toList.map fun entry =>
      (entry.binding.keys, scheme.command entry.binding.command))

/-- The key equivalent the menu bar shows for the command `command`: the
last chord the bindings bind to it alone that is one character with the
system key held and is none of `taken`, the keys the menu's system items
already show ("Key bindings", in the module docs); `none` when no binding
is such a chord. -/
def keyEquivalent? (registry : Registry) (command : String) (taken : List KeyEquivalent := []) :
    Option KeyEquivalent :=
  let keymap : Keymap String :=
    Keymap.ofList
      (registry.bindings.toList.map fun entry => (entry.binding.keys, entry.binding.command))
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
(`Mode.keymaps`). None for a name no mode is registered under. -/
def modeKeymaps (registry : Registry) (scheme : InputScheme) (name : String) :
    List (Keymap scheme.Binding) :=
  (registry.lineage name).flatMap (Mode.keymaps scheme)

/-- The active keymaps of `view` in `state` for `scheme`, in precedence
order: the keymaps of each minor mode of the view's buffer, the one added
last first, then its major mode's, then the global keymap of every owner's
key bindings (`keymap`). A view with no window has the global keymap
alone. -/
def activeMaps (registry : Registry) (scheme : InputScheme) (state : EditorState) (view : ViewId) :
    List (Keymap scheme.Binding) :=
  let global := registry.keymap scheme
  match state.target? view with
  | none => [global]
  | some target =>
    let minors := target.buffer.minors.toList.flatMap (registry.modeKeymaps scheme)
    let major := (target.buffer.major.map (registry.modeKeymaps scheme)).getD []
    minors ++ major ++ [global]

/-- The names the uses for `mode` (`none` for every buffer) give: config's
in the order it made them, then compiled code's. -/
def usesFor (registry : Registry) (mode : Option String) : Array String :=
  let of (owner : Owner) :=
    (registry.atPointUses.filter fun use => use.owner == owner && use.mode == mode).map (·.source)
  of .config ++
    (registry.atPointUses.filter fun use => use.owner != .config && use.mode == mode).map (·.source)

/-- The chain of at-point sources of a buffer whose major mode is `major`
and whose minor modes are `minors`, the one added last first ("At-point
sources", in the module docs): each minor mode, then the major mode, each
with its lineage nearest first, each mode giving its uses, config's then
compiled code's, then its own list; then the uses for every buffer. Each
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

/-- What the loop is told of the registry for a command's state requests
(`Editor/Command/Dispatch.lean`): for a name a mode is registered under,
its lineage, root first, whose on-enter actions run when the mode becomes a
buffer's major mode; whether a job is registered under a name, for a
command to start; and the ex binding of an ex name (`ex?`) and the ex
names that are bound (`exNames`), for the ex line; and the names themes
are registered under (`themeNames`), for the command that loads one;
config's workspace roots and the config generation, for the finder;
config's display rules, for a command that displays a buffer; config's
shell time limit, for `:!`; the language table (`languageTable`), for a
file's open and a mode's entry; and the compile contributions and config's
project commands (`compileHook`), for the compile mode; and the
completion source registered under a name (`source?`) and the names of
those registered in a category (`sourcesIn`), for a prompt that asks for
them. Which command a
name stands for, for a command run inside another,
is not said here: the loop takes it from the lookup it runs an invocation
by (`Loop.Keys.command?`, `Editor/Loop.lean`, "A command run inside
another"). -/
def registered (registry : Registry) : Loop.Registered :=
  { entering := fun name => (registry.mode? name).map fun _ => (registry.lineage name).reverse
    jobs := fun name => (registry.findJob? name).isSome, ex := registry.ex?
    exNames := registry.exNames, themeNames := registry.themeNames
    autoReload := registry.autoReload, workspaceRoots := registry.workspaceRoots
    generation := registry.generation, displayRules := registry.displayRules
    shellTimeLimit := registry.shellTimeLimit, syntaxRefreshDelay := registry.syntaxRefreshDelay
    languages := registry.languageTable, compile := registry.compileHook
    sources := registry.source?, categorySources := registry.sourcesIn
    atPoint := registry.atPoint?, atPointNames := registry.atPointNames }

end Registry

/-- What one run of a `setup` registers. -/
structure Registrations where
  /-- The commands, in the order they were registered. -/
  commands : Array Registration := #[]
  /-- The stores, in the order they were declared. -/
  stores : Array StoreDeclaration := #[]
  /-- The jobs, in the order they were registered. -/
  jobs : Array JobRegistration := #[]
  /-- The key bindings, in the order they were made, their keys as chords. -/
  bindings : Array KeyBinding := #[]
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
  /-- Each setting of where a child's environment comes from, in the order
they were made: one at most, in a `setup` that is not refused. -/
  environments : Array Process.Setting := #[]
  /-- What each `autoReload` of the `setup` said, in order. -/
  autoReload : Array Bool := #[]
  /-- The workspace roots the `setup` declared, in order: a root once at
  most, in a `setup` that is not refused. -/
  workspaceRoots : Array Workspace.ConfigRoot := #[]
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
  /-- The compile contributions, in the order they were registered. -/
  contributions : Array Compile.Contribution := #[]
  /-- The project commands, in the order they were given. -/
  projectCommands : Array Compile.ProjectCommands := #[]
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
  | .job name work, collected => ((), { collected with jobs := collected.jobs.push { name, work } })
  | .bind keys command, collected =>
    ((),
      { collected with
        bindings := collected.bindings.push { keys := keys.map Key.chord, command } })
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
  | .layout chosen, collected => ((), { collected with layouts := collected.layouts.push chosen })
  | .tabBar shown, collected => ((), { collected with tabBars := collected.tabBars.push shown })
  | .titleBar style, collected =>
    ((), { collected with titleBars := collected.titleBars.push style })
  | .processEnvironment setting, collected =>
    ((), { collected with environments := collected.environments.push setting })
  | .autoReload on, collected => ((), { collected with autoReload := collected.autoReload.push on })
  | .workspace root project, collected =>
    ((), { collected with workspaceRoots := collected.workspaceRoots.push { root, project } })
  | .displayRule rule, collected =>
    ((), { collected with displayRules := collected.displayRules.push rule })
  | .shellTimeLimit milliseconds, collected =>
    ((), { collected with shellTimeLimits := collected.shellTimeLimits.push milliseconds })
  | .syntaxRefreshDelay milliseconds, collected =>
    ((), { collected with syntaxRefreshDelays := collected.syntaxRefreshDelays.push milliseconds })
  | .language language, collected =>
    ((), { collected with languages := collected.languages.push language })
  | .compileContribution contribution, collected =>
    ((), { collected with contributions := collected.contributions.push contribution })
  | .projectCommands entry, collected =>
    ((), { collected with projectCommands := collected.projectCommands.push entry })
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

/-- Where a child's environment comes from, as the `setup` set it, or `none`
when it did not. -/
def environment (collected : Registrations) : Option Process.Setting :=
  collected.environments[0]?

/-- What a `setup` that sets auto-reload twice is refused with. -/
def autoReloadTwice : String :=
  "auto-reload is set twice"

/-- What a `setup` that declares the workspace root `root` twice is refused
with. -/
def workspaceTwice (root : System.FilePath) : String :=
  s!"the workspace root `{root}` is declared twice"

/-- What a `setup` that registers the compile contribution of `mode` twice
is refused with. -/
def contributionTwice (mode : String) : String :=
  s!"the compile contribution `{mode}` is registered twice"

/-- What a `setup` whose compile contribution of `mode` names the command
`name` twice is refused with. -/
def contributionCommandTwice (mode name : String) : String :=
  s!"the compile contribution `{mode}` names the command `{name}` twice"

/-- What a `setup` that gives the project commands of `mode` for the
project `project` twice is refused with. -/
def projectCommandsTwice (mode : String) (project : Project.Identity) : String :=
  s!"the project commands of `{mode}` for {project.describe} are given twice"

/-- What a `setup` whose project commands of `mode` for the project
`project` name the command `name` twice is refused with. -/
def projectCommandTwice (mode : String) (project : Project.Identity) (name : String) : String :=
  s!"the project commands of `{mode}` for {project.describe} name the command `{name}` twice"

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

/-- The first of `items` that an earlier one already is, if any. -/
def repeated? {α : Type} [BEq α] (items : Array α) : Option α := do
  for index in [0:items.size] do
    if let some item := items[index]? then
      if (items.extract 0 index).contains item then
        return item
  none

/-- What is wrong with what was collected, if anything: a store declared
twice, a command name or a job name registered twice, a face set twice, a
theme defined twice, a theme named twice (by its first two names), a
segment defined twice, the mode line listed twice, the frame padding set
twice, the layout chosen twice, the tab bar chosen twice, the title bar chosen twice, a key sequence bound twice, a binding of
no keys, an ex name bound twice, the process environment set twice,
auto-reload set twice, a workspace root declared twice, the shell time limit set twice, a compile contribution registered twice or naming a command twice, project commands given twice for one project and mode or naming a command twice, a command over a store that is not declared, a mode name defined twice, a
mode with a problem under any scheme (`Mode.problems`), of which the first
is named, a language name defined twice, a language with a pattern no
file name can be meant by (`Language.problems`), of which the first is
named, a completion source defined twice (`sourceTwice`), a completion
style defined twice (`styleTwice`), the style of a category, or the
default style, chosen twice (`styleChosenTwice`), a completion display
defined twice (`displayTwice`), or the display of a category, or the
default display, chosen twice (`displayChosenTwice`), or an at-point source
defined twice (`atPointTwice`).

One config's names are each registered once. A second command under a name
would make the first unreachable, which is a mistake in the config and never
what it meant, so it is refused like a second store of a name; and so is a
second job, a second binding of one key sequence, to the same command or to
another, a second binding of one ex name, and a second mode of a name. A
job and a command may share a name: one is run and the other is spawned. A
binding's command is not looked up: it may be compiled, or not registered
at all; nor is a mode's, nor an ex binding's. A second `face` of a name in
one `setup` is refused the same way: the second would be over the first
attribute by attribute, which a config that sets a face in two places did
not mean. -/
def problem? (collected : Registrations) : Option String := do
  let stores := collected.stores.map (·.name)
  if let some name := repeated? stores then
    return s!"the store `{name}` is declared twice"
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
  if collected.layouts.size > 1 then
    return "the layout is chosen twice"
  if collected.tabBars.size > 1 then
    return "the tab bar is chosen twice"
  if collected.titleBars.size > 1 then
    return "the title bar is chosen twice"
  if collected.environments.size > 1 then
    return "the process environment is set twice"
  if collected.autoReload.size > 1 then
    return autoReloadTwice
  if let some root := repeated? (collected.workspaceRoots.map (Process.trimmed ·.root)) then
    return workspaceTwice root
  if collected.shellTimeLimits.size > 1 then
    return shellTimeLimitTwice
  if collected.syntaxRefreshDelays.size > 1 then
    return syntaxRefreshDelayTwice
  if let some mode := repeated? (collected.contributions.map (·.mode)) then
    return contributionTwice mode
  for contribution in collected.contributions do
    if let some name := repeated? (contribution.commands.map (·.name)) then
      return contributionCommandTwice contribution.mode name
  if let some (project, mode) :=
      repeated? (collected.projectCommands.map fun entry => (entry.project, entry.mode)) then
    return projectCommandsTwice mode project
  for entry in collected.projectCommands do
    if let some name := repeated? (entry.commands.map (·.name)) then
      return projectCommandTwice entry.mode entry.project name
  for binding in collected.bindings do
    if binding.keys.isEmpty then
      return boundToNoKeys binding.command
  if let some keys := repeated? (collected.bindings.map (·.keys)) then
    return s!"the keys `{Key.notations keys}` are bound twice"
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

end Registrations

end Editor.Config
