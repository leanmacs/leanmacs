import Editor.File.Model
import Editor.Grep

/-!
# The pure model of project search

The searches a job's requests start, as a value, over the files and the
snapshots of the model of the files (`Editor/File/Model.lean`).
`GrepModel.handle` answers each search request (`Editor/Grep.lean`) as a pure
function, with no file and no library, so the logic above the job port is
tested by `lake test` alone. The job port's model hands its search requests
to it (`JobModel.greps`, `Editor/Job/Model.lean`), and the fake of the job
runner's grep service is this model behind the fake file service's
reference (`FakeFiles.greps`, `Editor/Job/Fake.lean`).

## How it answers

- **A start is refused in this order**: a root that is not absolute, or has
  a `..` component, as `notAbsolute`; a bound of 0, as `failed`; a pattern
  that is not literal, as `invalid` (the model matches literal patterns
  only, as the text model does: `TextModel.literalOf`); an overlay whose
  source names no snapshot, as `noSuchSnapshot`.
- **Otherwise the whole search is worked at the start**, and its
  deliveries kept: the model's world does not change while a job waits. A
  root not among the directories is the first read's refusal, `notFound`,
  or `notADirectory` when a file is there, as the library's walk refuses
  it.
- **The walk**: the files under the root, depth first, each directory's
  entries by name, leaving out a path with a component that starts with `.`
  and one with a component that a line of the root's `.ignore` names: the
  model's stand-in for the ignore files the library reads.
- **The matches** of a file are the literal's (`TextModel.literalMatches`)
  in its text as a load decodes it, or in its overlay's snapshot; a file
  with a NUL byte is binary and has none. A match's row is the line feeds
  before it.
- **The limits and the deliveries** are the library's rule
  (`editor_grep::service`): the file past the files limit, or the match past
  the matches limit, is not answered and the end is `truncated`; a delivery
  holds at most `bound` matches, a file with more cut across deliveries, and
  the last holds the end.
- **A `next` of a search the model does not hold** is `noSuchSearch`. After
  its last delivery a search is forgotten.

The contract (`JobContract.grepProperties`, `Editor/Job/Contract.lean`) is
what says the model, the fake and the library agree.
-/

namespace Editor

/-- Two kept searches are equal when they are the same case with equal
contents. `Except` derives no equality. -/
instance : DecidableEq (Except GrepError (Array Grep.Delivery))
  | .ok a, .ok b =>
    if h : a = b then isTrue (congrArg Except.ok h) else isFalse fun e => h (Except.ok.inj e)
  | .error a, .error b =>
    if h : a = b then isTrue (congrArg Except.error h) else isFalse fun e => h (Except.error.inj e)
  | .ok _, .error _ => isFalse fun e => by cases e
  | .error _, .ok _ => isFalse fun e => by cases e

/-- Two replies of a `next` are equal when they are the same case with equal
contents. -/
instance : DecidableEq (Except GrepError Grep.Delivery)
  | .ok a, .ok b =>
    if h : a = b then isTrue (congrArg Except.ok h) else isFalse fun e => h (Except.ok.inj e)
  | .error a, .error b =>
    if h : a = b then isTrue (congrArg Except.error h) else isFalse fun e => h (Except.error.inj e)
  | .ok _, .error _ => isFalse fun e => by cases e
  | .error _, .ok _ => isFalse fun e => by cases e

/-- A search of the model's: its id, and what its reads are still to
deliver, oldest first, or the refusal its first read is. -/
structure GrepModel.Search where
  /-- Its id. -/
  id : Nat
  /-- What its reads deliver, in order; a refusal is the first read's. -/
  deliveries : Except GrepError (Array Grep.Delivery)
  deriving DecidableEq

/-- The model of the searches a job started. -/
structure GrepModel where
  /-- Every search started and not ended, oldest first. -/
  searches : Array GrepModel.Search := #[]
  /-- The id the next search is given. -/
  next : Nat := 1
  /-- Every search ended with its job, oldest first. -/
  ended : Array Nat := #[]
  deriving DecidableEq

