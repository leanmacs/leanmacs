import Lean

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

- **`linter.inferredWait`**: a reference to a constant tagged
  `@[inferred_wait <kind> <subject module>*]`, a wait that infers "done"
  from something shared rather than from a signal for its own work: the
  activity count and idle (`count`, `idle`), a "first X after Y" wait
  another thread's X can satisfy (`firstAfter`), or a real service's
  readout whose fake exists (`realEffect`). It is allowed in the constant's
  own module, in the subject modules the attribute names, and in a test
  module that mirrors either (`<Root>.<module>`); anywhere else it is
  refused. In the own or a subject module, when that is a test module, a
  public declaration that references one must carry the attribute itself,
  so a kit cannot hand a restricted wait to everyone (no laundering). A
  site that a later phase removes says so with
  `set_option linter.inferredWait false in` and the row of
  `docs/dev-practices/inferred-waits.md` beside it.

Both options default to `false`, and our builds turn them on with
`linter.all` (`lean/lakefile.lean` and every package's lakefile): config a
user's editor elaborates is never linted.

The linters are active in every module that imports this one, directly or
through another: `Editor.Bound` and `Editor.Job.Activity` do, so every
module that can name a bound or a count wait has them, and so do the
`Check` modules of the four test roots and of the packages, which every
module that writes a check imports. A test library with no `Check` module
(an interface package's, and the fixture packages' under `tests/packages`
and `docs/packages`) reaches it through the modules its driver roots
import, and `EchoTest.Model` imports it itself. A module that imports none
of these is not linted.

Its checks are `ModelTest.lintWaitChecks` and the `#guard_msgs` fixtures of
`ModelTest/Editor/Lint/Wait.lean`.
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
      "refuse a reference to an @[inferred_wait] constant outside its own module, its subject modules and the test modules that mirror them" }

namespace Editor.Lint

/-- What a tagged constant's wait infers "done" from: one of `waitKinds`. -/
structure InferredWait where
  /-- `count`, `idle`, `firstAfter` or `realEffect`. -/
  kind : Name
  /-- The modules, beside its own, whose subject the wait is. -/
  subjects : Array Name
  deriving Inhabited, Repr

/-- The kinds an `@[inferred_wait]` names. -/
def waitKinds : List Name :=
  [`count, `idle, `firstAfter, `realEffect]

/-- `@[inferred_wait <kind> <subject module>*]`. -/
syntax (name := inferred_wait) "inferred_wait " ident (ppSpace ident)* : attr

/-- The `@[inferred_wait]` attribute: a wait that infers "done" from
something shared, with its kind and its subject modules. -/
initialize inferredWaitAttr : ParametricAttribute InferredWait ←
  registerParametricAttribute
      { name := `inferred_wait
        descr :=
          "a wait that infers done from something shared, allowed only in its own module, its subject modules and the test modules that mirror them (linter.inferredWait)"
        getParam := fun _ stx =>
          match stx with
          | `(attr| inferred_wait $kind:ident $subjects:ident*) => do
            unless waitKinds.contains kind.getId do
              throwErrorAt kind
              "an inferred wait's kind is one of count, idle, firstAfter and realEffect"
            return { kind := kind.getId, subjects := subjects.map (·.getId) }
          | _ => throwUnsupportedSyntax }

