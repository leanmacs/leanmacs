import Editor.File
import Editor.File.Model
import Editor.Job
import Editor.Job.Model
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import EnvironmentApi
import EnvironmentApiTest.Contract
import EnvironmentApiTest.Model
import Mise
import Mise.Compiled
import MiseTest.Check

/-!
# Model tests: `Mise.lean` and `Mise/Compiled.lean`

The model tests of `Mise.lean` and `Mise/Compiled.lean`: `miseChecks`, the
package's registration, its setting, its source and `environment-api`'s
contract held on the model rig; and `miseLookupChecks`, a child's
environment looked up by mise on the models, as a host installs the
package's value. The test driver's root, `MiseTest/Model.lean`, runs them;
its module doc says what each shows.
-/

namespace MiseTest

open Editor
open EnvironmentApiTest

/-- The directory sources `Mise.package` registers, as a host collects them. -/
def registeredSources : Array EnvironmentApi.DirectorySource :=
  registeredAt EnvironmentApi.DirectorySource Mise.package

/-- The layers a host installs with the package registered and no config:
its value alone. -/
def packageLayers : Process.Registered :=
  (EnvironmentApi.registered registeredSources #[] Process.inheritedName).1

/-- The layers a host installs with the package registered and config's
`Mise.executable path` after it. -/
def atLayers (path : System.FilePath) : Process.Registered :=
  (EnvironmentApi.registered (registeredSources.push (Mise.at path)) #[] Process.inheritedName).1

/-- What `mise env --json` prints, in its layout: one name a line, indented
two spaces. -/
def jsonOf (variables : Array (String × String)) : String :=
  "{\n" ++
    ",\n".intercalate
      (variables.toList.map fun (name, value) => s!"  {name.quote}: {value.quote}") ++
    "\n}\n"

/-- The program and stamp names of `value`'s source in `host`. -/
def sourceShape (value : EnvironmentApi.DirectorySource) (host : Process.Host) :
    Option (String × Process.Program × Array String) :=
  (value.source host).map fun source => (source.name, source.program, source.stampNames)

/-- Whether every sentence of `contract` holds. -/
def contractHolds (contract : List (String × IO Bool)) : IO Bool :=
  contract.allM (·.2)

/-- The checks of the package's registration, its setting and its source
(`Mise.lean`, `Mise/Compiled.lean`). -/
def miseChecks : List Check :=
  [{  name :=
        "the package registers one directory source, named mise: no lookup in the headless mode, and in the window mode mise at the first of the usual places there is, skipped with none, kept by mise's four config files"
      run :=
        pure
          (registeredSources.map (·.name) == #["mise"] &&
            registeredSources.all fun value =>
              sourceShape value .headless == none &&
                sourceShape value (.window (some "/u")) ==
                  some ("mise", .firstOf (Mise.candidates (some "/u")) .skip, Mise.stampNames)) },
    { name :=
        "the usual places are ~/.local/bin/mise under the home directory, if there is one, then /opt/homebrew/bin/mise and /usr/local/bin/mise"
      run :=
        pure
          (Mise.candidates (some "/u") ==
              #["/u/.local/bin/mise", "/opt/homebrew/bin/mise", "/usr/local/bin/mise"].map
                System.FilePath.mk &&
            Mise.candidates none ==
              #["/opt/homebrew/bin/mise", "/usr/local/bin/mise"].map System.FilePath.mk) },
    { name :=
        "Mise.executable registers mise at an absolute path in every mode, refuses a relative path, and replaces the package's value in its place"
      run :=
        let ordered :=
          EnvironmentApi.DirectorySource.ordered (registeredSources.push (Mise.at "/opt/mise"))
        pure
          ((match Config.Registrations.ofSetup (Mise.executable "bin/mise") with
            | .error said => said == Mise.relativePath "bin/mise"
            | .ok _ => false) &&
            (match Config.Registrations.ofSetup (Mise.executable "/opt/mise") with
            | .ok collected => collected.extensions.size == 1
            | .error _ => false) &&
            Mise.relativePath "bin/mise" == "the path to mise must be absolute: bin/mise" &&
            ordered.size == 1 &&
            ordered.all fun value =>
              sourceShape value .headless == some ("mise", .at "/opt/mise", Mise.stampNames)) },
    { name :=
        "Mise.executable called twice in one setup is refused with a message naming the setting, whatever the paths; the package's own setup, and one call in config's, are each accepted"
      run :=
        let refused (setup : SetupM Unit) : Option String :=
          match Config.Registrations.ofSetup setup with
          | .error said => some said
          | .ok _ => none
        let twice (first second : System.FilePath) : SetupM Unit := do
          Mise.executable first
          Mise.executable second
        pure
          (refused (twice "/opt/mise" "/usr/local/bin/mise") ==
              some (Config.Registrations.settingTwice "Mise.executable") &&
            refused (twice "/opt/mise" "/opt/mise") ==
              some (Config.Registrations.settingTwice "Mise.executable") &&
            refused Mise.package.setup == none &&
            refused (Mise.executable "/opt/mise") == none) },
    { name :=
        "the mise source runs mise env --json in the directory over the environment so far, and reads a JSON object of strings"
      run :=
        let source := Mise.source (.at "/m")
        pure
          (source.command "/m" "/p/d" { set := #[("A", "a")] } ==
              { program := "/m", arguments := #["env", "--json"], directory := "/p/d"
                environment := { set := #[("A", "a")] } } &&
            source.command "/m" "/p/d" {} == Mise.lookupCommand "/m" "/p/d" &&
            source.output == "a JSON object of strings" &&
            (match source.parse "{\"A\":\"a\"}".toUTF8 with
            | .ok variables => variables == #[("A", "a")]
            | .error _ => false)) },
    { name :=
        "the mise source's stamp paths of /p/d are mise's four config names in /p/d, then in /p, then in /"
      run :=
        let four (directory : String) : Array System.FilePath :=
          #[s!"{directory}mise.toml", s!"{directory}.mise.toml", s!"{directory}.tool-versions",
                s!"{directory}mise.local.toml"].map
            System.FilePath.mk
        let names := (Mise.source (.at "/m")).stampNames
        pure
          (Process.stampPaths names "/p/d" == four "/p/d/" ++ four "/p/" ++ four "/" &&
            Process.stampPaths names "/p/d/" == Process.stampPaths names "/p/d") },
    { name := "mise at a path keeps environment-api's directory-source contract on the model rig"
      run :=
        contractHolds
          (directoryContract Mise.package "mise"
            (modelDirectoryRig (Mise.at "/opt/mise") .headless jsonOf)) }]

/-- The command the lookup checks start in `/p/d`: a bare `lake`, with a
variable of its own set and one unset. -/
def lakeBuild : Process.Command :=
  { program := "lake", arguments := #["build"]
    environment := { set := #[("A", "own")], unset := #["DROP"] }, directory := "/p/d" }

/-- What the lookup prints for `/p/d`: a `PATH`, a variable the command sets
too, one it unsets, and one of its own. -/
def lookupJson : String :=
  "{\"PATH\":\"/m/bin:/usr/bin\",\"A\":\"mise\",\"DROP\":\"x\",\"B\":\"b\"}"

/-- `command` with the lookup's variables of `lookupJson` set under its own. -/
def mergedOf (command : Process.Command) : Process.Command :=
  { command with
    environment :=
      { set := #[("PATH", "/m/bin:/usr/bin"), ("B", "b"), ("A", "own")], unset := #["DROP"] } }

/-- `command` in `directory`. -/
def movedTo (command : Process.Command) (directory : System.FilePath) : Process.Command :=
  { command with directory }

/-- A file model holding each of `paths`, written in that order. -/
def filesAt (paths : List System.FilePath) : FileModel :=
  paths.foldl (fun model path => model.withFile path "x".toUTF8) {}

/-- `model` with the file at `path` gone. -/
def withoutFile (model : FileModel) (path : System.FilePath) : FileModel :=
  { model with files := model.files.filter (·.path != path) }

/-- Whether `requests` read the stamp of any of `paths`. -/
def stampsAny (requests : Array JobRequest) (paths : List System.FilePath) : Bool :=
  requests.any fun request =>
    match request with
    | .file (.stamp path) => paths.contains path
    | _ => false

/-- The job model the lookup checks start from: the files `files`, the
scripts of `mise` at `executable` printing `lookupJson` in each of
`directories` and of each command merged there, and the environments in the
mode `host` with `layers` installed, as a host installs them. -/
def lookupModel (layers : Process.Registered) (host : Process.Host) (files : FileModel)
    (executable : System.FilePath := "/opt/mise") (directories : List System.FilePath := ["/p/d"])
    (reply : Except ProcessError Process.Ran := printed lookupJson) (takes : Nat := 0) : JobModel :=
  let scripts : Array Process.Script :=
    directories.toArray.flatMap fun directory =>
      #[{ command := Mise.lookupCommand executable directory, reply, takes },
        { command := mergedOf (movedTo lakeBuild directory), reply := printed "built" },
        { command := movedTo lakeBuild directory, reply := printed "built inherited" }]
  { files, processes := { scripts },
    environments := ({ host } : Process.Environments).install layers }

/-- The checks of a child's environment looked up by mise on the models
(`docs/design/concurrency.md`, "A child's environment, as built"), with the
layers the package's registration gives, and config's `Mise.executable`
over it, as a host installs them: each runs jobs with `JobM.runModel` on one
`JobModel`, carried from job to job. They were the core's
(`ModelTest.environmentLookupChecks`) while mise was the core's. -/
def miseLookupChecks : List Check :=
  let candidates := ["/opt/homebrew/bin/mise", "/usr/local/bin/mise"].map System.FilePath.mk
  [{  name :=
        "the package's mise in the window mode runs the first candidate that exists: Homebrew's, with nothing under the home directory, and the home directory's once it is there"
      run :=
        let homebrew :=
          lookupModel packageLayers (.window (some "/u")) (filesAt candidates)
            "/opt/homebrew/bin/mise"
        let home :=
          lookupModel packageLayers (.window (some "/u"))
            (filesAt ("/u/.local/bin/mise" :: candidates)) "/u/.local/bin/mise"
        pure
          ((after (runsOn lakeBuild) homebrew).processes.started ==
              #[Mise.lookupCommand "/opt/homebrew/bin/mise" "/p/d", mergedOf lakeBuild] &&
            (after (runsOn lakeBuild) home).processes.started ==
              #[Mise.lookupCommand "/u/.local/bin/mise" "/p/d", mergedOf lakeBuild]) },
    { name :=
        "the package's mise in the window mode keeps what it resolved until a reload: with Homebrew's mise gone, a start in another directory still runs it and reads no candidate's stamp, and after install the next start resolves again"
      run :=
        let all : List System.FilePath := "/u/.local/bin/mise" :: candidates
        let model :=
          lookupModel packageLayers (.window (some "/u")) (filesAt candidates)
            "/opt/homebrew/bin/mise" (directories := ["/p/d", "/p/e"])
        let model :=
          { model with
            processes :=
              { model.processes with
                scripts :=
                  model.processes.scripts.push
                    { command := Mise.lookupCommand "/usr/local/bin/mise" "/p/d"
                      reply := printed lookupJson } } }
        let inE := movedTo lakeBuild "/p/e"
        let once := after (runsOn lakeBuild) model
        let gone := { once with files := withoutFile once.files "/opt/homebrew/bin/mise" }
        let second := after (runsOn inE) gone
        let installed := { second with environments := second.environments.install packageLayers }
        let third := after (runsOn lakeBuild) installed
        pure
          (second.processes.started ==
              #[Mise.lookupCommand "/opt/homebrew/bin/mise" "/p/d", mergedOf lakeBuild,
                Mise.lookupCommand "/opt/homebrew/bin/mise" "/p/e", mergedOf inE] &&
            !stampsAny (requestsOf (runsOn inE) gone) all &&
            stampsAny (requestsOf (runsOn lakeBuild) installed) all &&
            third.processes.started ==
              second.processes.started ++
                #[Mise.lookupCommand "/usr/local/bin/mise" "/p/d", mergedOf lakeBuild]) },
    { name :=
        "the package's mise in the window mode with none of the candidates starts the child as it would have"
      run :=
        pure
          ((after (runsOn lakeBuild)
                (lookupModel packageLayers (.window (some "/u")) {})).processes.started ==
            #[lakeBuild]) },
    { name :=
        "the package's mise in the headless mode starts the child as it would have and reads no stamp"
      run :=
        let model :=
          lookupModel packageLayers .headless (filesAt ("/u/.local/bin/mise" :: candidates))
            "/opt/homebrew/bin/mise"
        pure
          ((after (runsOn lakeBuild) model).processes.started == #[lakeBuild] &&
            !(requestsOf (runsOn lakeBuild) model).any fun request =>
                request matches .file (.stamp _)) },
    { name :=
        "with config's Mise.executable at a path, a run first runs mise env --json in its directory, then the command with the lookup's variables under its own: the bare name keeps its name and gets the lookup's PATH"
      run :=
        let model := lookupModel (atLayers "/opt/mise") .headless {}
        pure
          ((after (runsOn lakeBuild) model).processes.started ==
            #[Mise.lookupCommand "/opt/mise" "/p/d", mergedOf lakeBuild]) },
    { name :=
        "with config's Mise.executable at a path, a streaming start gets the lookup's variables the same way"
      run :=
        let model := lookupModel (atLayers "/opt/mise") .headless {}
        let model :=
          { model with
            processes :=
              { model.processes with
                streams :=
                  #[{ command := mergedOf lakeBuild, steps := #[.write .out "built\n".toUTF8] }] } }
        let starts : JobM Bool := do
          return (← Process.start lakeBuild { bound := 64 }) matches .ok _
        pure
          ((starts.runModel model).1 == .finished true &&
            (after starts model).processes.started ==
              #[Mise.lookupCommand "/opt/mise" "/p/d", mergedOf lakeBuild]) },
    { name :=
        "a second start in the directory runs no lookup; after mise.toml there or a parent's .tool-versions is rewritten, or a config file appears, the next one looks up again"
      run :=
        let model :=
          lookupModel (atLayers "/opt/mise") .headless
            (filesAt ["/p/d/mise.toml", "/p/.tool-versions"])
        let lookup := Mise.lookupCommand "/opt/mise" "/p/d"
        let once := after (runsOn lakeBuild) model
        let twice := after (runsOn lakeBuild) once
        let rewritten :=
          after (runsOn lakeBuild)
            { twice with files := twice.files.withFile "/p/d/mise.toml" "y".toUTF8 }
        let parent :=
          after (runsOn lakeBuild)
            { rewritten with files := rewritten.files.withFile "/p/.tool-versions" "y".toUTF8 }
        let appeared :=
          after (runsOn lakeBuild)
            { parent with files := parent.files.withFile "/.mise.toml" "y".toUTF8 }
        let merged := mergedOf lakeBuild
        pure
          (once.processes.started == #[lookup, merged] &&
            twice.processes.started == #[lookup, merged, merged] &&
            rewritten.processes.started == #[lookup, merged, merged, lookup, merged] &&
            parent.processes.started == #[lookup, merged, merged, lookup, merged, lookup, merged] &&
            appeared.processes.started ==
              #[lookup, merged, merged, lookup, merged, lookup, merged, lookup, merged]) },
    { name :=
        "a start in another directory runs its own lookup, and a reload's install drops every entry"
      run :=
        let model :=
          lookupModel (atLayers "/opt/mise") .headless {} (directories := ["/p/d", "/p/e"])
        let inD := after (runsOn lakeBuild) model
        let inE := after (runsOn (movedTo lakeBuild "/p/e")) inD
        let installed :=
          { inE with environments := inE.environments.install (atLayers "/opt/mise") }
        let again := after (runsOn lakeBuild) installed
        pure
          (inE.processes.started ==
              #[Mise.lookupCommand "/opt/mise" "/p/d", mergedOf lakeBuild,
                Mise.lookupCommand "/opt/mise" "/p/e", mergedOf (movedTo lakeBuild "/p/e")] &&
            again.processes.started ==
              inE.processes.started ++
                #[Mise.lookupCommand "/opt/mise" "/p/d", mergedOf lakeBuild]) },
    { name :=
        "a lookup that exits non-zero starts the child inherited and reports once for the directory; a second start looks up nothing and says nothing"
      run :=
        let model :=
          lookupModel (atLayers "/opt/mise") .headless {} (reply :=
            .ok { exit := .code 1, stdout := .empty, stderr := "not trusted\n".toUTF8 })
        let once := after (runsOn lakeBuild) model
        let twice := after (runsOn lakeBuild) once
        pure
          (once.processes.started.back? == some lakeBuild &&
            once.reported ==
              #[Process.failureMessage (.directory "/p/d" "mise") (.exited 1 "not trusted")] &&
            twice.processes.started == once.processes.started.push lakeBuild &&
            twice.reported == once.reported) },
    { name :=
        "a lookup whose output is not a JSON object of strings starts the child inherited and reports once for the directory"
      run :=
        let model := lookupModel (atLayers "/opt/mise") .headless {} (reply := printed "[1]")
        let once := after (runsOn lakeBuild) model
        let twice := after (runsOn lakeBuild) once
        pure
          (once.processes.started.back? == some lakeBuild &&
            once.reported ==
              #[Process.failureMessage (.directory "/p/d" "mise")
                  (.unparsable "a JSON object of strings" "it is not an object")] &&
            twice.processes.started == once.processes.started.push lakeBuild &&
            twice.reported == once.reported) },
    { name :=
        "a lookup that outlives the default limit of 5000 ms is killed at its start plus the limit, the child starts inherited, and the directory is reported once"
      run :=
        let model :=
          { lookupModel (atLayers "/opt/mise") .headless {} (takes := 6000) with now := 100 }
        let lookup := Mise.lookupCommand "/opt/mise" "/p/d"
        let once := after (runsOn lakeBuild) model
        let twice := after (runsOn lakeBuild) once
        pure
          (once.processes.started == #[lookup, lakeBuild] && once.processes.killed == #[lookup] &&
            once.now == 5100 &&
            once.reported ==
              #[Process.failureMessage (.directory "/p/d" "mise") (.timedOut 5000)] &&
            twice.processes.started == #[lookup, lakeBuild, lakeBuild] &&
            twice.reported == once.reported) },
    { name :=
        "a command that clears its environment runs no lookup, and a relative directory or program is refused as before, with no lookup"
      run :=
        let model := lookupModel (atLayers "/opt/mise") .headless {}
        let cleared := { lakeBuild with environment := { clear := true } }
        let model :=
          { model with
            processes :=
              { model.processes with
                scripts :=
                  model.processes.scripts.push { command := cleared, reply := printed "" } } }
        let relative := movedTo lakeBuild "p/d"
        let program := { lakeBuild with program := "bin/lake" }
        let refused (command : Process.Command) (error : ProcessError) : Bool :=
          match (Process.run command 1000).runModel model with
          | (.finished (.error refusal), after) =>
            refusal == error && after.processes.started.isEmpty
          | _ => false
        pure
          ((after (runsOn cleared) model).processes.started == #[cleared] &&
            refused relative .relativeDirectory &&
            refused program .relativeProgram) }]

end MiseTest
