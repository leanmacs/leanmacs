import Editor.File
import Editor.Process

/-!
# A child's environment, looked up for its directory

What environment does a child started in a directory get? The editor's own,
then the variables its directory's lookup returns set over it, then its
command's own `Environment` (`Process.Environment.over`). The editor's own
process environment is never changed.

This module is the pure part of the answer: the setting config chooses
(`Process.Setting`), how it resolves (`Process.Lookup`), the command a lookup
runs (`Process.lookupCommand`), the files whose stamps keep a lookup's
result (`Process.configPaths`), the parser of what `mise env --json` prints
(`Process.parseVariables`), and the state every job of a host shares
(`Process.Environments`) with the requests a job makes of it
(`EnvironmentRequest`). The program that asks them, `Process.prepared`, is
in `Editor/Job.lean`, beside the process operations it runs before. It
imports only the process and file requests, so nothing of `Std` or `Lean`
reaches config's closure.

## The rules

- **The setting** is config's (`SetupRequest.processEnvironment`,
  `Editor/Setup.lean`): `inherited`, no lookup; `mise`, with an optional
  absolute path to the executable; and the default, `auto`.
- **How it resolves.** `inherited` is no lookup. `mise` with a path is that
  executable. `mise` with none, and `auto` in the window mode, are the first
  of `~/.local/bin/mise`, `/opt/homebrew/bin/mise` and `/usr/local/bin/mise`
  whose stamp a file request answers (`Process.miseCandidates`); with none of
  them, `mise` with no path is `missing` and `auto` is `inherited`. `auto` in
  the headless mode is `inherited`. `mise` is never looked up by bare name:
  launchd's `PATH` holds none of those directories.
- **A lookup** runs `<mise> env --json` in the child's directory, through the
  process service, with a time limit (`ProcessRequest.runWithin`) and an
  output limit, and sets every variable of the JSON object it prints.
- **The cache** is one entry for each directory, kept while the stamps of
  `mise.toml`, `.mise.toml`, `.tool-versions` and `mise.local.toml` in that
  directory and in each of its ancestors are what they were before the
  lookup ran. A reload drops every entry (`Environments.install`). mise also
  reads its global config and environment variables; a change to those is
  picked up after a reload.
- **When a lookup fails** (a status other than 0, a signal, output that is
  not a JSON object of strings, a run past its limit, a refusal, no mise),
  the child starts with the inherited environment and the host says why in
  the echo area, once for each directory until its entry is dropped
  (`Environments.handle`, `record`).

## Adding to this

A new source (direnv, a login shell) is a constructor of `Process.Setting`
and of `Process.Lookup`, with its command and the parser of its output. A new
question a job asks of the shared state is a constructor of
`EnvironmentRequest` with its case in `EnvironmentRequest.Reply` and in
`Environments.handle`.
-/

namespace Editor

namespace Process

/-- Which source answers what environment a child gets: config's setting. -/
inductive Setting where
  /-- In the window mode, `mise` at the first candidate that exists, else
  `inherited`; in the headless mode, `inherited`. The default. -/
  | auto
  /-- No lookup: children start exactly as their commands say. -/
  | inherited
  /-- `mise env --json`, run by the executable at `executable`, an absolute
  path, or by the first candidate that exists when there is none. -/
  | mise (executable : Option System.FilePath)
  deriving DecidableEq, Repr

/-- Which mode the editor runs in, for what `auto` resolves to. -/
inductive Host where
  /-- The window mode, with the user's home directory if `HOME` names one. -/
  | window (home : Option System.FilePath)
  /-- The headless mode, and the checks. -/
  | headless
  deriving DecidableEq, Repr

/-- What a setting resolves to. -/
inductive Lookup where
  /-- No lookup. -/
  | inherited
  /-- `executable env --json`. -/
  | mise (executable : System.FilePath)
  /-- `mise` with no path, and none of `candidates` exists. -/
  | missing (candidates : Array System.FilePath)
  deriving DecidableEq, Repr

/-- `name` in the directory `directory`, with one separator between them, the
root's included. -/
def inDirectory (directory : System.FilePath) (name : String) : System.FilePath :=
  if directory.toString.endsWith "/" then ⟨directory.toString ++ name⟩ else directory / name

/-- Where mise is looked for when no path is given, in order: under the home
directory, if there is one, then Homebrew's two prefixes. -/
def miseCandidates (home : Option System.FilePath) : Array System.FilePath :=
  let underHome : Array System.FilePath :=
    match home with
    | some home => #[inDirectory home ".local/bin/mise"]
    | none => #[]
  underHome ++ #[("/opt/homebrew/bin/mise" : System.FilePath), "/usr/local/bin/mise"]

