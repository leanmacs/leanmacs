import Editor.Completion.Candidate
import Editor.Completion.Display
import Editor.Display
import Editor.DisplayRules
import Editor.Face
import Editor.File
import Editor.Floating
import Editor.GeneratedView
import Editor.Invocation
import Editor.JumpList
import Editor.Layout
import Editor.Marks
import Editor.Scene
import Editor.State.Outbox
import Editor.TabBar
import Editor.UndoTree
import Editor.Workspace

/-!
# The editor state

What the editor is showing and editing, as one immutable value the editor
thread holds (`EditorState`): the buffers, the windows, the one frame they
are arranged in, the echo area, the input method's preedit and the prompt
that is open, if one is. The command
loop (`Editor/Loop.lean`) takes it from one event to the next and publishes
a scene of it after each.

- **A buffer** (`Buffer`) is a text of the text store, a name, the text's
  undo tree, the buffer's local values (`Value` trees, as a store's cell
  holds, `Editor/Value.lean`), and the names of its modes: one major mode
  or none, and its minor modes, the one added last first. A name here is
  only a name: what a mode is, and what its keys and its `onEnter` are, is
  the registry's (`Editor/Mode.lean`, `Editor/Config/Registry.lean`), and a
  name no registered mode has contributes nothing. It also keeps the file
  it shows, if it shows one, and its line ending ("A buffer's file",
  below).
- **Buffers are kept in slots** (`EditorState.buffers`). A `BufferId` is an
  index there, and a buffer that is removed leaves its slot empty, as the
  text store keeps the place of a released text. So an id is never used
  again, and no window's `buffer` is renumbered when another buffer goes.
- **A window** (`Window`) is a view of a buffer: its `ViewId`, which names it
  in every scene, the buffer it shows, its scroll position as an anchor
  marker of the buffer's text, and its selections as one selection marker
  of that text, whose ranges are its cursors.
- **The frame** (`Frame`) is the one window of the platform: its size,
  whether it has the keyboard focus, and its tabs (`Tab`, "Tabs", below),
  each a whole arrangement of windows. The tab in view is the frame's own
  fields: the editor's windows as an ordered list (`Frame.windows`), the
  windows docked at an edge (`Frame.docked`) and the floating windows
  (`Frame.floats`), the layout that arranges the first two
  (`Frame.layout`, `Editor/Layout.lean`), and the window that is
  focused.

## The window list, the layout and their invariants

The frame's windows are an ordered list of `ViewId`s, the first being main,
and the focus is held by `ViewId` (`Frame.focused`). A layout value turns
the list into one rectangle per window shown (`Layout.place`):
master-and-stack by default, monocle, which shows only the selected
window, and manual splits, a tree of anonymous tiles the windows take in
list order, each of which an edge may wrap. The
list says which windows exist and in what order; the layout says only
where each goes.

**The windows docked at an edge are kept apart from the list**
(`Frame.docked`, each with its side), which stays the tiled list the
layout's operations index, so an edge layout leaves every rule of the list
as it was; the layout gives the windows docked at each of its edges that
edge's strip (`Layout.place`, `Layout.edge`). Which windows the frame has
is read in one place, `Frame.all`, the tiled list then the docked windows
then the floats, and `Frame.contains` asks whether a window is one of
them.

**The floating windows are kept apart from both** (`Frame.floats`, each a
`Floating` with its anchor, its share, whether it is pinned and the spot
its position anchor was last drawn at; `Editor/Floating.lean`), in
stacking order, the last on top, for the same reason: every layout
operation indexes the tiled list. They are placed in the tiled area
against their anchors, not by the layout ("A floating window", below).

**The frame keeps three more things about its windows**, each changed only
by the operations below:

| Field | What it holds |
|---|---|
| `Frame.zoomedFrom` | The layout a zoom left, to go back to: `some` while zoomed, when the layout is monocle |
| `Frame.lastFocused` | Vim's `prevwin`: the window of the frame focused before the current one. Set when the focus moves from one window of the frame to another, tiled, docked or floating (`Frame.focusedOn`), by `focusWindow` and by an exchange; focusing the minibuffer's view or leaving it does not set it. It is never cleared, and ids are never used again, so a reader checks that it is still in the frame |
| `Frame.chosen` | The layout config chose that the last publish applied. A publish handed the same layout again leaves the frame's (`Loop.publish`), so a zoom, a resized share, a main count or a split tree a command made lasts until config chooses another layout; `Frame.choose` then moves the windows docked at an edge the new layout lacks to the end of the list, sets the layout, fitted to the windows, and clears the zoom, so the same windows are rearranged and none is lost |

Every change of the list is applied to the layout and to the one zoom
returns to (`Frame.inserted`, `Frame.removed`), so a window split or closed
while zoomed is in the tree zoom returns to.

**The minibuffer's place always takes the frame's bottom strip**, outside
the area a layout tiles (`EditorState.tiled`). With no prompt open the
strip is the frame's bottom row, `heights.message` tall
(`EditorState.minibufferPlace`), where the display draws the echo, and
holds no view. With a prompt open it is the candidate list's rows, a text
row and that bottom row, `listRows * heights.text + heights.text +
heights.message`: the list, then the input, then the prompt.
`EditorState.cutStrip` cuts it in two: the minibuffer's view is the lower
part, `heights.text + heights.message` tall, and the candidate list's view
(`candidateListRect?`) the upper part, directly above it. A frame shorter
than the strip is all strip, and the tiled area has no height; a strip
shorter than the input and the bottom row is all the minibuffer's view, so
the list is cut before the input. The list's part is the prompt's, a
session at point's, or the key hints' shown ("Key hints"), whichever the
candidate list draws (`candidateSheet?`); a session and the hints have no
input row, so the strip is their list's rows and the bottom row.

**The list's part grows and never shrinks while the prompt is open**, as
vertico's default `vertico-resize` (grow-only) does: `listRows` is the
prompt's high-water mark (`Prompt.tallest`), the most rows any sheet the
display answered has shown since the prompt opened, not the current
sheet's. So typing that cuts the matches leaves the strip as tall as it
has been, with blank rows under the list. Each sheet holds at most its
display's rows, so the mark is capped there; a reload that installs a
display with fewer rows does not lower it. The mark goes with the prompt,
so closing the prompt gives the windows the height back with no rule of
its own: `minibufferPlace` is the bottom row again at the closing step's
publish.

**The candidate list's view** (`EditorState.candidateList`,
`GeneratedView`) is a text view over generated text, as the tab bar's
is: its text, anchor and view id are made the first time a publish draws
it and kept for the editor's life. It is no window: it has no target, no
key reaches it, it is never focused or followed; its rectangle and padding
are read through `rect?` and `paddingOf` as a window's are. Its rows are
not written into the minibuffer's buffer, because the whole text of that
buffer is the input. A command that asks `rect?` while a prompt is open is
answered with the rows the last publish displayed.

**The tab bar's strip** (`EditorState.tabBarRect?`, `Editor/TabBar.lean`)
is cut off the bottom of the tiled area, directly above the minibuffer's,
while the bar is shown (`EditorState.tabBarShown`: by default while there
are two tabs or more): one text row, or what the minibuffer's strip leaves
of the frame. Floats stay out of it, since they are placed in the tiled
area. The bar's view (`EditorState.tabBar`) is no window: it has no
target, no key reaches it and it is never focused; its rectangle and
padding are read through `rect?` and `paddingOf` as a window's are.

**The heights of the rows** are the display's (`Display.heights`):
`EditorState.heights` holds what it last answered, which `Loop.publish`
asks before it lays out the views, and a 16-pixel cell's before the first.
A view's rows are asked with its height less its bottom row
(`EditorState.bottomRow`): the status row for a window, and the bottom row
for the minibuffer's view. That is the height the display's frame gives
its text, so a command's questions of layout are answered with the rows
the frame shows.

**The rectangles of a state's views** are `EditorState.rects`: the frame's
tiled and docked windows laid out by its layout in the tiled area, then
each float in stacking order, placed in the tiled area against its anchor
(`Floating.placed`), then the minibuffer's view in the bottom strip while a
prompt is open. So the scene lists the floats after every tile and docked
window, and the display, which draws views in scene order each over its
own background, draws them above. Monocle is handed the selected
view (`EditorState.selectedView`), so while a prompt is open it shows the
asker, not the minibuffer; when that is a float, it is handed the float's
anchor window, or for a float anchored to the frame the window focused
before it (`EditorState.monocleView`). A window monocle hides has no rectangle, and so
is not in the scene, but it is still one of the views and can be focused,
which shows it. It is the one definition the scene's views and a command's
question about its view (`EditorState.rect?`) are both read from, so a
command is answered with the rectangle the next scene gives its view. The
tiles' and the strips' rectangles tile the area, and a float's lies inside
it: a view's padding is inside its rectangle, not between rectangles.

**The padding of the views** is in whole points, which the display
multiplies by its scale (Lean handles no scale). `EditorState.padding` is
the frame padding the last publish laid out with, set from config
(`framePadding`, `Editor/Setup.lean`) through the loop's keys. Each view's
is `EditorState.paddingOf`: a window is padded across and down by it, each
window its own; the minibuffer's view is padded across by the
bottom row's inset (`EditorState.bottomInset`: the padding, and at least
the window's corner clearance, `Frame.corner`, outside fullscreen) and not
down, since its place must stay exactly a text row and the bottom row
tall. A window along the frame's top edge (its rectangle at `y` 0) is
padded further at the top by the top inset (`EditorState.topInset`: what
the window's title bar covers of the frame, `Frame.top`, and none in
fullscreen), so its text starts below the title bar; any other is not. The echo is inset by the same bottom inset (`Scene.echoPadding`). A
command's question about its view carries the view's padding
(`Scroll.Area.ofRect`), so it is answered with the rows the frame shows.

The invariants are part of the model (`EditorState.wellFormed`). They are
stated over the state's views (`EditorState.views`): the frame's windows,
the tiled list in order, then the docked windows, then the floats
(`Frame.all`), then the minibuffer's view while a prompt is open
("Prompts", below).

- the frame's layout, and the one zoom returns to, fit the list: a manual
  split tree has as many tiles as the list has windows (`Layout.fitted`);
- every docked window's side is an edge of the layout out of a zoom
  (`Frame.underlying`, `Layout.edgeSides`), so no docked window is left
  without a strip;
- every float's anchor window, for a `window` or a `position` anchor, is a
  tiled or docked window of the frame (`Frame.anchors`): not a float, so
  placement never recurses, and not the minibuffer's view;
- a `position` anchor's marker is of the text of its window's buffer;
- the focused window is one of the views;
- the views' ids are distinct, and they are exactly the windows' ids;
- each window's buffer exists.

Each clause is seen to refuse: `ModelTest.spoilings` builds, for every
clause, a state that breaks it and keeps the others, and none is well
formed. A clause added here gets a state there.

An operation that would break one is refused with a `LayoutRefusal` and
changes nothing: it returns the state it was given. A command reaches each
as a request of the editor's port (`Editor/State/Request.lean`), whose
handler is these operations:

