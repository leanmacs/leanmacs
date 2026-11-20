import Editor.Restore.Indexed
import Editor.Restore.Journal

/-!
# The frame as the session index records it

The tabs and windows of the frame (`Frame.Record`, `Editor/Restore/Records.lean`)
as the session index writes them (`Editor/Restore/Document.lean`): their
JSON, the record of a state (`Frame.Record.of`), the record with its views
given this run's ids (`Frame.Record.renumber`) and what a restore refuses
of a record on its own (`Frame.Record.check`). The restore's command puts a
record back (`Editor/Restore/Run.lean`).

## The record

- **Every tab, in order**, and the index of the one in view; each tab's
  name when it was given one, its tiled windows, its docked windows with
  their sides, its floats in stacking order, its layout, the one a zoom
  returns to, its focused window and the one focused before it, when that
  is still one of its own. The tab in view's focused window is the
  selected one (`EditorState.selectedView`): a prompt's asker while a
  prompt is open, so opening one changes nothing of the record.
- **A float's anchor**: the frame, a window, or a position of a window's
  buffer as a spot (`spotOf`), a row and a byte column.
- **The layout config had chosen** (`Frame.chosen`), which a restore puts
  back so that config's first publish keeps the restored layout
  (`Editor/Loop.lean`, the held layout).
- **The windows elsewhere**: those whose buffer the index does not keep
  (`indexed`), each with its buffer's name. A restore shows `scratch` in
  each, and says so.

A window's place in its buffer and its jump list are not here: they are the
buffer's `views` (`Restore.Place`), as phase 1 wrote them.

## The JSON

```
{"selected":0,"chosen":<layout>,"tabs":[{"name":"logs","windows":[3,5],
 "docked":[[7,"left"]],"floats":[{"view":9,"anchor":<anchor>,"share":[60,50],
 "pinned":true}],"layout":<layout>,"zoomedFrom":<layout>,"focused":5,
 "lastFocused":3}],"elsewhere":[[11,"*vc-status*"]]}
<anchor> = "frame" | {"window":3} | {"position":[3,[row,column]]}
<layout> = {"masterStack":{"share":s,"side":"left","count":c}} | "monocle"
         | {"splits":<tree>} | {"edge":{"side":"left","size":25,"inner":<layout>}}
<tree>   = "tile" | {"axis":"rows","first":a,"second":b,"before":<tree>,"after":<tree>}
```

`chosen`, `name`, `zoomedFrom` and `lastFocused` are absent when there is
none. A reader reads the keys it knows and passes over the rest, so a newer
format's keys inside the frame are no error.

## Renumbering

A record's views are the ids of the run that wrote it. `renumber` gives the
tab in view's focused view the start window's id, and every other view the
next free id in the record's order (tab by tab, each tab's tiled, docked
and floating windows), so ids are never used again.

## What `check` refuses

What `EditorState.wellFormed` would refuse, on the record alone: no tab, a
selected index past the tabs, a tab with no tiled window, a layout that
does not fit its tiled windows, a docked side that is no edge of the layout,
a float anchored outside its tab, a focused window that is not the tab's,
and a view in two places.

Pinned by `ModelTest.restoreFrameChecks`.
-/

namespace Editor.Restore

open Journal (natJson natField? stringField?)

/-! ## The JSON -/

/-- A spot as JSON: `[row, column]`. -/
def Spot.toJson (spot : Spot) : Json.Value :=
  .array #[natJson spot.row, natJson spot.column]

/-- A spot from JSON, or none. -/
def Spot.ofJson? (value : Json.Value) : Option Spot := do
  let .array #[.number row, .number column] := value | none
  return { row := ← row.toNat?, column := ← column.toNat? }

/-- A side from its name, or none. -/
def sideOf? : String → Option Side
  | "left" => some .left
  | "right" => some .right
  | "top" => some .top
  | "bottom" => some .bottom
  | _ => none

/-- An axis's name. -/
def axisName : Axis → String
  | .rows => "rows"
  | .columns => "columns"

/-- An axis from its name, or none. -/
def axisOf? : String → Option Axis
  | "rows" => some .rows
  | "columns" => some .columns
  | _ => none

/-- A tree of manual splits as JSON. -/
def splitsJson : Splits → Json.Value
  | .tile => .string "tile"
  | .split axis first second before after =>
    .object
      #[("axis", .string (axisName axis)), ("first", natJson first), ("second", natJson second),
        ("before", splitsJson before), ("after", splitsJson after)]

/-- A tree of manual splits from JSON, or none. -/
partial def splitsOf? (value : Json.Value) : Option Splits :=
  match value with
  | .string "tile" => some .tile
  | _ => do
    return .split (← axisOf? (← stringField? value "axis")) (← natField? value "first")
        (← natField? value "second") (← splitsOf? (← value.field? "before"))
        (← splitsOf? (← value.field? "after"))

