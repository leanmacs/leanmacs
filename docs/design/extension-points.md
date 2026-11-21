# Extension points and interface packages

Status: decided 2026-11-19; **built** in the `features-as-packages`
roadmap's phase 1, which moves no feature yet. Built: the mechanism
(`lean/Editor/Extension.lean`, `SetupRequest.extend`,
`RegistryRequest.extensions`, kept by owner in the registry); the layer
imports check (`tools/layer-imports-check.sh`, over the facet
`editorLayerImports`), with interface packages declared by
`keywords = ["editor-interface"]` in their lakefile; the check that config
elaborated at runtime registers at a compiled package's extension point
(`config-test`); and the decision on reaches by name ("Reaches by name",
below), with its first contract check in the fixture interface package
`greeting-api`. No feature is on the mechanism yet: the roadmap's later
phases move them out on it.

This document says how one package uses what another provides without
importing it, so that any feature moved out of the core can be written again
by someone else, in another way, and put in its place. What a package is,
how a package set is built and what a package may import of the core today
are in [packages.md](packages.md).

## The problem

The packages roadmap moved two features out of the core, the shipped
palettes and the compile mode. The other features are still in the core's
Lake package, and they import one another: files, workspaces, version
control, working sets and buffers import each other in a cycle, the ex line
imports buffers, files and shell, and the core imports evil for the input
scheme ([packages.md](packages.md), "What each feature would have to
cross").

Moving a feature is not enough. If the files feature imports the git
package's modules, nobody can replace the git package without also changing
files. The goal is stronger: **anything moved out can be reimplemented by
someone else, in a different way**. So no package may import an
implementation package's code.

What one feature needs of another must then be an interface that both
depend on and neither owns. Today the only place such an interface can live
is the core. Every registration a package can make is a constructor of the
core's closed `SetupRequest` (`lean/Editor/Setup.lean`), and the compile
mode's own registrations (`compileContribution`, `projectCommands`) are
among them. If every interface had to live in the core, the core would grow
by one protocol for each feature that moves (project roots, a repository's
status, a file's ranges in a working set) and would end up holding the
shape of every feature.

## Prior art

**Emacs** builds completion out of agreements that many packages fill in,
not out of one package:

- *Sources*: `completion-at-point-functions` is a hook. Any package adds a
  function that returns `(start end table . props)`. Eglot, dabbrev and
  cape each add one, and none knows about the others.
- *Matching*: `completion-styles` and `completion-styles-alist`. A style is
  a name and two functions. Orderless adds itself to the alist, and the
  user chooses a style by name.
- *Display*: `completing-read-function` and `completion-in-region-function`
  are slots. Vertico and Corfu each replace one.

`minibuffer.el` defines the agreement. Sources, styles and displays depend
on it and never on each other. `project.el` and `xref.el` go one step
further: each is close to a pure interface package, a set of generic
functions (`project-root`, `xref-backend-definitions`) and a hook that finds
a backend. Eglot provides a backend for both, and anything that uses
projects depends on `project.el`, never on Eglot. The thing that makes this
work is that **any package can open a new extension point**: it `defvar`s a
hook or `cl-defgeneric`s a function, and other packages add to it.

**Vim** shows the failure. Its own slot, `omnifunc`, is one function per
buffer. Neovim's completion then grew around nvim-cmp, whose source API is
part of the cmp implementation, so every source depends on cmp. Replacing
cmp with blink.cmp needed a compatibility shim (`blink.compat`) to keep
cmp's sources working. **An interface that lives inside an implementation
cannot be replaced without replacing its users.**

The editor's completion is already shaped like Emacs's: sources, styles,
displays and at-point sources are records any package can register
(`Completion.Source`, `.Style`, `.Display`, `.AtPoint`), chosen by name with
`useStyle`, `useDisplay` and `useAtPoint`. What it lacks is a way for a
package, and not only the core, to declare a slot of its own.

## Three layers

- **The core** is mechanism: the ports, the state, the loop, commands,
  stores, registration, the config session and the hosts, and the
  extension point mechanism below. It names no feature.
- **An interface package** is a protocol and nothing else: the record types
  that make up the protocol, which are its extension points, and a fake and
  a contract check for each, as every port has (`AGENTS.md`). It registers
  no behaviour.
- **An implementation package** is a feature. It registers values at the
  extension points of the interface packages it implements, and reads the
  values at the extension points it uses.

The import rule:

- A package may import the core's API (as now, [packages.md](packages.md),
  "What a package may import") and interface packages.
- **No package imports an implementation package.** The core imports no
  package.
- An interface package imports only the core's API and other interface
  packages.

So any implementation package can be left out of a set, or replaced by
another that registers at the same extension points, and nothing else in
the set has to change or be rebuilt against it.

- **A package declares its layer in its lakefile**, with Lake's own
  package key `keywords`: an interface package declares
  `keywords = ["editor-interface"]`. Every other package is an
  implementation package, so a missing or misspelt keyword makes a package
  more refused, never less. The core is the core's Lake package. No list
  is kept by hand.
- **The rule holds for every module of a package**, its test modules and
  its linked test included. A test that imported another feature's
  implementation would stop building when that feature is left out; it
  uses the interface package's fake instead.
- **The gate checks the rule on Lake's module graph**
  (`tools/layer-imports-check.sh`; [the-gate.md](../dev-practices/the-gate.md),
  "The layer imports check"), as it checks what a package imports of the
  core (`tools/package-imports-check.sh`). It checks `import` lines; a
  `require` of an implementation package, which only orders registration,
  is not refused yet (the task `layer-requires-check`).

## How an interface is written in Lean

Lean has no `interface` keyword. The editor already uses two ways of
writing one, and an extension point uses the second.

- **A port**: an inductive of requests with a dependent reply type, and a
  program over it that a real handler and a pure model each interpret
  (`Editor/Clipboard.lean`; [lean-runtime.md](lean-runtime.md)). The set of
  ports is closed: the editor's port is their composite
  (`Editor/Command.lean`). That is right for what the core asks of the world
  outside, and wrong for what one package asks of another.
- **A record of functions**: a structure whose fields are programs, of which
  each implementation is a value. `Completion.Style` is one:

  ```lean
  structure Style where
    name : String
    hits : String → Array String → FuzzyM (Array Hit)
  ```

  Many implementations exist at once, as values, and which one runs is
  chosen when the editor runs, not when it is built.

Type classes are not used for interfaces between packages, as the editor
API's decision already says (README, "Lean editor API"). An instance is
resolved when the module that uses it is compiled, so config cannot choose
between implementations, and two packages that give an instance of one
class conflict.

## Extension points

An extension point is a **type**. An interface package declares it by
declaring the record type and deriving `TypeName` for it (Lean's
`Init/Dynamic.lean`):

```lean
-- The interface package `project`.
namespace Project

/-- What finds the project a path is in: the protocol a project backend
implements. -/
structure Finder where
  name : String
  find : System.FilePath → EditorM (Option System.FilePath)
  deriving TypeName

end Project
```

An implementation package registers a value from its `setup`, and a package
that uses the protocol reads every value registered, in a command:

```lean
-- The implementation package `project-git`: it imports the core and `project`.
def setup : SetupM Unit :=
  Extension.add ({ name := "git", find := gitRoot } : Project.Finder)

-- A package that uses projects, files say: it imports the core and
-- `project`, and names no backend.
def projectRoot (path : System.FilePath) : EditorM (Option System.FilePath) := do
  for finder in ← Extension.values Project.Finder do
    if let some root ← finder.find path then return some root
  return none
```

The core's whole API for it is four functions:

| Function | What it does |
|---|---|
| `Extension.add (value : α) : SetupM Unit` | Registers `value` at the extension point `α`, for whoever runs this `setup`: a package or config |
| `Extension.values (α) : EditorM (Array α)` | Every value registered at `α`, in registration order |
| `Extension.named (α) (name : α → String) (wanted : String) : EditorM (Option α)` | The latest value registered at `α` whose name is `wanted` |
| `Extension.workJob (α) (name) (work : Array α → List Argument → Work) (reported restarted) : SetupM Unit` | Registers the job `name` over `α`: each time it is started, its work is `work` applied to every value registered at `α` then, in registration order ("To a job", below) |

### A hook, or a choice

An interface package says, in its docs, which of the two each of its
extension points is:

- **A hook** uses every value, in order (`values`), as Emacs uses
  `completion-at-point-functions`. A package's values come before config's,
  and packages in the order they register (by dependency,
  [packages.md](packages.md), "The order packages register in").
- **A choice** uses one value, by name (`named`), as Emacs uses
  `completing-read-function` and as the editor uses `useStyle`. The latest
  registration of a name wins, so config's value replaces a package's value
  of the same name.

### How the values travel

The mechanism is one generic registration added to the core, taking the
place of a constructor per kind:

- `setup` makes the request `SetupRequest.extend key value`. The key is the
  type's declared name (`TypeName.typeName α`, for example
  `` `Project.Finder ``) and the value is a `Dynamic`, so the core holds
  values of types it has never seen.
- The registry keeps each value with its owner, as it keeps every other
  kind of registration (`Config.Registry.replaceOwned`). A reload of config,
  or a package's registration, replaces that owner's values and leaves the
  others.
- A command asks for the values at a key with a question to the registry
  (`RegistryRequest.extensions key`), answered by the loop from what it was
  told of the registry, and gets them back typed by `Dynamic.get? α`.

A registry reply cannot otherwise hold a program over the editor's port: a
reply type that held `EditorM` would refer to itself, which is why an
at-point source is run through a control request and not handed to the
command (`Editor/Command/Registry.lean`, "The rules"). `Dynamic` is an
opaque `Type`, so a record of `EditorM` functions travels in it, and the
command that reads it runs those functions itself.

#### To a job

A job's work is fixed when it is registered (`workJob`,
`Editor/Setup.lean`), its arguments are plain values, and a running job
(`JobM`) cannot ask the registry. So a job that needs a point's values, such
as a job that asks the version-control backend for a commit, is registered
over the point:

- `Extension.workJob α name work` makes one generic request,
  `SetupRequest.jobOver key name work`, keyed as `extend` is, with the work
  taking the point's values as `Dynamic`s.
- The registry keeps the job as any other, with the point and the function
  beside it (`JobRegistration.over`). Its plain `work` fails at once,
  saying the job is started through `Config.State.work?`, so code that took
  it without the values would fail loudly rather than run with none.
- The work is made where every job's work is made, `Config.State.work?`,
  by one function (`JobRegistration.workWith`): the function applied to the
  values registered at the key when the job starts, in registration order.
  So the job sees config's value once a reload installs it, and the
  package's alone after a reload that drops it.

A source answered later is a job too (`sourceJob` registers
`Completion.answering answer`), so a source's job is registered over a
point the same way. Pinned by `ModelTest.extensionChecks` and
`ModelTest.registryChecks` on the models, and by `ConfigTest.extensionChecks`
with config elaborated at runtime.

### What is checked when the code is built

Because an extension point is a type and not a name someone writes, the
mistakes that would make a registration go nowhere are type errors:

- **A value of the wrong type** cannot be registered at an extension point:
  `Extension.add` registers a value at its own type's extension point, so a
  `MyFinder` goes to `MyFinder`'s and never to `Project.Finder`'s, and a
  function that takes a `Project.Finder` refuses a `MyFinder` with a type
  mismatch.
- **A misspelt extension point** is an unknown identifier.
- **A missing interface package** is a failed import: an implementation
  must `require` the interface package in its lakefile to name its types.

Every value stored under a key is of the type the key names, so
`Dynamic.get?` never fails, and no check at install is needed for it.

`Dynamic.get?` compares a type's declared name, not its fields. That is
sound here because two types of one name and different fields cannot both
exist in an editor: every package of a set is built against the one copy
of each interface package the set's build resolves, Lean refuses two
declarations of one name in a program, and config is elaborated against
the same compiled modules. A type config declares itself can change between
reloads, but config's values are replaced as a set at every install, so no
value of the old type is left.

### What is checked when the editor runs

Two things cannot be types, and are inherent in letting an implementation
be left out:

- **No value registered.** A hook nobody registered at is empty, and the
  code that reads it treats no value as an ordinary case (`projectRoot`
  answers `none`).
- **A choice names a value nobody registered.** It is said in the echo area
  at install, as an unknown completion style is (`unknownStyles`,
  `Editor/Config/Registry.lean`).

### Constraints

- **An extension point's type is a structure of the interface package's
  own**, deriving `TypeName`. A type from elsewhere, `String` for one, has
  no `TypeName` instance and is not a point.
- **One extension point per type.** Two extension points that hold the
  same record need two types.

## What was not chosen

- **Extension points named by hand** (`Extension α` holding a name, made
  as `⟨`project.finders⟩`). The spike's first version. A value of another
  type registered under the name, or a value under a misspelt name, is
  stored and never read, with no message: the reader's `Dynamic.get?`
  leaves it out. Keying by the type removes both mistakes rather than
  reporting them at install.