- `removeWindow` refuses `noSuchWindow` for a window not in the list, and
  `onlyWindow` for the last window, which would leave nothing to focus. The
  window leaves the list, the layout gives its space to the rest, and the
  window is handed back: its markers are the caller's to give up. When the
  window was focused, the focus moves to the window that inherits its
  place when the layout says one: under manual splits the first window of
  the next part of its group, or the last of the previous part
  (`Splits.remove`, Vim's `win_altframe`), and the tree is balanced along
  the group's axis. Otherwise it moves to the window that took its index,
  or, when it was last, to the new last window, as xmonad's delete does.
  While zoomed, the inheritor is the one of the layout to return to.
- `focusWindow` takes a window of the frame, and the minibuffer's window
  while a prompt is open, so the focus can leave the minibuffer and come
  back. It refuses `noSuchWindow` for any other. Moving the focus from one
  window of the frame to another sets `lastFocused`, and closes the
  transient floats the focus leaves (`EditorState.focusedOn`, "A floating
  window", below).
- `splitWindow` takes a placement (`Placement`: an axis, and whether the
  new window goes before its source), which only manual splits read.
  Under them the new window takes the source's index when the placement
  says before and the index after it otherwise, the source's tile is split
  along the axis, and the tree is balanced along it (Vim's `equalalways`).
  Under master-and-stack and monocle it goes right after the source in the
  list: splitting main makes the new window the first of the stack, and
  splitting a stack window puts the new one below it. While zoomed, the
  layout zoom returns to says which. The new window shows the source window's buffer,
  with the two markers the caller made for it, and the focus stays where
  it was. It refuses `noSuchWindow` for a source not in the list, and
  `markersOfAnotherText` for a marker that is not of that buffer's text.
  Splitting a window and removing the new one gives back the frame from
  before the split, under every layout.
- `arrange` makes a change (`Arrange`) on a window of the list:
  - `promote` moves it to main, index 0, and main itself swaps with the
    next (dwm's zoom); `demote` swaps it with the next, and the last stays;
    `rotate` rotates the stack under master-and-stack, main staying, and
    the whole list under the other layouts, forward as Vim's `C-w r` (the
    last becomes the first) and back as `C-w R`. Each keeps the focus on
    its view, so the focus follows its window. Under manual splits they
    move windows between tiles, and the shape stays.
  - `exchange` swaps it with the `nth` of the list, or with the next, or
    the previous when it is last, and focuses the other view, which now
    stands where it was: Vim's `C-w x`.
  - `zoom` keeps the layout in `zoomedFrom` and makes it monocle, or goes
    back to it while zoomed. Under monocle with no zoom it is refused with
    `monocleChosen`. While zoomed, `rotate`, `balance`, `resize` and
    `mainCount` act on the layout zoom returns to, and monocle stays
    shown.
  - `balance` makes the windows equal: master-and-stack's share back to
    50, every split of a manual tree balanced along both axes, and nothing
    under monocle.
  - `resize` grows or shrinks the window by steps of 5 percent: main's
    share under master-and-stack, along its side's axis only and with a
    stack to share with, and the deepest split on the axis that holds the
    window's tile under manual splits. Anything else is refused with
    `notResizable` and the axis.
  - `mainCount` moves master-and-stack's count of main's windows, not
    below 0, and is refused with `noMain` under the other layouts.
  Each refuses `noSuchWindow` for a window not in the list and
  `ofMinibuffer` for the minibuffer's.
- Two readers serve the window commands: `toward?`, the window that lies
  in a direction, worked out from the rectangles the layout gave (so a
  window monocle hides has nothing in any direction, and the minibuffer's
  view is never one), and `cycled`, the next or previous window of the
  frame with wrap, or the Nth.
- `openWindow` opens a new window on a buffer at a spot (`WindowSpot`):
  after the last of the tiled list (`stack`), as a split of that window
  with the default placement would, docked at an edge, after that side's
  windows, or a float on top of the others (`float`). The focus stays. It refuses `noSuchEdge` for an edge the
  layout has none at, and the minibuffer's buffer, a buffer there is none
  of and markers of another text as `showBuffer` does.
- `displaying` says where a buffer is to be shown, under display rules
  (`Editor/DisplayRules.lean`): a window that shows it already, else the
  target of the first rule that matches it, else the stack. It decides and
  changes nothing; `BufferId.display` (`Editor/Api.lean`) carries it out.

`LayoutRefusal.describe` says each refusal in a sentence, which a window
command gives up with, so the echo area says, for the last window,
`window-close: the last window cannot be closed` (Vim's E444).
- `showBuffer` has a window show another buffer, with the two markers the
  caller made on that buffer's text. It refuses `noSuchWindow`,
  `noSuchBuffer` for a buffer there is none of (a window over no buffer
  would break the last invariant), and `markersOfAnotherText`.
- `setWanted` has a window keep a wanted column, or none ("The wanted
  column", below). It refuses `noSuchWindow` for a view with no window.

**A window at an edge is not special.** Every operation above takes a
docked window as it takes a tile, with these rules of its own:

- `removeWindow` takes it out of `docked`, and the edge's strip goes when
  no window is docked there; the layout is unchanged. The focus goes to the
  window of its side that took its index, else that side's new last
  window, else `lastFocused` while it is in the frame, else main.
  `onlyWindow` counts the tiles alone, so the last tile cannot be closed
  while windows are docked, as Emacs refuses to make a side window the
  only window.
- `splitWindow` docks the new window at the same side, right after it.
- `arrange`'s `promote` moves it into the tiles as main; `demote`,
  `rotate` and `exchange` act on the windows docked at its side, as a
  list; `resize` moves its edge's strip, refused with `notResizable`
  across the side's axis. `balance` and `mainCount` act on the layout as
  from any window, `mainCount` on the one inside the edges
  (`Layout.tiling`).
- `arrange`'s `edge side`, on any window: a tile is docked at `side`
  (refused with `lastTile` for the last one), a window docked at another
  side moves there, and one docked at `side` goes back to the end of the
  list. A side the layout has no edge at is refused with `noSuchEdge`.
- The window a prompt was asked from (`askedFrom`), and so where the focus
  goes when it closes and where `shownIn` shows a buffer, may be a docked
  window.

**A floating window** (`Frame.floats`, `Editor/Floating.lean`) is a window
of the frame like any other to every operation above, which reach it
through `Frame.all` and `Frame.contains`: `focusWindow`, `showBuffer`,
`cycled` (`C-w C-w` reaches a float), `askedFrom` and `shownIn` (a prompt
asked from a float returns there) and the reuse step of `displaying`. A
float is placed in the tiled area against its anchor (`rects`): centred
in the area for the frame, centred in its window's rectangle for a
window, or in the area when monocle hides that window, and beside the
spot of its position, flipped and clamped to stay inside the area, or as
for its window before the first publish has drawn the position. The area
is the tiled one, so a float never covers the echo row, the minibuffer's
view or a tab bar cut off the frame. These rules are its own:

- **The focus rule.** When the focus moves from one window of the frame to
  another, every transient float that is not the window now focused closes
  (`EditorState.focusedOn`, which `focusWindow` and an exchange use, and
  which `removeWindow` applies when it moves the focus). So a focused
  transient float closes when the focus goes anywhere else, one opened
  without the focus closes when the focus leaves the window it was opened
  from, and focusing it keeps it. Opening and closing a prompt is no move,
  so a prompt asked from a float keeps it, and the focus comes back to it.
  A pinned float stays until it is closed.
- **Closing a float** removes its window from `floats` and from `windows`
  (`closeFloats`); its markers and its anchor marker are the loop's to give
  up once the command ends (`Editor/Loop.lean`, "What a finished command
  gave up"). A focused float's focus goes to `lastFocused` while that is
  still in the frame, else to main.
- **When an anchor goes.** When a window that floats are anchored to (by
  `window` or `position`) leaves the tiles and the edges, because
  `removeWindow` closed it or `arrange`'s `float` floated it, the transient
  floats anchored to it close and the pinned ones are anchored to the
  frame (`anchorGone`). `showBuffer` does the same for the floats anchored
  at a position of the window it shows another buffer in, since their
  marker is of the old text (`dropAnchors`).
- **When an anchor is not drawn.** A publish asks where each position
  anchor is drawn and keeps the spot on the float, offset into frame
  pixels (`located`, `Loop.publish`). A transient float whose anchor is
  not drawn closes there: a position its window does not show, or an
  anchor window with no rectangle. A pinned one keeps its last spot.
- `removeWindow` takes a float out of `floats`, and never refuses it with
  `onlyWindow`: floats do not count, so the last tile cannot be closed
  while floats remain.
- `splitWindow` refuses a float with `floating`: it has no tile to split.
- `arrange`'s `promote` moves it into the tiles as main, `edge side` docks
  it, `float` moves it into the tiles at the end of the list, as
  `openWindow`'s `stack` places a window, and `resize` steps its share;
  `demote`, `rotate` and `exchange` refuse it with `floating`, since no
  operation changes the stacking order yet. `zoom`, `balance` and
  `mainCount` act as from any window. While a float is the selected view,
  focused or asked from, monocle shows the window it is anchored to, and
  for a float anchored to the frame the window focused before it
  (`monocleView`): so zoom from a float shows that window under it, and a
  focused transient float anchored to a window monocle would otherwise
  hide is not closed for want of its anchor.
- `arrange`'s `float` on a tile or a docked window floats it, pinned,
  anchored to the frame, of the default share, on top; the last tile is
  refused with `lastTile`.
- `toward?` never lands on a float, which overlaps the tiles it floats
  over; from a float the step starts from its rectangle.
- `openWindow`'s `float` refuses an anchor window that is a float with
  `floating`, one that is no tiled or docked window with `noSuchWindow`,
  and a position marker of another text than that window's buffer's with
  `markersOfAnotherText`.

**A view's id is never used again.** A new window's id is the state's
`nextView`, or one more than the greatest id a window has when that is
greater, so it is new on a state built by hand too; `nextView` is then one
past it. So what a scheme or a scene keeps under a closed view's id can
never come to mean another view.

The minibuffer's place is no window of the list, so no operation here can
remove it.
The minibuffer's window is not theirs either: `removeWindow`, `splitWindow`
and `showBuffer` refuse it with `ofMinibuffer` and its view, and
`showBuffer` refuses the same way to show the minibuffer's buffer in
another window. `removeWindow` counts the list's windows alone, so the last
ordinary window cannot be removed while a prompt is open.

## Tabs

A tab (`Tab`) is a whole arrangement of windows of its own, as a tmux
window is: its tiled list, its docked windows, its floats, its layout and
the one a zoom returns to, its focus, its last focused window, and the
name it was given, if any. Buffers are not a tab's: every tab's windows
show buffers of the one editor, and `EditorState.windows` holds every
window of every tab, with its markers.

**The frame extends the tab in view, as a zipper.** The tab in view is the
frame's own fields (`Frame extends Tab`), and the others are kept before
and after it (`Frame.tabsBefore`, `Frame.tabsAfter`), as xmonad's
`StackSet` keeps its current workspace and the hidden ones. So every read
of `frame.windows`, `frame.focused`, `frame.floats` and the rest is of the
tab in view, and so is every operation above: `EditorState.views`,
`rects`, `toward?`, `cycled` and the window operations read the tab in
view alone. An index into the tabs cannot be out of range, since the
zipper has none. What stays frame-wide is the frame's size, its focus,
fullscreen, its corner and top insets, and the layout config chose
(`Frame.chosen`).

- `Frame.tabs` is every tab in order, `Frame.tabIndex` the index of the tab
  in view, from 0, `Frame.everyWindow` every window of every tab, and
  `Frame.tabOf?` the tab a window is a window of.
- `Frame.selected index` moves the zipper so that the tab at `index` is in
  view, each tab as it was; an index past the last changes nothing.
  `Frame.withTabs` puts a new list of tabs in place, one of them in view.

`wellFormed` is stated over every tab: each tab's tiled list is not empty,
its layouts fit it, its docked windows' sides are edges of its layout, and
its floats are anchored to its own tiled or docked windows. A hidden tab's
focus is one of its own windows. The ids of every window of every tab,
then the minibuffer's view, are distinct and are exactly the windows' ids,
so no window is in two tabs.

**Tabs change by one operation**, `changeTab`, with the change as data
(`TabChange`), its indices from 0; each refusal leaves the state as it
was:

| Change | What it does | Refused with |
|---|---|---|
| `select i` | The tab left closes its transient floats (phase 4's rule that a transient float closes when it loses the focus, `closeFloats`), the zipper moves to `i`, and the buffer of the newly focused window becomes the most recent. Selecting the tab in view changes nothing | `noSuchTab`; `promptOpen` while a prompt is open and `i` is not the tab in view |
| `close i` | Every window of tab `i`, tiled, docked or floating, leaves `windows`, so the loop gives up their markers and tells the scheme they closed; its buffers stay. When `i` is the tab in view, the tab that takes its index comes into view, or the new last one when it was last, and its focused window's buffer becomes the most recent | `onlyTab`; `noSuchTab`; `promptOpen` when `i` is the tab in view and a prompt is open |
| `rename i name` | Sets the tab's name; `none` goes back to the generated one | `noSuchTab` |
| `move i to` | Tab `i` moves to `min to (count - 1)`; the tab in view stays in view, wherever it now stands | `noSuchTab` |

`promptOpen` keeps the asker of an open prompt a window of the tab in view,
so `closePrompt` never focuses a window that is not shown.

- **A new tab is a spot of `openWindow`** (`WindowSpot.tab`): right after
  the tab in view, its one window focused within it, under the layout
  config chose (`Frame.chosen`) or the default before any, fitted to it.
  The tab in view stays in view.
- **`focusWindow` takes a window of any tab.** For a window of a hidden tab
  it selects that tab as `select` does, then focuses the window within it,
  as Vim's `win_gotoid` switches tab pages; while a prompt is open that is
  refused with `promptOpen`.
- **`showBuffer` takes a window of any tab.** For a hidden tab's window it
  runs inside that tab (`inTabOf`): the zipper moves there, the buffer is
  shown and that tab's floats anchored at a position of the window are
  dropped (`dropAnchors`), and the zipper moves back.
- **The other operations stay with the tab in view.** For a hidden tab's
  window `removeWindow`, `splitWindow` and `arrange` answer `noSuchWindow`.

## The wanted column

A window keeps the column its vertical motions aim for, which survives
crossing a shorter line (`Window.wanted`, a `Window.Wanted`;
`docs/design/keymaps-and-modes.md`, "The wanted column").

- **The column** (`WantedColumn`) is a goal of the display's (`goal`), or
  `lineEnd`, the end of the row's content whatever its length. A goal is
  the x a move of the display aimed for, as the display passed it back
  (`Display.Moved.goal`): pixels from the start of the cursor's line laid
  out unwrapped. It is the display's number: the state keeps it and hands
  it back, and nothing here or above computes with it. A tab's stop and a
  character's width are layout's, and Lean keeps no copy of layout.
- **It is kept with the offset the cursor was left at** (`Wanted.head`),
  and holds only while the cursor is still there. So nothing has to clear
  it: whatever else moves the cursor makes it stale. Whether it holds is
  the reader's to ask, since the state does not know where a cursor is:
  that is a marker of the text store.
- `setWanted` sets it, or none, for any window, the minibuffer's among
  them.
- **A window shown another buffer keeps none** (`showBuffer`): an offset
  of one text means nothing in another. A window a split makes has none.
- It is a field of the state, so a command that does not run to its end
  leaves it as it was.

## What commands remember

What the editor keeps from one command to the next, for Vim's commands to
put back or repeat, is one field of the state (`EditorState.remembered`,
an `EditorState.Remembered`): the registers, the last character find and
the last search. Each part is set by one operation and read by one, is
never refused, and is rolled back with a command that does not run to its
end, since it is a field of the state.

### Registers

A register is a text a command set aside, to put back later
(`Register`; `docs/design/keymaps-and-modes.md`, "Registers").

- **It is a text and whether that text is whole lines** (`linewise`):
  what puts it back reads the flag to choose between the cursor and the
  line. The state does not check that a line-wise text ends in a line
  break: that is the rule of whoever sets it.
- **Registers are kept by name** (`EditorState.Remembered.registers`),
  for the whole editor and not for a buffer or a view. `register?` reads
  one, and `setRegister` sets one in place of the register the name had.
  A name is any string: which names mean something, the unnamed register
  among them, is the rule of the commands that set and read them, so one
  more register is one more name and nothing here changes.
- **The state starts with none.** A name nothing was set under reads as
  no register, which is another thing than a register whose text is
  empty.
- **They are fields of the state, so a command that does not run to its
  end leaves them as they were.** The clipboard is not here: it is
  outside the editor, behind a port of its own.

### The last search

The last search (`Search`, `EditorState.Remembered.lastSearch`, read by
`EditorState.lastSearch`) is what `n` and `N` repeat and what an empty
pattern reuses: the pattern as it was typed, and whether it went forward.
It is kept for the whole editor, as Vim keeps it, and set and kept as the
last find is (below): `setLastSearch` sets it, a motion hands it back as
data (`Vocabulary.To.search`), the command that ran the motion keeps it,
and a command that does not run to its end leaves it as it was. The loop
reads it too, for the matches it draws.

### The last find

The last character find (`Find`, `EditorState.Remembered.lastFind`, read
by `EditorState.lastFind`) is what Vim's `;` and `,` repeat: the
character an `f`, `t`, `F` or `T` looked for, and which of the four it was
(`docs/design/keymaps-and-modes.md`, "Motions as built"). It is kept for
the whole editor, as Vim keeps it and as the registers are kept.

- **The state starts with none**, and `setLastFind` sets it in place of
  the one it had. It is never refused.
- **A motion does not set it**: a motion changes nothing. It hands the
  find back as data (`Vocabulary.To.find`), and the command that ran it
  keeps it (`Editor/Evil.lean`, `Editor/Evil/Operators.lean`).
- **It is a field of the state, so a command that does not run to its end
  leaves it as it was.**

## The scroll margin

The scroll margin is how many rows a view keeps between its cursor's row
and the first and the last row it shows (`EditorState.scrollMargin`). Vim's
`scrolloff` is the model for the setting. The policy that reads it is in
`Editor/Scroll.lean`, which the loop runs before each scene
(`Editor/Loop.lean`, "Following the cursor").

- **It is 0 in a new state**: no margin, so a view moves only when its
  cursor's row is not among the rows it shows.
- **It is one number for every view**, kept for the whole editor. A margin
  for each window is a field of `Window` when something wants two.
- `setScrollMargin` sets it, in place of the one it had. It is never
  refused: any number is taken, and a margin larger than a view can keep
  is half the rows the view fits (`Editor/Scroll.lean`, "The margin"),
  which the state does not know.
- **It is a field of the state, so a command that does not run to its end
  leaves it as it was.**
- **It is set by a command**, since the state is. Nothing declares it when
  config loads: `setup` registers and runs no command. A setting that
  config declares is its home once there are settings.

## Prompts

A prompt is a request for one string, with a text to show beside the input
(the label). How a command waits for the answer is in
`docs/design/concurrency.md`, "Prompts".

- **The open prompt is editor state** (`EditorState.prompt`, a `Prompt`):
  its label, the minibuffer's view, the asking view, which was focused
  when the prompt was asked for, and the continuation, the invocation that
  receives the answer. One prompt is open at a time.
- **The minibuffer is a buffer and a window of the state.** The buffer is
  in the next slot, over a text the asking command made, with a name no
  buffer has (`Prompt.bufferName`, made free by `freeName`) and the major
  mode `Prompt.mode`. The window is in `windows`, with a new view id. So
  what works on a buffer and a window works on them with no rule of its
  own: a committed text is inserted there, the loop keeps and restores
  its markers and its history, and the scene has its view.
- **The window list does not change.** The minibuffer's place is always
  the frame's bottom strip, outside the area a layout tiles, and
  `EditorState.prompt` says whether a prompt is open and which window
  stands there. A view id in the list was set aside: the open prompt would
  then be in two places that an invariant must keep in step.
- `openPrompt` adds the buffer and the window, records the prompt with the
  focused view as its asker, focuses the new view and hands it back. It
  refuses, with the state as it was, `alreadyOpen` and the open prompt's
  view while one is open, `noWindow` when the focused view has no window
  to ask from (the state with nothing in it), and `notItsText` for a
  history or a marker of another text than the minibuffer's.
  `PromptRefusal.describe` says each as a sentence.
- `closePrompt` closes the open prompt, with an answer or with none for a
  prompt that is cancelled. It removes the minibuffer's window, empties
  its buffer's slot, and clears the prompt; the window list is as it was. It
  refuses `notOpen`, with the state as it was, when no prompt is open.
  - **The focus goes to the asking view**, even if it was moved meanwhile,
    so the answer's command runs with the window the prompt was asked in.
    When that view is no longer a window of the list, it goes to the first
    window of the list. A view's id is never used again,
    so the asker cannot have come to mean another view. The rule is one
    definition (`askedFrom`), for a command that was handed the
    minibuffer's view and needs a window of the list in its place.
  - **Given an answer it records the continuation**, with the answer as
    its first argument and the continuation's own after it
    (`EditorState.Outbox.answered`, `Editor/State/Outbox.lean`), until the
    loop hands it to its host (`Editor/Loop.lean`), as `starts` holds the
    jobs a command asked for.
    Closing and recording are one operation, so one request.
  - **The minibuffer's markers and text are not given up here**: the loop
    gives them up once the command that closed the prompt has run to its
    end, as it does for any window that is closed and any buffer that is
    removed.
- **A prompt may have candidates** (`Prompt.candidates`, a `Candidates`):
  records the answer may be chosen from (`Completion.Candidate`,
  `Editor/Completion/Candidate.lean`), each with the text accepting it
  gives and what a display may show beside it. They are plain data, as the
  rest of a prompt is, whichever sources answered them. They come in two
  kinds: those a style matches (`all`), and those a filtered source
  passed through (`passed`), which are listed as given. The prompt also
  holds its category (`category`), its first source's, which chooses the
  style it is matched with (`Loop.listed`). With them the prompt holds
  what it has shown of them:
  - **the listing**: the candidates the text typed so far matches, in the
    style's order, each with the ranges of its text that matched
    (`Completion.Listed`), then every passed candidate in the order given,
    whatever the text, none dropped, each with the ranges the style marks
    where it matches it (`Candidates.listing`, `Editor/Loop.lean`), and the
    text the listing was made for (`listed`, `listedFor`). The state does not match: `listCandidates` is handed the
    pattern and the hits a style answered for it (`Completion.Hit`), and
    keeps the candidates at those indices, in that order, with their
    ranges. An index that is none of the candidates' is dropped. A filtered
    source answered for the text it was asked with, and the style's
    matches are for the text typed now, so the matches come first;
  - **what the display showed of it** (`displayed`): the display the
    loop is handed for the prompt's category is handed the listing, the
    choice, where its window started last (`first`) and whether the
    listing holds two groups (`grouped`, computed when the listing is
    made). What it answers is kept on the prompt (`Prompt.sheet`), where
    its window starts now as `first`, and the high-water mark of its rows
    (`Prompt.tallest`). The state keeps the sheet, which is data, and
    never a display. A relisting for the same text keeps `first`, and one
    for another text starts it at 0;
  - **what the listing is made of** (`Candidates.answering`): the
    candidates as they answer the typed text, pure, the state never
    changed by it. An asking source whose listed answer was asked for
    another part of the text than its reask answers for
    (`Completion.Reask.answers`, against `Asking.answeredFor`) contributes
    nothing, so a directory's entries are never listed under another; and
    a hidden candidate (`Completion.Candidate.hiddenUntil`) is left out
    until the text after its source's separator reveals it. The size that
    chooses between listing inline and a match job projects only the
    stale answers (`Candidates.current`), per source, reading no
    candidate. A source's job that fails ends the source as `sourceAnswered`
    does and says why in the echo area (`sourceFailed`);
  - **what `TAB` and `RET` take from the listing**: `toInsert`, the chosen
    candidate, or the first listed with none chosen, of a listing for the
    minibuffer's text, which `minibuffer-insert` puts in the input; and
    `entered?`, a chosen candidate that is partial, which accepting goes
    into instead of answering;
  - **the choice**: an index of the listing, or none (`chosen`).
    `chooseCandidate` moves it by one step, `next` or `previous`. From
    nothing chosen, `next` chooses the first and `previous` the last;
    `next` from the last and `previous` from the first choose nothing. So
    the text as typed is one stop of the round, between the last candidate
    and the first. With nothing listed neither changes anything.
  - `setCandidates` replaces the candidates, the passed ones and the
    category (`Completion.Collected`) and forgets the listing and the
    choice; `listCandidates` forgets the choice, which was an index of
    the listing it replaces.
  - **What the prompt answers with** is `Candidates.answer`, of the text in
    the minibuffer: the chosen candidate's text, when one is chosen and
    the listing is for that text; otherwise the text typed. So a prompt
    with no candidates, or with nothing chosen, answers what was typed.
  - Each of the three operations refuses `notOpen`, with the state as it
    was, when no prompt is open. A prompt opened with none has no
    candidates, no listing and no choice, and is in every way the prompt
    it was before there were candidates.
  - They are fields of the state, so a command that does not run to its
    end leaves the listing and the choice as they were.

## A session at point

A session of completion at point (`EditorState.atPoint`, an
`AtPointSession`; `docs/design/keymaps-and-modes.md`, "Completion at
point") completes the region of a buffer an at-point source named. It is
plain data: the window it completes in and its buffer, the source that
answered, the markers of the region's ends (the start of bias `before`, the
end of bias `after`, so text typed at the end grows it), the text the user
typed (`typed`, what is matched) and what the session last left in the
region (`shown`), whether a preview was made, and the prompt's own
candidates, sheet and high-water mark.

- **One accessor serves both.** `completing?` is the open prompt's, else
  the session's (`Completing`: the view its candidates are keyed by, the
  view its sources are asked from, the candidates, the sheet, the
  high-water mark, and the typed text for a session), and
  `withCompleting view` writes back to whichever is in `view`. So
  `candidatesIn?`, `replaceCandidatesIn`, `addCandidates`, `sourceAnswered`,
  `listMatched`, `matchFailed` and `displayed` reach a session by its view
  with no rule of their own.
- `openAtPoint` opens one with the candidates its sources answered, nothing
  chosen; it is refused `promptOpen`, `alreadyOpen` and `noWindow`.
  `closeAtPoint` closes it and hands it back: its markers and snapshots
  are the caller's to give up. `chooseAtPoint`, `retypeAtPoint` (what a
  preview left) and `retakeAtPoint` (an edit the user made in the region:
  typed and shown, nothing chosen) are refused `notOpen` with none.
- `Candidates.region` and `Candidates.texts` keep the region as asked and
  the snapshots taken for sources that read the open buffers' texts, and
  `Candidates.exhausted` says nothing more is to come and nothing matches
  the typed text: the session closes then.
- **Its place.** While a session is open and no prompt is, the
  minibuffer's strip is the list's rows above the bottom row, with no input
  row (`listRows`, `minibufferPlace`, `cutStrip`, `candidateListRect?`),
  growing and never shrinking while it is open.
- `retyped` is a one-shot, as the outbox's `answered` is: what commands
  typed in place of typed text (`retype`), which the loop tells the input
  scheme.
- `wellFormed` holds a session to a view that is a window and a choice
  inside its listing.

## Key hints

The keys that can follow a pending prefix, once a delay has passed, are a
candidate list with no typed text (`EditorState.keyHints`, a
`KeyHintList`; `Editor/Loop.lean`, "Key hints", opens and closes them):

- **Fields.** The generation they were opened at, whether they are due,
  their listing (one candidate a key, with no ranges), the sheet the
  display answered at the last publish and its high-water mark.
  `keyHintGeneration` counts the generations and is never used again.
- **Due, by generation.** `keyHintsDue generation` makes them due only
  when they are of that generation, so a delay that fires for hints since
  closed, or for others, changes nothing, even when the host's withdrawal
  raced it. `listKeyHints` lists due hints and nothing else.
- **Shown while nothing is completing** (`hinting?`): the candidate list's
  place is an open prompt's or session's then (`candidateSheet?`), and the
  hints are not shown.
- **Their place** is the candidate list's, directly above the bottom row,
  with no input row (`listRows`, `minibufferPlace`, `cutStrip`,
  `candidateListRect?`), growing and never shrinking while they are open,
  as a prompt's does. `displayed` shows them with the display chosen for
  the category `key` (`KeyHintList.category`), handed their listing with
  nothing chosen.

## Buffers

- `addBuffer` gives a new buffer the next slot. It refuses `nameTaken` for
  a name a buffer already has, so that finding a buffer by its name
  (`findBuffer`) has one answer, and `notItsHistory` for an undo tree over
  another text than the buffer's.
- `removeBuffer` empties the buffer's slot. It refuses `noSuchBuffer`, and
  `shown`, with the first such view, while a window shows the buffer. The
  buffer's text is not released here: the loop releases it once the command
  that removed the buffer has run to its end (`Editor/Loop.lean`, "What a
  finished command gave up"), so a command that fails afterwards is rolled
  back whole.
- `setHistory` replaces a buffer's undo tree, for the commands that move in
  the history. It refuses `noSuchBuffer`, and `notItsHistory` for a tree
  over another text.
- `setValue` sets a buffer-local value under a name, in place of the one
  the name had; `value?` reads one.
- `renameBuffer` gives a buffer another name. It refuses `noSuchBuffer`,
  and `nameTaken` for a name another buffer has; a buffer renamed to its
  own name is as it was. It is there for one rule: the buffer left after
  the last one is closed is called `scratchName`, the name the initial
  buffer has, which is free only once the closed buffer is removed, and a
  shown buffer cannot be removed (`Editor/Buffers.lean`, "Close").
- `scratchName` is the editor's one name for its empty buffer with no file:
  the initial state's, and the one left after the last buffer is closed.
- A buffer may be **read-only** (`Buffer.readOnly`, set by `setReadOnly`,
  which refuses `noSuchBuffer`): an edit of its text by a command is
  refused where commands are dispatched (`Editor/Command/Dispatch.lean`,
  "Read-only buffers"), and a committed text into it is dropped
  (`Editor/Loop.lean`). `readOnly?` finds the read-only buffer over a
  text, with its name, and `readOnlyReason` is what is said. The command
  that owns such a buffer writes it inside `BufferId.writing`
  (`Editor/Api.lean`), as Emacs's `inhibit-read-only`.
- A buffer may have **spans** (`Buffer.spans`, set by `setSpans`, which
  refuses `noSuchBuffer`): byte ranges of its text, each with a face, that
  every view of it draws under the last search's matches
  (`Editor/Loop.lean`, "Decorations"). Nothing moves them on an edit: they
  are for a buffer its owner alone writes, such as a compilation buffer,
  which is read-only and whose spans the compile mode resets with its text
  (`Editor/Compile.lean`, "Locations").
- A buffer may have a **gutter** (`Buffer.gutter`, set by `setGutter`,
  which refuses `noSuchBuffer`): marks, each a byte range of its text at
  the gutter's revision with a short text and a face, which every window
  of it draws in a column `Buffer.Gutter.width` points wide before its text
  (`paddingOf`). Unlike spans they follow the edits made since: a view
  carries them to the revision it shows through the text's log
  (`Gutter.marksOf`). The version-control gutter is their owner
  (`Editor/VersionControl/Gutter.lean`).

### Excerpt buffers

An *excerpt buffer* is a buffer over an excerpt text (`createExcerpts`,
`Editor/Text.lean`), whose edits are its sources' edits. It is added by
`addExcerptBuffer`, which refuses as `addBuffer` does, and it keeps
`Buffer.excerpts`, the history of what it edited and an entry for each of
its excerpts, which `setExcerptHistory` replaces whole (refused with
`noSuchBuffer`, and with `notExcerpts` for a buffer that is not one).

- **Each excerpt's entry** (`Buffer.ExcerptEntry`) is its source's text
  and the header drawn above it, in list order. They are the editor's
  display data, kept here and not in the store's list: a window over the
  buffer draws each header as a block above its excerpt, and each source
  buffer's spans at its excerpts (`Editor/ExcerptView.lean`).
- **An entry may be tracked** (`Buffer.ExcerptEntry.viewed`, `some` of a
  `Buffer.Viewed`): the loop's publish records what the views showed of it,
  how many scenes, the clock at the first, and how long it was on screen
  (`markViewed`, `creditViewed`; `Editor/Loop.lean`, "After each event"),
  and a view draws one no scene has shown yet in `review-unexamined`
  (`Editor/ExcerptView.lean`). Both are pure, and ignore an entry that is
  not tracked and an index past the entries. The review buffer's excerpts
  are tracked (`Editor/VersionControl/Review.lean`).

- **Its own `history`** is an undo tree over its text like any buffer's,
  told and closed by the loop and never moved: its text keeps no inverse, so
  an undo in it is not its tree's. Its "modified" mark is not its tree's
  either: the mode line marks it modified while a buffer over one of its
  sources is (`ModeLine.Context.modified`, `Loop.contextOf`).
- **What it edited is a list of steps** (`Buffer.Excerpts`): each step
  (`Buffer.ExcerptStep`) names the source buffers an edit through the
  excerpt buffer reached, each with its name and the state its undo tree
  was left in once the step was closed (`Buffer.ExcerptSource`). The source
  buffers an edit reaches since the last step are `touched` (`touch`), and
  `closeExcerptGroup` makes them a step: pure, over trees already told and
  closed, it pushes one with each touched buffer's name and
  `history.state`, clears `touched` and empties `redos`.
- **An undo in it undoes one step in each source buffer**, and only when
  each is still in the state the step recorded: otherwise it is refused
  with `sourceMoved` and the first source that moved. A source buffer that
  was removed since is dropped from the step, the step with it once none is
  left, and the undo is refused with `sourceRemoved` and the name the step
  recorded (`Editor/Api.lean`, "Undo").
- `excerptBufferOver?` finds the excerpt buffer over a text, and
  `bufferOver?` the plain buffer over a source text, which the command
  dispatcher asks before an edit through an excerpt buffer
  (`Editor/Command/Dispatch.lean`, "Read-only buffers and excerpt
  sources").

### Most recently used

The state keeps the open buffers in the order they were last used
(`EditorState.recent`, most recent first, each once), so that a closed
buffer's windows show the one used before it, and a switch lists the
buffers in that order.

- **The operations that already exist keep it**, so no command keeps it
  by hand: `showBuffer` puts the shown buffer first; `focusWindow` puts
  the focused window's buffer first, unless it is the minibuffer's;
  `addBuffer` puts the new buffer last, so a buffer that was made and never
  shown is still in the order; `removeBuffer` takes the buffer out.
  `openPrompt` and `closePrompt` leave it: the minibuffer's buffer is never
  in it.
- **`mostRecent except`** is the first buffer of the order that is open
  and is neither `except` nor the minibuffer's, and failing that the first
  such buffer in the order of the slots, so a state built by hand with no
  order still has an answer. `none` when no other buffer is open.
- **`openBuffers`** is every open buffer but the minibuffer's in that same
  order: the order first, then the rest by slot. The buffer list and the
  switch prompt read it (`Editor/Buffers.lean`).
- `wellFormed` asks that every buffer of the order is open, and that none
  is there twice.

## A buffer's file

- **A buffer keeps its file** (`Buffer.file`, a `Buffer.File`): the file's
  path, and the stamp the last load or save of it answered, which is what
  the next save expects to find on disk (`Editor/File.lean`). `none` for a
  buffer that shows no file. The stamp is not optional: a buffer comes to
  hold a file by a load, which answers one.
- **A buffer keeps its line ending** (`Buffer.lineEnding`), a line feed
  unless a file said otherwise. It is the buffer's and not the file's: a
  buffer with no file needs an answer too when a command breaks a line. It
  decides only the line break a command inserts. Nothing is translated on
  the way in or out: the text holds every byte of the file.
- **The saved state is the undo tree's** (`UndoTree.saved`, in
  `Buffer.history`), and so is whether the buffer is modified
  (`Buffer.isModified`). A second copy here would be a second answer.
- **A path is matched as a string** (`findFile`): the buffer whose file's
  path is equal to it. Two spellings of one file (a symbolic link, `..`, a
  doubled slash) are two buffers. That is safe: once one is saved, a save
  of the other is refused as changed on disk, so neither overwrites the
  other unnoticed. A canonical path would be the file system's to answer,
  which the file port does not.
- `attachFile` has a buffer hold a file: its path, its stamp and the
  buffer's line ending, with no save in flight. It refuses `noSuchBuffer`,
  and `fileOpen`, with the buffer that holds it, for a path another buffer
  holds, so that `findFile` has one answer, as `nameTaken` gives
  `findBuffer` one. Attaching the path a buffer holds to that buffer again
  replaces its stamp, and clears the changed-on-disk mark. It leaves the
  history: a buffer made over loaded text has a new tree, which is saved at
  its root.
- **A buffer keeps what a check found of its file** (`Buffer.File.changed`,
  a `Buffer.Changed`): the file's stamp now, the last one found, or `none`
  for a file that is gone, and whether the user was told. A check is one
  stat, asked for by the loop (`Editor/Loop.lean`, "Files that changed on
  disk"); nothing watches a file.
  - `markChanged id stamp found told` records a check's result. `stamp` is
    the stamp the buffer recorded when the stat was asked for, and the
    request applies only while the buffer's stamp is still that one, so a
    result a save or a reload has overtaken is dropped. It clears the mark
    when `found = some stamp`; otherwise it sets it, in place of the
    `found` of a buffer already marked, told when `told` is or when the
    mark was already told of that same `found`.
  - `tellChanged id` marks the user as told: an edit is refused only while
    `told` is false (`untold?`, `Editor/Command/Dispatch.lean`, "The first
    edit after a change on disk").
  - `attachFile` and `endSave` with a stamp clear it.
- `freeName` is a name no buffer has, for a new buffer that would be
  called `name`: the name itself, or the name followed by `<2>`, `<3>` and
  so on, the first that is free. Two files with one base name are two
  buffers this way.
- **The state keeps a save in flight** (`Buffer.File.saving`, a
  `Buffer.Saving`): a save whose job has been started and whose result
  has not yet been delivered. It holds the snapshot the save writes and
  the state the text was in when the snapshot was taken.
  - `beginSave` records one. It refuses `noSuchBuffer`, `noFile` for a
    buffer that shows no file, and `beingSaved` while a save is in flight.
    Two saves of one buffer in flight would both expect the stamp from
    before the first, and the second would be refused as changed on disk
    though nothing but the editor wrote the file; here the second is
    refused when it is asked, with a refusal that says why.
  - `endSave` ends the one that writes a given snapshot: it is no longer
    in flight. Given the stamp of the file the save wrote, the buffer's
    file has that stamp and the kept state is the one marked as saved
    (`UndoTree.markSaved`): a buffer whose text has moved on since stays
    modified, since a save that reports late marks the state it wrote.
    Given no stamp, for a save that was refused, neither changes, and a
    quit that was asked is withdrawn ("Quit", below). It
    refuses `noSuchBuffer`, and `notBeingSaved` unless a save of the
    buffer that writes that snapshot is in flight.
  - Ending a save is one request that asks the text store nothing, so the
    command that makes it cannot be interrupted between the stamp and the
    mark. The snapshot is released by the loop, once that command has run
    to its end (`Editor/Loop.lean`, "What a finished command gave up").

## Quit

A command asks the editor to quit, and the editor quits once it can
(`docs/design/concurrency.md`, "Quit").

- **Asked to quit is editor state** (`EditorState.quitting`), set by one
  request (`StateRequest.quit`). So a command that asks and then does not
  run to its end is rolled back to a state that was not asked, and a quit
  that waits for a save outlives the command that asked.
- **A buffer has unsaved changes** (`Buffer.unsaved`) when it holds a
  file, its text is in another state than the one last saved, and no save
  in flight is writing the state it is in. A buffer with no file never
  has: it cannot be saved. A buffer whose save in flight covers its text
  has none; one edited since that save began has. Like "modified", the
  answer is right once the history was told the text's revision;
  `Buffer.unsavedAt` takes a tree a command told itself.
- **The editor leaves** (`EditorState.leaves`) when it was asked to quit,
  no buffer has unsaved changes, and no save is in flight. The loop asks
  after each scene and says stop (`Editor/Loop.lean`, "Quit").
- **A quit that cannot go ahead is withdrawn**, in two places, so that a
  quit that was waiting for a save is not left to fire at some later
  save:
  - `settleQuit`: asked to quit while a buffer has unsaved changes, the
    state is no longer asked. The loop applies it when it makes a scene.
    So a quit that was waiting ends without quitting when the buffer is
    edited meanwhile.
  - `endSave` with no stamp: a save that ends without having written the
    file withdraws the quit, whether or not the buffer is modified. A
    buffer that was not modified has no unsaved changes after its save
    was refused, so `settleQuit` alone would let the editor leave with
    the save's refusal unseen. The state does not keep which save a quit
    waits for: any save that is refused withdraws it.
- **The system's quit is remembered until it is answered**
  (`EditorState.systemQuit`), set by the loop when the system asks
  (`Event.quitRequested`) before it runs `quit`. `answerSystemQuit` answers
  it once the editor is not asked to quit: the quit was refused, or
  withdrawn in one of the two places above. While the editor is asked, it
  waits or leaves, and the system is not answered.

## A buffer's modes

Three operations set a buffer's modes, of the same shape. Each is refused,
with the state as it was, with `BufferRefusal.noSuchBuffer` for a buffer
there is none of. They take any name: whether a mode of that name is
registered is the loop's to ask, which also runs the mode's `onEnter`
(`Editor/Command/Dispatch.lean`).

- `setMajorMode` makes a mode the buffer's major mode, and says whether it
  became it: `false`, with nothing changed, when the buffer already had it.
- `addMinorMode` puts a minor mode first; one the buffer has already
  changes nothing.
- `removeMinorMode` takes a minor mode away; one the buffer does not have
  changes nothing.

## Smaller rules

- A new state's frame is focused, on view 0, with one window over a buffer
  called `scratch` of an empty text, whose scroll anchor is at 0 and whose
  selection is one cursor at 0 (`EditorState.initial`). The cursor's shape
  is the caller's to say, and exclusive when it says none: the loop gives
  it the shape its input scheme reports of the first view
  (`Editor/Loop.lean`). A window made later takes its shape from a window
  that exists (`ViewId.show`, `ViewId.split`, `Editor/Api.lean`), and the
  minibuffer's cursor is exclusive (`prompt`).
- The frame's `hasFocus` is the platform window's keyboard focus. While the
  frame does not have it, the scene names no focused view.
- The frame's `fullscreen` is whether the window last said it is in the
  system's fullscreen, on a resize: a command reads it
  (`toggle-fullscreen`, `Editor/FrameCommands.lean`), and nothing but a
  resize changes it.
- The selected view (`EditorState.selectedView`) is the open prompt's asker
  while a prompt is open, and the focused view otherwise. The window's
  title (`EditorState.title`) is its buffer's name, so it does not become
  the minibuffer's while a prompt is typed into.
- The preedit is the text an input method is composing in the focused
  window; `none` when it is composing nothing.
- No ambient context: a handler is given the window it acts on and its
  buffer, as a `Target`, never "the current buffer".
- `EditorState.none` is an editor with no buffer and no window. It is not
  well formed, and no loop holds it: it is what a command's state requests
  are answered from where no loop runs the command
  (`Editor/Command/Model.lean`).

## Workspaces

The state keeps the workspaces and the projects of the session
(`EditorState.workspaces`, a `Workspace.Table`, `Editor/Workspace.lean`):
each workspace and each project with a store of values by name, and each
directory's answer from the finder, stamped with the config generation it
was found under. Both stores live as long as the session; a reload of config
leaves them.

- **A buffer's workspace is a buffer-local value** (`Workspace.bufferLocal`):
  its location, encoded (`Location.encode`). `workspaceOf?` reads it and
  looks the workspace and its project up in the table; a buffer with no
  such value, or one whose workspace is not in the table, has none.
- `recordWorkspace` takes in what the finder answered for a directory: the
  workspace is added, or, found again, keeps its root, its project and its
  store and takes the new branch; the directory's answer is cached.
- `registerWorkspace` adds a workspace that is made, not found, for a
  location that is not on this machine; it refuses `local`.
- `setWorkspaceValue` and `setProjectValue` set a value in a workspace's or
  a project's store; they refuse `noSuchWorkspace` and `noSuchProject`.
- `setUnscopedValue` sets a value in the store of the buffers outside any
  workspace (`Workspace.Table.unscoped`); it is never refused.
- **The editor's working directory** (`workingDirectory`) is where a
  command run for a buffer with no workspace and no file runs. A host sets
  it once, when its loop's frame is made, from its own working directory
  (`Headless.Collaborators.workingDirectory`); it is `/` until then.
- **Where a command run for a buffer runs** is decided here, once, for
  every command that runs one (`:!`, `find-file-in-workspace`).
  `workingDirectoryOf` is the buffer's own answer, to which
  `BufferId.workingDirectory` (`Editor/Api.lean`) forwards: its
  workspace's root on this machine, its workspace's location when that is
  elsewhere, its file's directory with no separator at its end
  (`Process.trimmed`, so a file `/x//a` runs in `/x`), or `none`.
  `commandDirectoryOf` is the directory on this machine that comes to:
  that root or that directory, else the editor's working directory.
- **The directory a view reads names from** (`directoryOf`) is Emacs's
  `default-directory` for `find-file`: the directory of its buffer's file,
  else the root of its buffer's workspace when that is on this machine,
  else the editor's working directory. With the home directory (`home`,
  which a host sets when it knows it, and the headless host never does) it
  is the place a prompt's sources read paths from (`placeOf`,
  `Completion.Place`).

## The jump list and marks

Where Vim's jumps and marks are (`docs/design/keymaps-and-modes.md`, "The
jump list and marks") is pure data of the state. The rules of recording
and moving are `Editor/JumpList.lean`'s and `Editor/Jumps.lean`'s.

- **A place** (`Place`) is held by an anchor marker of an open buffer's
  text, which the store moves with every edit, or, once that buffer was
  closed, detached into its file's path, a row and a column.
- **Each window has its jump list and previous-context mark**
  (`Window.jumps`, a `Jumps`), set whole by `setJumps`. A split copies
  them to the new window, which then shares their markers: a marker is
  given up only when no place holds it.
- **A buffer has its marks** (`Buffer.marks`, Vim's lowercase marks),
  set by `setLocalMark`, and **the global marks** are what commands
  remember (`EditorState.Remembered.globalMarks`, Vim's uppercase marks),
  set by `setGlobalMark`.
- **Removing a buffer drops every place held in it**, from every window's
  jumps and from the global marks: whoever keeps them detaches them first.
- **The state holds only places that hold** (`wellFormed`): a held place's
  buffer is open and the marker is of its text, and a buffer's marks are
  markers of its own text.
- **The markers are the loop's to give up**, once a command has run to its
  end (`EditorState.placeMarkers`, `Loop.gaveUp`), so a command that is
  rolled back has unmarked nothing.
- **A buffer keeps what its marks follow line deletions and undo by**
  (`Buffer.markHistory`, `Marks.History`, `Editor/Marks.lean`). The loop
  reads and sets it once an event has been handled
  (`EditorState.followMarks`, `Editor/Marks/Follow.lean`): it erases a
  mark whose line was deleted, puts lowercase marks back after an undo or
  a redo, and gives up the markers of the marks it erased or replaced.
  Each step of an undo or a redo follows them too, as it is taken
  (`BufferId.moved`, `Editor/Api.lean`), setting it by `setMarkHistory`
  and the marks by `setLocalMark`.

## Where a new field goes

| What it belongs to | Where |
|---|---|
| One buffer (its line ending, its modes) | A field of `Buffer` |
| The file a buffer shows (what the next save expects on disk) | A field of `Buffer.File` |
| One view (a goal column, a scroll offset) | A field of `Window` |
| A place in a text that is to follow its edits and outlive its buffer (a jump list's entry, a mark) | A `Place`, held in `Window.jumps`, `Buffer.marks` or `EditorState.Remembered.globalMarks`, or a new field beside them that `EditorState.placeMarkers` reads, so its markers are given up |
| Something a command asks the loop to hand its host once it has run to its end (a job to start or cancel, an invocation to run next, a reload, a theme) | A field of `EditorState.Outbox` (`Editor/State/Outbox.lean`, "Where a new entry goes"), which the loop empties whole after each command |
| What commands remember for the whole editor from one command to the next, to put back or repeat (a register, the last find, the last search) | A field of `EditorState.Remembered` ("What commands remember"), set by an operation here and read through one |
| The whole editor, set and read on its own (the scroll margin, the pending key prefix, a command's choice of auto-reload, asked to quit, the order buffers were used in) | A field of `EditorState` |
| What the last publish was handed or measured, or drew itself (the row heights, the padding, when the tab bar shows, the tab bar's and the candidate list's views) | A field of `EditorState`, set by a publish (`Loop.publish`, `Editor/Loop.lean`) |
| What a reconciler of the loop keeps in step after each publish (the files followed for auto-reload, the gutter's tracked files and watched repositories, the open prompt's job keys) | A field of `EditorState` beside `following`, `tracked`, `refWatches` and `completionKeys`, written by that reconciler |
| One checkout or one codebase (compilation state, command history) | A value in a workspace's or a project's store (`Workspace.Table`) |
| The open prompt (what completes it, what it has shown) | A field of `Prompt` |
| What the user sees of it | A field of the scene (`Editor/Scene.lean`), filled in `Loop.scene`, or in `Loop.views` for a field of a view (`Editor/Loop.lean`) |

Each is pinned by `ModelTest.stateChecks`, and what the scene shows of it by
`ModelTest.loopChecks`. The operations a request reaches are pinned through
the requests' handler, by `ModelTest.stateRequestChecks`, and an outbox
entry's hand-back by `ModelTest.dispatchQuitChecks`.
-/

namespace Editor

/-- The name of a buffer: the index of its slot in the state's buffers. It is
never used again once its buffer is removed. -/
structure BufferId where
  /-- Which buffer. -/
  index : Nat
  deriving DecidableEq, Repr

/-- A save of a buffer that is in flight: its job has been started, and its
result has not yet been delivered. -/
structure Buffer.Saving where
  /-- The snapshot of the buffer's text the save writes. -/
  snapshot : SnapshotId
  /-- The state the text was in when the snapshot was taken: the one to
  mark as saved when the save reports. -/
  state : UndoTree.State
  deriving DecidableEq, Repr

/-- What a check found of a buffer's file that is not the file the buffer
holds: the file changed on disk ("A buffer's file", in the module docs). -/
structure Buffer.Changed where
  /-- The stamp the file has now, the last one found; `none` when the file
  is gone. -/
  found : Option File.Stamp
  /-- Whether the user was told, by a refused first edit or by the echo
  area of a check that found the buffer modified. An edit is refused only
  while this is false. -/
  told : Bool
  deriving DecidableEq, Repr

/-- The file a buffer shows: where it is, and what the next save of it
expects to find there. -/
structure Buffer.File where
  /-- The file's path, as it was opened: a path is matched to a buffer by
  equality with this. -/
  path : System.FilePath
  /-- The stamp the last load or save of the file answered. -/
  stamp : File.Stamp
  /-- The save of the buffer that is in flight, if one is. -/
  saving : Option Buffer.Saving := none
  /-- The file changed on disk, if a check found so since the last load or
  save; `none` otherwise. -/
  changed : Option Buffer.Changed := none
  deriving DecidableEq, Repr

/-- A source buffer an excerpt buffer's step reached, as the step recorded
it. -/
structure Buffer.ExcerptSource where
  /-- Which buffer. -/
  buffer : BufferId
  /-- Its name when the step was recorded: what is said of it once it is
  removed. -/
  name : String
  /-- The state its undo tree was in when the step was recorded. -/
  state : UndoTree.State
  deriving DecidableEq, Repr

/-- One step of an excerpt buffer's history: the source buffers an edit
through it reached, each with the state its undo tree was in when the step
was closed. -/
structure Buffer.ExcerptStep where
  /-- The source buffers, their names and their trees' states. -/
  sources : Array Buffer.ExcerptSource := #[]
  deriving DecidableEq, Repr

/-- What the views of a tracked excerpt showed of it ("Excerpt buffers", in
the module docs): written by the loop's publish (`Editor/Loop.lean`, "After
each event"). -/
structure Buffer.Viewed where
  /-- How many published scenes showed it in a view's visible rows. -/
  scenes : Nat := 0
  /-- The host clock's milliseconds at the first such scene. -/
  firstAt : Option Nat := none
  /-- How long it was on screen, in milliseconds: the time between a scene
  that showed it and the next publish, summed. -/
  shownFor : Nat := 0
  deriving DecidableEq, Repr

/-- Whether a scene has shown it. -/
def Buffer.Viewed.examined (viewed : Buffer.Viewed) : Bool :=
  viewed.scenes > 0

/-- One excerpt of an excerpt buffer as the editor keeps it beside the
store's list: its source's text, the header drawn above it, and, when it is
tracked, what was viewed of it ("Excerpt buffers", in the module docs). -/
structure Buffer.ExcerptEntry where
  /-- The text of its source. -/
  source : TextId
  /-- The header drawn above it; none when empty. -/
  header : String := ""
  /-- What the views showed of it, when it is tracked; `none` when it is
  not. -/
  viewed : Option Buffer.Viewed := none
  deriving DecidableEq, Repr

/-- What an excerpt buffer keeps of what its edits reached, and of each of
its excerpts ("Excerpt buffers", in the module docs). -/
structure Buffer.Excerpts where
  /-- The source buffers an edit reached since the last step was closed. -/
  touched : Array BufferId := #[]
  /-- The steps to undo, the last one last. -/
  undos : Array Buffer.ExcerptStep := #[]
  /-- The steps to redo, the next one last. -/
  redos : Array Buffer.ExcerptStep := #[]
  /-- One entry for each excerpt of its text, in list order: its source and
  its header. -/
  entries : Array Buffer.ExcerptEntry := #[]
  deriving DecidableEq, Repr

/-- A buffer's gutter: the marks its views draw in a gutter column, as byte
ranges of its text at `revision` ("Buffers", in the module docs). Its owner
sets it; a view carries the marks to the revision it shows through the
text's log (`Gutter.marksOf`, `Editor/Gutter.lean`). -/
structure Buffer.Gutter where
  /-- The revision of the text the marks are ranges of. -/
  revision : Nat
  /-- The marks. -/
  marks : Array GutterMark := #[]
  deriving DecidableEq, Repr

/-- The width of a gutter column, in points: a named constant of policy, the
padding of a window whose buffer has a gutter (`EditorState.paddingOf`). -/
def Buffer.Gutter.width : Nat :=
  12

/-- A buffer: a text and what the editor keeps about it. -/
structure Buffer where
  /-- Its name, as the user sees it. -/
  name : String
  /-- Its text, in the text store. -/
  text : TextId
  /-- The history of its text. -/
  history : UndoTree
  /-- Its local values, by name. -/
  locals : Array (String × Value) := #[]
  /-- The name of its major mode, if it has one. -/
  major : Option String := none
  /-- The names of its minor modes, the one added last first. -/
  minors : Array String := #[]
  /-- The name of its language (`Editor/Language.lean`), if it has one: the
  entry is looked up in the registry's table when a mode is entered, so a
  reload's entry of that name is the one used next. -/
  language : Option String := none
  /-- The file it shows; `none` for a buffer that shows none. -/
  file : Option Buffer.File := none
  /-- The line break a command inserts in it: its file's dominant line
  ending, and a line feed for a buffer with no file or a file with no line
  break. Nothing else is decided by it. -/
  lineEnding : File.LineEnding := .lf
  /-- Whether its text is read-only to editing commands ("Buffers", in the
  module docs). -/
  readOnly : Bool := false
  /-- Byte ranges of its text, each with a face, set by its owner and drawn
  under the last search's matches ("Buffers", in the module docs). -/
  spans : Array Decoration := #[]
  /-- For an excerpt buffer, what its edits reached ("Excerpt buffers", in
  the module docs); `none` for any other buffer. -/
  excerpts : Option Buffer.Excerpts := none
  /-- Its gutter, which every window of it draws in a column before its text
  ("Buffers", in the module docs); `none`, no column, by default. -/
  gutter : Option Buffer.Gutter := none
  /-- Its marks, Vim's lowercase marks: each letter with the anchor marker
  of its text it is held by ("The jump list and marks", in the module
  docs). No letter is here twice. -/
  marks : Array (Char × MarkerId) := #[]
  /-- What its marks follow line deletions and undo by (`Marks.History`,
  `Editor/Marks.lean`): the lines its marks and the global marks held in
  it were on, its lowercase marks at the last boundary of its history, and
  those each node of its history keeps. -/
  markHistory : Marks.History := {}
  deriving BEq, Repr

/-- Whether the buffer's text is in another state than the one last saved,
as its history knows it (`UndoTree.isModified`): right once the history was
told the revision the text is at, which the loop does before each scene. -/
def Buffer.isModified (buffer : Buffer) : Bool :=
  buffer.history.isModified

/-- Whether the buffer has unsaved changes, its text being in the state
`history` is in ("Quit", in the module docs): it holds a file, the text is
in another state than the one last saved, and no save in flight is writing
the state it is in. A buffer with no file never has. `history` is the
buffer's undo tree, told the revision the text is at. -/
def Buffer.unsavedAt (buffer : Buffer) (history : UndoTree) : Bool :=
  match buffer.file with
  | none => false
  | some file => history.isModified && !file.saving.any (·.state == history.state)

/-- Whether the buffer has unsaved changes, as its history knows it
(`Buffer.unsavedAt`): right once the history was told the revision the text
is at, which the loop does before each scene. -/
def Buffer.unsaved (buffer : Buffer) : Bool :=
  buffer.unsavedAt buffer.history

/-- The column a view's vertical motions aim for. -/
inductive WantedColumn where
  /-- The x a move of the display aimed for, as the display passed it back
  (`Display.Moved.goal`): pixels from the start of the cursor's line laid
  out unwrapped. It is passed back to the display and never computed
  with. -/
  | goal (x : Nat)
  /-- Where the row's content ends, whatever its length: what a motion to
  the line's end leaves, so that the vertical motions after it stay at line
  ends. -/
  | lineEnd
  deriving DecidableEq, Repr

/-- The wanted column a window keeps, with the position it was kept at. -/
structure Window.Wanted where
  /-- The column. -/
  column : WantedColumn
  /-- The offset the cursor was left at when the column was kept. The column
  holds only while the cursor is still there. -/
  head : Nat
  deriving DecidableEq, Repr

/-- Where a jump list's entry or a mark is ("The jump list and marks", in
the module docs): held by a marker of an open buffer's text, which moves
with every edit, or, once that buffer was closed, detached into its file's
path, a row and a column. -/
inductive Place where
  /-- At the anchor marker `marker` of the text of the buffer `buffer`. -/
  | held (buffer : BufferId) (marker : MarkerId)
  /-- In the file at `path`, at the row `row`, from 0, and the column
  `column`, in characters from the row's start: a place of a buffer that
  was closed. -/
  | file (path : System.FilePath) (row column : Nat)
  deriving DecidableEq, Repr

/-- The marker a place is held by; `none` for a place detached into a
file. -/
def Place.marker? : Place → Option MarkerId
  | .held _ marker => some marker
  | .file .. => none

/-- A window's jump list and its previous-context mark ("The jump list and
marks", in the module docs). -/
structure Jumps where
  /-- The jump list, Vim's `w_jumplist`. -/
  list : JumpList Place := {}
  /-- The previous-context mark, Vim's `w_pcmark`: where the last jump was
  made from, which `''` and ``` `` ``` go to; `none` before any jump. -/
  previous : Option Place := none
  deriving DecidableEq, Repr

/-- Every place of `jumps`: the list's entries, then the previous-context
mark. -/
def Jumps.places (jumps : Jumps) : Array Place :=
  jumps.list.entries ++ jumps.previous.toArray

/-- `jumps` with each place changed by `change`, and dropped where it
answers `none`: the list's as `JumpList.filterMap` changes it, which
carries its index, and the previous-context mark. -/
def Jumps.filterMap (change : Place → Option Place) (jumps : Jumps) : Jumps :=
  { list := jumps.list.filterMap change, previous := jumps.previous.bind change }

/-- A window: a view of a buffer. -/
structure Window where
  /-- The view's name in every scene. -/
  id : ViewId
  /-- The buffer it shows. -/
  buffer : BufferId
  /-- Its scroll position: an anchor marker of the buffer's text. -/
  scroll : MarkerId
  /-- Its selections: one selection marker of the buffer's text, whose
  ranges are its cursors. -/
  selection : MarkerId
  /-- The column its vertical motions aim for, with the offset the cursor
  was left at when it was kept; `none` when it keeps none ("The wanted
  column", in the module docs). -/
  wanted : Option Window.Wanted := none
  /-- Its jump list and previous-context mark ("The jump list and marks",
  in the module docs). -/
  jumps : Jumps := {}
  deriving DecidableEq, Repr

/-- One tab of the frame: a whole arrangement of windows of its own, as a
tmux window is. Buffers are not a tab's: every tab's windows show buffers
of the one editor ("Tabs", in the module docs). The tab in view is the
frame's own fields (`Frame extends Tab`). -/
structure Tab where
  /-- The tab's tiled windows, by their views' names, in order: the first
  is main. The minibuffer's window is not among them, nor are the windows
  docked at an edge (`docked`). -/
  windows : Array ViewId
  /-- The windows docked at an edge, each with its side, in order: they are
  not in `windows`, which stays the tiled list the layout's operations
  index. -/
  docked : Array (ViewId × Side) := #[]
  /-- The floating windows, above the tiles, in stacking order: the first is
  lowest, the last on top. They are in neither `windows` nor `docked`
  (`Editor/Floating.lean`). -/
  floats : Array Floating := #[]
  /-- How its windows are arranged (`Editor/Layout.lean`). -/
  layout : Layout := Layout.default
  /-- The window that is focused within it: in the tab in view, the
  minibuffer's view while a prompt is open. -/
  focused : ViewId
  /-- The layout a zoom left, to go back to: `some` while zoomed, when
  `layout` is monocle. -/
  zoomedFrom : Option Layout := none
  /-- The window of the tab focused before the current one, Vim's
  `prevwin`: set when the focus moves from one window of the tab to
  another (`contains`), and never cleared, so a reader checks that it is
  still in the tab. -/
  lastFocused : Option ViewId := none
  /-- The name the tab was given (`tab-rename`); none for the generated one,
  its focused window's buffer's name (`EditorState.tabLabel`). -/
  name : Option String := none
  deriving DecidableEq, Repr

namespace Tab

/-- Every window of the tab: the tiled list, then the docked windows, then
the floats in stacking order. The minibuffer's window is not among them. -/
def all (tab : Tab) : Array ViewId :=
  tab.windows ++ tab.docked.map (·.1) ++ tab.floats.map (·.view)

/-- Whether `id` is a window of the tab: in the tiled list, docked at an
edge, or floating. -/
def contains (tab : Tab) (id : ViewId) : Bool :=
  tab.windows.contains id || tab.docked.any (·.1 == id) || tab.floats.any (·.view == id)

/-- Whether `id` is a tiled or a docked window of the tab: a window a float
may be anchored to. A float is not, so placement never recurses. -/
def anchors (tab : Tab) (id : ViewId) : Bool :=
  tab.windows.contains id || tab.docked.any (·.1 == id)

/-- The float `id`, if it is one of the tab's. -/
def floating? (tab : Tab) (id : ViewId) : Option Floating :=
  tab.floats.find? (·.view == id)

/-- The side the window `id` is docked at; none for a window that is not
docked. -/
def sideOf? (tab : Tab) (id : ViewId) : Option Side :=
  (tab.docked.find? (·.1 == id)).map (·.2)

/-- The windows docked at `side`, in order. -/
def atSide (tab : Tab) (side : Side) : Array ViewId :=
  (tab.docked.filter (·.2 == side)).map (·.1)

/-- The layout the windows are arranged by out of a zoom: the one zoom
returns to while zoomed, and the tab's own otherwise. -/
def underlying (tab : Tab) : Layout :=
  tab.zoomedFrom.getD tab.layout

end Tab

/-- The one window of the platform: what is frame-wide, and the tabs of
windows arranged in it. The tab in view is the frame's own fields (it
extends `Tab`), so every read of `frame.windows`, `frame.focused` and the
rest is of the tab in view; the tabs before it and after it are kept
apart, in order (`tabsBefore`, `tabsAfter`), as xmonad's `StackSet` keeps
its current workspace and the hidden ones ("Tabs", in the module docs). -/
structure Frame extends Tab where
  /-- Its size, in physical pixels. -/
  size : Size
  /-- Whether it has the keyboard focus. -/
  hasFocus : Bool := true
  /-- Whether the window last said it is in the system's fullscreen
  (`Event.Resize.fullscreen`). A command reads it, and nothing but a resize
  changes it. -/
  fullscreen : Bool := false
  /-- How far in from the window's left and right edges its rounded bottom
  corners reach, in whole points, as the window last said on a resize
  (`Event.Resize.corner`): what the bottom row keeps clear of
  (`EditorState.bottomInset`). Nothing but a resize changes it. -/
  corner : Nat := 0
  /-- How far down from the window's top edge its title bar covers it, in
  whole points, as the window last said on a resize (`Event.Resize.top`):
  what the views along the frame's top edge start their text below
  (`EditorState.topInset`). Nothing but a resize changes it. -/
  top : Nat := 0
  /-- The layout config chose that the last publish applied (`Frame.choose`,
  `Loop.publish`): a publish handed the same one again leaves the frame's
  layout, so a command's change to it lasts. It is frame-wide: config's
  layout rearranges the tab in view, and a new tab takes it. -/
  chosen : Option Layout := none
  /-- The tabs before the one in view, in order. -/
  tabsBefore : Array Tab := #[]
  /-- The tabs after the one in view, in order. -/
  tabsAfter : Array Tab := #[]
  deriving DecidableEq, Repr

namespace Frame

/-- Every tab of the frame, in order: the tabs before the one in view, the
tab in view (the frame's own fields), and the tabs after it. -/
def tabs (frame : Frame) : Array Tab :=
  frame.tabsBefore ++ #[frame.toTab] ++ frame.tabsAfter

/-- The index of the tab in view among `tabs`, from 0; the tab bar and the
keys count from 1. -/
def tabIndex (frame : Frame) : Nat :=
  frame.tabsBefore.size

/-- Every window of every tab, tab by tab in order, each tab's in
`Tab.all`'s order. The minibuffer's window is not among them. -/
def everyWindow (frame : Frame) : Array ViewId :=
  frame.tabs.flatMap Tab.all

/-- The index of the tab the window `id` is a window of, if it is one of a
tab's. -/
def tabOf? (frame : Frame) (id : ViewId) : Option Nat :=
  frame.tabs.findIdx? (·.contains id)

/-- The frame with `tabs` as its tabs and the one at `index` in view; the
frame unchanged for an index past the last. -/
def withTabs (frame : Frame) (tabs : Array Tab) (index : Nat) : Frame :=
  match tabs[index]? with
  | some tab =>
    { frame with
      toTab := tab, tabsBefore := tabs.extract 0 index
      tabsAfter := tabs.extract (index + 1) tabs.size }
  | none => frame

/-- The frame with the tab at `index` in view, the zipper moved and every
tab as it was; the frame unchanged for an index past the last. -/
def selected (frame : Frame) (index : Nat) : Frame :=
  frame.withTabs frame.tabs index

/-- The frame with the float `id` changed by `change`; one that is not a
float leaves it as it was. -/
def withFloat (frame : Frame) (id : ViewId) (change : Floating → Floating) : Frame :=
  { frame with
    floats := frame.floats.map fun float => if float.view == id then change float else float }

/-- The frame with the windows docked at `side` replaced, in their places,
by `views` in order: `views` is a reorder of `atSide side`. -/
def withSide (frame : Frame) (side : Side) (views : Array ViewId) : Frame :=
  let (docked, _) :=
    frame.docked.foldl
      (fun (placed, left) (view, at_) =>
        match at_ == side, left[0]? with
        | true, some next => (placed.push (next, at_), left.extract 1 left.size)
        | _, _ => (placed.push (view, at_), left))
      ((#[] : Array (ViewId × Side)), views)
  { frame with docked }

/-- The frame with `layout` as the layout the windows are arranged by out
of a zoom (`underlying`): the one zoom returns to while zoomed, monocle
staying shown, and the frame's own otherwise. -/
def withUnderlying (frame : Frame) (layout : Layout) : Frame :=
  match frame.zoomedFrom with
  | some _ => { frame with zoomedFrom := some layout }
  | none => { frame with layout }

/-- The frame once config chose `layout`: the windows docked at a side the
layout has no edge at join the end of the tiled list, in order, so none is
lost; then its layout, fitted to the windows (`Layout.fits`), recorded as
the one chosen, and no zoom. -/
def choose (frame : Frame) (layout : Layout) : Frame :=
  let sides := layout.edgeSides
  let moved := (frame.docked.filter fun (_, side) => !sides.contains side).map (·.1)
  let windows := frame.windows ++ moved
  { frame with
    windows, docked := frame.docked.filter fun (_, side) => sides.contains side
    layout := layout.fits windows.size, chosen := some layout, zoomedFrom := none }

/-- The frame's layouts once its window at `index` was split by
`placement`: the layout and the one zoom returns to (`Layout.inserted`).
The list is the caller's. -/
def inserted (frame : Frame) (index : Nat) (placement : Placement) : Frame :=
  { frame with
    layout := frame.layout.inserted index placement
    zoomedFrom := frame.zoomedFrom.map (·.inserted index placement) }

/-- The frame's layouts once its window at `index` was removed
(`Layout.removed`), and the index, after the removal, of the window that
inherits its place, if a layout says one: while zoomed, the layout zoom
returns to says it. The list is the caller's. -/
def removed (frame : Frame) (index : Nat) : Frame × Option Nat :=
  let (layout, inheritor) := frame.layout.removed index
  match frame.zoomedFrom with
  | some back =>
    let (back, inheritor) := back.removed index
    ({ frame with
        layout, zoomedFrom := some back },
      inheritor)
  | none => ({ frame with layout }, inheritor)

/-- The frame with `id` focused, and, when the focus moves from one window
of the frame to another (`contains`), the one it leaves as the last
focused. -/
def focusedOn (frame : Frame) (id : ViewId) : Frame :=
  let moves := frame.focused != id && frame.contains frame.focused && frame.contains id
  { frame with
    focused := id, lastFocused := if moves then some frame.focused else frame.lastFocused }

end Frame

/-- A file buffer the loop follows for auto-reload: a `follow-file` job of
the key `Following.key` is armed for it ("Auto-reload", `Editor/Loop.lean`). -/
structure Following where
  /-- The buffer. -/
  buffer : BufferId
  /-- The path its watch is on. -/
  path : System.FilePath
  /-- The buffer's stamp when it was armed: a load, a reload or a save that
  changes it arms the follow again, so its order's stamp is the buffer's. -/
  stamp : File.Stamp
  /-- Whether its watch was refused: it is not armed again until the mode is
  turned off and on. -/
  refused : Bool := false
  deriving DecidableEq, Repr

/-- The key a host keeps the follow job of `buffer` under. -/
def Following.keyOf (buffer : BufferId) : String :=
  s!"follow {buffer.index}"

/-- A buffer of a tracked file the version-control gutter keeps marks for
(`Editor/VersionControl/Gutter.lean`): which file, its content at `HEAD`,
and the head fetch and the diff in flight for it. Plain data, beside
`Following`; the gutter's reconciler keeps it in step after each publish. -/
structure Tracked where
  /-- The buffer. -/
  buffer : BufferId
  /-- The root of its workspace, the repository's. -/
  root : System.FilePath
  /-- Its file's path, relative to the root. -/
  path : String
  /-- The git program. -/
  git : String
  /-- A snapshot of its file's content at `HEAD`, once one has arrived;
  `none` before, and when `HEAD` lacks the file. -/
  head : Option SnapshotId := none
  /-- Whether a head fetch is in flight. -/
  fetching : Bool := true
  /-- The revision of the buffer's text a diff in flight was taken at, and
  the snapshot taken of it. -/
  diffing : Option (Nat × SnapshotId) := none
  /-- The revision of the buffer's text last diffed against `head`. -/
  diffed : Option Nat := none
  /-- Whether `HEAD` or the index may have moved since `head` was fetched. -/
  stale : Bool := false
  /-- Which head fetch is the latest: a reply of another is stale. -/
  epoch : Nat := 0
  deriving DecidableEq, Repr

/-- A repository the version-control gutter watches for `HEAD` or the index
moving: its root, and whether the watch was refused, which is not tried
again while a buffer of it is tracked. -/
structure RefWatch where
  /-- The root. -/
  root : System.FilePath
  /-- Whether its watch was refused. -/
  refused : Bool := false
  deriving DecidableEq, Repr

/-- What a command of the version-control gutter tells the state of what
arrived (`StateRequest.gutter`). -/
inductive GutterChange where
  /-- The head fetch `epoch` of the buffer arrived: its content at `HEAD`, or
  `none` when `HEAD` lacks the file or the fetch failed. -/
  | held (buffer : BufferId) (epoch : Nat) (head : Option SnapshotId)
  /-- The diff of the buffer, taken at `revision`, arrived or failed. -/
  | diffed (buffer : BufferId) (epoch revision : Nat)
  /-- `HEAD` or the index of the repository at `root` may have moved. -/
  | moved (root : System.FilePath)
  /-- The watch of the repository at `root` was refused. -/
  | refused (root : System.FilePath)
  deriving DecidableEq, Repr

/-- The candidates of an open prompt, and what the prompt has shown of
them ("Prompts", in the module docs). It is plain data. -/
structure Candidates where
  /-- The candidates the prompt was asked with that a style matches, in the
  order they came in. -/
  all : Array Completion.Candidate := #[]
  /-- The candidates filtered sources answered, in the order they came in:
  listed after the matches, whatever the text, each with the style's ranges
  where it matches (`Candidates.listing`, `Editor/Loop.lean`). -/
  passed : Array Completion.Candidate := #[]
  /-- The prompt's category, which chooses its style: its first source's,
  or none. -/
  category : Option String := none
  /-- The text `listed` was made for; `none` when no listing has been made
  since the candidates were set. -/
  listedFor : Option String := none
  /-- The listing: the candidates that text matches, in the style's order,
  each with the ranges that matched, then the passed ones. -/
  listed : Array Completion.Listed := #[]
  /-- The choice: an index of `listed`, or none. -/
  chosen : Option Nat := none
  /-- The sources that answer later, in the order they were asked, each with
  what it has answered so far. -/
  asking : Array Completion.Asking := #[]
  /-- What may be listed, as a count: bumped whenever it changes, a batch
  taken or a source's answer replaced or cleared. -/
  revision : Nat := 0
  /-- The revision `listed` was made at. -/
  listedAt : Nat := 0
  /-- The match a worker is running for this prompt, if one is
  (`Editor/Loop.lean`, "Prompts"). -/
  matching : Option Completion.InFlight := none
  /-- The text and the revision a match failed for: not matched again until
  one of them changes. -/
  unmatched : Option (String × Nat) := none
  /-- The index of the listing the display's window started at in the last
  scene (`EditorState.displayed`). -/
  first : Nat := 0
  /-- Whether the listing holds two groups or more (`Completion.grouped`),
  computed when it was made. -/
  grouped : Bool := false
  /-- The region the sources were asked to complete, for a session at point
  ("A session at point", in the module docs); none for a prompt. -/
  region : Option Completion.Span := none
  /-- The snapshots taken for the sources that read the open buffers'
  texts (`Completion.Later.readsTexts`), the asking view's first: released
  when the prompt or the session closes. -/
  texts : Array SnapshotId := #[]
  /-- The place the sources were asked with (`Completion.Query.place`): what
  the orders of the sources that answer later carry. -/
  place : Completion.Place := {}
  /-- The context the sources were asked with (`Completion.Query.context`):
  what the command that opened the prompt handed them, which the orders of
  the sources that answer later carry too. -/
  context : List Argument := []
  deriving DecidableEq, Repr

namespace Candidates

/-- The candidates a style matches: the prompt's own, then what each
asking source that has not filtered answered, in the asking order. A
source that answers later comes after those that answered now. -/
def matchable (candidates : Candidates) : Array Completion.Candidate :=
  candidates.asking.foldl
    (fun all source => if source.filtered then all else all ++ source.answered) candidates.all

/-- The candidates listed as given, after the matches: the passed ones, then
what each filtered asking source answered, in the asking order. None is
dropped and their order is kept; the style only marks the ranges it matches
(`Candidates.listing`, `Editor/Loop.lean`). -/
def passing (candidates : Candidates) : Array Completion.Candidate :=
  candidates.asking.foldl
    (fun passed source => if source.filtered then passed ++ source.answered else passed)
    candidates.passed

/-- How many candidates a style matches (`matchable`), counted over the
sources without gathering them. -/
def matchableSize (candidates : Candidates) : Nat :=
  candidates.asking.foldl
    (fun size source => if source.filtered then size else size + source.answered.size)
    candidates.all.size

/-- How many candidates are listed as given (`passing`), counted over the
sources without gathering them. -/
def passingSize (candidates : Candidates) : Nat :=
  candidates.asking.foldl
    (fun size source => if source.filtered then size + source.answered.size else size)
    candidates.passed.size

/-- How many candidates a listing hands the style: those it matches, and
those listed as given, which it marks. It is what chooses whether a prompt
is listed on the editor thread or by a match job (`Loop.listed`,
`Loop.completionJobs`, `Editor/Loop.lean`). -/
def listingSize (candidates : Candidates) : Nat :=
  candidates.matchableSize + candidates.passingSize

/-- The candidates as they answer `typed`, for sizing a listing: each asking
source whose answer is for another text than `typed` answers by its reask
(`Completion.Reask.answers`) contributes nothing. It is per source, and
reads no candidate. -/
def current (candidates : Candidates) (typed : String) : Candidates :=
  { candidates with
    asking :=
      candidates.asking.map fun source =>
        match source.answeredFor with
        | some answeredFor =>
          if source.later.reask.answers answeredFor typed then source
          else { source with answered := #[] }
        | none => source }

/-- The candidates as they answer `typed`, for making a listing: `current`,
and each hidden candidate (`Completion.Candidate.hiddenUntil`) left out
unless the typed text after its source's separator (`Reask.after`, the whole
text for a given candidate) starts with what reveals it. It is pure: the
state is never changed by it. -/
def answering (candidates : Candidates) (typed : String) : Candidates :=
  let shown (after : String) (candidate : Completion.Candidate) : Bool :=
    match candidate.hiddenUntil with
    | some reveal => after.startsWith reveal
    | none => true
  let current := candidates.current typed
  { current with
    all := current.all.filter (shown typed)
    passed := current.passed.filter (shown typed)
    asking :=
      current.asking.map fun source =>
        { source with
          answered := source.answered.filter (shown (source.later.reask.after typed)) } }

/-- A step of the choice through the listing. -/
inductive Step where
  /-- To the candidate after the chosen one. -/
  | next
  /-- To the candidate before the chosen one. -/
  | previous
  deriving DecidableEq, Repr

/-- `candidates` with a listing for `pattern`: the candidates of `all` at
the hits' indices, in that order, each with its hit's ranges, an index that
is none of theirs dropped; then every passed candidate, in the order given,
with no ranges, since no style's hits for them are handed here (the match
job's listing, `Candidates.listing`, marks them); and nothing chosen, the
window at its start, and whether it holds two groups. -/
def list (candidates : Candidates) (pattern : String) (hits : Array Completion.Hit) : Candidates :=
  let matchable := candidates.matchable
  let matched :=
    hits.filterMap fun hit => (matchable[hit.index]?).map (Completion.Listed.of · hit.ranges)
  let listed := matched ++ candidates.passing.map Completion.Listed.of
  { candidates with
    listedFor := some pattern, listed, chosen := none, listedAt := candidates.revision, first := 0
    grouped := Completion.grouped listed }

/-- `candidates` with `listed` as the listing for `pattern`, made at
`revision`. The choice is kept on the same candidate, the first listed that
is equal to it, when `pattern` is the text the old listing was for, so a
batch that arrives does not throw away a choice; otherwise, or when that
candidate is not listed, nothing is chosen. The display's window keeps its
start for the same text, and starts at 0 for another; whether the listing
holds two groups is computed again. -/
def relist (candidates : Candidates) (pattern : String) (revision : Nat)
    (listed : Array Completion.Listed) : Candidates :=
  let same := candidates.listedFor == some pattern
  let chosen :=
    if same then
      candidates.chosen.bind fun index =>
        (candidates.listed[index]?).bind fun old => listed.findIdx? (·.candidate == old.candidate)
    else none
  { candidates with
    listedFor := some pattern, listed, chosen, listedAt := revision
    first := if same then candidates.first else 0, grouped := Completion.grouped listed }

/-- Whether a match is in flight for `pattern` at `revision`. -/
def matchingFor (candidates : Candidates) (pattern : String) (revision : Nat) : Bool :=
  candidates.matching.any fun inFlight =>
    inFlight.pattern == pattern && inFlight.revision == revision

/-- `candidates` with the choice moved by `step`: from nothing chosen to
the first or the last of the listing, from the last onward and from the
first backward to nothing chosen, and otherwise by one. With nothing listed
it is as it was. -/
def choose (candidates : Candidates) (step : Step) : Candidates :=
  let count := candidates.listed.size
  let chosen :=
    match step, candidates.chosen with
    | .next, none => if count == 0 then none else some 0
    | .next, some index => if index + 1 < count then some (index + 1) else none
    | .previous, none => if count == 0 then none else some (count - 1)
    | .previous, some 0 => none
    | .previous, some (index + 1) => some index
  { candidates with chosen }

/-- Whether nothing more is to come of these candidates for `typed`, and
nothing is listed for it: no match is in flight, every asking source's job
has ended, and either nothing can be listed at all, or the listing is for
`typed` at the current revision and empty. A session at point closes then
("A session at point", in the module docs): the text stopped matching. -/
def exhausted (candidates : Candidates) (typed : String) : Bool :=
  let current := candidates.current typed
  candidates.matching.isNone && candidates.asking.all (·.done) &&
    (current.matchableSize == 0 && current.passing.isEmpty ||
      candidates.listedFor == some typed && candidates.listedAt == candidates.revision &&
        candidates.listed.isEmpty)

/-- The candidate `minibuffer-insert` puts in a minibuffer holding `text`:
when the listing is for `text`, the chosen candidate, or the first listed
when nothing is chosen, as vertico preselects the first; `none` with
nothing listed, and for a listing of another text, which a match job has
not yet replaced. -/
def toInsert (candidates : Candidates) (text : String) : Option Completion.Candidate :=
  if candidates.listedFor != some text then none
  else
    let index := candidates.chosen.getD 0
    (candidates.listed[index]?).map (·.candidate)

/-- The chosen candidate, when the listing is for `text` and the candidate
is partial (`Completion.Candidate.isPartial`): what accepting goes into
instead of answering. -/
def entered? (candidates : Candidates) (text : String) : Option Completion.Candidate :=
  if candidates.listedFor != some text then none
  else
    (candidates.chosen.bind (candidates.listed[·]?)).bind fun listed =>
      if listed.candidate.isPartial then some listed.candidate else none

/-- What a prompt with these candidates answers with when the minibuffer
holds `text`: the chosen candidate's text, when one is chosen and the
listing is for `text`, and otherwise `text`. -/
def answer (candidates : Candidates) (text : String) : String :=
  match candidates.chosen with
  | some index =>
    if candidates.listedFor == some text then
      (candidates.listed[index]?.map (·.candidate.text)).getD text
    else text
  | none => text

end Candidates

/-- An open prompt: a request for one string ("Prompts", in the module
docs). It is plain data: the command that receives the answer is named. -/
structure Prompt where
  /-- The text shown beside the input. -/
  label : String
  /-- The minibuffer's view: the window the answer is typed in, which stands
  in the minibuffer's place while the prompt is open. -/
  view : ViewId
  /-- The asking view: the one that was focused when the prompt was asked
  for, which gets the focus back when the prompt is closed. -/
  asker : ViewId
  /-- The continuation: the command that receives the answer, and plain
  arguments of the asker's own, which follow the answer. -/
  continuation : Invocation
  /-- The candidates the answer may be chosen from, with their listing and
  the choice; none of any, unless the prompt was asked with sources that
  answered some. -/
  candidates : Candidates := {}
  /-- What the display answered at the last publish
  (`EditorState.displayed`): the rows of the candidate list. -/
  sheet : Completion.Sheet := {}
  /-- The most rows any sheet has shown since the prompt opened: how tall
  the candidate list's part of the minibuffer's place is, which grows and
  never shrinks while the prompt is open (`EditorState.listRows`). It is
  data only, and goes with the prompt. -/
  tallest : Nat := 0
  deriving DecidableEq, Repr

/-- The name of the major mode the minibuffer's buffer is made with. A mode
is registered under it by whoever ships the minibuffer's commands
(`Editor/Minibuffer.lean`); with none registered it contributes nothing. -/
def Prompt.mode : String :=
  "minibuffer"

/-- What the minibuffer's buffer is called, unless a buffer already has the
name (`EditorState.freeName`). -/
def Prompt.bufferName : String :=
  "minibuffer"

/-- A session of completion at point ("A session at point", in the module
docs): the region of a buffer being completed, held by markers, what the
user typed in it and what the session last left there, and the prompt's own
candidates, sheet and high-water mark. It is plain data. -/
structure AtPointSession where
  /-- The window it completes in, focused while it is open. -/
  view : ViewId
  /-- The buffer that window shows. -/
  buffer : BufferId
  /-- The name of the at-point source that answered. -/
  source : String
  /-- The marker of the region's start, an anchor of bias `before`. -/
  start : MarkerId
  /-- The marker of the region's end, an anchor of bias `after`: text typed
  at the end grows the region. -/
  stop : MarkerId
  /-- The text the user typed in the region: what is matched. -/
  typed : String
  /-- What the session last left in the region: `typed`, or the previewed
  candidate's text. -/
  shown : String
  /-- Whether a preview was made: the buffer's group was closed before the
  first, and is closed again when the session ends, so the previews and the
  accept are one step of the history. -/
  previewed : Bool := false
  /-- Whether it was asked silently, by itself on a trigger or a pause: it
  then closes without saying `no completions` when it never showed a
  row. -/
  silent : Bool := false
  /-- The candidates, their listing and the choice, as a prompt holds
  them. -/
  candidates : Candidates := {}
  /-- What the display answered at the last publish. -/
  sheet : Completion.Sheet := {}
  /-- The most rows any sheet has shown since the session opened. -/
  tallest : Nat := 0
  deriving DecidableEq, Repr

/-- What is completing now, a prompt or a session at point, as the loop's
listing, display and jobs read it (`EditorState.completing?`). -/
structure Completing where
  /-- The view its candidates are keyed by: the minibuffer's for a prompt,
  the window's for a session. -/
  view : ViewId
  /-- The view its sources are asked from: the prompt's asker, or the
  session's window. -/
  asker : ViewId
  /-- Its candidates. -/
  candidates : Candidates
  /-- What the display answered at the last publish. -/
  sheet : Completion.Sheet
  /-- Its high-water mark of rows. -/
  tallest : Nat
  /-- The text it matches, for a session (`AtPointSession.typed`); none for
  a prompt, whose minibuffer's text is read. -/
  typed : Option String
  deriving DecidableEq, Repr

/-- The key hints of a pending prefix ("Key hints", in the module docs): a
candidate list with no typed text, shown once its delay has passed. -/
structure KeyHintList where
  /-- The generation it was opened at (`EditorState.keyHintGeneration`): a
  delay that fires for another changes nothing. -/
  generation : Nat
  /-- Whether its delay has passed, so it is shown. -/
  due : Bool := false
  /-- The listing, one candidate a key that can follow, in the scheme's
  order, with no ranges: none until it is due. -/
  listed : Array Completion.Listed := #[]
  /-- What the display answered at the last publish. -/
  sheet : Completion.Sheet := {}
  /-- The most rows any sheet has shown since it opened. -/
  tallest : Nat := 0
  deriving DecidableEq, Repr

/-- The category the key hints are listed under, `key`: the display config
chose for it draws them (`Completion.Keys.category`, the `key` source's). -/
def KeyHintList.category : String :=
  "key"

/-- A register: a text a command set aside ("Registers", in the module
docs). -/
structure Register where
  /-- The text. -/
  text : String
  /-- Whether the text is whole lines, to be put back as lines. -/
  linewise : Bool := false
  deriving DecidableEq, Repr

/-- A search, as `n` and `N` repeat it ("The last search", in the module
docs). -/
structure Search where
  /-- The pattern, as it was typed. -/
  pattern : String
  /-- Whether it went forward, as `/` and `*` do. -/
  forward : Bool
  deriving DecidableEq, Repr

/-- A character find, as `;` and `,` repeat it ("The last find", in the
module docs). -/
structure Find where
  /-- The character looked for, as the key that named it printed it. -/
  char : String
  /-- Whether it looked forward, as `f` and `t` do. -/
  forward : Bool
  /-- Whether it stopped one cell short of the character, as `t` and `T`
  do. -/
  till : Bool
  deriving DecidableEq, Repr

/-- What the editor remembers from one command to the next, for Vim's
commands to put back or repeat: the registers, the last character find
and the last search ("What commands remember", in the module docs). -/
structure EditorState.Remembered where
  /-- The registers, each under its name, in the order each name was first
  set ("Registers", in the module docs). No name is here twice. -/
  registers : Array (String × Register) := #[]
  /-- The last character find, if one was made ("The last find", in the
  module docs). -/
  lastFind : Option Find := none
  /-- The last search, if one was made ("The last search", in the module
  docs). -/
  lastSearch : Option Search := none
  /-- The global marks, Vim's uppercase marks: each letter with the place
  it is at, in whichever buffer or file ("The jump list and marks", in the
  module docs). No letter is here twice. -/
  globalMarks : Array (Char × Place) := #[]
  deriving DecidableEq, Repr

/-- Everything the editor is showing and editing. -/
structure EditorState where
  /-- The buffers, one a slot; a `BufferId` is an index here, and the slot of
  a buffer that was removed is `none`. -/
  buffers : Array (Option Buffer)
  /-- The windows, each named by its view's id. -/
  windows : Array Window
  /-- The frame. -/
  frame : Frame
  /-- The echo area's text. -/
  echo : String := ""
  /-- The text an input method is composing in the focused window, if any. -/
  preedit : Option String := none
  /-- The id the next new window gets, unless a window already has one as
  great: an id is never used again. -/
  nextView : Nat := 1
  /-- What commands asked the loop to hand its host, which it has not yet
  handed (`Editor/State/Outbox.lean`). -/
  outbox : EditorState.Outbox := {}
  /-- The prompt that is open, if one is: its view is a window of `windows`
  that is not in the frame's list. -/
  prompt : Option Prompt := none
  /-- The session of completion at point that is open, if one is ("A session
  at point", in the module docs). -/
  atPoint : Option AtPointSession := none
  /-- The key hints of the prefix pending, if a prefix is pending and the
  hints are on ("Key hints", in the module docs): shown once due, while
  nothing is completing. The loop opens and closes them
  (`Loop.armedHints`). -/
  keyHints : Option KeyHintList := none
  /-- The generation the last key hints were opened at: counted up for
  each and never used again, so a delay armed for hints since closed
  fires for nothing. -/
  keyHintGeneration : Nat := 0
  /-- What commands typed in place of typed text, each with its view, in
  order, which the loop has not yet told the input scheme: backspace
  characters for the cells a command removed, then what it inserted, as the
  scheme records typed text ("A session at point", in the module docs). -/
  retyped : Array (ViewId × String) := #[]
  /-- Whether a command asked the editor to quit ("Quit", in the module
  docs). -/
  quitting : Bool := false
  /-- Whether the system asked the program to quit and has not been
  answered (`Event.quitRequested`; "Quit", in the module docs). -/
  systemQuit : Bool := false
  /-- What commands remember from one to the next: the registers, the last
  find and the last search ("What commands remember", in the module docs). -/
  remembered : EditorState.Remembered := {}
  /-- How many rows every view keeps between its cursor's row and the first
  and the last row it shows ("The scroll margin", in the module docs). -/
  scrollMargin : Nat := 0
  /-- The heights of a text row, a window's status row and the frame's
  bottom row, as the display last answered them: what the views and the
  minibuffer's place are sized by ("The heights of the rows", in the module
  docs). A publish asks them again (`Loop.publish`); before the first, a
  16-pixel cell's. -/
  heights : Display.Heights := { text := 16, status := 16, message := 16 }
  /-- The frame padding the last publish laid the views out with, in whole
  points: what every view's content is inset by ("The padding of the
  views", in the module docs). A publish sets it from what it is handed
  (`Loop.publish`), as it sets `heights`; 0 before the first. -/
  padding : Nat := 0
  /-- The open buffers in the order they were last used, most recent first,
  each once, without the minibuffer's ("Most recently used", in the module
  docs). -/
  recent : Array BufferId := #[]
  /-- Whether a command chose auto-reload on or off (`Files.autoReloadName`):
  `none` until one does, and then config's setting no longer decides. It
  lasts until the editor stops; a reload of config leaves it. -/
  autoReload : Option Bool := none
  /-- The file buffers the loop follows for auto-reload, each with its path
  and whether its watch was refused (`Editor/Loop.lean`, "Auto-reload"). -/
  following : Array Following := #[]
  /-- The keys of the jobs the loop started for the open prompt: its
  sources' jobs and its match (`Editor/Loop.lean`, "Prompts"), cancelled
  once the prompt no longer wants them. -/
  completionKeys : Array String := #[]
  /-- The buffers of tracked files the version-control gutter keeps marks
  for (`Editor/VersionControl/Gutter.lean`). -/
  tracked : Array Tracked := #[]
  /-- The repositories whose `HEAD` and index the version-control gutter
  watches. -/
  refWatches : Array RefWatch := #[]
  /-- The workspaces and projects of the session, with their stores, and
  each directory's cached answer ("Workspaces", in the module docs). -/
  workspaces : Workspace.Table := {}
  /-- The editor's working directory: where a command run for a buffer with
  no workspace and no file runs ("Workspaces", in the module docs). A host
  sets it once, from its own; `/` until it does. -/
  workingDirectory : System.FilePath := "/"
  /-- The home directory, which `~` names in a path typed in a prompt
  (`Editor/TypedPath.lean`). A host that knows it sets it once, with the
  working directory; none until then. -/
  home : Option System.FilePath := none
  /-- When the tab bar is shown (`Editor/TabBar.lean`): config's choice, as
  the last publish was handed it (`Loop.publish`); while there are two tabs
  or more before any. -/
  tabBarShown : TabBar.Shown := .several
  /-- The tab bar's view, text and line, once a publish has drawn it; kept
  for the editor's life (`Editor/TabBar.lean`, "What it is"). -/
  tabBar : Option GeneratedView := none
  /-- The candidate list's view, text and content, once a publish has drawn
  it; kept for the editor's life, as `tabBar` is ("The minibuffer's place",
  in the module docs). -/
  candidateList : Option GeneratedView := none
  deriving BEq, Repr

/-- What a handler acts on: a window and the buffer it shows. -/
structure Target where
  /-- The window. -/
  window : Window
  /-- Its buffer. -/
  buffer : Buffer
  deriving BEq, Repr

/-- A change of the frame's window list or its layout's parameters, which
`EditorState.arrange` makes on a window of the list. -/
inductive Arrange where
  /-- The window to main, index 0; main itself swaps with the next. -/
  | promote
  /-- The window swaps with the next of the list; the last stays. -/
  | demote
  /-- The windows the layout rotates (`Layout.rotated`), forward as Vim's
  `C-w r` or back as its `C-w R`. -/
  | rotate (forward : Bool)
  /-- The window swaps with the `nth` of the list, 1-based, or with the
  next, or the previous when it is last; the focus moves to the other. -/
  | exchange (nth : Option Nat)
  /-- Into monocle, keeping the layout to go back to, or back to it. -/
  | zoom
  /-- The windows made equal (`Layout.balanced`). -/
  | balance
  /-- The window grown or shrunk along `axis` by `steps` steps of 5 percent
  (`Layout.resized`). -/
  | resize (axis : Axis) (grow : Bool) (steps : Nat)
  /-- Master-and-stack's count of main's windows up or down by `steps`, not
  below 0. -/
  | mainCount (more : Bool) (steps : Nat)
  /-- A tiled window docked at `side`, a window docked at another side moved
  to it, and a window docked at `side` back into the tiles, at the end of
  the list. -/
  | edge (side : Side)
  /-- A tiled or docked window floated, pinned and anchored to the frame,
  on top of the floats; and a float back into the tiles, at the end of the
  list. -/
  | float
  deriving DecidableEq, Repr

/-- Where a new window goes (`EditorState.openWindow`). -/
inductive WindowSpot where
  /-- After the last window of the tiled list: the stack, under
  master-and-stack. -/
  | stack
  /-- Docked at `side`, after the windows docked there. -/
  | edge (side : Side)
  /-- A float on top of the others, placed against `anchor`, of `share`,
  pinned or transient (`Editor/Floating.lean`). -/
  | float (anchor : Floating.Anchor) (share : Floating.Share) (pinned : Bool)
  /-- The only window of a new tab, right after the tab in view, under the
  layout config chose (`Frame.chosen`), or the default before any. -/
  | tab
  deriving DecidableEq, Repr

/-- A change of the frame's tabs (`EditorState.changeTab`). Indices are
from 0. -/
inductive TabChange where
  /-- The tab at `index` into view. -/
  | select (index : Nat)
  /-- The tab at `index` closed, with every window of it. -/
  | close (index : Nat)
  /-- The tab at `index` given `name`, or the generated one for none. -/
  | rename (index : Nat) (name : Option String)
  /-- The tab at `index` moved to the index `to`, clamped to the last. -/
  | move (index : Nat) (to : Nat)
  deriving DecidableEq, Repr

/-- Where a buffer is to be displayed (`EditorState.displaying`). -/
inductive Displaying where
  /-- A window of the frame already shows it: `view`. -/
  | shown (view : ViewId)
  /-- The existing window `view` is to show it. -/
  | showIn (view : ViewId)
  /-- A new window, at `spot`. -/
  | opened (spot : WindowSpot)
  deriving DecidableEq, Repr

/-- Why an operation on the layout was refused. -/
inductive LayoutRefusal where
  /-- It would remove the last window, leaving nothing to focus. -/
  | onlyWindow
  /-- The window is not one of the frame's windows. -/
  | noSuchWindow (id : ViewId)
  /-- The state has no buffer of this id for a window to show. -/
  | noSuchBuffer (id : BufferId)
  /-- A marker handed in for a window is not a marker of the text of the
  buffer the window is to show. -/
  | markersOfAnotherText
  /-- The operation is on the minibuffer's window, `view`, or would show the
  minibuffer's buffer in another window: that window is closed by answering
  or cancelling its prompt, and only it shows its buffer. -/
  | ofMinibuffer (view : ViewId)
  /-- No other window of the list was focused before the current one. -/
  | noPreviousWindow
  /-- The layout cannot grow or shrink the window along `axis`. -/
  | notResizable (axis : Axis)
  /-- The layout has no main windows: only master-and-stack does. -/
  | noMain
  /-- The layout is monocle, which config chose, and no zoom is there to
  leave. -/
  | monocleChosen
  /-- The layout has no edge at `side` to dock a window at. -/
  | noSuchEdge (side : Side)
  /-- The window is the last of the tiled list, which cannot move to an
  edge or float: a frame of docked and floating windows has no area to
  tile. -/
  | lastTile
  /-- The window `view` is docked at an edge, and cannot be the only
  window: the tiles would be gone. -/
  | atEdge (view : ViewId)
  /-- The window `view` floats: it has no tile to split or to move through
  the list, and a float is no anchor of another. -/
  | floating (view : ViewId)
  /-- It would close the last tab, leaving no window to show. -/
  | onlyTab
  /-- The frame has no tab at `index`, from 0. -/
  | noSuchTab (index : Nat)
  /-- It would change the tab in view while a prompt is open: the prompt's
  asker must stay a window of the tab in view. -/
  | promptOpen
  deriving DecidableEq, Repr

/-- What a refusal of the layout says, as one sentence the echo area can
show after a command's name. -/
def LayoutRefusal.describe : LayoutRefusal → String
  | .onlyWindow => "the last window cannot be closed"
  | .noSuchWindow id => s!"there is no window {id.index}"
  | .noSuchBuffer id => s!"there is no buffer {id.index}"
  | .markersOfAnotherText => "a marker is not of the text of the window's buffer"
  | .ofMinibuffer _ => "the minibuffer's window is closed by answering or cancelling its prompt"
  | .noPreviousWindow => "no other window was focused before this one"
  | .notResizable .rows => "the window cannot be made taller or shorter in this layout"
  | .notResizable .columns => "the window cannot be made wider or narrower in this layout"
  | .noMain => "only master-and-stack has main windows"
  | .monocleChosen => "the layout is monocle, and there is no zoom to leave"
  | .noSuchEdge side => Layout.noEdge side
  | .lastTile => "the last tiled window cannot leave the tiles"
  | .atEdge _ => "a window at an edge cannot be the only window"
  | .floating _ => "a floating window is not in the layout"
  | .onlyTab => "the last tab cannot be closed"
  | .noSuchTab index => s!"there is no tab {index + 1}"
  | .promptOpen => "the tab in view cannot change while a prompt is open"

/-- Why an operation on the prompt was refused. -/
inductive PromptRefusal where
  /-- A prompt is open already, in `view`: there is one at a time. -/
  | alreadyOpen (view : ViewId)
  /-- No prompt is open. -/
  | notOpen
  /-- The history or a marker handed in for the minibuffer is of another
  text than the minibuffer's. -/
  | notItsText
  /-- No window is focused for the prompt to be asked from. -/
  | noWindow
  /-- The prompt was asked with a completion source by name, and no source
  is registered under `name`. -/
  | noSuchSource (name : String)
  /-- The prompt was asked with a completion source that answers later, by
  the job registered under `name`, and no job is. -/
  | noSuchJob (name : String)
  deriving DecidableEq, Repr

/-- Why an operation on the prompt was refused, as a sentence for the echo
area. -/
def PromptRefusal.describe : PromptRefusal → String
  | .alreadyOpen _ => "a prompt is open already"
  | .notOpen => "no prompt is open"
  | .notItsText => "the minibuffer's history and markers are not of its text"
  | .noWindow => "no window is focused to ask from"
  | .noSuchSource name => s!"no completion source is registered under `{name}`"
  | .noSuchJob name => s!"no job is registered under `{name}` to answer a completion source"

/-- Why the sources of a prompt or a session at point could not be
asked. -/
inductive SourceRefusal where
  /-- No completion source is registered under `name`. -/
  | noSuchSource (name : String)
  /-- No job is registered under `name` to answer a source that answers
  later. -/
  | noSuchJob (name : String)
  deriving DecidableEq, Repr

/-- Why a source could not be asked, as a sentence for the echo area: what
`PromptRefusal.describe` says of the same refusal. -/
def SourceRefusal.describe : SourceRefusal → String
  | .noSuchSource name => s!"no completion source is registered under `{name}`"
  | .noSuchJob name => s!"no job is registered under `{name}` to answer a completion source"

/-- Why an operation on a session at point was refused. -/
inductive AtPointRefusal where
  /-- A prompt is open: a session opens only while none is. -/
  | promptOpen
  /-- A session is open already: there is one at a time. -/
  | alreadyOpen
  /-- The session's view has no window. -/
  | noWindow
  /-- No session is open. -/
  | notOpen
  /-- The at-point source `source` answered a region that does not hold the
  cursor, or whose ends are not positions of the text. -/
  | outside (source : String)
  /-- The sources the region is completed from could not be asked. -/
  | source (refusal : SourceRefusal)
  deriving DecidableEq, Repr

/-- Why an operation on a session at point was refused, as a sentence for
the echo area. -/
def AtPointRefusal.describe : AtPointRefusal → String
  | .promptOpen => "a prompt is open"
  | .alreadyOpen => "a completion at point is open already"
  | .noWindow => "no window is focused to complete in"
  | .notOpen => "no completion at point is open"
  | .outside name => s!"the at-point source `{name}` answered a region away from the cursor"
  | .source refusal => refusal.describe

/-- Why an operation on a buffer was refused. -/
inductive BufferRefusal where
  /-- The state has no buffer of this id. -/
  | noSuchBuffer (id : BufferId)
  /-- A buffer already has this name. -/
  | nameTaken (name : String)
  /-- This window shows the buffer. -/
  | shown (view : ViewId)
  /-- The undo tree is the history of another text than the buffer's. -/
  | notItsHistory
  /-- Another buffer, `other`, holds the file at this path. -/
  | fileOpen (other : BufferId)
  /-- The buffer shows no file. -/
  | noFile
  /-- A save of the buffer is in flight. -/
  | beingSaved
  /-- No save of the buffer is in flight, or the one that is writes another
  snapshot. -/
  | notBeingSaved
  /-- The buffer is not an excerpt buffer. -/
  | notExcerpts
  /-- The marker is of another text than the buffer's. -/
  | markerOfAnotherText
  /-- The source buffer `source` of an excerpt buffer's step is no longer in
  the state the step left it in: it was edited, or moved in its history,
  since. -/
  | sourceMoved (source : BufferId)
  /-- A source buffer of an excerpt buffer's step, called `name` when the
  step was recorded, has been removed since. -/
  | sourceRemoved (name : String)
  deriving DecidableEq, Repr

/-- Why a job was not started. -/
inductive JobRefusal where
  /-- No job is registered under this name. -/
  | noSuchJob (name : String)
  deriving DecidableEq, Repr

/-- Why a job was not started, as a sentence for the echo area. -/
def JobRefusal.describe : JobRefusal → String
  | .noSuchJob name => s!"no job is registered under {name}"

/-- Why a theme was not loaded. -/
inductive ThemeRefusal where
  /-- No theme is registered under this name. -/
  | noSuchTheme (name : String)
  deriving DecidableEq, Repr

/-- Why a theme was not loaded, as a sentence for the echo area
(`Theme.unknown`). -/
def ThemeRefusal.describe : ThemeRefusal → String
  | .noSuchTheme name => Theme.unknown name

/-- Why setting a mode was refused. -/
inductive ModeRefusal where
  /-- The state has no window of this view. -/
  | noSuchWindow (id : ViewId)
  /-- No mode is registered under this name. -/
  | noSuchMode (name : String)
  /-- The state has no buffer of this id. -/
  | noSuchBuffer (id : BufferId)
  deriving DecidableEq, Repr

namespace EditorState

/-- The window whose view is `id`, if there is one. -/
def window? (state : EditorState) (id : ViewId) : Option Window :=
  state.windows.find? (·.id == id)

/-- The buffer `id` names, if there is one: none for an id no buffer was
given, and for one whose buffer was removed. -/
def buffer? (state : EditorState) (id : BufferId) : Option Buffer :=
  state.buffers[id.index]?.join

/-- The window whose view is `id` and its buffer: what a handler acting on
that view is given. -/
def target? (state : EditorState) (id : ViewId) : Option Target := do
  let window ← state.window? id
  let buffer ← state.buffer? window.buffer
  return { window, buffer }

/-- The focused window and its buffer. -/
def focusedTarget? (state : EditorState) : Option Target :=
  state.target? state.frame.focused

/-- The minibuffer's view: the open prompt's, if a prompt is open. -/
def minibufferView? (state : EditorState) : Option ViewId :=
  state.prompt.map (·.view)

/-- The selected view: the open prompt's asker while a prompt is open, and
otherwise the focused one. It is the one the user is working in, so typing
into a prompt does not take it into the minibuffer. -/
def selectedView (state : EditorState) : ViewId :=
  match state.prompt with
  | some asking => asking.asker
  | none => state.frame.focused

/-- The window's title: the name of the selected view's buffer
(`selectedView`), which a buffer with no file has too (`scratch`); empty
when that view has no window, which a well-formed state rules out. -/
def title (state : EditorState) : String :=
  ((state.target? state.selectedView).map (·.buffer.name)).getD ""

/-- The label of the tab at `index`, from 0 (Vim's tab label, Emacs's
`tab-bar-tab-name-current`): the name it was given (`Tab.name`), or else
the name of its focused window's buffer. For the tab in view that is the
selected view's (`selectedView`), so an open prompt does not relabel it.
Empty for an index past the last. -/
def tabLabel (state : EditorState) (index : Nat) : String :=
  match state.frame.tabs[index]? with
  | none => ""
  | some tab =>
    match tab.name with
    | some name => name
    | none =>
      let view := if index == state.frame.tabIndex then state.selectedView else tab.focused
      ((state.target? view).map (·.buffer.name)).getD ""

/-- The minibuffer's buffer: the one the open prompt's window shows, if a
prompt is open. -/
def minibufferBuffer? (state : EditorState) : Option BufferId := do
  return (← state.window? (← state.minibufferView?)).buffer

/-- The views of the state: the frame's windows, the tiled list and then
the docked windows (`Frame.all`), then the minibuffer's view while a prompt
is open. -/
def views (state : EditorState) : Array ViewId :=
  state.frame.all ++ state.minibufferView?.toArray

/-- The key hints shown ("Key hints", in the module docs): the hints, when
they are due and neither a prompt nor a session at point is open, whose
place the candidate list is then; none otherwise. -/
def hinting? (state : EditorState) : Option KeyHintList :=
  if state.prompt.isSome || state.atPoint.isSome then none else state.keyHints.filter (·.due)

/-- The sheet the candidate list's view draws and the high-water mark of its
rows: the open prompt's, else the open session's, else the key hints'
shown (`hinting?`); none when none of them is. -/
def candidateSheet? (state : EditorState) : Option (Completion.Sheet × Nat) :=
  match state.prompt, state.atPoint with
  | some asked, _ => some (asked.sheet, asked.tallest)
  | none, some session => some (session.sheet, session.tallest)
  | none, none => state.hinting?.map fun hints => (hints.sheet, hints.tallest)

/-- `state` with its key hints due, when they are of `generation`: a delay
that fires for hints since closed, or for others, changes nothing. -/
def keyHintsDue (generation : Nat) (state : EditorState) : EditorState :=
  match state.keyHints with
  | some hints =>
    if hints.generation == generation then
      { state with keyHints := some { hints with due := true } }
    else state
  | none => state

/-- `state` with `candidates` as its key hints' listing, in order, with no
ranges, when they are due; as it was otherwise. -/
def listKeyHints (candidates : Array Completion.Candidate) (state : EditorState) : EditorState :=
  match state.keyHints with
  | some hints =>
    if hints.due then
      { state with
        keyHints := some { hints with listed := candidates.map (Completion.Listed.of ·) } }
    else state
  | none => state

/-- How many text rows the candidate list's part of the minibuffer's place
is: the high-water mark of what the list's view draws (`candidateSheet?`),
the open prompt's (`Prompt.tallest`), the session's or the key hints', the
most rows any sheet has shown since it opened, so it grows and never
shrinks while it is open; 0 with none. -/
def listRows (state : EditorState) : Nat :=
  (state.candidateSheet?.map (·.2)).getD 0

/-- How tall the minibuffer's strip at the frame's bottom is: the frame's
bottom row while no prompt is open, where the echo is drawn; and while one
is, the candidate list's rows (`listRows`), then a text row for the input,
then the bottom row, which holds the prompt (`heights`). -/
def minibufferPlace (state : EditorState) : Nat :=
  if state.prompt.isSome then
    state.listRows * state.heights.text + state.heights.text + state.heights.message
  else state.listRows * state.heights.text + state.heights.message

/-- How tall the tab bar's strip is: a text row while the bar is shown over
the frame's tabs (`TabBar.Shown.shows`), clamped to what the minibuffer's
strip leaves of the frame, and 0 while it is not shown. -/
def tabBarHeight (state : EditorState) : Nat :=
  if state.tabBarShown.shows state.frame.tabs.size then
    let height := state.frame.size.height
    min state.heights.text (height - min state.minibufferPlace height)
  else 0

/-- The frame cut in two: the area a layout tiles, and below it the
minibuffer's strip, `minibufferPlace` tall, or the whole frame when that
is shorter. While the tab bar is shown its strip (`tabBarHeight`) is cut
off the bottom of the tiled area, directly above the minibuffer's
(`tabBarRect?`). -/
def cutFrame (state : EditorState) : Rect × Rect :=
  let frame := state.frame
  let height := frame.size.height
  let (above, strip) :=
    Layout.cut .rows { x := 0, y := 0, width := frame.size.width, height }
      (height - min state.minibufferPlace height)
  ({ above with height := above.height - state.tabBarHeight }, strip)

/-- The minibuffer's strip (`cutFrame`) cut in two: the candidate list's
part on top, and below it the minibuffer's view's, the input and the bottom
row, `heights.text + heights.message` tall, or the whole strip when that is
shorter. So a frame too short for the strip cuts the list before the
input. -/
def cutStrip (state : EditorState) : Rect × Rect :=
  let strip := state.cutFrame.2
  let input := if state.prompt.isSome then state.heights.text else 0
  let below := min (input + state.heights.message) strip.height
  Layout.cut .rows strip (strip.height - below)

/-- The area of the frame a layout tiles: the frame above the tab bar's
strip and the minibuffer's (`cutFrame`). -/
def tiled (state : EditorState) : Rect :=
  state.cutFrame.1

/-- The tab bar's strip, directly above the minibuffer's, one text row tall
or what the frame leaves of it; none while the bar is not shown or the
frame leaves it no height. -/
def tabBarRect? (state : EditorState) : Option Rect :=
  let tiled := state.tiled
  let height := state.tabBarHeight
  if height == 0 then none
  else some { x := 0, y := tiled.y + tiled.height, width := tiled.width, height }

/-- The view monocle shows: the selected view (`selectedView`), and when
that is a float, the window it is anchored to, by `window` or `position`,
or for a float anchored to the frame the window focused before it
(`Frame.lastFocused`). So a float focused, or asked from, under monocle
keeps the window it floats over drawn, and a transient one anchored to it
is not closed for want of its anchor (`located`). -/
def monocleView (state : EditorState) : ViewId :=
  let frame := state.frame
  let selected := state.selectedView
  match frame.floating? selected with
  | some float => (float.anchor.view? <|> frame.lastFocused).getD selected
  | none => selected

/-- How wide the divider between two tiled windows is, in physical pixels:
one point on a display of scale 2. Lean handles no scale, and a scene's
rectangles are physical pixels, so it is a width in pixels
(`Layout.carve`). -/
def dividerWidth : Nat :=
  2

/-- The frame's tiled windows laid out by its layout in the tiled area
(`tiled`), monocle showing `monocleView`, with the dividers between them
taken out (`Layout.carve`): the carved tiles, and the dividers. -/
private def carved (state : EditorState) : Array (ViewId × Rect) × Array Rect :=
  let frame := state.frame
  Layout.carve state.tiled dividerWidth
    (frame.layout.place frame.windows state.monocleView state.tiled frame.docked)

/-- The rectangle of each view of the state in its frame, in drawing order:
the frame's windows laid out by its layout in the tiled area (`tiled`),
monocle showing the selected view, or a float's anchor window
(`monocleView`), each with the divider beyond it taken out (`carved`); then
each float in stacking order, placed in the tiled area against its anchor's
carved rectangle (`Floating.placed`) and not carved itself; and then, while
a prompt is open, the minibuffer's view in the lower part of the strip below
it (`cutStrip`). A window the
layout does not show has none. It is what a scene's views are laid out in
(`Loop.views`, `Editor/Loop.lean`). -/
def rects (state : EditorState) : Array (ViewId × Rect) :=
  let frame := state.frame
  let laid := state.carved.1
  laid ++ frame.floats.map (fun float => (float.view, float.placed state.tiled laid)) ++
    (state.minibufferView?.map (·, state.cutStrip.2)).toArray

/-- The dividers between the frame's tiled windows (`carved`), in the
frame's physical pixels: a strip `dividerWidth` wide beyond each tile whose
right edge or foot is short of the tiled area's. Floats and the
minibuffer's view have none. -/
def dividers (state : EditorState) : Array Rect :=
  state.carved.2

/-- How far the frame's bottom row, where the echo and a prompt are drawn,
is inset from the frame's left and right edges, in points: the frame
padding, and at least the window's corner clearance outside fullscreen, so
that its first glyph is clear of the rounded corner. In fullscreen the
window has square corners, so it is the padding alone, whatever the window
last said of its corners. -/
def bottomInset (state : EditorState) : Nat :=
  if state.frame.fullscreen then state.padding else max state.padding state.frame.corner

/-- How far down the window's title bar covers the frame, in points: what
the window last said outside fullscreen, and none in fullscreen, where no
title bar covers the content, whatever the window last said. -/
def topInset (state : EditorState) : Nat :=
  if state.frame.fullscreen then 0 else state.frame.top

/-- How tall the bottom row of the view `id` is: the frame's bottom row for
the minibuffer's view, which holds the prompt, and a window's status row
for any other (`heights`). A view's rows are asked with its height less
this (`Scroll.Area.ofRect`), which is what the display's frame shows. -/
def bottomRow (state : EditorState) (id : ViewId) : Nat :=
  if state.minibufferView? == some id then state.heights.message else state.heights.status

/-- The candidate list's strip: the upper part of the minibuffer's
(`cutStrip`), `listRows` text rows tall or what the frame leaves of it,
directly above the minibuffer's view, while a prompt, a session at point or
the key hints shown (`candidateSheet?`) have a list that has shown a row
(even when the current sheet has fewer rows, or none, and when it is 0
pixels tall); none otherwise. -/
def candidateListRect? (state : EditorState) : Option Rect :=
  if state.candidateSheet?.isSome && 0 < state.listRows then some state.cutStrip.1 else none

/-- Whether `id` is the tab bar's view (`tabBar`). -/
def isTabBar (state : EditorState) (id : ViewId) : Bool :=
  state.tabBar.any (·.view == id)

/-- Whether `id` is the candidate list's view (`candidateList`). -/
def isCandidateList (state : EditorState) (id : ViewId) : Bool :=
  state.candidateList.any (·.view == id)

/-- The rectangle of the view `id` in the frame (`rects`), the tab bar's
strip for its view (`tabBarRect?`), or the candidate list's for its view
(`candidateListRect?`); none for a view that is not laid out: one with no
window in the list, a window the layout does not show, the minibuffer's
when no prompt is open, the tab bar's while it is not shown, and the
candidate list's while no prompt, session or key hints shown have listed a
row. -/
def rect? (state : EditorState) (id : ViewId) : Option Rect :=
  (state.rects.find? (·.1 == id)).map (·.2) <|>
    if state.isTabBar id then state.tabBarRect?
    else if state.isCandidateList id then state.candidateListRect? else none

/-- The padding of the view `id`, in points ("The padding of the views", in
the module docs): the frame padding across and down for a window, with the
top inset (`topInset`) at the top of a window along the frame's top edge;
and for the minibuffer's view the bottom row's inset across
(`bottomInset`) and none down, since its place is exactly a text row and
the bottom row (`minibufferPlace`) and must stay that tall; and for the
tab bar's view the frame padding across and none down, since its strip is
exactly one text row; and for the candidate list's view the bottom row's
inset across, as the minibuffer's, and none down, since its strip is
exactly its rows. Each window has
its own: two windows side by side are each padded, with no gap of their own
between them. -/
def paddingOf (state : EditorState) (id : ViewId) : Padding :=
  if state.minibufferView? == some id || state.isCandidateList id then
    { across := state.bottomInset, down := 0 }
  else
    if state.isTabBar id then { across := state.padding, down := 0 }
    else
      let top := if (state.rect? id).any (·.y == 0) then state.topInset else 0
      let gutter :=
        if
            ((state.window? id).bind fun window =>
                (state.buffer? window.buffer).bind (·.gutter)).isSome then
          Buffer.Gutter.width
        else 0
      { across := state.padding, down := state.padding, top, gutter }

/-- Whether `place` is held by a marker of the text of an open buffer, or
is detached into a file: a place a state may hold. -/
def placeHolds (state : EditorState) (place : Place) : Bool :=
  match place with
  | .held buffer marker => (state.buffer? buffer).any (·.text == marker.text)
  | .file .. => true

/-- Whether the state keeps the layout invariants ("The window list, the
layout and their invariants" and "Tabs", in the module docs). For every tab
of the frame (`Frame.tabs`): its tiled list is not empty, its layout, and
the one a zoom returns to, fit that list (`Layout.fitted`), every docked
window's side is an edge of its layout out of a zoom (`Tab.underlying`,
`Layout.edgeSides`), and every float's anchor window is a tiled or docked
window of the same tab (`Tab.anchors`), a position anchor's marker of the
text of that window's buffer. The tab in view's focused window is one of
the state's views (`views`), and every other tab's is one of its own
windows (`Tab.contains`). The ids of every window of every tab
(`Frame.everyWindow`), then the open prompt's view, are distinct, are
exactly the windows' ids, and each window's buffer exists. And whether an
open prompt's choice, if it has one, is an index of its listing, whether
every buffer of the order they were used in (`recent`) is open and is there
once, whether the tab bar's view and the candidate list's, once drawn,
are no window's, and whether every place of a window's jumps and of the
global marks holds (`placeHolds`) and every buffer's marks are markers of
its own text. -/
def wellFormed (state : EditorState) : Bool :=
  let ids := state.frame.everyWindow ++ state.minibufferView?.toArray
  let fits (tab : Tab) : Bool :=
    let count := tab.windows.size
    0 < count && tab.layout.fitted count && tab.zoomedFrom.all (·.fitted count) &&
      tab.docked.all (fun (_, side) => tab.underlying.edgeSides.contains side) &&
      tab.floats.all fun float =>
        float.anchor.view?.all tab.anchors &&
          match float.anchor with
          | .position view marker => (state.target? view).any (·.buffer.text == marker.text)
          | _ => true
  state.frame.tabs.all fits &&
    (state.frame.tabsBefore ++ state.frame.tabsAfter).all (fun tab => tab.contains tab.focused) &&
    state.views.contains state.frame.focused &&
    ids.toList.eraseDups.length == ids.size &&
    ids.size == state.windows.size &&
    ids.all (fun id => (state.window? id).isSome) &&
    (state.windows.all fun window => (state.buffer? window.buffer).isSome) &&
    (state.prompt.all fun asked =>
      asked.candidates.chosen.all (· < asked.candidates.listed.size)) &&
    (state.atPoint.all fun session =>
      (state.window? session.view).isSome &&
        session.candidates.chosen.all (· < session.candidates.listed.size)) &&
    state.recent.all (fun id => (state.buffer? id).isSome) &&
    state.recent.toList.eraseDups.length == state.recent.size &&
    state.tabBar.all (fun drawn => (state.window? drawn.view).isNone) &&
    (state.candidateList.all fun drawn => (state.window? drawn.view).isNone) &&
    (state.windows.all fun window => window.jumps.places.all state.placeHolds) &&
    (state.remembered.globalMarks.all fun (_, place) => state.placeHolds place) &&
    state.buffers.all fun slot => slot.all fun buffer => buffer.marks.all (·.2.text == buffer.text)

/-- The name the editor gives its empty buffer with no file: the initial
state's buffer's, and the one left after the last buffer is closed
(`Editor/Buffers.lean`, "Close"). -/
def scratchName : String :=
  "scratch"

/-- `recent` with `id` first, and nowhere else. -/
def Recent.touch (recent : Array BufferId) (id : BufferId) : Array BufferId :=
  #[id] ++ recent.filter (· != id)

/-- A buffer called `scratch` (`scratchName`) over a new empty text, and one window on it,
focused, the only window of the frame's list, under the default layout, in
a frame of `size`. The
window's scroll anchor is at 0, and its selection one cursor at 0 of the
shape `shape`, exclusive unless the caller says another. -/
def initial (size : Size) (shape : Shape := .exclusive) : TextM EditorState := do
  let text ← createText ""
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩], shape })
  let history ← UndoTree.over text
  return {
      buffers := #[some { name := scratchName, text, history }]
      windows := #[{ id := ⟨0⟩, buffer := ⟨0⟩, scroll, selection }]
      frame := { size, windows := #[⟨0⟩], focused := ⟨0⟩ }
      recent := #[⟨0⟩] }

/-- The state with every transient float but `keep` closed: each leaves
`floats` and `windows`, its markers the caller's to give up. The focus is
the caller's. -/
def closeTransient (keep : ViewId) (state : EditorState) : EditorState :=
  let closing (float : Floating) : Bool := !float.pinned && float.view != keep
  { state with
    windows :=
      state.windows.filter fun window =>
        !state.frame.floats.any fun float => closing float && float.view == window.id
    frame := { state.frame with floats := state.frame.floats.filter (!closing ·) } }

/-- The state with the focus on `id` (`Frame.focusedOn`), and, when the focus
moves from one window of the frame to another (`Frame.contains`), every
transient float that is not `id` closed (`closeTransient`): the focus rule
("A floating window", in the module docs). Focusing the minibuffer's view
or leaving it is no move, so a prompt asked from a float keeps it. -/
def focusedOn (id : ViewId) (state : EditorState) : EditorState :=
  let frame := state.frame
  let moves := frame.focused != id && frame.contains frame.focused && frame.contains id
  let focused := { state with frame := frame.focusedOn id }
  if moves then focused.closeTransient id else focused

/-- The state with the floats `closing` closed: each leaves `floats` and
`windows`, its markers the caller's to give up. A focus on one of them goes
to the window focused before it while that is still in the frame, else to
main, and every other transient float closes with it (the focus rule). -/
def closeFloats (closing : Array ViewId) (state : EditorState) : EditorState :=
  if closing.isEmpty then state
  else
    let frame := state.frame
    let closed :=
      { state with
        windows := state.windows.filter (!closing.contains ·.id)
        frame := { frame with floats := frame.floats.filter (!closing.contains ·.view) } }
    if closing.contains frame.focused then
      let main := frame.windows[0]?.getD frame.focused
      let back :=
        match frame.lastFocused with
        | some last => if closed.frame.contains last then last else main
        | none => main
      { closed with frame := { closed.frame with focused := back } }.closeTransient back
    else closed

/-- The state once the anchors of the floats `anchored` picks went: those
that are transient close (`closeFloats`), and those that are pinned are
anchored to the frame, with no spot. Their anchor markers are the
caller's to give up. -/
def dropAnchors (anchored : Floating → Bool) (state : EditorState) : EditorState :=
  let floats :=
    state.frame.floats.map fun float =>
      if anchored float && float.pinned then
        { float with
          anchor := .frame, spot := none }
      else float
  let closing :=
    (state.frame.floats.filter fun float => anchored float && !float.pinned).map (·.view)
  { state with frame := { state.frame with floats } }.closeFloats closing

/-- The state once the window `id` is no anchor any more, because it left
the tiles and the edges (`removeWindow`, `arrange`'s `float`): the floats
anchored to it by `window` or `position` (`dropAnchors`). -/
def anchorGone (id : ViewId) (state : EditorState) : EditorState :=
  state.dropAnchors (·.anchor.view? == some id)

/-- Removes the window `id` from the frame, and hands it back, its markers
the caller's to give up.

- **A tiled window** leaves the list, and the layout gives its space to the
  rest (`Frame.removed`). A focused window's focus moves to the window that
  inherits its place when the layout says one, as manual splits do, and
  otherwise to the window that took its index, or to the new last window
  when it was last.
- **A docked window** leaves the edge, whose strip goes when no window is
  docked there; the layout is unchanged. A focused window's focus moves to
  the window of the same side that took its index, else to that side's new
  last window, else to the window focused before it while that is still in
  the frame (`Frame.lastFocused`), else to main.

- **A float** leaves the floats (`closeFloats`). A focused float's focus
  goes to the window focused before it while that is still in the frame,
  else to main.

When the focus moves off the window, every transient float but the one
now focused closes (the focus rule). The floats anchored to the window
close when transient and are anchored to the frame when pinned
(`anchorGone`).

Refused, with the state unchanged, with `ofMinibuffer` for the
minibuffer's window, with `noSuchWindow` for a window not in the frame and
with `onlyWindow` for the last one of the tiled list: neither the
minibuffer's window nor a docked window nor a float counts. -/
def removeWindow (id : ViewId) (state : EditorState) : Except LayoutRefusal Window × EditorState :=
  match removing with
  | (.ok window, after) =>
    let moved :=
      if state.frame.focused == id then after.closeTransient after.frame.focused else after
    (.ok window, moved.anchorGone id)
  | refused => refused
where
  /-- The window removed from the tiles or an edge, the focus moved off it
  by the layout's rule, or a float closed. -/
  removing : Except LayoutRefusal Window × EditorState :=
    let windows := state.frame.windows
    match state.minibufferView? == some id, state.window? id, windows.findIdx? (· == id),
      state.frame.sideOf? id with
    | true, _, _, _ => (.error (.ofMinibuffer id), state)
    | false, some window, none, none =>
      if (state.frame.floating? id).isSome then (.ok window, state.closeFloats #[id])
      else (.error (.noSuchWindow id), state)
    | false, some window, none, some side =>
      let frame := state.frame
      let ofSide := frame.atSide side
      let index := (ofSide.findIdx? (· == id)).getD 0
      let rest := ofSide.filter (· != id)
      let focused :=
        if frame.focused == id then
          match rest[index]? <|> rest.back? with
          | some view => view
          | none =>
            match frame.lastFocused with
            | some last => if last != id && frame.contains last then last else windows[0]?.getD id
            | none => windows[0]?.getD id
        else frame.focused
      (.ok window,
        { state with
          windows := state.windows.filter (·.id != id)
          frame :=
            { frame with
              docked := frame.docked.filter (·.1 != id), focused } })
    | false, some window, some index, _ =>
      let rest := windows.filter (· != id)
      if rest.isEmpty then (.error .onlyWindow, state)
      else
        let (frame, inheritor) := state.frame.removed index
        let focused :=
          if state.frame.focused == id then
            match inheritor.bind (rest[·]?) with
            | some view => view
            | none => rest[index]?.getD (rest.back?.getD state.frame.focused)
          else state.frame.focused
        (.ok window,
          { state with
            windows := state.windows.filter (·.id != id)
            frame :=
              { frame with
                windows := rest, focused } })
    | false, _, _, _ => (.error (.noSuchWindow id), state)

/-- The state with the buffer of the tab in view's focused window the most
recently used, unless that window has none. -/
def touchFocused (state : EditorState) : EditorState :=
  match state.window? state.frame.focused with
  | some window => { state with recent := Recent.touch state.recent window.buffer }
  | none => state

/-- The state with the tab at `index` in view, for an index of a tab that is
not the one in view: the tab left closes its transient floats (`closeFloats`,
the focus rule: their focus is lost), the zipper moves (`Frame.selected`),
and the buffer of the newly focused window becomes the most recently
used. -/
def selectTab (index : Nat) (state : EditorState) : EditorState :=
  let transient := (state.frame.floats.filter (!·.pinned)).map (·.view)
  let left := state.closeFloats transient
  { left with frame := left.frame.selected index }.touchFocused

/-- Makes `change` on the frame's tabs (`TabChange`):

- `select index` brings the tab at `index` into view (`selectTab`); the tab
  in view changes nothing.
- `close index` closes the tab at `index`: every window of it, tiled,
  docked or floating, leaves `windows`, its markers the caller's to give
  up, and its buffers stay. When it is the tab in view, the tab that takes
  its index comes into view, or the new last one when it was last, and its
  focused window's buffer becomes the most recently used.
- `rename index name` gives the tab `name`, or the generated one for none.
- `move index to` moves the tab to `to`, clamped to the last; the tab in
  view stays in view, wherever it now stands.

Refused, with the state unchanged, with `noSuchTab` for an index past the
last, with `onlyTab` for closing the last tab, and with `promptOpen` for
selecting another tab or closing the tab in view while a prompt is open:
the prompt's asker must stay a window of the tab in view. -/
def changeTab (change : TabChange) (state : EditorState) :
    Except LayoutRefusal Unit × EditorState :=
  let frame := state.frame
  let tabs := frame.tabs
  let current := frame.tabIndex
  match change with
  | .select index =>
    if tabs.size ≤ index then (.error (.noSuchTab index), state)
    else
      if index == current then (.ok (), state)
      else
        if state.prompt.isSome then (.error .promptOpen, state) else (.ok (), state.selectTab index)
  | .close index =>
    match tabs[index]? with
    | none => (.error (.noSuchTab index), state)
    | some closing =>
      if tabs.size == 1 then (.error .onlyTab, state)
      else
        if index == current && state.prompt.isSome then (.error .promptOpen, state)
        else
          let gone := closing.all
          let rest := tabs.eraseIdx! index
          let inView :=
            if index == current then min index (rest.size - 1)
            else if index < current then current - 1 else current
          let closed :=
            { state with
              windows := state.windows.filter (!gone.contains ·.id)
              frame := frame.withTabs rest inView }
          (.ok (), if index == current then closed.touchFocused else closed)
  | .rename index name =>
    match tabs[index]? with
    | none => (.error (.noSuchTab index), state)
    | some tab =>
      (.ok (), { state with frame := frame.withTabs (tabs.set! index { tab with name }) current })
  | .move index to =>
    if tabs.size ≤ index then (.error (.noSuchTab index), state)
    else
      let order := ((List.range tabs.size).erase index).insertIdx (min to (tabs.size - 1)) index
      let moved := order.toArray.filterMap (tabs[·]?)
      let inView := (order.findIdx? (· == current)).getD current
      (.ok (), { state with frame := frame.withTabs moved inView })

/-- Focuses the window `id`: a window of the tab in view, or the minibuffer's
while a prompt is open (`focusedOn`, which keeps the window of the tab
focused before it, and closes the transient floats the focus leaves); or a
window of a hidden tab, whose tab is then selected (`selectTab`) before the
window is focused within it, as Vim's `win_gotoid` switches tab pages. Its
buffer is then the most recently used, unless it is the minibuffer's.
Refused, with the state unchanged, with `promptOpen` for a hidden tab's
window while a prompt is open, and with `noSuchWindow` for any other. -/
def focusWindow (id : ViewId) (state : EditorState) : Except LayoutRefusal Unit × EditorState :=
  if state.views.contains id then (.ok (), focusing state)
  else
    match state.frame.tabOf? id with
    | some index =>
      if state.prompt.isSome then (.error .promptOpen, state)
      else (.ok (), focusing (state.selectTab index))
    | none => (.error (.noSuchWindow id), state)
where
  /-- `state`, of which `id` is a view, with the focus on `id`. -/
  focusing (state : EditorState) : EditorState :=
    let recent :=
      match state.window? id with
      | some window =>
        if state.minibufferBuffer? == some window.buffer then state.recent
        else Recent.touch state.recent window.buffer
      | none => state.recent
    { state.focusedOn id with recent }

/-- Has the window `id` keep `wanted` as its wanted column, or none. Any
window is taken, the minibuffer's among them. Refused, with the state
unchanged, with `noSuchWindow` for a view with no window. -/
def setWanted (id : ViewId) (wanted : Option Window.Wanted) (state : EditorState) :
    Except LayoutRefusal Unit × EditorState :=
  if (state.window? id).isNone then (.error (.noSuchWindow id), state)
  else
    (.ok (),
      { state with
        windows :=
          state.windows.map fun window =>
            if window.id == id then { window with wanted } else window })

/-- Has the window `id` keep `jumps` as its jump list and previous-context
mark ("The jump list and marks", in the module docs). Refused, with the
state unchanged, with `noSuchWindow` for a view with no window, with
`noSuchBuffer` for a place held in a buffer there is none of, and with
`markersOfAnotherText` for a place whose marker is not of its buffer's
text. -/
def setJumps (id : ViewId) (jumps : Jumps) (state : EditorState) :
    Except LayoutRefusal Unit × EditorState :=
  let unheld :=
    jumps.places.findSome? fun place =>
      match place with
      | .held buffer marker =>
        match state.buffer? buffer with
        | none => some (LayoutRefusal.noSuchBuffer buffer)
        | some shown => if shown.text == marker.text then none else some .markersOfAnotherText
      | .file .. => none
  if (state.window? id).isNone then (.error (.noSuchWindow id), state)
  else
    match unheld with
    | some refusal => (.error refusal, state)
    | none =>
      (.ok (),
        { state with
          windows :=
            state.windows.map fun window =>
              if window.id == id then { window with jumps } else window })

/-- `state` with the buffer `id` changed by `change`, and what `change`
said. Refused, with the state unchanged, with `noSuchBuffer` for a buffer
there is none of. -/
private def changeBuffer {α : Type} (id : BufferId) (change : Buffer → α × Buffer)
    (state : EditorState) : Except BufferRefusal α × EditorState :=
  match state.buffer? id with
  | some buffer =>
    let (said, changed) := change buffer
    (.ok said, { state with buffers := state.buffers.set! id.index (some changed) })
  | none => (.error (.noSuchBuffer id), state)

/-- Makes the mode `name` the major mode of the buffer `id`, and says
whether it became the major mode: `false`, with nothing changed, when the
buffer already had it. Any name is taken. Refused, with the state
unchanged, with `noSuchBuffer` for a buffer there is none of. -/
def setMajorMode (id : BufferId) (name : String) (state : EditorState) :
    Except BufferRefusal Bool × EditorState :=
  changeBuffer id
    (fun buffer =>
      if buffer.major == some name then (false, buffer)
      else (true, { buffer with major := some name }))
    state

/-- Records `name` as the language of the buffer `id`, or, with `none`,
that it has none. Any name is taken. Refused, with the state unchanged,
with `noSuchBuffer` for a buffer there is none of. -/
def setLanguage (id : BufferId) (name : Option String) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  changeBuffer id (fun buffer => ((), { buffer with language := name })) state

/-- Adds the minor mode `name` to the buffer `id`, first; a minor mode the
buffer already has changes nothing. Refused, with the state unchanged,
with `noSuchBuffer` for a buffer there is none of. -/
def addMinorMode (id : BufferId) (name : String) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  changeBuffer id
    (fun buffer =>
      if buffer.minors.contains name then ((), buffer)
      else ((), { buffer with minors := #[name] ++ buffer.minors }))
    state

/-- Removes the minor mode `name` from the buffer `id`; one the buffer does
not have changes nothing. Refused, with the state unchanged, with
`noSuchBuffer` for a buffer there is none of. -/
def removeMinorMode (id : BufferId) (name : String) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  changeBuffer id (fun buffer => ((), { buffer with minors := buffer.minors.filter (· != name) }))
    state

/-- The first buffer with unsaved changes, in the order of the slots, if
there is one (`Buffer.unsaved`). -/
def unsaved (state : EditorState) : Option Buffer :=
  (state.buffers.find? fun slot => slot.any (·.unsaved)).join

/-- Whether a save of a buffer is in flight (`Buffer.File.saving`). -/
def isSaving (state : EditorState) : Bool :=
  state.buffers.any fun slot => slot.any (·.file.any (·.saving.isSome))

/-- Whether the editor leaves ("Quit", in the module docs): a command asked
it to quit, no buffer has unsaved changes, and no save is in flight. -/
def leaves (state : EditorState) : Bool :=
  state.quitting && state.unsaved.isNone && !state.isSaving

/-- `state` with a quit that cannot go ahead withdrawn: asked to quit while
a buffer has unsaved changes, it is no longer asked. Any other state is as
it was. -/
def settleQuit (state : EditorState) : EditorState :=
  if state.quitting && state.unsaved.isSome then { state with quitting := false } else state

/-- Whether the system's quit is to be answered now, and `state` with it
answered ("Quit", in the module docs): when the system asked and the editor
is not asked to quit, the quit was refused or withdrawn, so the answer is
to keep running, `true`, and the system's quit is no longer pending. While
the editor is asked to quit, it is waiting or leaving, and nothing is
answered yet. With no system quit pending nothing is answered. -/
def answerSystemQuit (state : EditorState) : EditorState × Bool :=
  if state.systemQuit && !state.quitting then ({ state with systemQuit := false }, true)
  else (state, false)

/-- An editor with no buffer and no window, in a frame of no size whose list
is empty. It is not well formed: nothing is focused.
It is what a command's state requests are answered from where no loop runs
the command. -/
protected def none : EditorState :=
  { buffers := #[], windows := #[], frame := { size := ⟨0, 0⟩, windows := #[], focused := ⟨0⟩ } }

/-- The first buffer of the order buffers were used in (`recent`) that is
open and is neither `except` nor the minibuffer's, and failing that the
first such buffer in the order of the slots; `none` when no other buffer is
open ("Most recently used", in the module docs). -/
def mostRecent (state : EditorState) (except : BufferId) : Option BufferId :=
  let other (id : BufferId) : Bool :=
    id != except && (state.buffer? id).isSome && state.minibufferBuffer? != some id
  match state.recent.find? other with
  | some id => some id
  | none => ((List.range state.buffers.size).map (⟨·⟩)).find? other

/-- The open buffers but the minibuffer's: those of the order they were used
in (`recent`) first, in that order, and then the rest in the order of the
slots ("Most recently used", in the module docs). -/
def openBuffers (state : EditorState) : Array BufferId :=
  let open? (id : BufferId) : Bool :=
    (state.buffer? id).isSome && state.minibufferBuffer? != some id
  let first := state.recent.filter open?
  first ++
    ((List.range state.buffers.size).map (⟨·⟩) |>.filter fun id =>
        open? id && !first.contains id).toArray

/-- The buffer called `name`, if there is one. Names are unique among the
buffers a request added (`addBuffer`), so there is at most one. -/
def findBuffer (state : EditorState) (name : String) : Option BufferId :=
  (state.buffers.findIdx? fun slot => slot.any (·.name == name)).map (⟨·⟩)

/-- The buffer that holds the file at `path`, if one does: the one whose
file's path is equal to it, as a string. A request attaches a path to one
buffer only (`attachFile`), so there is at most one. -/
def findFile (state : EditorState) (path : System.FilePath) : Option BufferId :=
  (state.buffers.findIdx? fun slot => slot.any (·.file.any (·.path == path))).map (⟨·⟩)

/-- A name no buffer has, for a new buffer that would be called `name`: the
name itself, or the name followed by `<2>`, `<3>` and so on, the first no
buffer has. With `n` buffers one of the first `n + 1` candidates is free. -/
def freeName (state : EditorState) (name : String) : String :=
  let free (candidate : String) : Bool := (state.findBuffer candidate).isNone
  if free name then name
  else
    (((List.range (state.buffers.size + 1)).map fun index => s!"{name}<{index + 2}>").find?
          free).getD
      name

/-- Has the buffer `id` hold the file at `path`, whose stamp is `stamp`,
and gives it the line ending `ending`. Its history is left as it is.
Refused, with the state unchanged, with `noSuchBuffer` for a buffer there
is none of, and with `fileOpen`, and the buffer that holds it, for a path
another buffer holds. -/
def attachFile (id : BufferId) (path : System.FilePath) (stamp : File.Stamp)
    (ending : File.LineEnding) (state : EditorState) : Except BufferRefusal Unit × EditorState :=
  match state.buffer? id, state.findFile path with
  | none, _ => (.error (.noSuchBuffer id), state)
  | some _, some holder => if holder == id then attached else (.error (.fileOpen holder), state)
  | some _, none => attached
where
  /-- The state with the file attached. -/
  attached : Except BufferRefusal Unit × EditorState :=
    changeBuffer id
      (fun buffer =>
        ((),
          { buffer with
            file := some { path, stamp }, lineEnding := ending }))
      state

/-- Records a save of the buffer `id` as in flight: it writes `snapshot`,
which was taken with the buffer's text in the state `saved`. Refused, with
the state unchanged, with `noSuchBuffer` for a buffer there is none of,
with `noFile` for a buffer that shows no file, and with `beingSaved` while
a save of it is in flight. -/
def beginSave (id : BufferId) (snapshot : SnapshotId) (saved : UndoTree.State)
    (state : EditorState) : Except BufferRefusal Unit × EditorState :=
  match state.buffer? id with
  | none => (.error (.noSuchBuffer id), state)
  | some buffer =>
    match buffer.file with
    | none => (.error .noFile, state)
    | some file =>
      if file.saving.isSome then (.error .beingSaved, state)
      else
        changeBuffer id
          (fun buffer =>
            ((),
              { buffer with
                file := some { file with saving := some { snapshot, state := saved } } }))
          state

/-- Ends the save of the buffer `id` that writes `snapshot`: the save is no
longer in flight. With the stamp of the file it wrote, the buffer's file
has that stamp, and the state the save kept is the one marked as saved in
the buffer's history (`UndoTree.markSaved`), wherever the text is by now.
With `none`, for a save that was refused, neither changes, and the state
is no longer asked to quit ("Quit", in the module docs). Refused, with
the state unchanged, with `noSuchBuffer` for a buffer there is none of, and
with `notBeingSaved` unless a save of the buffer that writes `snapshot` is
in flight. -/
def endSave (id : BufferId) (snapshot : SnapshotId) (stamp : Option File.Stamp)
    (state : EditorState) : Except BufferRefusal Unit × EditorState :=
  match state.buffer? id with
  | none => (.error (.noSuchBuffer id), state)
  | some buffer =>
    match buffer.file with
    | none => (.error .notBeingSaved, state)
    | some file =>
      match file.saving with
      | none => (.error .notBeingSaved, state)
      | some saving =>
        if saving.snapshot != snapshot then (.error .notBeingSaved, state)
        else
          let ended : Buffer :=
            match stamp with
            | some stamp =>
              { buffer with
                file :=
                  some
                    { file with
                      stamp, saving := none, changed := none }
                history := buffer.history.markSaved saving.state }
            | none => { buffer with file := some { file with saving := none } }
          -- A save that was refused wrote nothing: a quit that waited for
          -- it is withdrawn ("Quit", in the module docs).
          let state := if stamp.isNone then { state with quitting := false } else state
          changeBuffer id (fun _ => ((), ended)) state

/-- Records what a check of the buffer `id`'s file found ("A buffer's file",
in the module docs): `found` is the file's stamp now, `none` for a file that
is gone, and `told` whether the user was told. It applies only while the
buffer holds a file whose stamp is still `stamp`, the one recorded when the
check was asked for, so a result a save or a reload has overtaken changes
nothing. With `found = some stamp` the mark is cleared; otherwise the mark
holds `found`, in place of what it held, and is told when `told` is, or when
it was told already of that same `found`. Refused only with `noSuchBuffer`;
a buffer with no file or another stamp is left as it is. -/
def markChanged (id : BufferId) (stamp : File.Stamp) (found : Option File.Stamp) (told : Bool)
    (state : EditorState) : Except BufferRefusal Unit × EditorState :=
  match state.buffer? id with
  | none => (.error (.noSuchBuffer id), state)
  | some buffer =>
    match buffer.file with
    | some file =>
      if file.stamp != stamp then (.ok (), state)
      else
        let changed : Option Buffer.Changed :=
          if found == some stamp then none
          else
            let already := file.changed.any fun was => was.found == found && was.told
            some { found, told := told || already }
        changeBuffer id (fun buffer => ((), { buffer with file := some { file with changed } }))
          state
    | none => (.ok (), state)

/-- Marks the change on disk of the buffer `id`'s file as told: the next edit
lands ("A buffer's file", in the module docs). A buffer whose file is not
marked is left as it is. Refused only with `noSuchBuffer`. -/
def tellChanged (id : BufferId) (state : EditorState) : Except BufferRefusal Unit × EditorState :=
  match state.buffer? id with
  | none => (.error (.noSuchBuffer id), state)
  | some buffer =>
    match buffer.file with
    | some file =>
      match file.changed with
      | some changed =>
        changeBuffer id
          (fun buffer =>
            ((),
              { buffer with
                file := some { file with changed := some { changed with told := true } } }))
          state
      | none => (.ok (), state)
    | none => (.ok (), state)

/-- The buffer over the text `text` whose file changed on disk and the user
was not yet told of it, with the file's path and what was found, `none` for
a file that is gone: what refuses the first edit of that text. -/
def untold? (state : EditorState) (text : TextId) :
    Option (BufferId × System.FilePath × Option File.Stamp) :=
  (List.range state.buffers.size).findSome? fun index =>
    match state.buffer? ⟨index⟩ with
    | some buffer =>
      if buffer.text != text then none
      else
        match buffer.file with
        | some { path, changed := some { found, told := false }, .. } => some (⟨index⟩, path, found)
        | _ => none
    | none => none

/-- Makes the buffer `id` read-only to editing commands, or not, as `on`
says. Refused, with the state unchanged, with `noSuchBuffer` for a buffer
there is none of. -/
def setReadOnly (id : BufferId) (on : Bool) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  changeBuffer id (fun buffer => ((), { buffer with readOnly := on })) state

/-- Sets the spans of the buffer `id` to `spans`, in place of those it had
("Buffers", in the module docs). Refused, with the state unchanged, with
`noSuchBuffer` for a buffer there is none of. -/
def setSpans (id : BufferId) (spans : Array Decoration) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  changeBuffer id (fun buffer => ((), { buffer with spans })) state

/-- The state once `change` is told ("The version-control gutter",
`Editor/VersionControl/Gutter.lean`): a head that arrived for the latest
fetch is held and the next publish diffs against it; a diff that arrived
for the latest head clears the one in flight and records its revision; a
repository that moved makes its tracked buffers stale; and a refused watch
is recorded. A change of another epoch changes nothing. -/
def changeGutter (change : GutterChange) (state : EditorState) : EditorState :=
  match change with
  | .held buffer epoch head =>
    { state with
      tracked :=
        state.tracked.map fun entry =>
          if entry.buffer == buffer && entry.epoch == epoch then
            { entry with
              head, fetching := false, diffed := none }
          else entry }
  | .diffed buffer epoch revision =>
    { state with
      tracked :=
        state.tracked.map fun entry =>
          if entry.buffer == buffer then
            { entry with
              diffing := none
              diffed := if entry.epoch == epoch then some revision else entry.diffed }
          else entry }
  | .moved root =>
    { state with
      tracked :=
        state.tracked.map fun entry =>
          if entry.root == root then { entry with stale := true } else entry }
  | .refused root =>
    { state with
      refWatches :=
        state.refWatches.map fun watch =>
          if watch.root == root then { watch with refused := true } else watch }

/-- Sets the gutter of the buffer `id`, or takes it away with `none`
("Buffers", in the module docs). Refused with `noSuchBuffer` for a buffer
there is none of. -/
def setGutter (id : BufferId) (gutter : Option Buffer.Gutter) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  changeBuffer id (fun buffer => ((), { buffer with gutter })) state

/-- The buffer over the text `text` that is read-only, with its name: what
refuses an edit of that text ("Buffers", in the module docs). -/
def readOnly? (state : EditorState) (text : TextId) : Option (BufferId × String) :=
  (List.range state.buffers.size).findSome? fun index =>
    match state.buffer? ⟨index⟩ with
    | some buffer =>
      if buffer.text == text && buffer.readOnly then some (⟨index⟩, buffer.name) else none
    | none => none

/-- What is said of an edit refused because the buffer called `name` is
read-only. -/
def readOnlyReason (name : String) : String :=
  s!"{name} is read-only"

/-- What is said of an edit through the excerpt buffer called `name` refused
because it reaches a text no buffer holds. -/
def unheldReason (name : String) : String :=
  s!"{name} reads a text no buffer holds"

/-- The excerpt buffer over the text `text`, if there is one ("Excerpt
buffers", in the module docs). -/
def excerptBufferOver? (state : EditorState) (text : TextId) : Option BufferId :=
  (List.range state.buffers.size).findSome? fun index =>
    match state.buffer? ⟨index⟩ with
    | some buffer => if buffer.text == text && buffer.excerpts.isSome then some ⟨index⟩ else none
    | none => none

/-- The buffer over the text `text` that is not an excerpt buffer, if there
is one: the buffer of a source of an excerpt text. -/
def bufferOver? (state : EditorState) (text : TextId) : Option BufferId :=
  (List.range state.buffers.size).findSome? fun index =>
    match state.buffer? ⟨index⟩ with
    | some buffer => if buffer.text == text && buffer.excerpts.isNone then some ⟨index⟩ else none
    | none => none

/-- `state` with each of `sources` among the source buffers the excerpt
buffer `id` has touched since its last step, each once. Nothing changes for
a buffer that is not an excerpt buffer. -/
def touch (id : BufferId) (sources : Array BufferId) (state : EditorState) : EditorState :=
  match state.buffer? id with
  | some buffer@{ excerpts := some excerpts, .. } =>
    let touched :=
      sources.foldl
        (fun touched source => if touched.contains source then touched else touched.push source)
        excerpts.touched
    { state with
      buffers :=
        state.buffers.set! id.index
          (some { buffer with excerpts := some { excerpts with touched } }) }
  | _ => state

/-- `state` with the excerpt buffer `id`'s touched sources made one step:
when it touched any, a step of each touched buffer's name and undo tree's
state is pushed, `touched` is cleared and the steps to redo are emptied. It
is pure: the source buffers' trees were told and closed already. Nothing
changes for a buffer that is not an excerpt buffer, nor for one that
touched nothing. -/
def closeExcerptGroup (id : BufferId) (state : EditorState) : EditorState :=
  match state.buffer? id with
  | some buffer@{ excerpts := some excerpts, .. } =>
    if excerpts.touched.isEmpty then state
    else
      let sources :=
        excerpts.touched.filterMap fun source =>
          (state.buffer? source).map fun touched =>
            { buffer := source, name := touched.name, state := touched.history.state }
      let excerpts :=
        { excerpts with
          touched := #[], undos := excerpts.undos.push ⟨sources⟩, redos := #[] }
      { state with
        buffers := state.buffers.set! id.index (some { buffer with excerpts := some excerpts }) }
  | _ => state

/-- `state` with `change` made to what was viewed of each tracked entry of
the excerpt buffer `id` among `indices`. An entry that is not tracked, an
index past the entries and a buffer that is not an excerpt buffer change
nothing. -/
def changeViewed (id : BufferId) (indices : Array Nat) (change : Buffer.Viewed → Buffer.Viewed)
    (state : EditorState) : EditorState :=
  match state.buffer? id with
  | some buffer@{ excerpts := some excerpts, .. } =>
    let entries :=
      excerpts.entries.mapIdx fun index entry =>
        if indices.contains index then { entry with viewed := entry.viewed.map change } else entry
    { state with
      buffers :=
        state.buffers.set! id.index
          (some { buffer with excerpts := some { excerpts with entries } }) }
  | _ => state

/-- `state` with each tracked entry of the excerpt buffer `id` among
`indices` shown by one more scene, first at `now` when no scene showed it
before ("Excerpt buffers", in the module docs). -/
def markViewed (id : BufferId) (indices : Array Nat) (now : Nat) (state : EditorState) :
    EditorState :=
  state.changeViewed id indices fun viewed =>
    { viewed with
      scenes := viewed.scenes + 1, firstAt := viewed.firstAt <|> some now }

/-- `state` with `elapsed` milliseconds more on screen for each tracked entry
of the excerpt buffer `id` among `indices` ("Excerpt buffers", in the module
docs). -/
def creditViewed (id : BufferId) (indices : Array Nat) (elapsed : Nat) (state : EditorState) :
    EditorState :=
  state.changeViewed id indices fun viewed => { viewed with shownFor := viewed.shownFor + elapsed }

/-- Makes `excerpts` what the excerpt buffer `id` keeps of its edits.
Refused, with the state unchanged, with `noSuchBuffer` for a buffer there
is none of, and with `notExcerpts` for one that is not an excerpt buffer. -/
def setExcerptHistory (id : BufferId) (excerpts : Buffer.Excerpts) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  match state.buffer? id with
  | none => (.error (.noSuchBuffer id), state)
  | some buffer =>
    if buffer.excerpts.isNone then (.error .notExcerpts, state)
    else changeBuffer id (fun buffer => ((), { buffer with excerpts := some excerpts })) state

/-- The register kept under `name`, if one was set under it. -/
def register? (state : EditorState) (name : String) : Option Register :=
  (state.remembered.registers.find? (·.1 == name)).map (·.2)

/-- `state` with `register` kept under `name`, in place of the register the
name had, where that one was; a name nothing was set under is added
last. Nothing else changes, and it is never refused: a name is any
string. -/
def setRegister (name : String) (register : Register) (state : EditorState) : EditorState :=
  let registers := state.remembered.registers
  { state with
    remembered.registers :=
      if registers.any (·.1 == name) then
        registers.map fun entry => if entry.1 == name then (name, register) else entry
      else registers.push (name, register) }

/-- The last character find, if one was made: what `;` and `,` repeat ("The
last find", in the module docs). -/
def lastFind (state : EditorState) : Option Find :=
  state.remembered.lastFind

/-- The last search, if one was made: what `n` and `N` repeat ("The last
search", in the module docs). -/
def lastSearch (state : EditorState) : Option Search :=
  state.remembered.lastSearch

/-- `state` with `find` as its last character find, in place of the one it
had ("The last find", in the module docs). Nothing else changes, and it is
never refused. -/
def setLastFind (find : Find) (state : EditorState) : EditorState :=
  { state with remembered.lastFind := some find }

/-- `state` with `search` as its last search, in place of the one it had
("The last search", in the module docs). Nothing else changes, and it is
never refused. -/
def setLastSearch (search : Search) (state : EditorState) : EditorState :=
  { state with remembered.lastSearch := some search }

/-- The marker the buffer `id` holds its mark `char` by, if it has that
mark ("The jump list and marks", in the module docs). -/
def localMark? (state : EditorState) (id : BufferId) (char : Char) : Option MarkerId := do
  let buffer ← state.buffer? id
  (buffer.marks.find? (·.1 == char)).map (·.2)

/-- The place of the global mark `char`, if it is set ("The jump list and
marks", in the module docs). -/
def globalMark? (state : EditorState) (char : Char) : Option Place :=
  (state.remembered.globalMarks.find? (·.1 == char)).map (·.2)

/-- `marks` with `char` held by `value` in place of what it had, or without
`char` for none. -/
private def setMarkIn {α : Type} (marks : Array (Char × α)) (char : Char) (value : Option α) :
    Array (Char × α) :=
  let others := marks.filter (·.1 != char)
  match value with
  | some held =>
    if marks.any (·.1 == char) then
      marks.filterMap fun (kept, was) =>
        if kept == char then some (char, held) else some (kept, was)
    else others.push (char, held)
  | none => others

/-- Has the buffer `id` hold its mark `char` by `marker`, in place of the
marker it had, or no longer hold it for none ("The jump list and marks", in
the module docs). The marker it had is the loop's to give up. Refused, with
the state unchanged, with `noSuchBuffer` for a buffer there is none of, and
with `markerOfAnotherText` for a marker of another text than the
buffer's. -/
def setLocalMark (id : BufferId) (char : Char) (marker : Option MarkerId) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  match state.buffer? id with
  | none => (.error (.noSuchBuffer id), state)
  | some buffer =>
    if marker.any (·.text != buffer.text) then (.error .markerOfAnotherText, state)
    else
      (.ok (),
        { state with
          buffers :=
            state.buffers.set! id.index
              (some { buffer with marks := setMarkIn buffer.marks char marker }) })

/-- Has the buffer `id` keep `history` beside its marks
(`Buffer.markHistory`), in place of what it kept. Refused, with the state
unchanged, with `noSuchBuffer` for a buffer there is none of. -/
def setMarkHistory (id : BufferId) (history : Marks.History) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  changeBuffer id (fun buffer => ((), { buffer with markHistory := history })) state

/-- Sets the global mark `char` at `place`, in place of the place it had,
or unsets it for none ("The jump list and marks", in the module docs).
Refused, with the state unchanged, with `noSuchBuffer` for a place held in
a buffer there is none of, and with `markerOfAnotherText` for a place whose
marker is not of its buffer's text. -/
def setGlobalMark (char : Char) (place : Option Place) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  match place with
  | some (.held buffer marker) =>
    match state.buffer? buffer with
    | none => (.error (.noSuchBuffer buffer), state)
    | some held =>
      if held.text != marker.text then (.error .markerOfAnotherText, state)
      else
        (.ok (),
          { state with
            remembered.globalMarks := setMarkIn state.remembered.globalMarks char place })
  | _ =>
    (.ok (),
      { state with remembered.globalMarks := setMarkIn state.remembered.globalMarks char place })

/-- Every marker a place of `state` is held by: those of each window's jump
list and previous-context mark, of each buffer's marks and of the global
marks, each once. The loop gives up those of the state from before a
command that the state after holds none of (`Loop.gaveUp`). -/
def placeMarkers (state : EditorState) : Array MarkerId :=
  let all :=
    state.windows.flatMap (fun window => window.jumps.places.filterMap (·.marker?)) ++
      state.buffers.flatMap
        (fun slot => (slot.map fun buffer => buffer.marks.map (·.2)).getD #[]) ++
      state.remembered.globalMarks.filterMap (·.2.marker?)
  all.foldl (fun once id => if once.contains id then once else once.push id) #[]

/-- Gives up each marker a place of `before` is held by that no place of
`after` holds (`placeMarkers`): the one rule by which place markers are
released, at the end of a command (`Loop.gaveUp`) and when a publish erases
or replaces marks (`EditorState.followMarks`). It is not refused: the first
refusal is handed back, and the rest are still given up. -/
def givenUpPlaces (before after : EditorState) : TextM (Option TextError) := do
  let mut refusal := none
  let placed := after.placeMarkers
  for id in before.placeMarkers do
    unless placed.contains id do
      if let .error error← observing (id.text.unmark id) then
        refusal := refusal <|> some error
  return refusal

/-- `state` with `rows` as its scroll margin, in place of the one it had
("The scroll margin", in the module docs). Nothing else changes, and it is
never refused. -/
def setScrollMargin (rows : Nat) (state : EditorState) : EditorState :=
  { state with scrollMargin := rows }

/-- The value the buffer `id` keeps under `name`, if it keeps one. -/
def value? (state : EditorState) (id : BufferId) (name : String) : Option Value := do
  let buffer ← state.buffer? id
  (← buffer.locals.find? (·.1 == name)).2

/-- The workspace of the buffer `id`, and its project, as the table has
them: the workspace at the location its buffer-local value names
("Workspaces", in the module docs). -/
def workspaceOf? (state : EditorState) (id : BufferId) : Option (Workspace × Project) := do
  let location ← Location.decode? (← state.value? id Workspace.bufferLocal)
  let workspace ← state.workspaces.workspace? location
  return (workspace, (← state.workspaces.project? workspace.project.identity))

/-- Where a command run for the buffer `id` runs ("Workspaces", in the module
docs): its workspace's root on this machine, its workspace's location when
that is elsewhere, the directory of its file, with no separator at its end,
when it has no workspace, or none. -/
def workingDirectoryOf (state : EditorState) (id : BufferId) : Workspace.WorkingDirectory :=
  match state.workspaceOf? id with
  | some (workspace, _) =>
    match workspace.location with
    | .local root => .workspace root
    | location => .elsewhere location
  | none =>
    match ((state.buffer? id).bind (·.file)).bind (·.path.parent) with
    | some directory => .fileDirectory (Process.trimmed directory)
    | none => .none

/-- The directory on this machine a command run for the buffer `id` runs in
("Workspaces", in the module docs): `workingDirectoryOf`'s root or file
directory, else, for a workspace elsewhere and for none, the editor's working
directory. -/
def commandDirectoryOf (state : EditorState) (id : BufferId) : System.FilePath :=
  match state.workingDirectoryOf id with
  | .workspace root => root
  | .fileDirectory directory => directory
  | .elsewhere _ | .none => state.workingDirectory

/-- The directory the view `view` reads names from ("Workspaces", in the
module docs): the directory of its buffer's file, else the root of its
buffer's workspace when that is on this machine, else the editor's working
directory. -/
def directoryOf (state : EditorState) (view : ViewId) : System.FilePath :=
  let buffer := (state.window? view).map (·.buffer)
  let fileDirectory := ((buffer.bind state.buffer?).bind (·.file)).bind (·.path.parent)
  let workspaceRoot :=
    (buffer.bind state.workspaceOf?).bind fun (workspace, _) =>
      match workspace.location with
      | .local root => some root
      | _ => none
  (fileDirectory <|> workspaceRoot).getD state.workingDirectory

/-- The place the view `view`'s prompts read paths from: its directory
(`directoryOf`) and the home directory, if the host set it. -/
def placeOf (state : EditorState) (view : ViewId) : Completion.Place :=
  { directory := some (state.directoryOf view), home := state.home }

/-- `state` once the finder answered `found` for `directory` under the config
generation `generation` (`Workspace.Table.record`). Never refused. -/
def recordWorkspace (directory : System.FilePath) (generation : Nat)
    (found : Option Workspace.Found) (state : EditorState) : EditorState :=
  { state with workspaces := state.workspaces.record directory generation found }

/-- `state` with the result of `change` on its table, or the refusal with
the state as it was. -/
def changeWorkspaces (change : Workspace.Table → Except WorkspaceRefusal Workspace.Table)
    (state : EditorState) : Except WorkspaceRefusal Unit × EditorState :=
  match change state.workspaces with
  | .ok workspaces => (.ok (), { state with workspaces })
  | .error refusal => (.error refusal, state)

/-- Registers a workspace at `location`, not on this machine, of the project
of `remote`, with `branch` checked out if it is given
(`Workspace.Table.register`). Refused with `local` for a local location. -/
def registerWorkspace (location : Location) (remote : String) (branch : Option String)
    (state : EditorState) : Except WorkspaceRefusal Unit × EditorState :=
  state.changeWorkspaces (·.register location remote branch)

/-- Has the workspace at `location` keep `value` under `name`. Refused with
`noSuchWorkspace` when there is none. -/
def setWorkspaceValue (location : Location) (name : String) (value : Value) (state : EditorState) :
    Except WorkspaceRefusal Unit × EditorState :=
  state.changeWorkspaces (·.setWorkspaceValue location name value)

/-- Has the project of `identity` keep `value` under `name`. Refused with
`noSuchProject` when there is none. -/
def setProjectValue (identity : Project.Identity) (name : String) (value : Value)
    (state : EditorState) : Except WorkspaceRefusal Unit × EditorState :=
  state.changeWorkspaces (·.setProjectValue identity name value)

/-- Adds a buffer called `name` over `text`, whose history is `history`, in
the next slot, and hands back its id. It is the least recently used buffer
(`recent`). Refused, with the state unchanged,
with `nameTaken` for a name a buffer already has, and with `notItsHistory`
for a history over another text. -/
def addBuffer (name : String) (text : TextId) (history : UndoTree) (state : EditorState) :
    Except BufferRefusal BufferId × EditorState :=
  if (state.findBuffer name).isSome then (.error (.nameTaken name), state)
  else
    if history.text != text then (.error .notItsHistory, state)
    else
      (.ok ⟨state.buffers.size⟩,
        { state with
          buffers := state.buffers.push (some { name, text, history })
          recent := state.recent.push ⟨state.buffers.size⟩ })

/-- Adds an excerpt buffer called `name` over the excerpt text `text`, whose
history is `history`, whose excerpts are `entries`, with nothing edited
through it yet ("Excerpt buffers", in the module docs). Refused as
`addBuffer` refuses. -/
def addExcerptBuffer (name : String) (text : TextId) (history : UndoTree)
    (entries : Array Buffer.ExcerptEntry) (state : EditorState) :
    Except BufferRefusal BufferId × EditorState :=
  match state.addBuffer name text history with
  | (.ok id, added) =>
    (.ok id,
      { added with
        buffers :=
          added.buffers.modify id.index (·.map ({ · with excerpts := some { entries } })) })
  | refused => refused

/-- Removes the buffer `id`: its slot is empty from then on, its id is never
used again, and it leaves the order buffers were used in (`recent`). Its
text is the caller's to release. Every place held in it (`Place.held`) is
dropped with it, from each window's jump list and previous-context mark
and from the global marks (`remembered.globalMarks`), and its own marks go
with its slot; a caller that keeps them detaches them into its file first
(`Jumps.detach`, `Editor/Jumps.lean`). Refused, with the
state unchanged, with `noSuchBuffer` for a buffer there is none of, and
with `shown`, and the first such view, while a window shows it. -/
def removeBuffer (id : BufferId) (state : EditorState) : Except BufferRefusal Unit × EditorState :=
  match state.buffer? id, state.windows.find? (·.buffer == id) with
  | none, _ => (.error (.noSuchBuffer id), state)
  | some _, some window => (.error (.shown window.id), state)
  | some _, none =>
    -- The places held in its text go with it: a caller that keeps them
    -- detaches them first (`Editor/Jumps.lean`).
    let kept (place : Place) : Option Place :=
      match place with
      | .held buffer _ => if buffer == id then none else some place
      | .file .. => some place
    (.ok (),
      { state with
        buffers := state.buffers.set! id.index none
        recent := state.recent.filter (· != id)
        windows :=
          state.windows.map fun window => { window with jumps := window.jumps.filterMap kept }
        remembered.globalMarks :=
          state.remembered.globalMarks.filterMap fun (char, place) => (kept place).map (char, ·) })

/-- Gives the buffer `id` the name `name`. Renaming a buffer to its own name
changes nothing. Refused, with the state unchanged, with `noSuchBuffer` for
a buffer there is none of, and with `nameTaken` for a name another buffer
has. -/
def renameBuffer (id : BufferId) (name : String) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  match state.buffer? id, state.findBuffer name with
  | none, _ => (.error (.noSuchBuffer id), state)
  | some _, some holder =>
    if holder == id then (.ok (), state) else (.error (.nameTaken name), state)
  | some _, none => changeBuffer id (fun buffer => ((), { buffer with name })) state

/-- Makes `history` the undo tree of the buffer `id`. Refused, with the
state unchanged, with `noSuchBuffer` for a buffer there is none of, and
with `notItsHistory` for a tree over another text than the buffer's. -/
def setHistory (id : BufferId) (history : UndoTree) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  match state.buffer? id with
  | none => (.error (.noSuchBuffer id), state)
  | some buffer =>
    if history.text != buffer.text then (.error .notItsHistory, state)
    else changeBuffer id (fun buffer => ((), { buffer with history })) state

/-- Has the buffer `id` keep `value` under `name`, in place of the value the
name had, if it had one. Refused, with the state unchanged, with
`noSuchBuffer` for a buffer there is none of. -/
def setValue (id : BufferId) (name : String) (value : Value) (state : EditorState) :
    Except BufferRefusal Unit × EditorState :=
  changeBuffer id
    (fun buffer =>
      ((),
        { buffer with
          locals :=
            if buffer.locals.any (·.1 == name) then
              buffer.locals.map fun kept => if kept.1 == name then (name, value) else kept
            else buffer.locals.push (name, value) }))
    state

/-- The id a new window gets: `nextView`, or one more than the greatest id
a window has when that is greater. -/
def freshView (state : EditorState) : ViewId :=
  ⟨state.windows.foldl (fun least window => max least (window.id.index + 1)) state.nextView⟩

/-- Splits the window `id`: a new window on the same buffer, with `scroll`
and `selection` as its markers, is put in the frame's list, and its id is
handed back. Under manual splits (while zoomed, when the layout zoom
returns to is manual splits) it takes `id`'s index when `placement` says
before and the index after it otherwise, and `id`'s tile is split along the
placement's axis (`Frame.inserted`); under the other layouts the placement
is ignored and it goes right after `id`. A docked window's new window is
docked at the same side, right after it, the placement ignored and the
layout unchanged. The focus stays. Refused, with the state
unchanged, with `ofMinibuffer` for the minibuffer's window, with
`floating` for a float, which has no tile to split, with
`noSuchWindow` for a window not in the frame, and with
`markersOfAnotherText` when a marker is not of that buffer's text. -/
def splitWindow (id : ViewId) (scroll selection : MarkerId) (placement : Placement := {})
    (state : EditorState) : Except LayoutRefusal ViewId × EditorState :=
  let windows := state.frame.windows
  let docked := state.frame.docked
  match state.minibufferView? == some id, state.target? id, windows.findIdx? (· == id),
    docked.findIdx? (·.1 == id) with
  | true, _, _, _ => (.error (.ofMinibuffer id), state)
  | false, some _, none, none =>
    if (state.frame.floating? id).isSome then (.error (.floating id), state)
    else (.error (.noSuchWindow id), state)
  | false, some target, none, some at_ =>
    if scroll.text != target.buffer.text || selection.text != target.buffer.text then
      (.error .markersOfAnotherText, state)
    else
      let made := state.freshView
      let side := (docked[at_]?.map (·.2)).getD .left
      (.ok made,
        { state with
          windows :=
            state.windows.push
              { id := made, buffer := target.window.buffer, scroll, selection
                jumps := target.window.jumps }
          frame :=
            { state.frame with
              docked := (docked.extract 0 (at_ + 1)).push (made, side) ++ docked.extract (at_ + 1) }
          nextView := made.index + 1 })
  | false, some target, some index, _ =>
    if scroll.text != target.buffer.text || selection.text != target.buffer.text then
      (.error .markersOfAnotherText, state)
    else
      let made := state.freshView
      -- Only manual splits read a placement; the others put the new window
      -- right after its source.
      let place :=
        match state.frame.underlying.tiling with
        | .splits _ => if placement.before then index else index + 1
        | _ => index + 1
      (.ok made,
        { state with
          windows :=
            state.windows.push
              { id := made, buffer := target.window.buffer, scroll, selection
                jumps := target.window.jumps }
          frame :=
            { state.frame.inserted index placement with
              windows := (windows.extract 0 place).push made ++ windows.extract place }
          nextView := made.index + 1 })
  | false, _, _, _ => (.error (.noSuchWindow id), state)

/-- `windows` with the entries at `first` and `second` swapped. -/
private def swapped (windows : Array ViewId) (first second : Nat) : Array ViewId :=
  match windows[first]?, windows[second]? with
  | some one, some other => (windows.set! first other).set! second one
  | _, _ => windows

/-- Makes `change` on the window `id` (`Arrange`). On a window of the tiled
list:

- `promote` moves it to index 0, main, the others moving one on; main
  itself swaps with index 1. `demote` swaps it with the next of the list,
  and the last window stays. `rotate` rotates the windows its layout
  rotates (`Layout.rotated`, read off the layout a zoom returns to while
  zoomed). Each leaves the focus on the view it was on, so it follows its
  window.
- `exchange` swaps it with the `nth` window of the list (1-based), or with
  the next, or with the previous when it is last, and focuses the other
  view, which now stands where it was (`focusedOn`, the focus rule). One window, an
  `nth` past the list or the window itself changes nothing.
- `resize` is `Layout.resized`, refused with `notResizable` and its axis
  where it gives none.
- `edge side` docks it at `side`: it leaves the list (`Frame.removed`) and
  is put after the windows docked there. It is refused with `noSuchEdge`
  when the layout has no edge at `side`, and with `lastTile` for the last
  window of the list.

On a docked window ("A window at an edge is not special", in the module
docs):

- `promote` moves it into the tiles as main, index 0, split before tile 0
  under manual splits (`Frame.inserted`); the old main is the first of the
  stack.
- `demote`, `rotate` and `exchange` act on the windows docked at its side,
  as a list: the whole of it rotates.
- `resize` grows or shrinks its edge's strip along the side's axis
  (`Layout.resizedEdge`), and is refused with `notResizable` across it.
- `edge side` moves it back into the tiles, at the end of the list
  (`Frame.inserted` after the last), when it is docked at `side`; moves it
  to `side`, after the windows docked there, when it is docked at another
  side; and is refused with `noSuchEdge` when the layout has no edge at
  `side`.

On a float ("A floating window", in the module docs):

- `promote` moves it into the tiles as main, as for a docked window;
  `edge side` docks it at `side`, refused with `noSuchEdge` as for any
  window; and `float` moves it into the tiles at the end of the list
  (`Frame.inserted` after the last), as `openWindow`'s `stack` places a
  window. Its anchor is dropped, and the focus stays.
- `resize` steps its share on the axis (`Floating.Share.resized`).
- `demote`, `rotate` and `exchange` are refused with `floating`: changing
  the stacking order is not built.

`float` on a tile or a docked window floats it, pinned, anchored to the
frame, of the default share, on top of the floats; the focus stays, and
the last tile is refused with `lastTile`. The floats anchored to it close
when transient and are anchored to the frame when pinned (`anchorGone`).

On any window:

- `zoom` goes back to the layout a zoom left while zoomed; otherwise it
  keeps the layout in `zoomedFrom` and makes the layout monocle, and under
  monocle with no zoom it is refused with `monocleChosen`.
- `balance` is `Layout.balanced`, which leaves a strip's size.
- `mainCount` moves master-and-stack's count by `steps`, not below 0, in
  the layout inside the edges (`Layout.tiling`), and is refused with
  `noMain` under any other layout.

`balance`, `resize`, `mainCount` and `edge` act on the layout a zoom
returns to while zoomed (`Frame.underlying`), and the refusals are that
layout's: monocle stays shown, and zoom again shows the change
(`Frame.withUnderlying`).

Every change is refused, with the state unchanged, with `ofMinibuffer` for
the minibuffer's window and with `noSuchWindow` for a window not in the
frame. -/
def arrange (id : ViewId) (change : Arrange) (state : EditorState) :
    Except LayoutRefusal Unit × EditorState :=
  let frame := state.frame
  let windows := frame.windows
  let set (frame : Frame) : Except LayoutRefusal Unit × EditorState :=
    (.ok (), { state with frame })
  -- The index of the other window an exchange swaps the window at `index`
  -- of `list` with.
  let exchanged (list : Array ViewId) (index : Nat) (nth : Option Nat) : Nat :=
    match nth with
    | some nth => if 0 < nth && nth - 1 != index then nth - 1 else list.size
    | none => if index + 1 < list.size then index + 1 else index - 1
  let common : Except LayoutRefusal Unit × EditorState :=
    match change with
    | .zoom =>
      match frame.zoomedFrom with
      | some back =>
        set
          { frame with
            layout := back, zoomedFrom := none }
      | none =>
        if frame.layout == .monocle then (.error .monocleChosen, state)
        else
          set
            { frame with
              layout := .monocle, zoomedFrom := some frame.layout }
    | .balance => set (frame.withUnderlying frame.underlying.balanced)
    | .mainCount more steps =>
      match frame.underlying.tiling with
      | .masterStack parameters =>
        let count := if more then parameters.count + steps else parameters.count - steps
        set
          (frame.withUnderlying
            (frame.underlying.withTiling (.masterStack { parameters with count })))
      | _ => (.error .noMain, state)
    | _ => (.ok (), state)
  -- The frame once the window `id` left the tiles or an edge for the
  -- floats, pinned and anchored to the frame, on top: the floats anchored
  -- to it lose their anchor (`anchorGone`).
  let floated (frame : Frame) : Except LayoutRefusal Unit × EditorState :=
    (.ok (),
      ({ state with
              frame :=
                { frame with
                  floats := frame.floats.push { view := id, anchor := .frame, pinned := true } } } :
            EditorState).anchorGone
        id)
  -- The state with the focus on `view` by the focus rule (`focusedOn`), and
  -- then its frame changed by `change`.
  let focusing (view : ViewId) (change : Frame → Frame) : Except LayoutRefusal Unit × EditorState :=
    let moved := state.focusedOn view
    (.ok (), { moved with frame := change moved.frame })
  if state.minibufferView? == some id then (.error (.ofMinibuffer id), state)
  else
    match windows.findIdx? (· == id), frame.sideOf? id with
    | none, none =>
      if (frame.floating? id).isNone then (.error (.noSuchWindow id), state)
      else
        let unfloated := frame.floats.filter (·.view != id)
        match change with
        | .promote =>
          set
            { frame.inserted 0 { before := true } with
              windows := #[id] ++ windows, floats := unfloated }
        | .edge side =>
          if !frame.underlying.edgeSides.contains side then (.error (.noSuchEdge side), state)
          else
            set
              { frame with
                docked := frame.docked.push (id, side), floats := unfloated }
        | .float =>
          set
            { frame.inserted (windows.size - 1) {} with
              windows := windows.push id, floats := unfloated }
        | .resize axis grow steps =>
          set
            (frame.withFloat id fun float =>
              { float with share := float.share.resized axis grow steps })
        | .demote | .rotate _ | .exchange _ => (.error (.floating id), state)
        | _ => common
    | some index, _ =>
      match change with
      | .promote =>
        set
          { frame with
            windows :=
              if index == 0 then swapped windows 0 1 else #[id] ++ windows.eraseIdx! index }
      | .demote => set { frame with windows := swapped windows index (index + 1) }
      | .rotate forward => set { frame with windows := frame.underlying.rotated windows forward }
      | .exchange nth =>
        let other := exchanged windows index nth
        match windows[other]? with
        | some view =>
          if other == index then set frame
          else focusing view fun frame => { frame with windows := swapped windows index other }
        | none => set frame
      | .resize axis grow steps =>
        match frame.underlying.resized index windows.size axis grow steps with
        | some layout => set (frame.withUnderlying layout)
        | none => (.error (.notResizable axis), state)
      | .edge side =>
        if !frame.underlying.edgeSides.contains side then (.error (.noSuchEdge side), state)
        else
          if windows.size ≤ 1 then (.error .lastTile, state)
          else
            -- The focus stays on the window, so the inheritor is not read.
            set
              { (frame.removed index).1 with
                windows := windows.eraseIdx! index, docked := frame.docked.push (id, side) }
      | .float =>
        if windows.size ≤ 1 then (.error .lastTile, state)
        else
          -- The focus stays on the window, so the inheritor is not read.
          floated { (frame.removed index).1 with windows := windows.eraseIdx! index }
      | _ => common
    | none, some at_ =>
      let ofSide := frame.atSide at_
      let index := (ofSide.findIdx? (· == id)).getD 0
      let undocked := frame.docked.filter (·.1 != id)
      match change with
      | .promote =>
        set
          { frame.inserted 0 { before := true } with
            windows := #[id] ++ windows, docked := undocked }
      | .demote => set (frame.withSide at_ (swapped ofSide index (index + 1)))
      -- The whole list rotates, as monocle rotates its list.
      | .rotate forward => set (frame.withSide at_ (Layout.monocle.rotated ofSide forward))
      | .exchange nth =>
        let other := exchanged ofSide index nth
        match ofSide[other]? with
        | some view =>
          if other == index then set frame
          else focusing view (·.withSide at_ (swapped ofSide index other))
        | none => set frame
      | .resize axis grow steps =>
        match frame.underlying.resizedEdge at_ axis grow steps with
        | some layout => set (frame.withUnderlying layout)
        | none => (.error (.notResizable axis), state)
      | .edge side =>
        if side == at_ then
          set
            { frame.inserted (windows.size - 1) {} with
              windows := windows.push id, docked := undocked }
        else
          if !frame.underlying.edgeSides.contains side then (.error (.noSuchEdge side), state)
          else set { frame with docked := undocked.push (id, side) }
      | .float => floated { frame with docked := undocked }
      | _ => common

/-- The window `count` steps from the window `id` towards `side`, worked out
from the rectangles the layout gave (`rects`), so it holds under every
layout; none when no window lies that way, and for a window with no
rectangle, which monocle hides.

A step's candidates are the tiled and docked windows of the frame
(`Frame.anchors`), never a float, which overlaps the tiles it floats over;
from a float, the step starts from its rectangle. A candidate's rectangle lies
wholly on `side` of the window reached so far and overlaps it across
(`Side.lies`). The nearest edge wins; among windows equally near, the one
whose span holds the reference coordinate, the top of `id`'s rectangle for
left and right and its left for up and down, and failing that the first in
list order. The step repeats `count` times, once for a count of 0, with the
same reference, and stops at the last window reached: Vim's "Nth window",
which goes as far as it can. The minibuffer's view is never a candidate. -/
def toward? (state : EditorState) (id : ViewId) (side : Side) (count : Nat) : Option ViewId :=
  Id.run do
    let laid := state.rects.filter fun (view, _) => state.frame.contains view
    let some (_, start) := laid.find? (·.1 == id) | return none
    -- A float is never a candidate: it overlaps what it floats over.
    let laid := laid.filter fun (view, _) => (state.frame.floating? view).isNone
    let reference :=
      match side with
      | .left | .right => start.y
      | .top | .bottom => start.x
    let holds (rect : Rect) : Bool :=
      match side with
      | .left | .right => rect.y ≤ reference && reference < rect.y + rect.height
      | .top | .bottom => rect.x ≤ reference && reference < rect.x + rect.width
    let mut reached := (id, start)
    for _ in [0:max 1 count] do
      let from_ := reached
      let candidates := laid.filter fun (view, rect) => view != from_.1 && side.lies from_.2 rect
      let nearest :=
        candidates.filter fun (_, rect) =>
          candidates.all fun (_, other) => side.gap from_.2 rect ≤ side.gap from_.2 other
      match nearest.find? (holds ·.2) <|> nearest[0]? with
      | some next =>
        reached := next
      | none =>
        break
    return if reached.1 == id then none else some reached.1

/-- The window of the frame after the window `id` when `forward`, and before
it otherwise, wrapping at either end; or, with `nth` above 0, the `nth`
window of the frame, the last when `nth` is past it. The frame's windows
are walked in `Frame.all`'s order: the tiles, the docked windows, then the
floats in stacking order.
None for a window not in the frame. -/
def cycled (state : EditorState) (id : ViewId) (forward : Bool) (nth : Nat) : Option ViewId := do
  let windows := state.frame.all
  let index ← windows.findIdx? (· == id)
  if 0 < nth then
    windows[min nth windows.size - 1]?
  else if forward then
    windows[(index + 1) % windows.size]?
  else
    windows[(index + windows.size - 1) % windows.size]?

/-- `op` run inside the tab of the window `id`: for a window of a hidden tab,
on the state with that tab in view (`Frame.selected`, which closes nothing
and touches nothing), and the zipper moved back to the tab that was in
view after it; for any other window, on the state as it is. -/
def inTabOf {α : Type} (id : ViewId) (op : EditorState → α × EditorState) (state : EditorState) :
    α × EditorState :=
  match state.frame.contains id, state.frame.tabOf? id with
  | false, some index =>
    let (result, after) := op { state with frame := state.frame.selected index }
    (result, { after with frame := after.frame.selected state.frame.tabIndex })
  | _, _ => op state

/-- `showBuffer` for a window of the tab in view: any other is refused with
`noSuchWindow`. -/
def showBufferInView (id : ViewId) (buffer : BufferId) (scroll selection : MarkerId)
    (state : EditorState) : Except LayoutRefusal Unit × EditorState :=
  match state.minibufferView? with
  | some view =>
    if view == id || state.minibufferBuffer? == some buffer then
      (.error (.ofMinibuffer view), state)
    else showing
  | none => showing
where
  /-- The state with the buffer shown, for a window and a buffer that are
  not the minibuffer's. -/
  showing : Except LayoutRefusal Unit × EditorState :=
    if (state.window? id).isNone || !state.frame.contains id then (.error (.noSuchWindow id), state)
    else
      match state.buffer? buffer with
      | none => (.error (.noSuchBuffer buffer), state)
      | some shown =>
        if scroll.text != shown.text || selection.text != shown.text then
          (.error .markersOfAnotherText, state)
        else
          (.ok (),
            ({ state with
                    windows :=
                      state.windows.map fun window =>
                        if window.id == id then
                          { window with
                            buffer, scroll, selection, wanted := none }
                        else window
                    recent := Recent.touch state.recent buffer } :
                  EditorState).dropAnchors
              fun float =>
              match float.anchor with
              | .position view _ => view == id
              | _ => false)

/-- Has the window `id` show the buffer `buffer`, with `scroll` and
`selection` as its markers, and no wanted column: an offset of one text
means nothing in another. The buffer is then the most recently used
(`recent`). A window of a hidden tab is taken, and the buffer is shown
there, inside that tab (`inTabOf`); the tab in view stays in view. Refused,
with the state unchanged, with
`ofMinibuffer`, and the minibuffer's view, for the minibuffer's window and
for the minibuffer's buffer in another window, with `noSuchWindow` for a
window of no tab, with `noSuchBuffer` for a buffer there is none of,
and with `markersOfAnotherText` when a marker is not of that buffer's
text. The floats of the window's tab anchored at a position of the window
close when transient and are anchored to the frame when pinned, since
their marker is of the text it showed (`dropAnchors`). -/
def showBuffer (id : ViewId) (buffer : BufferId) (scroll selection : MarkerId)
    (state : EditorState) : Except LayoutRefusal Unit × EditorState :=
  state.inTabOf id (showBufferInView id buffer scroll selection)

/-- Opens a new window on the buffer `buffer`, with `scroll` and `selection`
as its markers, at `spot`, and hands its id back (`freshView`):

- `stack` puts it after the last window of the tiled list, as a split of
  that window with the default placement would (`Frame.inserted`): under
  master-and-stack the stack grows and main is untouched, under monocle it
  is appended, and under manual splits the last tile is split along rows;
- `edge side` docks it at `side`, after the windows docked there;
- `float anchor share pinned` puts it on top of the floats, placed against
  `anchor`;
- `tab` makes it the only window of a new tab, right after the tab in view
  (Vim's `:tabnew`, Emacs's `tab-bar-new-tab-to`), under the layout config
  chose (`Frame.chosen`), or the default before any, fitted to it: a new
  tab takes the configured default layout. The tab in view stays in view.

The focus stays. Refused, with the state unchanged, with `ofMinibuffer`,
and the minibuffer's view, for the minibuffer's buffer, with
`noSuchBuffer` for a buffer there is none of, with `markersOfAnotherText`
when a marker is not of that buffer's text, and with `noSuchEdge` for an
edge the layout has none at. A float's anchor window is refused with
`floating` when it is a float, with `noSuchWindow` when it is no tiled or
docked window of the frame, and a position anchor's marker with
`markersOfAnotherText` when it is not of the text of that window's
buffer. -/
def openWindow (buffer : BufferId) (scroll selection : MarkerId) (spot : WindowSpot)
    (state : EditorState) : Except LayoutRefusal ViewId × EditorState :=
  match state.minibufferView? with
  | some view =>
    if state.minibufferBuffer? == some buffer then (.error (.ofMinibuffer view), state) else opening
  | none => opening
where
  /-- The state with the window opened, for a buffer that is not the
  minibuffer's. -/
  opening : Except LayoutRefusal ViewId × EditorState :=
    let frame := state.frame
    match state.buffer? buffer with
    | none => (.error (.noSuchBuffer buffer), state)
    | some shown =>
      if scroll.text != shown.text || selection.text != shown.text then
        (.error .markersOfAnotherText, state)
      else
        let made := state.freshView
        let opened (frame : Frame) : Except LayoutRefusal ViewId × EditorState :=
          (.ok made,
            { state with
              windows := state.windows.push { id := made, buffer, scroll, selection }
              frame
              nextView := made.index + 1 })
        match spot with
        | .stack =>
          opened
            { frame.inserted (frame.windows.size - 1) {} with windows := frame.windows.push made }
        | .edge side =>
          if frame.underlying.edgeSides.contains side then
            opened { frame with docked := frame.docked.push (made, side) }
          else (.error (.noSuchEdge side), state)
        | .float anchor share pinned =>
          let refusal : Option LayoutRefusal :=
            match anchor.view? with
            | none => none
            | some view =>
              if (frame.floating? view).isSome then some (.floating view)
              else
                if !frame.anchors view then some (.noSuchWindow view)
                else
                  match anchor, state.target? view with
                  | .position _ marker, some target =>
                    if marker.text != target.buffer.text then some .markersOfAnotherText else none
                  | .position _ _, none => some (.noSuchWindow view)
                  | _, _ => none
          match refusal with
          | some refusal => (.error refusal, state)
          | none =>
            opened
              { frame with floats := frame.floats.push { view := made, anchor, share, pinned } }
        | .tab =>
          let tab : Tab :=
            { windows := #[made], focused := made
              layout := (frame.chosen.getD Layout.default).fits 1 }
          opened { frame with tabsAfter := #[tab] ++ frame.tabsAfter }

/-- The state once a publish placed its floats against their anchors
(`Loop.publish`). `spots` answers, for each float anchored at a position,
where the display drew its anchor in its window's view, from the view's
top left, or none when the view does not show it. A float whose anchor is
drawn has its spot, offset by its window's rectangle (`rects`) into frame
pixels. A transient float whose anchor is not drawn closes
(`closeFloats`): a position the display answered none for, or an anchor
window with no rectangle. A pinned one keeps the spot it last had. -/
def located (spots : Array (ViewId × Option Display.Spot)) (state : EditorState) : EditorState :=
  let laid := state.rects
  let drawn (view : ViewId) : Option Rect := (laid.find? (·.1 == view)).map (·.2)
  let answer (float : Floating) : Option (Option Display.Spot) :=
    (spots.find? (·.1 == float.view)).map (·.2)
  let floats :=
    state.frame.floats.map fun float =>
      match float.anchor, answer float with
      | .position view _, some (some spot) =>
        match drawn view with
        | some rect =>
          { float with
            spot := some { x := rect.x + spot.x, y := rect.y + spot.y, height := spot.height } }
        | none => float
      | _, _ => float
  let gone (float : Floating) : Bool :=
    !float.pinned &&
      match float.anchor with
      | .frame => false
      | .window view => (drawn view).isNone
      | .position view _ => (drawn view).isNone || answer float == some none
  let closing := (state.frame.floats.filter gone).map (·.view)
  { state with frame := { state.frame with floats } }.closeFloats closing

/-- Opens a prompt, asked from the focused view: a buffer in the next slot
over `text`, whose history is `history`, with the minibuffer's mode
(`Prompt.mode`) and a name no buffer has (`Prompt.bufferName`, made free),
and a window on it, with a new view id and `scroll` and `selection` as its
markers. The prompt is recorded with `label`, `continuation` and the
focused view as its asker; the new view is focused and handed back; and
the echo is cleared, as Vim clears it: the prompt takes the bottom row. The
window list is as it was. Refused, with the state unchanged, with `alreadyOpen`,
and its view, while a prompt is open, with `noWindow` when the focused view
has no window, and with `notItsText` for a history or a marker of another
text than `text`. -/
def openPrompt (label : String) (continuation : Invocation) (text : TextId) (history : UndoTree)
    (scroll selection : MarkerId) (state : EditorState) :
    Except PromptRefusal ViewId × EditorState :=
  match state.prompt, state.window? state.frame.focused with
  | some asked, _ => (.error (.alreadyOpen asked.view), state)
  | none, none => (.error .noWindow, state)
  | none, some asker =>
    if history.text != text || scroll.text != text || selection.text != text then
      (.error .notItsText, state)
    else
      let view := state.freshView
      (.ok view,
        { state with
          buffers :=
            state.buffers.push
              (some
                { name := state.freeName Prompt.bufferName, text, history
                  major := some Prompt.mode })
          windows :=
            state.windows.push { id := view, buffer := ⟨state.buffers.size⟩, scroll, selection }
          frame := { state.frame with focused := view }
          nextView := view.index + 1
          prompt := some { label, view, asker := asker.id, continuation }
          -- The prompt takes the bottom row; what was said is gone, as in
          -- Vim, and the row is empty once the prompt closes.
          echo := "" })

/-- The window of the frame that stands for the view the prompt `asked` was
asked from: the asking view while it is a window of the frame, tiled or
docked (`Frame.contains`), and the first window of the tiled list
otherwise. For a list with no window it is the asking view. The focus goes
there when the prompt closes (`closePrompt`), and a command that was
handed the minibuffer's view to show a buffer in shows it there
(`shownIn`). -/
def askedFrom (state : EditorState) (asked : Prompt) : ViewId :=
  if state.frame.contains asked.asker then asked.asker else state.frame.windows[0]?.getD asked.asker

/-- The view a buffer is shown in when it is to be shown in `view`: `view`,
or, when `view` is the minibuffer's, which shows no other buffer, the
window of the frame the open prompt was asked from (`askedFrom`). -/
def shownIn (state : EditorState) (view : ViewId) : ViewId :=
  match state.prompt with
  | some asked => if asked.view == view then state.askedFrom asked else view
  | none => view

/-- Where the buffer `buffer` is displayed when the command `opener`, acting
on the view `asking`, asks, under `rules`, and whether that window is to be
focused (`DisplayRule.focus`). A window of the frame that shows the buffer
already is used, whatever the rules say (`shown`), so the buffer being
edited never moves. Otherwise the first rule that matches the buffer's
name, its modes (major first) and `opener` decides, or the fallback
(`DisplayRule.choose`): `focused` shows it in `shownIn asking`, `main` in
the first window of the tiled list, `stack` opens a window after the last
of the list, `edge side` one docked at `side` when the layout out of
a zoom has that edge and in the stack otherwise, and `float` a float
anchored to the frame, of the rule's share, pinned when the rule says,
and `newTab` the only window of a new tab after the one in view
(`WindowSpot.tab`). The window that shows the buffer already is looked
for in the tab in view only. `focus` is the caller's
default: the fallback's focus when no rule matches. -/
def displaying (state : EditorState) (rules : Array DisplayRule) (buffer : BufferId)
    (asking : ViewId) (opener : String) (focus : Bool := true) : Displaying × Bool :=
  let held := state.buffer? buffer
  let facts : DisplayRule.Facts :=
    { name := (held.map (·.name)).getD ""
      modes := (held.map fun buffer => buffer.major.toList ++ buffer.minors.toList).getD []
      opener }
  let rule := DisplayRule.choose rules facts focus
  match state.frame.all.find? fun view => (state.window? view).any (·.buffer == buffer) with
  | some view => (.shown view, rule.focus)
  | none =>
    let decided : Displaying :=
      match rule.target with
      | .focused => .showIn (state.shownIn asking)
      | .main => .showIn (state.frame.windows[0]?.getD asking)
      | .edge side =>
        if state.frame.underlying.edgeSides.contains side then .opened (.edge side)
        else .opened .stack
      | .float share pinned => .opened (.float .frame share pinned)
      | .stack => .opened .stack
      | .newTab => .opened .tab
    (decided, rule.focus)

/-- Closes the open prompt: the minibuffer's window is removed, its buffer's
slot is emptied, and the focus goes to the asking view, or, when that view
is no longer a window of the frame, to the first window of the list
(`askedFrom`). The window list is as it was. Given an answer, the
prompt's continuation is recorded with the answer as its first argument,
before its own (`answered`). The minibuffer's markers and text are the
caller's to give up. Refused, with the state unchanged, with `notOpen` when
no prompt is open. -/
def closePrompt (answer : Option String) (state : EditorState) :
    Except PromptRefusal Unit × EditorState :=
  match state.prompt with
  | none => (.error .notOpen, state)
  | some asked =>
    (.ok (),
      { state with
        buffers :=
          match state.minibufferBuffer? with
          | some buffer => state.buffers.set! buffer.index none
          | none => state.buffers
        windows := state.windows.filter (·.id != asked.view)
        frame := { state.frame with focused := state.askedFrom asked }
        prompt := none
        outbox.answered :=
          match answer with
          | some answer =>
            state.outbox.answered.push
              { asked.continuation with arguments := .str answer :: asked.continuation.arguments }
          | none => state.outbox.answered })

/-- The state with the open prompt's candidates changed by `change`.
Refused, with the state unchanged, with `notOpen` when no prompt is
open. -/
def changeCandidates (change : Candidates → Candidates) (state : EditorState) :
    Except PromptRefusal Unit × EditorState :=
  match state.prompt with
  | none => (.error .notOpen, state)
  | some asked =>
    (.ok (), { state with prompt := some { asked with candidates := change asked.candidates } })

/-- Replaces the open prompt's candidates with what its sources answered,
`collected`: the candidates a style matches, those filtered sources passed
through and the prompt's category. It forgets the listing and the choice.
Refused, with the state unchanged, with `notOpen` when no prompt is
open. -/
def setCandidates (collected : Completion.Collected) (state : EditorState) :
    Except PromptRefusal Unit × EditorState :=
  state.changeCandidates fun _ =>
    { all := collected.all, passed := collected.passed, category := collected.category
      asking := collected.asking, region := collected.region, texts := collected.texts
      place := collected.place, context := collected.context }

/-- What is completing now ("A session at point", in the module docs): the
open prompt's, else the open session's, else none. -/
def completing? (state : EditorState) : Option Completing :=
  match state.prompt, state.atPoint with
  | some asked, _ =>
    some
      { view := asked.view, asker := asked.asker, candidates := asked.candidates
        sheet := asked.sheet, tallest := asked.tallest, typed := none }
  | none, some session =>
    some
      { view := session.view, asker := session.view, candidates := session.candidates
        sheet := session.sheet, tallest := session.tallest, typed := some session.typed }
  | none, none => none

/-- `state` with what is completing in `view` changed by `change`: its
candidates, sheet and high-water mark written back to the open prompt, when
it is open in `view`, or to the open session, when it is open in `view`.
Otherwise it is as it was. -/
def withCompleting (view : ViewId) (change : Completing → Completing) (state : EditorState) :
    EditorState :=
  match state.completing? with
  | none => state
  | some completing =>
    if completing.view != view then state
    else
      let changed := change completing
      match state.prompt with
      | some asked =>
        { state with
          prompt :=
            some
              { asked with
                candidates := changed.candidates, sheet := changed.sheet
                tallest := changed.tallest } }
      | none =>
        { state with
          atPoint :=
            state.atPoint.map fun session =>
              { session with
                candidates := changed.candidates, sheet := changed.sheet
                tallest := changed.tallest } }

/-- The candidates of what is completing in `view`: the open prompt's, when
it is open in `view`, or the open session's, when it is open in `view`. -/
def candidatesIn? (state : EditorState) (view : ViewId) : Option Candidates :=
  state.completing?.bind fun completing =>
    if completing.view == view then some completing.candidates else none

/-- `state` with `candidates` as the candidates of what is completing in
`view` (`withCompleting`). -/
def replaceCandidatesIn (view : ViewId) (state : EditorState) (candidates : Candidates) :
    EditorState :=
  state.withCompleting view fun completing => { completing with candidates }

/-- Takes `batch`, a batch of the job of the asking source `index` of the
prompt open in `view`, at the source's `generation`: the first of a
generation replaces what the source answered, a later one is appended,
each candidate in the source's group, and the revision is bumped. Says
whether it was taken: for another view, a source there is none of, another
generation (a stale job's) or no prompt open, it is dropped and the state
is as it was. -/
def addCandidates (view : ViewId) (index generation : Nat) (batch : Array Completion.Candidate)
    (state : EditorState) : Bool × EditorState :=
  match state.candidatesIn? view with
  | none => (false, state)
  | some candidates =>
    match candidates.asking[index]? with
    | none => (false, state)
    | some source =>
      if source.generation != generation then (false, state)
      else
        let batch := batch.map (·.inGroup source.source)
        let answered := if source.fresh then source.answered ++ batch else batch
        -- A generation's first batch is what the source answered for the
        -- text it was asked for.
        let answeredFor := if source.fresh then source.answeredFor else some source.askedFor
        (true,
          state.replaceCandidatesIn view
            { candidates with
              asking :=
                candidates.asking.set! index
                  { source with
                    answered, fresh := true, answeredFor }
              revision := candidates.revision + 1 })

/-- Marks the asking source `index` of the prompt open in `view` done, when
it is at `generation`: a generation that delivered nothing clears what the
source answered, bumping the revision when there was anything. Otherwise
the state is as it was. -/
def sourceAnswered (view : ViewId) (index generation : Nat) (state : EditorState) : EditorState :=
  match state.candidatesIn? view with
  | none => state
  | some candidates =>
    match candidates.asking[index]? with
    | none => state
    | some source =>
      if source.generation != generation then state
      else
        let cleared := !source.fresh && !source.answered.isEmpty
        state.replaceCandidatesIn view
          { candidates with
            asking :=
              candidates.asking.set! index
                { source with
                  done := true, fresh := true
                  answered := if source.fresh then source.answered else #[]
                  answeredFor := if source.fresh then source.answeredFor else some source.askedFor }
            revision := if cleared then candidates.revision + 1 else candidates.revision }

/-- Marks the asking source `index` of the prompt open in `view` done, as
`sourceAnswered` does, when its job at `generation` failed with `message`,
and says `<source>: <message>` in the echo area, as `matchFailed` says why a
match failed. A stale job's failure, of another generation or view, changes
nothing and says nothing. -/
def sourceFailed (view : ViewId) (index generation : Nat) (message : String) (state : EditorState) :
    EditorState :=
  match (state.candidatesIn? view).bind (·.asking[index]?) with
  | some source =>
    if source.generation != generation then state
    else { state.sourceAnswered view index generation with echo := s!"{source.source}: {message}" }
  | none => state

/-- Lists `listed`, which a match job made for `pattern` at `revision`, in
the prompt open in `view`, when that is the match in flight: the choice is
kept on its candidate (`Candidates.relist`), and nothing is in flight after
it. Otherwise the state is as it was. -/
def listMatched (view : ViewId) (pattern : String) (revision : Nat)
    (listed : Array Completion.Listed) (state : EditorState) : EditorState :=
  match state.candidatesIn? view with
  | some candidates =>
    if candidates.matchingFor pattern revision then
      state.replaceCandidatesIn view
        { candidates.relist pattern revision listed with matching := none }
    else state
  | none => state

/-- Ends the match in flight for `pattern` at `revision` in the prompt open
in `view`, which failed with `message`: nothing is in flight after it, the
pair is recorded as unmatched, and the echo area says
`completion-match: <message>`. The listing stays. For any other match the
state is as it was. -/
def matchFailed (view : ViewId) (pattern : String) (revision : Nat) (message : String)
    (state : EditorState) : EditorState :=
  match state.candidatesIn? view with
  | some candidates =>
    if candidates.matchingFor pattern revision then
      {
        state.replaceCandidatesIn view
          { candidates with
            matching := none, unmatched := some (pattern, revision) } with
        echo := s!"completion-match: {message}" }
    else state
  | none => state

/-- Makes the open prompt's listing the one for `pattern`: the candidates at
the hits' indices, in that order, with their ranges, then the passed ones,
with nothing chosen (`Candidates.list`). Refused, with the state unchanged,
with `notOpen` when no prompt is open. -/
def listCandidates (pattern : String) (hits : Array Completion.Hit) (state : EditorState) :
    Except PromptRefusal Unit × EditorState :=
  state.changeCandidates (·.list pattern hits)

/-- `state` with the open prompt's listing shown by the display
`displaying` chooses for its category (`Completion.Displaying.displayFor`):
the display is handed the listing, the choice, where its window started
last and whether the listing is grouped, and what it answers is kept on
the prompt (`Prompt.sheet`), where its window starts now as the
candidates' `first`, and the high-water mark raised to its rows
(`Prompt.tallest`); a session at point's the same way. With neither open,
the key hints shown (`hinting?`) are shown by the display chosen for the
category `key` (`KeyHintList.category`), handed their listing with nothing
chosen, its window at 0 and not grouped, and what it answers is kept on
the hints with their high-water mark raised. With none of them it is as it
was. It is pure: a display reads no state and asks no port. -/
def displayed (state : EditorState) (displaying : Completion.Displaying) : EditorState :=
  match state.completing? with
  | none =>
    match state.hinting? with
    | none => state
    | some hints =>
      let sheet :=
        (displaying.displayFor (some KeyHintList.category)).sheet
          { listed := hints.listed, category := some KeyHintList.category }
      { state with
        keyHints :=
          some
            { hints with
              sheet, tallest := max hints.tallest sheet.rows.size } }
  | some completing =>
    state.withCompleting completing.view fun completing =>
      let candidates := completing.candidates
      let sheet :=
        (displaying.displayFor candidates.category).sheet
          { listed := candidates.listed, chosen := candidates.chosen, first := candidates.first
            grouped := candidates.grouped, category := candidates.category }
      { completing with
        sheet, tallest := max completing.tallest sheet.rows.size
        candidates := { candidates with first := sheet.first } }

/-- Moves the open prompt's choice by `step` through its listing
(`Candidates.choose`). Refused, with the state unchanged, with `notOpen`
when no prompt is open. -/
def chooseCandidate (step : Candidates.Step) (state : EditorState) :
    Except PromptRefusal Unit × EditorState :=
  state.changeCandidates (·.choose step)

/-- Opens a session at point, `session`, with what its sources answered,
`collected`, as its candidates, with nothing chosen ("A session at point",
in the module docs). Refused, with the state unchanged, with `promptOpen`
while a prompt is open, `alreadyOpen` while a session is, and `noWindow`
when the session's view has no window. -/
def openAtPoint (session : AtPointSession) (collected : Completion.Collected)
    (state : EditorState) : Except AtPointRefusal Unit × EditorState :=
  if state.prompt.isSome then (.error .promptOpen, state)
  else
    if state.atPoint.isSome then (.error .alreadyOpen, state)
    else
      if (state.window? session.view).isNone then (.error .noWindow, state)
      else
        (.ok (),
          { state with
            atPoint :=
              some
                { session with
                  candidates :=
                    { all := collected.all, passed := collected.passed
                      category := collected.category, asking := collected.asking
                      region := collected.region, texts := collected.texts
                      place := collected.place, context := collected.context }
                  sheet := {}, tallest := 0 } })

/-- Closes the open session, and hands it back: its markers and its
snapshots are the caller's to give up. Refused, with the state unchanged,
with `notOpen` when no session is open. -/
def closeAtPoint (state : EditorState) : Except AtPointRefusal AtPointSession × EditorState :=
  match state.atPoint with
  | none => (.error .notOpen, state)
  | some session => (.ok session, { state with atPoint := none })

/-- The state with the open session changed by `change`. Refused, with the
state unchanged, with `notOpen` when no session is open. -/
def changeAtPoint (change : AtPointSession → AtPointSession) (state : EditorState) :
    Except AtPointRefusal Unit × EditorState :=
  match state.atPoint with
  | none => (.error .notOpen, state)
  | some session => (.ok (), { state with atPoint := some (change session) })

/-- Moves the open session's choice by `step` through its listing
(`Candidates.choose`). Refused with `notOpen` when no session is open. -/
def chooseAtPoint (step : Candidates.Step) (state : EditorState) :
    Except AtPointRefusal Unit × EditorState :=
  state.changeAtPoint fun session => { session with candidates := session.candidates.choose step }

/-- Records what a preview left in the open session's region, `shown`, and
whether a preview was made. Refused with `notOpen` when no session is
open. -/
def retypeAtPoint (shown : String) (previewed : Bool) (state : EditorState) :
    Except AtPointRefusal Unit × EditorState :=
  state.changeAtPoint fun session =>
    { session with
      shown, previewed := session.previewed || previewed }

/-- Records an edit the user made in the open session's region, which now
holds `text`: it is what is typed and what is shown, and nothing is chosen.
Refused with `notOpen` when no session is open. -/
def retakeAtPoint (text : String) (state : EditorState) :
    Except AtPointRefusal Unit × EditorState :=
  state.changeAtPoint fun session =>
    { session with
      typed := text, shown := text, candidates := { session.candidates with chosen := none } }

/-- Records that a command typed `text` in `view` in place of typed text
(`retyped`). -/
def retype (view : ViewId) (text : String) (state : EditorState) : EditorState :=
  { state with retyped := state.retyped.push (view, text) }

end EditorState

end Editor
