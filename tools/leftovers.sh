# The processes a check started that are still running, and their end,
# shared by the checks that start editors through the app's launcher
# (tools/bundle-test.sh, tools/bundle-sets.sh, tools/app-check.sh,
# tools/user-sets-test.sh and tools/user-sets-check.sh), which source this
# file. Defines functions only; runs nothing.
#
# Nothing a check starts may outlive it. The launcher spawns a watcher,
# detached, beside each editor it starts under a launch record
# (crates/editor-launch/src/watch.rs), and a watcher whose record is still
# there when its editor ends falls back to the next candidate; if the
# record is gone by then (the check's temporary directory removed under
# it), the launcher starts the shipped default cold with no arguments, a
# window on the desktop that no one waits for. So each check names every
# process it starts by its temporary directory, which each such process
# has on its command line (the launcher, the editor, the record or the
# data directory), and:
#
# - before it says it passed, requires none of them to be running once
#   the watchers had their time to see their records go (`no_leftovers`);
# - on its way out, whatever the outcome, kills every one still running,
#   before the directory is removed (`reap`).

# The processes whose command line names the directory `$1`, one pid a
# line, but this script and the subshells it forks, which name the
# directory in the same arguments: those whose command line is this
# shell's own. The directory reaches `awk` through the environment, so
# `awk` does not name it.
leftovers_of() {
  leftovers_self=$(ps -ww -o command= -p "$$")
  # shellcheck disable=SC2016 # awk's own variables
  ps -axww -o pid=,command= |
    LEFTOVERS_DIR="$1/" LEFTOVERS_SELF="$leftovers_self" awk '
    index($0, ENVIRON["LEFTOVERS_DIR"]) {
      pid = $1
      command = $0
      sub(/^ *[0-9]+ /, "", command)
      if (command != ENVIRON["LEFTOVERS_SELF"]) print pid
    }'
}

# Each process `leftovers_of "$1"` names, as `ps` shows it: pid and command.
leftovers_shown() {
  for pid in $(leftovers_of "$1"); do
    ps -ww -o pid=,command= -p "$pid" 2>/dev/null || true
  done
}

# Waits up to `$2` seconds (default 10) for the processes that name the
# directory `$1` to end; exits 0 when none is left, and 1, having written
# them on stderr, when some still run.
no_leftovers() {
  leftovers_wait=${2:-10}
  while [ -n "$(leftovers_of "$1")" ] && [ "$leftovers_wait" -gt 0 ]; do
    sleep 1
    leftovers_wait=$((leftovers_wait - 1))
  done
  [ -z "$(leftovers_of "$1")" ] && return 0
  echo "these processes it started are still running:" >&2
  leftovers_shown "$1" >&2
  return 1
}

# Kills every process that names the directory `$1`, a check script this
# one started among them (interrupted with it, it would start more), again
# until none is left (a watcher killed as it starts a fallback leaves none
# behind, but one it spawned just before may need a second round), at most
# ten rounds.
reap() {
  reap_round=0
  while [ -n "$(leftovers_of "$1")" ] && [ "$reap_round" -lt 10 ]; do
    # shellcheck disable=SC2046 # one pid a word
    kill -KILL $(leftovers_of "$1") 2>/dev/null || true
    sleep 1
    reap_round=$((reap_round + 1))
  done
}
