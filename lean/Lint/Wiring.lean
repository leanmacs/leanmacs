import Lint.Marks

/-!
# The wiring-set linter

`linter.wiringSet`: a test root's checks of the wiring set are selected from
code, by the root's check set (`checks : List (Editor.CheckGroup κ α)`,
`Editor/RealHost.lean`), and this linter holds that selection true and
complete, so a root's normal run and its wiring mode, which the stress
loop runs (`docs/dev-practices/real-thread-checks.md`, "How the set
runs"), select from a list no one keeps by hand. A module of the wiring set is one that
declares `.wiring` or `.contract` (`wiringSet.<module>`, read as
`Lint/Marks.lean` reads it); a check of a root's check type `α` is a
constant whose type, after its binders, is `α` or `List α`.

In a test module (`isTestModule`), it refuses, naming the constant:

- **(t) Tags.** In a check set's `.wired m s f`, `m` is a string literal,
  `s` the constant `wiringSet.<m>` declared in the module `m`, and every
  check `f` applies is declared in `m`; a check declared in a module of the
  wiring set appears only inside a `.wired` group of its own module, never
  in a `.plain` group.
- **(a) Reachable.** Every check declared in a module of the wiring set
  that the check set's module imports under its first name component is
  reached from the check set's `.wired` groups, by unfolding the
  declarations of modules under that component.
- **(u) Once.** No check occurs twice in a check set.
- **(b) No IO producer.** No declaration of a module of the wiring set
  itself has a type, after its binders, of `IO (List T)` for a closed `T`
  (`IO (List String)`, `IO (List (String × Bool))`, `IO (List Check)`),
  unless it has a mark (`<constant>.realHost`): a module's checks are
  leaves that only the check set runs.
- **(c) Through the check set.** A `main` of a root that links the library
  (its imports reach `Editor.Ffi`) references no definition of a module of
  the wiring set under its first name component, but a check set or a
  table of scenarios (`List Editor.Scenario`), directly or through a
  declaration of its module that no other module can name. A type, a
  constructor, a projection or an instance of such a module is data it may
  name.
- **(d) A wiring mode, selected by.** A `main` of a root that links the
  library, whose imports reach a module of the wiring set under its first
  name component, selects its checks by a mode from the shared selection
  (`Editor.CheckGroup.Mode`, `Editor/RealHost.lean`): it references, directly
  or through a declaration of its module that no other module can name, a
  check set, `Editor.CheckGroup.select`, and a shared reader of the mode:
  `Editor.CheckGroup.Mode.ofArguments?` or `Editor.CheckGroup.Mode.read?`,
  which read `--wiring`, or `Editor.CheckGroup.Mode.ofSubcommand?`, which
  reads ffi-test's subcommand `wiring`. A reference to the wiring groups
  alone (`Editor.CheckGroup.wiring`) is no wiring mode, and the mode
  `Editor.CheckGroup.Mode.wiring` named is no reading of it: a root that
  reads `--wiring` itself, and runs the wiring groups or selects by the
  mode it maps it to, is refused.

(c) and (d) hold only a root that links the library: model-test and the
linters' fixtures in it link none, and their `.wiring` declarations are
fixtures, which no gate step or stress round runs
(`ModelTest/Lint/Wiring.lean` pins that it is not refused).

The option defaults to `false`, and our builds turn it on with
`linter.all`, as the other linters'. It is loaded with them as the build's
plugin (`lintPlugin`, `lean/lakefile.lean`); `Lint.lean` imports it, and
no module of the editor or of a package does.

Its checks are `LintTest.lintWiringChecks` (`LintTest/Lint/Wiring.lean`),
run by `lint-test`, and the `#guard_msgs` fixtures of
`ModelTest/Lint/Wiring.lean` and the modules under `ModelTest/Lint/Wiring/`,
and of the fixture package `greeting`'s `GreetingTest/Linked/Lint/Wiring.lean`
and the modules under it, which a build of those modules runs.
-/

open Lean Elab Command

/-- `linter.wiringSet`: hold a root's check set true and complete. -/
register_option linter.wiringSet : Bool :=
  { defValue := false
    descr :=
      "refuse a root's check set (Editor.CheckGroup) whose wired groups miss, misplace or repeat a check of the wiring set, an IO list producer in a module of the wiring set, and a main that reaches the wiring set outside its check set or does not select its checks by the shared wiring mode" }

namespace Lint

/-- The type of a check set's groups (`Editor/RealHost.lean`). This library
imports no module of the editor, so it names the type, and the fixtures
hold the two to one name. -/
def checkGroupType : Name :=
  `Editor.CheckGroup

/-- The constructor of a group of a module of the wiring set. -/
def wiredName : Name :=
  `Editor.CheckGroup.wired

/-- The constructor of a group of other modules' checks. -/
def plainName : Name :=
  `Editor.CheckGroup.plain

/-- What a root selects its check set's checks by its mode with (rule d). -/
def selectName : Name :=
  `Editor.CheckGroup.select

/-- The shared readers of a root's mode (rule d). -/
def modeReaders : Array Name :=
  #[`Editor.CheckGroup.Mode.ofArguments?, `Editor.CheckGroup.Mode.read?,
    `Editor.CheckGroup.Mode.ofSubcommand?]

/-- The type of a scenario of a table (`Editor.Scenario`). -/
def scenarioType : Name :=
  `Editor.Scenario

/-- The modules of the library's bindings: a root that imports one links
the library. -/
def bindingsModule : Name :=
  `Editor.Ffi

/-- `type`'s result: what is left after its binders, without metadata. -/
def resultOf (type : Expr) : Expr :=
  type.getForallBody.consumeMData

/-- The element type of `type`'s result when it is `List e`. -/
def listElement? (type : Expr) : Option Expr :=
  match resultOf type with
  | .app (.const ``List _) element => some element.consumeMData
  | _ => none

/-- The context and check type of a check set's type: its result is
`List (Editor.CheckGroup κ α)`. -/
def checkSetOf? (type : Expr) : Option (Expr × Expr) := do
  let element ← listElement? type
  let .app (.app (.const name _) context) check := element | none
  unless name == checkGroupType do
    none
  return (context.consumeMData, check.consumeMData)

/-- Whether `type`'s result is `List Editor.Scenario`: a table of scenarios. -/
def isScenarioTable (type : Expr) : Bool :=
  (listElement? type).any (·.isConstOf scenarioType)

/-- Whether `type`'s result is `check` or `List check`, with no loose bound
variable: a check, or a list of them, of a root whose check type is
`check`. -/
def isCheckOf (check type : Expr) : Bool :=
  let result := resultOf type
  !result.hasLooseBVars && (result == check || (listElement? type).any (· == check))

/-- Whether `type`'s result is `IO (List T)` for a closed `T`: a producer
that runs checks and hands their outcomes back, which a module of the
wiring set may not declare (rule b). A generic `IO (List β)` is none. -/
def isIoListProducer (type : Expr) : Bool :=
  match resultOf type with
  | .app (.const ``IO _) list =>
    match list.consumeMData with
    | .app (.const ``List _) element => !element.hasLooseBVars
    | _ => false
  | _ => false

/-- One group of a check set's value, as `groupsOf` finds it: a plain
group's checks, or a wired group's module (`none` when it is no string
literal), its set and its checks. -/
inductive Group where
  /-- `.plain checks`. -/
  | plain (checks : Expr)
  /-- `.wired module set checks`. -/
  | wired (module : Option String) (set checks : Expr)
  deriving Inhabited

/-- The groups of a check set's value `value`, in the order they are
written: every application of `Editor.CheckGroup.plain` and `.wired` in it. -/
partial def groupsOf (value : Expr) : Array Group :=
  go value.consumeMData #[]
where
  /-- `groupsOf` over `e`, appending to `found`. -/
  go (e : Expr) (found : Array Group) : Array Group :=
    let function := e.getAppFn.consumeMData
    let arguments := e.getAppArgs
    if function.isConstOf plainName && arguments.size == 3 then found.push (.plain arguments[2]!)
    else
      if function.isConstOf wiredName && arguments.size == 5 then
        let module :=
          match arguments[2]!.consumeMData with
          | .lit (.strVal text) => some text
          | _ => none
        found.push (.wired module arguments[3]!.consumeMData arguments[4]!)
      else
        match e with
        | .app f a => go a.consumeMData (go f found)
        | .lam _ t b _ | .forallE _ t b _ => go b.consumeMData (go t.consumeMData found)
        | .letE _ t v b _ => go b.consumeMData (go v.consumeMData (go t.consumeMData found))
        | .mdata _ b => go b found
        | .proj _ _ b => go b.consumeMData found
        | _ => found

/-- Every constant `e` references, once for each place it is written (no
sharing is collapsed), in order. -/
partial def constantsOf (e : Expr) : Array Name :=
  go e #[]
where
  /-- `constantsOf` over `e`, appending to `found`. -/
  go (e : Expr) (found : Array Name) : Array Name :=
    match e with
    | .const name _ => found.push name
    | .app f a => go a (go f found)
    | .lam _ t b _ | .forallE _ t b _ => go b (go t found)
    | .letE _ t v b _ => go b (go v (go t found))
    | .mdata _ b | .proj _ _ b => go b found
    | _ => found

/-- The module a string literal of a `.wired` group names. -/
def moduleNamed (module : String) : Name :=
  module.toName

/-- What the module `module` declares itself, when the environment holds a
declaration of it that the linters can read (`wiringSet.<module>`, declared
in `module`): `declaredHere?` for a module this one imports. -/
def declaredIn? (env : Environment) (here module : Name) : Option Declared := do
  let name := wiringSetOf module
  let info ← env.find? name
  unless declaringModule env here name == module && info.type.isConstOf wiringSetType do
    none
  decodeWiringSet (← info.value? (allowOpaque := true))

/-- Whether `declared` puts a module's checks in the wiring set: `.wiring`
and `.contract`. -/
def Declared.runsWiring : Declared → Bool
  | .wiring .. | .contract _ => true
  | .edge _ => false

/-- Whether `module` is of the wiring set: it declares `.wiring` or
`.contract`. -/
def isWiringModule (env : Environment) (here module : Name) : Bool :=
  (declaredIn? env here module).any (·.runsWiring)

/-- The first name component of `module`. -/
def firstComponent (module : Name) : Option Name :=
  module.components.head?

/-- Whether `module` is under the first name component `first`. -/
def isUnder (first : Option Name) (module : Name) : Bool :=
  first.isSome && firstComponent module == first

/-- The modules of the wiring set that the module being elaborated imports,
directly or through another, under its own first name component. -/
def importedWiring (env : Environment) (here : Name) : Array Name :=
  env.header.moduleNames.filter fun module =>
    module != here && isUnder (firstComponent here) module && isWiringModule env here module

/-- Whether the module being elaborated links the library: its imports
reach a module of the bindings (`Editor.Ffi` or under it). -/
def linksLibrary (env : Environment) : Bool :=
  env.header.moduleNames.any fun module => bindingsModule.isPrefixOf module

/-- The value of the declaration `name`, and of its implementation when it
is `partial`. -/
def valuesOf (env : Environment) (name : Name) : List Expr :=
  [name, name.str "_unsafe_rec"].filterMap fun name =>
    (env.find? name).bind (·.value? (allowOpaque := true))

/-- Every constant `name`'s value references, and those of the declarations
of this module that no other module can name it references, directly or
through another such (`isLocalHelper`): what a reference to `name`
reaches, the helpers themselves left out. -/
partial def reachedThroughHelpers (env : Environment) (name : Name) : Array Name :=
  (visit name).run' {} |>.run #[] |>.2
where
  /-- Adds what `name` references to the state, skipping what is visited. -/
  visit (name : Name) : StateT NameSet (StateM (Array Name)) Unit := do
    if (← get).contains name then
      return
    modify (·.insert name)
    for value in valuesOf env name do
      for used in value.getUsedConstants do
        if isLocalHelper env used then
          visit used
        else
          modifyThe (Array Name) fun found => if found.contains used then found else found.push used

/-- The declarations reached from `start` by unfolding the values of the
declarations of modules under `first` (and of this module), `start`
included. -/
partial def unfolded (env : Environment) (here : Name) (first : Option Name) (start : Array Name) :
    NameSet :=
  go start.toList {}
where
  /-- Unfolds the names left, skipping those `seen` holds. -/
  go (left : List Name) (seen : NameSet) : NameSet :=
    match left with
    | [] => seen
    | name :: rest =>
      if seen.contains name then go rest seen
      else
        let seen := seen.insert name
        let module := declaringModule env here name
        if module == here || isUnder first module then
          let next :=
            (valuesOf env name).foldl (init := rest) fun next value =>
              value.getUsedConstants.toList ++ next
          go next seen
        else go rest seen

/-- The checks of the check type `check` that `body`, a group's checks,
references, once for each place. -/
def checksIn (env : Environment) (check body : Expr) : Array Name :=
  (constantsOf body).filter fun name => (env.find? name).any fun info => isCheckOf check info.type

/-- The checks of the check type `check` declared in the imported module
`module`, as their declarations are named: an auxiliary declaration (a
`match`'s) left out. -/
def checksDeclaredIn (env : Environment) (module : Name) (check : Expr) : Array Name :=
  match env.getModuleIdx? module with
  | none => #[]
  | some index =>
    match env.header.moduleData[index.toNat]? with
    | none => #[]
    | some data =>
      data.constNames.filter fun name =>
        !name.isInternal && (env.find? name).any fun info => isCheckOf check info.type

/-- The refusals of the check set `name`, of the check type `check`, in the
module `here`, by rules (t), (a) and (u). -/
def checkSetRefusals (env : Environment) (here name : Name) (check value : Expr) : Array String :=
  Id.run do
    let mut refused := #[]
    let groups := groupsOf value
    let first := firstComponent here
    let mut wiredChecks := #[]
    let mut occurrences := #[]
    for group in groups do
      match group with
      | .plain body =>
        for used in checksIn env check body do
          occurrences := occurrences.push used
          let module := declaringModule env here used
          if isWiringModule env here module then
            refused :=
              refused.push
                s!"`{used}` is a check of `{module}`, a module of the wiring set, in a plain group of `{name}`: put it in `.wired \"{module}\" {wiringSetOf module} fun … => …`"
      | .wired none _ _ =>
        refused :=
          refused.push
            s!"a wired group of `{name}` names its module with no string literal: write it as `.wired \"<module>\" wiringSet.<module> fun … => …`"
      | .wired (some written) set body =>
        let module := moduleNamed written
        let declaration := wiringSetOf module
        unless set.isConstOf declaration && declaringModule env here declaration == module do
          refused :=
            refused.push
              s!"the wired group \"{written}\" of `{name}` is tagged with something other than `{declaration}`, the declaration of the module `{written}`: tag it with that constant"
        for used in checksIn env check body do
          occurrences := occurrences.push used
          wiredChecks := wiredChecks.push used
          let declared := declaringModule env here used
          if declared != module then
            refused :=
              refused.push
                s!"`{used}` is a check of `{declared}`, in the wired group \"{written}\" of `{name}`: a wired group holds only its own module's checks"
    -- (u) Once.
    let mut named : NameSet := {}
    let mut twice : NameSet := {}
    for used in occurrences do
      if named.contains used then
        unless twice.contains used do
          twice := twice.insert used
          refused :=
            refused.push s!"`{used}` is in `{name}` twice: a check set runs each check once"
      named := named.insert used
    -- (a) Reachable.
    let reached := unfolded env here first wiredChecks
    for module in importedWiring env here do
      for declared in checksDeclaredIn env module check do
        unless reached.contains declared do
          refused :=
            refused.push
              s!"`{name}` leaves out `{declared}`, a check of `{module}`, a module of the wiring set: run it from a group `.wired \"{module}\" {wiringSetOf module} fun … => …`"
    return refused

/-- Whether `name` is a check set or a table of scenarios: what a `main`
may reach a module of the wiring set through (rule c). -/
def isSelection (env : Environment) (name : Name) : Bool :=
  (env.find? name).any fun info => (checkSetOf? info.type).isSome || isScenarioTable info.type

/-- Whether `name` is a declaration whose reference runs something: a
definition that is no structure's projection and no instance, as a module's
checks, helpers and scenarios are. A type, a constructor, a projection or an
instance of a module of the wiring set is plain data a `main` may name. -/
def runsSomething (env : Environment) (name : Name) : Bool :=
  (env.find? name).any fun info =>
    info.isDefinition && !env.isProjectionFn name && !Meta.isInstanceCore env name

/-- Whether `reached`, what a `main` references, selects a check set's
checks by the shared wiring mode (rule d): a check set (`isSet`),
`selectName`, and a reader of `modeReaders`. -/
def selectsByMode (isSet : Name → Bool) (reached : Array Name) : Bool :=
  reached.any isSet && reached.contains selectName && modeReaders.any reached.contains

/-- The refusals of the `main` named `name`, in the module `here`, by rules
(c) and (d): none for a module that does not link the library. -/
def mainRefusals (env : Environment) (here name : Name) : Array String :=
  Id.run do
    unless linksLibrary env do
      return #[]
    let first := firstComponent here
    let reached := reachedThroughHelpers env name
    let mut refused := #[]
    for used in reached do
      let module := declaringModule env here used
      if
          module != here && isUnder first module && isWiringModule env here module &&
            runsSomething env used &&
            !isSelection env used then
        refused :=
          refused.push
            s!"`{name}` reaches `{used}` of `{module}`, a module of the wiring set, outside a check set: run its checks from the root's check set (`Editor.CheckGroup`), or a scenario from a table of them (`List Editor.Scenario`)"
    let wiring := importedWiring env here
    if !wiring.isEmpty then
      let isSet (used : Name) := (env.find? used).any fun info => (checkSetOf? info.type).isSome
      unless selectsByMode isSet reached do
        refused :=
          refused.push
            s!"`{name}` links the library and its imports reach `{wiring[0]!}`, a module of the wiring set, but it does not select its check set's checks by the shared wiring mode: read the mode with a shared reader (`Editor.CheckGroup.Mode.ofArguments?`, `Editor.CheckGroup.Mode.read?` or `Editor.CheckGroup.Mode.ofSubcommand?`) and run what `Editor.CheckGroup.select` selects by it from a check set"
    return refused

/-- The refusal of the declaration `name` of a module of the wiring set
whose type is `type`, by rule (b), or nothing. -/
def producerRefusal? (env : Environment) (here name : Name) (type : Expr) : Option String :=
  if isIoListProducer type && !env.contains (name.str "realHost") then
    some
      s!"`{privateToUserName name}` of `{here}`, a module of the wiring set, runs checks as an IO list: make its checks a list of the root's check type (`List Check`), which the root's check set runs from its `.wired` group, or mark it a real host"
  else none

/-- `linter.wiringSet`: refuses a check set that misses, misplaces or repeats
a check of the wiring set, an IO list producer of a module of the wiring
set, and a `main` that reaches the wiring set outside a check set or does
not select its checks by the shared wiring mode. -/
def wiringSetLinter : Linter where
  name := `Lint.wiringSetLinter
  run :=
    withSetOptionIn fun _ => do
      unless Linter.getLinterValue linter.wiringSet (← Linter.getLinterOptions) do
        return
      let env ← getEnv
      let here := env.mainModule
      unless isTestModule here do
        return
      let inWiring := (declaredHere? env here).any (·.runsWiring)
      for tree in ← getInfoTrees do
        for (stx, name) in declared tree do
          if name.isInternal then
            continue
          let some info := env.find? name | continue
          if let some (_, check) := checkSetOf? info.type then
            for value in valuesOf env name do
              for refused in checkSetRefusals env here name check value do
                Linter.logLint linter.wiringSet stx m!"{refused}"
          if inWiring then
            if let some refused := producerRefusal? env here name info.type then
              Linter.logLint linter.wiringSet stx m!"{refused}"
          if isMainName name then
            for refused in mainRefusals env here name do
              Linter.logLint linter.wiringSet stx m!"{refused}"

initialize
  addLinter wiringSetLinter

end Lint
