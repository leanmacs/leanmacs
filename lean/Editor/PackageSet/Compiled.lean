import Editor.Api
import Editor.Package
import Editor.PackageSet.Build
import Editor.PackageSet.Edit

/-!
# The `package-set` package: a user's package set, from the editor

The core package that edits a user's package set and builds it
(`docs/design/packages.md`, "User package sets"): the job `package-build`
(`Editor/PackageSet/Build.lean`), the commands its posts run, and three
commands with ex names that edit the config's `lakefile.toml`
(`Editor/PackageSet/Edit.lean`).

- **`:package-install <name> <source> [<rev>]`** (`installName`) adds a
  require: a path (starting with `/`, `~` or `.`), a git repository (a url
  with `://`, or `git@…`) with an optional rev, or `<scope>/<name>
  [<version>]` for Reservoir.
- **`:package-remove <name>`** (`removeName`) drops a require, or a
  package of the shipped set the lakefile requires.
- **`:package-update [<name> [<rev>]]`** (`updateName`): with a rev it
  sets the require's rev; otherwise it starts the build in update mode,
  `lake update` for the named package or for every git and Reservoir one,
  with no edit of the lakefile: the manifest pins which revision. A
  lakefile without the core's require at its root, last (one an older
  editor generated, which requires the set alone), is repaired first
  instead (`repair`, `Editor/PackageSet/Edit.lean`), through the edit job,
  and nothing is updated: `lake update` would resolve the git core a
  package names, cloning it, before the build's core check refused it.
  The edit's line says to run it again.

Every edit writes the core's require at the lakefile's root, as its last
require, by the running editor's core directory (`withCoreEdit`,
`Editor/PackageSet/Edit.lean`, "The core's require"), so each repairs a
lakefile without it; an editor that knows no core directory refuses
them: `<command>: this editor knows no directory of its core, so it
cannot write the lakefile's editor-core require`.

An edit is computed from the lakefile as the last reload read it
(`EditorState.packageSet.facts`) and written by the job `package-edit`
(`editWork`), which reads the file again first and refuses one that has
changed since: `<command>: the lakefile changed since the last reload;
:reload and try again`. The job's command then asks for a reload
(`reloadConfig`), and the reload compares the fingerprints and starts the
build. A `lakefile.lean` is refused: the commands edit `lakefile.toml`
only.

Pinned by `ModelTest.packageSetBuildChecks`, on the loop's driver over the
models.
-/

namespace Editor.PackageSet

/-- The command and ex name that adds a require. -/
def installName : String :=
  "package-install"

/-- The command and ex name that drops a require. -/
def removeName : String :=
  "package-remove"

/-- The command and ex name that updates a package. -/
def updateName : String :=
  "package-update"

/-- The job that writes an edited lakefile. -/
def editJob : String :=
  "package-edit"

/-- The words of a command's text argument. -/
def wordsOf (call : Call) : List String :=
  match call.arguments with
  | .str text :: _ => (text.splitOn " ").filter (!·.isEmpty)
  | _ => []

/-- What `:package-install` takes. -/
def installUsage : String :=
  "give <name> <path>, <name> <git url> [<rev>], or <scope>/<name> [<version>]"

/-- The Reservoir require `qualified`, `<scope>/<name>`, names, at
`version`; none when it is not of that form. -/
def reservoirOf? (qualified : String) (version : Option String) : Option Require :=
  match qualified.splitOn "/" with
  | [scope, name] =>
    if scope.isEmpty || name.isEmpty || qualified.startsWith "." || qualified.startsWith "~" then
      none
    else some { name, source := .reservoir scope version }
  | _ => none

/-- The require `name` from `source`, with `rev`, where `home` is what `~`
names: a path, or a git repository. -/
def sourced (home : Option String) (name source : String) (rev : Option String) :
    Except String Require :=
  if source.startsWith "~/" then
    match home with
    | some home => .ok { name, source := .path (home ++ (source.drop 1).toString) }
    | none => .error "~ names no home directory here"
  else
    if source.startsWith "/" || source.startsWith "." then
      if rev.isSome then .error "a path dependency takes no rev"
      else .ok { name, source := .path source }
    else
      if (source.splitOn "://").length > 1 || source.startsWith "git@" then
        .ok { name, source := .git source rev none }
      else .error installUsage

/-- The require `:package-install`'s words name, or why they name none
(the module docs give the forms). -/
def requireOf (home : Option String) : List String → Except String Require
  | [first] =>
    match reservoirOf? first none with
    | some require => .ok require
    | none => .error installUsage
  | [first, second] =>
    match reservoirOf? first (some second) with
    | some require => .ok require
    | none => sourced home first second none
  | [name, source, rev] => sourced home name source (some rev)
  | _ => .error installUsage

/-- The lakefile's text and requires as the last reload read them, or why
the command `command` cannot edit it. -/
def editable (command : String) : EditorM (Option (String × Array Require)) := do
  match (← editorState).packageSet.facts.lakefile with
  | .toml text required =>
    return some (text, required)
  | .lean _ =>
    message
        s!"{command}: this config's lakefile is a lakefile.lean, and the package commands edit lakefile.toml only"
    return none
  | .absent =>
    message s!"{command}: the config directory has no lakefile.toml"
    return none
  | .unreadable why =>
    message s!"{command}: the lakefile cannot be read: {why}"
    return none

/-- Starts the job that writes `edited` over the lakefile, whose text was
`text`, for `command`, saying `done` once written. -/
def writeEdit (command text edited done : String) : EditorM Unit := do
  let config := (← editorState).packageSet.config
  let path := config ++ "/" ++ Config.LakePackage.lakefileName
  if let .error refusal←
      startJob editJob [.str command, .str path, .str text, .str edited, .str done] (key :=
        some editJob) then
    message s!"{command}: {refusal.describe}"

