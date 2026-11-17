namespace Programs

/-- Sums a list with a loop in `do` notation. -/
def sum (xs : List Nat) : IO Nat := do
  let mut total := 0
  for x in xs do
    total := total + x
  if total > 10 then
    IO.println s!"big: {total}"
  else
    IO.println "small"
  return total

def describe (n : Nat) : String :=
  match n with
  | 0 => "zero"
  | 1 => "one"
  | _ => "many"

private def helper {α : Type} [Inhabited α] (xs : Array α) : α :=
  xs.getD 0 default

@[inline] def twice (f : Nat → Nat) (x : Nat) : Nat := f (f x)

def main : IO Unit := do
  let n ← sum [1, 2, 3]
  IO.println (describe n)
where
  unused : Nat := 0

end Programs
