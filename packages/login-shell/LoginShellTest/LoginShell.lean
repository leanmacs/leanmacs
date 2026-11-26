import Editor.Config.Registry
import Editor.Job
import Editor.Job.Model
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import EnvironmentApi
import EnvironmentApiTest.Contract
import EnvironmentApiTest.Fake
import EnvironmentApiTest.Model
import LoginShell
import LoginShell.Compiled
import LoginShellTest.Check

/-!
# Model tests: `LoginShell.lean` and `LoginShell/Compiled.lean`

The model tests of `LoginShell.lean` and `LoginShell/Compiled.lean`:
`loginShellChecks`, the package's registration and default base, its
setting, its command, its probes, its parser and `environment-api`'s base
contract held on the model rig; and `loginShellLookupChecks`, a child's
environment over the login shell on the job model, as a host installs the
package's value. The test driver's root, `LoginShellTest/Model.lean`, runs
them; its module doc says what each shows.
-/

namespace LoginShellTest

open Editor
open EnvironmentApiTest

/-- The bases `LoginShell.package` registers, as a host collects them. -/
def registeredBases : Array EnvironmentApi.BaseSource :=
  registeredAt EnvironmentApi.BaseSource LoginShell.package

/-- What the checks compare of a base: its source's name, program and own
limit, and the directory it is looked up in; `none` for the inherited
base. -/
def baseShape : Process.Base → Option (String × Process.Program × Option Nat × System.FilePath)
  | .inherited => none
  | .lookup source directory => some (source.name, source.program, source.limit, directory)

/-- The base the name `wanted` chooses among `bases` in `host`, as its shape;
`none` for the inherited base or a name nothing answers to. -/
def chosenShape (bases : Array EnvironmentApi.BaseSource) (wanted : String) (host : Process.Host) :
    Option (String × Process.Program × Option Nat × System.FilePath) :=
  match EnvironmentApi.BaseSource.choose bases wanted with
  | .ok base => baseShape (base host)
  | .error _ => none

/-- Whether the name `wanted` chooses the inherited base among `bases` in
`host`. -/
def choosesInherited (bases : Array EnvironmentApi.BaseSource) (wanted : String)
    (host : Process.Host) : Bool :=
  match EnvironmentApi.BaseSource.choose bases wanted with
  | .ok base => (base host matches .inherited)
  | .error _ => false

/-- A NUL, which ends each variable the login shell prints. -/
def nul : String :=
  String.singleton (Char.ofNat 0)

/-- `variables` as `env -0` prints them: each `NAME=value` followed by a
NUL. -/
def block (variables : Array (String × String)) : String :=
  String.join (variables.toList.map fun (name, value) => s!"{name}={value}" ++ nul)

/-- What the login shell prints with `variables` in its environment, with
what rc files print before and after the markers. -/
def environmentOf (variables : Array (String × String)) : String :=
  "Last login: today\nNOISE=before\n" ++ LoginShell.beginMarker ++ block variables ++
    LoginShell.endMarker ++
    "bye\nNOISE=after\n"

/-- Whether `parse` reads `text` as `expected`. -/
def parsesAs (text : String) (expected : Array (String × String)) : Bool :=
  match LoginShell.parse text.toUTF8 with
  | .ok variables => variables == expected
  | .error _ => false

/-- Whether `parse` refuses `bytes` with `why`. -/
def refusedWith (bytes : ByteArray) (why : String) : Bool :=
  match LoginShell.parse bytes with
  | .error said => said == why
  | .ok _ => false

/-- What `setup` is refused with, or `none` when it is accepted. -/
def refusal (setup : SetupM Unit) : Option String :=
  match Config.Registrations.ofSetup setup with
  | .error said => some said
  | .ok _ => none