/-- The lookup a setting resolves to with no file asked about, or `none` when
it resolves to the first candidate that exists. -/
def Setting.resolveNow : Setting → Host → Option Lookup
  | .inherited, _ => some .inherited
  | .mise (some executable), _ => some (.mise executable)
  | .mise none, _ => none
  | .auto, .window _ => none
  | .auto, .headless => some .inherited

/-- The candidates a setting that does not resolve at once picks from. -/
def Host.candidates : Host → Array System.FilePath
  | .window home => miseCandidates home
  | .headless => miseCandidates none

/-- What a setting resolves to when `found` is the first candidate that
exists, if one does. -/
def Setting.resolveWith (setting : Setting) (host : Host) (found : Option System.FilePath) :
    Lookup :=
  match setting.resolveNow host, found with
  | some lookup, _ => lookup
  | none, some executable => .mise executable
  | none, none =>
    match setting with
    | .mise _ => .missing host.candidates
    | _ => .inherited

/-- The command a lookup runs: `executable env --json` in `directory`, with
the editor's environment as it is. -/
def lookupCommand (executable : System.FilePath) (directory : System.FilePath) : Command :=
  { program := executable.toString, arguments := #["env", "--json"], directory }

/-- The names of mise's config files whose stamps keep a lookup's result. -/
def configNames : Array String :=
  #["mise.toml", ".mise.toml", ".tool-versions", "mise.local.toml"]

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

/-- The config files of `directory` and of each of its ancestors up to the
root, nearest first, each directory's in the order of `configNames`. -/
def configPaths (directory : System.FilePath) : Array System.FilePath :=
  (ancestry directory).flatMap fun at_ => configNames.map (inDirectory at_)

/-- Why a lookup did not give variables. -/
inductive Failure where
  /-- It exited with `status`; `stderr` is the first line of its standard
  error. -/
  | exited (status : Nat) (stderr : String)
  /-- It was ended by the signal `signal`. -/
  | signalled (signal : Nat)
  /-- What it printed is not a JSON object of strings: `why`. -/
  | unparsable (why : String)
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

/-- What a failure says, as a clause for a person. -/
def Failure.describe : Failure → String
  | .exited status "" => s!"mise exited with status {status}"
  | .exited status stderr => s!"mise exited with status {status}: {stderr}"
  | .signalled signal => s!"mise was ended by signal {signal}"
  | .unparsable why => s!"mise's output is not a JSON object of strings: {why}"
  | .timedOut limit => s!"mise did not finish within {limit} ms and was killed"
  | .refused error => s!"mise could not be run: {error.describe}"
  | .missing candidates => s!"mise is not at {listed candidates}"

/-- What the echo area says of a failed lookup in `directory`. -/
def failureMessage (directory : System.FilePath) (failure : Failure) : String :=
  s!"environment: {directory}: {failure.describe}; its children get the editor's environment"

/-- What a lookup came to. -/
inductive Found where
  /-- The variables it set, in the order it printed them. -/
  | variables (variables : Array (String × String))
  /-- It failed, so the directory's children get the inherited environment. -/
  | failed (failure : Failure)
  deriving DecidableEq, Repr

/-- A directory's entry in the cache: the stamps of its config files before
its lookup ran (`configPaths`, in order), and what the lookup came to. -/
structure Entry where
  /-- The stamp of each config file, `none` where there is none. -/
  stamps : Array (Option File.Stamp)
  /-- What the lookup came to. -/
  found : Found
  deriving DecidableEq, Repr

/-! ## What `mise env --json` prints

One JSON object whose values are strings. It is read here, and not with
`Lean.Data.Json`, which lives in `Lean`, outside config's closure. -/

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

/-- The environment a child gets once its directory's lookup has set
`variables`: the lookup's variables over the editor's, then the command's own
`own` over those. A command that clears the editor's environment gets none of
the lookup's. A variable the command sets or unsets is the command's, so the
result never depends on the order in which `set` is applied. -/
def Environment.over (variables : Array (String × String)) (own : Environment) : Environment :=
  if own.clear then own
  else
    { clear := false, unset := own.unset
      set :=
        (variables.filter fun (name, _) =>
            !own.unset.contains name && !own.set.any (·.1 == name)) ++
          own.set }

/-- What a lookup's run came to, as an entry's finding: the variables of a run
that exited 0 and printed a JSON object of strings, or why not. -/
def foundOf : Except ProcessError Ran → Found
  | .error (.timedOut limit) => .failed (.timedOut limit)
  | .error error => .failed (.refused error)
  | .ok { exit := .signal signal, .. } => .failed (.signalled signal)
  | .ok { exit := .code 0, stdout, .. } =>
    match parseVariables stdout with
    | .ok variables => .variables variables
    | .error why => .failed (.unparsable why)
  | .ok { exit := .code status, stderr, .. } =>
    let text := (String.fromUTF8? stderr).getD ""
    .failed (.exited status ((text.splitOn "\n").headD "").trimAsciiEnd.toString)

/-- Whether `program` names a directory without being absolute: a command
the process service refuses before anything is started. -/
def namesRelative (program : String) : Bool :=
  program.contains '/' && !program.startsWith "/"

/-- What a job reads before it looks a directory up: the setting, the mode,
the lookup the setting resolved to if it has been resolved, and the time
limit of a lookup, in milliseconds. -/
structure Policy where
  /-- Config's setting. -/
  setting : Setting
  /-- The mode the editor runs in. -/
  host : Host
  /-- What the setting resolved to, once a job has resolved it. -/
  resolved : Option Lookup
  /-- How long a lookup may run, in milliseconds. -/
  limit : Nat
  deriving DecidableEq, Repr

/-- The state every job of a host shares: the setting, the mode, the time
limit, what the setting resolved to, and the cache. The default is what a
runner given no environments has: `auto` in the headless mode, which is
`inherited`. -/
structure Environments where
  /-- Config's setting. -/
  setting : Setting := .auto
  /-- The mode the editor runs in. -/
  host : Host := .headless
  /-- How long a lookup may run, in milliseconds. -/
  limit : Nat := 5000
  /-- What the setting resolved to, once a job has resolved it. -/
  resolved : Option Lookup := none
  /-- Each directory's entry, oldest first. -/
  entries : Array (System.FilePath × Entry) := #[]
  deriving DecidableEq, Repr

end Process

/-- What a job may ask of the environments its host shares. A new question
is a constructor here. -/
inductive EnvironmentRequest where
  /-- The setting, the mode, what the setting resolved to and the limit. -/
  | policy
  /-- Keep `lookup` as what the setting resolved to, until a reload. -/
  | resolved (lookup : Process.Lookup)
  /-- The entry of `directory`, if there is one. -/
  | cached (directory : System.FilePath)
  /-- Keep `entry` as the entry of `directory`. -/
  | record (directory : System.FilePath) (entry : Process.Entry)
  /-- Take `setting` as config's setting, and drop what was resolved and
  every entry: what a reload that installs does. -/
  | install (setting : Process.Setting)
  deriving DecidableEq, Repr

/-- The type of the reply to each environment request. -/
def EnvironmentRequest.Reply : EnvironmentRequest → Type
  | .policy => Process.Policy
  | .resolved _ => Unit
  | .cached _ => Option Process.Entry
  | .record .. => Unit
  | .install _ => Unit

namespace Process.Environments

/-- The state after a reload has installed `setting`: nothing resolved and no
entry, with the mode and the limit kept. -/
def install (state : Environments) (setting : Setting) : Environments :=
  { state with
    setting, resolved := none, entries := #[] }

/-- The entry of `directory`, if there is one. -/
def entry? (state : Environments) (directory : System.FilePath) : Option Entry :=
  (state.entries.find? (·.1 == directory)).map (·.2)

/-- The answer to `request`, the state after it, and what the echo area is to
say, if anything. Recording a failed entry that is not the one held for its
directory says its message: so a directory is reported once until its entry
is dropped, by new stamps or a reload, and two jobs that record the same
failure report it once. -/
def handle (state : Environments) :
    (request : EnvironmentRequest) → request.Reply × Environments × Option String
  | .policy =>
    let policy : Policy :=
      { setting := state.setting, host := state.host, resolved := state.resolved
        limit := state.limit }
    (policy, state, none)
  | .resolved lookup => ((), { state with resolved := some lookup }, none)
  | .cached directory => (state.entry? directory, state, none)
  | .record directory entry =>
    let said :=
      match entry.found with
      | .failed failure =>
        if state.entry? directory == some entry then none
        else some (failureMessage directory failure)
      | .variables _ => none
    ((),
      { state with entries := (state.entries.filter (·.1 != directory)).push (directory, entry) },
      said)
  | .install setting => ((), state.install setting, none)

end Process.Environments

end Editor
