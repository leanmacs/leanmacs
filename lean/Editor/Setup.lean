import Editor.Command.Call
import Editor.Compile.Contribution
import Editor.Completion
import Editor.Completion.Later
import Editor.Completion.Displays
import Editor.Completion.Styles
import Editor.DisplayRules
import Editor.Ex.Line
import Editor.Face
import Editor.Job
import Editor.Key.Notation
import Editor.Language
import Editor.Layout
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Store
import Editor.TabBar
import Editor.Window

/-!
# `setup`: what config registers

Config defines commands and jobs, and one action, `setup`, that registers
them with the editor:

```lean
def greet : EditorM Unit := do
  let text ← createText "hello"
  append text ", world"

def count : Unit → JobM Nat := fun _ => do
  sleep 10
  return 42

def setup : SetupM Unit := do
  command "greet" greet
  bindKey "C-c g" "greet"
  job "count" count fun n => discard <| createText s!"counted {n}"
  defineMode { name := "greeting", roles := [(Role.activate, "greet")], locals := [("g", "greet")] }
```

A job is registered with the handler that makes the command its result is
taken to the editor with. `setup` starts nothing: it is a collected program,
and nothing of a config exists until it is installed. A job is not a
command, and is not counted as one.

A job may take arguments (`jobWith`): plain values (`Argument`,
`Editor/Invocation.lean`), given by whoever starts it. A command starts a
job by its name with arguments (`startJob`, `Editor/Api.lean`), since a
request of the editor's port holds plain data and cannot hold the job:

```lean
def setup : SetupM Unit := do
  jobWith "double"
      (fun arguments => do
        let [.nat n] := arguments | throw "double takes one number"
        return 2 * n)
      fun n => message s!"doubled to {n}"
  command "ask" (discard <| startJob "double" [.nat 21])
```

A job registered with `job` takes none, and is the same job whatever it is
started with.

A command may be given what it was called with (`commandWith`, named as
`jobWith` is beside `job`): the `Call` (`Editor/Command/Call.lean`), which
holds the window it acts on, the invocation's arguments and the keys that
yielded it. A command registered with `command` is told none of it. So a
command of config's can read a count, and can be the continuation of a
prompt, which receives the answer as its first argument (`prompt`,
`Editor/Api.lean`):

```lean
def setup : SetupM Unit := do
  commandWith "greet-named" fun call =>
    match call.arguments with
    | .str name :: _ => message s!"hello {name}"
    | _ => message "hello"
  command "ask-name" (discard <| prompt "Name: " { command := "greet-named" })
```

Both kinds are commands under one set of names: a name registered twice is
refused whichever the two are.

A mode (`Editor/Mode.lean`) is defined with `defineMode`: the roles it
fills and its suffixes name commands, which are looked up when the keys are
typed. Its owner is the registry's to say, never the mode's. A mode is not a
command and is not counted as one.

A key sequence is bound to a command's name (`bindKey`), written as a key
string (`Editor/Key/Notation.lean`). The name is looked up when the keys
are typed, so a binding may name a compiled command, or a command that is
not registered, which then says so in the echo area. A binding is not a
command and is not counted as one. It is called `bindKey` and not `bind`,
which would shadow the monad's inside `namespace Editor` and for config,
which opens it.

An ex name is bound to a command's name (`exCommand`): a line of the ex
command line whose first word is the name runs that command
(`docs/design/keymaps-and-modes.md`, "The ex command line"). By default the
name takes nothing after it; with `takes := .text` the rest of the line is
the command's first argument, a string, which is where a prompt's answer
goes, so the continuation above is an ex command as it stands:

```lean
def setup : SetupM Unit := do
  commandWith "greet-named" fun call =>
    match call.arguments with
    | .str name :: _ => message s!"hello {name}"
    | _ => message "hello"
  exCommand "greet" "greet-named" (takes := .text)
```

The command's name is looked up when the line is run, as a key binding's
is. An ex binding is not a command and is not counted as one. `exCommand`
refuses a name the ex line cannot read back as itself: one that is empty,
holds white space, or starts with `!`, `%`, `.`, `$`, `,` or a digit, which
the line reads as a range or as `:!` (`Ex.reachable`,
`Editor/Ex/Line.lean`).

`setup` is a program over a port of its own, the *setup port*, whose requests
carry what is registered. It is plain data like any program
(`Editor/Program.lean`): it holds no `IO` and changes nothing by itself. After
a config has elaborated, the editor runs its `setup` against a handler that
collects the requests into a value (`Editor/Config/Registry.lean`), on the
thread that elaborated it, and the editor thread installs that value later.
So a reload is all-or-nothing by construction: nothing is registered until
the whole of `setup` has run and what it collected has been checked.

`setup` may refuse: a `throw` with a message ends it, the reload is rejected
with that message, and the config that was loaded before stays.

