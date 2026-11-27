import Editor.File
import Editor.Process

/-!
# A child's environment, in layers

What environment does a child started in a directory get? Four layers, each
later one winning a variable of the same name: the editor's own environment,
then the variables of the **base**, then those of each **directory source**
in order, looked up for the child's directory, then its command's own
`Environment` (`Process.Environment.over`). The editor's own process
environment is never changed.

This module is the pure part of the answer: a source as data
(`Process.Source`), the layers as the registry gives them
(`Process.Registered`) and as a host installs them (`Process.Sources`), how
two layers combine (`Process.layer`), the files whose stamps keep a
directory source's result (`Process.stampPaths`), the state every job of a
host shares (`Process.Environments`) with the requests a job makes of it
(`EnvironmentRequest`), and a parser of a JSON object of strings that a
source may read its output with (`Process.parseVariables`). It names no
source: the sources are packages, registered at the extension points of the
interface library `environment-api` (`EnvironmentApi.lean`). The program
that asks them, `Process.prepared`, is in `Editor/Job.lean`, beside the
process operations it runs before. It imports only the process and file
requests, so nothing of `Std` or `Lean` reaches config's closure.

## The rules

- **A source is data, not a program.** A `Source` is a name, where its
  executable is (`Program`: a path; the first of some candidates whose
  stamp a file request answers, with what to do when none is there; or the
  first absolute path some probes print, commands run through the process
  service, with a path to fall back to), the command a lookup runs (built
  from the executable, the directory and the environment so far), a parser
  from its output to variables or a reason, what that output must be (for
  a message), for a directory source the names of the files whose stamps
  keep its result, and, if it has one, its own time limit. None of it reaches a
  request or the editor state, so a source can be handed through a registry
  and its lookup run in a job through the process service, with no
  `EditorM` in the reply. An executable is never looked up by bare name:
  launchd's `PATH` holds none of the usual places.
- **The layers.** The base (`Base`) is `inherited`, launchd's: the editor's
  own environment with no lookup, built into the core under the name
  `inherited` (`inheritedName`); or a lookup a package registered, which
  runs once per run, in the directory it names, over the editor's
  environment. Each directory source then runs in the child's directory, in
  order, with the base's and the earlier sources' variables set over the
  editor's (`layer`), so a later source sees an earlier one's `PATH`.
- **The layers come from the registry.** At every reload that installs, the
  host reads the extension points (`EnvironmentApi.ofRegistry`): every
  directory source registered, and the base the setting `environmentBase`
  names (`Editor/Setup.lean`; config's choice, else a package's default,
  else `inherited`). Each is given for each mode (`Host`), and a source that
  gives none in a mode is left out there (`Registered.sources`). A base name
  nothing answers to gives no base, which would keep the one installed; the
  reload reducer refuses such a config before the host installs anything
  (`Editor/Config/Reload.lean`). With
  nothing registered a child gets the editor's own environment, and no
  lookup runs. A config rejected at start-up leaves nothing installed until
  a reload installs one.
- **A lookup** runs its source's command through the process service, with
  a time limit (`ProcessRequest.runWithin`: the source's own, `Source.limit`,
  else the shared `Environments.limit`) and an output limit
  (`Process.lookupOutput`), and sets every variable its parser reads from
  what it printed. A probed program's probes run under the same limits,
  before the lookup, once until a reload.
- **The caches** are the entries of the shared state, each under its
  `Slot`: the base's under `.base`, kept until a reload, so the base is
  looked up at most once per run; and one for each directory and source
  under `.directory`, kept while the stamps of the source's stamp files in
  that directory and in each of its ancestors, and the variables of the
  layers below it, are what they were before the lookup ran. A reload
  drops every entry and every program a source resolved to
  (`Environments.install`), so what a source reads beyond its stamp files
  is picked up after a reload.
