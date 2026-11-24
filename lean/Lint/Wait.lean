import Lint.Marks

/-!
# The wait linters

Lean linters for what a type cannot say about a test's waits
(`docs/dev-practices/inferred-waits.md`; `AGENTS.md`, "Deterministic
concurrency in tests"). Each reads the info trees of the command it lints
and looks at the constant each term resolved to, never at source text, and
logs a lint that `warningAsError` makes an error, so `lake build` fails on
it.

- **`linter.rawClock`**: a call of `IO.sleep`, or a read of
  `IO.monoMsNow` or `IO.monoNanosNow`, in any module but `Editor.Bound`,
  which owns the clock reads a bound needs (`Editor/Bound.lean`). A wait
  takes a `HangGuard`, real time is `RealTime.sleep`, and a measurement of
  real time (a bench, the `--timings` run) says so with
  `set_option linter.rawClock false in` and its reason beside it.

- **`linter.inferredWait`**: a reference to a constant that has a mark
  (`Editor/InferredWait.lean`: a declaration `<constant>.inferredWait` of
  the type `Editor.InferredWait`, its kind applied to a literal list of
  subject modules or to a constant that is one), or a structure instance's field whose projection has
  one: a wait that infers "done" from something shared rather than from a
  signal for its own work, the activity count and idle (`count`, `idle`),
  a "first X after Y" wait another thread's X can satisfy (`firstAfter`),
  or a real service's readout whose fake exists (`realEffect`). It is
  allowed in the constant's own module, in the subject modules its mark
  names, and in a test module that mirrors either (`<Root>.<module>`);
  anywhere else it is refused. A module of the wiring set beside a mirror
  (`<Root>.<module>.Real`, `<Root>.<module>.Real.<Subject>`) mirrors it
  too (`mirrors`). In the own or a subject module, when that is
  a test module, a public declaration that references one must have a mark
  itself, written before it, so a kit cannot hand a restricted wait to
  everyone (no laundering). A declaration of the module that no other
  module can name, a private or an auxiliary one, that references one,
  directly or through another such, is a reference to it wherever it is
  referenced (`referencedMark?`, `Lint/Marks.lean`), so no laundering holds through a private
  wrapper either. A public declaration of an own or subject module that is
  no test module may hand one on: those are the drivers' workings
  (`Round.judge`, `Host.waitWhile`). A site that a later phase removes says so with
  `set_option linter.inferredWait false in` and the row of
  `docs/dev-practices/inferred-waits.md` beside it.

Both options default to `false`, as does the real-host linter's
(`linter.realHost`, `Lint/RealHost.lean`), the build's other linter, which
the same plugin loads; and our builds turn them on with
`linter.all` (`lean/lakefile.lean` and every package's lakefile): config a
user's editor elaborates is never linted.

This module is the library `Lint`'s, outside the editor's library
`Editor`, and imports `Lean`, which no module of the config base or of the
model tests may reach (`docs/design/overview.md`, "Config is elaborated
behind a port, and two adapters link Lean's frontend";
`tools/core-imports-check.sh`, rule 4). So no module imports it: the build
loads the library as a Lean plugin (`lean --plugin`) as it elaborates each
module of the core's libraries and of every package under `packages/` and
`tests/packages/` (`lintPlugin` in `lean/lakefile.lean`, `plugins` in each
package's lakefile), which runs its `initialize` declarations, registering
the two options and the two linters, and leaves no trace in what it
elaborates. A package written as a user's is (`docs/packages/word-count`,
`tests/user-link/package`) names no plugin: the linters hold this
repository's tests to its practice, not a user's package. The marks the linter
reads are plain data in the editor's own modules, so the restricted waits
are marked where they are declared, in one place each.

Its checks are `LintTest.lintWaitChecks` (`LintTest/Lint/Wait.lean`), run
by `lint-test`, and the `#guard_msgs` fixtures of
`ModelTest/Lint/Wait.lean`, `ContractTest/Lint/Wait.lean`,
`ConfigTest/Lint/Wait.lean`, `FfiTest/Lint/Wait.lean` and the fixture
package `greeting`'s `GreetingTest/Lint/Wait.lean`, which a build of those
modules runs. That every library and executable of the core and of the
packages under `packages/` and `tests/packages/` loads the plugin is the
lint plugins check's (`tools/lint-plugins-check.sh`, over Lake's
configuration).
-/

open Lean Elab Command

/-- `linter.rawClock`: refuse a raw clock read outside `Editor.Bound`. -/
register_option linter.rawClock : Bool :=
  { defValue := false
    descr :=
      "refuse a call of IO.sleep or a read of IO.monoMsNow or IO.monoNanosNow outside Editor.Bound: a wait takes a HangGuard and real time is RealTime.sleep" }

/-- `linter.inferredWait`: refuse an inferred wait outside its allowed
modules. -/
register_option linter.inferredWait : Bool :=
  { defValue := false
    descr :=
      "refuse a reference to a constant marked an inferred wait (Editor.InferredWait) outside its own module, its subject modules and the test modules that mirror them" }

namespace Lint

/-- What a marked constant's wait infers "done" from, as its mark says. -/
structure InferredWait where
  /-- `count`, `idle`, `firstAfter` or `realEffect`: the constructor of
  `Editor.InferredWait` the mark applies. -/
  kind : Name
  /-- The modules, beside its own, whose subject the wait is. -/
  subjects : Array Name
  deriving Inhabited, Repr, BEq

/-- The type of a mark (`Editor/InferredWait.lean`). This library imports
no module of the editor, so it names the type, and the fixtures that a
mark makes a lint fire are what hold the two to one name. -/
def markType : Name :=
  `Editor.InferredWait

/-- The name of the mark of the constant `name`: `<name>.inferredWait`. -/
def markOf (name : Name) : Name :=
  name.str "inferredWait"

/-- The mark a mark's value says, when it is one of `markType`'s
constructors applied to a literal list of module names, or to a constant
whose value `resolve` says is one, and nothing otherwise. -/
def decodeMark (resolve : Name → Option Expr) (value : Expr) : Option InferredWait := do
  let .const constructor _ := value.getAppFn | none
  let .str type kind := constructor | none
  unless type == markType do
    none
  let #[subjects] := value.getAppArgs | none
  let subjects :=
    match subjects with
    | .const name _ => (resolve name).getD subjects
    | _ => subjects
  let (_, items) ← subjects.listLit?
  let names ← items.mapM Expr.name?
  return { kind := .mkSimple kind, subjects := names.toArray }

/-- What the mark of `name` says: `none` when `name` has none, an error
when its mark is not of `markType`, or its value is not written as
`decodeMark` reads it. -/
def markedWait? (env : Environment) (name : Name) : Option (Except String InferredWait) := do
  let info ← env.find? (markOf name)
  return do
    unless info.type.isConstOf markType do
      throw s!"`{markOf name}` is named as a mark and is not of the type `{markType}`"
    let some value := info.value? (allowOpaque := true)
      | throw s!"`{markOf name}` is a mark with no value"
    match decodeMark (fun name => (env.find? name).bind (·.value?)) value with
    | some wait =>
      return wait
    | none =>
      throw
          s!"`{markOf name}` is a mark the wait linter cannot read: write its value as a kind applied to a literal list of module names, or to a constant that is one, as `.count [`Editor.Job.Runner]`"

/-- The one module that may read the clock (`Editor/Bound.lean`). -/
def clockModule : Name :=
  `Editor.Bound

/-- The raw clock reads `linter.rawClock` refuses outside `clockModule`. -/
def rawClockReads : List Name :=
  [``IO.sleep, ``IO.monoMsNow, ``IO.monoNanosNow]

/-- Whether `module` is the test module that mirrors `target`: `target`
under a test root, `<Root>.<target>`, as `ModelTest.Editor.Job.Activity`
mirrors `Editor.Job.Activity`; or a module of the wiring set beside that
mirror, `<Root>.<target>.Real` or `<Root>.<target>.Real.<Subject>`, which
holds the mirror's checks over a real adapter that has no module of its
own (`docs/dev-practices/real-thread-checks.md`), as
`ConfigTest.Editor.Headless.Real.Waits` holds `Editor.Headless`'s waits
across a real loop thread. -/
def mirrors (module target : Name) : Bool :=
  match module.components with
  | root :: rest =>
    let target := target.components
    root.toString.endsWith "Test" &&
      (rest == target ||
        (rest.take target.length == target &&
          match rest.drop target.length with
          | [real] | [real, _] => real == `Real
          | _ => false))
  | [] => false

