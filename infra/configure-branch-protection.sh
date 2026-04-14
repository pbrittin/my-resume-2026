#!/usr/bin/env bash
# =============================================================================
# configure-branch-protection.sh
#
# Configures branch protection rules on `main` via the GitHub API so that
# PR validation checks are REQUIRED before any merge can happen.
#
# Without this, the pr-validation.yml workflow runs but its results are
# advisory only — someone can still merge a failing PR. This script makes
# the checks mandatory.
#
# Prerequisites:
#   - GitHub CLI (gh) installed and authenticated: gh auth login
#   - You must be a repo admin
#
# Usage:
#   chmod +x infra/configure-branch-protection.sh
#   ./infra/configure-branch-protection.sh
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

CONFIG_FILE="infra/config.env"
[[ -f "$CONFIG_FILE" ]] || { echo "infra/config.env not found."; exit 1; }
source "$CONFIG_FILE"

[[ -z "${GITHUB_USERNAME:-}" ]]   && { echo "GITHUB_USERNAME not set in config.env"; exit 1; }
[[ -z "${GITHUB_REPO_NAME:-}" ]]  && { echo "GITHUB_REPO_NAME not set in config.env"; exit 1; }

REPO="${GITHUB_USERNAME}/${GITHUB_REPO_NAME}"

echo -e "\n${BOLD}GitHub Branch Protection — $REPO${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Branch: main"
echo ""
echo "Required status checks that will be enforced:"
echo "  • Lint HTML          (pr-validation.yml)"
echo "  • Test backend       (pr-validation.yml)"
echo "  • Validate SAM template (pr-validation.yml)"
echo ""

# Check gh CLI is available
if ! command -v gh &>/dev/null; then
    echo -e "${YELLOW}GitHub CLI (gh) not found.${NC}"
    echo ""
    echo "Install it from: https://cli.github.com"
    echo ""
    echo "Then run this script again, or configure branch protection manually:"
    echo "  GitHub repo → Settings → Branches → Add branch protection rule"
    echo "  Branch name pattern: main"
    echo "  ✓ Require status checks to pass before merging"
    echo "    Add: 'Lint HTML', 'Test backend', 'Validate SAM template'"
    echo "  ✓ Require branches to be up to date before merging"
    echo "  ✓ Do not allow bypassing the above settings"
    exit 0
fi

# Verify gh is authenticated
if ! gh auth status &>/dev/null; then
    echo "Not authenticated. Run: gh auth login"
    exit 1
fi

read -rp "Apply branch protection rules to $REPO/main? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }

gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  "/repos/${REPO}/branches/main/protection" \
  --input - << 'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "Lint HTML",
      "Test backend",
      "Validate SAM template"
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true
}
EOF

echo ""
echo -e "${GREEN}✓ Branch protection rules applied to main${NC}"
echo ""
echo "Rules in effect:"
echo "  ✓ PRs require: Lint HTML, Test backend, Validate SAM template"
echo "  ✓ Branch must be up to date before merging"
echo "  ✓ Force pushes blocked"
echo "  ✓ Branch deletion blocked"
echo "  ✓ Applies to admins too (enforce_admins: true)"
echo ""
echo -e "${YELLOW}Also add CLOUDFRONT_DOMAIN to GitHub Actions variables:${NC}"
echo "  GitHub repo → Settings → Secrets and variables → Actions → Variables"
echo "  Name:  CLOUDFRONT_DOMAIN"
echo "  Value: your-distribution-id.cloudfront.net  (without https://)"
echo ""