The editor refuses a `setup` too, the same way, when what it registered
cannot be meant: a command name or a job name registered twice (the first
could never run), a key sequence bound twice (the first binding could never
run), an ex name bound twice, a store name declared twice, a theme defined
twice or named twice, a segment defined twice, the mode line listed twice,
a completion source defined twice, a completion style defined twice, the
style of one category or the default style chosen twice, a completion
display defined twice, the display of one category or the default display
chosen twice,
a command over a store the `setup`
does not declare, a mode name defined twice, or a mode that cannot be meant
under any scheme (`Mode.problems`: a role that is not registered, a suffix
used twice, a suffix that is not keys). The diagnostic names the command,
the job, the keys, the store or the mode, and a mode's problem. Whether a
scheme's hand-tuned key shadows one of its own needs a scheme, which the
registry does not know: only `Mode.check` reports it. `bindKey` itself refuses a key string that is not keys, with the
key parser's reason, and one that names no keys.

Config sets faces the same way (`Editor/Face.lean`): `face "keyword"
{ foreground := some (Color.rgb 200 0 0) }` sets the attributes it names of
the face `keyword`, over the theme's, and leaves the rest to the theme. A
face a config stops setting is the theme's again when the config is
installed. One `setup` sets a name once: a second `face` of a name is
refused like a second command of a name, and the diagnostic names the face.

Config registers whole themes too, and names the one in force:

```lean
def setup : SetupM Unit := do
  defineTheme "dusk" (Theme.builtin ++
    #[{ name := ⟨"default"⟩, face := { foreground := some (Color.rgb 200 200 0) } }])
  useTheme "dusk"
  face "keyword" { foreground := some (Color.rgb 200 0 0) }
```

`defineTheme` registers a theme by name, for this config; `useTheme` names
the theme in force once the config is installed, a compiled one (`default`
is the built-in theme) or one the `setup` defines. A theme in force replaces
the built-in theme wholesale, not over it: it must define every face it
needs, the cursor faces, `selection`, `echo-area` and `mode-line` among them,
or those faces are not drawn (a cursor face nothing defines is not seen).
The example keeps the built-in faces by building `dusk` as `Theme.builtin`
followed by its own definitions; a later definition of a name is over an
earlier one. Config's own faces are over whichever theme is in force. A
`setup` that defines a theme name twice,
or names a theme twice, is refused. A name no theme is registered under is
not refused: it is looked up when the config is installed, and the theme in
force then stays, and the echo area says so (`Editor/Config/Reload.lean`).
A config that names no theme keeps the theme in force.

Config registers completion sources, by name (`Editor/Completion.lean`):

```lean
def setup : SetupM Unit := do
  defineSource (.ofTexts "picks" "pick" #["wq", "edit", "w"])
```

`defineSource` registers a source for this config; a prompt asked with
`.named "picks"` lists what it answers (`prompt`, `Editor/Api.lean`). Config's
source of a compiled source's name is used in that one's place until a
reload drops it. A `setup` that defines a source name twice is refused
(`Config.Registrations.sourceTwice`).

A source that cannot answer before the next key answers later, from a job
it names (`Editor/Completion/Later.lean`):

```lean
def setup : SetupM Unit := do
  sourceJob "echo" fun query deliver => deliver #[.ofText query.text]
  defineSource (.answeringLater "echo" "pick" "echo" (reask := .afterPause 20))
```

`sourceJob` registers the job, which is given the query and delivers its
candidates in batches as they come; the source says which job answers it
and when it is asked again (`never`, or `afterPause` for one that depends
on the text). A reload cancels config's source jobs, as it cancels any job
of config's, and the listing keeps what came.

Config registers completion styles by name and chooses one for each
category, with a default for the rest (`Editor/Completion/Style.lean`):

```lean
def setup : SetupM Unit := do
  defineStyle (.keeping "starts" fun text candidate => candidate.startsWith text)
  useStyle "starts"
  useStyleFor "buffer" "orderless"
```

`defineStyle` registers a style for this config; the shipped styles,
`fuzzy` and `orderless` (`Completion.Styles.shipped`), are registered by
every host. `useStyleFor category name` chooses the style of the prompts of
`category`, and `useStyle name` the default for the others; with none
chosen the default is `fuzzy`. A name no style is registered under is not
refused: it is looked up at install, the category falls to the default
(the default to `fuzzy`), and the echo area says so
(`Completion.Styles.unknown`). A `setup` that defines a style name twice
is refused (`Config.Registrations.styleTwice`), and so is one that
chooses the style of one category, or the default, twice
(`Config.Registrations.styleChosenTwice`).

Config registers completion displays by name and chooses one for each
category, with a default for the rest (`Editor/Completion/Display.lean`),
as it does styles:

```lean
def setup : SetupM Unit := do
  defineDisplay (Completion.Displays.minibuffer (rows := 15))
  defineDisplay (Completion.Display.plain "plain")
  useDisplayFor "file" "plain"
```

`defineDisplay` registers a display for this config; the shipped display,
`minibuffer` (`Completion.Displays.shipped`), is registered by every host.
Config's display of a shipped name is used in its place: the first line
above replaces the shipped `minibuffer` with one that shows at most 15
rows, which is how config sets the most rows the minibuffer's list shows
(10 unless it does, `Completion.Displays.rows`). `useDisplayFor category
name` chooses the display of the prompts of `category`, and `useDisplay
name` the default for the others; with none chosen the default is
`minibuffer`. A name no display is registered under is not refused: it is
looked up at install, the category falls to the default (the default to
`minibuffer`), and the echo area says so (`Completion.Displays.unknown`).
A `setup` that defines a display name twice is refused
(`Config.Registrations.displayTwice`), and so is one that chooses the
display of one category, or the default, twice
(`Config.Registrations.displayChosenTwice`).

