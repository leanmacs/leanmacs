import Editor.Process

/-!
# The pure model of the processes a job runs

The processes a job's requests start, as a value: a script for each command
a test expects, saying what the command answers and how long it takes, and
a record of what was started and what was killed. `ProcessModel.handle`
answers each process request (`Editor/Process.lean`) as a pure function,
with no process and no library, so the logic above the job port is tested
by `lake test` alone. The job port's model hands its process requests to it
(`JobModel.processes`, `Editor/Job/Model.lean`), and the fake of the job
runner's process service is this model behind a reference
(`Editor/Job/Fake.lean`).

## How it answers

- **A run is refused in this order**: a directory that is not absolute; a
  program that names a directory and is not absolute; a command with no
  script, as `notFound`, as a program that is not there would be. None of
  them starts anything.
- **A scripted run** is recorded as started, and moves the job clock on by
  the script's `takes`, in milliseconds: so a job model whose cancellation
  falls inside the run sees it there, as it sees one inside a wait. Then the
  run is recorded as killed, which is what the library does to a cancelled
  job's child.
- **A stream past the limit** answers `outputTooLarge`, standard output
  looked at first, in place of the script's reply.
- **A run with a time limit** (`runWithin`) whose script takes longer than
  the limit answers `timedOut`, moves the clock on by the limit alone, and
  is recorded as killed. One within the limit is a run.

The contract (`JobContract.processProperties`, `Editor/Job/Contract.lean`)
is what says the model, the fake and the library agree: each property
carries the scripts of its commands, and the library's run of the same
property is what shows them true. A clause added to `ProcessModel.handle`
needs its property there.
-/

namespace Editor

/-- Two replies of a run are equal when they are the same case with equal
contents. `Except` derives no equality, and a script holds one. -/
instance : DecidableEq (Except ProcessError Process.Ran)
  | .ok a, .ok b =>
    if h : a = b then isTrue (congrArg Except.ok h) else isFalse fun e => h (Except.ok.inj e)
  | .error a, .error b =>
    if h : a = b then isTrue (congrArg Except.error h) else isFalse fun e => h (Except.error.inj e)
  | .ok _, .error _ => isFalse fun e => by cases e
  | .error _, .ok _ => isFalse fun e => by cases e

/-- What a scripted command does. -/
structure Process.Script where
  /-- The command. -/
  command : Process.Command
  /-- What a run of it answers, within any limit. -/
  reply : Except ProcessError Process.Ran
  /-- How long a run of it takes, in milliseconds on the job clock. -/
  takes : Nat := 0
  deriving DecidableEq

/-- One thing a scripted streaming child does. -/
inductive Process.Step where
  /-- Writes `bytes` to `stream`, as the bound lets it. -/
  | write (stream : Process.Stream) (bytes : ByteArray)
  /-- Waits for a line of its input, then writes it with its line feed; at
  the end of its input, writes what is left of it. -/
  | echoLine (stream : Process.Stream)
  /-- Writes back everything it is written until its input ends, as `cat`
  does. -/
  | echoUntilClosed (stream : Process.Stream)
  /-- Reads its input, and drops it, until it ends. -/
  | awaitClosed
  /-- Closes its own standard input: a later write to it is refused. -/
  | closesInput
  deriving DecidableEq

/-- What a scripted streaming command does: its steps, in order, then it
exits as `exit`. -/
structure Process.StreamScript where
  /-- The command. -/
  command : Process.Command
  /-- What it does. -/
  steps : Array Process.Step := #[]
  /-- How it exits once its steps are done. -/
  exit : Process.Exit := .code 0
  deriving DecidableEq

/-- A streaming child of the model's: where it is in its script, and what it
has written and not yet been read of it. -/
structure ProcessModel.Child where
  /-- Its id. -/
  id : Nat
  /-- What it does. -/
  script : Process.StreamScript
  /-- How it was started. -/
  streaming : Process.Streaming
  /-- How many of its steps it has begun. -/
  step : Nat := 0
  /-- The write it is in the middle of: its stream, its bytes, and how many
  of them it has written. -/
  writing : Option (Process.Stream × ByteArray × Nat) := none
  /-- Every byte the job has written to its input. -/
  received : ByteArray := .empty
  /-- How many of them it has read. -/
  consumed : Nat := 0
  /-- Whether the job has closed its input. -/
  inputClosed : Bool := false
  /-- Whether it has closed its own input. -/
  closedItsInput : Bool := false
  /-- What it has written to its standard output and has not been delivered. -/
  stdout : ByteArray := .empty
  /-- What it has written to its standard error and has not been delivered. -/
  stderr : ByteArray := .empty
  deriving DecidableEq

