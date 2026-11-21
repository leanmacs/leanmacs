import Editor.Headless.Queue

/-!
# The contract of the editor queue port

What every editor queue (`Headless.Queue`, `Editor/Headless/Queue.lean`)
promises its posters, as a list of properties over a `QueueRig`: the queue,
the source id the rig's posts are made under, how to take back the oldest
of them, and how many are left. The same list runs two ways:

- against the in-memory queue (`Queue.Memory`), by `model-test`
  (`ModelTest.queueContractChecks`), taken back with `take?`;
- against the library's editor queue (`Queue.library`), by `contract-test`
  (`ContractTest.queueContractChecks`), taken back with a pull of the
  editor queue.

The properties: posts from one thread are taken in order; a post's source,
code and text survive; each post is taken once; and posts from four
dedicated tasks, joined, are each taken once, each task's in its order.

This module imports only the port, so it imports nothing of the library.
The list is plain data, so it is a constant.
-/

namespace Editor.Headless.QueueContract

/-- An editor queue as the contract runs it. -/
structure QueueRig where
  /-- Which queue, as a failure names it. -/
  name : String
  /-- The queue. -/
  queue : Queue
  /-- The source id the properties post under: one no other poster uses. -/
  source : UInt64
  /-- Takes back the oldest post made under `source` that is still in the
  queue. Called only when one is. -/
  take : IO Posted
  /-- How many posts made under `source` are still in the queue. -/
  left : IO Nat

/-- One property of the queue port. -/
structure Property where
  /-- What must hold. -/
  name : String
  /-- Whether it holds of the rig. -/
  holds : QueueRig → IO Bool

/-- Posts each of `posts` in order; whether the queue took every one. -/
def postAll (rig : QueueRig) (posts : List Posted) : IO Bool :=
  posts.allM fun posted => rig.queue.post posted

/-- Takes back `count` posts, oldest first. -/
def takeAll (rig : QueueRig) (count : Nat) : IO (List Posted) := do
  let mut taken := #[]
  for _ in [0:count] do
    taken := taken.push (← rig.take)
  return taken.toList

/-- The properties. -/
def properties : List Property :=
  [{  name := "posts from one thread are taken in the order they were made"
      holds := fun rig => do
        let posts :=
          (List.range 5).map fun code => ({ source := rig.source, code := code.toUInt64 } : Posted)
        unless ← postAll rig posts do
          return false
        return (← takeAll rig 5).map (·.code) == posts.map (·.code) && (← rig.left) == 0 },
    { name := "a post's source, code and text survive the queue"
      holds := fun rig => do
        let posted : Posted := { source := rig.source, code := 4242, text := "héllo, \"queue\"" }
        unless ← rig.queue.post posted do
          return false
        return (← rig.take) == posted },
    { name := "each post is taken once: after as many takes as posts, none is left"
      holds := fun rig => do
        let posts :=
          (List.range 3).map fun code =>
            ({ source := rig.source, code := code.toUInt64, text := "once" } : Posted)
        unless ← postAll rig posts do
          return false
        let taken ← takeAll rig 3
        return taken == posts && (← rig.left) == 0 },
    { name :=
        "posts from four dedicated tasks, joined, are each taken once, each task's in its order"
      holds := fun rig => do
        let tasks ←
          (List.range 4).mapM fun poster =>
              IO.asTask (prio := .dedicated) do
                (List.range 25).allM fun index =>
                    rig.queue.post { source := rig.source, code := (poster * 100 + index).toUInt64 }
        let mut all := true
        for task in tasks do
          all := all && (← IO.ofExcept (← IO.wait task))
        unless all do
          return false
        let codes := (← takeAll rig 100).map (·.code.toNat)
        let ordered :=
          (List.range 4).all fun poster =>
            codes.filter (· / 100 == poster) == (List.range 25).map (poster * 100 + ·)
        return ordered && codes.length == 100 && (← rig.left) == 0 }]

/-- The names of the properties that do not hold of `rig`, each after the
rig's name, with what was thrown when one threw. -/
def failures (rig : QueueRig) : IO (List String) := do
  let mut failed := []
  for property in properties do
    let name := s!"{rig.name}: {property.name}"
    try
      unless ← property.holds rig do
        failed := failed ++ [name]
    catch error =>
      failed := failed ++ [s!"{name} ({error})"]
  return failed

end Editor.Headless.QueueContract