/-- The one module that may read the clock (`Editor/Bound.lean`). -/
def clockModule : Name :=
  `Editor.Bound

/-- The raw clock reads `linter.rawClock` refuses outside `clockModule`. -/
def rawClockReads : List Name :=
  [``IO.sleep, ``IO.monoMsNow, ``IO.monoNanosNow]

/-- Whether `module` is a test module: its first name component ends in
`Test` (the four test roots, `FilesApiTest`, a package's `<P>Test`), or it
is `Editor.Test` or under it (the core's test kits). A rule on the module's
name, kept here alone. -/
def isTestModule (module : Name) : Bool :=
  match module.components with
  | first :: rest =>
    first.toString.endsWith "Test" || (first == `Editor && rest.head? == some `Test)
  | [] => false

/-- Whether `module` is the test module that mirrors `target`: `target`
under a test root, `<Root>.<target>`, as `ModelTest.Editor.Job.Activity`
mirrors `Editor.Job.Activity`. -/
def mirrors (module target : Name) : Bool :=
  match module.components with
  | root :: rest => root.toString.endsWith "Test" && rest == target.components
  | [] => false

/-- Every constant a term of `tree` resolved to, with the syntax it was
written at and the declaration it was written in, once for each place: a
term elaborated twice (a `←` lifted out of an expression) is one
reference. -/
def referenced (tree : InfoTree) : Array (Syntax × Name × Option Name) :=
  let found :=
    tree.foldInfo (init := #[]) fun context info found =>
      match info with
      | .ofTermInfo term =>
        match term.expr.consumeMData with
        | .const name _ => found.push (term.stx, name, context.parentDecl?)
        | _ => found
      | _ => found
  found.foldl (init := #[]) fun kept (stx, name, user) =>
    if kept.any fun (other, seen, _) => seen == name && other.getRange? == stx.getRange? then kept
    else kept.push (stx, name, user)

/-- `linter.rawClock`: refuses a raw clock read outside `clockModule`. -/
def rawClockLinter : Linter where
  name := `Editor.Lint.rawClockLinter
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

/-- The module `name` was declared in, `here` for one of this module. -/
def declaringModule (env : Environment) (here name : Name) : Name :=
  match env.getModuleIdxFor? name with
  | some index => env.header.moduleNames[index.toNat]?.getD here
  | none => here

/-- Whether a reference to a constant declared in `owner`, with the
attribute `wait`, is allowed in the module `here`: `owner` itself, a
subject module, or a test module that mirrors one of them. -/
def allowedIn (wait : InferredWait) (owner here : Name) : Bool :=
  let homes := #[owner] ++ wait.subjects
  homes.contains here || homes.any (mirrors here)

/-- Whether a public declaration `user` of the module `here` that
references a constant declared in `owner`, with the attribute `wait`, hands
it on (no laundering): `here` is a test module that is `owner` or a subject
module, not a mirror, and `user` is public and untagged. -/
def launders (env : Environment) (wait : InferredWait) (owner here user : Name) : Bool :=
  isTestModule here && (#[owner] ++ wait.subjects).contains here && !isPrivateName user &&
    !user.isInternal &&
    (inferredWaitAttr.getParam? env user).isNone

/-- `linter.inferredWait`: refuses a reference to an `@[inferred_wait]`
constant outside the modules it is allowed in, and a public test-kit
declaration that hands one on untagged. -/
def inferredWaitLinter : Linter where
  name := `Editor.Lint.inferredWaitLinter
  run :=
    withSetOptionIn fun _ => do
      unless Linter.getLinterValue linter.inferredWait (← Linter.getLinterOptions) do
        return
      let env ← getEnv
      let here := env.mainModule
      for tree in ← getInfoTrees do
        for (stx, name, user) in referenced tree do
          let some wait := inferredWaitAttr.getParam? env name | continue
          if user == some name then
            continue
          let owner := declaringModule env here name
          let homes := #[owner] ++ wait.subjects
          if !allowedIn wait owner here then
            Linter.logLint linter.inferredWait stx
                m!"`{name}`{(user.map fun user => s!", in `{user}`,").getD ""} is an inferred wait ({wait.kind}): it infers done from something shared, not from a signal for this work. It is allowed only in {", ".intercalate (homes.toList.map toString)} and the test modules that mirror them; wait on the work's own handle, promise or flush, or, for a site a later phase removes, `set_option linter.inferredWait false in` with its row of docs/dev-practices/inferred-waits.md"
          else if let some user := user then
            if launders env wait owner here user then
              Linter.logLint linter.inferredWait stx
                  m!"`{user}` is public and hands on `{name}`, an inferred wait ({wait.kind}): tag it `@[inferred_wait {wait.kind} …]` or make it private"

initialize
  addLinter inferredWaitLinter

end Editor.Lint
