import Editor.Api
import Editor.Command.Call

/-!
# The command that loads a theme

A theme is registered by name, by its owner, as a command is
(`Editor/Config/Registry.lean`, "Themes"), and the theme in force is the
reload reducer's state (`Editor/Config/Reload.lean`). `load-theme` is the
command that switches it, with no reload, written over the editor API
(`themeNames`, `loadTheme`, `Editor/Api.lean`). `Editor.lean` imports this
module, so config calls it. The command as compiled code registers it, and
the themes that ship, are in `Editor/Themes/Compiled.lean`.

- **It asks for a name when it is given none** (`loadThemeCommand`), as the
  ex command asks for its line (`Editor/Ex.lean`). With a string as its
  first argument it loads the theme of that name. With anything else first,
  or nothing, it asks with a prompt labelled `label`, whose continuation is
  `load-theme` itself and whose candidates are the names themes are
  registered under (`themeNames`), which the loop answers from the registry
  as it is when the name is asked for. They come from the completion
  source `themes`, of the category `theme` (`source`,
  `Editor/Completion.lean`), which compiled code registers under its name:
  the prompt asks for the sources of the category `theme`, with `source`
  as its default, so config adds to the list by registering a source in
  `theme` and replaces it by registering one under `themes`.
- **Where the prompt is refused**, because one is open, the echo area says
  so (`notAsking`): the command's name, then the refusal's sentence. The
  open prompt stays.
- **A name no theme is registered under** is refused by the loop, and the
  echo area says so (`notLoaded`): `load-theme: ` and `Theme.unknown`, the
  sentence a reload whose config names it says too. The theme in force
  stays.
- **A registered name is loaded once the command has run to its end.** The
  loop hands the name to its host, which switches the theme in force and
  draws the next scene in it (`Editor/Loop.lean`, "A theme switch from a
  command"). The command says nothing.

Pinned by `ModelTest.themeChecks`, on the loop's driver over the editor's
models and the test scheme; by `ConfigTest.themeChecks`, through a host over
the real binding; and on the executable by the fixture `tests/headless/themes`.
-/

namespace Editor.Themes

/-- The name the command that loads a theme is registered under, Emacs's
name for it. -/
def loadName : String :=
  "load-theme"

/-- The label of the prompt the command asks for a theme's name with. -/
def label : String :=
  "Theme: "

/-- What the echo area says when the command was called with no name and
could not ask for one: the refusal's own sentence, after the command's
name. -/
def notAsking (refusal : PromptRefusal) : String :=
  s!"{loadName}: {refusal.describe}"

/-- What the echo area says when the theme was not loaded: the refusal's
own sentence, after the command's name. -/
def notLoaded (refusal : ThemeRefusal) : String :=
  s!"{loadName}: {refusal.describe}"

/-- The completion source of the names themes are registered under
(`themeNames`), as the loop answers them when it is asked: `themes`, of the
category `theme`. -/
def source : Completion.Source :=
  { name := "themes", category := "theme"
    candidates := fun _ => return (← themeNames).map Completion.Candidate.ofText }

/-- The command that loads a theme, as it is called: loads the theme whose
name is its first argument, a string, and says a refusal in the echo area
(`notLoaded`). With anything else first, or nothing, it asks for the name
(`prompt`, labelled `label`), with itself as the continuation and the
registered themes' names as the candidates (`source`); where the prompt is refused it
says so (`notAsking`). -/
def loadThemeCommand (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str name :: _ =>
    if let .error refusal← loadTheme name then
      message (notLoaded refusal)
  | _ =>
    if let .error refusal←
        prompt label { command := loadName } (sources := [.category "theme" [source]]) then
      message (notAsking refusal)

end Editor.Themes
