#!/usr/bin/env bash
# =============================================================================
# cloudfront-setup.sh — Create the CloudFront distribution for the resume site
#
# Run this AFTER:
#   1. infra/setup.sh has completed successfully
#   2. sam deploy has run and the S3 bucket has content
#   3. The ACM certificate status is ISSUED (check with: ./infra/check-cert.sh)
#
# What this script does:
#   1. Creates a CloudFront Origin Access Control (OAC)
#   2. Creates the CloudFront distribution pointing at the private S3 bucket
#   3. Attaches the S3 bucket policy to allow CloudFront OAC read access
#   4. Adds a CNAME DNS record reminder for your domain
#   5. Prints the distribution ID and domain for GitHub Actions variable setup
#
# Usage:
#   chmod +x infra/cloudfront-setup.sh
#   ./infra/cloudfront-setup.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}── $* ${NC}"; }

CONFIG_FILE="infra/config.env"
[[ -f "$CONFIG_FILE" ]] || error "infra/config.env not found. Run infra/setup.sh first."
source "$CONFIG_FILE"

[[ -z "${AWS_ACCOUNT_ID:-}" ]] && error "AWS_ACCOUNT_ID not set in config.env"
[[ -z "${S3_BUCKET_NAME:-}" ]]  && error "S3_BUCKET_NAME not set in config.env"
[[ -z "${AWS_REGION:-}" ]]      && error "AWS_REGION not set in config.env"

echo -e "\n${BOLD}CloudFront Distribution Setup${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "S3 bucket : $S3_BUCKET_NAME"
echo "Domain    : ${DOMAIN_NAME:-<not set>}"
echo ""

# ── Step 1: Resolve ACM certificate ARN ───────────────────────────────────────
step "1/5  Resolving ACM certificate"

CERT_ARN=""
if [[ -n "${DOMAIN_NAME:-}" ]]; then
    CERT_ARN=$(aws acm list-certificates \
        --region us-east-1 \
        --certificate-statuses ISSUED \
        --query "CertificateSummaryList[?DomainName=='${DOMAIN_NAME}'].CertificateArn | [0]" \
        --output text 2>/dev/null || echo "")

    if [[ -z "$CERT_ARN" || "$CERT_ARN" == "None" ]]; then
        warn "No ISSUED certificate found for $DOMAIN_NAME in us-east-1."
        warn "Check status with: ./infra/check-cert.sh"
        warn "Continuing WITHOUT custom domain — you can add it later."
        CERT_ARN=""
        DOMAIN_NAME=""
    else
        success "Certificate: $CERT_ARN"
    fi
else
    warn "DOMAIN_NAME not set — creating distribution without custom domain."
fi

# ── Step 2: Create Origin Access Control ──────────────────────────────────────
step "2/5  Creating Origin Access Control (OAC)"

OAC_NAME="resume-oac-${S3_BUCKET_NAME}"

# Check if OAC already exists
EXISTING_OAC=$(aws cloudfront list-origin-access-controls \
    --query "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id | [0]" \
    --output text 2>/dev/null || echo "")

if [[ -n "$EXISTING_OAC" && "$EXISTING_OAC" != "None" ]]; then
    OAC_ID="$EXISTING_OAC"
    success "OAC already exists: $OAC_ID"
else
    OAC_ID=$(aws cloudfront create-origin-access-control \
        --origin-access-control-config "{
            \"Name\": \"${OAC_NAME}\",
            \"Description\": \"OAC for resume S3 bucket\",
            \"SigningProtocol\": \"sigv4\",
            \"SigningBehavior\": \"always\",
            \"OriginAccessControlOriginType\": \"s3\"
        }" \
        --query 'OriginAccessControl.Id' \
        --output text)
    success "OAC created: $OAC_ID"
fi

# ── Step 3: Build distribution config ────────────────────────────────────────
step "3/5  Creating CloudFront distribution"

S3_ORIGIN_DOMAIN="${S3_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com"
CALLER_REF="aws-resume-$(date +%s)"

# Build the distribution config JSON, conditionally including the
# custom domain alias and ACM certificate if DOMAIN_NAME is set.
if [[ -n "${DOMAIN_NAME:-}" && -n "${CERT_ARN:-}" ]]; then
    ALIASES_BLOCK="\"Aliases\": { \"Quantity\": 1, \"Items\": [\"www.${DOMAIN_NAME}\"] },"
    CERT_BLOCK="\"ViewerCertificate\": {
        \"ACMCertificateArn\": \"${CERT_ARN}\",
        \"SSLSupportMethod\": \"sni-only\",
        \"MinimumProtocolVersion\": \"TLSv1.2_2021\"
    }"
