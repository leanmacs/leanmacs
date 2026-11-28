import Editor.Appearance
import Editor.Command
import Editor.Command.Dispatch
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Candidate
import Editor.Completion.Display
import Editor.Completion.Style
import Editor.Config.Owner
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.Config.Session
import Editor.Config.Stores
import Editor.DisplayRules
import Editor.Ex.Line
import Editor.Extension
import Editor.Face
import Editor.Fold
import Editor.Fuzzy
import Editor.Fuzzy.Model
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Keymap
import Editor.Layout
import Editor.Link
import Editor.Menu
import Editor.Mode
import Editor.ModeLine
import Editor.Program
import Editor.Role
import Editor.Scene
import Editor.State
import Editor.TabBar
import Editor.Test.Config
import Editor.Test.Keys
import Editor.Test.Models
import Editor.Text
import Editor.Window
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.Modes

/-!
# Model tests: `Editor/Config/Registry.lean`

The model tests of `Editor/Config/Registry.lean`: `registryChecks` and
`modeRegistryChecks`. `modeRegistryChecks` are of modes in the registry. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

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

/-- What `apartScheme` binds a mode's key that runs `name` to: the
invocation of `name` with the argument `mode`. -/
def apartMode (name : String) : Invocation :=
  { command := name, arguments := [.str "mode"] }

/-- What `apartScheme` binds a key that runs `name` only in `states` to:
the invocation of `name` with the states' names as its arguments. -/
def apartState (states : List String) (name : String) : Invocation :=
  { command := name, arguments := states.map .str }

/-- The test scheme, with its localleader on `C-l`, apart from its leader,
and with a mode's key and a key bound for some states each bound to an
invocation told apart from the command's (`apartMode`, `apartState`). -/
def apartScheme : InputScheme :=
  { TestScheme.scheme with
    localLeader := [.key (controlKey "l")]
    modeCommand := apartMode
    stateCommand := apartState }

/-- The test scheme with the Vim scheme's leaders: the leader on `SPC` and
the localleader on `<leader> m`. -/
def spaceScheme : InputScheme :=
  { TestScheme.scheme with
    leader := keys "SPC"
    localLeader := [.leader, .key (charKey "m")] }

/-- What is wrong under `scheme` with what `setup` collects
(`Registrations.problemUnder?`); `none` when nothing is, and when `setup` is
refused before (`Registrations.ofSetup`). -/
def problemUnder (scheme : InputScheme) (setup : SetupM Unit) : Option String :=
  match Config.Registrations.ofSetup setup with
  | .ok collected => collected.problemUnder? scheme
  | .error _ => none

/-- The binding of the key string `text` to `command` in the prompt category
`category`. -/
def inCategory (text command category : String) : Config.KeyBinding :=
  { binding text command with category := some category }

/-- The styles of the registry checks, written here and registered as a
package's would be: `fuzzy`, which keeps the candidates the text starts,
`orderless`, which keeps those that hold it, and `path`, which keeps every
candidate. Only their names and what they keep are read. -/
def writtenStyles : Array Completion.Style :=
  #[.keeping "fuzzy" fun text candidate => candidate.startsWith text,
    .keeping "orderless" fun text candidate => (candidate.splitOn text).length > 1,
    .keeping "path" fun _ _ => true]

/-- A display of the registry checks, written here: `minibuffer`, which
shows the texts of the first `rows` listed, one a row. -/
def cappedDisplay (rows : Nat) : Completion.Display :=
  { name := "minibuffer"
    sheet := fun showing =>
      { rows := (showing.listed.extract 0 rows).map fun listed => { text := listed.text } } }

/-- A value of an extension point of the registry's checks: a number. -/
structure Counted where
  /-- The number. -/
  n : Nat
  deriving TypeName

