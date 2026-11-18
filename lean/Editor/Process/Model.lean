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
- **A fed run** (`runInput`) is answered as a run with a time limit, by the
  command's script: the script carries what the child writes for that
  input. It is recorded with its input in `fed`, so a test sees what was
  written, once it has passed the refusals that start nothing.
- **A run that keeps its head** (`runHead`) is answered as a fed run, except
  that a scripted standard output over the limit answers `Process.Head.cut`
  with its first `limit` bytes and the script's standard error, and is
  recorded as killed, which is what the library does to it. Standard error
  over the limit is still `outputTooLarge`, and output within it answers
  `Process.Head.whole`.

- **A streaming child that pauses** (`Process.Step.pause`) stops for that
  many milliseconds of the job clock from when it begins the step. A read
  that finds nothing to deliver while the child pauses moves the clock to
  the pause's end, the child goes on, and the read is answered by the usual
  rules, through as many pauses as come one after another; when the job's
  cancel comes first, it is answered as a read that nothing can answer is.
  So a job sees a child's first line, alone and with no end, before its
  second. The fake process service, which asks at 0 every time, delivers
  through a pause at once.

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
  /-- Stops for `milliseconds` on the job clock, from the moment it begins
  the step: nothing more is written until the clock has moved that far. -/
  | pause (milliseconds : Nat)
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
  /-- The instant on the job clock at which the pause it is in ends; `none`
  when it is in none. -/
  resumeAt : Option Nat := none
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
  /-- Every fed run started, with what it was fed, oldest first. -/
  fed : Array (Process.Command × ByteArray) := #[]
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
have ended. A child in a pause is not. -/
def done (child : Child) : Bool :=
  child.writing.isNone && child.resumeAt.isNone && child.step ≥ child.script.steps.size

/-- `child`, in no pause, one move on when the job clock reads `now`, or
`none` when it cannot move: it waits for input, or for the bound to leave
room, or it is done. A pause it begins ends `milliseconds` after `now`. -/
def moveOnce (now : Nat) (child : Child) : Option Child :=
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
      | .pause milliseconds => some { next with resumeAt := some (now + milliseconds) }

/-- `child` one move on when the job clock reads `now`, or `none` when it
cannot move: it waits for input, or for the bound to leave room, or for its
pause to end, or it is done. A pause ends when the clock reads its end. -/
def advanceOnce (now : Nat) (child : Child) : Option Child :=
  match child.resumeAt with
  | some instant => if instant ≤ now then some { child with resumeAt := none } else none
  | none => child.moveOnce now

/-- `child` taken as far as it can go when the job clock reads `now`,
through at most `fuel` moves. -/
def advanceFor (now : Nat) : Nat → Child → Child
  | 0, child => child
  | fuel + 1, child =>
    match child.advanceOnce now with
    | some moved => advanceFor now fuel moved
    | none => child

/-- `child` taken as far as it can go when the job clock reads `now`: until
it waits for input, or for the bound to leave room, or for its pause to
end, or is done. A move begins or ends a step, or fills a stream to the
bound, so a few for each step are always enough. -/
def advance (now : Nat) (child : Child) : Child :=
  advanceFor now (4 * child.script.steps.size + 8) child

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

/-- Whether a read of `child` is answered as it is: it has something to
deliver, a line too long, or it is done. -/
def answerable (child : Child) : Bool :=
  child.deliverable .out || child.deliverable .err || child.tooLong .out || child.tooLong .err ||
    child.done

/-- Where a read of `child` made at `now` by a job cancelled at `cancelAt`
is answered from, through at most `fuel` pauses: while it has nothing to
answer and pauses, the clock moves to the pause's end and the child goes
on, unless the cancel comes first. The clock, and the child. -/
def through (cancelAt : Option Nat) : Nat → Nat → Child → Nat × Child
  | 0, now, child => (now, child)
  | fuel + 1, now, child =>
    if child.answerable then (now, child)
    else
      match child.resumeAt with
      | some instant =>
        if cancelAt.any (· ≤ instant) then (now, child)
        else through cancelAt fuel (max now instant) (child.advance (max now instant))
      | Option.none => (now, child)

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