else
    ALIASES_BLOCK=""
    CERT_BLOCK="\"ViewerCertificate\": {
        \"CloudFrontDefaultCertificate\": true
    }"
fi

DIST_CONFIG=$(cat <<EOF
{
    "CallerReference": "${CALLER_REF}",
    "Comment": "AWS Resume site",
    "DefaultRootObject": "index.html",
    "HttpVersion": "http2and3",
    "IsIPV6Enabled": true,
    "Enabled": true,
    ${ALIASES_BLOCK}
    "Origins": {
        "Quantity": 1,
        "Items": [{
            "Id": "S3-resume-origin",
            "DomainName": "${S3_ORIGIN_DOMAIN}",
            "OriginAccessControlId": "${OAC_ID}",
            "S3OriginConfig": { "OriginAccessIdentity": "" }
        }]
    },
    "DefaultCacheBehavior": {
        "TargetOriginId": "S3-resume-origin",
        "ViewerProtocolPolicy": "redirect-to-https",
        "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
        "AllowedMethods": {
            "Quantity": 2,
            "Items": ["GET", "HEAD"],
            "CachedMethods": {
                "Quantity": 2,
                "Items": ["GET", "HEAD"]
            }
        },
        "Compress": true
    },
    "CustomErrorResponses": {
        "Quantity": 1,
        "Items": [{
            "ErrorCode": 403,
            "ResponseCode": "200",
            "ResponsePagePath": "/index.html",
            "ErrorCachingMinTTL": 10
        }]
    },
    ${CERT_BLOCK}
}
EOF
)

DIST_RESULT=$(aws cloudfront create-distribution \
    --distribution-config "$DIST_CONFIG" \
    --output json)

DISTRIBUTION_ID=$(echo "$DIST_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Distribution']['Id'])")
CLOUDFRONT_DOMAIN=$(echo "$DIST_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Distribution']['DomainName'])")

success "Distribution created: $DISTRIBUTION_ID"
success "CloudFront domain:    https://$CLOUDFRONT_DOMAIN"

# ── Step 4: Apply S3 bucket policy for OAC ────────────────────────────────────
step "4/5  Applying S3 bucket policy for CloudFront OAC"

sed \
    -e "s|{{S3_BUCKET_NAME}}|${S3_BUCKET_NAME}|g" \
    -e "s|{{AWS_ACCOUNT_ID}}|${AWS_ACCOUNT_ID}|g" \
    -e "s|{{CLOUDFRONT_DISTRIBUTION_ID}}|${DISTRIBUTION_ID}|g" \
    infra/iam-policies/s3-bucket-policy.json > /tmp/s3-bucket-policy.json

aws s3api put-bucket-policy \
    --bucket "$S3_BUCKET_NAME" \
    --policy file:///tmp/s3-bucket-policy.json \
    --region "$AWS_REGION"

success "S3 bucket policy applied — CloudFront OAC has read access"

# ── Step 5: Summary ───────────────────────────────────────────────────────────
step "5/5  Done"

echo ""
echo -e "${GREEN}CloudFront distribution is deploying globally (~5–15 minutes).${NC}"
echo ""
echo "Distribution ID : $DISTRIBUTION_ID"
echo "CloudFront URL  : https://$CLOUDFRONT_DOMAIN"
[[ -n "${DOMAIN_NAME:-}" ]] && echo "Custom domain   : https://www.${DOMAIN_NAME}"
echo ""

if [[ -n "${DOMAIN_NAME:-}" ]]; then
    echo -e "${YELLOW}ACTION REQUIRED — DNS record:${NC}"
    echo "  Add this CNAME at your DNS registrar:"
    echo ""
    echo "  Type  : CNAME"
    echo "  Host  : www"
    echo "  Value : $CLOUDFRONT_DOMAIN"
    echo ""
fi

echo -e "${YELLOW}ACTION REQUIRED — GitHub Actions variable:${NC}"
echo "  Go to: GitHub repo → Settings → Secrets and variables → Actions → Variables"
echo "  Add:   CLOUDFRONT_DISTRIBUTION_ID = $DISTRIBUTION_ID"
echo ""
echo -e "${YELLOW}ACTION REQUIRED — Lock down CORS:${NC}"
echo "  1. In backend/template.yaml, uncomment and set:"
echo "     CORS_ORIGIN: https://www.${DOMAIN_NAME:-<your-cloudfront-domain>}"
echo "  2. Push to main — the backend workflow will redeploy automatically."
echo ""
echo "  Check distribution status with:"
echo "  aws cloudfront get-distribution --id $DISTRIBUTION_ID \\"
echo "    --query 'Distribution.Status' --output text"
echo ""
