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
import EnvironmentApiTest.Fake
import EnvironmentApiTest.Model
import ModelTest.Check

/-!
# Model tests: `Editor/Process/Environment.lean`

The model tests of `Editor/Process/Environment.lean`: `processEnvironmentChecks`
and `environmentLayerChecks`, the latter of the layers, a base under two
directory sources the core does not name (`EnvironmentApiTest.fakeSource`).
mise's lookup checks are the mise package's (`MiseTest.miseLookupChecks`).
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open EnvironmentApiTest

/-- A JSON object of strings in mise's layout: one name a line, indented two
spaces, with a `PATH` of 400 characters. -/
def jsonOutput : String :=
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

/-- What the checks compare of `sources`: whether the base is the inherited
one, and each directory source's name, program and stamp names. -/
def shapeOf (sources : Process.Sources) : Bool × Array (String × Process.Program × Array String) :=
  (sources.base matches .inherited,
    sources.directories.map fun source => (source.name, source.program, source.stampNames))

/-- The checks of the pure part of a child's environment
(`Editor/Process/Environment.lean`): the parser of a JSON object of strings,
how the layers' variables and a command's own environment combine, how
registered layers install, the shared state's answers and the messages. -/
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
        "parseVariables reads a multi-line object in mise's layout, with a PATH of 400 characters"
      run :=
        pure
          (readsVariables jsonOutput.toUTF8
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
        "install of registered layers takes each directory source in the state's mode: one that gives none in the headless mode and a source in the window mode is left out of a headless state and installed on a window state"
      run :=
        let windowOnly : Process.Host → Option Process.Source
          | .headless => none
          | .window _ => some (fakeSource "first" "/bin/first")
        let registered : Process.Registered := { directories := #[windowOnly] }
        let headless := ({} : Process.Environments).install registered
        let window := ({ host := .window (some "/u") } : Process.Environments).install registered
        pure
          (shapeOf headless.sources == (true, #[]) &&
            shapeOf window.sources == (true, #[("first", .at "/bin/first", #[])])) },
    { name :=
        "install with no base (a name nobody registered) keeps the base the state had, and with one installs it"
      run :=
        let state : Process.Environments :=
          { sources := { base := .lookup (fakeSource "old" "/bin/old") "/" } }
        let kept := state.install { base := none }
        let chosen :=
          state.install { base := some fun _ => .lookup (fakeSource "new" "/bin/new") "/n" }
        pure
          ((match kept.sources.base with
            | .lookup source directory => source.name == "old" && directory == "/"
            | .inherited => false) &&
            match chosen.sources.base with
            | .lookup source directory => source.name == "new" && directory == "/n"
            | .inherited => false) },
    { name :=
        "install drops every entry, the base's included, and every resolved program, and keeps the mode and the limit"
      run :=
        let host : Process.Host := .window (some "/u")
        let state : Process.Environments :=
          { host, limit := 7
            sources :=
              { base := .lookup (fakeSource "login" "/bin/login") "/"
                directories := #[fakeSource "first" "/bin/first"] }
            programs := #[("first", some "/m")]
            entries :=
              #[(.base "login", failedEntry (.signalled 9)),
                (.directory "/p" "first", failedEntry (.signalled 9))] }
        let after := state.install { base := none, directories := #[fun _ => none] }
        pure
          (after.host == host && after.limit == 7 && after.programs.isEmpty &&
            after.entries.isEmpty &&
            after.sources.directories.isEmpty) },
    { name := "the default registered layers install the inherited base and no directory source"
      run :=
        let state : Process.Environments :=
          {
            sources :=
              { base := .lookup (fakeSource "login" "/bin/login") "/"
                directories := #[fakeSource "first" "/bin/first"] } }
        pure (shapeOf (state.install {}).sources == (true, #[])) },
    { name := "the policy is the sources, what each resolved to and the limit"
      run :=
        let state : Process.Environments :=
          { sources :=
              {
                directories :=
                  #[{ fakeSource "first" "/bin/first" with
                      program := .firstOf #["/bin/a"] .report }] }
            programs := #[("first", none)] }
        let (policy, after, said) := state.handle .policy
        let policy : Process.Policy := policy
        pure
          (shapeOf policy.sources == shapeOf state.sources &&
            policy.programs == #[("first", none)] &&
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
            say (.missing #["/u/bin/mise", "/opt/bin/mise", "/usr/bin/mise"]) ==
              "environment: /p/d: mise is not at /u/bin/mise, /opt/bin/mise or /usr/bin/mise" ++
                tail) },
    { name :=
        "what a lookup's run came to: variables for status 0 and an object, and else the failure, with the first line of standard error"
      run :=
        let ran (exit : Process.Exit) (stdout stderr : String) : Except ProcessError Process.Ran :=
          .ok { exit, stdout := stdout.toUTF8, stderr := stderr.toUTF8 }
        let foundOf :=
          Process.foundOf
            { fakeSource "json" "/m" with
              parse := Process.parseVariables, output := "a JSON object of strings" }
        pure
          (foundOf (ran (.code 0) "{\"A\":\"a\"}" "") == .variables #[("A", "a")] &&
            foundOf (ran (.code 1) "" "first\nsecond\n") == .failed (.exited 1 "first") &&
            foundOf (ran (.signal 9) "" "") == .failed (.signalled 9) &&
            foundOf (ran (.code 0) "[1]" "") ==
              .failed (.unparsable "a JSON object of strings" "it is not an object") &&
            foundOf (.error .noSuchProcess) == .failed (.refused .noSuchProcess) &&
            foundOf (.error (.timedOut 5000)) == .failed (.timedOut 5000)) }]

/-! ## The layers, over sources the core does not name -/

/-- A file model holding each of `paths`, written in that order. -/
def filesAt (paths : List System.FilePath) : FileModel :=
  paths.foldl (fun model path => model.withFile path "x".toUTF8) {}

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
              once.processes.started ++ #[firstLookup, fakeLookup "second" "/p/d" below, child]) },
    { name :=
        "a directory source to be reported when its executable is at none of its candidates says it is not at them once for each directory, runs no lookup, and starts the child as it would have"
      run :=
        let candidates : Array System.FilePath := #["/no/a", "/no/b"]
        let source := { fakeSource "first" "/no/a" with program := .firstOf candidates .report }
        let model :=
          layeredModel
            #[{ command := layeredChild "/p/d", reply := printed "built" },
              { command := layeredChild "/p/e", reply := printed "built" }]
            (sources := { directories := #[source] })
        let once := after (runsOn (layeredChild "/p/d")) model
        let twice := after (runsOn (layeredChild "/p/d")) once
        let other := after (runsOn (layeredChild "/p/e")) twice
        let missing := Process.Failure.missing candidates
        pure
          (other.processes.started ==
              #[layeredChild "/p/d", layeredChild "/p/d", layeredChild "/p/e"] &&
            other.reported ==
              #[Process.failureMessage (.directory "/p/d" "first") missing,
                Process.failureMessage (.directory "/p/e" "first") missing]) }]

end ModelTest
