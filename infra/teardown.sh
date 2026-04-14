#!/usr/bin/env bash
# =============================================================================
# teardown.sh — Delete all AWS resources created by this project
#
# Use this when you want to shut down the project and stop all AWS charges.
# Resources deleted: CloudFormation stack (Lambda/API GW/DynamoDB),
# CloudFront distribution, S3 buckets, IAM roles, OIDC provider.
#
# The OIDC provider is shared across all GitHub repos in your account.
# The script will ask before deleting it.
#
# Usage:
#   chmod +x infra/teardown.sh
#   ./infra/teardown.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
step()    { echo -e "\n${BOLD}── $* ${NC}"; }

CONFIG_FILE="infra/config.env"
[[ -f "$CONFIG_FILE" ]] || { echo "infra/config.env not found."; exit 1; }
source "$CONFIG_FILE"

echo -e "\n${RED}${BOLD}AWS Resume — Teardown${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━"
warn "This will permanently delete all project resources."
echo ""
read -rp "Type 'delete' to confirm: " confirm
[[ "$confirm" == "delete" ]] || { info "Aborted."; exit 0; }

# ── CloudFormation stack (Lambda, API Gateway, DynamoDB) ──────────────────────
step "1  Delete SAM CloudFormation stack: $STACK_NAME"

if aws cloudformation describe-stacks \
       --stack-name "$STACK_NAME" \
       --region "$AWS_REGION" &>/dev/null; then
    aws cloudformation delete-stack \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION"
    info "Waiting for stack deletion..."
    aws cloudformation wait stack-delete-complete \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION"
    success "Stack deleted"
else
    success "Stack not found — skipping"
fi

# ── CloudFront distribution ───────────────────────────────────────────────────
step "2  Disable and delete CloudFront distribution"

DIST_ID=$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Comment=='AWS Resume site'].Id | [0]" \
    --output text 2>/dev/null || echo "")

if [[ -n "$DIST_ID" && "$DIST_ID" != "None" ]]; then
    # Must disable before deleting — get current ETag
    DIST_CONFIG_JSON=$(aws cloudfront get-distribution-config --id "$DIST_ID")
    ETAG=$(echo "$DIST_CONFIG_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['ETag'])")

    UPDATED_CONFIG=$(echo "$DIST_CONFIG_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['DistributionConfig']['Enabled'] = False
print(json.dumps(d['DistributionConfig']))
")

    aws cloudfront update-distribution \
        --id "$DIST_ID" \
        --distribution-config "$UPDATED_CONFIG" \
        --if-match "$ETAG" > /dev/null

    info "Distribution disabled — waiting for deployment (~5 min)..."
    aws cloudfront wait distribution-deployed --id "$DIST_ID"

    NEW_ETAG=$(aws cloudfront get-distribution-config \
        --id "$DIST_ID" \
        --query ETag --output text)

    aws cloudfront delete-distribution \
        --id "$DIST_ID" \
        --if-match "$NEW_ETAG"
    success "Distribution deleted: $DIST_ID"
else
    success "No CloudFront distribution found — skipping"
fi

# ── S3 buckets ────────────────────────────────────────────────────────────────
step "3  Empty and delete S3 buckets"

for BUCKET in "$S3_BUCKET_NAME" "$SAM_ARTIFACT_BUCKET"; do
    if aws s3api head-bucket --bucket "$BUCKET" --region "$AWS_REGION" &>/dev/null; then
        info "Emptying s3://$BUCKET ..."
        aws s3 rm "s3://$BUCKET" --recursive --region "$AWS_REGION" > /dev/null
        # Delete all object versions if versioning was enabled
        aws s3api list-object-versions --bucket "$BUCKET" --region "$AWS_REGION" \
            --output json 2>/dev/null | python3 -c "
import sys, json, subprocess
data = json.load(sys.stdin)
for key in ['Versions', 'DeleteMarkers']:
    for obj in data.get(key, []):
        subprocess.run([
            'aws', 's3api', 'delete-object',
            '--bucket', '$BUCKET',
            '--key', obj['Key'],
            '--version-id', obj['VersionId'],
            '--region', '$AWS_REGION'
        ], capture_output=True)
" 2>/dev/null || true
        aws s3api delete-bucket --bucket "$BUCKET" --region "$AWS_REGION"
        success "Deleted s3://$BUCKET"
    else
        success "s3://$BUCKET not found — skipping"
    fi
done

# ── IAM roles ─────────────────────────────────────────────────────────────────
step "4  Delete IAM roles"

for ROLE in "GitHubActions-Resume-Frontend" "GitHubActions-Resume-Backend"; do
    if aws iam get-role --role-name "$ROLE" &>/dev/null; then
        # Must delete inline policies before deleting the role
        POLICIES=$(aws iam list-role-policies --role-name "$ROLE" \
            --query PolicyNames --output text)
        for POLICY in $POLICIES; do
            aws iam delete-role-policy \
                --role-name "$ROLE" \
                --policy-name "$POLICY"
        done
        aws iam delete-role --role-name "$ROLE"
        success "Deleted role: $ROLE"
    else
        success "Role $ROLE not found — skipping"
    fi
done

# ── OIDC provider (optional) ──────────────────────────────────────────────────
step "5  GitHub OIDC Identity Provider"

OIDC_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if aws iam get-open-id-connect-provider \
       --open-id-connect-provider-arn "$OIDC_ARN" &>/dev/null; then
    warn "The GitHub OIDC provider is shared across all repos in your AWS account."
    read -rp "Delete it? Only do this if no other repos use GitHub Actions OIDC. [y/N] " del_oidc
    if [[ "${del_oidc,,}" == "y" ]]; then
        aws iam delete-open-id-connect-provider \
            --open-id-connect-provider-arn "$OIDC_ARN"
        success "OIDC provider deleted"
    else
        info "OIDC provider kept"
    fi
else
    success "OIDC provider not found — skipping"
fi

echo ""
echo -e "${GREEN}${BOLD}Teardown complete.${NC}"
echo "All project resources have been removed."
echo ""
