import Editor.UrlOpener

/-!
# The model of the URL opener

The URL opener port (`Editor/UrlOpener.lean`) as pure data: what it was
handed, in order, and whether it refuses. A URL it takes is recorded and
answered `.ok`; while `refusal` is set, every URL is answered `.error` with
it, and nothing is recorded, as a desktop with no handler for a scheme
refuses. The job model answers the port with it (`JobModel.urlOpener`), and
`UrlOpenerModel.fake` wraps it in a reference for a job runner's tests.
-/

namespace Editor

/-- The model of the system's URL opener. -/
structure UrlOpenerModel where
  /-- The URLs it took, in the order it was handed them. -/
  opened : Array String := #[]
  /-- The reason every URL is refused with, if it refuses. -/
  refusal : Option String := none
  deriving DecidableEq, Repr

namespace UrlOpenerModel

/-- The model's answer to `request`, and the model after it. -/
def handle : (request : UrlOpenerRequest) → UrlOpenerModel → request.Reply × UrlOpenerModel
  | .openUrl url, model =>
    match model.refusal with
    | some reason => (.error reason, model)
    | none => (.ok (), { model with opened := model.opened.push url })

/-- A handler over a model of its own that refuses with `refusal`, if given,
and what the model has taken so far: the fake a job runner's tests give its
`urlOpener` service. -/
def fake (refusal : Option String := none) : BaseIO (UrlOpenerHandler × BaseIO (Array String)) := do
  let cell ← IO.mkRef ({ refusal } : UrlOpenerModel)
  return (fun request => cell.modifyGet (handle request), return (← cell.get).opened)

end UrlOpenerModel

end Editor