- **When a lookup fails** (a status other than 0, a signal, output its
  parser refuses, a run past its limit, a refusal, no executable where one
  is required), that source is skipped and the layers below it are kept;
  the host says why in the echo area, once for each slot until its entry is
  dropped (`Environments.handle`, `record`): once for each directory and
  source, and once per run for the base.
- **Jobs that race.** The environments answer at once and never wait, so
  two jobs that both find no entry for a slot may both run its lookup;
  each records, and an equal failure is said once. "Once per run" holds for
  the jobs that start after the first one has recorded.

## Adding to this

A new source (direnv, a login shell) is a package that registers at
`environment-api`'s extension points (`EnvironmentApi.lean`, "Where an
addition goes"), not a constructor here: its program, its command, the
parser of its output and its stamp names. A new kind of data a source
carries is a field of `Source`. A new question a job asks of the shared
state is a constructor of `EnvironmentRequest` with its case in
`EnvironmentRequest.Reply` and in `Environments.handle`.
-/

namespace Editor

namespace Process

/-- The retired setting of where a child's environment came from, kept only
so that a config that still calls `processEnvironment` elaborates and is
then refused with a message that names what replaces each choice
(`processEnvironmentGone`, `Editor/Setup.lean`). Nothing reads it. -/
inductive Setting where
  /-- Was: mise at the first candidate in the window mode, nothing in the
  headless mode. The mise package does this now. -/
  | auto
  /-- Was: no lookup. Leaving the mise package out of the set does this now. -/
  | inherited
  /-- Was: mise at a path, or at the first candidate. The mise package's
  setting, `Mise.executable`, takes the path now. -/
  | mise (executable : Option System.FilePath)
  deriving DecidableEq, Repr

/-- Which mode the editor runs in: a source may give a layer in one mode and
none in another. -/
inductive Host where
  /-- The window mode, with the user's home directory if `HOME` names one. -/
  | window (home : Option System.FilePath)
  /-- The headless mode, and the checks. -/
  | headless
  deriving DecidableEq, Repr

/-- `name` in the directory `directory`, with one separator between them, the
root's included. -/
def inDirectory (directory : System.FilePath) (name : String) : System.FilePath :=
  if directory.toString.endsWith "/" then ⟨directory.toString ++ name⟩ else directory / name

/-- The user's home directory the host knows, which the editor state is given
(`Headless.Collaborators.home`): the window mode's, if `HOME` names one,
and none in the headless mode, which reads nothing from the environment. -/
def Host.home : Host → Option System.FilePath
  | .window home => home
  | .headless => none

/-- `directory` without a separator at its end, the root's kept. -/
def trimmed (directory : System.FilePath) : System.FilePath :=
  let text := directory.toString
  let stripped := String.ofList (text.toList.reverse.dropWhile (· == '/')).reverse
  if stripped.isEmpty && text.startsWith "/" then "/" else ⟨stripped⟩

/-- `directory` and each of its ancestors up to the root, nearest first. -/
def ancestry (directory : System.FilePath) : Array System.FilePath :=
  let rec go : Nat → System.FilePath → Array System.FilePath → Array System.FilePath
    | 0, _, found => found
    | fuel + 1, at_, found =>
      match at_.parent with
      | some parent => go fuel parent (found.push at_)
      | none => found.push at_
  let start := trimmed directory
  go (start.toString.length + 1) start #[]

/-- The files named `names` in `directory` and in each of its ancestors up to
the root, nearest first, each directory's in the order of `names`: the files
whose stamps keep a directory source's result. -/
def stampPaths (names : Array String) (directory : System.FilePath) : Array System.FilePath :=
  (ancestry directory).flatMap fun at_ => names.map (inDirectory at_)

