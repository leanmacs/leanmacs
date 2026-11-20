# Extension points and interface packages

Status: **proposal**, decided 2026-11-19; not built. A throwaway spike
checked the mechanism ("Evidence", below). The `features-as-packages`
roadmap builds it, and moves every feature out of the core on it.

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
the set has to change or be rebuilt against it. The gate checks the rule on
Lake's module graph, as it checks what a package imports of the core today
(`tools/package-imports-check.sh`).

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

The core's whole API for it is three functions:

| Function | What it does |
|---|---|
| `Extension.add (value : α) : SetupM Unit` | Registers `value` at the extension point `α`, for whoever runs this `setup`: a package or config |
| `Extension.values (α) : EditorM (Array α)` | Every value registered at `α`, in registration order |
| `Extension.named (α) (name : α → String) (wanted : String) : EditorM (Option α)` | The latest value registered at `α` whose name is `wanted` |

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

A throwaway spike, branch `spike/extension-points`, not landed, built the
mechanism with points named by hand, the version since rejected. It added
the generic registration (`SetupRequest.extend`, an owner-kept list in the
registry, `RegistryRequest.extensions`) and a module of the three
functions, about 60 lines of core. Its model tests are laid out as an
interface package, two implementation packages and a consumer, and they
show:

- values two packages register at an extension point come back typed, in
  the packages' order, and a consumer that names neither package runs
  them; swapping the packages' order changes which answers first;
- a value's functions are programs over the editor's port: the requests a
  consumer's call makes are the editor's;
- with nothing registered, and where no loop dispatched the command, a
  consumer reads no values;
- a value of another type under the same key, and a value at another key,
  are left out;
- config registers at a package's extension point, `named` finds config's
  value of a package's name, and a reload without config's value brings
  the package's back.

Every model check of the spike's tree passed (2738). A scratch file
showed that a structure of monadic functions derives `TypeName`, travels in
a `Dynamic` both compiled and in Lean's interpreter, and that keying by the
type turns a wrong type and a misspelt point into the build errors above.

Not shown: a config elaborated by the running editor (`config-test`)
registering at a compiled package's extension point, and the rest of the
gate.

## Open questions

- **A config elaborated at runtime.** Both sides go through Lean's compiled
  `Dynamic`, so it is expected to work. `config-test` must show it before
  anything is built on it.
- **Reaches by name.** A command named in a key table, a menu, an ex name or
  the default config is reached by its name, not by an import. Whether a
  command name is part of the contract a replacement must keep, or whether
  such reaches go through extension points too, is still open.
- **Order within a hook.** Values come in registration order, which is
  dependency order between Lake packages. Emacs lets a hook function ask to
  run early or late (`add-hook`'s depth). Whether a hook needs that is
  decided when a hook first needs it.
- **The registrations the core already has.** Completion sources, styles,
  displays and at-point sources, and the compile mode's contributions, are
  constructors of `SetupRequest` today. Whether each becomes an extension
  point of an interface package is decided as its feature moves.
- **A required extension point.** Running a package's `setup` registers
  nothing in the editor: the handler that collects is pure
  (`Config.Registrations.collect`). So the build of a package set could run
  every package's `setup` and fail when an extension point marked as
  required, such as the input scheme, has no value. The input scheme is
  refused at start-up for now ([packages.md](packages.md), "Input schemes").
