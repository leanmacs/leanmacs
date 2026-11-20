import BindingSearch
import BindingSearch.Compiled
import BindingSearchTest.Check
import Editor.Api
import Editor.Command.Call
import Editor.Completion
import Editor.Completion.Candidate
import Editor.Completion.Style
import Editor.Config.Packages
import Editor.Event
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Keymap
import Editor.Loop.Driver
import Editor.Minibuffer
import Editor.State
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Test.Prompts
import Editor.Test.Sources

/-!
# Model tests: `BindingSearch.lean`

The model tests of `BindingSearch.lean`: `bindingSearchChecks`. They were
the core's (`ModelTest.bindingSearchChecks`) while the binding search was
a module of the core, and moved here with their sentences as they were.
The test driver's root, `BindingSearchTest/Model.lean`, runs them.

They run on the core's test kit: the loop's driver (`Editor.Test.Driver`,
`Editor.Test.Loop`), the minibuffer's package as the kit's prompts bring it
(`Editor.Test.Prompts`), and the source contract's runner
(`Editor.Test.Sources`).
-/

namespace BindingSearchTest

open Editor
open Editor.Test

/-- The command `marked` of the binding search's checks: it says `marked`,
then what it was called with (`calledWith`). -/
def searchMarked : Dispatched := fun call => do
  message s!"marked {calledWith call}"
  return none

/-- The commands of the binding search's checks, by name: the commands
compiled code registers for the binding search and for the minibuffer
(`BindingSearch.package.registered.commands`, `Minibuffer.package.registered.commands`), then `marked`
(`searchMarked`). -/
def searchCommands : List (String × Dispatched) :=
  let compiled : List (String × Dispatched) :=
    (BindingSearch.package.registered.commands ++
          Minibuffer.package.registered.commands).toList.filterMap
      fun registration =>
      match registration.action with
      | .call run =>
        some
          (registration.name, fun call => do
            run call
            return none)
      | _ => none
  compiled ++ [("marked", searchMarked)]

/-- What a step of the binding search's checks is handed: one keymap, the
same for every view, that binds `C-e y` to the minibuffer's accept and
`C-c m` to `marked`, described `Mark it`; the commands of `searchCommands`;
and a style that keeps the candidates a text starts, in order, for every
category. No key is bound to `search-bindings`. -/
def searchKeys : Loop.Keys TestScheme.scheme :=
  { maps := fun _ _ =>
      [Keymap.ofDescribed
          [(keys "C-e y", invoke Minibuffer.acceptName, none),
            (keys "C-c m", invoke "marked", some "Mark it")]]
    command? := fun name => (searchCommands.find? (·.1 == name)).map (·.2)
    matching :=
      {
        default :=
          Completion.Style.keeping "starts" fun text candidate => candidate.startsWith text } }

