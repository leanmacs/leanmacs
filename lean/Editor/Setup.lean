import Editor.Command.Call
import Editor.Ex.Line
import Editor.Face
import Editor.Job
import Editor.Key.Notation
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Store
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
refuses a name that is empty or holds white space, which could not be
typed as a line's first word.

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
  | .titleBar _ => Unit
  | .processEnvironment _ => Unit
  | .autoReload _ => Unit
  | .workspace .. => Unit

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
`command` is refused with when the name is empty or holds white space. -/
def unusableExName (name command : String) : String :=
  s!"the ex name `{name}` of the command `{command}` cannot be typed: it is empty or holds white space"

/-- Binds the ex name `name` to the command called `command`: a line of the
ex command line whose first word is `name` runs that command. With
`takes := .text` the rest of the line is the command's first argument, a
string; by default the name takes nothing, and a line with more is refused
when it is run. The command's name is looked up when the line is run, so
the command need not be one this `setup` registers.

Refuses the `setup` for a name that is empty or holds white space, which
could not be typed as a line's first word. -/
def exCommand (name command : String) (takes : Ex.Takes := .nothing) : SetupM Unit := do
  if name.isEmpty || name.any (·.isWhitespace) then
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

end Editor
