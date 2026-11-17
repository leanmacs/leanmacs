# What GitHub Actions may run in this repository, and what its GITHUB_TOKEN
# may do (README.md, "Actions settings").

import {
  for_each = var.import_existing ? toset(["leanmacs"]) : toset([])
  to       = github_actions_repository_permissions.leanmacs
  id       = each.value
}

resource "github_actions_repository_permissions" "leanmacs" {
  repository = github_repository.leanmacs.name

  enabled = true
  # Once public, any fork PR can run the workflows, so a workflow edit must
  # not be able to pull in any third-party action: a new one needs its
  # pattern here, applied first, or its jobs fail at startup. Not every
  # verified creator either.
  allowed_actions = "selected"
  allowed_actions_config {
    github_owned_allowed = true
    verified_allowed     = false
    # Any ref: pinning refs is sha_pinning_required's job.
    patterns_allowed = [
      "jdx/mise-action@*",
    ]
  }
  # Every workflow pins its actions by full commit SHA, with the release tag
  # in a trailing comment. A local ./ reusable workflow needs none.
  sha_pinning_required = true
}

import {
  for_each = var.import_existing ? toset(["leanmacs"]) : toset([])
  to       = github_workflow_repository_permissions.leanmacs
  id       = each.value
}

# The live values, now declared: a read-only token that can't approve PRs.
resource "github_workflow_repository_permissions" "leanmacs" {
  repository = github_repository.leanmacs.name

  default_workflow_permissions     = "read"
  can_approve_pull_request_reviews = false
}