- **The core owning every interface.** The core would hold the protocol of
  every feature that moves, and a third party's feature could not offer an
  extension point of its own.
- **Bundling the features of a cycle into one package.** Replacing one of
  them would then mean replacing all of them.
- **A global `IO.Ref` per extension point, set by `initialize`**, as Lean's
  own `builtin_initialize` extensions are. Config may not declare
  `initialize` (`Editor/Config/Elaborate.lean`), state kept that way does
  not follow a reload, and it breaks hermetic tests.
- **Stores** ([lean-runtime.md](lean-runtime.md); `Editor/Store.lean`).
  They keep state across a reload by encoding it to a `Value` tree, and a
  record of functions cannot be encoded.
- **`unsafeCast` behind a typed key**, as Lean's `EnvExtension` does.
  `Dynamic.get?` gives the same result with a checked cast.
- **Type classes**, above.

## Evidence

The model tests (`ModelTest.extensionChecks`,
`lean/ModelTest/Editor/Extension.lean`) are laid out as an interface
package, two implementation packages and a consumer, and show:

- values two packages register at an extension point come back typed, in
  registration order, to a consumer that names neither package; swapping
  the packages swaps which answers first;
- a value's fields are programs over the editor's port: the requests a
  consumer's call makes are the editor's;
- with nothing registered, and run bare where no loop dispatched the
  command, a point holds no value;
