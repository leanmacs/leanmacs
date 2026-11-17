/-!
# A module of basic declarations

Its docs, in Markdown.
-/
import Std.Data.HashMap

namespace Editor.Sample

/-- A point on a grid. -/
structure Point where
  x : Nat
  y : Nat
  deriving Repr, BEq

/-- Which way a move goes. -/
inductive Direction where
  | up
  | down
  | left
  | right
  deriving Repr

-- A line comment.
def Point.origin : Point := { x := 0, y := 0 }

/- A block comment. -/
def move (p : Point) : Direction → Point
  | .up => { p with y := p.y + 1 }
  | .down => { p with y := p.y - 1 }
  | .left => { p with x := p.x - 1 }
  | .right => { p with x := p.x + 1 }

theorem move_up_y (p : Point) : (move p .up).y = p.y + 1 := by
  simp [move]

instance : ToString Point where
  toString p := s!"({p.x}, {p.y})"

end Editor.Sample
