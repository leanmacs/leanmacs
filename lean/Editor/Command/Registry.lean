import Editor.Completion.Candidate
import Editor.DisplayRules
import Editor.Ex.Line
import Editor.InputScheme
import Editor.Language.IndentUnit
import Editor.Process.Environment
import Editor.Role
import Editor.Store.Codec
import Editor.Workspace

/-!
# Questions to the registry and config

What a command asks of what the loop was told of the registry and config
(`Loop.Registered`, `Editor/Command/Dispatch.lean`): which command an ex
name runs, which themes and commands there are, which key sequences reach
a command, config's settings, the language table, the jobs and the
completion sources registered. A `RegistryRequest` is a
request of the editor's port (`EditorRequest.registry`,
`Editor/Command.lean`), and a command asks it with `RegistryRequest.ask`
(`Editor/Api.lean`).

## The rules

- **A question's reply is plain data.** A reply cannot hold a mode, a
  command or a source, which are programs over the port this request is
  part of: a reply that held one would be a type that refers to itself.
  So a question about a source is answered its names (`categorySources`,
  `atPointSources`), and the source is run by a control request
  (`Editor/Command/Control.lean`).
  The one exception is `extensions`, and `configExtensions` with it,
  answered the values registered at an
  extension point as `Dynamic`s: `Dynamic` is an opaque `Type`, so a value
  whose fields are `EditorM` programs travels in it without the reply's
  type referring to itself, and the command that reads it, typed again by
  `Dynamic.get?`, runs those programs itself (`Editor/Extension.lean`).
- **The loop answers every question with one pure function of what it was
  told** (`Loop.Registered.answer`, `Editor/Command/Dispatch.lean`). It
  reads no state and changes none, so a question about a buffer is handed
  what the asking command read of it (`atPointSources` takes the buffer's
  modes, not a view).
