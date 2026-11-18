import Editor.Appearance
import Editor.Command
import Editor.Command.Dispatch
import Editor.Compile.Contribution
import Editor.Compile.Errors
import Editor.Config.Owner
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.Config.Session
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.Ex.Line
import Editor.Face
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Keymap
import Editor.Layout
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Program
import Editor.Role
import Editor.Scene
import Editor.State
import Editor.TabBar
import Editor.Text
import Editor.Window
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.Config
import ModelTest.Support.Keys
import ModelTest.Support.Models
import ModelTest.Support.Modes

/-!
# Model tests: `Editor/Config/Registry.lean`

The model tests of `Editor/Config/Registry.lean`: `registryChecks` and
`modeRegistryChecks`. `modeRegistryChecks` are of modes in the registry. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- A registration of the job `name`, which finishes with a command that
makes the text `text`. -/
def jobRegistration (name text : String) : Config.JobRegistration :=
  { name, work := fun _ _ => pure (makes text) }

/-- How the job `registry` holds under `name` ends, started with `arguments`
and run against the job model; `none` if there is no such job. -/
def registeredWork (registry : Config.Registry) (name : String) (arguments : List Argument := []) :
    Option (Job.Outcome (Array String)) :=
  (registry.findJob? name).map fun entry => worked (entry.registration.work arguments)

/-- The texts the command `registry` holds under `name` leaves, run against a
text model with none; `none` if there is no such plain command. -/
def registeredTexts (registry : Config.Registry) (name : String) : Option (Array String) :=
  (registry.find? name).bind (plainTexts ·.registration.action)

