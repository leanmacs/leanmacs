# Mocked-provider tests for actions.tf: what Actions may run and what its
# token may do. Run by `mise run infra-check`.

variables {
  state_passphrase = "test-only-not-a-secret"
  # `tofu test` panics planning an import, even against a mock provider.
  import_existing = false
}

mock_provider "github" {}

run "actions_permissions_are_declared" {
  command = plan

  assert {
    condition     = github_actions_repository_permissions.leanmacs.repository == github_repository.leanmacs.name
    error_message = "The Actions permissions must be on the managed repository."
  }

  assert {
    condition = (
      github_actions_repository_permissions.leanmacs.enabled &&
      github_actions_repository_permissions.leanmacs.sha_pinning_required
    )
    error_message = "Actions must stay enabled, with SHA pinning required: every workflow pins its actions by commit SHA."
  }

  assert {
    condition     = github_actions_repository_permissions.leanmacs.allowed_actions == "selected"
    error_message = "allowed_actions must be selected: an explicit allowlist."
  }

  assert {
    condition = (
      github_actions_repository_permissions.leanmacs.allowed_actions_config[0].github_owned_allowed &&
      !github_actions_repository_permissions.leanmacs.allowed_actions_config[0].verified_allowed
    )
    error_message = "Allow GitHub-owned actions, but not every verified creator."
  }

  assert {
    condition = (
      toset(github_actions_repository_permissions.leanmacs.allowed_actions_config[0].patterns_allowed) ==
      toset(["Swatinem/rust-cache@*", "jdx/mise-action@*"])
    )
    error_message = "patterns_allowed must be exactly the third-party actions the workflows use: Swatinem/rust-cache and jdx/mise-action."
  }
}

run "workflow_token_is_read_only" {
  command = plan

  assert {
    condition     = github_workflow_repository_permissions.leanmacs.repository == github_repository.leanmacs.name
    error_message = "The workflow permissions must be on the managed repository."
  }

  assert {
    condition     = github_workflow_repository_permissions.leanmacs.default_workflow_permissions == "read"
    error_message = "GITHUB_TOKEN must default to read."
  }

  assert {
    condition     = !github_workflow_repository_permissions.leanmacs.can_approve_pull_request_reviews
    error_message = "Actions must not be able to approve pull requests."
  }
}
