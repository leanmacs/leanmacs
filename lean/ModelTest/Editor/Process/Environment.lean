import Editor.Diff
import Editor.File
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Fuzzy
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.Text
import Editor.Text.Model
import ModelTest.Check

/-!
# Model tests: `Editor/Process/Environment.lean`

The model tests of `Editor/Process/Environment.lean`: `processEnvironmentChecks`,
`environmentLookupChecks` and `environmentLayerChecks`. `environmentLookupChecks`
are of a child's environment looked up for its directory by the mise source;
`environmentLayerChecks` are of the layers, a base under two directory sources
the core does not name. The root module `ModelTest` runs them; its module doc
says what each shows.
-/

namespace ModelTest

open Editor

/-- What `mise env --json` prints, in its layout: one name a line, indented
two spaces, with a `PATH` of 400 characters. -/
def miseOutput : String :=
  let path := String.ofList (List.replicate 400 'p')
  "{\n  \"PATH\": \"" ++ path ++
    "\",\n  \"MACOSX_DEPLOYMENT_TARGET\": \"27.2\",\n  \"RUST\": \"1.98\"\n}\n"

/-- Whether `parseVariables` reads `bytes` as `expected`. -/
def readsVariables (bytes : ByteArray) (expected : Array (String × String)) : Bool :=
  match Process.parseVariables bytes with
  | .ok variables => variables == expected
  | .error _ => false

/-- Whether `parseVariables` refuses `text` with `why`. -/
def refusesVariables (text : String) (why : String) : Bool :=
  match Process.parseVariables text.toUTF8 with
  | .error said => said == why
  | .ok _ => false

