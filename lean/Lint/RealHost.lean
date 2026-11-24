import Lint.Marks

/-!
# The real-host linter

`linter.realHost`: a check runs a real editor loop thread or a real
background service only in a module of the wiring set (`AGENTS.md`,
"Deterministic concurrency in tests";
`docs/dev-practices/real-thread-checks.md`). What starts one is a constant
with a mark (`Editor/RealHost.lean`: a declaration `<constant>.realHost` of
the type `Editor.RealHost`, `.loop` or `.service`), and a module of the
wiring set declares itself one (`def wiringSet.<module> : Editor.WiringSet`,
`.wiring`, `.contract` or `.edge`). Like the wait linters
(`Lint/Wait.lean`), it reads the info trees of the command it lints and
looks at the constant each term resolved to, never at source text, and logs
a lint that `warningAsError` makes an error, so `lake build` fails on it.

For each reference to a marked constant, or to a declaration of the module
that no other module can name and that hands one on (`referencedMark?`,
`Lint/Marks.lean`), in the module `here`:

1. A module that is no test module (`isTestModule`) may reference one: the
   drivers' workings, whose entry points are marked by hand.
2. A contract root (`isContractRoot`: contract-test) may reference a
   `service` and never a `loop`: an adapter's contract runs no editor loop.
3. A module that declares `.wiring` may reference any; one that declares
   `.contract` a `service` and never a `loop`; one that declares `.edge`
   only in its `main`, or in a private helper of it, which is linted where
   `main` references it. A declaration this linter cannot read refuses
   itself (rule 6) and the module is then treated as declaring none.
4. Any other test module, a kit included, may reference one only inside a
   declaration that has a mark itself, which makes it an entry point the
   rule then holds to. A reference inside a private declaration is linted
   wherever that declaration is referenced, so a private wrapper launders
   nothing.
5. In a module that declares `.wiring` or `.contract`, a public declaration
   that references one, directly or through a private helper, must have a
   mark, be `main`, or be a check (`isCheckType`): a check or a list of them
   can only be run, so it hands no real host on.
6. A `wiringSet` declaration is linted as it is elaborated: it is this
   module's (`wiringSet.<module>`), and its value is a constructor of
   `Editor.WiringSet` applied to string literals none of which is empty
   (`decodeWiringSet`, `Lint/Marks.lean`, which the wait linter reads a
   module's declaration through too). A mark this linter cannot read is refused at each
   reference to the constant it marks.

The option defaults to `false`, and our builds turn it on with `linter.all`,
as the wait linters' (`lean/lakefile.lean` and every package's lakefile).
It is loaded with them as the build's plugin (`lintPlugin`); `Lint.lean`
imports it.

Its checks are `LintTest.lintRealHostChecks` (`LintTest/Lint/RealHost.lean`),
run by `lint-test`, and the `#guard_msgs` fixtures of
`ModelTest/Lint/RealHost.lean`, the modules under `ModelTest/Lint/RealHost/`,
`ConfigTest/Lint/RealHost.lean` and the fixture package `greeting`'s
`GreetingTest/Linked/Lint/RealHost.lean`, which a build of those modules runs.
-/

open Lean Elab Command

/-- `linter.realHost`: refuse a real host or service outside the wiring set. -/
register_option linter.realHost : Bool :=
  { defValue := false
    descr :=
      "refuse a reference to a constant marked a real host or service (Editor.RealHost) in a test module outside the wiring set (Editor.WiringSet), and a public helper of the wiring set that hands one on unmarked" }

namespace Lint

/-- What a marked constant runs, as its mark says (`Editor.RealHost`). -/
inductive Host where
  /-- A real editor loop thread. -/
  | loop
  /-- A real background service, and no loop thread. -/
  | service
  deriving Inhabited, Repr, BEq

/-- The constructor's name a mark of `host` applies, as a message writes it. -/
def Host.name : Host → String
  | .loop => "loop"
  | .service => "service"

/-- What a constant of `host` runs, as a message says it. -/
def Host.runs : Host → String
  | .loop => "a real editor loop thread (loop)"
  | .service => "a real background service (service)"

/-- The type of a mark (`Editor/RealHost.lean`). This library imports no
module of the editor, so it names the type, and the fixtures that a mark
makes a lint fire are what hold the two to one name. -/
def hostType : Name :=
  `Editor.RealHost

/-- The name of the mark of the constant `name`: `<name>.realHost`. -/
def hostMarkOf (name : Name) : Name :=
  name.str "realHost"

/-- What a mark's value says, when it is one of `hostType`'s constructors,
and nothing otherwise. -/
def decodeHost (value : Expr) : Option Host :=
  match value.consumeMData with
  | .const (.str type kind) _ =>
    if type != hostType then none
    else if kind == "loop" then some .loop else if kind == "service" then some .service else none
  | _ => none

/-- Whether `type`, the type of a public declaration, is a check's: after
its binders and any `IO`, `BaseIO` or `List` around the result, a constant
whose last name component is `Check`. A rule on the type's name, kept here
alone: a check, or a list of them, can only be run. -/
partial def isCheckType (type : Expr) : Bool :=
  match type.consumeMData with
  | .forallE _ _ body _ => isCheckType body
  | .app function argument =>
    match function.consumeMData with
    | .const name _ =>
      if name == ``IO || name == ``BaseIO || name == ``List then isCheckType argument else false
    | _ => false
  | .const name _ =>
    match name with
    | .str _ last => last == "Check"
    | _ => false
  | _ => false

/-- Whether `name` is an executable's `main`: its last name component is
`main`, at the top level as a root's is, or in a namespace, as a fixture's
must be, beside the test root's own `main`. -/
def isMainName (name : Name) : Bool :=
  match name with
  | .str _ "main" => true
  | _ => false

/-- Whether `module` is a contract root's: contract-test's, whose checks run
the ports' contracts against their real adapters, outside the rule. -/
def isContractRoot (module : Name) : Bool :=
  module.components.head? == some `ContractTest