/-- The bases `setup` registers, in order, as config's are collected. -/
def basesOfSetup (setup : SetupM Unit) : Array EnvironmentApi.BaseSource :=
  match Config.Registrations.ofSetup setup with
  | .ok collected =>
    collected.extensions.filterMap fun (key, value) =>
      if key == TypeName.typeName EnvironmentApi.BaseSource then
        value.get? EnvironmentApi.BaseSource
      else none
  | .error _ => #[]

/-- Whether every sentence of `contract` holds. -/
def contractHolds (contract : List (String × IO Bool)) : IO Bool :=
  contract.allM (·.2)

/-- The checks of the package's registration, its setting, its command, its
probes and its parser (`LoginShell.lean`, `LoginShell/Compiled.lean`). -/
def loginShellChecks : List Check :=
  [{  name :=
        "the package registers one base, named login-shell, and chooses it as its default base"
      run :=
        pure
          (registeredBases.map (·.name) == #["login-shell"] &&
            match Config.Registrations.ofSetup LoginShell.package.setup with
            | .ok collected =>
              collected.environmentBases == #["login-shell"] && collected.extensions.size == 1
            | .error _ => false) },
    { name :=
        "chosen by its name, the base is inherited in the headless mode, and in the window mode the login shell found by its probes, else /bin/zsh, looked up in the home directory, or / with none, within 5000 ms"
      run :=
        let shell : Process.Program := .probed LoginShell.shellProbes "/bin/zsh"
        pure
          (choosesInherited registeredBases "login-shell" .headless &&
            chosenShape registeredBases "login-shell" (.window (some "/u")) ==
              some ("login-shell", shell, some 5000, ⟨"/u"⟩) &&
            chosenShape registeredBases "login-shell" (.window none) ==
              some ("login-shell", shell, some 5000, ⟨"/"⟩) &&
            (match (EnvironmentApi.registered #[] registeredBases "login-shell") with
            | (registered, none) => registered.base.isSome
            | _ => false)) },
    { name := "config's environmentBase \"inherited\" chooses the core's base in both modes"
      run :=
        pure
          (choosesInherited registeredBases Process.inheritedName .headless &&
            choosesInherited registeredBases Process.inheritedName (.window (some "/u"))) },
    { name :=
        "LoginShell.timeLimit registers the base with its limit, which replaces the package's; 0 is refused, and so is a second call in one setup"
      run :=
        let configBases := basesOfSetup (LoginShell.timeLimit 2000)
        let twice : SetupM Unit := do
          LoginShell.timeLimit 2000
          LoginShell.timeLimit 3000
        pure
          (configBases.size == 1 &&
            chosenShape (registeredBases ++ configBases) "login-shell" (.window (some "/u")) ==
              some ("login-shell", LoginShell.program, some 2000, ⟨"/u"⟩) &&
            choosesInherited (registeredBases ++ configBases) "login-shell" .headless &&
            refusal (LoginShell.timeLimit 0) == some LoginShell.zeroLimit &&
            LoginShell.zeroLimit == "the login shell's time limit must be at least 1 ms" &&
            refusal twice == some (Config.Registrations.settingTwice "LoginShell.timeLimit") &&
            refusal (LoginShell.timeLimit 2000) == none) },
    { name :=
        "the lookup runs the shell as a login shell, never interactive, in the directory over the environment so far, with a command that prints the environment NUL-separated between two markers by absolute programs"
      run :=
        let source := LoginShell.source (.at "/bin/zsh")
        pure
          (LoginShell.lookupCommand "/bin/zsh" "/u" ==
              { program := "/bin/zsh", arguments := #["-l", "-c", LoginShell.printCommand]
                directory := "/u" } &&
            !(LoginShell.lookupCommand "/bin/zsh" "/u").arguments.contains "-i" &&
            source.command "/bin/zsh" "/u" { set := #[("A", "a")] } ==
              LoginShell.lookupCommand "/bin/zsh" "/u" { set := #[("A", "a")] } &&
            LoginShell.printCommand ==
              "/usr/bin/printf %s EDITOR-LOGIN-SHELL-ENVIRONMENT-BEGIN; /usr/bin/env -0; /usr/bin/printf %s EDITOR-LOGIN-SHELL-ENVIRONMENT-END" &&
            source.output == "the environment, NUL-separated between its markers" &&
            source.limit == some 5000) },
    { name :=
        "the shell is found by printenv SHELL, read whole, then by id -P, read at its last : field, each in /"
      run :=
        pure
          (LoginShell.shellProbes ==
              #[{ command :=
                    { program := "/usr/bin/printenv", arguments := #["SHELL"], directory := "/" }
                  answer := .line },
                { command := { program := "/usr/bin/id", arguments := #["-P"], directory := "/" }
                  answer := .lastField ':' }] &&
            LoginShell.program == .probed LoginShell.shellProbes "/bin/zsh") },
    { name :=
        "criterion 1: the parser takes the NUL-separated variables between the markers in order, ignores what comes before and after them, keeps a value's = and newline, and a name's last value"
      run :=
        pure
          (parsesAs (environmentOf #[("PATH", "/sh/bin:/usr/bin"), ("HOME", "/u")])
              #[("PATH", "/sh/bin:/usr/bin"), ("HOME", "/u")] &&
            parsesAs (environmentOf #[("F", "a=b\nc"), ("G", "")]) #[("F", "a=b\nc"), ("G", "")] &&
            parsesAs (environmentOf #[("A", "1"), ("B", "b"), ("A", "2")])
              #[("B", "b"), ("A", "2")] &&
            parsesAs (environmentOf #[]) #[]) },
    { name := "criterion 1: the parser drops PWD, OLDPWD, SHLVL and _, and keeps every other name"
      run :=
        pure
          (parsesAs
            (environmentOf
              #[("PWD", "/u"), ("PATH", "/bin"), ("OLDPWD", "/"), ("SHLVL", "1"),
                ("_", "/usr/bin/env"), ("PWDX", "x"), ("_X", "y"), ("TERM", "dumb")])
            #[("PATH", "/bin"), ("PWDX", "x"), ("_X", "y"), ("TERM", "dumb")]) },
    { name :=
        "the end marker's text inside a value does not end the variables: only one that follows the start marker or a NUL does, and the first such one; what follows it is ignored, a NUL and the marker again among it"
      run :=
        pure
          (parsesAs (environmentOf #[("V", s!"x{LoginShell.endMarker}y"), ("W", "1")])
              #[("V", s!"x{LoginShell.endMarker}y"), ("W", "1")] &&
            parsesAs (environmentOf #[("W", "1")] ++ "X=2" ++ nul ++ LoginShell.endMarker ++ "\n")
              #[("W", "1")] &&
            parsesAs
              (LoginShell.beginMarker ++ LoginShell.endMarker ++ "X=2" ++ nul ++
                LoginShell.endMarker)
              #[]) },
    { name :=
        "the parser refuses output with no start marker, with no end marker after its variables, a piece that is not NAME=value, and bytes that are not UTF-8, each with its reason"
      run :=
        pure
          (refusedWith "PATH=/bin\n".toUTF8 "it holds no start marker" &&
            refusedWith (LoginShell.beginMarker ++ block #[("A", "1")]).toUTF8
              "it holds no end marker after its variables" &&
            refusedWith (LoginShell.beginMarker ++ "JUNK" ++ nul ++ LoginShell.endMarker).toUTF8
              "the piece \"JUNK\" is not NAME=value" &&
            refusedWith (LoginShell.beginMarker ++ "=v" ++ nul ++ LoginShell.endMarker).toUTF8
              "the piece \"=v\" has no name" &&
            refusedWith ⟨#[0xFF]⟩ "it is not UTF-8") },
    { name := "the login shell keeps environment-api's base contract on the model rig"
      run :=
        contractHolds
          (baseContract LoginShell.package "login-shell"
            (modelBaseRig (LoginShell.baseSource LoginShell.defaultLimit) (.window (some "/u"))
              environmentOf)) }]

/-! ## A child's environment over the login shell, on the job model -/

/-- The layers a host installs with the package registered and no config: its
base, chosen by its default name. -/
def packageLayers : Process.Registered :=
  (EnvironmentApi.registered #[] registeredBases LoginShell.name).1

/-- The probe `printenv SHELL`, the first of `LoginShell.shellProbes`. -/
def printenvShell : Process.Command :=
  { program := "/usr/bin/printenv", arguments := #["SHELL"], directory := "/" }

/-- The probe `id -P`, the second of `LoginShell.shellProbes`. -/
def idRecord : Process.Command :=
  { program := "/usr/bin/id", arguments := #["-P"], directory := "/" }

/-- The user's record as `id -P` prints it, its login shell `/bin/bash`. -/
def passwdLine : String :=
  "u:********:501:20::0:0:U:/Users/u:/bin/bash\n"

/-- The lookup of the shell at `shell`, in the home directory `/u`. -/
def lookupOf (shell : System.FilePath) : Process.Command :=
  LoginShell.lookupCommand shell "/u"

/-- What the shell's environment holds: a `PATH` and an editor, beside the
shell's own per-session variables. -/
def shellEnvironment : Array (String × String) :=
  #[("PWD", "/u"), ("PATH", "/sh/bin:/usr/bin"), ("SHLVL", "1"), ("EDITOR", "vi"),
    ("_", "/usr/bin/env")]

/-- The variables the base gives: the shell's, without its per-session
ones. -/
def shellVariables : Array (String × String) :=
  #[("PATH", "/sh/bin:/usr/bin"), ("EDITOR", "vi")]

/-- The command the lookup checks start in `directory`, with a variable of
its own. -/
def child (directory : System.FilePath) : Process.Command :=
  { program := "/bin/build", arguments := #["all"], directory
    environment := { set := #[("A", "own")] } }

/-- `child directory` as it is started over `variables`. -/
def childOver (directory : System.FilePath) (variables : Array (String × String)) :
    Process.Command :=
  { child directory with
    environment := Process.Environment.over variables (child directory).environment }

/-- A script of `command` printing `stdout`. -/
def printing (command : Process.Command) (stdout : String) : Process.Script :=
  { command, reply := printed stdout }

/-- A script of `command` exiting with the status 1 and `stderr` on its
standard error. -/
def exitingOne (command : Process.Command) (stderr : String := "") : Process.Script :=
  { command, reply := .ok { exit := .code 1, stdout := .empty, stderr := stderr.toUTF8 } }

/-- The scripts of the children in `/p/d` and `/p/e`, over the shell's
variables and over none. -/
def childScripts : Array Process.Script :=
  (#["/p/d", "/p/e"] : Array System.FilePath).flatMap fun directory =>
    #[printing (childOver directory shellVariables) "built", printing (child directory) "built"]

/-- The job model of the lookup checks: the scripts `scripts` and the
children's, and the environments in the mode `host` with `layers`
installed, as a host installs them. -/
def shellModel (scripts : Array Process.Script) (host : Process.Host := .window (some "/u"))
    (layers : Process.Registered := packageLayers) : JobModel :=
  { processes := { scripts := scripts ++ childScripts }
    environments := ({ host } : Process.Environments).install layers }

/-- The scripts of a run where `SHELL` names fish and the shell's lookup
answers `reply`, taking `takes` milliseconds. -/
def fishWith (reply : Except ProcessError Process.Ran) (takes : Nat := 0) : Array Process.Script :=
  #[printing printenvShell "/opt/homebrew/bin/fish\n",
    { command := lookupOf "/opt/homebrew/bin/fish", reply, takes }]

/-- Whether children started in `/p/d` and then `/p/e` on `model` start
unchanged, and the echo area says the base's `failure` once. -/
def fallsBack (model : JobModel) (failure : Process.Failure) : Bool :=
  let inD := after (runsOn (child "/p/d")) model
  let inE := after (runsOn (child "/p/e")) inD
  inE.processes.started.back? == some (child "/p/e") &&
    inD.processes.started.back? == some (child "/p/d") &&
    inE.reported == #[Process.failureMessage (.base LoginShell.name) failure]

/-- The checks of a child's environment over the login shell on the job
model (`docs/design/concurrency.md`, "A child's environment, as built"),
with the layers the package's registration gives, and config's
`LoginShell.timeLimit` over it, as a host installs them: each runs jobs
with `JobM.runModel` on one `JobModel`, carried from job to job. -/
def loginShellLookupChecks : List Check :=
  [{  name :=
        "the shell is SHELL when printenv SHELL names one: the lookup runs that shell, and id -P is never started"
      run :=
        let model :=
          shellModel
            (#[printing printenvShell "/opt/homebrew/bin/fish\n", printing idRecord passwdLine,
              printing (lookupOf "/opt/homebrew/bin/fish") (environmentOf shellEnvironment)])
        pure
          ((after (runsOn (child "/p/d")) model).processes.started ==
            #[printenvShell, lookupOf "/opt/homebrew/bin/fish", childOver "/p/d" shellVariables]) },
    { name := "with SHELL unset, the shell is the user record's login shell"
      run :=
        let model :=
          shellModel
            #[exitingOne printenvShell, printing idRecord passwdLine,
              printing (lookupOf "/bin/bash") (environmentOf shellEnvironment)]
        pure
          ((after (runsOn (child "/p/d")) model).processes.started ==
            #[printenvShell, idRecord, lookupOf "/bin/bash", childOver "/p/d" shellVariables]) },
    { name := "with both probes failing, or SHELL relative and no record, the shell is /bin/zsh"
      run :=
        let zsh := printing (lookupOf "/bin/zsh") (environmentOf shellEnvironment)
        let failing := shellModel #[exitingOne printenvShell, zsh]
        let relative := shellModel #[printing printenvShell "zsh\n", exitingOne idRecord, zsh]
        pure
          ((after (runsOn (child "/p/d")) failing).processes.started ==
              #[printenvShell, lookupOf "/bin/zsh", childOver "/p/d" shellVariables] &&
            (after (runsOn (child "/p/d")) relative).processes.started ==
              #[printenvShell, idRecord, lookupOf "/bin/zsh", childOver "/p/d" shellVariables]) },
    { name :=
        "the login shell runs once per run, the first time a child is prepared: children in two directories get its variables, without the per-session ones, over the editor's environment and under their own; after a reload's install the probes and the lookup run again"
      run :=
        let model := shellModel (fishWith (printed (environmentOf shellEnvironment)))
        let inD := after (runsOn (child "/p/d")) model
        let inE := after (runsOn (child "/p/e")) inD
        let reloaded := { inE with environments := inE.environments.install packageLayers }
        let again := after (runsOn (child "/p/d")) reloaded
        let once :=
          #[printenvShell, lookupOf "/opt/homebrew/bin/fish", childOver "/p/d" shellVariables,
            childOver "/p/e" shellVariables]
        pure
          (inE.processes.started == once &&
            again.processes.started ==
              once ++
                #[printenvShell, lookupOf "/opt/homebrew/bin/fish",
                  childOver "/p/d" shellVariables] &&
            childOver "/p/d" shellVariables ==
              { child "/p/d" with
                environment :=
                  { set := #[("PATH", "/sh/bin:/usr/bin"), ("EDITOR", "vi"), ("A", "own")] } } &&
            again.reported.isEmpty) },
    { name :=
        "the headless mode starts no probe and no lookup, and its children start as their commands say"
      run :=
        let model := shellModel (fishWith (printed (environmentOf shellEnvironment))) .headless
        let inD := after (runsOn (child "/p/d")) model
        let inE := after (runsOn (child "/p/e")) inD
        pure (inE.processes.started == #[child "/p/d", child "/p/e"] && inE.reported.isEmpty) },
    { name :=
        "criterion 2: a shell that exits non-zero leaves children on the editor's own environment, and the echo area says why once for the run"
      run :=
        pure
          (fallsBack
            (shellModel
              (fishWith (.ok { exit := .code 1, stdout := .empty, stderr := "boom\n".toUTF8 })))
            (.exited 1 "boom")) },
    { name :=
        "criterion 2: a shell whose output lacks the markers, or its end marker, leaves children on the editor's own environment, and the echo area says why once for the run"
      run :=
        pure
          (fallsBack (shellModel (fishWith (printed "Last login: today\nPATH=/sh/bin\n")))
              (.unparsable LoginShell.output "it holds no start marker") &&
            fallsBack
              (shellModel
                (fishWith (printed (LoginShell.beginMarker ++ block #[("PATH", "/sh/bin")]))))
              (.unparsable LoginShell.output "it holds no end marker after its variables")) },
    { name :=
        "criterion 2: a shell that outlives the time limit of 5000 ms is killed at it, children start on the editor's own environment, and the echo area says why once for the run"
      run :=
        let model := shellModel (fishWith (printed (environmentOf shellEnvironment)) 6000)
        let inD := after (runsOn (child "/p/d")) model
        pure
          (fallsBack model (.timedOut 5000) &&
            inD.processes.killed == #[lookupOf "/opt/homebrew/bin/fish"]) },
    { name :=
        "a shell that is not where SHELL names leaves children on the editor's own environment, and the echo area says the process service's refusal once"
      run :=
        let refused : Option ProcessError :=
          match
            (Process.request
                  (.runWithin (lookupOf "/no/such/shell") Process.lookupOutput 5000)).runModel
              {} with
          | (.finished (.error error), _) => some error
          | _ => none
        let model := shellModel #[printing printenvShell "/no/such/shell\n"]
        pure
          (match refused with
          | some error => fallsBack model (.refused error)
          | none => false) },
    { name :=
        "with config's LoginShell.timeLimit 2000 after the package's base, a shell that takes 3000 ms is killed at 2000 and said once"
      run :=
        let layers :=
          (EnvironmentApi.registered #[]
              (registeredBases ++ basesOfSetup (LoginShell.timeLimit 2000)) LoginShell.name).1
        pure
          (fallsBack
            (shellModel (fishWith (printed (environmentOf shellEnvironment)) 3000) (layers :=
              layers))
            (.timedOut 2000)) },
    { name :=
        "a directory source over the login shell runs its lookup with the shell's variables set, and a child gets the PATH it prints first, the shell's other variables kept"
      run :=
        let directory : EnvironmentApi.DirectorySource :=
          fakeDirectory "fake-directory" "/fake/bin/directory" #[]
        let layers := (EnvironmentApi.registered #[directory] registeredBases LoginShell.name).1
        let dirLookup : Process.Command :=
          { program := "/fake/bin/directory", directory := "/p/d"
            environment := { set := shellVariables } }
        let dirVariables := #[("PATH", "/p/d/tools:/sh/bin:/usr/bin")]
        let layered := Process.layer shellVariables dirVariables
        let model :=
          shellModel
            (fishWith (printed (environmentOf shellEnvironment)) ++
              #[printing dirLookup (linesOf dirVariables),
                printing (childOver "/p/d" layered) "built"])
            (layers := layers)
        pure
          ((after (runsOn (child "/p/d")) model).processes.started ==
              #[printenvShell, lookupOf "/opt/homebrew/bin/fish", dirLookup,
                childOver "/p/d" layered] &&
            childOver "/p/d" layered ==
              { child "/p/d" with
                environment :=
                  {
                    set :=
                      #[("EDITOR", "vi"), ("PATH", "/p/d/tools:/sh/bin:/usr/bin"),
                        ("A", "own")] } }) }]

end LoginShellTest
