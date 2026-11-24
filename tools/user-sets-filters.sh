# The filters a user package set's end-to-end output passes through before
# it is compared with its fixture, shared by tools/user-sets-test.sh and
# tools/bundle-sets.sh (`sets`), which source this file. Defines functions
# only; runs nothing.

# Writes the output on stdin with each of the arguments' pairs substituted,
# in order: `scrub <text> <placeholder> ...` writes each <text> as its
# <placeholder>, so a run's own paths and the core's identity read the same
# from run to run (`@DIR@`, `@REPO@`, `@APP@`, `@CORE@`). A <text> is taken
# only as a whole: not where a letter, a digit, `.`, `_` or `-` touches it
# on either side, so a repository at /work (the Linux container's) leaves
# `packages/workspace` as it is (host-tests-on-fakes phase 7, F3).
scrub() {
  user_sets_scrub=
  while [ "$#" -ge 2 ]; do
    user_sets_scrub="${user_sets_scrub}s#(^|[^A-Za-z0-9._-])$1([^A-Za-z0-9._-]|\$)#\\1$2\\2#g; "
    shift 2
  done
  # Twice, so a text right after another of itself, which shares the
  # character between them with the first match, is taken too.
  sed -E "$user_sets_scrub$user_sets_scrub"
}

# Writes the lines of the output on stdin that are stable from run to run:
# job lines go, and so does every line of the build buffer's views, which
# hold Lake's own output and the build's time; those are checked apart. A
# scene line carries no count of publishes (`published` prints it on its
# own), so how Lake's lines fall into deliveries, each a post and a scene,
# changes nothing here.
stable() {
  grep -v '^job ' | grep -v 'Package build of' | grep -v '\*package-build\*' || true
}