/-- The model of the processes a job runs. -/
structure ProcessModel where
  /-- What each command a test expects does. -/
  scripts : Array Process.Script := #[]
  /-- What each streaming command a test expects does. -/
  streams : Array Process.StreamScript := #[]
  /-- Every streaming child started and not forgotten, oldest first. -/
  children : Array ProcessModel.Child := #[]
  /-- The id the next streaming child is given. -/
  next : Nat := 1
  /-- Every command started, oldest first. -/
  started : Array Process.Command := #[]
  /-- Every command killed because its job was cancelled while it ran,
  oldest first. -/
  killed : Array Process.Command := #[]
  deriving DecidableEq

namespace ProcessModel.Child

/-- What `child` has written to `stream` and has not been delivered. -/
def held (child : Child) : Process.Stream → ByteArray
  | .out => child.stdout
  | .err => child.stderr

/-- How `stream` of `child` is framed. -/
def framing (child : Child) : Process.Stream → Process.Framing
  | .out => child.streaming.stdout
  | .err => child.streaming.stderr

/-- How many more bytes of `stream` the bound lets `child` write. -/
def room (child : Child) (stream : Process.Stream) : Nat :=
  child.streaming.bound - (child.held stream).size

/-- `child` with `bytes` written to `stream`. -/
def push (child : Child) (stream : Process.Stream) (bytes : ByteArray) : Child :=
  match stream with
  | .out => { child with stdout := child.stdout ++ bytes }
  | .err => { child with stderr := child.stderr ++ bytes }

/-- Whether `child`'s input has ended for it: the job closed it, it closed it
itself, or it is not a pipe. -/
def inputEnded (child : Child) : Bool :=
  child.inputClosed || child.closedItsInput || !child.streaming.input

/-- Whether `child` is done with its steps: it has exited, and its streams
have ended. -/
def done (child : Child) : Bool :=
  child.writing.isNone && child.step ≥ child.script.steps.size

/-- `child` one move on, or `none` when it cannot move: it waits for input,
or for the bound to leave room, or it is done. -/
def advanceOnce (child : Child) : Option Child :=
  match child.writing with
  | some (stream, bytes, written) =>
    let room := child.room stream
    if room == 0 then none
    else
      let count := min room (bytes.size - written)
      let child := child.push stream (bytes.extract written (written + count))
      if written + count ≥ bytes.size then some { child with writing := none }
      else some { child with writing := some (stream, bytes, written + count) }
  | none =>
    match child.script.steps[child.step]? with
    | none => none
    | some step =>
      let unread := child.received.extract child.consumed child.received.size
      let next := { child with step := child.step + 1 }
      match step with
      | .write stream bytes => some { next with writing := some (stream, bytes, 0) }
      | .echoLine stream =>
        match unread.data.findIdx? (· == 10) with
        | some feed =>
          some
            { next with
              consumed := child.consumed + feed + 1
              writing := some (stream, unread.extract 0 (feed + 1), 0) }
        | none =>
          if child.inputEnded then
            some
              { next with
                consumed := child.received.size
                writing := some (stream, unread, 0) }
          else none
      | .echoUntilClosed stream =>
        if unread.size > 0 then
          some
            { child with
              consumed := child.received.size
              writing := some (stream, unread, 0) }
        else if child.inputEnded then some next else none
      | .awaitClosed =>
        if child.inputEnded then some { next with consumed := child.received.size } else none
      | .closesInput => some { next with closedItsInput := true }

/-- `child` taken as far as it can go, through at most `fuel` moves. -/
def advanceFor : Nat → Child → Child
  | 0, child => child
  | fuel + 1, child =>
    match child.advanceOnce with
    | some moved => advanceFor fuel moved
    | none => child

/-- `child` taken as far as it can go: until it waits for input, or for the
bound to leave room, or is done. A move begins or ends a step, or fills a
stream to the bound, so a few for each step are always enough. -/
def advance (child : Child) : Child :=
  advanceFor (4 * child.script.steps.size + 8) child

