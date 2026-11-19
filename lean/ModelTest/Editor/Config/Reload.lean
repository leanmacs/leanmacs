import Editor.Appearance
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Completion.AtPoint
import Editor.Completion.Display
import Editor.Completion.Displays
import Editor.Completion.Style
import Editor.Completion.Styles
import Editor.Completion.Words
import Editor.Config.Diagnostic
import Editor.Config.Display
import Editor.Config.Owner
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.Config.Session
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.Event
import Editor.Ex.Line
import Editor.Face
import Editor.Floating
import Editor.InputScheme
import Editor.Invocation
import Editor.Job
import Editor.Key.Notation
import Editor.Language
import Editor.Layout
import Editor.Loop
import Editor.Menu
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Program
import Editor.ProjectMode
import Editor.ProjectMode.Format
import Editor.Role
import Editor.Scene
import Editor.Setup
import Editor.State
import Editor.Store
import Editor.TabBar
import Editor.Text
import Editor.Text.Model
import Editor.Value
import Editor.Window
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.Config
import ModelTest.Support.Elaborator
import ModelTest.Support.Keys
import ModelTest.Support.Models

/-!
# Model tests: `Editor/Config/Reload.lean`

The model tests of `Editor/Config/Reload.lean`: `reloadChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The state the reducer reaches from `state` through `events`, and every
effect on the way. -/
def reduceFrom (state : Config.State Elaborated) (events : List (Config.Event Elaborated)) :
    Config.State Elaborated × Array Seen :=
  events.foldl
    (fun (state, effects) event =>
      let (state, more) := Config.step state event
      (state, effects ++ more.map seen))
    (state, #[])

/-- The state the reducer reaches through `events` from nothing loaded, and
every effect on the way. -/
def reduce (events : List (Config.Event Elaborated)) : Config.State Elaborated × Array Seen :=
  reduceFrom {} events

/-- A `setup` that registers `greet`, which makes the text `text`. -/
def greets (text : String) : SetupM Unit :=
  command "greet" (makes text)

/-- A `setup` that registers the command `greet` and the job `count`, each of
which makes the text `text`. -/
def counts (text : String) : SetupM Unit := do
  command "greet" (makes text)
  job "count" (fun _ => pure text) makes

/-- The job the editor would start for `name`: its owner's name, and how the
job ends when it runs against the job model; `none` if there is no such job. -/
def startable (state : Config.State Elaborated) (name : String) :
    Option (String × Job.Outcome (Array String)) :=
  (state.work? name).map fun (owner, work) => (owner.name, worked work)

/-- A `setup` that declares `counter` and registers `bump` over it, which
adds `step`. -/
def bumps (step : Nat) : SetupM Unit := do
  counter.declare
  counter.command "bump" fun n => pure (n + step)

/-- Runs the command called `name` the way the editor does, against the
editor's models `model`: the state once what the command wrote is written
back, and the models after it. `none` if there is no such command or it was
refused. -/
def runs (state : Config.State Elaborated) (name : String) (model : EditorModel := editorModel) :
    Option (Config.State Elaborated × EditorModel) :=
  (state.program? name).bind fun program =>
    match program.runModel model with
    | (.ok write, model) => some (state.written write, model)
    | (.error _, _) => none

/-- The texts the command called `name` leaves when the editor runs it. -/
def runTexts (state : Config.State Elaborated) (name : String) : Option (Array String) :=
  (runs state name).map (·.2.texts.contents)

/-- The value of the config's store called `name`. -/
def stored (state : Config.State Elaborated) (name : String) : Option Value :=
  (state.cells.find? .config name).map (·.value)

/-- What a command that is given its call was called with, as one line: its
label, its arguments, and its keys as a key string. -/
def callText (label : String) (call : Call) : String :=
  " ".intercalate (label :: call.arguments.map argumentText ++ [Key.notations call.keys])

/-- A registration of the command `name` that is given its call, and makes a
text of `label` and what it was called with (`callText`). -/
def callRegistration (name label : String) : Config.Registration :=
  { name, action := .call fun call => makes (callText label call) }

/-- Runs the command called `name` the way an invocation does
(`Config.State.command?`), against the editor's models, with a call for the
focused window of a new editor state, `arguments` and the keys `typed`: what
the command asks to write, and the texts after it, the scratch buffer's
first. `none` if there is no such command or it was refused. -/
def calls (state : Config.State Elaborated) (name : String) (arguments : List Argument := [])
    (typed : List Key := []) : Option (Option Config.Write × Array String) :=
  (state.command? name).bind fun run =>
    let program : EditorM (Option Config.Write) := do
      let editor ← EditorState.initial ⟨640, 480⟩
      let some target := editor.focusedTarget? | throw .noSuchText
      run { target, arguments, keys := typed }
    match program.runModel editorModel with
    | (.ok write, model) => some (write, model.texts.contents)
    | (.error _, _) => none

/-- A config state in which compiled code has registered `registrations`,
before any config. -/
def compiledWith (registrations : Array Config.Registration) : Config.State Elaborated :=
  { registry := ({} : Config.Registry).replace .compiled registrations }

/-- The theme `second` of the reducer's checks: one definition of its own. -/
def secondTheme : Theme :=
  oneFace 7

/-- A config state in which compiled code has registered two themes, before
any config: `default`, the built-in one, and `second` (`secondTheme`). -/
def themed : Config.State Elaborated :=
  {
    registry :=
      ({} : Config.Registry).replaceThemes .compiled
        #[{ name := Theme.defaultName, theme := Theme.builtin },
          { name := "second", theme := secondTheme }] }

/-- The report of the reload that finishes with `outcome` from `state`. -/
def reportFrom (state : Config.State Elaborated) (outcome : Config.Outcome Elaborated) :
    Config.Report :=
  (state.install outcome).2

/-- The checks of the reload reducer (`Editor/Config/Reload.lean`), with
outcomes built by hand. -/
def reloadChecks : List Check :=
  [{  name :=
        "an install replaces config's at-point sources and uses; its report names each at-point source a use names that nobody registered, which the echo area says after the displays' sentences; a later install that makes none clears them"
      run :=
        let shown : Config.State Elaborated :=
          { themed with
            registry := themed.registry.replaceAtPoints .compiled Completion.AtPoint.shipped }
        let uses : SetupM Unit := do
          defineAtPoint (Completion.AtPoint.silent "mine")
          useAtPoint "mine"
          useAtPointIn "lean" "nope"
          useDisplay "gone"
        let (state, _) := reduceFrom shown [.requested, .finished (accepted ["a"] uses)]
        let report := reportFrom shown (accepted ["a"] uses)
        let (dropped, _) := reduceFrom state [.requested, .finished (accepted ["a"] (pure ()))]
        pure
          (state.registry.atPointUses.map (fun use => (use.mode, use.source)) ==
              #[(none, "mine"), (some "lean", "nope")] &&
            (state.registry.atPoint? "mine").isSome &&
            report.unknownAtPoints == #["nope"] &&
            report.echo ==
              some
                "reload: no completion display is registered under `gone`; no at-point completion source is registered under `nope`" &&
            dropped.registry.atPointUses.isEmpty &&
            (dropped.registry.atPoint? "mine").isNone &&
            (dropped.registry.atPoint? "words").isSome &&
            (reportFrom state (accepted ["a"] (pure ()))).unknownAtPoints == #[]) },
    { name :=
        "an install sets the title bar config chooses, a later install that chooses none goes back to none, the themed one, and a rejected one changes nothing"
      run :=
        let (state, _) :=
          reduceFrom themed [.requested, .finished (accepted ["a"] (titleBar .standard))]
        let (dropped, _) := reduceFrom state [.requested, .finished (accepted ["a"] (pure ()))]
        let (kept, _) := reduceFrom state [.requested, .finished (rejected "a")]
        pure
          (themed.titleBar == none && state.titleBar == some .standard &&
            dropped.titleBar == none &&
            kept.titleBar == some .standard) },
    { name :=
        "the window opens with the title bar the start-up config chose once its reload has finished, themed when it chose none, and themed when the wait ran out before the reload finished, whatever was installed by then"
      run :=
        pure
          (Window.titleBarAtOpen true (some .standard) == .standard &&
            Window.titleBarAtOpen true (some .themed) == .themed &&
            Window.titleBarAtOpen true none == .themed &&
            Window.titleBarAtOpen false (some .standard) == .themed &&
            Window.titleBarAtOpen false none == .themed) },
    { name :=
        "an install sets the frame padding config sets, a later install that sets none goes back to none, the editor's own, and a rejected one changes nothing"
      run :=
        let (state, _) :=
          reduceFrom themed [.requested, .finished (accepted ["a"] (framePadding 12))]
        let (dropped, _) := reduceFrom state [.requested, .finished (accepted ["a"] (pure ()))]
        let (kept, _) := reduceFrom state [.requested, .finished (rejected "a")]
        pure
          (themed.framePadding == none && state.framePadding == some 12 &&
            dropped.framePadding == none &&
            kept.framePadding == some 12) },
    { name :=
        "an install sets the key hint delay config sets, a later install that sets none goes back to none, the editor's own, and a rejected one changes nothing"
      run :=
        let (state, _) :=
          reduceFrom themed [.requested, .finished (accepted ["a"] (keyHintDelay .never))]
        let (dropped, _) := reduceFrom state [.requested, .finished (accepted ["a"] (pure ()))]
        let (kept, _) := reduceFrom state [.requested, .finished (rejected "a")]
        pure
          (themed.keyHintDelay == none && state.keyHintDelay == some .never &&
            dropped.keyHintDelay == none &&
            kept.keyHintDelay == some .never) },
    { name :=
        "an install sets when the tab bar is shown as config chooses, a later install that chooses none goes back to none, the editor's own, and a rejected one changes nothing"
      run :=
        let (state, _) := reduceFrom themed [.requested, .finished (accepted ["a"] (tabBar .never))]
        let (dropped, _) := reduceFrom state [.requested, .finished (accepted ["a"] (pure ()))]
        let (kept, _) := reduceFrom state [.requested, .finished (rejected "a")]
        pure
          (themed.tabBar == none && state.tabBar == some .never && dropped.tabBar == none &&
            kept.tabBar == some .never) },
    { name :=
        "an install sets the layout config chooses, a later install that chooses none goes back to none, the editor's own, and a rejected one changes nothing"
      run :=
        let (state, _) :=
          reduceFrom themed [.requested, .finished (accepted ["a"] (layout .monocle))]
        let (dropped, _) := reduceFrom state [.requested, .finished (accepted ["a"] (pure ()))]
        let (kept, _) := reduceFrom state [.requested, .finished (rejected "a")]
        pure
          (themed.layout == none && state.layout == some .monocle && dropped.layout == none &&
            kept.layout == some .monocle) },
    { name :=
        "criterion 4, in the model: an install whose display rules name a float, a left edge the default layout lacks, a new tab and a right edge it lacks too is installed and keeps the float's and the new tab's, its report says each rule left out, by its place in the setup, and the echo area says them; under a layout with a left edge the float's, the left edge's and the new tab's rules are kept; a later install with no rule clears them, and a rejected one changes nothing"
      run :=
        let rules : Array DisplayRule :=
          #[{ opener := some "a", target := .float }, { name := some "b", target := .edge .left },
            { target := .newTab }, { target := .edge .right }]
        let ruled : SetupM Unit := rules.forM displayRule
        let edged : SetupM Unit := do
          layout (.edge .left 25 Layout.default)
          ruled
        let report := reportFrom themed (accepted ["a"] ruled)
        let (state, _) := reduceFrom themed [.requested, .finished (accepted ["a"] ruled)]
        let (left, _) := reduceFrom themed [.requested, .finished (accepted ["a"] edged)]
        let (dropped, _) := reduceFrom left [.requested, .finished (accepted ["a"] (pure ()))]
        let (kept, _) := reduceFrom left [.requested, .finished (rejected "a")]
        let both : SetupM Unit := do
          useTheme "gone"
          displayRule { target := .edge .right }
        pure
          (report.installed &&
            state.registry.displayRules ==
              #[{ opener := some "a", target := .float }, { target := .newTab }] &&
            report.unusableRules ==
              #[Config.Report.leftOut 2 (Layout.noEdge .left),
                Config.Report.leftOut 4 (Layout.noEdge .right)] &&
            report.echo ==
              some
                "reload: display rule 2 is left out: the layout has no left edge; display rule 4 is left out: the layout has no right edge" &&
            left.registry.displayRules ==
              #[{ opener := some "a", target := .float },
                { name := some "b", target := .edge .left }, { target := .newTab }] &&
            (reportFrom themed (accepted ["a"] edged)).unusableRules ==
              #[Config.Report.leftOut 4 (Layout.noEdge .right)] &&
            left.registry.registered.displayRules == left.registry.displayRules &&
            dropped.registry.displayRules == #[] &&
            kept.registry.displayRules == left.registry.displayRules &&
            (reportFrom themed (accepted ["a"] both)).echo ==
              some
                "reload: no theme is registered as `gone`; display rule 1 is left out: the layout has no right edge" &&
            (reportFrom themed (accepted ["a"] (displayRule { target := .stack }))).echo == none) },
    { name :=
        "an install sets the mode line config lists, and its report names each segment nobody registered, which the echo area says after the unknown theme's sentence; a later install that lists none goes back to the default, and a rejected one changes nothing"
      run :=
        let listed : SetupM Unit := modeLine ["state", "nope"] ["position"]
        let both : SetupM Unit := do
          useTheme "gone"
          modeLine ["state", "nope", "nope"] ["lost"]
        let segmented : Config.State Elaborated :=
          { themed with registry := themed.registry.replaceSegments .compiled ModeLine.shipped }
        let (state, _) := reduceFrom segmented [.requested, .finished (accepted ["a"] listed)]
        let report := reportFrom segmented (accepted ["a"] listed)
        let (dropped, _) := reduceFrom state [.requested, .finished (accepted ["a"] (pure ()))]
        let (kept, _) := reduceFrom state [.requested, .finished (rejected "a")]
        pure
          (state.modeLine == some { left := #["state", "nope"], right := #["position"] } &&
            report.unknownSegments == #["nope"] &&
            report.echo == some "reload: no segment is registered as `nope`" &&
            (reportFrom segmented (accepted ["a"] both)).echo ==
              some
                "reload: no theme is registered as `gone`; no segment is registered as `nope`; no segment is registered as `lost`" &&
            (reportFrom segmented (accepted ["a"] (modeLine ["state"] []))).echo == none &&
            dropped.modeLine == none &&
            kept.modeLine == state.modeLine &&
            (reportFrom segmented (accepted ["a"] (pure ()))).unknownSegments == #[]) },
    { name :=
        "an install sets config's style choices and replaces its styles; its report names each chosen style nobody registered, which the echo area says after the segments' sentences; a later install that chooses none clears them, and a rejected one changes nothing"
      run :=
        let styled : Config.State Elaborated :=
          { themed with
            registry := themed.registry.replaceStyles .compiled Completion.Styles.shipped }
        let choosing : SetupM Unit := do
          useStyleFor "pick" "orderless"
          useStyle "nope"
        let both : SetupM Unit := do
          modeLine ["lost"] []
          useStyle "nope"
        let own : SetupM Unit := do
          defineStyle (.keeping "mine" fun _ _ => true)
          useStyle "mine"
        let (state, _) := reduceFrom styled [.requested, .finished (accepted ["a"] choosing)]
        let report := reportFrom styled (accepted ["a"] choosing)
        let (dropped, _) := reduceFrom state [.requested, .finished (accepted ["a"] (pure ()))]
        let (kept, _) := reduceFrom state [.requested, .finished (rejected "a")]
        let (owned, _) := reduceFrom styled [.requested, .finished (accepted ["a"] own)]
        pure
          (state.registry.styleChoices == #[(some "pick", "orderless"), (none, "nope")] &&
            report.unknownStyles == #["nope"] &&
            report.echo == some "reload: no completion style is registered under `nope`" &&
            (reportFrom styled (accepted ["a"] both)).echo ==
              some
                "reload: no segment is registered as `lost`; no completion style is registered under `nope`" &&
            dropped.registry.styleChoices == #[] &&
            (reportFrom state (accepted ["a"] (pure ()))).unknownStyles == #[] &&
            kept.registry.styleChoices == state.registry.styleChoices &&
            (owned.registry.matching.styleFor none).name == "mine" &&
            (owned.registry.style? "mine").isSome) },
    { name :=
        "an install sets config's display choices and replaces its displays; its report names each chosen display nobody registered, which the echo area says after the styles' sentences; a later install that chooses none clears them, and a rejected one changes nothing"
      run :=
        let shown : Config.State Elaborated :=
          { themed with
            registry := themed.registry.replaceDisplays .compiled Completion.Displays.shipped }
        let choosing : SetupM Unit := do
          useDisplayFor "pick" "minibuffer"
          useDisplay "nope"
        let both : SetupM Unit := do
          useStyle "gone"
          useDisplay "nope"
        let own : SetupM Unit := do
          defineDisplay (Completion.Display.plain "plain")
          useDisplay "plain"
        let (state, _) := reduceFrom shown [.requested, .finished (accepted ["a"] choosing)]
        let report := reportFrom shown (accepted ["a"] choosing)
        let (dropped, _) := reduceFrom state [.requested, .finished (accepted ["a"] (pure ()))]
        let (kept, _) := reduceFrom state [.requested, .finished (rejected "a")]
        let (owned, _) := reduceFrom shown [.requested, .finished (accepted ["a"] own)]
        pure
          (state.registry.displayChoices == #[(some "pick", "minibuffer"), (none, "nope")] &&
            report.unknownDisplays == #["nope"] &&
            report.echo == some "reload: no completion display is registered under `nope`" &&
            (reportFrom shown (accepted ["a"] both)).echo ==
              some
                "reload: no completion style is registered under `gone`; no completion display is registered under `nope`" &&
            dropped.registry.displayChoices == #[] &&
            (reportFrom state (accepted ["a"] (pure ()))).unknownDisplays == #[] &&
            kept.registry.displayChoices == state.registry.displayChoices &&
            (owned.registry.displaying.displayFor none).name == "plain" &&
            (owned.registry.display? "plain").isSome) },
    { name :=
        "a config's segments are replaced at every install: one it defines can be listed, and is gone once a reload no longer defines it"
      run :=
        let own : SetupM Unit := do
          defineSegment "greeting" fun _ => #[{ text := "hi", face := ⟨"mode-line.secondary"⟩ }]
          modeLine ["greeting"] []
        let (state, _) := reduceFrom themed [.requested, .finished (accepted ["a"] own)]
        let (dropped, _) :=
          reduceFrom state [.requested, .finished (accepted ["a"] (modeLine ["greeting"] []))]
        pure
          ((state.registry.segment? "greeting").isSome &&
            (reportFrom themed (accepted ["a"] own)).unknownSegments.isEmpty &&
            (dropped.registry.segment? "greeting").isNone &&
            (reportFrom state (accepted ["a"] (modeLine ["greeting"] []))).unknownSegments ==
              #["greeting"]) },
    { name :=
        "criterion 1: a config that names a registered theme starts in it, with config's faces over it; so does one that names a theme it defines itself, and the report says nothing in the echo area"
      run :=
        let named : SetupM Unit := do
          useTheme "second"
          face "keyword" (coloured 1)
        let own : SetupM Unit := do
          defineTheme "mine" (oneFace 9)
          useTheme "mine"
        let (state, effects) := reduceFrom themed [.requested, .finished (accepted ["a"] named)]
        let (mine, _) := reduceFrom themed [.requested, .finished (accepted ["a"] own)]
        pure
          (state.themeName == "second" &&
            state.theme == secondTheme ++ #[defined "keyword" (coloured 1)] &&
            effects == #[.start none #[], .cancelJobs "config", .report 1 true #[] 1 0] &&
            (reportFrom themed (accepted ["a"] named)).echo == none &&
            mine.themeName == "mine" &&
            mine.theme == oneFace 9) },
    { name :=
        "a theme config defines replaces the built-in theme wholesale: one of `default` alone, in force, defines no `cursor.normal`; one built as `Theme.builtin ++ #[…]` keeps it"
      run :=
        let definesCursor (theme : Theme) : Bool := theme.any (·.name == ⟨"cursor.normal"⟩)
        let bare : SetupM Unit := do
          defineTheme "bare" (oneFace 9)
          useTheme "bare"
        let over : SetupM Unit := do
          defineTheme "over" (Theme.builtin ++ oneFace 9)
          useTheme "over"
        let (bareState, _) := reduceFrom themed [.requested, .finished (accepted ["a"] bare)]
        let (overState, _) := reduceFrom themed [.requested, .finished (accepted ["a"] over)]
        pure
          (definesCursor Theme.builtin && bareState.themeName == "bare" &&
            !definesCursor bareState.theme &&
            overState.themeName == "over" &&
            definesCursor overState.theme) },
    { name :=
        "criterion 2: a config that names no theme starts in default, the built-in theme, with config's faces over it; a state before any config is in default"
      run :=
        let (state, _) :=
          reduceFrom themed [.requested, .finished (accepted ["a"] (face "keyword" (coloured 1)))]
        pure
          (({} : Config.State Elaborated).themeName == Theme.defaultName &&
            themed.themeName == Theme.defaultName &&
            state.themeName == Theme.defaultName &&
            state.theme == Theme.builtin ++ #[defined "keyword" (coloured 1)]) },
    { name :=
        "criterion 2: choosing a registered theme switches to it with the effect that says so, and a reload whose config names no theme keeps the theme in force"
      run :=
        let (chosen, effects) := Config.step themed (.choose "second")
        let (reloaded, _) :=
          reduceFrom chosen [.requested, .finished (accepted ["a"] (face "keyword" (coloured 1)))]
        pure
          (chosen.themeName == "second" && effects.map seen == #[.themed] &&
            reloaded.themeName == "second" &&
            reloaded.theme == secondTheme ++ #[defined "keyword" (coloured 1)]) },
    { name :=
        "criterion 4: after a switch, config's own faces still apply over the new theme, in their order"
      run :=
        let setup : SetupM Unit := do
          face "keyword" (coloured 1)
          face "default" (coloured 2)
        let (loaded, _) := reduceFrom themed [.requested, .finished (accepted ["a"] setup)]
        let (switched, _) := Config.step loaded (.choose "second")
        pure
          (loaded.theme ==
              Theme.builtin ++ #[defined "keyword" (coloured 1), defined "default" (coloured 2)] &&
            switched.theme ==
              secondTheme ++ #[defined "keyword" (coloured 1), defined "default" (coloured 2)]) },
    { name :=
        "criteria 5 and 6: a config that names a theme nobody registered is installed, leaves the theme in force as it was, and its report names the unknown theme in the echo area"
      run :=
        let (chosen, _) := Config.step themed (.choose "second")
        let unknown : SetupM Unit := do
          useTheme "nope"
          face "keyword" (coloured 1)
        let (state, effects) := reduceFrom chosen [.requested, .finished (accepted ["a"] unknown)]
        let report := reportFrom chosen (accepted ["a"] unknown)
        pure
          (state.themeName == "second" &&
            state.theme == secondTheme ++ #[defined "keyword" (coloured 1)] &&
            effects == #[.start none #[], .cancelJobs "config", .report 1 true #[] 1 0] &&
            report.unknownTheme == some "nope" &&
            report.echo == some s!"reload: {Theme.unknown "nope"}" &&
            report.echo == some "reload: no theme is registered as `nope`" &&
            (reportFrom chosen (accepted ["a"] (useTheme "second"))).unknownTheme == none) },
    { name :=
        "a rejected reload leaves the theme in force; choosing a theme nobody registered leaves the state and has no effect; a theme of config's in force that the next reload drops falls back to default"
      run :=
        let (chosen, _) := Config.step themed (.choose "second")
        let (kept, _) := reduceFrom chosen [.requested, .finished (rejected "a")]
        let (unknown, nothing) := Config.step chosen (.choose "nope")
        let own : SetupM Unit := do
          defineTheme "mine" (oneFace 9)
          useTheme "mine"
        let (mine, _) := reduceFrom themed [.requested, .finished (accepted ["a"] own)]
        let (dropped, _) := reduceFrom mine [.requested, .finished (accepted ["a"] (pure ()))]
        pure
          (kept.themeName == "second" && unknown.themeName == "second" &&
            unknown.theme == chosen.theme &&
            nothing.isEmpty &&
            mine.themeName == "mine" &&
            dropped.themeName == Theme.defaultName &&
            dropped.theme == Theme.builtin) },
    { name :=
        "the display is handed the theme in force, with its name, after a reload that installs and after a choice that switched the theme, and not after a rejected reload or a choice of a theme nobody registered"
      run := do
        let handed ← IO.mkRef (#[] : Array (String × Theme))
        let setTheme (name : String) (theme : Theme) : BaseIO Unit :=
          handed.modify (·.push (name, theme))
        let steps : List (Config.Event Elaborated) :=
          [.requested, .finished (accepted ["a"] (face "keyword" (coloured 1))), .choose "second",
            .requested, .finished (rejected "a"), .choose "nope"]
        let mut state := themed
        for event in steps do
          let (next, effects) := Config.step state event
          Config.retheme setTheme next effects
          state := next
        return (← handed.get) ==
            #[(Theme.defaultName, Theme.builtin ++ #[defined "keyword" (coloured 1)]),
              ("second", secondTheme ++ #[defined "keyword" (coloured 1)])] },
    { name :=
        "a state whose registry holds no theme of the name in force is drawn in the built-in theme"
      run :=
        pure
          (({ themeName := "second" } : Config.State Elaborated).theme == Theme.builtin &&
            ({} : Config.State Elaborated).theme == Theme.builtin) },
    { name := "a request with no job running starts one, carrying the base and the loaded chunks"
      run :=
        let first := reduce [.requested]
        let later := reduce [.requested, .finished (accepted ["a", "b"] (greets "1")), .requested]
        pure
          (first.2 == #[.start none #[]] &&
            later.2 ==
              #[.start none #[], .cancelJobs "config", .report 1 true #[] 2 1,
                .start (some #[]) #["a", "b"]]) },
    { name :=
        "requests while a job runs start nothing, and the finish then starts exactly one more job"
      run :=
        let (running, effects) := reduce [.requested, .requested, .requested, .requested]
        let (after, more) := reduceFrom running [.finished (accepted ["a"] (greets "1"))]
        let (_, last) := reduceFrom after [.finished (accepted ["a"] (greets "1"))]
        pure
          (effects == #[.start none #[]] &&
            more == #[.cancelJobs "config", .report 1 true #[] 1 1, .start (some #[]) #["a"]] &&
            last == #[.cancelJobs "config", .report 2 true #[] 1 1]) },
    { name :=
        "an accepted outcome installs its chunks and exactly its commands, and the report says installed"
      run :=
        let (state, effects) := reduce [.requested, .finished (accepted ["a", "b"] (greets "1"))]
        pure
          (state.chunks.map (·.name) == #["a", "b"] && state.registry.names == #["greet"] &&
            state.registry.entries.all (·.owner == .config) &&
            effects == #[.start none #[], .cancelJobs "config", .report 1 true #[] 2 1]) },
    { name :=
        "a rejected outcome leaves the registry, the chunks and the cells as they were, and the report carries its diagnostics"
      run :=
        let setup : SetupM Unit := do
          greets "1"
          bumps 1
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] setup)]
        let bumped := ((runs loaded "bump").map (·.1)).getD loaded
        let (state, effects) :=
          reduceFrom bumped
            [.requested, .finished (rejected "a"), .requested, .finished (rejected "setup")]
        pure
          (state.chunks.map (·.name) == #["a"] && state.registry.names == #["greet", "bump"] &&
            runTexts state "greet" == some #["1"] &&
            stored state "counter" == some (.nat 1) &&
            effects ==
              #[.start (some #[]) #["a"], .report 2 false #["a"] 1 2, .start (some #[]) #["a"],
                .report 3 false #["setup"] 1 2]) },
    { name := "a rejected first load keeps the base it imported for the next job"
      run :=
        pure
          ((reduce [.requested, .finished (rejected "a"), .requested]).2 ==
            #[.start none #[], .report 1 false #["a"] 0 0, .start (some #[]) #[]]) },
    { name :=
        "the theme is the built-in one then the installed config's definitions, in the order its setup made them, and the built-in one alone before any config"
      run :=
        let setup : SetupM Unit := do
          face "keyword" (coloured 1)
          greets "1"
          face "default" (coloured 2)
        let (state, effects) := reduce [.requested, .finished (accepted ["a"] setup)]
        pure
          ((reduce []).1.theme == Theme.builtin &&
            state.theme ==
              Theme.builtin ++ #[defined "keyword" (coloured 1), defined "default" (coloured 2)] &&
            -- The report's line is what it was: faces are no commands.
            effects == #[.start none #[], .cancelJobs "config", .report 1 true #[] 1 1]) },
    { name :=
        "an install replaces config's faces as a set: a face the new config does not set is the theme's again, one it sets again is there once, and a config that sets none leaves the built-in theme"
      run :=
        let first : SetupM Unit := do
          face "keyword" (coloured 1)
          face "comment" (coloured 2)
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] first)]
        let (again, _) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (face "keyword" (coloured 3)))]
        let (bare, _) := reduceFrom again [.requested, .finished (accepted ["a"] (greets "1"))]
        pure
          (again.theme == Theme.builtin ++ #[defined "keyword" (coloured 3)] &&
            bare.theme == Theme.builtin) },
    { name := "a rejected reload keeps config's faces, and the theme with them"
      run :=
        let (loaded, _) :=
          reduce [.requested, .finished (accepted ["a"] (face "keyword" (coloured 1)))]
        let (state, _) :=
          reduceFrom loaded
            [.requested, .finished (rejected "a"), .requested, .finished (rejected "setup")]
        pure
          (state.theme == Theme.builtin ++ #[defined "keyword" (coloured 1)] &&
            state.theme == loaded.theme) },
    { name :=
        "an installed reload puts config's process environment in the registry, a rejected one leaves the one that was there, and a config that sets none gives none"
      run :=
        let (loaded, _) :=
          reduce [.requested, .finished (accepted ["a"] (processEnvironment .inherited))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let (bare, _) := reduceFrom kept [.requested, .finished (accepted ["a"] (greets "1"))]
        pure
          ((reduce []).1.registry.environment == none &&
            loaded.registry.environment == some .inherited &&
            kept.registry.environment == some .inherited &&
            bare.registry.environment == none) },
    { name :=
        "an installed reload puts config's workspace roots in the registry, which tells the loop of them with the config generation; every install bumps the generation, a rejected reload changes neither, and with nothing installed the generation is 0"
      run :=
        let roots : Array Workspace.ConfigRoot := #[{ root := "/r/tools", project := some "tools" }]
        let (loaded, _) :=
          reduce [.requested, .finished (accepted ["a"] (workspace "/r/tools" (some "tools")))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let (bare, _) := reduceFrom kept [.requested, .finished (accepted ["a"] (greets "1"))]
        let told (state : Config.State Elaborated) : Array Workspace.ConfigRoot × Nat :=
          let registered := state.registry.registered
          (registered.workspaceRoots, registered.generation)
        pure
          (told (reduce []).1 == (#[], 0) && told loaded == (roots, 1) && told kept == (roots, 1) &&
            told bare == (#[], 2)) },
    { name :=
        "an installed reload puts config's workspace listers in the registry, which tells the loop of them in its workspace settings; a rejected reload keeps them, and a config that declares none clears them"
      run :=
        let listers : Array Workspace.DeclaredLister :=
          #[{ scope := .root "/r", program := "fd", arguments := #["-0"], nul := true },
            { scope := .project (.remote "github.com/o/r"), program := "rg" }]
        let declares : SetupM Unit := do
          workspaceLister "/r" "fd" #["-0"] (nul := true)
          projectLister (.remote "github.com/o/r") "rg"
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] declares)]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let (bare, _) := reduceFrom kept [.requested, .finished (accepted ["a"] (greets "1"))]
        let told (state : Config.State Elaborated) : Array Workspace.DeclaredLister :=
          state.registry.registered.workspaceSettings.listers
        pure
          (told (reduce []).1 == #[] && told loaded == listers && told kept == listers &&
            told bare == #[]) },
    { name :=
        "an installed reload puts config's shell time limit in the registry, which tells the loop of it; a rejected reload leaves it, and a config that sets none goes back to none"
      run :=
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (shellTimeLimit 5000))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let (bare, _) := reduceFrom kept [.requested, .finished (accepted ["a"] (greets "1"))]
        let told (state : Config.State Elaborated) : Option Nat :=
          state.registry.registered.shellTimeLimit
        pure
          (told (reduce []).1 == none && told loaded == some 5000 && told kept == some 5000 &&
            told bare == none) },
    { name :=
        "an installed reload puts config's languages in the registry over the compiled ones, so the loop is told config's rust in place of the shipped one; a rejected reload keeps them, and a config that defines none brings the shipped one back"
      run :=
        let mine :=
          { Language.rust with
            syntaxTree := { grammar := "rust", highlights := some "(identifier) @variable" } }
        let start : Config.State Elaborated :=
          { registry := ({} : Config.Registry).replaceLanguages .compiled Language.shipped }
        let (loaded, _) :=
          reduceFrom start [.requested, .finished (accepted ["a"] (defineLanguage mine))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let (bare, _) := reduceFrom kept [.requested, .finished (accepted ["a"] (greets "1"))]
        let rustOf (state : Config.State Elaborated) : Option Language :=
          state.registry.registered.languages.find? (·.name == "rust")
        pure
          (rustOf start == some Language.rust && rustOf loaded == some mine &&
            loaded.registry.registered.languages.map (·.name) ==
              ["rust", "json", "markdown", "toml", "lean"] &&
            rustOf kept == some mine &&
            rustOf bare == some Language.rust) },
    { name :=
        "an installed reload puts config's syntax refresh delay in the registry, which tells the loop of it; a rejected reload leaves it, and a config that sets none goes back to none"
      run :=
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (syntaxRefreshDelay 250))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let (bare, _) := reduceFrom kept [.requested, .finished (accepted ["a"] (greets "1"))]
        let told (state : Config.State Elaborated) : Option Nat :=
          state.registry.registered.syntaxRefreshDelay
        pure
          (told (reduce []).1 == none && told loaded == some 250 && told kept == some 250 &&
            told bare == none) },
    { name :=
        "an installed reload puts config's compile contributions and project commands in the registry, which tells the loop of them; a rejected reload leaves them, and a config that registers none leaves the compiled ones alone"
      run :=
        let start : Config.State Elaborated :=
          {
            registry :=
              ({} : Config.Registry).replaceContributions .compiled
                #[{ mode := "a-mode", markers := #["a.toml"] }] }
        let setup : SetupM Unit := do
          compileContribution { mode := "b-mode", markers := #["b.toml"] }
          projectCommands (.remote "github.com/o/r") "b-mode" [("lint", "b-lint")]
        let (loaded, _) := reduceFrom start [.requested, .finished (accepted ["a"] setup)]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let (bare, _) := reduceFrom kept [.requested, .finished (accepted ["a"] (greets "1"))]
        let told (state : Config.State Elaborated) : Array String × Array String :=
          let hook := state.registry.registered.compile
          (hook.contributions.map (·.mode), hook.projects.map (·.mode))
        pure
          (told start == (#["a-mode"], #[]) &&
            told loaded == (#["b-mode", "a-mode"], #["b-mode"]) &&
            told kept == told loaded &&
            told bare == (#["a-mode"], #[])) },
    { name :=
        "an outcome with no base leaves the base as it was: with none known the next job imports again, and a known one is not forgotten"
      run :=
        let baseless : Config.Outcome Elaborated :=
          { base := none, diagnostics := #[told "base" .error], built := none }
        pure
          ((reduce [.requested, .finished baseless, .requested]).2 ==
              #[.start none #[], .report 1 false #["base"] 0 0, .start none #[]] &&
            (reduce
                  [.requested, .finished (rejected "a"), .requested, .finished baseless,
                    .requested]).2 ==
              #[.start none #[], .report 1 false #["a"] 0 0, .start (some #[]) #[],
                .report 2 false #["base"] 0 0, .start (some #[]) #[]]) },
    { name := "reload replaces a command"
      run :=
        let first : SetupM Unit := do
          greets "v1"
          command "old" (makes "old")
        let (state, _) :=
          reduce
            [.requested, .finished (accepted ["a"] first), .requested,
              .finished (accepted ["a"] (greets "v2"))]
        pure
          (runTexts state "greet" == some #["v2"] && state.registry.names == #["greet"] &&
            (state.program? "old").isNone) },
    { name := "a reload does not double-register"
      run :=
        let (state, _) :=
          reduce
            [.requested, .finished (accepted ["a"] (greets "v1")), .requested,
              .finished (accepted ["a"] (greets "v1")), .requested,
              .finished (accepted ["a"] (greets "v1"))]
        pure (state.registry.entries.size == 1 && runTexts state "greet" == some #["v1"]) },
    { name :=
        "a config that registers a command name twice is not installed, so the commands a report counts are the names that can be run"
      run := do
        let setup : SetupM Unit := do
          greets "v1"
          bumps 1
        let twice : SetupM Unit := do
          greets "v2"
          greets "v3"
        let (loaded, first) := reduce [.requested, .finished (accepted ["a"] setup)]
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build TestScheme.scheme (fakeElaborator calls (.ok twice)) (fakeSource ["a"])
              loaded.base loaded.chunks
        let (state, effects) := reduceFrom loaded [.requested, .finished outcome]
        return first == #[.start none #[], .cancelJobs "config", .report 1 true #[] 1 2] &&
            effects == #[.start (some #[]) #["a"], .report 2 false #["setup"] 1 2] &&
            state.registry.names == #["greet", "bump"] &&
            state.registry.entries.size == 2 &&
            runTexts state "greet" == some #["v1"] },
    { name := "a store value survives a reload"
      run :=
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (bumps 1))]
        let once := ((runs loaded "bump").map (·.1)).getD loaded
        let twice := ((runs once "bump").map (·.1)).getD once
        let (reloaded, _) := reduceFrom twice [.requested, .finished (accepted ["a"] (bumps 10))]
        let again := ((runs reloaded "bump").map (·.1)).getD reloaded
        pure
          (stored loaded "counter" == some (.nat 0) && stored twice "counter" == some (.nat 2) &&
            stored reloaded "counter" == some (.nat 2) &&
            stored again "counter" == some (.nat 12)) },
    { name :=
        "an installed reload's report carries the config's warnings, then a diagnostic for each store value that was lost"
      run :=
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (bumps 1))]
        let bumped := ((runs loaded "bump").map (·.1)).getD loaded
        -- An accepted outcome whose one chunk elaborated with a warning.
        let warned (setup : SetupM Unit) : Config.Outcome Elaborated :=
          { accepted ["a"] setup with diagnostics := #[told "a" .warning] }
        -- The counter at a version its store does not migrate to: the value
        -- is reset. And a config that no longer declares it: the cell goes.
        let unmigrated : SetupM Unit := ({ counter with version := 2 } : Store Nat).declare
        let (reset, resetEffects) := reduceFrom bumped [.requested, .finished (warned unmigrated)]
        let (removed, removedEffects) :=
          reduceFrom bumped [.requested, .finished (warned (greets "v1"))]
        pure
          (stored bumped "counter" == some (.nat 1) &&
            resetEffects ==
              #[.start (some #[]) #["a"], .cancelJobs "config",
                .report 2 true #["a", "store counter"] 1 0] &&
            ((reset.cells.find? .config "counter").map fun cell => (cell.version, cell.value)) ==
              some (2, .nat 0) &&
            removedEffects ==
              #[.start (some #[]) #["a"], .cancelJobs "config",
                .report 2 true #["a", "store counter"] 1 1] &&
            stored removed "counter" == none) },
    { name :=
        "a command over a store that is refused writes nothing, and a name nobody registered runs nothing"
      run :=
        let setup : SetupM Unit := do
          counter.declare
          counter.command "broken" fun n => do
              (⟨7⟩ : TextId).insert 0 "x"
              return n + 1
        let (state, _) := reduce [.requested, .finished (accepted ["a"] setup)]
        pure
          ((state.program? "broken").isSome && (runs state "broken").isNone &&
            (state.program? "missing").isNone) },
    { name :=
        "a job is not counted as a command: the report of a config that registers one command and one job says one command"
      run :=
        let (state, effects) := reduce [.requested, .finished (accepted ["a"] (counts "v1"))]
        pure
          (effects == #[.start none #[], .cancelJobs "config", .report 1 true #[] 1 1] &&
            state.commands == 1 &&
            state.registry.names == #["greet"]) },
    { name :=
        "an accepted outcome cancels the config's jobs before it is reported, and before the follow-up job starts; a rejected outcome cancels nothing"
      run :=
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (counts "v1"))]
        -- A reload asked for while one runs: the follow-up starts last.
        let (_, acceptedEffects) :=
          reduceFrom loaded [.requested, .requested, .finished (accepted ["a"] (counts "v2"))]
        -- The same source again: every accepted reload cancels.
        let (_, unchanged) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (counts "v1"))]
        let (_, rejectedEffects) :=
          reduceFrom loaded [.requested, .requested, .finished (rejected "a")]
        pure
          (acceptedEffects ==
              #[.start (some #[]) #["a"], .cancelJobs "config", .report 2 true #[] 1 1,
                .start (some #[]) #["a"]] &&
            unchanged ==
              #[.start (some #[]) #["a"], .cancelJobs "config", .report 2 true #[] 1 1] &&
            rejectedEffects ==
              #[.start (some #[]) #["a"], .report 2 false #["a"] 1 1, .start (some #[]) #["a"]]) },
    { name :=
        "a reload replaces the config's jobs: the registry finds the new config's job and not the old one's, and a rejected reload keeps the old one's"
      run :=
        let first : SetupM Unit := do
          counts "v1"
          job "old" (fun _ => pure "old") makes
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] first)]
        let (reloaded, _) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (counts "v2"))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        pure
          (startable loaded "count" == some ("config", .finished #["v1"]) &&
            startable loaded "old" == some ("config", .finished #["old"]) &&
            startable reloaded "count" == some ("config", .finished #["v2"]) &&
            startable reloaded "old" == none &&
            reloaded.registry.jobs.size == 1 &&
            startable kept "count" == some ("config", .finished #["v1"]) &&
            startable kept "old" == some ("config", .finished #["old"]) &&
            startable loaded "missing" == none) },
    { name :=
        "config registers a command under a compiled command's name: an invocation of the name runs config's, the report counts config's commands alone, and after a reload without the registration the invocation runs the compiled one"
      run :=
        let compiled := compiledWith #[registration "stamp" "compiled"]
        let (overridden, effects) :=
          reduceFrom compiled
            [.requested, .finished (accepted ["a"] (command "stamp" (makes "config")))]
        let (dropped, later) :=
          reduceFrom overridden [.requested, .finished (accepted ["a"] (greets "hello"))]
        pure
          ((calls compiled "stamp").map (·.2) == some #["", "compiled"] &&
            (calls overridden "stamp").map (·.2) == some #["", "config"] &&
            effects == #[.start none #[], .cancelJobs "config", .report 1 true #[] 1 1] &&
            (calls dropped "stamp").map (·.2) == some #["", "compiled"] &&
            later == #[.start (some #[]) #["a"], .cancelJobs "config", .report 2 true #[] 1 1] &&
            (calls dropped "missing").isNone) },
    { name :=
        "a command that is given its call is handed the call an invocation runs it with: its arguments and its keys"
      run :=
        let state := compiledWith #[callRegistration "stamp" "stamp"]
        pure
          ((calls state "stamp" [.nat 3, .str "w"] (keys "C-x i")).map (·.2) ==
              some #["", "stamp 3 w C-x i"] &&
            ((calls state "stamp").bind (·.1)).isNone) },
    { name :=
        "a command config registers as one given its call is handed the call an invocation runs it with: it acts on the call's target and reads its arguments and its keys; an install replaces it with config's other commands, and a config that no longer registers it drops it"
      run :=
        let greets (label : String) : SetupM Unit :=
          commandWith "greet" fun call => Loop.insert call.target (callText label call)
        let called (state : Config.State Elaborated) : Option (Array String) :=
          (calls state "greet" [.nat 3, .str "w"] (keys "C-x i")).map (·.2)
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (greets "one"))]
        let (reloaded, _) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (greets "two"))]
        let (dropped, _) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (command "other" (makes "o")))]
        pure
          (called loaded == some #["one 3 w C-x i"] && called reloaded == some #["two 3 w C-x i"] &&
            (called dropped).isNone &&
            loaded.registry.names == #["greet"]) },
    { name :=
        "a command over a store, run as an invocation runs it, hands back what to write: the owner, the store and the new tree, which the state then holds"
      run :=
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (bumps 4))]
        pure <|
          match calls loaded "bump" with
          | some (some write, _) =>
            write.owner == .config && write.store == "counter" && write.value == .nat 4 &&
              stored (loaded.written (some write)) "counter" == some (.nat 4)
          | _ => false },
    { name :=
        "the driver's run of a command that is given its call runs it with the target it is handed and nothing else, and runs nothing when it is handed none"
      run :=
        let state := compiledWith #[callRegistration "stamp" "stamp", registration "plain" "p"]
        let program : EditorM (Option Bool) := do
          let editor ← EditorState.initial ⟨640, 480⟩
          let some target := editor.focusedTarget? | throw .noSuchText
          let some run := state.program? "stamp" (some target) | return none
          return some (← run).isNone
        pure
          ((state.program? "stamp").isNone &&
            (match program.runModel editorModel with
            | (.ok (some true), model) => model.texts.contents == #["", "stamp "]
            | _ => false) &&
            runTexts state "plain" == some #["p"]) },
    { name :=
        "an accepted outcome replaces the config's key bindings and leaves compiled ones: a key the new config binds to another command is bound to that one alone, and one it no longer binds is unbound; a rejected outcome keeps them"
      run :=
        let compiled : Config.State Elaborated :=
          { registry := ({} : Config.Registry).replaceBindings .compiled #[binding "C-c k" "kept"] }
        let first : SetupM Unit := do
          bindKey "C-c t" "one"
          bindKey "C-c o" "old"
        let (loaded, _) := reduceFrom compiled [.requested, .finished (accepted ["a"] first)]
        let (reloaded, effects) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (bindKey "C-c t" "two"))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        pure
          (boundTo loaded.registry "C-c t" == some (invoke "one") &&
            boundTo loaded.registry "C-c o" == some (invoke "old") &&
            boundTo reloaded.registry "C-c t" == some (invoke "two") &&
            boundTo reloaded.registry "C-c o" == none &&
            boundTo reloaded.registry "C-c k" == some (invoke "kept") &&
            reloaded.registry.bindings.size == 2 &&
            effects == #[.start (some #[]) #["a"], .cancelJobs "config", .report 2 true #[] 1 0] &&
            boundTo kept.registry "C-c t" == some (invoke "one") &&
            boundTo kept.registry "C-c o" == some (invoke "old")) },
    { name :=
        "an accepted outcome that sets the leader expands config's <leader> bindings to it, and a later one that sets none expands them to the scheme's leader again"
      run :=
        let leading : SetupM Unit := do
          leaderKey "C-x"
          bindKey "<leader> f" "find"
        let (loaded, _) := reduceFrom {} [.requested, .finished (accepted ["a"] leading)]
        let (reloaded, _) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (bindKey "<leader> f" "find"))]
        pure
          (loaded.registry.leader == some (keys "C-x") &&
            boundTo loaded.registry "C-x f" == some (invoke "find") &&
            boundTo loaded.registry "C-c f" == none &&
            reloaded.registry.leader == none &&
            boundTo reloaded.registry "C-c f" == some (invoke "find") &&
            boundTo reloaded.registry "C-x f" == none) },
    { name :=
        "an accepted outcome that sets the localleader puts it in the registry, and one that sets none clears it"
      run :=
        let (loaded, _) :=
          reduceFrom {} [.requested, .finished (accepted ["a"] (localLeaderKey "<leader> m"))]
        let (reloaded, _) := reduceFrom loaded [.requested, .finished (accepted ["a"] (pure ()))]
        pure
          (loaded.registry.localLeader == some [.leader, .key (charKey "m")] &&
            reloaded.registry.localLeader == none) },
    { name :=
        "an accepted outcome replaces the config's modes and leaves compiled ones; a rejected outcome keeps config's"
      run :=
        let compiled : Config.State Elaborated :=
          { registry := ({} : Config.Registry).replaceModes .compiled #[{ name := "kept" }] }
        let first : SetupM Unit := do
          defineMode { name := "listing", parent := some "first" }
          defineMode { name := "gone" }
        let (loaded, _) := reduceFrom compiled [.requested, .finished (accepted ["a"] first)]
        let (reloaded, _) :=
          reduceFrom loaded
            [.requested,
              .finished
                (accepted ["a"] (defineMode { name := "listing", parent := some "second" }))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let names (state : Config.State Elaborated) : Array String :=
          state.registry.modes.map (·.mode.name)
        let parentOf (state : Config.State Elaborated) : Option String :=
          (state.registry.mode? "listing").bind (·.parent)
        pure
          (names loaded == #["kept", "listing", "gone"] && parentOf loaded == some "first" &&
            names reloaded == #["kept", "listing"] &&
            parentOf reloaded == some "second" &&
            names kept == names loaded &&
            parentOf kept == some "first") },
    { name :=
        "an accepted outcome replaces the config's ex bindings and leaves compiled ones: a name the new config binds to another command runs that one, one it no longer binds is found no more, and a compiled name it bound is the compiled one again; a rejected outcome keeps them; an ex binding is not counted as a command"
      run :=
        let compiled : Config.State Elaborated :=
          {
            registry :=
              ({} : Config.Registry).replaceEx .compiled
                #[{ name := "w", command := "compiled" }, { name := "q", command := "kept" }] }
        let first : SetupM Unit := do
          exCommand "greet" "one" (takes := .text)
          exCommand "old" "gone"
          exCommand "w" "config"
        let (loaded, _) := reduceFrom compiled [.requested, .finished (accepted ["a"] first)]
        let (reloaded, effects) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (exCommand "greet" "two"))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let runs (state : Config.State Elaborated) (name : String) : Option String :=
          (state.registry.ex? name).map (·.command)
        pure
          (runs loaded "greet" == some "one" && runs loaded "old" == some "gone" &&
            runs loaded "w" == some "config" &&
            runs loaded "q" == some "kept" &&
            reloaded.registry.ex? "greet" == some { name := "greet", command := "two" } &&
            runs reloaded "old" == none &&
            runs reloaded "w" == some "compiled" &&
            runs reloaded "q" == some "kept" &&
            reloaded.registry.ex.size == 3 &&
            effects == #[.start (some #[]) #["a"], .cancelJobs "config", .report 2 true #[] 1 0] &&
            kept.registry.ex == loaded.registry.ex) },
    { name :=
        "a rejected reload's echo is its first error with its place and the first line of its message, and says how many more errors there are"
      run :=
        let error (source : String) (line column : Nat) (message : String) : Config.Diagnostic :=
          { source, line, column, severity := .error, message }
        let warning : Config.Diagnostic :=
          { source := "a.lean", line := 1, severity := .warning, message := "unused" }
        let report (installed : Bool) (diagnostics : Array Config.Diagnostic) : Config.Report :=
          { number := 2, installed, diagnostics, chunks := 1, commands := 1 }
        let one := report false #[warning, error "30-broken.lean" 1 20 "type mismatch\n  \"x\""]
        let three :=
          report false
            #[error "b.lean" 3 4 "unknown identifier 'x'", warning, error "b.lean" 5 0 "second",
              error "setup" 0 0 "third"]
        pure
          (one.echo == some "reload: 30-broken.lean:1:20: error: type mismatch" &&
            three.echo == some "reload: b.lean:3:4: error: unknown identifier 'x' (and 2 more)" &&
            (report true #[warning]).echo == none &&
            (report true #[]).echo == none) },
    { name :=
        "an install replaces config's menus and leaves another owner's: config's menu of a title is shown at the other's place and its new one after, a later install that defines none brings the other's back, and a rejected one changes nothing"
      run :=
        let titled (title item : String) : Submenu :=
          { title, items := #[.item item none (.system .about)] }
        let theirs : Config.State Elaborated :=
          {
            registry :=
              ({} : Config.Registry).replaceMenus other
                #[titled "File" "theirs", titled "Edit" "edit"] }
        let defines : SetupM Unit := do
          defineMenu (titled "Help" "help")
          defineMenu (titled "File" "config's")
        let (state, _) := reduceFrom theirs [.requested, .finished (accepted ["a"] defines)]
        let (kept, _) := reduceFrom state [.requested, .finished (rejected "a.lean")]
        let (dropped, _) := reduceFrom state [.requested, .finished (accepted ["a"] (pure ()))]
        pure
          (state.registry.menuBar? ==
              some
                {
                  menus :=
                    #[titled "File" "config's", titled "Edit" "edit", titled "Help" "help"] } &&
            kept.registry.menuBar? == state.registry.menuBar? &&
            dropped.registry.menuBar? == theirs.registry.menuBar? &&
            dropped.registry.menus.map (·.owner) == #[other, other]) }]

/-- The checks that an install replaces config's descriptions and prefix
names along with its bindings. -/
def reloadHintChecks : List Check :=
  [{  name :=
        "an install of a config that names a prefix and describes a binding puts both in the registry, and a later install of one that does neither clears them"
      run :=
        let labelled : SetupM Unit := do
          prefixName "<leader> f" "file"
          bindKey "<leader> f f" "find" (desc := "Find file")
        let (loaded, _) := reduceFrom {} [.requested, .finished (accepted ["a"] labelled)]
        let (reloaded, _) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (bindKey "<leader> f f" "find"))]
        pure
          (loaded.registry.prefixName? TestScheme.scheme (keys "C-c f") == some "file" &&
            (loaded.registry.keymap TestScheme.scheme).describe? (keys "C-c f f") ==
              some "Find file" &&
            reloaded.registry.prefixName? TestScheme.scheme (keys "C-c f") == none &&
            (reloaded.registry.keymap TestScheme.scheme).describe? (keys "C-c f f") == none &&
            boundTo reloaded.registry "C-c f f" == some (invoke "find")) }]

end ModelTest