/-- What the mark of `name` says: `none` when `name` has none, an error
when its mark is not of `hostType`, or its value is not one of its
constructors. -/
def markedHost? (env : Environment) (name : Name) : Option (Except String Host) := do
  let info ← env.find? (hostMarkOf name)
  return do
    unless info.type.isConstOf hostType do
      throw s!"`{hostMarkOf name}` is named as a mark and is not of the type `{hostType}`"
    let some value := info.value? (allowOpaque := true)
      | throw s!"`{hostMarkOf name}` is a mark with no value"
    match decodeHost value with
    | some host =>
      return host
    | none =>
      throw
          s!"`{hostMarkOf name}` is a mark the real-host linter cannot read: write its value as `.loop` or `.service`"

/-- The fix a refused reference's message names. -/
def wiringFix (here : Name) : String :=
  s!"declare `def {wiringSetOf here} : Editor.WiringSet := .wiring \"…\" \"…\"` in a module that wires the adapter, or run the check on the stepped host and the fakes (AGENTS.md, \"Deterministic concurrency in tests\")"

/-- Lints the declaration `name`, when it is named as a module's declaration
and is of `wiringSetType` (rule 6): the reason it is refused, or nothing. -/
def declarationRefusal? (env : Environment) (here name : Name) : Option String := do
  unless name.components.head? == some `wiringSet do
    none
  let info ← env.find? name
  unless info.type.isConstOf wiringSetType do
    none
  if name != wiringSetOf here then
    return s!"`{privateToUserName name}` names a module's wiring set and is not this module's: a module declares itself as `def {wiringSetOf here} : Editor.WiringSet`"
  match info.value? (allowOpaque := true) >>= decodeWiringSet with
  | some _ =>
    none
  | none =>
    return s!"`{name}` is a wiring set the real-host linter cannot read: write it as a constructor of `{wiringSetType}` applied to string literals none of which is empty, as `.wiring \"the library's diff service\" \"why a fake cannot stand in\"`"

/-- Why the reference in `user`, a declaration of the module `here`, to the
constant `name` marked `host` is refused, by rules 1 to 4, or nothing when
it is allowed. A reference in a private declaration of a test module outside
the wiring set is not linted where it is written: it is linted where that
declaration is referenced. -/
def refusal? (env : Environment) (here : Name) (host : Host) (user : Option Name) : Option String :=
  if !isTestModule here then none
  else
    if isContractRoot here then
      if host == .loop then some "a contract runs no editor loop" else none
    else
      let isPrivateUser := user.any fun user => isLocalHelper env user && isPrivateName user
      match declaredHere? env here with
      | some (.wiring ..) => none
      | some (.contract _) =>
        if host == .loop then
          some s!"`{here}` declares a contract, and a contract runs no editor loop"
        else none
      | some (.edge _) =>
        if isPrivateUser || user.any isMainName then none
        else some s!"`{here}` declares an edge, and only its `main` may reach one"
      | none =>
        if isPrivateUser || user.any fun user => env.contains (hostMarkOf user) then none
        else some s!"a check runs one only in a module of the wiring set: {wiringFix here}"

/-- Whether the public declaration `user` of a module that declares `.wiring`
or `.contract` hands on a mark it references (rule 5): it has no mark, is
not `main`, and is no check. -/
def handsOnHost (env : Environment) (here user : Name) : Bool :=
  let launderRuled :=
    match declaredHere? env here with
    | some (.wiring ..) | some (.contract _) => true
    | _ => false
  launderRuled && isTestModule here && !isContractRoot here && !isPrivateName user &&
    !user.isInternal &&
    !isMainName user &&
    !env.contains (hostMarkOf user) &&
    !((env.find? user).any fun info => isCheckType info.type)

/-- `linter.realHost`: refuses a reference to a real host or service outside
the wiring set, a public helper of the wiring set that hands one on
unmarked, and a declaration of the wiring set it cannot read or that names
another module. -/
def realHostLinter : Linter where
  name := `Lint.realHostLinter
  run :=
    withSetOptionIn fun _ => do
      unless Linter.getLinterValue linter.realHost (← Linter.getLinterOptions) do
        return
      let env ← getEnv
      let here := env.mainModule
      for tree in ← getInfoTrees do
        for (stx, name) in declared tree do
          if let some refused := declarationRefusal? env here name then
            Linter.logLint linter.realHost stx m!"{refused}"
        for (stx, referencedName, user) in referenced tree do
          if user == some referencedName then
            continue
          let some (name, marked, through) := referencedMark? (markedHost? env) env referencedName
            | continue
          let via := (through.map fun helper => s!", through `{privateToUserName helper}`").getD ""
          let inUser := (user.map fun user => s!", in `{privateToUserName user}`,").getD ""
          -- A mark it cannot read is refused at each reference written in a
          -- declaration, not at the name a declaration is given.
          let .ok host := marked
            |
            if let (.error unread, some _) := (marked, user) then
              Linter.logLint linter.realHost stx m!"{unread}"
            continue
          if let some why := refusal? env here host user then
            Linter.logLint linter.realHost stx m!"`{name}`{inUser} runs {host.runs}{via}: {why}"
          else if let some user := user then
            if handsOnHost env here user then
              Linter.logLint linter.realHost stx
                  m!"`{user}` is public and hands on `{name}`, which runs {host.runs}{via}: mark it, with `def {user}.realHost : RealHost := .{host.name}` before it, or make it private"

initialize
  addLinter realHostLinter

end Lint