- **A question is not guarded.** It is pure Lean, not a call into the
  library, as a state request is (`Editor/Command/Dispatch.lean`, "The
  guard").
- **Where no loop dispatched the command, a runner answers it `bare`**
  (`RegistryRequest.bare`): as with nothing registered, except that any job
  name is taken, as a start of any name is where no loop gates it. Every
  command a host runs goes through the loop; only a test runs one bare.
- `ex` is answered the binding the registry has for an ex name
  (`Editor/Ex/Line.lean`), `exNames` the ex names that are bound, and
  `themeNames` the names themes are registered under.
- `commandNames` is answered the names commands are registered under, each
  once, in their order: the command prompt's candidates
  (`packages/execute-command/ExecuteCommand.lean`).
- `keyBindings` is answered the key sequences that reach a command in a
  view, as the input scheme says in the scheme's state of the step that
  asks: the loop fills it per step from the scheme, not from the registry
  (`Loop.Registered.keyBindings`). The binding search and the command
  prompt ask (`packages/binding-search/BindingSearch.lean`, `packages/execute-command/ExecuteCommand.lean`).
- `autoReload` is answered config's setting alone. Whether auto-reload is
  in effect is a command's choice, which is state (`EditorState.autoReload`),
  or else this.
- `workspaceSettings` is answered config's workspace roots and the config
  generation: what the finder is handed. Its settings carry config's
  workspace listers too, which choose what lists a workspace's files
  (`packages/workspace/Workspace/Lister.lean`).
- `displayRules` is answered config's display rules, in order
  (`Editor/DisplayRules.lean`).
- `shellTimeLimit` and `syntaxRefreshDelay` are answered config's shell
  time limit and its syntax refresh delay.
- `languageOf` is answered the name of the language the table chooses for
  a path (`Language.forPath`), and `indentUnitOf` the unit of the table's
  first entry of a name.
- `languageCaptures` is answered each language of the table, config's
  entries over the shipped ones, as its grammar's name and its captures'
  face overrides (`Mode.SyntaxTree.captures`): what a rendered Markdown
  view draws a fence's captures with (`Editor/Markdown/View.lean`). It is
  plain data, since this module sits below `Editor.Language`; `none` where
  no loop runs the command, which a caller reads as the shipped table.
- `hasJob` is answered whether a job is registered under a name, as a
  start is checked.
- `categorySources` is answered the names of the completion sources
  registered in a category, and `atPointSources` the names of the
  at-point sources of the chain of a buffer with the modes it is handed,
  that ask on an occasion.
- `roleCommand` is answered the command a buffer's own modes fill a role
  with, handed the buffer's major and minor modes: the first over the
  minor modes' lineages, the one added last first, then the major mode's,
  never the links mode's. The links mode's `link-follow` asks for
  `activate`, to run the buffer's own handler off a link
  (`Editor/Links.lean`).
- `storeCodec` is answered the codec a store of a name is kept across a
  restart with, and its owner's name (`Editor/Store/Codec.lean`): what the
  session restore meets a kept cell with before it hands the cell to the
  state as plain data (`Editor/Restore/Run.lean`). A codec holds pure
  functions over plain trees, never a program over the port, so it may be
  in a reply.

There is no single read of config's readings, as `StateRequest.read` is
for the state: the language table cannot be in a reply, since a language
holds a `Mode.SyntaxTree`, defined in `Editor/Mode.lean`, which imports the
editor's port, and `ex`, `hasJob`,
`categorySources` and `atPointSources` are lookups over what the registry
holds as functions. `docs/design/lean-runtime.md` ("The editor's port is a
composite") records the choice.

## Where an addition goes

A new question to the registry or config is: a field of `Loop.Registered`
(`Editor/Command/Dispatch.lean`) if the loop is not told it yet, a
constructor here with its `Reply` case and its `bare` case, its case in
`Loop.Registered.answer`, and the operation a command calls in
`Editor/Api.lean` if commands outside the editor ask it.

Pinned by `ModelTest.registryRequestChecks` (the bare answers) and
`ModelTest.dispatchRegistryChecks` (the loop's).
-/

namespace Editor

/-- What a command may ask of the registry and config, which the loop that
runs the command answers. -/
inductive RegistryRequest where
  /-- Which command the ex name `name` is bound to, and what it takes. -/
  | ex (name : String)
  /-- Which ex names are bound. -/
  | exNames
  /-- Which names themes are registered under. -/
  | themeNames
  /-- Which names commands are registered under. -/
  | commandNames
  /-- Which key sequences reach a command in the view, as the input scheme
  says in the state the command runs in. -/
  | keyBindings (view : ViewId)
  /-- Whether config's setting turns auto-reload on. A command's choice is
  the state's (`EditorState.autoReload`). -/
  | autoReload
  /-- What the finder is to be handed, config's roots among it, and the
  config generation; config's workspace listers are among the settings
  too. -/
  | workspaceSettings
  /-- Config's display rules, in order. -/
  | displayRules
  /-- How long a `:!` or a filter may run, in milliseconds, as config set
  it. -/
  | shellTimeLimit
  /-- How long a text goes unchanged after an edit before it is parsed
  whole again, in milliseconds, as config set it. -/
  | syntaxRefreshDelay
  /-- The name of the language the registry's table chooses for `path`. -/
  | languageOf (path : System.FilePath)
  /-- The indent unit of the language called `language`, from the
  registry's table. -/
  | indentUnitOf (language : String)
  /-- Each language of the registry's table, as its grammar's name and its
  captures' face overrides. -/
  | languageCaptures
  /-- Whether a job is registered under `name`. -/
  | hasJob (name : String)
  /-- Which completion sources are registered in `category`, by name, in
  registration order. -/
  | categorySources (category : String)
  /-- The names of the at-point sources of the chain of a buffer whose major
  mode is `major` and whose minor modes are `minors`, in the order they
  were added, that ask on `occasion`, in order. -/
  | atPointSources (major : Option String) (minors : Array String) (occasion : Completion.Occasion)
  /-- The codec the store called `name` is kept across a restart with, and
  its owner's name. -/
  | storeCodec (name : String)
  /-- The values registered at the extension point `key`, the name of the
  point's type, in registration order, each as a `Dynamic`
  (`Editor/Extension.lean`). -/
  | extensions (key : Lean.Name)
  /-- The values config registered at the extension point `key`, in
  registration order, each as a `Dynamic`: the tail of `extensions`'
  answer (`Extension.configValues`). -/
  | configExtensions (key : Lean.Name)
  /-- The name of the base of a child's environment a host installs:
  config's choice, else the latest package's default, else `inherited`
  (`Config.Registry.baseName`). -/
  | environmentBase
  /-- The command the modes of a buffer whose major mode is `major` and whose
  minor modes are `minors`, the one added last first, fill `role` with: the
  first over each minor mode's lineage, then the major mode's, nearest
  first, as the keymaps resolve; never the links mode's
  (`Config.Registry.roleCommand`). -/
  | roleCommand (major : Option String) (minors : Array String) (role : Role)

/-- The type of the reply to each question. -/
abbrev RegistryRequest.Reply : RegistryRequest → Type
  | .ex _ => Option Ex.Binding
  | .exNames => Array String
  | .themeNames => Array String
  | .commandNames => Array String
  | .keyBindings _ => Array KeyBinding
  | .autoReload => Bool
  | .workspaceSettings => Workspace.Settings × Nat
  | .displayRules => Array DisplayRule
  | .shellTimeLimit => Option Nat
  | .syntaxRefreshDelay => Option Nat
  | .languageOf _ => Option String
  | .indentUnitOf _ => Option Language.IndentUnit
  | .languageCaptures => Option (List (String × List (String × Option FaceName)))
  | .hasJob _ => Bool
  | .categorySources _ => Array String
  | .atPointSources .. => Array String
  | .storeCodec _ => Option (String × StoreCodec)
  | .extensions _ => Array Dynamic
  | .configExtensions _ => Array Dynamic
  | .environmentBase => String
  | .roleCommand .. => Option String

/-- The answer to `request` where no loop dispatched the command: as with
nothing registered and config's defaults, except that any job name is
taken, as a start of any name is where no loop gates it. -/
def RegistryRequest.bare : (request : RegistryRequest) → request.Reply
  | .ex _ => none
  | .exNames => #[]
  | .themeNames => #[]
  | .commandNames => #[]
  | .keyBindings _ => #[]
  | .autoReload => false
  | .workspaceSettings => ({}, 0)
  | .displayRules => #[]
  | .shellTimeLimit => none
  | .syntaxRefreshDelay => none
  | .languageOf _ => none
  | .indentUnitOf _ => none
  | .languageCaptures => none
  | .hasJob _ => true
  | .categorySources _ => #[]
  | .atPointSources .. => #[]
  | .storeCodec _ => none
  | .extensions _ => #[]
  | .configExtensions _ => #[]
  | .environmentBase => Process.inheritedName
  | .roleCommand .. => none

end Editor
