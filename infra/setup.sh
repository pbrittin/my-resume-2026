#!/usr/bin/env bash
# =============================================================================
# setup.sh — AWS Resume Challenge: one-time infrastructure setup
#
# Run this ONCE from the root of your cloned repo before any SAM deploys
# or GitHub Actions runs. It creates every AWS resource the project needs
# except for the SAM-managed ones (Lambda, API Gateway, DynamoDB) which are
# handled by `sam deploy`.
#
# Prerequisites:
#   - AWS CLI v2 configured with credentials that have admin or equivalent access
#   - jq  (brew install jq  /  sudo apt install jq)
#
# Usage:
#   chmod +x infra/setup.sh
#   ./infra/setup.sh
#
# The script is idempotent — safe to re-run if it fails partway through.
# Each step checks whether the resource already exists before creating it.
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}── $* ${NC}"; }

# ── Load configuration ────────────────────────────────────────────────────────
CONFIG_FILE="infra/config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
    error "Configuration file not found: $CONFIG_FILE\nCopy infra/config.env.example to infra/config.env and fill in your values."
fi

# shellcheck source=infra/config.env
source "$CONFIG_FILE"

# Validate required variables
REQUIRED_VARS=(
    AWS_ACCOUNT_ID AWS_REGION GITHUB_USERNAME GITHUB_REPO_NAME
    S3_BUCKET_NAME SAM_ARTIFACT_BUCKET STACK_NAME
)
for var in "${REQUIRED_VARS[@]}"; do
    [[ -z "${!var:-}" ]] && error "Required variable $var is not set in $CONFIG_FILE"
done

echo -e "\n${BOLD}AWS Resume Challenge — Infrastructure Setup${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Account : $AWS_ACCOUNT_ID"
echo "Region  : $AWS_REGION"
echo "Repo    : $GITHUB_USERNAME/$GITHUB_REPO_NAME"
echo "S3      : $S3_BUCKET_NAME"
echo "Stack   : $STACK_NAME"
echo ""
read -rp "Proceed? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { info "Aborted."; exit 0; }

# ── Step 1: OIDC Identity Provider ───────────────────────────────────────────
step "1/7  GitHub OIDC Identity Provider"

OIDC_URL="https://token.actions.githubusercontent.com"
OIDC_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" \
       --region "$AWS_REGION" &>/dev/null; then
    success "OIDC provider already exists — skipping"
else
    # Fetch the current thumbprint dynamically
    THUMBPRINT=$(openssl s_client -connect token.actions.githubusercontent.com:443 \
        -showcerts </dev/null 2>/dev/null \
        | openssl x509 -fingerprint -noout -sha1 \
        | sed 's/://g' \
        | awk -F= '{print tolower($2)}')

    aws iam create-open-id-connect-provider \
        --url "$OIDC_URL" \
        --client-id-list "sts.amazonaws.com" \
        --thumbprint-list "$THUMBPRINT" \
        --region "$AWS_REGION" > /dev/null

    success "OIDC provider created"
fi

# ── Step 2: Frontend S3 bucket ────────────────────────────────────────────────
step "2/7  Frontend S3 Bucket (private — CloudFront access only)"

if aws s3api head-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" &>/dev/null; then
    success "Bucket s3://$S3_BUCKET_NAME already exists — skipping"
else
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
        aws s3api create-bucket \
            --bucket "$S3_BUCKET_NAME" \
            --region "$AWS_REGION" > /dev/null
    else
        aws s3api create-bucket \
            --bucket "$S3_BUCKET_NAME" \
            --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION" > /dev/null
    fi
    success "Bucket created: s3://$S3_BUCKET_NAME"
fi

# Block all public access — CloudFront OAC handles access privately
aws s3api put-public-access-block \
    --bucket "$S3_BUCKET_NAME" \
    --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
    --region "$AWS_REGION"
success "Public access block enforced on s3://$S3_BUCKET_NAME"

# ── Step 3: SAM artifact bucket ───────────────────────────────────────────────
step "3/7  SAM Artifact Bucket (stores Lambda deployment packages)"

if aws s3api head-bucket --bucket "$SAM_ARTIFACT_BUCKET" --region "$AWS_REGION" &>/dev/null; then
    success "SAM artifact bucket already exists — skipping"
