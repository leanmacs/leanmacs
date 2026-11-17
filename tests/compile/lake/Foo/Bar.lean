-- The fixture lake reports an unknown identifier on line 12, column 4
-- (Lean counts columns from 0): the x below.

namespace Foo.Bar

def y : Nat :=
  1

end Foo.Bar

example : Nat :=
    x