/-- An entry of a lookup that failed with `failure`, its config files' stamps
`stamps`. -/
def failedEntry (failure : Process.Failure) (stamps : Array (Option File.Stamp) := #[]) :
    Process.Entry :=
  { stamps, found := .failed failure }

/-- The variables of `bytes` read as `NAME=value` lines: the fake sources'
output, which is no JSON, so the core is seen composing sources it does not
name. -/
def keyValues (bytes : ByteArray) : Except String (Array (String × String)) := do
  let some text := String.fromUTF8? bytes | throw "it is not UTF-8"
  ((text.splitOn "\n").filter (!·.isEmpty)).toArray.mapM fun line =>
      match line.splitOn "=" with
      | [name, value] => pure (name, value)
      | _ => throw s!"the line {line} is not NAME=value"

/-- `variables` written as `NAME=value` lines, which `keyValues` reads. -/
def linesOf (variables : Array (String × String)) : String :=
  String.join (variables.toList.map fun (name, value) => s!"{name}={value}\n")

/-- A source the core does not name: `name`, run at `path` with no arguments
in the directory it is given, over the environment so far, printing
`NAME=value` lines; its result kept by the stamps of `stampNames`. -/
def fakeSource (name : String) (path : System.FilePath) (stampNames : Array String := #[]) :
    Process.Source :=
  { name, program := .at path
    command := fun executable directory environment =>
      { program := executable.toString, directory, environment }
    parse := keyValues, output := "NAME=value lines", stampNames }

/-- The names of mise's config files, the mise source's stamp names, written
out. -/
def miseNames : Array String :=
  #["mise.toml", ".mise.toml", ".tool-versions", "mise.local.toml"]

/-- What the checks compare of `sources`: whether the base is the inherited
one, and each directory source's name, program and stamp names. -/
def shapeOf (sources : Process.Sources) : Bool × Array (String × Process.Program × Array String) :=
  (sources.base matches .inherited,
    sources.directories.map fun source => (source.name, source.program, source.stampNames))

/-- The checks of the pure part of a child's environment
(`Editor/Process/Environment.lean`): the parser of what mise prints, how the
layers' variables and a command's own environment combine, how config's
setting maps onto sources, the config files whose stamps keep an entry, the
shared state's answers and the messages. -/
def processEnvironmentChecks : List Check :=
  [{  name :=
        "layer lets the later layer win a shared name and keeps the order each layer gave the rest"
      run :=
        pure
          (Process.layer #[("A", "1"), ("B", "1"), ("C", "1")] #[("B", "2"), ("D", "2")] ==
              #[("A", "1"), ("C", "1"), ("B", "2"), ("D", "2")] &&
            Process.layer #[] #[("A", "1")] == #[("A", "1")] &&
            Process.layer #[("A", "1")] #[] == #[("A", "1")]) },
    { name :=
        "config's setting maps onto sources over the inherited base: inherited and auto in the headless mode none, auto in the window mode mise at the first candidate or skipped, mise with no path at the first candidate or reported, mise with a path at it"
      run :=
        let window : Process.Host := .window (some "/u")
        let mise (program : Process.Program) := (true, #[("mise", program, miseNames)])
        pure
          (shapeOf (Process.Setting.inherited.sources window) == (true, #[]) &&
            shapeOf (Process.Setting.inherited.sources .headless) == (true, #[]) &&
            shapeOf (Process.Setting.auto.sources .headless) == (true, #[]) &&
            shapeOf (Process.Setting.auto.sources window) ==
              mise (.firstOf (Process.miseCandidates (some "/u")) .skip) &&
            shapeOf ((Process.Setting.mise none).sources .headless) ==
              mise (.firstOf (Process.miseCandidates none) .report) &&
            shapeOf ((Process.Setting.mise none).sources window) ==
              mise (.firstOf (Process.miseCandidates (some "/u")) .report) &&
            shapeOf ((Process.Setting.mise (some "/m")).sources .headless) == mise (.at "/m") &&
            shapeOf ((Process.Setting.mise (some "/m")).sources window) == mise (.at "/m")) },
    { name :=
        "the mise source runs mise env --json in the directory over the environment so far, and reads a JSON object of strings"
      run :=
        let source := Process.miseSource (.at "/m")
        pure
          (source.command "/m" "/p/d" { set := #[("A", "a")] } ==
              { program := "/m", arguments := #["env", "--json"], directory := "/p/d"
                environment := { set := #[("A", "a")] } } &&
            source.command "/m" "/p/d" {} == Process.lookupCommand "/m" "/p/d" &&
            source.output == "a JSON object of strings" &&
            (match source.parse "{\"A\":\"a\"}".toUTF8 with
            | .ok variables => variables == #[("A", "a")]
            | .error _ => false)) },
    { name :=
        "the shared state says a failed base once, and again nothing; each directory source's failure says its own message, once for each directory"
      run :=
        let entry := failedEntry (.exited 1 "not trusted")
        let state : Process.Environments := {}
        let ((), state, base) := state.handle (.record (.base "login") entry)
        let ((), state, baseAgain) := state.handle (.record (.base "login") entry)
        let ((), state, first) := state.handle (.record (.directory "/p/d" "first") entry)
        let ((), state, second) := state.handle (.record (.directory "/p/d" "second") entry)
        let ((), state, firstAgain) := state.handle (.record (.directory "/p/d" "first") entry)
        let ((), state, firstE) := state.handle (.record (.directory "/p/e" "first") entry)
        let ((), _, secondE) := state.handle (.record (.directory "/p/e" "second") entry)
        let tail (source : String) := s!"; its children start without {source}'s variables"
        pure
          (base ==
              some
                "environment: the base, login: login exited with status 1: not trusted; children start without the base's variables" &&
            baseAgain.isNone &&
            first ==
              some ("environment: /p/d: first exited with status 1: not trusted" ++ tail "first") &&
            second ==
              some
                ("environment: /p/d: second exited with status 1: not trusted" ++ tail "second") &&
            firstAgain.isNone &&
            firstE ==
              some ("environment: /p/e: first exited with status 1: not trusted" ++ tail "first") &&
            secondE ==
              some
                ("environment: /p/e: second exited with status 1: not trusted" ++ tail "second")) },
    { name :=
        "installSources takes the sources and drops every entry, the base's included, and every resolved program, and keeps the mode and the limit"
      run :=
        let state : Process.Environments :=
          { host := .window (some "/u"), limit := 7
            sources := { directories := #[fakeSource "first" "/bin/first"] }
            programs := #[("mise", some "/m")]
            entries :=
              #[(.base "login", failedEntry (.signalled 9)),
                (.directory "/p" "first", failedEntry (.signalled 9))] }
        let after :=
          state.installSources
            { base := .lookup (fakeSource "login" "/bin/login") "/"
              directories := #[fakeSource "second" "/bin/second"] }
        pure
          (after.host == .window (some "/u") && after.limit == 7 && after.programs.isEmpty &&
            after.entries.isEmpty &&
            (match after.sources.base with
            | .lookup source directory => source.name == "login" && directory == "/"
            | .inherited => false) &&
            after.sources.directories.map (·.name) == #["second"]) },
    { name :=
        "a host's home directory is the window mode's, the one HOME names, and none with no HOME and in the headless mode"
      run :=
        pure
          (Process.Host.home (.window (some "/u")) == some "/u" &&
            Process.Host.home (.window none) == none &&
            Process.Host.home .headless == none) },
    { name :=
        "parseVariables reads mise's layout, a multi-line object with a PATH of 400 characters"
      run :=
        pure
          (readsVariables miseOutput.toUTF8
            #[("PATH", String.ofList (List.replicate 400 'p')),
              ("MACOSX_DEPLOYMENT_TARGET", "27.2"), ("RUST", "1.98")]) },
    { name :=
        "parseVariables reads every escape, a surrogate pair among them, and the empty object; the last of a name that comes twice wins"
      run :=
        pure
          (readsVariables
              "{\"A\":\"\\\" \\\\ \\/ \\b \\f \\n \\r \\t \\u00e9 \\ud83d\\ude00\",\"B\":\"1\",\"B\":\"2\"}".toUTF8
              #[("A", "\" \\ / \x08 \x0c \n \r \t é 😀"), ("B", "2")] &&
            readsVariables " { } ".toUTF8 #[]) },
    { name :=
        "parseVariables refuses a number, null, a nested object, an array, trailing text, bytes that are not UTF-8, a name holding =, an empty name and a NUL, each with its reason"
      run :=
        pure
          (refusesVariables "{\"A\":1}" "a value is not a string" &&
            refusesVariables "{\"A\":null}" "a value is not a string" &&
            refusesVariables "{\"A\":{}}" "a value is not a string" &&
            refusesVariables "[\"A\"]" "it is not an object" &&
            refusesVariables "{\"A\":\"a\"} x" "there is more after the object" &&
            (match Process.parseVariables ⟨#[0x7B, 0xFF, 0x7D]⟩ with
            | .error why => why == "it is not UTF-8"
            | .ok _ => false) &&
            refusesVariables "{\"A=B\":\"a\"}" "the name A=B holds =" &&
            refusesVariables "{\"\":\"a\"}" "a name is empty" &&
            refusesVariables "{\"A\":\"a\\u0000\"}" "a string holds a NUL" &&
            refusesVariables "{\"A\":\"a\nb\"}" "a string holds a control character" &&
            refusesVariables "{\"A\":\"\\ud83d\"}"
              "a high surrogate is not followed by a low one") },
    { name :=
        "a lookup's variables are set over the editor's, the command's own set wins over one of the same name, its unset removes one, and clear drops them all"
      run :=
        let variables := #[("PATH", "/m/bin"), ("A", "mise"), ("DROP", "x")]
        pure
          (Process.Environment.over variables {} == { set := variables } &&
            Process.Environment.over variables { set := #[("A", "own")], unset := #["DROP"] } ==
              { set := #[("PATH", "/m/bin"), ("A", "own")], unset := #["DROP"] } &&
            Process.Environment.over variables { clear := true, set := #[("ONLY", "x")] } ==
              { clear := true, set := #[("ONLY", "x")] }) },
    { name :=
        "the mise source's stamp paths of /p/d are mise's four config names in /p/d, then in /p, then in /"
      run :=
        let four (directory : String) : Array System.FilePath :=
          #[s!"{directory}mise.toml", s!"{directory}.mise.toml", s!"{directory}.tool-versions",
                s!"{directory}mise.local.toml"].map
            System.FilePath.mk
        let names := (Process.miseSource (.at "/m")).stampNames
        pure
          (Process.stampPaths names "/p/d" == four "/p/d/" ++ four "/p/" ++ four "/" &&
            Process.stampPaths names "/p/d/" == Process.stampPaths names "/p/d") },
    { name :=
        "the shared state gives back the entry a record kept; a failure recorded says its message once, the same failure again says nothing, and with new stamps it says it again"
      run :=
        let state : Process.Environments := {}
        let failure := Process.Failure.exited 1 "untrusted"
        let first := failedEntry failure #[none]
        let slot : Process.Slot := .directory "/p/d" "mise"
        let message := Process.failureMessage slot failure
        let ((), state, said) := state.handle (.record slot first)
        let (cached, state, quiet) := state.handle (.cached slot)
        let cached : Option Process.Entry := cached
        let ((), state, again) := state.handle (.record slot first)
        let ((), _, renewed) := state.handle (.record slot (failedEntry failure #[some ⟨1, 0, 3⟩]))
        let variables : Process.Entry := { stamps := #[], found := .variables #[("A", "a")] }
        let ((), _, found) :=
          ({} : Process.Environments).handle (.record (.directory "/p/e" "mise") variables)
        pure
          (said == some message && cached == some first && quiet.isNone && again.isNone &&
            renewed == some message &&
            found.isNone) },
    { name :=
        "install takes config's setting as sources and drops every resolved program and every entry, and keeps the mode and the limit"
      run :=
        let host : Process.Host := .window (some "/u")
        let state : Process.Environments :=
          { host, limit := 7, sources := (Process.Setting.mise none).sources host
            programs := #[("mise", some "/m")]
            entries := #[(.directory "/p" "mise", failedEntry (.signalled 9))] }
        let ((), after, said) := state.handle (.install .inherited)
        pure
          (shapeOf after.sources == (true, #[]) && after.host == host && after.limit == 7 &&
            after.programs.isEmpty &&
            after.entries.isEmpty &&
            said.isNone) },
    { name := "the policy is the sources, what each resolved to and the limit"
      run :=
        let state : Process.Environments :=
          { sources := (Process.Setting.mise none).sources .headless
            programs := #[("mise", none)] }
        let (policy, after, said) := state.handle .policy
        let policy : Process.Policy := policy
        pure
          (shapeOf policy.sources == shapeOf state.sources &&
            policy.programs == #[("mise", none)] &&
            policy.limit == 5000 &&
            shapeOf after.sources == shapeOf state.sources &&
            after.programs == state.programs &&
            after.entries == state.entries &&
            said.isNone) },
    { name := "each failure's message has its own words"
      run :=
        let say := Process.failureMessage (.directory "/p/d" "mise")
        let tail := "; its children start without mise's variables"
        pure
          (say (.exited 1 "not trusted") ==
              "environment: /p/d: mise exited with status 1: not trusted" ++ tail &&
            say (.exited 2 "") == "environment: /p/d: mise exited with status 2" ++ tail &&
            say (.signalled 9) == "environment: /p/d: mise was ended by signal 9" ++ tail &&
            say (.unparsable "a JSON object of strings" "it is not an object") ==
              "environment: /p/d: mise's output is not a JSON object of strings: it is not an object" ++
                tail &&
            say (.timedOut 5000) ==
              "environment: /p/d: mise did not finish within 5000 ms and was killed" ++ tail &&
            say (.refused (.denied "Permission denied")) ==
              "environment: /p/d: mise could not be run: the system does not allow it: Permission denied" ++
                tail &&
            say (.missing (Process.miseCandidates (some "/u"))) ==
              "environment: /p/d: mise is not at /u/.local/bin/mise, /opt/homebrew/bin/mise or /usr/local/bin/mise" ++
                tail) },
    { name :=
        "what a lookup's run came to: variables for status 0 and an object, and else the failure, with the first line of standard error"
      run :=
        let ran (exit : Process.Exit) (stdout stderr : String) : Except ProcessError Process.Ran :=
          .ok { exit, stdout := stdout.toUTF8, stderr := stderr.toUTF8 }
        let foundOf := Process.foundOf (Process.miseSource (.at "/m"))
        pure
          (foundOf (ran (.code 0) "{\"A\":\"a\"}" "") == .variables #[("A", "a")] &&
            foundOf (ran (.code 1) "" "first\nsecond\n") == .failed (.exited 1 "first") &&
            foundOf (ran (.signal 9) "" "") == .failed (.signalled 9) &&
            foundOf (ran (.code 0) "[1]" "") ==
              .failed (.unparsable "a JSON object of strings" "it is not an object") &&
            foundOf (.error .noSuchProcess) == .failed (.refused .noSuchProcess) &&
            foundOf (.error (.timedOut 5000)) == .failed (.timedOut 5000)) }]

/-- The requests `job` makes when it runs against the job port's model from
`model`, in order. -/
def requestsOf {α : Type} (job : JobM α) (model : JobModel) : Array JobRequest :=
  go 10000 job.run model #[]
where
  /-- The requests of `program` from `model`, with `fuel` steps at most. -/
  go : Nat → Program jobPort (Except String α) → JobModel → Array JobRequest → Array JobRequest
    | 0, _, _, seen => seen
    | _, .done _, _, seen => seen
    | fuel + 1, .step request next, model, seen =>
      let (reply, after) := JobModel.handle request model
      go fuel (next reply) after (seen.push request)

/-- A run that ends with the status 0 and prints `stdout`. -/
def printed (stdout : String) : Except ProcessError Process.Ran :=
  .ok { exit := .code 0, stdout := stdout.toUTF8, stderr := .empty }

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
`directories` and of each command merged there, and the environments with
`setting` and `host`. -/
def lookupModel (setting : Process.Setting) (host : Process.Host) (files : FileModel)
    (executable : System.FilePath := "/opt/mise") (directories : List System.FilePath := ["/p/d"])
    (reply : Except ProcessError Process.Ran := printed lookupJson) (takes : Nat := 0) : JobModel :=
  let scripts : Array Process.Script :=
    directories.toArray.flatMap fun directory =>
      #[{ command := Process.lookupCommand executable directory, reply, takes },
        { command := mergedOf (movedTo lakeBuild directory), reply := printed "built" },
        { command := movedTo lakeBuild directory, reply := printed "built inherited" }]
  { files, processes := { scripts }, environments := { host, sources := setting.sources host } }

/-- A run of `command` that the model answers. -/
def runsOn (command : Process.Command) : JobM Bool := do
  return (← Process.run command 1000) matches .ok _

/-- Runs `job` on the model, and gives the model after it. -/
def after {α : Type} (job : JobM α) (model : JobModel) : JobModel :=
  (job.runModel model).2

/-- The checks of a child's environment on the models (AC 1 to 5 of
`docs/design/concurrency.md`, "A child's environment, as built"): each runs
jobs with `JobM.runModel` on one `JobModel`, carried from job to job. -/
def environmentLookupChecks : List Check :=
  let candidates := ["/opt/homebrew/bin/mise", "/usr/local/bin/mise"].map System.FilePath.mk
  [{  name :=
        "auto in the window mode runs the first candidate that exists: Homebrew's, with nothing under the home directory, and the home directory's once it is there"
      run :=
        let homebrew :=
          lookupModel .auto (.window (some "/u")) (filesAt candidates) "/opt/homebrew/bin/mise"
        let home :=
          lookupModel .auto (.window (some "/u")) (filesAt ("/u/.local/bin/mise" :: candidates))
            "/u/.local/bin/mise"
        pure
          ((after (runsOn lakeBuild) homebrew).processes.started ==
              #[Process.lookupCommand "/opt/homebrew/bin/mise" "/p/d", mergedOf lakeBuild] &&
            (after (runsOn lakeBuild) home).processes.started ==
              #[Process.lookupCommand "/u/.local/bin/mise" "/p/d", mergedOf lakeBuild]) },
    { name :=
        "auto in the window mode keeps what it resolved until a reload: with Homebrew's mise gone, a start in another directory still runs it and reads no candidate's stamp, and after install the next start resolves again"
      run :=
        let all : List System.FilePath := "/u/.local/bin/mise" :: candidates
        let model :=
          lookupModel .auto (.window (some "/u")) (filesAt candidates) "/opt/homebrew/bin/mise"
            (directories := ["/p/d", "/p/e"])
        let model :=
          { model with
            processes :=
              { model.processes with
                scripts :=
                  model.processes.scripts.push
                    { command := Process.lookupCommand "/usr/local/bin/mise" "/p/d"
                      reply := printed lookupJson } } }
        let inE := movedTo lakeBuild "/p/e"
        let once := after (runsOn lakeBuild) model
        let gone := { once with files := withoutFile once.files "/opt/homebrew/bin/mise" }
        let second := after (runsOn inE) gone
        let installed := { second with environments := second.environments.install .auto }
        let third := after (runsOn lakeBuild) installed
        pure
          (second.processes.started ==
              #[Process.lookupCommand "/opt/homebrew/bin/mise" "/p/d", mergedOf lakeBuild,
                Process.lookupCommand "/opt/homebrew/bin/mise" "/p/e", mergedOf inE] &&
            !stampsAny (requestsOf (runsOn inE) gone) all &&
            stampsAny (requestsOf (runsOn lakeBuild) installed) all &&
            third.processes.started ==
              second.processes.started ++
                #[Process.lookupCommand "/usr/local/bin/mise" "/p/d", mergedOf lakeBuild]) },
    { name :=
        "mise with no path runs the first candidate that exists, in the headless mode and in the window mode"
      run :=
        let headless :=
          lookupModel (.mise none) .headless (filesAt candidates) "/opt/homebrew/bin/mise"
        let window :=
          lookupModel (.mise none) (.window (some "/u"))
            (filesAt ("/u/.local/bin/mise" :: candidates)) "/u/.local/bin/mise"
        pure
          ((after (runsOn lakeBuild) headless).processes.started ==
              #[Process.lookupCommand "/opt/homebrew/bin/mise" "/p/d", mergedOf lakeBuild] &&
            (after (runsOn lakeBuild) window).processes.started ==
              #[Process.lookupCommand "/u/.local/bin/mise" "/p/d", mergedOf lakeBuild] &&
            (after (runsOn lakeBuild) headless).reported.isEmpty) },
    { name :=
        "auto in the window mode with none of the candidates starts the child as it would have"
      run :=
        pure
          ((after (runsOn lakeBuild)
                (lookupModel .auto (.window (some "/u")) {})).processes.started ==
            #[lakeBuild]) },
    { name := "auto in the headless mode starts the child as it would have and reads no stamp"
      run :=
        let model :=
          lookupModel .auto .headless (filesAt ("/u/.local/bin/mise" :: candidates))
            "/opt/homebrew/bin/mise"
        pure
          ((after (runsOn lakeBuild) model).processes.started == #[lakeBuild] &&
            !(requestsOf (runsOn lakeBuild) model).any fun request =>
                request matches .file (.stamp _)) },
    { name :=
        "with mise at a path, a run first runs mise env --json in its directory, then the command with the lookup's variables under its own: the bare name keeps its name and gets the lookup's PATH"
      run :=
        let model := lookupModel (.mise (some "/opt/mise")) .headless {}
        pure
          ((after (runsOn lakeBuild) model).processes.started ==
            #[Process.lookupCommand "/opt/mise" "/p/d", mergedOf lakeBuild]) },
    { name := "with mise at a path, a streaming start gets the lookup's variables the same way"
      run :=
        let model := lookupModel (.mise (some "/opt/mise")) .headless {}
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
              #[Process.lookupCommand "/opt/mise" "/p/d", mergedOf lakeBuild]) },
    { name :=
        "a second start in the directory runs no lookup; after mise.toml there or a parent's .tool-versions is rewritten, or a config file appears, the next one looks up again"
      run :=
        let model :=
          lookupModel (.mise (some "/opt/mise")) .headless
            (filesAt ["/p/d/mise.toml", "/p/.tool-versions"])
        let lookup := Process.lookupCommand "/opt/mise" "/p/d"
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
          lookupModel (.mise (some "/opt/mise")) .headless {} (directories := ["/p/d", "/p/e"])
        let inD := after (runsOn lakeBuild) model
        let inE := after (runsOn (movedTo lakeBuild "/p/e")) inD
        let installed :=
          { inE with environments := inE.environments.install (.mise (some "/opt/mise")) }
        let again := after (runsOn lakeBuild) installed
        pure
          (inE.processes.started ==
              #[Process.lookupCommand "/opt/mise" "/p/d", mergedOf lakeBuild,
                Process.lookupCommand "/opt/mise" "/p/e", mergedOf (movedTo lakeBuild "/p/e")] &&
            again.processes.started ==
              inE.processes.started ++
                #[Process.lookupCommand "/opt/mise" "/p/d", mergedOf lakeBuild]) },
    { name :=
        "a lookup that exits non-zero starts the child inherited and reports once for the directory; a second start looks up nothing and says nothing"
      run :=
        let model :=
          lookupModel (.mise (some "/opt/mise")) .headless {} (reply :=
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
        let model := lookupModel (.mise (some "/opt/mise")) .headless {} (reply := printed "[1]")
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
          { lookupModel (.mise (some "/opt/mise")) .headless {} (takes := 6000) with now := 100 }
        let lookup := Process.lookupCommand "/opt/mise" "/p/d"
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
        "with the inherited setting, a run and a start start their command exactly, read no stamp, and make only the policy request beyond the process request"
      run :=
        let model :=
          lookupModel .inherited (.window (some "/u"))
            (filesAt ("/u/.local/bin/mise" :: candidates))
        let model :=
          { model with
            processes :=
              { model.processes with
                streams := #[{ command := lakeBuild, steps := #[.write .out "built\n".toUTF8] }] } }
        let starts : JobM Bool := do
          return (← Process.start lakeBuild { bound := 64 }) matches .ok _
        pure
          ((after (runsOn lakeBuild) model).processes.started == #[lakeBuild] &&
            (after starts model).processes.started == #[lakeBuild] &&
            (after (runsOn lakeBuild) model).files == model.files &&
            requestsOf (runsOn lakeBuild) model ==
              #[.environment .policy, .process (.run lakeBuild 1000)]) },
    { name :=
        "a command that clears its environment runs no lookup, and a relative directory or program is refused as before, with no lookup"
      run :=
        let model := lookupModel (.mise (some "/opt/mise")) .headless {}
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
            refused program .relativeProgram) },
    { name :=
        "mise with no path and none of the candidates reports mise is not at them once for each directory, and runs no lookup"
      run :=
        let model :=
          lookupModel (.mise none) (.window (some "/u")) {} (directories := ["/p/d", "/p/e"])
        let once := after (runsOn lakeBuild) model
        let twice := after (runsOn lakeBuild) once
        let other := after (runsOn (movedTo lakeBuild "/p/e")) twice
        let missing := Process.Failure.missing (Process.miseCandidates (some "/u"))
        pure
          (other.processes.started == #[lakeBuild, lakeBuild, movedTo lakeBuild "/p/e"] &&
            other.reported ==
              #[Process.failureMessage (.directory "/p/d" "mise") missing,
                Process.failureMessage (.directory "/p/e" "mise") missing]) }]

/-! ## The layers, over sources the core does not name -/

/-- What the fake base `login` prints. -/
def baseVariables : Array (String × String) :=
  #[("A", "base"), ("B", "base"), ("D", "base")]

/-- What the fake directory source `first` prints. -/
def firstVariables : Array (String × String) :=
  #[("B", "first"), ("C", "first")]

/-- What the fake directory source `second` prints. -/
def secondVariables : Array (String × String) :=
  #[("C", "second"), ("E", "second")]

/-- The base's and the first source's variables, the first's winning a
shared name: what the second source's lookup runs over. -/
def baseAndFirst : Array (String × String) :=
  #[("A", "base"), ("D", "base"), ("B", "first"), ("C", "first")]

/-- What every layer gives `layeredChild`, each later one winning a shared
name: the base's `A`, the first source's `B`, the second's `C`, and the
command's own `D` and `E`. -/
def everyLayer : Array (String × String) :=
  #[("A", "base"), ("B", "first"), ("C", "second"), ("D", "own"), ("E", "own")]

/-- The sources of the layer checks: the base `login`, looked up in `/`,
under the directory sources `first` and `second`, in that order, `first`
kept by the stamps of `firstStamps`. -/
def layeredSources (firstStamps : Array String := #[]) : Process.Sources :=
  { base := .lookup (fakeSource "login" "/bin/login") "/"
    directories :=
      #[fakeSource "first" "/bin/first" firstStamps, fakeSource "second" "/bin/second"] }

/-- The lookup of the fake source `name`, at `/bin/<name>`, run in
`directory` with `below` set over the editor's environment. -/
def fakeLookup (name : String) (directory : System.FilePath) (below : Array (String × String)) :
    Process.Command :=
  { program := s!"/bin/{name}", directory, environment := { set := below } }

/-- The child the layer checks start in `directory`, with an environment of
its own: `D` and `E` set, `DROP` unset. -/
def layeredChild (directory : System.FilePath) : Process.Command :=
  { program := "/bin/child", arguments := #["build"], directory
    environment := { set := #[("D", "own"), ("E", "own")], unset := #["DROP"] } }

/-- `layeredChild directory` as it is started with `set`, the editor's
environment kept and its own unset kept. -/
def layeredStarted (directory : System.FilePath) (set : Array (String × String)) :
    Process.Command :=
  { layeredChild directory with environment := { clear := false, set, unset := #["DROP"] } }

/-- A script of `command` printing `variables` as `NAME=value` lines. -/
def printing (command : Process.Command) (variables : Array (String × String)) : Process.Script :=
  { command, reply := printed (linesOf variables) }

/-- A script of `command` exiting with the status 1 and `stderr` on its
standard error. -/
def exitingOne (command : Process.Command) (stderr : String) : Process.Script :=
  { command, reply := .ok { exit := .code 1, stdout := .empty, stderr := stderr.toUTF8 } }

/-- The script of the base's lookup, printing `baseVariables`. -/
def baseScript : Process.Script :=
  printing (fakeLookup "login" "/" #[]) baseVariables

/-- The scripts of both directory sources' lookups and of the child in
`directory` when every source gives its variables. -/
def layeredScripts (directory : System.FilePath) : Array Process.Script :=
  #[printing (fakeLookup "first" directory baseVariables) firstVariables,
    printing (fakeLookup "second" directory baseAndFirst) secondVariables,
    { command := layeredStarted directory everyLayer, reply := printed "built" }]

/-- What is started in `directory` when every source gives its variables:
both directory sources' lookups, then the child. -/
def layeredStarts (directory : System.FilePath) : Array Process.Command :=
  #[fakeLookup "first" directory baseVariables, fakeLookup "second" directory baseAndFirst,
    layeredStarted directory everyLayer]

/-- The job model of the layer checks: the scripts `scripts`, the files
`files` and the environments with `sources`. -/
def layeredModel (scripts : Array Process.Script) (files : FileModel := {})
    (sources : Process.Sources := layeredSources) : JobModel :=
  { files, processes := { scripts }, environments := { sources } }

/-- The checks of a child's layered environment on the models, over a base
and two directory sources the core does not name (`fakeSource`): the order
of the layers, what each lookup runs over, the base's cache, and a failed
source skipped. Each runs jobs with `JobM.runModel` on one `JobModel`,
carried from job to job. -/
def environmentLayerChecks : List Check :=
  [{  name :=
        "a child gets the editor's environment, then the base's variables, then the first directory source's, then the second's, then its command's own, each later layer winning a shared name"
      run :=
        let model := layeredModel (#[baseScript] ++ layeredScripts "/p/d")
        let once := after (runsOn (layeredChild "/p/d")) model
        pure
          (once.processes.started.back? == some (layeredStarted "/p/d" everyLayer) &&
            once.reported.isEmpty) },
    { name :=
        "the base's lookup runs over the editor's environment alone, the first directory source's over the base's variables, and the second's over the base's and the first's"
      run :=
        let model := layeredModel (#[baseScript] ++ layeredScripts "/p/d")
        pure
          ((after (runsOn (layeredChild "/p/d")) model).processes.started ==
            #[fakeLookup "login" "/" #[], fakeLookup "first" "/p/d" baseVariables,
              fakeLookup "second" "/p/d" baseAndFirst, layeredStarted "/p/d" everyLayer]) },
    { name :=
        "children started in two directories run the base's lookup once and each directory's sources once, and after a reload the next child runs the base's lookup again"
      run :=
        let model := layeredModel (#[baseScript] ++ layeredScripts "/p/d" ++ layeredScripts "/p/e")
        let inD := after (runsOn (layeredChild "/p/d")) model
        let inE := after (runsOn (layeredChild "/p/e")) inD
        let reloaded := { inE with environments := inE.environments.installSources layeredSources }
        let again := after (runsOn (layeredChild "/p/d")) reloaded
        let base := fakeLookup "login" "/" #[]
        pure
          (inE.processes.started == #[base] ++ layeredStarts "/p/d" ++ layeredStarts "/p/e" &&
            again.processes.started == inE.processes.started ++ #[base] ++ layeredStarts "/p/d") },
    { name :=
        "a directory source whose lookup exits non-zero is skipped: the child gets the base's and the other source's variables, the echo area names that source and directory once, and a second child runs no lookup"
      run :=
        let baseAndSecond :=
          #[("A", "base"), ("B", "base"), ("C", "second"), ("D", "own"), ("E", "own")]
        let model :=
          layeredModel
            #[baseScript, exitingOne (fakeLookup "first" "/p/d" baseVariables) "not trusted\n",
              printing (fakeLookup "second" "/p/d" baseVariables) secondVariables,
              { command := layeredStarted "/p/d" baseAndSecond, reply := printed "built" }]
        let once := after (runsOn (layeredChild "/p/d")) model
        let twice := after (runsOn (layeredChild "/p/d")) once
        pure
          (once.processes.started ==
              #[fakeLookup "login" "/" #[], fakeLookup "first" "/p/d" baseVariables,
                fakeLookup "second" "/p/d" baseVariables, layeredStarted "/p/d" baseAndSecond] &&
            once.reported ==
              #["environment: /p/d: first exited with status 1: not trusted; its children start without first's variables"] &&
            twice.processes.started ==
              once.processes.started.push (layeredStarted "/p/d" baseAndSecond) &&
            twice.reported == once.reported) },
    { name :=
        "a directory source whose lookup exits 0 with output its parser refuses is skipped: the child gets the base's and the other source's variables, and the echo area says what that source's output must be, in its own words"
      run :=
        let baseAndSecond :=
          #[("A", "base"), ("B", "base"), ("C", "second"), ("D", "own"), ("E", "own")]
        let model :=
          layeredModel
            #[baseScript,
              { command := fakeLookup "first" "/p/d" baseVariables, reply := printed "no pair\n" },
              printing (fakeLookup "second" "/p/d" baseVariables) secondVariables,
              { command := layeredStarted "/p/d" baseAndSecond, reply := printed "built" }]
        let once := after (runsOn (layeredChild "/p/d")) model
        pure
          (once.processes.started ==
              #[fakeLookup "login" "/" #[], fakeLookup "first" "/p/d" baseVariables,
                fakeLookup "second" "/p/d" baseVariables, layeredStarted "/p/d" baseAndSecond] &&
            once.reported ==
              #["environment: /p/d: first's output is not NAME=value lines: the line no pair is not NAME=value; its children start without first's variables"]) },
    { name :=
        "a base whose lookup exits non-zero is said once in a run: children in two directories get the directory sources' variables over the editor's environment, and after a reload it is said again"
      run :=
        let firstAndSecond := #[("B", "first"), ("C", "second"), ("D", "own"), ("E", "own")]
        let base := fakeLookup "login" "/" #[]
        let inDirectory (directory : System.FilePath) : Array Process.Script :=
          #[printing (fakeLookup "first" directory #[]) firstVariables,
            printing (fakeLookup "second" directory firstVariables) secondVariables,
            { command := layeredStarted directory firstAndSecond, reply := printed "built" }]
        let model :=
          layeredModel (#[exitingOne base "no login"] ++ inDirectory "/p/d" ++ inDirectory "/p/e")
        let inD := after (runsOn (layeredChild "/p/d")) model
        let inE := after (runsOn (layeredChild "/p/e")) inD
        let reloaded := { inE with environments := inE.environments.installSources layeredSources }
        let again := after (runsOn (layeredChild "/p/d")) reloaded
        let message :=
          "environment: the base, login: login exited with status 1: no login; children start without the base's variables"
        pure
          (inD.processes.started.back? == some (layeredStarted "/p/d" firstAndSecond) &&
            inE.processes.started.back? == some (layeredStarted "/p/e" firstAndSecond) &&
            (inE.processes.started.filter (· == base)).size == 1 &&
            inE.reported == #[message] &&
            (again.processes.started.filter (· == base)).size == 2 &&
            again.processes.started.back? == some (layeredStarted "/p/d" firstAndSecond) &&
            again.reported == #[message, message]) },
    { name :=
        "a directory source is looked up again when a layer below it changes: with the first source's stamp file rewritten and its output changed, the first and the second run again, the second over the new variables, and the base does not"
      run :=
        let model :=
          layeredModel (#[baseScript] ++ layeredScripts "/p/d") (filesAt ["/p/d/first.toml"])
            (layeredSources #["first.toml"])
        let once := after (runsOn (layeredChild "/p/d")) model
        let renewed := #[("B", "renewed"), ("C", "renewed")]
        let below := #[("A", "base"), ("D", "base"), ("B", "renewed"), ("C", "renewed")]
        let child :=
          layeredStarted "/p/d"
            #[("A", "base"), ("B", "renewed"), ("C", "second"), ("D", "own"), ("E", "own")]
        let firstLookup := fakeLookup "first" "/p/d" baseVariables
        let scripts :=
          (once.processes.scripts.map fun script =>
              if script.command == firstLookup then printing firstLookup renewed else script) ++
            #[printing (fakeLookup "second" "/p/d" below) secondVariables,
              { command := child, reply := printed "built" }]
        let rewritten :=
          { once with
            files := once.files.withFile "/p/d/first.toml" "y".toUTF8
            processes := { once.processes with scripts } }
        let twice := after (runsOn (layeredChild "/p/d")) rewritten
        pure
          (once.processes.started == #[fakeLookup "login" "/" #[]] ++ layeredStarts "/p/d" &&
            twice.processes.started ==
              once.processes.started ++ #[firstLookup, fakeLookup "second" "/p/d" below, child]) }]

end ModelTest