/-- Why a lookup did not give variables. -/
inductive Failure where
  /-- It exited with `status`; `stderr` is the first line of its standard
  error. -/
  | exited (status : Nat) (stderr : String)
  /-- It was ended by the signal `signal`. -/
  | signalled (signal : Nat)
  /-- What it printed is not `expected`, what its source's output must be:
  `why`. -/
  | unparsable (expected why : String)
  /-- It did not end within `limit` milliseconds, and was killed. -/
  | timedOut (limit : Nat)
  /-- The process service refused it. -/
  | refused (error : ProcessError)
  /-- No path was given and none of `candidates` exists. -/
  | missing (candidates : Array System.FilePath)
  deriving DecidableEq, Repr

/-- `paths`, written as a list for a person: `a`, `a or b`, `a, b or c`. -/
def listed (paths : Array System.FilePath) : String :=
  match paths.toList.reverse with
  | [] => "nowhere"
  | [only] => only.toString
  | last :: rest => ", ".intercalate (rest.reverse.map (·.toString)) ++ " or " ++ last.toString

/-- What a failure of the source `name` says, as a clause for a person. -/
def Failure.describe (failure : Failure) (name : String) : String :=
  match failure with
  | .exited status "" => s!"{name} exited with status {status}"
  | .exited status stderr => s!"{name} exited with status {status}: {stderr}"
  | .signalled signal => s!"{name} was ended by signal {signal}"
  | .unparsable expected why => s!"{name}'s output is not {expected}: {why}"
  | .timedOut limit => s!"{name} did not finish within {limit} ms and was killed"
  | .refused error => s!"{name} could not be run: {error.describe}"
  | .missing candidates => s!"{name} is not at {listed candidates}"

/-- What a lookup came to. -/
inductive Found where
  /-- The variables it set, in the order it printed them. -/
  | variables (variables : Array (String × String))
  /-- It failed, so its source is skipped. -/
  | failed (failure : Failure)
  deriving DecidableEq, Repr

/-- An entry of the cache: the stamps of its source's stamp files before its
lookup ran (`stampPaths`, in order), what the lookup came to, and the
variables of the layers below it that it ran over. -/
structure Entry where
  /-- The stamp of each stamp file, `none` where there is none. -/
  stamps : Array (Option File.Stamp)
  /-- What the lookup came to. -/
  found : Found
  /-- The variables of the layers below that the lookup ran with, set over
  the editor's environment: a directory entry is kept only while they are
  the same. -/
  below : Array (String × String) := #[]
  deriving DecidableEq, Repr

/-! ## A JSON object of strings

What a source that prints one JSON object whose values are strings is read
with (`parseVariables`; mise's, `packages/mise/Mise.lean`, prints one). It
is read here, and not with `Lean.Data.Json`, which lives in `Lean`, outside
config's closure. -/

/-- The value of a hexadecimal digit. -/
def hexDigit? (character : Char) : Option Nat :=
  if '0' ≤ character && character ≤ '9' then some (character.toNat - '0'.toNat)
  else
    if 'a' ≤ character && character ≤ 'f' then some (character.toNat - 'a'.toNat + 10)
    else
      if 'A' ≤ character && character ≤ 'F' then some (character.toNat - 'A'.toNat + 10) else none

/-- The four hexadecimal digits at the start of `input` as a number, and what
follows them. -/
def hex4 (input : List Char) : Except String (Nat × List Char) :=
  match input with
  | a :: b :: c :: d :: rest =>
    match hexDigit? a, hexDigit? b, hexDigit? c, hexDigit? d with
    | some a, some b, some c, some d => .ok (((a * 16 + b) * 16 + c) * 16 + d, rest)
    | _, _, _, _ => .error "a \\u escape needs four hexadecimal digits"
  | _ => .error "a \\u escape needs four hexadecimal digits"

/-- `input` without the whitespace at its start. -/
def skipSpace : List Char → List Char
  | ' ' :: rest | '\n' :: rest | '\r' :: rest | '\t' :: rest => skipSpace rest
  | input => input

/-- The code point a `\u` escape and what follows it stand for, a surrogate
pair taken whole, and what follows. -/
def unicodeEscape (input : List Char) : Except String (Char × List Char) := do
  let (high, rest) ← hex4 input
  if 0xD800 ≤ high && high ≤ 0xDBFF then
    match rest with
    | '\\' :: 'u' :: after =>
      let (low, rest) ← hex4 after
      if 0xDC00 ≤ low && low ≤ 0xDFFF then
        return (Char.ofNat (0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)), rest)
      else
        throw "a high surrogate is not followed by a low one"
    | _ =>
      throw "a high surrogate is not followed by a low one"
  else if 0xDC00 ≤ high && high ≤ 0xDFFF then
    throw "a low surrogate stands alone"
  else if high == 0 then
    throw "a string holds a NUL"
  else
    return (Char.ofNat high, rest)