/-- `linter.rawClock`: refuses a raw clock read outside `clockModule`. -/
def rawClockLinter : Linter where
  name := `Lint.rawClockLinter
  run :=
    withSetOptionIn fun _ => do
      unless Linter.getLinterValue linter.rawClock (← Linter.getLinterOptions) do
        return
      if (← getEnv).mainModule == clockModule then
        return
      for tree in ← getInfoTrees do
        for (stx, name, _) in referenced tree do
          if rawClockReads.contains name then
            Linter.logLint linter.rawClock stx
                m!"`{name}` reads the clock: a wait takes a `HangGuard`, real time under test is `RealTime.sleep` (`Editor/Bound.lean`), and a measurement of real time says so with `set_option linter.rawClock false in` and its reason"

initialize
  addLinter rawClockLinter

/-- Whether a reference to a constant declared in `owner`, with the
mark `wait`, is allowed in the module `here`: `owner` itself, a
subject module, or a test module that mirrors one of them. -/
def allowedIn (wait : InferredWait) (owner here : Name) : Bool :=
  let homes := #[owner] ++ wait.subjects
  homes.contains here || homes.any (mirrors here)

/-- Whether a public declaration `user` of the module `here` that
references a constant declared in `owner`, with the mark `wait`, hands it
on (no laundering): `here` is a test module that is `owner` or a subject
module, not a mirror, and `user` is public and has no mark. -/
def launders (env : Environment) (wait : InferredWait) (owner here user : Name) : Bool :=
  isTestModule here && (#[owner] ++ wait.subjects).contains here && !isPrivateName user &&
    !user.isInternal &&
    !env.contains (markOf user)

/-- `linter.inferredWait`: refuses a reference to a marked constant outside
the modules it is allowed in, and a public test-kit declaration that hands
one on unmarked, directly or through a private declaration. -/
def inferredWaitLinter : Linter where
  name := `Lint.inferredWaitLinter
  run :=
    withSetOptionIn fun _ => do
      unless Linter.getLinterValue linter.inferredWait (← Linter.getLinterOptions) do
        return
      let env ← getEnv
      let here := env.mainModule
      for tree in ← getInfoTrees do
        for (stx, referencedName, user) in referenced tree do
          if user == some referencedName then
            continue
          let some (name, marked, through) := referencedMark? (markedWait? env) env referencedName
            | continue
          let via := (through.map fun helper => s!", through `{privateToUserName helper}`").getD ""
          -- A mark it cannot read is refused at each reference written in a
          -- declaration, not at the name a declaration is given.
          let .ok wait := marked
            |
            if let (.error unread, some _) := (marked, user) then
              Linter.logLint linter.inferredWait stx m!"{unread}"
            continue
          let owner := declaringModule env here name
          let homes := #[owner] ++ wait.subjects
          if !allowedIn wait owner here then
            Linter.logLint linter.inferredWait stx
                m!"`{name}`{(user.map fun user => s!", in `{privateToUserName user}`,").getD ""} is an inferred wait ({wait.kind}){via}: it infers done from something shared, not from a signal for this work. It is allowed only in {", ".intercalate (homes.toList.map toString)} and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md"
          else if let some user := user then
            if launders env wait owner here user then
              Linter.logLint linter.inferredWait stx
                  m!"`{user}` is public and hands on `{name}`, an inferred wait ({wait.kind}){via}: mark it, with `def {user}.inferredWait : InferredWait := .{wait.kind} […]` before it, or make it private"

initialize
  addLinter inferredWaitLinter

end Lint