- a value is registered at its own type's point: another type's value
  does not come back from `Finder`'s, and does from its own;
- a reload replaces config's values and keeps a package's, which come
  first;
- `named` finds config's value of a package's name, the package's again
  after a reload without it, and nothing of a name nobody registered.

`config-test` (`ConfigTest.extensionChecks`,
`lean/ConfigTest/Editor/Extension.lean`, over `lean/ExtensionFixture.lean`)
shows a config elaborated by the running editor registering at a compiled
package's extension point: the compiled package reads config's value typed,
runs its interpreted program, and a reload without the registration leaves
the package's value alone.

A throwaway spike, branch `spike/extension-points`, not landed, first
checked the mechanism with points named by hand, the version rejected
("What was not chosen"), and that a structure of monadic functions derives
`TypeName` and travels in a `Dynamic` both compiled and in Lean's
interpreter.

## Reaches by name

A command named in a key table, a menu, an ex name or the default config is
reached by its name, not by an import. Decided in features-as-packages
phase 1:

**A name another package reaches is part of the contract a replacement must
keep. It is declared in the interface package of the feature that owns it,
and it is not routed through an extension point.**

- **Why not an extension point.** The registry already looks up a command,
  an ex name, a mode or a theme by name when it is used, at a key press, an
  ex line's run or a menu choice, not when code is built. That is the same
  late binding `Extension.named` gives. An extension point per reached
  command would hold the command the registry already holds, and every key
  table would have to name a type per command: two mechanisms for one job.