namespace GrepModel

/-- The components of `path` under `root`, if it is under it and not it. -/
def relative (root path : System.FilePath) : Option (List String) :=
  let parts := root.components
  if path.components.take parts.length == parts && path.components.length > parts.length then
    some (path.components.drop parts.length)
  else none

/-- Whether `a` comes before `b` in the walk: component by component, each
by its characters, which is the order of their bytes. -/
def walkBefore : List String → List String → Bool
  | [], [] => false
  | [], _ :: _ => true
  | _ :: _, [] => false
  | a :: as, b :: bs => if a == b then walkBefore as bs else decide (a < b)

/-- The names the root's `.ignore` lists, a line each. -/
def ignoredNames (files : FileModel) (root : System.FilePath) : List String :=
  match files.files.find? (·.path == root / ".ignore") with
  | some file => ((FileModel.decode file.bytes).splitOn "\n").filter (!·.isEmpty)
  | none => []

/-- The files the walk visits under `root`, in its order, each with its
components under the root. -/
def walked (files : FileModel) (root : System.FilePath) : Array (FileModel.File × List String) :=
  let ignored := ignoredNames files root
  let kept :=
    files.files.filterMap fun file =>
      match relative root file.path with
      | some parts =>
        if parts.any (·.startsWith ".") || parts.any ignored.contains then none
        else some (file, parts)
      | none => none
  kept.qsort fun a b => walkBefore a.2 b.2

/-- The rows and offsets of each match of `literal` in `text`. -/
def matchesIn (text : String) (literal : TextModel.Literal) : Array Grep.Match :=
  let bytes := text.toUTF8
  (TextModel.literalMatches text literal).filterMap fun extent =>
    if extent.start == extent.stop then none
    else
      let row := ((bytes.extract 0 extent.start).toList.filter (· == 10)).length
      some { row, start := extent.start, stop := extent.stop }

/-- The files with matches of a search, in the walk's order, under its
limits, and how it ends. -/
def worked (files : FileModel) (root : System.FilePath) (literal : TextModel.Literal)
    (overlays : Array (System.FilePath × String)) (limits : Grep.Limits) :
    Array Grep.Found × Grep.End :=
  Id.run do
    let mut found : Array Grep.Found := #[]
    let mut count := 0
    for (file, _) in walked files root do
      let (origin, text?) :=
        match overlays.find? (·.1 == file.path) with
        | some (_, text) => (Grep.Origin.buffer, some text)
        | none =>
          if file.bytes.toList.contains 0 then (Grep.Origin.disk, none)
          else (Grep.Origin.disk, some (FileModel.decode file.bytes))
      let some text := text? | continue
      let matched := matchesIn text literal
      if matched.isEmpty then
        continue
      if found.size == limits.files then
        return (found, .truncated found.size count)
      let room := limits.found - count
      if matched.size > room then
        let cut := matched.extract 0 room
        if !cut.isEmpty then
          found := found.push { path := file.path, origin, found := cut }
        return (found, .truncated found.size (count + cut.size))
      found := found.push { path := file.path, origin, found := matched }
      count := count + matched.size
    return (found, .complete found.size count)

