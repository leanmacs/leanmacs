# The token comes from GITHUB_TOKEN, which the infra-plan/infra-apply tasks
# set from `gh auth token`. No PAT is stored anywhere. This root manages no
# secrets, so it has no 1Password provider: 1Password holds only the state
# passphrase, read by `op run` (op.env).
provider "github" {
  owner = "leanmacs"
}
