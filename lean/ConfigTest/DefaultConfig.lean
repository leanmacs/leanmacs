import ConfigTest.Check
import ConfigTest.Support.Configs
import ConfigTest.Support.Hosts
import ConfigTest.Support.Keys
import ConfigTest.Support.Lines
import ConfigTest.Support.Syntax
import Editor.Config.Directory
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.Headless
import Editor.InputScheme.Vim.Default
import Editor.ProjectSearch.Run
import Editor.WorkingSet.Run
import Editor.Workspace.FindFile
import Editor.Workspace.FindInProject
import EditorCore.EditorPackage

/-!
# Config tests: the default config

The tests of the default config `mise run install` ships (`config/default`):
`defaultConfigChecks`, through a host of the Vim scheme that ships and on the
registry a host starts with. The default config is config, not a Lean module,
so this module mirrors none; it sits beside the mirrored ones under
`ConfigTest/`. The root module `ConfigTest` runs them; its module doc says what
each shows.
-/

namespace ConfigTest

open Editor

/-- The registrations of the default config (`config/default`, the
directory `context.defaultConfig` names), built as a reload builds them
(`Config.build`), under the Vim scheme that ships, with the real
elaborator. Throws with the diagnostics when the build is rejected, so a
check that fails says why. -/
def defaultBuilt (context : Context) : IO Config.Registrations := do
  let outcome ←
    Config.build Vim.Default.scheme context.elaborator
        (Config.Directory.source context.defaultConfig) Config.PackageFiles.none none none #[]
  match outcome.built with
  | some built =>
    return built.registrations
  | none =>
    throw <|
        IO.userError
          s!"the default config was rejected: {outcome.diagnostics.toList.map (·.message)}"

/-- The registry a host of the executable starts with, the one the packages
of the core's Lake package make (`Config.State.ofPackages` of
`EditorCore.EditorPackage.packages`), with the
default config's bindings, prefix names
and leaders installed for the owner `.config`, as a reload installs them
(`Config.Reload.install`). -/
def defaultRegistry (registrations : Config.Registrations) : IO Config.Registry := do
  let (state, _) : Config.State Config.Elaborate.Base Config.Elaborate.Handle × Array String :=
    Config.State.ofPackages EditorCore.EditorPackage.packages
  let registry :=
    (state.registry.replaceBindings .config registrations.bindings).replacePrefixNames .config
      registrations.prefixNames
  return { registry with
      leader := registrations.leader, localLeader := registrations.localLeader }

/-- Whether `lines` hold the status line of a prompt labelled `label`. Each
prompt opens a minibuffer view of its own, so a prompt's status line is
compared from its view's id on. -/
def promptOf (label : String) (lines : Array String) : Bool :=
  lines.any fun line => line.startsWith "status " && afterId line == afterId (promptStatus label)