/-- A layout as JSON. -/
def layoutJson : Layout → Json.Value
  | .masterStack parameters =>
    .object
      #[("masterStack",
          .object
            #[("share", natJson parameters.share), ("side", .string parameters.side.name),
              ("count", natJson parameters.count)])]
  | .monocle => .string "monocle"
  | .splits tree => .object #[("splits", splitsJson tree)]
  | .edge side size inner =>
    .object
      #[("edge",
          .object
            #[("side", .string side.name), ("size", natJson size), ("inner", layoutJson inner)])]

/-- A layout from JSON, or none. -/
partial def layoutOf? (value : Json.Value) : Option Layout :=
  match value with
  | .string "monocle" => some .monocle
  | _ =>
    if let some parameters := value.field? "masterStack" then do
      return .masterStack
          { share := ← natField? parameters "share"
            side := ← sideOf? (← stringField? parameters "side")
            count := ← natField? parameters "count" }
    else
      if let some tree := value.field? "splits" then (splitsOf? tree).map .splits
      else
        if let some edge := value.field? "edge" then do
          return .edge (← sideOf? (← stringField? edge "side")) (← natField? edge "size")
              (← layoutOf? (← edge.field? "inner"))
        else none

/-- A recorded jump as JSON: `{"key":k,"row":r,"column":c}` or
`{"path":p,"row":r,"column":c}`, the column in characters. -/
def Jump.toJson : Jump → Json.Value
  | .kept key row column =>
    .object #[("key", natJson key), ("row", natJson row), ("column", natJson column)]
  | .file path row column =>
    .object #[("path", .string path), ("row", natJson row), ("column", natJson column)]

/-- A recorded jump from JSON, or none. -/
def Jump.ofJson? (value : Json.Value) : Option Jump := do
  let row ← natField? value "row"
  let column ← natField? value "column"
  match natField? value "key", stringField? value "path" with
  | some key, _ =>
    some (.kept key row column)
  | none, some path =>
    some (.file path row column)
  | none, none =>
    none

