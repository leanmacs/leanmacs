/- solarized fixture -/
def area (w h : Nat) : Nat :=
  w * h -- width_times_height
#eval area 3 4 |>.succ
