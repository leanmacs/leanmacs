import Compile.Errors
import CompileApi

/-!
# What the compile mode makes of contributions: offers and formats in use

A contribution is what a minor mode gives the compile mode
(`Compile.lean`), as data a package or config registers
(`Contribution`, `ProjectCommands` and the hook the loop is told, `Hook`,
all in `packages/compile-api/CompileApi.lean`, a core module). This module is the
compile mode's: the rules by which it turns the registered contributions
into the commands it offers in a buffer and the error formats it reads a
run's output with. Pure, with no editor API.

## The rules

- **Offers** (`offers`): each on-mode's commands, in on-mode order (nearest
  root first, then registration order), each mode's in its order. A
  command its listing gave at the mode's root of a name the contribution
  already gives replaces it in place; one of a new name comes after the
  contribution's. A project's command of a name already there replaces it
  in place; one of a new name comes after them. An offer runs in its
  command's directory resolved against the mode's root (`resolve`, so an
  absolute one is kept), else in the mode's root. A mode whose contribution is not registered offers
  nothing. An offer is shown as `<name> (<mode>)` (`Offer.candidate`).
- **Choosing** (`chooseOffer`): an answer, trimmed, matches an offer's
  candidate whole first, then a bare command name, the first offer of that
  name.
- **Formats in use** (`formatsOf`): each on-mode's contribution's formats,
  in on-mode order, then `Format.general`. A mode whose contribution is not
  registered, as after a reload that dropped it, gives none.

Pinned by `CompileTest.compileOfferChecks`, pure, and
`CompileTest.compileHookChecks` and `CompileTest.compileListedChecks`, on the
loop's driver.
-/

namespace Editor

namespace Compile

/-- A named command offered in a buffer: its mode, its name, its line and
the mode's root, where it runs. -/
structure Offer where
  /-- The minor mode that gives it. -/
  mode : String
  /-- Its name. -/
  name : String
  /-- Its command line. -/
  line : String
  /-- The mode's root. -/
  root : System.FilePath
  deriving DecidableEq, Repr

/-- How an offer is shown among a prompt's candidates: `<name> (<mode>)`. -/
def Offer.candidate (offer : Offer) : String :=
  s!"{offer.name} ({offer.mode})"

/-- The offer `answer` chooses ("Choosing", in the module docs): the one
whose candidate it is, else the first of its name; none for any other. -/
def chooseOffer (offers : Array Offer) (answer : String) : Option Offer :=
  let answer := answer.trimAscii.toString
  (offers.find? (·.candidate == answer)).orElse fun _ => offers.find? (·.name == answer)

/-- `commands` with each of `project`'s in it: one of a name already there
in its place, one of a new name after them ("Offers", in the module
docs). -/
def withProject (commands project : Array NamedCommand) : Array NamedCommand :=
  project.foldl
    (fun (commands : Array NamedCommand) command =>
      if commands.any (·.name == command.name) then
        commands.map fun kept => if kept.name == command.name then command else kept
      else commands.push command)
    commands

/-- The named commands offered for the on-modes `modes`, given the
registered `contributions`, the project's commands `projects` and the
commands each mode's listing gave at a root, `listed` ("Offers", in the
module docs). -/
def offers (contributions : Array Contribution) (projects : Array ProjectCommands)
    (modes : Array Workspace.OnMode)
    (listed : String → System.FilePath → Array NamedCommand := fun _ _ => #[]) : Array Offer :=
  modes.flatMap fun on =>
    match contributions.find? (·.mode == on.mode) with
    | none => #[]
    | some contribution =>
      let project := (projects.filter (·.mode == on.mode)).flatMap (·.commands)
      (withProject (withProject contribution.commands (listed on.mode on.root)) project).map
        fun command =>
        { mode := on.mode, name := command.name, line := command.line
          root :=
            (command.directory.map fun directory => resolve on.root directory.toString).getD
              on.root }

/-- The error formats in use for the on-modes `modes` ("Formats in use", in
the module docs). -/
def formatsOf (contributions : Array Contribution) (modes : Array Workspace.OnMode) :
    Array Format :=
  (modes.flatMap fun on =>
        ((contributions.find? (·.mode == on.mode)).map (·.formats)).getD #[]).push
    Format.general

end Compile

end Editor