/-- The checks of the default config `mise run install` ships
(`config/default`), read from the directory the fourth argument names: it
loads with no reload error and `SPC f f` opens a file, `SPC p f` and `SPC SPC`
open the workspace finder and `SPC p p` runs `find-file-in-project`, each binding names a
registered command, and each prefix it binds under the leader is named. -/
def defaultConfigChecks (context : Context) : List Check :=
  [{  name :=
        "the default config: a reload installs it with no diagnostic; SPC f f then runs open-file, which asks for a path, once that is cancelled SPC : opens the command prompt, and once that is cancelled SPC ? opens the binding search, which, once open is typed, lists SPC f f  open-file"
      run := do
        let files ← configFiles context.defaultConfig
        withRealVimHost context files fun session => do
            session.ask [.reload]
            let output ← session.output.get
            let installed := output.any (·.startsWith "reload 1: installed")
            let clean := !output.any (·.startsWith "diagnostic:")
            let before ← session.sceneLines
            session.typed "SPC f f"
            let joined := (← session.host.join patience) == .settled
            let after ← session.sceneLines
            session.typed "<Escape>"
            let cancelled ← session.sceneLines
            session.typed "SPC :"
            let rejoined := (← session.host.join patience) == .settled
            let commanding ← session.sceneLines
            session.typed "<Escape>"
            session.typed "SPC ?"
            let searched := (← session.host.join patience) == .settled
            let searching ← session.sceneLines
            -- The list shows only its first rows: typing `open` narrows it
            -- to the bindings that match.
            session.typed "o p e n"
            let narrowed := (← session.host.join patience) == .settled
            let opening ← session.sceneLines
            return installed && clean && joined && rejoined && searched && narrowed &&
                !before.contains (promptStatus Files.openPrompt) &&
                after.contains (promptStatus Files.openPrompt) &&
                !cancelled.contains (promptStatus Files.openPrompt) &&
                !promptOf ExecuteCommand.label cancelled &&
                promptOf ExecuteCommand.label commanding &&
                !promptOf BindingSearch.label commanding &&
                promptOf BindingSearch.label searching &&
                opening.any fun line =>
                  line.startsWith "view " && (afterId line).contains "SPC f f  open-file" },
    { name :=
        "the default config: SPC p f opens the workspace finder, once that is cancelled SPC SPC opens it again, and once that is cancelled SPC p p runs find-file-in-project, which says the scratch buffer is in no project"
      run := do
        let files ← configFiles context.defaultConfig
        withRealVimHost context files fun session => do
            session.ask [.reload]
            let output ← session.output.get
            let installed := output.any (·.startsWith "reload 1: installed")
            let clean := !output.any (·.startsWith "diagnostic:")
            let label := Workspace.FindFile.promptLabel "/"
            let before ← session.sceneLines
            session.typed "SPC p f"
            let joined := (← session.host.join patience) == .settled
            let finding ← session.sceneLines
            session.typed "<Escape>"
            let cancelled ← session.sceneLines
            session.typed "SPC SPC"
            let rejoined := (← session.host.join patience) == .settled
            let refinding ← session.sceneLines
            session.typed "<Escape>"
            let recancelled ← session.sceneLines
            session.typed "SPC p p"
            let switched := (← session.host.join patience) == .settled
            let switching ← session.sceneLines
            let said := s!", echo {(Workspace.FindInProject.noProject "scratch").quote}"
            return installed && clean && joined && rejoined && switched && !promptOf label before &&
                promptOf label finding &&
                !promptOf label cancelled &&
                promptOf label refinding &&
                !promptOf label recancelled &&
                switching.any fun line => (line.splitOn said).length == 2 },
    { name :=
        "the default config: every binding names a command registered compiled or by the config, <leader> f f is bound to open-file, <leader> : to execute-command, described Execute command, and <leader> ? to search-bindings, described Search bindings, <leader> p f and <leader> SPC to find-file-in-workspace, described Find file in workspace, <leader> p p to find-file-in-project, described Switch workspace, <leader> s p and <leader> / to project-search, described Search workspace, <leader> * to project-search-symbol, described Search symbol in workspace, <leader> k a to working-set-add, described Add to working set, and <leader> k o and <leader> RET to working-set-open, described Open working set"
      run := do
        let registrations ← defaultBuilt context
        let registry ← defaultRegistry registrations
        let unregistered :=
          registrations.bindings.filter fun binding =>
            (registry.find? binding.command).isNone &&
              !registrations.commands.any (·.name == binding.command)
        unless unregistered.isEmpty do
          throw <| IO.userError s!"unregistered commands: {unregistered.toList.map (·.command)}"
        return !registrations.bindings.isEmpty &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> f f" &&
                  binding.command == Files.openName) &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> :" &&
                  binding.command == ExecuteCommand.name &&
                  binding.desc == some "Execute command") &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> ?" &&
                  binding.command == BindingSearch.name &&
                  binding.desc == some "Search bindings") &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> p f" &&
                  binding.command == Workspace.FindFile.name &&
                  binding.desc == some "Find file in workspace") &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> SPC" &&
                  binding.command == Workspace.FindFile.name &&
                  binding.desc == some "Find file in workspace") &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> p p" &&
                  binding.command == Workspace.FindInProject.name &&
                  binding.desc == some "Switch workspace") &&
            ["<leader> s p", "<leader> /"].all
              (fun keys =>
                registrations.bindings.any fun binding =>
                  Key.strokeNotations binding.keys == keys &&
                    binding.command == ProjectSearch.name &&
                    binding.desc == some "Search workspace") &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> *" &&
                  binding.command == ProjectSearch.symbolName &&
                  binding.desc == some "Search symbol in workspace") &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> k a" &&
                  binding.command == WorkingSet.addName &&
                  binding.desc == some "Add to working set") &&
            ["<leader> k o", "<leader> <Enter>"].all fun keys =>
              registrations.bindings.any fun binding =>
                Key.strokeNotations binding.keys == keys &&
                  binding.command == WorkingSet.openName &&
                  binding.desc == some "Open working set" },
    { name :=
        "the default config: SPC k o runs working-set-open, which says the scratch buffer is in no workspace"
      run := do
        let files ← configFiles context.defaultConfig
        withRealVimHost context files fun session => do
            session.ask [.reload]
            session.typed "SPC k o"
            let ran := (← session.host.join patience) == .settled
            let lines ← session.sceneLines
            let said := s!", echo {(WorkingSet.noWorkspace WorkingSet.openName "scratch").quote}"
            return ran && lines.any fun line => (line.splitOn said).length == 2 },
    { name :=
        "the default config: every prefix it binds under the leader has a prefix name, and those prefixes are SPC f, SPC b, SPC w, SPC TAB, SPC h, SPC p, SPC s and SPC k, named project, search and working set"
      run := do
        let registrations ← defaultBuilt context
        let registry ← defaultRegistry registrations
        let leaders := registry.leaders Vim.Default.scheme
        let leader := leaders.leader.map Key.chord
        let mut prefixes : Array (List Key) := #[]
        for binding in registrations.bindings do
          let keys := (Key.expand leaders binding.keys).map Key.chord
          unless keys.take leader.length == leader do
            continue
          for n in [leader.length + 1:keys.length] do
            let begun := keys.take n
            unless prefixes.contains begun do
              prefixes := prefixes.push begun
        let unnamed :=
          prefixes.filter fun begun => (registry.prefixName? Vim.Default.scheme begun).isNone
        unless unnamed.isEmpty do
          throw <| IO.userError s!"unnamed prefixes: {unnamed.toList.map Key.notations}"
        let expected :=
          ["SPC f", "SPC b", "SPC w", "SPC TAB", "SPC h", "SPC p", "SPC s", "SPC k"].map fun text =>
            (keysOf text).map Key.chord
        return prefixes.size == expected.length && expected.all prefixes.contains &&
            registry.prefixName? Vim.Default.scheme ((keysOf "SPC p").map Key.chord) ==
              some "project" &&
            registry.prefixName? Vim.Default.scheme ((keysOf "SPC s").map Key.chord) ==
              some "search" &&
            registry.prefixName? Vim.Default.scheme ((keysOf "SPC k").map Key.chord) ==
              some "working set" }]

end ConfigTest
