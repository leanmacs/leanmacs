namespace Strings

def greeting : String := "héllo, 漢字 😀"

def escaped : String := "a \"quoted\" word\n\ttabbed"

def interpolated (name : String) (n : Nat) : String :=
  s!"{name} has {n} items"

def letter : Char := 'x'

def newline : Char := '\n'

def numbers : List Nat := [0, 1, 42, 0xff, 1000000]

def ratio : Float := 3.25

def flag : Bool := true && !false

end Strings