/-- A window's recorded jumps as JSON: `{"entries":[…],"index":i,"previous":<jump>}`,
`previous` absent when there is none. -/
def Jumps.Record.toJson (jumps : Jumps.Record) : Json.Value :=
  .object <|
    #[("entries", .array (jumps.entries.map (·.toJson))), ("index", natJson jumps.index)] ++
      (jumps.previous.map fun jump => #[("previous", jump.toJson)]).getD #[]

/-- A window's recorded jumps from JSON, or none. -/
def Jumps.Record.ofJson? (value : Json.Value) : Option Jumps.Record := do
  let .array entries ← value.field? "entries" | none
  let previous ←
    match value.field? "previous" with
    | none =>
      some none
    | some jump =>
      (Jump.ofJson? jump).map some
  return { entries := ← entries.mapM Jump.ofJson?, index := ← natField? value "index", previous }

/-- A float's anchor as JSON. -/
def Float.Anchor.toJson : Float.Anchor → Json.Value
  | .frame => .string "frame"
  | .window view => .object #[("window", natJson view)]
  | .position view spot => .object #[("position", .array #[natJson view, spot.toJson])]

/-- A float's anchor from JSON, or none. -/
def Float.Anchor.ofJson? (value : Json.Value) : Option Float.Anchor :=
  match value with
  | .string "frame" => some .frame
  | _ =>
    match natField? value "window", value.field? "position" with
    | some view, _ => some (.window view)
    | none, some (.array #[.number view, spot]) => do
      return .position (← view.toNat?) (← Spot.ofJson? spot)
    | _, _ => none

/-- A float as JSON. -/
def Float.Record.toJson (float : Float.Record) : Json.Value :=
  .object
    #[("view", natJson float.view), ("anchor", float.anchor.toJson),
      ("share", .array #[natJson float.share.width, natJson float.share.height]),
      ("pinned", .bool float.pinned)]

/-- A float from JSON, or none. -/
def Float.Record.ofJson? (value : Json.Value) : Option Float.Record := do
  let .array #[.number width, .number height] ← value.field? "share" | none
  let .bool pinned ← value.field? "pinned" | none
  return {
      view := ← natField? value "view", anchor := ← Float.Anchor.ofJson? (← value.field? "anchor")
      share := { width := ← width.toNat?, height := ← height.toNat? }, pinned }

/-- The members `name` holds when `value` is some, none otherwise. -/
def optionalMember (name : String) (value : Option Json.Value) : Array (String × Json.Value) :=
  (value.map fun value => #[(name, value)]).getD #[]

/-- A tab as JSON. -/
def Tab.Record.toJson (tab : Tab.Record) : Json.Value :=
  .object <|
    optionalMember "name" (tab.name.map .string) ++
      #[("windows", .array (tab.windows.map natJson)),
        ("docked",
          .array (tab.docked.map fun (view, side) => .array #[natJson view, .string side.name])),
        ("floats", .array (tab.floats.map (·.toJson))), ("layout", layoutJson tab.layout)] ++
      optionalMember "zoomedFrom" (tab.zoomedFrom.map layoutJson) ++
      #[("focused", natJson tab.focused)] ++
      optionalMember "lastFocused" (tab.lastFocused.map natJson)

/-- The numbers of an array member of `value`, or none. -/
def natsField? (value : Json.Value) (name : String) : Option (Array Nat) := do
  let .array items ← value.field? name | none
  items.mapM fun
      | .number text => text.toNat?
      | _ => none

/-- An optional member read by `read`: `some none` when absent, `none` when
it is there and `read` refuses it. -/
def optionalField? {α : Type} (value : Json.Value) (name : String) (read : Json.Value → Option α) :
    Option (Option α) :=
  match value.field? name with
  | none => some none
  | some member => (read member).map some

/-- A tab from JSON, or none. -/
def Tab.Record.ofJson? (value : Json.Value) : Option Tab.Record := do
  let .array docked ← value.field? "docked" | none
  let docked ←
    docked.mapM fun
        | .array #[.number view, .string side] => do
          some (← view.toNat?, ← sideOf? side)
        | _ => none
  let .array floats ← value.field? "floats" | none
  let name ←
    optionalField? value "name" fun
        | .string name => some name
        | _ => none
  return {
      name, windows := ← natsField? value "windows", docked
      floats := ← floats.mapM Float.Record.ofJson?, layout := ← layoutOf? (← value.field? "layout")
      zoomedFrom := ← optionalField? value "zoomedFrom" layoutOf?
      focused := ← natField? value "focused"
      lastFocused :=
        ←
          optionalField? value "lastFocused" fun
              | .number text => text.toNat?
              | _ => none }

/-- The frame's record as JSON ("The JSON", in the module docs). -/
def Frame.Record.toJson (record : Frame.Record) : Json.Value :=
  .object <|
    #[("selected", natJson record.selected)] ++
      optionalMember "chosen" (record.chosen.map layoutJson) ++
      #[("tabs", .array (record.tabs.map (·.toJson))),
        ("elsewhere",
          .array (record.elsewhere.map fun (view, name) => .array #[natJson view, .string name]))]

/-- The frame's record from JSON, or none: the keys it knows, and the rest
passed over. -/
def Frame.Record.ofJson? (value : Json.Value) : Option Frame.Record := do
  let .array tabs ← value.field? "tabs" | none
  let elsewhere ←
    match value.field? "elsewhere" with
    | none =>
      some #[]
    | some (.array items) =>
      items.mapM fun
          | .array #[.number view, .string name] => do
            some (← view.toNat?, name)
          | _ => none
    | some _ =>
      none
  return {
      selected := ← natField? value "selected", chosen := ← optionalField? value "chosen" layoutOf?
      tabs := ← tabs.mapM Tab.Record.ofJson?, elsewhere }

/-! ## The record of a state -/

/-- The record of `float`, a float of `state` ("The record", in the module
docs): a position anchor as a spot of its window's buffer, or the window
itself when its marker cannot be read. -/
def Float.Record.of (state : EditorState) (float : Floating) : TextM Float.Record := do
  let anchor ←
    match float.anchor with
    | .frame =>
      pure Float.Anchor.frame
    | .window view =>
      pure (.window view.index)
    | .position view marker =>
      match state.target? view with
      | none =>
        pure .frame
      | some target =>
        match ← observing (Marks.offsetOf marker) with
        | .ok offset =>
          pure (.position view.index (← spotOf target.buffer.text offset))
        | .error _ =>
          pure (.window view.index)
  return { view := float.view.index, anchor, share := float.share, pinned := float.pinned }

/-- The record of `tab`, a tab of `state`, whose focused window is
`focused`. -/
def Tab.Record.of (state : EditorState) (tab : Tab) (focused : ViewId) : TextM Tab.Record := do
  return {
      name := tab.name, windows := tab.windows.map (·.index)
      docked := tab.docked.map fun (view, side) => (view.index, side)
      floats := ← tab.floats.mapM (Float.Record.of state), layout := tab.layout
      zoomedFrom := tab.zoomedFrom, focused := focused.index
      lastFocused :=
        (tab.lastFocused.filter fun last => tab.contains last && last != focused).map (·.index) }

/-- The record of the frame of `state` ("The record", in the module docs). -/
def Frame.Record.of (state : EditorState) : TextM Frame.Record := do
  let frame := state.frame
  let mut tabs := #[]
  let all := frame.tabs
  for index in [0:all.size] do
    let some tab := all[index]? | continue
    let focused := if index == frame.tabIndex then state.selectedView else tab.focused
    tabs := tabs.push (← Tab.Record.of state tab focused)
  let elsewhere :=
    frame.everyWindow.filterMap fun view => do
      let window ← state.window? view
      let buffer ← state.buffer? window.buffer
      if indexed state window.buffer buffer then
        none
      else
        some (view.index, buffer.name)
  return { selected := frame.tabIndex, chosen := frame.chosen, tabs, elsewhere }

/-! ## Renumbering and checking -/

/-- Every view of a tab's record: its tiled windows, its docked windows and
its floats, in that order. -/
def Tab.Record.views (tab : Tab.Record) : Array Nat :=
  tab.windows ++ tab.docked.map (·.1) ++ tab.floats.map (·.view)

/-- Every view of the record, tab by tab. -/
def Frame.Record.views (record : Frame.Record) : Array Nat :=
  record.tabs.flatMap Tab.Record.views

/-- The focused view of the tab in view, if there is one. -/
def Frame.Record.focused? (record : Frame.Record) : Option Nat :=
  record.tabs[record.selected]?.map (·.focused)

/-- The record with each view `map` maps given its new id, and an unmapped
one left. -/
def Frame.Record.mapViews (record : Frame.Record) (map : Nat → Nat) : Frame.Record :=
  let anchor : Float.Anchor → Float.Anchor
    | .frame => .frame
    | .window view => .window (map view)
    | .position view spot => .position (map view) spot
  { record with
    tabs :=
      record.tabs.map fun tab =>
        { tab with
          windows := tab.windows.map map,
          docked := tab.docked.map fun (view, side) => (map view, side)
          floats :=
            tab.floats.map fun float =>
              { float with
                view := map float.view, anchor := anchor float.anchor }
          focused := map tab.focused, lastFocused := tab.lastFocused.map map }
    elsewhere := record.elsewhere.map fun (view, name) => (map view, name) }

/-- The record renumbered ("Renumbering", in the module docs): the tab in
view's focused view as `start`, and every other view the next id from
`next` in the record's order. With it, the map from each old id to its new
one, and the next id free after them. -/
def Frame.Record.renumber (record : Frame.Record) (start next : Nat) :
    Frame.Record × Array (Nat × Nat) × Nat :=
  let focused := record.focused?
  let (pairs, free) :=
    record.views.foldl
      (fun (pairs, free) view =>
        if pairs.any (·.1 == view) then (pairs, free)
        else
          if some view == focused then (pairs.push (view, start), free)
          else (pairs.push (view, free), free + 1))
      ((#[] : Array (Nat × Nat)), next)
  let map (view : Nat) : Nat := ((pairs.find? (·.1 == view)).map (·.2)).getD view
  (record.mapViews map, pairs, free)

/-- Why a restore refuses `record` on its own ("What `check` refuses", in
the module docs); none when it does not. -/
def Frame.Record.check (record : Frame.Record) : Option String := do
  if record.tabs.isEmpty then
    return "the frame has no tab"
  if record.selected ≥ record.tabs.size then
    return s!"the tab in view, {record.selected + 1}, is past the {record.tabs.size} tabs"
  let views := record.views
  if views.toList.eraseDups.length != views.size then
    return "a window is in two places"
  for index in [0:record.tabs.size] do
    let some tab := record.tabs[index]? | none
    let named := s!"tab {index + 1}"
    let count := tab.windows.size
    if count == 0 then
      return s!"{named} has no tiled window"
    if !tab.layout.fitted count || !tab.zoomedFrom.all (·.fitted count) then
      return s!"{named}'s layout does not fit its {count} tiled windows"
    let underlying := tab.zoomedFrom.getD tab.layout
    if tab.docked.any fun (_, side) => !underlying.edgeSides.contains side then
      return s!"{named} docks a window at a side its layout has no edge at"
    let anchors (view : Nat) : Bool := tab.windows.contains view || tab.docked.any (·.1 == view)
    for float in tab.floats do
      let anchored :=
        match float.anchor with
        | .frame => true
        | .window view | .position view _ => anchors view
      if !anchored then
        return s!"{named}'s float {float.view} is anchored outside it"
    if !tab.views.contains tab.focused then
      return s!"{named}'s focused window is not one of its own"
  none

end Editor.Restore
