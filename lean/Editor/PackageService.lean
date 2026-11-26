import Editor.Invocation

/-!
# A package's service

The port through which a running job reaches a service a package brings,
usually one of its own crate (`docs/design/packages.md`, "Behind a port, so
it stays replaceable"): the request a job makes (`PackageRequest`), the
reply it gets (`PackageReply`), the port a package implements
(`PackageService`) and its pure model (`PackageModel`).

- **A request is plain data**: the service's name, an operation and plain
  arguments, the vocabulary a command starts a job with (`Argument`). So
  the job port's requests keep their decidable equality
  (`JobRequest.package`, `Editor/Job.lean`).
- **A reply is a `Dynamic`**: the package's binding makes a value of a
  type of its own, which derives `TypeName`, and the package's typed
  wrapper reads it back (`PackageService.askAs`), as an extension point's
  values travel (`docs/design/extension-points.md`, "How the values
  travel"). Every reply type is a named type of the package's, so no two
  packages share one. The core needs no codec for it.
- **A service the runner was not given** is answered `noSuchService` at
  once, with no wait, as a process the job does not hold is answered
  `noSuchProcess`.

A package registers its services in its record (`Package.services`,
`Editor/Package.lean`), and the program's edge hands them to the job runner
(`Headless.shipped`); a check hands the runner a fake in their place
(`Job.FakePackageService`, `Editor/Job/Fake.lean`). What the runner does
with the port is `Editor/Job/Runner.lean`'s ("The ports its waits are made
of").

It imports nothing but `Editor.Invocation`, so the package record can name
the port with none of the runner.

## Where an addition goes

| Addition | Where |
|---|---|
| A new kind of refusal | A variant of `PackageError` |
| What a package's service answers | Its own binding and its own reply type |
| A capability every service needs | A field of `PackageService`, a field of the fake and a property of `JobContract.packageProperties` |
-/

namespace Editor

/-- A request a job makes of a package's service. -/
structure PackageRequest where
  /-- The service's name, as it registered it (`PackageService.name`). -/
  service : String
  /-- What the service is asked to do, in its own words. -/
  operation : String
  /-- The operation's arguments, in order. -/
  arguments : List Argument := []
  deriving DecidableEq, Repr

/-- Why a package's service did not answer a request. -/
inductive PackageError where
  /-- The runner was given no service of this name. -/
  | noSuchService (service : String)
  /-- The service refused the request, or answered it with something that
  is not the asker's. -/
  | refused (reason : String)
  deriving DecidableEq, Repr, Inhabited

/-- What a package's service answers a request: a value of a type of the
package's own, which the package's typed wrapper reads back, or why it did
not. -/
abbrev PackageReply :=
  Except PackageError Dynamic

/-- A package's service, as the job runner reaches it: the port. A request
is started as a wait of the runner's table, under the wait's id, which the
service completes once its reply can be taken. -/
structure PackageService where
  /-- The service's name: what a request names it by. -/
  name : String
  /-- Starts `request` as the wait `id`, and says whether it started: a
  service that does not take the request refuses it here. It returns at
  once and never blocks. -/
  start : (id : UInt64) → (request : PackageRequest) → BaseIO Bool
  /-- The reply to `request`, which was started as the wait `id` and has
  completed. It is asked once, on the job's thread. -/
  take : (id : UInt64) → (request : PackageRequest) → BaseIO PackageReply
  /-- Withdraws the wait `id`: the service will not complete it, and keeps
  nothing of it. Safe for any id, another service's included. -/
  cancel : (id : UInt64) → BaseIO Unit
  /-- Asks for the wait `id` to be completed once every request started
  before this call that the service finishes by itself has completed. It
  returns at once and never blocks, and keeps no reply. A field with no
  default, as on every port of the runner. -/
  flush : (id : UInt64) → BaseIO Unit

/-- The pure model of package services: each request's reply, or `none`
for a request of a service the model does not know. -/
abbrev PackageModel :=
  PackageRequest → Option PackageReply

namespace PackageModel

/-- A model that knows no service. -/
def none : PackageModel := fun _ => Option.none

/-- The reply the model answers `request`: its own, or `noSuchService` for a
service it does not know. -/
def answer (model : PackageModel) (request : PackageRequest) : PackageReply :=
  (model request).getD (.error (.noSuchService request.service))

/-- `first`, and `second` for a request `first` does not know. -/
def orElse (first second : PackageModel) : PackageModel := fun request =>
  (first request).orElse fun _ => second request

end PackageModel

end Editor