/-- The rest of a string whose opening quote has been read, with `fuel` at
least the length of `input`: its value, and what follows its closing
quote. -/
def stringRest : Nat → String → List Char → Except String (String × List Char)
  | 0, _, _ => .error "a string is not closed"
  | _ + 1, _, [] => .error "a string is not closed"
  | fuel + 1, value, character :: rest =>
    match character with
    | '"' => .ok (value, rest)
    | '\\' =>
      match rest with
      | '"' :: rest => stringRest fuel (value.push '"') rest
      | '\\' :: rest => stringRest fuel (value.push '\\') rest
      | '/' :: rest => stringRest fuel (value.push '/') rest
      | 'b' :: rest => stringRest fuel (value.push '\x08') rest
      | 'f' :: rest => stringRest fuel (value.push '\x0c') rest
      | 'n' :: rest => stringRest fuel (value.push '\n') rest
      | 'r' :: rest => stringRest fuel (value.push '\r') rest
      | 't' :: rest => stringRest fuel (value.push '\t') rest
      | 'u' :: rest =>
        match unicodeEscape rest with
        | .ok (decoded, rest) => stringRest fuel (value.push decoded) rest
        | .error why => .error why
      | _ => .error "a string has an escape JSON does not have"
    | _ =>
      if character.toNat == 0 then .error "a string holds a NUL"
      else
        if character.toNat < 0x20 then .error "a string holds a control character"
        else stringRest fuel (value.push character) rest

/-- A string at the start of `input`, after any whitespace: its value and what
follows it. -/
def string (input : List Char) : Except String (String × List Char) :=
  match skipSpace input with
  | '"' :: rest => stringRest (rest.length + 1) "" rest
  | _ => .error "a value is not a string"

/-- `variables` with `name` set to `value`: an earlier one of the name is
dropped, so the last one wins. -/
def setLast (variables : Array (String × String)) (name value : String) : Array (String × String) :=
  (variables.filter (·.1 != name)).push (name, value)

/-- The members of an object whose opening brace and first member have been
read, with `fuel` at least the length of `input`: the variables, and what
follows the closing brace. -/
def members :
    Nat → Array (String × String) → List Char → Except String (Array (String × String) × List Char)
  | 0, _, _ => .error "the object is not closed"
  | fuel + 1, variables, input =>
    match skipSpace input with
    | '}' :: rest => .ok (variables, rest)
    | ',' :: rest => do
      let (name, rest) ← string rest
      if name.isEmpty then
        throw "a name is empty"
      if name.contains '=' then
        throw s!"the name {name} holds ="
      match skipSpace rest with
      | ':' :: rest =>
        let (value, rest) ← string rest
        members fuel (setLast variables name value) rest
      | _ =>
        throw s!"the name {name} has no colon"
    | _ => .error "the object is not closed"

