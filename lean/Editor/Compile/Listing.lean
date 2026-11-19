import Editor.Api
import Editor.Compile.Contribution
import Editor.Job
import Editor.ProjectMode

/-!
# Computed commands: a contribution's listing, run in its mode's root

What gives a contribution the named commands it computes
(`Contribution.listing`, `Editor/Compile/Contribution.lean`): a program run
in the mode's root, whose standard output the contribution reads into named
commands, as `mise-mode` runs `mise tasks ls --json`
(`Editor/Compile/Shipped.lean`). Written over the editor API and the job
port: a command may not wait and a job may, so a check is a call that
starts a job (`refreshListings`), the job, which stamps the markers and runs
the listing (`listWork`), and the job's command, which keeps what it gave
(`listed`).

It imports neither `Editor.Compile` nor `Editor.Files`, so that
`Editor/Workspace/Modes.lean`, which `Editor/Workspace/Attach.lean` imports,
can start a check when a mode turns on.

## The rules

- **An entry** (`Listing.Entry`) is kept for each mode and root: the config
  generation it was listed under, the stamps of the contribution's markers
  in the root, in marker order, read before the run, and what came of it,
  the commands listed or why none were.
- **Where entries live** (`listingStore`, `compile-listings`): a buffer's
  place (`placeOfBuffer`) is its workspace's location, whose store holds
  them, so each worktree keeps its own; a buffer outside any workspace's
  are in the unscoped store; a workspace whose location cannot run
  commands (`Location.can`, the rule `compile` and the shell ask too) has
  none, so no listing is started there.
- **A check** (`refreshListings`) starts the job `compile-list` for each
  on-mode whose contribution has a listing, under the key `compile-list
  <mode> <root>`, so a later check of the same mode and root replaces one
  in flight. It hands the job the stamps its entry holds, but only an entry
  listed under the current config generation, so the next check after a
  reload runs the listing again. A start that is refused is silent.
- **The job** (`listWork`) stamps the markers in the root; when they are
  the stamps handed, it does nothing. Otherwise it runs the listing in the
  root (`Process.runWithin`, at most `listingOutput` bytes and
  `listingTime` milliseconds, with the environment every child gets) and
  hands its command what came of it.
