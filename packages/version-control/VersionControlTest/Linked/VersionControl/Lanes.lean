import VersionControlTest.Check

/-!
# Linked tests: the lanes the version-control contract runs in

`inLanes`, which runs the version-control contract's properties a bounded
number at a time, `versionControlLanes` (`VersionControlTest/Linked/VersionControl/Git.lean`,
`versionControlContractChecks`), and its checks, `inLanesChecks`, over
plain numbers, with no git and no process. It declares no wiring set: its
checks reach no real host or service, so the linked test's check set runs
them from a plain group. It was in `Git.lean`, a `.contract` module, until
host-tests-on-fakes phase 7, where its numbers' run (`runInLanes`, an
`IO (List String)`) would be a producer of checks the wiring-set linter
refuses (`linter.wiringSet`, rule b).
-/

namespace VersionControlTest.Linked

/-- How many of the version-control contract's properties run at once. It
is bounded, not one lane per property, so that on a runner with few cores
and every core busy, every property's git at once does not crowd the
machine. A property's job is waited for on its end, and `patience` is only
a hang guard. -/
def versionControlLanes : Nat :=
  8

/-- Runs `run` on each of `items` in `width` lanes, each a dedicated task
that takes every `width`-th item in turn: one result per item, in `items`'
order. A width of 0 is taken as 1, so no item is ever left unrun. An item
whose run throws gives `failed` its error, and only that item: the lane
goes on to its next item, whose result is its own. The lanes are dedicated
threads, because each item may block on a process or on a job's end, and
Lean's task pool must stay as the job checks measure it. -/
def inLanes {α β : Type} (width : Nat) (items : List α) (run : α → IO β)
    (failed : α → IO.Error → β) : IO (List β) := do
  let width := max width 1
  let numbered := items.zipIdx
  let lanes :=
    (List.range width).map fun lane => numbered.filter fun (_, index) => index % width == lane
  let tasks ←
    lanes.mapM fun lane =>
        IO.asTask (prio := .dedicated)
          (lane.mapM fun (item, index) => do
            try
              return (index, ← run item)
            catch error =>
              return (index, failed item error))
  let results ←
    tasks.flatMapM fun task => do
        -- A lane catches each item's error, so it cannot throw.
        IO.ofExcept (← IO.wait task)
  return (results.mergeSort fun a b => a.1 ≤ b.1).map (·.2)

/-- Runs `inLanes` at `width` over the numbers below `count`, where running
`thrown` throws and running any other number gives `ran` and the number. -/
def runInLanes (width count thrown : Nat) : IO (List String) :=
  inLanes width (List.range count) (failed := fun item error => s!"failed {item}: {error}")
    fun item => if item == thrown then throw (IO.userError "thrown") else return s!"ran {item}"

/-- What `runInLanes width count thrown` must give: one result per number, in
order, only the thrown one failed. -/
def ranInLanes (count thrown : Nat) : List String :=
  (List.range count).map fun item =>
    if item == thrown then s!"failed {item}: thrown" else s!"ran {item}"

/-- The checks of `inLanes` itself, over plain numbers, with no git and no
process: that it gives one result per item, in the items' order, at any
width, at a width of 0 too, so the version-control properties can never be
run as none; and that an item that throws fails alone, its lane's other
items run and keep their own results. -/
def inLanesChecks : List Check :=
  [{  name := "inLanes gives each item's result in the items' order in one lane"
      run := return (← runInLanes 1 7 7) == ranInLanes 7 7 },
    { name := "inLanes gives each item's result in the items' order in three lanes"
      run := return (← runInLanes 3 10 10) == ranInLanes 10 10 },
    { name := "inLanes gives each item's result in order with more lanes than items"
      run := return (← runInLanes 20 5 5) == ranInLanes 5 5 },
    { name := "inLanes at a width of 0 runs every item, as in one lane"
      run := return (← runInLanes 0 5 5) == ranInLanes 5 5 },
    { name := "inLanes over no items gives no results"
      run := return (← runInLanes 3 0 0) == [] },
    { name :=
        "inLanes fails only the item that threw, and its lane's other items keep their results"
      run := return (← runInLanes 3 10 4) == ranInLanes 10 4 },
    { name := "inLanes fails only the item that threw in a single lane"
      run := return (← runInLanes 1 6 0) == ranInLanes 6 0 }]

end VersionControlTest.Linked