/-- Answers an edit: the new text written, or the refusal said. -/
def edit (command : String) (answer : Except String String) (text done : String) : EditorM Unit :=
  do
  match answer with
  | .ok edited =>
    writeEdit command text edited done
  | .error why =>
    message s!"{command}: {why}"

/-- `:package-install` ("The `package-set` package", in the module docs). -/
def installCommand (call : Call) : EditorM Unit := do
  let state ← editorState
  match requireOf (state.home.map (·.toString)) (wordsOf call) with
  | .error why =>
    message s!"{installName}: {why}"
  | .ok require =>
    let some (text, required) ← editable installName | return
    edit installName
        (withCoreEdit state.packageSet.config state.packageSet.coreDirectory text required
          (install · · require))
        text s!"{installName}: added {require.name}"

/-- `:package-remove` ("The `package-set` package", in the module docs). -/
def removeCommand (call : Call) : EditorM Unit := do
  let [name] := wordsOf call | message s!"{removeName}: give the name of the package to remove"
  let some (text, required) ← editable removeName | return
  let packageSet := (← editorState).packageSet
  edit removeName
      (withCoreEdit packageSet.config packageSet.coreDirectory text required
        (remove · · name packageSet.config packageSet.setName packageSet.facts.setRequires))
      text s!"{removeName}: removed {name}"

/-- `:package-update` ("The `package-set` package", in the module docs). -/
def updateCommand (call : Call) : EditorM Unit := do
  match wordsOf call with
  | [name, rev] =>
    let some (text, required) ← editable updateName | return
    let packageSet := (← editorState).packageSet
    edit updateName
        (withCoreEdit packageSet.config packageSet.coreDirectory text required
          (setRev · · name rev))
        text s!"{updateName}: {name} at {rev}"
  | names =>
    let packageSet := (← editorState).packageSet
    let required :=
      match packageSet.facts.lakefile with
      | .toml _ required => required
      | _ => #[]
    let unknown := names.filter fun name => !required.any (·.name == name)
    unless unknown.isEmpty do
      message s!"{updateName}: the lakefile does not require {", ".intercalate unknown}"
      return
    -- A lakefile without the core's require at its root, last, is repaired
    -- first, so `lake update` never resolves a git core a package names.
    if let .toml text required := packageSet.facts.lakefile then
      if let .ok repaired := repair packageSet.config packageSet.coreDirectory text required then
        unless repaired == text do
          writeEdit updateName text repaired
              s!"{updateName}: wrote the core's require at the root of the lakefile; :{updateName} again to update"
          return
    let resolve :=
      if names.isEmpty then (required.filter (·.source.fetched)).map (·.name) else names.toArray
    match orderOf packageSet packageSet.facts (resolve := some resolve) with
    | .error "" =>
      message s!"{updateName}: this editor cannot build its package set"
    | .error why =>
      message s!"{updateName}: {why}"
    | .ok order =>
      match ← startJob buildJob [.str order.encode] (key := some buildJob) with
      | .error refusal =>
        message s!"{updateName}: {refusal.describe}"
      | .ok () =>
        message startedLine

/-- The command of the build's first post: the build buffer made, or its
text replaced by the header line, and shown ("The buffer" in
`Editor/PackageSet/Build.lean`). -/
def startedCommand (call : Call) : EditorM Unit := do
  let .str line :: _ := call.arguments | return
  let id ←
    match ← findBuffer bufferName with
    | some id =>
      let .ok text ← id.text | return
      id.writing do
          text.replaceRange 0 (← text.byteLength) (line ++ "\n")
      pure id
    | none =>
      let .ok id ← createBuffer bufferName (line ++ "\n") | return
      discard <| id.setReadOnly true
      pure id
  discard <| id.display call.target.window.id opener (focus := false)

/-- The command the build's output is posted to: its lines appended. -/
def outputCommand (call : Call) : EditorM Unit :=
  appendLines
    (call.arguments.toArray.filterMap fun
      | .str line => some line
      | _ => none)

/-- The job `package-edit`: the lakefile read again, and refused when it is
not the text the edit was made from; else the edited text written beside
it and moved over it. Its command says what was done and asks for a
reload. -/
def editWork (arguments : List Argument) : Work := fun _ => do
  let .str command :: .str path :: .str text :: .str edited :: .str done :: _ := arguments
    | throw s!"{editJob}: its arguments are not an edit"
  let current ← readText path
  unless current == some text do
    return message s!"{command}: the lakefile changed since the last reload; :reload and try again"
  let temporary := path ++ ".leanmacs-edit"
  discard <| File.remove temporary
  if let .error error← File.append temporary edited.toUTF8 then
    return message s!"{command}: the lakefile could not be written: {error.describe}"
  match ← runOf (rootCommand "/bin/mv" #[temporary, path]) checkPatience with
  | .ok { exit := .code 0, .. } =>
    return do
      message s!"{done}; reloading"
      reloadConfig
  | _ =>
    discard <| File.remove temporary
    return message s!"{command}: the lakefile could not be written"

/-- The package `package-set` ("The `package-set` package", in the module
docs). -/
def package : Package :=
  { name := "package-set"
    setup := do
      commandWith installName installCommand
      commandWith removeName removeCommand
      commandWith updateName updateCommand
      commandWith startedName startedCommand
      commandWith outputName outputCommand
      workJob buildJob buildWork (reported := true)
      workJob editJob editWork
      exCommand installName installName (takes := .text)
      exCommand removeName removeName (takes := .text)
      exCommand updateName updateName (takes := .text) }

end Editor.PackageSet