else
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
        aws s3api create-bucket \
            --bucket "$SAM_ARTIFACT_BUCKET" \
            --region "$AWS_REGION" > /dev/null
    else
        aws s3api create-bucket \
            --bucket "$SAM_ARTIFACT_BUCKET" \
            --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION" > /dev/null
    fi

    # Enable versioning so SAM can reference previous deployment packages
    aws s3api put-bucket-versioning \
        --bucket "$SAM_ARTIFACT_BUCKET" \
        --versioning-configuration Status=Enabled \
        --region "$AWS_REGION"

    # Block public access on artifact bucket too
    aws s3api put-public-access-block \
        --bucket "$SAM_ARTIFACT_BUCKET" \
        --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
        --region "$AWS_REGION"

    success "SAM artifact bucket created: s3://$SAM_ARTIFACT_BUCKET"
fi

# ── Step 4: IAM role — GitHub Actions frontend ────────────────────────────────
step "4/7  IAM Role: GitHubActions-Resume-Frontend"

FRONTEND_ROLE="GitHubActions-Resume-Frontend"
FRONTEND_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${FRONTEND_ROLE}"

# Render trust policy with actual values
sed \
    -e "s|{{AWS_ACCOUNT_ID}}|${AWS_ACCOUNT_ID}|g" \
    -e "s|{{GITHUB_USERNAME}}|${GITHUB_USERNAME}|g" \
    -e "s|{{GITHUB_REPO_NAME}}|${GITHUB_REPO_NAME}|g" \
    infra/iam-policies/frontend-trust-policy.json > /tmp/frontend-trust-policy.json

if aws iam get-role --role-name "$FRONTEND_ROLE" &>/dev/null; then
    # Update trust policy in case repo details changed
    aws iam update-assume-role-policy \
        --role-name "$FRONTEND_ROLE" \
        --policy-document file:///tmp/frontend-trust-policy.json > /dev/null
    success "Role $FRONTEND_ROLE already exists — trust policy updated"
else
    aws iam create-role \
        --role-name "$FRONTEND_ROLE" \
        --assume-role-policy-document file:///tmp/frontend-trust-policy.json \
        --description "Assumed by GitHub Actions to deploy the resume frontend" \
        --tags Key=Project,Value=aws-resume > /dev/null
    success "Role created: $FRONTEND_ROLE"
fi

# Render and apply the least-privilege permission policy
sed \
    -e "s|{{AWS_ACCOUNT_ID}}|${AWS_ACCOUNT_ID}|g" \
    -e "s|{{AWS_REGION}}|${AWS_REGION}|g" \
    -e "s|{{S3_BUCKET_NAME}}|${S3_BUCKET_NAME}|g" \
    infra/iam-policies/frontend-permissions.json > /tmp/frontend-permissions.json

aws iam put-role-policy \
    --role-name "$FRONTEND_ROLE" \
    --policy-name "ResumeFrontendDeployPolicy" \
    --policy-document file:///tmp/frontend-permissions.json > /dev/null
success "Permissions policy applied to $FRONTEND_ROLE"

# ── Step 5: IAM role — GitHub Actions backend ─────────────────────────────────
step "5/7  IAM Role: GitHubActions-Resume-Backend"

BACKEND_ROLE="GitHubActions-Resume-Backend"
BACKEND_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${BACKEND_ROLE}"

sed \
    -e "s|{{AWS_ACCOUNT_ID}}|${AWS_ACCOUNT_ID}|g" \
    -e "s|{{GITHUB_USERNAME}}|${GITHUB_USERNAME}|g" \
    -e "s|{{GITHUB_REPO_NAME}}|${GITHUB_REPO_NAME}|g" \
    infra/iam-policies/backend-trust-policy.json > /tmp/backend-trust-policy.json

if aws iam get-role --role-name "$BACKEND_ROLE" &>/dev/null; then
    aws iam update-assume-role-policy \
        --role-name "$BACKEND_ROLE" \
        --policy-document file:///tmp/backend-trust-policy.json > /dev/null
    success "Role $BACKEND_ROLE already exists — trust policy updated"
else
    aws iam create-role \
        --role-name "$BACKEND_ROLE" \
        --assume-role-policy-document file:///tmp/backend-trust-policy.json \
        --description "Assumed by GitHub Actions to deploy the resume backend via SAM" \
        --tags Key=Project,Value=aws-resume > /dev/null
    success "Role created: $BACKEND_ROLE"
fi

