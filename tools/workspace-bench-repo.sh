#!/bin/sh
# Makes the repository the workspace finder's benchmark searches
# (`mise run find-file-bench`, docs/dev-practices/on-demand-checks.md, "The
# workspace finder benchmark, on demand"):
#
#   sh tools/workspace-bench-repo.sh <dir> [count]
#
# <dir> must not exist, or be empty. It gets `count` files (100,000 by
# default) at src/m<i / 100>/f<i>.rs, each holding its own number and a line
# feed, committed once on `main` by a fixed author at a fixed date. Git reads
# neither the user's nor the system's config, so the repository is the same
# on every machine: the run can be repeated elsewhere.
set -eu

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "usage: sh tools/workspace-bench-repo.sh <dir> [count]" >&2
  exit 2
fi
dir=$1
count=${2:-100000}
case $count in
'' | *[!0-9]*)
  echo "workspace-bench-repo: the count must be a number: $count" >&2
  exit 2
  ;;
esac

mkdir -p "$dir"
if [ -n "$(ls -A "$dir")" ]; then
  echo "workspace-bench-repo: $dir is not empty" >&2
  exit 2
fi
cd "$dir"

# One awk run writes every file: a process per file would take minutes.
awk -v count="$count" 'BEGIN {
  for (i = 0; i < count; i++) {
    d = "src/m" int(i / 100)
    if (i % 100 == 0) {
      system("mkdir -p " d)
    }
    path = d "/f" i ".rs"
    print i > path
    close(path)
  }
}'

GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_NOSYSTEM=1
GIT_AUTHOR_NAME=bench
GIT_AUTHOR_EMAIL=bench@example.com
GIT_COMMITTER_NAME=bench
GIT_COMMITTER_EMAIL=bench@example.com
GIT_AUTHOR_DATE=2026-01-01T00:00:00Z
GIT_COMMITTER_DATE=2026-01-01T00:00:00Z
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL \
  GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_DATE
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

git init -q -b main
git add -A
git -c commit.gpgsign=false commit -q -m "$count files"