/-- The variables of the JSON object of strings `bytes` holds: each name and
its value, in the order they come, where a name that comes twice has its last
value. UTF-8, with JSON's whitespace and escapes. Anything that is not a
string value, a control character or a NUL in a string, a name that holds
`=` or is empty, and anything after the closing brace is refused, with why. -/
def parseVariables (bytes : ByteArray) : Except String (Array (String × String)) := do
  let some text := String.fromUTF8? bytes | throw "it is not UTF-8"
  let input := skipSpace text.toList
  let '{' :: rest := input | throw "it is not an object"
  let (variables, rest) ←
    match skipSpace rest with
    | '}' :: rest =>
      pure (#[], rest)
    | rest =>
      members (rest.length + 1) #[] (',' :: rest)
  unless (skipSpace rest).isEmpty do
    throw "there is more after the object"
  return variables

/-- The environment a child gets once the layers below its command have set
`variables`: those variables over the editor's, then the command's own `own`
over those. A command that clears the editor's environment gets none of
them. A variable the command sets or unsets is the command's, so the result
never depends on the order in which `set` is applied. -/
def Environment.over (variables : Array (String × String)) (own : Environment) : Environment :=
  if own.clear then own
  else
    { clear := false, unset := own.unset
      set :=
        (variables.filter fun (name, _) =>
            !own.unset.contains name && !own.set.any (·.1 == name)) ++
          own.set }

/-- The variables of the layer `above` set over those of the layer `below`:
`above` wins a name both set, and each keeps the order it gave the rest. -/
def layer (below above : Array (String × String)) : Array (String × String) :=
  (below.filter fun (name, _) => !above.any (·.1 == name)) ++ above

/-- What a source whose executable is at none of its candidates does. -/
inductive WhenNone where
  /-- No lookup, and nothing said: the source is left out. -/
  | skip
  /-- No lookup, and the slot records `Failure.missing`, which is said. -/
  | report
  deriving DecidableEq, Repr

/-- How a probe's standard output names a path (`Probe`). -/
inductive ProbeAnswer where
  /-- Its first line, whole. -/
  | line
  /-- The last field of its first line, the fields separated by
  `separator`: the login shell of a passwd line, with `':'`. -/
  | lastField (separator : Char)
  deriving DecidableEq, Repr

/-- The path `output` names as `answer` reads it: its first line, trimmed,
whole or its last field, trimmed; `none` when the output is not UTF-8, or
the path is empty or not absolute. -/
def ProbeAnswer.read (answer : ProbeAnswer) (output : ByteArray) : Option System.FilePath := do
  let text ← String.fromUTF8? output
  let line := ((text.splitOn "\n").headD "").trimAscii.toString
  let named : String :=
    match answer with
    | .line => line
    | .lastField separator =>
      ((line.splitOn (String.singleton separator)).getLastD "").trimAscii.toString
  let path : System.FilePath := ⟨named⟩
  if named.isEmpty || !path.isAbsolute then
    none
  else
    some path

/-- A command whose standard output may name where a source's executable is:
run through the process service, with the editor's own environment and its
source's time limit, and read as `answer` says. -/
structure Probe where
  /-- What it runs: an absolute program in an absolute directory. -/
  command : Command
  /-- How its output names a path. -/
  answer : ProbeAnswer
  deriving DecidableEq, Repr

/-- Where a source's executable is. It is never a bare name. -/
inductive Program where
  /-- At `path`, an absolute path. -/
  | at (path : System.FilePath)
  /-- At the first of `candidates` whose stamp a file request answers,
  resolved once and kept until a reload; `whenNone` when none is there. -/
  | firstOf (candidates : Array System.FilePath) (whenNone : WhenNone)
  /-- At the first absolute path one of `probes` names, each run in order
  through the process service: a refused, failing, empty or relative
  answer passes to the next, and nothing is said of it. At `otherwise` when
  none names one. Resolved once and kept until a reload. -/
  | probed (probes : Array Probe) (otherwise : System.FilePath)
  deriving DecidableEq, Repr

/-- A source of variables for a child's environment, as data: a base, or a
directory source. Every field is data a package can register. It holds
functions, so it is compared by the fields a check reads. -/
structure Source where
  /-- The name the cache and the echo area know it by. -/
  name : String
  /-- Where its executable is. -/
  program : Program
  /-- The command its lookup runs, given the executable, the directory it
  runs in, and the environment so far: the variables of the layers below,
  as `{ set := below }`. -/
  command : System.FilePath → System.FilePath → Environment → Command
  /-- Its output read as variables, in order, or why not. -/
  parse : ByteArray → Except String (Array (String × String))
  /-- What its output must be, for a person: what `Failure.unparsable`
  says it is not. -/
  output : String
  /-- For a directory source, the names of the files whose stamps in the
  directory and in each of its ancestors keep its result. A base ignores
  it. -/
  stampNames : Array String := #[]
  /-- How long its lookups and probes may run, in milliseconds; `none` is
  the shared limit (`Environments.limit`). -/
  limit : Option Nat := none

/-- What a lookup's run came to, as an entry's finding: the variables
`source`'s parser reads from a run that exited 0, or why not. -/
def foundOf (source : Source) : Except ProcessError Ran → Found
  | .error (.timedOut limit) => .failed (.timedOut limit)
  | .error error => .failed (.refused error)
  | .ok { exit := .signal signal, .. } => .failed (.signalled signal)
  | .ok { exit := .code 0, stdout, .. } =>
    match source.parse stdout with
    | .ok variables => .variables variables
    | .error why => .failed (.unparsable source.output why)
  | .ok { exit := .code status, stderr, .. } =>
    let text := (String.fromUTF8? stderr).getD ""
    .failed (.exited status ((text.splitOn "\n").headD "").trimAsciiEnd.toString)

/-- The layer under every directory source. -/
inductive Base where
  /-- launchd's: the editor's own environment, with no lookup. -/
  | inherited
  /-- The variables of `source`, looked up once per run in `directory` over
  the editor's environment. -/
  | lookup (source : Source) (directory : System.FilePath)

/-- The layers a host installs, in order: the base, then each directory
source. -/
structure Sources where
  /-- The layer under the directory sources. -/
  base : Base := .inherited
  /-- The directory sources, each set over the ones before it. -/
  directories : Array Source := #[]

/-- The name of the base built into the core, launchd's (`Base.inherited`):
the base a host installs when no base is chosen, and the one a choice by
this name gives when no package registers a base of it. -/
def inheritedName : String :=
  "inherited"

/-- The layers as the registry gives them, before the host's mode picks
(`EnvironmentApi.ofRegistry`): the base for each mode, and each directory
source for each mode. A host installs them at every reload that installs
(`Environments.install`). -/
structure Registered where
  /-- The base for each mode; `none` keeps the base installed before, which
  is what a name no registered base answers to comes to (the reload reducer
  refuses such a config, so the host never installs one). -/
  base : Option (Host → Base) := some fun _ => .inherited
  /-- The directory sources, in order; one that gives `none` in a mode is
  left out there. -/
  directories : Array (Host → Option Source) := #[]

/-- The layers `registered` gives in the mode `host`, with `kept` as the base
when it names none. -/
def Registered.sources (registered : Registered) (host : Host) (kept : Base) : Sources :=
  { base := (registered.base.map (· host)).getD kept
    directories := registered.directories.filterMap (· host) }

/-- Which lookup an entry belongs to: the cache's key, and what a failure is
said once for. -/
inductive Slot where
  /-- The base, the source `source`: once per run. -/
  | base (source : String)
  /-- The source `source` in `directory`. -/
  | directory (directory : System.FilePath) (source : String)
  deriving DecidableEq, Repr

/-- What the echo area says of a failed lookup in `slot`: the failure, and
that children start without that source's variables alone, the other layers
being kept. -/
def failureMessage : Slot → Failure → String
  | .directory directory source, failure =>
    s!"environment: {directory}: {failure.describe source}; its children start without {source}'s variables"
  | .base source, failure =>
    s!"environment: the base, {source}: {failure.describe source}; children start without the base's variables"

/-- What a job reads before it builds a child's environment: the layers,
what each `firstOf` or `probed` source has resolved to, and the shared time
limit of a lookup, in milliseconds. -/
structure Policy where
  /-- The layers. -/
  sources : Sources
  /-- What each `firstOf` or `probed` source resolved to, by name, once a
  job resolved it. -/
  programs : Array (String × Option System.FilePath)
  /-- How long a lookup of a source with no limit of its own may run, in
  milliseconds. -/
  limit : Nat

/-- The state every job of a host shares: the mode, the time limit, the
layers, what each source's program resolved to, and the caches. The default
is what a runner given no environments has: the headless mode, the inherited
base and no directory source, so children start exactly as their commands
say. -/
structure Environments where
  /-- The mode the editor runs in. -/
  host : Host := .headless
  /-- How long a lookup may run, in milliseconds. -/
  limit : Nat := 5000
  /-- The layers. -/
  sources : Sources := {}
  /-- What each `firstOf` or `probed` source resolved to, by name, until a
  reload. -/
  programs : Array (String × Option System.FilePath) := #[]
  /-- Each slot's entry, oldest first: the base's, and one for each
  directory and source. -/
  entries : Array (Slot × Entry) := #[]

end Process

/-- What a job may ask of the environments its host shares. A new question
is a constructor here. -/
inductive EnvironmentRequest where
  /-- The layers, what each source resolved to and the limit. -/
  | policy
  /-- Keep `program` as what the source `source` resolved to, until a
  reload. -/
  | resolved (source : String) (program : Option System.FilePath)
  /-- The entry of `slot`, if there is one. -/
  | cached (slot : Process.Slot)
  /-- Keep `entry` as the entry of `slot`. -/
  | record (slot : Process.Slot) (entry : Process.Entry)
  deriving DecidableEq, Repr

/-- The type of the reply to each environment request. -/
def EnvironmentRequest.Reply : EnvironmentRequest → Type
  | .policy => Process.Policy
  | .resolved .. => Unit
  | .cached _ => Option Process.Entry
  | .record .. => Unit

namespace Process.Environments

/-- The state after a reload that installs `sources`: those layers, with no
resolved program and no entry, the base's included, and the mode and the
limit kept. -/
def installSources (state : Environments) (sources : Sources) : Environments :=
  { state with
    sources, programs := #[], entries := #[] }

/-- The entry of `slot`, if there is one. -/
def entry? (state : Environments) (slot : Slot) : Option Entry :=
  (state.entries.find? (·.1 == slot)).map (·.2)

/-- The state after a reload that installs `registered`: its layers in the
state's mode, the base it had kept when `registered` names none
(`Registered.sources`), with no resolved program and no entry, the base's
included (`installSources`). -/
def install (state : Environments) (registered : Registered) : Environments :=
  state.installSources (registered.sources state.host state.sources.base)

end Process.Environments

namespace Process.Environments

/-- The answer to `request`, the state after it, and what the echo area is to
say, if anything. Recording a failed entry that is not the one held for its
slot says its message: so a directory and source is reported once until its
entry is dropped, by new stamps, new variables below or a reload, the base
once until a reload, and two jobs that record the same failure report it
once. -/
def handle (state : Environments) :
    (request : EnvironmentRequest) → request.Reply × Environments × Option String
  | .policy =>
    let policy : Policy :=
      { sources := state.sources, programs := state.programs, limit := state.limit }
    (policy, state, none)
  | .resolved source program =>
    ((), { state with programs := (state.programs.filter (·.1 != source)).push (source, program) },
      none)
  | .cached slot => (state.entry? slot, state, none)
  | .record slot entry =>
    let said :=
      match entry.found with
      | .failed failure =>
        if state.entry? slot == some entry then none else some (failureMessage slot failure)
      | .variables _ => none
    ((), { state with entries := (state.entries.filter (·.1 != slot)).push (slot, entry) }, said)

end Process.Environments

end Editor