/-- What a run that keeps its head under `limit` answers when its command is
scripted to answer `reply`: standard error past the limit is too large, and
standard output past it is cut to its first `limit` bytes. -/
def headed (limit : Nat) : Except ProcessError Process.Ran → Except ProcessError Process.Head
  | .ok ran =>
    if ran.stderr.size > limit then .error (.outputTooLarge .err limit)
    else
      if ran.stdout.size > limit then .ok (.cut (ran.stdout.extract 0 limit) ran.stderr)
      else .ok (.whole ran)
  | .error error => .error error

/-- `model` with `child` in place of its child of the same id. -/
def put (model : ProcessModel) (child : Child) : ProcessModel :=
  { model with
    children := model.children.map fun held => if held.id == child.id then child else held }

/-- The model's answer to a run of `command` made at `now` by a job cancelled
at `cancelAt`, ended by its time limit `time` if it has one and its script
takes longer, its script's reply given to `answer`, which applies the run's
limit: the reply, the model after it, and the clock after it. -/
def runFor {α : Type} (model : ProcessModel) (now : Nat) (cancelAt : Option Nat)
    (command : Process.Command) (answer : Except ProcessError Process.Ran → Except ProcessError α)
    (time : Option Nat) : Except ProcessError α × ProcessModel × Nat :=
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
            (answer script.reply,
              if killed then { started with killed := started.killed.push command } else started,
              after)
        | none =>
          let after := now + script.takes
          let killed := cancelAt.any fun instant => now < instant && instant ≤ after
          (answer script.reply,
            if killed then { started with killed := started.killed.push command } else started,
            after)

/-- The model's answer to `request` made at `now` on the job clock, by a job
cancelled at `cancelAt` if it ever is: the reply, the model after it, and
the clock after it. -/
def handle (model : ProcessModel) (now : Nat) (cancelAt : Option Nat) :
    (request : ProcessRequest) → request.Reply × ProcessModel × Nat
  | .run command limit => model.runFor now cancelAt command (limited limit) none
  | .runWithin command limit time => model.runFor now cancelAt command (limited limit) (some time)
  | .runInput command input limit time =>
    let (reply, after, now') := model.runFor now cancelAt command (limited limit) (some time)
    let fed := after.started.size > model.started.size
    (reply, if fed then { after with fed := after.fed.push (command, input) } else after, now')
  | .runHead command input limit time =>
    let (reply, after, now') := model.runFor now cancelAt command (headed limit) (some time)
    let fed := after.started.size > model.started.size
    let after := if fed then { after with fed := after.fed.push (command, input) } else after
    -- The library ends a child it cut, unless a cancel or the clock already
    -- did.
    let cut :=
      match reply with
      | .ok (.cut ..) => after.killed.size == model.killed.size
      | _ => false
    (reply, if cut then { after with killed := after.killed.push command } else after, now')
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
                children := model.children.push (child.advance now)
                next := model.next + 1 },
              now)
  | .read process =>
    match model.children.find? (·.id == process.number) with
    | none => (.error .noSuchProcess, model, now)
    | some child =>
      -- A child that pauses with nothing to deliver is waited for, to the
      -- pause's end, unless the cancel comes first.
      let (now, child) := (child.advance now).through cancelAt (child.script.steps.size + 1) now
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
        else (.ok { stdout, stderr }, put (child.advance now), now)
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
      let child := child.advance now
      if !child.streaming.input || child.inputClosed then
        (.error (.inputClosed "the job closed the child's input, or asked for none"), model, now)
      else
        if child.closedItsInput || child.done then
          (.error (.inputClosed "the child has closed its input"), model, now)
        else
          let child := { child with received := child.received ++ bytes }
          (.ok (), model.put (child.advance now), now)
  | .closeInput process =>
    match model.children.find? (·.id == process.number) with
    | none => (.error .noSuchProcess, model, now)
    | some child => (.ok (), model.put ({ child with inputClosed := true }.advance now), now)

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