Config defines segments of the mode line and lists them for each side
(`Editor/ModeLine.lean`):

```lean
def setup : SetupM Unit := do
  defineSegment "greeting" fun _ =>
    #[{ text := "hi", face := ⟨"mode-line.secondary"⟩, padding := 4 }]
  modeLine ["state", "buffer", "modified"] ["greeting", "line-column", "position"]
```

`defineSegment` registers a segment by name, for this config: a function
from what a window shows (`ModeLine.Context`: its buffer, the scheme's
reported fields, its cursor, its rows, whether it is selected) to fields.
`modeLine` lists the segments of each side by name, shipped ones
(`ModeLine.shipped`) or the config's own. A name no segment is registered
under is left out, the rest are drawn, and the echo area says so. A config
that lists none has the default order. A `setup` that defines a segment
name twice, or lists the mode line twice, is refused.

Config sets the frame padding in points (`framePadding 12`): how far every
window's text is inset from its edges, the bottom row at least as far as
the window's corners reach. A config that sets none has the editor's 8,
and a reload changes it. Setting it twice is refused.

Config chooses the window layout (`layout`, `Editor/Layout.lean`), as a
value with its parameters, the way it sets the frame padding:
`layout (.masterStack { share := 60, side := .right })`, with main's count
of windows as `count` (`layout (.masterStack { count := 2 })`),
`layout .monocle`, or the manual split layout, `layout Layout.manual`,
whose tree of tiles the window commands grow and which is fitted to the
windows there are. A config that chooses none has master-and-stack with
main taking half on the left (`Layout.default`), and a reload changes it,
rearranging the same windows; a reload that chooses the same layout again
leaves the changes the window commands made. Any of them may be wrapped in
edges, `layout (.edge .left 25 Layout.default)`: the windows docked at an
edge's side share a strip of its size in percent, and the layout inside it
has the rest. Choosing it twice is refused, and so are a master-and-stack
share above 100, an edge above 100 and a side given twice, at any depth
(`Layout.problem?`).

Config chooses when the tab bar is shown (`tabBar`, `Editor/TabBar.lean`):
`tabBar .never` turns it off, `tabBar .always` shows it with one tab too,
and a config that chooses none has it while there are two tabs or more
(`TabBar.Shown.several`). A reload changes it. Choosing it twice is
refused.

Config says where a buffer a command makes is shown with display rules
(`displayRule`, `Editor/DisplayRules.lean`), matched in order on the
buffer's modes, its name and the command that opened it:
`displayRule { mode := some "notes", target := .edge .left }`. With none
the buffer goes to the stack. Nothing about a rule is refused by `setup`:
at install a rule whose target does not exist under the layout config
chose is left out, and the echo area says so.

The window commands are compiled and bound by the Vim scheme under `C-w`
in normal state. A config puts them in every state, insert state included,
with one line that binds the scheme's own table:
`for (keys, name) in Vim.Default.windowKeys do bindKey keys name`. Its
`C-w` prefix then shadows insert state's `C-w`, Vim's word delete, which a
config that binds nothing under `C-w` keeps.

Config keeps the system's standard title bar with `titleBar .standard`, in
place of the themed one, whose paper is the theme's. It is read when the
window opens, so a reload changes it at the next start. Choosing it twice
is refused.

Config chooses where a child's environment comes from
(`Editor/Process/Environment.lean`) with `processEnvironment`, the first
option of the port: `inherited`, no lookup; `mise`, with the absolute path of
the executable or with none, which looks in the usual places; or the
default, `auto`, which a `setup` that does not set it keeps:

```lean
def setup : SetupM Unit := do
  processEnvironment (.mise (some "/opt/homebrew/bin/mise"))
```

A relative path is refused, and so is a second `processEnvironment` in one
`setup`. A reload that installs takes the setting, and drops every
directory's cached environment.

Config sets how long a `:!` or a filter may run before it is killed with
`shellTimeLimit`, in milliseconds (`shellTimeLimit 5000`); with none it is
30 seconds. Setting it twice is refused, and a reload changes it for the
next run.

Config sets how long a text goes unchanged after an edit before it is parsed
whole again with `syntaxRefreshDelay`, in milliseconds
(`syntaxRefreshDelay 250`); with none it is 500 milliseconds
(`Highlight.defaultRefreshDelay`). Each edit's tree is the incremental
reparse, and the whole parse once the text is quiet makes it exact. Setting
it twice is refused, and a reload changes it from the next buffer whose mode
is entered.

Config defines a language with `defineLanguage` (`Editor/Language.lean`):
the file names it is chosen for, its grammar with any query overrides, and
its indent unit. One of a shipped language's name replaces it whole, so
config overrides the shipped Rust entry's highlights query with

```lean
def setup : SetupM Unit := do
  defineLanguage
    { Language.rust with
      syntaxTree := { Language.rust.syntaxTree with highlights := some "(identifier) @variable" } }
```

