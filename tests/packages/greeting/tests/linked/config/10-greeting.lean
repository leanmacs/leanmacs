-- The config the package's linked test loads in a config session on the
-- real elaborator (GreetingTest/Linked.lean). It names the package's
-- command, which is compiled into the executable and registered before any
-- config, and binds a key to it.
def setup : SetupM Unit :=
  bindKey "C-c g" "greeting-hello"