/-- `found` delivered at most `bound` matches a read, a file with more cut
across reads, the last read holding `ending`. -/
def deliver (found : Array Grep.Found) (ending : Grep.End) (bound : Nat) : Array Grep.Delivery :=
  Id.run do
    -- Each file's matches, cut into pieces of at most `bound`.
    let pieces : Array Grep.Found :=
      found.foldl (init := #[]) fun pieces file =>
        let rec cutUp (rest : List Grep.Match) (fuel : Nat) (acc : Array Grep.Found) :
          Array Grep.Found :=
          match fuel, rest with
          | 0, _ => acc
          | _, [] => acc
          | fuel + 1, rest =>
            cutUp (rest.drop bound) fuel (acc.push { file with found := (rest.take bound).toArray })
        cutUp file.found.toList file.found.size pieces
    let mut deliveries : Array Grep.Delivery := #[]
    let mut current : Array Grep.Found := #[]
    let mut size := 0
    for piece in pieces do
      if size + piece.found.size > bound && !current.isEmpty then
        deliveries := deliveries.push { found := current, ended := none }
        current := #[]
        size := 0
      current := current.push piece
      size := size + piece.found.size
    return deliveries.push { found := current, ended := some ending }

/-- Why `root` may not be searched at all, if it may not: the library's
`refusal_before_search`. -/
def refusal (root : System.FilePath) : Option GrepError :=
  if !root.isAbsolute then some (.notAbsolute s!"cannot search {root}: the path is not absolute")
  else
    if root.components.contains ".." then
      some (.notAbsolute s!"cannot search {root}: the path has a `..` component")
    else none

/-- The deliveries of a search, worked at once, or why it may not start. -/
def plan (files : FileModel) (root : System.FilePath) (pattern : String)
    (overlays : Array (System.FilePath × File.Source)) (limits : Grep.Limits) (bound : Nat) :
    Except GrepError (Except GrepError (Array Grep.Delivery)) := do
  if let some error := refusal root then
    throw error
  if bound == 0 then
    throw (.failed s!"cannot search {root}: a bound of 0 delivers nothing")
  let some literal := TextModel.literalOf pattern | throw (.invalid TextModel.notLiteral)
  let texts ←
    overlays.mapM fun (path, source) =>
        match files.source? source with
        | some content => pure (path, content.contents)
        | none => throw GrepError.noSuchSnapshot
  if !files.directories.contains root then
    if files.files.any (·.path == root) then
      return .error (.notADirectory s!"cannot search {root}: it is not a directory")
    return .error (.notFound s!"cannot search {root}: it is not there")
  let (found, ending) := worked files root literal texts limits
  return .ok (deliver found ending bound)

/-- Starts the search `id`: the model with it held, or why it may not
start. -/
def start (model : GrepModel) (files : FileModel) (id : Nat) (root : System.FilePath)
    (pattern : String) (overlays : Array (System.FilePath × File.Source)) (limits : Grep.Limits)
    (bound : Nat) : Except GrepError GrepModel := do
  let deliveries ← plan files root pattern overlays limits bound
  return { model with searches := model.searches.push { id, deliveries } }

/-- The next delivery of the search `id`, and the model after it: a search
whose last delivery this is, or whose read is refused, is forgotten. -/
def read (model : GrepModel) (id : Nat) : Except GrepError Grep.Delivery × GrepModel :=
  match model.searches.find? (·.id == id) with
  | none => (.error .noSuchSearch, model)
  | some search =>
    let forget := { model with searches := model.searches.filter (·.id != id) }
    match search.deliveries with
    | .error error => (.error error, forget)
    | .ok deliveries =>
      match deliveries[0]? with
      | none => (.error .noSuchSearch, forget)
      | some delivery =>
        if delivery.ended.isSome then (.ok delivery, forget)
        else
          (.ok delivery,
            { model with
              searches :=
                model.searches.map fun held =>
                  if held.id == id then { held with deliveries := .ok (deliveries.extract 1) }
                  else held })

/-- The model's answer to each search request over `files`, and the model
after it. A start names the search with the next id. -/
def handle (files : FileModel) : (request : GrepRequest) → GrepModel → request.Reply × GrepModel
  | .start root pattern overlays limits bound, model =>
    match model.start files model.next root pattern overlays limits bound with
    | .ok started => (.ok ⟨model.next⟩, { started with next := model.next + 1 })
    | .error error => (.error error, model)
  | .next search, model => model.read search.number

/-- The model once the job has ended: every search it holds is ended and
forgotten. -/
def endAll (model : GrepModel) : GrepModel :=
  { model with
    searches := #[], ended := model.ended ++ model.searches.map (·.id) }

end GrepModel

end Editor
