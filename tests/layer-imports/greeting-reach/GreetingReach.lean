import GreetingApi
import Greeting

/-!
# The fixture package `greeting-reach`

It imports the interface package `greeting-api`, which the three-layer rule
allows, and the implementation package `greeting`, which the rule refuses
(`tools/layer-imports-check.sh`). It is never built.
-/
