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
through a private wrapper for either linter.
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

end Lint
