import Greeting

/-!
# A test module of the fixture package `greeting-reach`

It imports the implementation package `greeting`, which the three-layer
rule refuses to a test module as to any module of a package
(`tools/layer-imports-check.sh`): a test uses an interface package's fake.
It is never built.
-/