/-- A driver of the binding search's checks over the initial state, with
`keys`; `none` if making the state was refused. -/
def searchDriver (keys : Loop.Keys TestScheme.scheme := searchKeys) : Option TestDriver :=
  (Loop.Driver.over keys (fun _ => none) (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- `driver` after the binding search is called as a step of its own, as a
host's driver runs a command it calls by name with no key. -/
def searching (driver : TestDriver) : TestDriver :=
  (driver.stepped (driver.loop.runNamed driver.handed BindingSearch.name)).1

/-- `driver` after the binding search is called, `typed` is committed into
it and the minibuffer's accept runs. -/
def acceptingBinding (driver : TestDriver) (typed : String) : TestDriver :=
  (fedTo (searching driver) (.commit typed :: presses "C-e y")).1

/-- The keys of the binding search's checks (`searchKeys`) with `C-c s` bound
to `search-bindings` as well, after the others. -/
def keyedSearchKeys : Loop.Keys TestScheme.scheme :=
  { searchKeys with
    maps := fun _ _ =>
      [Keymap.ofDescribed
          [(keys "C-e y", invoke Minibuffer.acceptName, none),
            (keys "C-c m", invoke "marked", some "Mark it"),
            (keys "C-c s", invoke BindingSearch.name, none)]] }

/-- What the prompt open in `driver`'s loop lists: each candidate's text and
annotation; `none` with no prompt open. -/
def promptRows {scheme : InputScheme} (driver : Loop.Driver scheme) :
    Option (Array (String × Option String)) :=
  driver.loop.state.prompt.map fun asking =>
    asking.candidates.all.map fun candidate => (candidate.text, candidate.annotation)

/-- What the binding search lists from `keyedSearchKeys`, by whichever path
it is opened. -/
def keyedSearchRows : Array (String × Option String) :=
  #[("C-e y  minibuffer-accept", none), ("C-c m  marked", some "Mark it"),
    ("C-c s  search-bindings", none)]

/-- The test scheme, but an answer to its question completes the invocation
of the command the answer names: a fake that hands the loop a command an
answer completes, which the Vim scheme, whose answers complete only
motions, never does. -/
def answeringScheme : InputScheme :=
  { TestScheme.scheme with answered := fun _ text state => (state, some { command := text }) }

/-- The keys of `keyedSearchKeys`, for `answeringScheme`. -/
def answeringSearchKeys : Loop.Keys answeringScheme :=
  { maps := keyedSearchKeys.maps
    command? := keyedSearchKeys.command?
    matching := keyedSearchKeys.matching }

/-- A fake style for the binding search's checks: it keeps every candidate,
in reverse order, with no ranges. -/
def reversingBindings : Completion.Style :=
  { name := "reversing"
    hits := fun _ candidates =>
      pure ((Array.range candidates.size).reverse.map Completion.Hit.ofIndex) }

/-- The checks of the binding search (`BindingSearch.lean`,
`BindingSearch/Compiled.lean`), on the loop's driver over the
editor's models and the test scheme: it lists every binding the scheme
reaches with its keys, command and description, runs the one accepted as
its key would, and the style chosen for the category `binding` decides the
order. -/
def bindingSearchChecks : List Check :=
  [{    name :=
          "calling search-bindings opens a prompt labelled with its label whose continuation is the command itself, listing each binding as its keys and command, annotated with its description, of the kind binding"
        run :=
          pure <|
            match searchDriver with
            | none => false
            | some driver =>
              let asking := searching driver
              asking.loop.state.prompt.map (fun asking => (asking.label, asking.continuation)) ==
                  some (BindingSearch.label, { command := BindingSearch.name }) &&
                (candidatesOf asking).map (·.all.map fun c => (c.text, c.annotation, c.kind)) ==
                  some
                    #[("C-e y  minibuffer-accept", none, some "binding"),
                      ("C-c m  marked", some "Mark it", some "binding")] },
      { name :=
          "accepting C-c m  marked runs marked with the keys C-c m and no argument, as pressing C-c m at rest does, and closes the prompt"
        run :=
          pure <|
            match searchDriver with
            | none => false
            | some driver =>
              let accepted := acceptingBinding driver "C-c m  marked"
              let pressed := (fedTo driver (presses "C-c m")).1
              promptEcho accepted == "marked C-c m" && promptEcho accepted == promptEcho pressed &&
                accepted.loop.state.prompt == none },
      { name :=
          "accepting a typed fragment with nothing chosen runs the binding the style lists first for it; a text nothing matches is said and runs nothing; an empty answer says nothing"
        run :=
          pure <|
            match searchDriver with
            | none => false
            | some driver =>
              let fragment := acceptingBinding driver "C-c"
              let unmatched := acceptingBinding driver "zzz"
              let empty := acceptingBinding driver ""
              promptEcho fragment == "marked C-c m" &&
                promptEcho unmatched == BindingSearch.noMatch "zzz" &&
                promptEcho unmatched == "search-bindings: no binding matches `zzz`" &&
                unmatched.loop.state.prompt == none &&
                promptEcho empty == "" &&
                empty.loop.state.prompt == none },
      { name :=
          "calling the binding search while a prompt is open says the refusal after its own name and leaves that prompt open"
        run :=
          pure <|
            match searchDriver with
            | none => false
            | some driver =>
              let again := searching (searching driver)
              promptEcho again == BindingSearch.notAsking (.alreadyOpen ⟨1⟩) &&
                again.loop.state.prompt.map (·.label) == some BindingSearch.label },
      { name :=
          "the style the loop is handed for the category binding decides the order of the binding search's candidates: a fake that reverses lists them in reverse"
        run :=
          pure <|
            let keys : Loop.Keys TestScheme.scheme :=
              { searchKeys with
                matching :=
                  { default := Completion.Style.keeping "all" fun _ _ => true
                    byCategory := fun category =>
                      if category == BindingSearch.category then some reversingBindings
                      else none } }
            match searchDriver keys with
            | none => false
            | some driver =>
              (candidatesOf (searching driver)).map (·.listed.map (·.candidate.text)) ==
                some #["C-c m  marked", "C-e y  minibuffer-accept"] },
      { name :=
          "pressing C-c s, a key bound to search-bindings, lists every binding with its description, as calling it by name does"
        run :=
          pure <|
            match searchDriver keyedSearchKeys with
            | none => false
            | some driver =>
              let named := searching driver
              let pressed := (fedTo driver (presses "C-c s")).1
              promptRows pressed == some keyedSearchRows &&
                promptRows pressed == promptRows named },
      { name :=
          "choosing search-bindings from the menu lists every binding with its description, as calling it by name does"
        run :=
          pure <|
            match searchDriver keyedSearchKeys with
            | none => false
            | some driver =>
              let named := searching driver
              let chosen := (fedTo driver [.menu BindingSearch.name]).1
              promptRows chosen == some keyedSearchRows && promptRows chosen == promptRows named },
      { name :=
          "an answer to the scheme's question that completes search-bindings, from a fake scheme whose answer names the command, lists every binding with its description, as calling it by name does"
        run :=
          pure <|
            match
              (Loop.Driver.over answeringSearchKeys (fun _ => none) (EditorState.initial ⟨640, 480⟩)
                  editorModel).toOption with
            | none => false
            | some driver =>
              let named :=
                (driver.stepped (driver.loop.runNamed driver.handed BindingSearch.name)).1
              let answered :=
                (driver.stepped
                    (driver.loop.invoke driver.handed
                      { command := InputScheme.answerName,
                        arguments := [.str BindingSearch.name] })).1
              promptRows answered == some keyedSearchRows &&
                promptRows answered == promptRows named }] ++
    (sourceHolds BindingSearch.source).map fun (name, held) => { name, run := pure held }

end BindingSearchTest