/-- The checks of the registry (`Editor/Config/Registry.lean`). -/
def registryChecks : List Check :=
  [{  name :=
        "the registry's compile contributions are config's in config's order, then the compiled ones config does not register; config's a-mode replaces the compiled a-mode whole, and replacing config's with none brings the compiled one back"
      run :=
        let compiledA : Compile.Contribution :=
          { mode := "a-mode", markers := #["a.toml"]
            commands :=
              #[{ name := "build", line := "compiled-build" },
                { name := "lint", line := "compiled-lint" }]
            formats := #[Compile.Format.general] }
        let compiledC : Compile.Contribution := { mode := "c-mode", markers := #["c.toml"] }
        let configB : Compile.Contribution := { mode := "b-mode", markers := #["b.toml"] }
        let configA : Compile.Contribution :=
          { mode := "a-mode", markers := #["x.toml"]
            commands := #[{ name := "build", line := "config-build" }] }
        let compiled :=
          ({} : Config.Registry).replaceContributions .compiled #[compiledA, compiledC]
        let both := compiled.replaceContributions .config #[configB, configA]
        let dropped := both.replaceContributions .config #[]
        let shape (contributions : Array Compile.Contribution) :=
          contributions.map fun contribution =>
            (contribution.mode, contribution.markers, contribution.commands,
              contribution.formats.map (·.name))
        pure
          (shape compiled.compileContributions == shape #[compiledA, compiledC] &&
            shape both.compileContributions == shape #[configB, configA, compiledC] &&
            shape dropped.compileContributions == shape #[compiledA, compiledC] &&
            shape both.compileHook.contributions == shape #[configB, configA, compiledC]) },
    {
      name :=
        "replace for an owner leaves exactly the new commands of that owner, and a second replace does not add to the first",
      run :=
        let once : Config.Registry :=
          ({} : Config.Registry).replace .config
            #[registration "greet" "1", registration "part" "1"]
        let twice := once.replace .config #[registration "greet" "2"]
        pure
          (once.names == #["greet", "part"] && twice.names == #["greet"] &&
            twice.entries.size == 1 &&
            registeredTexts twice "greet" == some #["2"]) },
    { name := "replace leaves another owner's entries alone"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replace other #[registration "theirs" "t"]).replace .config
            #[registration "greet" "1"]
        let replaced := registry.replace .config #[]
        pure
          (registry.names == #["theirs", "greet"] && replaced.names == #["theirs"] &&
            registeredTexts replaced "theirs" == some #["t"]) },
    { name := "a lookup returns the latest entry of a name, and none for a name nobody registered"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replace other #[registration "greet" "theirs"]).replace .config
            #[registration "greet" "ours"]
        pure
          (registeredTexts registry "greet" == some #["ours"] && registry.names == #["greet"] &&
            (registry.find? "missing").isNone) },
    { name :=
        "an owner's jobs are replaced as a set, and another owner's are left: a lookup finds the latest job of a name, and the commands are untouched"
      run :=
        let registry : Config.Registry :=
          ((({} : Config.Registry).replace .config #[registration "greet" "1"]).replaceJobs other
                #[jobRegistration "theirs" "t"]).replaceJobs
            .config #[jobRegistration "count" "1", jobRegistration "old" "1"]
        let replaced := registry.replaceJobs .config #[jobRegistration "count" "2"]
        pure
          (registry.jobs.map (·.registration.name) == #["theirs", "count", "old"] &&
            replaced.jobs.map (·.registration.name) == #["theirs", "count"] &&
            registeredWork replaced "count" == some (.finished #["2"]) &&
            registeredWork replaced "theirs" == some (.finished #["t"]) &&
            registeredWork replaced "old" == none &&
            replaced.names == #["greet"] &&
            (replaced.find? "count").isNone) },
    { name :=
        "a job is held with what it takes: the work a lookup hands back for the arguments the job is started with computes from them, and so does the work the editor would start for an installed config"
      run :=
        let doubling : Config.JobRegistration :=
          { name := "double"
            work := fun arguments =>
              Work.of
                (fun _ =>
                  match arguments with
                  | [.nat n] => pure (2 * n)
                  | _ => throw "no number")
                fun n => makes (toString n) }
        let registry := ({} : Config.Registry).replaceJobs .config #[doubling]
        let state : Config.State Unit := { registry }
        let starting (arguments : List Argument) :=
          (state.work? "double" arguments).map fun (owner, work) => (owner.name, worked work)
        pure
          (registeredWork registry "double" [.nat 21] == some (.finished #["42"]) &&
            registeredWork registry "double" == some (.failed "no number") &&
            starting [.nat 4] == some ("config", .finished #["8"]) &&
            starting [] == some ("config", .failed "no number") &&
            (state.work? "missing" [.nat 4]).isNone) },
    { name :=
        "compiled code is an owner of its own: config's entry of a name a compiled entry has is the one a lookup finds, and once config no longer registers it the compiled one is found again"
      run :=
        let compiled : Config.Registry :=
          ({} : Config.Registry).replace .compiled
            #[registration "stamp" "compiled", registration "only" "compiled"]
        let overridden := compiled.replace .config #[registration "stamp" "config"]
        let dropped := overridden.replace .config #[]
        pure
          (Config.Owner.compiled != Config.Owner.config &&
            registeredTexts compiled "stamp" == some #["compiled"] &&
            registeredTexts overridden "stamp" == some #["config"] &&
            registeredTexts overridden "only" == some #["compiled"] &&
            overridden.names == #["stamp", "only"] &&
            registeredTexts dropped "stamp" == some #["compiled"] &&
            dropped.entries.all (·.owner == .compiled)) },
    { name :=
        "replacing an owner's bindings removes its old ones and leaves another owner's, and touches no command"
      run :=
        let registry : Config.Registry :=
          ((({} : Config.Registry).replace .config #[registration "greet" "1"]).replaceBindings
                .compiled #[binding "C-c a" "theirs"]).replaceBindings
            .config #[binding "C-c b" "one", binding "C-c c" "old"]
        let replaced := registry.replaceBindings .config #[binding "C-c b" "two"]
        pure
          (boundTo registry "C-c a" == some (invoke "theirs") &&
            boundTo registry "C-c b" == some (invoke "one") &&
            boundTo registry "C-c c" == some (invoke "old") &&
            boundTo replaced "C-c a" == some (invoke "theirs") &&
            boundTo replaced "C-c b" == some (invoke "two") &&
            boundTo replaced "C-c c" == none &&
            replaced.bindings.size == 2 &&
            replaced.names == #["greet"]) },
    { name :=
        "of two owners' bindings of one key sequence, the registry's keymap gives the later owner's, and the earlier's again once the later owner binds nothing"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceBindings .compiled
                #[binding "C-c t" "compiled", binding "C-c u" "kept"]).replaceBindings
            .config #[binding "C-c t" "config"]
        pure
          (boundTo registry "C-c t" == some (invoke "config") &&
            boundTo registry "C-c u" == some (invoke "kept") &&
            boundTo (registry.replaceBindings .config #[]) "C-c t" == some (invoke "compiled") &&
            (registry.keymap TestScheme.scheme).continues (keys "C-c")) },
    { name :=
        "replacing an owner's modes leaves the others', and the latest mode of a name is the one found"
      run :=
        let named (name parent : String) : Mode := { name, parent := some parent }
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceModes .compiled
                #[named "listing" "compiled", named "kept" "compiled"]).replaceModes
            .config #[named "listing" "config", named "gone" "config"]
        let replaced := registry.replaceModes .config #[named "new" "config"]
        let parentOf (registry : Config.Registry) (name : String) : Option String :=
          (registry.mode? name).bind (·.parent)
        pure
          (parentOf registry "listing" == some "config" &&
            parentOf registry "kept" == some "compiled" &&
            parentOf registry "gone" == some "config" &&
            parentOf replaced "listing" == some "compiled" &&
            (replaced.mode? "gone").isNone &&
            parentOf replaced "new" == some "config" &&
            replaced.modes.map (·.mode.name) == #["listing", "kept", "new"] &&
            (registry.mode? "none").isNone) },
    { name :=
        "replacing an owner's ex bindings removes its old ones and adds the new, and leaves another owner's; a name nobody bound is not found"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceEx .compiled
                #[{ name := "w", command := "theirs" }]).replaceEx
            .config
            #[{ name := "greet", command := "one", takes := .text },
              { name := "old", command := "gone" }]
        let replaced := registry.replaceEx .config #[{ name := "greet", command := "two" }]
        pure
          (registry.ex? "w" == some { name := "w", command := "theirs" } &&
            registry.ex? "greet" == some { name := "greet", command := "one", takes := .text } &&
            registry.ex? "old" == some { name := "old", command := "gone" } &&
            replaced.ex? "w" == some { name := "w", command := "theirs" } &&
            replaced.ex? "greet" == some { name := "greet", command := "two" } &&
            replaced.ex? "old" == none &&
            replaced.ex.size == 2 &&
            registry.ex? "missing" == none) },
    { name :=
        "of two owners' ex bindings of one name the latest entry is the one found: config's while it is there, and the compiled one again once config binds nothing"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceEx .compiled
                #[{ name := "w", command := "compiled" },
                  { name := "q", command := "kept" }]).replaceEx
            .config #[{ name := "w", command := "config" }]
        pure
          ((registry.ex? "w").map (·.command) == some "config" &&
            (registry.ex? "q").map (·.command) == some "kept" &&
            ((registry.replaceEx .config #[]).ex? "w").map (·.command) == some "compiled") },
    { name :=
        "what the loop is told of a registry's ex names is each bound name once, in the order they were first bound: a name config binds over a compiled one is listed once, at the compiled one's place, a name of config's alone comes after, and a registry with no ex binding has none"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceEx .compiled
                #[{ name := "w", command := "compiled" },
                  { name := "q", command := "kept" }]).replaceEx
            .config
            #[{ name := "greet", command := "greet-named" }, { name := "w", command := "config" }]
        pure
          (registry.registered.exNames == #["w", "q", "greet"] &&
            registry.registered.exNames.all (fun name => (registry.registered.ex name).isSome) &&
            ({} : Config.Registry).registered.exNames == #[] &&
            (registry.replaceEx .config #[]).registered.exNames == #["w", "q"]) },
    { name :=
        "themes are held by owner and replaced as a set: the latest entry of a name is the one found, config's theme of a compiled theme's name while config registers it and the compiled one again once it does not; the theme names are each listed once, in the order first registered, and are what the loop is told; the commands and the faces are left as they were"
      run :=
        let registry : Config.Registry :=
          ((({} : Config.Registry).replace .config #[registration "greet" "1"]).replaceThemes
                .compiled #[namedTheme "default" 1, namedTheme "second" 2]).replaceThemes
            .config #[namedTheme "mine" 3, namedTheme "second" 4]
        let replaced := registry.replaceThemes .config #[namedTheme "other" 5]
        pure
          (registry.theme? "second" == some (namedTheme "second" 4) &&
            registry.theme? "default" == some (namedTheme "default" 1) &&
            registry.theme? "nope" == none &&
            registry.themeNames == #["default", "second", "mine"] &&
            registry.registered.themeNames == registry.themeNames &&
            { registry with displayRules := #[{ target := .main }] }.registered.displayRules ==
              #[{ target := .main }] &&
            registry.registered.displayRules == #[] &&
            replaced.theme? "second" == some (namedTheme "second" 2) &&
            replaced.theme? "mine" == none &&
            replaced.themeNames == #["default", "second", "other"] &&
            replaced.themes.size == 3 &&
            replaced.names == #["greet"] &&
            replaced.definitions.isEmpty &&
            ({} : Config.Registry).registered.themeNames == #[]) },
    { name :=
        "segments are held by owner and replaced as a set: the latest entry of a name is the one found; a mode line resolves in its listing's order, with the names nobody registered listed in order, each once"
      run :=
        let mine : Segment :=
          { name := "buffer", fields := fun _ => #[{ text := "mine", face := ⟨"x"⟩ }] }
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceSegments .compiled ModeLine.shipped).replaceSegments
            .config #[mine]
        let replaced := registry.replaceSegments .config #[]
        let texts (registry : Config.Registry) (order : ModeLine.Order) : Array String :=
          ((registry.resolve order).1.fields loopContext).map (·.text)
        let (_, unknown) :=
          registry.resolve { left := #["nope", "buffer", "nope"], right := #["gone", "position"] }
        pure
          ((registry.segment? "buffer").map (·.name) == some "buffer" &&
            texts registry { left := #["buffer"], right := #[] } == #["mine"] &&
            texts replaced { left := #["buffer"], right := #[] } == #["Loop.lean"] &&
            replaced.segments.size == ModeLine.shipped.size &&
            (registry.segment? "nope").isNone &&
            unknown == #["nope", "gone"] &&
            texts registry ModeLine.Order.standard ==
              #["NORMAL", "mine", "●", "lean/Editor", "lean", "959:5", "41%"]) },
    { name :=
        "replacing an owner's ex bindings leaves the commands, the jobs, the key bindings and the modes as they were"
      run :=
        let registry : Config.Registry :=
          (((({} : Config.Registry).replace .config #[registration "greet" "1"]).replaceJobs .config
                    #[jobRegistration "count" "1"]).replaceBindings
                .config #[binding "C-c b" "one"]).replaceModes
            .config #[{ name := "listing" }]
        let replaced := registry.replaceEx .config #[{ name := "w", command := "write" }]
        pure
          (replaced.names == #["greet"] && registeredTexts replaced "greet" == some #["1"] &&
            replaced.jobs.map (·.registration.name) == #["count"] &&
            boundTo replaced "C-c b" == some (invoke "one") &&
            replaced.modes.map (·.mode.name) == #["listing"] &&
            (replaced.ex? "w").isSome) },
    { name :=
        "an owner's faces are replaced as a set, in their order, and another owner's are left: the definitions are every owner's, oldest first, and the commands are untouched"
      run :=
        let theirs := defined "keyword" (coloured 1)
        let registry : Config.Registry :=
          ((({} : Config.Registry).replace .config #[registration "greet" "1"]).replaceFaces other
                #[theirs]).replaceFaces
            .config #[defined "keyword" (coloured 2), defined "comment" (coloured 3)]
        let replaced := registry.replaceFaces .config #[defined "string" (coloured 4)]
        pure
          (registry.definitions ==
              #[theirs, defined "keyword" (coloured 2), defined "comment" (coloured 3)] &&
            replaced.definitions == #[theirs, defined "string" (coloured 4)] &&
            (replaced.replaceFaces .config #[]).definitions == #[theirs] &&
            replaced.names == #["greet"]) }]

/-- The invocation of the command `filling name` fills `role` with. -/
def filled (name : String) (role : Role) : Invocation :=
  invoke s!"{name}-{role.name}"

/-- What the active keymaps `registry` makes for the test scheme, in
`state`, for `view`, make of the keys `role` is on. -/
def activeLookup (registry : Config.Registry) (state : EditorState) (view : ViewId) (role : Role) :
    Lookup Invocation :=
  Keymap.resolve (registry.activeMaps TestScheme.scheme state view) (roleKeys role)

/-- The checks of modes in the registry (`Editor/Config/Registry.lean`): a
mode's lineage, and the active keymaps of a view. -/
def modeRegistryChecks : List Check :=
  [{  name :=
        "a lineage is the mode then its parents, and ends at a name with no mode and at a cycle"
      run :=
        let looped :=
          modeRegistry.replaceModes .config
            #[filling "a" [] (some "b"), filling "b" [] (some "a"),
              filling "orphan" [] (some "missing")]
        pure
          ((modeRegistry.lineage "child").map (·.name) == ["child", "base", "root"] &&
            (modeRegistry.lineage "root").map (·.name) == ["root"] &&
            (looped.lineage "a").map (·.name) == ["a", "b"] &&
            (looped.lineage "orphan").map (·.name) == ["orphan"] &&
            (looped.lineage "missing").isEmpty) },
    { name :=
        "the active keymaps of a view are its buffer's minor modes', the last added first, then its major mode's lineage's, then the global keymap"
      run :=
        pure <|
          match onTextModel (withModes "major" ["m1", "m2"]) with
          | none => false
          | some state =>
            let lookup := activeLookup modeRegistry state ⟨0⟩
            (modeRegistry.activeMaps TestScheme.scheme state ⟨0⟩).length == 7 &&
              lookup Role.nextItem == .bound (filled "m2" Role.nextItem) &&
              lookup Role.previousItem == .bound (filled "m1" Role.previousItem) &&
              lookup Role.activate == .bound (filled "major" Role.activate) &&
              lookup Role.quit == .bound (invoke "global-quit") &&
              lookup Role.mark == .unbound &&
              activeLookup modeRegistry state ⟨1⟩ Role.nextItem == .bound (invoke "global-next") },
    { name :=
        "a derived mode's own role wins over its parents', and a role it does not fill falls to the nearest that fills it"
      run :=
        pure <|
          match onTextModel (withModes "child" []) with
          | none => false
          | some state =>
            let lookup := activeLookup modeRegistry state ⟨0⟩
            lookup Role.mark == .bound (filled "child" Role.mark) &&
              lookup Role.refresh == .bound (filled "base" Role.refresh) &&
              lookup Role.toggle == .bound (filled "root" Role.toggle) &&
              lookup Role.quit == .bound (invoke "global-quit") },
    { name := "a mode name no mode is registered under contributes nothing"
      run :=
        pure <|
          match onTextModel (withModes "ghost" ["phantom"]) with
          | none => false
          | some state =>
            (modeRegistry.activeMaps TestScheme.scheme state ⟨0⟩).length == 1 &&
              activeLookup modeRegistry state ⟨0⟩ Role.nextItem == .bound (invoke "global-next") },
    { name := "a view with no window has the global keymap alone"
      run :=
        pure <|
          match onTextModel (withModes "major" ["m1"]) with
          | none => false
          | some state =>
            (modeRegistry.activeMaps TestScheme.scheme state ⟨9⟩).length == 1 &&
              activeLookup modeRegistry state ⟨9⟩ Role.nextItem == .bound (invoke "global-next") }]

end ModelTest
