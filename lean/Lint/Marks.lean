import Lean

/-!
# What the mark linters share

The build's linters that read marks (`Lint/Wait.lean`'s
`linter.inferredWait`, `Lint/RealHost.lean`'s `linter.realHost`) read a
command's info trees, never its source text, and look at each constant a
term resolved to. A mark is plain data in the editor's own modules: a
declaration named after the constant it marks. This module holds what both
read through: the references a command's info trees hold, the rule on a
module's name that says it is a test module, the module a constant was
declared in, and the search for the mark a declaration of the module being
elaborated hands on, over any mark (`handedOn?`), so no laundering holds
through a private wrapper for either linter. It also holds how a module
declares itself of the wiring set (`wiringSet.<module>`, `declaredHere?`),
which the real-host linter confines real hosts to, the wait linter counts
beside a mirror as that mirror and the wiring-set linter holds a root's
check set to, so they read one declaration; and which declaration is an
executable's `main`, which the real-host and wiring-set linters both rule.
-/

open Lean Elab

namespace Lint

/-- Whether `module` is a test module: its first name component ends in
`Test` (the four test roots, `FilesApiTest`, a package's `<P>Test`), or it
is `Editor.Test` or under it (the core's test kits). A rule on the module's
name, kept here alone. -/
def isTestModule (module : Name) : Bool :=
  match module.components with
  | first :: rest =>
    first.toString.endsWith "Test" || (first == `Editor && rest.head? == some `Test)
  | [] => false

/-- Whether `name` is an executable's `main`: its last name component is
`main`, at the top level as a root's is, or in a namespace, as a fixture's
must be, beside the test root's own `main`. -/
def isMainName (name : Name) : Bool :=
  match name with
  | .str _ "main" => true
  | _ => false

/-- Every constant a term of `tree` resolved to, and every field a
structure instance of it sets (`{ busy := … }`, `{ kind with busy := … }`)
as its projection, with the syntax it was written at and the declaration it
was written in, once for each place: a term elaborated twice (a `←` lifted
out of an expression) is one reference. The name a declaration is given is
no reference (`declared`). -/
def referenced (tree : InfoTree) : Array (Syntax × Name × Option Name) :=
  let found :=
    tree.foldInfo (init := #[]) fun context info found =>
      match info with
      | .ofTermInfo term =>
        match term.expr.consumeMData with
        | .const name _ =>
          if term.isBinder then found else found.push (term.stx, name, context.parentDecl?)
        | _ => found
      | .ofFieldInfo field => found.push (field.stx, field.projName, context.parentDecl?)
      | _ => found
  found.foldl (init := #[]) fun kept (stx, name, user) =>
    if kept.any fun (other, seen, _) => seen == name && other.getRange? == stx.getRange? then kept
    else kept.push (stx, name, user)

/-- Every constant `tree` declares, with the syntax of the name it is given. -/
def declared (tree : InfoTree) : Array (Syntax × Name) :=
  tree.foldInfo (init := #[]) fun _ info found =>
    match info with
    | .ofTermInfo term =>
      match term.expr.consumeMData with
      | .const name _ => if term.isBinder then found.push (term.stx, name) else found
      | _ => found
    | _ => found

/-- The module `name` was declared in, `here` for one of this module. -/
def declaringModule (env : Environment) (here name : Name) : Name :=
  match env.getModuleIdxFor? name with
  | some index => env.header.moduleNames[index.toNat]?.getD here
  | none => here

/-- Whether `name` is a declaration of the module being elaborated that no
other module can name: a private one, or an auxiliary one (its name
internal, as a `match`'s). A reference to one that hands a mark on
(`handedOn?`) is a reference to that mark. -/
def isLocalHelper (env : Environment) (name : Name) : Bool :=
  env.contains name && (env.getModuleIdxFor? name).isNone && (isPrivateName name || name.isInternal)

/-- The mark the declaration `name` of this module hands on, as `read`
reads a constant's mark (`none` when it has none): the first marked
constant its value references, directly or through a declaration of this
module that no other module can name (`isLocalHelper`), with what `read`
says of it; `none` when it references none. A `partial` declaration's value
is its implementation's (`_unsafe_rec`). So no laundering holds through a
private wrapper: what a private declaration references is what a reference
to it references. -/
partial def handedOn? {α : Type} (read : Name → Option α) (env : Environment) (name : Name) :
    Option (Name × α) :=
  (visit name).run' {}
where
  /-- `handedOn?` of `name`, skipping the declarations the state holds, those already visited. -/
  visit (name : Name) : StateM NameSet (Option (Name × α)) := do
    if (← get).contains name then
      return none
    modify (·.insert name)
    let values :=
      [name, name.str "_unsafe_rec"].filterMap fun name =>
        (env.find? name).bind (·.value? (allowOpaque := true))
    for value in values do
      for used in value.getUsedConstants do
        if let some marked := read used then
          return some (used, marked)
        if isLocalHelper env used then
          if let some found← visit used then
            return some found
    return none

/-- The mark a reference to `name` is, as `read` reads a constant's mark,
with the declaration of this module it is reached through, if any: `name`'s
own mark, or, for a declaration of this module that no other module can
name and that has no mark, the mark it hands on (`handedOn?`). -/
def referencedMark? {α : Type} (read : Name → Option α) (env : Environment) (name : Name) :
    Option (Name × α × Option Name) :=
  match read name with
  | some marked => some (name, marked, none)
  | none =>
    if isLocalHelper env name then
      (handedOn? read env name).map fun (marked, mark) => (marked, mark, some name)
    else none

/-- Why a module may reach marked entry points, as its declaration says
(`Editor.WiringSet`). -/
inductive Declared where
  /-- Its checks wire the real adapter `adapter`, for `why`. -/
  | wiring (adapter why : String)
  /-- It runs `port`'s contract against its real adapter. -/
  | contract (port : String)
  /-- An executable's root, whose `main` wires real adapters, for `why`. -/
  | edge (why : String)
  deriving Inhabited, Repr, BEq

/-- The type of a module's declaration (`Editor/RealHost.lean`). -/
def wiringSetType : Name :=
  `Editor.WiringSet

/-- The name of the declaration of the module `module`:
`wiringSet.<module>`: under a root namespace of its own, `wiringSet`, so the
namespace of no module's own name is made (`ConfigTest.Editor` would
shadow `Editor` in `namespace ConfigTest`). -/
def wiringSetOf (module : Name) : Name :=
  `wiringSet ++ module

/-- The string `value` is written as, when it is a literal that is not
empty. -/
def nonEmptyString? (value : Expr) : Option String :=
  match value.consumeMData with
  | .lit (.strVal text) => if text.isEmpty then none else some text
  | _ => none

/-- What a declaration's value says, when it is one of `wiringSetType`'s
constructors applied to string literals none of which is empty, and nothing
otherwise. -/
def decodeWiringSet (value : Expr) : Option Declared := do
  let value := value.consumeMData
  let .const (.str type kind) _ := value.getAppFn.consumeMData | none
  unless type == wiringSetType do
    none
  let texts ← value.getAppArgs.toList.mapM nonEmptyString?
  match kind, texts with
  | "wiring", [adapter, why] =>
    some (.wiring adapter why)
  | "contract", [port] =>
    some (.contract port)
  | "edge", [why] =>
    some (.edge why)
  | _, _ =>
    none

/-- What the module being elaborated declares itself (`wiringSet.<here>`,
declared in it, of `wiringSetType`, its value as `decodeWiringSet` reads
it), and nothing when it declares nothing the linters can read: what both
linters read a module's membership of the wiring set from. -/
def declaredHere? (env : Environment) (here : Name) : Option Declared := do
  let name := wiringSetOf here
  let info ← env.find? name
  unless (env.getModuleIdxFor? name).isNone && info.type.isConstOf wiringSetType do
    none
  decodeWiringSet (← info.value? (allowOpaque := true))

/-- Whether `declared`, what a module declares itself, is `.wiring`. -/
def Declared.isWiring : Declared → Bool
  | .wiring .. => true
  | _ => false

end Lint
