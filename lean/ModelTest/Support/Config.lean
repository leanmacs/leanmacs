import Editor.Command
import Editor.Command.Call
import Editor.Config.Owner
import Editor.Config.Registry
import Editor.Face
import Editor.File
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.InputScheme.Vim
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Keymap
import Editor.ModeLine
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Scene
import Editor.State
import Editor.Store
import Editor.Text
import Editor.Text.Model
import Editor.UndoTree
import Editor.Value
import ModelTest.Support.Jobs
import ModelTest.Support.Keys
import ModelTest.Support.Models

/-!
# Model tests: support: Config

Config fixtures: plain registered commands, faces and themes defined by a
config, its bindings, and the loop context a config is elaborated with. Shared
by several test modules under `ModelTest/Editor/`; it holds no checks of its
own.
-/

namespace ModelTest

open Editor

/-- The texts a registered command leaves when it is a plain command, run
against a text model with none; `none` for a command over a store and for
one that is given its call. -/
def plainTexts : Config.Action → Option (Array String)
  | .plain run => some (textsOf run)
  | .store .. => none
  | .call _ => none

/-- How `work` ends when it runs against the job model from a clock at 0 that
nothing cancels, as a check compares it. -/
def worked (work : Work) : Job.Outcome (Array String) :=
  texts ((work ()).runModel {}).1

/-- A store of one number, at version 1. -/
def counter : Store Nat :=
  { name := "counter", version := 1, initial := 0, encode := .nat,
    decode := fun
      | .nat n => some n
      | _ => none }

/-- A face that sets a foreground of the red `red` and nothing else. -/
def coloured (red : UInt8) : Face :=
  { foreground := some (Color.rgb red 0 0) }

/-- The definition of the face `name` as `attributes`. -/
def defined (name : String) (attributes : Face) : FaceDefinition :=
  { name := ⟨name⟩, face := attributes }

/-- A theme of one definition: the face `default` in the red `red`. -/
def oneFace (red : UInt8) : Theme :=
  #[defined "default" (coloured red)]

/-- The theme called `name`, of one definition in the red `red`
(`oneFace`). -/
def namedTheme (name : String) (red : UInt8) : NamedTheme :=
  { name, theme := oneFace red }

/-- The buffer the mode line checks show: `Loop.lean`, opened as
`lean/Editor/Loop.lean`, in the major mode `lean`, modified when `modified`
says. -/
def loopLean (modified : Bool := true) (path : String := "lean/Editor/Loop.lean") : Buffer :=
  let history := UndoTree.new ⟨0⟩ 0
  { name := "Loop.lean", text := ⟨0⟩, history := if modified then history.record 1 else history
    major := some "lean",
    file := some { path, stamp := { seconds := 0, nanoseconds := 0, size := 0 } } }

/-- The context of a window on `buffer` in normal state, its cursor on row
958 at column 4 of 2338 rows, selected when `selected` says. -/
def loopContext (buffer : Buffer := loopLean) (selected : Bool := true) : ModeLine.Context :=
  { buffer, reported := #[{ text := "NORMAL", face := Vim.stateFace "normal" }]
    cursor := some ⟨958, 4⟩, lines := 2338, selected }

/-- A registration of the plain command `name`, which makes the text `text`. -/
def registration (name text : String) : Config.Registration :=
  { name, action := .plain (makes text) }

/-- An owner that is not the config. -/
def other : Config.Owner :=
  { name := "other" }

/-- The binding of the key string `text`, as it is written, placeholders
in place, to the command `command`. -/
def binding (text command : String) : Config.KeyBinding :=
  { keys := strokes text, command }

/-- What the keys the key string `text` names are bound to in the keymap
`registry` makes for the test scheme, whose binding is an invocation. -/
def boundTo (registry : Config.Registry) (text : String) : Option Invocation :=
  (registry.keymap TestScheme.scheme).find? (keys text)

/-- An argument as a check's command writes it. -/
def argumentText : Argument → String
  | .nat value => toString value
  | .int value => toString value
  | .str value => value
  | .bool value => toString value

end ModelTest
