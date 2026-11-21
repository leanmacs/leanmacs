import ConfigTest.Check
import ConfigTest.Support.Configs
import ConfigTest.Support.Hosts
import ConfigTest.Support.Keys
import ConfigTest.Support.Lines
import ConfigTest.Support.Shipped
import ConfigTest.Support.Syntax
import Editor.Config.Directory
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.Headless
import Editor.InputScheme.Vim.Default

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
of the core's Lake package and the kit's stand-ins make
(`Config.State.ofPackages` of `shippedPackages`), with the
default config's bindings, prefix names
and leaders installed for the owner `.config`, as a reload installs them
(`Config.Reload.install`). -/
def defaultRegistry (registrations : Config.Registrations) : IO Config.Registry := do
  let (state, _) : Config.State Config.Elaborate.Base Config.Elaborate.Handle × Array String :=
    Config.State.ofPackages shippedPackages
  let registry :=
    (state.registry.replaceBindings .config registrations.bindings).replacePrefixNames .config
      registrations.prefixNames
  return { registry with
      leader := registrations.leader, localLeader := registrations.localLeader }

/-- The commands the default config binds that no package of the core's
Lake package registers: the command prompt's, `execute-command`, and the
binding search's, `search-bindings`, which default packages register, and
the twelve of the files, the buffers, the workspace, project search and the
working sets, which the default packages of those features register. They
are written as text, as a reacher inside the core names a name another
package declares (`docs/design/extension-points.md`, "Reaches by name"):
the core cannot import a package. The interface packages of the features
declare them: `execute-command-api` and `binding-search-api` the first two,
`files-api` `open-file`, `save-buffer` and `reload-buffer`, `buffers-api`
`switch-buffer`, `list-buffers` and `close-buffer`, `project-api`
`find-file-in-workspace` and `find-file-in-project`, `project-search-api`
`project-search` and `project-search-symbol`, and `working-set-api`
`working-set-add` and `working-set-open`. That the default editor runs them
for their keys (`SPC :`, `SPC ?`, `SPC f f`, `SPC p f`, `SPC SPC`, `SPC p p`,
`SPC s p`, `SPC /`, `SPC *`, `SPC k a`, `SPC k o`) is the headless fixture
`tests/headless/default-config`'s. -/
def defaultPackageCommands : Array String :=
  #["execute-command", "search-bindings", "open-file", "save-buffer", "reload-buffer",
    "switch-buffer", "list-buffers", "close-buffer", "find-file-in-workspace",
    "find-file-in-project", "project-search", "project-search-symbol", "working-set-add",
    "working-set-open"]

/-- The checks of the default config `mise run install` ships
(`config/default`), read from the directory the fourth argument names: it
loads with no reload error, each binding names a registered command or one of
`defaultPackageCommands`, and each prefix it binds under the leader is named.
What its keys into the default packages do is the headless fixture
`tests/headless/default-config`'s. -/
def defaultConfigChecks (context : Context) : List Check :=
  [{  name := "the default config: a reload installs it with no diagnostic"
      run := do
        let files ← configFiles context.defaultConfig
        withVimHost context files fun session => do
            session.ask [.reload]
            let output ← session.output.get
            let installed := output.any (·.startsWith "reload 1: installed")
            let clean := !output.any (·.startsWith "diagnostic:")
            return installed && clean },
    { name :=
        "the default config: every binding names a command registered compiled, by the config, or one of the default packages' commands it binds, by name (defaultPackageCommands); <leader> f f is bound to open-file, <leader> : to execute-command, described Execute command, and <leader> ? to search-bindings, described Search bindings, <leader> p f and <leader> SPC to find-file-in-workspace, described Find file in workspace, <leader> p p to find-file-in-project, described Switch workspace, <leader> s p and <leader> / to project-search, described Search workspace, <leader> * to project-search-symbol, described Search symbol in workspace, <leader> k a to working-set-add, described Add to working set, and <leader> k o and <leader> RET to working-set-open, described Open working set"
      run := do
        let registrations ← defaultBuilt context
        let registry ← defaultRegistry registrations
        let unregistered :=
          registrations.bindings.filter fun binding =>
            (registry.find? binding.command).isNone &&
              !registrations.commands.any (·.name == binding.command) &&
              !defaultPackageCommands.contains binding.command
        unless unregistered.isEmpty do
          throw <| IO.userError s!"unregistered commands: {unregistered.toList.map (·.command)}"
        return !registrations.bindings.isEmpty &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> f f" &&
                  binding.command == "open-file") &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> :" &&
                  binding.command == "execute-command" &&
                  binding.desc == some "Execute command") &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> ?" &&
                  binding.command == "search-bindings" &&
                  binding.desc == some "Search bindings") &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> p f" &&
                  binding.command == "find-file-in-workspace" &&
                  binding.desc == some "Find file in workspace") &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> SPC" &&
                  binding.command == "find-file-in-workspace" &&
                  binding.desc == some "Find file in workspace") &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> p p" &&
                  binding.command == "find-file-in-project" &&
                  binding.desc == some "Switch workspace") &&
            ["<leader> s p", "<leader> /"].all
              (fun keys =>
                registrations.bindings.any fun binding =>
                  Key.strokeNotations binding.keys == keys && binding.command == "project-search" &&
                    binding.desc == some "Search workspace") &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> *" &&
                  binding.command == "project-search-symbol" &&
                  binding.desc == some "Search symbol in workspace") &&
            registrations.bindings.any
              (fun binding =>
                Key.strokeNotations binding.keys == "<leader> k a" &&
                  binding.command == "working-set-add" &&
                  binding.desc == some "Add to working set") &&
            ["<leader> k o", "<leader> <Enter>"].all fun keys =>
              registrations.bindings.any fun binding =>
                Key.strokeNotations binding.keys == keys && binding.command == "working-set-open" &&
                  binding.desc == some "Open working set" },
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