- **Why it keeps replaceability.** A reach by name is not an import, so
  leaving the package out fails no build. The reach answers as an unknown
  name does today, an ordinary case like an empty hook.
- **Where the contract is written.** An interface package declares each
  name another package may reach as a constant (for example
  `Files.Names.findFile`).
- **How a reacher names it depends on where the reacher is.**
  - **A reacher outside the core names the constant, never the text**: a
    package, or an interface package's consumer. A misspelt name is then an
    unknown identifier at build time, the property extension points are
    keyed by type for.
  - **A reacher still inside the core keeps naming the reached command as
    text**: the Vim scheme's default tables
    (`lean/Editor/InputScheme/Vim/Default.lean`), the menu, the ex names and
    the core's default config (`config/default`). It cannot import the
    interface package, because the core imports no package. **The core →
    interface refusal of the layer imports check stays**: no exception is
    made for name constants.
  - **When a reacher moves out of the core** (evil and the Vim tables in
    phase 7; the ex line, the menu and the default config's reaches in
    phase 8), it switches from text to the constant in the same move. It
    then requires and imports the interface package, which the rule
    allows.
- **How it is enforced.** The interface package publishes a contract check
  (`AGENTS.md`: the owner of a port publishes its fake and its contract
  check), which every implementation runs. It collects the
  implementation's `setup` with the pure collector (`Package.registered`,
  `lean/Editor/Config/Packages.lean`) and checks that the implementation's
  registered names include every name the interface package declares.
  Until the core's reachers move out, this check is what catches a missing
  or renamed command: a command a core table names by text is declared by
  the interface package, so an implementation that drops or renames it
  fails its contract check, though the core's text is not checked at build
  time.