/-- Whether `bytes` holds a line feed. -/
def hasLineFeed (bytes : ByteArray) : Bool :=
  bytes.data.contains 10

/-- Whether a read of `stream` would give anything: a whole line, or under
bytes framing any byte, or, once `child` is done, a last line. -/
def deliverable (child : Child) (stream : Process.Stream) : Bool :=
  let held := child.held stream
  match child.framing stream with
  | .bytes => held.size > 0
  | .lines => hasLineFeed held || (child.done && held.size > 0)

/-- Whether `stream` holds a partial line that alone fills the bound and
`child` has more of it to write, so the line is longer than the bound and
can never be delivered whole. A partial line exactly the bound long is not
too long while the child has nothing more to write to it: it is a last line
if the child ends there. -/
def tooLong (child : Child) (stream : Process.Stream) : Bool :=
  let held := child.held stream
  let writesMore :=
    match child.writing with
    | some (writing, _, _) => writing == stream
    | none => false
  child.framing stream == .lines && !hasLineFeed held && held.size ≥ child.streaming.bound &&
    writesMore

/-- The whole lines of `bytes` and the bytes after its last line feed. -/
def splitLines (bytes : ByteArray) : Array ByteArray × ByteArray :=
  let (lines, start) :=
    (List.range bytes.size).foldl (init := (#[], 0)) fun (lines, start) offset =>
      if bytes.get! offset == 10 then (lines.push (bytes.extract start offset), offset + 1)
      else (lines, start)
  (lines, bytes.extract start bytes.size)

/-- Takes what a read gives of `stream`: its frames, and what is left. -/
def take (child : Child) (stream : Process.Stream) : Process.Frames × ByteArray :=
  let held := child.held stream
  match child.framing stream with
  | .bytes => (.bytes held, .empty)
  | .lines =>
    let (lines, rest) := splitLines held
    if child.done && rest.size > 0 then (.lines (lines.push rest), .empty) else (.lines lines, rest)

/-- No frames of `stream`'s framing. -/
def none (child : Child) (stream : Process.Stream) : Process.Frames :=
  match child.framing stream with
  | .bytes => .bytes .empty
  | .lines => .lines #[]

end ProcessModel.Child

namespace ProcessModel

/-- What a run of `command` under `limit` answers when the command is
scripted to answer `reply`: a stream past the limit, standard output first,
is too large. -/
def limited (limit : Nat) : Except ProcessError Process.Ran → Except ProcessError Process.Ran
  | .ok ran =>
    if ran.stdout.size > limit then .error (.outputTooLarge .out limit)
    else if ran.stderr.size > limit then .error (.outputTooLarge .err limit) else .ok ran
  | .error error => .error error

/-- `model` with `child` in place of its child of the same id. -/
def put (model : ProcessModel) (child : Child) : ProcessModel :=
  { model with
    children := model.children.map fun held => if held.id == child.id then child else held }

/-- The model's answer to a run of `command` under `limit` made at `now` by
a job cancelled at `cancelAt`, ended by its time limit `time` if it has one
and its script takes longer: the reply, the model after it, and the clock
after it. -/
def runFor (model : ProcessModel) (now : Nat) (cancelAt : Option Nat) (command : Process.Command)
    (limit : Nat) (time : Option Nat) : Except ProcessError Process.Ran × ProcessModel × Nat :=
  if !command.directory.isAbsolute then (.error .relativeDirectory, model, now)
  else
    if command.namesRelative then (.error .relativeProgram, model, now)
    else
      match model.scripts.find? (·.command == command) with
      | none =>
        (.error
            (.notFound
              s!"cannot start `{command.program}` in {command.directory}: the model has no script for it"),
          model, now)
      | some script =>
        let started := { model with started := model.started.push command }
        match time with
        | some time =>
          if script.takes > time then
            -- The limit kills it, whether or not a cancel comes first.
            (.error (.timedOut time), { started with killed := started.killed.push command },
              now + time)
          else
            let after := now + script.takes
            let killed := cancelAt.any fun instant => now < instant && instant ≤ after
            (limited limit script.reply,
              if killed then { started with killed := started.killed.push command } else started,
              after)
        | none =>
          let after := now + script.takes
          let killed := cancelAt.any fun instant => now < instant && instant ≤ after
          (limited limit script.reply,
            if killed then { started with killed := started.killed.push command } else started,
            after)

/-- The model's answer to `request` made at `now` on the job clock, by a job
cancelled at `cancelAt` if it ever is: the reply, the model after it, and
the clock after it. -/
def handle (model : ProcessModel) (now : Nat) (cancelAt : Option Nat) :
    (request : ProcessRequest) → request.Reply × ProcessModel × Nat
  | .run command limit => model.runFor now cancelAt command limit none
  | .runWithin command limit time => model.runFor now cancelAt command limit (some time)
  | .start command streaming =>
    if !command.directory.isAbsolute then (.error .relativeDirectory, model, now)
    else
      if command.namesRelative then (.error .relativeProgram, model, now)
      else
        match model.streams.find? (·.command == command) with
        | none =>
          (.error
              (.notFound
                s!"cannot start `{command.program}` in {command.directory}: the model has no script for it"),
            model, now)
        | some script =>
          if streaming.bound == 0 then
            (.error (.failed "the bound must be at least one byte"), model, now)
          else
            let child : Child := { id := model.next, script, streaming }
            (.ok ⟨model.next⟩,
              { model with
                started := model.started.push command
                children := model.children.push child.advance
                next := model.next + 1 },
              now)
  | .read process =>
    match model.children.find? (·.id == process.number) with
    | none => (.error .noSuchProcess, model, now)
    | some child =>
      let child := child.advance
      let forget (model : ProcessModel) :=
        { model with children := model.children.filter (·.id != child.id) }
      let put (child : Child) := model.put child
      if child.deliverable .out || child.deliverable .err then
        let (stdout, outRest) := child.take .out
        let (stderr, errRest) := child.take .err
        let child :=
          { child with
            stdout := outRest, stderr := errRest }
        if child.done && outRest.size == 0 && errRest.size == 0 then
          (.ok { stdout, stderr, ended := some (.exited child.script.exit) }, forget model, now)
        else (.ok { stdout, stderr }, put child.advance, now)
      else
        match [Process.Stream.out, .err].find? child.tooLong with
        | some stream =>
          (.ok {
                stdout := child.none .out, stderr := child.none .err
                ended := some (.lineTooLong stream child.streaming.bound) },
            { forget model with killed := model.killed.push child.script.command }, now)
        | none =>
          if child.done then
            (.ok {
                  stdout := child.none .out, stderr := child.none .err
                  ended := some (.exited child.script.exit) }, forget model, now)
          else
            -- Nothing can ever answer this read: only a cancel ends it.
            match cancelAt with
            | some instant => (.error (.failed "the job was cancelled"), put child, max now instant)
            | none =>
              (.error (.failed "the model's child waits for input that is never written"),
                put child, now)
  | .write process bytes =>
    match model.children.find? (·.id == process.number) with
    | none => (.error .noSuchProcess, model, now)
    | some child =>
      let child := child.advance
      if !child.streaming.input || child.inputClosed then
        (.error (.inputClosed "the job closed the child's input, or asked for none"), model, now)
      else
        if child.closedItsInput || child.done then
          (.error (.inputClosed "the child has closed its input"), model, now)
        else
          let child := { child with received := child.received ++ bytes }
          (.ok (), model.put child.advance, now)
  | .closeInput process =>
    match model.children.find? (·.id == process.number) with
    | none => (.error .noSuchProcess, model, now)
    | some child => (.ok (), model.put { child with inputClosed := true }.advance, now)

/-- Ends the streaming child `id`, as a cancel does: recorded as killed if
it was still running, and forgotten. Nothing for an id it does not hold. -/
def kill (model : ProcessModel) (id : Nat) : ProcessModel :=
  match model.children.find? (·.id == id) with
  | none => model
  | some child =>
    { model with
      children := model.children.filter (·.id != id)
      killed := if child.done then model.killed else model.killed.push child.script.command }

/-- Ends every streaming child, as the runner does when their job ends:
each still running is recorded as killed, and every one is forgotten. -/
def endAll (model : ProcessModel) : ProcessModel :=
  { model with
    children := #[]
    killed := model.killed ++ (model.children.filter (!·.done)).map (·.script.command) }

end ProcessModel

end Editor
