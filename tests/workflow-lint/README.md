The fixtures of `tools/workflow-lint-probe.sh`, which `mise run
workflow-lint` runs (docs/dev-practices/ci.md). They live outside
`.github/workflows/`, so GitHub never runs them and the lint's own pass over
`.github/workflows/` never reads them.

- tag-pinned.yml: a workflow whose one action is pinned by a tag
  (`actions/checkout@v7.0.1`). zizmor, with `.github/zizmor.yml`, must exit
  non-zero on it with an `unpinned-uses` finding.

The probe's other cases are made at run time: it copies
`.github/workflows/ci.yml` into a temporary directory, breaks one rule of
`tools/workflow-check.sh` at a time with `yq`, and requires the check to
fail on each with a message naming that rule, then to pass on the
unbroken copy.
