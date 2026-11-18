import Editor.Api.Cases
import Editor.Buffers.Compiled
import Editor.Clipboard.Contract
import Editor.Clipboard.Model
import Editor.Command.Append
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Compile.Compiled
import Editor.Compile.Shipped
import Editor.Config.Display
import Editor.Config.Reload
import Editor.Display.Contract
import Editor.Display.Model
import Editor.Evil.Compiled
import Editor.Ex.Compiled
import Editor.Ex.Line
import Editor.Executable
import Editor.Face
import Editor.Face.Vocabulary
import Editor.File.Cases
import Editor.File.Model
import Editor.FileWatch.Model
import Editor.Files.Compiled
import Editor.Floating
import Editor.FrameCommands.Compiled
import Editor.Fuzzy.Contract
import Editor.Fuzzy.Model
import Editor.Headless.CommandLine
import Editor.Indent
import Editor.InputScheme.Contract
import Editor.InputScheme.Test
import Editor.InputScheme.Vim.Default
import Editor.Job.Contract
import Editor.Job.Fake
import Editor.Job.Jobs
import Editor.Job.Model
import Editor.Job.Pool
import Editor.Json
import Editor.Key.Notation
import Editor.Language
import Editor.Layout
import Editor.Loop.Driver
import Editor.Menu.Compiled
import Editor.Minibuffer.Compiled
import Editor.Mode
import Editor.ModeLine
import Editor.ModuleLookup
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Role
import Editor.Scene
import Editor.Scroll
import Editor.Shell.Compiled
import Editor.State
import Editor.State.Request
import Editor.SyntaxTree.Contract
import Editor.SyntaxTree.Model
import Editor.TabBar
import Editor.TabCommands.Compiled
import Editor.Text.Contract
import Editor.Themes.Check
import Editor.Themes.Compiled
import Editor.Themes.FairyFloss
import Editor.Themes.Solarized
import Editor.UndoTree.Cases
import Editor.Version
import Editor.Watch.Contract
import Editor.Watch.Model
import Editor.Window
import Editor.WindowCheck
import Editor.WindowCommands.Compiled
import Editor.Workspace.Compiled
import Editor.Workspace.Contract

/-!
# Model tests: the check

The type of one model test, `Check`, and `failures`, which runs a list of
them. Every module of the model tests (`ModelTest/*.lean`) imports this one,
through the chain of imports the root module `ModelTest` describes; this
module carries the `Editor.*` imports the chain needs.
-/

namespace ModelTest

/-- One behaviour, and how to observe it. -/
structure Check where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the behaviour; `true` when it holds. -/
  run : IO Bool

/-- Runs `checks` and returns the names of those that failed. A check that
throws has failed, and its error is reported with its name. -/
def failures (checks : List Check) : IO (List String) :=
  checks.filterMapM fun check => do
    try
      return if ← check.run then none else some check.name
    catch error =>
      return some s!"{check.name} ({error})"

end ModelTest