- **Its command** (`listed`) asks the loop for the contribution now
  registered: with none of that mode, or one with no listing, it does
  nothing. Otherwise standard output of a run that exited 0 is read by the
  contribution's `read`; anything else is a failure, said `<program
  arguments…> exited with status <n>` (with its first line of standard error
  after a colon, when it has one), `… was ended by signal <n>`, `… printed
  no list of commands: <why>`, `… did not finish within <ms> ms and was
  killed` or `… could not be run: <why>`. The entry is kept, and a failure is
  said in the echo area, `<mode> in <root>: <why>`, when the entry is not
  the one held: so once, until the stamps change or a reload.
- **What is offered** (`listedCommands`): the commands of a mode's entry at
  a root; none for no entry or a failed one.

Pinned by `ModelTest.listingChecks` and `ModelTest.projectModeChecks`.
-/

namespace Editor.Compile

namespace Listing

/-- What a listing came to. -/
inductive Outcome where
  /-- The commands it listed, in order. -/
  | listed (commands : Array NamedCommand)
  /-- Why it gave none. -/
  | failed (why : String)
  deriving BEq, Repr

/-- A mode's listing at a root ("The rules", in the module docs). -/
structure Entry where
  /-- The minor mode. -/
  mode : String
  /-- Its root, where the listing ran. -/
  root : System.FilePath
  /-- The config generation it was listed under. -/
  generation : Nat
  /-- The stamps of the contribution's markers in the root, in marker
  order, read before the run; `none` where there is none. -/
  stamps : Array (Option File.Stamp)
  /-- What came of it. -/
  outcome : Outcome
  deriving BEq, Repr

/-- A named command as a tree: its name, its line and its directory. -/
def encodeCommand (command : NamedCommand) : Value :=
  .list
    [.str command.name, .str command.line,
      optional (fun (directory : System.FilePath) => .str directory.toString) command.directory]

/-- The named command a tree is (`encodeCommand`), if it is one. -/
def decodeCommand? : Value → Option NamedCommand
  | .list [.str name, .str line, .null] => some { name, line }
  | .list [.str name, .str line, .str directory] => some { name, line, directory := some directory }
  | _ => none

/-- A stamp, or none, as a tree. -/
def encodeStamp : Option File.Stamp → Value
  | some stamp => .list [.int stamp.seconds, .nat stamp.nanoseconds, .nat stamp.size]
  | none => .null

/-- The stamp, or none, a tree is (`encodeStamp`), if it is one. -/
def decodeStamp? : Value → Option (Option File.Stamp)
  | .list [.int seconds, .nat nanoseconds, .nat size] => some (some { seconds, nanoseconds, size })
  | .null => some none
  | _ => none

/-- An outcome as a tree. -/
def Outcome.encode : Outcome → Value
  | .listed commands => .record [("listed", .list (commands.toList.map encodeCommand))]
  | .failed why => .record [("failed", .str why)]

/-- The outcome a tree is (`Outcome.encode`), if it is one. -/
def Outcome.decode? : Value → Option Outcome
  | .record [("listed", .list commands)] => (.listed ·.toArray) <$> commands.mapM decodeCommand?
  | .record [("failed", .str why)] => some (.failed why)
  | _ => none

/-- An entry as a tree. -/
def Entry.encode (entry : Entry) : Value :=
  .record
    [("mode", .str entry.mode), ("root", .str entry.root.toString),
      ("generation", .nat entry.generation),
      ("stamps", .list (entry.stamps.toList.map encodeStamp)), ("outcome", entry.outcome.encode)]

/-- The entry a tree is (`Entry.encode`), if it is one. -/
def Entry.decode? : Value → Option Entry
  | .record fields => do
    let .str mode := field fields "mode" | none
    let .str root := field fields "root" | none
    let .nat generation := field fields "generation" | none
    let .list stamps := field fields "stamps" | none
    let stamps ← stamps.mapM decodeStamp?
    let outcome ← Outcome.decode? (field fields "outcome")
    return { mode, root, generation, stamps := stamps.toArray, outcome }
  | _ => none

end Listing

/-- The listings of a place, each mode's at each root ("Where entries
live", in the module docs). -/
def listingStore : Store (Array Listing.Entry) :=
  { name := "compile-listings", version := 1, initial := #[]
    encode := fun entries => .list (entries.toList.map Listing.Entry.encode)
    decode := fun
      | .list items => (·.toArray) <$> items.mapM Listing.Entry.decode?
      | _ => none }

/-- The listing place of a workspace at `location`: the location, where it
can run commands (`Location.can`); none where it cannot ("Where entries
live", in the module docs). -/
def placeOfLocation (location : Location) : Option (Option Location) :=
  if location.can.runCommands then some (some location) else none

/-- The listing place of the buffer `id` in `state`: its workspace's
location, `some none` outside any workspace, and none in a workspace whose
location cannot run commands ("Where entries live", in the module docs). -/
def placeOfBuffer (state : EditorState) (id : BufferId) : Option (Option Location) :=
  match state.workspaceOf? id with
  | some (workspace, _) => placeOfLocation workspace.location
  | none => some none

/-- The entries `place` keeps in `state`. -/
def entriesOf (state : EditorState) : Option Location → Array Listing.Entry
  | some location => state.workspaces.get listingStore location
  | none => state.workspaces.getUnscoped listingStore

/-- The entry of `mode` at `root` among `entries`. -/
def entryOf? (entries : Array Listing.Entry) (mode : String) (root : System.FilePath) :
    Option Listing.Entry :=
  entries.find? fun entry => entry.mode == mode && entry.root == root

/-- Has `place` keep `entry`, in place of its mode's at its root. -/
def keepEntry (place : Option Location) (entry : Listing.Entry) : EditorM Unit := do
  let entries := entriesOf (← editorState) place
  let entries :=
    if (entryOf? entries entry.mode entry.root).isSome then
      entries.map fun kept =>
        if kept.mode == entry.mode && kept.root == entry.root then entry else kept
    else entries.push entry
  match place with
  | some location =>
    discard <| Workspace.set listingStore location entries
  | none =>
    Workspace.setUnscoped listingStore entries

/-- The commands `place`'s entry of a mode at a root lists in `state`; none
for no entry or a failed one ("What is offered", in the module docs). This
is what `offers` is handed. -/
def listedCommands (state : EditorState) (place : Option Location) (mode : String)
    (root : System.FilePath) : Array NamedCommand :=
  match (entryOf? (entriesOf state place) mode root).map (·.outcome) with
  | some (Listing.Outcome.listed commands) => commands
  | _ => #[]

/-- The name the job that runs a listing is registered under. -/
def listJob : String :=
  "compile-list"

/-- The key the listing job of `mode` at `root` is started under. -/
def listKey (mode : String) (root : System.FilePath) : String :=
  s!"{listJob} {mode} {root}"

/-- The most bytes of each stream a listing may write: a mebibyte. -/
def listingOutput : Nat :=
  1024 * 1024

/-- How long a listing may run, in milliseconds. -/
def listingTime : Nat :=
  10000

/-- What the listing job is started with ("A check", in the module docs). -/
structure ListOrder where
  /-- The place whose entry it writes. -/
  place : Option Location
  /-- The minor mode. -/
  mode : String
  /-- Its root, where the listing runs. -/
  root : System.FilePath
  /-- The config generation it is checked under. -/
  generation : Nat
  /-- The contribution's markers. -/
  markers : Array String
  /-- The stamps of the entry held, one per marker; none to run it
  whatever the stamps. -/
  held : Option (Array (Option File.Stamp))
  /-- The listing's program. -/
  program : String
  /-- The program's arguments. -/
  programArguments : Array String
  deriving DecidableEq, Repr

/-- A stamp, or none, as arguments. -/
def stampArguments : Option File.Stamp → List Argument
  | some stamp => [.bool true, .int stamp.seconds, .nat stamp.nanoseconds, .nat stamp.size]
  | none => [.bool false]

/-- The order as the arguments a job is started with: the place, the mode,
the root, the generation, the number of markers and each marker, the held
stamps, the program and each argument. -/
def ListOrder.arguments (order : ListOrder) : List Argument :=
  (match order.place with
    | some location => .str "workspace" :: location.arguments
    | none => [.str "unscoped"]) ++
    [.str order.mode, .str order.root.toString, .nat order.generation, .nat order.markers.size] ++
    order.markers.toList.map .str ++
    (match order.held with
    | some stamps => .bool true :: stamps.toList.flatMap stampArguments
    | none => [.bool false]) ++
    .str order.program :: order.programArguments.toList.map .str

/-- `count` strings at the start of `arguments`, and the rest. -/
def stringsOf? : Nat → List Argument → Option (Array String × List Argument)
  | 0, rest => some (#[], rest)
  | count + 1, .str text :: rest => do
    let (more, rest) ← stringsOf? count rest
    return (#[text] ++ more, rest)
  | _, _ => none

/-- `count` stamps at the start of `arguments` (`stampArguments`), and the
rest. -/
def stampsOf? : Nat → List Argument → Option (Array (Option File.Stamp) × List Argument)
  | 0, rest => some (#[], rest)
  | count + 1, .bool false :: rest => do
    let (more, rest) ← stampsOf? count rest
    return (#[none] ++ more, rest)
  | count + 1, .bool true :: .int seconds :: .nat nanoseconds :: .nat size :: rest => do
    let (more, rest) ← stampsOf? count rest
    return (#[some { seconds, nanoseconds, size }] ++ more, rest)
  | _, _ => none

/-- The order `arguments` are, if they are one (`ListOrder.arguments`). -/
def ListOrder.ofArguments? (arguments : List Argument) : Option ListOrder := do
  let (place, rest) ←
    match arguments with
    | .str "workspace" :: rest =>
      (Location.of? rest).map fun (location, rest) => (some location, rest)
    | .str "unscoped" :: rest =>
      some (none, rest)
    | _ =>
      none
  let .str mode :: .str root :: .nat generation :: .nat count :: rest := rest | none
  let (markers, rest) ← stringsOf? count rest
  let (held, rest) ←
    match rest with
    | .bool false :: rest =>
      some (none, rest)
    | .bool true :: rest =>
      do
        let (stamps, rest) ← stampsOf? count rest
        some (some stamps, rest)
    | _ =>
      none
  let .str program :: rest := rest | none
  let arguments ←
    rest.mapM fun
        | .str argument => some argument
        | _ => none
  return { place, mode, root, generation, markers, held, program,
           programArguments := arguments.toArray }

/-- The child an order runs: its program and arguments in its root. -/
def ListOrder.command (order : ListOrder) : Process.Command :=
  { program := order.program, arguments := order.programArguments, directory := order.root }

/-- The order's program and arguments, as a person reads them. -/
def ListOrder.described (order : ListOrder) : String :=
  " ".intercalate (order.program :: order.programArguments.toList)

/-- What a listing's run came to, read by `read` ("Its command", in the
module docs). -/
def outcomeOf (order : ListOrder) (read : ByteArray → Except String (Array NamedCommand)) :
    Except ProcessError Process.Ran → Listing.Outcome
  | .error (.timedOut limit) =>
    .failed s!"{order.described} did not finish within {limit} ms and was killed"
  | .error error => .failed s!"{order.described} could not be run: {error.describe}"
  | .ok { exit := .signal signal, .. } => .failed s!"{order.described} was ended by signal {signal}"
  | .ok { exit := .code 0, stdout, .. } =>
    match read stdout with
    | .ok commands => .listed commands
    | .error why => .failed s!"{order.described} printed no list of commands: {why}"
  | .ok { exit := .code status, stderr, .. } =>
    let first :=
      (((String.fromUTF8? stderr).getD "").splitOn "\n").headD "" |>.trimAsciiEnd.toString
    if first.isEmpty then .failed s!"{order.described} exited with status {status}"
    else .failed s!"{order.described} exited with status {status}: {first}"

/-- The command a finished listing job hands the loop ("Its command", in the
module docs). -/
def listed (order : ListOrder) (stamps : Array (Option File.Stamp))
    (ran : Except ProcessError Process.Ran) : EditorM Unit := do
  let hook ← RegistryRequest.ask .compileHook
  let some contribution := hook.contributions.find? (·.mode == order.mode) | return
  let some listing := contribution.listing | return
  let entry : Listing.Entry :=
    { mode := order.mode, root := order.root, generation := order.generation, stamps
      outcome := outcomeOf order listing.read ran }
  let held := entryOf? (entriesOf (← editorState) order.place) order.mode order.root
  keepEntry order.place entry
  if let .failed why := entry.outcome then
    if held != some entry then
      message s!"{order.mode} in {order.root}: {why}"

/-- The listing job ("The job", in the module docs). It fails only for
arguments that are not an order. -/
def listWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    ListOrder.ofArguments? arguments | throw s!"{listJob}: its arguments are not a listing order"
  let stamps ←
    order.markers.mapM fun marker => Process.stampOrNone (Process.inDirectory order.root marker)
  if order.held == some stamps then
    return pure ()
  return listed order stamps (← Process.runWithin order.command listingOutput listingTime)

/-- Checks the listing of each of the on-modes `modes` in `place` ("A
check", in the module docs). -/
def refreshListings (place : Option Location) (modes : Array Workspace.OnMode) : EditorM Unit := do
  let hook ← RegistryRequest.ask .compileHook
  let (_, generation) ← RegistryRequest.ask .workspaceSettings
  let entries := entriesOf (← editorState) place
  for on in modes do
    let some contribution := hook.contributions.find? (·.mode == on.mode) | continue
    let some listing := contribution.listing | continue
    let held :=
      (entryOf? entries on.mode on.root).bind fun entry =>
        if entry.generation == generation && entry.stamps.size == contribution.markers.size then
          some entry.stamps
        else none
    let order : ListOrder :=
      { place, mode := on.mode, root := on.root, generation, markers := contribution.markers, held
        program := listing.program, programArguments := listing.arguments }
    -- Refused only when no listing job is registered: nothing is said.
    discard <| startJob listJob order.arguments (key := some (listKey on.mode on.root))

end Editor.Compile