Config's entries are matched before the shipped ones. Defining a language
name twice, or a pattern that is empty or holds `/`, is refused; a reload's
languages hold from the next file opened.

Config declares a workspace root with `workspace`, for a directory that is
not a repository, or to split one, with the name of the project it belongs
to if it gives one (`Editor/Workspace.lean`):

```lean
def setup : SetupM Unit := do
  workspace "/Users/me/notes"
  workspace "/Users/me/src/mono/tools" (some "tools")
```

A root that is not absolute is refused, and so is one root declared twice.
A reload that installs takes the roots, and bumps the config generation, so
the next file opened asks its directory's workspace again.

Config gives the compile mode what fits a kind of project with
`compileContribution` (`Editor/Compile/Contribution.lean`): a minor mode's
marker files, which turn the mode on in a buffer whose file is under one of
them inside its workspace, its named commands, and its error formats. And
it gives one project, by its identity, its own commands and settings for a
mode with `projectCommands`, so every worktree of that codebase has them:

```lean
def setup : SetupM Unit := do
  compileContribution
    { mode := "make-mode", markers := #["Makefile"]
      commands := #[{ name := "build", line := "make" }, { name := "test", line := "make check" }] }
  projectCommands (.remote "github.com/me/tool") "make-mode" [("lint", "make lint")]
```

Config's contribution of a mode's name replaces a compiled one of that name
whole. A contribution with no marker is refused, and so is one registered
twice or naming a command twice, and project commands given twice for one
project and mode, or naming a command twice.

A request of this port can carry an `EditorM`, which a request of the
editor's own port could not: the setup port is not the port `EditorM` runs
over, so the type does not refer to itself. A job's handler is carried the
same way, inside the job: a `Work` finishes with an `EditorM Unit`, so the
type of a job's result never reaches the registry.

## Adding to the port

A new kind of registration (a subscription, an option) is a
constructor of `SetupRequest` with its case in `SetupRequest.Reply`, and an
operation here that makes the request. It then needs a clause in the
collecting handler (`Config.Registrations.collect`), which is where it
becomes part of what a reload installs, and a check in `ModelTest.setupChecks`,
which is what pins it. Grow the port with requests, not with new ways to run
`setup`.
-/

namespace Editor

/-- What `setup` may ask of the editor: each request registers one thing. -/
inductive SetupRequest where
  /-- Register `run` as the command called `name`. -/
  | command (name : String) (run : EditorM Unit)
  /-- Register `run` as the command called `name`, which is given what it
  was called with (`Editor/Command/Call.lean`). -/
  | commandWith (name : String) (run : Call → EditorM Unit)
  /-- Declare a store: a cell whose value survives a reload
  (`Editor/Store.lean`). -/
  | store (declaration : StoreDeclaration)
  /-- Register the command called `name` over the store called `store`:
  `step` takes the cell's tree to its new tree. -/
  | storeCommand (name : String) (store : String) (step : Value → EditorM Value)
  /-- Register `work` as the job called `name`: given the arguments it is
  started with, a job that finishes with the command that takes its result
  to the editor (`Editor/Job.lean`). -/
  | job (name : String) (work : List Argument → Work)
  /-- Bind the key sequence `keys` to the command called `command`. The
  name is looked up when the keys are typed. -/
  | bind (keys : List Key) (command : String)
  /-- Define the mode `mode`. -/
  | mode (mode : Mode)
  /-- Bind an ex name to a command's name (`Ex.Binding`,
  `Editor/Ex/Line.lean`). The command's name is looked up when a line of
  that name is run. -/
  | ex (binding : Ex.Binding)
  /-- Set the attributes `attributes` sets of the face called `name`, over
  the theme's (`Editor/Face.lean`). -/
  | face (name : FaceName) (attributes : Face)
  /-- Register `named` as a theme, by its name (`Editor/Face.lean`). -/
  | theme (named : NamedTheme)
  /-- Name the theme called `name` as the one in force once the config is
  installed. -/
  | useTheme (name : String)
  /-- Register `segment` as a segment of the mode line, by its name
  (`Editor/ModeLine.lean`). -/
  | segment (segment : Segment)
  /-- List the segments of the mode line, by name, for each side, once the
  config is installed. -/
  | modeLine (order : ModeLine.Order)
  /-- Set the frame padding, in whole points, once the config is installed:
  how far every window's content is inset from its edges, and the bottom
  row at least (`EditorState.paddingOf`). -/
  | framePadding (points : Nat)
  /-- Choose the layout the frame's windows are arranged by, once the config
  is installed (`Editor/Layout.lean`). -/
  | layout (chosen : Layout)
  /-- Choose when the tab bar is shown, once the config is installed
  (`Editor/TabBar.lean`). -/
  | tabBar (shown : TabBar.Shown)
  /-- Choose the title bar the window opens with (`Window.TitleBar`). -/
  | titleBar (style : Window.TitleBar)
  /-- Choose where a child's environment comes from
  (`Editor/Process/Environment.lean`). -/
  | processEnvironment (setting : Process.Setting)
  /-- Set auto-reload on or off (`Editor/Loop.lean`, "Auto-reload"). -/
  | autoReload (on : Bool)
  /-- Declare `root`, an absolute path, a workspace root, of the project
  called `project` when one is given (`Editor/Workspace.lean`). -/
  | workspace (root : System.FilePath) (project : Option String)
  /-- Add `rule` to the display rules, after the ones made before it
  (`Editor/DisplayRules.lean`). -/
  | displayRule (rule : DisplayRule)
  /-- Set how long a `:!` or a filter may run, in milliseconds, before it is
  killed (`Editor/Shell.lean`). -/
  | shellTimeLimit (milliseconds : Nat)
  /-- Set how long a text goes unchanged after an edit, in milliseconds,
  before it is parsed whole again (`Editor/Highlight.lean`). -/
  | syntaxRefreshDelay (milliseconds : Nat)
  /-- Define the language `language`: a name, the file names it is chosen
  for, how its text is parsed and drawn, and its indent unit
  (`Editor/Language.lean`). -/
  | language (language : Language)
  /-- Register `contribution`, what its minor mode gives the compile mode
  (`Editor/Compile/Contribution.lean`). -/
  | compileContribution (contribution : Compile.Contribution)
  /-- Give one project its own commands and settings for a mode
  (`Compile.ProjectCommands`). -/
  | projectCommands (entry : Compile.ProjectCommands)
  /-- Register `source` as a completion source, by its name
  (`Editor/Completion.lean`). -/
  | source (source : Completion.Source)
  /-- Register `style` as a completion style, by its name
  (`Editor/Completion/Style.lean`). -/
  | style (style : Completion.Style)
  /-- Choose the completion style registered under `name` for the prompts of
  `category`, or, with `none`, for every prompt whose category has none
  chosen. -/
  | useStyle (category : Option String) (name : String)
  /-- Register `display` as a completion display, by its name
  (`Editor/Completion/Display.lean`). -/
  | display (display : Completion.Display)
  /-- Choose the completion display registered under `name` for the prompts
  of `category`, or, with `none`, for every prompt whose category has none
  chosen. -/
  | useDisplay (category : Option String) (name : String)