sed \
    -e "s|{{AWS_ACCOUNT_ID}}|${AWS_ACCOUNT_ID}|g" \
    -e "s|{{AWS_REGION}}|${AWS_REGION}|g" \
    -e "s|{{SAM_ARTIFACT_BUCKET}}|${SAM_ARTIFACT_BUCKET}|g" \
    -e "s|{{STACK_NAME}}|${STACK_NAME}|g" \
    infra/iam-policies/backend-permissions.json > /tmp/backend-permissions.json

aws iam put-role-policy \
    --role-name "$BACKEND_ROLE" \
    --policy-name "ResumeBackendDeployPolicy" \
    --policy-document file:///tmp/backend-permissions.json > /dev/null
success "Permissions policy applied to $BACKEND_ROLE"

# ── Step 6: ACM Certificate (us-east-1 required for CloudFront) ───────────────
step "6/7  ACM TLS Certificate"

if [[ -z "${DOMAIN_NAME:-}" ]]; then
    warn "DOMAIN_NAME not set in config.env — skipping ACM certificate."
    warn "Set it and re-run this script when your domain is ready."
    CERT_ARN=""
else
    # Check for an existing issued certificate for this domain
    CERT_ARN=$(aws acm list-certificates \
        --region us-east-1 \
        --certificate-statuses ISSUED PENDING_VALIDATION \
        --query "CertificateSummaryList[?DomainName=='${DOMAIN_NAME}'].CertificateArn | [0]" \
        --output text 2>/dev/null || echo "")

    if [[ -n "$CERT_ARN" && "$CERT_ARN" != "None" ]]; then
        success "Certificate already exists: $CERT_ARN"
    else
        CERT_ARN=$(aws acm request-certificate \
            --domain-name "$DOMAIN_NAME" \
            --subject-alternative-names "www.${DOMAIN_NAME}" \
            --validation-method DNS \
            --region us-east-1 \
            --tags Key=Project,Value=aws-resume \
            --query CertificateArn \
            --output text)

        echo ""
        warn "Certificate requested: $CERT_ARN"
        warn "ACTION REQUIRED: Add the DNS CNAME validation records shown below"
        warn "to your DNS registrar, then wait for status to become ISSUED."
        echo ""
        aws acm describe-certificate \
            --certificate-arn "$CERT_ARN" \
            --region us-east-1 \
            --query 'Certificate.DomainValidationOptions[*].{Domain:DomainName,Name:ResourceRecord.Name,Value:ResourceRecord.Value}' \
            --output table
    fi
fi

# ── Step 7: Summary ───────────────────────────────────────────────────────────
step "7/7  Setup Complete — Next Steps"

echo ""
echo -e "${GREEN}Resources created/verified:${NC}"
echo "  ✓  GitHub OIDC provider"
echo "  ✓  s3://$S3_BUCKET_NAME  (frontend, private)"
echo "  ✓  s3://$SAM_ARTIFACT_BUCKET  (SAM artifacts)"
echo "  ✓  IAM role: $FRONTEND_ROLE"
echo "  ✓  IAM role: $BACKEND_ROLE"
[[ -n "${CERT_ARN:-}" ]] && echo "  ✓  ACM certificate: $CERT_ARN"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Validate the ACM certificate via DNS (if requested above)"
echo "  2. Run the first SAM deploy manually:"
echo "       cd backend"
echo "       sam build"
echo "       sam deploy --guided"
echo "         → s3_bucket: $SAM_ARTIFACT_BUCKET"
echo "         → stack_name: $STACK_NAME"
echo "         → region: $AWS_REGION"
echo "  3. Paste the printed ApiUrl into frontend/js/main.js as API_URL"
echo "  4. Create the CloudFront distribution:"
echo "       ./infra/cloudfront-setup.sh"
echo "  5. Add these GitHub Actions variables to your repo"
echo "     (Settings → Secrets and variables → Actions → Variables):"
echo ""
echo "       AWS_ACCOUNT_ID             = $AWS_ACCOUNT_ID"
echo "       AWS_REGION                 = $AWS_REGION"
echo "       S3_BUCKET                  = $S3_BUCKET_NAME"
echo "       SAM_STACK_NAME             = $STACK_NAME"
echo "       CLOUDFRONT_DISTRIBUTION_ID = <from cloudfront-setup.sh output>"
echo ""
echo "  6. Push your resume HTML, then let GitHub Actions handle all future deploys."
echo ""
