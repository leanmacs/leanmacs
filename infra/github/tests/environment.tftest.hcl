# Mocked-provider tests for the github-pages environment in pages.tf. Run by
# `mise run infra-check`.

variables {
  state_passphrase = "test-only-not-a-secret"
  # `tofu test` panics planning an import, even against a mock provider.
  import_existing = false
}

mock_provider "github" {}

run "github_pages_deploys_from_main_only" {
  command = plan

  assert {
    condition     = github_repository_environment.github_pages.environment == "github-pages"
    error_message = "The environment must be github-pages, the one release.yml's pages job deploys to."
  }

  assert {
    condition     = github_repository_environment.github_pages.repository == github_repository.leanmacs.name
    error_message = "The environment must be on the managed repository."
  }

  assert {
    condition     = github_repository_environment.github_pages.deployment_branch_policy[0].custom_branch_policies == true
    error_message = "The environment must use custom branch policies."
  }

  assert {
    condition     = github_repository_environment.github_pages.deployment_branch_policy[0].protected_branches == false
    error_message = "The environment must not allow every protected branch."
  }

  assert {
    condition     = length(github_repository_environment.github_pages.reviewers) == 0
    error_message = "The environment must have no reviewers: main's nightly deploys unattended."
  }

  assert {
    condition     = github_repository_environment_deployment_policy.github_pages_main.environment == github_repository_environment.github_pages.environment
    error_message = "The branch policy must be the github-pages environment's."
  }

  assert {
    condition     = github_repository_environment_deployment_policy.github_pages_main.repository == github_repository.leanmacs.name
    error_message = "The branch policy must be on the managed repository."
  }

  assert {
    condition     = github_repository_environment_deployment_policy.github_pages_main.branch_pattern == "main"
    error_message = "The one branch policy must be main."
  }
}