/-- The type of the reply to each request: nothing, for all of them. -/
def SetupRequest.Reply : SetupRequest → Type
  | .command .. => Unit
  | .commandWith .. => Unit
  | .store _ => Unit
  | .storeCommand .. => Unit
  | .job .. => Unit
  | .bind .. => Unit
  | .mode _ => Unit
  | .ex _ => Unit
  | .face .. => Unit
  | .theme _ => Unit
  | .useTheme _ => Unit
  | .segment _ => Unit
  | .modeLine _ => Unit
  | .framePadding _ => Unit
  | .layout _ => Unit
  | .tabBar _ => Unit
  | .titleBar _ => Unit
  | .processEnvironment _ => Unit
  | .autoReload _ => Unit
  | .workspace .. => Unit
  | .displayRule _ => Unit
  | .shellTimeLimit _ => Unit
  | .syntaxRefreshDelay _ => Unit
  | .language _ => Unit
  | .compileContribution _ => Unit
  | .projectCommands _ => Unit
  | .source _ => Unit
  | .style _ => Unit
  | .useStyle .. => Unit
  | .display _ => Unit
  | .useDisplay .. => Unit

/-- The setup port: `SetupRequest` and the reply to each request. -/
abbrev setupPort : Port :=
  { Request := SetupRequest, Reply := SetupRequest.Reply }

/-- The type of `setup`: a program over the setup port that may refuse with a
message. -/
abbrev SetupM :=
  ExceptT String (Program setupPort)

/-- Registers `run` as the command called `name`. -/
def command (name : String) (run : EditorM Unit) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.command name run))

/-- Registers `run` as the command called `name`, which is given what it was
called with (`Call`): the window it acts on, the invocation's arguments and
the keys that yielded it. -/
def commandWith (name : String) (run : Call → EditorM Unit) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.commandWith name run))

/-- Declares `store`: the editor keeps a cell of that name for it, whose value
survives a reload. -/
def Store.declare {α : Type} (store : Store α) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.store store.declaration))

/-- Registers the command called `name` over `store`: `run` takes the store's
value to its new value. The store must be declared in the same `setup`. -/
def Store.command {α : Type} (store : Store α) (name : String) (run : α → EditorM α) :
    SetupM Unit :=
  ExceptT.lift
    (Program.request (port := setupPort) (.storeCommand name store.name (store.step run)))

/-- Registers `run` as the job called `name`, and `handler` as what makes the
command that receives its result. Registering starts nothing: the editor
starts the job when it is asked to, on a pool thread, and runs the command
the handler makes on the editor thread when the job has finished.

`run` is a function, so that none of the job runs before its task exists.
The job takes no arguments: it is the same whatever it is started with. -/
def job {α : Type} (name : String) (run : Unit → JobM α) (handler : α → EditorM Unit) :
    SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.job name fun _ => Work.of run handler))

/-- Registers `run` as the job called `name`, which takes the arguments it
is started with, and `handler` as what makes the command that receives its
result. Registering starts nothing, as for `job`.

