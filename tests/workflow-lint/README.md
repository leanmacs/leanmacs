The fixtures of `tools/workflow-lint-probe.sh`, which `mise run
workflow-lint` runs (docs/dev-practices/ci.md). They live outside
`.github/workflows/`, so GitHub never runs them and the lint's own pass over
`.github/workflows/` never reads them.

- tag-pinned.yml: a workflow whose one action is pinned by a tag
  (`actions/checkout@v7.0.1`). zizmor, with `.github/zizmor.yml`, must exit
  non-zero on it with an `unpinned-uses` finding.

The probe's other cases are made at run time: for each case it copies
`.github/workflows/ci.yml` and `build.yml`, with the check and the files it
reads, into a temporary directory, breaks one rule of
`tools/workflow-check.sh` (with `yq` on the tree's `ci.yml` or `build.yml`,
or `sed` on another file), and requires the check, run on the tree's copy
of the workflow, to fail with a message naming that rule and no other. The
copy's base name picks the rules, as in the checkout, and a copy of
`ci.yml` saved as `release.yml`, a file the check has no rules for, must
fail the rule `workflows`. Last, the check must pass both workflows of an
unbroken tree.
