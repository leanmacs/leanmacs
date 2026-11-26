import Editor.File.Model
import Editor.Process.Model
import Editor.Test.Fixture.Fixture

/-!
# The headless fixture harness: setups

What a stepped run of a fixture is given beyond its config directory and
script (`docs/dev-practices/headless-mode.md`, "How the gate runs a
fixture"). **The default is to run stepped, with nothing declared**
(`Setup.default`): the file fake's model holds only the working directory,
`/work/lean`, holding one empty file, `lakefile.lean`, since the gate runs
the CLI in `lean/`, which is never empty, and a listing of it delivers one
batch of entries, which a fixture's job lines count; the process fake's
model scripts nothing; and nothing of the output is scrubbed.

A fixture whose script names a file has a **setup** (`Setup.core`, keyed by
the script's path from the repository's root). It declares:

- the model directory the script's `@DIR@` stands for (`directory`), and
  what `@FILE@` stands for (`file`);
- the checked-in files and trees copied into the model under it (`seeds`);
- what is scrubbed of the output: the directory, written back as `@DIR@`,
  and the lines that start `job `, where the gate dropped them;
- after-checks (`After`): a model file equal to a checked-in file, or no
  output line starting with a prefix;
- scripted process answers (`processes`) and another working directory.

The harness refuses (`refusal?`), naming the fixture: a script that holds a
placeholder (`@FILE@`, `@DIR@` or any other `@…@`) it has no setup for; a
fixture with no expected file and no after-check; and a script that aborts
or waits for a restart and has no entry in the real-thread set
(`Editor/Test/Fixture/RealThread.lean`). So a fixture never passes stepped by
accident. A stepped run that differs from its expected file never has its
expected file edited: the fake is fixed, or the seed added here, or the
fixture moved into the real-thread set with the reason.

Lines are compared as the shell's `diff` sees them (`textLines`): the first
difference from an expected file (`firstDifference?`), the lines each side
alone has (`bothWays`), and a runner entry's CLI output against its stepped
run and its expected file (`compared`); and a real-effect entry's CLI
output with its expected file alone (`expectedDifference?`).

Pure: model-test pins it (`ModelTest/Editor/Test/Fixture/Setup.lean`).
-/

namespace Editor.Test.Fixture

/-- The working directory of a stepped run: an empty directory of the file
fake's model, so the run never reads the real one. The gate runs the CLI in
`lean/`, so its last part is `lean`, which an output names. -/
def defaultWorkingDirectory : String :=
  "/work/lean"

/-- The entries of the working directory of a stepped run, each an empty
file: the gate's `lean/` is never empty, so a listing of the CLI's working
directory delivers one batch, and so must the model's. No output names
them. -/
def defaultWorkingEntries : Array String :=
  #["lakefile.lean"]

/-- What a setup copies into the file fake's model. -/
inductive Seed where
  /-- The checked-in file `source`, from the repository's root, as the
  model's file `target`. -/
  | file (source target : String)
  /-- Every file under the checked-in directory `source`, at the same place
  under the model's directory `target`. -/
  | tree (source target : String)
  deriving DecidableEq, Repr

/-- What a setup checks once a stepped run has ended. -/
inductive After where
  /-- The model's file `target` holds what the checked-in file `checked`
  does. -/
  | fileEquals (target checked : String)
  /-- No output line starts with `prefix`. -/
  | noLineStartsWith (pfx : String)
  deriving DecidableEq, Repr

/-- What a stepped run of a fixture is given (the module docs). -/
structure Setup where
  /-- The model directory the script's `@DIR@` stands for, written back as
  `@DIR@` in the output. -/
  directory : Option String := none
  /-- What the script's `@FILE@` stands for. -/
  file : Option String := none
  /-- What is copied into the file fake's model. -/
  seeds : Array Seed := #[]
  /-- Whether output lines that start `job ` are dropped, where the gate
  dropped them. -/
  dropJobLines : Bool := false
  /-- What is checked once the run has ended. -/
  after : Array After := #[]
  /-- The process fake's model: the runs it answers. -/
  processes : ProcessModel := {}
  /-- The run's working directory, a directory of the file fake's model. -/
  workingDirectory : String := defaultWorkingDirectory
  /-- The entries of the working directory, each an empty file. -/
  workingEntries : Array String := defaultWorkingEntries
  deriving DecidableEq

/-- The setup of a fixture that declares none. -/
def Setup.default : Setup :=
  {}

/-- The model directory of the fixtures that name one file: `/fixture`. -/
def fixtureDirectory : String :=
  "/fixture"

/-- A setup with the checked-in file `source` at `/fixture/<name>`, which
the script's `@FILE@` names, and `/fixture` scrubbed to `@DIR@`. -/
def Setup.oneFile (source name : String) (after : Array After := #[]) : Setup :=
  { directory := some fixtureDirectory, file := some s!"{fixtureDirectory}/{name}"
    seeds := #[.file source s!"{fixtureDirectory}/{name}"], after }

/-- A setup with the checked-in tree `source` at `<directory>/tree`, the
script's `@DIR@` naming `directory`, scrubbed back. `directory` has the
byte length of the `mktemp` template the gate made it with, since the
scene prints byte offsets over the path; it is a path of the model, so
nothing under `/tmp` is touched. -/
def Setup.tree (source directory : String) : Setup :=
  { directory := some directory, seeds := #[.tree source s!"{directory}/tree"] }

/-- What git answers outside a repository, as the real git does under
`/tmp`: its error and status 128, for any `git` run in `directory`. -/
def gitOutside (directory : String) : ProcessModel :=
  {
    scripts :=
      #[{ command := { program := "git", arguments := #["rev-parse", "--show-toplevel"], directory }
          reply :=
            .ok {
                exit := .code 128, stdout := .empty
                stderr :=
                  "fatal: not a git repository (or any of the parent directories): .git\n".toUTF8 } }] }

/-- The setups of the core's fixtures, keyed by their scripts' paths from the
repository's root. A fixture not here takes `Setup.default`. -/
def Setup.core : Array (String × Setup) :=
  #[("tests/headless/column/script",
      .oneFile "tests/headless/column/lines.txt" "lines.txt"
        #[.fileEquals s!"{fixtureDirectory}/lines.txt" "tests/headless/column/lines.txt"]),
    ("tests/headless/view/script",
      .oneFile "tests/headless/view/lines.txt" "lines.txt"
        #[.fileEquals s!"{fixtureDirectory}/lines.txt" "tests/headless/view/lines.txt"]),
    ("tests/headless/session/script",
      .oneFile "tests/headless/session/verse.txt" "verse.txt"
        #[.fileEquals s!"{fixtureDirectory}/verse.txt" "tests/headless/session/verse-expected"]),
    ("tests/headless/ex/save-quit-script",
      .oneFile "tests/headless/ex/note.txt" "note.txt"
        #[.fileEquals s!"{fixtureDirectory}/note.txt" "tests/headless/ex/note-expected",
          .noLineStartsWith "commands:"]),
    ("tests/headless/ex/wq-script",
      .oneFile "tests/headless/ex/note.txt" "note.txt"
        #[.fileEquals s!"{fixtureDirectory}/note.txt" "tests/headless/ex/note-expected",
          .noLineStartsWith "commands:"]),
    ("tests/headless/working-set-reopen/script",
      { Setup.tree "tests/headless/working-set-reopen/tree" "/tmp/working-set.stepped0" with
        processes := gitOutside "/tmp/working-set.stepped0/tree" }),
    ("tests/headless/working-set-from-search/script",
      {
        Setup.tree "tests/headless/working-set-from-search/tree"
          "/tmp/working-set-search.stepped0" with
        dropJobLines := true, processes := gitOutside "/tmp/working-set-search.stepped0/tree" })]

/-- The setup of the fixture whose script is `script`: its own, or the
default. -/
def Setup.of (script : String) (setups : Array (String × Setup) := Setup.core) : Setup :=
  ((setups.find? (·.1 == script)).map (·.2)).getD .default

/-- Whether `script` has a setup of its own among `setups`. -/
def Setup.declared (script : String) (setups : Array (String × Setup) := Setup.core) : Bool :=
  setups.any (·.1 == script)

/-- The placeholders `text` holds, each `@NAME@` of capitals and `_`, in
order, each once. -/
def placeholders (text : String) : Array String :=
  Id.run do
    let parts := (text.splitOn "@").toArray
    let mut found := #[]
    -- A placeholder is a part between two `@` made of capitals and `_` alone.
    for index in [1:parts.size - 1] do
      let part := parts[index]!
      if !part.isEmpty && part.all (fun c => c.isUpper || c == '_') then
        let name := s!"@{part}@"
        unless found.contains name do
          found := found.push name
    return found

/-- The script's text with the setup's placeholders replaced: `@DIR@` by
its directory and `@FILE@` by its file. -/
def Setup.substitute (setup : Setup) (text : String) : String :=
  let text :=
    match setup.directory with
    | some directory => text.replace "@DIR@" directory
    | none => text
  match setup.file with
  | some file => text.replace "@FILE@" file
  | none => text

/-- The placeholders a setup replaces. -/
def Setup.replaces (setup : Setup) : Array String :=
  (if setup.directory.isSome then #["@DIR@"] else #[]) ++
    if setup.file.isSome then #["@FILE@"] else #[]

/-- The output as it is compared: the setup's directory written as `@DIR@`,
and the `job ` lines dropped where the setup drops them. -/
def Setup.scrub (setup : Setup) (lines : Array String) : Array String :=
  let lines :=
    match setup.directory with
    | some directory => lines.map (·.replace directory "@DIR@")
    | none => lines
  if setup.dropJobLines then lines.filter (!·.startsWith "job ") else lines

/-- Every directory above `path`, the root's last: `/a/b/c` has `/a/b`, `/a`
and `/`. -/
def ancestors (path : String) : Array String :=
  Id.run do
    let parts := (path.splitOn "/").filter (!·.isEmpty)
    let mut found := #[]
    for count in [0:parts.length] do
      let kept := parts.take (parts.length - 1 - count)
      found := found.push ("/" ++ "/".intercalate kept)
    return found

/-- The file fake's model of a run with `setup`: its working directory with
its entries, and `files`, each a model path and its bytes, with every directory above them
and each of `directories`. -/
def Setup.model (setup : Setup) (files : Array (String × ByteArray))
    (directories : Array String := #[]) : FileModel :=
  Id.run do
    let mut wanted := #[setup.workingDirectory]
    for directory in directories do
      wanted := wanted.push directory
    for (path, _) in files do
      wanted := wanted ++ ancestors path
    for directory in directories do
      wanted := wanted ++ ancestors directory
    let mut model : FileModel := {}
    let mut made : Array String := #[]
    for directory in wanted do
      unless made.contains directory do
        made := made.push directory
        model := model.withDirectory directory
    for entry in setup.workingEntries do
      model := model.withFile s!"{setup.workingDirectory}/{entry}" .empty
    for (path, bytes) in files do
      model := model.withFile path bytes
    return model

/-- What failed of an after-check over the run's final `model`, its scrubbed
`output`, and `checked`, the bytes of a checked-in file by its path from the
repository's root: none when it holds. -/
def After.failure? (after : After) (model : FileModel) (output : Array String)
    (checked : String → Option ByteArray) : Option String :=
  match after with
  | .fileEquals target source =>
    match model.file? target, checked source with
    | some file, some bytes =>
      if file.bytes == bytes then none else some s!"the model's {target} is not {source}"
    | none, _ => some s!"the model holds no {target}"
    | _, none => some s!"{source} cannot be read"
  | .noLineStartsWith pfx =>
    match output.find? (·.startsWith pfx) with
    | some line => some s!"an output line starts with {pfx.quote}: {line.quote}"
    | none => none

/-- Whether a line of a script is a directive a stepped run cannot do: an
`abort`, which ends its process, or a `restarted`, which waits for the next
one. -/
def endsProcess (line : String) : Bool :=
  let line := line.trimAscii.toString
  line == "abort" || line == "restarted" || line.startsWith "restarted "

/-- Why the harness refuses to run `fixture` stepped, with `script` its
script's text and `setup` its setup, if it has one of its own; `inSet` says
whether it has an entry in the real-thread set (the module docs). None
when it may run. -/
def refusal? (fixture : Parts) (script : String) (setup : Option Setup) (inSet : Bool) :
    Option String :=
  let held := placeholders script
  let replaced := (setup.map Setup.replaces).getD #[]
  let unreplaced := held.filter (!replaced.contains ·)
  let checks := (setup.map (·.after.size)).getD 0
  if !unreplaced.isEmpty then
    some
      s!"{fixture.script} holds {", ".intercalate unreplaced.toList}, and no setup (Editor.Test.Fixture.Setup) says what it stands for"
  else
    if fixture.expected.isNone && checks == 0 then
      some s!"{fixture.script} has no expected file and no after-check"
    else
      if !inSet && (script.splitOn "\n").any endsProcess then
        some
          s!"{fixture.script} aborts or waits for a restart, which a stepped run cannot do, and has no entry in the real-thread set (Editor.Test.Fixture.RealThread)"
      else none

/-- The lines of a text as `$(…)` and `diff` see them: split at line feeds,
with the empty lines at the end dropped. -/
def textLines (text : String) : Array String :=
  let lines := (text.splitOn "\n").toArray
  lines.popWhile (·.isEmpty)

/-- The first difference between the `expected` lines and the `actual` ones,
as a line of the report: its number, and both texts. None when they are the
same. -/
def firstDifference? (expected actual : Array String) : Option String :=
  Id.run do
    for index in [0:max expected.size actual.size] do
      match expected[index]?, actual[index]? with
      | some want, some got =>
        if want != got then
          return some s!"line {index + 1} differs: expected {want.quote}, got {got.quote}"
      | some want, none =>
        return some s!"line {index + 1} is missing: expected {want.quote}"
      | none, some got =>
        return some s!"line {index + 1} is extra: got {got.quote}"
      | none, none =>
        pure ()
    return none

/-- The lines only one side holds, as `diff` puts them: each line of `left`
not at the same place in `right`, with its number, marked `<`, then each of
`right` not at the same place in `left`, marked `>`. Empty when they are the
same. -/
def bothWays (left right : Array String) : Array String :=
  Id.run do
    let mut said := #[]
    for index in [0:left.size] do
      if right[index]? != some left[index]! then
        said := said.push s!"< {index + 1}: {left[index]!}"
    for index in [0:right.size] do
      if left[index]? != some right[index]! then
        said := said.push s!"> {index + 1}: {right[index]!}"
    return said

/-- What is wrong with a runner entry's CLI output `cli`, against its
stepped run `stepped` and its expected file `expected`: the lines each side
alone has, both ways, and the first difference of the CLI's output from the
expected file, which holds even when the two runs agree. Empty when the
three agree. -/
def compared (cli stepped expected : Array String) : Array String :=
  let both := bothWays cli stepped
  let differs :=
    if both.isEmpty then #[]
    else
      #["the CLI over a real loop thread (<) and the stepped run (>) printed otherwise: " ++
          "; ".intercalate both.toList]
  match firstDifference? expected cli with
  | some difference => differs.push s!"the CLI's output is not its expected file: {difference}"
  | none => differs

/-- The first difference of a real-effect entry's CLI output `cli` from its
expected file `expected` (`fixture-test … expect`), as the restore cases
compare one: the run's directory `dir`, when given, written `@DIR@`, and
the lines starting `job ` and `commands:` dropped. None when they agree. -/
def expectedDifference? (cli expected : Array String) (dir : Option String) : Option String :=
  let scrubbed :=
    match dir with
    | some directory => cli.map fun (line : String) => line.replace directory "@DIR@"
    | none => cli
  let kept := scrubbed.filter fun line => !line.startsWith "job " && !line.startsWith "commands:"
  firstDifference? expected kept

end Editor.Test.Fixture