`run` is applied to the arguments inside the job, on the job's task: what
is made where the job is started is only the function the task applies, so
none of the job runs before its task exists. -/
def jobWith {α : Type} (name : String) (run : List Argument → JobM α) (handler : α → EditorM Unit) :
    SetupM Unit :=
  ExceptT.lift
    (Program.request (port := setupPort)
      (.job name fun arguments => Work.of (fun _ => run arguments) handler))

/-- Registers the job called `name` that answers a completion source that
answers later (`Editor/Completion/Later.lean`): `answer` is given the query
and a way to deliver a batch of candidates, which it may call as often as it
likes, as its candidates come. A source names it
(`Completion.Source.answeringLater`, registered with `defineSource`); the
editor starts it when a prompt asks that source, and cancels it when the
prompt closes or asks again. -/
def sourceJob (name : String)
    (answer : Completion.Query → (Array Completion.Candidate → JobM Unit) → JobM Unit) :
    SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.job name (Completion.answering answer)))

/-- The message a binding of no keys to the command called `command` is
refused with. -/
def boundToNoKeys (command : String) : String :=
  s!"the command `{command}` is bound to no keys"

/-- Binds the key sequence the key string `keys` names (`Key.parse`:
`"C-x C-s"`) to the command called `command`. The name is looked up when
the keys are typed, so the command need not be one this `setup` registers.

Refuses the `setup` for a key string that is not keys, with the key
parser's reason, which names the stroke, and for one that names no keys. -/
def bindKey (keys : String) (command : String) : SetupM Unit := do
  match Key.parse keys with
  | .error reason =>
    throw reason
  | .ok [] =>
    throw (boundToNoKeys command)
  | .ok chords =>
    ExceptT.lift (Program.request (port := setupPort) (.bind chords command))

/-- The message a binding of the ex name `name` to the command called
`command` is refused with when the ex line cannot read the name back as
itself (`Ex.reachable`): it is empty, holds white space, or starts with
what the line reads as a range or as `!`. -/
def unusableExName (name command : String) : String :=
  s!"the ex name `{name}` of the command `{command}` cannot be typed: it is empty, holds white space, or starts with a range or `!`"

/-- Binds the ex name `name` to the command called `command`: a line of the
ex command line whose first word is `name` runs that command. With
`takes := .text` the rest of the line is the command's first argument, a
string; by default the name takes nothing, and a line with more is refused
when it is run. The command's name is looked up when the line is run, so
the command need not be one this `setup` registers.

Refuses the `setup` for a name the ex line cannot read back as itself
(`Ex.reachable`): one that is empty, holds white space, or starts with `!`,
`%`, `.`, `$`, `,` or a digit, which the line reads as a range or as the
bang form. -/
def exCommand (name command : String) (takes : Ex.Takes := .nothing) : SetupM Unit := do
  if !Ex.reachable name then
    throw (unusableExName name command)
  ExceptT.lift (Program.request (port := setupPort) (.ex { name, command, takes }))

/-- Defines the mode `mode`: its roles and suffixes name commands, looked
up when the keys are typed, so they need not be ones this `setup`
registers. The editor refuses the `setup` for a mode name defined twice and
for a mode with a problem (`Mode.problems`). -/
def defineMode (mode : Mode) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.mode mode))

/-- Sets the attributes `attributes` sets of the face called `name`: each is
over the theme's, and an attribute left unset stays the theme's. It changes
what the face looks like from the first frame after the config is
installed. -/
def face (name : String) (attributes : Face) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.face ⟨name⟩ attributes))

/-- Registers `theme` as the theme called `name`, for this config: a config
can then name it (`useTheme`), and the command that loads a theme lists it.
The editor refuses the `setup` for a theme name defined twice. -/
def defineTheme (name : String) (theme : Theme) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.theme { name, theme }))

/-- Registers `source` as a completion source, for this config, under its
name: a prompt that asks for that name lists what it answers
(`Editor/Completion.lean`). Config's source of a compiled source's name is
used in that one's place. The editor refuses the `setup` for a source name
defined twice. -/
def defineSource (source : Completion.Source) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.source source))

/-- Registers `style` as a completion style, for this config, under its
name (`Editor/Completion/Style.lean`): `useStyle` and `useStyleFor` can
then choose it. Config's style of a compiled style's name is used in that
one's place. The editor refuses the `setup` for a style name defined
twice. -/
def defineStyle (style : Completion.Style) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.style style))

/-- Chooses the completion style registered under `name` as the default:
the style of every prompt whose category has none chosen (`useStyleFor`),
and of one with no category. The name is looked up when the config is
installed; one no style is registered under leaves the fuzzy style and is
said in the echo area. The editor refuses the `setup` for choosing the
default twice. -/
def useStyle (name : String) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.useStyle none name))

/-- Chooses the completion style registered under `name` for the prompts of
`category`. The name is looked up when the config is installed; one no
style is registered under leaves the category to the default and is said
in the echo area. The editor refuses the `setup` for choosing one
category's style twice. -/
def useStyleFor (category name : String) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.useStyle (some category) name))

