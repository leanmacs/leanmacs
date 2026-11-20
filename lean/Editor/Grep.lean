import Editor.File

/-!
# Project search, as a job asks for it

The data of the search requests a job can make: every match of a pattern in
the files under a root, honouring ignore files, with open buffers' texts in
place of their files. It is plain data, as `Editor/FileWatch.lean` is. The
requests themselves are requests of the job port (`Editor/Job.lean`,
`JobRequest.grep`): a search is a thing a job waits on, and the operations a
job is written with, `Grep.start` and `Grep.next`, are there.

Walking the files, reading them and deciding each match are the library's
(`crates/editor-grep`, its service over the adapter in
`crates/editor-grep-ripgrep`). Lean never walks a tree for a search.

## The rules

- **A start** (`GrepRequest.start`) names a root, a pattern in the syntax of
  `/`, the overlays, the limits and the bound. The reply names the search
  (`Grep.Id`) for the job that started it: a `next` of an id the job does
  not hold is `noSuchSearch` at once, with nothing asked of the library.
- **Refused before any walk**: a root that is not absolute, or has a `..`
  component (`notAbsolute`); a pattern that does not parse or that the
  engine refuses (`invalid`, with the sentence `/` says); an overlay that
  names no snapshot (`noSuchSnapshot`); a bound of 0 (`failed`).
- **An overlay** is an open buffer's text, as a snapshot the command took,
  searched in place of the file at its path when the walk reaches it. Its
  matches are answered as the buffer's (`Grep.Origin.buffer`). An overlay
  the walk does not reach (its file is ignored) is not searched.
- **A read** (`GrepRequest.next`) waits for the next delivery
  (`Grep.Delivery`): the files found and not yet taken, in the walk's order
  (depth first, each directory's entries by name), at most `bound` matches
  in all, a file with more cut across deliveries under one path; and, in
  the last, how the search ended. A walk that refuses the root (not there,
  not a directory, not readable) is the first read's refusal.
- **A match** is its row, from 0, and its start and stop, byte offsets in
  the file (or the buffer's text).
- **The limits** (`Grep.Limits`) stop a search after so many files with a
  match or so many matches, and its end says it was truncated.
- **A search does not outlive its job.** However the job ends, the runner
  cancels every search the job still holds.
- **Errors are values.** A reply is an `Except GrepError`, which the job
  matches on, or throws `GrepError.describe` of.

## Where an addition goes

| Addition | Where | Pinned by |
|---|---|---|
| A request | A constructor of `GrepRequest` with its case in `GrepRequest.Reply`, and an operation in `Editor/Job.lean` | A clause of `GrepModel.handle` (`Editor/Grep/Model.lean`), the fake and the real service of the runner (`Editor/Job/Fake.lean`, `Editor/Job/Real.lean`), and a property of `JobContract.grepProperties` |
| A refusal | A constructor of `GrepError` with its sentence in `GrepError.describe` | The property that asks for it |
-/

namespace Editor

namespace Grep

/-- Where a search stops. -/
structure Limits where
  /-- How many files with a match it answers. -/
  files : Nat
  /-- How many matches it answers, over every file. -/
  found : Nat
  deriving DecidableEq, Repr

/-- A search, as the job that started it names it: the id of the wait its
start was. It is the job's: another job's requests cannot name it. -/
structure Id where
  /-- The number. -/
  number : Nat
  deriving DecidableEq, Repr, Hashable

/-- One match: its row, from 0, and its start and stop, byte offsets. -/
structure Match where
  /-- The row it is on. -/
  row : Nat
  /-- Where it starts. -/
  start : Nat
  /-- Where it stops. -/
  stop : Nat
  deriving DecidableEq, Repr

/-- Where a file's matches were found. -/
inductive Origin where
  /-- In the file on disk. -/
  | disk
  /-- In an open buffer's text, in place of the file. -/
  | buffer
  deriving DecidableEq, Repr

/-- A file with matches, as a delivery holds it. -/
structure Found where
  /-- Its path: the root as the job spelled it, joined with the path under
  it. -/
  path : System.FilePath
  /-- Where its matches were found. -/
  origin : Origin
  /-- Its matches, in order. -/
  found : Array Match
  deriving DecidableEq, Repr

/-- How a search ended. -/
inductive End where
  /-- It answered every match: so many files and matches. -/
  | complete (files found : Nat)
  /-- It stopped at a limit with more to answer. -/
  | truncated (files found : Nat)
  deriving DecidableEq, Repr

/-- What a read delivers. -/
structure Delivery where
  /-- The files found and not yet taken, in the walk's order. -/
  found : Array Found
  /-- How the search ended, in its last delivery; `none` while it goes on. -/
  ended : Option End
  deriving DecidableEq, Repr

end Grep

/-- Why a search was refused, or a read of one. -/
inductive GrepError where
  /-- The root is not absolute, or has a `..` component. -/
  | notAbsolute (detail : String)
  /-- The root is not there. -/
  | notFound (detail : String)
  /-- The root is not a directory. -/
  | notADirectory (detail : String)
  /-- The system does not let it be read. -/
  | denied (detail : String)
  /-- The pattern does not parse, or its engine refuses it: the sentence `/`
  says. -/
  | invalid (reason : String)
  /-- An overlay names no snapshot: one a command released or never took, or
  one this job does not hold. -/
  | noSuchSnapshot
  /-- No search of the job's has this id. -/
  | noSuchSearch
  /-- Anything else; `detail` says what. -/
  | failed (detail : String)
  deriving DecidableEq, Repr

/-- What a refusal says, as a sentence for a person. -/
def GrepError.describe : GrepError → String
  | .notAbsolute detail => s!"the path is not absolute: {detail}"
  | .notFound detail => s!"the directory is not there: {detail}"
  | .notADirectory detail => s!"the path is not a directory: {detail}"
  | .denied detail => s!"the system does not allow it: {detail}"
  | .invalid reason => reason
  | .noSuchSnapshot => "the search names no snapshot"
  | .noSuchSearch => "the job has no such search"
  | .failed detail => s!"the search failed: {detail}"

/-- What a job may ask of project search. A new request is a constructor
here. -/
inductive GrepRequest where
  /-- Search `root` for `pattern`, with each `(path, source)` of `overlays`
  searched in place of the file at `path`, stopping at `limits`, with at most
  `bound` matches a delivery: the search, named for the job. -/
  |
  start (root : System.FilePath) (pattern : String)
    (overlays : Array (System.FilePath × File.Source)) (limits : Grep.Limits) (bound : Nat)
  /-- Wait for the next delivery of `search`. -/
  | next (search : Grep.Id)
  deriving DecidableEq, Repr

/-- The type of the reply to each search request: a refusal or the result. A
refusal is a value, never a throw. -/
def GrepRequest.Reply : GrepRequest → Type
  | .start .. => Except GrepError Grep.Id
  | .next .. => Except GrepError Grep.Delivery

/-- The reply to `request` that refuses it with `error`, whatever the request:
for a service that answers without asking anyone. -/
def GrepRequest.refused (error : GrepError) : (request : GrepRequest) → request.Reply
  | .start .. => .error error
  | .next .. => .error error

/-- The sources a start's overlays name, to check that the job holds each. -/
def GrepRequest.sources : GrepRequest → Array File.Source
  | .start _ _ overlays _ _ => overlays.map (·.2)
  | .next _ => #[]

end Editor