/-- The checks of the registry (`Editor/Config/Registry.lean`). -/
def registryChecks : List Check :=
  [{  name :=
        "the codec of a store's name is the latest owner's, an owner's codecs are replaced with its other entries, and the loop is told the codec with its owner's name and which jobs are reported; the registry says which jobs are restarted by their owner"
      run :=
        pure <|
          let theirs : Store Nat := { counter with version := 4 }
          let registrations : Config.Registrations :=
            { codecs := #[counter.codec],
              jobs :=
                #[{ jobRegistration "waited" "w" with reported := true },
                  { jobRegistration "rewatched" "r" with restarted := true }] }
          let registry :=
            (({} : Config.Registry).replaceOwned other registrations).replaceCodecs .config
              #[theirs.codec]
          let dropped := registry.replaceOwned .config {}
          let registered := registry.registered
          ((registry.codec? "counter").map fun (owner, codec) =>
                (owner, codec.declaration.version)) ==
              some (.config, 4) &&
            ((dropped.codec? "counter").map fun (owner, codec) =>
                (owner, codec.declaration.version)) ==
              some (other, 1) &&
            (registry.codec? "nobody").isNone &&
            ((registered.codec? "counter").map fun (owner, codec) =>
                (owner, codec.declaration.version)) ==
              some ("config", 4) &&
            registered.reported "waited" &&
            !registered.reported "nobody" &&
            !registered.reported "rewatched" &&
            registry.restarted "rewatched" &&
            !registry.restarted "waited" &&
            !registry.restarted "nobody" &&
            !(({} : Config.Registry).replaceJobs .config
                    #[jobRegistration "plain" "p"]).registered.reported
                "plain" },
    { name :=
        "a buffer's at-point chain is its minor modes', then its major mode's lineage, then every buffer's, config's before what ships, each once"
      run :=
        pure <|
          let modes : Array Mode :=
            #[{ name := "n", atPoint := ["c"] }, { name := "p", atPoint := ["b"] },
              { name := "m", parent := some "p", atPoint := ["a"] }]
          let registry :=
            ((({} : Config.Registry).replaceModes .compiled modes).replaceAtPointUses .config
                  #[(some "m", "d"), (none, "e")]).replaceAtPointUses
              .compiled #[(none, "words")]
          let repeated :=
            registry.replaceAtPointUses .compiled
              #[(none, "words"), (some "p", "a"), (some "m", "x")]
          registry.atPointNames (some "m") #["n"] == #["c", "d", "a", "b", "e", "words"] &&
            repeated.atPointNames (some "m") #["n"] == #["c", "d", "x", "a", "b", "e", "words"] &&
            registry.atPointNames none #[] == #["e", "words"] &&
            registry.atPointNames (some "nobody") #[] == #["e", "words"] },
    { name :=
        "the latest at-point entry of a name is the one found, config's over compiled's until a reload drops it; a name a use or a mode lists that nobody registered is unknown; the loop is told the lookup and the chain"
      run :=
        pure <|
          let words (pause : Nat) : Completion.AtPoint :=
            { Completion.AtPoint.silent "words" with pause := some pause }
          let compiled :=
            (({} : Config.Registry).replaceAtPoints .compiled #[words 240]).replaceModes .compiled
              #[{ name := "m", atPoint := ["lost"] }]
          let tuned :=
            (compiled.replaceAtPoints .config #[words 100]).replaceAtPointUses .config
              #[(none, "words"), (none, "gone")]
          let dropped := tuned.replaceAtPoints .config #[]
          (tuned.atPoint? "words").bind (·.pause) == some 100 &&
            (dropped.atPoint? "words").bind (·.pause) == some 240 &&
            (compiled.atPoint? "other").isNone &&
            tuned.unknownAtPoints == #["gone", "lost"] &&
            ((tuned.registered.atPoint "words").bind (·.pause)) == some 100 &&
            tuned.registered.atPointNames (some "m") #[] == #["lost", "words", "gone"] },
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
        let state : Config.State Unit Unit := { registry }
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
        "the registry's keymap expands a binding written with <leader> to the scheme's leader while the registry sets none, and to the leader the registry sets when it sets one"
      run :=
        let registry : Config.Registry :=
          ({} : Config.Registry).replaceBindings .config #[binding "<leader> f f" "find"]
        let led := { registry with leader := some (keys "C-x") }
        pure
          (boundTo registry "C-c f f" == some (invoke "find") &&
            boundTo led "C-x f f" == some (invoke "find") &&
            boundTo led "C-c f f" == none) },
    { name :=
        "a binding whose keys begin with the leader or the localleader in force, however written, is bound to what the scheme binds a mode's key to; one that begins with neither, to the command; one given states, to what the scheme binds a key for those states to, under a leader too"
      run :=
        let registry : Config.Registry :=
          ({} : Config.Registry).replaceBindings .config
            #[binding "<leader> a" "a", binding "<localleader> b" "b", binding "C-l c" "c",
              binding "C-c d" "d", binding "C-x e" "e",
              { binding "<leader> s" "s" with states := ["insert"] }]
        let bound (text : String) : Option Invocation :=
          (registry.keymap apartScheme).find? (keys text)
        pure
          (bound "C-c a" == some (apartMode "a") && bound "C-l b" == some (apartMode "b") &&
            bound "C-l c" == some (apartMode "c") &&
            bound "C-c d" == some (apartMode "d") &&
            bound "C-x e" == some (invoke "e") &&
            bound "C-c s" == some (apartState ["insert"] "s")) },
    { name :=
        "two bindings written apart whose keys are one sequence under the leaders in force are bound twice, and the refusal names the keys and both ways they are written"
      run :=
        pure
          (problemUnder spaceScheme
                (do
                  bindKey "<leader> f" "a"
                  bindKey "SPC f" "b") ==
              some "the keys `SPC f` are bound twice: as `<leader> f` and as `SPC f`" &&
            problemUnder spaceScheme
                (do
                  bindKey "<localleader> x" "a"
                  bindKey "<leader> m x" "b") ==
              some
                "the keys `SPC m x` are bound twice: as `<localleader> x` and as `<leader> m x`" &&
            problemUnder spaceScheme
                (do
                  leaderKey "C-x"
                  bindKey "<leader> f" "a"
                  bindKey "C-x f" "b") ==
              some "the keys `C-x f` are bound twice: as `<leader> f` and as `C-x f`" &&
            problemUnder spaceScheme
                (do
                  localLeaderKey "C-l"
                  bindKey "<localleader> x" "a"
                  bindKey "C-l x" "b") ==
              some "the keys `C-l x` are bound twice: as `<localleader> x` and as `C-l x`") },
    { name :=
        "bindings whose keys are apart under the leaders in force are not bound twice, though they would be under other leaders"
      run :=
        pure
          (problemUnder spaceScheme
                (do
                  bindKey "<leader> f" "a"
                  bindKey "C-x f" "b"
                  bindKey "<localleader> f" "c") ==
              none &&
            problemUnder TestScheme.scheme
                (do
                  bindKey "<leader> f" "a"
                  bindKey "SPC f" "b") ==
              none) },
    { name :=
        "the registry's keymap holds a sequence once, so of two bindings of one sequence for states apart only the later can run, and the earlier is gone in every state"
      run :=
        let registry : Config.Registry :=
          ({} : Config.Registry).replaceBindings .config
            #[{ binding "C-a" "first" with states := ["insert"] },
              { binding "C-a" "second" with states := ["normal"] }]
        let keymap : Keymap Invocation := registry.keymap apartScheme
        pure
          (keymap.find? (keys "C-a") == some (apartState ["normal"] "second") &&
            keymap.bindings.length == 1) },
    { name :=
        "bindings given states apart whose keys are one sequence under the leaders in force are bound twice, as the registry's keymap would keep only the later"
      run :=
        pure
          (problemUnder spaceScheme
              (do
                bindKey "<leader> a" "a" (states := [⟨"insert"⟩])
                bindKey "SPC a" "b" (states := [⟨"normal"⟩])) ==
            some "the keys `SPC a` are bound twice: as `<leader> a` and as `SPC a`") },
    { name :=
        "the menu bar's key equivalent of a command is never a binding written with a placeholder, whatever the leader is on"
      run :=
        let led (bindings : Array Config.KeyBinding) : Config.Registry :=
          { ({} : Config.Registry).replaceBindings .config bindings with
            leader := some (keys "s-o") }
        pure
          ((led #[binding "<leader>" "open"]).keyEquivalent? "open" == none &&
            ((led #[binding "s-o" "open"]).keyEquivalent? "open").isSome) },
    { name :=
        "the active keymaps of the open prompt's minibuffer view begin with its category's keymap, over the global one; another view, a prompt of another category and a prompt with no category do not have its bindings"
      run :=
        let registry : Config.Registry :=
          ({} : Config.Registry).replaceBindings .config
            #[binding "C-c g" "global", inCategory "C-c g" "in-c" "c",
              inCategory "C-c h" "only-c" "c"]
        let prompted (category : Option String) (state : EditorState) : EditorState :=
          { state with
            prompt :=
              some
                { label := "P: ", view := ⟨0⟩, asker := ⟨1⟩, continuation := invoke "answer"
                  candidates := { category } } }
        let lookup (state : EditorState) (view : ViewId) (text : String) : Lookup Invocation :=
          Keymap.resolve (registry.activeMaps TestScheme.scheme state view) (keys text)
        pure <|
          match onTextModel (withModes "major" []) with
          | none => false
          | some state =>
            let opened := prompted (some "c") state
            (registry.activeMaps TestScheme.scheme opened ⟨0⟩).length == 2 &&
              lookup opened ⟨0⟩ "C-c g" == .bound (invoke "in-c") &&
              lookup opened ⟨0⟩ "C-c h" == .bound (invoke "only-c") &&
              lookup opened ⟨1⟩ "C-c g" == .bound (invoke "global") &&
              lookup opened ⟨1⟩ "C-c h" == .unbound &&
              lookup (prompted (some "d") state) ⟨0⟩ "C-c g" == .bound (invoke "global") &&
              lookup (prompted (some "d") state) ⟨0⟩ "C-c h" == .unbound &&
              (registry.activeMaps TestScheme.scheme (prompted none state) ⟨0⟩).length == 1 &&
              lookup (prompted none state) ⟨0⟩ "C-c g" == .bound (invoke "global") },
    { name :=
        "the registry's keymap leaves a category's bindings out; the category's keymap holds them, bound by the leader and states rules, config's over compiled code's for one sequence; the menu bar's key equivalent never reads them"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceBindings .compiled
                #[inCategory "C-x t" "compiled" "c", inCategory "s-o" "open" "c"]).replaceBindings
            .config
            #[inCategory "C-x t" "config" "c", inCategory "<leader> a" "a" "c",
              { inCategory "C-x s" "s" "c" with states := ["insert"] }]
        let inC : Keymap Invocation := registry.categoryKeymap apartScheme "c"
        pure
          (boundTo registry "C-x t" == none && boundTo registry "s-o" == none &&
            inC.find? (keys "C-x t") == some (invoke "config") &&
            inC.find? (keys "C-c a") == some (apartMode "a") &&
            inC.find? (keys "C-x s") == some (apartState ["insert"] "s") &&
            (registry.categoryKeymap apartScheme "d").bindings.isEmpty &&
            registry.keyEquivalent? "open" == none) },
    { name :=
        "one sequence may be bound globally and in a category, and in two categories; bound twice in one category, as written or as it expands, it is refused, naming the category"
      run :=
        let apart : SetupM Unit := do
          bindKey "C-o e" "a"
          bindKey "C-o e" "b" (category := some "c")
          bindKey "C-o e" "d" (category := some "e")
        let written : SetupM Unit := do
          bindKey "C-o e" "a" (category := some "c")
          bindKey "C-o e" "b" (category := some "c")
        let refusedWith (setup : SetupM Unit) : Option String :=
          match Config.Registrations.ofSetup setup with
          | .error said => some said
          | .ok _ => none
        pure
          (refusedWith apart == none && problemUnder spaceScheme apart == none &&
            refusedWith written ==
              some "the keys `C-o e` are bound twice in the prompt category `c`" &&
            problemUnder spaceScheme
                (do
                  bindKey "<leader> e" "a" (category := some "c")
                  bindKey "SPC e" "b" (category := some "c")) ==
              some
                "the keys `SPC e` are bound twice in the prompt category `c`: as `<leader> e` and as `SPC e`" &&
            problemUnder spaceScheme
                (do
                  bindKey "<leader> e" "a" (category := some "c")
                  bindKey "SPC e" "b") ==
              none) },
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
        "what the loop is told of a registry's command names is every name a command is registered under, once: compiled names first, then config's, a config name that shadows a compiled one listed once at the compiled one's place; a reload that registers none of config's drops config's own names, and a registry with no command has none"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replace .compiled
                #[registration "load-theme" "1", registration "quit" "2"]).replace
            .config #[registration "mine" "3", registration "quit" "4"]
        pure
          (registry.registered.commandNames == #["load-theme", "quit", "mine"] &&
            registry.registered.commandNames == registry.names &&
            (registry.replace .config #[]).registered.commandNames == #["load-theme", "quit"] &&
            ({} : Config.Registry).registered.commandNames == #[]) },
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
        "the sources of a category are the names registered in it, each once, in the order first registered, compiled before config: config's source of a compiled name keeps its place and is the one found, and one of another category drops the name from it; the loop is told the same"
      run :=
        let compiled : Config.Registry :=
          ({} : Config.Registry).replaceSources .compiled #[.ofTexts "buffers" "buffer" #["a"]]
        let registry :=
          compiled.replaceSources .config
            #[.ofTexts "mine" "buffer" #[], .ofTexts "other-cat" "other" #[]]
        let replacing :=
          compiled.replaceSources .config
            #[.ofTexts "mine" "buffer" #[], .ofTexts "other-cat" "other" #[],
              .ofTexts "buffers" "buffer" #["b"]]
        let moved :=
          compiled.replaceSources .config
            #[.ofTexts "mine" "buffer" #[], .ofTexts "buffers" "elsewhere" #[]]
        let ownerOf (registry : Config.Registry) (name : String) : Option Config.Owner :=
          (registry.sources.findRev? (·.source.name == name)).map (·.owner)
        pure
          (registry.sourcesIn "buffer" == #["buffers", "mine"] &&
            registry.sourcesIn "other" == #["other-cat"] &&
            replacing.sourcesIn "buffer" == #["buffers", "mine"] &&
            ownerOf replacing "buffers" == some .config &&
            moved.sourcesIn "buffer" == #["mine"] &&
            moved.sourcesIn "elsewhere" == #["buffers"] &&
            registry.sourcesIn "none" == #[] &&
            ["buffer", "other", "none"].all fun category =>
              registry.registered.categorySources category == registry.sourcesIn category &&
                moved.registered.categorySources category == moved.sourcesIn category) },
    { name :=
        "a category's compiled default sits between config's two choices: the category gets it, owned by compiled, and other categories the fuzzy style; config's default leaves it and moves the others; config's choice for the category overrides it; a default naming no style falls through to the next"
      run :=
        let shipped : Config.Registry :=
          { ({} : Config.Registry).replaceStyles .compiled writtenStyles with
            styleDefaults := #[("file", "path")] }
        let entryOf (registry : Config.Registry) (category : String) : String × Config.Owner :=
          let entry := registry.styleEntry (some category)
          (entry.style.name, entry.owner)
        let defaulted := { shipped with styleChoices := #[(none, "orderless")] }
        let overridden :=
          { shipped with styleChoices := #[(some "file", "fuzzy"), (none, "orderless")] }
        let nameless := { shipped with styleDefaults := #[("file", "nope")] }
        pure
          (entryOf shipped "file" == ("path", .compiled) &&
            entryOf shipped "buffer" == ("fuzzy", .compiled) &&
            (entryOf defaulted "file").1 == "path" &&
            (entryOf defaulted "buffer").1 == "orderless" &&
            (entryOf overridden "file").1 == "fuzzy" &&
            (entryOf nameless "file").1 == "fuzzy" &&
            ({ nameless with styleChoices := #[(none, "orderless")] } |> (entryOf · "file")).1 ==
              "orderless" &&
            (shipped.matching.styleFor (some "file")).name == "path" &&
            shipped.matching.ownerFor (some "file") == .compiled) },
    { name :=
        "the matching follows config's choices over the registered styles: a category's chosen style, the chosen default for a category with none, and the style registered first, fuzzy, with no choice, or the core's own with none registered; a choice of a name nobody registered falls to the default and is reported once; config's style of a shipped name is the one found until config's styles are replaced, and with no choice config's style named fuzzy is the default, on a host that ships the fuzzy style and on one that ships none"
      run :=
        let shipped : Config.Registry :=
          ({} : Config.Registry).replaceStyles .compiled writtenStyles
        let mine : Completion.Style := .keeping "mine" fun _ _ => true
        let chosen : Config.Registry :=
          { shipped.replaceStyles .config #[mine] with
            styleChoices := #[(some "pick", "orderless"), (none, "mine")] }
        let unknown : Config.Registry :=
          { shipped with
            styleChoices := #[(some "pick", "nope"), (some "other", "nope"), (none, "gone")] }
        let keepingAll : Completion.Style := .keeping "fuzzy" fun _ _ => true
        let overridden : Config.Registry := shipped.replaceStyles .config #[keepingAll]
        let dropped := overridden.replaceStyles .config #[]
        let unshipped : Config.Registry :=
          ({} : Config.Registry).replaceStyles .config #[keepingAll]
        let nameOf (registry : Config.Registry) (category : Option String) : String :=
          (registry.matching.styleFor category).name
        let hitsOf (registry : Config.Registry) : Array Completion.Hit :=
          (Program.run (port := fuzzyPort) FuzzyModel.handle
              ((registry.matching.styleFor none).hits "z" #["a"]) ()).1
        pure
          (nameOf chosen (some "pick") == "orderless" && nameOf chosen (some "other") == "mine" &&
            nameOf chosen none == "mine" &&
            nameOf shipped (some "pick") == "fuzzy" &&
            nameOf {} none == Completion.Style.unregistered.name &&
            nameOf unknown (some "pick") == "fuzzy" &&
            unknown.unknownStyles == #["nope", "gone"] &&
            chosen.unknownStyles == #[] &&
            (overridden.style? "fuzzy").isSome &&
            hitsOf overridden == #[.ofIndex 0] &&
            hitsOf dropped == #[] &&
            hitsOf unshipped == #[.ofIndex 0] &&
            hitsOf {} == #[]) },
    { name :=
        "the matching says who registered the style each category gets: config for a category config chose its own style for, and for the default config's style; compiled for a shipped style chosen by config, for the shipped default, and on a registry with no style"
      run :=
        let shipped : Config.Registry :=
          ({} : Config.Registry).replaceStyles .compiled writtenStyles
        let mine : Completion.Style := .keeping "mine" fun _ _ => true
        let chosen : Config.Registry :=
          { shipped.replaceStyles .config #[mine] with
            styleChoices := #[(some "pick", "orderless"), (some "own", "mine")] }
        let defaulted : Config.Registry :=
          { shipped.replaceStyles .config #[mine] with styleChoices := #[(none, "mine")] }
        pure
          (chosen.matching.ownerFor (some "own") == .config &&
            chosen.matching.ownerFor (some "pick") == .compiled &&
            chosen.matching.ownerFor (some "other") == .compiled &&
            chosen.matching.ownerFor none == .compiled &&
            defaulted.matching.ownerFor none == .config &&
            defaulted.matching.ownerFor (some "pick") == .config &&
            shipped.matching.ownerFor none == .compiled &&
            ({} : Config.Registry).matching.ownerFor none == .compiled) },
    { name :=
        "the matching's style and owner for a category are the one style entry the category resolves to: its style, by what it matches, and its owner, on registries with choices, with a choice of a name nobody registered, with config's style named fuzzy over the shipped one and with none; with no entry, the core's own style, as compiled's"
      run :=
        let shipped : Config.Registry :=
          ({} : Config.Registry).replaceStyles .compiled writtenStyles
        let mine : Completion.Style := .keeping "mine" fun _ _ => true
        let keepingAll : Completion.Style := .keeping "fuzzy" fun _ _ => true
        let overridden : Config.Registry := shipped.replaceStyles .config #[keepingAll]
        let registries : List Config.Registry :=
          [{}, shipped, overridden, overridden.replaceStyles .config #[],
            ({} : Config.Registry).replaceStyles .config #[keepingAll],
            { shipped.replaceStyles .config #[mine] with
              styleChoices := #[(some "pick", "orderless"), (some "own", "mine")] },
            { overridden.replaceStyles .config #[mine, keepingAll] with
              styleChoices := #[(none, "mine"), (some "pick", "fuzzy")] },
            { shipped with styleChoices := #[(some "pick", "nope"), (none, "gone")] }]
        let categories : List (Option String) := [none, some "pick", some "own", some "other"]
        let hitsOf (style : Completion.Style) : Array Completion.Hit :=
          (Program.run (port := fuzzyPort) FuzzyModel.handle (style.hits "z" #["a"]) ()).1
        let agrees (registry : Config.Registry) (category : Option String) : Bool :=
          let entry := registry.styleEntry category
          let style := registry.matching.styleFor category
          registry.matching.ownerFor category == entry.owner && style.name == entry.style.name &&
            hitsOf style == hitsOf entry.style
        let empty := ({} : Config.Registry).styleEntry none
        pure
          (registries.all (fun registry => categories.all (agrees registry)) &&
            (overridden.styleEntry none).owner == .config &&
            hitsOf (overridden.styleEntry (some "pick")).style == #[.ofIndex 0] &&
            empty.owner == .compiled &&
            empty.style.name == Completion.Style.unregistered.name &&
            hitsOf empty.style == #[]) },
    { name :=
        "the displaying follows config's choices over the registered displays: a category's chosen display, the chosen default for a category with none, and the display registered first, minibuffer, with no choice; config's display named minibuffer is used in the shipped one's place, so it sets the rows, until config's displays are replaced; a choice of a name nobody registered falls to the default and is reported once; with no entry, the core's own display, as compiled's"
      run :=
        let shipped : Config.Registry :=
          ({} : Config.Registry).replaceDisplays .compiled #[cappedDisplay 10]
        let plain := Completion.Display.plain "plain"
        let chosen : Config.Registry :=
          { shipped.replaceDisplays .config #[plain] with
            displayChoices := #[(some "pick", "plain")] }
        let defaulted : Config.Registry :=
          { shipped.replaceDisplays .config #[plain] with displayChoices := #[(none, "plain")] }
        let three := shipped.replaceDisplays .config #[cappedDisplay 3]
        let unknown : Config.Registry :=
          { shipped with
            displayChoices := #[(some "pick", "nope"), (some "other", "nope"), (none, "gone")] }
        let showing : Completion.Showing :=
          { listed := (Array.range 15).map fun index => .of (.ofText s!"c{index}") }
        let nameOf (registry : Config.Registry) (category : Option String) : String :=
          (registry.displaying.displayFor category).name
        let rowsOf (registry : Config.Registry) (category : Option String) : Nat :=
          ((registry.displaying.displayFor category).sheet showing).rows.size
        pure
          (nameOf chosen (some "pick") == "plain" && nameOf chosen (some "other") == "minibuffer" &&
            nameOf chosen none == "minibuffer" &&
            nameOf defaulted (some "pick") == "plain" &&
            nameOf defaulted none == "plain" &&
            rowsOf chosen (some "pick") == 15 &&
            rowsOf shipped none == 10 &&
            rowsOf three none == 3 &&
            rowsOf three (some "pick") == 3 &&
            (three.displayEntry none).owner == .config &&
            rowsOf (three.replaceDisplays .config #[]) none == 10 &&
            nameOf {} none == Completion.Display.unregistered.name &&
            rowsOf {} none == 15 &&
            (({} : Config.Registry).displayEntry none).owner == .compiled &&
            nameOf unknown (some "pick") == "minibuffer" &&
            unknown.unknownDisplays == #["nope", "gone"] &&
            chosen.unknownDisplays == #[] &&
            (three.display? "minibuffer").isSome &&
            (({} : Config.Registry).display? "plain").isNone) },
    { name :=
        "with no style registered, every category, and a prompt with none, is matched with the core's own style, ranked, owned by compiled: it lists what the fuzzy port ranks, in its order, with no ranges"
      run :=
        let empty : Config.Registry := {}
        let hitsOf (style : Completion.Style) : Array Completion.Hit :=
          (Program.run (port := fuzzyPort) FuzzyModel.handle (style.hits "ab" #["xab", "ab", "b"])
              ()).1
        pure
          ([none, some "pick", some "file"].all fun category =>
            let entry := empty.styleEntry category
            entry.owner == .compiled && entry.style.name == Completion.Style.unregistered.name &&
              (empty.matching.styleFor category).name == "ranked" &&
              hitsOf entry.style == #[.ofIndex 1, .ofIndex 0]) },
    { name :=
        "with two packages' styles registered and no choice, every category is matched with the style registered first, the earlier package's, owned by it"
      run :=
        let first : Config.Owner := { name := "first" }
        let second : Config.Owner := { name := "second" }
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceStyles first
                #[.keeping "one" fun _ _ => true, .keeping "two" fun _ _ => true]).replaceStyles
            second #[.keeping "three" fun _ _ => true]
        pure
          ([none, some "pick"].all fun category =>
            let entry := registry.styleEntry category
            entry.style.name == "one" && entry.owner == first) },
    { name :=
        "config's style of the name of the style registered first is used in its place as the default, owned by config, until config's styles are replaced"
      run :=
        let first : Config.Owner := { name := "first" }
        let registry : Config.Registry :=
          ({} : Config.Registry).replaceStyles first
            #[.keeping "one" fun _ _ => false, .keeping "two" fun _ _ => true]
        let mine := registry.replaceStyles .config #[.keeping "one" fun _ _ => true]
        let hitsOf (registry : Config.Registry) : Array Completion.Hit :=
          (Program.run (port := fuzzyPort) FuzzyModel.handle
              ((registry.matching.styleFor none).hits "z" #["a"]) ()).1
        pure
          ((mine.styleEntry none).owner == .config && hitsOf mine == #[.ofIndex 0] &&
            (mine.replaceStyles .config #[] |>.styleEntry none).owner == first &&
            hitsOf (mine.replaceStyles .config #[]) == #[]) },
    { name :=
        "with no display registered, every category, and a listing with none, is shown with the core's own display, plain, owned by compiled: the interface's model"
      run :=
        let empty : Config.Registry := {}
        let showing : Completion.Showing :=
          { listed := #[.of (.ofText "a"), .of (.ofText "b")], chosen := some 1 }
        pure
          ([none, some "pick", some "file"].all fun category =>
            let entry := empty.displayEntry category
            entry.owner == .compiled &&
              entry.display.name == Completion.Display.unregistered.name &&
              (empty.displaying.displayFor category).name == "plain" &&
              entry.display.sheet showing == (Completion.Display.plain "plain").sheet showing) },
    { name :=
        "with two packages' displays registered and no choice, every category is shown with the display registered first, the earlier package's, owned by it"
      run :=
        let first : Config.Owner := { name := "first" }
        let second : Config.Owner := { name := "second" }
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceDisplays first
                #[Completion.Display.plain "one", Completion.Display.plain "two"]).replaceDisplays
            second #[Completion.Display.plain "three"]
        pure
          ([none, some "pick"].all fun category =>
            let entry := registry.displayEntry category
            entry.display.name == "one" && entry.owner == first) },
    { name :=
        "config's display of the name of the display registered first is used in its place as the default, owned by config, until config's displays are replaced"
      run :=
        let first : Config.Owner := { name := "first" }
        let registry : Config.Registry :=
          ({} : Config.Registry).replaceDisplays first
            #[Completion.Display.plain "one", Completion.Display.plain "two"]
        let mine : Completion.Display :=
          { name := "one", sheet := fun _ => { rows := #[{ text := "mine" }] } }
        let configured := registry.replaceDisplays .config #[mine]
        let rowsOf (registry : Config.Registry) : Array String :=
          ((registry.displaying.displayFor none).sheet { listed := #[.of (.ofText "a")] }).rows.map
            (·.text)
        pure
          ((configured.displayEntry none).owner == .config && rowsOf configured == #["mine"] &&
            (configured.replaceDisplays .config #[] |>.displayEntry none).owner == first &&
            rowsOf (configured.replaceDisplays .config #[]) == #["  a"]) },
    { name :=
        "completion sources are held by owner and replaced as a set: the latest entry of a name is the one found, config's source of a compiled source's name while config registers it and the compiled one again once it does not; the loop is told what the lookup answers"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceSources .compiled
                #[.ofTexts "buffers" "compiled-buffer" #["a"],
                  .ofTexts "kept" "kept" #[]]).replaceSources
            .config #[.ofTexts "buffers" "config-buffer" #["b"], .ofTexts "mine" "mine" #[]]
        let replaced := registry.replaceSources .config #[]
        let category (found : Option Completion.Source) : Option String := found.map (·.category)
        let names := ["buffers", "kept", "mine", "nope"]
        pure
          (category (registry.source? "buffers") == some "config-buffer" &&
            category (registry.source? "kept") == some "kept" &&
            category (registry.source? "mine") == some "mine" &&
            category (registry.source? "nope") == none &&
            category (replaced.source? "buffers") == some "compiled-buffer" &&
            category (replaced.source? "mine") == none &&
            replaced.sources.size == 2 &&
            names.all fun name =>
              category (registry.registered.sources name) == category (registry.source? name) &&
                category (replaced.registered.sources name) == category (replaced.source? name)) },
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
            replaced.names == #["greet"]) },
    { name :=
        "a registry no menu is registered in has no menu bar, whatever else it holds; one with a menu has a bar of it"
      run :=
        let bound : Config.Registry :=
          ({} : Config.Registry).replaceBindings other #[.ofKeys (keys "s-o") "open"]
        let file : Submenu := { title := "File" }
        pure
          (({} : Config.Registry).menuBar? == none && bound.menuBar? == none &&
            (bound.replaceMenus other #[file]).menuBar? == some { menus := #[file] }) },
    { name :=
        "the menu bar is each title once, at the place it was first registered, as its latest entry: a later owner's menu of a title is shown at the first one's place, one of a new title comes after, and replacing the later owner's menus with none brings the first's back"
      run :=
        let titled (title item : String) : Submenu :=
          { title, items := #[.item item none (.system .about)] }
        let registry : Config.Registry :=
          ({} : Config.Registry).replaceMenus other #[titled "File" "theirs", titled "Edit" "edit"]
        let replaced :=
          registry.replaceMenus .config #[titled "Help" "help", titled "File" "config's"]
        pure
          (registry.menuBar? == some { menus := #[titled "File" "theirs", titled "Edit" "edit"] } &&
            replaced.menuBar? ==
              some
                {
                  menus :=
                    #[titled "File" "config's", titled "Edit" "edit", titled "Help" "help"] } &&
            (replaced.replaceMenus .config #[]).menuBar? == registry.menuBar? &&
            (replaced.replaceMenus other #[]).menuBar? ==
              some { menus := #[titled "Help" "help", titled "File" "config's"] }) },
    { name :=
        "the menu bar's command items show the keys the bindings give their commands, as menuOf fills a menu: a system item keeps its own key, and a chord a system item shows is no command item's"
      run :=
        let quit : KeyEquivalent := { character := 'q', modifiers := { superKey := true } }
        let app : Submenu :=
          { title := "App", role := some .app,
            items := #[.item "Quit" (some quit) (.system .quit)] }
        let file : Submenu :=
          { title := "File"
            items :=
              #[.item "Open…" none (.command "open"), .separator,
                .item "Save" none (.command "save"), .item "Close" none (.command "close")] }
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceMenus other #[app, file]).replaceBindings other
            #[.ofKeys (keys "s-o") "open", .ofKeys (keys "s-q") "save",
              .ofKeys (keys "C-x k") "close"]
        let opened : KeyEquivalent := { character := 'o', modifiers := { superKey := true } }
        pure
          (registry.menuBar? == some (registry.menuOf { menus := #[app, file] }) &&
            registry.menuBar? ==
              some
                {
                  menus :=
                    #[app,
                      { file with
                        items :=
                          #[.item "Open…" (some opened) (.command "open"), .separator,
                            .item "Save" none (.command "save"),
                            .item "Close" none (.command "close")] }] }) },
    { name :=
        "a job registered over an extension point holds a work that fails at once, saying it is started through `Config.State.work?`, and `workWith` makes its work from the values handed it at its point; a job with no point's `workWith` is its work"
      run :=
        let counting : Package :=
          { name := "counting"
            setup :=
              Extension.workJob Counted "count-values" fun values arguments =>
                Work.of (fun _ => pure (values.map (·.n), arguments.length)) fun (ns, count) =>
                  makes s!"{ns.toList} {count}" }
        let job := (Package.registered counting).jobs.find? (·.name == "count-values")
        let values (key : Lean.Name) : Array Dynamic :=
          if key == TypeName.typeName Counted then
            #[.mk ({ n := 1 } : Counted), .mk ({ n := 2 } : Counted)]
          else #[]
        pure
          ((job.map fun job => worked (job.work [])) ==
              some
                (.failed
                  "count-values: made over an extension point; it is started through Config.State.work?") &&
            (job.map fun job => worked (job.workWith values [.nat 7])) ==
              some (.finished #["[1, 2] 1"]) &&
            (job.map fun job => worked (job.workWith (fun _ => #[]) [])) ==
              some (.finished #["[] 0"]) &&
            worked ((jobRegistration "plain" "p").workWith values []) == .finished #["p"]) },
    { name :=
        "of the values at an extension point the registry answers config's alone, in order, where it is asked for config's: a package's value there, and config's value at another point, are not among them, and the loop is told the same"
      run :=
        let other : Lean.Name := `ModelTest.OtherPoint
        let key := TypeName.typeName Counted
        let counted (n : Nat) : Lean.Name × Dynamic := (key, .mk ({ n } : Counted))
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceExtensions { name := "counting" }
                #[counted 1, counted 2]).replaceExtensions
            .config #[counted 3, (other, .mk ({ n := 9 } : Counted)), counted 4]
        let numbers (values : Array Dynamic) : Array Nat :=
          values.filterMap fun value => (value.get? Counted).map (·.n)
        pure
          (numbers (registry.extensionsAt key) == #[1, 2, 3, 4] &&
            numbers (registry.configExtensionsAt key) == #[3, 4] &&
            numbers (registry.configExtensionsAt other) == #[9] &&
            numbers (registry.registered.answer (.configExtensions key)) == #[3, 4] &&
            numbers (registry.registered.answer (.extensions key)) == #[1, 2, 3, 4] &&
            numbers (RegistryRequest.bare (.configExtensions key)) == #[]) },
    { name :=
        "the loop is told the name of the base a host installs: config's choice when it made one, else the latest package's default, else inherited"
      run :=
        let defaulted : Config.Registry := { baseDefaults := #["first", "second"] }
        pure
          (({} : Config.Registry).registered.answer .environmentBase == Process.inheritedName &&
            defaulted.registered.answer .environmentBase == "second" &&
            { defaulted with environmentBase := some "chosen" }.registered.answer
                .environmentBase ==
              "chosen") },
    { name :=
        "the collector keeps a job over an extension point with its point, a host installs it with its owner, and `Package.registered` lists its name among the jobs"
      run :=
        let counting : Package :=
          { name := "counting"
            setup :=
              Extension.workJob Counted "count-values" (reported := true) fun _ _ =>
                Work.of (fun _ => pure ()) fun _ => pure () }
        let (state, refused) : Config.State Unit Unit × Array String :=
          Config.State.ofPackages #[counting]
        pure
          (refused.isEmpty &&
            ((Package.registered counting).jobs.map (·.name)) == #["count-values"] &&
            ((Package.registered counting).jobs.map fun job =>
                (job.over.map (·.1), job.reported)) ==
              #[(some (TypeName.typeName Counted), true)] &&
            (state.registry.findJob? "count-values").map (·.owner.name) == some "counting") },
    { name :=
        "an owned table holds each owner's items over the owners' before it, in the order the owners first appear: the latest owner's first, in its order, then the earlier owners' items it does not name"
      run :=
        let package : Config.Owner := { name := "package" }
        let entries : Array (Config.Owner × String × Nat) :=
          #[(package, "a", 1), (package, "b", 2), (.config, "b", 3), (package, "c", 4),
            (.config, "d", 5)]
        pure
          (Config.Registry.ownedTable entries (·.1) (·.2) (·.1) ==
              [("b", 3), ("d", 5), ("a", 1), ("c", 4)] &&
            Config.Registry.ownedTable (#[] : Array (Config.Owner × String × Nat)) (·.1) (·.2)
                (·.1) ==
              []) }]

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
    { name :=
        "the active keymaps bind a mode's suffix under the localleader the registry sets, over the leader it sets, and under the scheme's while it sets none"
      run :=
        let listing : Mode := { name := "listing", locals := [("x", "listing-run")] }
        let registry := ({} : Config.Registry).replaceModes .config #[listing]
        let led :=
          { registry with
            leader := some (keys "C-x"), localLeader := some [.leader, .key (charKey "m")] }
        let lookup (registry : Config.Registry) (state : EditorState) (text : String) :
          Lookup Invocation :=
          Keymap.resolve (registry.activeMaps TestScheme.scheme state ⟨0⟩) (keys text)
        pure <|
          match onTextModel (withModes "listing" []) with
          | none => false
          | some state =>
            lookup led state "C-x m x" == .bound (invoke "listing-run") &&
              lookup led state "C-c x" == .unbound &&
              lookup registry state "C-c x" == .bound (invoke "listing-run") },
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
              activeLookup modeRegistry state ⟨9⟩ Role.nextItem == .bound (invoke "global-next") },
    { name :=
        "in a buffer with links the links mode's keymaps go before its minor and major modes', and with no links, or no links mode registered, the buffer's own modes resolve as before"
      run :=
        let links := modeRegistry.replaceModes .config #[filling Links.modeName [Role.activate]]
        let linked (state : EditorState) : EditorState :=
          { state with
            buffers :=
              state.buffers.modify 0
                (·.map
                  ({ · with
                    links :=
                      #[{ start := 0, stop := 1, target := .command { command := "x" } }] })) }
        pure <|
          match onTextModel (withModes "major" ["m1"]) with
          | none => false
          | some state =>
            activeLookup links (linked state) ⟨0⟩ Role.activate ==
                .bound (filled Links.modeName Role.activate) &&
              activeLookup links (linked state) ⟨0⟩ Role.nextItem ==
                .bound (filled "m1" Role.nextItem) &&
              activeLookup links state ⟨0⟩ Role.activate == .bound (filled "major" Role.activate) &&
              activeLookup modeRegistry (linked state) ⟨0⟩ Role.activate ==
                .bound (filled "major" Role.activate) },
    { name :=
        "in a buffer with foldable ranges the folds mode's keymaps go after the links mode's and before its minor and major modes', and with no foldable range, or no folds mode registered, not at all; the command a role is filled with never comes from the folds mode"
      run :=
        let both :=
          modeRegistry.replaceModes .config
            #[filling Links.modeName [Role.activate],
              filling Folds.modeName [Role.toggle, Role.activate, Role.nextItem]]
        let folding (links : Bool) (state : EditorState) : EditorState :=
          { state with
            buffers :=
              state.buffers.modify 0
                (·.map fun buffer =>
                  { buffer with
                    folds := #[{ start := 0, stop := 1, key := "k", text := "…" }]
                    links :=
                      if links then
                        #[{ start := 0, stop := 1, target := .command { command := "x" } }]
                      else #[] }) }
        pure <|
          match onTextModel (withModes "major" ["m1"]) with
          | none => false
          | some state =>
            activeLookup both (folding true state) ⟨0⟩ Role.activate ==
                .bound (filled Links.modeName Role.activate) &&
              activeLookup both (folding false state) ⟨0⟩ Role.activate ==
                .bound (filled Folds.modeName Role.activate) &&
              activeLookup both (folding true state) ⟨0⟩ Role.toggle ==
                .bound (filled Folds.modeName Role.toggle) &&
              activeLookup both (folding true state) ⟨0⟩ Role.nextItem ==
                .bound (filled Folds.modeName Role.nextItem) &&
              activeLookup both state ⟨0⟩ Role.nextItem == .bound (filled "m1" Role.nextItem) &&
              activeLookup both state ⟨0⟩ Role.activate == .bound (filled "major" Role.activate) &&
              activeLookup modeRegistry (folding false state) ⟨0⟩ Role.nextItem ==
                .bound (filled "m1" Role.nextItem) &&
              both.roleCommand (some "major") #["m1"] Role.toggle == none &&
              both.roleCommand (some "major") #["m1"] Role.nextItem ==
                some (filled "m1" Role.nextItem).command },
    { name :=
        "the command a buffer's modes fill a role with is a minor mode's, the last added first, over the major mode's, a derived mode's over its parent's, never the links mode's, and none when no mode fills it"
      run :=
        let links := modeRegistry.replaceModes .config #[filling Links.modeName [Role.mark]]
        pure
          (links.roleCommand (some "major") #["m2", "m1"] Role.nextItem ==
              some (filled "m2" Role.nextItem).command &&
            links.roleCommand (some "major") #["m2", "m1"] Role.previousItem ==
              some (filled "m1" Role.previousItem).command &&
            links.roleCommand (some "major") #["m1"] Role.activate ==
              some (filled "major" Role.activate).command &&
            links.roleCommand (some "child") #[] Role.refresh ==
              some (filled "base" Role.refresh).command &&
            links.roleCommand (some "child") #[] Role.mark ==
              some (filled "child" Role.mark).command &&
            links.roleCommand (some "major") #[] Role.mark == none &&
            links.roleCommand none #[] Role.activate == none) }]

/-- The checks of what the registry holds for the key hints: a binding's
description on its keymap, and the prefix names, by owner, expanded against
the leaders in force. -/
def registryHintChecks : List Check :=
  [{  name := "the registry's keymap carries a binding's description on its expanded keys"
      run :=
        let registry : Config.Registry :=
          ({} : Config.Registry).replaceBindings .config
            #[{ binding "<leader> f f" "find" with desc := some "Find file" },
              binding "<leader> f g" "grep"]
        let keymap := registry.keymap TestScheme.scheme
        pure
          (keymap.describe? (keys "C-c f f") == some "Find file" &&
            keymap.describe? (keys "C-c f g") == none) },
    { name :=
        "a prefix name is found at its keys expanded against the leaders in force: the scheme's when config sets none, and config's when it does"
      run :=
        let named : Config.Registry :=
          ({} : Config.Registry).replacePrefixNames .config
            #[{ keys := strokes "<leader> f", name := "file" }]
        let leading := { named with leader := some (keys "C-x") }
        pure
          (named.prefixName? TestScheme.scheme (keys "C-c f") == some "file" &&
            named.prefixName? TestScheme.scheme (keys "C-x f") == none &&
            leading.prefixName? TestScheme.scheme (keys "C-x f") == some "file" &&
            leading.prefixName? TestScheme.scheme (keys "C-c f") == none) },
    { name :=
        "of two owners that name one prefix the later's name is found, and replacing one owner's names keeps the other's"
      run :=
        let both : Config.Registry :=
          (({} : Config.Registry).replacePrefixNames .compiled
                #[{ keys := strokes "C-x r", name := "rectangle" }]).replacePrefixNames
            .config #[{ keys := strokes "C-x r", name := "rect" }]
        let replaced := both.replacePrefixNames .config #[]
        pure
          (both.prefixName? TestScheme.scheme (keys "C-x r") == some "rect" &&
            replaced.prefixName? TestScheme.scheme (keys "C-x r") == some "rectangle" &&
            replaced.prefixNames.size == 1) },
    { name :=
        "a setup that names one prefix twice as it expands under the scheme's leaders is refused, naming both ways it was written"
      run :=
        let twice : SetupM Unit := do
          prefixName "<leader> f" "file"
          prefixName "SPC f" "files"
        pure
          (problemUnder spaceScheme twice ==
              some
                (Config.Registrations.prefixNamedTwiceAs (keys "SPC f") (strokes "<leader> f")
                  (strokes "SPC f")) &&
            problemUnder TestScheme.scheme twice == none) }]

end ModelTest