/-- Registers `display` as a completion display, for this config, under its
name (`Editor/Completion/Display.lean`): `useDisplay` and `useDisplayFor`
can then choose it. Config's display of a compiled display's name is used
in that one's place, so `defineDisplay (Completion.Displays.minibuffer
(rows := n))` sets the rows the minibuffer's list shows. The editor refuses
the `setup` for a display name defined twice. -/
def defineDisplay (display : Completion.Display) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.display display))

/-- Chooses the completion display registered under `name` as the default:
the display of every prompt whose category has none chosen
(`useDisplayFor`), and of one with no category. The name is looked up when
the config is installed; one no display is registered under leaves the
minibuffer display and is said in the echo area. The editor refuses the
`setup` for choosing the default twice. -/
def useDisplay (name : String) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.useDisplay none name))

/-- Chooses the completion display registered under `name` for the prompts
of `category`. The name is looked up when the config is installed; one no
display is registered under leaves the category to the default and is said
in the echo area. The editor refuses the `setup` for choosing one
category's display twice. -/
def useDisplayFor (category name : String) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.useDisplay (some category) name))

/-- Names the theme called `name` as the one in force once the config is
installed: the compiled theme of that name, or one this `setup` defines.
The name is looked up when the config is installed, and a name no theme is
registered under keeps the theme in force and says so in the echo area. The
editor refuses the `setup` for naming a theme twice. -/
def useTheme (name : String) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.useTheme name))

/-- Registers a segment of the mode line called `name`, for this config:
`fields` gives its fields for what a window shows (`ModeLine.Context`), and
none when it has nothing to say. A config can then list it (`modeLine`).
Its fields' sides are the listing's; their faces and paddings are its own.
The editor refuses the `setup` for a segment name defined twice. -/
def defineSegment (name : String) (fields : ModeLine.Context → Array StatusField) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.segment { name, fields }))

/-- Lists the segments of the mode line once the config is installed: `left`
from the row's start and `right` ending at its end, each by its name, a
shipped one (`ModeLine.shipped`) or one this `setup` defines. A name nobody
registered is left out, and the echo area says so; the rest are drawn in
order. A config that lists none has the default order
(`ModeLine.Order.standard`). The editor refuses the `setup` for listing the
mode line twice. -/
def modeLine (left right : List String) : SetupM Unit :=
  ExceptT.lift
    (Program.request (port := setupPort)
      (.modeLine { left := left.toArray, right := right.toArray }))

/-- Sets the frame padding once the config is installed, in whole points
(logical pixels, which the display multiplies by the window's scale): how
far every window's text and its mode line's first and last fields are inset
from its edges, filled with the default face's background. The bottom row,
the echo and a prompt, is inset at least this, and at least as far as the
window's rounded corners reach outside fullscreen. A config that sets none
has the editor's 8 (`Loop.padding`); 0 draws as with no padding. A reload
changes it with no restart. The editor refuses the `setup` for setting the
frame padding twice. -/
def framePadding (points : Nat) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.framePadding points))

/-- Chooses the layout the frame's windows are arranged by once the config
is installed: master-and-stack with main's share, in percent, its side and
main's count (`layout (.masterStack { share := 60, side := .right })`),
monocle, which shows only the selected window (`layout .monocle`), or the
manual split layout (`layout Layout.manual`), fitted to the windows. A config that chooses
none has master-and-stack with main taking half on the left
(`Layout.default`). Any of them may be wrapped in edges, each giving the
windows docked at its side a strip of its size in percent
(`layout (.edge .left 25 Layout.default)`, the outermost cutting first). A
reload changes it with no restart. The editor refuses the `setup` for what
`Layout.problem?` finds, at any depth: a share above 100
(`Layout.shareTooLarge`), an edge above 100 (`Layout.edgeTooLarge`) and a
side given twice (`Layout.edgeTwice`); and for choosing the layout twice. -/
def layout (chosen : Layout) : SetupM Unit := do
  if let some problem := chosen.problem? then
    throw problem
  ExceptT.lift (Program.request (port := setupPort) (.layout chosen))

/-- Chooses when the tab bar is shown once the config is installed
(`Editor/TabBar.lean`): `tabBar .never`, `tabBar .always`, or
`tabBar .several`, the editor's own, while there are two tabs or more. A
reload changes it with no restart. The editor refuses the `setup` for
choosing it twice. -/
def tabBar (shown : TabBar.Shown) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.tabBar shown))

/-- Adds `rule` to the display rules, after the ones made before it: where a
buffer a command shows goes, matched in order on its modes, its name and
the command that asked (`Editor/DisplayRules.lean`), for example
`displayRule { mode := some "notes", target := .edge .left }`. Nothing
about a rule is refused here: at install, a rule whose target the chosen
layout lacks is left out, and the echo area says so. -/
def displayRule (rule : DisplayRule) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.displayRule rule))

/-- Chooses the title bar the window opens with: `titleBar .standard` keeps
the system's standard title bar, above the content, in place of the themed
one, which shows the theme's paper under the window's title and buttons. A
config that chooses none has the themed title bar. It is read when the
window opens, once the start-up config has loaded, so a reload changes it
at the next start. The editor refuses the `setup` for choosing it twice. -/
def titleBar (style : Window.TitleBar) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.titleBar style))

/-- The message a setting of mise's path is refused with when the path is not
absolute. -/
def relativeMise (path : System.FilePath) : String :=
  s!"the path to mise must be absolute: {path}"

/-- Chooses where a child's environment comes from: `inherited`, no lookup;
`mise` with the absolute path of the executable, or with none, which takes
the first of the usual places that exists; or `auto`, the default
(`Editor/Process/Environment.lean`). Refuses the `setup` for a path that is
not absolute. -/
def processEnvironment (setting : Process.Setting) : SetupM Unit := do
  if let .mise (some path) := setting then
    unless path.isAbsolute do
      throw (relativeMise path)
  ExceptT.lift (Program.request (port := setupPort) (.processEnvironment setting))

/-- Turns auto-reload on, or with `false` off. With it on, a follow job
watches each file buffer's file, and a change on disk reloads a buffer with
no unsaved changes, or marks one with them (`Editor/Loop.lean`,
"Auto-reload"). It is off when config says nothing, and a command's choice
(`auto-reload-mode`, the ex names `autoread` and `noautoread`) decides over
it until the editor stops. A second call in one `setup` is refused, as a
second face of one name is. -/
def autoReload (on : Bool := true) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.autoReload on))

/-- Sets how long a `:!` or a filter may run before its child is killed and
the echo area says so, in milliseconds: 30 000 when config says nothing
(`Shell.defaultTimeLimit`, `Editor/Shell.lean`). A reload changes it for
the next run. A second call in one `setup` is refused, as a second frame
padding is. -/
def shellTimeLimit (milliseconds : Nat) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.shellTimeLimit milliseconds))

/-- Sets how long a text parsed with a grammar goes unchanged after an edit,
in milliseconds, before it is parsed whole again: 500 when config says
nothing (`Highlight.defaultRefreshDelay`, `Editor/Highlight.lean`). An
edit's tree is the incremental reparse, and the whole parse once the text
is quiet makes it exact. A reload changes it from the next buffer whose
mode is entered, for every text. A second call in one `setup` is refused,
as a second shell time limit is. -/
def syntaxRefreshDelay (milliseconds : Nat) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.syntaxRefreshDelay milliseconds))

/-- Defines the language `language` (`Editor/Language.lean`): a buffer
opened from a file whose name it matches records it and is put in the
`code` mode, whose text is parsed and drawn as the language says. A
language of a shipped language's name (`Language.shipped`) replaces that
one whole; config's entries are matched before the shipped ones, in the
order config defines them. A reload's languages hold from the next file
opened. The editor refuses the `setup` for a language name defined twice,
and for a pattern no file name can be meant by (`Language.problems`). -/
def defineLanguage (language : Language) : SetupM Unit :=
  ExceptT.lift (Program.request (port := setupPort) (.language language))

/-- The message a workspace root is refused with when it is not absolute. -/
def relativeWorkspace (root : System.FilePath) : String :=
  s!"a workspace root must be absolute: {root}"

/-- Declares `root` a workspace root, of the project called `project` when
one is given, which then identifies it; otherwise the root is its own
project. A file under the root belongs to its workspace whatever git says,
the deepest root winning (`Editor/Workspace.lean`). Refuses the `setup` for
a root that is not absolute, and for a root declared twice. -/
def workspace (root : System.FilePath) (project : Option String := none) : SetupM Unit := do
  unless root.isAbsolute do
    throw (relativeWorkspace root)
  ExceptT.lift (Program.request (port := setupPort) (.workspace root project))

/-- The message a compile contribution with no marker is refused with. -/
def compileWithoutMarkers (mode : String) : String :=
  s!"the compile contribution `{mode}` has no marker"

/-- Registers `contribution`, what the minor mode `contribution.mode` gives
the compile mode: its markers, which turn the mode on in a buffer whose
file is under one of them inside its workspace, its named commands and its
error formats (`Editor/Compile/Contribution.lean`). Config's contribution of
a mode's name replaces a compiled one of that name whole. Refuses the
`setup` for a contribution with no marker; the editor refuses one registered
twice, or naming a command twice. -/
def compileContribution (contribution : Compile.Contribution) : SetupM Unit := do
  if contribution.markers.isEmpty then
    throw (compileWithoutMarkers contribution.mode)
  ExceptT.lift (Program.request (port := setupPort) (.compileContribution contribution))

/-- Gives the project identified by `project` its own `commands`, each a name
and a command line, and `settings` for the minor mode `mode`: the compile
mode reads them by that project's identity from what the loop is told of
config, so every worktree of the codebase has them while the mode is on
there, and no other project does. A command
of a name the mode's contribution gives replaces it; one of a new name comes
after the contribution's. The editor refuses the `setup` for project
commands given twice for one project and mode, or naming a command
twice. -/
def projectCommands (project : Project.Identity) (mode : String) (commands : List (String × String))
    (settings : List (String × Value) := []) : SetupM Unit :=
  ExceptT.lift
    (Program.request (port := setupPort)
      (.projectCommands
        { project, mode, settings
          commands := commands.toArray.map fun (name, line) => { name, line } }))

end Editor