- **A name no interface package declares** is the implementation's own. A
  replacement need not keep it.
- **A user's config** is unaffected, and still names commands as text.
- **Today.** No core module reaches `shipped-themes`, `compile`,
  `mode-line` or `languages` by name (the default config binds
  `load-theme`, a core command; the mode line's listing and the `code`
  mode are names the core declares). The default config does reach two
  default packages' commands, `execute-command` (`SPC :`) and
  `search-bindings` (`SPC ?`), so the features-as-packages roadmap's
  phase 3 built the first two feature interface packages with those
  features' moves: `execute-command-api`
  (`ExecuteCommandApi.executeCommandName`) and `binding-search-api`
  (`BindingSearchApi.searchBindingsName`), each with a fake and a contract
  check its implementation runs (`packages/execute-command-api/`,
  `packages/binding-search-api/`; [packages.md](packages.md), "The
  interface packages `execute-command-api` and `binding-search-api`").
  The default config is in the core until phase 8, so it and its test name
  the two as text. Phase 4 built three more with the moves of completion,
  completion at point and the minibuffer, which the core reaches by name
  (the Vim scheme's insert and minibuffer tables, the command every batch
  of a source's job is posted as, the commands the loop runs at a trigger
  and a pause, and the files package's `path` style):
  `completion-api` (`CompletionApi.pathStyleName`), `at-point-api` (the
  nine `AtPointApi.…Name`) and `minibuffer-api` (the nine
  `MinibufferApi.…Name` and the mode's name `MinibufferApi.modeName`;
  `packages/completion-api/`, `packages/at-point-api/`,
  `packages/minibuffer-api/`; [packages.md](packages.md), "The interface
  packages `completion-api`, `at-point-api` and `minibuffer-api`"). The
  fakes behind the last two are no names-only packages: they are the core
  test kit's own hand-written minibuffer and at-point
  (`Editor.Test.Minibuffer`, `Editor.Test.AtPoint`), which the core's tests
  run on, since the core cannot import an interface package; the
  interfaces' tests hold them to the contract, and the core's tests hold
  the Vim tables' text to the kit's names. The core's reachers name the
  names as text; `compile`, `execute-command` and `binding-search`
  require `minibuffer-api` and name its constants. The fixture
  interface package `greeting-api` (`tests/packages/greeting-api/`) is the
  first to declare a reached name, `greeting-reply`
  (`GreetingApi.replyName`, and every declared name in `GreetingApi.names`),
  and the working example later interface packages follow: its fake
  (`GreetingApiTest.fake`) and its contract check
  (`GreetingApiTest.contractChecks`) are modules of its test library; the
  implementation `greeting` runs the check; the consumer `greeting-loud`
  reaches the name through the constant and tests against the fake; and
  greeting-api's own tests pin the check's failure case, a package that
  lacks the name or misspells it. Each feature's interface package builds
  its own as the feature moves (phases 3 to 8).

## Open questions

- **Order within a hook.** Values come in registration order, which is
  dependency order between Lake packages. Emacs lets a hook function ask to
  run early or late (`add-hook`'s depth). Whether a hook needs that is
  decided when a hook first needs it.
- **The registrations the core already has.** Completion sources, styles,
  displays and at-point sources, and the compile mode's contributions, are
  constructors of `SetupRequest` today. **Styles, displays and at-point
  sources stay registrations of the core's interfaces** (decided in
  features-as-packages phase 4, when completion and at-point moved out):
  they are records any package registers already, the core's loop and
  registry read them, and the roadmap keeps the core's completion
  interfaces in the core. What the loop needs of at-point beyond its
  sources is to run a command at a trigger and at a pause, and the
  registry resolves a command by its name when it runs ("Reaches by
  name"), so the core declares those two names
  (`Completion.AtPoint.triggeredCommand`, `.pausedCommand`) and no
  extension point was added. Whether the compile mode's contributions
  become an extension point of an interface package is still open, and is
  decided as their feature moves.
- **A required extension point.** Running a package's `setup` registers
  nothing in the editor: the handler that collects is pure
  (`Config.Registrations.collect`). So the build of a package set could run
  every package's `setup` and fail when an extension point marked as
  required, such as the input scheme, has no value. The input scheme is
  refused at start-up for now ([packages.md](packages.md), "Input schemes").
